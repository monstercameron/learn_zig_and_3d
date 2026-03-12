# Current Features And API Usage

This document is a practical map of what exists in the repository today, which functions drive each feature, and how those features are used from the runtime.

Verified against the current codebase on 2026-03-12.

## Runtime Entry And Scene Selection

Primary entry:

- `engine/src/main.zig` -> `pub fn main() !void`

Scene selection flow:

- `resolveLaunchSceneKey(...)` chooses the scene key from:
1. `--scene=<key>` or `--scene <key>`
2. `ZIG_SCENE`
3. `defaultScene` in `assets/configs/scenes/index.json`
- `resolveSceneFilePath(...)` maps scene key -> scene file path.
- `buildSceneDefinition(...)` parses `SceneFile` JSON into runtime definitions.

Current scene index:

- `assets/configs/scenes/index.json` with keys:
1. `gun_physics`
2. `cornell`
3. `loading_neutral`
4. `mixed_shadows`
5. `mixed_shadows_static`
6. `shadow_tuning`
7. `shadow_single_model`

Usage:

```powershell
zig build run -- --scene=cornell
$env:ZIG_SCENE = "shadow_tuning"
zig build run
```

## Config Layers And How They Are Applied

Config load order at startup (later overrides earlier):

1. `assets/configs/default.settings.json` via `app_config.load(...)`
2. `assets/configs/render_passes.json` via `app_config.loadRenderPasses(...)`
3. `assets/configs/engine.ini` via `app_config.loadEngineIni(...)`

Key functions:

- `engine/src/core/app_config.zig`
1. `pub fn load(...)`
2. `pub fn loadRenderPasses(...)`
3. `pub fn loadEngineIni(...)`
4. `pub fn targetFrameTimeNs() i128`

Usage pattern in code:

- `main()` loads all three layers once.
- Renderer behavior reads global config vars (for example `WINDOW_VSYNC`, `TARGET_FPS`, pass toggles, camera tuning).

## Input And Camera Modes

Input state is bitmask-driven:

- `engine/src/platform/input.zig`
1. `pub fn updateKeyState(...) ?KeyEvent`
2. `VirtualKeys` + `KeyBits` mappings (`WASD`, arrows, `Space`, `Ctrl`, `Enter`, `Q`, `E`)

Camera mode and look behavior:

- `engine/src/render/camera_controller.zig`
1. `consumeLookDelta(...)`
2. `effectiveSensitivity(...)`
3. `applyFirstPersonLook(...)`
4. `stepFpsBody(...)`
5. `computeViewBasis(...)`
6. `computeProjectionScalars(...)`

Mode toggle and interactive controls:

- `engine/src/render/renderer.zig` -> `handleCharInput(...)`
1. `V`: toggle editor <-> first-person mode
2. `Q/E`: FOV step
3. `P`: render overlay toggle
4. `H/N`: hybrid-shadow debug stepping
5. `M`: scene-item gizmo enable/disable
6. `G`: light gizmo enable/disable
7. `L`: cycle selected light
8. `X/Y/Z`: axis selection for active gizmo
9. `J/K`: move selected gizmo target along active axis

Pointer and raw-mouse functions:

- `handleMouseMove(...)`
- `handleRawMouseDelta(...)`
- `handleMouseLeftClick(...)`
- `handleMouseLeftRelease(...)`
- `handleMouseRightClick(...)`
- `handleMouseRightRelease(...)`
- `handleFocusLost(...)`
- `handleFocusGained(...)`

## Scene Item And Light Gizmos

Scene item gizmo API:

- `engine/src/render/scene_item_gizmo.zig` -> `State` methods:
1. `setBindings(...)`
2. `handlePointerMove(...)`
3. `handlePointerDown(...)`
4. `handlePointerUp()`
5. `consumeTranslateRequest()`
6. `notifyItemTranslated(...)`
7. `setItemOrigin(...)`
8. `drawGizmo(...)`
9. `applyOutline(...)`

Renderer integration points:

- `setSceneItemBindings(...)`
- `consumeSceneItemTranslateRequest(...)`
- `notifySceneItemTranslated(...)`
- `setSceneItemCenter(...)`

Main-loop usage:

- `main()` calls `renderer.consumeSceneItemTranslateRequest()`
- if a request exists, `applySceneItemTranslateRequest(...)` mutates mesh/physics state
- scene physics updates are paused while dragging (`renderer.isSceneItemDragActive()`)

## Rendering Pipeline And Pass System

Pass graph and ordering:

- `engine/src/render/pipeline/pass_graph.zig`
1. `RenderPassId` enum
2. `default_post_pass_order`
3. `passBit(...)`, `allPassMask(...)`

Pass execution:

- `engine/src/render/pipeline/pass_registry.zig`
1. `buildEnabledMask(...)`
2. `executeMask(...)`
3. `executeMaskWithPhaseBoundary(...)`
4. `executePostPasses(...)`
5. `PassInterface(...)`

Post-pass families currently wired:

1. `skybox`
2. `shadow_resolve`
3. `hybrid_shadow`
4. `ssao`
5. `ssgi`
6. `ssr`
7. `depth_fog`
8. `taa`
9. `motion_blur`
10. `god_rays`
11. `bloom`
12. `lens_flare`
13. `dof`
14. `chromatic_aberration`
15. `film_grain_vignette`
16. `color_grade`

Representative pass APIs:

- `engine/src/render/passes/*`
1. `runPipeline(...)` for full-pass scheduling
2. `runRows(...)` for stripe/range execution

Representative kernel APIs:

- `engine/src/render/kernels/*`
1. `applyRows(...)` style kernels for row-based effects
2. `main(ctx: *ComputeContext)` style compute kernels
3. utility kernels like `shadow_sample_kernel.sampleOcclusion(...)`

## Renderer Public API Most Used By Main

Initialization and lifecycle:

- `Renderer.init(...)`
- `Renderer.deinit(...)`
- `Renderer.render3DMeshWithPump(...)`

Scene/bootstrap setup:

- `setLightCapacity(...)`
- `setDirectionalLight(...)`
- `setLightShadowMode(...)`
- `setLightShadowUpdateInterval(...)`
- `setLightShadowMapSize(...)`
- `setLightGlow(...)`
- `setTextures(...)`
- `setHdriMap(...)`
- `setCameraPosition(...)`
- `setCameraOrientation(...)`

Frame pacing and loading overlay:

- `shouldRenderFrame()`
- `waitUntilNextFrame()`
- `beginSceneLoadingOverlay(...)`
- `updateSceneLoadingOverlay(...)`
- `endSceneLoadingOverlay()`
- `renderLoadingOverlayFrame(...)`

Profiling hooks:

- `recordRenderPassTiming(...)`
- `recordRenderPassDuration(...)`

## Frame Pacing, VSync, FPS Cap, And HUD

Core controls:

- `WINDOW_VSYNC` and `TARGET_FPS` in `app_config`
- `Renderer.shouldRenderFrame()` gates frame start
- `Renderer.waitUntilNextFrame()` sleeps/yields until next frame slot

HUD metrics and graph:

- `engine/src/render/frame_pacing_hud.zig`
1. `Tracker.recordSample(...)`
2. `panelRect(...)`
3. `drawPanel(...)`
4. percentile metrics (`p95`, `p99`), stutter count, CPU/wait breakdown
5. graph uses fixed time buckets for scrolling history (`history_len = 512`)

Typical `engine.ini` controls:

```ini
[window]
vsync = true

[rendering]
fps_limit = 24
```

Use `fps_limit = 0` to run uncapped.

## Scene Runtime (ECS/Streaming Layer)

Main API:

- `engine/src/scene/main.zig` -> `SceneRuntime`
1. `init(...)`
2. `deinit()`
3. `createEntity()`
4. `destroyEntity(...)`
5. `bootstrapFromDescription(...)`
6. `updateFrame(...)`
7. `pinFrameAssets(...)`
8. `unpinFrameAssets(...)`

Frame extraction:

- `engine/src/scene/render_extraction.zig`
1. `extractFrameSnapshot(...)`
2. returns `RenderSnapshot { active_camera, renderables, lights }`

Supporting subsystems:

- `world.zig`: entity lifecycle and deferred command application
- `components.zig`: component storage
- `graph.zig`: parent/child hierarchy
- `dependency_graph.zig`: dependency edges + cycle validation/topological order
- `asset_registry.zig`: retain/release/pin/unpin/destroy for asset handles
- `residency_manager.zig` + `octree.zig`: spatial residency and active/prefetch control
- `script_host.zig`: script module registration and per-frame dispatch

How main uses it:

1. `populateSceneRuntimeBootstrap(...)` maps loaded scene data into `BootstrapScene`.
2. `phase13_runtime.updateFrame(...)` runs once per frame.
3. Snapshot assets are pinned during render and unpinned after render.

## Job System And Parallel Work

Job system API:

- `engine/src/core/job_system.zig`
1. `Job.init(...)`, `Job.execute()`, `Job.wait()`
2. `JobQueue.push(...)`, `pop()`, `steal()`
3. `JobSystem.init(...)`, `submitJobAuto(...)`, `pendingJobs()`
4. `allocateJob(...)`, `freeJob(...)`

Usage in renderer:

- Pass and kernel work is partitioned into stripes/tiles.
- Jobs are enqueued to the shared `JobSystem`.
- Render path waits where synchronization is required for compose/present.

## Environment Variables And Runtime Flags

From `engine/src/main.zig`:

1. `ZIG_RENDER_TTL_SECONDS`: auto-exit after time budget
2. `ZIG_RENDER_TTL_FRAMES`: auto-exit after frame budget
3. `ZIG_RENDER_PROFILE_FRAME`: dump profile data for selected frame
4. `ZIG_SCENE`: scene key override

CLI:

- `--scene=<key>` or `--scene <key>`

## Practical Recipes

Enable only shadow-related passes quickly (`assets/configs/engine.ini`):

```ini
[passes]
shadows = true
hybrid_shadows = true
ssao = false
ssgi = false
ssr = false
taa = false
bloom = false
depth_fog = false
motion_blur = false
lens_flare = false
chromatic_aberration = false
film_grain = false
god_rays = false
dof = false
skybox = false
color_correction = false
```

Run a specific scene for tuning:

```powershell
zig build run -- --scene=shadow_tuning
```

