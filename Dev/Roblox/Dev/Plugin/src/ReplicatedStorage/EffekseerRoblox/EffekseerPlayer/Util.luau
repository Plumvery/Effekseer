--!nonstrict
-- Generic helpers: safe property writes, asset-map lookups, payload readers,
-- math, curves, and rotation composition. No dependencies on other modules.

local Types = require(script.Parent:WaitForChild("Types"))

type VectorPayload = Types.VectorPayload
type RangePayload = Types.RangePayload
type BakedKeys = Types.BakedKeys
type UVPayload = Types.UVPayload

local Util = {}

function Util.safeSet(instance: Instance, property: string, value)
	pcall(function()
		(instance :: any)[property] = value
	end)
end

function Util.assetMapValue(assetMap: { [string]: any }, assetPath: string, prefix: string?): any
	local mapPrefix = prefix or ""
	local direct = assetMap[mapPrefix .. assetPath]
	if direct and direct ~= "" then
		return direct
	end

	local basename = string.match(assetPath, "[^/\\]+$")
	if basename then
		local named = assetMap[mapPrefix .. basename]
		if named and named ~= "" then
			return named
		end

		local textureNamed = assetMap[mapPrefix .. "Texture/" .. basename]
		if textureNamed and textureNamed ~= "" then
			return textureNamed
		end

		local modelNamed = assetMap[mapPrefix .. "Model/" .. basename]
		if modelNamed and modelNamed ~= "" then
			return modelNamed
		end
	end

	local lowered = string.lower(assetPath)
	local lowerDirect = assetMap[mapPrefix .. lowered]
	if lowerDirect and lowerDirect ~= "" then
		return lowerDirect
	end

	if basename then
		local lowerBasename = string.lower(basename)
		local lowerNamed = assetMap[mapPrefix .. lowerBasename]
		if lowerNamed and lowerNamed ~= "" then
			return lowerNamed
		end

		local lowerTextureNamed = assetMap[mapPrefix .. "texture/" .. lowerBasename]
		if lowerTextureNamed and lowerTextureNamed ~= "" then
			return lowerTextureNamed
		end

		local lowerModelNamed = assetMap[mapPrefix .. "model/" .. lowerBasename]
		if lowerModelNamed and lowerModelNamed ~= "" then
			return lowerModelNamed
		end
	end

	return nil
end

function Util.rangeValue(range: RangePayload?, key: string, fallback: number): number
	if range == nil then
		return fallback
	end

	local value = (range :: any)[key]
	if typeof(value) == "number" then
		return value
	end

	if typeof(range.center) == "number" then
		return range.center
	end

	return fallback
end

function Util.vectorPayload(value: VectorPayload?, fallback: Vector3?): Vector3
	local fallbackVector = fallback or Vector3.zero
	if value == nil then
		return fallbackVector
	end
	return Vector3.new(value.x or fallbackVector.X, value.y or fallbackVector.Y, value.z or fallbackVector.Z)
end

function Util.componentMul(a: Vector3, b: Vector3): Vector3
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end

function Util.averageXYVector(value: Vector3): number
	return (math.abs(value.X) + math.abs(value.Y)) * 0.5
end

function Util.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Util.evaluateKeysVector(keys: BakedKeys, frame: number): Vector3
	local frames = keys.frames
	local values = keys.values
	local count = #frames
	if count == 0 then
		return Vector3.zero
	end
	if frame <= frames[1] then
		local first = values[1]
		return Vector3.new(first.x or 0, first.y or 0, first.z or 0)
	end
	if frame >= frames[count] then
		local last = values[count]
		return Vector3.new(last.x or 0, last.y or 0, last.z or 0)
	end
	for index = 2, count do
		if frame <= frames[index] then
			local span = frames[index] - frames[index - 1]
			local t = if span > 1e-9 then (frame - frames[index - 1]) / span else 0
			local a = values[index - 1]
			local b = values[index]
			return Vector3.new(
				Util.lerp(a.x or 0, b.x or 0, t),
				Util.lerp(a.y or 0, b.y or 0, t),
				Util.lerp(a.z or 0, b.z or 0, t)
			)
		end
	end
	local last = values[count]
	return Vector3.new(last.x or 0, last.y or 0, last.z or 0)
end

-- Piecewise-linear lookup of a baked easing-progress curve (uniform 0..1 samples).
function Util.easedProgress(progress: { number }?, t: number): number
	if not progress or #progress < 2 then
		return t
	end
	local scaled = math.clamp(t, 0, 1) * (#progress - 1)
	local index = math.floor(scaled)
	local fraction = scaled - index
	local a = progress[index + 1]
	local b = progress[math.min(#progress, index + 2)]
	return a + (b - a) * fraction
end

-- Quadratic Lagrange through (0, start), (0.5, middle), (1, finish) —
-- approximates Effekseer's 3-point easing spline.
function Util.threePointNumber(startValue: number, middleValue: number, finishValue: number, t: number): number
	return startValue * (2 * (t - 0.5) * (t - 1)) + middleValue * (-4 * t * (t - 1)) + finishValue * (2 * t * (t - 0.5))
end

function Util.threePointVector(startValue: Vector3, middleValue: Vector3, finishValue: Vector3, t: number): Vector3
	return startValue * (2 * (t - 0.5) * (t - 1)) + middleValue * (-4 * t * (t - 1)) + finishValue * (2 * t * (t - 0.5))
end

function Util.alignYToDirection(direction: Vector3): CFrame
	if direction.Magnitude < 1e-6 then
		return CFrame.identity
	end
	local up = direction.Unit
	local reference = if math.abs(up:Dot(Vector3.xAxis)) > 0.99 then Vector3.zAxis else Vector3.xAxis
	local right = up:Cross(reference).Unit
	return CFrame.fromMatrix(Vector3.zero, right, up)
end

function Util.uvRectAt(uv: UVPayload, ageFrames: number): (Vector2?, Vector2?)
	local sizeX = uv.size and uv.size.x or 0
	local sizeY = uv.size and uv.size.y or 0
	if sizeX <= 0 or sizeY <= 0 then
		return nil, nil
	end
	local startX = uv.start and uv.start.x or 0
	local startY = uv.start and uv.start.y or 0

	if uv.type == 2 and uv.animation then
		local animation = uv.animation
		local total = math.max(1, animation.countX * animation.countY)
		local frameIndex = math.floor(ageFrames / math.max(1, animation.frameLength)) + (animation.startSheet or 0)
		if animation.loopType == 1 then
			frameIndex = frameIndex % total
		elseif animation.loopType == 2 then
			local cycle = frameIndex % (2 * total)
			frameIndex = if cycle < total then cycle else 2 * total - 1 - cycle
		else
			frameIndex = math.clamp(frameIndex, 0, total - 1)
		end
		local column = frameIndex % animation.countX
		local row = math.floor(frameIndex / animation.countX)
		return Vector2.new(startX + column * sizeX, startY + row * sizeY), Vector2.new(sizeX, sizeY)
	end

	if uv.type == 3 and uv.scroll then
		local speed = uv.scroll.speed
		-- Wrap by the rect size so full-texture scrolls repeat like Effekseer's Repeat wrap mode.
		local offsetX = (startX + (speed.x or 0) * ageFrames) % math.max(1, sizeX)
		local offsetY = (startY + (speed.y or 0) * ageFrames) % math.max(1, sizeY)
		return Vector2.new(offsetX, offsetY), Vector2.new(sizeX, sizeY)
	end

	return Vector2.new(startX, startY), Vector2.new(sizeX, sizeY)
end

function Util.sphericalDirection(polarDegrees: number, azimuthDegrees: number): Vector3
	local polar = math.rad(polarDegrees)
	local azimuth = math.rad(azimuthDegrees)
	return Vector3.new(math.cos(polar) * math.cos(azimuth), math.sin(polar), math.cos(polar) * math.sin(azimuth))
end

function Util.randomBetween(minValue: number, maxValue: number): number
	if minValue > maxValue then
		minValue, maxValue = maxValue, minValue
	end
	return minValue + (maxValue - minValue) * math.random()
end

function Util.numberRange(minValue: number, maxValue: number): NumberRange
	if minValue > maxValue then
		minValue, maxValue = maxValue, minValue
	end

	return NumberRange.new(minValue, maxValue)
end

function Util.color3(color: { r: number, g: number, b: number }): Color3
	return Color3.fromRGB(color.r or 255, color.g or 255, color.b or 255)
end

function Util.enumValue(enumType, name: string)
	local ok, value = pcall(function()
		return (enumType :: any)[name]
	end)
	if ok then
		return value
	end
	return nil
end

function Util.rotationZXY(rotation: VectorPayload?): CFrame
	if not rotation then
		return CFrame.identity
	end

	local x = math.rad(rotation.x or 0)
	local y = math.rad(rotation.y or 0)
	local z = math.rad(rotation.z or 0)
	-- Effekseer evaluates Euler rotations as RotationZXY(z, x, y).
	return CFrame.Angles(0, y, 0) * CFrame.Angles(x, 0, 0) * CFrame.Angles(0, 0, z)
end

return Util
