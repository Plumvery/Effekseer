--!nonstrict
-- Easing curve sampling: legacy StartSpeed/EndSpeed cubics, the 1.8 standard
-- easing functions, and 3-point middle values.

local Xml = require(script.Parent:WaitForChild("Xml"))

local Easing = {}

local EASING_SAMPLE_COUNT = 13

-- Exact port of the runtime's getEaseOutBounce (Effekseer.Easing.h).
local function easeOutBounceValue(t: number): number
	if t < 4 / 11 then
		t = t / 4 * 11
		return t * t
	end
	if t < 8 / 11 then
		t = t - 4 / 11 - 2 / 11
		return 1 + (t * t - (2 / 11) * (2 / 11)) * 8
	end
	if t < 10 / 11 then
		t = t - 8 / 11 - 1 / 11
		return 1 + (t * t - (1 / 11) * (1 / 11)) * 8
	end
	t = t - 10 / 11 - 0.5 / 11
	return 1 + (t * t - (0.5 / 11) * (0.5 / 11)) * 8
end

local function easeBack(t: number): number
	local c = 1.8
	return (c + 1) * t * t * t - c * t * t
end

-- Effekseer EasingType values 10..62 (Effekseer.Easing.h getEaseValue).
local function standardEasingValue(easingType: number, t: number): number?
	if easingType >= 10 and easingType <= 42 then
		local power = math.floor(easingType / 10) + 1
		local variant = easingType % 10
		if variant == 0 then
			return t ^ power
		end
		if variant == 1 then
			return 1 - (1 - t) ^ power
		end
		if t <= 0.5 then
			return (t * 2) ^ power * 0.5
		end
		return 1 - ((1 - t) * 2) ^ power * 0.5
	end
	if easingType == 50 then
		return easeBack(t)
	end
	if easingType == 51 then
		return 1 - easeBack(1 - t)
	end
	if easingType == 52 then
		return if t <= 0.5 then easeBack(t * 2) * 0.5 else 1 - easeBack((1 - t) * 2) * 0.5
	end
	if easingType == 60 then
		return 1 - easeOutBounceValue(1 - t)
	end
	if easingType == 61 then
		return easeOutBounceValue(t)
	end
	if easingType == 62 then
		return if t <= 0.5
			then (1 - easeOutBounceValue(1 - t * 2)) * 0.5
			else easeOutBounceValue((t - 0.5) * 2) * 0.5 + 0.5
	end
	return nil
end

-- Returns sampled easing progress values (uniform 0..1 times) or nil when linear.
function Easing.easingProgressValues(easingNode)
	if not easingNode then
		return nil
	end
	local easingType = Xml.intAt(easingNode, "Type", 0)
	local startSpeed = Xml.numberAt(easingNode, "StartSpeed", 0)
	local endSpeed = Xml.numberAt(easingNode, "EndSpeed", 0)
	if easingType == 1 then
		return nil
	end

	local evaluate
	if easingType == 0 then
		if startSpeed == 0 and endSpeed == 0 then
			return nil
		end
		-- MathUtl.Easing: speeds are slope angles offset from the linear 45 degrees.
		local g1 = math.tan((startSpeed + 45) / 180 * math.pi)
		local g2 = math.tan((endSpeed + 45) / 180 * math.pi)
		local c = g1
		local a = g2 - g1 - (1 - c) * 2
		local b = (g2 - g1 - a * 3) / 2
		evaluate = function(t: number): number
			return a * t * t * t + b * t * t + c * t
		end
	else
		if standardEasingValue(easingType, 0.5) == nil then
			return nil
		end
		evaluate = function(t: number): number
			return standardEasingValue(easingType, t) :: number
		end
	end

	local values = {}
	for index = 0, EASING_SAMPLE_COUNT - 1 do
		local value = evaluate(index / (EASING_SAMPLE_COUNT - 1))
		table.insert(values, math.floor(value * 1e6 + 0.5) / 1e6)
	end
	return values
end

function Easing.easingMiddleVectorAt(easingNode, start, finish)
	if not easingNode or not Xml.boolAt(easingNode, "IsMiddleEnabled", false) then
		return nil
	end
	local defaults = {
		x = ((start.center.x or 0) + (finish.center.x or 0)) * 0.5,
		y = ((start.center.y or 0) + (finish.center.y or 0)) * 0.5,
		z = ((start.center.z or 0) + (finish.center.z or 0)) * 0.5,
	}
	return Xml.randomVectorAt(easingNode, "Middle", defaults)
end

return Easing
