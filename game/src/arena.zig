//! Arena shooter — the canonical benchmark workload.
//!
//! See ROADMAP.md "Phase A: Game (the workload)". The goal of this
//! module is *not* a fun game — it's a deterministic, content-rich
//! scene that exercises raster + lighting + post-processing in a
//! repeatable way so the cross-ISA SIMD benchmark has a fair workload.
//!
//! Not implemented yet. Sketch of what goes here:
//!
//! - Fixed-tick gameplay (player movement, enemy spawns, projectile
//!   integration) decoupled from frame rate so the render workload
//!   stays identical regardless of which SIMD path is rendering it.
//! - Scripted enemy waves with a deterministic RNG seed.
//! - Hook for the record/replay system so inputs can be played back.
//! - A canonical "benchmark map" with locked triangle count, light
//!   count, and post-pass set.

const std = @import("std");

pub const SeedConfig = struct {
    rng_seed: u64 = 0xCAFE_F00D,
};

pub fn step(seed: SeedConfig, dt: f32) void {
    _ = seed;
    _ = dt;
}
