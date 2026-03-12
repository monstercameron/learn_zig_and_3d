# Bloom Pass

Source: /engine/src/render/passes/bloom_pass.zig

## How It Should Work (Design Contract)
- Run bloom as a deterministic stage pipeline: extract -> blur H -> blur V -> composite.
- Support threshold/intensity control through LUTs so tuning is cheap at runtime.
- Distribute stage work in row stripes for multicore CPU utilization.
- Keep stage boundaries explicit to simplify profiling and quality tuning.

## How It Does Work Today (Code Walkthrough)
- Defines Stage enum and per-stage dispatch through dispatchStage().
- buildThresholdCurve() and buildIntensityLut() precompute 8-bit mappings.
- runStageRange() calls row-kernel callbacks for extract/blur/composite.
- runPipeline() executes all stages in fixed order each frame.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../pipeline/pass_dispatch.zig
- ../core/utils.zig

## Key Entry Points in This File
- L9: pub const Stage = enum {
- L17: pub fn buildThresholdCurve(threshold: i32) [256]u8 {
- L31: pub fn buildIntensityLut(intensity_percent: i32) [256]u8 {
- L41: pub fn JobContext(comptime BloomScratchType: type) type {
- L85: fn runStageRange(
- L114: fn dispatchStage(
- L177: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
