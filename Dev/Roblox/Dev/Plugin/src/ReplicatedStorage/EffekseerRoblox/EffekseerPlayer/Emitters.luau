--!nonstrict
-- ParticleEmitter construction and scheduling: spawn-shape hosts, velocity
-- alignment, ordered burst emission, and rate windows.

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))
local Appearance = require(script.Parent:WaitForChild("Appearance"))
local Timing = require(script.Parent:WaitForChild("Timing"))
local Rig = require(script.Parent:WaitForChild("Rig"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions

local NORMAL_IDS = Types.NORMAL_IDS
local RING_FALLBACK_TEXTURE = Types.RING_FALLBACK_TEXTURE
local safeSet = Util.safeSet
local rangeValue = Util.rangeValue
local vectorPayload = Util.vectorPayload
local componentMul = Util.componentMul
local averageXYVector = Util.averageXYVector
local numberRange = Util.numberRange
local alignYToDirection = Util.alignYToDirection
local hasSpawnShape = Sampling.hasSpawnShape
local spawnOffsetForIndex = Sampling.spawnOffsetForIndex
local vectorPayloadCenter = Sampling.vectorPayloadCenter
local particle2DRotationEnabled = Sampling.particle2DRotationEnabled
local shouldUseSpriteParts = Sampling.shouldUseSpriteParts
local textureForNode = Appearance.textureForNode
local colorSequence = Appearance.colorSequence
local transparencySequence = Appearance.transparencySequence
local sizeSequence = Appearance.sizeSequence
local blendLightEmission = Appearance.blendLightEmission
local particleOrientationForNode = Appearance.particleOrientationForNode
local tryApplyFlipbook = Appearance.tryApplyFlipbook
local nodeLifeFrames = Timing.nodeLifeFrames
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle
local emitBurst = Timing.emitBurst
local scheduleRateWindow = Timing.scheduleRateWindow
local nodeCFrame = Rig.nodeCFrame
local createAttachment = Rig.createAttachment
local createHostPart = Rig.createHostPart
local hasSpawnPositionRange = Rig.hasSpawnPositionRange
local spawnVolumeSize = Rig.spawnVolumeSize
local randomRangeOffset = Rig.randomRangeOffset

local Emitters = {}

local function emitBurstForNode(
	node: EffectNode,
	emitter: ParticleEmitter,
	count: number,
	generationSeconds: number,
	controller,
	baseCFrame: CFrame,
	unitScale: number,
	parentScale: Vector3
)
	local attachment = emitter.Parent
	local wantsOffsets = hasSpawnShape(node) or hasSpawnPositionRange(node)
	if not attachment or not attachment:IsA("Attachment") or not wantsOffsets then
		emitBurst(emitter, count, generationSeconds, controller)
		return
	end

	for index = 1, count do
		task.delay((index - 1) * generationSeconds, function()
			if not controller._alive or not emitter.Parent or not attachment.Parent then
				return
			end
			local offset = spawnOffsetForIndex(node, index) + randomRangeOffset(node)
			attachment.CFrame = baseCFrame * CFrame.new(componentMul(offset, parentScale) * unitScale)
			emitter:Emit(1)
			attachment.CFrame = baseCFrame
		end)
	end
end

function Emitters.createParticleEmitter(
	node: EffectNode,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	parentScale: Vector3,
	controller
): ParticleEmitter?
	if not node.rendered then
		return nil
	end
	if shouldUseSpriteParts(node, node.generation.max or 1, options) then
		return nil
	end
	if node.rendererType == "Ribbon" or node.rendererType == "Track" or node.rendererType == "Model" then
		return nil
	end

	local hasTexturePath = node.texturePath ~= nil and node.texturePath ~= ""
	local fallbackTexture = if node.rendererType == "Ring" and not hasTexturePath then RING_FALLBACK_TEXTURE else nil
	local texture = textureForNode(node, options, fallbackTexture)
	if hasTexturePath and texture == "" then
		return nil
	end

	local frameRate = effect.frameRate or 60
	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1
	local speedScale = options.speedScale or 1
	local inheritedSpeedScale = averageXYVector(parentScale)
	local lifeMin = math.max(1 / frameRate, nodeLifeFrames(node, effect, "min") / frameRate)
	local lifeMax = math.max(lifeMin, nodeLifeFrames(node, effect, "max") / frameRate)

	local localCFrame = nodeCFrame(node, rootCFrame, unitScale, parentScale)
	local emissionDirection = NORMAL_IDS[node.transform.emissionDirection] or Enum.NormalId.Top
	local velocityDirection = componentMul(vectorPayloadCenter(node.transform.velocity, Vector3.zero), parentScale)
	if velocityDirection.Magnitude > 1e-6 then
		-- Orient the emitter so +Y matches the real velocity direction instead of
		-- rounding the launch direction to the nearest world axis.
		localCFrame = localCFrame * alignYToDirection(velocityDirection)
		emissionDirection = Enum.NormalId.Top
	end

	local spawn = node.spawn
	local orderedSpawn = false
	if spawn then
		if spawn.type == 3 and spawn.circle and spawn.circle.order ~= 0 then
			orderedSpawn = true
		elseif spawn.type == 4 and spawn.line and spawn.line.order ~= 0 then
			orderedSpawn = true
		end
	end
	-- Ordered placements teleport a point attachment per burst emit; random shapes
	-- use a host part with a matching emitter shape.
	local wantsAttachmentSpawn = orderedSpawn and (node.generation.max or 1) ~= 0

	local emitterParent: Instance? = nil
	local shapeKind: string? = nil
	local hostName = "EffekseerVolume_" .. tostring(node.id) .. "_" .. tostring(node.name)
	if spawn and hasSpawnShape(node) and not wantsAttachmentSpawn then
		local inheritedScale = averageXYVector(parentScale)
		if spawn.type == 1 and spawn.sphere then
			local diameter = math.max(0.05, rangeValue(spawn.sphere.radius, "max", 0) * 2 * inheritedScale * unitScale)
			emitterParent =
				createHostPart(targetPart, hostName, localCFrame, Vector3.new(diameter, diameter, diameter), controller)
			shapeKind = "sphere"
		elseif spawn.type == 3 and spawn.circle then
			local circle = spawn.circle
			local diameter = math.max(0.05, rangeValue(circle.radius, "max", 0) * 2 * inheritedScale * unitScale)
			local orientation = CFrame.identity
			if circle.axis == 2 then
				-- Roblox discs lie in the XZ plane; Effekseer's ZAxis circles lie in XY.
				orientation = CFrame.Angles(math.pi / 2, 0, 0)
			elseif circle.axis == 0 then
				orientation = CFrame.Angles(0, 0, math.pi / 2)
			end
			emitterParent = createHostPart(
				targetPart,
				hostName,
				localCFrame * orientation,
				Vector3.new(diameter, 0.05, diameter),
				controller
			)
			shapeKind = "disc"
		elseif spawn.type == 4 and spawn.line then
			local fromCenter = vectorPayloadCenter(spawn.line.from, Vector3.zero)
			local toCenter = vectorPayloadCenter(spawn.line.to, Vector3.zero)
			local along = componentMul(toCenter - fromCenter, parentScale) * unitScale
			local middle = componentMul((fromCenter + toCenter) * 0.5, parentScale) * unitScale
			emitterParent = createHostPart(
				targetPart,
				hostName,
				localCFrame * CFrame.new(middle) * alignYToDirection(along),
				Vector3.new(0.05, math.max(0.05, along.Magnitude), 0.05),
				controller
			)
			shapeKind = "box"
		end
	end
	if not emitterParent then
		if hasSpawnPositionRange(node) and not wantsAttachmentSpawn then
			emitterParent = createHostPart(
				targetPart,
				hostName,
				localCFrame,
				spawnVolumeSize(node, unitScale, parentScale),
				controller
			)
			shapeKind = "box"
		else
			emitterParent = createAttachment(
				targetPart,
				"Effekseer_" .. tostring(node.id) .. "_" .. tostring(node.name),
				localCFrame,
				controller
			)
		end
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter_" .. tostring(node.name)
	emitter.Enabled = false
	emitter.Texture = texture
	emitter.Lifetime = numberRange(lifeMin, lifeMax)
	emitter.Rate = 0
	emitter.Speed = numberRange(
		(node.transform.speed.min or 0) * unitScale * frameRate * speedScale * inheritedSpeedScale,
		(node.transform.speed.max or 0) * unitScale * frameRate * speedScale * inheritedSpeedScale
	)
	-- ParticleEmitter.Acceleration is applied in world space, so rotate the
	-- effect-local vector by the target's orientation at creation time.
	local localAcceleration = componentMul(vectorPayload(node.transform.acceleration.center, Vector3.zero), parentScale)
		* unitScale
		* frameRate
		* frameRate
	emitter.Acceleration = (targetPart.CFrame * rootCFrame).Rotation * localAcceleration
	emitter.EmissionDirection = emissionDirection
	emitter.SpreadAngle = Vector2.new(node.transform.spreadAngle or 0, node.transform.spreadAngle or 0)
	emitter.Color = colorSequence(node)
	emitter.Transparency = transparencySequence(node, lifeMax, frameRate)
	emitter.Size = sizeSequence(node, unitScale, particleSizeScale, parentScale)
	emitter.LightEmission = blendLightEmission(node)
	emitter.LightInfluence = 0
	emitter.LockedToPart = false
	safeSet(emitter, "Orientation", particleOrientationForNode(node))
	if particle2DRotationEnabled(node) then
		emitter.Rotation = numberRange(
			rangeValue(node.transform.rotation.rotation, "min", 0),
			rangeValue(node.transform.rotation.rotation, "max", 0)
		)
		emitter.RotSpeed = numberRange(
			rangeValue(node.transform.rotation.speed, "min", 0) * frameRate,
			rangeValue(node.transform.rotation.speed, "max", 0) * frameRate
		)
	else
		emitter.Rotation = NumberRange.new(0)
		emitter.RotSpeed = NumberRange.new(0)
	end
	if shapeKind == "sphere" then
		pcall(function()
			emitter.Shape = Enum.ParticleEmitterShape.Sphere
		end)
		pcall(function()
			emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		end)
	elseif shapeKind == "disc" then
		pcall(function()
			emitter.Shape = Enum.ParticleEmitterShape.Disc
		end)
		pcall(function()
			emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		end)
	elseif shapeKind == "box" then
		pcall(function()
			emitter.Shape = Enum.ParticleEmitterShape.Box
		end)
		pcall(function()
			emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		end)
	end
	tryApplyFlipbook(emitter, node, frameRate)
	emitter.Parent = emitterParent
	table.insert(controller._emitters, emitter)

	return emitter
end

function Emitters.scheduleEmitter(
	node: EffectNode,
	emitter: ParticleEmitter,
	effect: EffectData,
	options: PlayOptions,
	controller,
	parentScale: Vector3,
	inheritedDelaySeconds: number?
)
	local frameRate, maxGeneration, generationSeconds, offsetSeconds, nodeInfinite =
		visualTiming(node, effect, options, inheritedDelaySeconds)
	local burstTaskLimit = options.burstTaskLimit or 200
	local unitScale = options.unitScale or effect.unitScale or 0.01
	local rate = 1 / generationSeconds
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil
	local attachment = emitter.Parent
	local baseCFrame = if attachment and attachment:IsA("Attachment") then attachment.CFrame else CFrame.identity

	if nodeInfinite then
		repeatEveryCycle(
			controller,
			emitter,
			offsetSeconds,
			cycleSeconds,
			function(cycleOffset: number, activeCycleSeconds: number?)
				scheduleRateWindow(emitter, rate, nil, controller, cycleOffset, activeCycleSeconds)
			end
		)
		return
	end

	maxGeneration = math.max(0, maxGeneration)
	if maxGeneration <= burstTaskLimit then
		repeatEveryCycle(controller, emitter, offsetSeconds, cycleSeconds, function()
			emitBurstForNode(
				node,
				emitter,
				maxGeneration,
				generationSeconds,
				controller,
				baseCFrame,
				unitScale,
				parentScale
			)
		end)
	else
		local duration = maxGeneration / rate
		repeatEveryCycle(controller, emitter, offsetSeconds, cycleSeconds, function()
			scheduleRateWindow(emitter, rate, duration, controller, nil, nil)
		end)
	end
end

return Emitters
