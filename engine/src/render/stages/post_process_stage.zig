const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");

pub const Config = struct {
    enabled: bool = false,
    clear_color: u32 = 0xFF0B1220,
    lift: i16 = 0,
};

pub const Result = struct {
    present_rect: ?direct_primitives.Rect2i = null,
    processed_pixels: usize = 0,
};

pub fn execute(
    resources: frame_resources.FrameResources,
    composed_rect: ?direct_primitives.Rect2i,
    config: Config,
) Result {
    const rect = composed_rect orelse return .{};
    const bounds = direct_primitives.intersectRect(rect, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = resources.target.width - 1,
        .max_y = resources.target.height - 1,
    }) orelse return .{};
    if (bounds.min_x > bounds.max_x or bounds.min_y > bounds.max_y) return .{};
    if (!config.enabled or config.lift == 0) {
        return .{ .present_rect = bounds, .processed_pixels = 0 };
    }

    const color = resources.target.color;
    const stride: usize = @intCast(resources.target.width);
    var processed_pixels: usize = 0;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const row_start = @as(usize, @intCast(y)) * stride;
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const idx = row_start + @as(usize, @intCast(x));
            const pixel = color[idx];
            if (pixel == config.clear_color) continue;
            color[idx] = applyLift(pixel, config.lift);
            processed_pixels += 1;
        }
    }

    return .{
        .present_rect = bounds,
        .processed_pixels = processed_pixels,
    };
}

inline fn applyLift(color: u32, lift: i16) u32 {
    const a = color & 0xFF000000;
    const r = clampChannel(@as(i16, @intCast((color >> 16) & 0xFF)) + lift);
    const g = clampChannel(@as(i16, @intCast((color >> 8) & 0xFF)) + lift);
    const b = clampChannel(@as(i16, @intCast(color & 0xFF)) + lift);
    return a | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

inline fn clampChannel(value: i16) u8 {
    return @intCast(@max(@as(i16, 0), @min(@as(i16, 255), value)));
}

test "post process stage identity fast path forwards rect without touching pixels" {
    var color = [_]u32{
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
        0xFF0B1220, 0xFFFF0000, 0xFF00FF00, 0xFF0B1220,
        0xFF0B1220, 0xFF0000FF, 0xFFFFFFFF, 0xFF0B1220,
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
    };
    const original = color;
    const resources: frame_resources.FrameResources = .{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
        },
        .aux = .{
            .scene_camera = &.{},
            .scene_normal = &.{},
            .scene_surface = &.{},
        },
    };

    const result = execute(resources, .{
        .min_x = 1,
        .min_y = 1,
        .max_x = 2,
        .max_y = 2,
    }, .{});

    try @import("std").testing.expectEqual(@as(usize, 0), result.processed_pixels);
    try @import("std").testing.expectEqualSlices(u32, original[0..], color[0..]);
}

test "post process stage can brighten composed pixels" {
    var color = [_]u32{
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
        0xFF0B1220, 0xFF101010, 0xFF202020, 0xFF0B1220,
        0xFF0B1220, 0xFF303030, 0xFF404040, 0xFF0B1220,
        0xFF0B1220, 0xFF0B1220, 0xFF0B1220, 0xFF0B1220,
    };
    const resources: frame_resources.FrameResources = .{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
        },
        .aux = .{
            .scene_camera = &.{},
            .scene_normal = &.{},
            .scene_surface = &.{},
        },
    };

    const result = execute(resources, .{
        .min_x = 1,
        .min_y = 1,
        .max_x = 2,
        .max_y = 2,
    }, .{ .enabled = true, .lift = 8 });

    try @import("std").testing.expectEqual(@as(usize, 4), result.processed_pixels);
    try @import("std").testing.expect(color[5] != 0xFF101010);
}
