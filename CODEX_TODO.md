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
- [ ] Add `EntityId` with generation/versioning to avoid stale references after destroy/reuse.
- [ ] Add `AssetId` / `AssetHandle` with generation/versioning for safe resource reuse.
- [ ] Add stable `SceneNodeId` or equivalent authoring/runtime mapping for debug and serialization.
- [ ] Add central name/tag registry for optional lookup by authored id (`camera.main`, `light.key`, etc.).
- [ ] Add validation that duplicate authored ids are rejected during scene load.

### 13.2 World Core (ECS Foundation)
- [ ] Create `engine/src/scene/world.zig`.
- [ ] Create typed component storage with explicit containers, not string-keyed maps.
- [ ] Add core lifecycle ops: create entity, destroy entity, enable entity, disable entity.
- [ ] Add deferred `Commands` buffer for structural edits during update/event processing.
- [ ] Add post-frame application of deferred commands at a single safe point.
- [ ] Add world-level destroy queue so runtime code can request deletion without invalidating iterators.
- [ ] Add world snapshot/debug dump helpers for inspection during migration.

### 13.3 Scene Graph (Hierarchy)
- [ ] Create `engine/src/scene/graph.zig`.
- [ ] Add `Parent` relationship component/storage.
- [ ] Add child list or first-child/next-sibling representation.
- [ ] Add `LocalTransform` component.
- [ ] Add `WorldTransform` cache component.
- [ ] Add `HierarchyDirty` propagation flagging.
- [ ] Add reparent operation with cycle rejection.
- [ ] Add subtree enable/disable propagation semantics.
- [ ] Add transform propagation pass ordered before physics-to-render extraction.
- [ ] Add attach-point support for child entities that inherit transforms from parent items.

### 13.4 Dependency Graph (Non-Transform DAG)
- [ ] Create `engine/src/scene/dependency_graph.zig`.
- [ ] Add dependency edge kinds: `asset`, `script`, `activation`, `logic`, `physics`, `render`.
- [ ] Add load-time DAG validation and cycle detection.
- [ ] Add topological ordering helper for activation/load/unload sequencing.
- [ ] Add dependency query helpers for “why is this entity pinned/resident?”.
- [ ] Add policy for soft vs hard dependencies.
- [ ] Add failure behavior when a hard dependency fails to load.

### 13.5 Authoring Schema Evolution
- [ ] Define unified scene schema that can express:
- [ ] entity id/name.
- [ ] parent/children.
- [ ] components.
- [ ] script attachments.
- [ ] dependency edges.
- [ ] residency hints / stream group / cell assignment overrides.
- [ ] Add migration path from current `assets/configs/scenes/*.scene.json` model entries.
- [ ] Reuse or absorb useful structure from `assets/levels/default.level.json` (`children`, `scripts`).
- [ ] Add schema validation with clear diagnostics for invalid ids, cycles, and missing assets.
- [ ] Add scene loader tests for parent-child + dependency + script declarations.

### 13.6 Asset Registry and Resource Lifetime
- [ ] Create `engine/src/scene/asset_registry.zig`.
- [ ] Register mesh assets as distinct resources instead of merging everything up front.
- [ ] Register texture assets with stable handles.
- [ ] Register HDRI/environment assets with stable handles.
- [ ] Register script modules with stable handles.
- [ ] Add resource states: `unloaded`, `queued`, `loading`, `resident`, `failed`, `evict_pending`, `offloading`.
- [ ] Add generation counters to all handles so stale references fail safely.
- [ ] Add ref-count or residency-request tracking separate from transient per-frame pins.
- [ ] Add central unload queue processed only at safe points.

### 13.7 Octree Residency Manager (Spatial Load/Offload)
- [ ] Create `engine/src/scene/residency_manager.zig`.
- [ ] Create `engine/src/scene/octree.zig` or equivalent loose-octree module.
- [ ] Define world bounds / root cell policy.
- [ ] Add support for static entity registration into octree leaves.
- [ ] Add support for dynamic entity reassignment or loose-octree membership.
- [ ] Add camera-driven residency request computation.
- [ ] Add preload radius / active radius / eviction hysteresis settings.
- [ ] Add cell states: `cold`, `prefetch`, `requested`, `resident`, `evict_pending`.
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
- [ ] Add per-phase pins for render extraction, script dispatch, and physics sync.
- [ ] Prevent unload while any pin is active.
- [ ] Add temporary frame pins for resources touched by current extraction/update phase.
- [ ] Add `will_offload` / `did_offload` notifications for dependent systems.
- [ ] Add stale-handle diagnostics in debug builds.
- [ ] Add policy for unresolved handles returned to scripts (`null object`, error event, or deferred retry).

### 13.10 Component Set for First Rollout
- [ ] Add `TransformLocal`.
- [ ] Add `TransformWorld`.
- [ ] Add `MeshRef` / `Renderable`.
- [ ] Add `MaterialRef` / `TextureSlots`.
- [ ] Add `Camera`.
- [ ] Add `Light` with current shadow/glow parameters.
- [ ] Add `PhysicsBody` / motion-type metadata.
- [ ] Add `Selectable` / gizmo metadata.
- [ ] Add `ScriptComponent`.
- [ ] Add `Streamable` / residency policy metadata.
- [ ] Add `ActivationState` or enabled-mask component.

### 13.11 Script Host and Event Model
- [ ] Create `engine/src/scene/script_host.zig`.
- [ ] Define first-pass Zig-native script ABI.
- [ ] Add script instance creation/destruction lifecycle.
- [ ] Add per-entity script attachment with authored bindings.
- [ ] Add event set:
- [ ] `OnAttach`, `OnDetach`.
- [ ] `OnEnable`, `OnDisable`.
- [ ] `OnBeginPlay`, `OnEndPlay`.
- [ ] `OnUpdate`, `OnFixedUpdate`, `OnLateUpdate`.
- [ ] `OnParentChanged`, `OnTransformChanged`.
- [ ] `OnAssetReady`, `OnAssetLost`.
- [ ] `OnZoneEnter`, `OnZoneExit`.
- [ ] `OnCollisionEnter`, `OnCollisionStay`, `OnCollisionExit`.
- [ ] Require scripts to mutate world state through deferred commands only.
- [ ] Disallow scripts from persisting raw component pointers across callbacks.
- [ ] Add host-side version checks for script module ABI compatibility.

### 13.12 Script Reload / Persistence Hooks
- [ ] Reuse ideas from `experiments/hotreload_demo` for module hot-reload.
- [ ] Add script module `create` / `destroy` / `on_event` entrypoints.
- [ ] Add optional script state serialize/deserialize hooks for reload/offload.
- [ ] Add graceful fallback when module reload fails (keep prior instance or disable script explicitly).
- [ ] Add event ordering guarantees around reload (`will_reload`, `did_reload`, `reload_failed`).

### 13.13 World Phase Scheduler
- [ ] Define explicit frame phases:
- [ ] input.
- [ ] residency decisions.
- [ ] job completion integration.
- [ ] script events.
- [ ] fixed-step physics.
- [ ] transform propagation.
- [ ] render extraction.
- [ ] present.
- [ ] safe offload / deferred destruction.
- [ ] Add invariant checks so no forbidden mutations occur during extraction or traversal.
- [ ] Move existing main-loop special cases into phase-owned systems incrementally.

### 13.14 Physics Integration Refactor
- [ ] Stop treating physics runtime structs as separate scene-side ownership islands.
- [ ] Update physics to write entity transform/body state, not raw mesh ownership state.
- [ ] Add script/selection-safe pause rules for drag interactions.
- [ ] Add collision event emission into script event queue.
- [ ] Add handling for physics entities that become non-resident or offloaded.

### 13.15 Render Extraction Bridge
- [ ] Create `engine/src/scene/render_extraction.zig`.
- [ ] Extract active camera from world to renderer state.
- [ ] Extract visible/resident lights from world to renderer state.
- [ ] Extract visible/resident renderables into a frame snapshot.
- [ ] Preserve current renderer API shape during first migration step.
- [ ] Add mapping from extracted render item back to `EntityId` for picking/gizmo interactions.
- [ ] Replace current scene-item binding identity path with entity-backed selection ids.
- [ ] Gate extraction to resident cells only.

### 13.16 Selection, Gizmos, and Editor-Style Interactions
- [ ] Rewire scene-item selection to target `EntityId` rather than merged-mesh instance index.
- [ ] Keep outline/gizmo logic working when items stream in/out.
- [ ] Add behavior for selected entity offload attempts (pin selected entity, or clear selection explicitly).
- [ ] Add parent/child manipulation policy (move child local transform vs move root). 
- [ ] Add event emission for selection changes into script/event system.

### 13.17 Streaming Diagnostics and Tooling
- [ ] Add octree/cell debug overlay.
- [ ] Add resident/prefetch/evict-pending counters to debug HUD.
- [ ] Add dependency graph inspection dump for selected entity.
- [ ] Add asset pin-count / residency-state diagnostics.
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
- [ ] Stage 1: land `EntityId`, world core, and scene graph without changing renderer behavior.
- [ ] Stage 2: move scene loading to entity/component creation while keeping current renderer bridge.
- [ ] Stage 3: add asset registry and stable handles.
- [ ] Stage 4: add octree residency manager with no script integration yet.
- [ ] Stage 5: add script host and event dispatch.
- [ ] Stage 6: move physics and selection to entity-backed state.
- [ ] Stage 7: remove remaining special-case runtime structs from `main.zig`.

### 13.20 Validation and Approval Gates
- [ ] Approval gate: review scene schema before loader migration starts.
- [ ] Approval gate: review first-pass script ABI before `script_host.zig` lands.
- [ ] Approval gate: review octree residency policy before automatic eviction is enabled.
- [ ] Approval gate: confirm selection/gizmo behavior for streamed entities.
- [ ] For each migration stage, run `zig build check` and targeted runtime smoke validation.
- [ ] Add at least one end-to-end streaming fixture scene before enabling offload by default.
