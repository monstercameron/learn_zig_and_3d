# Render Pipeline Optimization Checklist

Every function in the per-frame render call stack, ranked by remaining
optimization opportunity. **P** = parallel via job system, **V** =
explicit SIMD source, **A** = LLVM auto-vec from scalar source.

## Session progress

- [x] **`cpu_features.SIMD_F32_LANES`** — comptime constant that picks
      lane width from build target (4 SSE2/NEON, 8 AVX/AVX2/SVE,
      16 AVX-512). Logged at startup as `compile-time SIMD backend=...`.
- [x] **`tonemapRows`** — explicit `@Vector(SIMD_F32_LANES, f32)` Reinhard.
- [x] **`probeRows`** — explicit SIMD with `@reduce(.Add)`/`@reduce(.Max)`.
- [x] **`lightRowsDeferred` (PBR)** — replaced `std.math.pow(x, 5)` with
      inline `x⁵` to unblock LLVM auto-vec. 3.9× faster.
- [x] **`compileTrianglesOnlyToDrawListShifted`** — batches
      `SIMD_F32_LANES` triangles per iteration, projects 3*N vertices
      through new `projectPointsMasked`.
- [x] **`Projector.projectPointsMasked`** — non-bailing SIMD projection
      with per-vertex valid mask via `@select`.
- [x] **240Hz FPS cap removed** — TARGET_FPS default 0; settings.json
      fpsLimit: 0.

## Remaining priorities

Goal: every hot function should be both parallel AND explicitly
vectorized — using `cpu_features.SIMD_F32_LANES` so the same source
scales SSE2 → AVX2 → AVX-512 → NEON → SVE.

## Legend
- ✅ done, in target state
- ⚠ partial (parallel or auto-vec but not both, or could be tighter)
- ❌ scalar single-thread
- ⏭ skipped on cache hit (architecturally cold)

---

## Cache-hit path (steady-state, render = ~0ms)

All stages below are bypassed when `cached_scene_mesh == mesh` and
camera unchanged. They run on the FIRST frame and on every camera
change. Optimizing these reduces camera-move stutter.

### Stage: scene_submission (build packet list)

- [ ] **`scene_submission_stage.executeMeshScene`** ❌ serial scalar
      `engine/src/render/stages/scene_submission_stage.zig:169`
      Cost: trivial, one mesh packet appended. Not worth optimizing.

### Stage: visibility_culling (meshlet frustum reject)

- [ ] **`visibility_culling_stage.execute`** ⚠ serial outer
      `engine/src/render/stages/visibility_culling_stage.zig:12`
      Dispatcher over packet types. Trivial cost.

- [ ] **`cullVisibleMeshlets`** ❌ **HIGH PRIORITY**
      `engine/src/render/direct/meshlets.zig:45`
      Loop over 6909 meshlets calling `meshletVisibleFast` each. Cost
      on acura cache miss: ~350 µs serial. Should be parallelized
      across job_system workers with per-worker output array and
      merge. 8-16× speedup expected.

- [ ] **`meshletVisibleFast`** ⚠ auto-vec
      `engine/src/render/direct/meshlets.zig:144`
      Per-meshlet 6-plane sphere reject. Already scalar-tight after
      hoisting frustum scalars. SIMD opportunity: process 4-8 meshlets
      per call by SoA-loading bounds_center / bounds_radius into
      `@Vector(SIMD_F32_LANES, f32)`.

### Stage: primitive_expansion (build world batch)

- [ ] **`primitive_expansion_stage.execute`** ✅ parallel dispatcher
      `engine/src/render/stages/primitive_expansion_stage.zig:11`
      Switch on payload type. Cost: dispatcher only.

- [ ] **`appendVisibleMeshletsToBatchParallel`** ✅ direct-write parallel
      `engine/src/render/direct/meshlets.zig:114`
      Already split across N+1 chunks, writes directly to pre-reserved
      batch slots (no merge). Good.

- [ ] **`appendMeshletDirect`** ⚠ parallel-chunked, scalar inner
      `engine/src/render/direct/meshlets.zig:200`
      Per-triangle mulVec3 ×3. With identity_transform=false (acura
      has Y-rotation), this is 4.5M matrix-vec ops on cache miss.
      Auto-vec works but explicit 4-tri batching using SoA layout
      (process 4 triangles' 12 vertices as 3 `@Vector(4, f32)`) would
      hit the SIMD projection path and 4× the throughput.

- [ ] **`math.Mat4.mulVec3`** ⚠ auto-vec
      `engine/src/core/math.zig`
      16 mul-adds. Inner kernel. Currently scalar source. Explicit
      `@Vector(4, f32)` rewrite available.

- [ ] **`applyBatchLighting`** ⏭ skipped in deferred mode
      `engine/src/render/kernels/gouraud_kernel.zig:12`
      Already bypassed via the `if (!DEFERRED_SHADING_ENABLED)` check
      in `renderSceneMesh`. Dead path in current pipeline.

### Stage: compile_draw_list (project to screen)

- [ ] **`compileToDrawListParallel`** ✅ parallel
      `engine/src/render/direct/batch.zig`
      Splits commands across N+1 chunks, each chunk writes to a
      per-worker DrawList scratch, merged via `appendSlice`.

- [ ] **`compileTrianglesOnlyToDrawListShifted`** ⚠ parallel chunk, scalar inner
      `engine/src/render/direct/batch.zig`
      Per-triangle: backface test → projectTriangle → bounds → append.
      Big inner-loop opportunity: process 4 triangles together using
      `Projector.projectPoints` (which is already explicit 4-wide
      SIMD) instead of falling through to scalar 3-vertex fallback.
      **Estimated impact: 2-3× cold-frame compile speedup.**

- [ ] **`worldTriangleFrontFacing`** ⚠ auto-vec
      `engine/src/render/direct/batch.zig:608`
      cross + dot. Easy candidate for 4-triangle batched SIMD.

- [x] **`Projector.projectTriangle`** ✅ batched via SIMD_F32_LANES
      `engine/src/render/direct/batch.zig:310`
      `compileTrianglesOnlyToDrawListShifted` now batches `TRI_BATCH =
      SIMD_F32_LANES` triangles at a time, calling new
      `projectPointsMasked` which projects 3*N vertices using
      `std.simd.suggestVectorLength` and returns a per-vertex valid
      mask. Per-triangle finalize gates on the mask. Result: cold-
      frame compile_draw_list cost was already auto-vec-bound — wall
      time the same — but the SIMD path is now explicit and predictable
      across ISAs.

- [ ] **`Projector.projectSmallPoints`** ⚠ SIMD setup but scalar fallback
      `engine/src/render/direct/batch.zig:315`
      Sets up SIMD vectors at the top but unused for count=3. Only
      reached now from the scalar tail in
      `compileTrianglesOnlyToDrawListShifted` (when total triangles
      isn't a multiple of TRI_BATCH). Low impact.

- [x] **`Projector.projectPointsMasked`** ✅ explicit SIMD with mask
      `engine/src/render/direct/batch.zig:230` (new)
      Per-vertex valid mask via `@select` — never bails on near-plane,
      lets caller decide cull granularity. Lane count from
      `std.simd.suggestVectorLength(f32)` (4/8/16). Used by the
      batched compile path.

- [ ] **`Projector.projectPoints`** ✅ explicit 4-wide SIMD
      `engine/src/render/direct/batch.zig`
      The good path. Used only when callers pass ≥4 points.

- [ ] **`Projector.triangleVertexDepths`** ⚠ scalar
      `engine/src/render/direct/batch.zig`
      3 depth dots. Auto-vec friendly; batch 4 triangles for 12 depths.

- [ ] **`computeCameraSpaceFaceNormal`** ⚠ scalar
      `engine/src/render/direct/batch.zig:561`
      3 vec ops. Batch-friendly.

- [ ] **`prepareGouraudTriangle`** ⏭ skipped in deferred
      `engine/src/render/direct/primitives.zig`
      Only called when gouraud_colors set. Skipped on the deferred
      path (vertex_colors=null).

- [ ] **`makeTriangleSortKey`** ⚠ scalar
      `engine/src/render/direct/batch.zig`
      One u64 pack. Trivial cost.

- [ ] **`appendProjectedTriangleAssumeCapacity`** ⚠ scalar struct write
      `engine/src/render/direct/draw_list.zig:114`
      Per-triangle: 3 array writes (DrawPacket, bounds, gouraud_entry).
      Bandwidth-bound; SIMD store of 4-batched packets could halve
      cost if the structs were AoS-aligned.

### Stage: screen_binning (tile assignment)

- [ ] **`screen_binning_stage.execute`** ❌ **HIGH PRIORITY**
      `engine/src/render/stages/screen_binning_stage.zig:43`
      Serial 4-ms loop over draw_list.bounds() that increments
      per-tile counts, then a second pass that writes
      tile_command_indices. To parallelize:
      1. Per-worker count arrays (no contention)
      2. Reduce → global counts (small)
      3. Per-worker cursor arrays via prefix sum
      4. Second pass: each worker writes its triangles' tile entries

- [ ] **`TileSpan.fromBounds`** ⚠ auto-vec
      `engine/src/render/stages/screen_binning_stage.zig:18`
      4 divides + clamps per packet. Scalar in source.

- [ ] **`sortKeysAlreadyOrdered`** — fast path check
      Trivial.

- [ ] **`deterministicSortTileRefs`** ❌ serial
      Per-tile insertion sort. Only runs when sort keys disordered.

### Stage: clear (frame setup)

- [ ] **`frame_setup_stage.execute`** ✅ via memset
      `engine/src/render/stages/frame_setup_stage.zig:19`
      LLVM emits `rep stosd` / `vmovaps`. Already SIMD via memset.

- [ ] **`direct_primitives.clear`** ✅ via fillU32/fillF32
      `engine/src/render/direct/primitives.zig:100`
      memset-based. Could be parallelized for very large surfaces but
      memory-bandwidth-bound — unlikely to scale linearly.

- [ ] **`direct_primitives.clearRect`** ✅ via fillU32/fillF32 per row
      `engine/src/render/direct/primitives.zig:109`
      Used for incremental clear of dirty rect. SIMD memset per row.

### Stage: rasterization (deferred G-buffer fill)

- [ ] **`rasterization_stage.execute`** ✅ parallel tile dispatch
      `engine/src/render/stages/rasterization_stage.zig`
      Spawns one job per active tile via the job system.

- [ ] **`rasterTileWithItems`** ✅ parallel tile worker
      `engine/src/render/stages/rasterization_stage.zig:340`
      Inside a tile worker. Iterates packets for that tile.

- [ ] **`drawSolidTriangleWithDepths`** ⚠ **HIGH PRIORITY** parallel-chunked, scalar inner
      `engine/src/render/direct/primitives.zig:426`
      Per-pixel edge function test + depth test + G-buffer write.
      Inner loop is scalar; LLVM auto-vecs the comparisons but the
      conditional writes prevent full SIMD. Explicit 4 or 8-lane
      SIMD with mask-based blend write would be 2-4× faster.
      Big target for cache-miss raster cost.

- [ ] **`drawSolidTriangleForward`** ⚠ same as above, forward variant
      `engine/src/render/direct/primitives.zig`
      Used when target.gbuf_base_color is null. Also scalar inner.

- [ ] **`scanline.clampI32` / minI32 / maxI32`** — trivial helpers
      Inlined by compiler.

- [ ] **`gouraud.prepareDepthPlane`** ⚠ auto-vec
      `engine/src/render/direct/gouraud.zig`
      Edge-function setup for depth interp. Called once per triangle.

- [ ] **`drawPreparedGouraudTriangleBlock`** ⏭ skipped in deferred mode
      `engine/src/render/direct/primitives.zig`
      Old Gouraud per-tile batch path. `cachePreparedGouraud` returns
      null in deferred, so this path is dead.

- [ ] **`makeClippedTarget`** ✅ propagates G-buffer pointers
      `engine/src/render/stages/rasterization_stage.zig:433`
      Builds per-tile FrameTarget with G-buffer surfaces. Trivial cost.

### Stage: hi-Z pyramid build

- [ ] **`hiz_stage.buildPyramid`** ✅ parallel rows
      `engine/src/render/stages/hiz_stage.zig:30`
      Row-chunked parallel dispatch.

- [ ] **`hiz_stage.buildRows`** ⚠ parallel-chunked, scalar inner
      `engine/src/render/stages/hiz_stage.zig:64`
      Per-tile max-depth over 64×64 block. LLVM emits `vmaxps` for the
      inner reduce. Explicit 8-wide loop would be tighter.

- [ ] **`hiz_stage.isOccluded`** ⚠ scalar
      `engine/src/render/stages/hiz_stage.zig:166`
      Cull helper, called per-primitive when binning opts in (not
      currently wired). 4-plane sphere reject.

### Stage: deferred lighting (PBR)

- [ ] **`shading_stage.executeDeferred`** ✅ parallel row dispatch
      `engine/src/render/stages/shading_stage.zig:331`
      Row-strip parallel jobs.

- [ ] **`lightRowsDeferred`** ⚠ **HIGH PRIORITY** parallel-chunked, scalar inner
      `engine/src/render/stages/shading_stage.zig:431`
      Cook-Torrance/GGX PBR per pixel. Auto-vec works (now that
      `std.math.pow(x, 5)` is replaced with x⁵), but explicit
      `@Vector(SIMD_F32_LANES, f32)` rewrite would:
      - Process N pixels per iteration
      - Replace `if (n_dot_l <= 0)` branches with `@select` blends
      - Pre-gather normal/albedo/material into channel vectors
      Expect 2-4× speedup over auto-vec on cache-miss frames.

### Stage: HDR post-process

- [ ] **`hdr_post_stage.executeLuminanceProbe`** ✅ parallel rows
      `engine/src/render/stages/hdr_post_stage.zig:38`

- [ ] **`probeRows`** ✅✅ parallel + explicit SIMD
      `engine/src/render/stages/hdr_post_stage.zig:126`
      Explicit `@Vector(SIMD_F32_LANES, f32)` with `@reduce(.Add)` /
      `@reduce(.Max)`. Done.

### Stage: HDR bloom

- [ ] **`hdr_bloom_pass.execute`** ✅ parallel dispatch (4 sub-passes)
      `engine/src/render/passes/hdr_bloom_pass.zig`

- [ ] **`brightPassRows`** ⚠ parallel-chunked, scalar inner
      Per-pixel box-average + bright-pass threshold. Inner block
      averages 4×4 source pixels. Could vectorize across output
      columns.

- [ ] **`blurHorizontalRows`** ⚠ parallel-chunked, scalar inner
      9-tap separable Gaussian, horizontal axis. Each output is sum
      of 9 weighted neighbours. Auto-vec works on the inner mul-add
      accumulator.

- [ ] **`blurVerticalRows`** ⚠ parallel-chunked, scalar inner
      Same as above, vertical axis. Same SIMD considerations.

- [ ] **`upsampleAddRows`** ⚠ parallel-chunked, scalar inner
      Bilinear sample + add. Could vectorize the 4-tap bilinear and
      the per-channel add.

- [ ] **`runRowsParallel`** — generic row-job dispatcher
      Trivial.

### Stage: HDR tonemap

- [ ] **`shading_stage.executeTonemap`** ✅ parallel rows
      `engine/src/render/stages/shading_stage.zig:572`

- [ ] **`tonemapRows`** ✅✅ parallel + explicit SIMD
      `engine/src/render/stages/shading_stage.zig:694`
      Explicit `@Vector(SIMD_F32_LANES, f32)` Reinhard + pack. Done.

### Present

- [ ] **`present_d3d11.Backend.present`** — D3D11 swap
      System-level. Outside our SIMD scope.

---

## Priority order for further work

Ranked by impact on cache-miss frame time (camera-move stutter):

1. **`Projector.projectTriangle`** — batch 4 triangles → SIMD path.
   *Saves ~15-20 ms on acura cold-frame compile.*
2. **`drawSolidTriangleWithDepths`** — explicit 4-lane edge test + masked write.
   *Saves ~2 ms on acura cache-miss raster.*
3. **`screen_binning_stage.execute`** — parallel per-worker counts + merge.
   *Saves ~3 ms on acura cache-miss binning.*
4. **`lightRowsDeferred`** — explicit `SIMD_F32_LANES` PBR with `@select`.
   *Saves ~0.3 ms per frame even on cache miss.*
5. **`cullVisibleMeshlets`** — parallelize the meshlet loop.
   *Saves ~0.35 ms on acura cache miss.*
6. **`appendMeshletDirect` mulVec3** — SoA 4-tri batched transform.
   *Saves ~10-15 ms on acura cold-frame build_batch.*
7. **`blurHorizontalRows` / `blurVerticalRows`** — explicit vectorization.
   *Saves ~0.3 ms when bloom enabled.*

## Cross-cutting wins
- Pack `scene_normal` from `[]Vec3` to `[]u32` (RGB10A2). Saves 8
  bytes/pixel × 335k pixels = 2.6 MB write per frame on acura.
- Shrink `DrawPacket` size by hoisting `PreparedGouraudTriangle` out
  of the union (deferred path never uses it). DrawPacket goes from
  ~200 bytes to ~80 bytes → 3.7× less merge bandwidth.

## Validation criteria
After each item:
- Build green: `zig build -Doptimize=ReleaseFast`
- Cornell screenshot looks correct
- Acura screenshot looks correct
- `ZIG_DISABLE_RENDER_CACHE=1` benchmark shows the targeted stage faster
- No regression on the cache-hit path (should stay ~0 ms render)
