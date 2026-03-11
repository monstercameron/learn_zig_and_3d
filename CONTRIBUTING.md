# Contributing

## Scope

This repository is an active renderer and systems playground. Keep changes small, reviewable, and easy to validate locally.

## Ground Rules

- Preserve the current source layout under `src/` unless a refactor clearly improves ownership or build flow.
- Avoid mixing cleanup, feature work, and benchmark tuning in a single change.
- Do not commit generated artifacts, local caches, or profiling output.
- Keep Windows as the primary supported runtime unless a change explicitly broadens platform support.

## Typical Workflow

```powershell
zig build validate
zig build check
zig build run
zig build run -Doptimize=ReleaseFast
```

`zig build validate` is the repo-wide baseline for the renderer, benchmarks, and hot reload demo. Run the MP3 experiment separately when you are specifically working in that area.

If you touch profiling-sensitive code, also validate with:

```powershell
zig build -Doptimize=ReleaseFast -Dprofile=true
```

## Repo Areas

- `src/`: engine and renderer implementation
- `assets/`: runtime assets and configuration
- `docs/`: design notes, specs, profiling, and roadmap material
- `benchmarks/`: focused performance experiments
- `experiments/`: isolated prototypes that should not silently change main-app behavior
- `tools/`: development scripts and profiling helpers

## Documentation Expectations

- Update the root `README.md` when the public entry points or build commands change.
- Update `docs/README.md` when adding a new design note or spec.
- Add or update folder-level README files when a subproject gains new setup steps.
- Prefer `zig build validate` before larger repo-wide changes or cleanup commits.

## Style

- Follow the existing Zig style in nearby files.
- Prefer focused comments over broad narrative comments.
- Keep public names and module boundaries stable unless the refactor requires a breaking change.