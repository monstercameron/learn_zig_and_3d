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
const profiler = @import("profiler.zig");
const windows = std.os.windows;
const math = @import("math.zig");
const zphysics = @import("zphysics");
const physics_utils = @import("physics_utils.zig");

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

// Constant for PeekMessageW: remove the message from the queue after reading.
const PM_REMOVE = 1;

// Windows Sleep function for frame pacing.
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// Import other modules from our project.
// JS Analogy: `const Window = require('./window.js');`
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;
const obj_loader = @import("obj_loader.zig");
const gltf_loader = @import("gltf_loader.zig");
const mesh_module = @import("mesh.zig");
const texture = @import("texture.zig");
const config = @import("app_config.zig");
const log = @import("log.zig");

const app_logger = log.get("app.main");
const preferred_model_path = "resources/models/gun/rovelver1.0.0.glb";
const fallback_model_path = "resources/models/teapot.obj";
const gun_bullet_albedo_path = "resources/models/gun/Texture/Cylinder/1_bullet-low_ALBEDO.bmp";
const gun_body_albedo_path = "resources/models/gun/Texture/body/1_body_low_ALBEDO.004.bmp";

const SceneAsset = struct {
    mesh: mesh_module.Mesh,
    uses_gun_materials: bool,
};

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
    const renderer_start_ns = std.time.nanoTimestamp();

    log.init(allocator);
    defer log.deinit();
    app_logger.infoSub("bootstrap", "log manager initialized", .{});
    if (renderer_ttl_ns) |ttl_ns| {
        app_logger.infoSub("bootstrap", "renderer TTL active {d:.3}s", .{@as(f64, @floatFromInt(ttl_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))});
    }

    // Create a window.
    // JS Analogy: `const window = new Window(800, 600);`
    // The `try` keyword is like `await` for a function that might fail. If `Window.init`
    // returns an error, `main` will immediately stop and report the error.
    config.load(allocator, "resources/configs/default.settings.json") catch |err| {
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

    var bullet_albedo: ?texture.Texture = null;
    defer if (bullet_albedo) |*tex| tex.deinit();
    var body_albedo: ?texture.Texture = null;
    defer if (body_albedo) |*tex| tex.deinit();
    var material_textures = [_]?*const texture.Texture{ null, null, null };

    // Load the preferred scene model, falling back to the teapot if the GLB path fails.
    var scene_asset = try loadPrimaryMesh(allocator);
    defer scene_asset.mesh.deinit(); // Guarantees the mesh memory is freed on exit.
    if (scene_asset.uses_gun_materials) {
        configureGunTextures(allocator, &bullet_albedo, &body_albedo, &material_textures);
        renderer.setTextures(material_textures[0..]);

        // Load HDRI background
        if (texture.loadHdrRaw(allocator, "resources/hdri/envmap.raw")) |env_map| {
            app_logger.infoSub("assets", "loaded HDRI env map", .{});
            renderer.setHdriMap(env_map);
        } else |err| {
            app_logger.warn("failed to load HDRI: {s}", .{@errorName(err)});
        }
    }

    scene_asset.mesh.centerToOrigin(); // Center the model at (0,0,0).

    // Calculate exact bounds
    var gun_min_b = scene_asset.mesh.vertices[0];
    var gun_max_b = scene_asset.mesh.vertices[0];
    for (scene_asset.mesh.vertices[1..scene_asset.mesh.vertices.len]) |v| {
        gun_min_b.x = @min(gun_min_b.x, v.x);
        gun_min_b.y = @min(gun_min_b.y, v.y);
        gun_min_b.z = @min(gun_min_b.z, v.z);
        gun_max_b.x = @max(gun_max_b.x, v.x);
        gun_max_b.y = @max(gun_max_b.y, v.y);
        gun_max_b.z = @max(gun_max_b.z, v.z);
    }
    const gun_hx = (gun_max_b.x - gun_min_b.x) * 0.5;
    const gun_hy = (gun_max_b.y - gun_min_b.y) * 0.5;
    const gun_hz = (gun_max_b.z - gun_min_b.z) * 0.5;

    const num_gun_vertices = scene_asset.mesh.vertices.len;
    const num_gun_triangles = scene_asset.mesh.triangles.len;

    const original_gun_vertices = try allocator.alloc(math.Vec3, num_gun_vertices);
    defer allocator.free(original_gun_vertices);
    @memcpy(original_gun_vertices, scene_asset.mesh.vertices[0..num_gun_vertices]);

    const original_gun_normals = try allocator.alloc(math.Vec3, num_gun_triangles);
    defer allocator.free(original_gun_normals);
    @memcpy(original_gun_normals, scene_asset.mesh.normals[0..num_gun_triangles]);

    try levelAppendGroundPlane(&scene_asset.mesh, allocator);
    try scene_asset.mesh.generateMeshlets(64, 126);
    app_logger.infoSub(
        "assets",
        "loaded scene mesh vertices={} triangles={} meshlets={}",
        .{ scene_asset.mesh.vertices.len, scene_asset.mesh.triangles.len, scene_asset.mesh.meshlets.len },
    );

    renderer.setCameraPosition(math.Vec3.new(0.0, 2.0, -10.0));
    renderer.setCameraOrientation(-0.1, 0.0);

    // ==== PHYSICS INIT ====
    try zphysics.init(allocator, .{});
    app_logger.info("zphysics.init done", .{});
    defer zphysics.deinit();
    var pw = try physics_utils.PhysicsWorld.init(allocator);
    app_logger.info("PhysicsWorld.init done", .{});
    defer pw.deinit(allocator);

    const body_interface = pw.system.getBodyInterfaceMut();

    // floor
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
    const floor_body_id = try body_interface.createAndAddBody(floor_body_settings, .activate);
    _ = floor_body_id;

    // gun
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
    // Add angular velocity and initial bounce
    gun_body_settings.angular_velocity = .{ 2.0, 1.0, 3.0, 0.0 };
    gun_body_settings.restitution = 0.5;

    const gun_body_id = try body_interface.createAndAddBody(gun_body_settings, .activate);
    app_logger.info("gun body created!", .{});

    // ========== EVENT LOOP PHASE ==========

    // This is the main application loop, similar to `requestAnimationFrame` in JS.
    // We use `PeekMessageW` for a non-blocking loop, which allows us to render
    // frames continuously even if there are no new user input events.
    var running = true;

    app_logger.info("starting main event loop...", .{});

    // The MessagePump is a helper for processing all pending OS events.
    // JS Analogy: This is like the internal logic a browser runs between frames
    // to handle all queued user inputs.
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
            // Process all pending messages in the queue without blocking.
            while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
                // If we get a quit message, signal the main loop to exit.
                if (m.message == WM_QUIT) {
                    app_logger.info("received WM_QUIT message, exiting", .{});
                    return false; // Signal to exit.
                }

                // Handle keyboard input directly for maximum responsiveness.
                if (m.message == WM_KEYDOWN) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, true);
                } else if (m.message == WM_KEYUP) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, false);
                } else if (m.message == WM_CHAR) {
                    const char_code: u32 = @intCast(m.wParam);
                    r.handleCharInput(char_code);
                } else if (m.message == WM_MOUSEMOVE) {
                    const coords = decodeMouseCoords(m.lParam);
                    r.handleMouseMove(coords.x, coords.y);
                }

                // These two functions are part of the standard Windows message handling.
                // `TranslateMessage` converts key presses into character messages.
                // `DispatchMessageW` sends the message to our main window handler (`WindowProc`).
                _ = TranslateMessage(&m);
                _ = DispatchMessageW(&m);
            }
            return true; // Continue running.
        }
    };

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

        // First, process all pending user input and window events.
        if (!MessagePump.pump(&renderer)) {
            app_logger.info("message pump requested shutdown", .{});
            running = false;
            break;
        }

        // Physics Step
        pw.system.update(1.0 / 60.0, .{ .collision_steps = 1 }) catch {};

        // Update Gun Mesh Vertices
        const lock_iface = pw.system.getBodyLockInterfaceNoLock();
        var read_lock: zphysics.BodyLockRead = .{};
        read_lock.lock(lock_iface, gun_body_id);
        const body = read_lock.body.?;
        const xform = body.getWorldTransform();
        const rot = xform.rotation;
        const pos = xform.position;

        for (scene_asset.mesh.vertices[0..num_gun_vertices], 0..) |*v, i| {
            const ov = original_gun_vertices[i];
            v.x = rot[0] * ov.x + rot[3] * ov.y + rot[6] * ov.z + pos[0];
            v.y = rot[1] * ov.x + rot[4] * ov.y + rot[7] * ov.z + pos[1];
            v.z = rot[2] * ov.x + rot[5] * ov.y + rot[8] * ov.z + pos[2];
        }

        for (scene_asset.mesh.normals[0..num_gun_triangles], 0..) |*n, i| {
            const on = original_gun_normals[i];
            n.x = rot[0] * on.x + rot[3] * on.y + rot[6] * on.z;
            n.y = rot[1] * on.x + rot[4] * on.y + rot[7] * on.z;
            n.z = rot[2] * on.x + rot[5] * on.y + rot[8] * on.z;
        }

        scene_asset.mesh.refreshMeshlets();
        renderer.invalidateMeshWork();

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

fn loadPrimaryMesh(allocator: std.mem.Allocator) !SceneAsset {
    if (gltf_loader.load(allocator, preferred_model_path)) |mesh| {
        app_logger.infoSub("assets", "loaded gltf scene from {s}", .{preferred_model_path});
        return .{
            .mesh = mesh,
            .uses_gun_materials = true,
        };
    } else |err| {
        app_logger.warn("preferred model load failed for {s}: {s}; falling back to {s}", .{
            preferred_model_path,
            @errorName(err),
            fallback_model_path,
        });
    }

    const fallback_mesh = try obj_loader.load(allocator, fallback_model_path);
    app_logger.infoSub("assets", "loaded fallback obj from {s}", .{fallback_model_path});
    return .{
        .mesh = fallback_mesh,
        .uses_gun_materials = false,
    };
}

fn configureGunTextures(
    allocator: std.mem.Allocator,
    bullet_albedo: *?texture.Texture,
    body_albedo: *?texture.Texture,
    material_textures: *[3]?*const texture.Texture,
) void {
    bullet_albedo.* = texture.loadBmp(allocator, gun_bullet_albedo_path) catch |err| blk: {
        app_logger.warn("failed to load gun bullet texture {s}: {s}", .{ gun_bullet_albedo_path, @errorName(err) });
        break :blk null;
    };
    if (bullet_albedo.*) |*tex| {
        material_textures[0] = tex;
        app_logger.infoSub("assets", "loaded gun bullet albedo {s}", .{gun_bullet_albedo_path});
    }

    body_albedo.* = texture.loadBmp(allocator, gun_body_albedo_path) catch |err| blk: {
        app_logger.warn("failed to load gun body texture {s}: {s}", .{ gun_body_albedo_path, @errorName(err) });
        break :blk null;
    };
    if (body_albedo.*) |*tex| {
        material_textures[1] = tex;
        app_logger.infoSub("assets", "loaded gun body albedo {s}", .{gun_body_albedo_path});
    }
}

fn levelLiftMeshToGround(mesh: *mesh_module.Mesh) void {
    if (mesh.vertices.len == 0) return;
    var min_y = mesh.vertices[0].y;
    for (mesh.vertices[1..]) |v| {
        if (v.y < min_y) min_y = v.y;
    }
    const offset = -min_y;
    if (offset == 0.0) return;
    for (mesh.vertices) |*v| {
        v.y += offset;
    }
    mesh.clearMeshlets();
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
            const u = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(segments));
            const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(segments));
            new_tex_coords[idx] = math.Vec2.new(u, v);
        }
    }

    // Copy the original mesh's triangles to the START so their indices don't shift.
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
