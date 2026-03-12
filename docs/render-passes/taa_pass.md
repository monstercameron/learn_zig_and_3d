# Temporal AA Pass

Source: /engine/src/render/passes/taa_pass.zig

## How It Should Work (Design Contract)
- Reproject previous frame history into current frame and blend with confidence gating.
- Prefer geometry-identity reprojection, fallback to camera reprojection when needed.
- Clamp history to local neighborhoods to avoid ghosting and lag trails.
- Finalize and persist history channels for next-frame reuse.

## How It Does Work Today (Code Walkthrough)
- bootstrapHistory() initializes history buffers on first valid frame.
- runPipeline() dispatches row jobs then calls finalizeHistory() each frame.
- runRows() performs reprojection, depth/normal/edge confidence checks, and blending.
- Uses taa_helpers and taa_meshlet_batch fast-path before scalar fallback.

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
- std
- ../../core/math.zig
- taa_helpers.zig

## Key Entry Points in This File
- L12: pub fn bootstrapHistory(
- L33: pub fn runPipeline(
- L126: pub fn finalizeHistory(
- L150: pub fn runRows(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
