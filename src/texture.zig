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
const config = @import("app_config.zig");

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
    pixels: []u32, // Array for LOD 0
    mip_levels: std.ArrayList([]u32), // Precomputed mipmaps
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Texture) void {
        for (self.mip_levels.items) |mip| {
            self.allocator.free(mip);
        }
        self.mip_levels.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }

    /// Looks up the color of a pixel in the texture at a given UV coordinate.
    /// This process is called "sampling".
    /// - `uv`: A 2D vector with components from 0.0 to 1.0.
    pub fn sample(self: *const Texture, uv: math.Vec2) u32 {
        return self.sampleLod(uv, 0.0);
    }
    
    pub fn sampleLod(self: *const Texture, uv: math.Vec2, lod: f32) u32 {
        if (self.width == 0 or self.height == 0) return 0xFF000000;
        
        var target_pixels = self.pixels;
        var target_w = self.width;
        var target_h = self.height;
        
        const mip_level = @as(usize, @intFromFloat(lod));
        if (mip_level > 0 and self.mip_levels.items.len > 0) {
            const level = @min(mip_level - 1, self.mip_levels.items.len - 1);
            target_pixels = self.mip_levels.items[level];
            target_w = @max(1, self.width >> @as(u5, @intCast(level + 1)));
            target_h = @max(1, self.height >> @as(u5, @intCast(level + 1)));
        }

        if (config.TEXTURE_FILTERING_BILINEAR) {
            return sampleBilinearImpl(target_pixels, target_w, target_h, uv);
        } else {
            return sampleNearestImpl(target_pixels, target_w, target_h, uv);
        }
    }

    fn sampleNearestImpl(pixels: []const u32, w: usize, h: usize, uv: math.Vec2) u32 {
        const u = std.math.clamp(uv.x, 0.0, 1.0);
        const v = std.math.clamp(uv.y, 0.0, 1.0);

        const max_x = if (w > 0) w - 1 else 0;
        const max_y = if (h > 0) h - 1 else 0;
        const x_f = u * @as(f32, @floatFromInt(max_x));
        const y_f = v * @as(f32, @floatFromInt(max_y));

        const x = @min(@as(usize, @intFromFloat(@floor(x_f + 0.5))), max_x);
        const y = @min(@as(usize, @intFromFloat(@floor(y_f + 0.5))), max_y);

        return pixels[y * w + x];
    }
    
    fn sampleBilinearImpl(pixels: []const u32, w: usize, h: usize, uv: math.Vec2) u32 {
        const u = std.math.clamp(uv.x, 0.0, 1.0);
        const v = std.math.clamp(uv.y, 0.0, 1.0);

        const w_f = @as(f32, @floatFromInt(w)) - 1.0;
        const h_f = @as(f32, @floatFromInt(h)) - 1.0;

        const x_coord = std.math.clamp(u * w_f, 0.0, w_f);
        const y_coord = std.math.clamp(v * h_f, 0.0, h_f);

        const x_floor = @floor(x_coord);
        const y_floor = @floor(y_coord);

        const dx = x_coord - x_floor;
        const dy = y_coord - y_floor;

        const ux0 = @as(usize, @intFromFloat(x_floor));
        const uy0 = @as(usize, @intFromFloat(y_floor));
        const ux1 = @min(ux0 + 1, w - 1);
        const uy1 = @min(uy0 + 1, h - 1);

        const c00 = pixels[uy0 * w + ux0];
        const c10 = pixels[uy0 * w + ux1];
        const c01 = pixels[uy1 * w + ux0];
        const c11 = pixels[uy1 * w + ux1];

        const frac_x = @as(u32, @intFromFloat(dx * 255.0));
        const frac_y = @as(u32, @intFromFloat(dy * 255.0));
        const inv_x = 255 - frac_x;
        const inv_y = 255 - frac_y;

        const w00 = inv_x * inv_y;
        const w10 = frac_x * inv_y;
        const w01 = inv_x * frac_y;
        const w11 = frac_x * frac_y;

        var result: u32 = 0;
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const val00 = (c00 >> shift) & 0xFF;
            const val10 = (c10 >> shift) & 0xFF;
            const val01 = (c01 >> shift) & 0xFF;
            const val11 = (c11 >> shift) & 0xFF;
            const sum = (val00 * w00 + val10 * w10 + val01 * w01 + val11 * w11);
            const blended = sum / 65025;
            result |= (blended << shift);
        }

        return result;
    }
};

/// Loads a texture from a .bmp file. This is a manual parser for the BMP format.
pub fn loadBmp(allocator: std.mem.Allocator, path: []const u8) !Texture {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
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
            const a: u8 = if (bytes_per_pixel == 4) row[base + 3] else 0xFF;

            // Pack the components into a single 0xAARRGGBB integer.
            const dest_index = y * width + x;
            pixels[dest_index] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        }
    }

    var mip_levels = std.ArrayList([]u32){};
    var current_w = width;
    var current_h = height;
    var current_pixels = pixels;
    
    // Generate mipmaps down to 1x1
    while (current_w > 1 or current_h > 1) {
        const next_w = @max(1, current_w / 2);
        const next_h = @max(1, current_h / 2);
        const next_pixels = allocator.alloc(u32, next_w * next_h) catch break; // Break out if memory fails
        
        // Simple box filter
        for (0..next_h) |ny| {
            for (0..next_w) |nx| {
                const px0 = nx * 2;
                const py0 = ny * 2;
                var sum_r: u32 = 0; var sum_g: u32 = 0; var sum_b: u32 = 0; var sum_a: u32 = 0;
                var count: u32 = 0;
                
                for (0..2) |dy| {
                    for (0..2) |dx| {
                        const px = px0 + dx;
                        const py = py0 + dy;
                        if (px < current_w and py < current_h) {
                            const c = current_pixels[py * current_w + px];
                            sum_a += (c >> 24) & 0xFF;
                            sum_r += (c >> 16) & 0xFF;
                            sum_g += (c >> 8) & 0xFF;
                            sum_b += c & 0xFF;
                            count += 1;
                        }
                    }
                }
                const a = sum_a / count;
                const r = sum_r / count;
                const g = sum_g / count;
                const b = sum_b / count;
                next_pixels[ny * next_w + nx] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        mip_levels.append(allocator, next_pixels) catch {
            allocator.free(next_pixels);
            break;
        };
        current_pixels = next_pixels;
        current_w = next_w;
        current_h = next_h;
    }

    return Texture{ .width = width, .height = height, .pixels = pixels, .mip_levels = mip_levels, .allocator = allocator };
}
