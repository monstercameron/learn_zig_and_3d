# Project Roadmap

This document is the active backlog only. Completed work has been removed so the roadmap stays useful as a planning surface instead of turning into a changelog.

## Meshlet Pipeline

- [ ] Improve offline meshlet clustering so the builder accounts for shared-vertex reuse, spatial locality, and tighter grouping quality.
- [ ] Batch meshlet triangle reservations to reduce shared-output contention during emission.
- [ ] Reduce the cost of the meshlet-to-tile merge step so binning scales better with meshlet job parallelism.
- [ ] Promote meshlets to the primary render work unit instead of adapting them back into the older triangle-centric path.
- [ ] Add tighter meshlet bounds such as AABBs for elongated clusters that cull poorly with spheres alone.
- [ ] Investigate depth-aware meshlet ordering once scene complexity is high enough for front-to-back scheduling to matter.
- [ ] Add meshlet debug overlays and rollout toggles so active meshlets, bounds, and legacy-vs-meshlet binning can be compared in runtime builds.
- [ ] Refactor BinningStage to operate on slices so meshlet triangle spans can be binned independently with thread-local buffers.

## Audio

- [ ] Port the MP3 decoder path to pure Zig instead of relying on dr_mp3.

## Rendering Features

- [ ] Add additional shading models such as Gouraud and classic Phong where they still offer useful comparisons or debug views.
- [ ] Expand lighting beyond the current single-light-oriented path with additional light types and attenuation.
- [ ] Add higher-quality texture filtering follow-ups such as trilinear and anisotropic filtering.
- [ ] Finish transparent rendering by adding correct ordering for alpha-blended objects.
- [ ] Split camera behavior into a dedicated camera module and add a proper look-at helper.
- [ ] Add a lightweight runtime UI for render/debug controls.
- [ ] Render a proper 3D light proxy instead of the current simpler debug representation.

## Performance

- [ ] Re-evaluate AVX-512 paths against AVX2 on real hardware and keep only the variants that produce measurable wins.
- [ ] Vectorize the remaining hot math paths in math.zig, prioritizing batched callers instead of isolated scalar helpers.
- [ ] Finish SIMD-oriented vertex transform work for the non-meshlet main path.
- [ ] Replace per-pixel barycentric recomputation in tile_renderer.zig with incremental or block-based evaluation.
- [ ] Batch MeshWorkWriter reservations to reduce atomic contention.
- [ ] Replace per-tile std.ArrayList churn in binning_stage.zig with persistent buffers.
- [ ] Investigate a more direct present path than the current compatible-DC plus BitBlt flow.
- [ ] Build a standalone hot-reload validation harness for experiments/hotreload_demo.
- [ ] Speed up tile compositing with wider pixel copy batches.
- [ ] Revisit the job-system queue design if contention becomes a dominant frame cost.
- [ ] Add a more efficient scene data structure once the current content set outgrows the flat approach.

## Refactoring And Robustness

- [ ] Break up render3DMeshWithPump into clearer pipeline stages.
- [ ] Make keybindings configurable.
- [ ] Improve OBJ loader diagnostics and add .mtl material loading.
- [ ] Continue replacing hardcoded values with config-driven or data-driven settings where it meaningfully improves iteration.
- [ ] Reduce small allocation churn in remaining hot paths.
- [ ] Add proper window resize handling.
- [ ] Replace the job-system mutex bottleneck with a lower-contention design if profiling justifies it.
- [ ] Implement OBJ vertex deduplication so shared v/vt/vn combinations stop inflating mesh data.
- [ ] Revisit OBJ winding correction for complex meshes.
- [ ] Add a proper depth bias path for wireframe overlays.
- [ ] Harden raster edge cases further where floating-point instability can still leak through.
- [ ] Centralize remaining std.debug.print usage behind log.zig.

## Platform, Testing, And Docs

- [ ] Abstract windowing/input enough to make future Linux and macOS support practical.
- [ ] Broaden asset loading beyond the current formats when that work becomes necessary.
- [ ] Expand unit coverage for math and asset loading.
- [ ] Add integration-style image regression coverage for renderer output.
- [ ] Generate API documentation from the Zig sources.
