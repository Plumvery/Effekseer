# EffekseerForRoblox

This is the experimental Effekseer runtime bridge for Roblox. It follows the same repository shape as the other `EffekseerFor*` integrations: `Dev/Plugin` is the Rojo/Argon-ready runtime project, `src` contains converter tooling, and `Tests` contains converter tests.

The bridge converts `.efkproj` or `.efkefc` files into Luau ModuleScripts and plays supported nodes through Roblox visual primitives. It is not a native C++ renderer port.

## Renderer support

- `Sprite`: Roblox `ParticleEmitter`, or per-particle quads (SurfaceGui/Decal parts) when UV cropping, sheet animation, or fixed orientation requires it
- `Ring`: Roblox `ParticleEmitter` with the ring radius (including Outer/Inner PVA and easing animation) folded into the particle size; fixed-orientation rings render as quads so shockwaves lie flat
- `Ribbon` / `Track`: a moving tracer with a Roblox `Trail` when the node moves its particles, otherwise a static `Beam`
- `Model`: Roblox `MeshPart` when a model asset is mapped, otherwise a placeholder part; position/rotation/scale/color animate over the node's lifetime

Converter feature coverage:

- UV `Fixed` / `Animation` / `Scroll` (sheet animations map to Roblox flipbooks when they are square 2x2/4x4/8x8 grids; other layouts render through animated quads)
- Generation locations `Point` / `Sphere` / `Circle` / `Line` (Model-surface spawning is unsupported and warned)
- Location / rotation / scaling FCurves are baked into linear key samples at conversion time
- Legacy `LocationAbsValues` gravity and Effekseer 1.6+ `LocalForceField` gravity; other force fields warn
- Effekseer 1.5+ `DrawingValues/ColorAll` StandardColor (Fixed / Random / Easing; FCurve and Gradient fall back to fixed with a warning)
- Node sounds (`SoundValues`) convert to Roblox `Sound` playback when a sound asset id is mapped
- "Delete when life expires = off" nodes live for the whole effect timeline
- Easing interpolation curves: legacy StartSpeed/EndSpeed cubics, the 1.8 standard easing functions (Quadratic..Quintic, Back, Bounce), and 3-point middle values are baked into sampled progress curves that keep the start/end randomness
- Emitter-path parents spawn an invisible carrier part per particle instance, so child nodes are generated per parent particle and follow its trajectory (bounded by `burstTaskLimit`)

Unsupported features (distortion, custom materials, subtract/multiply blending, attractive force, RotateToViewpoint/Velocity, UV FCurve, model-surface spawning) are reported in the conversion warnings instead of being silently dropped.

## Requirements

- Node.js 18 or later
- Rojo or Argon
- Optional: `rocas` for automatic Roblox asset upload and texture ID resolution

Install tool dependencies:

```bash
npm install
```

## Convert effects

```bash
npm run convert:sample
```

Manual conversion:

```bash
node bin/effekseer-for-roblox.js convert path/to/effect.efkproj \
  -o Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/MyEffect.luau \
  --module-name MyEffect
```

Convert a folder of Effekseer sample projects into a Studio preview pack:

```bash
npm run convert:sample-pack -- C:/Users/princ/Downloads/Effekseer01/Effekseer01
```

This writes generated effect modules under `Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/<package>`, a manifest module next to them, and a preview asset map under `EffekseerAssets`. The bundled demo client uses that manifest to switch between samples in Play mode.

Pass `--rocas-config rocas.toml --rocas-sync` when you want the sample pack to upload referenced assets first and embed the uploaded Roblox asset IDs into the preview asset map.

On Windows, you can run the same workflow with the bundled batch file:

```bat
update-effekseer01-preview.bat
```

Pass a different sample directory as the first argument when needed:

```bat
update-effekseer01-preview.bat D:\Samples\Effekseer01
```

## rocas asset integration

Copy `rocas.toml.example` to `rocas.toml`, set your creator ID, then configure one or more texture folders. `rocas` writes lock files with Roblox asset IDs. The converter reads those lock files and automatically fills `texture` fields in generated effect modules.

```bash
ROCAS_API_KEY=... npx rocas sync

node bin/effekseer-for-roblox.js convert path/to/effect.efkproj \
  -o Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/MyEffect.luau \
  --module-name MyEffect \
  --rocas-config rocas.toml
```

Use `--rocas-sync` to run `rocas sync` before conversion:

```bash
node bin/effekseer-for-roblox.js convert path/to/effect.efkproj \
  -o Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/MyEffect.luau \
  --rocas-config rocas.toml \
  --rocas-sync
```

## Build or serve

```bash
npm run build:rojo
npm run build:argon
```

For live development:

```bash
rojo serve Dev/Plugin/default.project.json
argon serve Dev/Plugin/default.project.json
```

## Studio plugin

The Studio plugin lets artists import effects without Rojo or Argon in the target project. It installs the `EffekseerRoblox` runtime into `ReplicatedStorage`, imports external `.efkproj` and `.efkefc` files into `ReplicatedStorage.EffekseerEffects` (the packaged `.efkefc` format is decompressed by a pure-Luau DEFLATE decoder), can also import already generated `.luau` effect modules, imports local texture files for Studio-only preview through temporary `rbxtemp://` content IDs, and previews the selected ModuleScript in Studio.

Build the local plugin package:

```bat
build-studio-plugin.bat
```

Install it into the local Roblox Studio plugins folder:

```bat
install-studio-plugin.bat
```

The generated package is `Dist/EffekseerForRobloxImporter.rbxm`. After installing, restart Studio and click the `Effekseer` toolbar button to open the plugin window. Use the window actions to install the runtime, import effects or textures, and preview the selected effect.

For direct `.efkproj` imports, use `Import Textures` in the plugin window and select the referenced texture images before previewing. Temporary texture IDs are valid only for the current Studio session; use `rocas` for uploaded, persistent asset IDs.

## Tests

```bash
npm test
```

The converter tests cover Effekseer-style chunk/XML handling, supported and unsupported renderer nodes, hierarchy conversion, rocas asset-map resolution, CLI output, and a regression conversion for an included Effekseer sample project.

## Runtime use

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effekseer = require(ReplicatedStorage.EffekseerRoblox)
local effect = require(ReplicatedStorage.EffekseerEffects.SnowstormSample)

local handle = Effekseer.play(effect, workspace.EffectPart, {
	loop = false,
	hideTarget = true,
})

-- handle:Stop()
-- handle:Destroy()
```

If an effect was generated before its texture IDs were resolved, you can still pass an `assetMap` table at runtime.
