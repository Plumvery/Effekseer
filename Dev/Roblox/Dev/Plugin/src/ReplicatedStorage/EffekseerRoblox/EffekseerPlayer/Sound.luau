--!nonstrict
-- Node sound playback (volume/pitch randomization, delay, loop cycles).

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))
local Sampling = require(script.Parent:WaitForChild("Sampling"))
local Timing = require(script.Parent:WaitForChild("Timing"))

type EffectNode = Types.EffectNode
type EffectData = Types.EffectData
type PlayOptions = Types.PlayOptions

local assetMapValue = Util.assetMapValue
local rangeValue = Util.rangeValue
local randomRangePayload = Sampling.randomRangePayload
local visualTiming = Timing.visualTiming
local effectLoopEnabled = Timing.effectLoopEnabled
local effectCycleSeconds = Timing.effectCycleSeconds
local repeatEveryCycle = Timing.repeatEveryCycle

local Sound = {}

function Sound.scheduleSound(
	node: EffectNode,
	targetPart: BasePart,
	effect: EffectData,
	options: PlayOptions,
	controller,
	inheritedDelaySeconds: number?
)
	local soundPayload = node.sound
	if not soundPayload then
		return
	end

	local asset: any = nil
	if options.assetMap then
		asset = assetMapValue(options.assetMap, soundPayload.wave, nil)
			or assetMapValue(options.assetMap, "Sound/" .. soundPayload.wave, nil)
	end
	if asset == nil and soundPayload.asset and soundPayload.asset ~= "" then
		asset = soundPayload.asset
	end
	if asset == nil or asset == "" then
		return
	end

	local frameRate = effect.frameRate or 60
	local _, _, _, offsetSeconds = visualTiming(node, effect, options, inheritedDelaySeconds)
	local delaySeconds = offsetSeconds + math.max(0, rangeValue(soundPayload.delay, "center", 0) / frameRate)
	local cycleSeconds = if effectLoopEnabled(effect, options) then effectCycleSeconds(effect, frameRate) else nil

	local sound = Instance.new("Sound")
	sound.Name = "EffekseerSound_" .. tostring(node.id) .. "_" .. tostring(node.name)
	if typeof(asset) == "Content" then
		local ok = pcall(function()
			(sound :: any).SoundId = asset
		end)
		if not ok then
			return
		end
	else
		sound.SoundId = asset
	end
	sound.Parent = targetPart
	table.insert(controller._instances, sound)

	repeatEveryCycle(controller, sound, delaySeconds, cycleSeconds, function()
		if not controller._alive or not sound.Parent then
			return
		end
		sound.Volume = randomRangePayload(soundPayload.volume, 1)
		-- Effekseer pitch is in octaves around 0.
		sound.PlaybackSpeed = 2 ^ randomRangePayload(soundPayload.pitch, 0)
		sound:Play()
	end)
end

return Sound
