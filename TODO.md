# TODO List

This is a comprehensive list of potential improvements, new features, and refactoring opportunities for the Zig 3D CPU Rasterizer project.

## Mesh Shader Follow-Up (High Priority)

- [x] Generate meshlets for loaded meshes (partition triangles, compute vertex remapping, populate bounding spheres).
- [x] Reuse cached per-meshlet vertex transforms to avoid reprojecting untouched geometry each frame.
- [x] Tighten tile binning to scan only the intersecting tile range derived from triangle bounds.
- [x] Extend benchmarking harnesses to exercise meshlet-enabled pipelines and capture mesh shader metrics.
- [x] Cache per-triangle camera and screen-space vertices so raster stages can bypass mesh lookups.
- [x] Parallelize meshlet task emission by dispatching meshlet jobs through the job system.
- [ ] Persist meshlet work buffers across frames with fine-grained invalidation to avoid rebuilds.
- [ ] Add runtime telemetry (meshlets culled/processed, triangles emitted) to validate task-stage performance.

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
    - [ ] Integrate `dr_mp3` C library for `loadMp3` functionality.
- [ ] **Phase 4: Public API Implementation**
    - [ ] Connect the public `audio.zig` functions to the backend and mixer.
    - [ ] Implement thread-safe command passing for playback control (play, stop, setVolume, etc.).

## Rendering Features

- [ ] **Shading Models**:
    - [ ] Implement Gouraud shading (per-vertex lighting).
    - [ ] Implement Phong shading (per-pixel lighting).
    - [ ] Implement Blinn-Phong shading for more realistic specular highlights.
- [ ] **Lighting**:
    - [ ] Add support for multiple light sources.
    - [ ] Implement different light types (e.g., point lights, spot lights).
    - [ ] Add support for specular highlights.
    - [ ] Implement attenuation for point and spot lights.
- [ ] **Texturing**:
    - [ ] Implement bilinear texture filtering for smoother textures.
    - [ ] Implement trilinear texture filtering.
    - [ ] Add support for mipmapping to reduce aliasing on distant objects.
    - [ ] Implement anisotropic filtering for improved texture quality on surfaces at an angle.
- [ ] **Transparency**:
    - [ ] Add support for alpha blending for transparent objects.
    - [ ] Implement a sorting mechanism for transparent objects to render them correctly.
- [ ] **Camera**:
    - [ ] Create a dedicated camera struct to manage view and projection matrices.
    - [ ] Implement a "look-at" function for the camera.
    - [ ] Add support for orthographic projection.
- [ ] **Clipping**:
    - [ ] Implement near-plane clipping to correctly handle geometry that is partially behind the camera.
    - [ ] Implement frustum culling to discard objects that are entirely outside the camera's view.
- [ ] **UI & Debugging**:
    - [ ] Add an immediate-mode GUI (e.g., using Dear ImGui) to control rendering options in real-time.
    - [ ] Render the light source as a 3D sphere instead of a 2D circle.
    - [ ] Add a skybox or skydome for a more interesting background.

## Performance Optimizations

- [ ] **SIMD Vectorization Candidates**:
    - [ ] **`math.zig`**: Vectorize all core `Vec2`, `Vec3`, `Vec4`, and `Mat4` operations. This is the highest priority for SIMD.
        - `Vec2.add`, `Vec2.sub`, `Vec2.scale`.
        - `Vec3.add`, `Vec3.sub`, `Vec3.scale`, `Vec3.dot`, `Vec3.cross`.
        - `Mat4.multiply`: Classic 4x4 matrix multiplication is highly parallelizable.
        - `Mat4.mulVec4`: Can be optimized using 4-wide dot products.
        - [x] Prototype SIMD implementations in benchmarks (`benchmarks/src/math_copy.zig`, `math_simd.zig`, `math_simd_optimized.zig`) for validation.
    - [ ] **`renderer.zig`**: Vectorize the main vertex transformation loop in `render3DMeshWithPump`. This involves processing multiple vertices (e.g., 4 or 8 at a time) through the series of dot products and matrix multiplications.
    - [ ] **`tile_renderer.zig`**: Optimize `rasterizeTriangleToTile` to calculate barycentric coordinates for 2x2 or 4x4 pixel blocks simultaneously. This is a standard advanced technique that maps well to SIMD operations.
    - [ ] **`lighting.zig`**: Vectorize the `applyIntensity` function to process 4 or 8 pixels at once. The unpack-multiply-repack sequence for RGBA colors is a perfect use case for byte-shuffling and parallel multiplication instructions.
        - [x] Benchmark-only SIMD batch implementation available in `benchmarks/src/lighting_simd.zig` for reference.
    - [ ] **`renderer.zig`**: Reuse per-frame scratch buffers in the meshlet pipeline (`renderer.zig:1505-1635`). The current code re-allocates `visibility`, `job` arrays, and completion flags every frame; promote them to cached slices on `Renderer` to eliminate allocator churn.
    - [ ] **`tile_renderer.zig`**: Replace per-pixel barycentric recomputation in `rasterizeTriangleToTile` (`tile_renderer.zig:200-270`) with incremental half-space edge functions or block-based evaluation (e.g., 2×2 quads) to cut FLOPs and improve SIMD potential.
    - [ ] **`renderer.zig`**: Remove per-frame atomic `resetVertexStates` (`renderer.zig:479-483`) by switching to a versioned/bitset scheme so vertices don’t require a full atomic sweep.
    - [ ] **`renderer.zig`**: Batch `MeshWorkWriter` reservations (`renderer.zig:632-705`) to reduce atomic contention when emitting triangles—reserve chunks per meshlet or per thread.
    - [ ] **`renderer.zig`**: Cache camera/light basis math (`render3DMeshWithPump`, `renderer.zig:988-1050`) to avoid recomputing sin/cos/matrix multiplies every frame.
    - [ ] **`renderer.zig`**: Reuse meshlet-task job buffers (`renderer.zig:1685-1765`) instead of allocating `MeshletTaskJob`, `Job`, and completion arrays each frame.
    - [ ] **`tile_renderer.zig`**: Introduce tile “dirty flags” so untouched tiles skip color/depth clears (`TileBuffer.clear`, `tile_renderer.zig:40-48`).
    - [ ] **`binning_stage.zig`**: Replace per-tile `std.ArrayList` allocations with persistent buffers and length resets to eliminate allocator churn during binning.
    - [ ] **`renderer.zig`**: Investigate pushing the back-buffer DIB directly with `SetDIBitsToDevice`/`StretchDIBits` instead of selecting into a compatible DC + `BitBlt` each frame (`drawBitmap`, `renderer.zig:1360-1390`). This removes the extra memory DC hop and cuts a GDI state change per present.
    - [ ] **`tile_renderer.zig`**: Speed up the `compositeTileToScreen` function by using SIMD instructions to copy larger blocks of pixel data from the tile buffer to the main framebuffer.
- [ ] **Job System**:
    - [ ] Implement a truly lock-free work-stealing queue to reduce contention in the job system.
    - [ ] Add job priorities to allow more important tasks to be executed first.
- [ ] **Algorithmic Optimizations**:
    - [ ] **`obj_loader.zig`**: Implement vertex deduplication. Use a hash map to cache unique `v/vt/vn` combinations and reuse vertex indices. This is critical for reducing memory usage and improving rendering speed.
    - [ ] **`renderer.zig`**: Perform backface culling once before binning. Triangles that are back-facing should be culled before they are sent to the binning stage, preventing them from ever being processed by worker threads.
    - [ ] **`renderer.zig`**: Reuse per-frame memory allocations. Buffers for `projected` and `transformed_vertices` should be allocated once and reused each frame to avoid allocator overhead.
    - [ ] **`renderer.zig`**: Cache transformation matrices (view, projection). These matrices should only be recalculated when the camera or settings change, not every single frame.
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

### Phase 2 – Runtime Task Stage

- [x] **Task-Level Culling**: Implement frustum and view-dependent culling that accepts a meshlet's bounds and enqueues only visible meshlets (CPU analog of a task shader).
- [ ] **Redesign Work Unit**: Replace `TileRenderJob` submissions with `MeshletRenderJob`s that own the meshlet’s vertex/primitive processing.
- [ ] **Shared Vertex Cache**: Introduce a per-job scratch buffer for transformed vertices to cut redundant math across primitives inside a meshlet.
- [x] **Parallel Meshlet Submission**: Feed visible meshlets into the job system with deterministic output spans to unlock multi-core task processing.

### Phase 3 – Meshlet Processing & Output

- [ ] **Integrate Vertex Transformation**: Move the current global vertex transform loop into the meshlet job so each job transforms only its local vertices.
- [x] **Per-Meshlet Primitive Culling**: Perform backface and near-plane clipping inside the meshlet job before emission.
- [x] **Emit Screen-Space Primitives**: Design an output structure for ready-to-raster triangles (clip-space positions, UVs, shading data) produced by each meshlet job.
- [x] **Cache Expanded Attributes**: Extend meshlet outputs to include UVs, normals, and material IDs so raster stages remain mesh-agnostic.

### Phase 4 – Raster Backend Adaptation

- [ ] **Rework Binning Stage**: Feed the meshlet-emitted primitives into the existing tile binning step; evaluate if a two-pass (meshlet -> tile) pipeline is needed.
- [ ] **Update Rasterizer Input Path**: Allow `rasterizeTriangleToTile` (and the direct path) to consume primitives that already carry transformed data instead of pulling from global mesh arrays.
- [ ] **Depth Buffer Integration**: Introduce a depth buffer so overlapping meshlets composit correctly once triangles are no longer globally ordered.

### Phase 5 – Validation & Tooling

- [ ] **Meshlet Visualization**: Render debugging overlays to highlight active meshlets and their bounds during runtime.
- [ ] **Performance Telemetry**: Capture per-frame counts (meshlets culled, processed, emitted triangles) to validate expected wins.
- [ ] **Regression Tests**: Add targeted scenes exercising near-plane clipping, culling edges, and high triangle counts to ensure the new pipeline is stable.
