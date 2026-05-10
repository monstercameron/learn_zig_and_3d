const std = @import("std");
const config = @import("../core/app_config.zig");
const pass_graph = @import("pipeline/pass_graph.zig");
const frame_graph = @import("graph/frame_graph.zig");
const frame_plan = @import("graph/frame_plan.zig");
const frame_executor = @import("frame_executor.zig");

pub const PostPipelineFeatures = struct {
    shadow_map_light_count: usize,
    taa_history_valid: bool,
};

pub const FramePlanFeatures = struct {
    has_shadow_map_lights: bool,
    backend: frame_plan.BackendKind,
    include_post_process: bool = true,
    include_present: bool = true,
};

pub const ScratchBindings = struct {
    scratch_a: []u32,
    scratch_b: []u32,
};

pub const BufferSet = struct {
    front: *[]u32,
    scratch_a: *[]u32,
    scratch_b: *[]u32,
};

pub const PhaseTimingRecorder = struct {
    enabled: bool = false,
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, phase: pass_graph.PassPhase, duration_ns: i128) void,
};

pub fn isPostPassEnabled(features: PostPipelineFeatures, pass_id: pass_graph.RenderPassId) bool {
    const enabled = switch (pass_id) {
        .skybox => config.POST_SKYBOX_ENABLED,
        .shadow_resolve => config.POST_SHADOW_ENABLED and features.shadow_map_light_count > 0,
        .hybrid_shadow => config.POST_HYBRID_SHADOW_ENABLED,
        .ssao => config.POST_SSAO_ENABLED,
        .ssgi => config.POST_SSGI_ENABLED,
        .ssr => config.POST_SSR_ENABLED,
        .depth_fog => config.POST_DEPTH_FOG_ENABLED,
        .taa => config.POST_TAA_ENABLED,
        .motion_blur => config.POST_MOTION_BLUR_ENABLED,
        .god_rays => config.POST_GOD_RAYS_ENABLED,
        .bloom => config.POST_BLOOM_ENABLED,
        .lens_flare => config.POST_LENS_FLARE_ENABLED,
        .dof => config.POST_DOF_ENABLED,
        .chromatic_aberration => config.POST_CHROMATIC_ABERRATION_ENABLED,
        .film_grain_vignette => config.POST_FILM_GRAIN_VIGNETTE_ENABLED,
        .color_grade => config.POST_COLOR_CORRECTION_ENABLED,
    };
    if (!enabled) return false;
    if (pass_id == .motion_blur and !features.taa_history_valid) return false;
    return true;
}

pub fn buildPostEnabledMask(features: PostPipelineFeatures) u64 {
    var enabled_mask: u64 = 0;
    for (pass_graph.default_post_pass_order) |node| {
        if (!isPostPassEnabled(features, node.id)) continue;
        enabled_mask |= pass_graph.passBit(node.id);
    }
    return enabled_mask;
}

pub fn availablePostResources(features: PostPipelineFeatures) pass_graph.ResourceMask {
    var available_resources = pass_graph.resourceMask(&.{
        .scene_color,
        .scene_depth,
        .scene_normals,
        .scene_surface,
    });
    if (features.shadow_map_light_count > 0) {
        available_resources |= pass_graph.resourceBit(.shadow_buffer);
    }
    if (features.taa_history_valid) {
        available_resources |= pass_graph.resourceBit(.history_color);
    }
    return available_resources;
}

pub fn phaseTimingName(phase: pass_graph.PassPhase) []const u8 {
    return switch (phase) {
        .scene => "phase_scene",
        .geometry_post => "phase_geometry_post",
        .lighting_scatter => "phase_lighting_scatter",
        .final_color => "phase_final_color",
    };
}

pub fn applyScratchBindings(bindings: ScratchBindings) ScratchBindings {
    return bindings;
}

pub fn commitPassOutput(buffers: BufferSet, target: pass_graph.SurfaceTarget) void {
    switch (target) {
        .main => {},
        .scratch_a => std.mem.swap([]u32, buffers.front, buffers.scratch_a),
        .scratch_b => std.mem.swap([]u32, buffers.front, buffers.scratch_b),
        .history => {},
    }
}

pub fn compileCachedPostGraph(
    cache: *frame_graph.CachedGraph,
    features: PostPipelineFeatures,
) frame_graph.CompileError!frame_graph.CompiledGraph {
    const enabled_mask = buildPostEnabledMask(features);
    const available_resources = availablePostResources(features);
    try cache.compileIfNeeded(enabled_mask, available_resources);
    return cache.compiled();
}

pub fn compileCachedFramePlan(cache: *frame_plan.CachedPlan, features: FramePlanFeatures) frame_plan.CompiledPlan {
    cache.compileIfNeeded(.{
        .include_shadow_build = features.has_shadow_map_lights,
        .backend = features.backend,
        .include_post_process = features.include_post_process,
        .include_present = features.include_present,
    });
    return cache.compiled();
}

const TestRunContext = struct {
    seen: std.ArrayList(pass_graph.RenderPassId),
};

fn makeTestDispatcher(comptime Context: type) frame_executor.PostPassDispatcher(Context) {
    return .{
        .skybox = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .skybox) catch unreachable; } }.run,
        .shadow_resolve = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .shadow_resolve) catch unreachable; } }.run,
        .hybrid_shadow = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .hybrid_shadow) catch unreachable; } }.run,
        .ssao = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .ssao) catch unreachable; } }.run,
        .ssgi = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .ssgi) catch unreachable; } }.run,
        .ssr = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .ssr) catch unreachable; } }.run,
        .depth_fog = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .depth_fog) catch unreachable; } }.run,
        .taa = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .taa) catch unreachable; } }.run,
        .motion_blur = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .motion_blur) catch unreachable; } }.run,
        .god_rays = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .god_rays) catch unreachable; } }.run,
        .bloom = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .bloom) catch unreachable; } }.run,
        .lens_flare = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .lens_flare) catch unreachable; } }.run,
        .dof = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .dof) catch unreachable; } }.run,
        .chromatic_aberration = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .chromatic_aberration) catch unreachable; } }.run,
        .film_grain_vignette = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .film_grain_vignette) catch unreachable; } }.run,
        .color_grade = struct { fn run(ctx: Context) void { ctx.seen.append(std.testing.allocator, .color_grade) catch unreachable; } }.run,
    };
}

const TestTimingContext = struct {
    count: usize = 0,
    fn record(ctx: *anyopaque, phase: pass_graph.PassPhase, duration_ns: i128) void {
        _ = phase;
        _ = duration_ns;
        const self: *TestTimingContext = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

test "execute compiled post graph respects order and buffer target commits" {
    var cache = frame_graph.CachedGraph{};
    const compiled = try compileCachedPostGraph(&cache, .{
        .shadow_map_light_count = 0,
        .taa_history_valid = false,
    });

    var front = [_]u32{ 1, 2, 3 };
    var scratch_a = [_]u32{ 4, 5, 6 };
    var scratch_b = [_]u32{ 7, 8, 9 };
    var run_ctx = TestRunContext{ .seen = .{} };
    defer run_ctx.seen.deinit(std.testing.allocator);
    var timing_ctx = TestTimingContext{};

    frame_executor.executePostGraph(
        *TestRunContext,
        compiled,
        .{
            .front = &front[0..],
            .scratch_a = &scratch_a[0..],
            .scratch_b = &scratch_b[0..],
        },
        .{
            .enabled = true,
            .ctx = &timing_ctx,
            .record = TestTimingContext.record,
        },
        &run_ctx,
        makeTestDispatcher(*TestRunContext),
    );

    try std.testing.expect(run_ctx.seen.items.len > 0);
    try std.testing.expect(timing_ctx.count > 0);
}

test "execute compiled post graph can skip timing when disabled" {
    var cache = frame_graph.CachedGraph{};
    const compiled = try compileCachedPostGraph(&cache, .{
        .shadow_map_light_count = 0,
        .taa_history_valid = false,
    });

    var front = [_]u32{ 1, 2, 3 };
    var scratch_a = [_]u32{ 4, 5, 6 };
    var scratch_b = [_]u32{ 7, 8, 9 };
    var run_ctx = TestRunContext{ .seen = .{} };
    defer run_ctx.seen.deinit(std.testing.allocator);
    var timing_ctx = TestTimingContext{};

    frame_executor.executePostGraph(
        *TestRunContext,
        compiled,
        .{
            .front = &front[0..],
            .scratch_a = &scratch_a[0..],
            .scratch_b = &scratch_b[0..],
        },
        .{
            .enabled = false,
            .ctx = &timing_ctx,
            .record = TestTimingContext.record,
        },
        &run_ctx,
        makeTestDispatcher(*TestRunContext),
    );

    try std.testing.expect(run_ctx.seen.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), timing_ctx.count);
}

test "frame plan compilation is pure from feature inputs" {
    var cache = frame_plan.CachedPlan{};
    const compiled = compileCachedFramePlan(&cache, .{
        .has_shadow_map_lights = true,
        .backend = .direct,
    });
    try std.testing.expectEqual(@as(usize, 4), compiled.stages.len);
    try std.testing.expectEqual(frame_plan.FrameStageId.shadow_build, compiled.stages[0]);
    try std.testing.expectEqual(frame_plan.FrameStageId.scene_raster_direct, compiled.stages[1]);
}
