# SSAO Pass

Source: /engine/src/render/passes/ssao_pass.zig

## How It Should Work (Design Contract)
- Run SSAO as staged pipeline: generate AO -> blur H -> blur V -> composite.
- Use depth/normal cues to estimate occlusion while limiting halo artifacts.
- Blur with depth awareness to denoise without crossing hard edges.
- Keep each stage independently schedulable for profiling/tuning.

## How It Does Work Today (Code Walkthrough)
- Defines Stage enum and executes stage-specific kernels via runStageRange().
- dispatchStage() partitions rows and submits jobs for current stage.
- runPipeline() executes generate/blur/composite in fixed order each frame.
- Composite stage darkens final scene color using AO visibility results.

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
- ../kernels/ssao_sample_kernel.zig
- ../kernels/ssao_blur_kernel.zig

## Key Entry Points in This File
- L9: pub const Stage = enum {
- L18: pub fn JobContext(
- L78: fn runStageRange(
- L99: fn dispatchStage(
- L168: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
