--!nonstrict
-- Node lifetimes, generation windows, loop cycles, and the shared scheduling
-- primitives built on top of them.

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions

local rangeValue = Util.rangeValue

local Timing = {}

-- Life in frames; "delete when life expires = false" nodes live for the whole effect timeline instead.
function Timing.nodeLifeFrames(node: EffectNode, effect: EffectData, key: string): number
	local frames = rangeValue(node.life, key, 100)
	if node.life.infinite then
		local durationFrames = effect.durationFrames or 0
		if durationFrames <= 0 then
			durationFrames = math.max(0, (effect.endFrame or 0) - (effect.startFrame or 0))
		end
		frames = math.max(frames, if durationFrames > 0 then durationFrames else 600)
	end
	return frames
end

function Timing.visualTiming(node: EffectNode, effect: EffectData, options: PlayOptions, inheritedDelaySeconds: number?)
	local frameRate = effect.frameRate or 60
	local maxGeneration = node.generation.max or 1
	local generationFrames = math.max(0.001, rangeValue(node.generation.time, "center", 1))
	local generationSeconds = generationFrames / frameRate
	local offsetSeconds = (inheritedDelaySeconds or 0)
		+ math.max(0, rangeValue(node.generation.offset, "center", 0) / frameRate)
	local nodeInfinite = maxGeneration == 0
	local lifeMax = math.max(1 / frameRate, Timing.nodeLifeFrames(node, effect, "max") / frameRate)
	local duration = if nodeInfinite
		then 0
		else math.max(lifeMax, math.max(1, maxGeneration) * generationSeconds + lifeMax)
	return frameRate, maxGeneration, generationSeconds, offsetSeconds, nodeInfinite, lifeMax, duration
end

function Timing.nodeLocalDelay(node: EffectNode, effect: EffectData): number
	local frameRate = effect.frameRate or 60
	return math.max(0, rangeValue(node.generation.offset, "center", 0) / frameRate)
end

function Timing.effectLoopEnabled(effect: EffectData, options: PlayOptions): boolean
	return options.loop == true or (options.loop == nil and effect.isLoop == true)
end

function Timing.effectCycleSeconds(effect: EffectData, frameRate: number): number?
	local durationFrames = effect.durationFrames
	if not durationFrames or durationFrames <= 0 then
		durationFrames = math.max(0, (effect.endFrame or 0) - (effect.startFrame or 0))
	end
	if durationFrames and durationFrames > 0 then
		return durationFrames / frameRate
	end
	return nil
end

function Timing.repeatEveryCycle(controller, instance: Instance, offsetSeconds: number, cycleSeconds: number?, callback)
	if cycleSeconds and cycleSeconds > 0 then
		local cycleOffset = offsetSeconds % cycleSeconds
		task.spawn(function()
			task.wait(cycleOffset)
			while controller._alive and instance.Parent do
				callback(cycleOffset, cycleSeconds)
				task.wait(cycleSeconds)
			end
		end)
		return
	end

	task.delay(offsetSeconds, function()
		if controller._alive and instance.Parent then
			callback(offsetSeconds, nil)
		end
	end)
end

function Timing.disableEmitterAfter(emitter: ParticleEmitter, delaySeconds: number)
	task.delay(delaySeconds, function()
		if emitter.Parent then
			emitter.Enabled = false
			emitter.Rate = 0
		end
	end)
end

function Timing.emitBurst(emitter: ParticleEmitter, count: number, generationSeconds: number, controller)
	for index = 1, count do
		task.delay((index - 1) * generationSeconds, function()
			if not controller._alive or not emitter.Parent then
				return
			end
			emitter:Emit(1)
		end)
	end
end

function Timing.scheduleRateWindow(
	emitter: ParticleEmitter,
	rate: number,
	durationSeconds: number?,
	controller,
	cycleOffset: number?,
	cycleSeconds: number?
)
	if not controller._alive or not emitter.Parent then
		return
	end
	emitter.Rate = rate
	emitter.Enabled = true

	if durationSeconds then
		Timing.disableEmitterAfter(emitter, durationSeconds)
	elseif cycleSeconds then
		Timing.disableEmitterAfter(emitter, math.max(0.03, cycleSeconds - (cycleOffset or 0)))
	end
end

return Timing
