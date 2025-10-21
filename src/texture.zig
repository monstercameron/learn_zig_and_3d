const std = @import("std");
const math = @import("math.zig");

inline fn readU16le(bytes: []const u8) u16 {
    return (@as(u16, bytes[0])) | (@as(u16, bytes[1]) << 8);
}

inline fn readU32le(bytes: []const u8) u32 {
    return (@as(u32, bytes[0])) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

inline fn readI32le(bytes: []const u8) i32 {
    return @bitCast(readU32le(bytes));
}

pub const Texture = struct {
    width: usize,
    height: usize,
    pixels: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.pixels);
    }

    pub fn sample(self: *const Texture, uv: math.Vec2) u32 {
        if (self.width == 0 or self.height == 0) return 0xFF000000;

        const u = std.math.clamp(uv.x, 0.0, 1.0);
        const v = std.math.clamp(uv.y, 0.0, 1.0);

        const max_x = if (self.width > 0) self.width - 1 else 0;
        const max_y = if (self.height > 0) self.height - 1 else 0;

    const x_f = u * @as(f32, @floatFromInt(max_x));
    const y_f = v * @as(f32, @floatFromInt(max_y));

    const x = @min(@as(usize, @intFromFloat(@floor(x_f + 0.5))), max_x);
    const y = @min(@as(usize, @intFromFloat(@floor(y_f + 0.5))), max_y);

        return self.pixels[y * self.width + x];
    }
};

pub fn loadBmp(allocator: std.mem.Allocator, path: []const u8) !Texture {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    if (data.len < 54) return error.InvalidBmpHeader;

    if (!(data[0] == 'B' and data[1] == 'M')) return error.InvalidBmpSignature;

    const pixel_offset = @as(usize, @intCast(readU32le(data[10..14])));

    const dib_slice = data[14..];
    if (dib_slice.len < 40) return error.InvalidBmpHeader;

    const header_size = readU32le(dib_slice[0..4]);
    if (header_size < 40) return error.UnsupportedBmpCompression; // minimal BITMAPINFOHEADER size

    const width_signed = readI32le(dib_slice[4..8]);
    const height_signed = readI32le(dib_slice[8..12]);
    const planes = readU16le(dib_slice[12..14]);
    const bit_count = readU16le(dib_slice[14..16]);
    const compression = readU32le(dib_slice[16..20]);

    if (planes != 1) return error.UnsupportedBmpPlanes;
    if (compression != 0) return error.UnsupportedBmpCompression;
    if (bit_count != 24 and bit_count != 32) return error.UnsupportedBmpBitDepth;
    if (width_signed <= 0) return error.UnsupportedBmpDimension;
    if (height_signed == 0) return error.UnsupportedBmpDimension;

    const width = @as(usize, @intCast(width_signed));
    const flipped = height_signed > 0;
    const height = @as(usize, @intCast(if (height_signed < 0) -height_signed else height_signed));

    const bytes_per_pixel = @divExact(bit_count, 8);
    const row_stride = ((@as(usize, bit_count) * width + 31) / 32) * 4;

    if (pixel_offset + row_stride * height > data.len) return error.BmpDataTruncated;

    const pixel_data = data[pixel_offset .. pixel_offset + row_stride * height];

    const pixel_count = width * height;
    const pixels = try allocator.alloc(u32, pixel_count);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_y = if (flipped) (height - 1 - y) else y;
        const row = pixel_data[src_y * row_stride .. src_y * row_stride + row_stride];

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const base = x * bytes_per_pixel;
            if (base + bytes_per_pixel > row.len) return error.BmpRowOverflow;

            const b = row[base];
            const g = row[base + 1];
            const r = row[base + 2];
            const a: u8 = if (bytes_per_pixel == 4) row[base + 3] else 0xFF;

            const dest_index = y * width + x;
            pixels[dest_index] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        }
    }

    return Texture{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
}
