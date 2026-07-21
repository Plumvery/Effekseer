--!nonstrict
-- Target resolution and the attachments/host parts effects hang off of.

local Types = require(script.Parent:WaitForChild("Types"))
local Util = require(script.Parent:WaitForChild("Util"))

type EffectNode = Types.EffectNode

local rangeValue = Util.rangeValue
local componentMul = Util.componentMul
local vectorPayload = Util.vectorPayload
local rotationZXY = Util.rotationZXY
local randomBetween = Util.randomBetween

local Rig = {}

function Rig.resolveTarget(target: Instance): (BasePart, CFrame)
	if target:IsA("Attachment") then
		local parent = target.Parent
		assert(parent and parent:IsA("BasePart"), "Effekseer target Attachment must be parented to a BasePart")
		return parent, target.CFrame
	end

	if target:IsA("BasePart") then
		return target, CFrame.identity
	end

	if target:IsA("Model") then
		local primaryPart = target.PrimaryPart
		assert(primaryPart ~= nil, "Effekseer target Model must have PrimaryPart set")
		return primaryPart, CFrame.identity
	end

	error("Effekseer target must be a BasePart, Attachment, or Model")
end

function Rig.nodeCFrame(node: EffectNode, rootCFrame: CFrame, unitScale: number, parentScale: Vector3?): CFrame
	local rotation3 = node.transform.rotation.rotation3
	local rotation = if rotation3
		then rotation3.center
		else { x = 0, y = 0, z = rangeValue(node.transform.rotation.rotation, "center", 0) }
	local inheritedScale = parentScale or Vector3.one
	local localPosition = componentMul(vectorPayload(node.transform.position, Vector3.zero), inheritedScale) * unitScale
	return rootCFrame * CFrame.new(localPosition) * rotationZXY(rotation)
end

function Rig.createAttachment(targetPart: BasePart, name: string, cframe: CFrame, controller): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = cframe
	attachment.Parent = targetPart
	table.insert(controller._instances, attachment)
	return attachment
end

function Rig.createHostPart(targetPart: BasePart, name: string, cframe: CFrame, size: Vector3, controller): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Transparency = 1
	part.Size = size
	part.CFrame = targetPart.CFrame * cframe
	part.Parent = targetPart

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = targetPart
	weld.Part1 = part
	weld.Parent = part

	table.insert(controller._instances, part)
	table.insert(controller._parts, part)
	return part
end

function Rig.hasSpawnPositionRange(node: EffectNode): boolean
	local range = node.transform.positionRange
	if not range then
		return false
	end

	for _, axis in { "x", "y", "z" } do
		local minValue = (range.min :: any)[axis] or 0
		local maxValue = (range.max :: any)[axis] or 0
		local centerValue = (range.center :: any)[axis] or 0
		if math.abs(minValue - centerValue) > 1e-6 or math.abs(maxValue - centerValue) > 1e-6 then
			return true
		end
	end

	return false
end

function Rig.spawnVolumeSize(node: EffectNode, unitScale: number, parentScale: Vector3): Vector3
	local range = node.transform.positionRange
	if not range then
		return Vector3.new(0.05, 0.05, 0.05)
	end

	return Vector3.new(
		math.max(0.05, math.abs((range.max.x or 0) - (range.min.x or 0)) * math.abs(parentScale.X) * unitScale),
		math.max(0.05, math.abs((range.max.y or 0) - (range.min.y or 0)) * math.abs(parentScale.Y) * unitScale),
		math.max(0.05, math.abs((range.max.z or 0) - (range.min.z or 0)) * math.abs(parentScale.Z) * unitScale)
	)
end

function Rig.randomRangeOffset(node: EffectNode): Vector3
	local range = node.transform.positionRange
	if not range then
		return Vector3.zero
	end

	local center = range.center
	return Vector3.new(
		randomBetween(range.min.x or 0, range.max.x or 0) - (center.x or 0),
		randomBetween(range.min.y or 0, range.max.y or 0) - (center.y or 0),
		randomBetween(range.min.z or 0, range.max.z or 0) - (center.z or 0)
	)
end

return Rig
