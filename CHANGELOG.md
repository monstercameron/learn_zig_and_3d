# Changelog

## 2026-04-02

### Staged Direct Pipeline

- added a typed full-image pipeline scaffold in `engine/src/render/full_pipeline.zig`
- extracted direct-frame resources into `engine/src/render/frame_resources.zig`
- implemented and extracted direct stages under `engine/src/render/stages`
- added `frame_setup_stage.zig` for direct-frame clears, buffer reset policy, and frame setup metadata
- added `scene_submission_stage.zig` for world-side direct scene packet submission
- added `visibility_culling_stage.zig` for visible packet selection and meshlet visibility filtering
- added `primitive_expansion_stage.zig` for expansion from visible scene data into `PrimitiveBatch`
- added `screen_binning_stage.zig` for deterministic tile bin construction and touched-tile stats
- added `rasterization_stage.zig` for single-thread and worker-tile raster execution
- added `visible_scene.zig` as a typed boundary between visibility and expansion
- rewired `engine/src/render/backends/direct_backend.zig` to orchestrate the extracted direct stages instead of owning inline stage logic
- kept the direct path able to render the known-good single triangle through the staged pipeline

### Direct Path Optimization Passes

- narrowed the minimal benchmark to a true one-triangle scene so benchmark results reflect the renderer instead of showcase scene complexity
- skipped auxiliary scene-buffer clears for the direct benchmark path in `frame_setup_stage.zig`
- added targeted rect clears for the generic direct fast path in `engine/src/render/backends/direct_backend.zig`
- generalized the direct fast path so it applies to small single-thread non-depth draw lists instead of a hardcoded demo scene
- added explicit `0`-packet and `1`-packet fast paths in `engine/src/render/stages/rasterization_stage.zig`
- bypassed stage-5 tile binning for the one-packet single-thread fast path while keeping the tiled path for the general backend
- added reusable bounds helpers and rect clear helpers in `engine/src/render/direct_primitives.zig`
- optimized line raster with horizontal and vertical span fast paths in `engine/src/render/direct_primitives.zig`
- optimized triangle raster with incremental edge stepping in both the color-only and depth-writing paths
- split triangle fill into positive-area and negative-area loops to remove per-pixel winding branches
- added a direct color-only triangle fill path so no-depth packets avoid slower generic pixel writes
- optimized fill-only circles with a midpoint scanline fill path instead of per-row `sqrt`
- optimized triangle packet dispatch so fill and optional outline are emitted directly without rebuilding temporary style structs
- added SIMD clear helpers and vector-width-guided buffer fill paths in `engine/src/render/direct_primitives.zig`
- added SIMD point projection and vectorized projection rejection in `engine/src/render/direct_batch.zig`
- added SIMD polygon-bounds reduction in `engine/src/render/direct_primitives.zig`
- aligned hot renderer-owned frame buffers to 64-byte boundaries in `engine/src/render/renderer.zig`
- pre-reserved packet, visible-scene, meshlet, primitive-batch, draw-command, and polygon-point capacities across the direct callstack to reduce allocator churn
- reduced redundant direct-backend scans by analyzing fast-path eligibility, bounds, and tile estimate in one pass
- added power-of-two shift coverage math for direct fast-path tile estimates where possible

### DX11 Presentation Optimization

- switched the DX11 swap chain in `engine/src/render/present/present_d3d11.zig` to `DXGI_SWAP_EFFECT_FLIP_DISCARD`
- cached present row pitch in the DX11 backend instead of recomputing it on every present
- added early returns for empty-frame present attempts in the DX11 present path
- validated that partial dirty-rect updates directly to the swap-chain backbuffer were unsafe and reverted that path after it produced stale-rect artifacts
- kept DX11 presentation as the remaining dominant cost after the CPU-side direct render optimizations

### Validation

- `zig build check`
- `zig build test`
- `ZIG_RENDER_TTL_SECONDS=30 zig build run`

## 2026-04-01

### Render Core Redesign

- introduced a typed render-core module surface in `engine/src/render/main.zig`
- added cached frame-graph compilation in `engine/src/render/graph/frame_graph.zig`
- added cached frame-stage planning in `engine/src/render/graph/frame_plan.zig`
- added post-pipeline feature selection and resource setup in `engine/src/render/frame_pipeline.zig`
- moved frame and post execution loops into `engine/src/render/frame_executor.zig`
- moved renderer-to-executor hook construction into `engine/src/render/frame_hooks.zig`
- upgraded post-pass metadata in `engine/src/render/pipeline/pass_graph.zig` with explicit resource reads, writes, phases, and targets
- removed ad hoc post-pass buffer swapping from pass bodies and centralized output commits in the executor path
- reused per-frame shadow light counts across planning and post execution instead of rescanning lights
- gated post-phase timing so the hot path skips timestamp work unless the render overlay, profiler, or capture frame needs it
- replaced the test-only graph compilation `ArrayList` path with a fixed local buffer plus a final owned copy
- added direct tests for frame graph compilation, cached plan reuse, executor ordering, and renderer-style hook wiring

### Validation

- `zig build test`
- `zig build check`

### App Loop Refactor

- extracted generic app-loop control flow into `engine/src/app_loop.zig`
- replaced the old wide context and forwarding-hook shape with `LoopControl` plus a typed driver/session boundary
- added `AppSession` and `AppLoopDriver` in `engine/src/main.zig` so app-specific update and render policy remains local to the app shell
- promoted Win32 message pumping and cursor application to reusable file-level helpers in `engine/src/main.zig`
- added direct unit tests for app-loop frame TTL exit, message-pump shutdown, and skipped-render wait behavior

### Platform Layer Refactor

- split the platform layer into shared facades and OS backends under `engine/src/platform`
- added shared platform types in `engine/src/platform/types.zig` for `WindowDesc`, `CursorStyle`, and `PlatformEvent`
- added platform facade modules in `engine/src/platform/window.zig` and `engine/src/platform/loop.zig`
- moved Win32 window lifecycle code into `engine/src/platform/windows/window_win32.zig`
- moved Win32 event pumping and translation into `engine/src/platform/windows/loop_win32.zig`
- added Linux and macOS backend stub files under `engine/src/platform/linux` and `engine/src/platform/macos`
- removed app-policy `Esc` handling from the native window primitive
- made Win32 window-class registration reusable instead of failing on an already-registered class
- made app code consume typed platform events and platform primitives instead of calling renderer-coupled platform helpers
- wired lifecycle events for `close_requested`, `minimized`, `restored`, and `resized` into app behavior
- removed the last out-of-band Enter polling path so input handling is event-driven through normal keyboard state
- mapped both left and right control keys to `.ctrl` in `engine/src/platform/input.zig`
- restricted Win32 system-library linking in `build.zig` to Windows targets only
- added direct platform backend tests for key, resize, focus-loss, and close-request event translation

### Input System Refactor

- split semantic input handling out of the raw platform device-state module by adding `engine/src/input/actions.zig`
- kept `engine/src/platform/input.zig` focused on typed keyboard and mouse state only
- added table-driven semantic input bindings with explicit `InputContext`, `InputAction`, `ActionState`, and `BindingMap`
- added chord support for semantic actions such as editor nudge shortcuts
- wired resolved actions through `engine/src/main.zig` into scene script execution inputs
- exposed semantic actions through `engine/src/scene/script_host.zig` and `engine/src/scene/main.zig`
- migrated default and shadow-scene scripts to consume semantic actions instead of hardcoded raw keys where appropriate
- updated unit and smoke tests to cover semantic action resolution and runtime wiring

### Frame Pacing Cleanup

- fixed the app loop in `engine/src/app_loop.zig` so simulation update runs only when a frame is actually due to render
- added direct app-loop coverage for the pacing-sensitive one-update-per-rendered-frame behavior
- extracted pacing policy into `engine/src/render/frame_pacing.zig`
- centralized render pacing mode selection, deadline checks, sleep budgeting, sleep-bias adjustment, and deadline advancement
- rewired `engine/src/render/renderer.zig` to delegate pacing math and policy to the new render-side pacing module
- unified presented-frame bookkeeping so loading-overlay frames and normal present frames keep counters and deadlines consistent

### Job System Upgrade

- upgraded `engine/src/core/job_system.zig` from mutex-based worker queues to Chase-Lev worker-local deques with lock-free injected submission stacks for cross-thread work
- added explicit `JobClass` scheduling with `high`, `normal`, and `background` classes plus priority-aware injected draining
- rewired render job submissions across `engine/src/render/renderer.zig`, `engine/src/render/passes`, and `engine/src/render/kernels/dispatcher.zig` to use explicit submission classes instead of relying on implicit default priority
- moved scene script dispatch onto the job system in `engine/src/scene/script_host.zig` and threaded the scene-owned job system through `engine/src/scene/main.zig`
- changed parallel script dispatch to use per-instance command buffers so merged commands preserve original callback order instead of chunk order
- added `Commands.appendFrom` in `engine/src/scene/world.zig` for deterministic ordered command merging
- expanded unit and smoke coverage for queue growth, priority preference, parent-child completion, and parallel script command ordering
- normalized `job_system` as an imported build module in `build.zig` so render and scene code can share the scheduler without fragile relative imports

### Camera System Cleanup

- extracted renderer camera runtime behavior into `engine/src/render/camera_runtime.zig`
- centralized scene-side camera defaults and normalization in `engine/src/scene/camera_state.zig`
- moved duplicated script camera movement and look code into `engine/src/scene/scripts/camera_motion.zig`
- preserved authored camera FOV through scene loading and bootstrap in `engine/src/scene/loader.zig` and `engine/src/main.zig`
- made scene camera FOV scene-authoritative end-to-end and removed the old renderer FOV-delta forwarding path
- added a typed `camera_state.State` boundary and rewired scene update and render extraction through it
- strengthened active-camera management in `engine/src/scene/main.zig` with typed active camera queries, cycling, and normalization of invalid multi-active state
- moved more camera-mode and cursor-style policy out of `engine/src/render/renderer.zig` into `engine/src/render/camera_runtime.zig`
- removed the deprecated scalar `updateFrameWithCameraState` API so `updateFrameWithCamera` is the only camera-state update path
- expanded smoke coverage for authored camera FOV, normalized typed camera updates, active-camera cycling, and the no-forwarded-FOV-command regression

### Direct Render Foundation

- added a dedicated DX11 present backend in `engine/src/render/present/present_d3d11.zig` and moved CPU-framebuffer presentation out of the old GDI window blit path
- introduced an explicit present-state boundary in `engine/src/render/present_state.zig`
- extracted direct primitive raster operations into `engine/src/render/direct_primitives.zig`
- added typed compiled draw packets in `engine/src/render/direct_packets.zig`
- added compiled draw-list ownership in `engine/src/render/direct_draw_list.zig`
- added world-space primitive compilation in `engine/src/render/direct_batch.zig`
- added unified world-side submission packets for primitives, meshes, and meshlets in `engine/src/render/direct_scene_packets.zig`
- added direct mesh ingestion helpers in `engine/src/render/direct_mesh.zig`
- added direct meshlet ingestion, culling, and parallel batch emission in `engine/src/render/direct_meshlets.zig`
- extracted the direct backend into `engine/src/render/backends/direct_backend.zig`
- rewired `engine/src/render/renderer.zig` to delegate direct rendering to the new backend and present modules instead of owning the inline showcase path
- rewired minimal showcase startup in `engine/src/main.zig` so it uses the stripped direct path as the known-good baseline
- added deterministic tile-ref sorting, single-thread versus worker parity coverage, and non-background framebuffer assertions for the direct path
- added direct frame diagnostics for `clear`, `build`, `compile`, `bin`, `raster`, `present`, `primitive_count`, and `touched_tiles`
- added a meshlet-backed showcase cube on the direct path so the baseline now exercises initial mesh and meshlet submission instead of primitives only
- updated `build.zig` to link the DX11 presentation dependencies needed by the new present backend on Windows

### Tile Renderer Cache Pass

- kept the live direct showcase on the extracted tile-render path by forcing the single-triangle scene through stage 5 binning and stage 6 worker-tile raster in `engine/src/render/renderer.zig`
- cached per-command packet bounds in `engine/src/render/direct_draw_list.zig` so stage 5 binning can reuse frame-local bounds data instead of recomputing geometric bounds during tile setup
- extended `engine/src/render/stages/screen_binning_stage.zig` to emit active tile indices, per-tile command counts, and cached tile spans, reducing duplicate tile-coordinate derivation between the count and write passes
- upgraded `engine/src/render/stages/screen_binning_stage.zig` to use deterministic hybrid tile-ref sorting with insertion sort for tiny tile lists and block sort for larger tile lists
- moved tile-execution policy fully into `engine/src/render/stages/rasterization_stage.zig`, including direct-versus-tiled analysis, active-tile scheduling, and density-aware worker chunking
- changed stage 6 worker raster to consume active-tile outputs directly from stage 5 instead of rebuilding them locally
- aligned raster chunk contexts for better cache-line behavior and reduced worker-side pointer chasing by carrying draw-item slices directly in `engine/src/render/stages/rasterization_stage.zig`
- added prefetch on the tile command walk in `engine/src/render/stages/rasterization_stage.zig` so denser tile lists can pull upcoming draw packets toward cache earlier
- added direct-backend storage for cached tile spans and active tile command counts in `engine/src/render/backends/direct_backend.zig`
- validated the tile path with `zig build check`, `zig build test`, and live TTL runs on the single-triangle worker-tile scene

### Multi-Primitive Tile Showcase Pass

- switched the live direct showcase scene in `engine/src/render/renderer.zig` from the single-triangle benchmark back to the multi-primitive showcase while keeping stage 6 on `worker_tiles`
- added a 15-second default renderer TTL in `engine/src/main.zig` when no explicit `ZIG_RENDER_TTL_SECONDS` or frame-based TTL is configured, while keeping explicit environment overrides authoritative
- optimized `engine/src/render/direct_primitives.zig` line rendering for the tiled path by clipping segments to tile bounds before Bresenham and using a direct color-write path after clipping
- optimized `engine/src/render/direct_batch.zig` compile-time projection by adding fixed-size line and triangle projection helpers, a small-point vector projection path, and a cheaper circle-radius projection path
- added projected backface culling for triangles and polygons in `engine/src/render/direct_batch.zig` so hidden faces are dropped before stage 5 binning and stage 6 raster
- added front-face helper reductions and hot inlining in `engine/src/render/direct_batch.zig` to keep compile-side helpers lean on the multi-primitive path
- changed `engine/src/render/backends/direct_backend.zig` tiled clears to use the union of the previous and current dirty rects instead of clearing the whole frame every tiled frame
- reduced showcase scene cost in `engine/src/render/stages/scene_submission_stage.zig` by removing the meshlet-cube outline override while preserving the filled cube in the scene
- validated the multi-primitive worker-tile path with `zig build check`, `zig build test`, and repeated `zig build run` TTL runs, including a 15-second explicit TTL run showing `primitives=16`, `touched_tiles=89`, and raster around the low-2ms range

### Known Limits

- the direct raster backend is still a stub in `engine/src/render/renderer.zig`
- stage and pass implementations still live primarily in `renderer.zig`; only orchestration has been extracted so far
