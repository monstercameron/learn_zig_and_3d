# Skybox Pass

Source: /engine/src/render/passes/skybox_pass.zig

## How It Should Work (Design Contract)
- Fill background pixels by mapping camera rays into sky/HDR environment.
- Avoid touching foreground pixels that already contain valid scene geometry where required.
- Run as row-parallel pass due to full-frame coverage.
- Provide generic job context wrappers for renderer integration.

## How It Does Work Today (Code Walkthrough)
- JobContext() and runJobWrapper() bridge renderer job system to row kernel calls.
- runRows() invokes skybox kernel over [start_row, end_row).
- runPipeline() computes stripe partition and dispatches jobs.
- Consumes renderer/camera/projection + HDR map inputs to write output color.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../../core/math.zig
- ../kernels/skybox_kernel.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L12: pub fn JobContext(comptime RendererType: type, comptime ProjectionType: type, comptime HdriMapType: type) type {
- L27: pub fn runJobWrapper(comptime CtxType: type) fn (*anyopaque) void {
- L50: pub fn runRows(
- L77: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
