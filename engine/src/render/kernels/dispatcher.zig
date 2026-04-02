//! Dispatcher module.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");
const compute = @import("compute.zig");
const Vec2u = compute.Vec2u;
const ComputeContext = compute.ComputeContext;
const job_system = @import("job_system");

const GroupDispatchJobContext = struct {
    ctx_base: ComputeContext,
    gx: u32,
    gy: u32,
    shared: ?[]u8,
};

fn runGroup(comptime K: type, job_ctx: *const GroupDispatchJobContext) void {
    const gs = Vec2u{ .x = K.group_size_x, .y = K.group_size_y };
    var ctx = job_ctx.ctx_base;
    ctx.group_size = gs;
    ctx.shared_mem = job_ctx.shared;
    ctx.group_id = .{ .x = job_ctx.gx, .y = job_ctx.gy };

    var ly: u32 = 0;
    while (ly < gs.y) : (ly += 1) {
        var lx: u32 = 0;
        while (lx < gs.x) : (lx += 1) {
            const px = ctx.group_id.x * gs.x + lx;
            const py = ctx.group_id.y * gs.y + ly;
            if (px >= ctx.image_size.x or py >= ctx.image_size.y) continue;

            ctx.local_id = .{ .x = lx, .y = ly };
            ctx.global_id = .{ .x = px, .y = py };
            K.main(&ctx);
        }
    }
}

fn noopJob(ctx: *anyopaque) void {
    _ = ctx;
}

/// Dispatches a compute kernel across a grid of thread groups.
/// This version uses the project's job system for multi-threaded execution.
///
/// Constraint: K must provide:
///   pub const group_size_x: u32;
///   pub const group_size_y: u32;
///   pub const SharedSize: usize = 0; // optional
///   pub fn main(ctx: *ComputeContext) void;
pub fn dispatchKernel(comptime K: type, allocator: std.mem.Allocator, job_sys: *job_system.JobSystem, ctx_base: *const ComputeContext) !void {
    const gs = Vec2u{ .x = K.group_size_x, .y = K.group_size_y };
    _ = gs;

    const group_count: usize = @as(usize, @intCast(ctx_base.num_groups.x)) * @as(usize, @intCast(ctx_base.num_groups.y));
    if (group_count == 0) return;

    var parent_job = job_system.Job.init(noopJob, @ptrFromInt(1), null);
    var contexts = try allocator.alloc(GroupDispatchJobContext, group_count);
    defer allocator.free(contexts);
    var jobs = try allocator.alloc(job_system.Job, if (group_count > 1) group_count - 1 else 1);
    defer allocator.free(jobs);

    var shared_pool: ?[]u8 = null;
    if (K.SharedSize > 0) {
        shared_pool = try allocator.alloc(u8, K.SharedSize * group_count);
        @memset(shared_pool.?, 0);
    }
    defer if (shared_pool) |pool| allocator.free(pool);

    errdefer {
        parent_job.complete();
        job_sys.waitFor(&parent_job);
    }

    const Dispatch = struct {
        fn run(ctx_ptr: *anyopaque) void {
            const job_ctx: *const GroupDispatchJobContext = @ptrCast(@alignCast(ctx_ptr));
            runGroup(K, job_ctx);
        }
    };

    var index: usize = 0;
    var gy: u32 = 0;
    while (gy < ctx_base.num_groups.y) : (gy += 1) {
        var gx: u32 = 0;
        while (gx < ctx_base.num_groups.x) : (gx += 1) {
            contexts[index] = .{
                .ctx_base = ctx_base.*, // Copy the base context
                .gx = gx,
                .gy = gy,
                .shared = if (shared_pool) |pool|
                    pool[index * K.SharedSize ..][0..K.SharedSize]
                else
                    null,
            };

            if (index == 0) {
                index += 1;
                continue;
            }

            const job_index = index - 1;
            jobs[job_index] = job_system.Job.init(
                Dispatch.run,
                @ptrCast(&contexts[index]),
                &parent_job,
            );
            if (!job_sys.submitJobWithClass(&jobs[job_index], .normal)) {
                // Fallback preserves forward progress without failing dispatch.
                Dispatch.run(@ptrCast(&contexts[index]));
            }

            index += 1;
        }
    }

    Dispatch.run(@ptrCast(&contexts[0]));
    parent_job.complete();
    job_sys.waitFor(&parent_job);
}
