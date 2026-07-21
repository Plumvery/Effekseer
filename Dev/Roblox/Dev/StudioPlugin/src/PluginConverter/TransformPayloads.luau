--!nonstrict
-- Location, rotation, and scaling payloads (PVA, easing, FCurve baking) plus
-- gravity/force-field acceleration.

local Xml = require(script.Parent:WaitForChild("Xml"))
local VectorMath = require(script.Parent:WaitForChild("VectorMath"))
local Easing = require(script.Parent:WaitForChild("Easing"))
local FCurve = require(script.Parent:WaitForChild("FCurve"))
local Diagnostics = require(script.Parent:WaitForChild("Diagnostics"))

local warning = Diagnostics.warning

local TransformPayloads = {}

local LOCAL_FORCE_FIELD_NAMES = {
	[1] = "Turbulence",
	[2] = "Force",
	[3] = "Wind",
	[4] = "Vortex",
	[7] = "Drag",
	[9] = "AttractiveForce",
}

local function fieldAcceleration(node, warnings, nodeName: string)
	local acceleration = Xml.randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local abs = Xml.find(node, "LocationAbsValues")
	if not abs then
		return acceleration
	end

	-- Legacy (pre-1.6) layout: Type selects None(0)/Gravity(1)/AttractiveForce(2).
	local legacyType = Xml.intAt(abs, "Type", if Xml.find(abs, "Gravity") then 1 else 0)
	if legacyType == 1 and Xml.find(abs, "Gravity") then
		acceleration = VectorMath.addVectorRanges(
			acceleration,
			Xml.randomVectorAt(abs, "Gravity/Gravity", { x = 0, y = 0, z = 0 })
		)
	elseif legacyType == 2 then
		table.insert(
			warnings,
			warning("force_field_unsupported", "Attractive force is not supported by the Roblox runtime.", nodeName)
		)
	end

	-- Modern (1.6+) layout: up to four LocalForceField slots.
	for index = 1, 4 do
		local field = Xml.find(abs, "LocalForceField" .. tostring(index))
		if field then
			local fieldType = Xml.intAt(field, "Type", 0)
			if fieldType == 8 then
				local power = Xml.numberAt(field, "Power", 1)
				acceleration = VectorMath.addVectorRanges(
					acceleration,
					VectorMath.scaleVectorRange(
						Xml.randomVectorAt(field, "Gravity/Gravity", { x = 0, y = 0, z = 0 }),
						power
					)
				)
			elseif fieldType ~= 0 then
				table.insert(
					warnings,
					warning(
						"force_field_unsupported",
						"Local force field '"
							.. (LOCAL_FORCE_FIELD_NAMES[fieldType] or tostring(fieldType))
							.. "' is not supported by the Roblox runtime.",
						nodeName
					)
				)
			end
		end
	end
	return acceleration
end

function TransformPayloads.locationPayload(node, warnings, nodeName: string, life)
	local locationType = Xml.intAt(node, "LocationValues/Type", 0)
	local position = { x = 0, y = 0, z = 0 }
	local positionRange = VectorMath.vectorRangeFromVector(position)
	local velocity = Xml.randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local acceleration = Xml.randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local positionKeys = nil
	local positionEasing = nil

	if locationType == 0 then
		position = Xml.fixedVectorAt(node, "LocationValues/Fixed/Location", { x = 0, y = 0, z = 0 })
		positionRange = VectorMath.vectorRangeFromVector(position)
	elseif locationType == 1 then
		positionRange = Xml.randomVectorAt(node, "LocationValues/PVA/Location", { x = 0, y = 0, z = 0 })
		position = positionRange.center
		velocity = Xml.randomVectorAt(node, "LocationValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		acceleration = Xml.randomVectorAt(node, "LocationValues/PVA/Acceleration", { x = 0, y = 0, z = 0 })
	elseif locationType == 2 then
		local easingNode = Xml.find(node, "LocationValues/Easing")
		local start = Xml.randomVectorAt(node, "LocationValues/Easing/Start", { x = 0, y = 0, z = 0 })
		local finish = Xml.randomVectorAt(node, "LocationValues/Easing/End", start.center)
		position = start.center
		positionRange = start
		velocity = VectorMath.vectorVelocityFromRanges(start, finish, math.max(1, life.center or 1))
		local progress = Easing.easingProgressValues(easingNode)
		local middle = Easing.easingMiddleVectorAt(easingNode, start, finish)
		if progress or middle then
			positionEasing = { start = start, finish = finish, middle = middle, progress = progress }
		end
	elseif locationType == 3 then
		local container = FCurve.fcurveContainerAt(node, {
			"LocationValues/LocationFCurve/FCurve",
			"LocationValues/FCurve/FCurve",
			"LocationValues/LocationFCurve",
			"LocationValues/FCurve",
		})
		local baked = if container then FCurve.bakeFCurveVector(container, life, { x = 0, y = 0, z = 0 }) else nil
		if baked then
			positionKeys = baked
			position = baked.values[1]
			positionRange = VectorMath.vectorRangeFromVector(position)
			local last = baked.values[#baked.values]
			local frames = math.max(1, baked.frames[#baked.frames] - baked.frames[1])
			velocity = VectorMath.vectorRangeFromVector(
				VectorMath.divideVector(VectorMath.subtractVectors(last, position), frames)
			)
			table.insert(
				warnings,
				warning("location_fcurve", "Location FCurve is approximated with baked linear samples.", nodeName)
			)
		else
			table.insert(
				warnings,
				warning(
					"location_fcurve",
					"Location FCurve keys could not be read; the node stays at its origin.",
					nodeName
				)
			)
		end
	else
		table.insert(
			warnings,
			warning(
				"location_unsupported",
				"Location type " .. tostring(locationType) .. " is not supported.",
				nodeName
			)
		)
	end

	acceleration = VectorMath.addVectorRanges(acceleration, fieldAcceleration(node, warnings, nodeName))

	return {
		type = locationType,
		position = position,
		positionRange = positionRange,
		positionKeys = positionKeys,
		positionEasing = positionEasing,
		velocity = velocity,
		acceleration = acceleration,
		emissionDirection = VectorMath.dominantDirection(velocity.center),
		spreadAngle = VectorMath.spreadFromRange(velocity),
	}
end

function TransformPayloads.rotationPayload(node, life, warnings, nodeName: string)
	local rotationType = Xml.intAt(node, "RotationValues/Type", 0)
	local rotation = { center = 0, min = 0, max = 0 }
	local speed = { center = 0, min = 0, max = 0 }
	local rotation3 = Xml.randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local speed3 = Xml.randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local rotationKeys = nil
	local rotationEasing = nil

	if rotationType == 0 then
		local fixed = Xml.fixedVectorAt(node, "RotationValues/Fixed/Rotation", { x = 0, y = 0, z = 0 })
		rotation3 = VectorMath.vectorRangeFromVector(fixed)
		rotation = { center = fixed.z, min = fixed.z, max = fixed.z }
	elseif rotationType == 1 then
		rotation3 = Xml.randomVectorAt(node, "RotationValues/PVA/Rotation", { x = 0, y = 0, z = 0 })
		speed3 = Xml.randomVectorAt(node, "RotationValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		rotation = Xml.randomNumberAt(node, "RotationValues/PVA/Rotation/Z", 0)
		speed = Xml.randomNumberAt(node, "RotationValues/PVA/Velocity/Z", 0)
	elseif rotationType == 2 then
		local easingNode = Xml.find(node, "RotationValues/Easing")
		local start3 = Xml.randomVectorAt(node, "RotationValues/Easing/Start", { x = 0, y = 0, z = 0 })
		local finish3 = Xml.randomVectorAt(node, "RotationValues/Easing/End", start3.center)
		local frames = math.max(1, life.center or 1)
		rotation3 = start3
		speed3 = VectorMath.vectorVelocityFromRanges(start3, finish3, frames)
		rotation = { center = start3.center.z, min = start3.min.z, max = start3.max.z }
		speed = VectorMath.numberVelocityFromRanges(
			{ center = start3.center.z, min = start3.min.z, max = start3.max.z },
			{ center = finish3.center.z, min = finish3.min.z, max = finish3.max.z },
			frames
		)
		local progress = Easing.easingProgressValues(easingNode)
		local middle = Easing.easingMiddleVectorAt(easingNode, start3, finish3)
		if progress or middle then
			rotationEasing = { start = start3, finish = finish3, middle = middle, progress = progress }
		end
	elseif rotationType == 3 then
		rotation = Xml.randomNumberAt(node, "RotationValues/AxisPVA/Rotation", 0)
		speed = Xml.randomNumberAt(node, "RotationValues/AxisPVA/Velocity", 0)
	elseif rotationType == 4 then
		rotation = Xml.randomNumberAt(node, "RotationValues/AxisEasing/Easing/Start", 0)
		local finish = Xml.randomNumberAt(node, "RotationValues/AxisEasing/Easing/End", rotation.center)
		speed = VectorMath.numberVelocityFromRanges(rotation, finish, math.max(1, life.center or 1))
	elseif rotationType == 5 then
		local container = FCurve.fcurveContainerAt(node, {
			"RotationValues/RotationFCurve/FCurve",
			"RotationValues/FCurve/FCurve",
			"RotationValues/RotationFCurve",
		})
		local baked = if container then FCurve.bakeFCurveVector(container, life, { x = 0, y = 0, z = 0 }) else nil
		if baked then
			rotationKeys = baked
			local first = baked.values[1]
			local last = baked.values[#baked.values]
			local frames = math.max(1, baked.frames[#baked.frames] - baked.frames[1])
			local averageSpeed = VectorMath.divideVector(VectorMath.subtractVectors(last, first), frames)
			rotation3 = VectorMath.vectorRangeFromVector(first)
			speed3 = VectorMath.vectorRangeFromVector(averageSpeed)
			rotation = { center = first.z, min = first.z, max = first.z }
			speed = { center = averageSpeed.z, min = averageSpeed.z, max = averageSpeed.z }
			table.insert(
				warnings,
				warning("rotation_fcurve", "Rotation FCurve is approximated with baked linear samples.", nodeName)
			)
		else
			table.insert(
				warnings,
				warning("rotation_fcurve", "Rotation FCurve keys could not be read; fixed rotation is used.", nodeName)
			)
		end
	elseif rotationType == 6 or rotationType == 7 then
		table.insert(
			warnings,
			warning(
				"rotation_unsupported",
				"Rotation type "
					.. (if rotationType == 6 then "RotateToViewpoint" else "RotateToVelocity")
					.. " is not supported.",
				nodeName
			)
		)
	end

	return {
		type = rotationType,
		rotation = rotation,
		speed = speed,
		rotation3 = rotation3,
		speed3 = speed3,
		rotationKeys = rotationKeys,
		rotationEasing = rotationEasing,
	}
end

function TransformPayloads.scalePayload(node, life, warnings, nodeName: string)
	local scaleType = Xml.intAt(node, "ScalingValues/Type", 0)
	local start = 1
	local finish = 1
	local envelope = 0
	local startVector = { x = 1, y = 1, z = 1 }
	local finishVector = { x = 1, y = 1, z = 1 }
	local pva = nil
	local easing = nil
	local singlePva = nil
	local singleEasing = nil
	local scaleKeys = nil

	if scaleType == 0 then
		local scale = Xml.fixedVectorAt(node, "ScalingValues/Fixed/Scale", { x = 1, y = 1, z = 1 })
		start = math.max(0, VectorMath.averageXY(scale))
		finish = start
		startVector = VectorMath.scaleVector(scale)
		finishVector = startVector
	elseif scaleType == 1 then
		local base = Xml.randomVectorAt(node, "ScalingValues/PVA/Scale", { x = 1, y = 1, z = 1 })
		local velocity = Xml.randomVectorAt(node, "ScalingValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		local acceleration = Xml.randomVectorAt(node, "ScalingValues/PVA/Acceleration", { x = 0, y = 0, z = 0 })
		local lifeFrames = life.center
		start = math.max(0, VectorMath.averageXY(base.center))
		local endX = base.center.x
			+ velocity.center.x * lifeFrames
			+ 0.5 * acceleration.center.x * lifeFrames * lifeFrames
		local endY = base.center.y
			+ velocity.center.y * lifeFrames
			+ 0.5 * acceleration.center.y * lifeFrames * lifeFrames
		local endZ = base.center.z
			+ velocity.center.z * lifeFrames
			+ 0.5 * acceleration.center.z * lifeFrames * lifeFrames
		finish = math.max(0, (math.abs(endX) + math.abs(endY)) * 0.5)
		envelope = math.max(0, (base.max.x - base.min.x + base.max.y - base.min.y) * 0.25)
		startVector = VectorMath.scaleVector(base.center)
		finishVector = VectorMath.scaleVector({ x = endX, y = endY, z = endZ })
		pva = { scale = base, velocity = velocity, acceleration = acceleration }
	elseif scaleType == 2 then
		local easingNode = Xml.find(node, "ScalingValues/Easing")
		local startRange = Xml.randomVectorAt(node, "ScalingValues/Easing/Start", { x = 1, y = 1, z = 1 })
		local finishRange = Xml.randomVectorAt(node, "ScalingValues/Easing/End", startRange.center)
		start = math.max(0, VectorMath.averageXY(startRange.center))
		finish = math.max(0, VectorMath.averageXY(finishRange.center))
		envelope = math.max(
			0,
			(
				startRange.max.x
				- startRange.min.x
				+ startRange.max.y
				- startRange.min.y
				+ finishRange.max.x
				- finishRange.min.x
				+ finishRange.max.y
				- finishRange.min.y
			) * 0.125
		)
		startVector = VectorMath.scaleVector(startRange.center)
		finishVector = VectorMath.scaleVector(finishRange.center)
		easing = {
			start = startRange,
			finish = finishRange,
			middle = Easing.easingMiddleVectorAt(easingNode, startRange, finishRange),
			progress = Easing.easingProgressValues(easingNode),
		}
	elseif scaleType == 3 then
		local base = Xml.randomNumberAt(node, "ScalingValues/SinglePVA/Scale", 1)
		local velocity = Xml.randomNumberAt(node, "ScalingValues/SinglePVA/Velocity", 0)
		local acceleration = Xml.randomNumberAt(node, "ScalingValues/SinglePVA/Acceleration", 0)
		local lifeFrames = life.center
		start = math.max(0, math.abs(base.center))
		finish = math.max(
			0,
			math.abs(base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames)
		)
		envelope = math.max(0, (base.max - base.min) * 0.5)
		startVector = VectorMath.singleScaleVector(base.center)
		finishVector = VectorMath.singleScaleVector(
			base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames
		)
		singlePva = { scale = base, velocity = velocity, acceleration = acceleration }
	elseif scaleType == 4 then
		local easingNode = Xml.find(node, "ScalingValues/SingleEasing")
		local startRange = Xml.randomNumberAt(node, "ScalingValues/SingleEasing/Start", 1)
		local finishRange = Xml.randomNumberAt(node, "ScalingValues/SingleEasing/End", startRange.center)
		start = math.max(0, math.abs(startRange.center))
		finish = math.max(0, math.abs(finishRange.center))
		envelope = math.max(0, math.max(startRange.max - startRange.min, finishRange.max - finishRange.min) * 0.5)
		startVector = VectorMath.singleScaleVector(startRange.center)
		finishVector = VectorMath.singleScaleVector(finishRange.center)
		singleEasing = {
			start = startRange,
			finish = finishRange,
			middle = if easingNode and Xml.boolAt(easingNode, "IsMiddleEnabled", false)
				then Xml.randomNumberAt(easingNode, "Middle", (startRange.center + finishRange.center) * 0.5)
				else nil,
			progress = Easing.easingProgressValues(easingNode),
		}
	elseif scaleType == 5 or scaleType == 6 then
		local container = if scaleType == 5
			then FCurve.fcurveContainerAt(node, { "ScalingValues/FCurve/FCurve", "ScalingValues/FCurve" })
			else FCurve.fcurveContainerAt(
				node,
				{ "ScalingValues/SingleFCurve/FCurve", "ScalingValues/SingleFCurve" }
			)
		local baked = if container then FCurve.bakeFCurveVector(container, life, { x = 1, y = 1, z = 1 }) else nil
		if baked then
			scaleKeys = baked
			local first = baked.values[1]
			local last = baked.values[#baked.values]
			start = math.max(0, VectorMath.averageXY(first))
			finish = math.max(0, VectorMath.averageXY(last))
			startVector = VectorMath.scaleVector(first)
			finishVector = VectorMath.scaleVector(last)
			table.insert(
				warnings,
				warning("scaling_fcurve", "Scaling FCurve is approximated with baked linear samples.", nodeName)
			)
		else
			table.insert(
				warnings,
				warning("scaling_fcurve", "Scaling FCurve keys could not be read; scale 1 is used.", nodeName)
			)
		end
	end

	if finish ~= finish then
		finish = if start == start then start else 1
	end
	return {
		type = scaleType,
		start = start,
		finish = finish,
		envelope = envelope,
		startVector = startVector,
		finishVector = finishVector,
		pva = pva,
		easing = easing,
		singlePva = singlePva,
		singleEasing = singleEasing,
		scaleKeys = scaleKeys,
	}
end

return TransformPayloads
