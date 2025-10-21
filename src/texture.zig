//! # Texture Loading and Sampling
//!
//! This module defines a `Texture` data structure and provides a function to load
//! and parse `.bmp` (Bitmap) image files. A texture is an image that can be mapped
//! onto the surface of a 3D model.
//!
//! ## JavaScript Analogy
//!
//! In JavaScript, you would typically load an image like this:
//!
//! ```javascript
//! const myImage = new Image();
//! myImage.src = 'path/to/image.png';
//! myImage.onload = () => {
//!   // In WebGL, you would then create a texture from the image.
//!   const texture = gl.createTexture();
//!   gl.bindTexture(gl.TEXTURE_2D, texture);
//!   gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, myImage);
//! };
//! ```
//! 
//! This file is doing all of that work manually. The `loadBmp` function is like the
//! browser's native code that decodes the image file, and the `Texture` struct is
//! like the resulting WebGL texture object, holding the raw pixel data.

const std = @import("std");
const math = @import("math.zig");

// Helper functions to read little-endian integers from a byte slice.
// File formats often specify a specific byte order (endianness).
inline fn readU16le(bytes: []const u8) u16 {
    return (@as(u16, bytes[0])) | (@as(u16, bytes[1]) << 8);
}

inline fn readU32le(bytes: []const u8) u32 {
    return (@as(u32, bytes[0])) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

inline fn readI32le(bytes: []const u8) i32 {
    return @bitCast(readU32le(bytes));
}

/// Represents a 2D texture, holding the dimensions and the raw pixel data.
pub const Texture = struct {
    width: usize,
    height: usize,
    pixels: []u32, // A flat array of 32-bit integer colors (0xAARRGGBB).
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.pixels);
    }

    /// Looks up the color of a pixel in the texture at a given UV coordinate.
    /// This process is called "sampling".
    /// - `uv`: A 2D vector with components from 0.0 to 1.0.
    pub fn sample(self: *const Texture, uv: math.Vec2) u32 {
        if (self.width == 0 or self.height == 0) return 0xFF000000; // Return black for invalid textures.

        // Clamp UV coordinates to the [0, 1] range to prevent out-of-bounds access.
        const u = std.math.clamp(uv.x, 0.0, 1.0);
        const v = std.math.clamp(uv.y, 0.0, 1.0);

        // Convert normalized UV coordinates to integer pixel coordinates.
        const max_x = if (self.width > 0) self.width - 1 else 0;
        const max_y = if (self.height > 0) self.height - 1 else 0;
        const x_f = u * @as(f32, @floatFromInt(max_x));
        const y_f = v * @as(f32, @floatFromInt(max_y));

        // This is "Nearest Neighbor" filtering: we just round to the nearest pixel.
        const x = @min(@as(usize, @intFromFloat(@floor(x_f + 0.5))), max_x);
        const y = @min(@as(usize, @intFromFloat(@floor(y_f + 0.5))), max_y);

        return self.pixels[y * self.width + x];
    }
};

/// Loads a texture from a .bmp file. This is a manual parser for the BMP format.
pub fn loadBmp(allocator: std.mem.Allocator, path: []const u8) !Texture {
    const data = try std.fs.cwd().openFile(path, .{}).readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    // --- BMP Header Parsing ---
    // A BMP file has a specific header structure that we must parse to understand the image data.

    if (data.len < 54) return error.InvalidBmpHeader; // 14-byte file header + 40-byte DIB header.

    // Check for the 'BM' magic bytes at the start of the file.
    if (!(data[0] == 'B' and data[1] == 'M')) return error.InvalidBmpSignature;

    // The header tells us where the actual pixel data starts in the file.
    const pixel_offset = @as(usize, @intCast(readU32le(data[10..14])));

    // The DIB (Device-Independent Bitmap) header contains image metadata.
    const dib_slice = data[14..];
    if (dib_slice.len < 40) return error.InvalidBmpHeader;

    const width_signed = readI32le(dib_slice[4..8]);
    const height_signed = readI32le(dib_slice[8..12]);
    const planes = readU16le(dib_slice[12..14]);
    const bit_count = readU16le(dib_slice[14..16]); // Bits per pixel (e.g., 24 for RGB, 32 for RGBA).
    const compression = readU32le(dib_slice[16..20]);

    // --- Validation ---
    // We only support uncompressed, 24-bit or 32-bit BMPs.
    if (planes != 1) return error.UnsupportedBmpPlanes;
    if (compression != 0) return error.UnsupportedBmpCompression;
    if (bit_count != 24 and bit_count != 32) return error.UnsupportedBmpBitDepth;
    if (width_signed <= 0 or height_signed == 0) return error.UnsupportedBmpDimension;

    const width = @as(usize, @intCast(width_signed));
    // A positive height in a BMP header means the image is stored "bottom-up".
    const flipped = height_signed > 0;
    const height = @as(usize, @intCast(if (flipped) height_signed else -height_signed));

    // --- Pixel Data Parsing ---
    const bytes_per_pixel = @divExact(bit_count, 8);
    // In BMPs, each row of pixels is padded to be a multiple of 4 bytes long.
    // This is a C-style memory alignment requirement that we have to handle manually.
    const row_stride = ((bit_count * width + 31) / 32) * 4;

    if (pixel_offset + row_stride * height > data.len) return error.BmpDataTruncated;

    const pixel_data = data[pixel_offset .. pixel_offset + row_stride * height];
    const pixels = try allocator.alloc(u32, width * height);

    // Loop through each row and pixel to convert from BGR(A) to our 32-bit ARGB format.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        // If the BMP is bottom-up, we read the source rows in reverse order.
        const src_y = if (flipped) (height - 1 - y) else y;
        const row = pixel_data[src_y * row_stride .. (src_y + 1) * row_stride];

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const base = x * bytes_per_pixel;
            if (base + bytes_per_pixel > row.len) return error.BmpRowOverflow;

            // BMP stores colors in BGR order.
            const b = row[base];
            const g = row[base + 1];
            const r = row[base + 2];
            const a: u8 = if (bytes_per_pixel == 4) row[base + 3] else 0xFF; // Default to full alpha if not present.

            // Pack the components into a single 0xAARRGGBB integer.
            const dest_index = y * width + x;
            pixels[dest_index] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        }
    }

    return Texture{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
}