# Codex Migration TODOs

Status date: 2026-03-11
Owner: Codex + repo maintainer

## Phase 1 - Hygiene Baseline
- [x] Ignore generated `artifacts/` output in `.gitignore`.
- [x] Add root `LICENSE` file.
- [x] Add/update README section that distinguishes `assets/` (runtime) vs `artifacts/` (generated).
- [ ] Decide whether any files inside `artifacts/` should be versioned examples and relocate those to `docs/assets/images/` if needed.

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
- [ ] Define pass contract in `engine/src/render/pass_graph.zig`:
- [ ] `RenderPassId`, explicit pass ordering, dependency metadata, enabled predicate.
- [ ] Shared `FrameContext` for color/depth/normals/history/scratch surfaces.
- [ ] Shared `PassDispatch` helpers for stripe jobs.
- [ ] Add `engine/src/render/passes/README.md` with naming/ownership rules.
- [ ] Approval gate: review pass interface and dependency order before first extraction.

### 6.1 Core Scene Passes
- [ ] Extract `SkyboxPass` to `engine/src/render/passes/skybox_pass.zig`.
- [ ] Extract row kernel to `engine/src/render/kernels/skybox_kernel.zig`.
- [ ] Wire through pass graph and remove inline skybox code from renderer.
- [ ] Add parity check screenshot for skybox-enabled frame.

- [ ] Extract `ShadowMapPass` to `engine/src/render/passes/shadow_map_pass.zig`.
- [ ] Extract triangle raster/shadow sampling kernels to:
- [ ] `engine/src/render/kernels/shadow_raster_kernel.zig`
- [ ] `engine/src/render/kernels/shadow_sample_kernel.zig`
- [ ] Keep current depth bias behavior identical.
- [ ] Add before/after shadow-depth debug image parity check.

- [ ] Extract `ShadowResolvePass` to `engine/src/render/passes/shadow_resolve_pass.zig`.
- [ ] Extract resolve kernel to `engine/src/render/kernels/shadow_resolve_kernel.zig`.
- [ ] Keep darkness scaling and lit/occluded blending identical.

- [ ] Extract `HybridShadowPass` to `engine/src/render/passes/hybrid_shadow_pass.zig`.
- [ ] Extract cache/grid/candidate kernels to:
- [ ] `engine/src/render/kernels/hybrid_shadow_cache_kernel.zig`
- [ ] `engine/src/render/kernels/hybrid_shadow_candidate_kernel.zig`
- [ ] `engine/src/render/kernels/hybrid_shadow_resolve_kernel.zig`
- [ ] Preserve debug stepping semantics and overlay counters.
- [ ] Approval gate: review perf impact and memory growth after hybrid extraction.

### 6.2 Lighting/Post Feature Passes
- [ ] Extract `SSAOPass` to `engine/src/render/passes/ssao_pass.zig`.
- [ ] Extract AO kernels to:
- [ ] `engine/src/render/kernels/ssao_sample_kernel.zig`
- [ ] `engine/src/render/kernels/ssao_blur_kernel.zig`
- [ ] Preserve current downsample and blur threshold config behavior.

- [ ] Extract `SSGIPass` to `engine/src/render/passes/ssgi_pass.zig`.
- [ ] Extract GI kernel to `engine/src/render/kernels/ssgi_kernel.zig`.
- [ ] Keep sample count/radius/intensity semantics unchanged.

- [ ] Extract `SSRPass` to `engine/src/render/passes/ssr_pass.zig`.
- [ ] Extract reflection kernel to `engine/src/render/kernels/ssr_kernel.zig`.
- [ ] Keep max steps/thickness/intensity behavior unchanged.

- [ ] Extract `DepthFogPass` to `engine/src/render/passes/depth_fog_pass.zig`.
- [ ] Extract fog kernel to `engine/src/render/kernels/depth_fog_kernel.zig`.
- [ ] Preserve near/far/strength/color parameter mapping.

- [ ] Extract `TAAPass` to `engine/src/render/passes/taa_pass.zig`.
- [ ] Extract temporal resolve kernel to `engine/src/render/kernels/taa_kernel.zig`.
- [ ] Keep current jitter sequence/history rejection behavior.

- [ ] Extract `MotionBlurPass` to `engine/src/render/passes/motion_blur_pass.zig`.
- [ ] Extract blur kernel to `engine/src/render/kernels/motion_blur_kernel.zig`.
- [ ] Preserve dependency on TAA previous view state.

- [ ] Extract `GodRaysPass` to `engine/src/render/passes/god_rays_pass.zig`.
- [ ] Extract radial sample kernel to `engine/src/render/kernels/god_rays_kernel.zig`.
- [ ] Preserve sample/decay/density/weight/exposure behavior.

- [ ] Extract `BloomPass` orchestrator to `engine/src/render/passes/bloom_pass.zig`.
- [ ] Split bloom kernels into:
- [ ] `engine/src/render/kernels/bloom_extract_kernel.zig` (existing, keep)
- [ ] `engine/src/render/kernels/bloom_blur_h_kernel.zig` (new)
- [ ] `engine/src/render/kernels/bloom_blur_v_kernel.zig` (new)
- [ ] `engine/src/render/kernels/bloom_composite_kernel.zig` (existing, keep)
- [ ] Preserve threshold curve and intensity LUT behavior.

- [ ] Extract `LensFlarePass` to `engine/src/render/passes/lens_flare_pass.zig`.
- [ ] Extract flare kernel to `engine/src/render/kernels/lens_flare_kernel.zig`.

- [ ] Extract `DepthOfFieldPass` to `engine/src/render/passes/depth_of_field_pass.zig`.
- [ ] Extract DoF kernel to `engine/src/render/kernels/depth_of_field_kernel.zig` (existing, consolidate ownership).
- [ ] Preserve autofocus smoothing and focal params.

- [ ] Extract `ChromaticAberrationPass` to `engine/src/render/passes/chromatic_aberration_pass.zig`.
- [ ] Extract chromatic kernel to `engine/src/render/kernels/chromatic_aberration_kernel.zig`.

- [ ] Extract `FilmGrainVignettePass` to `engine/src/render/passes/film_grain_vignette_pass.zig`.
- [ ] Split kernels to:
- [ ] `engine/src/render/kernels/film_grain_kernel.zig`
- [ ] `engine/src/render/kernels/vignette_kernel.zig`
- [ ] Preserve current combined visual output.

- [ ] Extract `ColorGradePass` to `engine/src/render/passes/color_grade_pass.zig`.
- [ ] Extract grading kernel to `engine/src/render/kernels/color_grade_kernel.zig`.
- [ ] Preserve current blockbuster profile LUT behavior.

### 6.3 Render Pipeline Wiring
- [ ] Create pass registration in `engine/src/render/pass_registry.zig`.
- [ ] Move `applyPostProcessingPasses` ordering into pass graph execution.
- [ ] Keep current config flags as pass enable predicates.
- [ ] Ensure pass timings are emitted per pass module (same labels as today).
- [ ] Approval gate: confirm final pass order with you before removing old call path.

### 6.4 Incremental Safety and Tests
- [ ] For each extracted pass:
- [ ] Run `zig build check`, `zig build test`, `zig build validate`.
- [ ] Capture one parity screenshot in `artifacts/` with matching camera seed.
- [ ] Capture pass timing delta (old vs new) and note regressions >5%.
- [ ] Add/extend targeted unit tests where deterministic kernels are feasible.

### 6.5 Definition of Done
- [ ] `engine/src/render/renderer.zig` only orchestrates frame state + pass graph execution.
- [ ] Every standalone feature has:
- [ ] one pass file under `engine/src/render/passes/`
- [ ] one owned kernel file under `engine/src/render/kernels/`
- [ ] All builds green (`check`, `test`, `validate`) and visual parity validated.
