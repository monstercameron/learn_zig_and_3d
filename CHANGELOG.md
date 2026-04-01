# Changelog

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

### Known Limits

- the direct raster backend is still a stub in `engine/src/render/renderer.zig`
- stage and pass implementations still live primarily in `renderer.zig`; only orchestration has been extracted so far
