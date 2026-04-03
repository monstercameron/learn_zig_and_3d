const std = @import("std");

pub const StageCategory = enum(u8) {
    setup,
    submission,
    visibility,
    geometry,
    raster,
    shading,
    composition,
    post,
    present,
};

pub const StageId = enum(u8) {
    frame_setup,
    scene_submission,
    visibility_culling,
    primitive_expansion,
    screen_binning,
    rasterization,
    shading,
    composition,
    post_process,
    presentation,
};

pub const stage_count: usize = @typeInfo(StageId).@"enum".fields.len;

pub const ResourceId = enum(u8) {
    frame_params,
    scene_packets,
    visible_items,
    primitive_batch,
    tile_bins,
    color_target,
    depth_target,
    post_target,
    present_target,
};

pub const resource_count: usize = @typeInfo(ResourceId).@"enum".fields.len;
pub const ResourceMask = std.bit_set.IntegerBitSet(resource_count);

pub const StageDescriptor = struct {
    id: StageId,
    category: StageCategory,
    label: []const u8,
    description: []const u8,
    reads: ResourceMask = ResourceMask.initEmpty(),
    writes: ResourceMask = ResourceMask.initEmpty(),
    enabled_by_default: bool = true,
};

pub const StageConfig = struct {
    enabled: [stage_count]bool = [_]bool{true} ** stage_count,

    pub fn initDefault() StageConfig {
        var config = StageConfig{};
        for (descriptors, 0..) |descriptor, index| {
            config.enabled[index] = descriptor.enabled_by_default;
        }
        return config;
    }

    pub fn setEnabled(self: *StageConfig, stage: StageId, enabled: bool) void {
        self.enabled[@intFromEnum(stage)] = enabled;
    }

    pub fn isEnabled(self: *const StageConfig, stage: StageId) bool {
        return self.enabled[@intFromEnum(stage)];
    }
};

pub const CompiledPipeline = struct {
    stages: []const StageDescriptor,
};

pub const CachedPipeline = struct {
    valid: bool = false,
    config: StageConfig = StageConfig.initDefault(),
    stage_count: usize = 0,
    stages: [stage_count]StageDescriptor = undefined,

    pub fn invalidate(self: *CachedPipeline) void {
        self.valid = false;
        self.stage_count = 0;
    }

    pub fn compileIfNeeded(self: *CachedPipeline, config: StageConfig) void {
        if (self.valid and std.meta.eql(self.config, config)) return;

        self.stage_count = 0;
        for (descriptors, 0..) |descriptor, index| {
            if (!config.enabled[index]) continue;
            self.stages[self.stage_count] = descriptor;
            self.stage_count += 1;
        }
        self.config = config;
        self.valid = true;
    }

    pub fn compiled(self: *const CachedPipeline) CompiledPipeline {
        return .{ .stages = self.stages[0..self.stage_count] };
    }
};

pub const descriptors = [_]StageDescriptor{
    .{
        .id = .frame_setup,
        .category = .setup,
        .label = "Frame Setup",
        .description = "Prepare frame-local state, timers, and target metadata.",
        .writes = mask(&.{.frame_params}),
    },
    .{
        .id = .scene_submission,
        .category = .submission,
        .label = "Scene Submission",
        .description = "Build world-space submission packets from the scene and runtime state.",
        .reads = mask(&.{.frame_params}),
        .writes = mask(&.{.scene_packets}),
    },
    .{
        .id = .visibility_culling,
        .category = .visibility,
        .label = "Visibility Culling",
        .description = "Cull submitted items against the active camera and frame constraints.",
        .reads = mask(&.{ .frame_params, .scene_packets }),
        .writes = mask(&.{.visible_items}),
    },
    .{
        .id = .primitive_expansion,
        .category = .geometry,
        .label = "Primitive Expansion",
        .description = "Expand visible scene items into a primitive batch ready for raster compilation.",
        .reads = mask(&.{ .frame_params, .visible_items }),
        .writes = mask(&.{.primitive_batch}),
    },
    .{
        .id = .screen_binning,
        .category = .geometry,
        .label = "Screen Binning",
        .description = "Compile and bin primitives into tile-friendly screen-space work lists.",
        .reads = mask(&.{ .frame_params, .primitive_batch }),
        .writes = mask(&.{.tile_bins}),
    },
    .{
        .id = .rasterization,
        .category = .raster,
        .label = "Rasterization",
        .description = "Rasterize binned primitives into the color and depth targets.",
        .reads = mask(&.{ .frame_params, .tile_bins }),
        .writes = mask(&.{ .color_target, .depth_target }),
    },
    .{
        .id = .shading,
        .category = .shading,
        .label = "Shading",
        .description = "Evaluate material and lighting for rasterized fragments or tiles.",
        .reads = mask(&.{ .frame_params, .color_target, .depth_target }),
        .writes = mask(&.{.color_target}),
    },
    .{
        .id = .composition,
        .category = .composition,
        .label = "Composition",
        .description = "Combine scene layers, overlays, and resolved buffers into a final scene image.",
        .reads = mask(&.{ .frame_params, .color_target }),
        .writes = mask(&.{.post_target}),
    },
    .{
        .id = .post_process,
        .category = .post,
        .label = "Post Process",
        .description = "Apply tone mapping and image-space post effects to the composed image.",
        .reads = mask(&.{ .frame_params, .post_target }),
        .writes = mask(&.{.present_target}),
    },
    .{
        .id = .presentation,
        .category = .present,
        .label = "Presentation",
        .description = "Upload and present the final image to the active present backend.",
        .reads = mask(&.{ .frame_params, .present_target }),
        .enabled_by_default = true,
    },
};

fn mask(comptime ids: []const ResourceId) ResourceMask {
    var out = ResourceMask.initEmpty();
    for (ids) |id| out.set(@intFromEnum(id));
    return out;
}

test "default full pipeline preserves intended stage order" {
    var cache = CachedPipeline{};
    cache.compileIfNeeded(StageConfig.initDefault());
    const compiled = cache.compiled();

    try std.testing.expectEqual(stage_count, compiled.stages.len);
    try std.testing.expectEqual(StageId.frame_setup, compiled.stages[0].id);
    try std.testing.expectEqual(StageId.scene_submission, compiled.stages[1].id);
    try std.testing.expectEqual(StageId.visibility_culling, compiled.stages[2].id);
    try std.testing.expectEqual(StageId.primitive_expansion, compiled.stages[3].id);
    try std.testing.expectEqual(StageId.screen_binning, compiled.stages[4].id);
    try std.testing.expectEqual(StageId.rasterization, compiled.stages[5].id);
    try std.testing.expectEqual(StageId.shading, compiled.stages[6].id);
    try std.testing.expectEqual(StageId.composition, compiled.stages[7].id);
    try std.testing.expectEqual(StageId.post_process, compiled.stages[8].id);
    try std.testing.expectEqual(StageId.presentation, compiled.stages[9].id);
}

test "full pipeline config can enable stages incrementally" {
    var config = StageConfig.initDefault();
    config.setEnabled(.visibility_culling, false);
    config.setEnabled(.primitive_expansion, false);
    config.setEnabled(.screen_binning, false);
    config.setEnabled(.rasterization, false);
    config.setEnabled(.shading, false);
    config.setEnabled(.composition, false);
    config.setEnabled(.post_process, false);
    config.setEnabled(.presentation, false);

    var cache = CachedPipeline{};
    cache.compileIfNeeded(config);
    const compiled = cache.compiled();

    try std.testing.expectEqual(@as(usize, 2), compiled.stages.len);
    try std.testing.expectEqual(StageId.frame_setup, compiled.stages[0].id);
    try std.testing.expectEqual(StageId.scene_submission, compiled.stages[1].id);
}
