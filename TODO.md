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

- [ ] **SIMD**:
    - [ ] Use SIMD instructions to accelerate vector and matrix operations in `math.zig`.
    - [ ] Use SIMD to speed up pixel processing in the rasterization and compositing stages.
- [ ] **Job System**:
    - [ ] Implement a truly lock-free work-stealing queue to reduce contention in the job system.
    - [ ] Add job priorities to allow more important tasks to be executed first.
- [ ] **Algorithmic Optimizations**:
    - [ ] Implement a more efficient rasterization algorithm, such as one based on half-space functions.
    - [ ] Optimize the `obj_loader` for faster parsing of large files.
    - [ ] Use a more efficient data structure for storing the scene (e.g., a scene graph or an octree).

## Refactoring & Code Quality

- [ ] **`renderer.zig`**:
    - [ ] Refactor the monolithic `render3DMeshWithPump` function into smaller, more manageable functions for each stage of the pipeline (e.g., `transformAndProject`, `binAndRasterize`, `composite`).
    - [ ] Move the camera logic out of `renderer.zig` and into a dedicated camera module.
    - [ ] Abstract the rendering backend to make it easier to switch between the direct and tiled rendering paths.
- [ ] **`input.zig`**:
    - [ ] Make the keybindings configurable, for example by loading them from a file.
    - [ ] Add support for mouse input (e.g., for click-and-drag camera rotation).
- [ ] **`obj_loader.zig`**:
    - [ ] Improve error handling to provide more specific error messages.
    - [ ] Add support for loading material properties from `.mtl` files.
- [ ] **General**:
    - [ ] Replace hardcoded values with constants or configuration options from `app_config.zig`.
    - [ ] Improve the use of allocators to reduce the number of small allocations.

## Bug Fixes & Robustness

- [ ] **Depth Buffer**: The depth buffer is not correctly used for Z-testing in the tiled renderer. This needs to be fixed to ensure correct rendering of overlapping objects.
- [ ] **Z-Fighting**: The wireframe overlay can z-fight with the filled triangles. This could be fixed by slightly offsetting the wireframe in depth.
- [ ] **Window Resizing**: The application does not currently handle window resizing. The renderer and bitmap should be updated when the window size changes.
- [ ] **OBJ Loader**: The OBJ loader does not handle all variations of the format (e.g., negative indices). It should be made more robust.

## Build, Tooling & Platform Support

- [ ] **Cross-Platform Support**:
    - [ ] Abstract the windowing and input handling to support Linux and macOS.
    - [ ] Create a build configuration that can target different platforms.
- [ ] **Asset Handling**:
    - [ ] Implement a more robust asset loading system that can handle different file paths and formats.
    - [ ] Add support for loading more common image formats like PNG and JPG.
- [ ] **Configuration**:
    - [ ] Load application settings from a configuration file (e.g., `config.json` or `config.ini`).

## Testing

- [ ] **Unit Tests**:
    - [ ] Add unit tests for the `math.zig` module to verify the correctness of vector and matrix operations.
    - [ ] Add unit tests for the `obj_loader.zig` to test parsing of different `.obj` files.
- [ ] **Integration Tests**:
    - [ ] Create a set of reference images and a testing framework to compare the renderer's output against them.

## Documentation

- [ ] **Code Comments**: Add more detailed comments to complex parts of the code, such as the job system and the rasterizer.
- [ ] **API Documentation**: Generate API documentation from the source code using Zig's documentation generation tools.