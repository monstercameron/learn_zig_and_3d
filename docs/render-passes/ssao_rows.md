# SSAO Rows

Source: /engine/src/render/passes/ssao_rows.zig

## How It Should Work (Design Contract)
- Provide row-level SSAO generation, bilateral blur, and compositing kernels.
- Use runtime SIMD lane sizing for stable CPU throughput improvements.
- Keep neighborhood sampling edge-aware to avoid depth bleeding.
- Offer reusable row APIs so orchestration code stays simple.

## How It Does Work Today (Code Walkthrough)
- renderRows() computes AO from sample offsets in camera/depth space.
- blurHorizontalRows()/blurVerticalRows() perform depth-threshold blur passes.
- compositeRows() applies AO visibility onto destination pixels.
- Includes SIMD block helpers for blur/composite hot loops.

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
- ../../core/cpu_features.zig
- ../core/utils.zig
- taa_helpers.zig

## Key Entry Points in This File
- L18: fn runtimeLanes() usize {
- L28: pub fn renderRows(scene_camera: []const math.Vec3, scene_width: usize, scene_height: usize, ao: anytype, config_value: anytype, start_row: usize, end_row: usize) void {
- L88: pub fn blurHorizontalRows(ao: anytype, depth_threshold: f32, start_row: usize, end_row: usize) void {
- L127: pub fn blurVerticalRows(ao: anytype, depth_threshold: f32, start_row: usize, end_row: usize) void {
- L164: fn blurHorizontalBlock(
- L195: fn blurVerticalBlock(
- L228: fn sampleVisibility(ao: anytype, scene_width: usize, scene_height: usize, x: usize, y: usize) f32 {
- L250: pub fn compositeRows(dst: []u32, scene_camera: []const math.Vec3, dst_width: usize, dst_height: usize, ao: anytype, start_row: usize, end_row: usize) void {
- L280: fn compositeBlock(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
