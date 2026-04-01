const std = @import("std");
const pass_graph = @import("pipeline/pass_graph.zig");
const frame_graph = @import("graph/frame_graph.zig");
const frame_plan = @import("graph/frame_plan.zig");
const frame_pipeline = @import("frame_pipeline.zig");

pub fn PostPassDispatcher(comptime Context: type) type {
    return struct {
        skybox: *const fn (Context) void,
        shadow_resolve: *const fn (Context) void,
        hybrid_shadow: *const fn (Context) void,
        ssao: *const fn (Context) void,
        ssgi: *const fn (Context) void,
        ssr: *const fn (Context) void,
        depth_fog: *const fn (Context) void,
        taa: *const fn (Context) void,
        motion_blur: *const fn (Context) void,
        god_rays: *const fn (Context) void,
        bloom: *const fn (Context) void,
        lens_flare: *const fn (Context) void,
        dof: *const fn (Context) void,
        chromatic_aberration: *const fn (Context) void,
        film_grain_vignette: *const fn (Context) void,
        color_grade: *const fn (Context) void,
    };
}

pub fn dispatchPostPass(
    comptime Context: type,
    ctx: Context,
    dispatcher: PostPassDispatcher(Context),
    pass_id: pass_graph.RenderPassId,
) void {
    switch (pass_id) {
        .skybox => dispatcher.skybox(ctx),
        .shadow_resolve => dispatcher.shadow_resolve(ctx),
        .hybrid_shadow => dispatcher.hybrid_shadow(ctx),
        .ssao => dispatcher.ssao(ctx),
        .ssgi => dispatcher.ssgi(ctx),
        .ssr => dispatcher.ssr(ctx),
        .depth_fog => dispatcher.depth_fog(ctx),
        .taa => dispatcher.taa(ctx),
        .motion_blur => dispatcher.motion_blur(ctx),
        .god_rays => dispatcher.god_rays(ctx),
        .bloom => dispatcher.bloom(ctx),
        .lens_flare => dispatcher.lens_flare(ctx),
        .dof => dispatcher.dof(ctx),
        .chromatic_aberration => dispatcher.chromatic_aberration(ctx),
        .film_grain_vignette => dispatcher.film_grain_vignette(ctx),
        .color_grade => dispatcher.color_grade(ctx),
    }
}

pub fn FrameStageDispatcher(comptime Context: type) type {
    return struct {
        shadow_build: *const fn (Context) void,
        scene_raster_tiled: *const fn (Context) anyerror!void,
        scene_raster_direct: *const fn (Context) anyerror!void,
        post_process: *const fn (Context) void,
        present: *const fn (Context) anyerror!i128,
    };
}

pub fn executeFramePlan(
    comptime Context: type,
    compiled_plan: frame_plan.CompiledPlan,
    ctx: Context,
    comptime dispatcher: FrameStageDispatcher(Context),
    initial_time: i128,
) !i128 {
    var current_time = initial_time;
    for (compiled_plan.stages) |stage| {
        switch (stage) {
            .shadow_build => dispatcher.shadow_build(ctx),
            .scene_raster_tiled => try dispatcher.scene_raster_tiled(ctx),
            .scene_raster_direct => try dispatcher.scene_raster_direct(ctx),
            .post_process => dispatcher.post_process(ctx),
            .present => current_time = try dispatcher.present(ctx),
        }
    }
    return current_time;
}

pub fn executePostGraph(
    comptime Context: type,
    compiled_graph: frame_graph.CompiledGraph,
    buffers: frame_pipeline.BufferSet,
    recorder: frame_pipeline.PhaseTimingRecorder,
    ctx: Context,
    comptime dispatcher: PostPassDispatcher(Context),
) void {
    if (!recorder.enabled) {
        for (compiled_graph.passes) |pass| {
            dispatchPostPass(Context, ctx, dispatcher, pass.id);
            frame_pipeline.commitPassOutput(buffers, pass.output_target);
        }
        return;
    }

    var current_phase: ?pass_graph.PassPhase = null;
    var phase_start_ns: i128 = 0;
    for (compiled_graph.passes) |pass| {
        if (current_phase == null or current_phase.? != pass.phase) {
            if (current_phase) |phase| {
                recorder.record(recorder.ctx, phase, std.time.nanoTimestamp() - phase_start_ns);
            }
            current_phase = pass.phase;
            phase_start_ns = std.time.nanoTimestamp();
        }

        dispatchPostPass(Context, ctx, dispatcher, pass.id);
        frame_pipeline.commitPassOutput(buffers, pass.output_target);
    }
    if (current_phase) |phase| {
        recorder.record(recorder.ctx, phase, std.time.nanoTimestamp() - phase_start_ns);
    }
}

const TestPostContext = struct {
    seen: *std.ArrayList(pass_graph.RenderPassId),
};

fn testPostPush(comptime pass_id: pass_graph.RenderPassId) *const fn (TestPostContext) void {
    return struct {
        fn run(ctx: TestPostContext) void {
            ctx.seen.append(std.testing.allocator, pass_id) catch unreachable;
        }
    }.run;
}

const test_post_dispatcher = PostPassDispatcher(TestPostContext){
    .skybox = testPostPush(.skybox),
    .shadow_resolve = testPostPush(.shadow_resolve),
    .hybrid_shadow = testPostPush(.hybrid_shadow),
    .ssao = testPostPush(.ssao),
    .ssgi = testPostPush(.ssgi),
    .ssr = testPostPush(.ssr),
    .depth_fog = testPostPush(.depth_fog),
    .taa = testPostPush(.taa),
    .motion_blur = testPostPush(.motion_blur),
    .god_rays = testPostPush(.god_rays),
    .bloom = testPostPush(.bloom),
    .lens_flare = testPostPush(.lens_flare),
    .dof = testPostPush(.dof),
    .chromatic_aberration = testPostPush(.chromatic_aberration),
    .film_grain_vignette = testPostPush(.film_grain_vignette),
    .color_grade = testPostPush(.color_grade),
};

const TestStageContext = struct {
    seen: *std.ArrayList(frame_plan.FrameStageId),
};

fn testStageMark(comptime stage: frame_plan.FrameStageId) *const fn (TestStageContext) void {
    return struct {
        fn run(ctx: TestStageContext) void {
            ctx.seen.append(std.testing.allocator, stage) catch unreachable;
        }
    }.run;
}

fn testStageMarkTry(comptime stage: frame_plan.FrameStageId) *const fn (TestStageContext) anyerror!void {
    return struct {
        fn run(ctx: TestStageContext) !void {
            ctx.seen.append(std.testing.allocator, stage) catch unreachable;
        }
    }.run;
}

fn testStagePresent(comptime stage: frame_plan.FrameStageId) *const fn (TestStageContext) anyerror!i128 {
    return struct {
        fn run(ctx: TestStageContext) !i128 {
            ctx.seen.append(std.testing.allocator, stage) catch unreachable;
            return 42;
        }
    }.run;
}

const test_stage_dispatcher = FrameStageDispatcher(TestStageContext){
    .shadow_build = testStageMark(.shadow_build),
    .scene_raster_tiled = testStageMarkTry(.scene_raster_tiled),
    .scene_raster_direct = testStageMarkTry(.scene_raster_direct),
    .post_process = testStageMark(.post_process),
    .present = testStagePresent(.present),
};

test "post pass dispatcher routes pass ids without renderer coupling" {
    var seen = std.ArrayList(pass_graph.RenderPassId){};
    defer seen.deinit(std.testing.allocator);
    const ctx = TestPostContext{ .seen = &seen };

    dispatchPostPass(TestPostContext, ctx, test_post_dispatcher, .ssao);
    dispatchPostPass(TestPostContext, ctx, test_post_dispatcher, .taa);
    dispatchPostPass(TestPostContext, ctx, test_post_dispatcher, .color_grade);

    try std.testing.expectEqual(@as(usize, 3), seen.items.len);
    try std.testing.expectEqual(pass_graph.RenderPassId.ssao, seen.items[0]);
    try std.testing.expectEqual(pass_graph.RenderPassId.taa, seen.items[1]);
    try std.testing.expectEqual(pass_graph.RenderPassId.color_grade, seen.items[2]);
}

test "frame stage executor follows compiled stage order" {
    var seen = std.ArrayList(frame_plan.FrameStageId){};
    defer seen.deinit(std.testing.allocator);
    var cache = frame_plan.CachedPlan{};
    cache.compileIfNeeded(.{
        .include_shadow_build = true,
        .backend = .direct,
        .include_post_process = true,
        .include_present = true,
    });

    const result_time = try executeFramePlan(
        TestStageContext,
        cache.compiled(),
        .{ .seen = &seen },
        test_stage_dispatcher,
        5,
    );

    try std.testing.expectEqual(@as(i128, 42), result_time);
    try std.testing.expectEqual(@as(usize, 4), seen.items.len);
    try std.testing.expectEqual(frame_plan.FrameStageId.shadow_build, seen.items[0]);
    try std.testing.expectEqual(frame_plan.FrameStageId.scene_raster_direct, seen.items[1]);
    try std.testing.expectEqual(frame_plan.FrameStageId.post_process, seen.items[2]);
    try std.testing.expectEqual(frame_plan.FrameStageId.present, seen.items[3]);
}
