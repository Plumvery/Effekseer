--!nonstrict
-- Effekseer project converter for the Studio plugin. Reads .efkproj XML or
-- packaged .efkefc binaries and produces the EffekseerRobloxEffect table the
-- runtime plays back. Mirrors Dev/Roblox/src/converter.js — keep both in sync.

local Xml = require(script:WaitForChild("Xml"))
local VectorMath = require(script:WaitForChild("VectorMath"))
local Diagnostics = require(script:WaitForChild("Diagnostics"))
local NodeValues = require(script:WaitForChild("NodeValues"))
local TransformPayloads = require(script:WaitForChild("TransformPayloads"))
local RendererPayloads = require(script:WaitForChild("RendererPayloads"))
local AssetMap = require(script:WaitForChild("AssetMap"))
local Efkefc = require(script:WaitForChild("Efkefc"))
local Serialize = require(script:WaitForChild("Serialize"))

local warning = Diagnostics.warning

local Converter = {}

local SUPPORTED_RENDERERS = {
	Sprite = true,
	Ribbon = true,
	Ring = true,
	Track = true,
	Model = true,
}

local function sortedKeys(setTable)
	local result = {}
	for key in pairs(setTable) do
		table.insert(result, key)
	end
	table.sort(result)
	return result
end

local function convertNode(node, context, idPrefix: string)
	local nodeName = Xml.textAt(node, "Name") or ("Node" .. idPrefix)
	local rendererType = NodeValues.rendererTypeFor(node)
	local rendered = Xml.boolAt(node, "IsRendered", true) and rendererType ~= "None"
	local life = NodeValues.nodeLife(node)
	local color = RendererPayloads.colorPayload(node, context.warnings, nodeName)
	local texturePath = NodeValues.texturePathFor(node)
	local texture = nil
	if texturePath ~= "" then
		context.dependencies.textures[texturePath] = true
		texture = AssetMap.assetMapValue(context.assetMap, texturePath)
		if not texture and context.useFallbackTextures then
			texture = AssetMap.builtInTextureFor(texturePath)
		end
	end

	local modelPath = if rendererType == "Model" then NodeValues.modelPathFor(node) else ""
	local modelAsset = nil
	if modelPath ~= "" then
		context.dependencies.models[modelPath] = true
		modelAsset = AssetMap.assetMapValue(context.assetMap, modelPath)
	end

	if rendered and not SUPPORTED_RENDERERS[rendererType] then
		table.insert(
			context.warnings,
			warning(
				"renderer_unsupported",
				"Renderer " .. rendererType .. " is not supported by the Roblox runtime.",
				nodeName
			)
		)
		rendered = false
	end
	if rendered and texturePath ~= "" and not texture then
		table.insert(
			context.warnings,
			warning("texture_unmapped", "No Roblox asset id mapped for texture '" .. texturePath .. "'.", nodeName)
		)
	end
	if rendered and rendererType == "Model" and modelPath ~= "" and not modelAsset then
		table.insert(
			context.warnings,
			warning(
				"model_unmapped",
				"No Roblox asset id mapped for model '" .. modelPath .. "'. A placeholder part will be used.",
				nodeName
			)
		)
	end

	local uv = if rendered then RendererPayloads.uvPayload(node, context.warnings, nodeName) else nil
	local spawn = NodeValues.spawnPayload(node, context.warnings, nodeName)
	local sound = NodeValues.soundPayload(node, context, nodeName)
	local alphaBlend = RendererPayloads.alphaBlendAt(node)

	if rendered then
		local materialType = Xml.intAt(node, "RendererCommonValues/Material", 0)
		if materialType == 6 or Xml.boolAt(node, "RendererCommonValues/Distortion", false) then
			table.insert(
				context.warnings,
				warning("distortion_unsupported", "Background distortion is rendered as a plain texture.", nodeName)
			)
		elseif materialType == 128 then
			table.insert(
				context.warnings,
				warning(
					"material_unsupported",
					"Custom material files are not supported; textures may be missing.",
					nodeName
				)
			)
		elseif materialType == 7 then
			table.insert(
				context.warnings,
				warning("material_unsupported", "Lighting material is approximated with unlit rendering.", nodeName)
			)
		end
		if alphaBlend == 3 or alphaBlend == 4 then
			table.insert(
				context.warnings,
				warning(
					"blend_unsupported",
					(if alphaBlend == 3 then "Subtract" else "Multiply")
						.. " blending is approximated with normal blending.",
					nodeName
				)
			)
		end
	end

	local location = TransformPayloads.locationPayload(node, context.warnings, nodeName, life)
	if spawn and spawn.type == 0 and spawn.point then
		location.position = VectorMath.addVectors(location.position, spawn.point.location.center)
		location.positionRange = VectorMath.addVectorRanges(location.positionRange, spawn.point.location)
		spawn = nil
	end
	local speedMin = VectorMath.vectorMagnitude(location.velocity.min)
	local speedMax = VectorMath.vectorMagnitude(location.velocity.max)
	if speedMin > speedMax then
		speedMin, speedMax = speedMax, speedMin
	end

	-- Evaluate rotation/scale before recursing so warning order matches converter.js.
	local rotation = TransformPayloads.rotationPayload(node, life, context.warnings, nodeName)
	local size = TransformPayloads.scalePayload(node, life, context.warnings, nodeName)

	local childRoot = Xml.find(node, "Children")
	local childNodes = if childRoot then Xml.children(childRoot, "Node") else {}
	local convertedChildren = {}
	for index, childNode in ipairs(childNodes) do
		table.insert(convertedChildren, convertNode(childNode, context, idPrefix .. "_" .. tostring(index)))
	end

	return {
		id = idPrefix,
		name = nodeName,
		rendererType = rendererType,
		rendered = rendered,
		texturePath = texturePath,
		texture = texture,
		alphaBlend = alphaBlend,
		zTest = Xml.boolAt(node, "RendererCommonValues/ZTest", true),
		fadeIn = RendererPayloads.fadeFrameAt(node, "FadeIn"),
		fadeOut = RendererPayloads.fadeFrameAt(node, "FadeOut"),
		color = color.color,
		colorOverLife = color.colorOverLife,
		uv = uv,
		spawn = spawn,
		sound = sound,
		visual = RendererPayloads.visualPayload(node, rendererType, modelPath, modelAsset, life),
		life = life,
		generation = {
			max = NodeValues.maxGeneration(node),
			time = NodeValues.generationTime(node),
			offset = NodeValues.generationOffset(node),
		},
		transform = {
			position = location.position,
			positionRange = location.positionRange,
			positionKeys = location.positionKeys,
			positionEasing = location.positionEasing,
			velocity = location.velocity,
			acceleration = location.acceleration,
			speed = { min = speedMin, max = speedMax },
			emissionDirection = location.emissionDirection,
			spreadAngle = location.spreadAngle,
			rotation = rotation,
			size = size,
		},
		children = convertedChildren,
	}
end

Converter.parseEfkefc = Efkefc.parseEfkefcRoot
Converter.toLuau = Serialize.toLuau
Converter.toModuleSource = Serialize.toModuleSource

function Converter.convertProject(xml: string, options)
	options = options or {}
	local projectRoot = if string.sub(xml, 1, 4) == "EFKE" then Efkefc.parseEfkefcRoot(xml) else Xml.parseXml(xml)
	if projectRoot.name ~= "EffekseerProject" then
		error("Expected EffekseerProject XML root, got " .. projectRoot.name)
	end

	local context = {
		warnings = {},
		dependencies = {
			textures = {},
			models = {},
			sounds = {},
		},
		assetMap = options.assetMap or {},
		useFallbackTextures = options.useFallbackTextures == true,
	}
	context.assetMapLookup = function(assetPath: string)
		return AssetMap.assetMapValue(context.assetMap, assetPath)
	end

	local childRoot = Xml.find(projectRoot, "Root/Children")
	local rootNodes = if childRoot then Xml.children(childRoot, "Node") else {}
	local nodes = {}
	for index, node in ipairs(rootNodes) do
		table.insert(nodes, convertNode(node, context, tostring(index)))
	end
	local startFrame = Xml.numberAt(projectRoot, "StartFrame", 0)
	local endFrame = Xml.numberAt(projectRoot, "EndFrame", 0)

	return {
		format = "EffekseerRobloxEffect",
		formatVersion = 2,
		name = options.moduleName or "ImportedEffect",
		source = options.source or "Studio import",
		frameRate = options.frameRate or 60,
		startFrame = startFrame,
		endFrame = endFrame,
		durationFrames = math.max(0, endFrame - startFrame),
		isLoop = Xml.boolAt(projectRoot, "IsLoop", false),
		unitScale = options.unitScale or 0.2,
		particleSizeScale = options.particleSizeScale or 1,
		dependencies = {
			textures = sortedKeys(context.dependencies.textures),
			models = sortedKeys(context.dependencies.models),
			sounds = sortedKeys(context.dependencies.sounds),
		},
		warnings = context.warnings,
		nodes = nodes,
	}
end

return Converter
