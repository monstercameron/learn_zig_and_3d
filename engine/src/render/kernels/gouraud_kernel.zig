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
    const packed_config = PackedLightConfig.init(light_dir, config);
    for (batch.commands.items) |*command| {
        switch (command.*) {
            .triangle => |*payload| {
                const vertex_normals = payload.vertex_normals orelse continue;
                payload.gouraud_colors = shadeTriangle(payload.material.fill_color, vertex_normals, packed_config);
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

inline fn shadeTriangle(base_color: u32, normals: [3]math.Vec3, packed_config: PackedLightConfig) [3]u32 {
    const channels = unpackBaseColor(base_color);
    const Vec = @Vector(4, f32);
    const nx: Vec = .{ normals[0].x, normals[1].x, normals[2].x, 0.0 };
    const ny: Vec = .{ normals[0].y, normals[1].y, normals[2].y, 0.0 };
    const nz: Vec = .{ normals[0].z, normals[1].z, normals[2].z, 1.0 };
    const normalized = normalizeTriangleNormals(nx, ny, nz);
    return shadeTriangleColors(channels, triangleShadeFactors(normalized.x, normalized.y, normalized.z, packed_config));
}

const PackedLightConfig = struct {
    light_x: @Vector(4, f32),
    light_y: @Vector(4, f32),
    light_z: @Vector(4, f32),
    ambient: @Vector(4, f32),
    diffuse_scale: @Vector(4, f32),

    inline fn init(light_dir: math.Vec3, config: LightConfig) PackedLightConfig {
        return .{
            .light_x = @splat(light_dir.x),
            .light_y = @splat(light_dir.y),
            .light_z = @splat(light_dir.z),
            .ambient = @splat(config.ambient),
            .diffuse_scale = @splat(config.diffuse),
        };
    }
};

const PackedNormals = struct {
    x: @Vector(4, f32),
    y: @Vector(4, f32),
    z: @Vector(4, f32),
};

inline fn normalizeTriangleNormals(nx: @Vector(4, f32), ny: @Vector(4, f32), nz: @Vector(4, f32)) PackedNormals {
    const Vec = @Vector(4, f32);
    const eps: Vec = @splat(1e-8);
    const one: Vec = @splat(1.0);
    const zero: Vec = @splat(0.0);
    const len_sq = nx * nx + ny * ny + nz * nz;
    const safe_len_sq = @max(len_sq, eps);
    const inv_len = one / @sqrt(safe_len_sq);
    const zero_mask = len_sq <= eps;
    const unit_mask = @abs(len_sq - one) <= @as(Vec, @splat(1e-4));
    const scaled_x = nx * inv_len;
    const scaled_y = ny * inv_len;
    const scaled_z = nz * inv_len;
    const candidate_x = @select(f32, unit_mask, nx, scaled_x);
    const candidate_y = @select(f32, unit_mask, ny, scaled_y);
    const candidate_z = @select(f32, unit_mask, nz, scaled_z);
    return .{
        .x = @select(f32, zero_mask, zero, candidate_x),
        .y = @select(f32, zero_mask, zero, candidate_y),
        .z = @select(f32, zero_mask, one, candidate_z),
    };
}

inline fn triangleShadeFactors(nx: @Vector(4, f32), ny: @Vector(4, f32), nz: @Vector(4, f32), packed_config: PackedLightConfig) @Vector(4, u32) {
    const Vec = @Vector(4, f32);
    const zero: Vec = @splat(0.0);
    const one: Vec = @splat(1.0);
    const factor_scale: Vec = @splat(255.0);
    const bias: Vec = @splat(0.5);

    const diffuse = @min(@max(nx * packed_config.light_x + ny * packed_config.light_y + nz * packed_config.light_z, zero), one);
    const intensity = @min(@max(packed_config.ambient + packed_config.diffuse_scale * diffuse, zero), one);
    return @intFromFloat(intensity * factor_scale + bias);
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

inline fn shadeTriangleColors(base_color: BaseColor, factors: @Vector(4, u32)) [3]u32 {
    const Vec = @Vector(4, u32);
    const bias: Vec = @splat(127);
    const scale: Vec = @splat(257);
    const shift: Vec = @splat(16);
    const r = (((@as(Vec, @splat(base_color.r)) * factors + bias) * scale) >> shift);
    const g = (((@as(Vec, @splat(base_color.g)) * factors + bias) * scale) >> shift);
    const b = (((@as(Vec, @splat(base_color.b)) * factors + bias) * scale) >> shift);
    return .{
        base_color.a | (r[0] << 16) | (g[0] << 8) | b[0],
        base_color.a | (r[1] << 16) | (g[1] << 8) | b[1],
        base_color.a | (r[2] << 16) | (g[2] << 8) | b[2],
    };
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
