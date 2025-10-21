const std = @import("std");
const compute = @import("compute.zig");
const dispatcher = @import("dispatcher.zig");
const job_system = @import("../job_system.zig");
const InvertKernel = @import("invert_kernel.zig").InvertKernel;

pub fn runInvertExample(
    allocator: std.mem.Allocator,
    src_rgba8: *const compute.Texture2D,
    dst_rgba8: *compute.RWTexture2D,
    job_sys: *job_system.JobSystem,
) !void {
    var ctx = compute.ComputeContext{
        .group_size = .{ .x = 0, .y = 0 }, // filled by dispatcher
        .num_groups = .{
            .x = (src_rgba8.width + InvertKernel.group_size_x - 1) / InvertKernel.group_size_x,
            .y = (src_rgba8.height + InvertKernel.group_size_y - 1) / InvertKernel.group_size_y,
        },
        .image_size = .{ .x = src_rgba8.width, .y = src_rgba8.height },
        .ro_textures = &[_]*const compute.Texture2D{ src_rgba8 },
        .rw_textures = &[_]*compute.RWTexture2D{ dst_rgba8 },
        .push_constants = null,
        .group_id = .{ .x = 0, .y = 0 },
        .local_id = .{ .x = 0, .y = 0 },
        .global_id = .{ .x = 0, .y = 0 },
        .shared_mem = null,
    };

    try dispatcher.dispatchKernel(InvertKernel, allocator, job_sys, &ctx);
}
