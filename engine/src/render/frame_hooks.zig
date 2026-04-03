const std = @import("std");
const config = @import("../core/app_config.zig");
const frame_executor = @import("frame_executor.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const frame_plan = @import("graph/frame_plan.zig");

pub fn makePostPassDispatcher(comptime Context: type) frame_executor.PostPassDispatcher(Context) {
    return .{
        .skybox = struct { fn run(ctx: Context) void { ctx.renderer.applySkyboxPass(ctx.basis_right, ctx.basis_up, ctx.basis_forward, ctx.projection); } }.run,
        .shadow_resolve = struct {
            fn run(ctx: Context) void {
                ctx.renderer.runShadowResolvePass(
                    ctx.camera_position,
                    ctx.basis_right,
                    ctx.basis_up,
                    ctx.basis_forward,
                    ctx.projection,
                    ctx.shadow_build_elapsed_ns,
                );
            }
        }.run,
        .hybrid_shadow = struct {
            fn run(ctx: Context) void {
                ctx.renderer.runHybridShadowPass(
                    ctx.mesh,
                    ctx.camera_position,
                    ctx.basis_right,
                    ctx.basis_up,
                    ctx.basis_forward,
                    ctx.light_dir_world,
                );
            }
        }.run,
        .ssao = struct { fn run(ctx: Context) void { ctx.renderer.applyAmbientOcclusionPass(); } }.run,
        .ssgi = struct { fn run(ctx: Context) void { ctx.renderer.applySSGIPass(); } }.run,
        .ssr = struct { fn run(ctx: Context) void { ctx.renderer.applySSRPass(ctx.projection); } }.run,
        .depth_fog = struct { fn run(ctx: Context) void { ctx.renderer.applyDepthFogPass(); } }.run,
        .taa = struct { fn run(ctx: Context) void { ctx.renderer.applyTemporalAAPass(ctx.mesh, ctx.current_view); } }.run,
        .motion_blur = struct { fn run(ctx: Context) void { ctx.renderer.applyMotionBlurPass(ctx.current_view); } }.run,
        .god_rays = struct { fn run(ctx: Context) void { ctx.renderer.applyGodRaysPass(ctx.projection, ctx.light_dir_world); } }.run,
        .bloom = struct { fn run(ctx: Context) void { ctx.renderer.applyBloomPass(); } }.run,
        .lens_flare = struct { fn run(ctx: Context) void { ctx.renderer.applyLensFlarePass(); } }.run,
        .dof = struct { fn run(ctx: Context) void { ctx.renderer.applyDepthOfFieldPass(); } }.run,
        .chromatic_aberration = struct { fn run(ctx: Context) void { ctx.renderer.applyChromaticAberrationPass(); } }.run,
        .film_grain_vignette = struct { fn run(ctx: Context) void { ctx.renderer.applyFilmGrainVignettePass(); } }.run,
        .color_grade = struct { fn run(ctx: Context) void { ctx.renderer.applyBlockbusterColorGradePass(); } }.run,
    };
}

pub fn makeFrameStageDispatcher(comptime Context: type) frame_executor.FrameStageDispatcher(Context) {
    return .{
        .shadow_build = struct { fn run(ctx: Context) void { ctx.renderer.stageBuildShadowMaps(ctx.mesh); } }.run,
        .scene_raster_tiled = struct {
            fn run(ctx: Context) !void {
                try ctx.renderer.stageRenderScene(.tiled, ctx.mesh, ctx.view_rotation, ctx.light_dir, ctx.pump, ctx.raster_projection, ctx.mesh_work);
            }
        }.run,
        .scene_raster_direct = struct {
            fn run(ctx: Context) !void {
                try ctx.renderer.stageRenderScene(.direct, ctx.mesh, ctx.view_rotation, ctx.light_dir, ctx.pump, ctx.raster_projection, ctx.mesh_work);
            }
        }.run,
        .post_process = struct {
            fn run(ctx: Context) void {
                ctx.renderer.runPostProcessStage(
                    ctx.is_editor_mode,
                    ctx.mesh,
                    ctx.basis_right,
                    ctx.basis_up,
                    ctx.basis_forward,
                    ctx.taa_view,
                    ctx.raster_projection,
                    ctx.shadow_map_light_count,
                    ctx.light_dir_world,
                );
            }
        }.run,
        .present = struct {
            fn run(ctx: Context) !i128 {
                return ctx.renderer.stageOverlayAndPresent(
                    ctx.is_editor_mode,
                    ctx.light_camera,
                    ctx.center_x,
                    ctx.center_y,
                    ctx.x_scale,
                    ctx.y_scale,
                    ctx.basis_right,
                    ctx.basis_up,
                    ctx.basis_forward,
                    ctx.cache_projection,
                );
            }
        }.run,
    };
}

const FakeProjection = struct {};
const FakeView = struct {};
const FakeMesh = struct {};
const FakeMeshWork = struct {};
const FakeVec3 = struct {};
const FakeMat4 = struct {};

const FakeRenderer = struct {
    calls: *std.ArrayList([]const u8),

    fn mark(self: *FakeRenderer, name: []const u8) void {
        self.calls.append(std.testing.allocator, name) catch unreachable;
    }

    pub fn applySkyboxPass(self: *FakeRenderer, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeProjection) void { self.mark("skybox"); }
    pub fn runShadowResolvePass(self: *FakeRenderer, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeProjection, _: []const i128) void { self.mark("shadow_resolve"); }
    pub fn runHybridShadowPass(self: *FakeRenderer, _: *const FakeMesh, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeVec3) void { self.mark("hybrid_shadow"); }
    pub fn applyAmbientOcclusionPass(self: *FakeRenderer) void { self.mark("ssao"); }
    pub fn applySSGIPass(self: *FakeRenderer) void { self.mark("ssgi"); }
    pub fn applySSRPass(self: *FakeRenderer, _: FakeProjection) void { self.mark("ssr"); }
    pub fn applyDepthFogPass(self: *FakeRenderer) void { self.mark("depth_fog"); }
    pub fn applyTemporalAAPass(self: *FakeRenderer, _: *const FakeMesh, _: FakeView) void { self.mark("taa"); }
    pub fn applyMotionBlurPass(self: *FakeRenderer, _: FakeView) void { self.mark("motion_blur"); }
    pub fn applyGodRaysPass(self: *FakeRenderer, _: FakeProjection, _: FakeVec3) void { self.mark("god_rays"); }
    pub fn applyBloomPass(self: *FakeRenderer) void { self.mark("bloom"); }
    pub fn applyLensFlarePass(self: *FakeRenderer) void { self.mark("lens_flare"); }
    pub fn applyDepthOfFieldPass(self: *FakeRenderer) void { self.mark("dof"); }
    pub fn applyChromaticAberrationPass(self: *FakeRenderer) void { self.mark("chromatic_aberration"); }
    pub fn applyFilmGrainVignettePass(self: *FakeRenderer) void { self.mark("film_grain_vignette"); }
    pub fn applyBlockbusterColorGradePass(self: *FakeRenderer) void { self.mark("color_grade"); }
    pub fn stageBuildShadowMaps(self: *FakeRenderer, _: *const FakeMesh) void { self.mark("shadow_build"); }
    pub fn stageRenderScene(self: *FakeRenderer, backend: frame_plan.BackendKind, _: *const FakeMesh, _: FakeMat4, _: FakeVec3, _: ?*const fn (*FakeRenderer) bool, _: FakeProjection, _: *const FakeMeshWork) !void {
        self.mark(if (backend == .tiled) "scene_tiled" else "scene_direct");
    }
    pub fn runPostProcessStage(self: *FakeRenderer, _: bool, _: *const FakeMesh, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeView, _: FakeProjection, _: usize, _: FakeVec3) void { self.mark("post_process"); }
    pub fn stageOverlayAndPresent(self: *FakeRenderer, _: bool, _: FakeVec3, _: f32, _: f32, _: f32, _: f32, _: FakeVec3, _: FakeVec3, _: FakeVec3, _: FakeProjection) !i128 {
        self.mark("present");
        return 99;
    }
};

const FakePostContext = struct {
    renderer: *FakeRenderer,
    mesh: *const FakeMesh,
    camera_position: FakeVec3,
    basis_right: FakeVec3,
    basis_up: FakeVec3,
    basis_forward: FakeVec3,
    current_view: FakeView,
    projection: FakeProjection,
    light_dir_world: FakeVec3,
    shadow_build_elapsed_ns: []const i128,
};

const FakeFrameContext = struct {
    renderer: *FakeRenderer,
    mesh: *const FakeMesh,
    view_rotation: FakeMat4,
    light_dir: FakeVec3,
    pump: ?*const fn (*FakeRenderer) bool,
    raster_projection: FakeProjection,
    mesh_work: *const FakeMeshWork,
    is_editor_mode: bool,
    light_camera: FakeVec3,
    center_x: f32,
    center_y: f32,
    x_scale: f32,
    y_scale: f32,
    basis_right: FakeVec3,
    basis_up: FakeVec3,
    basis_forward: FakeVec3,
    taa_view: FakeView,
    shadow_map_light_count: usize,
    light_dir_world: FakeVec3,
    cache_projection: FakeProjection,
};

const FakeTiming = struct {
    count: usize = 0,
    fn record(ctx: *anyopaque, _: anytype, _: i128) void {
        const self: *FakeTiming = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

test "shared post-pass wiring drives executor through generic hooks" {
    var calls = std.ArrayList([]const u8){};
    defer calls.deinit(std.testing.allocator);
    var renderer = FakeRenderer{ .calls = &calls };
    const mesh = FakeMesh{};
    const shadow_times = [_]i128{0};
    var graph_cache = @import("graph/frame_graph.zig").CachedGraph{};
    const compiled = try frame_pipeline.compileCachedPostGraph(&graph_cache, .{
        .shadow_map_light_count = 1,
        .taa_history_valid = true,
    });
    var front = [_]u32{1};
    var scratch_a = [_]u32{2};
    var scratch_b = [_]u32{3};
    var timing = FakeTiming{};

    frame_executor.executePostGraph(
        FakePostContext,
        compiled,
        .{ .front = &front[0..], .scratch_a = &scratch_a[0..], .scratch_b = &scratch_b[0..] },
        .{ .enabled = true, .ctx = &timing, .record = FakeTiming.record },
        .{
            .renderer = &renderer,
            .mesh = &mesh,
            .camera_position = .{},
            .basis_right = .{},
            .basis_up = .{},
            .basis_forward = .{},
            .current_view = .{},
            .projection = .{},
            .light_dir_world = .{},
            .shadow_build_elapsed_ns = &shadow_times,
        },
        makePostPassDispatcher(FakePostContext),
    );

    try std.testing.expect(calls.items.len > 0);
    try std.testing.expect(timing.count > 0);
}

test "shared frame-stage wiring drives executor through generic hooks" {
    var calls = std.ArrayList([]const u8){};
    defer calls.deinit(std.testing.allocator);
    var renderer = FakeRenderer{ .calls = &calls };
    const mesh = FakeMesh{};
    const mesh_work = FakeMeshWork{};
    var plan_cache = frame_plan.CachedPlan{};
    plan_cache.compileIfNeeded(.{
        .include_shadow_build = true,
        .backend = .tiled,
        .include_post_process = true,
        .include_present = true,
    });

    const end_time = try frame_executor.executeFramePlan(
        FakeFrameContext,
        plan_cache.compiled(),
        .{
            .renderer = &renderer,
            .mesh = &mesh,
            .view_rotation = .{},
            .light_dir = .{},
            .pump = null,
            .raster_projection = .{},
            .mesh_work = &mesh_work,
            .is_editor_mode = true,
            .light_camera = .{},
            .center_x = 0,
            .center_y = 0,
            .x_scale = 1,
            .y_scale = 1,
            .basis_right = .{},
            .basis_up = .{},
            .basis_forward = .{},
            .taa_view = .{},
            .shadow_map_light_count = 1,
            .light_dir_world = .{},
            .cache_projection = .{},
        },
        makeFrameStageDispatcher(FakeFrameContext),
        7,
    );

    try std.testing.expectEqual(@as(i128, 99), end_time);
    try std.testing.expectEqualStrings("shadow_build", calls.items[0]);
    try std.testing.expectEqualStrings("scene_tiled", calls.items[1]);
    try std.testing.expectEqualStrings("post_process", calls.items[2]);
    try std.testing.expectEqualStrings("present", calls.items[3]);
}
