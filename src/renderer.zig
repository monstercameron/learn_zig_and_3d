//! # Renderer Module
//!
//! This module handles all drawing operations.
//! It manages the connection between the bitmap (pixel buffer) and the window display.
//!
//! **Single Concern**: Converting bitmap data to screen display (blitting)
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Like canvas context operations
//! class Renderer {
//!   constructor(windowHandle, width, height) {
//!     this.windowDC = getDeviceContext(windowHandle);
//!     this.bitmap = new Bitmap(width, height);
//!   }
//!
//!   renderHelloWorld() {
//!     // Fill all pixels with blue
//!     for (let i = 0; i < this.bitmap.pixels.length; i++) {
//!       this.bitmap.pixels[i] = 0xFF0000FF; // BGRA format
//!     }
//!     this.drawBitmap(); // Copy to screen
//!   }
//!
//!   drawBitmap() {
//!     // Copy bitmap pixels to window: like canvas.drawImage()
//!     bitBlt(this.windowDC, this.memoryDC, ...);
//!   }
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;
const math = @import("math.zig");
const Mesh = @import("mesh.zig").Mesh;

// ========== TYPES ==========
/// HGDIOBJ - Handle to a GDI (Graphics Device Interface) object
/// In Windows, graphics resources (bitmaps, pens, brushes) are handles
/// Similar to DOM node IDs or file descriptors
const HGDIOBJ = *anyopaque;

// ========== CONSTANTS ==========
/// SRCCOPY - Raster operation: copy source directly to destination
/// There are other operations like AND, XOR, invert, etc.
/// We use SRCCOPY because we want a direct 1:1 copy (no blending)
const SRCCOPY = 0x00CC0020;

// ========== WINDOWS API DECLARATIONS ==========
/// Get a device context for a window
/// A DC is a "graphics surface" - the interface for drawing
/// Similar to canvas.getContext("2d") in JavaScript
extern "user32" fn GetDC(hWnd: windows.HWND) ?windows.HDC;

/// Release a device context (free resources)
extern "user32" fn ReleaseDC(hWnd: windows.HWND, hDC: windows.HDC) i32;

/// Create a device context compatible with another DC
/// This creates an "off-screen" drawing surface in memory
/// Like creating a canvas element for off-screen rendering
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;

/// Select a graphics object (bitmap, pen, brush) into a DC
/// This is like "use this bitmap" or "use this drawing tool"
/// Returns the previous object (so you can restore it)
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;

/// Bit Block Transfer - copy pixels from source to destination
/// This is the fundamental operation for drawing a bitmap to screen
/// Similar to ctx.drawImage() in JavaScript canvas
extern "gdi32" fn BitBlt(
    hdcDest: windows.HDC,
    nXDest: i32,
    nYDest: i32,
    nWidth: i32,
    nHeight: i32,
    hdcSrc: windows.HDC,
    nXSrc: i32,
    nYSrc: i32,
    dwRop: u32,
) bool;

/// Delete a device context and free its resources
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;

/// Set window text (title)
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;

/// Sleep for a given number of milliseconds
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// ========== MODULE IMPORTS ==========
/// Import the Bitmap module for pixel buffer management
const Bitmap = @import("bitmap.zig").Bitmap;
const TileRenderer = @import("tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("binning_stage.zig");
const JobSystem = @import("job_system.zig").JobSystem;
const Job = @import("job_system.zig").Job;
const JobFn = @import("job_system.zig").JobFn;

// ========== RENDERING CONSTANTS ==========
/// Initial light direction - will be modified by keyboard input
/// This is now a base, and the actual light is computed per frame
const INITIAL_LIGHT_DIR = math.Vec3.new(0.0, 0.0, -1.0); // Pointing toward -Z (into screen)

// ========== RENDERER STRUCT ==========
/// Manages rendering operations: converting bitmap data to screen display
/// Similar to a canvas context: ctx = canvas.getContext("2d")
pub const Renderer = struct {
    hwnd: windows.HWND, // Window handle - where we'll draw
    bitmap: Bitmap, // The pixel buffer we draw to
    hdc: ?windows.HDC, // Device context - the interface for drawing to the window
    hdc_mem: ?windows.HDC, // Cached memory device context (for faster blitting)
    allocator: std.mem.Allocator, // Memory allocator
    rotation_angle: f32, // Current rotation angle around Y axis
    rotation_x: f32, // Current rotation angle around X axis
    light_orbit_x: f32, // Light: orbit angle around X axis
    light_orbit_y: f32, // Light: orbit angle around Y axis
    light_distance: f32, // Distance of light from origin
    keys_pressed: u32, // Bitmask for currently pressed keys
    frame_count: u32, // Number of frames rendered
    last_time: i128, // Last time we calculated FPS (in nanoseconds)
    last_frame_time: i128, // Last time a frame was rendered (in nanoseconds)
    current_fps: u32, // Current FPS counter
    target_frame_time_ns: i128, // Target nanoseconds per frame (1_000_000_000 / 120)
    last_log_time: i128, // Last time we logged rotation/shading info
    last_brightness_min: f32, // Minimum brightness from last frame
    last_brightness_max: f32, // Maximum brightness from last frame
    last_brightness_avg: f32, // Average brightness from last frame
    tile_grid: ?TileGrid, // Tile grid for tile-based rendering (optional)
    tile_buffers: ?[]TileBuffer, // Per-tile rendering buffers
    show_tile_borders: bool, // Debug: show tile boundaries
    use_tiled_rendering: bool, // Enable tile-based rendering (vs direct to screen)
    job_system: ?*JobSystem, // Job system for parallel execution
    previous_frame_jobs: ?[]Job, // Keep previous frame's jobs alive to prevent use-after-free
    previous_frame_tile_jobs: ?[]TileRenderJob, // Keep tile job contexts alive too

    /// Initialize the renderer for a window
    /// Similar to: canvas = document.createElement("canvas"); ctx = canvas.getContext("2d")
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        // ===== STEP 1: Get window's device context =====
        // A DC is a "graphics interface" - like a canvas context
        // We'll use this to copy our bitmap to the screen
        const hdc = GetDC(hwnd);
        if (hdc == null) return error.DCNotFound;

        // ===== STEP 2: Create cached memory device context =====
        // Create this once and reuse it for all frames (much faster than recreating every frame)
        const hdc_mem = CreateCompatibleDC(hdc);
        if (hdc_mem == null) {
            _ = ReleaseDC(hwnd, hdc.?);
            return error.MemoryDCCreationFailed;
        }

        // ===== STEP 3: Create a bitmap =====
        // This allocates a pixel buffer (width × height × 4 bytes)
        const bitmap = try Bitmap.init(width, height);

        const current_time = std.time.nanoTimestamp();

        // Initialize tile grid for tile-based rendering
        const tile_grid = try TileGrid.init(width, height, allocator);

        // Allocate tile buffers (one per tile)
        const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
        for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
            buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
        }

        // Initialize job system for parallel rendering
        const job_system = try JobSystem.init(allocator);

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .hdc_mem = hdc_mem,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
            .light_orbit_x = 0.0,
            .light_orbit_y = 0.0,
            .light_distance = 3.0,
            .keys_pressed = 0,
            .frame_count = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .current_fps = 0,
            .target_frame_time_ns = 8_333_333, // 1_000_000_000 / 120 = 8.333ms in nanoseconds
            .last_log_time = current_time,
            .last_brightness_min = 0,
            .last_brightness_max = 0,
            .last_brightness_avg = 0,
            .tile_grid = tile_grid,
            .tile_buffers = tile_buffers,
            .show_tile_borders = true, // Enable by default for visualization
            .use_tiled_rendering = true, // Enable tile-based rendering
            .job_system = job_system,
            .previous_frame_jobs = null,
            .previous_frame_tile_jobs = null,
        };
    }

    /// Clean up renderer resources
    /// Called with 'defer renderer.deinit()' in main.zig
    pub fn deinit(self: *Renderer) void {
        // Shut down job system first
        if (self.job_system) |js| {
            js.deinit();
        }
        // Free any remaining previous frame jobs
        if (self.previous_frame_jobs) |jobs| {
            self.allocator.free(jobs);
        }
        if (self.tile_buffers) |buffers| {
            for (buffers) |*buf| {
                buf.deinit();
            }
            self.allocator.free(buffers);
        }
        if (self.tile_grid) |*grid| {
            grid.deinit();
        }
        if (self.hdc_mem) |hdc_mem| {
            _ = DeleteDC(hdc_mem);
        }
        if (self.hdc) |hdc| {
            _ = ReleaseDC(self.hwnd, hdc);
        }
        self.bitmap.deinit();
    }

    // ========== TILE RENDER JOB ==========

    /// Job context for rendering a single tile
    const TileRenderJob = struct {
        tile_idx: usize,
        tile: *const TileRenderer.Tile,
        tile_buffer: *TileBuffer,
        tri_list: *const BinningStage.TileTriangleList,
        mesh: *const Mesh,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        transform: math.Mat4,
        light_dir: math.Vec3,

        /// Job function that renders one tile
        fn renderTileJob(ctx: *anyopaque) void {
            const job: *TileRenderJob = @ptrCast(@alignCast(ctx));

            // Render triangles in this tile
            for (job.tri_list.triangles.items) |tri_idx| {
                const tri = job.mesh.triangles[tri_idx];

                // Skip if fill is culled
                if (tri.cull_flags.cull_fill) continue;

                const p0 = job.projected[tri.v0];
                const p1 = job.projected[tri.v1];
                const p2 = job.projected[tri.v2];

                // Check if triangle is completely off-screen
                if (p0[0] < -1000 or p1[0] < -1000 or p2[0] < -1000) continue;

                // Transform the face normal
                const normal = job.mesh.normals[tri_idx];
                const normal_transformed_raw = math.Vec3.new(
                    job.transform.data[0] * normal.x + job.transform.data[1] * normal.y + job.transform.data[2] * normal.z,
                    job.transform.data[4] * normal.x + job.transform.data[5] * normal.y + job.transform.data[6] * normal.z,
                    job.transform.data[8] * normal.x + job.transform.data[9] * normal.y + job.transform.data[10] * normal.z,
                );
                const normal_transformed = normal_transformed_raw.normalize();

                // Backface culling
                const p0_cam = job.transformed_vertices[tri.v0];
                const p1_cam = job.transformed_vertices[tri.v1];
                const p2_cam = job.transformed_vertices[tri.v2];

                const face_center_unscaled = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
                const face_center = math.Vec3.scale(face_center_unscaled, 1.0 / 3.0);

                const view_length = face_center.length();
                if (view_length <= 0.0001) continue;
                const view_vector = math.Vec3.scale(face_center, -1.0 / view_length);

                const camera_facing = normal_transformed.dot(view_vector);
                if (camera_facing <= 0.0) continue;

                // Calculate lighting
                var brightness = normal_transformed.dot(job.light_dir);
                if (brightness < 0.0) brightness = 0.0;
                if (brightness > 1.0) brightness = 1.0;

                // Convert brightness to color
                const r = @as(u32, @intFromFloat(brightness * 255)) << 16;
                const g = @as(u32, @intFromFloat(brightness * 200)) << 8;
                const b = @as(u32, @intFromFloat(brightness * 50));
                const shaded_color = 0xFF000000 | r | g | b;

                // Rasterize triangle to tile buffer
                TileRenderer.rasterizeTriangleToTile(job.tile, job.tile_buffer, p0, p1, p2, shaded_color);
            }

            // Draw wireframe for triangles in this tile
            for (job.tri_list.triangles.items) |tri_idx| {
                const tri = job.mesh.triangles[tri_idx];
                if (tri.cull_flags.cull_wireframe) continue;

                const p0 = job.projected[tri.v0];
                const p1 = job.projected[tri.v1];
                const p2 = job.projected[tri.v2];

                // Apply backface culling (same as filled)
                const normal = job.mesh.normals[tri_idx];
                const normal_transformed_raw = math.Vec3.new(
                    job.transform.data[0] * normal.x + job.transform.data[1] * normal.y + job.transform.data[2] * normal.z,
                    job.transform.data[4] * normal.x + job.transform.data[5] * normal.y + job.transform.data[6] * normal.z,
                    job.transform.data[8] * normal.x + job.transform.data[9] * normal.y + job.transform.data[10] * normal.z,
                );
                const normal_transformed = normal_transformed_raw.normalize();

                const p0_cam = job.transformed_vertices[tri.v0];
                const p1_cam = job.transformed_vertices[tri.v1];
                const p2_cam = job.transformed_vertices[tri.v2];

                const face_center_unscaled = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
                const face_center = math.Vec3.scale(face_center_unscaled, 1.0 / 3.0);

                const view_length = face_center.length();
                if (view_length <= 0.0001) continue;
                const view_vector = math.Vec3.scale(face_center, -1.0 / view_length);

                const camera_facing = normal_transformed.dot(view_vector);
                if (camera_facing <= 0.0) continue;

                // Draw wireframe edges
                TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p0, p1, 0xFFFFFFFF);
                TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p1, p2, 0xFFFFFFFF);
                TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p2, p0, 0xFFFFFFFF);
            }
        }
    };

    /// Calculate brightness statistics from the current frame
    fn calculateBrightnessStats(self: *Renderer) void {
        var min_brightness: f32 = 1.0;
        var max_brightness: f32 = 0.0;
        var sum_brightness: f32 = 0.0;
        var non_black_count: u32 = 0;

        for (self.bitmap.pixels) |pixel| {
            // Skip black pixels (background)
            if (pixel == 0xFF000000) continue;

            // Skip pure white (wireframe edges)
            if (pixel == 0xFFFFFFFF) continue;

            // Extract RGB components (BGRA format)
            const b = @as(f32, @floatFromInt((pixel >> 0) & 0xFF)) / 255.0;
            const g = @as(f32, @floatFromInt((pixel >> 8) & 0xFF)) / 255.0;
            const r = @as(f32, @floatFromInt((pixel >> 16) & 0xFF)) / 255.0;

            // Calculate perceived brightness as average of RGB
            const brightness = (r + g + b) / 3.0;

            if (brightness < min_brightness) min_brightness = brightness;
            if (brightness > max_brightness) max_brightness = brightness;
            sum_brightness += brightness;
            non_black_count += 1;
        }

        self.last_brightness_min = if (non_black_count > 0) min_brightness else 0;
        self.last_brightness_max = if (non_black_count > 0) max_brightness else 0;
        self.last_brightness_avg = if (non_black_count > 0) sum_brightness / @as(f32, @floatFromInt(non_black_count)) else 0;
    }
    pub fn handleKeyInput(self: *Renderer, key: u32, is_down: bool) void {
        const VK_LEFT = 0x25;
        const VK_RIGHT = 0x27;
        const VK_UP = 0x26;
        const VK_DOWN = 0x28;
        const VK_W = 0x57;
        const VK_A = 0x41;
        const VK_S = 0x53;
        const VK_D = 0x44;
        const VK_Q = 0x51;
        const VK_E = 0x45;
        const KEY_LEFT_BIT: u32 = 1;
        const KEY_RIGHT_BIT: u32 = 2;
        const KEY_UP_BIT: u32 = 4;
        const KEY_DOWN_BIT: u32 = 8;
        const KEY_W_BIT: u32 = 16;
        const KEY_A_BIT: u32 = 32;
        const KEY_S_BIT: u32 = 64;
        const KEY_D_BIT: u32 = 128;
        const KEY_Q_BIT: u32 = 256;
        const KEY_E_BIT: u32 = 512;

        if (key == VK_LEFT) {
            if (is_down) {
                self.keys_pressed |= KEY_LEFT_BIT;
            } else {
                self.keys_pressed &= ~KEY_LEFT_BIT;
            }
        } else if (key == VK_RIGHT) {
            if (is_down) {
                self.keys_pressed |= KEY_RIGHT_BIT;
            } else {
                self.keys_pressed &= ~KEY_RIGHT_BIT;
            }
        } else if (key == VK_UP) {
            if (is_down) {
                self.keys_pressed |= KEY_UP_BIT;
            } else {
                self.keys_pressed &= ~KEY_UP_BIT;
            }
        } else if (key == VK_DOWN) {
            if (is_down) {
                self.keys_pressed |= KEY_DOWN_BIT;
            } else {
                self.keys_pressed &= ~KEY_DOWN_BIT;
            }
        } else if (key == VK_W) {
            if (is_down) {
                self.keys_pressed |= KEY_W_BIT;
            } else {
                self.keys_pressed &= ~KEY_W_BIT;
            }
        } else if (key == VK_A) {
            if (is_down) {
                self.keys_pressed |= KEY_A_BIT;
            } else {
                self.keys_pressed &= ~KEY_A_BIT;
            }
        } else if (key == VK_S) {
            if (is_down) {
                self.keys_pressed |= KEY_S_BIT;
            } else {
                self.keys_pressed &= ~KEY_S_BIT;
            }
        } else if (key == VK_D) {
            if (is_down) {
                self.keys_pressed |= KEY_D_BIT;
            } else {
                self.keys_pressed &= ~KEY_D_BIT;
            }
        } else if (key == VK_Q) {
            if (is_down) {
                self.keys_pressed |= KEY_Q_BIT;
            } else {
                self.keys_pressed &= ~KEY_Q_BIT;
            }
        } else if (key == VK_E) {
            if (is_down) {
                self.keys_pressed |= KEY_E_BIT;
            } else {
                self.keys_pressed &= ~KEY_E_BIT;
            }
        }
    }

    /// Wait until it's time to render the next frame (frame rate limiting)
    /// Implements frame pacing to hit target FPS with nanosecond precision
    /// Target: 120 FPS = 8.333333ms per frame = 8_333_333ns per frame
    pub fn shouldRenderFrame(self: *Renderer) bool {
        const current_time = std.time.nanoTimestamp();
        const elapsed = current_time - self.last_frame_time;

        // Use exact nanosecond timing for precise 120 FPS
        // 1_000_000_000 ns / 120 fps = 8_333_333.333ns per frame
        // No need for patterns - nanoseconds give us the fractional timing naturally
        if (elapsed >= self.target_frame_time_ns) {
            self.last_frame_time = current_time;
            return true;
        }
        return false;
    }

    /// Render a 3D mesh with rotation and projection
    /// This demonstrates the full 3D pipeline:
    /// 1. Create transformation matrices (rotation)
    /// 2. Transform 3D vertices to world space
    /// 3. Project to 2D screen space
    /// 4. Rasterize filled triangles
    /// 5. Draw wireframe on top
    pub fn render3DMesh(self: *Renderer, mesh: *const Mesh) !void {
        try self.render3DMeshWithPump(mesh, null);
    }

    /// Render a 3D mesh with message pump callback for responsive input
    /// The pump function is called periodically during slow rendering
    pub fn render3DMeshWithPump(self: *Renderer, mesh: *const Mesh, pump: ?*const fn (*Renderer) bool) !void {
        // ===== STEP 1: Fill all pixels with black color =====
        // Use @memset for much faster clearing (CPU-optimized bulk fill)
        const black: u32 = 0xFF000000;
        @memset(self.bitmap.pixels, black);

        // ===== STEP 2: Update rotation based on currently pressed keys =====
        const KEY_LEFT_BIT: u32 = 1;
        const KEY_RIGHT_BIT: u32 = 2;
        const KEY_UP_BIT: u32 = 4;
        const KEY_DOWN_BIT: u32 = 8;
        const KEY_W_BIT: u32 = 16;
        const KEY_A_BIT: u32 = 32;
        const KEY_S_BIT: u32 = 64;
        const KEY_D_BIT: u32 = 128;
        const KEY_Q_BIT: u32 = 256;
        const KEY_E_BIT: u32 = 512;
        const rotation_speed = 0.02; // Radians per frame
        const auto_orbit_speed = 0.01; // Radians per frame for automatic light orbit

        if ((self.keys_pressed & KEY_LEFT_BIT) != 0) {
            self.rotation_angle -= rotation_speed;
        }
        if ((self.keys_pressed & KEY_RIGHT_BIT) != 0) {
            self.rotation_angle += rotation_speed;
        }
        if ((self.keys_pressed & KEY_UP_BIT) != 0) {
            self.rotation_x -= rotation_speed;
        }
        if ((self.keys_pressed & KEY_DOWN_BIT) != 0) {
            self.rotation_x += rotation_speed;
        }
        if ((self.keys_pressed & KEY_W_BIT) != 0) {
            self.light_orbit_x += rotation_speed;
        }
        if ((self.keys_pressed & KEY_S_BIT) != 0) {
            self.light_orbit_x -= rotation_speed;
        }
        if ((self.keys_pressed & KEY_A_BIT) != 0) {
            self.light_orbit_y -= rotation_speed;
        }
        if ((self.keys_pressed & KEY_D_BIT) != 0) {
            self.light_orbit_y += rotation_speed;
        }

        // Handle light distance adjustment with Q and E keys
        const distance_speed = 0.1; // Distance change per frame
        if ((self.keys_pressed & KEY_Q_BIT) != 0) {
            self.light_distance -= distance_speed;
            if (self.light_distance < 0.5) self.light_distance = 0.5; // Minimum distance
        }
        if ((self.keys_pressed & KEY_E_BIT) != 0) {
            self.light_distance += distance_speed;
            if (self.light_distance > 10.0) self.light_distance = 10.0; // Maximum distance
        }

        // Automatic light orbit: continuously rotate the light around the triangle on X axis only
        self.light_orbit_x += auto_orbit_speed;

        // ===== STEP 3: Compute light 1 position using orbit transform =====
        // Light 1 orbits around the triangle on X axis
        const light_orbit_x_mat = math.Mat4.rotateX(self.light_orbit_x);
        const light_orbit_y_mat = math.Mat4.rotateY(self.light_orbit_y);
        const light_orbit = math.Mat4.multiply(light_orbit_y_mat, light_orbit_x_mat);

        // Start with light at distance along +Z, then apply orbit transforms
        const light_base_pos = math.Vec3.new(0.0, 0.0, self.light_distance);
        const light_pos_4d = light_orbit.mulVec4(math.Vec4.from3D(light_base_pos));
        const light_pos = light_pos_4d.to3D();

        // Light 1 direction: from surface to light (for proper dot product with outward normals)
        const light_dir = light_pos.normalize();

        // ===== STEP 4: Create transformation matrices for mesh =====
        // Apply both Y-axis rotation (left/right) and X-axis rotation (up/down)
        const transform_y = math.Mat4.rotateY(self.rotation_angle);
        const transform_x = math.Mat4.rotateX(self.rotation_x);
        const transform = math.Mat4.multiply(transform_y, transform_x);

        // DEBUG: Print transform matrix and culling info once per second
        const current_time_ns = std.time.nanoTimestamp();
        const should_log_debug = (current_time_ns - self.last_log_time) >= 1_000_000_000; // 1 second in nanoseconds

        if (should_log_debug) {
            const orbit_x_deg = self.light_orbit_x * 180.0 / 3.14159265359;
            const orbit_y_deg = self.light_orbit_y * 180.0 / 3.14159265359;
            std.debug.print("Light: X={d:.2}° Y={d:.2}° Pos:({d:.2}, {d:.2}, {d:.2}) Dir:({d:.2}, {d:.2}, {d:.2})\n", .{ orbit_x_deg, orbit_y_deg, light_pos.x, light_pos.y, light_pos.z, light_dir.x, light_dir.y, light_dir.z });

            std.debug.print("\n=== TRANSFORM MATRIX ===\n", .{});
            std.debug.print("Rotation Y: {d:.4} rad ({d:.2}°), Rotation X: {d:.4} rad ({d:.2}°)\n", .{ self.rotation_angle, self.rotation_angle * 180.0 / 3.14159265359, self.rotation_x, self.rotation_x * 180.0 / 3.14159265359 });
            std.debug.print("Transform Matrix:\n", .{});
            std.debug.print("  [{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{ transform.data[0], transform.data[1], transform.data[2], transform.data[3] });
            std.debug.print("  [{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{ transform.data[4], transform.data[5], transform.data[6], transform.data[7] });
            std.debug.print("  [{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{ transform.data[8], transform.data[9], transform.data[10], transform.data[11] });
            std.debug.print("  [{d:.4} {d:.4} {d:.4} {d:.4}]\n", .{ transform.data[12], transform.data[13], transform.data[14], transform.data[15] });
            self.last_log_time = current_time_ns;
        }

        // ===== STEP 3: Transform and project vertices =====
        const projected = try self.allocator.alloc([2]i32, mesh.vertices.len);
        defer self.allocator.free(projected);

        const transformed_vertices = try self.allocator.alloc(math.Vec3, mesh.vertices.len);
        defer self.allocator.free(transformed_vertices);

        const center_x = @as(f32, @floatFromInt(self.bitmap.width)) / 2.0;
        const center_y = @as(f32, @floatFromInt(self.bitmap.height)) / 2.0;
        const z_offset = 4.0; // Push mesh forward so the camera sits at the origin

        for (mesh.vertices, 0..) |vertex, i| {
            // Transform vertex by rotation
            const rotated = transform.mulVec3(vertex);
            const transformed = math.Vec3.new(rotated.x, rotated.y, rotated.z + z_offset);
            transformed_vertices[i] = transformed;

            const camera_z = transformed.z;

            // Avoid division by zero or negative z
            if (camera_z <= 0.1) {
                // Behind camera or too close - place off screen
                projected[i][0] = -1000;
                projected[i][1] = -1000;
                continue;
            }

            // Perspective projection: divide by depth for perspective effect
            const fov = 400.0; // Scale factor for field of view (larger = zoomed out)
            const screen_x = (transformed.x / camera_z) * fov + center_x;
            const screen_y = -(transformed.y / camera_z) * fov + center_y; // Negate Y because screen Y increases downward

            projected[i][0] = @as(i32, @intFromFloat(screen_x));
            projected[i][1] = @as(i32, @intFromFloat(screen_y));
        }

        // ===== STEP 4: Draw filled triangles (flat shaded) =====
        // Use flat shading based on face normals and light direction

        if (should_log_debug) {
            std.debug.print("\n=== TRIANGLE CULLING STATUS ===\n", .{});
        }

        // Choose rendering path: tiled or direct
        if (self.use_tiled_rendering and self.tile_grid != null and self.tile_buffers != null) {
            try self.renderTiled(mesh, projected, transformed_vertices, transform, light_dir, should_log_debug, pump);
        } else {
            // Direct rendering to screen buffer (original method)
            try self.renderDirect(mesh, projected, transformed_vertices, transform, light_dir, light_pos, z_offset, center_x, center_y, should_log_debug);
        }

        // ===== STEP 5.5: Project and draw light position as a cyan sphere =====
        // Project the light position to screen space
        const light_camera_z = light_pos.z + z_offset;
        if (light_camera_z > 0.1) {
            const fov = 400.0;
            const light_screen_x = (light_pos.x / light_camera_z) * fov + center_x;
            const light_screen_y = -(light_pos.y / light_camera_z) * fov + center_y;

            const light_x = @as(i32, @intFromFloat(light_screen_x));
            const light_y = @as(i32, @intFromFloat(light_screen_y));

            // Draw a small circle (radius 5 pixels) in bright cyan to represent light 1
            const light_radius: i32 = 5;
            const light_color = 0xFF00FFFF; // Cyan: ARGB format

            var py = light_y - light_radius;
            while (py <= light_y + light_radius) : (py += 1) {
                if (py < 0 or py >= @as(i32, @intCast(self.bitmap.height))) continue;
                var px = light_x - light_radius;
                while (px <= light_x + light_radius) : (px += 1) {
                    if (px < 0 or px >= @as(i32, @intCast(self.bitmap.width))) continue;

                    const dx = @as(f32, @floatFromInt(px)) - @as(f32, @floatFromInt(light_x));
                    const dy = @as(f32, @floatFromInt(py)) - @as(f32, @floatFromInt(light_y));
                    const dist = @sqrt(dx * dx + dy * dy);

                    if (dist <= @as(f32, @floatFromInt(light_radius))) {
                        const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                        if (idx < self.bitmap.pixels.len) {
                            self.bitmap.pixels[idx] = light_color;
                        }
                    }
                }
            }
        }

        // ===== STEP 6: Copy bitmap to screen =====
        self.drawBitmap();

        // ===== STEP 7: Calculate brightness statistics from rendered frame =====
        self.calculateBrightnessStats();

        // ===== STEP 8: Update FPS counter and log =====
        self.frame_count += 1;
        const current_time = std.time.nanoTimestamp();
        const elapsed_ns = current_time - self.last_time;

        // Update FPS every 1 second (1_000_000_000 nanoseconds)
        if (elapsed_ns >= 1_000_000_000) {
            // Calculate FPS: frames * 1_000_000_000 ns/s / elapsed nanoseconds
            const elapsed_us = @divTrunc(elapsed_ns, 1000); // Convert to microseconds
            self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

            // Calculate average frame time BEFORE resetting frame_count
            const frame_count_f = @as(f32, @floatFromInt(self.frame_count));
            const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            const avg_frame_time_ms = elapsed_ms / frame_count_f;

            self.frame_count = 0;
            self.last_time = current_time;

            // Log rotation angle and shading information
            const rotation_degrees = self.rotation_angle * 180.0 / 3.14159265359;
            const light_orbit_x_degrees = self.light_orbit_x * 180.0 / 3.14159265359;
            const light_orbit_y_degrees = self.light_orbit_y * 180.0 / 3.14159265359;
            const sample_r = @as(u32, @intFromFloat(self.last_brightness_avg * 255));
            const sample_g = @as(u32, @intFromFloat(self.last_brightness_avg * 200));
            const sample_b = @as(u32, @intFromFloat(self.last_brightness_avg * 50));

            std.debug.print("Rotation: {d:.2}° | Light Orbit: X={d:.2}° Y={d:.2}° | Brightness: min={d:.2} avg={d:.2} max={d:.2} | Sample RGB: ({}, {}, {}) | FPS: {}\n", .{ rotation_degrees, light_orbit_x_degrees, light_orbit_y_degrees, self.last_brightness_min, self.last_brightness_avg, self.last_brightness_max, sample_r, sample_g, sample_b, self.current_fps });

            // Update window title with FPS info
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "Zig 3D CPU Rasterizer | FPS: {} | Frame: {d:.2}ms", .{ self.current_fps, avg_frame_time_ms }) catch "Zig 3D CPU Rasterizer";

            var title_wide: [256:0]u16 = undefined;
            const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
            title_wide[title_len] = 0;
            _ = SetWindowTextW(self.hwnd, &title_wide);
        }
    }

    /// Render using tile-based method (new, for parallelization)
    fn renderTiled(
        self: *Renderer,
        mesh: *const Mesh,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        transform: math.Mat4,
        light_dir: math.Vec3,
        should_log_debug: bool,
        pump: ?*const fn (*Renderer) bool,
    ) !void {
        // Get tile grid and buffers
        const grid = &(self.tile_grid.?);
        const tile_buffers = self.tile_buffers.?;

        // Clear all tile buffers
        for (tile_buffers) |*buf| {
            buf.clear();
        }

        // Bin triangles to tiles
        const triangle_indices = try self.allocator.alloc([3]usize, mesh.triangles.len);
        defer self.allocator.free(triangle_indices);

        for (mesh.triangles, 0..) |tri, i| {
            triangle_indices[i] = [3]usize{ tri.v0, tri.v1, tri.v2 };
        }

        const tile_lists = try BinningStage.binTrianglesToTiles(
            projected,
            triangle_indices,
            grid,
            self.allocator,
        );
        defer BinningStage.freeTileTriangleLists(tile_lists, self.allocator);

        // Free previous frame's job data now (they're definitely not in use anymore)
        if (self.previous_frame_jobs) |old_jobs| {
            self.allocator.free(old_jobs);
            self.previous_frame_jobs = null;
        }
        if (self.previous_frame_tile_jobs) |old_tile_jobs| {
            self.allocator.free(old_tile_jobs);
            self.previous_frame_tile_jobs = null;
        }

        // Create job contexts for each tile
        const tile_jobs = try self.allocator.alloc(TileRenderJob, grid.tiles.len);
        // Don't defer free - tile_jobs must survive until next frame

        const jobs = try self.allocator.alloc(Job, grid.tiles.len);
        // Don't defer free - save for next frame to prevent use-after-free

        // Check if job system is available
        if (self.job_system) |js| {
            // Dispatch all tiles as parallel jobs
            if (should_log_debug) {
                std.debug.print("Dispatching {} tile jobs to workers...\n", .{grid.tiles.len});
            }
            for (grid.tiles, 0..) |*tile, tile_idx| {
                const tile_buffer = &tile_buffers[tile_idx];
                const tri_list = &tile_lists[tile_idx];

                // Set up job context for this tile
                tile_jobs[tile_idx] = TileRenderJob{
                    .tile_idx = tile_idx,
                    .tile = tile,
                    .tile_buffer = tile_buffer,
                    .tri_list = tri_list,
                    .mesh = mesh,
                    .projected = projected,
                    .transformed_vertices = transformed_vertices,
                    .transform = transform,
                    .light_dir = light_dir,
                };

                // Create job for this tile (no parent job)
                jobs[tile_idx] = Job.init(
                    TileRenderJob.renderTileJob,
                    @ptrCast(&tile_jobs[tile_idx]),
                    null,
                );

                // Submit job to worker threads
                const submitted = js.submitJobAuto(&jobs[tile_idx]);
                if (!submitted) {
                    std.debug.print("ERROR: Failed to submit job for tile {}\n", .{tile_idx});
                }
            }

            // Wait for all tiles to complete
            if (should_log_debug) {
                std.debug.print("Waiting for {} jobs to complete...\n", .{jobs.len});
            }
            for (jobs, 0..) |*job, i| {
                if (should_log_debug and i < 3) {
                    std.debug.print("Waiting for job {}... (complete={})\n", .{ i, job.isComplete() });
                }
                job.wait();
                if (should_log_debug and i < 3) {
                    std.debug.print("Job {} completed\n", .{i});
                }
            }
            if (should_log_debug) {
                std.debug.print("All jobs complete\n", .{});
            }

            // Save jobs and tile_jobs for next frame - don't free yet to prevent use-after-free
            // Workers might still have references even after jobs complete
            self.previous_frame_jobs = jobs;
            self.previous_frame_tile_jobs = tile_jobs;
        } else {
            std.debug.print("ERROR: Job system not initialized!\n", .{});
            // If no job system, clean up allocated memory immediately
            self.allocator.free(jobs);
            self.allocator.free(tile_jobs);
            return;
        }

        // Composite all tiles to screen after parallel rendering
        for (grid.tiles, 0..) |*tile, tile_idx| {
            const tile_buffer = &tile_buffers[tile_idx];
            TileRenderer.compositeTileToScreen(tile, tile_buffer, &self.bitmap);
        }

        // Process messages if pump callback provided
        if (pump) |pump_fn| {
            _ = pump_fn(self);
        }
    }

    /// Render using direct method (original, for comparison)
    fn renderDirect(
        self: *Renderer,
        mesh: *const Mesh,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        transform: math.Mat4,
        light_dir: math.Vec3,
        light_pos: math.Vec3,
        z_offset: f32,
        center_x: f32,
        center_y: f32,
        should_log_debug: bool,
    ) !void {
        for (mesh.triangles, 0..) |tri, tri_idx| {
            // Skip if fill is culled
            if (tri.cull_flags.cull_fill) {
                if (should_log_debug) {
                    std.debug.print("Triangle {}: CULLED (cull_fill flag set)\n", .{tri_idx});
                }
                continue;
            }

            const p0 = projected[tri.v0];
            const p1 = projected[tri.v1];
            const p2 = projected[tri.v2];

            // Check if triangle is completely off-screen
            if (p0[0] < -1000 or p1[0] < -1000 or p2[0] < -1000) {
                if (should_log_debug) {
                    std.debug.print("Triangle {}: CULLED (off-screen)\n", .{tri_idx});
                }
                continue;
            }

            // Transform the face normal using ONLY rotation (w=0 prevents translation)
            // We manually multiply by rotation part of matrix
            const normal = mesh.normals[tri_idx];
            const normal_transformed_raw = math.Vec3.new(
                transform.data[0] * normal.x + transform.data[1] * normal.y + transform.data[2] * normal.z,
                transform.data[4] * normal.x + transform.data[5] * normal.y + transform.data[6] * normal.z,
                transform.data[8] * normal.x + transform.data[9] * normal.y + transform.data[10] * normal.z,
            );
            const normal_transformed = normal_transformed_raw.normalize();

            // Use the triangle center in camera space to decide if it faces the viewer
            const p0_cam = transformed_vertices[tri.v0];
            const p1_cam = transformed_vertices[tri.v1];
            const p2_cam = transformed_vertices[tri.v2];

            const face_center_unscaled = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
            const face_center = math.Vec3.scale(face_center_unscaled, 1.0 / 3.0);

            const view_length = face_center.length();
            if (view_length <= 0.0001) {
                if (should_log_debug) {
                    std.debug.print("Triangle {}: CULLED (view length too small)\n", .{tri_idx});
                }
                continue;
            }
            const view_vector = math.Vec3.scale(face_center, -1.0 / view_length);

            const camera_facing = normal_transformed.dot(view_vector);
            if (camera_facing <= 0.0) {
                if (should_log_debug) {
                    std.debug.print("Triangle {}: CULLED (backface: dot={d:.4})\n", .{ tri_idx, camera_facing });
                }
                continue;
            }

            if (should_log_debug) {
                std.debug.print("Triangle {}: RENDERED (frontface: dot={d:.4}, normal=({d:.4}, {d:.4}, {d:.4}))\n", .{ tri_idx, camera_facing, normal_transformed.x, normal_transformed.y, normal_transformed.z });
            }

            // Calculate lighting from light
            var brightness = normal_transformed.dot(light_dir);

            // Clamp to 0-1 range
            if (brightness < 0.0) brightness = 0.0;
            if (brightness > 1.0) brightness = 1.0;

            // Convert brightness to color (yellow-orange gradient for high contrast)
            const r = @as(u32, @intFromFloat(brightness * 255)) << 16;
            const g = @as(u32, @intFromFloat(brightness * 200)) << 8;
            const b = @as(u32, @intFromFloat(brightness * 50));
            const shaded_color = 0xFF000000 | r | g | b;

            self.drawFilledTriangle(p0[0], p0[1], p1[0], p1[1], p2[0], p2[1], shaded_color);
        }

        // ===== STEP 5: Draw wireframe edges on top (white lines) =====
        for (mesh.triangles, 0..) |tri, tri_idx| {
            // Skip if wireframe is culled
            if (tri.cull_flags.cull_wireframe) {
                continue;
            }

            // Apply the same backface culling as filled triangles
            const normal = mesh.normals[tri_idx];
            const normal_transformed_raw = math.Vec3.new(
                transform.data[0] * normal.x + transform.data[1] * normal.y + transform.data[2] * normal.z,
                transform.data[4] * normal.x + transform.data[5] * normal.y + transform.data[6] * normal.z,
                transform.data[8] * normal.x + transform.data[9] * normal.y + transform.data[10] * normal.z,
            );
            const normal_transformed = normal_transformed_raw.normalize();

            const p0_cam = transformed_vertices[tri.v0];
            const p1_cam = transformed_vertices[tri.v1];
            const p2_cam = transformed_vertices[tri.v2];

            const face_center_unscaled = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
            const face_center = math.Vec3.scale(face_center_unscaled, 1.0 / 3.0);

            const view_length = face_center.length();
            if (view_length <= 0.0001) {
                continue;
            }
            const view_vector = math.Vec3.scale(face_center, -1.0 / view_length);

            const camera_facing = normal_transformed.dot(view_vector);
            if (camera_facing <= 0.0) {
                continue; // Skip back-facing wireframes
            }

            const p0 = projected[tri.v0];
            const p1 = projected[tri.v1];
            const p2 = projected[tri.v2];

            // Draw three edges of the triangle with white color
            self.drawLineColored(p0[0], p0[1], p1[0], p1[1], 0xFFFFFFFF);
            self.drawLineColored(p1[0], p1[1], p2[0], p2[1], 0xFFFFFFFF);
            self.drawLineColored(p2[0], p2[1], p0[0], p0[1], 0xFFFFFFFF);
        }

        // ===== STEP 5.5: Project and draw light position as a cyan sphere =====
        // Project the light position to screen space
        const light_camera_z = light_pos.z + z_offset;
        if (light_camera_z > 0.1) {
            const fov = 400.0;
            const light_screen_x = (light_pos.x / light_camera_z) * fov + center_x;
            const light_screen_y = -(light_pos.y / light_camera_z) * fov + center_y;

            const light_x = @as(i32, @intFromFloat(light_screen_x));
            const light_y = @as(i32, @intFromFloat(light_screen_y));

            // Draw a small circle (radius 5 pixels) in bright cyan to represent light 1
            const light_radius: i32 = 5;
            const light_color = 0xFF00FFFF; // Cyan: ARGB format

            var py = light_y - light_radius;
            while (py <= light_y + light_radius) : (py += 1) {
                if (py < 0 or py >= @as(i32, @intCast(self.bitmap.height))) continue;
                var px = light_x - light_radius;
                while (px <= light_x + light_radius) : (px += 1) {
                    if (px < 0 or px >= @as(i32, @intCast(self.bitmap.width))) continue;

                    const dx = @as(f32, @floatFromInt(px)) - @as(f32, @floatFromInt(light_x));
                    const dy = @as(f32, @floatFromInt(py)) - @as(f32, @floatFromInt(light_y));
                    const dist = @sqrt(dx * dx + dy * dy);

                    if (dist <= @as(f32, @floatFromInt(light_radius))) {
                        const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                        if (idx < self.bitmap.pixels.len) {
                            self.bitmap.pixels[idx] = light_color;
                        }
                    }
                }
            }
        }

        // ===== STEP 6: Copy bitmap to screen =====
        self.drawBitmap();

        // ===== STEP 7: Calculate brightness statistics from rendered frame =====
        self.calculateBrightnessStats();

        // ===== STEP 8: Update FPS counter and log =====
        self.frame_count += 1;
        const current_time = std.time.nanoTimestamp();
        const elapsed_ns = current_time - self.last_time;

        // Update FPS every 1 second (1_000_000_000 nanoseconds)
        if (elapsed_ns >= 1_000_000_000) {
            // Calculate FPS: frames * 1_000_000_000 ns/s / elapsed nanoseconds
            const elapsed_us = @divTrunc(elapsed_ns, 1000); // Convert to microseconds
            self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

            // Calculate average frame time BEFORE resetting frame_count
            const frame_count_f = @as(f32, @floatFromInt(self.frame_count));
            const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            const avg_frame_time_ms = elapsed_ms / frame_count_f;

            self.frame_count = 0;
            self.last_time = current_time;

            // Log rotation angle and shading information
            const rotation_degrees = self.rotation_angle * 180.0 / 3.14159265359;
            const light_orbit_x_degrees = self.light_orbit_x * 180.0 / 3.14159265359;
            const light_orbit_y_degrees = self.light_orbit_y * 180.0 / 3.14159265359;
            const sample_r = @as(u32, @intFromFloat(self.last_brightness_avg * 255));
            const sample_g = @as(u32, @intFromFloat(self.last_brightness_avg * 200));
            const sample_b = @as(u32, @intFromFloat(self.last_brightness_avg * 50));

            std.debug.print("Rotation: {d:.2}° | Light Orbit: X={d:.2}° Y={d:.2}° | Brightness: min={d:.2} avg={d:.2} max={d:.2} | Sample RGB: ({}, {}, {}) | FPS: {}\n", .{ rotation_degrees, light_orbit_x_degrees, light_orbit_y_degrees, self.last_brightness_min, self.last_brightness_avg, self.last_brightness_max, sample_r, sample_g, sample_b, self.current_fps });

            // Update window title with FPS info
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "Zig 3D CPU Rasterizer | FPS: {} | Frame: {d:.2}ms", .{ self.current_fps, avg_frame_time_ms }) catch "Zig 3D CPU Rasterizer";

            var title_wide: [256:0]u16 = undefined;
            const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
            title_wide[title_len] = 0;
            _ = SetWindowTextW(self.hwnd, &title_wide);
        }
    }

    /// Render initial "Hello World" - fills screen with black color
    /// This demonstrates both pixel manipulation and blitting to screen
    pub fn renderHelloWorld(self: *Renderer) void {
        // ===== STEP 1: Fill all pixels with black color =====
        // Color format: 0xAARRGGBB (Alpha, Red, Green, Blue)
        // 0xFF000000 = opaque (FF) + no red (00) + no green (00) + no blue (00) = black
        // In BGRA format (used by Windows): it becomes black
        const black: u32 = 0xFF000000;

        // Loop through every pixel and set it to black
        // Similar to JavaScript: pixels.fill(0xFF000000)
        for (self.bitmap.pixels) |*pixel| {
            pixel.* = black;
        }

        // ===== STEP 2: Draw a red triangle wireframe =====
        // Triangle vertices: top center, bottom-left, bottom-right
        const width = self.bitmap.width;
        const height = self.bitmap.height;

        // Triangle corners
        const top_x = @divTrunc(width, 2);
        const top_y = @divTrunc(height, 4);
        const left_x = @divTrunc(width, 4);
        const left_y = @divTrunc(3 * height, 4);
        const right_x = @divTrunc(3 * width, 4);
        const right_y = @divTrunc(3 * height, 4);

        // Draw the three edges as lines
        // This is similar to: canvas.strokeStyle = "#FF0000"; canvas.strokeRect()
        self.drawLine(top_x, top_y, left_x, left_y); // Top-left edge
        self.drawLine(left_x, left_y, right_x, right_y); // Bottom edge
        self.drawLine(right_x, right_y, top_x, top_y); // Right edge

        // ===== STEP 3: Copy bitmap to screen =====
        // Now that we've filled the bitmap, draw it to the window
        self.drawBitmap();
    }

    /// Draw a line between two points using Bresenham's line algorithm with custom color
    /// This is the fundamental algorithm for drawing lines on a raster display
    fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        var x = x0;
        var y = y0;

        const dx = if (x0 < x1) x1 - x0 else x0 - x1;
        const dy = if (y0 < y1) y1 - y0 else y0 - y1;

        const sx = if (x0 < x1) @as(i32, 1) else @as(i32, -1);
        const sy = if (y0 < y1) @as(i32, 1) else @as(i32, -1);

        var err = dx - dy;

        while (true) {
            // Plot current pixel if within bounds
            if (x >= 0 and x < self.bitmap.width and y >= 0 and y < self.bitmap.height) {
                const pixel_index = @as(usize, @intCast(y * self.bitmap.width + x));
                if (pixel_index < self.bitmap.pixels.len) {
                    self.bitmap.pixels[pixel_index] = color;
                }
            }

            // Check if we've reached the endpoint
            if (x == x1 and y == y1) break;

            // Bresenham error term stepping
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    /// Draw a line between two points using Bresenham's line algorithm
    /// This is the fundamental algorithm for drawing lines on a raster display
    ///
    /// **How it works**:
    /// - Determine the major axis (dx vs dy)
    /// - Calculate the error term that determines when to step in the minor axis
    /// - Step along the major axis, using the error term to decide minor axis steps
    ///
    /// **JavaScript Equivalent**:
    /// ```javascript
    /// function drawLine(x0, y0, x1, y1) {
    ///   const dx = Math.abs(x1 - x0);
    ///   const dy = Math.abs(y1 - y0);
    ///   let err = dx - dy;
    ///   let x = x0, y = y0;
    ///   const sx = x0 < x1 ? 1 : -1;
    ///   const sy = y0 < y1 ? 1 : -1;
    ///
    ///   while (true) {
    ///     setPixel(x, y, RED);
    ///     if (x === x1 && y === y1) break;
    ///     const e2 = 2 * err;
    ///     if (e2 > -dy) { err -= dy; x += sx; }
    ///     if (e2 <  dx) { err += dx; y += sy; }
    ///   }
    /// }
    /// ```
    fn drawLine(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32) void {
        self.drawLineColored(x0, y0, x1, y1, 0xFFFFFFFF); // White by default
    }

    /// Draw a filled triangle using scanline rasterization
    /// This is a fundamental graphics algorithm
    fn drawFilledTriangle(self: *Renderer, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color: u32) void {
        // Clamp vertices to screen bounds + margin for partial triangles
        const margin = 50;
        const x1_clamped = std.math.clamp(x1, -margin, self.bitmap.width + margin);
        const y1_clamped = std.math.clamp(y1, -margin, self.bitmap.height + margin);
        const x2_clamped = std.math.clamp(x2, -margin, self.bitmap.width + margin);
        const y2_clamped = std.math.clamp(y2, -margin, self.bitmap.height + margin);
        const x3_clamped = std.math.clamp(x3, -margin, self.bitmap.width + margin);
        const y3_clamped = std.math.clamp(y3, -margin, self.bitmap.height + margin);

        // Sort vertices by Y coordinate (top to bottom)
        var v = [3][2]i32{ .{ x1_clamped, y1_clamped }, .{ x2_clamped, y2_clamped }, .{ x3_clamped, y3_clamped } };

        // Bubble sort by Y
        if (v[0][1] > v[1][1]) {
            const temp = v[0];
            v[0] = v[1];
            v[1] = temp;
        }
        if (v[1][1] > v[2][1]) {
            const temp = v[1];
            v[1] = v[2];
            v[2] = temp;
        }
        if (v[0][1] > v[1][1]) {
            const temp = v[0];
            v[0] = v[1];
            v[1] = temp;
        }

        const top_x = v[0][0];
        const top_y = v[0][1];
        const mid_x = v[1][0];
        const mid_y = v[1][1];
        const bot_x = v[2][0];
        const bot_y = v[2][1];

        // Skip degenerate triangles (all points on same line)
        if (top_y == mid_y and mid_y == bot_y) return;

        // Draw upper half (from top to middle)
        if (top_y < mid_y) {
            var y = top_y;
            while (y <= mid_y) : (y += 1) {
                if (y >= 0 and y < self.bitmap.height) {
                    const x_left_edge = self.lineIntersectionX(top_x, top_y, mid_x, mid_y, y);
                    const x_right_edge = self.lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

                    var x_left = minI32(x_left_edge, x_right_edge);
                    var x_right = maxI32(x_left_edge, x_right_edge);

                    x_left = maxI32(x_left, 0);
                    x_right = minI32(x_right, self.bitmap.width - 1);

                    if (x_left <= x_right) {
                        var x = x_left;
                        while (x <= x_right) : (x += 1) {
                            const pixel_index = @as(usize, @intCast(y * self.bitmap.width + x));
                            if (pixel_index < self.bitmap.pixels.len) {
                                self.bitmap.pixels[pixel_index] = color;
                            }
                        }
                    }
                }
            }
        }

        // Draw lower half (from middle to bottom)
        if (mid_y < bot_y) {
            var y = mid_y;
            while (y <= bot_y) : (y += 1) {
                if (y >= 0 and y < self.bitmap.height) {
                    const x_left_edge = self.lineIntersectionX(mid_x, mid_y, bot_x, bot_y, y);
                    const x_right_edge = self.lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

                    var x_left = minI32(x_left_edge, x_right_edge);
                    var x_right = maxI32(x_left_edge, x_right_edge);

                    x_left = maxI32(x_left, 0);
                    x_right = minI32(x_right, self.bitmap.width - 1);

                    if (x_left <= x_right) {
                        var x = x_left;
                        while (x <= x_right) : (x += 1) {
                            const pixel_index = @as(usize, @intCast(y * self.bitmap.width + x));
                            if (pixel_index < self.bitmap.pixels.len) {
                                self.bitmap.pixels[pixel_index] = color;
                            }
                        }
                    }
                }
            }
        }
    }
    /// This is a fundamental graphics algorithm
    ///
    /// **How it works**:
    /// - Sort vertices by Y coordinate (top to bottom)
    /// - Draw upper triangle (flat bottom) from top to middle
    /// - Draw lower triangle (flat top) from middle to bottom
    /// - For each scanline, find exact left and right edges
    ///
    /// **JavaScript Equivalent**:
    /// ```javascript
    /// function drawTriangle(x1, y1, x2, y2, x3, y3) {
    ///   // Sort vertices by y
    ///   const verts = sortByY([{x:x1,y:y1}, {x:x2,y:y2}, {x:x3,y:y3}]);
    ///   const [top, mid, bot] = verts;
    ///
    ///   // Upper half: edges are (top->mid) and (top->bot)
    ///   for (let y = top.y; y <= mid.y; y++) {
    ///     const xL = interpolateX(top, mid, y);
    ///     const xR = interpolateX(top, bot, y);
    ///     fillScanline(y, Math.min(xL,xR), Math.max(xL,xR));
    ///   }
    ///   // Lower half: edges are (mid->bot) and (top->bot)
    ///   for (let y = mid.y; y <= bot.y; y++) {
    ///     const xL = interpolateX(mid, bot, y);
    ///     const xR = interpolateX(top, bot, y);
    ///     fillScanline(y, Math.min(xL,xR), Math.max(xL,xR));
    ///   }
    /// }
    /// ```
    fn drawTriangle(self: *Renderer, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32) void {
        // Red color in BGRA format
        const red: u32 = 0xFFFF0000;

        // Sort vertices by Y coordinate (top to bottom)
        var v = [3][2]i32{ .{ x1, y1 }, .{ x2, y2 }, .{ x3, y3 } };

        // Bubble sort by Y
        if (v[0][1] > v[1][1]) {
            const temp = v[0];
            v[0] = v[1];
            v[1] = temp;
        }
        if (v[1][1] > v[2][1]) {
            const temp = v[1];
            v[1] = v[2];
            v[2] = temp;
        }
        if (v[0][1] > v[1][1]) {
            const temp = v[0];
            v[0] = v[1];
            v[1] = temp;
        }

        const top_x = v[0][0];
        const top_y = v[0][1];
        const mid_x = v[1][0];
        const mid_y = v[1][1];
        const bot_x = v[2][0];
        const bot_y = v[2][1];

        // Draw upper half (from top to middle)
        var y = top_y;
        while (y <= mid_y) : (y += 1) {
            if (y < 0 or y >= self.bitmap.height) continue;

            const x_left_edge = self.lineIntersectionX(top_x, top_y, mid_x, mid_y, y);
            const x_right_edge = self.lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

            var x_left = minI32(x_left_edge, x_right_edge);
            var x_right = maxI32(x_left_edge, x_right_edge);

            x_left = maxI32(x_left, 0);
            x_right = minI32(x_right, self.bitmap.width - 1);

            var x = x_left;
            while (x <= x_right) : (x += 1) {
                const pixel_index = @as(usize, @intCast(y * self.bitmap.width + x));
                if (pixel_index < self.bitmap.pixels.len) {
                    self.bitmap.pixels[pixel_index] = red;
                }
            }
        }

        // Draw lower half (from middle to bottom)
        y = mid_y;
        while (y <= bot_y) : (y += 1) {
            if (y < 0 or y >= self.bitmap.height) continue;

            const x_left_edge = self.lineIntersectionX(mid_x, mid_y, bot_x, bot_y, y);
            const x_right_edge = self.lineIntersectionX(top_x, top_y, bot_x, bot_y, y);

            var x_left = minI32(x_left_edge, x_right_edge);
            var x_right = maxI32(x_left_edge, x_right_edge);

            x_left = maxI32(x_left, 0);
            x_right = minI32(x_right, self.bitmap.width - 1);

            var x = x_left;
            while (x <= x_right) : (x += 1) {
                const pixel_index = @as(usize, @intCast(y * self.bitmap.width + x));
                if (pixel_index < self.bitmap.pixels.len) {
                    self.bitmap.pixels[pixel_index] = red;
                }
            }
        }
    }

    /// Helper: return the minimum of two i32 values
    fn minI32(a: i32, b: i32) i32 {
        return if (a < b) a else b;
    }

    /// Helper: return the maximum of two i32 values
    fn maxI32(a: i32, b: i32) i32 {
        return if (a > b) a else b;
    }

    /// Calculate where a line segment intersects a horizontal scanline
    /// Uses linear interpolation to find the x coordinate
    ///
    /// **How it works**:
    /// - Given a line from (x1,y1) to (x2,y2)
    /// - Find where it crosses a horizontal line at height y
    /// - Uses the formula: x = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
    ///
    /// This is linear interpolation (lerp) - fundamental in graphics
    fn lineIntersectionX(_: *Renderer, x1: i32, y1: i32, x2: i32, y2: i32, y: i32) i32 {
        // Avoid division by zero
        if (y1 == y2) return x1;

        // Linear interpolation formula
        // (x - x1) / (x2 - x1) = (y - y1) / (y2 - y1)
        // Solve for x: x = x1 + (y - y1) * (x2 - x1) / (y2 - y1)

        const dy = y2 - y1;
        const dx = x2 - x1;
        const t_num = y - y1;

        // Use integer arithmetic to avoid floating point
        // Result: x1 + (t_num * dx) / dy
        const result = x1 + @divTrunc(t_num * dx, dy);
        return result;
    }

    /// Copy the bitmap to the window display using cached memory DC
    /// This is the core rendering operation: get pixels on screen
    /// Similar to: ctx.putImageData() in JavaScript
    fn drawBitmap(self: *Renderer) void {
        // Draw tile boundaries if enabled (for visualization)
        if (self.show_tile_borders) {
            if (self.tile_grid) |*grid| {
                TileRenderer.drawTileBoundaries(grid, &self.bitmap);
            }
        }

        if (self.hdc) |hdc| {
            if (self.hdc_mem) |hdc_mem| {
                // ===== Select our bitmap into the memory DC =====
                // Tell Windows: "I want to draw from THIS bitmap"
                // SelectObject returns the old object (so we can restore it)
                const old_bitmap = SelectObject(hdc_mem, self.bitmap.hbitmap);
                defer _ = SelectObject(hdc_mem, old_bitmap);

                // ===== Copy bitmap to window (BitBlt = Bit Block Transfer) =====
                // This is the fundamental pixel-copying operation
                // Copy a rectangle of pixels from source (memory DC) to destination (window DC)
                // Using cached memory DC avoids the overhead of creating/destroying it every frame
                // Like: ctx.drawImage(sourceCanvas, destX, destY, width, height)
                _ = BitBlt(hdc, // Destination: window display
                    0, // Destination X position
                    0, // Destination Y position
                    self.bitmap.width, // Source width
                    self.bitmap.height, // Source height
                    hdc_mem, // Source: memory DC containing our bitmap
                    0, // Source X position
                    0, // Source Y position
                    SRCCOPY // Raster operation: direct copy (no blending)
                );
            }
        }
    }
};
