# Shadow Resolve Pass

Source: /engine/src/render/passes/shadow_resolve_pass.zig

## How It Should Work (Design Contract)
- Sample shadow map visibility per pixel and attenuate final lit color.
- Use SIMD batching where possible, but preserve scalar correctness for tails.
- Operate over row stripes to parallelize full-screen shadow application.
- Respect depth/near-plane validity and shadow strength configuration.

## How It Does Work Today (Code Walkthrough)
- JobContext() creates typed job wrappers for row execution.
- runRows() delegates to shadow_resolve_kernel.runRows() with config/shadow inputs.
- Kernel reconstructs world position and applies occlusion-scaled darkening.
- Supports both direct and dispatched paths depending on stripe count/job system.

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
- ../kernels/shadow_resolve_kernel.zig

## Key Entry Points in This File
- L11: pub fn JobContext(comptime ConfigType: type, comptime ShadowMapType: type) type {
- L54: pub fn runRows(

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
