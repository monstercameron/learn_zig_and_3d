//! # Main Entry Point: The Heart of the Application
//!
//! This file is the equivalent of your `index.js` or the main script that kicks everything off.
//! It orchestrates the entire application lifecycle:
//! 1. **Initialization**: Sets up the application window and the renderer.
//! 2. **Event Loop**: Runs the main loop that processes user input and renders frames.
//! 3. **Cleanup**: Ensures all resources are freed when the application closes.
//!
//! ## JavaScript Analogy
//!
//! Think of this file as the top-level script in an HTML page.
//!
//! ```javascript
//! // 1. Initialization
//! const canvas = document.createElement('canvas');
//! const renderer = new Renderer(canvas);
//!
//! // 2. Event Loop (simplified)
//! function gameLoop() {
//!   const events = getPendingUserEvents(); // e.g., keyboard, mouse
//!   processEvents(events);
//!   renderer.renderScene();
//!   requestAnimationFrame(gameLoop);
//! }
//!
//! // 3. Start the loop
//! requestAnimationFrame(gameLoop);
//! ```
//!
const std = @import("std");
const profiler = @import("core/profiler.zig");
const math = @import("core/math.zig");
const zphysics = @import("zphysics");

// Import other modules from our project.
// JS Analogy: `const Window = require('./window.js');`
const Window = @import("platform/window.zig").Window;
const renderer_module = @import("render/renderer.zig");
const Renderer = renderer_module.Renderer;
const LightShadowMode = renderer_module.LightInfo.ShadowMode;
const CursorStyle = renderer_module.CursorStyle;
const SceneItemBinding = renderer_module.SceneItemBinding;
const SceneItemTranslateRequest = renderer_module.SceneItemTranslateRequest;
const gltf_loader = @import("assets/gltf_loader.zig");
const obj_loader = @import("assets/obj_loader.zig");
const texture = @import("assets/texture.zig");
const mesh_module = @import("render/core/mesh.zig");
const config = @import("core/app_config.zig");
const cpu_features = @import("core/cpu_features.zig");
const app_loop = @import("app_loop.zig");
const platform_loop = @import("platform/loop.zig");
const input = @import("platform_input");
const input_actions = @import("input_actions");
const log = @import("core/log.zig");
const scene_runtime = @import("scene_main");
const main_module = @This();

const app_logger = log.get("app.main");
const scenes_index_path = "assets/configs/scenes/index.json";
const scene_texture_slots_capacity: usize = scene_runtime.max_texture_slots;
const minimal_triangle_demo_enabled = false;

const SceneModelType = scene_runtime.LoadedSceneModelType;
const SceneAssetConfigEntry = scene_runtime.SceneAssetConfigEntry;
const SceneTextureSlotEntry = scene_runtime.SceneTextureSlotEntry;
const SceneFile = scene_runtime.SceneFile;
const SceneIndexEntry = scene_runtime.SceneIndexEntry;
const SceneIndexFile = scene_runtime.SceneIndexFile;
const LoadedSceneAsset = scene_runtime.LoadedSceneAsset;
const LoadedSceneLight = scene_runtime.LoadedSceneLight;
const LoadedSceneDescription = scene_runtime.LoadedSceneDescription;
const LoadedSceneRuntimeKind = scene_runtime.LoadedSceneRuntimeKind;

const SceneMeshResources = struct {
    mesh: mesh_module.Mesh,
    render_instances: []SceneRenderInstance,

    fn deinit(self: *SceneMeshResources, allocator: std.mem.Allocator) void {
        for (self.render_instances) |instance| {
            allocator.free(instance.local_vertices);
            allocator.free(instance.local_normals);
        }
        self.mesh.deinit();
        allocator.free(self.render_instances);
    }
};

const SceneRenderInstance = struct {
    entity: scene_runtime.EntityId,
    asset_index: usize,
    vertex_start: usize,
    vertex_count: usize,
    triangle_start: usize,
    triangle_count: usize,
    local_bounds_min: math.Vec3,
    local_bounds_max: math.Vec3,
    bounds_min: math.Vec3,
    bounds_max: math.Vec3,
    local_vertices: []math.Vec3,
    local_normals: []math.Vec3,
};

const AppSession = struct {
    window: *Window,
    renderer: *Renderer,
    phase13_runtime: *scene_runtime.SceneRuntime,
    scene_resources: *SceneMeshResources,
    minimal_demo: bool = false,
    mouse_grabbed: *bool,
    selected_scene_entity_pin: *?scene_runtime.EntityId,
    last_runtime_update_ns: i128,
    minimized: bool = false,
    close_requested: bool = false,
};

const MinimalAppSession = struct {
    window: *Window,
    renderer: *Renderer,
    mouse_grabbed: *bool,
    minimized: bool = false,
    close_requested: bool = false,
};

fn logDirectFrameTimings(renderer: *Renderer, scope: []const u8) void {
    const timings = renderer.lastDirectFrameTimings();
    app_logger.infoSub(scope, "timings clear={d:.3}ms build={d:.3}ms compile={d:.3}ms bin={d:.3}ms raster={d:.3}ms shade={d:.3}ms compose={d:.3}ms post={d:.3}ms present={d:.3}ms primitives={d} touched_tiles={d}", .{
        @as(f64, @floatFromInt(timings.clear_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.build_batch_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.compile_draw_list_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.binning_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.raster_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.shading_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.composition_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.post_process_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(timings.present_ns)) / 1_000_000.0,
        timings.primitive_count,
        timings.touched_tiles,
    });
}

fn toPlatformCursorStyle(style: CursorStyle) platform_loop.CursorStyle {
    return switch (style) {
        .arrow => .arrow,
        .grab => .grab,
        .grabbing => .grabbing,
        .hidden => .hidden,
    };
}

fn applyPlatformCursor(renderer: *Renderer) void {
    platform_loop.setCursor(toPlatformCursorStyle(renderer.desiredCursorStyle()));
}

fn syncFirstPersonMouseGrab(window: *Window, renderer: *Renderer, mouse_grabbed: *bool) void {
    const focused = platform_loop.windowHasFocus(window.hwnd);
    const should_grab = focused and renderer.isFirstPersonMode();
    if (should_grab) {
        if (!mouse_grabbed.*) {
            platform_loop.setMouseCapture(window.hwnd, true);
            platform_loop.centerCursorInWindow(window.hwnd);
            mouse_grabbed.* = true;
        }
        return;
    }
    if (mouse_grabbed.*) {
        platform_loop.setMouseCapture(window.hwnd, false);
        mouse_grabbed.* = false;
    }
}

fn consumePlatformEvent(session: *AppSession, event: platform_loop.PlatformEvent) void {
    const renderer = session.renderer;
    switch (event) {
        .key => |payload| renderer.handleKeyInput(payload.code, payload.is_down),
        .char => |char_code| renderer.handleCharInput(char_code),
        .focus_changed => |focused| {
            if (focused) {
                renderer.handleFocusGained();
            } else {
                renderer.handleFocusLost();
                session.mouse_grabbed.* = false;
            }
            applyPlatformCursor(renderer);
        },
        .raw_mouse_delta => |delta| renderer.handleRawMouseDelta(delta.x, delta.y),
        .mouse_move => |move| {
            if (!renderer.isFirstPersonMode()) {
                if (!move.left_down) renderer.handleMouseLeftRelease(move.x, move.y);
                if (!move.right_down) renderer.handleMouseRightRelease(move.x, move.y);
            }
            renderer.handleMouseMove(move.x, move.y);
            applyPlatformCursor(renderer);
        },
        .mouse_button => |button| {
            switch (button.button) {
                .left => if (button.pressed)
                    renderer.handleMouseLeftClick(button.x, button.y)
                else
                    renderer.handleMouseLeftRelease(button.x, button.y),
                .right => if (button.pressed)
                    renderer.handleMouseRightClick(button.x, button.y)
                else
                    renderer.handleMouseRightRelease(button.x, button.y),
            }
            applyPlatformCursor(renderer);
        },
        .resized => |size| {
            if (size.width > 0 and size.height > 0) {
                config.WINDOW_WIDTH = @intCast(size.width);
                config.WINDOW_HEIGHT = @intCast(size.height);
                renderer.setPresentSize(size.width, size.height);
            }
        },
        .minimized => {
            session.minimized = true;
            renderer.setPresentMinimized(true);
        },
        .restored => {
            session.minimized = false;
            renderer.setPresentMinimized(false);
        },
        .close_requested => {
            session.close_requested = true;
        },
        .quit => {},
    }
}

fn pumpRendererEvents(renderer: *Renderer) bool {
    var dummy_mouse_grabbed = false;
    var dummy_selected_pin: ?scene_runtime.EntityId = null;
    var dummy_window = Window{ .hwnd = renderer.hwnd };
    var session = AppSession{
        .window = &dummy_window,
        .renderer = renderer,
        .phase13_runtime = undefined,
        .scene_resources = undefined,
        .mouse_grabbed = &dummy_mouse_grabbed,
        .selected_scene_entity_pin = &dummy_selected_pin,
        .last_runtime_update_ns = 0,
    };
    const Hooks = struct {
        pub fn handleEvent(target: *AppSession, event: platform_loop.PlatformEvent) void {
            consumePlatformEvent(target, event);
        }
    };
    return platform_loop.pumpEvents(&session, Hooks);
}

fn populateSceneRuntimeBootstrap(runtime: *scene_runtime.SceneRuntime, scene_desc: scene_runtime.LoadedSceneDescription) !void {
    const default_camera_modules = [_][]const u8{
        "scene.default.camera_controls",
        "scene.default.renderer_controls",
    };
    const bootstrap_camera_scripts = try runtime.allocator.alloc(scene_runtime.BootstrapScriptAttachment, scene_desc.camera_scripts.len + default_camera_modules.len);
    defer runtime.allocator.free(bootstrap_camera_scripts);
    var bootstrap_camera_script_count: usize = 0;
    for (scene_desc.camera_scripts) |script| {
        bootstrap_camera_scripts[bootstrap_camera_script_count] = .{ .module_name = script.module_name };
        bootstrap_camera_script_count += 1;
    }
    for (default_camera_modules) |module_name| {
        var already_present = false;
        for (scene_desc.camera_scripts) |script| {
            if (std.mem.eql(u8, script.module_name, module_name)) {
                already_present = true;
                break;
            }
        }
        if (already_present) continue;
        bootstrap_camera_scripts[bootstrap_camera_script_count] = .{ .module_name = module_name };
        bootstrap_camera_script_count += 1;
    }

    const bootstrap_lights = try runtime.allocator.alloc(scene_runtime.BootstrapLight, scene_desc.lights.len);
    defer runtime.allocator.free(bootstrap_lights);
    for (scene_desc.lights, 0..) |light, index| {
        const light_scripts = try runtime.allocator.alloc(scene_runtime.BootstrapScriptAttachment, light.scripts.len);
        for (light.scripts, 0..) |script, script_index| {
            light_scripts[script_index] = .{ .module_name = script.module_name };
        }
        bootstrap_lights[index] = .{
            .authored_id = light.authored_id,
            .parent_authored_id = light.parent_authored_id,
            .scripts = light_scripts,
            .direction = .{ .x = light.direction.x, .y = light.direction.y, .z = light.direction.z },
            .distance = light.distance,
            .color = .{ .x = light.color.x, .y = light.color.y, .z = light.color.z },
            .glow_radius = light.glow_radius,
            .glow_intensity = light.glow_intensity,
            .shadow_mode = light.shadow_mode,
            .shadow_update_interval_frames = light.shadow_update_interval_frames,
            .shadow_map_size = light.shadow_map_size,
        };
    }

    const bootstrap_assets = try runtime.allocator.alloc(scene_runtime.BootstrapAsset, scene_desc.assets.len);
    defer {
        for (bootstrap_assets) |asset| {
            if (asset.texture_slots.len != 0) runtime.allocator.free(asset.texture_slots);
            if (asset.scripts.len != 0) runtime.allocator.free(asset.scripts);
        }
        for (bootstrap_lights) |light| {
            if (light.scripts.len != 0) runtime.allocator.free(light.scripts);
        }
        runtime.allocator.free(bootstrap_assets);
    }

    for (scene_desc.assets, 0..) |asset, asset_index| {
        const texture_slots = try runtime.allocator.alloc(scene_runtime.BootstrapTextureSlot, asset.texture_slots.len);
        for (asset.texture_slots, 0..) |slot, slot_index| {
            texture_slots[slot_index] = .{ .slot = slot.slot, .path = slot.path };
        }
        const asset_scripts = try runtime.allocator.alloc(scene_runtime.BootstrapScriptAttachment, asset.scripts.len);
        for (asset.scripts, 0..) |script, script_index| {
            asset_scripts[script_index] = .{ .module_name = script.module_name };
        }
        bootstrap_assets[asset_index] = .{
            .authored_id = asset.authored_id,
            .parent_authored_id = asset.parent_authored_id,
            .scripts = asset_scripts,
            .model_path = asset.model_path,
            .position = .{ .x = asset.position.x, .y = asset.position.y, .z = asset.position.z },
            .rotation_deg = .{ .x = asset.rotation_deg.x, .y = asset.rotation_deg.y, .z = asset.rotation_deg.z },
            .scale = .{ .x = asset.scale.x, .y = asset.scale.y, .z = asset.scale.z },
            .texture_slots = texture_slots,
            .physics_motion = asset.physics_motion,
            .physics_shape = asset.physics_shape,
            .physics_mass = asset.physics_mass,
            .physics_restitution = asset.physics_restitution,
        };
    }

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .authored_id = scene_desc.camera_authored_id,
            .parent_authored_id = scene_desc.camera_parent_authored_id,
            .scripts = bootstrap_camera_scripts[0..bootstrap_camera_script_count],
            .position = .{ .x = scene_desc.camera_position.x, .y = scene_desc.camera_position.y, .z = scene_desc.camera_position.z },
            .pitch = scene_desc.camera_orientation_pitch,
            .yaw = scene_desc.camera_orientation_yaw,
            .fov_deg = scene_desc.camera_fov_deg,
        },
        .lights = bootstrap_lights,
        .assets = bootstrap_assets,
        .hdri_path = scene_desc.hdri_path,
    });
}

fn toSceneLightShadowMode(mode: LightShadowMode) scene_runtime.components.LightShadowMode {
    return switch (mode) {
        .none => .none,
        .shadow_map => .shadow_map,
        .meshlet_ray => .meshlet_ray,
    };
}

fn toRendererLightShadowMode(mode: scene_runtime.components.LightShadowMode) LightShadowMode {
    return switch (mode) {
        .none => .none,
        .shadow_map => .shadow_map,
        .meshlet_ray => .meshlet_ray,
    };
}

fn toRenderVec3(vec: anytype) math.Vec3 {
    return .{ .x = vec.x, .y = vec.y, .z = vec.z };
}

fn entityToSelectionId(entity: scene_runtime.EntityId) u64 {
    return @bitCast(entity);
}

fn selectionIdToEntity(selection_id: u64) scene_runtime.EntityId {
    return @bitCast(selection_id);
}

fn syncRendererFromSceneSnapshot(renderer: *Renderer, snapshot: *const scene_runtime.RenderSnapshot) !void {
    if (snapshot.active_camera) |camera| {
        renderer.setCameraPosition(toRenderVec3(camera.state.position));
        renderer.setCameraOrientation(camera.state.pitch, camera.state.yaw);
        renderer.setCameraFov(camera.state.fov_deg);
    }

    try renderer.setLightCapacity(snapshot.lights.items.len);
    for (snapshot.lights.items, 0..) |light, index| {
        const direction = if (light.kind == .directional)
            toRenderVec3(light.position)
        else
            math.Vec3.new(0.0, -1.0, 0.0);
        renderer.setDirectionalLight(index, direction, light.range, toRenderVec3(light.color));
        renderer.setLightShadowMode(index, toRendererLightShadowMode(light.shadow_mode));
        renderer.setLightShadowUpdateInterval(index, light.shadow_update_interval_frames);
        try renderer.setLightShadowMapSize(index, light.shadow_map_size);
        renderer.setLightGlow(index, light.glow_radius, light.glow_intensity);
    }
}

fn applySceneRendererCommand(renderer: *Renderer, command: scene_runtime.Command) void {
    switch (command) {
        .set_camera_mode => |mode| renderer.applyCameraModeCommand(@intFromEnum(mode)),
        .toggle_scene_item_gizmo => renderer.toggleSceneItemGizmo(),
        .toggle_light_gizmo => renderer.toggleLightGizmo(),
        .set_gizmo_axis => |axis| renderer.setActiveGizmoAxis(@intFromEnum(axis)),
        .cycle_light_selection => renderer.cycleLightGizmoSelection(),
        .nudge_active_gizmo => |payload| renderer.nudgeActiveGizmo(payload.delta),
        .toggle_render_overlay => renderer.toggleRenderOverlay(),
        .toggle_shadow_debug => renderer.toggleHybridShadowDebug(),
        .advance_shadow_debug => renderer.advanceHybridShadowDebug(),
        .adjust_camera_fov => {},
        else => {},
    }
}

const SceneLoadingProgress = struct {
    renderer: *Renderer,
    running: *bool,
    pump: ?*const fn (*Renderer) bool,
    total_steps: usize,
    completed_steps: usize = 0,
};

fn sceneLoadingTotalSteps(scene_desc: LoadedSceneDescription) usize {
    return @max(@as(usize, 1), scene_desc.assets.len + scene_desc.textureSlotCount() + 1);
}

/// renderSceneLoadingFrame renders Main output.
fn renderSceneLoadingFrame(progress: *SceneLoadingProgress) void {
    if (!progress.running.*) return;
    if (!progress.renderer.renderLoadingOverlayFrame(progress.pump)) {
        progress.running.* = false;
    }
}

fn startSceneLoadingProgress(progress: ?*SceneLoadingProgress) void {
    if (progress) |state| {
        state.renderer.updateSceneLoadingOverlay(0, state.total_steps, "Preparing assets...");
        renderSceneLoadingFrame(state);
    }
}

fn advanceSceneLoadingProgress(progress: ?*SceneLoadingProgress, phase: []const u8) void {
    if (progress) |state| {
        if (!state.running.*) return;
        state.completed_steps = @min(state.total_steps, state.completed_steps + 1);
        state.renderer.updateSceneLoadingOverlay(state.completed_steps, state.total_steps, phase);
        renderSceneLoadingFrame(state);
    }
}

/// # Application Entry Point
/// This `main` function is where the program execution begins.
/// JS Analogy: Think of this as an `async function main() { ... }` that is called
/// as soon as the script loads. The `!void` means it can return an error but
/// doesn't return a value on success.
pub fn main() !void {
    profiler.Profiler.init(std.heap.page_allocator);
    defer profiler.Profiler.deinit();
    // ========== INITIALIZATION PHASE ==========

    // Set up a general-purpose allocator for dynamic memory.
    // JS Analogy: JavaScript has a garbage collector that manages memory for you.
    // In Zig, you often manage memory manually. This line gets us a "tool" for
    // allocating and freeing memory.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // `defer` is like a `finally` block for a specific line. This guarantees
    // that `gpa.deinit()` is called at the end of the `main` function, cleaning up the allocator.
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const requested_renderer_ttl_ns = loadRendererTtlNs(allocator);
    const renderer_ttl_frames = loadRendererTtlFrames(allocator);
    const profile_frame_target = loadProfileFrameTarget(allocator);
    const auto_profile_ttl_frames: ?u64 = if (renderer_ttl_frames == null and profile_frame_target != null)
        profile_frame_target.? + 30
    else
        null;
    const effective_ttl_frames = renderer_ttl_frames orelse auto_profile_ttl_frames;
    const renderer_ttl_ns = requested_renderer_ttl_ns orelse if (effective_ttl_frames == null)
        defaultRendererTtlNs()
    else
        null;
    const renderer_start_ns = std.time.nanoTimestamp();

    log.init(allocator);
    defer log.deinit();
    app_logger.infoSub("bootstrap", "log manager initialized", .{});
    const isa_support = cpu_features.detect();
    app_logger.infoSub(
        "cpu",
        "runtime ISA support neon={} sse2={} avx={} fma={} avx2={} avx512f={} avx512bw={} amx_tile={} amx_int8={} amx_bf16={}",
        .{
            isa_support.neon,
            isa_support.sse2,
            isa_support.avx,
            isa_support.fma,
            isa_support.avx2,
            isa_support.avx512f,
            isa_support.avx512bw,
            isa_support.amx_tile,
            isa_support.amx_int8,
            isa_support.amx_bf16,
        },
    );
    app_logger.infoSub(
        "cpu",
        "runtime ISA state os_avx={} os_avx512={} os_amx={} preferred_backend={s}",
        .{
            isa_support.os_avx_state,
            isa_support.os_avx512_state,
            isa_support.os_amx_state,
            @tagName(isa_support.preferredVectorBackend()),
        },
    );
    if (renderer_ttl_ns) |ttl_ns| {
        app_logger.infoSub("bootstrap", "renderer TTL active {d:.3}s", .{@as(f64, @floatFromInt(ttl_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))});
    }
    if (effective_ttl_frames) |ttl_frames| {
        app_logger.infoSub("bootstrap", "renderer TTL active {} frame(s)", .{ttl_frames});
    }

    // Create a window.
    // JS Analogy: `const window = new Window(800, 600);`
    // The `try` keyword is like `await` for a function that might fail. If `Window.init`
    // returns an error, `main` will immediately stop and report the error.
    config.load(allocator, "assets/configs/default.settings.json") catch |err| {
        app_logger.errSub("bootstrap", "Failed to load config: {any}", .{err});
    };
    // Keep pass toggles in explicit override files so scene agents know where to edit
    // without searching renderer internals.
    config.loadRenderPasses(allocator, "assets/configs/render_passes.json") catch |err| {
        app_logger.errSub("bootstrap", "Failed to load render pass config: {any}", .{err});
    };
    config.loadEngineIni(allocator, "assets/configs/engine.ini") catch |err| {
        app_logger.errSub("bootstrap", "Failed to load engine ini: {any}", .{err});
    };
    defer config.deinit();

    const initial_width = @as(i32, @intCast(config.WINDOW_WIDTH));
    const initial_height = @as(i32, @intCast(config.WINDOW_HEIGHT));
    var window = try Window.init(.{
        .title = config.WINDOW_TITLE,
        .width = initial_width,
        .height = initial_height,
        .visible = true,
    });
    defer window.deinit(); // Guarantees the window is destroyed on exit.
    try platform_loop.registerRawMouseInput(window.hwnd);
    app_logger.infoSub("bootstrap", "window created {d}x{d}", .{ initial_width, initial_height });

    // Safely enforce a minimum size to prevent 0-dimension crashes
    const rw = (config.WINDOW_WIDTH * config.RENDER_RESOLUTION_SCALE_PERCENT) / 100;
    const rh = (config.WINDOW_HEIGHT * config.RENDER_RESOLUTION_SCALE_PERCENT) / 100;
    const render_width = @as(i32, @intCast(@max(1, rw)));
    const render_height = @as(i32, @intCast(@max(1, rh)));

    // Create a renderer.
    // JS Analogy: `const renderer = canvas.getContext('2d');`
    var renderer = try Renderer.init(window.hwnd, render_width, render_height, allocator);
    defer renderer.deinit(); // Guarantees the renderer is cleaned up on exit.
    app_logger.infoSub("bootstrap", "renderer initialized backbuffer={d}x{d}", .{ renderer.bitmap.width, renderer.bitmap.height });

    var running = true;
    var mouse_grabbed = false;

    if (minimal_triangle_demo_enabled) {
        try renderer.setLightCapacity(0);
        renderer.show_light_orb = false;
        renderer.show_frame_pacing_overlay = false;
        renderer.show_render_overlay = false;
        renderer.setCameraPosition(math.Vec3.new(0.0, 0.0, -3.0));
        renderer.setCameraOrientation(0.0, 0.0);
        renderer.setCameraFov(config.CAMERA_FOV_INITIAL);
        renderer.setSceneCameraScriptActive(false);
        app_logger.infoSub("bootstrap", "minimal primitive showcase active", .{});

        const MinimalDriver = struct {
            pub fn beginFrame(session: *MinimalAppSession) void {
                session.renderer.keys_pressed.beginFrame();
                session.renderer.mouse_input.beginFrame();
            }

            pub fn pump(session: *MinimalAppSession) bool {
                const Hooks = struct {
                    pub fn handleEvent(target: *MinimalAppSession, event: platform_loop.PlatformEvent) void {
                        switch (event) {
                            .key => |payload| target.renderer.handleKeyInput(payload.code, payload.is_down),
                            .char => |char_code| target.renderer.handleCharInput(char_code),
                            .focus_changed => |focused| {
                                if (focused) target.renderer.handleFocusGained() else {
                                    target.renderer.handleFocusLost();
                                    target.mouse_grabbed.* = false;
                                }
                                applyPlatformCursor(target.renderer);
                            },
                            .raw_mouse_delta => |delta| target.renderer.handleRawMouseDelta(delta.x, delta.y),
                            .mouse_move => |move| {
                                target.renderer.handleMouseMove(move.x, move.y);
                                applyPlatformCursor(target.renderer);
                            },
                            .mouse_button => |button| {
                                switch (button.button) {
                                    .left => if (button.pressed)
                                        target.renderer.handleMouseLeftClick(button.x, button.y)
                                    else
                                        target.renderer.handleMouseLeftRelease(button.x, button.y),
                                    .right => if (button.pressed)
                                        target.renderer.handleMouseRightClick(button.x, button.y)
                                    else
                                        target.renderer.handleMouseRightRelease(button.x, button.y),
                                }
                                applyPlatformCursor(target.renderer);
                            },
                            .resized => |size| {
                                if (size.width > 0 and size.height > 0) {
                                    config.WINDOW_WIDTH = @intCast(size.width);
                                    config.WINDOW_HEIGHT = @intCast(size.height);
                                    target.renderer.setPresentSize(size.width, size.height);
                                }
                            },
                            .minimized => {
                                target.minimized = true;
                                target.renderer.setPresentMinimized(true);
                            },
                            .restored => {
                                target.minimized = false;
                                target.renderer.setPresentMinimized(false);
                            },
                            .close_requested => target.close_requested = true,
                            .quit => {},
                        }
                    }
                };
                const keep_running = platform_loop.pumpEvents(session, Hooks);
                return keep_running and !session.close_requested;
            }

            pub fn update(session: *MinimalAppSession, _: u32) !void {
                syncFirstPersonMouseGrab(session.window, session.renderer, session.mouse_grabbed);
                applyPlatformCursor(session.renderer);
            }

            pub fn shouldRender(session: *MinimalAppSession) bool {
                if (session.minimized or session.close_requested) return false;
                return session.renderer.shouldRenderFrame();
            }

            pub fn waitUntilNextFrame(session: *MinimalAppSession) void {
                session.renderer.waitUntilNextFrame();
            }

            pub fn render(session: *MinimalAppSession) !void {
                try session.renderer.renderMinimalPrimitiveFrame(pumpRendererEvents);
            }

            pub fn onTtlExpired(_: *MinimalAppSession, kind: enum { time, frames }) void {
                switch (kind) {
                    .time => app_logger.info("renderer TTL expired, exiting", .{}),
                    .frames => app_logger.info("renderer frame TTL expired, exiting", .{}),
                }
            }

            pub fn onMessagePumpShutdown(_: *MinimalAppSession) void {
                app_logger.info("message pump requested shutdown", .{});
            }

            pub fn onFrameStart(_: *MinimalAppSession, frame_count: u32) void {
                if (frame_count <= 3) app_logger.debug("rendering frame {}", .{frame_count});
            }

            pub fn onRenderError(_: *MinimalAppSession, err: anyerror) void {
                if (err == error.RenderInterrupted) {
                    app_logger.info("render interrupted by shutdown request", .{});
                } else {
                    app_logger.@"error"("rendering failed: {s}", .{@errorName(err)});
                }
            }

            pub fn onFrameComplete(session: *MinimalAppSession, frame_count: u32) void {
                if (frame_count <= 3) {
                    app_logger.debug("frame {} complete", .{frame_count});
                } else if (frame_count % 300 == 0) {
                    logDirectFrameTimings(session.renderer, "direct_demo");
                }
            }
        };

        var loop_control = app_loop.LoopControl{
            .running = &running,
            .start_ns = renderer_start_ns,
            .ttl_ns = renderer_ttl_ns,
            .ttl_frames = effective_ttl_frames,
        };
        var minimal_session = MinimalAppSession{
            .window = &window,
            .renderer = &renderer,
            .mouse_grabbed = &mouse_grabbed,
        };
        app_logger.info("starting main event loop...", .{});
        const frame_count = try app_loop.run(&loop_control, &minimal_session, MinimalDriver);
        app_logger.info("exited main loop after {} frames", .{frame_count});
        return;
    }

    try zphysics.init(allocator, .{});
    defer zphysics.deinit();
    var phase13_runtime = try scene_runtime.SceneRuntime.init(allocator, .{
        .min = .{ .x = -512.0, .y = -512.0, .z = -512.0 },
        .max = .{ .x = 512.0, .y = 512.0, .z = 512.0 },
    });
    defer phase13_runtime.deinit();

    var scene_resources = blk: {
        const scene_index_bytes = try std.fs.cwd().readFileAlloc(allocator, scenes_index_path, 1024 * 1024);
        defer allocator.free(scene_index_bytes);
        const parsed_scene_index = try std.json.parseFromSlice(SceneIndexFile, allocator, scene_index_bytes, .{ .ignore_unknown_fields = true });
        defer parsed_scene_index.deinit();

        const selected_scene_key = try resolveLaunchSceneKey(allocator, parsed_scene_index.value);
        const selected_scene_file_path = try resolveSceneFilePath(parsed_scene_index.value, selected_scene_key);
        const scene_file_bytes = try std.fs.cwd().readFileAlloc(allocator, selected_scene_file_path, 1024 * 1024);
        defer allocator.free(scene_file_bytes);
        const parsed_scene_file = try std.json.parseFromSlice(SceneFile, allocator, scene_file_bytes, .{ .ignore_unknown_fields = true });
        defer parsed_scene_file.deinit();

        var scene_desc = try scene_runtime.buildSceneDescription(
            allocator,
            parsed_scene_file.value,
            config.MESHLET_SHADOWS_ENABLED,
            config.POST_SHADOW_ENABLED,
            config.POST_SHADOW_MAP_SIZE,
        );
        defer scene_desc.deinit(allocator);

        try populateSceneRuntimeBootstrap(&phase13_runtime, scene_desc);
        app_logger.infoSub("bootstrap", "launch scene: {s}", .{scene_desc.key});
        try renderer.setLightCapacity(scene_desc.lights.len);
        var scene_loading_progress: ?SceneLoadingProgress = null;
        var scene_loading_overlay_active = false;
        defer if (scene_loading_overlay_active) renderer.endSceneLoadingOverlay();

        if (parsed_scene_index.value.loadingScene) |loading_key| {
            const loading_file_path = resolveSceneFilePath(parsed_scene_index.value, loading_key) catch null;
            if (loading_file_path != null) {
                const total_steps = sceneLoadingTotalSteps(scene_desc);
                renderer.beginSceneLoadingOverlay(scene_desc.key, total_steps);
                scene_loading_overlay_active = true;
                scene_loading_progress = .{
                    .renderer = &renderer,
                    .running = &running,
                    .pump = pumpRendererEvents,
                    .total_steps = total_steps,
                };
                if (scene_loading_progress) |*progress| startSceneLoadingProgress(progress);
            }
        }

        var scene_textures = [_]?texture.Texture{null} ** scene_texture_slots_capacity;
        defer for (&scene_textures) |*tex| {
            if (tex.*) |*loaded| loaded.deinit();
        };
        var material_textures = [_]?*const texture.Texture{null} ** scene_texture_slots_capacity;

        var loaded_scene_resources = try loadSceneMeshResourcesWithProgress(allocator, scene_desc, if (scene_loading_progress) |*progress| progress else null);
        assignSceneRenderEntities(&loaded_scene_resources, &phase13_runtime);
        syncSceneMeshFromRuntime(null, &loaded_scene_resources, &phase13_runtime);
        const runtime_renderables = try buildRuntimeRenderableSetups(allocator, &loaded_scene_resources);
        defer allocator.free(runtime_renderables);
        try phase13_runtime.configureExecution(scene_desc.runtime, runtime_renderables);
        syncSceneMeshFromRuntime(null, &loaded_scene_resources, &phase13_runtime);
        try configureSceneItemBindings(allocator, &renderer, &loaded_scene_resources, &phase13_runtime);
        if (scene_desc.textureSlotCount() > 0) {
            try loadSceneTexturesWithProgress(
                allocator,
                scene_desc.assets,
                &scene_textures,
                &material_textures,
                if (scene_loading_progress) |*progress| progress else null,
            );
            renderer.setTextures(material_textures[0..]);
        }
        if (scene_desc.hdri_path) |hdri_path| {
            if (texture.loadHdrRaw(allocator, hdri_path)) |env_map| {
                app_logger.infoSub("assets", "loaded HDRI env map", .{});
                renderer.setHdriMap(env_map);
            } else |err| {
                app_logger.warn("failed to load HDRI {s}: {s}", .{ hdri_path, @errorName(err) });
            }
        }
        try renderer.setLightCapacity(scene_desc.lights.len);
        try configureSceneLights(&renderer, scene_desc.lights);

        const meshlet_builder = @import("render/core/meshlets/meshlet_builder.zig");
        advanceSceneLoadingProgress(if (scene_loading_progress) |*progress| progress else null, "Building meshlets");
        try meshlet_builder.buildMeshlets(allocator, &loaded_scene_resources.mesh, .{});

        app_logger.infoSub(
            "assets",
            "loaded scene mesh vertices={} triangles={} meshlets={}",
            .{ loaded_scene_resources.mesh.vertices.len, loaded_scene_resources.mesh.triangles.len, loaded_scene_resources.mesh.meshlets.len },
        );
        if (scene_loading_overlay_active) {
            renderer.endSceneLoadingOverlay();
            scene_loading_overlay_active = false;
        }

        renderer.setCameraPosition(toRenderVec3(scene_desc.camera_position));
        renderer.setCameraOrientation(scene_desc.camera_orientation_pitch, scene_desc.camera_orientation_yaw);
        renderer.setCameraFov(scene_desc.camera_fov_deg);
        renderer.setSceneCameraScriptActive(true);
        break :blk loaded_scene_resources;
    };
    defer scene_resources.deinit(allocator);
    var selected_scene_entity_pin: ?scene_runtime.EntityId = null;
    defer if (selected_scene_entity_pin) |entity| phase13_runtime.residency.unpinEntity(entity);

    if (!running) return;

    app_logger.info("starting main event loop...", .{});
    const AppLoopDriver = struct {
        pub fn beginFrame(session: *AppSession) void {
            session.renderer.keys_pressed.beginFrame();
            session.renderer.mouse_input.beginFrame();
        }

        pub fn pump(session: *AppSession) bool {
            const Hooks = struct {
                pub fn handleEvent(target: *AppSession, event: platform_loop.PlatformEvent) void {
                    consumePlatformEvent(target, event);
                }
            };
            const keep_running = platform_loop.pumpEvents(session, Hooks);
            return keep_running and !session.close_requested;
        }

        pub fn update(session: *AppSession, frame_count: u32) !void {
            if (session.minimal_demo) {
                syncFirstPersonMouseGrab(session.window, session.renderer, session.mouse_grabbed);
                applyPlatformCursor(session.renderer);
                return;
            }
            const current_selected_entity = blk: {
                const selection_id = session.renderer.selectedSceneItemSelectionId() orelse break :blk null;
                const entity = main_module.selectionIdToEntity(selection_id);
                if (!entity.isValid() or !session.phase13_runtime.world.isAlive(entity)) break :blk null;
                break :blk entity;
            };
            session.phase13_runtime.setSelectedEntity(current_selected_entity) catch |err| {
                app_logger.warn("phase13 selection sync failed: {}", .{err});
            };

            const enter_is_down = session.renderer.keys_pressed.isDown(.enter);
            const now_ns = std.time.nanoTimestamp();
            const runtime_delta_ns = @max(@as(i128, 0), now_ns - session.last_runtime_update_ns);
            session.last_runtime_update_ns = now_ns;
            const runtime_delta_seconds = std.math.clamp(
                @as(f32, @floatFromInt(runtime_delta_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s)),
                0.0,
                0.1,
            );
            const scene_look_delta = session.renderer.consumeSceneCameraLookDelta(runtime_delta_seconds);
            const current_keys_pressed = session.renderer.keys_pressed;
            const input_context: input_actions.InputContext = if (session.renderer.isFirstPersonMode())
                .gameplay
            else
                .editor;
            const resolved_actions = input_actions.resolveActions(
                input_context,
                current_keys_pressed,
                session.renderer.mouse_input,
            );
            session.phase13_runtime.setExecutionInputs(enter_is_down, session.renderer.isSceneItemDragActive(), .{
                .first_person_active = session.renderer.isFirstPersonMode(),
                .keyboard = current_keys_pressed,
                .mouse = session.renderer.mouse_input,
                .actions = resolved_actions,
                .look_delta = .{
                    .x = scene_look_delta.x,
                    .y = scene_look_delta.y,
                },
            });

            var phase13_snapshot = session.phase13_runtime.updateFrameWithCamera(.{
                .position = .{
                    .x = session.renderer.camera_position.x,
                    .y = session.renderer.camera_position.y,
                    .z = session.renderer.camera_position.z,
                },
                .pitch = session.renderer.rotation_x,
                .yaw = session.renderer.rotation_angle,
                .fov_deg = session.renderer.camera_fov_deg,
            }, 48.0, 96.0, frame_count, runtime_delta_seconds) catch |err| {
                app_logger.warn("phase13 runtime update failed: {}", .{err});
                return;
            };
            defer phase13_snapshot.deinit();
            session.phase13_runtime.pinFrameAssets(&phase13_snapshot);
            defer session.phase13_runtime.unpinFrameAssets(&phase13_snapshot);

            main_module.syncRendererFromSceneSnapshot(session.renderer, &phase13_snapshot) catch |err| {
                app_logger.warn("phase13 renderer bridge failed: {}", .{err});
                return;
            };
            for (session.phase13_runtime.rendererCommands()) |command| {
                main_module.applySceneRendererCommand(session.renderer, command);
            }
            session.phase13_runtime.clearRendererCommands();
            syncFirstPersonMouseGrab(session.window, session.renderer, session.mouse_grabbed);
            applyPlatformCursor(session.renderer);
            main_module.syncSceneMeshForFrame(session.renderer, session.scene_resources, session.phase13_runtime);

            if (session.selected_scene_entity_pin.*) |pinned_entity| {
                if (current_selected_entity == null or !pinned_entity.eql(current_selected_entity.?)) {
                    session.phase13_runtime.residency.unpinEntity(pinned_entity);
                    session.selected_scene_entity_pin.* = null;
                }
            }
            if (current_selected_entity) |entity| {
                if (session.selected_scene_entity_pin.* == null) {
                    session.phase13_runtime.residency.pinEntity(entity);
                    session.selected_scene_entity_pin.* = entity;
                }
            }

            if (session.renderer.consumeSceneItemTranslateRequest()) |move_request| {
                main_module.applySceneItemTranslateRequest(
                    session.renderer,
                    session.phase13_runtime,
                    session.scene_resources,
                    move_request,
                );
                main_module.syncSceneMeshForFrame(session.renderer, session.scene_resources, session.phase13_runtime);
            }
        }

        pub fn shouldRender(session: *AppSession) bool {
            if (session.minimized or session.close_requested) return false;
            return session.renderer.shouldRenderFrame();
        }

        pub fn waitUntilNextFrame(session: *AppSession) void {
            session.renderer.waitUntilNextFrame();
        }

        pub fn render(session: *AppSession) !void {
            if (!session.minimal_demo) session.phase13_runtime.beginPresent();
            session.renderer.render3DMeshWithPump(&session.scene_resources.mesh, pumpRendererEvents) catch |err| {
                if (!session.minimal_demo) session.phase13_runtime.endPresent();
                return err;
            };
            if (!session.minimal_demo) session.phase13_runtime.endPresent();
        }

        pub fn onTtlExpired(_: *AppSession, kind: enum { time, frames }) void {
            switch (kind) {
                .time => app_logger.info("renderer TTL expired, exiting", .{}),
                .frames => app_logger.info("renderer frame TTL expired, exiting", .{}),
            }
        }

        pub fn onMessagePumpShutdown(_: *AppSession) void {
            app_logger.info("message pump requested shutdown", .{});
        }

        pub fn onFrameStart(_: *AppSession, frame_count: u32) void {
            if (frame_count <= 3) app_logger.debug("rendering frame {}", .{frame_count});
        }

        pub fn onRenderError(_: *AppSession, err: anyerror) void {
            if (err == error.RenderInterrupted) {
                app_logger.info("render interrupted by shutdown request", .{});
            } else {
                app_logger.@"error"("rendering failed: {s}", .{@errorName(err)});
            }
        }

        pub fn onFrameComplete(session: *AppSession, frame_count: u32) void {
            if (frame_count <= 3) {
                app_logger.debug("frame {} complete", .{frame_count});
            } else if (frame_count % 300 == 0) {
                logDirectFrameTimings(session.renderer, "scene_render");
            }
        }
    };

    var loop_control = app_loop.LoopControl{
        .running = &running,
        .start_ns = renderer_start_ns,
        .ttl_ns = renderer_ttl_ns,
        .ttl_frames = effective_ttl_frames,
    };
    var app_session = AppSession{
        .window = &window,
        .renderer = &renderer,
        .phase13_runtime = &phase13_runtime,
        .scene_resources = &scene_resources,
        .minimal_demo = minimal_triangle_demo_enabled,
        .mouse_grabbed = &mouse_grabbed,
        .selected_scene_entity_pin = &selected_scene_entity_pin,
        .last_runtime_update_ns = std.time.nanoTimestamp(),
    };
    const frame_count = try app_loop.run(&loop_control, &app_session, AppLoopDriver);

    app_logger.info("exited main loop after {} frames", .{frame_count});
}

/// Loads l oa dr en de re rt tl ns from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadRendererTtlNs(allocator: std.mem.Allocator) ?i128 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_TTL_SECONDS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => {
            app_logger.warn("failed to read ZIG_RENDER_TTL_SECONDS: {s}", .{@errorName(err)});
            return null;
        },
    };
    defer allocator.free(raw_value);

    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const ttl_seconds = std.fmt.parseFloat(f64, trimmed) catch {
        app_logger.warn("invalid ZIG_RENDER_TTL_SECONDS value: {s}", .{trimmed});
        return null;
    };
    if (!std.math.isFinite(ttl_seconds) or ttl_seconds <= 0.0) {
        app_logger.warn("ignoring non-positive ZIG_RENDER_TTL_SECONDS: {d}", .{ttl_seconds});
        return null;
    }

    const ttl_ns_f64 = ttl_seconds * @as(f64, @floatFromInt(std.time.ns_per_s));
    return @as(i128, @intFromFloat(ttl_ns_f64));
}

fn defaultRendererTtlNs() i128 {
    return 15 * std.time.ns_per_s;
}

/// Loads l oa dr en de re rt tl fr am es from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadRendererTtlFrames(allocator: std.mem.Allocator) ?u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_TTL_FRAMES") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => {
            app_logger.warn("failed to read ZIG_RENDER_TTL_FRAMES: {s}", .{@errorName(err)});
            return null;
        },
    };
    defer allocator.free(raw_value);

    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const ttl_frames = std.fmt.parseUnsigned(u64, trimmed, 10) catch {
        app_logger.warn("invalid ZIG_RENDER_TTL_FRAMES value: {s}", .{trimmed});
        return null;
    };
    if (ttl_frames == 0) {
        app_logger.warn("ignoring zero ZIG_RENDER_TTL_FRAMES value", .{});
        return null;
    }
    return ttl_frames;
}

/// Loads l oa dp ro fi le fr am et ar ge t from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadProfileFrameTarget(allocator: std.mem.Allocator) ?u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    defer allocator.free(raw_value);
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
}

/// Resolves r es ol ve la un ch sc en ek ey into a final normalized result.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn resolveLaunchSceneKey(allocator: std.mem.Allocator, scene_index: SceneIndexFile) ![]const u8 {
    var requested_scene: ?[]const u8 = null;
    var owned_requested_scene: ?[]u8 = null;
    defer if (owned_requested_scene) |buf| allocator.free(buf);
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--scene=")) {
            requested_scene = arg["--scene=".len..];
            break;
        } else if (std.mem.eql(u8, arg, "--scene") and i + 1 < args.len) {
            requested_scene = args[i + 1];
            i += 1;
            break;
        }
    }

    if (requested_scene == null) {
        const env_scene = std.process.getEnvVarOwned(allocator, "ZIG_SCENE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => null,
        };
        if (env_scene) |env| {
            defer allocator.free(env);
            const trimmed = std.mem.trim(u8, env, " \t\r\n");
            if (trimmed.len != 0) {
                owned_requested_scene = try allocator.dupe(u8, trimmed);
                requested_scene = owned_requested_scene.?;
            }
        }
    }

    const chosen_key = requested_scene orelse scene_index.defaultScene;
    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(chosen_key, entry.key)) return entry.key;
    }

    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(chosen_key, entry.file)) return entry.key;

        const entry_basename = std.fs.path.basename(entry.file);
        if (std.ascii.eqlIgnoreCase(chosen_key, entry_basename)) return entry.key;

        if (std.mem.endsWith(u8, entry_basename, ".scene.json")) {
            const entry_stem = entry_basename[0 .. entry_basename.len - ".scene.json".len];
            if (std.ascii.eqlIgnoreCase(chosen_key, entry_stem)) return entry.key;
        }
    }

    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(scene_index.defaultScene, entry.key)) return entry.key;
    }
    return error.SceneNotFound;
}

/// Resolves r es ol ve sc en ef il ep at h into a final normalized result.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn resolveSceneFilePath(scene_index: SceneIndexFile, key: []const u8) ![]const u8 {
    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry.key)) return entry.file;
    }
    return error.SceneFilePathNotFound;
}

/// configureSceneLights applies configuration for Main.
fn configureSceneLights(renderer: *Renderer, lights: []const LoadedSceneLight) !void {
    for (lights, 0..) |light, i| {
        renderer.setDirectionalLight(i, toRenderVec3(light.direction), light.distance, toRenderVec3(light.color));
        renderer.setLightShadowMode(i, toRendererLightShadowMode(light.shadow_mode));
        renderer.setLightShadowUpdateInterval(i, light.shadow_update_interval_frames);
        try renderer.setLightShadowMapSize(i, light.shadow_map_size);
        renderer.setLightGlow(i, light.glow_radius, light.glow_intensity);
    }
}

/// configureSceneItemBindings applies configuration for Main.
fn configureSceneItemBindings(
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    scene_resources: *const SceneMeshResources,
    runtime: *const scene_runtime.SceneRuntime,
) !void {
    const bindings = try allocator.alloc(SceneItemBinding, scene_resources.render_instances.len);
    defer allocator.free(bindings);
    for (scene_resources.render_instances, 0..) |instance, idx| {
        const gizmo_origin = if (runtime.worldTransform(instance.entity)) |transform|
            toRenderVec3(transform.position)
        else
            math.Vec3.scale(math.Vec3.add(instance.bounds_min, instance.bounds_max), 0.5);
        bindings[idx] = .{
            .selection_id = entityToSelectionId(instance.entity),
            .vertex_start = instance.vertex_start,
            .vertex_count = instance.vertex_count,
            .triangle_start = instance.triangle_start,
            .triangle_count = instance.triangle_count,
            .bounds_min = instance.bounds_min,
            .bounds_max = instance.bounds_max,
            .gizmo_origin = gizmo_origin,
        };
    }
    try renderer.setSceneItemBindings(bindings, scene_resources.mesh.triangles.len);
}

/// Applies scene item translate request.
/// Mutates owned state and keeps dependent cached values coherent for downstream systems.
fn applySceneItemTranslateRequest(
    renderer: *Renderer,
    runtime: *scene_runtime.SceneRuntime,
    scene_resources: *SceneMeshResources,
    request: SceneItemTranslateRequest,
) void {
    const instance_index = findSceneRenderInstanceIndexBySelectionId(scene_resources, request.selection_id) orelse blk: {
        if (request.item_index >= scene_resources.render_instances.len) return;
        break :blk request.item_index;
    };
    const instance = &scene_resources.render_instances[instance_index];
    _ = runtime.translateEntity(instance.entity, .{ .x = request.delta.x, .y = request.delta.y, .z = request.delta.z });
    renderer.notifySceneItemTranslated(instance_index, request.delta);
}

fn buildRuntimeRenderableSetups(allocator: std.mem.Allocator, scene_resources: *const SceneMeshResources) ![]scene_runtime.RuntimeRenderableSetup {
    const setups = try allocator.alloc(scene_runtime.RuntimeRenderableSetup, scene_resources.render_instances.len);
    for (scene_resources.render_instances, 0..) |instance, index| {
        setups[index] = .{
            .entity = instance.entity,
            .local_bounds_min = .{ .x = instance.local_bounds_min.x, .y = instance.local_bounds_min.y, .z = instance.local_bounds_min.z },
            .local_bounds_max = .{ .x = instance.local_bounds_max.x, .y = instance.local_bounds_max.y, .z = instance.local_bounds_max.z },
        };
    }
    return setups;
}

fn syncSceneMeshIfDirty(renderer: *Renderer, scene_resources: *SceneMeshResources, runtime: *scene_runtime.SceneRuntime) void {
    if (!runtime.takeRenderablesDirty()) return;
    syncSceneMeshFromRuntime(renderer, scene_resources, runtime);
    scene_resources.mesh.refreshMeshlets();
    renderer.invalidateMeshWork();
}

fn syncSceneMeshForFrame(renderer: *Renderer, scene_resources: *SceneMeshResources, runtime: *scene_runtime.SceneRuntime) void {
    syncSceneMeshFromRuntime(renderer, scene_resources, runtime);
    scene_resources.mesh.refreshMeshlets();
    renderer.invalidateMeshWork();
}

fn syncSceneMeshFromRuntime(renderer: ?*Renderer, scene_resources: *SceneMeshResources, runtime: *const scene_runtime.SceneRuntime) void {
    for (scene_resources.render_instances, 0..) |*instance, instance_index| {
        const transform = runtime.worldTransform(instance.entity) orelse continue;
        if (instance.vertex_count == 0) continue;
        const position = toRenderVec3(transform.position);
        const rotation = toRenderVec3(transform.rotation_deg);
        const scale = toRenderVec3(transform.scale);
        var bounds_min = math.Vec3.new(0.0, 0.0, 0.0);
        var bounds_max = math.Vec3.new(0.0, 0.0, 0.0);
        var initialized = false;
        for (scene_resources.mesh.vertices[instance.vertex_start .. instance.vertex_start + instance.vertex_count], instance.local_vertices) |*vertex, local_vertex| {
            vertex.* = transformPoint(local_vertex, position, rotation, scale);
            if (!initialized) {
                bounds_min = vertex.*;
                bounds_max = vertex.*;
                initialized = true;
            } else {
                bounds_min.x = @min(bounds_min.x, vertex.x);
                bounds_min.y = @min(bounds_min.y, vertex.y);
                bounds_min.z = @min(bounds_min.z, vertex.z);
                bounds_max.x = @max(bounds_max.x, vertex.x);
                bounds_max.y = @max(bounds_max.y, vertex.y);
                bounds_max.z = @max(bounds_max.z, vertex.z);
            }
        }
        for (scene_resources.mesh.normals[instance.triangle_start .. instance.triangle_start + instance.triangle_count], instance.local_normals) |*normal, local_normal| {
            normal.* = rotateVector(local_normal, rotation).normalize();
        }
        if (initialized) {
            instance.bounds_min = bounds_min;
            instance.bounds_max = bounds_max;
            if (renderer) |r| {
                r.setSceneItemCenter(instance_index, math.Vec3.scale(math.Vec3.add(bounds_min, bounds_max), 0.5));
            }
        }
    }
}

fn assignSceneRenderEntities(scene_resources: *SceneMeshResources, runtime: *const scene_runtime.SceneRuntime) void {
    for (scene_resources.render_instances, 0..) |*instance, asset_index| {
        instance.entity = runtime.renderableEntityAt(asset_index) orelse scene_runtime.EntityId.invalid();
    }
}

fn findSceneRenderInstanceIndexBySelectionId(scene_resources: *const SceneMeshResources, selection_id: u64) ?usize {
    const entity = selectionIdToEntity(selection_id);
    if (!entity.isValid()) return null;
    for (scene_resources.render_instances, 0..) |instance, index| {
        if (instance.entity.eql(entity)) return index;
    }
    return null;
}

fn loadSceneMeshResources(allocator: std.mem.Allocator, scene_desc: LoadedSceneDescription) !SceneMeshResources {
    return loadSceneMeshResourcesWithProgress(allocator, scene_desc, null);
}

fn loadSceneMeshResourcesWithProgress(
    allocator: std.mem.Allocator,
    scene_desc: LoadedSceneDescription,
    progress: ?*SceneLoadingProgress,
) !SceneMeshResources {
    if (scene_desc.assets.len == 0) return error.SceneHasNoAssets;

    var merged_mesh: ?mesh_module.Mesh = null;
    const instances = try allocator.alloc(SceneRenderInstance, scene_desc.assets.len);
    var instance_count: usize = 0;
    for (scene_desc.assets, 0..) |asset, asset_index| {
        const prev_vertex_count = if (merged_mesh) |m| m.vertices.len else 0;
        const prev_triangle_count = if (merged_mesh) |m| m.triangles.len else 0;
        var loaded_mesh: mesh_module.Mesh = switch (asset.model_type) {
            .gltf => try loadGltfMeshAsset(allocator, asset),
            .obj => try loadObjMeshAsset(allocator, asset),
        };
        if (asset.model_type == .obj and std.mem.endsWith(u8, asset.model_path, "suzanne.obj")) {
            loaded_mesh.centerToOrigin();
        }
        if (scene_desc.runtime == .gun_physics and asset_index == 0) loaded_mesh.centerToOrigin();
        const loaded_vertex_count = loaded_mesh.vertices.len;
        const loaded_triangle_count = loaded_mesh.triangles.len;
        const local_vertices = try allocator.dupe(math.Vec3, loaded_mesh.vertices);
        errdefer allocator.free(local_vertices);
        const local_normals = try allocator.dupe(math.Vec3, loaded_mesh.normals);
        errdefer allocator.free(local_normals);
        var bounds_min = local_vertices[0];
        var bounds_max = local_vertices[0];
        for (local_vertices[1..]) |v| {
            bounds_min.x = @min(bounds_min.x, v.x);
            bounds_min.y = @min(bounds_min.y, v.y);
            bounds_min.z = @min(bounds_min.z, v.z);
            bounds_max.x = @max(bounds_max.x, v.x);
            bounds_max.y = @max(bounds_max.y, v.y);
            bounds_max.z = @max(bounds_max.z, v.z);
        }

        if (merged_mesh == null) {
            merged_mesh = loaded_mesh;
        } else {
            var existing = merged_mesh.?;
            try appendMesh(allocator, &existing, &loaded_mesh);
            loaded_mesh.deinit();
            merged_mesh = existing;
        }

        instances[instance_count] = .{
            .entity = scene_runtime.EntityId.invalid(),
            .asset_index = asset_index,
            .vertex_start = prev_vertex_count,
            .vertex_count = loaded_vertex_count,
            .triangle_start = prev_triangle_count,
            .triangle_count = loaded_triangle_count,
            .local_bounds_min = bounds_min,
            .local_bounds_max = bounds_max,
            .bounds_min = bounds_min,
            .bounds_max = bounds_max,
            .local_vertices = local_vertices,
            .local_normals = local_normals,
        };
        instance_count += 1;

        var phase_buf: [160]u8 = undefined;
        const phase = std.fmt.bufPrint(
            &phase_buf,
            "Loading mesh {}/{}: {s}",
            .{ asset_index + 1, scene_desc.assets.len, std.fs.path.basename(asset.model_path) },
        ) catch "Loading mesh";
        advanceSceneLoadingProgress(progress, phase);
    }

    if (merged_mesh) |*mesh| {
        if (scene_desc.runtime == .gun_physics) try levelAppendGroundPlane(mesh, allocator);
    }

    return .{
        .mesh = merged_mesh.?,
        .render_instances = instances[0..instance_count],
    };
}

/// Loads l oa ds ce ne te xt ur es from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadSceneTextures(
    allocator: std.mem.Allocator,
    assets: []const LoadedSceneAsset,
    loaded_slots: *[scene_texture_slots_capacity]?texture.Texture,
    material_textures: *[scene_texture_slots_capacity]?*const texture.Texture,
) !void {
    return loadSceneTexturesWithProgress(allocator, assets, loaded_slots, material_textures, null);
}

/// Loads l oa ds ce ne te xt ur es wi th pr og re ss from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadSceneTexturesWithProgress(
    allocator: std.mem.Allocator,
    assets: []const LoadedSceneAsset,
    loaded_slots: *[scene_texture_slots_capacity]?texture.Texture,
    material_textures: *[scene_texture_slots_capacity]?*const texture.Texture,
    progress: ?*SceneLoadingProgress,
) !void {
    var texture_total: usize = 0;
    for (assets) |asset| texture_total += asset.texture_slots.len;
    var texture_index: usize = 0;
    for (assets) |asset| {
        for (asset.texture_slots) |slot| {
            if (slot.slot >= loaded_slots.len) {
                app_logger.warn("texture slot {} out of range for {s}", .{ slot.slot, slot.path });
            } else {
                loaded_slots[slot.slot] = texture.loadBmp(allocator, slot.path) catch |err| blk: {
                    app_logger.warn("failed to load texture slot {} {s}: {s}", .{ slot.slot, slot.path, @errorName(err) });
                    break :blk null;
                };
                if (loaded_slots[slot.slot]) |*tex| material_textures[slot.slot] = tex;
            }
            texture_index += 1;
            var phase_buf: [160]u8 = undefined;
            const phase = std.fmt.bufPrint(
                &phase_buf,
                "Loading texture {}/{}: {s}",
                .{ texture_index, texture_total, std.fs.path.basename(slot.path) },
            ) catch "Loading texture";
            advanceSceneLoadingProgress(progress, phase);
        }
    }
}

fn loadGltfMeshAsset(allocator: std.mem.Allocator, asset: LoadedSceneAsset) !mesh_module.Mesh {
    if (gltf_loader.load(allocator, asset.model_path)) |mesh| {
        app_logger.infoSub("assets", "loaded gltf asset from {s}", .{asset.model_path});
        return mesh;
    } else |err| {
        app_logger.warn("scene gltf load failed for {s}: {s}", .{ asset.model_path, @errorName(err) });
    }
    if (asset.fallback_model_path) |fallback_path| {
        const fallback_mesh = try obj_loader.load(allocator, fallback_path);
        app_logger.infoSub("assets", "loaded fallback obj from {s}", .{fallback_path});
        return fallback_mesh;
    }
    return error.SceneModelLoadFailed;
}

fn loadObjMeshAsset(allocator: std.mem.Allocator, asset: LoadedSceneAsset) !mesh_module.Mesh {
    var mesh = try obj_loader.load(allocator, asset.model_path);
    if (asset.apply_cornell_palette) applyCornellColors(&mesh);
    app_logger.infoSub("assets", "loaded obj asset from {s}", .{asset.model_path});
    return mesh;
}

fn appendMesh(allocator: std.mem.Allocator, target: *mesh_module.Mesh, source: *const mesh_module.Mesh) !void {
    const old_vertex_count = target.vertices.len;
    const old_triangle_count = target.triangles.len;
    const new_vertex_count = old_vertex_count + source.vertices.len;
    const new_triangle_count = old_triangle_count + source.triangles.len;

    const new_vertices = try allocator.alloc(math.Vec3, new_vertex_count);
    errdefer allocator.free(new_vertices);
    const new_tex_coords = try allocator.alloc(math.Vec2, new_vertex_count);
    errdefer allocator.free(new_tex_coords);
    const new_triangles = try allocator.alloc(mesh_module.Triangle, new_triangle_count);
    errdefer allocator.free(new_triangles);
    const new_normals = try allocator.alloc(math.Vec3, new_triangle_count);
    errdefer allocator.free(new_normals);
    const new_vertex_normals = try allocator.alloc(math.Vec3, new_vertex_count);
    errdefer allocator.free(new_vertex_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[0..old_vertex_count], target.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..old_vertex_count], target.tex_coords);
    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..old_triangle_count], target.triangles);
    std.mem.copyForwards(math.Vec3, new_normals[0..old_triangle_count], target.normals);
    std.mem.copyForwards(math.Vec3, new_vertex_normals[0..old_vertex_count], target.vertex_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[old_vertex_count..], source.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[old_vertex_count..], source.tex_coords);
    std.mem.copyForwards(math.Vec3, new_vertex_normals[old_vertex_count..], source.vertex_normals);
    for (source.triangles, 0..) |tri, i| {
        var shifted = tri;
        shifted.v0 += old_vertex_count;
        shifted.v1 += old_vertex_count;
        shifted.v2 += old_vertex_count;
        new_triangles[old_triangle_count + i] = shifted;
    }
    std.mem.copyForwards(math.Vec3, new_normals[old_triangle_count..], source.normals);

    allocator.free(target.vertices);
    allocator.free(target.tex_coords);
    allocator.free(target.triangles);
    allocator.free(target.normals);
    allocator.free(target.vertex_normals);
    target.vertices = new_vertices;
    target.tex_coords = new_tex_coords;
    target.triangles = new_triangles;
    target.normals = new_normals;
    target.vertex_normals = new_vertex_normals;
    target.clearMeshlets();
}

fn transformPoint(v: math.Vec3, position: math.Vec3, rotation_deg: math.Vec3, scale: math.Vec3) math.Vec3 {
    const scaled = math.Vec3.new(v.x * scale.x, v.y * scale.y, v.z * scale.z);
    const rotated = rotateVector(scaled, rotation_deg);
    return math.Vec3.add(rotated, position);
}

fn rotateVector(v: math.Vec3, rotation_deg: math.Vec3) math.Vec3 {
    const rad_scale = std.math.pi / 180.0;
    const rx = rotation_deg.x * rad_scale;
    const ry = rotation_deg.y * rad_scale;
    const rz = rotation_deg.z * rad_scale;

    const sx = @sin(rx);
    const cx = @cos(rx);
    const sy = @sin(ry);
    const cy = @cos(ry);
    const sz = @sin(rz);
    const cz = @cos(rz);

    const x1 = v.x;
    const y1 = v.y * cx - v.z * sx;
    const z1 = v.y * sx + v.z * cx;

    const x2 = x1 * cy + z1 * sy;
    const y2 = y1;
    const z2 = -x1 * sy + z1 * cy;

    return math.Vec3.new(
        x2 * cz - y2 * sz,
        x2 * sz + y2 * cz,
        z2,
    );
}

fn applyCornellColors(mesh: *mesh_module.Mesh) void {
    const white: u32 = 0xFFE6E6E6;
    const red: u32 = 0xFF3A3ACB;
    const green: u32 = 0xFF59D66F;

    for (mesh.triangles, 0..) |*tri, i| {
        tri.base_color = if (i < 2)
            white
        else if (i < 4)
            red
        else if (i < 6)
            green
        else if (i < 12)
            white
        else
            white;
    }

    const flip_count: usize = @min(mesh.normals.len, 12);
    for (mesh.normals[0..flip_count]) |*n| {
        n.x = -n.x;
        n.y = -n.y;
        n.z = -n.z;
    }
}

fn levelAppendGroundPlane(mesh: *mesh_module.Mesh, allocator: std.mem.Allocator) !void {
    const plane_extent: f32 = 40.0;
    const plane_y: f32 = -1.0;
    const start_vertex = mesh.vertices.len;
    const start_triangle = mesh.triangles.len;

    const new_vertices = try allocator.alloc(math.Vec3, mesh.vertices.len + 4);
    errdefer allocator.free(new_vertices);
    const new_tex_coords = try allocator.alloc(math.Vec2, mesh.tex_coords.len + 4);
    errdefer allocator.free(new_tex_coords);
    const new_triangles = try allocator.alloc(mesh_module.Triangle, mesh.triangles.len + 2);
    errdefer allocator.free(new_triangles);
    const new_normals = try allocator.alloc(math.Vec3, mesh.normals.len + 2);
    errdefer allocator.free(new_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[0..mesh.vertices.len], mesh.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..mesh.tex_coords.len], mesh.tex_coords);
    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..mesh.triangles.len], mesh.triangles);
    std.mem.copyForwards(math.Vec3, new_normals[0..mesh.normals.len], mesh.normals);

    new_vertices[start_vertex + 0] = math.Vec3.new(-plane_extent, plane_y, -plane_extent);
    new_vertices[start_vertex + 1] = math.Vec3.new(plane_extent, plane_y, -plane_extent);
    new_vertices[start_vertex + 2] = math.Vec3.new(plane_extent, plane_y, plane_extent);
    new_vertices[start_vertex + 3] = math.Vec3.new(-plane_extent, plane_y, plane_extent);

    new_tex_coords[start_vertex + 0] = math.Vec2.new(0.0, 0.0);
    new_tex_coords[start_vertex + 1] = math.Vec2.new(1.0, 0.0);
    new_tex_coords[start_vertex + 2] = math.Vec2.new(1.0, 1.0);
    new_tex_coords[start_vertex + 3] = math.Vec2.new(0.0, 1.0);

    new_triangles[start_triangle + 0] = mesh_module.Triangle.newWithColor(start_vertex + 0, start_vertex + 2, start_vertex + 1, 0xFF4A4A4A);
    new_triangles[start_triangle + 1] = mesh_module.Triangle.newWithColor(start_vertex + 0, start_vertex + 3, start_vertex + 2, 0xFF4A4A4A);
    new_normals[start_triangle + 0] = math.Vec3.new(0.0, 1.0, 0.0);
    new_normals[start_triangle + 1] = math.Vec3.new(0.0, 1.0, 0.0);

    allocator.free(mesh.vertices);
    allocator.free(mesh.tex_coords);
    allocator.free(mesh.triangles);
    allocator.free(mesh.normals);
    mesh.vertices = new_vertices;
    mesh.tex_coords = new_tex_coords;
    mesh.triangles = new_triangles;
    mesh.normals = new_normals;
    mesh.clearMeshlets();
}
