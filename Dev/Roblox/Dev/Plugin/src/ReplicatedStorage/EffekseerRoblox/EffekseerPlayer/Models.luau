--!nonstrict
-- Model nodes: MeshPart (or placeholder) visuals animated over the node's
-- lifetime — position, rotation, non-uniform scale, color, and fades.

local RunService = game:GetService("RunService")

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))
local Appearance = require(script.Parent:WaitForChild("Appearance"))
local Timing = require(script.Parent:WaitForChild("Timing"))
local Rig = require(script.Parent:WaitForChild("Rig"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions

local safeSet = Util.safeSet
local componentMul = Util.componentMul
local averageXYVector = Util.averageXYVector
local color3 = Util.color3
local rotationZXY = Util.rotationZXY
local evaluateKeysVector = Util.evaluateKeysVector
local sizeVectorAt = Sampling.sizeVectorAt
local samplePositionEasingState = Sampling.samplePositionEasingState
local sampleRotationEasingState = Sampling.sampleRotationEasingState
local easedStateVector = Sampling.easedStateVector
local randomVectorPayload = Sampling.randomVectorPayload
local spawnOffsetForIndex = Sampling.spawnOffsetForIndex
local sampleScaleState = Sampling.sampleScaleState
local scaleStateVector = Sampling.scaleStateVector
local modelAssetForNode = Appearance.modelAssetForNode
local textureForNode = Appearance.textureForNode
local color3At = Appearance.color3At
local spriteTransparencyAt = Appearance.spriteTransparencyAt
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle
local nodeCFrame = Rig.nodeCFrame

local Models = {}

function Models.createModelVisual(
	node: EffectNode,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	parentScale: Vector3,
	controller
): BasePart?
	if not node.rendered or node.rendererType ~= "Model" then
		return nil
	end

	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1
	local size = math.max(
		0.05,
		averageXYVector(componentMul(sizeVectorAt(node, 0), parentScale)) * unitScale * particleSizeScale
	)
	local modelAsset = modelAssetForNode(node, options)
	local part: BasePart

	if modelAsset and modelAsset ~= "" then
		local ok, meshPart = pcall(function()
			local mesh = Instance.new("MeshPart")
			mesh.MeshId = modelAsset
			local texture = textureForNode(node, options, nil)
			if texture ~= "" then
				mesh.TextureID = texture
			end
			return mesh
		end)
		part = if ok then meshPart :: BasePart else Instance.new("Part")
	else
		part = Instance.new("Part")
		safeSet(part, "Shape", Enum.PartType.Ball)
	end

	part.Name = "Model_" .. tostring(node.name)
	-- Anchored so scheduleModelPart can drive the CFrame each frame (PVA motion,
	-- rotation, and scale animation) while still following the target part.
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Material = if node.alphaBlend == 2 then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Color = color3(node.color)
	part.Size = Vector3.new(size, size, size)
	part.Transparency = 1
	part.CFrame = targetPart.CFrame * nodeCFrame(node, rootCFrame, unitScale, parentScale)
	part.Parent = targetPart

	table.insert(controller._instances, part)
	table.insert(controller._parts, part)

	return part
end

function Models.scheduleModelPart(
	node: EffectNode,
	part: BasePart,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	controller,
	parentScale: Vector3,
	inheritedDelaySeconds: number?
)
	local frameRate, _, _, offsetSeconds, nodeInfinite, lifeMax, duration =
		visualTiming(node, effect, options, inheritedDelaySeconds)
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil
	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1

	local function animate(activeSeconds: number?)
		task.spawn(function()
			local spawnRootCFrame = targetPart.CFrame * rootCFrame
			local positionKeys = node.transform.positionKeys
			local rotationKeys = node.transform.rotation.rotationKeys
			local positionEasingState = samplePositionEasingState(node, parentScale)
			local rotationEasingState = sampleRotationEasingState(node)
			local baseOffset = if positionKeys or positionEasingState
				then Vector3.zero
				else randomVectorPayload(node.transform.positionRange, Vector3.zero)
			local initialPosition = componentMul(baseOffset + spawnOffsetForIndex(node, 1), parentScale)
			local velocity = componentMul(randomVectorPayload(node.transform.velocity, Vector3.zero), parentScale)
			local acceleration =
				componentMul(randomVectorPayload(node.transform.acceleration, Vector3.zero), parentScale)
			local initialRotation = randomVectorPayload(node.transform.rotation.rotation3, Vector3.zero)
			local rotationSpeed = randomVectorPayload(node.transform.rotation.speed3, Vector3.zero)
			local scaleState = sampleScaleState(node)
			local startClock = os.clock()
			local limit = math.min(lifeMax, activeSeconds or lifeMax)

			while controller._alive and part.Parent do
				local ageSeconds = os.clock() - startClock
				if ageSeconds >= limit then
					break
				end
				local ageFrames = ageSeconds * frameRate
				local t = math.clamp(ageSeconds / math.max(lifeMax, 1 / frameRate), 0, 1)
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
				local scaleVector = componentMul(scaleStateVector(scaleState, t, ageFrames), parentScale)
					* unitScale
					* particleSizeScale
				part.CFrame = spawnRootCFrame
					* CFrame.new(localPosition * unitScale)
					* rotationZXY({ x = rotation.X, y = rotation.Y, z = rotation.Z })
				part.Size = Vector3.new(
					math.max(0.05, math.abs(scaleVector.X)),
					math.max(0.05, math.abs(scaleVector.Y)),
					math.max(0.05, math.abs(scaleVector.Z))
				)
				part.Color = color3At(node, t)
				part.Transparency = spriteTransparencyAt(node, ageSeconds, lifeMax, frameRate)
				RunService.Heartbeat:Wait()
			end

			if part.Parent then
				part.Transparency = 1
			end
		end)
	end

	repeatEveryCycle(
		controller,
		part,
		offsetSeconds,
		cycleSeconds,
		function(cycleOffset: number, activeCycleSeconds: number?)
			if not controller._alive or not part.Parent then
				return
			end
			local activeSeconds: number? = nil
			if nodeInfinite and activeCycleSeconds then
				activeSeconds = math.max(0.03, activeCycleSeconds - cycleOffset)
			elseif not nodeInfinite then
				activeSeconds = duration
			end
			animate(activeSeconds)
		end
	)
end

return Models
