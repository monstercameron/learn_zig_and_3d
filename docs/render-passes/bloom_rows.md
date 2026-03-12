# Bloom Rows

Source: /engine/src/render/passes/bloom_rows.zig

## How It Should Work (Design Contract)
- Provide cache-friendly row kernels for downsample, blur, and composite steps.
- Use runtime SIMD lane width when available while preserving scalar correctness.
- Keep row kernels reusable from orchestration code without pass-state coupling.
- Minimize per-pixel branch divergence in blur/composite loops.

## How It Does Work Today (Code Walkthrough)
- extractDownsampleRows() downsamples bright content into bloom scratch targets.
- blurHorizontalRows() and blurVerticalRows() apply separable blur taps.
- compositeRows() merges bloom back into destination using intensity LUT scaling.
- compositeBlock() handles SIMD block packing/unpacking for batch writes.

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
- ../../core/cpu_features.zig
- ../core/utils.zig

## Key Entry Points in This File
- L10: fn averageBlur5(sum: i32) u8 {
- L16: fn runtimeLanes() usize {
- L27: pub fn extractDownsampleRows(
- L85: pub fn blurHorizontalRows(bloom: anytype, start_row: usize, end_row: usize) void {
- L117: pub fn blurVerticalRows(bloom: anytype, start_row: usize, end_row: usize) void {
- L149: pub fn compositeRows(dst: []u32, dst_width: usize, bloom: anytype, intensity_lut: *const [256]u8, start_row: usize, end_row: usize) void {
- L181: fn compositeBlock(comptime lanes: usize, dst: []u32, row_start: usize, x_start: usize, bloom_row: []const u32, intensity_lut: *const [256]u8) void {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
