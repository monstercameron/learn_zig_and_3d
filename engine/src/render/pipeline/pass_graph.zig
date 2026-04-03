//! Pass Graph module.
//! Render pipeline graph/registry/dispatch definitions for pass execution order and toggles.

const std = @import("std");

pub const RenderPassId = enum {
    skybox,
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

pub const PassPhase = enum {
    scene,
    geometry_post,
    lighting_scatter,
    final_color,
};

pub const SurfaceTarget = enum {
    main,
    scratch_a,
    scratch_b,
    history,
};

pub const ResourceId = enum(u8) {
    scene_color,
    scene_depth,
    scene_normals,
    scene_surface,
    shadow_buffer,
    history_color,
    scratch_a,
    scratch_b,
};

pub const ResourceMask = u32;

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
    phase: PassPhase = .final_color,
    output_target: SurfaceTarget = .main,
    reads: ResourceMask = 0,
    writes: ResourceMask = 0,
};

pub const default_post_pass_order = [_]PassNode{
    .{
        .id = .skybox,
        .name = "skybox",
        .flags = .{ .reads_depth = true },
        .phase = .scene,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .shadow_resolve,
        .name = "shadow_resolve",
        .flags = .{ .reads_depth = true },
        .phase = .scene,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .shadow_buffer }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .hybrid_shadow,
        .name = "hybrid_shadow",
        .flags = .{ .reads_depth = true },
        .phase = .scene,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .ssao,
        .name = "ssao",
        .flags = .{ .reads_depth = true },
        .phase = .geometry_post,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .ssgi,
        .name = "ssgi",
        .flags = .{ .reads_depth = true },
        .phase = .geometry_post,
        .output_target = .scratch_a,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
        .writes = resourceMask(&.{.scratch_a}),
    },
    .{
        .id = .ssr,
        .name = "ssr",
        .flags = .{ .reads_depth = true },
        .phase = .geometry_post,
        .output_target = .scratch_b,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
        .writes = resourceMask(&.{.scratch_b}),
    },
    .{
        .id = .depth_fog,
        .name = "depth_fog",
        .flags = .{ .reads_depth = true },
        .phase = .geometry_post,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .taa,
        .name = "taa",
        .flags = .{ .reads_depth = true, .requires_history = true },
        .phase = .geometry_post,
        .output_target = .history,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .scene_normals, .scene_surface, .history_color }),
        .writes = resourceMask(&.{ .scene_color, .history_color }),
    },
    .{
        .id = .motion_blur,
        .name = "motion_blur",
        .flags = .{ .requires_history = true },
        .phase = .geometry_post,
        .output_target = .scratch_a,
        .reads = resourceMask(&.{ .scene_color, .scene_depth, .history_color }),
        .writes = resourceMask(&.{.scratch_a}),
    },
    .{
        .id = .god_rays,
        .name = "god_rays",
        .flags = .{},
        .phase = .lighting_scatter,
        .output_target = .scratch_a,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scratch_a}),
    },
    .{
        .id = .bloom,
        .name = "bloom",
        .flags = .{},
        .phase = .lighting_scatter,
        .output_target = .main,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .lens_flare,
        .name = "lens_flare",
        .flags = .{},
        .phase = .lighting_scatter,
        .output_target = .scratch_a,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scratch_a}),
    },
    .{
        .id = .dof,
        .name = "dof",
        .flags = .{ .reads_depth = true },
        .phase = .final_color,
        .output_target = .main,
        .reads = resourceMask(&.{ .scene_color, .scene_depth }),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .chromatic_aberration,
        .name = "chromatic_aberration",
        .flags = .{},
        .phase = .final_color,
        .output_target = .scratch_a,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scratch_a}),
    },
    .{
        .id = .film_grain_vignette,
        .name = "film_grain_vignette",
        .flags = .{},
        .phase = .final_color,
        .output_target = .main,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scene_color}),
    },
    .{
        .id = .color_grade,
        .name = "color_grade",
        .flags = .{},
        .phase = .final_color,
        .output_target = .main,
        .reads = resourceMask(&.{.scene_color}),
        .writes = resourceMask(&.{.scene_color}),
    },
};

pub const post_pass_count: usize = default_post_pass_order.len;

/// Returns pass index.
/// Keeps pass index as the single implementation point so call-site behavior stays consistent.
pub fn passIndex(id: RenderPassId) ?usize {
    for (default_post_pass_order, 0..) |node, idx| {
        if (node.id == id) return idx;
    }
    return null;
}

/// Performs pass bit.
/// Keeps pass bit as the single implementation point so call-site behavior stays consistent.
pub fn passBit(id: RenderPassId) u64 {
    const idx = passIndex(id) orelse return 0;
    return @as(u64, 1) << @as(u6, @intCast(idx));
}

/// Performs pass node.
/// Keeps pass node as the single implementation point so call-site behavior stays consistent.
pub fn passNode(id: RenderPassId) ?PassNode {
    for (default_post_pass_order) |node| {
        if (node.id == id) return node;
    }
    return null;
}

pub fn resourceBit(id: ResourceId) ResourceMask {
    return @as(ResourceMask, 1) << @as(u5, @intCast(@intFromEnum(id)));
}

pub fn resourceMask(comptime ids: []const ResourceId) ResourceMask {
    var mask: ResourceMask = 0;
    for (ids) |id| mask |= resourceBit(id);
    return mask;
}

/// Returns all pass mask.
/// Keeps all pass mask as the single implementation point so call-site behavior stays consistent.
pub fn allPassMask() u64 {
    if (post_pass_count == 0) return 0;
    if (post_pass_count >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(post_pass_count))) - 1;
}

/// Returns whether contains pass.
/// Keeps contains pass as the single implementation point so call-site behavior stays consistent.
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
