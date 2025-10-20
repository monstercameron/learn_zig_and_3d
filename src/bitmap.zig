// src/bitmap.zig - Bitmap management module
// This module provides functionality to create and manage a device-independent bitmap (DIB)
// for rendering purposes in Windows.

const std = @import("std");
const windows = std.os.windows;

// Define types
const HGDIOBJ = *anyopaque;

// Define BITMAPINFO type
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32, // For simplicity, assume no color table
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

// Constants
const BI_RGB = 0;
const DIB_RGB_COLORS = 0;

// Extern declarations
extern "gdi32" fn CreateDIBSection(hdc: ?windows.HDC, pbmi: *const BITMAPINFO, iUsage: u32, ppvBits: *?*anyopaque, hSection: ?windows.HANDLE, dwOffset: u32) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(hObject: HGDIOBJ) bool;

// Bitmap structure to hold bitmap data
pub const Bitmap = struct {
    hbitmap: HGDIOBJ, // Handle to the bitmap
    pixels: []u32, // Pointer to the pixel data
    width: i32, // Width of the bitmap
    height: i32, // Height of the bitmap

    // Initialize a new bitmap with the given dimensions
    pub fn init(width: i32, height: i32) !Bitmap {
        // Bitmap info header for a 32-bit BGRA bitmap
        var bmi: BITMAPINFO = std.mem.zeroes(BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        bmi.bmiHeader.biHeight = -height; // Negative height for top-down bitmap
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32; // 32 bits per pixel (BGRA)
        bmi.bmiHeader.biCompression = BI_RGB;

        // Create the DIB section
        var pixels: ?*anyopaque = undefined;
        const hbitmap = CreateDIBSection(null, // Device context (can be null for DIB)
            &bmi, // Bitmap info
            DIB_RGB_COLORS, // Color format
            &pixels, // Pointer to pixel data
            null, // File mapping object
            0 // File offset
        );

        if (hbitmap == null) return error.BitmapCreationFailed;

        // Cast the pixel pointer to a slice of u32
        const pixel_count = @as(usize, @intCast(width * height));
        const pixel_slice = @as([*]u32, @ptrCast(@alignCast(pixels)))[0..pixel_count];

        return Bitmap{
            .hbitmap = hbitmap.?, // Unwrap the optional
            .pixels = pixel_slice,
            .width = width,
            .height = height,
        };
    }

    // Clean up the bitmap resources
    pub fn deinit(self: *Bitmap) void {
        _ = DeleteObject(self.hbitmap);
    }
};
