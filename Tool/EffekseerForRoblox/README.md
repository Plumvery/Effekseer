# Effekseer for Roblox

This folder contains the Roblox bridge for Effekseer projects.

The bridge does not embed the native Effekseer C++ renderer into Roblox. Instead, it converts `.efkproj` or `.efkefc` effect data into a Luau ModuleScript and plays the supported renderer nodes through Roblox `ParticleEmitter` instances. This fits Rojo and Argon workflows because generated effects are normal `.luau` files.

## Supported scope

- Reads `.efkproj` XML.
- Reads `.efkefc` files by extracting the compressed `EDIT` XML chunk.
- Converts Sprite, Ring, Ribbon, and Track renderer nodes into approximate `ParticleEmitter` playback.
- Preserves node hierarchy, generation count, generation interval, life, offset, color, alpha, texture path, position, velocity, acceleration, rotation around Z, and simple scale.
- Emits warnings for unsupported features such as model rendering and FCurve motion.

Roblox cannot consume local texture files from Effekseer directly. Upload the textures to Roblox and pass a JSON map from Effekseer texture paths to `rbxassetid://...` IDs.

## Convert an effect

```powershell
python Tool\EffekseerForRoblox\effekseer_to_roblox.py `
  Release\Sample\01_Suzuki01\003_snowstorm_effect\snowstorm11.efkproj `
  -o Dev\Roblox\src\ReplicatedStorage\EffekseerEffects\SnowstormSample.luau `
  --module-name SnowstormSample `
  --texture-map texture-map.json
```

Example `texture-map.json`:

```json
{
  "Texture/Particle01.png": "rbxassetid://1234567890",
  "Texture/Particle02.png": "rbxassetid://1234567891"
}
```

If a texture is not mapped, the generated module keeps the original path and the converter prints a warning. You can also pass an `assetMap` table at runtime.

## Use in Roblox

`Dev/Roblox/default.project.json` is a Rojo/Argon-ready project. Sync it, then play a generated effect from a `BasePart` or `Attachment`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effekseer = require(ReplicatedStorage.EffekseerRoblox)
local effect = require(ReplicatedStorage.EffekseerEffects.SnowstormSample)

local handle = Effekseer.play(effect, workspace.EffectPart, {
	loop = false,
	assetMap = {
		["Texture/Particle01.png"] = "rbxassetid://1234567890",
	},
})

-- handle:Stop()
-- handle:Destroy()
```

The runtime creates temporary attachments and particle emitters under the target part. `Destroy()` removes them.
