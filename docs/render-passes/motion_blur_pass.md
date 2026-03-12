# Motion Blur Pass

Source: /engine/src/render/passes/motion_blur_pass.zig

## How It Should Work (Design Contract)
- Blur along motion vectors derived from current/previous camera transforms and depth.
- Reject invalid depth samples and near-plane artifacts to avoid streak corruption.
- Bound sample count and intensity for predictable frame cost.
- Preserve detail where motion is small while smoothing fast motion.

## How It Does Work Today (Code Walkthrough)
- runRows() reconstructs world position and accumulates along motion direction.
- validSceneCameraSample()/projection helpers guard invalid or near-plane samples.
- Uses POST_MOTION_BLUR_SAMPLES and POST_MOTION_BLUR_INTENSITY config.
- runPipeline() splits into row jobs and executes via job system when available.

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
- ../pipeline/pass_dispatch.zig

## Key Entry Points in This File
- L14: fn validSceneCameraSample(camera_pos: math.Vec3) bool {
- L21: fn cameraToWorldPosition(
- L41: fn projectCameraPositionFloat(position: math.Vec3, projection: anytype) math.Vec2 {
- L57: pub fn runRows(
- L144: pub fn runPipeline(self: anytype, current_view: anytype, height: usize, width: usize, comptime noop_job_fn: fn (*anyopaque) void) void {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
