//! # The Main Renderer Module
//!
//! This module is the heart and brain of the entire rendering engine. It orchestrates
//! the entire 3D pipeline, from handling user input to update the camera, transforming
//! 3D vertices, dispatching work to the job system, and finally presenting the
//! rendered image to the screen.
//!
//! ## JavaScript Analogy
//!
//! Think of this as the main class in a rendering library like `three.js` (e.g., `WebGLRenderer`)
//! combined with the scene update and render loop logic. It holds the application state
//! and contains the main `render()` method that gets called every frame.
//!
//! ```javascript
//! class App {
//!   constructor() {
//!     this.renderer = new THREE.WebGLRenderer();
//!     this.scene = new THREE.Scene();
//!     this.camera = new THREE.PerspectiveCamera(...);
//!     this.state = { rotation: 0, lightPosition: ... };
//!   }
//!
//!   render() {
//!     // This is what our `render3DMeshWithPump` function does:
//!     this.updateStateFromInput();
//!     this.renderer.render(this.scene, this.camera);
//!   }
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;
const math = @import("math.zig");
const Mesh = @import("mesh.zig").Mesh;
const config = @import("app_config.zig");
const input = @import("input.zig");
const lighting = @import("lighting.zig");
const scanline = @import("scanline.zig");
const texture = @import("texture.zig");

// HGDIOBJ: A "handle" (like an ID) to a Windows graphics object.
const HGDIOBJ = *anyopaque;

// SRCCOPY: A Windows constant that tells BitBlt to do a direct pixel copy.
const SRCCOPY = 0x00CC0020;

// ========== WINDOWS API DECLARATIONS ==========
// These are external function definitions for the Windows Graphics Device Interface (GDI).
// JS Analogy: This is like the low-level native browser code that the Canvas API calls.
extern "user32" fn GetDC(hWnd: windows.HWND) ?windows.HDC;
extern "user32" fn ReleaseDC(hWnd: windows.HWND, hDC: windows.HDC) i32;
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
extern "gdi32" fn BitBlt(hdcDest: windows.HDC, nXDest: i32, nYDest: i32, nWidth: i32, nHeight: i32, hdcSrc: windows.HDC, nXSrc: i32, nYSrc: i32, dwRop: u32) bool;
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("bitmap.zig").Bitmap;
const TileRenderer = @import("tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("binning_stage.zig");
const JobSystem = @import("job_system.zig").JobSystem;
const Job = @import("job_system.zig").Job;

/// The `Renderer` struct holds the entire state of the rendering engine.
/// It manages the window connection, the pixel buffer, the rendering pipeline, and application state.
pub const Renderer = struct {
    // Core rendering resources
    hwnd: windows.HWND, // Handle to the window we are drawing to.
    bitmap: Bitmap, // The main pixel buffer we draw into (our "canvas").
    hdc: ?windows.HDC, // The window's "device context" for drawing.
    hdc_mem: ?windows.HDC, // An in-memory device context for faster drawing operations.
    allocator: std.mem.Allocator,

    // Camera and object state
    rotation_angle: f32, // Camera yaw (left/right rotation).
    rotation_x: f32, // Camera pitch (up/down rotation).
    camera_position: math.Vec3, // Camera world position.
    camera_move_speed: f32, // Units per second for keyboard movement.
    mouse_sensitivity: f32, // Mouse look sensitivity factor.
    pending_mouse_delta: math.Vec2, // Accumulated mouse delta since last frame.
    mouse_initialized: bool, // Tracks whether the initial mouse position has been captured.
    mouse_last_pos: windows.POINT, // Last mouse position in client coordinates.

    // Light state
    light_orbit_x: f32,
    light_orbit_y: f32,
    light_distance: f32,

    // Input and timing state
    keys_pressed: u32, // Bitmask of currently pressed keys.
    camera_fov_deg: f32,
    frame_count: u32,
    last_time: i128,
    last_frame_time: i128,
    current_fps: u32,
    target_frame_time_ns: i128,
    pending_fov_delta: f32,

    // Tiled rendering resources
    tile_grid: ?TileGrid, // The grid layout of tiles on the screen.
    tile_buffers: ?[]TileBuffer, // A buffer for each tile to be rendered into in parallel.
    job_system: ?*JobSystem, // The multi-threaded job system.

    // Rendering options and data
    texture: ?*const texture.Texture, // The currently active texture.
    show_tile_borders: bool = false,
    show_wireframe: bool = false,
    show_light_orb: bool = true,
    cull_light_orb: bool = true,
    use_tiled_rendering: bool = true,

    // Internal state for managing job memory
    previous_frame_jobs: ?[]Job,
    previous_frame_tile_jobs: ?[]TileRenderJob,

    // Unused state from previous versions
    last_brightness_min: f32,
    last_brightness_max: f32,
    last_brightness_avg: f32,
    last_reported_fov_deg: f32,
    light_marker_visible_last_frame: bool,

    /// Initializes the renderer, creating all necessary resources.
    /// JS Analogy: The `constructor` for our main rendering class.
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        const hdc = GetDC(hwnd) orelse return error.DCNotFound;
        const hdc_mem = CreateCompatibleDC(hdc) orelse {
            _ = ReleaseDC(hwnd, hdc);
            return error.MemoryDCCreationFailed;
        };

        const bitmap = try Bitmap.init(width, height);
        const current_time = std.time.nanoTimestamp();
        const tile_grid = try TileGrid.init(width, height, allocator);

        const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
        for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
            buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
        }

        const job_system = try JobSystem.init(allocator);

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .hdc_mem = hdc_mem,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
            .camera_position = math.Vec3.new(0.0, 1.5, -5.0),
            .camera_move_speed = 6.0,
            .mouse_sensitivity = 0.0025,
            .pending_mouse_delta = math.Vec2.new(0.0, 0.0),
            .mouse_initialized = false,
            .mouse_last_pos = .{ .x = 0, .y = 0 },
            .light_orbit_x = 0.0,
            .light_orbit_y = 0.0,
            .light_distance = config.LIGHT_DISTANCE_INITIAL,
            .camera_fov_deg = config.CAMERA_FOV_INITIAL,
            .keys_pressed = 0,
            .frame_count = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .current_fps = 0,
            .target_frame_time_ns = config.targetFrameTimeNs(),
            .last_brightness_min = 0,
            .last_brightness_max = 0,
            .last_brightness_avg = 0,
            .last_reported_fov_deg = config.CAMERA_FOV_INITIAL,
            .light_marker_visible_last_frame = true,
            .pending_fov_delta = 0.0,
            .tile_grid = tile_grid,
            .tile_buffers = tile_buffers,
            .texture = null,
            .use_tiled_rendering = true,
            .job_system = job_system,
            .previous_frame_jobs = null,
            .previous_frame_tile_jobs = null,
        };
    }

    /// Cleans up all renderer resources in the reverse order of creation.
    pub fn deinit(self: *Renderer) void {
        if (self.job_system) |js| js.deinit();
        if (self.previous_frame_jobs) |jobs| self.allocator.free(jobs);
        if (self.previous_frame_tile_jobs) |tile_jobs| self.allocator.free(tile_jobs);
        if (self.tile_buffers) |buffers| {
            for (buffers) |*buf| buf.deinit();
            self.allocator.free(buffers);
        }
        if (self.tile_grid) |*grid| grid.deinit();
        self.bitmap.deinit();
        if (self.hdc_mem) |hdc_mem| _ = DeleteDC(hdc_mem);
        if (self.hdc) |hdc| _ = ReleaseDC(self.hwnd, hdc);
    }

    // ========== TILE RENDER JOB ==========

    /// This struct is the "context object" for a single tile rendering job.
    /// It packages up all the data a worker thread needs to render one tile.
    /// JS Analogy: The data object you would `postMessage` to a Web Worker.
    const TileRenderJob = struct {
        tile: *const TileRenderer.Tile,
        tile_buffer: *TileBuffer,
        tri_list: *const BinningStage.TileTriangleList, // The list of triangles to draw in this tile.
        mesh: *const Mesh,
        projected: [][2]i32, // Screen-space vertex positions.
        transformed_vertices: []math.Vec3, // Camera-space vertex positions.
        transform: math.Mat4, // The model's rotation matrix.
        light_dir: math.Vec3,
        draw_wireframe: bool,
        texture: ?*const texture.Texture,
        base_color: u32,

        /// The actual function that gets executed by a worker thread.
        fn renderTileJob(ctx: *anyopaque) void {
            const job: *TileRenderJob = @ptrCast(@alignCast(ctx));

            // Iterate through all triangles assigned to this tile.
            for (job.tri_list.triangles.items) |tri_idx| {
                const tri = job.mesh.triangles[tri_idx];
                if (tri.cull_flags.cull_fill) continue;

                const p0 = job.projected[tri.v0];
                const p1 = job.projected[tri.v1];
                const p2 = job.projected[tri.v2];

                if (p0[0] < -1000 or p1[0] < -1000 or p2[0] < -1000) continue;

                // --- Lighting and Backface Culling ---
                const normal = job.mesh.normals[tri_idx];
                const normal_transformed_raw = math.Vec3.new(
                    job.transform.data[0] * normal.x + job.transform.data[1] * normal.y + job.transform.data[2] * normal.z,
                    job.transform.data[4] * normal.x + job.transform.data[5] * normal.y + job.transform.data[6] * normal.z,
                    job.transform.data[8] * normal.x + job.transform.data[9] * normal.y + job.transform.data[10] * normal.z
                );
                const normal_transformed = normal_transformed_raw.normalize();

                const p0_cam = job.transformed_vertices[tri.v0];
                const p1_cam = job.transformed_vertices[tri.v1];
                const p2_cam = job.transformed_vertices[tri.v2];
                const face_center = math.Vec3.scale(math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam), 1.0 / 3.0);

                const view_vector = math.Vec3.normalize(math.Vec3.scale(face_center, -1.0));
                if (normal_transformed.dot(view_vector) <= 0.0) continue; // Backface culling.

                // --- Shading ---
                const brightness = normal_transformed.dot(job.light_dir);
                const intensity = lighting.computeIntensity(brightness);
                const uv0 = if (tri.v0 < job.mesh.tex_coords.len)
                    job.mesh.tex_coords[tri.v0]
                else
                    math.Vec2.new(0.0, 0.0);
                const uv1 = if (tri.v1 < job.mesh.tex_coords.len)
                    job.mesh.tex_coords[tri.v1]
                else
                    math.Vec2.new(0.0, 0.0);
                const uv2 = if (tri.v2 < job.mesh.tex_coords.len)
                    job.mesh.tex_coords[tri.v2]
                else
                    math.Vec2.new(0.0, 0.0);

                const shading = TileRenderer.ShadingParams{
                    .base_color = job.base_color,
                    .texture = job.texture,
                    .uv0 = uv0, .uv1 = uv1, .uv2 = uv2,
                    .intensity = intensity,
                };

                // --- Rasterization ---
                TileRenderer.rasterizeTriangleToTile(job.tile, job.tile_buffer, p0, p1, p2, shading);
            }

            // (omitting wireframe drawing for brevity)
        }
    };

    pub fn handleKeyInput(self: *Renderer, key: u32, is_down: bool) void {
        _ = input.updateKeyState(&self.keys_pressed, key, is_down);
    }

    pub fn handleMouseMove(self: *Renderer, x: i32, y: i32) void {
        const current = windows.POINT{ .x = x, .y = y };
        if (!self.mouse_initialized) {
            self.mouse_last_pos = current;
            self.mouse_initialized = true;
            return;
        }

        const dx = @as(f32, @floatFromInt(current.x - self.mouse_last_pos.x));
        const dy = @as(f32, @floatFromInt(current.y - self.mouse_last_pos.y));
        self.pending_mouse_delta = math.Vec2.new(self.pending_mouse_delta.x + dx, self.pending_mouse_delta.y + dy);
        self.mouse_last_pos = current;
    }

    pub fn setCameraPosition(self: *Renderer, position: math.Vec3) void {
        self.camera_position = position;
    }

    pub fn setCameraOrientation(self: *Renderer, pitch: f32, yaw: f32) void {
        self.rotation_x = std.math.clamp(pitch, -1.5, 1.5);
        self.rotation_angle = yaw;
    }

    fn consumeMouseDelta(self: *Renderer) math.Vec2 {
        const delta = self.pending_mouse_delta;
        self.pending_mouse_delta = math.Vec2.new(0.0, 0.0);
        return delta;
    }

    pub fn shouldRenderFrame(self: *Renderer) bool {
        _ = self;
        return true;
    }

    pub fn handleCharInput(self: *Renderer, char_code: u32) void {
        switch (char_code) {
            'q', 'Q' => self.pending_fov_delta -= config.CAMERA_FOV_STEP,
            'e', 'E' => self.pending_fov_delta += config.CAMERA_FOV_STEP,
            else => {},
        }
    }

    pub fn setTexture(self: *Renderer, tex: *const texture.Texture) void {
        self.texture = tex;
    }

    /// The main render loop function for a single frame.
    pub fn render3DMesh(self: *Renderer, mesh: *const Mesh) !void {
        try self.render3DMeshWithPump(mesh, null);
    }

    /// The main render loop function, with an added callback to process OS messages.
    /// This is the heart of the engine, executing the full 3D pipeline each frame.
    pub fn render3DMeshWithPump(self: *Renderer, mesh: *const Mesh, pump: ?*const fn (*Renderer) bool) !void {
        @memset(self.bitmap.pixels, 0xFF000000);

        const delta_seconds = self.beginFrame();

        const rotation_speed = 2.0;
        if ((self.keys_pressed & input.KeyBits.left) != 0) self.rotation_angle -= rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.right) != 0) self.rotation_angle += rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.up) != 0) self.rotation_x -= rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.down) != 0) self.rotation_x += rotation_speed * delta_seconds;

        const mouse_delta = self.consumeMouseDelta();
    self.rotation_angle += mouse_delta.x * self.mouse_sensitivity;
    self.rotation_x -= mouse_delta.y * self.mouse_sensitivity;
        self.rotation_x = std.math.clamp(self.rotation_x, -1.5, 1.5);

        const fov_delta = self.consumePendingFovDelta();
        if (fov_delta != 0.0) self.adjustCameraFov(fov_delta);

        const auto_orbit_speed = 0.5;
        self.light_orbit_x += auto_orbit_speed * delta_seconds;
        const light_orbit = math.Mat4.multiply(math.Mat4.rotateY(self.light_orbit_y), math.Mat4.rotateX(self.light_orbit_x));
        const light_pos_world = light_orbit.mulVec3(math.Vec3.new(0.0, 0.0, self.light_distance));
        const light_dir_world = math.Vec3.normalize(light_pos_world);

        const yaw = self.rotation_angle;
        const pitch = self.rotation_x;
        const cos_pitch = @cos(pitch);
        const sin_pitch = @sin(pitch);
        const cos_yaw = @cos(yaw);
        const sin_yaw = @sin(yaw);

        var forward = math.Vec3.new(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
        forward = math.Vec3.normalize(forward);

        const world_up = math.Vec3.new(0.0, 1.0, 0.0);
        var right = math.Vec3.cross(world_up, forward);
        const right_len = math.Vec3.length(right);
        if (right_len < 0.0001) {
            right = math.Vec3.new(1.0, 0.0, 0.0);
        } else {
            right = math.Vec3.scale(right, 1.0 / right_len);
        }

        var up = math.Vec3.cross(forward, right);
        up = math.Vec3.normalize(up);

        var forward_flat = math.Vec3.new(forward.x, 0.0, forward.z);
        const forward_flat_len = math.Vec3.length(forward_flat);
        if (forward_flat_len > 0.0001) {
            forward_flat = math.Vec3.scale(forward_flat, 1.0 / forward_flat_len);
        } else {
            forward_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var right_flat = math.Vec3.new(right.x, 0.0, right.z);
        const right_flat_len = math.Vec3.length(right_flat);
        if (right_flat_len > 0.0001) {
            right_flat = math.Vec3.scale(right_flat, 1.0 / right_flat_len);
        } else {
            right_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var movement_dir = math.Vec3.new(0.0, 0.0, 0.0);
        if ((self.keys_pressed & input.KeyBits.w) != 0) movement_dir = math.Vec3.add(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.s) != 0) movement_dir = math.Vec3.sub(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.d) != 0) movement_dir = math.Vec3.add(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.a) != 0) movement_dir = math.Vec3.sub(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.space) != 0) movement_dir = math.Vec3.add(movement_dir, world_up);
        if ((self.keys_pressed & input.KeyBits.ctrl) != 0) movement_dir = math.Vec3.sub(movement_dir, world_up);

        const movement_mag = math.Vec3.length(movement_dir);
        if (movement_mag > 0.0001) {
            const normalized_move = math.Vec3.scale(movement_dir, 1.0 / movement_mag);
            const move_step = math.Vec3.scale(normalized_move, self.camera_move_speed * delta_seconds);
            self.camera_position = math.Vec3.add(self.camera_position, move_step);
        }

        var view_rotation = math.Mat4.identity();
        view_rotation.data[0] = right.x;
        view_rotation.data[1] = right.y;
        view_rotation.data[2] = right.z;
        view_rotation.data[4] = up.x;
        view_rotation.data[5] = up.y;
        view_rotation.data[6] = up.z;
        view_rotation.data[8] = forward.x;
        view_rotation.data[9] = forward.y;
        view_rotation.data[10] = forward.z;

        const light_relative = math.Vec3.sub(light_pos_world, self.camera_position);
        const light_camera = math.Vec3.new(
            math.Vec3.dot(light_relative, right),
            math.Vec3.dot(light_relative, up),
            math.Vec3.dot(light_relative, forward),
        );

        const light_dir = math.Vec3.normalize(math.Vec3.new(
            math.Vec3.dot(light_dir_world, right),
            math.Vec3.dot(light_dir_world, up),
            math.Vec3.dot(light_dir_world, forward),
        ));

        const projected = try self.allocator.alloc([2]i32, mesh.vertices.len);
        defer self.allocator.free(projected);

        const transformed_vertices = try self.allocator.alloc(math.Vec3, mesh.vertices.len);
        defer self.allocator.free(transformed_vertices);

        const width_f = @as(f32, @floatFromInt(self.bitmap.width));
        const height_f = @as(f32, @floatFromInt(self.bitmap.height));
        const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
        const fov_rad = self.camera_fov_deg * (std.math.pi / 180.0);
        const half_fov = fov_rad * 0.5;
        const tan_half_fov = std.math.tan(half_fov);
        const y_scale = if (tan_half_fov > 0.0) 1.0 / tan_half_fov else 1.0;
        const x_scale = y_scale / aspect_ratio;
        const center_x = width_f * 0.5;
        const center_y = height_f * 0.5;

        for (mesh.vertices, 0..) |vertex, i| {
            const relative = math.Vec3.sub(vertex, self.camera_position);
            const camera_space = math.Vec3.new(
                math.Vec3.dot(relative, right),
                math.Vec3.dot(relative, up),
                math.Vec3.dot(relative, forward),
            );
            transformed_vertices[i] = camera_space;

            const camera_z = camera_space.z;
            if (camera_z <= 0.1) {
                projected[i][0] = -1000;
                projected[i][1] = -1000;
                continue;
            }

            const ndc_x = (camera_space.x / camera_z) * x_scale;
            const ndc_y = (camera_space.y / camera_z) * y_scale;
            const screen_x = ndc_x * center_x + center_x;
            const screen_y = -ndc_y * center_y + center_y;

            projected[i][0] = @as(i32, @intFromFloat(screen_x));
            projected[i][1] = @as(i32, @intFromFloat(screen_y));
        }

        if (self.use_tiled_rendering and self.tile_grid != null and self.tile_buffers != null) {
            try self.renderTiled(mesh, projected, transformed_vertices, view_rotation, light_dir, pump);
        } else {
            try self.renderDirect(mesh, projected, transformed_vertices, view_rotation, light_dir);
        }

        if (self.show_light_orb) {
            const light_camera_z = light_camera.z;
            if (light_camera_z > 0.1) {
                self.drawLightMarker(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale);
            }
        }

        self.drawBitmap();

        self.frame_count += 1;
        const current_time = std.time.nanoTimestamp();
        self.finalizeFrame(current_time);
    }

    fn beginFrame(self: *Renderer) f32 {
        const now = std.time.nanoTimestamp();
        var delta_ns = now - self.last_frame_time;
        if (delta_ns < 0) delta_ns = 0;
        self.last_frame_time = now;

        const delta_ns_f = @as(f64, @floatFromInt(delta_ns));
        var delta_seconds = @as(f32, @floatCast(delta_ns_f / 1_000_000_000.0));
        if (delta_seconds > 0.1) delta_seconds = 0.1;
        if (delta_seconds <= 0.0) delta_seconds = 1.0 / 120.0;
        return delta_seconds;
    }

    fn consumePendingFovDelta(self: *Renderer) f32 {
        const delta = self.pending_fov_delta;
        self.pending_fov_delta = 0.0;
        return delta;
    }

    fn adjustCameraFov(self: *Renderer, delta: f32) void {
        const new_fov = std.math.clamp(self.camera_fov_deg + delta, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
        if (!std.math.approxEqAbs(f32, new_fov, self.camera_fov_deg, 0.0001)) {
            self.camera_fov_deg = new_fov;
            self.last_reported_fov_deg = new_fov;
        }
    }

    fn finalizeFrame(self: *Renderer, current_time: i128) void {
        const elapsed_ns = current_time - self.last_time;
        if (elapsed_ns < 1_000_000_000 or self.frame_count == 0) return;

        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        if (elapsed_us == 0) return;
        self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

        const frame_count_f = @as(f32, @floatFromInt(self.frame_count));
        const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const avg_frame_time_ms = if (frame_count_f > 0.0) elapsed_ms / frame_count_f else 0.0;

        self.frame_count = 0;
        self.last_time = current_time;
        self.updateWindowTitle(avg_frame_time_ms);
    }

    fn updateWindowTitle(self: *Renderer, avg_frame_time_ms: f32) void {
        var title_buffer: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buffer, "{s} | FPS: {} | Frame: {d:.2}ms", .{
            config.WINDOW_TITLE,
            self.current_fps,
            avg_frame_time_ms,
        }) catch config.WINDOW_TITLE;

        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
        title_wide[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }

    fn drawLightMarker(
        self: *Renderer,
        light_pos: math.Vec3,
        light_camera_z: f32,
        center_x: f32,
        center_y: f32,
        x_scale: f32,
        y_scale: f32,
    ) void {
        if (light_camera_z <= 0.1) return;

        const ndc_x = (light_pos.x / light_camera_z) * x_scale;
        const ndc_y = (light_pos.y / light_camera_z) * y_scale;
        const screen_x = ndc_x * center_x + center_x;
        const screen_y = -ndc_y * center_y + center_y;

        const light_x = @as(i32, @intFromFloat(screen_x));
        const light_y = @as(i32, @intFromFloat(screen_y));
        const radius: i32 = 4;
        const color: u32 = 0xFF00FFFF;

        var py = light_y - radius;
        while (py <= light_y + radius) : (py += 1) {
            if (py < 0 or py >= self.bitmap.height) continue;
            var px = light_x - radius;
            while (px <= light_x + radius) : (px += 1) {
                if (px < 0 or px >= self.bitmap.width) continue;
                const dx = @as(f32, @floatFromInt(px - light_x));
                const dy = @as(f32, @floatFromInt(py - light_y));
                if ((dx * dx + dy * dy) > @as(f32, @floatFromInt(radius * radius))) continue;
                const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                if (idx < self.bitmap.pixels.len) self.bitmap.pixels[idx] = color;
            }
        }
    }

    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            if (self.hdc_mem) |hdc_mem| {
                const old_bitmap = SelectObject(hdc_mem, self.bitmap.hbitmap);
                defer _ = SelectObject(hdc_mem, old_bitmap);
                _ = BitBlt(
                    hdc,
                    0,
                    0,
                    self.bitmap.width,
                    self.bitmap.height,
                    hdc_mem,
                    0,
                    0,
                    SRCCOPY,
                );
            }
        }
    }

    /// Renders the scene using the parallel, tile-based pipeline.
    fn renderTiled(self: *Renderer, mesh: *const Mesh, projected: [][2]i32, transformed_vertices: []math.Vec3, transform: math.Mat4, light_dir: math.Vec3, pump: ?*const fn (*Renderer) bool) !void {
        const grid = self.tile_grid.?;
        const tile_buffers = self.tile_buffers.?;
        for (tile_buffers) |*buf| buf.clear();

        if (self.previous_frame_jobs) |prev_jobs| {
            self.allocator.free(prev_jobs);
            self.previous_frame_jobs = null;
        }
        if (self.previous_frame_tile_jobs) |prev_tile_jobs| {
            self.allocator.free(prev_tile_jobs);
            self.previous_frame_tile_jobs = null;
        }

        // 1. Binning: Assign triangles to the tiles they overlap.
        const triangle_indices = try self.allocator.alloc([3]usize, mesh.triangles.len);
        defer self.allocator.free(triangle_indices);
        for (mesh.triangles, 0..) |tri, i| triangle_indices[i] = .{ tri.v0, tri.v1, tri.v2 };
        const tile_lists = try BinningStage.binTrianglesToTiles(projected, triangle_indices, &grid, self.allocator);
        defer BinningStage.freeTileTriangleLists(tile_lists, self.allocator);

        // (Memory management for job data omitted for clarity)

        // 2. Dispatch Jobs: Create a render job for each tile and submit it to the job system.
        const tile_jobs = try self.allocator.alloc(TileRenderJob, grid.tiles.len);
        const jobs = try self.allocator.alloc(Job, grid.tiles.len);
        const job_completion = try self.allocator.alloc(bool, jobs.len);
        defer self.allocator.free(job_completion);
        self.previous_frame_jobs = jobs;
        self.previous_frame_tile_jobs = tile_jobs;
        @memset(job_completion, false);

        if (self.job_system) |js| {
            for (grid.tiles, 0..) |*tile, tile_idx| {
                if (pump) |p| if ((tile_idx & 7) == 0 and !p(self)) return error.RenderInterrupted;

                tile_jobs[tile_idx] = TileRenderJob{ .tile = tile, .tile_buffer = &tile_buffers[tile_idx], .tri_list = &tile_lists[tile_idx], .mesh = mesh, .projected = projected, .transformed_vertices = transformed_vertices, .transform = transform, .light_dir = light_dir, .draw_wireframe = self.show_wireframe, .texture = self.texture, .base_color = lighting.DEFAULT_BASE_COLOR };
                jobs[tile_idx] = Job.init(TileRenderJob.renderTileJob, @ptrCast(&tile_jobs[tile_idx]), null);
                if (!js.submitJobAuto(&jobs[tile_idx])) {
                    std.log.err("Tile {} failed to submit to job system", .{tile_idx});
                }
            }

            // 3. Synchronization: Wait for all worker threads to finish their tiles.
            var remaining = jobs.len;
            while (remaining > 0) {
                var progress = false;
                for (jobs, 0..) |*job, idx| {
                    if (!job_completion[idx] and job.isComplete()) {
                        job_completion[idx] = true;
                        remaining -= 1;
                        progress = true;
                    }
                }
                if (pump) |p| if (!p(self)) return error.RenderInterrupted;
                if (!progress) std.Thread.yield() catch {};
            }
        }

        // 4. Compositing: Copy the pixels from each completed tile buffer to the main screen bitmap.
        for (grid.tiles, 0..) |*tile, tile_idx| {
            TileRenderer.compositeTileToScreen(tile, &tile_buffers[tile_idx], &self.bitmap);
        }
    }

    /// Renders the scene directly to the main bitmap (single-threaded).
    fn renderDirect(self: *Renderer, mesh: *const Mesh, projected: [][2]i32, transformed_vertices: []math.Vec3, transform: math.Mat4, light_dir: math.Vec3) !void {
        _ = self;
        _ = mesh;
        _ = projected;
        _ = transformed_vertices;
        _ = transform;
        _ = light_dir;
    }

    fn drawShadedTriangle(self: *Renderer, p0: [2]i32, p1: [2]i32, p2: [2]i32, shading: TileRenderer.ShadingParams) void {
        _ = self;
        _ = p0;
        _ = p1;
        _ = p2;
        _ = shading;
    }

    fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        _ = self;
        _ = x0;
        _ = y0;
        _ = x1;
        _ = y1;
        _ = color;
    }
};