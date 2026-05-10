# Project Roadmap

This is the master plan for `learn_zig_and_3d`. It supersedes `CODEX_TODO.md` (migration phases, mostly complete) and `todos.md` (direct-renderer bring-up, mostly complete) and `docs/project-roadmap.md` (older notes). Those are kept for historical reference but should not be added to.

## North Star

A **playable game-like demo** powered by this CPU rasterizer, used as a **stable, reproducible benchmark workload** for comparing CPU SIMD ISAs:

| ISA | Status |
| --- | --- |
| Scalar | baseline |
| SSE2 | implemented |
| AVX2 | implemented |
| AVX-512 | TODO |
| NEON (ARM) | TODO |
| SVE / SVE2 (ARM) | TODO |

The game's job is to provide a **deterministic, content-rich workload** — varied geometry, lighting, post-processing, animation. It does not need to be fun. It needs to render the same frames every time given the same input log.

The benchmark's job is to produce a **publishable cross-ISA performance comparison**: per-frame stage timings, per-kernel speedup tables, frame-time histograms across architectures.

## Hardware reality check

The current dev box is Windows + AVX2 (no AVX-512, no NEON). Cross-ISA measurement needs:

- **AVX-512**: Intel 12th-gen+ or AMD Zen 4+ — desktop CPU, or cloud VM (Hetzner CCX, AWS C7i, Azure Dadsv5)
- **NEON**: Apple Silicon Mac, AWS Graviton, or Raspberry Pi 4/5
- **SVE / SVE2**: AWS Graviton 3+, or Apple M4 (limited SME); QEMU works for correctness but not perf

Not blockers — develop on x86_64 + AVX2, run measurement passes elsewhere.

## Phase A — Game (the workload)

Scope: a deterministic, repeatable scene that exercises raster + lighting + post-processing.

- [ ] Pick the game shape — recommendation: top-down arena shooter (fixed map, scripted enemy spawns, deterministic physics). Alternatives: marble run, baked-light first-person walkthrough.
- [ ] Define the canonical benchmark scene: locked triangle count, light count, post-pass set
- [ ] Deterministic input record/replay: `--record session.bin` and `--replay session.bin`. Same input + same seed → bit-identical frames.
- [ ] Decouple physics tick from frame rate (fixed dt + accumulator) so the workload stays identical regardless of which SIMD path is rendering it
- [ ] Per-frame game-state hash — regression check that all SIMD paths produce the same simulation, not just visually-similar frames

## Phase B — SIMD coverage (the measurement axis)

Scope: every hot kernel implemented across every target ISA.

- [ ] Audit existing dispatch — which kernels have which paths today (matrix kernel × ISA)
- [ ] AVX-512 path for hot kernels (raster edge functions, tile binning, gouraud setup, post-process row kernels)
- [ ] NEON path (ARM equivalent of AVX2 — Apple Silicon native)
- [ ] SVE / SVE2 path — variable vector width, the most interesting research dimension since it's not a fixed lane count
- [ ] Runtime override: env var or CLI flag to force scalar / SSE2 / AVX2 / AVX-512 / NEON / SVE for like-for-like measurement on the same hardware
- [ ] Frame-output equivalence test — every path renders the same scene to the same pixels (within tolerance) before comparing perf

## Phase C — Cross-platform build

- [ ] Linux x86_64 build (needed for AVX-512 cloud-VM runs)
- [ ] macOS ARM64 build (Apple Silicon NEON native)
- [ ] Linux ARM64 build (Graviton, Raspberry Pi)
- [ ] CI matrix building all four per commit (GitHub Actions has Linux ARM and Apple Silicon runners)

## Phase D — Benchmark harness

- [ ] Headless run mode — no window, render to memory buffer, optionally dump frames to disk
- [ ] Per-frame CSV export with stage breakdown: clear / build / compile / bin / raster / shade / post / present
- [ ] Build label baked into output: `arch=x86_64 isa=avx512 build=release frame_count=...`
- [ ] Multi-run aggregator: N runs, compute median / p95 / p99 (single-run numbers lie)
- [ ] `zig build bench` step that runs the canonical scene once and dumps the CSV

## Phase E — Hot-path identification (drives Phase B priority)

- [ ] Profile the canonical workload on AVX2 baseline; rank top-10 functions by self-time
- [ ] Build a coverage matrix: kernel × ISA → has-implementation? Drives the Phase B priority queue.
- [ ] Classify each top-10 kernel: SIMD-bound, memory-bound, or branchy — only SIMD-bound kernels gain from wider lanes

## Phase F — Reporting (the final artifact)

- [ ] Per-architecture results table: scalar / SSE2 / AVX2 / AVX-512 / NEON / SVE side-by-side on the same scene
- [ ] Per-kernel speedup table — which kernels benefit most from each ISA. This is the actually-interesting result.
- [ ] Frame-time histograms — wider SIMD often improves average more than worst-case
- [ ] Writeup: blog post or `docs/benchmark-results.md` with results + interpretation

## Phase G — Engine debt that distorts measurements

These are supportive, not blocking, but landing them sharpens every measurement.

- [ ] **`renderer.zig` split** (deferred from cleanup) — without it, perf attribution is per-7800-line-blob, not per-subsystem. High priority for clean numbers.
- [ ] **MeshWork zombie sweep** (deferred from cleanup) — dead code in raster path could distort branch prediction / icache behavior
- [ ] **`direct/primitives.zig` split** (deferred from cleanup) — sharper hotspot boundaries in profiles

## Critical-path ordering

```
G (debt) ──┐
           ├─→ E (hot-path ID) ──→ B (SIMD coverage) ──→ F (reporting)
A (game) ──┴─→ D (harness) ───────┘                        ↑
                                                            │
C (cross-platform) ─────────────────────────────────────────┘
```

## Practical first 4 steps

1. **A1** — pick the game shape (one decision, unblocks the rest)
2. **D1** — headless run mode (lets you measure without a window, simplifies everything else)
3. **A3** — record/replay (foundation for *every* measurement)
4. **G1** — `renderer.zig` split (so profiles attribute time to subsystems, not one blob)

## Out of scope

- Becoming a real game engine, level editor, or asset pipeline beyond what the benchmark scene needs
- Vulkan/D3D12/Metal GPU backends — the project is CPU-first by design
- Beating Mesa swiftshader / lavapipe at their own game — those are Vulkan front-ends, different target
- Networking, multiplayer, UI frameworks
