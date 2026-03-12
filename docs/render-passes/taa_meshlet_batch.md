# TAA Meshlet Batch

Source: /engine/src/render/passes/taa_meshlet_batch.zig

## How It Should Work (Design Contract)
- Accelerate TAA when adjacent pixels share stable meshlet/surface identity.
- Batch reprojection/history fetches to maximize SIMD lane utilization.
- Fallback immediately when batch coherence assumptions are violated.
- Produce identical blend semantics to scalar TAA path where conditions match.

## How It Does Work Today (Code Walkthrough)
- tryApply() checks SIMD-lane window validity and surface coherence.
- Collects batched history colors/weights and blends via helper batch API.
- Writes blended results directly to resolve buffer on success.
- Returns false to trigger scalar per-pixel fallback otherwise.

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
- taa_helpers.zig

## Key Entry Points in This File
- L11: pub fn tryApply(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
