--!nonstrict
-- Colors, transparency, size sequences, textures, billboards, and flipbooks —
-- everything that determines how a node looks rather than where it is.

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))

type EffectNode = Types.EffectNode
type PlayOptions = Types.PlayOptions
type UVPayload = Types.UVPayload

local BILLBOARD = Types.BILLBOARD
local safeSet = Util.safeSet
local assetMapValue = Util.assetMapValue
local rangeValue = Util.rangeValue
local componentMul = Util.componentMul
local averageXYVector = Util.averageXYVector
local lerp = Util.lerp
local easedProgress = Util.easedProgress
local threePointNumber = Util.threePointNumber
local color3 = Util.color3
local enumValue = Util.enumValue
local sizeVectorAt = Sampling.sizeVectorAt
local visualSizeMultiplierAt = Sampling.visualSizeMultiplierAt
local vectorPayloadCenter = Sampling.vectorPayloadCenter
local billboardMode = Sampling.billboardMode
local flipbookMappable = Sampling.flipbookMappable

local Appearance = {}

function Appearance.colorOverLifeProgress(node: EffectNode): { number }?
	local colorOverLife = node.colorOverLife
	if not colorOverLife then
		return nil
	end
	return (colorOverLife :: any).progress
end

local colorOverLifeProgress = Appearance.colorOverLifeProgress

function Appearance.color3At(node: EffectNode, t: number): Color3
	if node.colorOverLife then
		local p = easedProgress(colorOverLifeProgress(node), t)
		return Color3.new(
			math.clamp(
				lerp((node.colorOverLife.start.r or 255) / 255, (node.colorOverLife.finish.r or 255) / 255, p),
				0,
				1
			),
			math.clamp(
				lerp((node.colorOverLife.start.g or 255) / 255, (node.colorOverLife.finish.g or 255) / 255, p),
				0,
				1
			),
			math.clamp(
				lerp((node.colorOverLife.start.b or 255) / 255, (node.colorOverLife.finish.b or 255) / 255, p),
				0,
				1
			)
		)
	end

	return color3(node.color)
end

function Appearance.spriteTransparencyAt(
	node: EffectNode,
	ageSeconds: number,
	lifeSeconds: number,
	frameRate: number
): number
	local t = math.clamp(ageSeconds / math.max(lifeSeconds, 1 / frameRate), 0, 1)
	local startColor = if node.colorOverLife then node.colorOverLife.start else node.color
	local finishColor = if node.colorOverLife then node.colorOverLife.finish else node.color
	local startTransparency = 1 - math.clamp((startColor.a or 255) / 255, 0, 1)
	local finishTransparency = 1 - math.clamp((finishColor.a or 255) / 255, 0, 1)
	local transparency =
		math.clamp(lerp(startTransparency, finishTransparency, easedProgress(colorOverLifeProgress(node), t)), 0, 1)
	local fadeInSeconds = math.max(0, node.fadeIn or 0) / frameRate
	local fadeOutSeconds = math.max(0, node.fadeOut or 0) / frameRate

	if fadeInSeconds > 0 and ageSeconds < fadeInSeconds then
		local fadeT = math.clamp(ageSeconds / fadeInSeconds, 0, 1)
		transparency = lerp(1, transparency, fadeT)
	end
	if fadeOutSeconds > 0 and ageSeconds > lifeSeconds - fadeOutSeconds then
		local fadeT = math.clamp((ageSeconds - (lifeSeconds - fadeOutSeconds)) / fadeOutSeconds, 0, 1)
		transparency = lerp(transparency, 1, fadeT)
	end

	return transparency
end

function Appearance.colorSequence(node: EffectNode): ColorSequence
	if node.colorOverLife then
		local progress = colorOverLifeProgress(node)
		if progress and #progress >= 2 then
			-- color3At applies the eased progress internally, so sampling at uniform
			-- times reproduces the curve.
			local keypoints = {}
			for index = 1, #progress do
				local time = (index - 1) / (#progress - 1)
				table.insert(keypoints, ColorSequenceKeypoint.new(time, Appearance.color3At(node, time)))
			end
			return ColorSequence.new(keypoints)
		end
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, color3(node.colorOverLife.start)),
			ColorSequenceKeypoint.new(1, color3(node.colorOverLife.finish)),
		})
	end

	return ColorSequence.new(color3(node.color))
end

-- NumberSequence requires strictly increasing keypoint times ending exactly at 1.
function Appearance.sanitizedSequence(entries: { { time: number, value: number, envelope: number? } }): NumberSequence
	table.sort(entries, function(left, right)
		return left.time < right.time
	end)
	local keypoints = {}
	local previousTime = -1
	for index, entry in entries do
		local time = math.clamp(entry.time, 0, 1)
		if index == #entries then
			time = 1
		end
		if time <= previousTime then
			time = math.min(1, previousTime + 1e-3)
		end
		if time > previousTime then
			table.insert(
				keypoints,
				NumberSequenceKeypoint.new(time, math.clamp(entry.value, 0, 1e9), entry.envelope or 0)
			)
			previousTime = time
		end
	end
	if #keypoints == 0 then
		return NumberSequence.new(0)
	end
	if keypoints[1].Time > 0 then
		table.insert(keypoints, 1, NumberSequenceKeypoint.new(0, keypoints[1].Value, keypoints[1].Envelope))
	end
	if keypoints[#keypoints].Time < 1 then
		local last = keypoints[#keypoints]
		table.insert(keypoints, NumberSequenceKeypoint.new(1, last.Value, last.Envelope))
	end
	return NumberSequence.new(keypoints)
end

local sanitizedSequence = Appearance.sanitizedSequence

function Appearance.transparencySequence(node: EffectNode, lifeSeconds: number, frameRate: number): NumberSequence
	local startColor = if node.colorOverLife then node.colorOverLife.start else node.color
	local finishColor = if node.colorOverLife then node.colorOverLife.finish else node.color
	local startTransparency = 1 - math.clamp((startColor.a or 255) / 255, 0, 1)
	local finishTransparency = 1 - math.clamp((finishColor.a or 255) / 255, 0, 1)
	local fadeIn = math.max(0, node.fadeIn or 0)
	local fadeOut = math.max(0, node.fadeOut or 0)
	local duration = math.max(1 / frameRate, lifeSeconds)

	local progress = colorOverLifeProgress(node)
	if progress and #progress >= 2 then
		-- Sample the eased alpha curve (with fades applied) directly.
		local entries = {}
		for index = 1, #progress do
			local time = (index - 1) / (#progress - 1)
			table.insert(entries, {
				time = time,
				value = Appearance.spriteTransparencyAt(node, time * duration, duration, frameRate),
			})
		end
		return sanitizedSequence(entries)
	end

	if fadeIn <= 0 and fadeOut <= 0 and startTransparency == finishTransparency then
		return NumberSequence.new(startTransparency)
	end

	local fadeInT = math.clamp((fadeIn / frameRate) / duration, 0, 0.98)
	local fadeOutT = math.clamp(1 - (fadeOut / frameRate) / duration, fadeInT, 1)

	local entries = {
		{ time = 0, value = if fadeIn > 0 then 1 else startTransparency },
	}

	if fadeIn > 0 then
		table.insert(entries, { time = fadeInT, value = startTransparency })
	end

	if fadeOut > 0 then
		table.insert(entries, { time = fadeOutT, value = finishTransparency })
		table.insert(entries, { time = 1, value = 1 })
	elseif startTransparency ~= finishTransparency then
		table.insert(entries, { time = 1, value = finishTransparency })
	else
		table.insert(entries, { time = 1, value = startTransparency })
	end

	return sanitizedSequence(entries)
end

function Appearance.blendLightEmission(node: EffectNode): number
	return if node.alphaBlend == 2 then 1 else 0
end

function Appearance.sizeSequence(
	node: EffectNode,
	unitScale: number,
	particleSizeScale: number,
	parentScale: Vector3
): NumberSequence
	local size = node.transform.size
	local scale = unitScale * particleSizeScale
	local envelope = math.max(0, (size.envelope or 0) * scale)

	local scaleKeys = size.scaleKeys
	if scaleKeys and #scaleKeys.frames > 1 then
		local lastFrame = math.max(1, scaleKeys.frames[#scaleKeys.frames])
		local entries = {}
		for index, frame in scaleKeys.frames do
			local t = math.clamp(frame / lastFrame, 0, 1)
			local value = scaleKeys.values[index]
			local vector = componentMul(Vector3.new(value.x or 1, value.y or 1, value.z or 1), parentScale)
			table.insert(entries, {
				time = t,
				value = math.max(0.01, averageXYVector(vector) * scale * visualSizeMultiplierAt(node, t)),
				envelope = envelope,
			})
		end
		return sanitizedSequence(entries)
	end

	local sizeEasing: any = if size.type == 2 then size.easing elseif size.type == 4 then size.singleEasing else nil
	if sizeEasing and (sizeEasing.progress or sizeEasing.middle) then
		local startScalar = averageXYVector(componentMul(sizeVectorAt(node, 0), parentScale)) * scale
		local finishScalar = averageXYVector(componentMul(sizeVectorAt(node, 1), parentScale)) * scale
		local middleScalar = nil
		if sizeEasing.middle then
			if size.type == 2 then
				middleScalar = averageXYVector(
					componentMul(vectorPayloadCenter(sizeEasing.middle, Vector3.one), parentScale)
				) * scale
			else
				middleScalar = math.abs(rangeValue(sizeEasing.middle, "center", 1))
					* averageXYVector(parentScale)
					* scale
			end
		end
		local progress = sizeEasing.progress
		local count = if progress then #progress else 13
		local entries = {}
		for index = 1, count do
			local time = (index - 1) / (count - 1)
			local p = easedProgress(progress, time)
			local value
			if middleScalar then
				value = threePointNumber(startScalar, middleScalar, finishScalar, p)
			else
				value = lerp(startScalar, finishScalar, p)
			end
			table.insert(entries, {
				time = time,
				value = math.max(0.01, value * visualSizeMultiplierAt(node, time)),
				envelope = envelope,
			})
		end
		return sanitizedSequence(entries)
	end

	local startSize = math.max(
		0.01,
		averageXYVector(componentMul(sizeVectorAt(node, 0), parentScale)) * scale * visualSizeMultiplierAt(node, 0)
	)
	local finishSize = math.max(
		0.01,
		averageXYVector(componentMul(sizeVectorAt(node, 1), parentScale)) * scale * visualSizeMultiplierAt(node, 1)
	)

	if math.abs(startSize - finishSize) < 1e-5 then
		if envelope <= 0 then
			return NumberSequence.new(startSize)
		end

		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, startSize, envelope),
			NumberSequenceKeypoint.new(1, startSize, envelope),
		})
	end

	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, startSize, envelope),
		NumberSequenceKeypoint.new(1, finishSize, envelope),
	})
end

local function additivePreviewTextureForNode(node: EffectNode, options: PlayOptions): any
	if
		options.useAdditivePreviewTexture ~= true
		or node.alphaBlend ~= 2
		or not options.assetMap
		or not node.texturePath
	then
		return nil
	end

	return assetMapValue(options.assetMap, node.texturePath, "additive:")
end

function Appearance.textureForNode(
	node: EffectNode,
	options: PlayOptions,
	fallback: string?,
	preferAdditivePreview: boolean?
): any
	if preferAdditivePreview then
		local additiveTexture = additivePreviewTextureForNode(node, options)
		if additiveTexture then
			return additiveTexture
		end
	end

	if options.assetMap and node.texturePath then
		local mappedTexture = assetMapValue(options.assetMap, node.texturePath, nil)
		if mappedTexture then
			return mappedTexture
		end
	end

	local texture = node.texture
	return texture or fallback or ""
end

function Appearance.modelAssetForNode(node: EffectNode, options: PlayOptions): string?
	local model = if node.visual then node.visual.model else nil
	if not model then
		return nil
	end

	if options.assetMap and model.path and model.path ~= "" then
		local mappedModel = assetMapValue(options.assetMap, model.path, nil)
		if mappedModel then
			return mappedModel
		end
	end

	if model.asset and model.asset ~= "" then
		return model.asset
	end

	return nil
end

function Appearance.particleOrientationForNode(node: EffectNode)
	local billboard = billboardMode(node)
	if billboard == BILLBOARD.YAxisFixed then
		return enumValue(Enum.ParticleOrientation, "FacingCameraWorldUp") or Enum.ParticleOrientation.FacingCamera
	end
	if billboard == BILLBOARD.DirectionalBillboard then
		return enumValue(Enum.ParticleOrientation, "VelocityParallel") or Enum.ParticleOrientation.FacingCamera
	end
	return Enum.ParticleOrientation.FacingCamera
end

-- Square-grid sheet animations map straight onto Roblox particle flipbooks.
function Appearance.tryApplyFlipbook(emitter: ParticleEmitter, node: EffectNode, frameRate: number)
	if not flipbookMappable(node) then
		return
	end
	local uv = node.uv :: UVPayload
	local animation = uv.animation
	if not animation then
		return
	end
	local layout = enumValue(Enum.ParticleFlipbookLayout, "Grid" .. animation.countX .. "x" .. animation.countX)
	if not layout then
		return
	end
	local applied = pcall(function()
		(emitter :: any).FlipbookLayout = layout
	end)
	if not applied then
		return
	end
	safeSet(
		emitter,
		"FlipbookFramerate",
		NumberRange.new(math.clamp(frameRate / math.max(1, animation.frameLength), 0, 30))
	)
	local modeName = if animation.loopType == 0 then "OneShot" elseif animation.loopType == 2 then "PingPong" else "Loop"
	local mode = enumValue(Enum.ParticleFlipbookMode, modeName)
	if mode then
		safeSet(emitter, "FlipbookMode", mode)
	end
end

function Appearance.billboardCFrame(baseCFrame: CFrame, billboard: number, direction: Vector3?): CFrame
	if billboard == BILLBOARD.Fixed then
		return baseCFrame
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return baseCFrame
	end

	local front = camera.CFrame.LookVector
	local up = Vector3.yAxis
	if billboard == BILLBOARD.YAxisFixed then
		up = baseCFrame.UpVector
	elseif billboard == BILLBOARD.DirectionalBillboard and direction and direction.Magnitude > 1e-6 then
		up = direction.Unit
	end

	local right = up:Cross(front)
	if right.Magnitude < 1e-6 then
		right = baseCFrame.RightVector
	else
		right = right.Unit
	end
	local correctedFront = right:Cross(up)
	if correctedFront.Magnitude < 1e-6 then
		correctedFront = front
	else
		correctedFront = correctedFront.Unit
	end

	return CFrame.fromMatrix(baseCFrame.Position, right, up.Unit, -correctedFront)
end

function Appearance.setSpriteVisualState(
	node: EffectNode,
	visual: Instance,
	visible: boolean,
	ageSeconds: number,
	lifeSeconds: number,
	frameRate: number
)
	if visible then
		local t = math.clamp(ageSeconds / math.max(lifeSeconds, 1 / frameRate), 0, 1)
		local color = Appearance.color3At(node, t)
		local transparency = Appearance.spriteTransparencyAt(node, ageSeconds, lifeSeconds, frameRate)
		if visual:IsA("Decal") then
			visual.Color3 = color
			visual.Transparency = transparency
		elseif visual:IsA("ImageLabel") then
			visual.ImageColor3 = color
			visual.ImageTransparency = transparency
		end
	else
		if visual:IsA("Decal") then
			visual.Transparency = 1
		elseif visual:IsA("ImageLabel") then
			visual.ImageTransparency = 1
		end
	end
end

return Appearance
