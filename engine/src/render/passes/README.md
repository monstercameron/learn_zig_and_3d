# Render Passes

Each standalone renderer feature should live in this folder as a dedicated pass module.

Conventions:
- file name: `<feature>_pass.zig`
- one pass per file
- pass orchestration only (job splitting, scratch routing, timing labels)
- pixel/row algorithms belong in `../kernels/`

Ownership model:
- pass file owns call ordering for its feature
- kernel file owns row/pixel math for its feature
- `renderer.zig` should orchestrate passes, not hold feature algorithms
