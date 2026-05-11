const std = @import("std");

pub const BackendKind = enum(u8) {
    tiled,
    direct,
};

pub const FrameStageId = enum(u8) {
    shadow_build,
    scene_raster_tiled,
    scene_raster_direct,
    post_process,
    present,
};

pub const BuildConfig = struct {
    include_shadow_build: bool,
    backend: BackendKind,
    include_post_process: bool = true,
    include_present: bool = true,
};

pub const CompiledPlan = struct {
    stages: []const FrameStageId,
};

pub const CachedPlan = struct {
    valid: bool = false,
    config: BuildConfig = .{
        .include_shadow_build = false,
        .backend = .tiled,
    },
    stage_count: usize = 0,
    stages: [5]FrameStageId = undefined,

    pub fn invalidate(self: *CachedPlan) void {
        self.valid = false;
        self.stage_count = 0;
    }

    pub fn compileIfNeeded(self: *CachedPlan, config: BuildConfig) void {
        if (self.valid and std.meta.eql(self.config, config)) return;

        self.stage_count = 0;
        if (config.include_shadow_build) {
            self.stages[self.stage_count] = .shadow_build;
            self.stage_count += 1;
        }
        self.stages[self.stage_count] = switch (config.backend) {
            .tiled => .scene_raster_tiled,
            .direct => .scene_raster_direct,
        };
        self.stage_count += 1;
        if (config.include_post_process) {
            self.stages[self.stage_count] = .post_process;
            self.stage_count += 1;
        }
        if (config.include_present) {
            self.stages[self.stage_count] = .present;
            self.stage_count += 1;
        }

        self.config = config;
        self.valid = true;
    }

    pub fn compiled(self: *const CachedPlan) CompiledPlan {
        return .{ .stages = self.stages[0..self.stage_count] };
    }
};

test "frame plan orders stages by backend and feature set" {
    var plan = CachedPlan{};
    plan.compileIfNeeded(.{
        .include_shadow_build = true,
        .backend = .direct,
    });

    try std.testing.expectEqual(@as(usize, 4), plan.stage_count);
    try std.testing.expectEqual(FrameStageId.shadow_build, plan.stages[0]);
    try std.testing.expectEqual(FrameStageId.scene_raster_direct, plan.stages[1]);
    try std.testing.expectEqual(FrameStageId.post_process, plan.stages[2]);
    try std.testing.expectEqual(FrameStageId.present, plan.stages[3]);
}
