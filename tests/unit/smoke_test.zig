const std = @import("std");
const taa_kernel = @import("taa_kernel");
const hybrid_shadow_candidate_kernel = @import("hybrid_shadow_candidate_kernel");
const hybrid_shadow_resolve_kernel = @import("hybrid_shadow_resolve_kernel");

test "smoke: test harness boots" {
    try std.testing.expect(true);
}

test "taa kernel resolvePixel blends history and current" {
    const current: u32 = 0xFF204060;
    const history: u32 = 0xFF6080A0;
    const params = taa_kernel.TemporalResolveParams{ .history_weight = 0.5 };
    const out = taa_kernel.resolvePixel(current, history, params);

    try std.testing.expectEqual(@as(u32, 0xFF406080), out);
}

test "hybrid shadow candidate kernel advances generation and wraps" {
    var marks = [_]u32{ 1, 2, 3 };
    const next1 = hybrid_shadow_candidate_kernel.nextMark(7, marks[0..]);
    try std.testing.expectEqual(@as(u32, 8), next1);

    const wrapped = hybrid_shadow_candidate_kernel.nextMark(std.math.maxInt(u32), marks[0..]);
    try std.testing.expectEqual(@as(u32, 1), wrapped);
    try std.testing.expectEqual(@as(u32, 0), marks[0]);
    try std.testing.expectEqual(@as(u32, 0), marks[1]);
    try std.testing.expectEqual(@as(u32, 0), marks[2]);
}

test "hybrid shadow resolve kernel blends with clamped factor" {
    const blended_a = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 0.0);
    const blended_b = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 1.0);
    const blended_c = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), blended_a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), blended_b, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), blended_c, 1e-6);
}
