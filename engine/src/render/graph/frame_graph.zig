const std = @import("std");
pub const pass_graph = @import("../pipeline/pass_graph.zig");

pub const RenderPassId = pass_graph.RenderPassId;
pub const PassPhase = pass_graph.PassPhase;
pub const ResourceId = pass_graph.ResourceId;
pub const ResourceMask = pass_graph.ResourceMask;
pub const PassNode = pass_graph.PassNode;

pub const CompiledPass = struct {
    id: RenderPassId,
    phase: PassPhase,
    output_target: pass_graph.SurfaceTarget,
    reads: ResourceMask,
    writes: ResourceMask,
};

pub const CompiledGraph = struct {
    passes: []const CompiledPass,
    available_resources: ResourceMask,

    pub fn deinit(self: *CompiledGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        self.* = undefined;
    }

    pub fn phaseMask(self: CompiledGraph, phase: PassPhase) u64 {
        var mask: u64 = 0;
        for (self.passes) |pass| {
            if (pass.phase != phase) continue;
            mask |= pass_graph.passBit(pass.id);
        }
        return mask;
    }
};

pub const CachedGraph = struct {
    valid: bool = false,
    enabled_mask: u64 = 0,
    initial_resources: ResourceMask = 0,
    available_resources: ResourceMask = 0,
    pass_count: usize = 0,
    passes: [pass_graph.post_pass_count]CompiledPass = undefined,

    pub fn invalidate(self: *CachedGraph) void {
        self.valid = false;
        self.enabled_mask = 0;
        self.initial_resources = 0;
        self.available_resources = 0;
        self.pass_count = 0;
    }

    pub fn compileIfNeeded(self: *CachedGraph, enabled_mask: u64, initial_resources: ResourceMask) CompileError!void {
        if (self.valid and self.enabled_mask == enabled_mask and self.initial_resources == initial_resources) return;

        self.pass_count = 0;
        self.available_resources = initial_resources;
        var previous_phase: ?PassPhase = null;

        for (pass_graph.default_post_pass_order) |node| {
            if ((enabled_mask & pass_graph.passBit(node.id)) == 0) continue;
            if (node.flags.requires_history and (self.available_resources & pass_graph.resourceBit(.history_color)) == 0) {
                self.invalidate();
                return error.HistoryRequestedWithoutResource;
            }
            if (previous_phase) |phase| {
                if (@intFromEnum(node.phase) < @intFromEnum(phase)) {
                    self.invalidate();
                    return error.PassOrderRegressedPhase;
                }
            }
            if ((node.reads & ~self.available_resources) != 0) {
                self.invalidate();
                return error.MissingRequiredResource;
            }

            self.passes[self.pass_count] = .{
                .id = node.id,
                .phase = node.phase,
                .output_target = node.output_target,
                .reads = node.reads,
                .writes = node.writes,
            };
            self.pass_count += 1;
            self.available_resources |= node.writes;
            previous_phase = node.phase;
        }

        self.enabled_mask = enabled_mask;
        self.initial_resources = initial_resources;
        self.valid = true;
    }

    pub fn compiled(self: *const CachedGraph) CompiledGraph {
        return .{
            .passes = self.passes[0..self.pass_count],
            .available_resources = self.available_resources,
        };
    }
};

pub const CompileError = error{
    MissingRequiredResource,
    HistoryRequestedWithoutResource,
    PassOrderRegressedPhase,
};

pub const CompilePassesError = CompileError || std.mem.Allocator.Error;

pub fn compileEnabledPasses(
    allocator: std.mem.Allocator,
    enabled_mask: u64,
    initial_resources: ResourceMask,
) CompilePassesError!CompiledGraph {
    var compiled_buffer: [pass_graph.post_pass_count]CompiledPass = undefined;
    var compiled_count: usize = 0;
    var available = initial_resources;
    var previous_phase: ?PassPhase = null;

    for (pass_graph.default_post_pass_order) |node| {
        if ((enabled_mask & pass_graph.passBit(node.id)) == 0) continue;
        if (node.flags.requires_history and (available & pass_graph.resourceBit(.history_color)) == 0) {
            return error.HistoryRequestedWithoutResource;
        }
        if (previous_phase) |phase| {
            if (@intFromEnum(node.phase) < @intFromEnum(phase)) return error.PassOrderRegressedPhase;
        }
        if ((node.reads & ~available) != 0) return error.MissingRequiredResource;

        compiled_buffer[compiled_count] = .{
            .id = node.id,
            .phase = node.phase,
            .output_target = node.output_target,
            .reads = node.reads,
            .writes = node.writes,
        };
        compiled_count += 1;
        available |= node.writes;
        previous_phase = node.phase;
    }

    const owned_passes = try allocator.alloc(CompiledPass, compiled_count);
    @memcpy(owned_passes, compiled_buffer[0..compiled_count]);
    return .{
        .passes = owned_passes,
        .available_resources = available,
    };
}

test "compile enabled passes preserves declared order and phases" {
    const allocator = std.testing.allocator;
    var graph = try compileEnabledPasses(
        allocator,
        pass_graph.passBit(.skybox) | pass_graph.passBit(.ssao) | pass_graph.passBit(.bloom),
        pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    defer graph.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), graph.passes.len);
    try std.testing.expectEqual(RenderPassId.skybox, graph.passes[0].id);
    try std.testing.expectEqual(RenderPassId.ssao, graph.passes[1].id);
    try std.testing.expectEqual(RenderPassId.bloom, graph.passes[2].id);
    try std.testing.expectEqual(PassPhase.scene, graph.passes[0].phase);
    try std.testing.expectEqual(PassPhase.geometry_post, graph.passes[1].phase);
    try std.testing.expectEqual(PassPhase.lighting_scatter, graph.passes[2].phase);
}

test "compile enabled passes rejects missing history resource" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.HistoryRequestedWithoutResource,
        compileEnabledPasses(
            allocator,
            pass_graph.passBit(.motion_blur),
            pass_graph.resourceMask(&.{ .scene_color, .scene_depth }),
        ),
    );
}

test "compile enabled passes rejects missing dependency resource" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MissingRequiredResource,
        compileEnabledPasses(
            allocator,
            pass_graph.passBit(.shadow_resolve),
            pass_graph.resourceMask(&.{ .scene_color, .scene_depth }),
        ),
    );
}

test "cached graph reuses compilation when inputs are unchanged" {
    var cache = CachedGraph{};
    try cache.compileIfNeeded(
        pass_graph.passBit(.skybox) | pass_graph.passBit(.ssao),
        pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    const first_count = cache.pass_count;
    try cache.compileIfNeeded(
        pass_graph.passBit(.skybox) | pass_graph.passBit(.ssao),
        pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    try std.testing.expect(cache.valid);
    try std.testing.expectEqual(first_count, cache.pass_count);
}
