--!nonstrict
-- Math over {x, y, z} vectors and {center, min, max} random ranges.

local VectorMath = {}

function VectorMath.vectorRangeFromVector(vector)
	return {
		center = { x = vector.x, y = vector.y, z = vector.z },
		min = { x = vector.x, y = vector.y, z = vector.z },
		max = { x = vector.x, y = vector.y, z = vector.z },
	}
end

function VectorMath.vectorMagnitude(vector): number
	return math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
end

function VectorMath.dominantDirection(vector): string
	-- Tie-break priority matches converter.js: Right, then Top, then Back.
	local axis = "Right"
	local value = vector.x
	if math.abs(vector.y) > math.abs(value) then
		axis = "Top"
		value = vector.y
	end
	if math.abs(vector.z) > math.abs(value) then
		axis = "Back"
		value = vector.z
	end
	if math.abs(value) < 1e-6 then
		return "Top"
	end
	if axis == "Right" and value < 0 then
		return "Left"
	end
	if axis == "Top" and value < 0 then
		return "Bottom"
	end
	if axis == "Back" and value < 0 then
		return "Front"
	end
	return axis
end

function VectorMath.spreadFromRange(velocity): number
	local center = velocity.center
	local maxDelta = 0
	for _, axis in ipairs({ "x", "y", "z" }) do
		maxDelta =
			math.max(maxDelta, math.abs(velocity.max[axis] - center[axis]), math.abs(center[axis] - velocity.min[axis]))
	end
	local speed = math.max(VectorMath.vectorMagnitude(center), 1e-6)
	return math.clamp((math.atan(maxDelta / speed) * 180 * 2) / math.pi, 0, 180)
end

function VectorMath.subtractVectors(a, b)
	return {
		x = (a.x or 0) - (b.x or 0),
		y = (a.y or 0) - (b.y or 0),
		z = (a.z or 0) - (b.z or 0),
	}
end

function VectorMath.addVectors(a, b)
	return {
		x = (a.x or 0) + (b.x or 0),
		y = (a.y or 0) + (b.y or 0),
		z = (a.z or 0) + (b.z or 0),
	}
end

function VectorMath.divideVector(vector, divisor: number)
	local safeDivisor = if math.abs(divisor) > 1e-6 then divisor else 1
	return {
		x = (vector.x or 0) / safeDivisor,
		y = (vector.y or 0) / safeDivisor,
		z = (vector.z or 0) / safeDivisor,
	}
end

function VectorMath.vectorVelocityFromRanges(start, finish, frames: number)
	return {
		center = VectorMath.divideVector(VectorMath.subtractVectors(finish.center, start.center), frames),
		min = VectorMath.divideVector(VectorMath.subtractVectors(finish.min, start.min), frames),
		max = VectorMath.divideVector(VectorMath.subtractVectors(finish.max, start.max), frames),
	}
end

function VectorMath.addVectorRanges(a, b)
	return {
		center = VectorMath.addVectors(a.center, b.center),
		min = VectorMath.addVectors(a.min, b.min),
		max = VectorMath.addVectors(a.max, b.max),
	}
end

function VectorMath.numberVelocityFromRanges(start, finish, frames: number)
	local safeFrames = if math.abs(frames) > 1e-6 then frames else 1
	local minValue = (finish.min - start.min) / safeFrames
	local maxValue = (finish.max - start.max) / safeFrames
	if minValue > maxValue then
		minValue, maxValue = maxValue, minValue
	end
	return {
		center = (finish.center - start.center) / safeFrames,
		min = minValue,
		max = maxValue,
	}
end

function VectorMath.averageXY(vector): number
	return (math.abs(vector.x or 0) + math.abs(vector.y or 0)) * 0.5
end

function VectorMath.scaleVector(vector)
	return {
		x = math.abs(vector.x or 0),
		y = math.abs(vector.y or 0),
		z = math.abs(vector.z or 0),
	}
end

function VectorMath.singleScaleVector(value: number)
	local safeValue = math.abs(value or 0)
	return { x = safeValue, y = safeValue, z = safeValue }
end

function VectorMath.scaleVectorRange(range, factor: number)
	local function scale(vector)
		return {
			x = (vector.x or 0) * factor,
			y = (vector.y or 0) * factor,
			z = (vector.z or 0) * factor,
		}
	end
	return { center = scale(range.center), min = scale(range.min), max = scale(range.max) }
end

return VectorMath
