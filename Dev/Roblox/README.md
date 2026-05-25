# EffekseerForRoblox

This is the experimental Effekseer runtime bridge for Roblox. It follows the same repository shape as the other `EffekseerFor*` integrations: `Dev/Plugin` is the Rojo/Argon-ready runtime project, `src` contains converter tooling, and `Tests` contains converter tests.

The bridge converts `.efkproj` or `.efkefc` files into Luau ModuleScripts and plays supported nodes through Roblox `ParticleEmitter` instances. It is not a native C++ renderer port.

## Requirements

- Node.js 18 or later
- Rojo or Argon
- Optional: `rocs` for automatic Roblox asset upload and texture ID resolution

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

## rocs asset integration

Copy `rocs.toml.example` to `rocs.toml`, set your creator ID, then configure one or more texture folders. `rocs` writes lock files with Roblox asset IDs. The converter reads those lock files and automatically fills `texture` fields in generated effect modules.

```bash
ROCS_API_KEY=... npx rocs sync

node bin/effekseer-for-roblox.js convert path/to/effect.efkproj \
  -o Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/MyEffect.luau \
  --module-name MyEffect \
  --rocs-config rocs.toml
```

Use `--rocs-sync` to run `rocs sync` before conversion:

```bash
node bin/effekseer-for-roblox.js convert path/to/effect.efkproj \
  -o Dev/Plugin/src/ReplicatedStorage/EffekseerEffects/MyEffect.luau \
  --rocs-config rocs.toml \
  --rocs-sync
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

## Runtime use

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effekseer = require(ReplicatedStorage.EffekseerRoblox)
local effect = require(ReplicatedStorage.EffekseerEffects.SnowstormSample)

local handle = Effekseer.play(effect, workspace.EffectPart, {
	loop = false,
})

-- handle:Stop()
-- handle:Destroy()
```

If an effect was generated before its texture IDs were resolved, you can still pass an `assetMap` table at runtime.
