// src/renderer.zig - Rendering module
// This module handles creating a bitmap, rendering content to it,
// and drawing the bitmap to the window using the Windows GDI.

const std = @import("std");
const windows = std.os.windows;

// Define types
const HGDIOBJ = *anyopaque;

// Extern declarations for user32 functions
extern "user32" fn GetDC(hWnd: windows.HWND) ?windows.HDC;
extern "user32" fn ReleaseDC(hWnd: windows.HWND, hDC: windows.HDC) i32;

// Extern declarations for gdi32 functions
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
extern "gdi32" fn BitBlt(hdcDest: windows.HDC, nXDest: i32, nYDest: i32, nWidth: i32, nHeight: i32, hdcSrc: windows.HDC, nXSrc: i32, nYSrc: i32, dwRop: u32) bool;
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;

// Constants
const SRCCOPY = 0x00CC0020;

// Import the Bitmap module
const Bitmap = @import("bitmap.zig").Bitmap;

// Renderer structure to manage rendering operations
pub const Renderer = struct {
    hwnd: windows.HWND, // Handle to the window
    bitmap: Bitmap, // The bitmap to render to
    hdc: ?windows.HDC, // Device context for the window

    // Initialize the renderer with the window handle and bitmap dimensions
    pub fn init(hwnd: windows.HWND, width: i32, height: i32) !Renderer {
        // Get the device context for the window
        const hdc = GetDC(hwnd);
        if (hdc == null) return error.DCNotFound;

        // Create a bitmap with the specified dimensions
        const bitmap = try Bitmap.init(width, height);

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
        };
    }

    // Clean up the renderer resources
    pub fn deinit(self: *Renderer) void {
        if (self.hdc) |hdc| {
            _ = ReleaseDC(self.hwnd, hdc);
        }
        self.bitmap.deinit();
    }

    // Render a simple "Hello World" by filling the bitmap with a solid color
    pub fn renderHelloWorld(self: *Renderer) void {
        // Fill the bitmap with a blue color (RGB: 0, 0, 255)
        const color: u32 = 0xFF0000FF; // Blue in BGRA format
        for (self.bitmap.pixels) |*pixel| {
            pixel.* = color;
        }

        // Draw the bitmap to the window
        self.drawBitmap();
    }

    // Draw the bitmap to the window using BitBlt
    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            const hdc_mem = CreateCompatibleDC(hdc);
            if (hdc_mem == null) return;
            const hdc_mem_unwrapped = hdc_mem.?;

            defer _ = DeleteDC(hdc_mem_unwrapped);

            const old_bitmap = SelectObject(hdc_mem_unwrapped, self.bitmap.hbitmap);
            defer _ = SelectObject(hdc_mem_unwrapped, old_bitmap);

            // Copy the bitmap to the window
            _ = BitBlt(hdc, // Destination DC
                0, 0, // Destination position
                self.bitmap.width, self.bitmap.height, // Size
                hdc_mem_unwrapped, // Source DC
                0, 0, // Source position
                SRCCOPY // Raster operation
            );
        }
    }
};
