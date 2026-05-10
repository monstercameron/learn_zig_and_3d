# Todos

## Primitive Bring-Up

- [x] Route frame execution through the direct backend for the current bring-up path.
- [x] Disable post-processing on the direct bring-up path so the flat test image is not overwritten.
- [x] Implement a minimal direct renderer that clears the backbuffer every frame.
- [x] Render a minimal primitive showcase with line, triangle, polygon, and circle primitives.
- [x] Clear direct-path depth, normal, camera, and surface buffers to deterministic values.
- [x] Move direct primitive drawing into reusable render modules outside `engine/src/render/renderer.zig`.
- [x] Introduce a typed direct draw-list that can become the future submission layer for tiling and jobs.

## Direct Renderer Next

- [ ] Introduce a `PrimitiveBatch` or `DrawPacket` layer above the current draw list so scene submission is decoupled from raw primitive commands.
- [ ] Add per-primitive transform/color state so submission is not limited to pre-baked screen-space shapes.
- [ ] Support polyline and rectangle primitives through the same draw-list interface.
- [ ] Feed the direct path from a typed test mesh instead of ignoring the current `Mesh` input.
- [ ] Write depth for the direct path consistently, not just a flat placeholder value.
- [ ] Populate `scene_camera`, `scene_normal`, and `scene_surface` correctly for direct-path pixels.
- [ ] Add direct-path unit coverage that verifies each showcase primitive lands in expected pixels.
- [ ] Add a runtime toggle between `direct` and `tiled` backends instead of forcing direct in renderer init.
- [ ] Add a tiling-friendly screen binning step that consumes the draw list without changing primitive APIs.

## Present And Windowing

- [ ] Handle window resize by rebuilding any direct-path assumptions tied to backbuffer size.
- [ ] Add a visible `direct backend active` overlay line during bring-up.
- [ ] Verify minimize/restore behavior does not leave stale backbuffer contents.
- [ ] Verify pacing and present still behave correctly with the direct path forced on.

## Renderer Architecture

- [x] Move the temporary direct primitive raster composition out of `engine/src/render/renderer.zig`.
- [ ] Add a dedicated direct backend module under `engine/src/render/backends`.
- [ ] Define a minimal direct backend interface that accepts a typed list of screen-space or clip-space primitives.
- [ ] Split the current direct path into `submission`, `binning`, `raster`, and `present` modules before adding job-based scaling.
- [ ] Decide whether the direct backend will become a real supported path or remain a bring-up/debug backend.
- [ ] If it remains debug-only, make that explicit in config and documentation.

## Scene Integration

- [x] Add a startup/demo mode that requests a direct primitive showcase intentionally rather than piggybacking on the main scene flow.
- [ ] Add a matching simple quad path after the primitive path is stable.
- [ ] Add a flat-color material path for direct-render test primitives.
- [ ] Add an orthographic camera test mode for 2D-style bring-up.

## Validation

- [ ] Capture a screenshot artifact of the primitive showcase for regression comparison.
- [ ] Add a test that verifies post-processing stays disabled on the forced direct path.
- [ ] Add a test that switching back to tiled restores post-processing and previous frame-plan behavior.
- [ ] Review the direct backend again after the first real mesh render to remove temporary shortcuts.
