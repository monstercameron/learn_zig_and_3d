//! Image-quality scanner. Compares before/after framebuffers around a
//! post-process pass and emits an `ArtifactReport` describing what the
//! pass did and where it failed.
//!
//! Two questions per pass:
//!
//!   1. **Adherence**: did the pass actually do something? (`pixels_changed`,
//!      `mean_channel_delta`). A pass enabled but silently no-op'ing is
//!      a regression we want to catch.
//!   2. **Artifacts**: did it do something *wrong*?
//!      - `saturation_introduced`: pixels newly clamped at 255 (over-bright)
//!      - `grayscale_collapse`:    R≈G≈B pixels that weren't grayscale before
//!      - `bleeding_outside_geom`: pixels modified where depth == +inf
//!                                 (post effect leaked into background)
//!      - `discontinuity_score`:   high Laplacian on the diff = visible seam
//!      - `nan_pixels`:            HDR pass produced NaN/Inf (deferred path)
//!
//! Composite `score` in [0, 100]: 100 means the pass ran cleanly with no
//! detected artifacts; lower means at least one issue.

const std = @import("std");

/// Local Vec4 mirror so the scanner stays standalone-testable. Layout
/// matches `math.Vec4`; the HDR scan only reads x/y/z/w as f32 anyway.
pub const HdrPixel = struct { x: f32, y: f32, z: f32, w: f32 };

pub const Snapshot = struct {
    pixels: []const u32,
    depth: ?[]const f32 = null,
    width: i32,
    height: i32,
};

pub const ArtifactReport = struct {
    pass_name: []const u8 = "",
    total_pixels: usize = 0,

    // -- Adherence -------------------------------------------------------
    /// Pixels whose final colour differs from the source (any channel).
    pixels_changed: usize = 0,
    /// Mean |delta| across R/G/B for pixels that changed.
    mean_channel_delta: f32 = 0.0,
    /// Largest single-channel delta seen.
    max_channel_delta: u8 = 0,

    // -- Artifacts -------------------------------------------------------
    /// Pixels that newly hit 255 on any channel (weren't before).
    saturation_introduced: usize = 0,
    /// Pixels that became R≈G≈B (within `grayscale_eps`) but weren't.
    /// Catches the "deferred path went grayscale" regression class.
    grayscale_collapse: usize = 0,
    /// Pixels modified where source depth was non-finite (background).
    /// A bleeding score >0 means the pass leaked outside geometry —
    /// silhouette-aware passes should report 0 here.
    bleeding_outside_geom: usize = 0,
    /// Sum of |∇²(after - before)| over the diff. Discrete Laplacian
    /// magnitude; spikes when the pass introduces hard edges/seams.
    discontinuity_score: f32 = 0.0,
    /// Floating-point NaN/Inf detected (HDR passes only; 0 here in LDR).
    nan_pixels: usize = 0,

    // -- Score -----------------------------------------------------------
    /// 0-100 composite. 100 = clean. Each artifact category subtracts.
    score: f32 = 100.0,

    pub fn writeJsonLine(self: ArtifactReport, w: anytype) !void {
        try w.print(
            "{{\"event\":\"iq_scan\",\"pass\":\"{s}\",\"total\":{d},\"changed\":{d},\"mean_delta\":{d:.2},\"max_delta\":{d},\"saturation\":{d},\"grayscale\":{d},\"bleed\":{d},\"discontinuity\":{d:.1},\"nan\":{d},\"score\":{d:.1}}}\n",
            .{
                self.pass_name,
                self.total_pixels,
                self.pixels_changed,
                self.mean_channel_delta,
                self.max_channel_delta,
                self.saturation_introduced,
                self.grayscale_collapse,
                self.bleeding_outside_geom,
                self.discontinuity_score,
                self.nan_pixels,
                self.score,
            },
        );
    }
};

const GRAYSCALE_EPS: u32 = 4; // |R-G|+|G-B|+|R-B| < EPS counts as grayscale

inline fn unpackR(p: u32) i32 {
    return @intCast((p >> 16) & 0xFF);
}
inline fn unpackG(p: u32) i32 {
    return @intCast((p >> 8) & 0xFF);
}
inline fn unpackB(p: u32) i32 {
    return @intCast(p & 0xFF);
}

inline fn isGrayscale(r: i32, g: i32, b: i32) bool {
    const rg: u32 = @intCast(@abs(r - g));
    const gb: u32 = @intCast(@abs(g - b));
    const rb: u32 = @intCast(@abs(r - b));
    return (rg + gb + rb) < GRAYSCALE_EPS;
}

/// Compare two LDR framebuffers. Both must be the same shape. The depth
/// buffer in `before` is used to detect bleeding outside geometry; pass
/// `null` to skip that check (no silhouette assumption).
pub fn compare(
    before: Snapshot,
    after_pixels: []const u32,
    pass_name: []const u8,
) ArtifactReport {
    var r: ArtifactReport = .{ .pass_name = pass_name };
    if (before.pixels.len == 0 or before.pixels.len != after_pixels.len) {
        r.score = 0.0;
        return r;
    }
    r.total_pixels = before.pixels.len;

    var sum_delta: u64 = 0;
    var max_delta: u8 = 0;
    var changed: usize = 0;
    var saturated: usize = 0;
    var grayscaled: usize = 0;
    var bled: usize = 0;

    for (before.pixels, 0..) |bp, idx| {
        const ap = after_pixels[idx];
        if (bp == ap) continue;
        changed += 1;

        const br = unpackR(bp);
        const bg = unpackG(bp);
        const bb = unpackB(bp);
        const ar = unpackR(ap);
        const ag = unpackG(ap);
        const ab = unpackB(ap);

        const dr: u8 = @intCast(@abs(ar - br));
        const dg: u8 = @intCast(@abs(ag - bg));
        const db: u8 = @intCast(@abs(ab - bb));
        sum_delta += @as(u64, dr) + @as(u64, dg) + @as(u64, db);
        max_delta = @max(max_delta, @max(dr, @max(dg, db)));

        // Saturation: any channel went from <255 to ==255.
        if ((ar == 255 and br < 255) or
            (ag == 255 and bg < 255) or
            (ab == 255 and bb < 255))
        {
            saturated += 1;
        }

        // Grayscale collapse: became grayscale but wasn't.
        if (isGrayscale(ar, ag, ab) and !isGrayscale(br, bg, bb)) {
            grayscaled += 1;
        }

        // Bleeding: pixel was background (depth == +inf) but got modified.
        if (before.depth) |dbuf| {
            if (!std.math.isFinite(dbuf[idx])) bled += 1;
        }
    }

    if (changed > 0) {
        r.mean_channel_delta = @as(f32, @floatFromInt(sum_delta)) / @as(f32, @floatFromInt(changed)) / 3.0;
    }
    r.max_channel_delta = max_delta;
    r.pixels_changed = changed;
    r.saturation_introduced = saturated;
    r.grayscale_collapse = grayscaled;
    r.bleeding_outside_geom = bled;
    r.discontinuity_score = discontinuityScore(before.pixels, after_pixels, before.width, before.height);
    r.score = composite(r);
    return r;
}

/// Approximate HDR f32 NaN/Inf scan. For the deferred path's `scene_hdr`
/// before tonemap. Returns the count of non-finite components.
pub fn scanHdrNaN(buffer: []const HdrPixel) usize {
    var n: usize = 0;
    for (buffer) |p| {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y) or
            !std.math.isFinite(p.z) or !std.math.isFinite(p.w))
        {
            n += 1;
        }
    }
    return n;
}

/// Discrete Laplacian on the channel-wise diff buffer. Summed over the
/// frame, divided by total_pixels so the score is scale-invariant. High
/// values mean the pass introduced visible high-frequency edges that
/// weren't there before (a classic artifact symptom).
fn discontinuityScore(before: []const u32, after: []const u32, width: i32, height: i32) f32 {
    if (width < 3 or height < 3) return 0.0;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    var accum: u64 = 0;
    var y: usize = 1;
    while (y + 1 < h) : (y += 1) {
        const row = y * w;
        var x: usize = 1;
        while (x + 1 < w) : (x += 1) {
            const idx = row + x;
            const dc = diffLumI(before[idx], after[idx]);
            const dl = diffLumI(before[idx - 1], after[idx - 1]);
            const dr = diffLumI(before[idx + 1], after[idx + 1]);
            const du = diffLumI(before[idx - w], after[idx - w]);
            const dd = diffLumI(before[idx + w], after[idx + w]);
            const lap: i32 = 4 * dc - dl - dr - du - dd;
            accum += @intCast(@abs(lap));
        }
    }
    return @as(f32, @floatFromInt(accum)) / @as(f32, @floatFromInt(w * h));
}

inline fn diffLumI(b: u32, a: u32) i32 {
    // Approx luminance delta: avg of channel deltas (no perceptual weights;
    // we only need a stable scalar for second-derivative magnitudes).
    const br = unpackR(b);
    const bg = unpackG(b);
    const bb = unpackB(b);
    const ar = unpackR(a);
    const ag = unpackG(a);
    const ab = unpackB(a);
    return @divTrunc((ar - br) + (ag - bg) + (ab - bb), 3);
}

/// 100 = clean. Each detected artifact class subtracts proportionally
/// to its fraction of total pixels. Hard cap at 0.
fn composite(r: ArtifactReport) f32 {
    if (r.total_pixels == 0) return 0.0;
    const total_f: f32 = @floatFromInt(r.total_pixels);
    var score: f32 = 100.0;
    score -= 100.0 * @as(f32, @floatFromInt(r.saturation_introduced)) / total_f;
    score -= 100.0 * @as(f32, @floatFromInt(r.grayscale_collapse)) / total_f;
    score -= 100.0 * @as(f32, @floatFromInt(r.bleeding_outside_geom)) / total_f;
    score -= @min(40.0, r.discontinuity_score * 4.0);
    score -= 100.0 * @as(f32, @floatFromInt(r.nan_pixels)) / total_f;
    return @max(0.0, score);
}

// -----------------------------------------------------------------------
//                              tests
// -----------------------------------------------------------------------

test "identical buffers score 100 with zero artifacts" {
    var before_pixels = [_]u32{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC };
    const snap: Snapshot = .{ .pixels = &before_pixels, .width = 2, .height = 2 };
    const report = compare(snap, &before_pixels, "noop");
    try std.testing.expectEqual(@as(usize, 0), report.pixels_changed);
    try std.testing.expectEqual(@as(f32, 100.0), report.score);
}

test "saturation introduction is counted" {
    const before_pixels = [_]u32{ 0xFF101010, 0xFF202020, 0xFF303030, 0xFF404040 };
    const after_pixels = [_]u32{ 0xFFFFFFFF, 0xFF202020, 0xFF303030, 0xFF404040 };
    const snap: Snapshot = .{ .pixels = &before_pixels, .width = 2, .height = 2 };
    const report = compare(snap, &after_pixels, "sat");
    try std.testing.expectEqual(@as(usize, 1), report.saturation_introduced);
    try std.testing.expect(report.score < 100.0);
}

test "grayscale collapse is detected" {
    // Source has distinct R/G/B; after, all three channels equal.
    const before_pixels = [_]u32{ 0xFF112233, 0xFF334455 };
    const after_pixels = [_]u32{ 0xFF222222, 0xFF444444 };
    const snap: Snapshot = .{ .pixels = &before_pixels, .width = 2, .height = 1 };
    const report = compare(snap, &after_pixels, "gray");
    try std.testing.expectEqual(@as(usize, 2), report.grayscale_collapse);
    try std.testing.expect(report.score < 100.0);
}

test "bleeding flagged when depth was infinite" {
    const before_pixels = [_]u32{ 0xFF000000, 0xFF000000 };
    const after_pixels = [_]u32{ 0xFF112233, 0xFF000000 };
    const depth = [_]f32{ std.math.inf(f32), 1.0 };
    const snap: Snapshot = .{ .pixels = &before_pixels, .depth = &depth, .width = 2, .height = 1 };
    const report = compare(snap, &after_pixels, "bleed");
    try std.testing.expectEqual(@as(usize, 1), report.bleeding_outside_geom);
}
