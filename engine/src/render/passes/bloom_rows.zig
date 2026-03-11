const math = @import("../../core/math.zig");
const render_utils = @import("../core/utils.zig");

fn averageBlur5(sum: i32) u8 {
    return @intCast(@divTrunc(sum + 2, 5));
}

pub fn extractDownsampleRows(
    src: []u32,
    src_width: usize,
    src_height: usize,
    bloom: anytype,
    threshold_curve: *const [256]u8,
    start_row: usize,
    end_row: usize,
) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const sy0 = @min(src_height - 1, y << 2);
        const sy1 = @min(src_height - 1, sy0 + 1);
        const sy2 = @min(src_height - 1, sy0 + 2);
        const sy3 = @min(src_height - 1, sy0 + 3);
        const row0 = sy0 * src_width;
        const row1 = sy1 * src_width;
        const row2 = sy2 * src_width;
        const row3 = sy3 * src_width;
        const dst_row = y * bloom.width;

        var x: usize = 0;
        while (x < bloom.width) : (x += 1) {
            const sx = x << 2;
            var r_sum: u32 = 0;
            var g_sum: u32 = 0;
            var b_sum: u32 = 0;
            inline for (0..4) |dx| {
                const sample_x = @min(src_width - 1, sx + dx);
                const p0 = src[row0 + sample_x];
                const p1 = src[row1 + sample_x];
                const p2 = src[row2 + sample_x];
                const p3 = src[row3 + sample_x];
                r_sum += (p0 >> 16) & 0xFF; g_sum += (p0 >> 8) & 0xFF; b_sum += p0 & 0xFF;
                r_sum += (p1 >> 16) & 0xFF; g_sum += (p1 >> 8) & 0xFF; b_sum += p1 & 0xFF;
                r_sum += (p2 >> 16) & 0xFF; g_sum += (p2 >> 8) & 0xFF; b_sum += p2 & 0xFF;
                r_sum += (p3 >> 16) & 0xFF; g_sum += (p3 >> 8) & 0xFF; b_sum += p3 & 0xFF;
            }

            const r = r_sum >> 4;
            const g = g_sum >> 4;
            const b = b_sum >> 4;
            const luma: usize = @intCast((r_sum * 77 + g_sum * 150 + b_sum * 29) >> 12);
            const factor = threshold_curve[luma];
            if (factor == 0) {
                bloom.ping[dst_row + x] = 0xFF000000;
            } else {
                const br = render_utils.fastScale255(r, factor);
                const bg = render_utils.fastScale255(g, factor);
                const bb = render_utils.fastScale255(b, factor);
                bloom.ping[dst_row + x] = 0xFF000000 | (@as(u32, br) << 16) | (@as(u32, bg) << 8) | @as(u32, bb);
            }
        }
    }
}

pub fn blurHorizontalRows(bloom: anytype, start_row: usize, end_row: usize) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const row_start = y * bloom.width;
        const src_row = bloom.ping[row_start .. row_start + bloom.width];
        const dst_row = bloom.pong[row_start .. row_start + bloom.width];
        const edge1 = @min(bloom.width - 1, @as(usize, 1));
        const edge2 = @min(bloom.width - 1, @as(usize, 2));
        const p0 = src_row[0];
        const p1 = src_row[edge1];
        const p2 = src_row[edge2];
        var r: i32 = @intCast(((p0 >> 16) & 0xFF) * 3 + ((p1 >> 16) & 0xFF) + ((p2 >> 16) & 0xFF));
        var g: i32 = @intCast(((p0 >> 8) & 0xFF) * 3 + ((p1 >> 8) & 0xFF) + ((p2 >> 8) & 0xFF));
        var b: i32 = @intCast((p0 & 0xFF) * 3 + (p1 & 0xFF) + (p2 & 0xFF));

        var x: usize = 0;
        while (x < bloom.width) : (x += 1) {
            dst_row[x] = 0xFF000000 | (@as(u32, averageBlur5(r)) << 16) | (@as(u32, averageBlur5(g)) << 8) | @as(u32, averageBlur5(b));
            if (x + 1 >= bloom.width) break;
            const remove_idx = if (x >= 2) x - 2 else 0;
            const add_idx = @min(bloom.width - 1, x + 3);
            const remove_pixel = src_row[remove_idx];
            const add_pixel = src_row[add_idx];
            r += @as(i32, @intCast((add_pixel >> 16) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 16) & 0xFF));
            g += @as(i32, @intCast((add_pixel >> 8) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 8) & 0xFF));
            b += @as(i32, @intCast(add_pixel & 0xFF)) - @as(i32, @intCast(remove_pixel & 0xFF));
        }
    }
}

pub fn blurVerticalRows(bloom: anytype, start_row: usize, end_row: usize) void {
    var x: usize = 0;
    while (x < bloom.width) : (x += 1) {
        var r: i32 = 0;
        var g: i32 = 0;
        var b: i32 = 0;
        var offset: i32 = -2;
        while (offset <= 2) : (offset += 1) {
            const sample_y = @min(bloom.height - 1, @as(usize, @intCast(@max(0, @as(i32, @intCast(start_row)) + offset))));
            const pixel = bloom.pong[sample_y * bloom.width + x];
            r += @intCast((pixel >> 16) & 0xFF);
            g += @intCast((pixel >> 8) & 0xFF);
            b += @intCast(pixel & 0xFF);
        }

        var y = start_row;
        while (y < end_row) : (y += 1) {
            bloom.ping[y * bloom.width + x] = 0xFF000000 | (@as(u32, averageBlur5(r)) << 16) | (@as(u32, averageBlur5(g)) << 8) | @as(u32, averageBlur5(b));
            if (y + 1 >= end_row) break;
            const remove_idx = if (y >= 2) y - 2 else 0;
            const add_idx = @min(bloom.height - 1, y + 3);
            const remove_pixel = bloom.pong[remove_idx * bloom.width + x];
            const add_pixel = bloom.pong[add_idx * bloom.width + x];
            r += @as(i32, @intCast((add_pixel >> 16) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 16) & 0xFF));
            g += @as(i32, @intCast((add_pixel >> 8) & 0xFF)) - @as(i32, @intCast((remove_pixel >> 8) & 0xFF));
            b += @as(i32, @intCast(add_pixel & 0xFF)) - @as(i32, @intCast(remove_pixel & 0xFF));
        }
    }
}

pub fn compositeRows(dst: []u32, dst_width: usize, bloom: anytype, intensity_lut: *const [256]u8, start_row: usize, end_row: usize) void {
    var y = start_row;
    while (y < end_row) : (y += 1) {
        const by = @min(bloom.height - 1, y >> 2);
        const bloom_row = bloom.ping[by * bloom.width ..][0..bloom.width];
        const row_start = y * dst_width;
        var x: usize = 0;
        while (x < dst_width) : (x += 1) {
            const bloom_pixel = bloom_row[@min(bloom.width - 1, x >> 2)];
            const idx = row_start + x;
            const dst_pixel = dst[idx];
            const a = dst_pixel & 0xFF000000;
            const r = @as(i32, @intCast((dst_pixel >> 16) & 0xFF)) + intensity_lut[(bloom_pixel >> 16) & 0xFF];
            const g = @as(i32, @intCast((dst_pixel >> 8) & 0xFF)) + intensity_lut[(bloom_pixel >> 8) & 0xFF];
            const b = @as(i32, @intCast(dst_pixel & 0xFF)) + intensity_lut[bloom_pixel & 0xFF];
            dst[idx] = a |
                (@as(u32, render_utils.clampByte(r)) << 16) |
                (@as(u32, render_utils.clampByte(g)) << 8) |
                @as(u32, render_utils.clampByte(b));
        }
    }
}
