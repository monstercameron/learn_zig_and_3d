const std = @import("std");
const math = @import("../../core/math.zig");
const direct_batch = @import("../direct_batch.zig");

pub const LightConfig = struct {
    ambient: f32 = 0.18,
    diffuse: f32 = 0.82,
    light_dir: math.Vec3 = math.Vec3.new(-0.35, -0.45, 0.82),
};

pub fn applyBatchLighting(batch: *direct_batch.PrimitiveBatch, config: LightConfig) void {
    const light_dir = normalize(config.light_dir);
    for (batch.commands.items) |*command| {
        switch (command.*) {
            .triangle => |*payload| {
                const vertex_normals = payload.vertex_normals orelse continue;
                payload.gouraud_colors = shadeTriangle(payload.material.fill_color, vertex_normals, light_dir, config);
            },
            else => {},
        }
    }
}

inline fn normalize(v: math.Vec3) math.Vec3 {
    const len_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    if (len_sq <= 1e-8) return math.Vec3.new(0.0, 0.0, 1.0);
    if (@abs(len_sq - 1.0) <= 1e-4) return v;
    const inv_len = 1.0 / std.math.sqrt(len_sq);
    return math.Vec3.new(v.x * inv_len, v.y * inv_len, v.z * inv_len);
}

inline fn shadeColor(base_color: u32, normal: math.Vec3, light_dir: math.Vec3, config: LightConfig) u32 {
    const n = normalize(normal);
    const diffuse = std.math.clamp(math.Vec3.dot(n, light_dir), 0.0, 1.0);
    const intensity = std.math.clamp(config.ambient + config.diffuse * diffuse, 0.0, 1.0);
    const factor: u32 = @intFromFloat(intensity * 255.0 + 0.5);
    const a: u32 = base_color & 0xFF000000;
    const r = (((base_color >> 16) & 0xFF) * factor + 127) / 255;
    const g = (((base_color >> 8) & 0xFF) * factor + 127) / 255;
    const b = (((base_color) & 0xFF) * factor + 127) / 255;
    return a | (r << 16) | (g << 8) | b;
}

inline fn shadeTriangle(base_color: u32, normals: [3]math.Vec3, light_dir: math.Vec3, config: LightConfig) [3]u32 {
    const channels = unpackBaseColor(base_color);
    const Vec = @Vector(4, f32);
    const nx: Vec = .{ normals[0].x, normals[1].x, normals[2].x, 0.0 };
    const ny: Vec = .{ normals[0].y, normals[1].y, normals[2].y, 0.0 };
    const nz: Vec = .{ normals[0].z, normals[1].z, normals[2].z, 1.0 };
    const len_sq = nx * nx + ny * ny + nz * nz;

    var normalized_x = nx;
    var normalized_y = ny;
    var normalized_z = nz;
    inline for (0..3) |lane| {
        const lane_len_sq = len_sq[lane];
        if (lane_len_sq <= 1e-8) {
            normalized_x[lane] = 0.0;
            normalized_y[lane] = 0.0;
            normalized_z[lane] = 1.0;
        } else if (@abs(lane_len_sq - 1.0) > 1e-4) {
            const inv_len = 1.0 / std.math.sqrt(lane_len_sq);
            normalized_x[lane] *= inv_len;
            normalized_y[lane] *= inv_len;
            normalized_z[lane] *= inv_len;
        }
    }

    const light_x: Vec = @splat(light_dir.x);
    const light_y: Vec = @splat(light_dir.y);
    const light_z: Vec = @splat(light_dir.z);
    const ambient: Vec = @splat(config.ambient);
    const diffuse_scale: Vec = @splat(config.diffuse);
    const zero: Vec = @splat(0.0);
    const one: Vec = @splat(1.0);
    const factor_scale: Vec = @splat(255.0);

    const diffuse = @min(@max(normalized_x * light_x + normalized_y * light_y + normalized_z * light_z, zero), one);
    const intensity = @min(@max(ambient + diffuse_scale * diffuse, zero), one);
    const factors = intensity * factor_scale + @as(Vec, @splat(0.5));

    return .{
        shadeColorWithFactor(channels, @intFromFloat(factors[0])),
        shadeColorWithFactor(channels, @intFromFloat(factors[1])),
        shadeColorWithFactor(channels, @intFromFloat(factors[2])),
    };
}

const BaseColor = struct {
    a: u32,
    r: u32,
    g: u32,
    b: u32,
};

inline fn unpackBaseColor(base_color: u32) BaseColor {
    return .{
        .a = base_color & 0xFF000000,
        .r = (base_color >> 16) & 0xFF,
        .g = (base_color >> 8) & 0xFF,
        .b = base_color & 0xFF,
    };
}

inline fn shadeColorWithFactor(base_color: BaseColor, factor: u32) u32 {
    const r = ((base_color.r * factor) + 127) / 255;
    const g = ((base_color.g * factor) + 127) / 255;
    const b = ((base_color.b * factor) + 127) / 255;
    return base_color.a | (r << 16) | (g << 8) | b;
}

test "gouraud kernel shades per-vertex colors" {
    var batch = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();

    try batch.appendTriangleLit(.{
        .a = math.Vec3.new(0.0, 1.0, 2.0),
        .b = math.Vec3.new(-1.0, -1.0, 2.0),
        .c = math.Vec3.new(1.0, -1.0, 2.0),
    }, .{ .fill_color = 0xFF808080 }, .{
        math.Vec3.new(0.0, 0.0, 1.0),
        math.Vec3.new(0.0, 0.0, 1.0),
        math.Vec3.new(0.0, 0.0, 1.0),
    });

    applyBatchLighting(&batch, .{});

    try std.testing.expect(batch.items()[0].triangle.gouraud_colors != null);
}
