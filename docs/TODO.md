# TODO List

This is a comprehensive list of potential improvements, new features, and refactoring opportunities for the Zig 3D CPU Rasterizer project.

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
    - [ ] **`math.zig`**: Vectorize all core `Vec3`, `Vec4`, and `Mat4` operations. This is the highest priority for SIMD.
        - `Mat4.multiply`: Classic 4x4 matrix multiplication is highly parallelizable.
        - `Mat4.mulVec4`: Can be optimized using 4-wide dot products.
        - `Vec3.dot`, `Vec3.cross`, `Vec3.add`, `Vec3.sub`, `Vec3.scale`.
    - [ ] **`renderer.zig`**: Vectorize the main vertex transformation loop in `render3DMeshWithPump`. This involves processing multiple vertices (e.g., 4 or 8 at a time) through the series of dot products and matrix multiplications.
    - [ ] **`tile_renderer.zig`**: Optimize `rasterizeTriangleToTile` to calculate barycentric coordinates for 2x2 or 4x4 pixel blocks simultaneously. This is a standard advanced technique that maps well to SIMD operations.
    - [ ] **`lighting.zig`**: Vectorize the `applyIntensity` function to process 4 or 8 pixels at once. The unpack-multiply-repack sequence for RGBA colors is a perfect use case for byte-shuffling and parallel multiplication instructions.
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

- [ ] **Critical Depth Buffer Bug**: The `rasterizeTriangleToTile` function in the tiled renderer does not perform a depth buffer check before writing a pixel. This is a critical bug that results in incorrect occlusion, where triangles will be drawn over closer ones simply because they were processed later.
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

## Advanced Rendering Techniques

- [ ] **Implement Ray Tracing**: Explore integrating a basic ray tracing pipeline for more realistic lighting and reflections.
- [ ] **Implement Path Tracing**: Develop a path tracing renderer for physically accurate global illumination.

## Mesh Shader Conversion Plan

### Phase 0 – Research & Tooling

- [x] **Survey Meshlet Techniques**: Document target meshlet size, vertex/primitive limits, and culling heuristics based on current scene characteristics. See `docs/meshlet_research.md`.
- [ ] **Author Meshlet Debug Visuals**: Plan how to visualize meshlets (color overlays, stats) to aid future debugging.

### Phase 1 – Offline Meshlet Generation

- [ ] **Define Meshlet Data Structure**: Create a `Meshlet` struct containing a small number of vertex indices and primitive indices, along with a bounding sphere/box for culling.
- [ ] **Implement Meshlet Builder**: Add an offline/loader step in `obj_loader.zig` (or a new tool) that partitions each mesh into meshlets using the target limits.
- [ ] **Persist Meshlets**: Decide on in-memory vs serialized storage and update asset loading to populate meshlet arrays alongside the existing `Mesh`.

### Phase 2 – Runtime Task Stage

- [ ] **Task-Level Culling**: Implement frustum and view-dependent culling that accepts a meshlet's bounds and enqueues only visible meshlets (CPU analog of a task shader).
- [ ] **Redesign Work Unit**: Replace `TileRenderJob` submissions with `MeshletRenderJob`s that own the meshlet’s vertex/primitive processing.
- [ ] **Shared Vertex Cache**: Introduce a per-job scratch buffer for transformed vertices to cut redundant math across primitives inside a meshlet.

### Phase 3 – Meshlet Processing & Output

- [ ] **Integrate Vertex Transformation**: Move the current global vertex transform loop into the meshlet job so each job transforms only its local vertices.
- [ ] **Per-Meshlet Primitive Culling**: Perform backface and near-plane clipping inside the meshlet job before emission.
- [ ] **Emit Screen-Space Primitives**: Design an output structure for ready-to-raster triangles (clip-space positions, UVs, shading data) produced by each meshlet job.

### Phase 4 – Raster Backend Adaptation

- [ ] **Rework Binning Stage**: Feed the meshlet-emitted primitives into the existing tile binning step; evaluate if a two-pass (meshlet -> tile) pipeline is needed.
- [ ] **Update Rasterizer Input Path**: Allow `rasterizeTriangleToTile` (and the direct path) to consume primitives that already carry transformed data instead of pulling from global mesh arrays.
- [ ] **Depth Buffer Integration**: Introduce a depth buffer so overlapping meshlets composit correctly once triangles are no longer globally ordered.

### Phase 5 – Validation & Tooling

- [ ] **Meshlet Visualization**: Render debugging overlays to highlight active meshlets and their bounds during runtime.
- [ ] **Performance Telemetry**: Capture per-frame counts (meshlets culled, processed, emitted triangles) to validate expected wins.
- [ ] **Regression Tests**: Add targeted scenes exercising near-plane clipping, culling edges, and high triangle counts to ensure the new pipeline is stable.