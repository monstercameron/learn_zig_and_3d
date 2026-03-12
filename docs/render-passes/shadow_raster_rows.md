# Shadow Raster Rows

Source: /engine/src/render/passes/shadow_raster_rows.zig

## How It Should Work (Design Contract)
- Transform meshlet triangles into light space and rasterize depth for assigned row spans.
- Skip oversized/invalid meshlets to keep raster cost bounded.
- Preserve depth test consistency across job stripes.
- Keep hot raster logic isolated from pass orchestration.

## How It Does Work Today (Code Walkthrough)
- rasterizeShadowMeshRange() iterates meshlets and local primitives.
- Projects vertices using precomputed light basis vectors from shadow map state.
- Calls shadow_raster_kernel.rasterizeTriangleRows() for depth write/update.
- Early exits when shadow target is inactive.

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
- ../kernels/shadow_raster_kernel.zig

## Key Entry Points in This File
- L11: pub fn rasterizeShadowMeshRange(mesh: anytype, shadow: anytype, start_row: usize, end_row: usize, light_dir_world: math.Vec3, max_shadow_meshlet_vertices: usize) void {

## Current Gaps / Risks to Watch
- No explicit TODO/FIXME markers in this module; behavior risks are primarily integration/config related.

## Validation Checklist (When Editing This Pass)
- Verify dispatch boundaries (start_row/end_row or range bounds) do not overrun target buffers.
- Confirm scalar and SIMD paths produce equivalent visual output for representative scenes.
- Check frame-time impact in profiler/HUD after changes to hot loops or sample counts.
- Confirm pass ordering/enable flags in renderer pipeline still match intended graph behavior.
