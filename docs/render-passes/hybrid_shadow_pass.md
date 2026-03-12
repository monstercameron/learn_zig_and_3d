# Hybrid Shadow Pass

Source: /engine/src/render/passes/hybrid_shadow_pass.zig

## How It Should Work (Design Contract)
- Build per-light shadow candidates cheaply before expensive intersection tests.
- Keep CPU ray/shadow work bounded by tile receiver bounds and caster culling.
- Reuse scratch buffers and caches to avoid per-frame allocations.
- Expose instrumentation so shadow cost can be tuned against frame budget.

## How It Does Work Today (Code Walkthrough)
- ensureScratch() grows caster/tile/grid scratch arrays on demand.
- buildReceiverBounds() and collectTileCandidates() prune work per tile.
- buildGrid() builds coarse spatial bins for caster lookup acceleration.
- runPipeline() orchestrates candidate/cache/resolve steps and updates pass timing stats.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- std
- ../../core/math.zig
- ../../core/app_config.zig
- ../kernels/hybrid_shadow_cache_kernel.zig
- ../kernels/hybrid_shadow_candidate_kernel.zig
- ../core/utils.zig

## Key Entry Points in This File
- L27: pub fn run(
- L36: pub fn ensureScratch(self: anytype, caster_capacity: usize, tile_candidate_capacity: usize, grid_candidate_capacity: usize) !void {
- L75: fn nextCandidateMark(self: anytype) u32 {
- L83: fn collectTileCandidates(self: anytype, receiver_bounds: anytype, candidate_write: *usize) @TypeOf(self.hybrid_shadow_stats) {
- L144: fn buildReceiverBounds(self: anytype, tile: anytype, camera_to_light: anytype) ?ReceiverBounds {
- L196: fn buildGrid(self: anytype, caster_count: usize, light_basis_right: math.Vec3, light_basis_up: math.Vec3) void {
- L279: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
