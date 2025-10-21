//! # Bitmap Management Module
//!
//! This module handles the low-level, OS-specific details of creating a block of memory
//! to hold pixel data. This block of memory is called a bitmap, and it's what we will
//! draw our 3D scene onto, pixel by pixel.
//!
//! ## JavaScript Analogy
//!
//! This is very similar to the `ImageData` object you get from a 2D canvas context.
//!
//! ```javascript
//! const ctx = canvas.getContext('2d');
//! const imageData = ctx.createImageData(width, height);
//! // imageData.data is a Uint8ClampedArray - our `pixels` slice is like this.
//! 
//! // You can manipulate pixels directly:
//! imageData.data[0] = 255; // R
//! imageData.data[1] = 0;   // G
//! imageData.data[2] = 0;   // B
//! imageData.data[3] = 255; // A
//! 
//! // Then you put it on the canvas:
//! ctx.putImageData(imageData, 0, 0);
//! ```
//! Our `Bitmap` struct holds the pixel data, and our `renderer.zig` is responsible for
//! the `putImageData` part.

const std = @import("std");
const windows = std.os.windows;

// A handle to a Windows Graphics Device Interface (GDI) object.
// JS Analogy: Think of this as an ID. When you create a bitmap, the OS gives you
// an ID (a handle) so you can refer to it later when you want to draw it or delete it.
const HGDIOBJ = *anyopaque;

// ========== WINDOWS API STRUCTURES ==========

/// `BITMAPINFOHEADER`: A C-style struct that describes the properties of a bitmap.
/// JS Analogy: This is like a `settings` object you pass to a library. We have to
/// fill this out to tell the Windows OS exactly what kind of pixel buffer we want.
const BITMAPINFOHEADER = extern struct {
    biSize: u32, // The size of this header struct itself.
    biWidth: i32, // Bitmap width in pixels.
    biHeight: i32, // Bitmap height. A negative value means a top-down bitmap (0,0 is top-left).
    biPlanes: u16, // Must be 1.
    biBitCount: u16, // Bits per pixel. We use 32 (4 bytes: B, G, R, A).
    biCompression: u32, // Compression type. We use 0 (BI_RGB) for uncompressed.
    biSizeImage: u32, // The size of the image in bytes. Can be 0 for uncompressed images.
    biXPelsPerMeter: i32, // Horizontal resolution (pixels per meter).
    biYPelsPerMeter: i32, // Vertical resolution (pixels per meter).
    biClrUsed: u32, // Number of colors in the palette (0 for full color).
    biClrImportant: u32, // Number of important colors (0 means all are important).
};

/// `BITMAPINFO`: The complete bitmap information, combining the header and color palette.
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32, // We don't use a palette, but the struct requires this field.
};

// ========== CONSTANTS ==========
const BI_RGB = 0; // No compression.
const DIB_RGB_COLORS = 0; // Use literal RGB colors, not palette indices.

// ========== WINDOWS API DECLARATIONS ==========

/// `CreateDIBSection`: A low-level Windows function to create a Device-Independent Bitmap (DIB).
/// This asks the OS to allocate a block of memory for our pixels and gives us a handle to it.
/// JS Analogy: The native C++ code that would run inside the browser when you call `ctx.createImageData()`.
extern "gdi32" fn CreateDIBSection(
    hdc: ?windows.HDC, // Optional device context handle.
    pbmi: *const BITMAPINFO, // Pointer to our bitmap settings object.
    iUsage: u32, // Color format type.
    ppvBits: *?*anyopaque, // An "out parameter": Windows will write the memory address of the pixel buffer here.
    hSection: ?windows.HANDLE, // Not used by us.
    dwOffset: u32, // Not used by us.
) ?HGDIOBJ;

/// `DeleteObject`: A Windows function to free a graphics object (like our bitmap).
/// JS Analogy: Since we manually asked the OS for memory, we must manually free it.
/// This is what a garbage collector would do for you automatically in JS.
extern "gdi32" fn DeleteObject(hObject: HGDIOBJ) bool;

// ========== BITMAP STRUCT ==========

/// Encapsulates a Windows bitmap, holding both the OS handle and a direct slice of the pixel data.
pub const Bitmap = struct {
    hbitmap: HGDIOBJ, // The OS handle (ID) for this bitmap.
    pixels: []u32, // A Zig slice pointing directly to the pixel data. JS: `Uint32Array`.
    width: i32,
    height: i32,

    /// Creates a new bitmap with the specified dimensions.
    pub fn init(width: i32, height: i32) !Bitmap {
        // ===== STEP 1: Define the bitmap properties =====
        // We create a `BITMAPINFO` struct to describe the bitmap we want.
        var bmi: BITMAPINFO = std.mem.zeroes(BITMAPINFO);

        bmi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        // A negative height tells Windows to create a "top-down" bitmap, where the
        // first pixel in the buffer corresponds to the top-left corner of the image.
        // This is more intuitive and matches how most modern graphics APIs work.
        bmi.bmiHeader.biHeight = -height;
        bmi.bmiHeader.biPlanes = 1;
        // 32 bits per pixel gives us 8 bits for each channel: Blue, Green, Red, and Alpha.
        // Note the BGRA order, which is standard for Windows bitmaps.
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB; // No compression.

        // ===== STEP 2: Ask Windows to create the bitmap =====
        // We call the OS function, passing our settings. Windows allocates the memory
        // and gives us back a handle and a raw pointer to the pixel data.
        var pixel_data_pointer: ?*anyopaque = undefined;
        const hbitmap = CreateDIBSection(
            null, // No specific device context needed for creation.
            &bmi, // Pass the settings.
            DIB_RGB_COLORS,
            &pixel_data_pointer, // Windows writes the memory address here.
            null, // No file mapping.
            0, // No offset.
        );

        if (hbitmap == null) return error.BitmapCreationFailed;

        // ===== STEP 3: Convert the raw C-style pointer to a safe Zig slice =====
        // The OS gives us a generic, untyped pointer (`*anyopaque`). We need to cast it
        // to a typed pointer and then create a slice with the correct length.
        // JS Analogy: `const pixelArray = new Uint32Array(rawBuffer, 0, pixel_count);`
        const pixel_count = @as(usize, @intCast(width * height));
        const pixel_slice = @as([*]u32, @ptrCast(@alignCast(pixel_data_pointer)))[0..pixel_count];

        return Bitmap{
            .hbitmap = hbitmap.?,
            .pixels = pixel_slice,
            .width = width,
            .height = height,
        };
    }

    /// Frees the bitmap resources by telling the OS to delete the object.
    pub fn deinit(self: *Bitmap) void {
        _ = DeleteObject(self.hbitmap);
    }
};