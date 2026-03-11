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
const windows = std.os.windows;
const math = @import("core/math.zig");
const zphysics = @import("zphysics");

// Windows message structure.
// JS Analogy: This is the raw event object from the operating system. A browser
// would normally process this and give you a cleaner `KeyboardEvent` or `MouseEvent`.
const MSG = extern struct {
    hwnd: windows.HWND, // The window handle this message is for.
    message: u32, // The type of message (e.g., WM_KEYDOWN, WM_CLOSE).
    wParam: windows.WPARAM, // Extra event-specific data. For keyboard events, this is the key code.
    lParam: windows.LPARAM, // More event-specific data.
    time: u32, // Timestamp of when the event occurred.
    pt: windows.POINT, // Mouse position when the event occurred.
};

// Windows message type constants.
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_CHAR = 0x0102;
const WM_QUIT = 0x12;
const WM_MOUSEMOVE = 0x0200;

// Declarations for Windows API functions.
// JS Analogy: These are low-level functions to interact with the OS event queue.
// Think of them as the underlying native functions a browser's JS engine would call
// to handle events, but here we are calling them directly.
extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?windows.HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
) i32;

extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?windows.HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
    wRemoveMsg: u32,
) i32;

extern "user32" fn TranslateMessage(lpMsg: *const MSG) bool;

extern "user32" fn DispatchMessageW(lpMsg: *const MSG) windows.LRESULT;
extern "user32" fn GetAsyncKeyState(vKey: i32) i16;

// Constant for PeekMessageW: remove the message from the queue after reading.
const PM_REMOVE = 1;
const VK_RETURN = 0x0D;

// Windows Sleep function for frame pacing.
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// Import other modules from our project.
// JS Analogy: `const Window = require('./window.js');`
const Window = @import("platform/window.zig").Window;
const Renderer = @import("render/renderer.zig").Renderer;
const gltf_loader = @import("assets/gltf_loader.zig");
const obj_loader = @import("assets/obj_loader.zig");
const texture = @import("assets/texture.zig");
const mesh_module = @import("render/core/mesh.zig");
const config = @import("core/app_config.zig");
const cpu_features = @import("core/cpu_features.zig");
const physics_utils = @import("physics/physics_utils.zig");
const input = @import("platform/input.zig");
const log = @import("core/log.zig");

const app_logger = log.get("app.main");
const scenes_index_path = "assets/configs/scenes/index.json";
const gun_jump_velocity: [3]f32 = .{ 0.0, 12.0, 0.0 };

const SceneRuntime = enum {
    static,
    gun_physics,
};

const SceneModelType = enum {
    gltf,
    obj,
};

const SceneAssetConfigEntry = struct {
    type: []const u8,
    modelType: []const u8 = "",
    modelPath: []const u8 = "",
    fallbackModelPath: ?[]const u8 = null,
    applyCornellPalette: bool = false,
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    rotationDeg: [3]f32 = .{ 0.0, 0.0, 0.0 },
    scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
    textures: []SceneTextureSlotEntry = &[_]SceneTextureSlotEntry{},
    path: ?[]const u8 = null,
    runtimeName: ?[]const u8 = null,
    cameraPosition: ?[3]f32 = null,
    cameraOrientation: ?[2]f32 = null,
    cameraName: ?[]const u8 = null,
};

const SceneTextureSlotEntry = struct {
    slot: u32,
    path: []const u8,
};

const SceneFile = struct {
    key: []const u8,
    assets: []SceneAssetConfigEntry,
};

const SceneIndexEntry = struct {
    key: []const u8,
    file: []const u8,
};

const SceneIndexFile = struct {
    defaultScene: []const u8,
    loadingScene: ?[]const u8 = null,
    loadingFrames: ?u32 = null,
    scenes: []SceneIndexEntry,
};

const SceneAssetDefinition = struct {
    model_type: SceneModelType,
    model_path: []const u8,
    fallback_model_path: ?[]const u8,
    apply_cornell_palette: bool,
    position: math.Vec3,
    rotation_deg: math.Vec3,
    scale: math.Vec3,
    texture_slots: []SceneTextureSlotDefinition,
};

const SceneTextureSlotDefinition = struct {
    slot: usize,
    path: []const u8,
};

const SceneDefinition = struct {
    key: []const u8,
    assets: []SceneAssetDefinition,
    texture_slots: []SceneTextureSlotDefinition,
    runtime: SceneRuntime,
    hdri_path: ?[]const u8,
    camera_position: math.Vec3,
    camera_orientation_pitch: f32,
    camera_orientation_yaw: f32,
};

const SceneAsset = struct {
    mesh: mesh_module.Mesh,
};

const GunRuntime = struct {
    pw: *physics_utils.PhysicsWorld,
    gun_body_id: zphysics.BodyId,
    num_gun_vertices: usize,
    num_gun_triangles: usize,
    original_gun_vertices: []math.Vec3,
    original_gun_normals: []math.Vec3,
    enter_was_down: bool = false,

    fn deinit(self: *GunRuntime, allocator: std.mem.Allocator) void {
        allocator.free(self.original_gun_vertices);
        allocator.free(self.original_gun_normals);
        self.pw.deinit(allocator);
    }
};

fn isEnterDown() bool {
    return GetAsyncKeyState(VK_RETURN) < 0;
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
    const renderer_ttl_ns = loadRendererTtlNs(allocator);
    const renderer_ttl_frames = loadRendererTtlFrames(allocator);
    const profile_frame_target = loadProfileFrameTarget(allocator);
    const auto_profile_ttl_frames: ?u64 = if (renderer_ttl_frames == null and profile_frame_target != null)
        profile_frame_target.? + 30
    else
        null;
    const effective_ttl_frames = renderer_ttl_frames orelse auto_profile_ttl_frames;
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
    defer config.deinit();

    const initial_width = @as(i32, @intCast(config.WINDOW_WIDTH));
    const initial_height = @as(i32, @intCast(config.WINDOW_HEIGHT));
    var window = try Window.init(config.WINDOW_TITLE, initial_width, initial_height);
    defer window.deinit(); // Guarantees the window is destroyed on exit.
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
    const MessagePump = struct {
        fn decodeMouseCoords(lParam: windows.LPARAM) windows.POINT {
            const raw: usize = @bitCast(lParam);
            const x16: u16 = @intCast(raw & 0xFFFF);
            const y16: u16 = @intCast((raw >> 16) & 0xFFFF);
            const x_component: i16 = @bitCast(x16);
            const y_component: i16 = @bitCast(y16);
            return windows.POINT{
                .x = @intCast(x_component),
                .y = @intCast(y_component),
            };
        }

        fn pump(r: *Renderer) bool {
            var m: MSG = undefined;
            while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
                if (m.message == WM_QUIT) {
                    app_logger.info("received WM_QUIT message, exiting", .{});
                    return false;
                }
                if (m.message == WM_KEYDOWN or m.message == WM_SYSKEYDOWN) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, true);
                } else if (m.message == WM_KEYUP or m.message == WM_SYSKEYUP) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, false);
                } else if (m.message == WM_CHAR) {
                    const char_code: u32 = @intCast(m.wParam);
                    r.handleCharInput(char_code);
                } else if (m.message == WM_MOUSEMOVE) {
                    const coords = decodeMouseCoords(m.lParam);
                    r.handleMouseMove(coords.x, coords.y);
                }
                _ = TranslateMessage(&m);
                _ = DispatchMessageW(&m);
            }
            return true;
        }
    };

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

    const scene_def = try buildSceneDefinition(allocator, parsed_scene_file.value);
    defer allocator.free(scene_def.assets);
    defer allocator.free(scene_def.texture_slots);
    app_logger.infoSub("bootstrap", "launch scene: {s}", .{scene_def.key});

    if (parsed_scene_index.value.loadingScene) |loading_key| {
        const loading_file_path = resolveSceneFilePath(parsed_scene_index.value, loading_key) catch null;
        if (loading_file_path) |path| {
            const loading_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
            defer allocator.free(loading_bytes);
            const parsed_loading = try std.json.parseFromSlice(SceneFile, allocator, loading_bytes, .{ .ignore_unknown_fields = true });
            defer parsed_loading.deinit();
            const loading_scene = try buildSceneDefinition(allocator, parsed_loading.value);
            defer allocator.free(loading_scene.assets);
            defer allocator.free(loading_scene.texture_slots);

            var loading_asset = try loadPrimaryMesh(allocator, loading_scene);
            defer loading_asset.mesh.deinit();
            try loading_asset.mesh.generateMeshlets(64, 126);
            renderer.setCameraPosition(loading_scene.camera_position);
            renderer.setCameraOrientation(loading_scene.camera_orientation_pitch, loading_scene.camera_orientation_yaw);

            const loading_frames = parsed_scene_index.value.loadingFrames orelse 45;
            var lf: u32 = 0;
            while (lf < loading_frames and running) : (lf += 1) {
                if (!MessagePump.pump(&renderer)) {
                    running = false;
                    break;
                }
                if (!renderer.shouldRenderFrame()) {
                    renderer.waitUntilNextFrame();
                    continue;
                }
                renderer.render3DMeshWithPump(&loading_asset.mesh, MessagePump.pump) catch {};
                Sleep(0);
            }
        }
    }

    var scene_textures = [_]?texture.Texture{ null, null, null };
    defer for (&scene_textures) |*tex| {
        if (tex.*) |*loaded| loaded.deinit();
    };
    var material_textures = [_]?*const texture.Texture{ null, null, null };

    try zphysics.init(allocator, .{});
    defer zphysics.deinit();

    var scene_asset = try loadPrimaryMesh(allocator, scene_def);
    defer scene_asset.mesh.deinit(); // Guarantees the mesh memory is freed on exit.
    var gun_runtime: ?GunRuntime = null;
    if (scene_def.texture_slots.len > 0) {
        try loadSceneTextures(allocator, scene_def.assets, &scene_textures, &material_textures);
        renderer.setTextures(material_textures[0..]);
    }
    if (scene_def.hdri_path) |hdri_path| {
        if (texture.loadHdrRaw(allocator, hdri_path)) |env_map| {
            app_logger.infoSub("assets", "loaded HDRI env map", .{});
            renderer.setHdriMap(env_map);
        } else |err| {
            app_logger.warn("failed to load HDRI {s}: {s}", .{ hdri_path, @errorName(err) });
        }
    }
    if (scene_def.runtime == .gun_physics) {
        gun_runtime = try setupGunRuntime(allocator, &scene_asset.mesh);
    }
    defer if (gun_runtime) |*runtime| runtime.deinit(allocator);

    try scene_asset.mesh.generateMeshlets(64, 126);
    app_logger.infoSub(
        "assets",
        "loaded scene mesh vertices={} triangles={} meshlets={}",
        .{ scene_asset.mesh.vertices.len, scene_asset.mesh.triangles.len, scene_asset.mesh.meshlets.len },
    );

    renderer.setCameraPosition(scene_def.camera_position);
    renderer.setCameraOrientation(scene_def.camera_orientation_pitch, scene_def.camera_orientation_yaw);

    if (!running) return;

    app_logger.info("starting main event loop...", .{});

    // ========== EVENT LOOP PHASE ==========

    var frame_count: u32 = 0;
    // The main event loop.
    // JS Analogy: `while(true)` combined with `requestAnimationFrame`.
    while (running) {
        if (renderer_ttl_ns) |ttl_ns| {
            if (std.time.nanoTimestamp() - renderer_start_ns >= ttl_ns) {
                app_logger.info("renderer TTL expired, exiting", .{});
                running = false;
                break;
            }
        }
        if (effective_ttl_frames) |ttl_frames| {
            if (frame_count >= ttl_frames) {
                app_logger.info("renderer frame TTL expired, exiting", .{});
                running = false;
                break;
            }
        }

        // First, process all pending user input and window events.
        if (!MessagePump.pump(&renderer)) {
            app_logger.info("message pump requested shutdown", .{});
            running = false;
            break;
        }

        if (gun_runtime) |*runtime| {
            const enter_is_down = ((renderer.keys_pressed & input.KeyBits.enter) != 0) or isEnterDown();
            if (enter_is_down and !runtime.enter_was_down) {
                const body_interface = runtime.pw.system.getBodyInterfaceMut();
                body_interface.activate(runtime.gun_body_id);
                body_interface.setLinearVelocity(runtime.gun_body_id, gun_jump_velocity);
            }
            runtime.enter_was_down = enter_is_down;

            runtime.pw.system.update(1.0 / 60.0, .{ .collision_steps = 1 }) catch {};

            const lock_iface = runtime.pw.system.getBodyLockInterfaceNoLock();
            var read_lock: zphysics.BodyLockRead = .{};
            read_lock.lock(lock_iface, runtime.gun_body_id);
            const body = read_lock.body.?;
            const xform = body.getWorldTransform();
            const rot = xform.rotation;
            const pos = xform.position;

            for (scene_asset.mesh.vertices[0..runtime.num_gun_vertices], 0..) |*v, i| {
                const ov = runtime.original_gun_vertices[i];
                v.x = rot[0] * ov.x + rot[3] * ov.y + rot[6] * ov.z + pos[0];
                v.y = rot[1] * ov.x + rot[4] * ov.y + rot[7] * ov.z + pos[1];
                v.z = rot[2] * ov.x + rot[5] * ov.y + rot[8] * ov.z + pos[2];
            }
            for (scene_asset.mesh.normals[0..runtime.num_gun_triangles], 0..) |*n, i| {
                const on = runtime.original_gun_normals[i];
                n.x = rot[0] * on.x + rot[3] * on.y + rot[6] * on.z;
                n.y = rot[1] * on.x + rot[4] * on.y + rot[7] * on.z;
                n.z = rot[2] * on.x + rot[5] * on.y + rot[8] * on.z;
            }
            scene_asset.mesh.refreshMeshlets();
            renderer.invalidateMeshWork();
        }

        // Check if it's time to render a new frame, based on our target FPS.

        if (!renderer.shouldRenderFrame()) {
            renderer.waitUntilNextFrame();
            continue;
        }

        frame_count += 1;
        if (frame_count <= 3) {
            app_logger.debug("rendering frame {}", .{frame_count});
        }
        // This is the main drawing call.
        // JS Analogy: `renderer.renderScene(scene);` inside a `requestAnimationFrame` callback.
        renderer.render3DMeshWithPump(&scene_asset.mesh, MessagePump.pump) catch |err| {
            // If rendering fails, log the error and exit the loop.
            if (err == error.RenderInterrupted) {
                app_logger.info("render interrupted by shutdown request", .{});
            } else {
                app_logger.@"error"("rendering failed: {s}", .{@errorName(err)});
            }
            running = false;
            break;
        };
        if (frame_count <= 3) {
            app_logger.debug("frame {} complete", .{frame_count});
        }

        // Yield to the OS. This prevents our app from using 100% CPU if it's running
        // faster than the target frame rate.
        // JS Analogy: `setTimeout(0)` - hints to the OS to run other processes.
        Sleep(0);
    }

    app_logger.info("exited main loop after {} frames", .{frame_count});
}

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

fn loadProfileFrameTarget(allocator: std.mem.Allocator) ?u64 {
    const raw_value = std.process.getEnvVarOwned(allocator, "ZIG_RENDER_PROFILE_FRAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    defer allocator.free(raw_value);
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
}

fn resolveLaunchSceneKey(allocator: std.mem.Allocator, scene_index: SceneIndexFile) ![]const u8 {
    var requested_scene: ?[]const u8 = null;
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
            requested_scene = std.mem.trim(u8, env, " \t\r\n");
        }
    }

    const chosen_key = requested_scene orelse scene_index.defaultScene;
    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(chosen_key, entry.key)) return entry.key;
    }

    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(scene_index.defaultScene, entry.key)) return entry.key;
    }
    return error.SceneNotFound;
}

fn resolveSceneFilePath(scene_index: SceneIndexFile, key: []const u8) ![]const u8 {
    for (scene_index.scenes) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry.key)) return entry.file;
    }
    return error.SceneFilePathNotFound;
}

fn buildSceneDefinition(allocator: std.mem.Allocator, scene_file: SceneFile) !SceneDefinition {
    var runtime: SceneRuntime = .static;
    var hdri_path: ?[]const u8 = null;
    var camera_position = math.Vec3.new(0.0, 2.0, -6.5);
    var camera_orientation_pitch: f32 = 0.0;
    var camera_orientation_yaw: f32 = 0.0;

    var model_count: usize = 0;
    var texture_count: usize = 0;
    for (scene_file.assets) |asset| {
        if (std.ascii.eqlIgnoreCase(asset.type, "model")) {
            model_count += 1;
            texture_count += asset.textures.len;
        } else if (std.ascii.eqlIgnoreCase(asset.type, "runtime")) {
            if (asset.runtimeName) |runtime_name| {
                if (std.ascii.eqlIgnoreCase(runtime_name, "gun_physics")) runtime = .gun_physics;
            }
        } else if (std.ascii.eqlIgnoreCase(asset.type, "hdri")) {
            hdri_path = asset.path;
        } else if (std.ascii.eqlIgnoreCase(asset.type, "camera")) {
            if (asset.cameraPosition) |pos| {
                camera_position = math.Vec3.new(pos[0], pos[1], pos[2]);
            }
            if (asset.cameraOrientation) |angles| {
                camera_orientation_pitch = angles[0];
                camera_orientation_yaw = angles[1];
            }
        }
    }

    const assets = try allocator.alloc(SceneAssetDefinition, model_count);
    const texture_slots = try allocator.alloc(SceneTextureSlotDefinition, texture_count);
    var model_index: usize = 0;
    var texture_index: usize = 0;
    for (scene_file.assets) |asset| {
        if (!std.ascii.eqlIgnoreCase(asset.type, "model")) continue;

        const model_type = if (std.ascii.eqlIgnoreCase(asset.modelType, "gltf"))
            SceneModelType.gltf
        else if (std.ascii.eqlIgnoreCase(asset.modelType, "obj"))
            SceneModelType.obj
        else
            return error.InvalidSceneModelType;

        const start = texture_index;
        for (asset.textures) |slot| {
            texture_slots[texture_index] = .{
                .slot = @intCast(slot.slot),
                .path = slot.path,
            };
            texture_index += 1;
        }

        assets[model_index] = .{
            .model_type = model_type,
            .model_path = asset.modelPath,
            .fallback_model_path = asset.fallbackModelPath,
            .apply_cornell_palette = asset.applyCornellPalette,
            .position = math.Vec3.new(asset.position[0], asset.position[1], asset.position[2]),
            .rotation_deg = math.Vec3.new(asset.rotationDeg[0], asset.rotationDeg[1], asset.rotationDeg[2]),
            .scale = math.Vec3.new(asset.scale[0], asset.scale[1], asset.scale[2]),
            .texture_slots = texture_slots[start..texture_index],
        };
        model_index += 1;
    }

    return .{
        .key = scene_file.key,
        .assets = assets,
        .texture_slots = texture_slots,
        .runtime = runtime,
        .hdri_path = hdri_path,
        .camera_position = camera_position,
        .camera_orientation_pitch = camera_orientation_pitch,
        .camera_orientation_yaw = camera_orientation_yaw,
    };
}

fn loadPrimaryMesh(allocator: std.mem.Allocator, scene_def: SceneDefinition) !SceneAsset {
    if (scene_def.assets.len == 0) return error.SceneHasNoAssets;

    var merged_mesh: ?mesh_module.Mesh = null;
    for (scene_def.assets) |asset| {
        var loaded_mesh: mesh_module.Mesh = switch (asset.model_type) {
            .gltf => try loadGltfMeshAsset(allocator, asset),
            .obj => try loadObjMeshAsset(allocator, asset),
        };
        applyAssetTransform(&loaded_mesh, asset);
        if (merged_mesh == null) {
            merged_mesh = loaded_mesh;
        } else {
            var existing = merged_mesh.?;
            try appendMesh(allocator, &existing, &loaded_mesh);
            loaded_mesh.deinit();
            merged_mesh = existing;
        }
    }

    return .{ .mesh = merged_mesh.? };
}

fn loadGltfMeshAsset(allocator: std.mem.Allocator, asset: SceneAssetDefinition) !mesh_module.Mesh {
    if (gltf_loader.load(allocator, asset.model_path)) |mesh| {
        app_logger.infoSub("assets", "loaded gltf asset from {s}", .{asset.model_path});
        return mesh;
    } else |err| {
        app_logger.warn("scene gltf load failed for {s}: {s}", .{
            asset.model_path,
            @errorName(err),
        });
    }
    if (asset.fallback_model_path) |fallback_path| {
        const fallback_mesh = try obj_loader.load(allocator, fallback_path);
        app_logger.infoSub("assets", "loaded fallback obj from {s}", .{fallback_path});
        return fallback_mesh;
    }
    return error.SceneModelLoadFailed;
}

fn loadObjMeshAsset(allocator: std.mem.Allocator, asset: SceneAssetDefinition) !mesh_module.Mesh {
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

    std.mem.copyForwards(math.Vec3, new_vertices[0..old_vertex_count], target.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..old_vertex_count], target.tex_coords);
    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..old_triangle_count], target.triangles);
    std.mem.copyForwards(math.Vec3, new_normals[0..old_triangle_count], target.normals);

    std.mem.copyForwards(math.Vec3, new_vertices[old_vertex_count..], source.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[old_vertex_count..], source.tex_coords);
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
    target.vertices = new_vertices;
    target.tex_coords = new_tex_coords;
    target.triangles = new_triangles;
    target.normals = new_normals;
    target.clearMeshlets();
}

fn loadSceneTextures(
    allocator: std.mem.Allocator,
    assets: []const SceneAssetDefinition,
    loaded_slots: *[3]?texture.Texture,
    material_textures: *[3]?*const texture.Texture,
) !void {
    for (assets) |asset| {
        for (asset.texture_slots) |slot| {
            if (slot.slot >= loaded_slots.len) {
                app_logger.warn("texture slot {} out of range for {s}", .{ slot.slot, slot.path });
                continue;
            }
            loaded_slots[slot.slot] = texture.loadBmp(allocator, slot.path) catch |err| blk: {
                app_logger.warn("failed to load texture slot {} {s}: {s}", .{ slot.slot, slot.path, @errorName(err) });
                break :blk null;
            };
            if (loaded_slots[slot.slot]) |*tex| material_textures[slot.slot] = tex;
        }
    }
}

fn applyAssetTransform(mesh: *mesh_module.Mesh, asset: SceneAssetDefinition) void {
    for (mesh.vertices) |*v| {
        v.* = transformPoint(v.*, asset.position, asset.rotation_deg, asset.scale);
    }
    for (mesh.normals) |*n| {
        n.* = rotateVector(n.*, asset.rotation_deg).normalize();
    }
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

fn setupGunRuntime(allocator: std.mem.Allocator, mesh: *mesh_module.Mesh) !GunRuntime {
    mesh.centerToOrigin();

    var gun_min_b = mesh.vertices[0];
    var gun_max_b = mesh.vertices[0];
    for (mesh.vertices[1..]) |v| {
        gun_min_b.x = @min(gun_min_b.x, v.x);
        gun_min_b.y = @min(gun_min_b.y, v.y);
        gun_min_b.z = @min(gun_min_b.z, v.z);
        gun_max_b.x = @max(gun_max_b.x, v.x);
        gun_max_b.y = @max(gun_max_b.y, v.y);
        gun_max_b.z = @max(gun_max_b.z, v.z);
    }

    const num_gun_vertices = mesh.vertices.len;
    const num_gun_triangles = mesh.triangles.len;
    const original_gun_vertices = try allocator.alloc(math.Vec3, num_gun_vertices);
    const original_gun_normals = try allocator.alloc(math.Vec3, num_gun_triangles);
    @memcpy(original_gun_vertices, mesh.vertices[0..num_gun_vertices]);
    @memcpy(original_gun_normals, mesh.normals[0..num_gun_triangles]);

    try levelAppendGroundPlane(mesh, allocator);

    var pw = try physics_utils.PhysicsWorld.init(allocator);
    const body_interface = pw.system.getBodyInterfaceMut();

    const floor_shape_settings = try zphysics.BoxShapeSettings.create(.{ 100.0, 1.0, 100.0 });
    defer floor_shape_settings.asShapeSettings().release();
    const floor_shape = try floor_shape_settings.asShapeSettings().createShape();
    defer floor_shape.release();
    const floor_body_settings = zphysics.BodyCreationSettings{
        .shape = floor_shape,
        .position = .{ 0.0, -2.0, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .static,
        .object_layer = physics_utils.object_layers.non_moving,
    };
    _ = try body_interface.createAndAddBody(floor_body_settings, .activate);

    const gun_hx = (gun_max_b.x - gun_min_b.x) * 0.5;
    const gun_hy = (gun_max_b.y - gun_min_b.y) * 0.5;
    const gun_hz = (gun_max_b.z - gun_min_b.z) * 0.5;
    const gun_shape_settings = try zphysics.BoxShapeSettings.create(.{ gun_hx, gun_hy, gun_hz });
    defer gun_shape_settings.asShapeSettings().release();
    const gun_shape = try gun_shape_settings.asShapeSettings().createShape();
    defer gun_shape.release();

    var gun_body_settings = zphysics.BodyCreationSettings{
        .shape = gun_shape,
        .position = .{ 0.0, 5.0, 0.0, 0.0 },
        .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
        .motion_type = .dynamic,
        .object_layer = physics_utils.object_layers.moving,
    };
    gun_body_settings.angular_velocity = .{ 2.0, 1.0, 3.0, 0.0 };
    gun_body_settings.restitution = 0.5;
    const gun_body_id = try body_interface.createAndAddBody(gun_body_settings, .activate);

    return .{
        .pw = pw,
        .gun_body_id = gun_body_id,
        .num_gun_vertices = num_gun_vertices,
        .num_gun_triangles = num_gun_triangles,
        .original_gun_vertices = original_gun_vertices,
        .original_gun_normals = original_gun_normals,
    };
}

fn applyCornellColors(mesh: *mesh_module.Mesh) void {
    const white: u32 = 0xFFE6E6E6;
    const red: u32 = 0xFF3A3ACB;
    const green: u32 = 0xFF59D66F;

    for (mesh.triangles, 0..) |*tri, i| {
        tri.base_color = if (i < 2)
            white // back
        else if (i < 4)
            red // left
        else if (i < 6)
            green // right
        else if (i < 12)
            white // floor, ceiling, light
        else
            white; // inner boxes
    }

    // Cornell room is viewed from the inside; flip room and light panel normals so
    // backface rejection keeps interior surfaces visible.
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
    const plane_color: u32 = 0xFFFFFFFF;
    const segments: usize = 16;

    const old_vertex_count = mesh.vertices.len;
    const old_triangle_count = mesh.triangles.len;
    const verts_per_row = segments + 1;
    const plane_vertex_count = verts_per_row * verts_per_row;
    const plane_triangle_count = segments * segments * 2;
    const new_vertex_count = old_vertex_count + plane_vertex_count;
    const new_triangle_count = old_triangle_count + plane_triangle_count;

    const new_vertices = try allocator.alloc(math.Vec3, new_vertex_count);
    errdefer allocator.free(new_vertices);
    const new_tex_coords = try allocator.alloc(math.Vec2, new_vertex_count);
    errdefer allocator.free(new_tex_coords);
    const new_triangles = try allocator.alloc(mesh_module.Triangle, new_triangle_count);
    errdefer allocator.free(new_triangles);

    std.mem.copyForwards(math.Vec3, new_vertices[0..old_vertex_count], mesh.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..old_vertex_count], mesh.tex_coords);

    const base = old_vertex_count;
    const step = (plane_extent * 2.0) / @as(f32, @floatFromInt(segments));
    var row: usize = 0;
    while (row < verts_per_row) : (row += 1) {
        const z = -plane_extent + step * @as(f32, @floatFromInt(row));
        var col: usize = 0;
        while (col < verts_per_row) : (col += 1) {
            const x = -plane_extent + step * @as(f32, @floatFromInt(col));
            const idx = base + row * verts_per_row + col;
            new_vertices[idx] = math.Vec3.new(x, plane_y, z);
            new_tex_coords[idx] = math.Vec2.new(
                @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(segments)),
                @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(segments)),
            );
        }
    }

    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..old_triangle_count], mesh.triangles);
    var tri_write: usize = old_triangle_count;
    row = 0;
    while (row < segments) : (row += 1) {
        var col: usize = 0;
        while (col < segments) : (col += 1) {
            const v00 = base + row * verts_per_row + col;
            const v10 = base + row * verts_per_row + (col + 1);
            const v01 = base + (row + 1) * verts_per_row + col;
            const v11 = base + (row + 1) * verts_per_row + (col + 1);
            new_triangles[tri_write] = mesh_module.Triangle.newWithColor(v00, v11, v10, plane_color);
            tri_write += 1;
            new_triangles[tri_write] = mesh_module.Triangle.newWithColor(v00, v01, v11, plane_color);
            tri_write += 1;
        }
    }

    const new_normals = try allocator.alloc(math.Vec3, new_triangle_count);
    errdefer allocator.free(new_normals);
    allocator.free(mesh.vertices);
    allocator.free(mesh.tex_coords);
    allocator.free(mesh.triangles);
    allocator.free(mesh.normals);
    mesh.vertices = new_vertices;
    mesh.tex_coords = new_tex_coords;
    mesh.triangles = new_triangles;
    mesh.normals = new_normals;
    mesh.recalculateNormals();
    mesh.clearMeshlets();
}
