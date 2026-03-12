# Depth Of Field Pass

Source: /engine/src/render/passes/depth_of_field_pass.zig

## How It Should Work (Design Contract)
- Blur pixels by circle-of-confusion derived from focus distance/range.
- Preserve focused plane while smoothly increasing blur out of focus.
- Use scratch buffers to avoid read/write hazards during neighborhood sampling.
- Scale workload via row stripes for multicore CPU execution.

## How It Does Work Today (Code Walkthrough)
- runRows() invokes DoF kernel over assigned row ranges.
- runPipeline() stages job contexts with configured focal range and blur radius.
- Reads scene color/depth and writes into output/scratch targets.
- Uses config constants for focal plane and max blur radius.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../kernels/depth_of_field_kernel.zig
- ../../core/app_config.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L12: pub fn runRows(
- L39: pub fn runPipeline(self: anytype, scene_width: usize, scene_height: usize, comptime noop_job_fn: fn (*anyopaque) void) void {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
