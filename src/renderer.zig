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

// ========== RENDERING CONSTANTS ==========
/// Light direction: direction TO the light source (where bright faces should point)
/// Camera looks along +Z axis at the mesh
/// Light should come FROM behind the camera, pointing toward -Z (into the screen)
/// This lights up faces that point toward the camera
const LIGHT_DIR = math.Vec3.new(0.0, 0.0, -1.0); // Pointing toward -Z (into screen)

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
        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .hdc_mem = hdc_mem,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
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
        };
    }

    /// Clean up renderer resources
    /// Called with 'defer renderer.deinit()' in main.zig
    pub fn deinit(self: *Renderer) void {
        if (self.hdc_mem) |hdc_mem| {
            _ = DeleteDC(hdc_mem);
        }
        if (self.hdc) |hdc| {
            _ = ReleaseDC(self.hwnd, hdc);
        }
        self.bitmap.deinit();
    }

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
        const KEY_LEFT_BIT: u32 = 1;
        const KEY_RIGHT_BIT: u32 = 2;
        const KEY_UP_BIT: u32 = 4;
        const KEY_DOWN_BIT: u32 = 8;

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
        // ===== STEP 1: Fill all pixels with black color =====
        // Use @memset for much faster clearing (CPU-optimized bulk fill)
        const black: u32 = 0xFF000000;
        @memset(self.bitmap.pixels, black);

        // ===== STEP 2: Update rotation based on currently pressed keys =====
        const KEY_LEFT_BIT: u32 = 1;
        const KEY_RIGHT_BIT: u32 = 2;
        const KEY_UP_BIT: u32 = 4;
        const KEY_DOWN_BIT: u32 = 8;
        const rotation_speed = 0.02; // Radians per frame

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

        // ===== STEP 3: Create transformation matrices =====
        // Apply both Y-axis rotation (left/right) and X-axis rotation (up/down)
        const transform_y = math.Mat4.rotateY(self.rotation_angle);
        const transform_x = math.Mat4.rotateX(self.rotation_x);
        const transform = math.Mat4.multiply(transform_y, transform_x);

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

        for (mesh.triangles, 0..) |tri, tri_idx| {
            // Skip if fill is culled
            if (tri.cull_flags.cull_fill) {
                continue;
            }

            const p0 = projected[tri.v0];
            const p1 = projected[tri.v1];
            const p2 = projected[tri.v2];

            // Check if triangle is completely off-screen
            if (p0[0] < -1000 or p1[0] < -1000 or p2[0] < -1000) {
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
                continue;
            }
            const view_vector = math.Vec3.scale(face_center, -1.0 / view_length);

            const camera_facing = normal_transformed.dot(view_vector);
            if (camera_facing <= 0.0) {
                continue;
            }

            // Calculate lighting: dot product of normal and light direction
            var brightness = normal_transformed.dot(LIGHT_DIR);

            // Clamp to 0-1 range (NO minimum ambient light for debugging shading)
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
        for (mesh.triangles) |tri| {
            // Skip if wireframe is culled
            if (tri.cull_flags.cull_wireframe) {
                continue;
            }

            const p0 = projected[tri.v0];
            const p1 = projected[tri.v1];
            const p2 = projected[tri.v2];

            // Draw three edges of the triangle with white color
            self.drawLineColored(p0[0], p0[1], p1[0], p1[1], 0xFFFFFFFF);
            self.drawLineColored(p1[0], p1[1], p2[0], p2[1], 0xFFFFFFFF);
            self.drawLineColored(p2[0], p2[1], p0[0], p0[1], 0xFFFFFFFF);
        }

        // ===== STEP 6: Copy bitmap to screen =====
        self.drawBitmap();

        // ===== STEP 7: Calculate brightness statistics from rendered frame =====
        self.calculateBrightnessStats();

        // ===== STEP 8: Update FPS counter and log =====
        self.frame_count += 1;
        const current_time = std.time.nanoTimestamp();
        const elapsed_ns = current_time - self.last_time;

        // Update FPS every 500ms (500_000_000 nanoseconds)
        if (elapsed_ns >= 500_000_000) {
            // Calculate FPS: frames * 1_000_000_000 ns/s / elapsed nanoseconds
            const elapsed_us = @divTrunc(elapsed_ns, 1000); // Convert to microseconds
            self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));
            self.frame_count = 0;
            self.last_time = current_time;

            // Log rotation angle and shading information
            const rotation_degrees = self.rotation_angle * 180.0 / 3.14159265359;
            const sample_r = @as(u32, @intFromFloat(self.last_brightness_avg * 255));
            const sample_g = @as(u32, @intFromFloat(self.last_brightness_avg * 200));
            const sample_b = @as(u32, @intFromFloat(self.last_brightness_avg * 50));

            std.debug.print("Rotation: {d:.2}° | Brightness: min={d:.2} avg={d:.2} max={d:.2} | Sample RGB: ({}, {}, {}) | FPS: {}\n", .{
                rotation_degrees, self.last_brightness_min, self.last_brightness_avg, self.last_brightness_max, sample_r, sample_g, sample_b, self.current_fps
            });
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
