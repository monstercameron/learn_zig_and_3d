# Lens Flare Pass

Source: /engine/src/render/passes/lens_flare_pass.zig

## How It Should Work (Design Contract)
- Generate stylized flare artifacts from bright source regions/light direction.
- Support streak/ghost style composition with bounded intensity.
- Execute as post process with no scene mutation side effects.
- Scale by row dispatch to keep cost manageable on CPU.

## How It Does Work Today (Code Walkthrough)
- runRows() delegates to lens flare kernel per stripe.
- runPipeline() partitions and schedules row jobs.
- Reads source frame and writes flare-composited destination pixels.
- Relies on kernel-level sampling/threshold logic for flare shape.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../kernels/lens_flare_kernel.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L11: pub fn runRows(
- L24: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
