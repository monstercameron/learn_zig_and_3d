# Shadow Map Pass

Source: /engine/src/render/passes/shadow_map_pass.zig

## How It Should Work (Design Contract)
- For each shadow-map light, build light-space depth then resolve occlusion to scene color.
- Compute robust light-space bounds and texel bias to reduce acne/peter-panning.
- Rasterize and resolve in parallel stripes for multicore scaling.
- Gracefully disable when shadow inputs are invalid or disabled.

## How It Does Work Today (Code Walkthrough)
- runBuild() computes light-space basis/bounds, clears depth, and dispatches raster stripes.
- RasterJobContext wraps row jobs that call shadow_raster_rows.rasterizeShadowMeshRange().
- runPipeline() dispatches shadow resolve job stripes over scene pixels.
- runPerLight() is the per-light orchestration entry used by renderer light loop.

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
- shadow_raster_rows.zig
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L14: pub fn RasterJobContext(comptime MeshType: type, comptime ShadowMapType: type) type {
- L59: pub fn runBuild(
- L175: pub fn runPerLight(
- L188: pub fn runPipeline(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
