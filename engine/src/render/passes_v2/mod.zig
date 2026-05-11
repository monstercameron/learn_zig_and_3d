//! `passes_v2` — modern post-process pass interface for the deferred
//! pipeline. Replaces the naive `passes/*_pass.zig` family, which read
//! `renderer.bitmap.pixels` directly and ping-ponged through scratch
//! buffers via implicit globals.
//!
//! Design principles (deliberate departures from the v1 passes):
//!
//!   1. **Explicit I/O.** Every pass takes `in_color` and `out_color` as
//!      slice arguments. In-place is signalled by passing the same
//!      slice for both — never assumed.
//!   2. **G-buffer aware.** Passes that need depth/normal/material
//!      receive them as typed read-only slices, not via the global
//!      `Renderer` struct.
//!   3. **Silhouette-correct.** Passes that should not affect the
//!      background (vignette, grain, rim) read the depth buffer and
//!      gate writes on `isFinite(depth)`. No more rectangular halos.
//!   4. **Idempotency contract.** Each pass declares `.idempotent: bool`
//!      in its `Descriptor`. Cache-aware drivers can skip non-idempotent
//!      passes on cache-hit frames.
//!   5. **Scanner-friendly.** Each pass returns a `Result` with the
//!      bounds it touched + counters, so `iq_scanner.compare()` can
//!      verify adherence and detect artifacts without instrumentation.
//!   6. **Cache & SIMD-portable.** Inner kernels use
//!      `cpu_features.SIMD_F32_LANES` — the same source compiles to
//!      SSE2/AVX2/AVX-512/NEON/SVE.
//!
//! A pass is just a struct that exposes `pub const descriptor: Descriptor`
//! and `pub fn execute(Inputs) Result`. Stateless. No allocator threading.

const std = @import("std");
const direct_primitives = @import("../direct/primitives.zig");

pub const Rect2i = direct_primitives.Rect2i;

/// Read-only G-buffer view passed to every pass. Slices are non-owning;
/// the renderer owns the underlying memory.
pub const GBufferView = struct {
    width: i32,
    height: i32,
    depth: []const f32, // +inf = no geometry at this pixel
    normal: []const Vec3, // camera-space normal
    base_color: []const u32, // packed RGBA8 albedo
    material: []const u32, // packed roughness/metallic/ao/flags
};

/// Local Vec3 mirror so this module stays decoupled from the math
/// module's full surface area; layout matches `math.Vec3`.
pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };

/// Standard input struct every v2 pass receives. Drivers fill this
/// once per frame and reuse it across passes.
pub const Inputs = struct {
    width: i32,
    height: i32,
    /// Source LDR colour (packed 0xAARRGGBB).
    in_color: []const u32,
    /// Destination LDR colour. May alias `in_color` — passes that need
    /// the source intact after they write must check
    /// `descriptor.requires_scratch`.
    out_color: []u32,
    /// G-buffer for shaders that consult geometry data.
    gbuf: ?GBufferView = null,
    /// Bounds to process. `null` means the full screen. Passes are
    /// expected to clip to their own valid region and the in-bounds
    /// intersection.
    dirty_rect: ?Rect2i = null,
    /// Per-frame seed for animated noise (film grain etc.). Drivers
    /// typically pass `frame_index` or `nanos & 0xFFFFFFFF`.
    seed: u32 = 0,
};

/// Pass result — counters the scanner and telemetry consume.
pub const Result = struct {
    /// Bounds the pass actually wrote to. Useful for downstream stages
    /// (present, scanner) to know what changed.
    touched_rect: ?Rect2i = null,
    /// Pixels modified by this pass. Drivers can compare against
    /// expected lower bounds to flag silent no-ops.
    pixels_modified: usize = 0,
    /// Nanoseconds spent inside `execute`. Filled by the driver, not
    /// the pass body — but exposed here so all reporting is uniform.
    elapsed_ns: i128 = 0,
};

/// Compile-time description of how a pass behaves. Drivers use this
/// to schedule, cache, and validate.
pub const Descriptor = struct {
    name: []const u8,
    /// True if running the pass twice on its own output produces the
    /// same result the first run did. False = cache-aware drivers must
    /// skip on cache-hit frames.
    idempotent: bool,
    /// True if the pass needs a separate scratch buffer (cannot accept
    /// `in_color == out_color`). Drivers must allocate scratch when
    /// composing such passes.
    requires_scratch: bool,
    /// True if the pass reads from the G-buffer (depth/normal/material).
    /// Drivers can skip the pass when no G-buffer is bound.
    reads_gbuffer: bool,
    /// One-line description for telemetry / CLI listings.
    summary: []const u8,
};

// -----------------------------------------------------------------------
//                           Re-exports
// -----------------------------------------------------------------------
//
// As each legacy pass is ported, its v2 module is registered here. The
// driver iterates this list to enable/dispatch/scan them uniformly.

pub const depth_fog = @import("depth_fog.zig");
pub const chromatic_aberration = @import("chromatic_aberration.zig");
pub const color_grade = @import("color_grade.zig");
pub const lens_flare = @import("lens_flare.zig");
pub const motion_blur = @import("motion_blur.zig");
pub const god_rays = @import("god_rays.zig");

/// Compile-time table of every available v2 pass. Drivers iterate it
/// to look up by name or list available passes via CLI.
pub const all = [_]Descriptor{
    depth_fog.descriptor,
    chromatic_aberration.descriptor,
    color_grade.descriptor,
    lens_flare.descriptor,
    motion_blur.descriptor,
    god_rays.descriptor,
};
