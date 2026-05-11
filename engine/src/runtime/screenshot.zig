//! Frame screenshot capture — dumps the presented framebuffer as a
//! 24-bit BMP for visual verification.
//!
//! Env-controlled. Set `ZIG_SCREENSHOT_PATH=path.bmp` to enable.
//! Trigger options:
//!   - `ZIG_SCREENSHOT_TIME_S=5.0`  — fire after N seconds elapsed
//!     (preferred; works regardless of frame rate)
//!   - `ZIG_SCREENSHOT_FRAME=60`    — fire after N monotonic frames
//!     (legacy; uses renderer.total_frames_rendered)
//! The first satisfied trigger captures the frame and disables further
//! writes.

const std = @import("std");

var enabled_initialized: bool = false;
var enabled_cached: bool = false;
var path_buf: [260]u8 = undefined;
var path_len: usize = 0;
var trigger_frame: u64 = 60;
var trigger_time_s: f64 = -1.0;
var start_time_ns: ?i128 = null;
var captured: bool = false;

pub fn isEnabled() bool {
    if (enabled_initialized) return enabled_cached;
    enabled_initialized = true;
    enabled_cached = std.process.hasEnvVarConstant("ZIG_SCREENSHOT_PATH");
    if (!enabled_cached) return false;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ZIG_SCREENSHOT_PATH")) |path| {
        defer std.heap.page_allocator.free(path);
        const copy_len = @min(path.len, path_buf.len);
        @memcpy(path_buf[0..copy_len], path[0..copy_len]);
        path_len = copy_len;
    } else |_| {
        enabled_cached = false;
        return false;
    }
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ZIG_SCREENSHOT_FRAME")) |frame_str| {
        defer std.heap.page_allocator.free(frame_str);
        trigger_frame = std.fmt.parseUnsigned(u64, frame_str, 10) catch 60;
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ZIG_SCREENSHOT_TIME_S")) |time_str| {
        defer std.heap.page_allocator.free(time_str);
        trigger_time_s = std.fmt.parseFloat(f64, time_str) catch -1.0;
    } else |_| {}
    return enabled_cached;
}

pub fn shouldCapture(frame_index: u64) bool {
    if (captured) return false;
    if (!isEnabled()) return false;
    const now = std.time.nanoTimestamp();
    if (start_time_ns == null) start_time_ns = now;
    if (trigger_time_s > 0.0) {
        const elapsed_ns = now - start_time_ns.?;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        return elapsed_s >= trigger_time_s;
    }
    return frame_index >= trigger_frame;
}

/// Writes pixels (assumed 0xAARRGGBB little-endian u32) as a 24-bit BMP.
/// Pixels are interpreted as a width×height row-major buffer where row 0
/// is the top of the image; BMP wants rows bottom-up so we reverse on
/// write.
pub fn capture(pixels: []const u32, width: i32, height: i32) void {
    if (captured) return;
    if (path_len == 0) return;
    const path = path_buf[0..path_len];

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    // BMP requires each row padded to a multiple of 4 bytes. 3 bytes per
    // pixel × width may not be aligned, so we compute padding.
    const row_bytes = w * 3;
    const pad = (4 - (row_bytes % 4)) % 4;
    const row_stride = row_bytes + pad;
    const pixel_data_size: u32 = @intCast(row_stride * h);
    const headers_size: u32 = 14 + 40;
    const file_size: u32 = headers_size + pixel_data_size;

    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();

    // ----- 14-byte BITMAPFILEHEADER -----
    var hdr: [14]u8 = undefined;
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u16, hdr[6..8], 0, .little);
    std.mem.writeInt(u16, hdr[8..10], 0, .little);
    std.mem.writeInt(u32, hdr[10..14], headers_size, .little);
    file.writeAll(&hdr) catch return;

    // ----- 40-byte BITMAPINFOHEADER -----
    var info: [40]u8 = undefined;
    std.mem.writeInt(u32, info[0..4], 40, .little); // header size
    std.mem.writeInt(i32, info[4..8], width, .little);
    std.mem.writeInt(i32, info[8..12], height, .little); // positive = bottom-up
    std.mem.writeInt(u16, info[12..14], 1, .little); // planes
    std.mem.writeInt(u16, info[14..16], 24, .little); // bits per pixel
    std.mem.writeInt(u32, info[16..20], 0, .little); // compression = BI_RGB
    std.mem.writeInt(u32, info[20..24], pixel_data_size, .little);
    std.mem.writeInt(i32, info[24..28], 2835, .little); // 72 DPI horizontal
    std.mem.writeInt(i32, info[28..32], 2835, .little); // 72 DPI vertical
    std.mem.writeInt(u32, info[32..36], 0, .little); // colours used
    std.mem.writeInt(u32, info[36..40], 0, .little); // important colours
    file.writeAll(&info) catch return;

    // ----- pixel data, bottom-up -----
    // Reuse a row buffer to avoid an allocation. Cap at 16K which covers
    // any sensible window width.
    var row_buf: [16 * 1024]u8 = undefined;
    const usable_row = row_stride;
    if (usable_row > row_buf.len) return;

    var y: usize = h;
    while (y > 0) {
        y -= 1;
        const src_row_start = y * w;
        var x: usize = 0;
        var di: usize = 0;
        while (x < w) : (x += 1) {
            const p = pixels[src_row_start + x];
            row_buf[di] = @truncate(p); // B
            row_buf[di + 1] = @truncate(p >> 8); // G
            row_buf[di + 2] = @truncate(p >> 16); // R
            di += 3;
        }
        // Zero the padding bytes.
        var pi: usize = 0;
        while (pi < pad) : (pi += 1) {
            row_buf[di + pi] = 0;
        }
        file.writeAll(row_buf[0..usable_row]) catch return;
    }
    captured = true;
}
