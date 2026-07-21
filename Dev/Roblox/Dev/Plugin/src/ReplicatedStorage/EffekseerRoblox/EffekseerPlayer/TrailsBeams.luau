--!nonstrict
-- Ribbon/Track rendering. Effekseer ribbons connect the particles a node emits
-- over time; a moving tracer part with a Trail reproduces that path far more
-- faithfully than a static Beam, so trails are used whenever the node actually
-- moves its particles and beams remain the static fallback.

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
local rangeValue = Util.rangeValue
local componentMul = Util.componentMul
local averageXYVector = Util.averageXYVector
local evaluateKeysVector = Util.evaluateKeysVector
local samplePositionEasingState = Sampling.samplePositionEasingState
local easedStateVector = Sampling.easedStateVector
local randomVectorPayload = Sampling.randomVectorPayload
local spawnOffsetForIndex = Sampling.spawnOffsetForIndex
local textureForNode = Appearance.textureForNode
local colorSequence = Appearance.colorSequence
local transparencySequence = Appearance.transparencySequence
local blendLightEmission = Appearance.blendLightEmission
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle
local nodeCFrame = Rig.nodeCFrame
local createAttachment = Rig.createAttachment

local TrailsBeams = {}

function TrailsBeams.scheduleTrails(
	node: EffectNode,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	controller,
	parentScale: Vector3,
	inheritedDelaySeconds: number?
): boolean
	if not node.rendered or (node.rendererType ~= "Ribbon" and node.rendererType ~= "Track") then
		return false
	end

	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1
	local frameRate, maxGeneration, generationSeconds, offsetSeconds, nodeInfinite, lifeMax =
		visualTiming(node, effect, options, inheritedDelaySeconds)

	local speedStuds = (node.transform.speed.max or 0) * unitScale * frameRate
	if speedStuds < 0.05 and not node.transform.positionKeys and not (node.transform :: any).positionEasing then
		-- The trail would collapse to a point; the static Beam is a better fit.
		return false
	end

	local visualScale = unitScale * particleSizeScale * averageXYVector(parentScale)
	local beamVisual = if node.visual then node.visual.beam else nil
	local width =
		math.max(0.02, (if beamVisual then beamVisual.width else node.transform.size.start or 1) * visualScale)
	local texture = textureForNode(node, options, nil)
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil
	local windowSeconds = if nodeInfinite then nil else math.max(0.03, math.max(1, maxGeneration) * generationSeconds)

	local marker = Instance.new("Folder")
	marker.Name = "EffekseerTrail_" .. tostring(node.id) .. "_" .. tostring(node.name)
	marker.Parent = targetPart
	table.insert(controller._instances, marker)

	local function spawnTracer(): boolean
		if not controller._alive or not marker.Parent or not targetPart.Parent then
			return false
		end

		local spawnRootCFrame = targetPart.CFrame * rootCFrame
		local positionKeys = node.transform.positionKeys
		local positionEasingState = samplePositionEasingState(node, parentScale)
		local baseOffset = if positionKeys or positionEasingState
			then Vector3.zero
			else randomVectorPayload(node.transform.positionRange, Vector3.zero)
		local initialPosition = componentMul(baseOffset + spawnOffsetForIndex(node, 1), parentScale)
		local velocity = componentMul(randomVectorPayload(node.transform.velocity, Vector3.zero), parentScale)
		local acceleration = componentMul(randomVectorPayload(node.transform.acceleration, Vector3.zero), parentScale)

		local tracer = Instance.new("Part")
		tracer.Name = "EffekseerTracer_" .. tostring(node.name)
		tracer.Anchored = true
		tracer.CanCollide = false
		tracer.CanQuery = false
		tracer.CanTouch = false
		tracer.CastShadow = false
		tracer.Massless = true
		tracer.Transparency = 1
		tracer.Size = Vector3.new(0.05, 0.05, 0.05)
		tracer.CFrame = spawnRootCFrame * CFrame.new(initialPosition * unitScale)
		tracer.Parent = targetPart
		table.insert(controller._instances, tracer)

		local attachment0 = Instance.new("Attachment")
		attachment0.Position = Vector3.new(0, width * 0.5, 0)
		attachment0.Parent = tracer
		local attachment1 = Instance.new("Attachment")
		attachment1.Position = Vector3.new(0, -width * 0.5, 0)
		attachment1.Parent = tracer

		local trail = Instance.new("Trail")
		trail.Name = "Trail_" .. tostring(node.name)
		trail.Attachment0 = attachment0
		trail.Attachment1 = attachment1
		trail.Lifetime = lifeMax
		trail.Color = colorSequence(node)
		trail.Transparency = transparencySequence(node, lifeMax, frameRate)
		trail.LightEmission = blendLightEmission(node)
		trail.LightInfluence = 0
		trail.FaceCamera = true
		trail.MinLength = 0
		if texture ~= "" then
			trail.Texture = texture
			safeSet(trail, "TextureMode", Enum.TextureMode.Stretch)
			trail.TextureLength = 1
		end
		trail.Parent = tracer

		task.spawn(function()
			local startClock = os.clock()
			while controller._alive and tracer.Parent do
				local ageSeconds = os.clock() - startClock
				if ageSeconds >= lifeMax then
					break
				end
				local ageFrames = ageSeconds * frameRate
				local accelerationTerm = acceleration * (0.5 * ageFrames * ageFrames)
				local localPosition
				if positionKeys then
					localPosition = initialPosition + evaluateKeysVector(positionKeys, ageFrames) + accelerationTerm
				elseif positionEasingState then
					local t = math.clamp(ageSeconds / math.max(lifeMax, 1 / frameRate), 0, 1)
					localPosition = initialPosition + easedStateVector(positionEasingState, t) + accelerationTerm
				else
					localPosition = initialPosition + velocity * ageFrames + accelerationTerm
				end
				tracer.CFrame = spawnRootCFrame * CFrame.new(localPosition * unitScale)
				RunService.Heartbeat:Wait()
			end
			if trail.Parent then
				trail.Enabled = false
			end
			task.delay(lifeMax, function()
				if tracer.Parent then
					tracer:Destroy()
				end
			end)
		end)
		return true
	end

	repeatEveryCycle(
		controller,
		marker,
		offsetSeconds,
		cycleSeconds,
		function(cycleOffset: number, activeCycleSeconds: number?)
			task.spawn(function()
				local startClock = os.clock()
				local windowLimit = windowSeconds
				if nodeInfinite then
					windowLimit = if activeCycleSeconds
						then math.max(0.03, activeCycleSeconds - (cycleOffset or 0))
						else nil
				end
				-- Overlapping tracers every particle lifetime keep a continuous
				-- ribbon while the node is generating.
				repeat
					if not spawnTracer() then
						break
					end
					task.wait(lifeMax)
				until not controller._alive
					or not marker.Parent
					or (windowLimit ~= nil and os.clock() - startClock >= windowLimit)
			end)
		end
	)
	return true
end

function TrailsBeams.createBeam(
	node: EffectNode,
	targetPart: BasePart,
	rootCFrame: CFrame,
	effect: EffectData,
	options: PlayOptions,
	parentScale: Vector3,
	controller
): Beam?
	if not node.rendered or (node.rendererType ~= "Ribbon" and node.rendererType ~= "Track") then
		return nil
	end

	local frameRate = effect.frameRate or 60
	local unitScale = options.unitScale or effect.unitScale or 0.01
	local particleSizeScale = options.particleSizeScale or effect.particleSizeScale or 1
	local inheritedVisualScale = averageXYVector(parentScale)
	local visualScale = unitScale * particleSizeScale * inheritedVisualScale
	local lifeMax = math.max(1 / frameRate, rangeValue(node.life, "max", 100) / frameRate)
	local beamVisual = if node.visual then node.visual.beam else nil
	local baseSize = math.max(0.05, (node.transform.size.start or 1) * visualScale)
	local width = math.max(0.02, (if beamVisual then beamVisual.width * visualScale else baseSize))
	local length = math.max(width * 2, (if beamVisual then beamVisual.length * visualScale else baseSize * 8))
	local center = nodeCFrame(node, rootCFrame, unitScale, parentScale)
	local half = length * 0.5

	local attachment0 = createAttachment(
		targetPart,
		"EffekseerBeam0_" .. tostring(node.id) .. "_" .. tostring(node.name),
		center * CFrame.new(-half, 0, 0),
		controller
	)
	local attachment1 = createAttachment(
		targetPart,
		"EffekseerBeam1_" .. tostring(node.id) .. "_" .. tostring(node.name),
		center * CFrame.new(half, 0, 0),
		controller
	)

	local beam = Instance.new("Beam")
	beam.Name = "Beam_" .. tostring(node.name)
	beam.Attachment0 = attachment0
	beam.Attachment1 = attachment1
	beam.Enabled = false
	beam.Width0 = width
	beam.Width1 = width
	beam.FaceCamera = true
	beam.Segments = 8
	beam.Color = colorSequence(node)
	beam.Transparency = transparencySequence(node, lifeMax, frameRate)
	beam.LightEmission = blendLightEmission(node)
	beam.LightInfluence = 0
	local texture = textureForNode(node, options, nil)
	if texture ~= "" then
		beam.Texture = texture
		beam.TextureLength = math.max(0.1, length)
		pcall(function()
			beam.TextureMode = Enum.TextureMode.Wrap
		end)
		local uv = node.uv
		if uv and uv.type == 3 and uv.scroll then
			-- Approximate Effekseer's UV scroll (px/frame) as texture cycles per second.
			local speed = uv.scroll.speed
			local sizeReference = math.max(1, math.abs(uv.size.x or 0), math.abs(uv.size.y or 0))
			local dominant = if math.abs(speed.y or 0) >= math.abs(speed.x or 0) then speed.y or 0 else speed.x or 0
			safeSet(beam, "TextureSpeed", (dominant / sizeReference) * frameRate)
		end
	end
	beam.Parent = targetPart
	table.insert(controller._instances, beam)
	table.insert(controller._beams, beam)

	return beam
end

function TrailsBeams.scheduleBeam(
	node: EffectNode,
	beam: Beam,
	effect: EffectData,
	options: PlayOptions,
	controller,
	inheritedDelaySeconds: number?
)
	local frameRate, _, _, offsetSeconds, nodeInfinite, _, duration =
		visualTiming(node, effect, options, inheritedDelaySeconds)
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil

	repeatEveryCycle(
		controller,
		beam,
		offsetSeconds,
		cycleSeconds,
		function(cycleOffset: number, activeCycleSeconds: number?)
			if not controller._alive or not beam.Parent then
				return
			end
			beam.Enabled = true

			local visibleSeconds = duration
			if nodeInfinite and activeCycleSeconds then
				visibleSeconds = math.max(0.03, activeCycleSeconds - cycleOffset)
			end
			if not nodeInfinite or activeCycleSeconds then
				task.delay(visibleSeconds, function()
					if beam.Parent then
						beam.Enabled = false
					end
				end)
			end
		end
	)
end

return TrailsBeams
