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
- [x] Wire through pass graph and remove inline skybox code from renderer.
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

- [x] `taa_kernel.zig`
- [x] Vectorize neighborhood/history blend sections where contiguous memory access exists.
- [ ] Preserve rejection thresholds and history validity behavior.

- [ ] `ssr_kernel.zig`
- [ ] Vectorize ray-step accumulation where branch divergence is manageable.
- [ ] Keep hit thickness/max-step behavior identical.

- [x] `ssao_blur_kernel.zig` and `ssao_sample_kernel.zig`
- [x] Vectorize blur taps and sample accumulation batches.
- [x] Preserve radius/bias/threshold semantics.
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

## Phase 11 - Composition Layer Optimization (CPU / Cache / IPC)
- [x] Add pass metadata for composition phase + output target in pass graph.
- [x] Add phase-aware execution in pass registry with phase boundary callback support.
- [x] Build per-frame `CompositionPlan` masks in renderer (`scene`, `geometry_post`, `lighting_scatter`, `final_color`).
- [x] Execute post passes in explicit phase barriers and record phase timing buckets.
- [x] Align motion-blur enable scheduling with runtime history availability.
- [x] Replace full-frame copy-back with buffer swaps for scratch-output passes where safe:
- [x] `ssgi`, `ssr`, `motion_blur`, `god_rays`, `lens_flare`, `chromatic_aberration`.

## Phase 12 - Frame Pacing Hardening
Goal: make frame cadence explicit and stable instead of mixing software caps, OS yields, and compositor pacing.

- [x] Define one pacing authority per mode:
- [x] software-paced when `vsync=false` and `fps_limit>0`
- [x] compositor-paced when `vsync=true` and `fps_limit=0`
- [x] reject or clearly disable mixed pacing paths that fight each other
- [x] Remove unconditional `Sleep(0)` from the main loop after frame present.
- [x] Keep deadline pacing based on absolute frame deadlines, not frame-end relative sleeps.
- [x] Improve Windows wait behavior for software pacing:
- [x] prefer precise sleep or timer wait for coarse phase
- [x] retain short yield/spin tail only near the deadline
- [x] Add separate telemetry for:
- [x] CPU frame time
- [x] software pacing wait time
- [x] present/compositor wait time
- [x] total frame interval
- [x] Update HUD text/graph so pacing mode is visible during profiling.
- [x] Validate with `zig build check`, `zig build`, and a compositor-mode TTL smoke run; software-paced path is compile-validated in this change set.
- [x] Validate runtime launch in `ReleaseFast` after composition swap changes.

## Phase 12 - Arbitrary Lights + Arbitrary Shadows (CPU-First Execution Model)
Goal: evolve from fixed-size light/shadow assumptions into a data-driven CPU renderer pipeline tuned for high IPC, SIMD/vector lanes, and large-cache locality.

### 12.0 Profiling Contract and Guardrails
- [x] Add mandatory per-frame counters: active lights, shadow-casting lights, shadow queries, meshlet-ray tests, and rejected light tiles.
- [x] Add single-frame profile labels that separate shadow-map build vs shadow resolve vs meshlet-ray shadowing without double-counting.
  Status: `shadow_map_build_total`, `shadow_map_resolve_total`, `meshlet_shadows` labels + per-light `shadow_light {id} build/resolve` capture.
- [x] Add per-pass cache/throughput notes in profiling docs (L1/L2 miss-sensitive loops, branch-heavy loops, SIMD-hot loops).
- [x] Define default perf targets for 720p and 1080p in `docs/technical-overview.md` (frame time budget + shadow budget).

### 12.1 Dynamic Light Capacity (Foundational)
- [x] Remove fixed two-light assumption from renderer allocation path by adding runtime light-capacity API.
- [x] Set renderer light capacity from selected scene light count before scene runtime starts.
- [x] Add safety floor/ceiling config (`LIGHT_COUNT_MIN`, `LIGHT_COUNT_MAX`) to protect CPU budget.
- [x] Add runtime log line with actual allocated light count and shadow map memory footprint.
- [x] Validate parity on existing scenes (`gun_physics`, `cornell`) after dynamic capacity wiring.

### 12.2 Light Data Layout for CPU Efficiency
- [ ] Introduce light SoA buffer set for hot shading/shadow loops (`dir_x[]`, `dir_y[]`, `dir_z[]`, `distance[]`, `color_r/g/b[]`, flags).
  Status: partial - landed contiguous `dir_x/dir_y/dir_z/dir_cam_x/dir_cam_y/dir_cam_z/distance/shadow_mode` arrays and migrated hot culling/shadow loops to SoA reads.
- [ ] Keep AoS `LightInfo` only as authoring/control structure; generate SoA views once per frame or on light changes.
- [ ] Ensure SoA arrays are contiguous and cache-line friendly; avoid pointer-chasing from per-pixel loops.
- [ ] Add SIMD lane-width aware light batch iterators (`1/4/8/16/32`) keyed off detected backend.
- [ ] Keep scalar fallback path for deterministic debugging and portability.

### 12.3 Unified Shadow Interface
- [x] Add `ShadowMode` per light (`none`, `shadow_map`, `meshlet_ray`) with explicit per-light enable toggles.
  Status: `LightInfo.shadow_mode` + renderer API toggle + scene `lightShadowMode` parsing + mode-aware shadow-map build/resolve and meshlet tile dispatch landed.
- [ ] Route shading through one interface (`sampleShadow(light_id, surface_sample)`) regardless of backend.
- [x] Decouple pass naming from fixed light indexes; emit stable labels with light id + mode.
- [ ] Add configuration policy for per-light shadow resolution and update cadence.
  Status: partial - scene-configurable per-light cadence (`lightShadowUpdateInterval`) and per-light map size (`lightShadowMapSize`) landed/validated; per-frame shadow budget governor is now integrated (`shadowBudgetPercent` + budget-skip reuse path + profile counters), remaining is auto-scaling rules.

### 12.4 Tiled/Clustered Light Culling
- [ ] Build per-tile compact light lists before shading (screen-space bounds + depth bounds).
  Status: partial - landed contiguous per-tile light ranges/indices and frame profile counters; now performs tile-level light rejection using camera-space normal bounds with SIMD broad-phase tests (directional-light path), with local-list-driven shadow dispatch.
- [x] Add SIMD broad-phase overlap tests for tile/light rejection.
- [ ] Store tile-light lists in contiguous compressed ranges to maximize prefetch efficiency.
- [x] Add hard cap and overflow diagnostics for tile-light list growth.
- [ ] Validate shading loops only iterate local tile lists (not global light array).

### 12.5 Meshlet-Native Shadow Accelerator
- [ ] Build/maintain meshlet acceleration data in contiguous arrays (BVH/TLAS-friendly, branch-light traversal).
- [ ] Add packetized shadow ray traversal (SIMD packet width based on backend) with coherent ray sorting.
- [ ] Add early-out rules: backface, depth-threshold, tile frustum, and conservative meshlet bounds.
- [ ] Add temporal reuse for stable light/camera conditions (skip unchanged shadow query regions).
- [ ] Measure instruction mix and branch divergence changes after each traversal optimization.

### 12.6 Shadow Work Scheduling (CPU Throughput)
- [ ] Batch shadow work by `(shadow mode, light id, tile chunk)` for cache locality and predictable worker utilization.
- [ ] Tune chunk sizes for IPC and L2 reuse; avoid over-fragmentation that increases scheduling overhead.
- [ ] Keep worker queues lock-light with preallocated job arrays for steady frame times.
- [ ] Add shadow budget governor: gracefully degrade sample counts/resolution when frame budget is exceeded.
  Status: partial - per-frame shadow-map rebuild budget now skips/reuses active maps when over budget (`POST_SHADOW_BUDGET_PERCENT`, `shadow_budget_skipped`), adaptive shadow-map resolution scaling is active (budget downscale/upscale with target-size recovery), and adaptive rebuild cadence scaling is active (dynamic interval multiplier under sustained pressure); adaptive sample-count control is still pending.

### 12.7 Visual/Behavioral Correctness
- [ ] Add deterministic parity captures for core scenes across scalar and SIMD paths.
- [ ] Add regression checks for acne/peter-panning, temporal flicker, and shadow pop-in under moving lights.
- [x] Validate mixed shadow modes in one frame (`shadow_map` and `meshlet_ray` concurrently).
- [x] Confirm existing pass toggles (`render_passes.json` + `engine.ini`) still map correctly to runtime behavior.
  Status: added `tools/validate-pass-toggles.ps1`, validating `engine.ini` precedence over `render_passes.json` and runtime shadow-pass activation/deactivation on `mixed_shadows_static`.
- [x] Add automated regression fixture for mixed shadow modes (avoid relying on manual run).
  Status: added `tools/validate-mixed-shadows.ps1` with log-pattern assertions for mixed-mode frame profile output.

### 12.8 Rollout Sequence
- [x] Start implementation with dynamic light-capacity support and scene-driven sizing.
- [x] Next: fix shadow timing attribution so per-light metrics are trustworthy.
- [x] Next: introduce SoA light views and migrate one hot shading loop to SoA+SIMD.
- [ ] Next: land tile-light culling and verify frame-time scaling with increasing light counts.
  Status: in progress - directional-light tile rejection and local shadow dispatch wiring landed; remaining work is screen/depth broad-phase + scaling sweeps.
- [ ] Next: integrate unified shadow mode dispatch with per-light backends.

## Phase 13 - Hierarchical Scene Runtime + Streaming Residency + Script Host (Approval-Gated)
Goal: add a scene runtime that supports parent/child hierarchy, dependency-aware on-demand loading/offloading, item-attached scripts with events, and a safe bridge into the existing renderer.

### 13.0 Architecture Gates
- [ ] Approval gate: confirm the three-layer model before code lands:
- [ ] `SceneGraph` for parent/child transform hierarchy.
- [ ] `DependencyGraph` for non-transform dependencies.
- [ ] `ResidencyManager` for octree-driven load/offload policy.
- [ ] Approval gate: confirm scripts are Zig-native host modules first, not a separate embedded language.
- [ ] Approval gate: confirm renderer remains a consumer of extracted frame data during first rollout.

### 13.1 Scene Identity and Handles
- [x] Add `EntityId` with generation/versioning to avoid stale references after destroy/reuse.
- [x] Add `AssetId` / `AssetHandle` with generation/versioning for safe resource reuse.
- [x] Add stable `SceneNodeId` or equivalent authoring/runtime mapping for debug and serialization.
- [x] Add central name/tag registry for optional lookup by authored id (`camera.main`, `light.key`, etc.).
- [x] Add validation that duplicate authored ids are rejected during scene load.

### 13.2 World Core (ECS Foundation)
- [x] Create `engine/src/scene/world.zig`.
- [x] Create typed component storage with explicit containers, not string-keyed maps.
- [x] Add core lifecycle ops: create entity, destroy entity, enable entity, disable entity.
- [x] Add deferred `Commands` buffer for structural edits during update/event processing.
- [x] Add post-frame application of deferred commands at a single safe point.
- [x] Add world-level destroy queue so runtime code can request deletion without invalidating iterators.
- [x] Add world snapshot/debug dump helpers for inspection during migration.

### 13.3 Scene Graph (Hierarchy)
- [x] Create `engine/src/scene/graph.zig`.
- [x] Add `Parent` relationship component/storage.
- [x] Add child list or first-child/next-sibling representation.
- [x] Add `LocalTransform` component.
- [x] Add `WorldTransform` cache component.
- [x] Add `HierarchyDirty` propagation flagging.
- [x] Add reparent operation with cycle rejection.
- [x] Add subtree enable/disable propagation semantics.
- [x] Add transform propagation pass ordered before physics-to-render extraction.
- [ ] Add attach-point support for child entities that inherit transforms from parent items.

### 13.4 Dependency Graph (Non-Transform DAG)
- [x] Create `engine/src/scene/dependency_graph.zig`.
- [x] Add dependency edge kinds: `asset`, `script`, `activation`, `logic`, `physics`, `render`.
- [x] Add load-time DAG validation and cycle detection.
- [x] Add topological ordering helper for activation/load/unload sequencing.
- [x] Add dependency query helpers for “why is this entity pinned/resident?”.
- [ ] Add policy for soft vs hard dependencies.
- [ ] Add failure behavior when a hard dependency fails to load.

### 13.5 Authoring Schema Evolution
- [ ] Define unified scene schema that can express:
- [x] entity id/name.
- [-] parent/children.
- [ ] components.
- [x] script attachments.
- [ ] dependency edges.
- [ ] residency hints / stream group / cell assignment overrides.
- [-] Add migration path from current `assets/configs/scenes/*.scene.json` model entries.
- [ ] Reuse or absorb useful structure from `assets/levels/default.level.json` (`children`, `scripts`).
- [ ] Add schema validation with clear diagnostics for invalid ids, cycles, and missing assets.
- [x] Add scene loader tests for parent-child + dependency + script declarations.

### 13.6 Asset Registry and Resource Lifetime
- [x] Create `engine/src/scene/asset_registry.zig`.
- [ ] Register mesh assets as distinct resources instead of merging everything up front.
- [ ] Register texture assets with stable handles.
- [ ] Register HDRI/environment assets with stable handles.
- [x] Register script modules with stable handles.
- [x] Add resource states: `unloaded`, `queued`, `loading`, `resident`, `failed`, `evict_pending`, `offloading`.
- [x] Add generation counters to all handles so stale references fail safely.
- [x] Add ref-count or residency-request tracking separate from transient per-frame pins.
- [ ] Add central unload queue processed only at safe points.

### 13.7 Octree Residency Manager (Spatial Load/Offload)
- [x] Create `engine/src/scene/residency_manager.zig`.
- [x] Create `engine/src/scene/octree.zig` or equivalent loose-octree module.
- [ ] Define world bounds / root cell policy.
- [x] Add support for static entity registration into octree leaves.
- [x] Add support for dynamic entity reassignment or loose-octree membership.
- [x] Add camera-driven residency request computation.
- [ ] Add preload radius / active radius / eviction hysteresis settings.
- [x] Add cell states: `cold`, `prefetch`, `requested`, `resident`, `evict_pending`.
- [ ] Add per-cell debug counters: entity count, asset count, pending loads, pin count.
- [ ] Add rules for cross-cell parent/child attachments.
- [ ] Add rules for cross-cell dependency pins so required assets/scripts are not evicted prematurely.
- [ ] Add safe offload delay to avoid thrashing when camera hovers near boundaries.

### 13.8 Loader / Offloader Execution
- [ ] Create async/staged load tasks on top of existing job system.
- [ ] Add staged mesh load pipeline: file read -> decode -> upload/register -> resident transition.
- [ ] Add staged texture load pipeline with same state transitions.
- [ ] Add staged script module load/reload pipeline.
- [ ] Add unload pipeline: unbind -> mark evict pending -> wait for pins -> destroy -> bump generation.
- [ ] Add cancellation behavior when camera movement makes queued loads obsolete.
- [ ] Add retry/backoff policy for transient load failures.
- [ ] Add loading-overlay integration for long-running scene or cell residency operations.
- [ ] Add explicit “safe point” integration where completed loads/offloads become visible to the world.

### 13.9 Pinning and Safety Model
- [x] Add per-phase pins for render extraction, script dispatch, and physics sync.
- [x] Add per-phase pins for render extraction, script dispatch, and physics sync.
- [x] Prevent unload while any pin is active.
- [x] Add temporary frame pins for resources touched by current extraction/update phase.
- [ ] Add `will_offload` / `did_offload` notifications for dependent systems.
- [ ] Add stale-handle diagnostics in debug builds.
- [ ] Add policy for unresolved handles returned to scripts (`null object`, error event, or deferred retry).

### 13.10 Component Set for First Rollout
- [x] Add `TransformLocal`.
- [x] Add `TransformWorld`.
- [x] Add `MeshRef` / `Renderable`.
- [x] Add `MaterialRef` / `TextureSlots`.
- [x] Add `Camera`.
- [x] Add `Light` with current shadow/glow parameters.
- [x] Add `PhysicsBody` / motion-type metadata.
- [x] Add `Selectable` / gizmo metadata.
- [x] Add `ScriptComponent`.
- [x] Add `Streamable` / residency policy metadata.
- [x] Add `ActivationState` or enabled-mask component.

### 13.11 Script Host and Event Model
- [x] Create `engine/src/scene/script_host.zig`.
- [x] Define first-pass Zig-native script ABI.
- [x] Add script instance creation/destruction lifecycle.
- [x] Add per-entity script attachment with authored bindings.
- [-] Add event set:
- [x] `OnAttach`, `OnDetach`.
- [x] `OnEnable`, `OnDisable`.
- [x] `OnBeginPlay`, `OnEndPlay`.
- [x] `OnUpdate`, `OnFixedUpdate`, `OnLateUpdate`.
- [x] `OnParentChanged`, `OnTransformChanged`.
- [x] `OnAssetReady`, `OnAssetLost`.
- [x] `OnZoneEnter`, `OnZoneExit`.
- [ ] `OnCollisionEnter`, `OnCollisionStay`, `OnCollisionExit`.
- [x] Require scripts to mutate world state through deferred commands only.
- [x] Disallow scripts from persisting raw component pointers across callbacks.
- [x] Add host-side version checks for script module ABI compatibility.

### 13.12 Script Reload / Persistence Hooks
- [ ] Reuse ideas from `experiments/hotreload_demo` for module hot-reload.
- [ ] Add script module `create` / `destroy` / `on_event` entrypoints.
- [ ] Add optional script state serialize/deserialize hooks for reload/offload.
- [ ] Add graceful fallback when module reload fails (keep prior instance or disable script explicitly).
- [ ] Add event ordering guarantees around reload (`will_reload`, `did_reload`, `reload_failed`).

### 13.13 World Phase Scheduler
- [x] Define explicit frame phases:
- [x] input.
- [x] residency decisions.
- [x] job completion integration.
- [x] script events.
- [x] fixed-step physics.
- [x] transform propagation.
- [x] render extraction.
- [x] present.
- [x] safe offload / deferred destruction.
- [x] Add invariant checks so no forbidden mutations occur during extraction or traversal.
- [ ] Move existing main-loop special cases into phase-owned systems incrementally.

### 13.14 Physics Integration Refactor
- [x] Stop treating physics runtime structs as separate scene-side ownership islands.
- [x] Update physics to write entity transform/body state, not raw mesh ownership state.
- [x] Add script/selection-safe pause rules for drag interactions.
- [ ] Add collision event emission into script event queue.
- [x] Add handling for physics entities that become non-resident or offloaded.

### 13.15 Render Extraction Bridge
- [x] Create `engine/src/scene/render_extraction.zig`.
- [x] Extract active camera from world to renderer state.
- [x] Extract visible/resident lights from world to renderer state.
- [x] Extract visible/resident renderables into a frame snapshot.
- [x] Preserve current renderer API shape during first migration step.
- [x] Add mapping from extracted render item back to `EntityId` for picking/gizmo interactions.
- [x] Replace current scene-item binding identity path with entity-backed selection ids.
- [x] Gate extraction to resident cells only.

### 13.16 Selection, Gizmos, and Editor-Style Interactions
- [x] Rewire scene-item selection to target `EntityId` rather than merged-mesh instance index.
- [ ] Keep outline/gizmo logic working when items stream in/out.
- [x] Add behavior for selected entity offload attempts (pin selected entity, or clear selection explicitly).
- [x] Add parent/child manipulation policy (move child local transform vs move root). 
- [x] Add event emission for selection changes into script/event system.

### 13.17 Streaming Diagnostics and Tooling
- [ ] Add octree/cell debug overlay.
- [ ] Add resident/prefetch/evict-pending counters to debug HUD.
- [x] Add dependency graph inspection dump for selected entity.
- [x] Add asset pin-count / residency-state diagnostics.
- [ ] Add script instance/event trace logging in debug builds.
- [ ] Add focused validation scene that exercises load, offload, dependency pins, and script callbacks.

### 13.18 Failure and Recovery Policy
- [ ] Define behavior when a required asset fails to load.
- [ ] Define behavior when an optional asset fails to load.
- [ ] Define behavior when a script module fails to load or reload.
- [ ] Define behavior when dependency cycle validation fails.
- [ ] Define behavior when offload is requested but denied due to active pins.
- [ ] Surface all of the above through logs and optional on-screen debug overlay.

### 13.19 Incremental Migration Strategy
- [x] Stage 1: land `EntityId`, world core, and scene graph without changing renderer behavior.
- [x] Stage 2: move scene loading to entity/component creation while keeping current renderer bridge.
- [x] Stage 3: add asset registry and stable handles.
- [x] Stage 4: add octree residency manager with no script integration yet.
- [x] Stage 5: add script host and event dispatch.
- [x] Stage 6: move physics and selection to entity-backed state.
- [ ] Stage 7: remove remaining special-case runtime structs from `main.zig`.

### 13.20 Validation and Approval Gates
- [ ] Approval gate: review scene schema before loader migration starts.
- [ ] Approval gate: review first-pass script ABI before `script_host.zig` lands.
- [ ] Approval gate: review octree residency policy before automatic eviction is enabled.
- [ ] Approval gate: confirm selection/gizmo behavior for streamed entities.
- [ ] For each migration stage, run `zig build check` and targeted runtime smoke validation.
- [ ] Add at least one end-to-end streaming fixture scene before enabling offload by default.

## Phase 14 - Kernel SIMD Readiness + CPU Bottleneck Remediation (Granular)
Goal: remove remaining scalar bottlenecks in hot render paths, improve SIMD utilization, and cut scheduling/memory overhead while preserving image parity.

### 14.0 Baseline and Safety Gates
- [x] Capture a locked baseline frame profile for `mixed_shadows_static` (fixed resolution, fixed camera, fixed frame id).
- [x] Export baseline `profile.json` and store summarized top zones (`renderTileJob`, `meshletShadowTile`, `meshletShadowTrace`, `meshletShadowApply`).
- [ ] Record baseline counters: active tiles, shadow queries, meshlet-ray tests, total shadow jobs.
- [x] Add a per-change perf log template (`before_us`, `after_us`, `delta_pct`, scene, config).
- [ ] Add a parity capture checklist: screenshot pair + max per-channel error + pass/fail.
- [ ] Require one `Debug` and one `ReleaseFast` run for each hotspot optimization ticket.

### 14.1 `compute.zig` Hot Access Path Specialization
- [x] Add specialized `loadRGBA32F`/`storeRGBA32F` helpers that skip format switching in hot loops.
- [x] Add specialized `loadRGBA8`/`storeRGBA8` helpers for byte-backed post passes.
- [x] Add specialized `loadR32F`/`storeR32F` helpers for depth/luminance paths.
- [ ] Convert hottest kernels to call specialized helpers instead of generic `loadRGBA`/`storeRGBA`.
- [x] Keep generic helpers only as fallback for non-hot code paths.
- [x] Benchmark helper-only delta in a microbench (`pixels/s`, `ns/pixel`).
  Status: migrated `motion_blur_kernel.zig`, `luminance_histogram_kernel.zig`, `deferred_lighting_kernel.zig`, `depth_of_field_kernel.zig`, `tonemap_kernel.zig`, `depth_visualize_kernel.zig`, `normal_visualize_kernel.zig`, and `bloom_extract_kernel.zig`; additional hot kernels pending.

### 14.2 Compute Dispatcher Overhead Reduction
- [ ] Remove per-group `allocator.create(GroupDispatchJobContext)` in favor of preallocated context arrays.
- [ ] Remove per-group shared-memory allocations by using fixed scratch arenas per worker.
- [ ] Add a fast path that executes tiny dispatches inline without job submission.
- [ ] Add a threshold heuristic for inline path (`num_groups * group_size` based).
- [ ] Reuse parent job object across passes where safe to reduce allocation churn.
- [ ] Measure dispatcher-only overhead before/after with a no-op kernel.

### 14.3 `shadow_raster_kernel.zig` Raster Core Rewrite
- [x] Hoist `inv_area` outside pixel loops.
- [ ] Replace per-pixel `shadowEdge` recomputation with incremental edge stepping across scanlines.
- [ ] Precompute `w0/w1/w2` row start values for each y.
- [ ] Precompute edge x-step deltas and y-step deltas.
- [ ] Add a 4-wide/8-wide x block path for inside-test + depth interpolation.
- [ ] Keep scalar fallback for tail pixels and low-width triangles.
- [ ] Add deterministic parity tests for clockwise/counterclockwise triangles.
  Status: incremental edge-stepping prototype regressed microbench throughput and was rolled back; revisit with packetized block approach.

### 14.4 Shadow Sampling and Resolve
- [ ] Add a packetized `sampleOcclusionBatch` path in `shadow_sample_kernel.zig`.
- [ ] Precompute common shadow-space scales/biases per batch.
- [ ] Replace per-lane world reconstruction in `shadow_resolve_kernel.zig` with SoA batch transforms.
- [ ] Avoid invoking occlusion sampling when lane mask is empty.
- [ ] Add masked writeback to skip untouched lanes without branch-heavy scalar loops.
- [ ] Validate parity against current scalar resolve for all lane widths (`1/8/16/32`).

### 14.5 Meshlet Shadow Tile Hot Path (`renderer.zig`)
- [ ] Convert `applyMeshletShadows` pixel gather to strict SoA staging (origins/dirs/skip ids).
- [ ] Sort or bucket ray packets by coherence key (tile-local direction/depth band).
- [ ] Reduce per-ray normal/world reconstruction FLOPs via hoisted matrix rows.
- [x] Add early reject for clearly backfacing/light-opposed fragments before packet fill.
- [ ] Replace scalar occlusion apply loop with masked vectorized attenuation writeback.
- [ ] Add per-tile telemetry fields: packet_count, avg_active_lanes, occluded_ratio.
- [ ] Tune shadow chunk splitting thresholds from measured worker utilization data.

### 14.6 Meshlet Visibility and Primitive Build Kernels
- [ ] Add batch culling path in `meshlet_visibility_kernel.zig` using SoA descriptor reads.
- [ ] Move repeated basis dot products to batched vector operations.
- [ ] Add cache-friendly triangle index prefetch in `meshlet_primitive_kernel.zig`.
- [ ] Replace per-triangle branch chain with compact mask pipeline where feasible.
- [ ] Evaluate splitting primitive emission into two passes: cull pass then emit pass.
- [ ] Add benchmarks for meshlet cull and primitive build throughput independently.

### 14.7 `ssr_kernel.zig` SIMD-Ready Refactor
- [ ] Split SSR into phases: normal estimate, ray march, composite.
- [ ] Cache estimated normals into a temporary buffer to avoid recomputation in march path.
- [ ] Convert reflection setup to SoA arrays for lane-based batch marching.
- [ ] Implement fixed-iteration masked ray march loop to reduce divergence.
- [ ] Add early tile rejection for tiles with invalid camera/depth ranges.
- [ ] Vectorize final color blend/write path for hit lanes.
- [ ] Add SSR perf counters: rays_started, rays_hit, avg_steps_per_ray.
  Status: normal-estimation neighborhood fetch now reuses clamped row starts to reduce repeated pointer math in the hot path.

### 14.8 `ssgi_kernel.zig` SIMD-Ready Refactor
- [ ] Replace per-pixel PRNG init with deterministic tile-seeded random streams.
- [ ] Precompute rotated sample kernels per tile/frame instead of per pixel.
- [ ] Convert sample accumulation buffers to SoA (`accum_r/g/b`, `weight_sum`).
- [ ] Use fixed sample-count masked loops to reduce branch divergence.
- [ ] Add optional half-resolution mode gate for heavy scenes.
- [ ] Vectorize composite stage after scalar/packet sample phase.
- [ ] Add counters: valid_samples, rejected_samples, avg_weight.
  Status: normal-estimation neighborhood fetch now reuses clamped row starts to reduce repeated pointer math in the hot path.

### 14.9 SSAO Row Backend (`ssao_rows.zig`)
- [ ] Replace lane loops inside `blurHorizontalBlock` with true vector math for tap weights.
- [ ] Replace lane loops inside `blurVerticalBlock` with true vector math for tap weights.
- [ ] Add gather-lite strategy for depth threshold checks (mask then blend).
- [ ] Vectorize `sampleVisibility` call sites in composite block where address pattern allows.
- [ ] Keep scalar fallback for depth-discontinuous regions and tails.
- [ ] Verify AO blur parity against current implementation with strict diff thresholds.

### 14.10 Bloom Row Backend (`bloom_rows.zig`)
- [ ] Add vectorized horizontal blur block for contiguous pixel windows.
- [ ] Add vertical blur cache optimization via tile transpose or strip-mined working set.
- [ ] Evaluate temporary transposed bloom buffer for vertical pass locality.
- [ ] Vectorize composite LUT apply path end-to-end (load, add, clamp, pack).
- [ ] Add microbench for bloom horizontal vs vertical bandwidth.
- [ ] Validate bloom parity across thresholds/intensity presets.

### 14.11 TAA Kernel (`taa_kernel.zig`)
- [ ] Replace `resolvePixelBatch` lane loop with true pixel-lane SIMD unpack/blend/pack.
- [ ] Add SIMD path for `8/16/32` lane widths with scalar fallback.
- [ ] Add optional clipping neighborhood stage hooks for ghosting control.
- [ ] Add perf counters: history_rejected, history_accepted, blended_pixels.
- [ ] Add parity test cases for edge depths and high-contrast motion.

### 14.12 God Rays and Lens Flare (Hybrid -> More SIMD)
- [ ] Convert sample accumulation in `god_rays_kernel.zig` from per-lane scalar loops to packetized masked batches.
- [ ] Convert sample accumulation in `lens_flare_kernel.zig` from per-lane scalar loops to packetized masked batches.
- [ ] Keep current SIMD composite/write stage and extend it to masked accumulation outputs.
- [ ] Add quality guardrails to ensure no regression in halo/ghost falloff.
- [ ] Add scene-based perf captures with effect enabled and disabled.

### 14.13 Other Scalar Post Kernels
- [x] Add vectorized row paths for `chromatic_aberration_kernel.zig`.
- [ ] Add vectorized row paths for `motion_blur_kernel.zig` tail-safe batches.
- [x] Add vectorized row paths for `mipmap_kernel.zig` 2x2 gather/average.
- [x] Add vectorized row paths for `luminance_histogram_kernel.zig` luminance conversion.
- [ ] Defer low-impact kernels (`invert`, `grayscale`, `normal_visualize`) unless profiling shows impact.
  Status: SIMD block path (8-lane) now exists in `chromatic_aberration_kernel.zig` plus channel-SIMD upgrades landed for `mipmap_kernel.zig` and `luminance_histogram_kernel.zig`; current chromatic SIMD path is functionally correct but microbench-regressed and needs a faster gather strategy.

### 14.14 Data Layout and Memory Locality
- [ ] Audit hot buffers for alignment suitable for `@Vector` loads/stores.
- [ ] Add explicit alignment assertions where SIMD block casts are used.
- [ ] Expand SoA adoption in per-light/per-ray loops that still read AoS fields in hot code.
- [x] Remove avoidable pointer-chasing from per-pixel inner loops.
- [ ] Add cache-miss-focused profiling notes per optimized hotspot.
  Status: removed avoidable pointer-chasing/row-base recomputation in `depth_of_field_kernel.zig`, `ssr_kernel.zig`, `ssgi_kernel.zig`, `chromatic_aberration_kernel.zig`, and `skybox_kernel.zig`; attempted row-slice rewrite for `lens_flare_kernel.zig` regressed microbench throughput and was rolled back.

### 14.15 Verification and Regression Gates
- [ ] Add scalar-vs-SIMD parity captures for core scenes (`cornell`, `mixed_shadows_static`, `gun_physics`).
- [ ] Add deterministic test harness for lane widths (`1/8/16/32`) for each optimized kernel.
- [ ] Add tolerance policy per pass (`exact` for integer-only, `epsilon` for float blends).
- [ ] Add automated perf threshold checks for key zones in CI (non-failing report first).
- [ ] Document rollback switches for each new SIMD path.

### 14.16 Exit Criteria
- [ ] Reduce combined `meshletShadowTile + meshletShadowTrace + meshletShadowApply` frame cost by >= 25% in baseline scene.
- [ ] Reduce `renderTileJob` total by >= 15% in baseline scene.
- [ ] Land true SIMD (not lane-loop wrappers) in at least 5 currently scalar/hybrid hotspots.
- [ ] Keep image parity within agreed thresholds across all validation scenes.
- [ ] Update SIMD status table and profiling docs with final before/after data.

### 14.17 High-IPC + Cache + SIMD Follow-ups (Non-Duplicate)
- [ ] In `shadow_resolve_kernel.zig`, compact active lanes (non-zero occlusion candidates) into dense mini-packets before calling occlusion sampling; avoid scalar-per-lane gather work when masks are sparse.
- [ ] In `shadow_resolve_kernel.zig`, remove per-iteration fixed `[32]` scratch initialization in the hot loop; reuse worker-owned scratch buffers sized to active lane width to cut stack writes and improve IPC.
- [ ] In `shadow_sample_kernel.zig`, replace looped 5-tap PCF with an unrolled, branch-light path using preclamped tap coordinates and fixed weights to reduce branch pressure.
- [ ] In `shadow_sample_kernel.zig`, precompute row base + tap x offsets for center/tap neighbors so per-tap address generation does not redo multiply/add chains.
- [ ] In `ssr_kernel.zig`, replace scalar `pow`-based Fresnel with a polynomial approximation path that is vector-friendly and benchmark parity/quality impact.
- [ ] Add a dedicated microbench for `shadow_resolve` active-lane occupancy cases (`0%`, `25%`, `50%`, `100%`) and track `ns/pixel` vs lane utilization.
- [ ] Add a SIMD row path for `skybox_kernel.zig` direction reconstruction + tone/gamma stage (`8/16/32` lanes) with scalar tail fallback.
- [ ] In `skybox_kernel.zig`, add depth-mask span skipping (contiguous non-sky runs) to avoid per-pixel math on rows where most pixels are already filled.
- [ ] In `chromatic_aberration_kernel.zig`, replace current regressed SIMD gather path with a tile-local offset-table strategy and require recovery to >= scalar baseline before keeping SIMD path enabled.

## Phase 15 - CPU Hot Path Execution Backlog (IPC + SIMD + Cache)
Goal: execute a focused optimization pass on measured frame hotspots (`renderTileJob`, `meshletShadowTile`, `meshletShadowTrace`, `meshletShadowApply`) and remove key scalability bottlenecks in scheduling and memory access.

### 15.0 Hotspot Baseline Automation
- [x] Add `tools/profile-hotspots.ps1` to run a fixed-scene capture and emit top-zone totals + p50/p90/p99.
- [x] Parse `profile.json` and print per-zone imbalance metrics (`max/p50`, `p99/p50`) for tile and shadow jobs.
- [x] Persist baseline artifact set per run (`profile.json`, scene/config hash, summary markdown).
- [x] Add a "hotspot report" template in `artifacts/perf/` with before/after tables.
- [x] Require all Phase 15 tasks to include exact baseline and post-change frame id + scene id.

### 15.1 `renderTileJob` Raster IPC Cleanup
- [x] In `tile_renderer.zig`, remove redundant per-lane index bounds checks in the clipped bbox inner loop.
- [x] Split opaque vs alpha handling into separate write paths to reduce branch pressure in hot pixels.
- [x] Convert barycentric evaluation to incremental edge stepping across x/y spans.
- [x] Hoist invariant setup from pixel loops (`light_dir`, texture flags, packed constants).
- [x] Add a microbench for `rasterizeTriangleToTile` with small, medium, and full-tile triangles.
- [x] Add perf counters: triangles_rasterized, covered_pixels, depth_tests_passed, alpha_pixels.

### 15.2 Meshlet Shadow Tile Work Balancing
- [x] Replace pixel-count-only chunking with a cost model including tile triangle count and candidate density.
- [ ] Add adaptive split policy for long-running shadow chunks (mid-execution split allowed).
- [x] Add queueing support for finer-grain chunk stealability when worker_count > 4.
- [x] Add telemetry per chunk: `pixels`, `active_rays`, `trace_us`, `apply_us`.
- [x] Add imbalance guardrail: target `meshletShadowTile p99 <= 2.5x p50`.
- [ ] Re-tune default `shadow_chunk_pixels` and `shadow_min_chunk_pixels` based on telemetry.

### 15.3 Meshlet Shadow Packet Build + Apply Path
- [ ] In `renderer.zig` `applyMeshletShadows`, precompute world-space camera basis row products once per chunk.
- [ ] Build strict SoA staging for normals and camera positions before packet fill.
- [x] Add an early reject mask pass (depth invalid, backfacing, near-zero normal length) before any world transform math.
- [ ] Replace scalar occlusion darken loop with masked SIMD attenuation writes for active occluded lanes.
- [x] Add separate fast path for fully occluded packet chunks (uniform darken span).
- [x] Track packet efficiency counters: avg_active_lanes, avg_occluded_lanes, packets_skipped.
- [x] Replace per-lane occlusion scan with set-bit iteration (`ctz`/bitwalk) to cut branch work on sparse occlusion masks.
- [x] Remove redundant per-lane ray-direction stores/loads in shadow packet tracing; use `shared_dir` splats in packet intersection kernels.
- [x] Add dual-path occlusion apply strategy (`bitwalk` for sparse masks, contiguous full-span path for dense masks).

### 15.4 Adaptive Hybrid Shadow Traversal Unification
- [ ] In `adaptive_shadow_tile_pass.zig`, remove per-iteration repacking of triangle vertices from AoS mesh data.
- [ ] Add a path that reuses `shadow_system.zig` packetized triangles for candidate meshlet intersection.
- [ ] Add a candidate-meshlet packet trace API in `shadow_system.zig` for tile-local query workloads.
- [ ] Reuse cached meshlet triangle packets in adaptive shadow pass (no duplicate pack in inner loops).
- [ ] Add correctness checks for skip-self triangle behavior to avoid self-shadow artifacts.
- [ ] Benchmark adaptive shadow pass alone before/after (`candidate_ms`, `execute_ms`, `rays/test`).

### 15.5 Job System Throughput and Wait Strategy
- [ ] Replace mutex-heavy deque operations (`push/pop/steal`) with a lock-free or low-lock design.
- [x] Add worker wake signaling (semaphore/event) to avoid `yield`-only idle loops.
- [x] Add "help while waiting" parent-job behavior so waiting threads execute pending work.
- [x] Remove renderer-side manual polling loops where parent-job wait is sufficient.
- [ ] Add scheduler perf counters: steals, failed steals, queue contention, idle-wait time.
- [ ] Add stress test with many tiny jobs to validate throughput scaling across core counts.

### 15.6 Mesh Work Build + Binning Dataflow
- [ ] Avoid post-job triangle compaction copy where possible by computing final packed offsets up front.
- [ ] Add optional two-pass meshlet emit mode (count pass then write pass) for deterministic contiguous output.
- [ ] Optimize `MeshletContribution` lookup hashing in hot insert path (fewer probes/re-hashes).
- [ ] Add cache-friendly layout for contribution entries to reduce pointer chasing during tile population.
- [ ] Add perf counters for mesh work generation: cull_jobs_us, emit_jobs_us, compaction_us, binning_us.
- [ ] Validate no regressions in triangle/meshlet accounting invariants after dataflow changes.

### 15.7 Composite + Tonemap Vectorization
- [ ] Add SIMD row kernel for `packColorTonemapped` usage in `compositeTileToScreen`.
- [ ] Provide specialized composite variants for attachment combinations (color-only vs color+depth+gbuffer).
- [ ] Minimize optional-attachment branches inside pixel loops by selecting function pointers up front.
- [ ] Evaluate SoA tile-local color/depth/normal staging for write-combine friendly screen writes.
- [ ] Add composite bandwidth benchmark (`GB/s`, `ns/pixel`) with 720p and 1080p targets.
- [ ] Validate tonemap parity tolerance after SIMD conversion.

### 15.8 Texture Bilinear Sampling Cache Behavior
- [ ] In `texture.zig`, replace lane-by-lane bilinear gather loop with a cache-aware block sampler.
- [ ] Evaluate tiled/swizzled texture storage for better locality on bilinear quad fetches.
- [ ] Add an AVX2/AVX512 gather-assisted path behind CPU feature checks where beneficial.
- [ ] Add prefetch hints for predictable row-neighbor loads in large texture sampling batches.
- [x] Add microbench cases for random UVs vs coherent UVs to quantify cache behavior.
- [ ] Gate SIMD bilinear path by measured speedup; fallback to scalar if regressed.

### 15.9 Hybrid Shadow Cache Lifetime Strategy
- [ ] Replace full-cache clear (`0xFF`) per pass with generation-stamped validity.
- [ ] Add partial invalidation by active tile bounds and changed caster bounds.
- [ ] Add cache hit/miss counters for coarse and edge caches.
- [ ] Add policy for stale-cell reuse across frames with camera/light movement thresholds.
- [ ] Validate no stale-shadow artifacts under fast camera motion and light rotation.
- [ ] Measure cache-clear time reduction and total hybrid-shadow pass impact.

### 15.11 Additional Shadow-System Hot Path Candidates (Post 15.3 Scan)
- [x] In `shadow_system.zig`, specialize `tracePacketAnyHit` by lane width (`1/8/16`) once per call to remove per-chunk lane-width switches from traversal loops.
- [x] In `shadow_system.zig`, precompute/pack per-triangle lane activity as an 8-bit mask to avoid `active_mask[triangle_lane]` scalar checks in inner loops.
- [x] In `shadow_system.zig`, add near-first child traversal ordering heuristic for BLAS DFS (ray-direction sign based or centroid-dot ordering) and benchmark early-occlusion effect.
- [x] In `shadow_system.zig`, add packet-level early-exit in traversal when `occluded_mask` covers all currently active rays.
- [x] In `shadow_system.zig`, eliminate by-value `ShadowTrianglePacket` copies in hot loops/intersection calls (pointer-based access).
- [ ] In `shadow_system.zig`, evaluate triangle-test loop reordering (`chunk -> triangle_lane` vs current `triangle_lane -> chunk`) using microbench to improve origin/dir reuse and cache locality.
- [x] In `renderer.zig` meshlet shadow packet build, split reject-only prepass (depth/backface/normal-length) from world-space transform pass to reduce wasted math on invalid lanes.
- [x] Add `phase15-microbench` shadow trace sub-bench with occupancy sweeps (`active lanes 1/4/8/16/32/64`) and triangle packet counts (`1/4/8/16`) to isolate traversal scaling.
- [x] Add `phase15-microbench` apply dual-path threshold sweep to determine switch point between sparse bitwalk and dense contiguous span writes.

### 15.10 Exit Criteria
- [ ] Reduce `renderTileJob` total zone time by >= 20% in baseline profile scene.
- [ ] Reduce `meshletShadowTile` total zone time by >= 30% and cut p99/p50 imbalance by >= 35%.
- [ ] Reduce combined `meshletShadowTrace + meshletShadowApply` time by >= 25%.
- [ ] Improve frame-time stability (95th percentile frame time) by >= 15% in stress scene.
- [ ] Document all accepted optimizations with before/after evidence in `docs/performance-profiling.md`.

### 15.12 Random Hot-Path Scan Additions (2026-03-12)
- [x] `H1` `shadow_system.zig`: precompute and store meshlet cone-sine once during BLAS build; remove per-trace `sqrt` in `meshletOccludesRay` and `meshletOccludesPacketMaskLanes`.
- [x] `H1` `renderer.zig` `applyMeshletShadows`: collapse reject prepass + origin build into one pass to remove candidate staging arrays and extra memory traffic.
- [ ] `H1` `adaptive_shadow_tile_pass.zig`: stop repacking triangle AoS data inside `isPointShadowed`; consume prepacked packets from `shadow_system.zig`.
- [x] `H1` `shadow_system.zig`: add near-first BLAS child traversal ordering heuristic and benchmark packet early-occlusion impact.
- [ ] `H2` `renderer.zig` meshlet apply: add masked SIMD attenuation path for dense/sparse occluded masks and keep scalar fallback for tails.
- [ ] `H2` `core/job_system.zig`: prototype low-lock queue path + worker wake signaling; benchmark tiny-job throughput and idle spin reduction.
- [ ] `H2` `render/kernels/dispatcher.zig`: remove per-group heap alloc/free for job contexts/shared scratch via reusable pools.
- [ ] `H2` `render/core/tile_renderer.zig`: reduce temporary lane-array pressure in triangle inner loop (fewer gather/scatter scratch arrays).
- [ ] `H3` `assets/texture.zig`: replace lane-scalar bilinear gather/write loop in `sampleBilinearBatchImpl` with cache-aware blocked path and gather-assisted variants.
- [ ] `H3` `scene/script_host.zig`: replace O(events * instances) queued dispatch with entity-indexed dispatch buckets for large script counts.
- [ ] Add microbench set for new random-scan tasks: `shadow cone test`, `meshlet packet build`, `dispatcher group submit`, `job queue tiny jobs`, `texture bilinear coherent/random`, `script dispatch fanout`.
- [ ] Add before/after hotspot report entries for each landed `H1`/`H2` task with frame id + scene hash.
  Status: first `H1` batch landed (`cone-sine precompute`, `single-pass packet origin build`, `near-first traversal ordering`) and compared against `profile-20260312-165313.json`: combined `meshletShadowTile+Trace+Apply` improved by `-13.78%` (`169.516ms -> 146.164ms`).
