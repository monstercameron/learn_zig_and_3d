const std = @import("std");

pub const RenderPassId = enum {
    skybox,
    shadow_map,
    shadow_resolve,
    hybrid_shadow,
    ssao,
    ssgi,
    ssr,
    depth_fog,
    taa,
    motion_blur,
    god_rays,
    bloom,
    lens_flare,
    dof,
    chromatic_aberration,
    film_grain_vignette,
    color_grade,
};

pub const PassFlags = packed struct(u8) {
    reads_depth: bool = false,
    writes_color: bool = true,
    requires_history: bool = false,
    reserved: u5 = 0,
};

pub const PassNode = struct {
    id: RenderPassId,
    name: []const u8,
    flags: PassFlags = .{},
};

pub const default_post_pass_order = [_]PassNode{
    .{ .id = .skybox, .name = "skybox", .flags = .{ .reads_depth = true } },
    .{ .id = .shadow_resolve, .name = "shadow_resolve", .flags = .{ .reads_depth = true } },
    .{ .id = .hybrid_shadow, .name = "hybrid_shadow", .flags = .{ .reads_depth = true } },
    .{ .id = .ssao, .name = "ssao", .flags = .{ .reads_depth = true } },
    .{ .id = .ssgi, .name = "ssgi", .flags = .{ .reads_depth = true } },
    .{ .id = .ssr, .name = "ssr", .flags = .{ .reads_depth = true } },
    .{ .id = .depth_fog, .name = "depth_fog", .flags = .{ .reads_depth = true } },
    .{ .id = .taa, .name = "taa", .flags = .{ .reads_depth = true, .requires_history = true } },
    .{ .id = .motion_blur, .name = "motion_blur", .flags = .{ .requires_history = true } },
    .{ .id = .god_rays, .name = "god_rays", .flags = .{} },
    .{ .id = .bloom, .name = "bloom", .flags = .{} },
    .{ .id = .lens_flare, .name = "lens_flare", .flags = .{} },
    .{ .id = .dof, .name = "dof", .flags = .{ .reads_depth = true } },
    .{ .id = .chromatic_aberration, .name = "chromatic_aberration", .flags = .{} },
    .{ .id = .film_grain_vignette, .name = "film_grain_vignette", .flags = .{} },
    .{ .id = .color_grade, .name = "color_grade", .flags = .{} },
};

pub const post_pass_count: usize = default_post_pass_order.len;

pub fn passIndex(id: RenderPassId) ?usize {
    for (default_post_pass_order, 0..) |node, idx| {
        if (node.id == id) return idx;
    }
    return null;
}

pub fn passBit(id: RenderPassId) u64 {
    const idx = passIndex(id) orelse return 0;
    return @as(u64, 1) << @as(u6, @intCast(idx));
}

pub fn allPassMask() u64 {
    if (post_pass_count == 0) return 0;
    if (post_pass_count >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(post_pass_count))) - 1;
}

pub fn containsPass(id: RenderPassId) bool {
    for (default_post_pass_order) |node| {
        if (node.id == id) return true;
    }
    return false;
}

test "default pass order contains depth fog" {
    try std.testing.expect(containsPass(.depth_fog));
}

test "pass index and bit are stable" {
    const taa_idx = passIndex(.taa) orelse unreachable;
    try std.testing.expect(taa_idx < post_pass_count);
    try std.testing.expect(passBit(.taa) != 0);
}
