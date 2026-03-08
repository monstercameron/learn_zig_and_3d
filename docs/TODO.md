# TODO List

This is a comprehensive list of potential improvements, new features, and refactoring opportunities for the Zig 3D CPU Rasterizer project.

## Mesh Shader Follow-Up (High Priority)

- [x] Generate meshlets for loaded meshes (partition triangles, compute vertex remapping, populate bounding spheres).
- [x] Reuse cached per-meshlet vertex transforms to avoid reprojecting untouched geometry each frame.
- [x] Tighten tile binning to scan only the intersecting tile range derived from triangle bounds.
- [x] Extend benchmarking harnesses to exercise meshlet-enabled pipelines and capture mesh shader metrics.
- [x] Cache per-triangle camera and screen-space vertices so raster stages can bypass mesh lookups.
- [x] Parallelize meshlet task emission by dispatching meshlet jobs through the job system.
- [x] Persist meshlet work buffers across frames with fine-grained invalidation to avoid rebuilds.
- [x] Add runtime telemetry (meshlets culled/processed, triangles emitted) to validate task-stage performance.

## Meshlet Implementation Upgrades

- [x] **Adopt Packed Meshlet Storage**: Replace per-meshlet heap slices in [`src/mesh.zig`] with a descriptor array plus packed vertex-index and triangle-index buffers to improve cache locality and reduce allocation overhead.
- [x] **Add Local Vertex Remapping**: Store meshlet-local vertex indices instead of only global mesh indices so meshlet jobs can operate on tighter working sets and smaller index formats.
- [ ] **Improve Offline Meshlet Clustering**: Upgrade the greedy builder in [`src/mesh.zig`] / [`src/meshlet_builder.zig`] to account for shared-vertex reuse, spatial locality, and tighter bounds when grouping triangles.
- [x] **Serialize Packed Meshlet Data**: Update [`src/meshlet_cache.zig`] to persist the packed meshlet format directly instead of reconstructing fragmented heap-owned slices on load.
- [x] **Use Narrower Meshlet Index Types**: Downsize meshlet-local indices to `u16` or smaller when limits allow to reduce bandwidth and cache pressure.

## Meshlet Runtime Optimizations

- [x] **Give Meshlet Jobs Local Vertex Scratch**: Replace the shared global vertex-ready path in [`src/renderer.zig`] with per-meshlet local transform scratch keyed by meshlet-local vertex lists.
- [ ] **Batch Meshlet Triangle Reservations**: Reserve triangle output spans once per meshlet in [`src/renderer.zig`] instead of incrementing shared output state per emitted triangle.
- [x] **Make Tile Contribution Recording O(1)**: Replace the linear search inside `MeshletContribution.addTriangle` in [`src/renderer.zig`] with a dense tile lookup or per-frame stamp table.
- [ ] **Parallelize Meshlet-to-Tile Binning Further**: Reduce the cost of the post-emission merge step in [`src/renderer.zig`] so tile list assembly scales with meshlet job parallelism.
- [ ] **Promote Meshlets to the Primary Work Unit**: Refactor [`src/renderer.zig`] so the meshlet path is the first-class render path rather than an adapter back into generic triangle packets.

## Meshlet Culling & Data Quality

- [x] **Add Meshlet Normal-Cones**: Extend meshlet data with average-normal or cone information and use it for coarse backface culling before primitive emission.
- [ ] **Add Tighter Bounds**: Evaluate storing meshlet AABBs alongside spheres for elongated clusters that cull poorly with spherical bounds alone.
- [ ] **Add Depth-Aware Scheduling**: Investigate front-to-back meshlet ordering once scene complexity grows so culling and depth efficiency improve together.
- [x] **Persist More Offline Derived Data**: Precompute and serialize extra meshlet metadata such as tighter bounds, cone data, and local remap tables.

## Meshlet Tooling & Validation

- [x] **Add Meshlet Telemetry Counters**: Track visible meshlets, emitted triangles, rejected triangles, tiles touched, and merge costs per frame in [`src/renderer.zig`].
- [ ] **Add Meshlet Debug Visualizations**: Render overlays showing active meshlets, meshlet bounds, and visibility state to validate clustering and culling behavior.
- [x] **Benchmark Meshlet Quality**: Extend [`benchmarks/src/bench_meshlet.zig`] to report reuse ratio, average local vertex count, bounds quality, and emission efficiency instead of only cull timing.
- [x] **Add Meshlet Regression Tests**: Cover near-plane crossing, degenerate clusters, and cache reload correctness so meshlet changes don’t regress silently.
- [x] **Compare Meshlet vs Non-Meshlet Paths**: Add reproducible benchmark traces using the same mesh/camera inputs so improvements can be validated against the legacy triangle path.

## Audio Engine (Native Windows)

- [ ] **Phase 1: WASAPI Backend**
    - [x] Define WASAPI COM interface bindings in Zig.
    - [x] Implement audio device enumeration and initialization.
    - [x] Create a dedicated audio thread for stream callbacks.
- [ ] **Phase 2: Software Mixer**
    - [x] Implement a "Voice" struct to represent a single playing sound.
    - [x] Build the core mixer loop to combine/resample active voices.
    - [x] Integrate the mixer with the WASAPI backend.
- [ ] **Phase 3: Sound Decoders**
    - [x] Implement `loadWav` using `std.wave` and a sample format converter.
    - [x] Integrate `dr_mp3` C library for `loadMp3` functionality.
    - [ ] Port MP3 decoder to pure Zig.
- [ ] **Phase 4: Public API Implementation**
    - [x] Connect the public `audio.zig` functions to the backend and mixer.
    - [x] Implement thread-safe command passing for playback control (play, stop, setVolume, etc.).

## Rendering Features

- [ ] **Shading Models**:
    - [ ] Implement Gouraud shading (per-vertex lighting).
    - [ ] Implement Phong shading (per-pixel lighting).
    - [ ] Implement Blinn-Phong shading for more realistic specular highlights.
- [ ] **Lighting**:
    - [ ] Add support for multiple light sources.
    - [ ] Implement different light types (e.g., point lights, spot lights).
    - [x] Add support for specular highlights.
    - [ ] Implement attenuation for point and spot lights.
- [ ] **Texturing**:
    - [x] Implement bilinear texture filtering for smoother textures.
    - [ ] Implement trilinear texture filtering.
    - [x] Add support for mipmapping to reduce aliasing on distant objects.
    - [ ] Implement anisotropic filtering for improved texture quality on surfaces at an angle.
- [ ] **Transparency**:
    - [x] Add support for alpha blending for transparent objects.
    - [ ] Implement a sorting mechanism for transparent objects to render them correctly.
- [ ] **Camera**:
    - [ ] Create a dedicated camera struct to manage view and projection matrices.
    - [ ] Implement a "look-at" function for the camera.
    - [x] Add support for orthographic projection.
- [ ] **Clipping**:
    - [x] Implement near-plane clipping to correctly handle geometry that is partially behind the camera.
    - [x] Implement frustum culling to discard objects that are entirely outside the camera's view.
- [ ] **UI & Debugging**:
    - [ ] Add an immediate-mode GUI (e.g., using Dear ImGui) to control rendering options in real-time.
    - [ ] Render the light source as a 3D sphere instead of a 2D circle.
    - [x] Add a skybox or skydome for a more interesting background.

## Performance Optimizations

- [ ] **SIMD Vectorization Candidates**:
    - [x] **AVX2 Dispatch Layer**: Add runtime CPU feature detection and baseline/AVX2/AVX-512 dispatch for a small set of hot kernels so one binary can scale across multiple x86 CPUs without globally targeting the widest ISA.
        - [x] Add a runtime x86 instruction-set checker (`src/cpu_features.zig`) that detects SSE2, AVX, FMA, AVX2, AVX-512 state, and AMX state at startup.
        - [x] Route the existing `renderer.zig` packed color/blend batch helpers through runtime-selected scalar/8-lane/16-lane/32-lane paths so TAA resolve, bloom packing, AO/depth fog compositing, skybox packing, god rays, lens flare, chromatic aberration, film grain, and motion blur no longer hard-wire one compile-time lane width.
        - [x] Replace compile-time SIMD-width selection in hot kernels with runtime dispatch where one binary needs to support multiple CPU classes.
    - [x] **`shadow_system.zig`**: Convert `tracePacketAnyHit` to packet-aware BVH traversal instead of peeling one ray at a time from the mask. This is the highest-value AVX2 target because current profiling shows shadow tracing is still the main hotspot.
    - [x] **`shadow_system.zig`**: Rework `meshletOccludesRay` so skip-triangle masking, packet iteration, and early-out logic stay vector-friendly around the already-8-wide triangle kernel instead of falling back to scalar lane handling.
    - [x] **`shadow_system.zig`**: Cache packed shadow meshlet geometry and BLAS nodes across frames so meshlet-shadow rendering only rebuilds acceleration data when mesh topology or meshlet contents change.
    - [x] **`shadow_system.zig`**: Split BLAS and TLAS invalidation so static meshes can retain their BLAS while only instance transforms trigger TLAS rebuilds.
    - [x] **`tile_renderer.zig`**: Batch fragment shading spans in `rasterizeTriangleToTile` so texture sampling, normal interpolation, view/light vector setup, and BRDF evaluation can run on 4-8 pixels at a time.
    - [x] **`texture.zig`**: Add an AVX2-friendly batched bilinear sampling path around `sampleBilinearImpl` so four-tap filtering, channel unpacking, and weighted blending can be amortized across multiple UVs.
    - [x] **`lighting.zig`**: Add a batched `computePBR` path for span shading. The scalar function is math-dense, but the real payoff comes from evaluating multiple fragments together rather than only micro-optimizing single calls.
    - [x] **`renderer.zig`**: Revisit SSAO generation loops so sample accumulation uses structure-of-arrays batches and vectorized `Vec3` math instead of scalar neighbor walks inside partially batched code.
    - [ ] **AVX-512 Follow-Up**: Re-evaluate the same hot kernels for 16-lane execution once AVX2 versions exist, especially packet shadow traversal, batched bilinear sampling, deferred lighting, and span-based fragment shading. Only keep AVX-512 paths that outperform AVX2 on real hardware rather than assuming wider is always faster.
        - [x] Extend the new runtime-dispatched `renderer.zig` batch helper path to include a 32-lane backend so the existing post-process kernels can exercise AVX-512-width execution without changing their call sites again.
    - [x] **`shadow_system.zig`**: Prototype 16-lane AVX-512 packet traversal for `tracePacketAnyHit` and `meshletOccludesRay` after the packet-oriented control flow is in place.
    - [x] **`texture.zig`**: Prototype AVX-512 batched filtering around `sampleBilinearImpl` once multiple-UV sampling can be issued together.
    - [x] **`kernels/deferred_lighting_kernel.zig`**: Evaluate whether the deferred lighting kernel can be executed in CPU-side AVX-512 batches, since its per-pixel math is regular enough to benefit from wider lanes if the execution model is widened.
        - Current evaluation: the kernel exists, but no live dispatch/use site was found in the renderer path, so AVX-512 work here stays deferred until the kernel is actually wired into frame execution.
    - [x] **AMX Assessment**: Keep AMX off the active optimization path unless the renderer gains a genuinely tile-matrix workload such as ML denoising, large batched skinning, or convolution-heavy post-processing. Current raster, shading, and traversal code is not a good AMX fit.
    - [ ] **`math.zig`**: Vectorize all core `Vec2`, `Vec3`, `Vec4`, and `Mat4` operations. This is the highest priority for SIMD.
        - `Vec2.add`, `Vec2.sub`, `Vec2.scale`.
        - `Vec3.add`, `Vec3.sub`, `Vec3.scale`, `Vec3.dot`, `Vec3.cross`.
        - `Mat4.multiply`: Classic 4x4 matrix multiplication is highly parallelizable.
        - `Mat4.mulVec4`: Can be optimized using 4-wide dot products.
        - [x] Prototype SIMD implementations in benchmarks (`benchmarks/src/math_copy.zig`, `math_simd.zig`, `math_simd_optimized.zig`) for validation.
        - [ ] Prioritize `Vec3.dot` and `Vec3.cross` for AVX2-backed batched callers first; the standalone scalar helpers are too small to justify ISA-specific rewrites unless surrounding loops are also restructured.
    - [ ] **`renderer.zig`**: Vectorize the main vertex transformation loop in `render3DMeshWithPump`. This involves processing multiple vertices (e.g., 4 or 8 at a time) through the series of dot products and matrix multiplications.
        - [x] Batch the meshlet-local visible-vertex transform/project loop in `generateMeshWork` so contiguous meshlet vertex slices can run through runtime-dispatched 4/8/16-lane camera-space and projection math.
    - [ ] **`tile_renderer.zig`**: Optimize `rasterizeTriangleToTile` to calculate barycentric coordinates for 2x2 or 4x4 pixel blocks simultaneously. This is a standard advanced technique that maps well to SIMD operations.
    - [x] **`lighting.zig`**: Vectorize the `applyIntensity` function to process 4 or 8 pixels at once. The unpack-multiply-repack sequence for RGBA colors is a perfect use case for byte-shuffling and parallel multiplication instructions.
        - [x] Benchmark-only SIMD batch implementation available in `benchmarks/src/lighting_simd.zig` for reference.
    - [x] **`renderer.zig`**: Reuse per-frame scratch buffers in the meshlet pipeline (`renderer.zig:1505-1635`). The current code re-allocates `visibility`, `job` arrays, and completion flags every frame; promote them to cached slices on `Renderer` to eliminate allocator churn.
    - [ ] **`tile_renderer.zig`**: Replace per-pixel barycentric recomputation in `rasterizeTriangleToTile` (`tile_renderer.zig:200-270`) with incremental half-space edge functions or block-based evaluation (e.g., 2×2 quads) to cut FLOPs and improve SIMD potential.
    - [x] **`renderer.zig`**: Remove per-frame atomic `resetVertexStates` (`renderer.zig:479-483`) by switching to a versioned/bitset scheme so vertices don’t require a full atomic sweep.
        - `MeshWorkCache.advanceVertexGeneration()` now advances per-frame generation tags and only falls back to a full atomic clear on generation wraparound.
    - [ ] **`renderer.zig`**: Batch `MeshWorkWriter` reservations (`renderer.zig:632-705`) to reduce atomic contention when emitting triangles—reserve chunks per meshlet or per thread.
    - [x] **`renderer.zig`**: Cache camera/light basis math (`render3DMeshWithPump`, `renderer.zig:988-1050`) to avoid recomputing sin/cos/matrix multiplies every frame.
    - [x] **`renderer.zig`**: Cache derived frame view state (camera basis vectors, `view_rotation`, projection params, and camera-space light vectors) behind dirty flags so stationary frames skip redundant trig, normalization, and matrix setup.
    - [x] **`renderer.zig`**: Reuse meshlet-task job buffers (`renderer.zig:1685-1765`) instead of allocating `MeshletTaskJob`, `Job`, and completion arrays each frame.
    - [x] **`tile_renderer.zig`**: Introduce tile “dirty flags” so untouched tiles skip color/depth clears (`TileBuffer.clear`, `tile_renderer.zig:40-48`).
    - [x] **`renderer.zig`**: Avoid full-frame `scene_depth` and `scene_camera` clears by tracking active tile spans and clearing only the regions touched by the current frame.
    - [ ] **`binning_stage.zig`**: Replace per-tile `std.ArrayList` allocations with persistent buffers and length resets to eliminate allocator churn during binning.
    - [ ] **`renderer.zig`**: Investigate pushing the back-buffer DIB directly with `SetDIBitsToDevice`/`StretchDIBits` instead of selecting into a compatible DC + `BitBlt` each frame (`drawBitmap`, `renderer.zig:1360-1390`). This removes the extra memory DC hop and cuts a GDI state change per present.
    - [ ] **`experiments/hotreload_demo`**: Build a standalone hot-reload test harness that loads multiple Zig-built shared libraries via `std.DynLib` and calls their exported functions, proving out the shared ABI + hot-swap workflow without touching the main engine.
    - [ ] **`tile_renderer.zig`**: Speed up the `compositeTileToScreen` function by using SIMD instructions to copy larger blocks of pixel data from the tile buffer to the main framebuffer.
    - [x] **`renderer.zig`**: Fuse TAA history color/depth/surface-tag fetches into a single cached lookup path so reprojected pixels do not repeat screen-to-history bounds and index work three times.
- [ ] **Job System**:
    - [ ] Implement a truly lock-free work-stealing queue to reduce contention in the job system.
    - [ ] Add job priorities to allow more important tasks to be executed first.
- [ ] **Algorithmic Optimizations**:
    - [ ] **`obj_loader.zig`**: Implement vertex deduplication. Use a hash map to cache unique `v/vt/vn` combinations and reuse vertex indices. This is critical for reducing memory usage and improving rendering speed.
    - [x] **`renderer.zig`**: Perform backface culling once before binning. Triangles that are back-facing should be culled before they are sent to the binning stage, preventing them from ever being processed by worker threads.
    - [x] **`renderer.zig`**: Reuse per-frame memory allocations. Buffers for `projected` and `transformed_vertices` should be allocated once and reused each frame to avoid allocator overhead.
    - [x] **`renderer.zig`**: Cache transformation matrices (view, projection). These matrices should only be recalculated when the camera or settings change, not every single frame.
    - [ ] Implement a more efficient rasterization algorithm, such as one based on half-space functions.
    - [ ] Use a more efficient data structure for storing the scene (e.g., a scene graph or an octree).

## Refactoring & Code Quality

- [x] **`renderer.zig`**:
    - [ ] Refactor the monolithic `render3DMeshWithPump` function into smaller, more manageable functions for each stage of the pipeline (e.g., `transformAndProject`, `binAndRasterize`, `composite`).
    - [ ] Move the camera logic out of `renderer.zig` and into a dedicated camera module.
    - [ ] Abstract the rendering backend to make it easier to switch between the direct and tiled rendering paths.
- [ ] **`input.zig`**:
    - [ ] Make the keybindings configurable, for example by loading them from a file.
    - [x] Add support for mouse input (e.g., for click-and-drag camera rotation).
- [ ] **`obj_loader.zig`**:
    - [ ] Improve error handling to provide more specific error messages.
    - [ ] Add support for loading material properties from `.mtl` files.
- [ ] **General**:
    - [ ] Replace hardcoded values with constants or configuration options from `app_config.zig`.
    - [ ] Improve the use of allocators to reduce the number of small allocations.

## Bug Fixes & Robustness

- [x] **Critical Depth Buffer Bug**: The `rasterizeTriangleToTile` function in the tiled renderer does not perform a depth buffer check before writing a pixel. This is a critical bug that results in incorrect occlusion, where triangles will be drawn over closer ones simply because they were processed later.
- [ ] **No Window Resizing Support**: The application does not handle `WM_SIZE` events. If the user resizes the window, the bitmap, depth buffer, and camera aspect ratio are not updated, leading to visual distortion.
- [ ] **Job System Mutex Bottleneck**: The job queue uses a single mutex for all operations. Under heavy contention, this lock can become a major performance bottleneck, negating the benefits of multi-threading.
- [ ] **Inefficient OBJ Vertex Handling**: The OBJ loader creates a unique vertex for every face entry, which can massively inflate the vertex count for well-formed models that reuse vertices. It should use a map to cache and reuse unique `v/vt/vn` combinations.
- [ ] **Unreliable OBJ Winding Order**: The logic to correct triangle winding order is a heuristic that can fail on complex or concave meshes, causing faces to be incorrectly lit or culled.
- [ ] **Z-Fighting**: The wireframe overlay can z-fight with the filled triangles. This could be fixed by slightly offsetting the wireframe in depth or using a proper depth bias.
- [ ] **Floating Point Instability**: The barycentric coordinate calculation in the rasterizer can lead to division by zero or `NaN` values for degenerate (zero-area) triangles, potentially causing rendering artifacts.

## Build, Tooling & Platform Support

- [ ] **Cross-Platform Support**:
    - [ ] Abstract the windowing and input handling to support Linux and macOS.
    - [ ] Create a build configuration that can target different platforms.
- [ ] **Asset Handling**:
    - [ ] Implement a more robust asset loading system that can handle different file paths and formats.
    - [ ] Add support for loading more common image formats like PNG and JPG.
- [x] **Configuration**:
    - [x] Load application settings from a configuration file (e.g., `config.json` or `config.ini`).

## Testing

- [ ] **Unit Tests**:
    - [ ] Add unit tests for the `math.zig` module to verify the correctness of vector and matrix operations.
    - [ ] Add unit tests for the `obj_loader.zig` to test parsing of different `.obj` files.
- [ ] **Integration Tests**:
    - [ ] Create a set of reference images and a testing framework to compare the renderer's output against them.

## Documentation

- [x] **Code Comments**: Add more detailed comments to complex parts of the code, such as the job system and the rasterizer.
- [ ] **API Documentation**: Generate API documentation from the source code using Zig's documentation generation tools.

## Mesh Shader Conversion Plan

### Phase 0 – Research & Tooling

- [x] **Survey Meshlet Techniques**: Document target meshlet size, vertex/primitive limits, and culling heuristics based on current scene characteristics. See `docs/meshlet_research.md`.
- [ ] **Author Meshlet Debug Visuals**: Plan how to visualize meshlets (color overlays, stats) to aid future debugging.

### Phase 1 – Offline Meshlet Generation

- [x] **Define Meshlet Data Structure**: Create a `Meshlet` struct containing a small number of vertex indices and primitive indices, along with a bounding sphere/box for culling.
- [x] **Implement Meshlet Builder**: Add an offline/loader step in `obj_loader.zig` (or a new tool) that partitions each mesh into meshlets using the target limits.
- [x] **Persist Meshlets**: Decide on in-memory vs serialized storage and update asset loading to populate meshlet arrays alongside the existing `Mesh`.
- [x] **Invalidate Legacy Cache Entries**: Bump the meshlet cache version or auto-detect single-triangle cache files so the new greedy packing replaces older one-triangle meshlets without manual intervention.

### Phase 2 – Runtime Task Stage

- [x] **Task-Level Culling**: Implement frustum and view-dependent culling that accepts a meshlet's bounds and enqueues only visible meshlets (CPU analog of a task shader).
- [ ] **Redesign Work Unit**: Replace `TileRenderJob` submissions with `MeshletRenderJob`s that own the meshlet’s vertex/primitive processing.
- [x] **Shared Vertex Cache**: Introduce a per-job scratch buffer for transformed vertices to cut redundant math across primitives inside a meshlet.
- [x] **Parallel Meshlet Submission**: Feed visible meshlets into the job system with deterministic output spans to unlock multi-core task processing.

### Phase 3 – Meshlet Processing & Output

- [ ] **Integrate Vertex Transformation**: Move the current global vertex transform loop into the meshlet job so each job transforms only its local vertices.
- [x] **Per-Meshlet Primitive Culling**: Perform backface and near-plane clipping inside the meshlet job before emission.
- [x] **Emit Screen-Space Primitives**: Design an output structure for ready-to-raster triangles (clip-space positions, UVs, shading data) produced by each meshlet job.
- [x] **Cache Expanded Attributes**: Extend meshlet outputs to include UVs, normals, and material IDs so raster stages remain mesh-agnostic.

### Phase 4 – Raster Backend Adaptation

- [x] **Rework Binning Stage**: Feed the meshlet-emitted primitives into the existing tile binning step; evaluate if a two-pass (meshlet -> tile) pipeline is needed.
- [x] **Update Rasterizer Input Path**: Allow `rasterizeTriangleToTile` (and the direct path) to consume primitives that already carry transformed data instead of pulling from global mesh arrays.
- [x] **Depth Buffer Integration**: Introduce a depth buffer so overlapping meshlets composit correctly once triangles are no longer globally ordered.
- [ ] **Meshlet→Tile Integration Plan**:
    - [ ] Refactor `BinningStage` to operate on slices so a meshlet’s triangle span can be binned independently with thread-local buffers.
    - [x] Implement `MeshletBinningJob` using the job system to bin each visible meshlet in parallel and stage per-tile contributions.
    - [x] Merge job-local tile contributions into the renderer’s shared tile lists while preserving per-meshlet culling benefits.
    - [x] Wire tile render jobs to consume the merged lists and skip untouched tiles based on meshlet activity.
    - [x] Extend `MeshWorkCache` to reuse the temporary buffers required by the new binning jobs and merge step.
    - [ ] Add debug counters/toggles to compare legacy and meshlet-driven binning paths during rollout.

### Phase 5 – Validation & Tooling

- [ ] **Meshlet Visualization**: Render debugging overlays to highlight active meshlets and their bounds during runtime.
- [x] **Performance Telemetry**: Capture per-frame counts (meshlets culled, processed, emitted triangles) to validate expected wins.
- [x] **Regression Tests**: Add targeted scenes exercising near-plane clipping, culling edges, and high triangle counts to ensure the new pipeline is stable.
- [ ] **Centralize Logging**: Migrate remaining `std.debug.print` call sites to the structured `log.zig` facility so log levels can be configured per namespace.
