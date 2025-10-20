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

// ========== RENDERER STRUCT ==========
/// Manages rendering operations: converting bitmap data to screen display
/// Similar to a canvas context: ctx = canvas.getContext("2d")
pub const Renderer = struct {
    hwnd: windows.HWND, // Window handle - where we'll draw
    bitmap: Bitmap, // The pixel buffer we draw to
    hdc: ?windows.HDC, // Device context - the interface for drawing to the window
    allocator: std.mem.Allocator, // Memory allocator
    rotation_angle: f32, // Current rotation angle for animation
    frame_count: u32, // Number of frames rendered
    last_time: i64, // Last time we calculated FPS (in milliseconds)
    last_frame_time: i64, // Last time a frame was rendered (for frame pacing)
    current_fps: u32, // Current FPS counter
    target_frame_time_ms: i64, // Target milliseconds per frame (1000/120 = 8.33ms)

    /// Initialize the renderer for a window
    /// Similar to: canvas = document.createElement("canvas"); ctx = canvas.getContext("2d")
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        // ===== STEP 1: Get window's device context =====
        // A DC is a "graphics interface" - like a canvas context
        // We'll use this to copy our bitmap to the screen
        const hdc = GetDC(hwnd);
        if (hdc == null) return error.DCNotFound;

        // ===== STEP 2: Create a bitmap =====
        // This allocates a pixel buffer (width × height × 4 bytes)
        const bitmap = try Bitmap.init(width, height);

        const current_time = std.time.milliTimestamp();
        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .allocator = allocator,
            .rotation_angle = 0,
            .frame_count = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .current_fps = 0,
            .target_frame_time_ms = 8, // 1000ms / 120fps = 8.33ms, round to 8
        };
    }

    /// Clean up renderer resources
    /// Called with 'defer renderer.deinit()' in main.zig
    pub fn deinit(self: *Renderer) void {
        if (self.hdc) |hdc| {
            _ = ReleaseDC(self.hwnd, hdc);
        }
        self.bitmap.deinit();
    }

    /// Wait until it's time to render the next frame (frame rate limiting)
    /// Implements frame pacing to hit target FPS
    /// Returns true if frame should be rendered, false if we should skip it
    pub fn shouldRenderFrame(self: *Renderer) bool {
        const current_time = std.time.milliTimestamp();
        const elapsed_since_last_frame = current_time - self.last_frame_time;

        // Only render if enough time has passed for the target frame rate
        if (elapsed_since_last_frame >= self.target_frame_time_ms) {
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
    /// 4. Draw wireframe
    pub fn render3DMesh(self: *Renderer, mesh: *const Mesh) !void {
        // ===== STEP 1: Fill all pixels with black color =====
        const black: u32 = 0xFF000000;
        for (self.bitmap.pixels) |*pixel| {
            pixel.* = black;
        }

        // ===== STEP 2: Create transformation matrices =====
        // Rotation matrices for X, Y, Z axes
        const rot_x = math.Mat4.rotateX(self.rotation_angle);
        const rot_y = math.Mat4.rotateY(self.rotation_angle * 1.5);
        const rot_z = math.Mat4.rotateZ(self.rotation_angle * 0.7);

        // Combine rotations: total = Z * Y * X
        const rot_xy = math.Mat4.multiply(rot_y, rot_x);
        const transform = math.Mat4.multiply(rot_z, rot_xy);

        // ===== STEP 3: Transform and project vertices =====
        const projected = try self.allocator.alloc([2]i32, mesh.vertices.len);
        defer self.allocator.free(projected);

        const center_x = @as(f32, @floatFromInt(self.bitmap.width)) / 2.0;
        const center_y = @as(f32, @floatFromInt(self.bitmap.height)) / 2.0;

        for (mesh.vertices, 0..) |vertex, i| {
            // Transform vertex by rotation
            const transformed = transform.mulVec3(vertex);

            // Move away from camera (simple z offset for perspective)
            const z_offset = 4.0; // Distance from camera
            const camera_z = transformed.z + z_offset;

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

        // ===== STEP 4: Draw all triangles =====
        for (mesh.triangles) |tri| {
            const p0 = projected[tri.v0];
            const p1 = projected[tri.v1];
            const p2 = projected[tri.v2];

            // Draw three edges of the triangle
            self.drawLine(p0[0], p0[1], p1[0], p1[1]);
            self.drawLine(p1[0], p1[1], p2[0], p2[1]);
            self.drawLine(p2[0], p2[1], p0[0], p0[1]);
        }

        // ===== STEP 5: Copy bitmap to screen =====
        self.drawBitmap();

        // ===== STEP 6: Update FPS counter =====
        self.frame_count += 1;
        const current_time = std.time.milliTimestamp();
        const elapsed_ms = current_time - self.last_time;

        // Update FPS every 500ms
        if (elapsed_ms >= 500) {
            self.current_fps = @as(u32, @intCast((self.frame_count * 1000) / @as(u32, @intCast(elapsed_ms))));
            self.frame_count = 0;
            self.last_time = current_time;

            // Create title string: "Zig 3D CPU Rasterizer - X FPS"
            var fps_buf: [64]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&fps_buf, "Zig 3D CPU Rasterizer - FPS: {d}", .{self.current_fps}) catch "Zig 3D CPU Rasterizer";

            // Convert UTF-8 to UTF-16 for Windows (null-terminated)
            var wide_title: [128:0]u16 = undefined;
            var idx: usize = 0;
            for (fps_str) |ch| {
                if (idx >= 127) break;
                wide_title[idx] = ch;
                idx += 1;
            }
            wide_title[idx] = 0; // Null terminator

            _ = SetWindowTextW(self.hwnd, &wide_title);
        }

        // ===== STEP 7: Update rotation for next frame =====
        self.rotation_angle += 0.02;
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
        self.drawLine(top_x, top_y, left_x, left_y);    // Top-left edge
        self.drawLine(left_x, left_y, right_x, right_y);  // Bottom edge
        self.drawLine(right_x, right_y, top_x, top_y);   // Right edge

        // ===== STEP 3: Copy bitmap to screen =====
        // Now that we've filled the bitmap, draw it to the window
        self.drawBitmap();
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
        // White color in BGRA format: 0xFFFFFFFF
        const white: u32 = 0xFFFFFFFF;

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
                    self.bitmap.pixels[pixel_index] = white;
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

    /// Draw a filled triangle using scanline rasterization
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

    /// Copy the bitmap to the window display
    /// This is the core rendering operation: get pixels on screen
    /// Similar to: ctx.putImageData() in JavaScript
    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            // ===== STEP 1: Create a memory DC =====
            // Create an off-screen drawing surface compatible with the window DC
            // This is necessary because SelectObject needs a DC to work with
            const hdc_mem = CreateCompatibleDC(hdc);
            if (hdc_mem == null) return;
            const hdc_mem_unwrapped = hdc_mem.?;

            // Use 'defer' to ensure cleanup even if we return early
            // This is like try/finally in JavaScript: cleanup always happens
            defer _ = DeleteDC(hdc_mem_unwrapped);

            // ===== STEP 2: Select our bitmap into the memory DC =====
            // Tell Windows: "I want to draw from THIS bitmap"
            // SelectObject returns the old object (so we can restore it)
            const old_bitmap = SelectObject(hdc_mem_unwrapped, self.bitmap.hbitmap);
            defer _ = SelectObject(hdc_mem_unwrapped, old_bitmap);

            // ===== STEP 3: Copy bitmap to window (BitBlt = Bit Block Transfer) =====
            // This is the fundamental pixel-copying operation
            // Copy a rectangle of pixels from source (memory DC) to destination (window DC)
            // Like: ctx.drawImage(sourceCanvas, destX, destY, width, height)
            _ = BitBlt(hdc, // Destination: window display
                0, // Destination X position
                0, // Destination Y position
                self.bitmap.width, // Source width
                self.bitmap.height, // Source height
                hdc_mem_unwrapped, // Source: memory DC containing our bitmap
                0, // Source X position
                0, // Source Y position
                SRCCOPY // Raster operation: direct copy (no blending)
            );
        }
    }
};
