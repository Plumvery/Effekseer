--!nonstrict
-- Per-particle random sampling (positions, easing endpoints, scale states) and
-- node-policy helpers (billboard modes, quad-vs-emitter rendering decisions).

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))

type EffectNode = Types.EffectNode
type RangePayload = Types.RangePayload
type PlayOptions = Types.PlayOptions

local BILLBOARD = Types.BILLBOARD
local rangeValue = Util.rangeValue
local componentMul = Util.componentMul
local vectorPayload = Util.vectorPayload
local lerp = Util.lerp
local evaluateKeysVector = Util.evaluateKeysVector
local easedProgress = Util.easedProgress
local threePointVector = Util.threePointVector
local sphericalDirection = Util.sphericalDirection

local Sampling = {}

function Sampling.randomRangePayload(range: RangePayload?, fallback: number): number
	local minValue = rangeValue(range, "min", fallback)
	local maxValue = rangeValue(range, "max", fallback)
	if minValue > maxValue then
		minValue, maxValue = maxValue, minValue
	end
	return minValue + (maxValue - minValue) * math.random()
end

function Sampling.randomVectorPayload(range, fallback: Vector3?): Vector3
	local fallbackVector = fallback or Vector3.zero
	if not range then
		return fallbackVector
	end
	local function axisValue(axis: string, fallbackValue: number): number
		local minValue = (range.min and (range.min :: any)[axis]) or fallbackValue
		local maxValue = (range.max and (range.max :: any)[axis]) or fallbackValue
		if minValue > maxValue then
			minValue, maxValue = maxValue, minValue
		end
		return minValue + (maxValue - minValue) * math.random()
	end
	return Vector3.new(
		axisValue("x", fallbackVector.X),
		axisValue("y", fallbackVector.Y),
		axisValue("z", fallbackVector.Z)
	)
end

function Sampling.vectorPayloadCenter(range, fallback: Vector3?): Vector3
	local fallbackVector = fallback or Vector3.zero
	local center = if range then range.center else nil
	if not center then
		return fallbackVector
	end
	return Vector3.new(center.x or fallbackVector.X, center.y or fallbackVector.Y, center.z or fallbackVector.Z)
end

-- Local-space spawn offset (in Effekseer units) for the generation-location shapes.
-- `index` is the 1-based particle index so Order/ReverseOrder placements are deterministic.
function Sampling.spawnOffsetForIndex(node: EffectNode, index: number): Vector3
	local spawn = node.spawn
	if not spawn then
		return Vector3.zero
	end

	if spawn.type == 1 and spawn.sphere then
		local sphere = spawn.sphere
		local radius = Sampling.randomRangePayload(sphere.radius, 0)
		local polar = Sampling.randomRangePayload(sphere.rotationX, 0)
		local azimuth = Sampling.randomRangePayload(sphere.rotationY, 0)
		return sphericalDirection(polar, azimuth) * radius
	end

	if spawn.type == 3 and spawn.circle then
		local circle = spawn.circle
		local division = math.max(1, circle.division or 8)
		local t
		if circle.order == 1 then
			t = ((index - 1) % division) / division
		elseif circle.order == 2 then
			t = 1 - ((index - 1) % division) / division
		else
			t = math.random()
		end
		local angleStart = Sampling.randomRangePayload(circle.angleStart, 0)
		local angleEnd = Sampling.randomRangePayload(circle.angleEnd, 360)
		local noise = if circle.angleNoise then Sampling.randomRangePayload(circle.angleNoise, 0) else 0
		local angle = math.rad(angleStart + (angleEnd - angleStart) * t + noise)
		local radius = Sampling.randomRangePayload(circle.radius, 0)
		local cosValue = math.cos(angle) * radius
		local sinValue = math.sin(angle) * radius
		if circle.axis == 0 then
			return Vector3.new(0, cosValue, sinValue)
		elseif circle.axis == 1 then
			return Vector3.new(cosValue, 0, sinValue)
		end
		return Vector3.new(cosValue, sinValue, 0)
	end

	if spawn.type == 4 and spawn.line then
		local line = spawn.line
		local division = math.max(1, line.division or 8)
		local t
		if line.order == 1 then
			t = if division > 1 then ((index - 1) % division) / (division - 1) else 0
		else
			t = math.random()
		end
		local fromPosition = Sampling.randomVectorPayload(line.from, Vector3.zero)
		local toPosition = Sampling.randomVectorPayload(line.to, Vector3.zero)
		local noise = if line.noise then Sampling.randomRangePayload(line.noise, 0) else 0
		local along = toPosition - fromPosition
		local base = fromPosition + along * t
		if noise ~= 0 and along.Magnitude > 1e-6 then
			base += along.Unit * noise
		end
		return base
	end

	return Vector3.zero
end

function Sampling.hasSpawnShape(node: EffectNode): boolean
	local spawn = node.spawn
	return spawn ~= nil and (spawn.type == 1 or spawn.type == 3 or spawn.type == 4)
end

-- Per-particle sampled easing endpoints (preserves start/end randomness while
-- following the baked non-linear progress curve).
function Sampling.samplePositionEasingState(node: EffectNode, parentScale: Vector3)
	local easing = (node.transform :: any).positionEasing
	if not easing then
		return nil
	end
	return {
		start = componentMul(Sampling.randomVectorPayload(easing.start, Vector3.zero), parentScale),
		middle = if easing.middle
			then componentMul(Sampling.randomVectorPayload(easing.middle, Vector3.zero), parentScale)
			else nil,
		finish = componentMul(Sampling.randomVectorPayload(easing.finish, Vector3.zero), parentScale),
		progress = easing.progress,
	}
end

function Sampling.sampleRotationEasingState(node: EffectNode)
	local easing = (node.transform.rotation :: any).rotationEasing
	if not easing then
		return nil
	end
	return {
		start = Sampling.randomVectorPayload(easing.start, Vector3.zero),
		middle = if easing.middle then Sampling.randomVectorPayload(easing.middle, Vector3.zero) else nil,
		finish = Sampling.randomVectorPayload(easing.finish, Vector3.zero),
		progress = easing.progress,
	}
end

function Sampling.easedStateVector(state, t: number): Vector3
	local p = easedProgress(state.progress, t)
	if state.middle then
		return threePointVector(state.start, state.middle, state.finish, p)
	end
	return state.start:Lerp(state.finish, p)
end

function Sampling.sizeVectorAt(node: EffectNode, t: number): Vector3
	local size = node.transform.size
	local startVector = vectorPayload(size.startVector, Vector3.new(size.start or 1, size.start or 1, size.start or 1))
	local finishFallback =
		Vector3.new(size.finish or size.start or 1, size.finish or size.start or 1, size.finish or size.start or 1)
	local finishVector = vectorPayload(size.finishVector, finishFallback)
	return Vector3.new(
		lerp(startVector.X, finishVector.X, t),
		lerp(startVector.Y, finishVector.Y, t),
		lerp(startVector.Z, finishVector.Z, t)
	)
end

function Sampling.ringDiameterAt(node: EffectNode, t: number): number
	local ring = if node.visual then node.visual.ring else nil
	if not ring then
		return 1
	end
	local startRadius = ring.outerRadius or 1
	local finishRadius = ring.outerRadiusFinish or startRadius
	return math.max(0.01, lerp(startRadius, finishRadius, t) * 2)
end

function Sampling.inheritedScaleForNode(node: EffectNode): Vector3
	local scale = Sampling.sizeVectorAt(node, 0)
	return Vector3.new(
		math.max(0.001, math.abs(scale.X)),
		math.max(0.001, math.abs(scale.Y)),
		math.max(0.001, math.abs(scale.Z))
	)
end

function Sampling.visualSizeMultiplierAt(node: EffectNode, t: number): number
	if node.rendererType == "Ring" then
		return Sampling.ringDiameterAt(node, t)
	end
	return 1
end

function Sampling.spriteGeometry(node: EffectNode)
	local sprite = if node.visual then node.visual.sprite else nil
	local position = if sprite then sprite.position else nil
	local center = if position then position.center else nil
	local size = if position then position.size else nil
	return {
		centerX = if center then center.x or 0 else 0,
		centerY = if center then center.y or 0 else 0,
		width = if size then math.max(0.01, size.x or 1) else 1,
		height = if size then math.max(0.01, size.y or 1) else 1,
	}
end

function Sampling.scaleStateVector(state, t: number, ageFrames: number): Vector3
	if state.mode == "keys" then
		return evaluateKeysVector(state.keys, ageFrames)
	end
	if state.mode == "pva" then
		return state.initial + state.velocity * ageFrames + state.acceleration * (0.5 * ageFrames * ageFrames)
	end
	if state.mode == "easing" then
		local p = easedProgress(state.progress, t)
		if state.middle then
			return threePointVector(state.initial, state.middle, state.finish, p)
		end
		return Vector3.new(
			lerp(state.initial.X, state.finish.X, p),
			lerp(state.initial.Y, state.finish.Y, p),
			lerp(state.initial.Z, state.finish.Z, p)
		)
	end
	return Sampling.sizeVectorAt(state.node, t)
end

function Sampling.sampleScaleState(node: EffectNode)
	local size = node.transform.size
	if size.scaleKeys and #size.scaleKeys.frames > 0 then
		return { mode = "keys", keys = size.scaleKeys }
	end
	if size.type == 1 and size.pva then
		return {
			mode = "pva",
			initial = Sampling.randomVectorPayload(size.pva.scale, Vector3.new(1, 1, 1)),
			velocity = Sampling.randomVectorPayload(size.pva.velocity, Vector3.zero),
			acceleration = Sampling.randomVectorPayload(size.pva.acceleration, Vector3.zero),
		}
	end
	if size.type == 2 and size.easing then
		local easing: any = size.easing
		return {
			mode = "easing",
			initial = Sampling.randomVectorPayload(
				easing.start,
				Vector3.new(size.start or 1, size.start or 1, size.start or 1)
			),
			finish = Sampling.randomVectorPayload(
				easing.finish,
				Vector3.new(size.finish or 1, size.finish or 1, size.finish or 1)
			),
			middle = if easing.middle then Sampling.randomVectorPayload(easing.middle, Vector3.one) else nil,
			progress = easing.progress,
		}
	end
	if size.type == 3 and size.singlePva then
		local initial = Sampling.randomRangePayload(size.singlePva.scale, size.start or 1)
		local velocity = Sampling.randomRangePayload(size.singlePva.velocity, 0)
		local acceleration = Sampling.randomRangePayload(size.singlePva.acceleration, 0)
		return {
			mode = "pva",
			initial = Vector3.new(initial, initial, initial),
			velocity = Vector3.new(velocity, velocity, velocity),
			acceleration = Vector3.new(acceleration, acceleration, acceleration),
		}
	end
	if size.type == 4 and size.singleEasing then
		local easing: any = size.singleEasing
		local initial = Sampling.randomRangePayload(easing.start, size.start or 1)
		local finish = Sampling.randomRangePayload(easing.finish, size.finish or 1)
		local middle = if easing.middle
			then Sampling.randomRangePayload(easing.middle, (initial + finish) * 0.5)
			else nil
		return {
			mode = "easing",
			initial = Vector3.new(initial, initial, initial),
			finish = Vector3.new(finish, finish, finish),
			middle = if middle then Vector3.new(middle, middle, middle) else nil,
			progress = easing.progress,
		}
	end

	return { mode = "center", node = node }
end

function Sampling.billboardMode(node: EffectNode): number
	local visual = node.visual
	local sprite = if visual then visual.sprite else nil
	local ring = if visual then visual.ring else nil
	local billboard = if sprite then sprite.billboard elseif ring then ring.billboard else nil
	return billboard or 0
end

function Sampling.particle2DRotationEnabled(node: EffectNode): boolean
	local billboard = Sampling.billboardMode(node)
	return node.rendererType == "Sprite" and billboard == BILLBOARD.RotatedBillboard
end

function Sampling.flipbookMappable(node: EffectNode): boolean
	local uv = node.uv
	if not uv or uv.type ~= 2 or not uv.animation then
		return false
	end
	local animation = uv.animation
	if animation.countX ~= animation.countY then
		return false
	end
	if animation.countX ~= 2 and animation.countX ~= 4 and animation.countX ~= 8 then
		return false
	end
	if math.abs(uv.start.x or 0) > 1e-6 or math.abs(uv.start.y or 0) > 1e-6 then
		return false
	end
	return true
end

-- Cases a ParticleEmitter cannot represent: cropped or scrolling UVs, non-grid
-- sheet animations, and quads with a fixed world orientation.
function Sampling.needsQuadRendering(node: EffectNode): boolean
	if node.uv and not Sampling.flipbookMappable(node) then
		return true
	end
	local billboard = Sampling.billboardMode(node)
	if billboard == BILLBOARD.Fixed then
		return true
	end
	if node.rendererType == "Ring" and billboard == BILLBOARD.YAxisFixed then
		return true
	end
	return false
end

function Sampling.shouldUseSpriteParts(node: EffectNode, maxGeneration: number, options: PlayOptions): boolean
	if not node.rendered then
		return false
	end
	if node.rendererType ~= "Sprite" and node.rendererType ~= "Ring" then
		return false
	end
	if maxGeneration ~= 0 and maxGeneration > (options.burstTaskLimit or 200) then
		return false
	end
	if Sampling.needsQuadRendering(node) then
		return true
	end
	if node.rendererType == "Ring" then
		return false
	end
	if node.alphaBlend == 2 and options.useAdditiveSpriteParts ~= true then
		return false
	end
	return true
end

function Sampling.nodeMovesParticles(node: EffectNode): boolean
	if (node.transform.speed.max or 0) > 1e-9 then
		return true
	end
	if node.transform.positionKeys or (node.transform :: any).positionEasing then
		return true
	end
	local rotation = node.transform.rotation
	if rotation.rotationKeys or (rotation :: any).rotationEasing then
		return true
	end
	local speed3 = rotation.speed3
	if speed3 and speed3.center then
		local center = speed3.center
		if math.abs(center.x or 0) > 1e-9 or math.abs(center.y or 0) > 1e-9 or math.abs(center.z or 0) > 1e-9 then
			return true
		end
	end
	return false
end

return Sampling
