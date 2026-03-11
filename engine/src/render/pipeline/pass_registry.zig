const pass_graph = @import("pass_graph.zig");

pub const PassNode = pass_graph.PassNode;
pub const RenderPassId = pass_graph.RenderPassId;

pub const post_passes = pass_graph.default_post_pass_order;

pub fn executePostPasses(
    ctx: anytype,
    comptime is_enabled_fn: fn (@TypeOf(ctx), RenderPassId) bool,
    comptime run_fn: fn (@TypeOf(ctx), RenderPassId) void,
) void {
    for (post_passes) |node| {
        if (!is_enabled_fn(ctx, node.id)) continue;
        run_fn(ctx, node.id);
    }
}
