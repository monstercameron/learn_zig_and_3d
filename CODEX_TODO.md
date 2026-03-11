# Codex Migration TODOs

Status date: 2026-03-11
Owner: Codex + repo maintainer

## Phase 1 - Hygiene Baseline
- [x] Ignore generated `artifacts/` output in `.gitignore`.
- [x] Add root `LICENSE` file.
- [x] Add/update README section that distinguishes `assets/` (runtime) vs `artifacts/` (generated).
- [x] Decide whether any files inside `artifacts/` should be versioned examples and relocate those to `docs/assets/images/` if needed.
  Decision: keep `artifacts/` as non-versioned generated output; only curated docs visuals belong in `docs/assets/images/`.

## Phase 2 - Resource Namespace Cleanup
- [x] Rename `resources/` to `assets/`.
- [x] Update all source/runtime references from `resources/...` to `assets/...`.
- [x] Update docs and onboarding commands that mention `assets/`.
- [x] Build + run smoke test after path migration.

## Phase 3 - App/Engine Split (No Behavior Change)
- [x] Create `app/src/` and move app entrypoint/bootstrap files there.
- [x] Create `engine/src/` and move reusable renderer/engine modules there.
- [x] Update `build.zig` module roots and imports to preserve current executable output.
- [x] Run `zig build check` and `zig build validate`.

## Phase 4 - Internal Engine Domains
- [x] Organize `engine/src` into initial internal domains (`platform/`, `render/`) with compatibility shims.
- [x] Move rendering kernels under `engine/src/render/kernels/`.
- [x] Keep migrations incremental and compile green after each move.

## Phase 5 - Tests and CI
- [x] Add top-level `tests/` with `unit/`, `integration/`, `perf-smoke/`.
- [x] Add at least one executable test target in root `build.zig`.
- [x] Add CI check step for `zig build check` + selected tests.

## Rules of Engagement
- Keep each move small and compile-verified.
- Prefer path aliases/import wrappers temporarily to reduce breakage.
- Do not mix structural moves with unrelated feature work.

## Phase 6 - Render Pass + Kernel Isolation (Approval-Gated)
Goal: every standalone renderer feature becomes its own render pass module and its own dedicated kernel file.

### 6.0 Architecture Guardrails
- [x] Define pass contract in `engine/src/render/pass_graph.zig`:
- [x] `RenderPassId`, explicit pass ordering, dependency metadata, enabled predicate.
- [x] Shared `FrameContext` for color/depth/normals/history/scratch surfaces.
- [x] Shared `PassDispatch` helpers for stripe jobs.
- [x] Add `engine/src/render/passes/README.md` with naming/ownership rules.
- [ ] Approval gate: review pass interface and dependency order before first extraction.

### 6.1 Core Scene Passes
- [x] Extract `SkyboxPass` to `engine/src/render/passes/skybox_pass.zig`.
- [x] Extract row kernel to `engine/src/render/kernels/skybox_kernel.zig`.
- [ ] Wire through pass graph and remove inline skybox code from renderer.
- [ ] Add parity check screenshot for skybox-enabled frame.

- [x] Extract `ShadowMapPass` to `engine/src/render/passes/shadow_map_pass.zig`.
- [x] Extract triangle raster/shadow sampling kernels to:
- [x] `engine/src/render/kernels/shadow_raster_kernel.zig`
- [x] `engine/src/render/kernels/shadow_sample_kernel.zig`
- [ ] Keep current depth bias behavior identical.
- [ ] Add before/after shadow-depth debug image parity check.

- [x] Extract `ShadowResolvePass` to `engine/src/render/passes/shadow_resolve_pass.zig`.
- [x] Extract resolve kernel to `engine/src/render/kernels/shadow_resolve_kernel.zig`.
- [ ] Keep darkness scaling and lit/occluded blending identical.

- [x] Extract `HybridShadowPass` to `engine/src/render/passes/hybrid_shadow_pass.zig`.
- [x] Extract cache/grid/candidate kernels to:
- [x] `engine/src/render/kernels/hybrid_shadow_cache_kernel.zig`
- [x] `engine/src/render/kernels/hybrid_shadow_candidate_kernel.zig`
- [x] `engine/src/render/kernels/hybrid_shadow_resolve_kernel.zig`
- [ ] Preserve debug stepping semantics and overlay counters.
- [ ] Approval gate: review perf impact and memory growth after hybrid extraction.

### 6.2 Lighting/Post Feature Passes
- [x] Extract `SSAOPass` to `engine/src/render/passes/ssao_pass.zig`.
- [x] Extract AO kernels to:
- [x] `engine/src/render/kernels/ssao_sample_kernel.zig`
- [x] `engine/src/render/kernels/ssao_blur_kernel.zig`
- [ ] Preserve current downsample and blur threshold config behavior.

- [x] Extract `SSGIPass` to `engine/src/render/passes/ssgi_pass.zig`.
- [x] Extract GI kernel to `engine/src/render/kernels/ssgi_kernel.zig`.
- [ ] Keep sample count/radius/intensity semantics unchanged.

- [x] Extract `SSRPass` to `engine/src/render/passes/ssr_pass.zig`.
- [x] Extract reflection kernel to `engine/src/render/kernels/ssr_kernel.zig`.
- [ ] Keep max steps/thickness/intensity behavior unchanged.

- [x] Extract `DepthFogPass` to `engine/src/render/passes/depth_fog_pass.zig`.
- [x] Extract fog kernel to `engine/src/render/kernels/depth_fog_kernel.zig`.
- [ ] Preserve near/far/strength/color parameter mapping.

- [x] Extract `TAAPass` to `engine/src/render/passes/taa_pass.zig`.
- [x] Extract temporal resolve kernel to `engine/src/render/kernels/taa_kernel.zig`.
- [ ] Keep current jitter sequence/history rejection behavior.

- [x] Extract `MotionBlurPass` to `engine/src/render/passes/motion_blur_pass.zig`.
- [x] Extract blur kernel to `engine/src/render/kernels/motion_blur_kernel.zig`.
- [ ] Preserve dependency on TAA previous view state.

- [x] Extract `GodRaysPass` to `engine/src/render/passes/god_rays_pass.zig`.
- [x] Extract radial sample kernel to `engine/src/render/kernels/god_rays_kernel.zig`.
- [ ] Preserve sample/decay/density/weight/exposure behavior.

- [x] Extract `BloomPass` orchestrator to `engine/src/render/passes/bloom_pass.zig`.
- [x] Split bloom kernels into:
- [x] `engine/src/render/kernels/bloom_extract_kernel.zig` (existing, keep)
- [x] `engine/src/render/kernels/bloom_blur_h_kernel.zig` (new)
- [x] `engine/src/render/kernels/bloom_blur_v_kernel.zig` (new)
- [x] `engine/src/render/kernels/bloom_composite_kernel.zig` (existing, keep)
- [ ] Preserve threshold curve and intensity LUT behavior.

- [x] Extract `LensFlarePass` to `engine/src/render/passes/lens_flare_pass.zig`.
- [x] Extract flare kernel to `engine/src/render/kernels/lens_flare_kernel.zig`.

- [x] Extract `DepthOfFieldPass` to `engine/src/render/passes/depth_of_field_pass.zig`.
- [x] Extract DoF kernel to `engine/src/render/kernels/depth_of_field_kernel.zig` (existing, consolidate ownership).
- [ ] Preserve autofocus smoothing and focal params.

- [x] Extract `ChromaticAberrationPass` to `engine/src/render/passes/chromatic_aberration_pass.zig`.
- [x] Extract chromatic kernel to `engine/src/render/kernels/chromatic_aberration_kernel.zig`.

- [x] Extract `FilmGrainVignettePass` to `engine/src/render/passes/film_grain_vignette_pass.zig`.
- [x] Split kernels to:
- [x] `engine/src/render/kernels/film_grain_kernel.zig`
- [x] `engine/src/render/kernels/vignette_kernel.zig`
- [ ] Preserve current combined visual output.

- [x] Extract `ColorGradePass` to `engine/src/render/passes/color_grade_pass.zig`.
- [x] Extract grading kernel to `engine/src/render/kernels/color_grade_kernel.zig`.
- [ ] Preserve current blockbuster profile LUT behavior.

### 6.3 Render Pipeline Wiring
- [x] Create pass registration in `engine/src/render/pass_registry.zig`.
- [x] Move `applyPostProcessingPasses` ordering into pass graph execution.
- [x] Keep current config flags as pass enable predicates.
- [x] Ensure pass timings are emitted per pass module (same labels as today).
- [ ] Approval gate: confirm final pass order with you before removing old call path.

### 6.4 Incremental Safety and Tests
- [ ] For each extracted pass:
- [x] Run `zig build check`, `zig build test`, `zig build validate`.
- [ ] Capture one parity screenshot in `artifacts/` with matching camera seed.
- [ ] Capture pass timing delta (old vs new) and note regressions >5%.
- [x] Add/extend targeted unit tests where deterministic kernels are feasible.

### 6.5 Definition of Done
- [ ] `engine/src/render/renderer.zig` only orchestrates frame state + pass graph execution.
- [ ] Every standalone feature has:
- [x] one pass file under `engine/src/render/passes/`
- [x] one owned kernel file under `engine/src/render/kernels/`
- [ ] All builds green (`check`, `test`, `validate`) and visual parity validated.

## Phase 7 - Render Layout Hardening (Renderer Top-Level + Core/Pipeline Split)
- [x] Create `engine/src/render/core/` and move shared render primitives there:
- [x] `lighting.zig`, `mesh.zig`, `scanline.zig`, `tile_renderer.zig`, `shadow_system.zig`, `binning_stage.zig`, `mesh_work_types.zig`, `utils.zig`, `frame_context.zig`.
- [x] Create `engine/src/render/core/meshlets/` and move:
- [x] `meshlet_builder.zig`, `meshlet_cache.zig`.
- [x] Create `engine/src/render/pipeline/` and move:
- [x] `pass_dispatch.zig`, `pass_graph.zig`, `pass_registry.zig`.
- [x] Update all imports across `engine/src`, `app/src`, and tests after moves.
- [x] Keep `engine/src/render/renderer.zig` as top-level orchestrator.
- [x] Keep `engine/src/render/passes/` and `engine/src/render/kernels/` as feature execution layers.

## Phase 8 - Lighting As Pass + Shared Core Lighting
- [x] Introduce `engine/src/render/passes/lighting_pass.zig` as pass-owned lighting execution entrypoint.
- [x] Keep pass-agnostic BRDF/color/intensity helpers in `engine/src/render/core/lighting.zig`.
- [x] Rewire renderer/tile paths to invoke lighting through pass module boundaries.
- [x] Ensure shadow + lighting remain strictly pass-owned behaviors.
- [x] Verify no direct heavy pass logic remains embedded in renderer for lighting/shadow.
- [x] Run and pass `zig build check`, `zig build test`, `zig build validate`.

## Phase 9 - Final Renderer De-Embedding Sweep
- [x] Remove embedded color-grade kernel path from `renderer.zig`:
- [x] Migrate or delete `applyBlockbusterGradeRange` and keep color-grade execution pass-owned (`passes/color_grade_pass.zig` + `kernels/color_grade_kernel.zig`).
- [x] Move bloom LUT builders out of renderer:
- [x] `buildBloomThresholdCurve` and `buildBloomIntensityLut` should live in bloom pass/module-owned location.
- [ ] Reduce renderer callback adapters where feasible:
- [ ] `renderAmbientOcclusionRows`, `blurAmbientOcclusionHorizontalRows`, `blurAmbientOcclusionVerticalRows`, `compositeAmbientOcclusionRows`, `rasterizeShadowMeshRange`, `tryApplyTemporalAAMeshletBatch`.
- [ ] Keep only required typed bridge shims in renderer where Zig callback typing requires concrete signatures.
- [x] Validate with `zig build check`, `zig build test`, `zig build validate`.

## Phase 10 - Kernel SIMD/Vectorization Rollout
Goal: add explicit SIMD/vectorized code paths in hottest kernels while preserving output parity.

### 10.1 Baseline and Guardrails
- [x] Add per-kernel SIMD status table (scalar vs vectorized) to track rollout.
- [ ] Add CPU backend lane policy (scalar/sse2/avx2/avx512/neon) per kernel.
- [ ] Keep scalar fallback path in each optimized kernel for correctness and portability.
- [ ] Validate parity after each kernel update (`check/test/validate`).

### 10.2 Wave 1 (High ROI)
- [x] `color_grade_kernel.zig`
- [x] Add vectorized batch path for per-pixel color curve + tone shaping.
- [x] Runtime lane selection by backend (`1/8/16/32` or platform-appropriate subset).
- [x] Keep identical clamp/saturation math.

- [ ] `taa_kernel.zig`
- [ ] Vectorize neighborhood/history blend sections where contiguous memory access exists.
- [ ] Preserve rejection thresholds and history validity behavior.

- [ ] `ssr_kernel.zig`
- [ ] Vectorize ray-step accumulation where branch divergence is manageable.
- [ ] Keep hit thickness/max-step behavior identical.

- [ ] `ssao_blur_kernel.zig` and `ssao_sample_kernel.zig`
- [ ] Vectorize blur taps and sample accumulation batches.
- [ ] Preserve radius/bias/threshold semantics.
- [x] `ssao_blur_kernel.zig` and `ssao_sample_kernel.zig`
- [x] Vectorize blur taps and sample accumulation batches. (implemented in `passes/ssao_rows.zig` batched lane blocks + SIMD composite path)
- [x] Preserve radius/bias/threshold semantics.

- [x] `shadow_resolve_kernel.zig`
- [x] Vectorize shadow factor application over contiguous pixel spans.
- [x] Preserve depth checks and darkness scaling.

### 10.3 Wave 2 (Medium ROI)
- [x] `bloom_blur_h_kernel.zig`, `bloom_blur_v_kernel.zig`, `bloom_composite_kernel.zig`
- [x] `motion_blur_kernel.zig`
- [x] `depth_fog_kernel.zig`
- [x] `god_rays_kernel.zig`
- [x] `lens_flare_kernel.zig`

### 10.4 Wave 3 (Targeted/Complex)
- [ ] `meshlet_primitive_kernel.zig` (batch triangle shading/packing hotspots).
- [ ] `shadow_raster_kernel.zig` and `shadow_sample_kernel.zig` (careful with branch-heavy code).
- [ ] `ssgi_kernel.zig` (sample accumulation if memory access regularity allows).

### 10.5 Completion Criteria
- [x] At least 6 production kernels with explicit SIMD paths.
- [ ] No behavior regressions in visual output and config semantics.
- [x] `zig build check`, `zig build test`, `zig build validate` all pass.

### 10.6 SIMD Status Table (Current)
- [x] `color_grade_kernel.zig` -> `vectorized` (`runtime lanes: 1/8/16/32`)
- [x] `shadow_resolve_kernel.zig` -> `vectorized` (`runtime lanes: 1/8/16/32`, batched factor apply)
- [x] `depth_fog_kernel.zig` -> `vectorized` (`runtime lanes: 1/8/16/32`, batched fog blend)
- [x] `film_grain_vignette_pass.zig` -> `vectorized` (`runtime lanes: 1/8/16/32`, fused vignette+grain batch write path)
- [x] `motion_blur_pass.zig` -> `cpu-optimized scalar` (`incremental sample t, reduced conversion/reload overhead`)
- [x] `god_rays_kernel.zig` -> `hybrid` (`scalar ray march per lane + SIMD final composite/write, runtime lanes 1/8/16/32`)
- [x] `lens_flare_kernel.zig` -> `hybrid` (`scalar thresholded sample accumulation per lane + SIMD final composite/write, runtime lanes 1/8/16/32`)
- [x] `taa_kernel.zig` -> `vectorized` (`SIMD channel blend in resolve path + batch resolve helper`)
- [x] `ssr_kernel.zig` -> `cpu-optimized scalar` (`hoisted invariants, reduced float conversions, distance recurrence in ray march`)
- [x] `ssao_sample_kernel.zig` -> `cpu-optimized scalar` (`row-base hoists, reduced per-pixel division in AO sampling path via ssao_rows backend`)
- [x] `ssao_blur_kernel.zig` -> `hybrid` (`batched lane blur blocks with scalar depth-threshold taps via ssao_rows backend`)
- [x] `bloom_blur_h_kernel.zig` -> `cpu-optimized scalar` (`rolling window blur in bloom_rows backend`)
- [x] `bloom_blur_v_kernel.zig` -> `cpu-optimized scalar` (`rolling window blur in bloom_rows backend`)
- [x] `bloom_composite_kernel.zig` -> `vectorized` (`Float4 SIMD composite math per pixel`)
- [x] `motion_blur_kernel.zig` -> `cpu-optimized scalar` (`hoisted scales/bounds, incremental t, mul by inverse instead of divide`)
