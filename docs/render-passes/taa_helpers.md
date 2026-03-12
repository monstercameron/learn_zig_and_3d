# TAA Helpers

Source: /engine/src/render/passes/taa_helpers.zig

## How It Should Work (Design Contract)
- Provide all reusable TAA primitives for history sampling, validation, and blending.
- Keep history clamp rules conservative to suppress ghosting/disocclusion artifacts.
- Support both scalar and SIMD blending paths with consistent output semantics.
- Isolate surface-tag logic so TAA pass can reason about identity stability.

## How It Does Work Today (Code Walkthrough)
- Implements bilinear/nearest history sampling for color/depth/normal/tag channels.
- Provides neighborhood and surface-aware history clamping functions.
- Implements scalar and SIMD temporal color blend routines.
- Exports luma and surface-tag utility functions consumed by TAA pass.

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
- ../core/tile_renderer.zig

## Key Entry Points in This File
- L19: fn clampByte(value: i32) u8 {
- L24: pub fn sampleHistoryColor(history: []const u32, width: usize, height: usize, screen: math.Vec2) ?[3]f32 {
- L64: pub fn sampleHistoryColorNearest(history: []const u32, width: usize, height: usize, screen: math.Vec2) ?[3]f32 {
- L77: pub fn sampleHistoryNearest(history_pixels: []const u32, history_depth: []const f32, history_surface_tags: []const u64, width: usize, height: usize, screen: math.Vec2) ?HistoryNearestSample {
- L101: pub fn packHistoryNormal(normal: math.Vec3) u32 {
- L110: fn unpackHistoryNormal(packed_normal: u32) math.Vec3 {
- L118: pub fn sampleHistoryNormalNearest(history_normals: []const u32, width: usize, height: usize, screen: math.Vec2) ?math.Vec3 {
- L127: pub fn surfaceTagForHandle(handle: TileRenderer.SurfaceHandle) u64 {
- L134: pub fn surfaceTagMeshletId(tag: u64) u32 {
- L140: pub fn clampHistoryToSurfaceNeighborhood(
- L197: pub fn surfaceHistoryEdgeFactor(surface_handles: []const TileRenderer.SurfaceHandle, width: usize, height: usize, x: usize, y: usize) f32 {
- L221: pub fn clampHistoryToNeighborhood(pixels: []const u32, width: usize, height: usize, x: usize, y: usize, history_color: [3]f32) [3]f32 {
- L255: pub fn blendTemporalColor(current_pixel: u32, history_color: [3]f32, history_weight: f32) u32 {
- L268: fn blendTemporalColorBatchSimd(comptime lanes: usize, current_pixels: *const [lanes]u32, history_colors: *const [lanes][3]f32, history_weights: *const [lanes]f32) [lanes]u32 {
- L307: pub fn blendTemporalColorBatch(current_pixels: []const u32, history_colors: []const [3]f32, history_weights: []const f32, output: []u32) void {
- L335: pub fn pixelLuma(pixel: u32) f32 {
- L344: pub fn colorLuma(color: [3]f32) f32 {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
