--!nonstrict
-- Per-particle quad rendering (Sprite and fixed-orientation Ring nodes):
-- anchored plane parts with Decal/SurfaceGui faces, driven every Heartbeat.

local RunService = game:GetService("RunService")

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))
local Appearance = require(script.Parent:WaitForChild("Appearance"))
local Timing = require(script.Parent:WaitForChild("Timing"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions
type UVPayload = Types.UVPayload

local RING_FALLBACK_TEXTURE = Types.RING_FALLBACK_TEXTURE
local safeSet = Util.safeSet
local componentMul = Util.componentMul
local evaluateKeysVector = Util.evaluateKeysVector
local uvRectAt = Util.uvRectAt
local color3 = Util.color3
local rotationZXY = Util.rotationZXY
local spriteGeometry = Sampling.spriteGeometry
local visualSizeMultiplierAt = Sampling.visualSizeMultiplierAt
local samplePositionEasingState = Sampling.samplePositionEasingState
local sampleRotationEasingState = Sampling.sampleRotationEasingState
local easedStateVector = Sampling.easedStateVector
local randomVectorPayload = Sampling.randomVectorPayload
local spawnOffsetForIndex = Sampling.spawnOffsetForIndex
local sampleScaleState = Sampling.sampleScaleState
local scaleStateVector = Sampling.scaleStateVector
local billboardMode = Sampling.billboardMode
local shouldUseSpriteParts = Sampling.shouldUseSpriteParts
local inheritedScaleForNode = Sampling.inheritedScaleForNode
local textureForNode = Appearance.textureForNode
local setSpriteVisualState = Appearance.setSpriteVisualState
local color3At = Appearance.color3At
local spriteTransparencyAt = Appearance.spriteTransparencyAt
local billboardCFrame = Appearance.billboardCFrame
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle
local nodeLocalDelay = Timing.nodeLocalDelay

local Quads = {}

local function createSpritePlane(
	node: EffectNode,
	targetPart: BasePart,
	worldCFrame: CFrame,
	texture,
	unitScale: number,
	particleSizeScale: number,
	parentScale: Vector3,
	initialScaleVector: Vector3,
	controller
): BasePart
	local geometry = spriteGeometry(node)
	local startSize = componentMul(initialScaleVector, parentScale)
		* unitScale
		* particleSizeScale
		* visualSizeMultiplierAt(node, 0)
	local startWidth = math.max(0.01, math.abs(startSize.X))
	local startHeight = math.max(0.01, math.abs(startSize.Y))
	local part = Instance.new("Part")
	part.Name = "Sprite_" .. tostring(node.name)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Transparency = 1
	part.Size = Vector3.new(geometry.width * startWidth, geometry.height * startHeight, 0.01)
	part.CFrame = worldCFrame * CFrame.new(geometry.centerX * startWidth, geometry.centerY * startHeight, 0)
	part.Parent = targetPart

	if texture == nil or texture == "" then
		-- Untextured Effekseer sprites render as plain colored quads.
		part.Material = if node.alphaBlend == 2 then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.Color = color3(node.color)
	elseif node.uv then
		-- ImageLabels support ImageRectOffset/Size, which Decals do not, so UV
		-- cropping, sheet animation, and scrolling all go through SurfaceGuis.
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local gui = Instance.new("SurfaceGui")
			gui.Name = "EffekseerSpriteGui"
			gui.Face = face
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 128
			gui.LightInfluence = 0
			gui.AlwaysOnTop = false
			safeSet(gui, "Brightness", if node.alphaBlend == 2 then 2 else 1)

			local image = Instance.new("ImageLabel")
			image.Name = "EffekseerSprite"
			image.BackgroundTransparency = 1
			image.BorderSizePixel = 0
			image.Size = UDim2.fromScale(1, 1)
			image.ImageColor3 = color3(node.color)
			image.ImageTransparency = 1
			if typeof(texture) == "Content" then
				local ok = pcall(function()
					(image :: any).ImageContent = texture
				end)
				if not ok then
					safeSet(image, "Image", texture)
				end
			else
				image.Image = texture
			end
			local offset, rectSize = uvRectAt(node.uv :: UVPayload, 0)
			if offset and rectSize then
				image.ImageRectOffset = offset
				image.ImageRectSize = rectSize
			end
			image.Parent = gui
			gui.Parent = part
		end
	else
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local decal = Instance.new("Decal")
			decal.Name = "EffekseerSprite"
			decal.Face = face
			decal.Color3 = color3(node.color)
			decal.Transparency = 1
			if typeof(texture) == "Content" then
				local ok = pcall(function()
					(decal :: any).ColorMapContent = texture
				end)
				if not ok then
					safeSet(decal, "TextureContent", texture)
				end
			else
				decal.Texture = texture
			end
			decal.Parent = part
		end
	end

	table.insert(controller._instances, part)
	table.insert(controller._parts, part)
	return part
end

local function updateSpritePlane(
	node: EffectNode,
	part: BasePart,
	spawnRootCFrame: CFrame,
	billboard: number,
	initialPosition: Vector3,
	velocity: Vector3,
	acceleration: Vector3,
	initialRotation: Vector3,
	rotationSpeed: Vector3,
	lifeSeconds: number,
	frameRate: number,
	unitScale: number,
	particleSizeScale: number,
	parentScale: Vector3,
	scaleState,
	easingStates,
	controller
)
	local geometry = spriteGeometry(node)
	local startClock = os.clock()
	local positionKeys = node.transform.positionKeys
	local rotationKeys = node.transform.rotation.rotationKeys
	local positionEasingState = if easingStates then easingStates.position else nil
	local rotationEasingState = if easingStates then easingStates.rotation else nil
	local uv = node.uv
	local animatedUV = uv ~= nil and (uv.type == 2 or uv.type == 3)
	local hasVisualChildren = false
	for _, child in part:GetDescendants() do
		if child:IsA("Decal") or child:IsA("ImageLabel") then
			hasVisualChildren = true
			break
		end
	end

	while controller._alive and part.Parent do
		local ageSeconds = os.clock() - startClock
		if ageSeconds >= lifeSeconds then
			break
		end

		local ageFrames = ageSeconds * frameRate
		local t = math.clamp(ageSeconds / math.max(lifeSeconds, 1 / frameRate), 0, 1)
		local accelerationTerm = acceleration * (0.5 * ageFrames * ageFrames)
		local localPosition
		if positionKeys then
			localPosition = initialPosition + evaluateKeysVector(positionKeys, ageFrames) + accelerationTerm
		elseif positionEasingState then
			localPosition = initialPosition + easedStateVector(positionEasingState, t) + accelerationTerm
		else
			localPosition = initialPosition + velocity * ageFrames + accelerationTerm
		end
		local rotation
		if rotationKeys then
			rotation = evaluateKeysVector(rotationKeys, ageFrames)
		elseif rotationEasingState then
			rotation = easedStateVector(rotationEasingState, t)
		else
			rotation = initialRotation + rotationSpeed * ageFrames
		end
		local baseCFrame = spawnRootCFrame
			* CFrame.new(localPosition * unitScale)
			* rotationZXY({ x = rotation.X, y = rotation.Y, z = rotation.Z })
		local orientedCFrame = billboardCFrame(baseCFrame, billboard, velocity)
		local scaleVector = componentMul(scaleStateVector(scaleState, t, ageFrames), parentScale)
			* unitScale
			* particleSizeScale
			* visualSizeMultiplierAt(node, t)
		local width = math.max(0.01, math.abs(scaleVector.X))
		local height = math.max(0.01, math.abs(scaleVector.Y))

		part.Size = Vector3.new(geometry.width * width, geometry.height * height, 0.01)
		part.CFrame = orientedCFrame * CFrame.new(geometry.centerX * width, geometry.centerY * height, 0)
		if hasVisualChildren then
			local rectOffset: Vector2? = nil
			local rectSize: Vector2? = nil
			if uv and animatedUV then
				rectOffset, rectSize = uvRectAt(uv, ageFrames)
			end
			for _, child in part:GetDescendants() do
				if child:IsA("Decal") or child:IsA("ImageLabel") then
					setSpriteVisualState(node, child, true, ageSeconds, lifeSeconds, frameRate)
					if rectOffset and rectSize and child:IsA("ImageLabel") then
						child.ImageRectOffset = rectOffset
						child.ImageRectSize = rectSize
					end
				end
			end
		else
			part.Color = color3At(node, t)
			part.Transparency = spriteTransparencyAt(node, ageSeconds, lifeSeconds, frameRate)
		end

		RunService.Heartbeat:Wait()
	end

	if part.Parent then
		part:Destroy()
	end
end

-- `visit` is the runtime's visitNodes; injected so child subtrees can be played
-- on each spawned quad without a circular module dependency.
function Quads.scheduleSpriteParts(
	node: EffectNode,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	controller,
	parentScale: Vector3,
	inheritedDelaySeconds: number?,
	visit
): boolean
	if not node.rendered or (node.rendererType ~= "Sprite" and node.rendererType ~= "Ring") then
		return false
	end

	-- An empty texture is allowed: Effekseer renders untextured sprites as plain
	-- colored quads, and bailing out here would also silently drop the child nodes.
	local fallbackTexture = if node.rendererType == "Ring" then RING_FALLBACK_TEXTURE else nil
	local texture = textureForNode(node, options, fallbackTexture, true)

	local frameRate, maxGeneration, generationSeconds, offsetSeconds, nodeInfinite, lifeMax =
		visualTiming(node, effect, options, inheritedDelaySeconds)
	if not shouldUseSpriteParts(node, maxGeneration, options) then
		return false
	end

	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil
	local marker = Instance.new("Folder")
	marker.Name = "EffekseerSpriteParts_" .. tostring(node.id) .. "_" .. tostring(node.name)
	marker.Parent = targetPart
	table.insert(controller._instances, marker)

	local spawnCounter = 0
	local function spawnSpritePart(): boolean
		if not controller._alive or not marker.Parent or not targetPart.Parent then
			return false
		end

		spawnCounter += 1
		local spawnRootCFrame = targetPart.CFrame * rootCFrame
		local positionEasingState = samplePositionEasingState(node, parentScale)
		local rotationEasingState = sampleRotationEasingState(node)
		-- Baked position keys and sampled easing endpoints already contain the
		-- spawn position, so only the generation-location offset applies then.
		local baseOffset = if node.transform.positionKeys or positionEasingState
			then Vector3.zero
			else randomVectorPayload(node.transform.positionRange, Vector3.zero)
		local initialPosition = componentMul(baseOffset + spawnOffsetForIndex(node, spawnCounter), parentScale)
		local velocity = componentMul(randomVectorPayload(node.transform.velocity, Vector3.zero), parentScale)
		local acceleration = componentMul(randomVectorPayload(node.transform.acceleration, Vector3.zero), parentScale)
		local initialRotation = if rotationEasingState
			then easedStateVector(rotationEasingState, 0)
			else randomVectorPayload(node.transform.rotation.rotation3, Vector3.zero)
		local rotationSpeed = randomVectorPayload(node.transform.rotation.speed3, Vector3.zero)
		local scaleState = sampleScaleState(node)
		local initialScaleVector = scaleStateVector(scaleState, 0, 0)
		local initialVisualPosition = if positionEasingState
			then initialPosition + positionEasingState.start
			else initialPosition
		local initialCFrame = spawnRootCFrame
			* CFrame.new(initialVisualPosition * unitScale)
			* rotationZXY({ x = initialRotation.X, y = initialRotation.Y, z = initialRotation.Z })
		initialCFrame = billboardCFrame(initialCFrame, billboardMode(node), velocity)
		local part = createSpritePlane(
			node,
			targetPart,
			initialCFrame,
			texture,
			unitScale,
			particleSizeScale,
			parentScale,
			initialScaleVector,
			controller
		)
		if visit and node.children and #node.children > 0 then
			visit(
				node.children,
				part,
				CFrame.identity,
				effect,
				options,
				controller,
				componentMul(parentScale, inheritedScaleForNode(node)),
				(inheritedDelaySeconds or 0) + nodeLocalDelay(node, effect)
			)
		end
		task.spawn(function()
			updateSpritePlane(
				node,
				part,
				spawnRootCFrame,
				billboardMode(node),
				initialPosition,
				velocity,
				acceleration,
				initialRotation,
				rotationSpeed,
				lifeMax,
				frameRate,
				unitScale,
				particleSizeScale,
				parentScale,
				scaleState,
				{ position = positionEasingState, rotation = rotationEasingState },
				controller
			)
		end)
		return true
	end

	repeatEveryCycle(
		controller,
		marker,
		offsetSeconds,
		cycleSeconds,
		function(cycleOffset: number, activeCycleSeconds: number?)
			if nodeInfinite then
				task.spawn(function()
					local startClock = os.clock()
					local activeSeconds = if activeCycleSeconds
						then math.max(0.03, activeCycleSeconds - (cycleOffset or 0))
						else nil
					while controller._alive and marker.Parent and targetPart.Parent do
						if activeSeconds and os.clock() - startClock >= activeSeconds then
							break
						end
						if not spawnSpritePart() then
							break
						end
						task.wait(generationSeconds)
					end
				end)
				return
			end

			for index = 1, math.max(0, maxGeneration) do
				task.delay((index - 1) * generationSeconds, spawnSpritePart)
			end
		end
	)

	return true
end

return Quads
