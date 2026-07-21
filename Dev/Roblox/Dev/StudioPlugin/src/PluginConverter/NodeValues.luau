--!nonstrict
-- Node-level common values: renderer type, life/generation, texture and model
-- paths, generation-location spawn shapes, and node sounds.

local Xml = require(script.Parent:WaitForChild("Xml"))
local Diagnostics = require(script.Parent:WaitForChild("Diagnostics"))

local warning = Diagnostics.warning

local NodeValues = {}

local RENDERER_TYPES = {
	[0] = "None",
	[2] = "Sprite",
	[3] = "Ribbon",
	[4] = "Ring",
	[5] = "Model",
	[6] = "Track",
}

function NodeValues.rendererTypeFor(node): string
	local rendererId = Xml.intAt(node, "DrawingValues/Type", 2)
	return RENDERER_TYPES[rendererId] or ("Unknown" .. tostring(rendererId))
end

function NodeValues.generationTime(node)
	local common = Xml.find(node, "CommonValues")
	if not common then
		return { center = 1, min = 1, max = 1 }
	end
	local nested = Xml.randomNumberAt(common, "Generation/GenerationTime", 1)
	local legacy = Xml.randomNumberAt(common, "GenerationTime", nested.center)
	return if Xml.find(common, "Generation/GenerationTime") or not Xml.find(common, "GenerationTime")
		then nested
		else legacy
end

function NodeValues.generationOffset(node)
	local common = Xml.find(node, "CommonValues")
	if not common then
		return { center = 0, min = 0, max = 0 }
	end
	local nested = Xml.randomNumberAt(common, "Generation/GenerationTimeOffset", 0)
	local legacy = Xml.randomNumberAt(common, "GenerationTimeOffset", nested.center)
	return if Xml.find(common, "Generation/GenerationTimeOffset") or not Xml.find(common, "GenerationTimeOffset")
		then nested
		else legacy
end

function NodeValues.nodeLife(node)
	local common = Xml.find(node, "CommonValues")
	local life = if common then Xml.randomNumberAt(common, "Life", 100) else { center = 100, min = 100, max = 100 }
	if common then
		-- Modern saves nest removal flags under Removal; legacy saves keep flat RemoveWhen* elements.
		local removalNested = Xml.boolAt(common, "Removal/WhenLifeIsExtinct", true)
		local removalLegacy = Xml.boolAt(common, "RemoveWhenLifeIsExtinct", true)
		if not removalNested or not removalLegacy then
			life.infinite = true
		end
	end
	return life
end

function NodeValues.maxGeneration(node): number
	local common = Xml.find(node, "CommonValues")
	if not common then
		return 1
	end
	if Xml.boolAt(common, "MaxGeneration/Infinite", false) then
		return 0
	end
	return math.max(0, Xml.intAt(common, "MaxGeneration/Value", 1))
end

function NodeValues.texturePathFor(node): string
	return Xml.textAt(node, "RendererCommonValues/ColorTexture")
		or Xml.textAt(node, "DrawingValues/Sprite/ColorTexture")
		or Xml.textAt(node, "DrawingValues/Ribbon/ColorTexture")
		or Xml.textAt(node, "DrawingValues/Ring/ColorTexture")
		or Xml.textAt(node, "DrawingValues/Track/ColorTexture")
		or ""
end

function NodeValues.modelPathFor(node): string
	return Xml.textAt(node, "DrawingValues/Model/Model") or ""
end

local function rangeIsZero(range): boolean
	for _, key in ipairs({ "center", "min", "max" }) do
		local vector = range[key] or {}
		if math.abs(vector.x or 0) > 1e-9 or math.abs(vector.y or 0) > 1e-9 or math.abs(vector.z or 0) > 1e-9 then
			return false
		end
	end
	return true
end

function NodeValues.spawnPayload(node, warnings, nodeName: string)
	local base = Xml.find(node, "GenerationLocationValues")
	if not base then
		return nil
	end
	local spawnType = Xml.intAt(base, "Type", 0)
	local effectsRotation = Xml.boolAt(base, "EffectsRotation", false)

	if spawnType == 0 then
		-- Point offsets are merged into transform.positionRange by convertNode.
		local location = Xml.randomVectorAt(base, "Point/Location", { x = 0, y = 0, z = 0 })
		if rangeIsZero(location) then
			return nil
		end
		return { type = 0, effectsRotation = effectsRotation, point = { location = location } }
	end

	if spawnType == 1 then
		return {
			type = 1,
			effectsRotation = effectsRotation,
			sphere = {
				radius = Xml.randomNumberAt(base, "Sphere/Radius", 0),
				rotationX = Xml.randomNumberAt(base, "Sphere/RotationX", 0),
				rotationY = Xml.randomNumberAt(base, "Sphere/RotationY", 0),
			},
		}
	end

	if spawnType == 3 then
		return {
			type = 3,
			effectsRotation = effectsRotation,
			circle = {
				radius = Xml.randomNumberAt(base, "Circle/Radius", 0),
				axis = Xml.intAt(base, "Circle/AxisDirection", 2),
				division = math.max(1, Xml.intAt(base, "Circle/Division", 8)),
				angleStart = Xml.randomNumberAt(base, "Circle/AngleStart", 0),
				angleEnd = Xml.randomNumberAt(base, "Circle/AngleEnd", 360),
				angleNoise = Xml.randomNumberAt(base, "Circle/AngleNoize", 0),
				order = Xml.intAt(base, "Circle/Type", 0),
			},
		}
	end

	if spawnType == 4 then
		return {
			type = 4,
			effectsRotation = effectsRotation,
			line = {
				from = Xml.randomVectorAt(base, "Line/PositionStart", { x = 0, y = 0, z = 0 }),
				to = Xml.randomVectorAt(base, "Line/PositionEnd", { x = 0, y = 0, z = 0 }),
				division = math.max(1, Xml.intAt(base, "Line/Division", 8)),
				noise = Xml.randomNumberAt(base, "Line/PositionNoize", 0),
				order = Xml.intAt(base, "Line/Type", 0),
			},
		}
	end

	table.insert(
		warnings,
		warning(
			"spawn_unsupported",
			"Generation location type " .. tostring(spawnType) .. " is not supported; point emission is used.",
			nodeName
		)
	)
	return nil
end

function NodeValues.soundPayload(node, context, nodeName: string)
	local base = Xml.find(node, "SoundValues")
	if not base or Xml.intAt(base, "Type", 0) ~= 1 then
		return nil
	end
	local wave = Xml.textAt(base, "Sound/Wave")
	if not wave then
		return nil
	end

	context.dependencies.sounds[wave] = true
	local asset = nil
	if context.assetMap then
		asset = context.assetMapLookup(wave)
	end
	if not asset then
		table.insert(
			context.warnings,
			warning("sound_unmapped", "No Roblox asset id mapped for sound '" .. wave .. "'.", nodeName)
		)
	end
	return {
		wave = wave,
		asset = asset,
		volume = Xml.randomNumberAt(base, "Sound/Volume", 1),
		pitch = Xml.randomNumberAt(base, "Sound/Pitch", 0),
		delay = Xml.randomNumberAt(base, "Sound/Delay", 0),
	}
end

return NodeValues
