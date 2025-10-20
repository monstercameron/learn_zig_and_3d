//! # Bitmap Management Module
//!
//! This module handles low-level bitmap creation and pixel buffer management.
//! A bitmap is a 2D grid of pixels stored in memory that can be drawn to.
//!
//! **Single Concern**: Creating, managing, and providing access to pixel data
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Like canvas.getContext("2d") giving you a pixel buffer
//! class Bitmap {
//!   constructor(width, height) {
//!     // Create a buffer big enough for all pixels
//!     // Each pixel is 4 bytes (R, G, B, A)
//!     this.pixelData = new Uint32Array(width * height);
//!     this.width = width;
//!     this.height = height;
//!   }
//!
//!   // Set a pixel color: bitmap.pixelData[y * width + x] = color
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;

// ========== WINDOWS API TYPES ==========
// HGDIOBJ - Handle to a Graphics Device Interface object
// In Windows, any graphics object (bitmap, pen, brush) is represented as a "handle"
// Similar to a file descriptor or DOM node reference
const HGDIOBJ = *anyopaque;

// ========== WINDOWS API STRUCTURES ==========
/// BITMAPINFOHEADER - Describes the structure of a bitmap
/// This tells Windows how to interpret the pixel data
/// (width, height, color depth, compression, etc.)
const BITMAPINFOHEADER = extern struct {
    biSize: u32, // Size of this header structure
    biWidth: i32, // Bitmap width in pixels
    biHeight: i32, // Bitmap height in pixels (negative = top-down)
    biPlanes: u16, // Must be 1 (legacy)
    biBitCount: u16, // Bits per pixel: 1, 4, 8, 16, 24, or 32
    biCompression: u32, // Compression type (0 = uncompressed)
    biSizeImage: u32, // Compressed size (0 if uncompressed)
    biXPelsPerMeter: i32, // Horizontal resolution (pixels per meter)
    biYPelsPerMeter: i32, // Vertical resolution (pixels per meter)
    biClrUsed: u32, // Number of colors in palette (0 = all)
    biClrImportant: u32, // Number of important colors (0 = all)
};

/// BITMAPINFO - Complete bitmap information structure
/// Contains both the header and optional color palette
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32, // Color palette (we use only 1 slot for BGRA format)
};

// ========== CONSTANTS ==========
const BI_RGB = 0; // No compression
const DIB_RGB_COLORS = 0; // Use RGB colors (not palette indices)

// ========== WINDOWS API DECLARATIONS ==========
/// Create a Device-Independent Bitmap (DIB)
/// This creates a bitmap that owns its pixel data directly
/// Returns a handle to the bitmap on success, null on failure
extern "gdi32" fn CreateDIBSection(
    hdc: ?windows.HDC, // Device context (can be null)
    pbmi: *const BITMAPINFO, // Bitmap info structure
    iUsage: u32, // Color format type
    ppvBits: *?*anyopaque, // Pointer to pixel data buffer (output)
    hSection: ?windows.HANDLE, // File mapping (null = new buffer)
    dwOffset: u32, // Offset in file (0 for new buffer)
) ?HGDIOBJ;

/// Delete a graphics object and free its memory
extern "gdi32" fn DeleteObject(hObject: HGDIOBJ) bool;

// ========== BITMAP STRUCT ==========
/// Encapsulates a bitmap and its pixel data
/// Similar to a canvas backing store in JavaScript
pub const Bitmap = struct {
    hbitmap: HGDIOBJ, // Handle to the bitmap object
    pixels: []u32, // Array of pixel colors (BGRA format)
    width: i32, // Width in pixels
    height: i32, // Height in pixels

    /// Create a new bitmap with specified dimensions
    /// Similar to: canvas.width = 800; canvas.height = 600
    pub fn init(width: i32, height: i32) !Bitmap {
        // ===== STEP 1: Set up bitmap info structure =====
        // This is like describing the canvas: "I want 800x600 at 32-bit color"
        var bmi: BITMAPINFO = std.mem.zeroes(BITMAPINFO);

        bmi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        bmi.bmiHeader.biHeight = -height; // Negative = top-down (0,0 at top-left)
        bmi.bmiHeader.biPlanes = 1; // Always 1
        bmi.bmiHeader.biBitCount = 32; // 32 bits per pixel: BGRA format
        // - B: Blue channel (0-255)
        // - G: Green channel (0-255)
        // - R: Red channel (0-255)
        // - A: Alpha/transparency (0-255)
        bmi.bmiHeader.biCompression = BI_RGB; // No compression

        // ===== STEP 2: Create the bitmap in Windows =====
        // This allocates memory for all pixels: width * height * 4 bytes
        var pixels: ?*anyopaque = undefined;
        const hbitmap = CreateDIBSection(null, // No device context needed
            &bmi, // Use our bitmap info
            DIB_RGB_COLORS, // RGB color format
            &pixels, // Out parameter: Windows fills this with the buffer pointer
            null, // No file mapping - new buffer
            0 // No offset
        );

        if (hbitmap == null) return error.BitmapCreationFailed;

        // ===== STEP 3: Convert void pointer to Zig array =====
        // Windows gives us a void pointer; we need a proper Zig slice
        // Similar to: const pixelArray = new Uint32Array(buffer)
        const pixel_count = @as(usize, @intCast(width * height));
        const pixel_slice = @as([*]u32, // Pointer to u32 array
            @ptrCast(@alignCast(pixels)) // Cast and align the void pointer
            )[0..pixel_count]; // Create a slice of the array

        return Bitmap{
            .hbitmap = hbitmap.?,
            .pixels = pixel_slice,
            .width = width,
            .height = height,
        };
    }

    /// Free bitmap resources
    /// Called when done with the bitmap
    /// Similar to: canvas.getContext("2d").clearRect() but for the whole bitmap
    pub fn deinit(self: *Bitmap) void {
        _ = DeleteObject(self.hbitmap);
    }
};
