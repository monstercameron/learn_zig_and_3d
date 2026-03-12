# God Rays Pass

Source: /engine/src/render/passes/god_rays_pass.zig

## How It Should Work (Design Contract)
- Estimate light shaft scattering by sampling along light-projected screen rays.
- Accumulate and normalize shaft contribution without washing out highlights.
- Support row-parallel execution due to high sample counts.
- Blend result as additive/weighted post light effect.

## How It Does Work Today (Code Walkthrough)
- runRows() calls god-rays kernel for a row stripe.
- runPipeline() partitions image by rows and submits jobs.
- Kernel performs ray-march style sampling from each pixel toward light.
- Writes filtered shaft contribution into destination pixels.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../kernels/god_rays_kernel.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L11: pub fn runRows(
- L44: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
