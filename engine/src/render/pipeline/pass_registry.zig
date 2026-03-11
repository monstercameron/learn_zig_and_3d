const pass_graph = @import("pass_graph.zig");

pub const PassNode = pass_graph.PassNode;
pub const RenderPassId = pass_graph.RenderPassId;
pub const PassPhase = pass_graph.PassPhase;
pub const PassMask = u64;

pub const post_passes = pass_graph.default_post_pass_order;

pub fn PassInterface(comptime CtxType: type) type {
    return struct {
        is_enabled: fn (CtxType, RenderPassId) bool,
        run: fn (CtxType, RenderPassId) void,
        on_phase_boundary: ?*const fn (CtxType, PassPhase) void = null,
    };
}

pub fn buildEnabledMask(
    ctx: anytype,
    comptime is_enabled_fn: fn (@TypeOf(ctx), RenderPassId) bool,
) PassMask {
    var mask: PassMask = 0;
    for (post_passes) |node| {
        if (!is_enabled_fn(ctx, node.id)) continue;
        mask |= pass_graph.passBit(node.id);
    }
    return mask;
}

pub fn executeMask(
    ctx: anytype,
    enabled_mask: PassMask,
    comptime run_fn: fn (@TypeOf(ctx), RenderPassId) void,
) void {
    executeMaskWithPhaseBoundary(ctx, enabled_mask, run_fn, null);
}

pub fn executeMaskWithPhaseBoundary(
    ctx: anytype,
    enabled_mask: PassMask,
    comptime run_fn: fn (@TypeOf(ctx), RenderPassId) void,
    phase_boundary_fn: ?*const fn (@TypeOf(ctx), PassPhase) void,
) void {
    if (enabled_mask == 0) return;
    var current_phase: ?PassPhase = null;
    for (post_passes) |node| {
        if ((enabled_mask & pass_graph.passBit(node.id)) == 0) continue;
        if (current_phase == null or current_phase.? != node.phase) {
            current_phase = node.phase;
            if (phase_boundary_fn) |f| f(ctx, node.phase);
        }
        run_fn(ctx, node.id);
    }
}

pub fn executePostPasses(
    ctx: anytype,
    comptime is_enabled_fn: fn (@TypeOf(ctx), RenderPassId) bool,
    comptime run_fn: fn (@TypeOf(ctx), RenderPassId) void,
) void {
    const enabled_mask = buildEnabledMask(ctx, is_enabled_fn);
    executeMask(ctx, enabled_mask, run_fn);
}

pub fn executeWithInterface(ctx: anytype, iface: PassInterface(@TypeOf(ctx))) void {
    const enabled_mask = buildEnabledMask(ctx, iface.is_enabled);
    executeMaskWithPhaseBoundary(ctx, enabled_mask, iface.run, iface.on_phase_boundary);
}

pub fn executeMaskWithInterface(ctx: anytype, enabled_mask: PassMask, iface: PassInterface(@TypeOf(ctx))) void {
    executeMaskWithPhaseBoundary(ctx, enabled_mask, iface.run, iface.on_phase_boundary);
}
