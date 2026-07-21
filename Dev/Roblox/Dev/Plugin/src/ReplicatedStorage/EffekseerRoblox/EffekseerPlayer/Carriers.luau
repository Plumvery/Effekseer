--!nonstrict
-- Emitter-path parents cannot attach children to their GPU particles, so an
-- invisible carrier part is spawned per parent particle instance instead. Each
-- carrier follows a sampled parent trajectory and hosts the child subtree, which
-- matches Effekseer's per-instance child generation far better than a single
-- static child emitter at the node origin.

local RunService = game:GetService("RunService")

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))
local Timing = require(script.Parent:WaitForChild("Timing"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions

local componentMul = Util.componentMul
local rotationZXY = Util.rotationZXY
local evaluateKeysVector = Util.evaluateKeysVector
local nodeMovesParticles = Sampling.nodeMovesParticles
local hasSpawnShape = Sampling.hasSpawnShape
local inheritedScaleForNode = Sampling.inheritedScaleForNode
local samplePositionEasingState = Sampling.samplePositionEasingState
local sampleRotationEasingState = Sampling.sampleRotationEasingState
local easedStateVector = Sampling.easedStateVector
local randomVectorPayload = Sampling.randomVectorPayload
local spawnOffsetForIndex = Sampling.spawnOffsetForIndex
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle

local Carriers = {}

-- `visit` is the runtime's visitNodes; injected so child subtrees can be played
-- on each carrier without a circular module dependency.
function Carriers.scheduleChildCarriers(
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
	if not node.children or #node.children == 0 then
		return false
	end

	local frameRate, maxGeneration, generationSeconds, offsetSeconds, nodeInfinite, lifeMax =
		visualTiming(node, effect, options, inheritedDelaySeconds)
	local carrierLimit = options.burstTaskLimit or 200
	if nodeInfinite then
		if lifeMax / generationSeconds > carrierLimit then
			return false
		end
	elseif maxGeneration > carrierLimit then
		return false
	end
	if not nodeInfinite and maxGeneration <= 1 and not nodeMovesParticles(node) and not hasSpawnShape(node) then
		-- A single static instance is equivalent to the plain child visit.
		return false
	end

	local unitScale = options.unitScale or effect.unitScale or 0.01
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil
	local childScale = componentMul(parentScale, inheritedScaleForNode(node))

	local marker = Instance.new("Folder")
	marker.Name = "EffekseerCarriers_" .. tostring(node.id) .. "_" .. tostring(node.name)
	marker.Parent = targetPart
	table.insert(controller._instances, marker)

	local spawnCounter = 0
	local function spawnCarrier(): boolean
		if not controller._alive or not marker.Parent or not targetPart.Parent then
			return false
		end

		spawnCounter += 1
		local spawnRootCFrame = targetPart.CFrame * rootCFrame
		local positionKeys = node.transform.positionKeys
		local rotationKeys = node.transform.rotation.rotationKeys
		local positionEasingState = samplePositionEasingState(node, parentScale)
		local rotationEasingState = sampleRotationEasingState(node)
		local baseOffset = if positionKeys or positionEasingState
			then Vector3.zero
			else randomVectorPayload(node.transform.positionRange, Vector3.zero)
		local initialPosition = componentMul(baseOffset + spawnOffsetForIndex(node, spawnCounter), parentScale)
		local velocity = componentMul(randomVectorPayload(node.transform.velocity, Vector3.zero), parentScale)
		local acceleration = componentMul(randomVectorPayload(node.transform.acceleration, Vector3.zero), parentScale)
		local initialRotation = if rotationEasingState
			then easedStateVector(rotationEasingState, 0)
			else randomVectorPayload(node.transform.rotation.rotation3, Vector3.zero)
		local rotationSpeed = randomVectorPayload(node.transform.rotation.speed3, Vector3.zero)

		local carrier = Instance.new("Part")
		carrier.Name = "EffekseerCarrier_" .. tostring(node.name)
		carrier.Anchored = true
		carrier.CanCollide = false
		carrier.CanQuery = false
		carrier.CanTouch = false
		carrier.CastShadow = false
		carrier.Massless = true
		carrier.Transparency = 1
		carrier.Size = Vector3.new(0.05, 0.05, 0.05)
		local startVisualPosition = if positionEasingState
			then initialPosition + positionEasingState.start
			else initialPosition
		carrier.CFrame = spawnRootCFrame
			* CFrame.new(startVisualPosition * unitScale)
			* rotationZXY({ x = initialRotation.X, y = initialRotation.Y, z = initialRotation.Z })
		carrier.Parent = targetPart
		table.insert(controller._instances, carrier)

		if visit then
			visit(node.children, carrier, CFrame.identity, effect, options, controller, childScale, 0)
		end

		task.spawn(function()
			local startClock = os.clock()
			while controller._alive and carrier.Parent do
				local ageSeconds = os.clock() - startClock
				if ageSeconds >= lifeMax then
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
				carrier.CFrame = spawnRootCFrame
					* CFrame.new(localPosition * unitScale)
					* rotationZXY({ x = rotation.X, y = rotation.Y, z = rotation.Z })
				RunService.Heartbeat:Wait()
			end
			if carrier.Parent then
				carrier:Destroy()
			end
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
						if not spawnCarrier() then
							break
						end
						task.wait(generationSeconds)
					end
				end)
				return
			end

			for index = 1, math.max(0, maxGeneration) do
				task.delay((index - 1) * generationSeconds, spawnCarrier)
			end
		end
	)
	return true
end

return Carriers
