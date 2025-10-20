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

    /// Initialize the renderer for a window
    /// Similar to: canvas = document.createElement("canvas"); ctx = canvas.getContext("2d")
    pub fn init(hwnd: windows.HWND, width: i32, height: i32) !Renderer {
        // ===== STEP 1: Get window's device context =====
        // A DC is a "graphics interface" - like a canvas context
        // We'll use this to copy our bitmap to the screen
        const hdc = GetDC(hwnd);
        if (hdc == null) return error.DCNotFound;

        // ===== STEP 2: Create a bitmap =====
        // This allocates a pixel buffer (width × height × 4 bytes)
        const bitmap = try Bitmap.init(width, height);

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
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

    /// Render initial "Hello World" - fills screen with blue color
    /// This demonstrates both pixel manipulation and blitting to screen
    pub fn renderHelloWorld(self: *Renderer) void {
        // ===== STEP 1: Fill all pixels with blue color =====
        // Color format: 0xAARRGGBB (Alpha, Red, Green, Blue)
        // 0xFF0000FF = opaque (FF) + red (00) + green (00) + blue (FF)
        // In BGRA format (used by Windows): it becomes blue
        const blue: u32 = 0xFF0000FF;

        // Loop through every pixel and set it to blue
        // Similar to JavaScript: pixels.fill(0xFF0000FF)
        for (self.bitmap.pixels) |*pixel| {
            pixel.* = blue;
        }

        // ===== STEP 2: Draw a red triangle =====
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
        
        // Draw the triangle by scanning horizontally
        // This is similar to: canvas.fillStyle = "#FF0000"; canvas.fillPath()
        self.drawTriangle(top_x, top_y, left_x, left_y, right_x, right_y);

        // ===== STEP 3: Copy bitmap to screen =====
        // Now that we've filled the bitmap, draw it to the window
        self.drawBitmap();
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
