# Hotspot Snapshot Template

- generated_at:
- baseline_scene_id:
- baseline_frame_id:
- post_scene_id:
- post_frame_id:
- input_trace:
- copied_trace:
- engine_ini_sha256:
- render_passes_sha256:

## Required Capture IDs

- baseline: `<scene_id>@<frame_id>`
- post-change: `<scene_id>@<frame_id>`

## Focus Zones

| name | count | total_ms | p50_us | p90_us | p99_us | max_us | p99_over_p50 | max_over_p50 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| renderTileJob |  |  |  |  |  |  |  |  |
| meshletShadowTile |  |  |  |  |  |  |  |  |
| meshletShadowTrace |  |  |  |  |  |  |  |  |
| meshletShadowApply |  |  |  |  |  |  |  |  |

## Top Zones

| name | count | total_ms | avg_us | p50_us | p90_us | p99_us | max_us | share_pct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
|  |  |  |  |  |  |  |  |  |

## Before vs After

| zone | before_total_ms | after_total_ms | delta_ms | delta_pct |
|---|---:|---:|---:|---:|
| renderTileJob |  |  |  |  |
| meshletShadowTile |  |  |  |  |
| meshletShadowTrace |  |  |  |  |
| meshletShadowApply |  |  |  |  |

## Notes

- scene/config constraints:
- visual parity result:
- risk or caveats:
