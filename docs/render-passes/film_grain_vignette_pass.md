# Film Grain Vignette Pass

Source: /engine/src/render/passes/film_grain_vignette_pass.zig

## How It Should Work (Design Contract)
- Apply grain and vignette in one pass to reduce memory traffic.
- Use stable pseudo-random grain per frame/pixel with bounded intensity.
- Darken toward edges with controllable radial falloff.
- Keep SIMD/scalar results visually consistent.

## How It Does Work Today (Code Walkthrough)
- runtimeLanes() chooses SIMD width from CPU feature detection.
- runRows() processes stripes and falls back safely when SIMD width is low.
- applyBlock() handles batched pixel updates for grain+vignette math.
- runPipeline() dispatches striped work each frame.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../kernels/film_grain_kernel.zig
- ../pipeline/pass_dispatch.zig
- ../../core/cpu_features.zig

## Key Entry Points in This File
- L12: fn runtimeLanes() usize {
- L23: pub fn runRows(
- L70: fn applyBlock(
- L123: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
