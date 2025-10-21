const std = @import("std");
const compute = @import("compute.zig");
const Vec2u = compute.Vec2u;
const ComputeContext = compute.ComputeContext;
const job_system = @import("../job_system.zig"); // Import the main job system

/// Context for a single group dispatch job.
/// This struct holds the necessary information for a worker thread to process one group.
const GroupDispatchJobContext = struct {
    kernel_type: type, // Store the kernel type for comptime access
    ctx_base: ComputeContext, // Base context with global resources
    gx: u32, // Group X ID
    gy: u32, // Group Y ID
    allocator: std.mem.Allocator, // Allocator for shared memory
};

/// The function executed by a worker thread for a single group.
fn groupDispatchJobFn(ctx_ptr: *anyopaque) void {
    const job_ctx: *GroupDispatchJobContext = @ptrCast(@alignCast(ctx_ptr));
    const K = job_ctx.kernel_type; // Get the kernel type from the context

    const gs = Vec2u{ .x = K.group_size_x, .y = K.group_size_y };
    var shared: ?[]u8 = null;
    if (K.SharedSize > 0) {
        // Allocate shared memory for this group
        shared = job_ctx.allocator.alloc(u8, K.SharedSize) catch {
            std.debug.print("ERROR: Failed to allocate shared memory for kernel group!\n", .{});
            return; // Handle allocation failure
        };
        std.mem.set(u8, shared.?, 0);
    }

    var ctx = job_ctx.ctx_base; // Copy the base context
    ctx.group_size = gs;
    ctx.shared_mem = shared;
    ctx.group_id = .{ .x = job_ctx.gx, .y = job_ctx.gy };

    // Loop through local threads within this group
    var ly: u32 = 0;
    while (ly < gs.y) : (ly += 1) {
        var lx: u32 = 0;
        while (lx < gs.x) : (lx += 1) {
            const px = ctx.group_id.x * gs.x + lx;
            const py = ctx.group_id.y * gs.y + ly;

            // Check bounds against image size
            if (px >= ctx.image_size.x or py >= ctx.image_size.y) continue;

            ctx.local_id = .{ .x = lx, .y = ly };
            ctx.global_id = .{ .x = px, .y = py };
            K.main(&ctx); // Execute the kernel's main function
        }
    }

    if (shared) |buf| job_ctx.allocator.free(buf);
    // Free the job context itself after the job is done
    job_ctx.allocator.destroy(job_ctx);
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

    // Create a parent job to track completion of all group dispatches
    var parent_job = try job_system.allocateJob(allocator, noopJob, null, null);
    defer job_system.freeJob(allocator, parent_job);

    // Loop through the grid of groups and submit a job for each
    var gy: u32 = 0;
    while (gy < ctx_base.num_groups.y) : (gy += 1) {
        var gx: u32 = 0;
        while (gx < ctx_base.num_groups.x) : (gx += 1) {
            // Allocate job context for this group
            var job_ctx = try allocator.create(GroupDispatchJobContext);
            job_ctx.* = GroupDispatchJobContext{
                .kernel_type = K,
                .ctx_base = ctx_base.*, // Copy the base context
                .gx = gx,
                .gy = gy,
                .allocator = allocator,
            };

            // Allocate and submit the job
            var job = try job_system.allocateJob(allocator, groupDispatchJobFn, job_ctx, parent_job);
            if (!job_sys.submitJobAuto(job)) {
                // Handle job submission failure (e.g., queue full)
                job_system.freeJob(allocator, job);
                allocator.destroy(job_ctx);
                return error.JobSubmissionFailed;
            }
        }
    }

    // Wait for all child jobs (group dispatches) to complete
    parent_job.wait();
}
