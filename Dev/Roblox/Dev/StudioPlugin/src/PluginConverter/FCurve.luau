--!nonstrict
-- FCurve key parsing and baking into linear key samples.

local Xml = require(script.Parent:WaitForChild("Xml"))

local FCurve = {}

local FCURVE_MAX_SAMPLES = 24

local function keyedChildrenSorted(node, prefix: string)
	local entries = {}
	for _, candidate in ipairs(node.children) do
		if string.sub(candidate.name, 1, #prefix) == prefix then
			local index = tonumber(string.sub(candidate.name, #prefix + 1))
			if index ~= nil then
				table.insert(entries, { index = index, node = candidate })
			end
		end
	end
	table.sort(entries, function(left, right)
		return left.index < right.index
	end)
	local result = {}
	for _, entry in ipairs(entries) do
		table.insert(result, entry.node)
	end
	return result
end

local function parseFCurveKeys(axisNode)
	if not axisNode then
		return {}
	end
	local keys = {}
	for _, keyNode in ipairs(keyedChildrenSorted(axisNode, "Key")) do
		table.insert(keys, {
			frame = Xml.numberAt(keyNode, "Frame", 0),
			value = Xml.numberAt(keyNode, "Value", 0),
		})
	end
	table.sort(keys, function(left, right)
		return left.frame < right.frame
	end)
	return keys
end

local function evaluateFCurve(keys, frame: number, defaultValue: number): number
	if #keys == 0 then
		return defaultValue
	end
	if frame <= keys[1].frame then
		return keys[1].value
	end
	local last = keys[#keys]
	if frame >= last.frame then
		return last.value
	end
	for index = 2, #keys do
		if frame <= keys[index].frame then
			local previous = keys[index - 1]
			local nextKey = keys[index]
			local span = nextKey.frame - previous.frame
			local t = if span > 1e-9 then (frame - previous.frame) / span else 0
			return previous.value + (nextKey.value - previous.value) * t
		end
	end
	return last.value
end

function FCurve.bakeFCurveVector(container, life, defaults)
	local keysNode = Xml.find(container, "Keys")
	if not keysNode then
		return nil
	end

	local axes = {
		x = parseFCurveKeys(Xml.child(keysNode, "X")),
		y = parseFCurveKeys(Xml.child(keysNode, "Y")),
		z = parseFCurveKeys(Xml.child(keysNode, "Z")),
		s = parseFCurveKeys(Xml.child(keysNode, "S")),
	}
	if #axes.x == 0 and #axes.y == 0 and #axes.z == 0 and #axes.s == 0 then
		return nil
	end

	local lifeFrames = math.max(1, life.max or life.center or 1)
	local frameSet = { [0] = true, [lifeFrames] = true }
	for _, axisKeys in pairs(axes) do
		for _, key in ipairs(axisKeys) do
			if key.frame >= 0 and key.frame <= lifeFrames then
				frameSet[key.frame] = true
			end
		end
	end
	local frames = {}
	for frame in pairs(frameSet) do
		table.insert(frames, frame)
	end
	table.sort(frames)
	if #frames > FCURVE_MAX_SAMPLES then
		local sampledSet = {}
		for index = 0, FCURVE_MAX_SAMPLES - 1 do
			local pick = frames[math.floor((index * (#frames - 1)) / (FCURVE_MAX_SAMPLES - 1) + 0.5) + 1]
			sampledSet[pick] = true
		end
		frames = {}
		for frame in pairs(sampledSet) do
			table.insert(frames, frame)
		end
		table.sort(frames)
	end

	local scalar = #axes.s > 0
	local values = {}
	for _, frame in ipairs(frames) do
		if scalar then
			local value = evaluateFCurve(axes.s, frame, defaults.x)
			table.insert(values, { x = value, y = value, z = value })
		else
			table.insert(values, {
				x = evaluateFCurve(axes.x, frame, defaults.x),
				y = evaluateFCurve(axes.y, frame, defaults.y),
				z = evaluateFCurve(axes.z, frame, defaults.z),
			})
		end
	end
	return { frames = frames, values = values }
end

function FCurve.fcurveContainerAt(node, candidates)
	for _, candidate in ipairs(candidates) do
		local found = Xml.find(node, candidate)
		if found and Xml.find(found, "Keys") then
			return found
		end
	end
	return nil
end

return FCurve
