# EffekseerForRoblox

This is the experimental Effekseer runtime bridge for Roblox. It follows the same repository shape as the other `EffekseerFor*` integrations: `Dev/Plugin` is the Rojo/Argon-ready runtime project, `src` contains converter tooling, and `Tests` contains converter tests.

The bridge converts `.efkproj` or `.efkefc` files into Luau ModuleScripts and plays supported nodes through Roblox visual primitives. It is not a native C++ renderer port.

## Renderer support

- `Sprite`: Roblox `ParticleEmitter`
- `Ring`: Roblox `ParticleEmitter` with disc-shaped emission when available, plus a fallback preview texture for textureless rings
- `Ribbon`: Roblox `Beam`
- `Track`: Roblox `Beam`
- `Model`: Roblox `MeshPart` when a model asset is mapped, otherwise a visible placeholder part for preview

Effekseer curves, UV animation, and native model geometry are still approximated. The goal of this bridge is reliable Roblox Studio preview and Rojo/Argon-friendly generated Luau first, then incremental visual parity.

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

The Studio plugin lets artists import effects without Rojo or Argon in the target project. It installs the `EffekseerRoblox` runtime into `ReplicatedStorage`, imports external `.efkproj` files into `ReplicatedStorage.EffekseerEffects`, can also import already generated `.luau` effect modules, imports local texture files for Studio-only preview through temporary `rbxtemp://` content IDs, and previews the selected ModuleScript in Studio.

Build the local plugin package:

```bat
build-studio-plugin.bat
```

Install it into the local Roblox Studio plugins folder:

```bat
install-studio-plugin.bat
```

The generated package is `Dist/EffekseerForRobloxImporter.rbxm`. After installing, restart Studio and use the `Effekseer` toolbar.

For direct `.efkproj` imports, click `Import Textures` and select the referenced texture images before previewing. Temporary texture IDs are valid only for the current Studio session; use `rocas` for uploaded, persistent asset IDs.

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
