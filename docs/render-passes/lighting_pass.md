# Lighting Pass Interface

Source: /engine/src/render/passes/lighting_pass.zig

## How It Should Work (Design Contract)
- Centralize core lighting intensity/shading helpers used by render stages.
- Provide stable scalar interfaces independent of backend implementation details.
- Keep lighting math reusable across deferred/forward-like paths.
- Preserve deterministic mapping from brightness to packed color output.

## How It Does Work Today (Code Walkthrough)
- Exposes wrappers: computeIntensity(), applyIntensity(), shadeSolid().
- Delegates actual math to render/core/lighting.zig.
- Acts as a pass-facing API adapter rather than a pipeline scheduler.
- No job dispatch or frame state ownership in this module.

## Inputs, Outputs, and Side Effects
- Inputs are passed explicitly through function arguments/job contexts (buffers, camera/projection state, config values, and scratch arenas).
- Outputs are written to destination buffers/scratch owned by the renderer; no file/network IO occurs in these pass modules.
- Side effects are limited to buffer mutation and pass timing/stat counters when invoked by renderer orchestration.

## Execution Model and Performance Notes
- Most full-screen work is striped by rows and dispatched through the job system when multiple stripes are available.
- Hot loops favor cache-friendly contiguous access and SIMD/vectorized batch operations when runtime ISA support allows.
- Scalar fallback paths remain present for tails, unsupported ISA widths, and edge-case control flow.

## Imported Dependencies
- ../core/lighting.zig

## Key Entry Points in This File
- L13: pub fn computeIntensity(brightness: f32) f32 {
- L19: pub fn applyIntensity(color: u32, intensity: f32) u32 {
- L25: pub fn shadeSolid(brightness: f32) u32 {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
