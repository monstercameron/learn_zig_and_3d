# Color Grade Pass

Source: /engine/src/render/passes/color_grade_pass.zig

## How It Should Work (Design Contract)
- Apply final color transform/profile uniformly across the frame.
- Allow grading to run in contiguous ranges for SIMD-friendly processing.
- Avoid introducing temporal instability by keeping transform deterministic.
- Keep profile application centralized and reusable.

## How It Does Work Today (Code Walkthrough)
- runRange() applies grade operations over [start_index, end_index).
- runPipeline() partitions frame into jobs and dispatches them across workers.
- Uses kernel implementation for per-pixel grading math.
- Acts as a late post-process stage over already-lit color.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../kernels/color_grade_kernel.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L11: pub fn runRange(
- L21: pub fn runPipeline(self: anytype, width: usize, height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
