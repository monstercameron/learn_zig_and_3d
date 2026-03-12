# Scene Authoring Rework

## Current State

The project is in a hybrid state.

- Scene JSON parsing is already owned by the ECS-side loader in `engine/src/scene/loader.zig`.
- ECS bootstrap is real: parsed camera, lights, assets, residency metadata, authored ids, and script attachments are loaded into `SceneRuntime`.
- Render extraction is ECS-native.
- Selection and residency updates now track ECS entities.

What is still old:

- Mesh assets are still merged into one big runtime mesh for the old render/selection/physics path.
- `engine/src/main.zig` still owns the compatibility mesh bridge and scene-item binding layer that feeds the current single-mesh renderer.

So the accurate answer is:

- We are using the new ECS scene loader as the authoring/parser entry point.
- We are using the new ECS scene runtime for execution, physics, selection identity, and transform authority.
- The remaining old system is now mostly a compatibility bridge, not the source of truth for authoring.

## Why The Current Scene Files Will Not Scale Well

The current `assets/configs/scenes/*.scene.json` format is flat and type-switched.

Problems:

- All entities live in one `assets` array with `type = model|camera|light|runtime|hdri`.
- Hierarchy is not first-class.
- Dependencies are implicit rather than authored.
- Scripts are attached, but module declarations and parameters are not first-class.
- Streaming zones/cells are not authorable.
- Reusing repeated groups requires copying blocks instead of composition.
- Scene-level metadata, entity graph, resources, and gameplay logic are mixed together.

For small test scenes this is acceptable. For larger worlds it becomes brittle.

## Recommended Direction

Move to a scene package model instead of one flat scene file.

Recommended layout:

```text
assets/
  scenes/
    registry.json
    shadow_tuning/
      scene.json
      entities/
        world_root.entity.json
        camera_main.entity.json
        key_light.entity.json
        pillar_a.entity.json
      prefabs/
        column_stack.prefab.json
      scripts/
        modules.json
      streaming/
        cells.json
        groups.json
      overrides/
        debug.json
```

This separates concerns:

- `registry.json`: top-level launchable scene registry.
- `scene.json`: scene metadata, imports, root entities, active profile.
- `entities/*.entity.json`: one entity per file for composability and source control.
- `prefabs/*.prefab.json`: reusable authored entity graphs.
- `scripts/modules.json`: scene-local script module declarations and bindings.
- `streaming/*.json`: residency groups, cell overrides, streaming hints.
- `overrides/*.json`: optional environment-specific or debug-only overrides.

## Recommended Top-Level Scene Schema

Example `scene.json`:

```json
{
  "id": "shadow_tuning",
  "version": 2,
  "displayName": "Shadow Tuning",
  "runtimeProfile": "static",
  "environment": {
    "hdri": null,
    "loadingScene": "loading_neutral"
  },
  "roots": [
    "entities/world_root.entity.json",
    "entities/camera_main.entity.json"
  ],
  "imports": [],
  "streaming": {
    "worldBounds": {
      "min": [-64.0, -32.0, -64.0],
      "max": [64.0, 32.0, 64.0]
    },
    "defaultPolicy": {
      "activeRadius": 48.0,
      "prefetchRadius": 96.0,
      "offloadDelayFrames": 30
    }
  }
}
```

Key changes:

- `version` allows schema migration.
- `roots` makes hierarchy explicit.
- `imports` allows composition across scene packages.
- `streaming` moves residency policy to scene-level defaults.

## Recommended Entity Schema

Example `entities/pillar_a.entity.json`:

```json
{
  "id": "pillar.a",
  "name": "Pillar A",
  "parent": "world.root",
  "enabled": true,
  "transform": {
    "position": [-8.0, 0.55, -0.5],
    "rotationDeg": [0.0, 0.0, 0.0],
    "scale": [0.9, 1.1, 0.9]
  },
  "components": {
    "renderable": {
      "mesh": "models/box.obj",
      "material": {
        "textures": []
      },
      "castsShadows": true
    },
    "physicsBody": {
      "motion": "static"
    },
    "selectable": {},
    "streamable": {
      "policy": "proximity",
      "group": "main_set"
    }
  },
  "scripts": [],
  "children": []
}
```

This is the main shift:

- Stop encoding entity kind by `type` at the array level.
- Make each entity a normal node with components.
- Camera, light, mesh, trigger, script host, and physics body are just component sets.

## Recommended Prefab Schema

Example `prefabs/column_stack.prefab.json`:

```json
{
  "id": "prefab.column_stack",
  "entities": [
    "column_base.entity.json",
    "column_mid.entity.json",
    "column_top.entity.json"
  ]
}
```

Then scene roots can instantiate prefabs with overrides.

Example usage:

```json
{
  "prefab": "prefabs/column_stack.prefab.json",
  "instanceId": "stack.left",
  "parent": "world.root",
  "transformOverride": {
    "position": [-6.0, 0.0, 2.0]
  }
}
```

This removes copy-pasted repeated authoring blocks.

## Recommended Script Authoring Model

Current attached scripts are only module names. That is a good first step, but it should evolve into explicit declarations and per-instance config.

Recommended `scripts/modules.json`:

```json
{
  "modules": [
    {
      "id": "builtin.noop",
      "kind": "native"
    },
    {
      "id": "game.rotate_light",
      "kind": "native"
    }
  ]
}
```

Recommended entity-side attachment:

```json
{
  "scripts": [
    {
      "module": "game.rotate_light",
      "enabled": true,
      "params": {
        "speed": 0.35,
        "axis": "y"
      }
    }
  ]
}
```

This gives:

- explicit module declaration
- per-entity parameters
- a clear path to hot reload and validation

## Recommended Streaming Authoring Model

Do not force all streaming info into per-entity blobs.

Recommended split:

- entity-level hints for simple cases
- scene-level groups/cells for large authored spaces

Example `streaming/groups.json`:

```json
{
  "groups": [
    {
      "id": "main_set",
      "policy": "proximity",
      "activeRadius": 48.0,
      "prefetchRadius": 96.0,
      "offloadDelayFrames": 30
    },
    {
      "id": "always_on_lights",
      "policy": "always_resident"
    }
  ]
}
```

Example `streaming/cells.json`:

```json
{
  "cells": [
    {
      "id": "cell.entry",
      "bounds": {
        "min": [-16.0, -8.0, -16.0],
        "max": [16.0, 8.0, 16.0]
      },
      "entities": ["pillar.a", "pillar.b", "light.key"]
    }
  ]
}
```

This gives authored control without bloating every entity file.

## Recommended Registry Layout

Current registry:

- a flat scene key to file path list in one JSON file

Recommended registry:

```json
{
  "defaultScene": "shadow_tuning",
  "scenes": [
    {
      "id": "shadow_tuning",
      "path": "assets/scenes/shadow_tuning/scene.json",
      "tags": ["test", "lighting", "debug"]
    }
  ]
}
```

This supports filtering, tooling, and build-time validation.

## Migration Plan

Recommended migration order:

1. Keep `SceneDescription` as the runtime-facing intermediate format.
2. Replace the current flat `SceneFile` parser with a package loader that resolves `scene.json` plus entity files.
3. Add component-style authoring in the loader while preserving current runtime bootstrap.
4. Support prefab expansion before bootstrap.
5. Move streaming/cell declarations into loader output.
6. Remove legacy `SceneDefinition` generation from `engine/src/main.zig` once mesh/physics ownership moves fully into `SceneRuntime`.

## Concrete Recommendation

Do not keep growing `assets/configs/scenes/*.scene.json`.

That format was useful as a bootstrap format, but it is already bending under new ECS requirements. The right long-term move is:

- new root folder: `assets/scenes/`
- one folder per launchable scene
- one entity per file
- components instead of `type`-switched flat asset records
- explicit scene package metadata, script declarations, and streaming declarations

That gives better scaling, cleaner diffs, prefab support, and a direct mapping onto the ECS runtime we are building.