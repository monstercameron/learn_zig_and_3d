# Adaptive Shadow Tile Pass

Source: /engine/src/render/passes/adaptive_shadow_tile_pass.zig

## How It Should Work (Design Contract)
- Classify screen-space blocks quickly into lit/shadowed/mixed using conservative sampling.
- Avoid full per-pixel ray cost by refining only ambiguous blocks.
- Use coarse/edge caches to preserve temporal stability and reduce repeated ray queries.
- Apply exact sampling only where block-level confidence is insufficient.

## How It Does Work Today (Code Walkthrough)
- Entry point run() bounds work to valid receiver extents and recurses via processBlock().
- classifyBlock() probes corners/center and switches to exact resolve when classification is mixed.
- sampleShadowCache*() lazily fills quantized coarse/edge caches and blends coverage.
- isPointShadowed() performs meshlet candidate filtering then packet triangle tests in 8-lane chunks.

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
- ../../core/app_config.zig
- ../kernels/hybrid_shadow_resolve_kernel.zig
- ../core/utils.zig

## Key Entry Points in This File
- L28: pub fn run(ctx: anytype) void {
- L36: fn processBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32, depth: u32) void {
- L61: fn classifyBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32) BlockClassification {
- L104: fn evaluateShadowPoint(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
- L120: fn evaluateShadowCellAtScale(ctx: anytype, cache_x: usize, cache_y: usize, shadow_scale: i32) ShadowSample {
- L159: fn sampleShadowCache(ctx: anytype, cache: []u8, cache_width: usize, cache_height: usize, shadow_scale: i32, screen_x: i32, screen_y: i32) ShadowSample {
- L221: fn sampleShadowCacheNearest(ctx: anytype, cache: []u8, cache_width: usize, cache_height: usize, shadow_scale: i32, screen_x: i32, screen_y: i32) ShadowSample {
- L244: fn sampleShadowCoarse(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
- L257: fn sampleShadowRefined(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
- L291: fn sampleShadow(ctx: anytype, screen_x: i32, screen_y: i32) ShadowSample {
- L297: fn isPointShadowed(ctx: anytype, camera_pos: math.Vec3, light_sample: anytype) bool {
- L365: fn resolveBlockExact(ctx: anytype, x: i32, y: i32, width: i32, height: i32) void {
- L408: fn darkenBlock(ctx: anytype, x: i32, y: i32, width: i32, height: i32) void {
- L418: fn darkenPixelSpan(pixels: []u32, start_index: usize, end_index: usize, scale: f32) void {
- L426: fn rayIntersectsSphere(origin: math.Vec3, direction: math.Vec3, center: math.Vec3, radius: f32) bool {
- L437: fn rayIntersectsTriangle8(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
