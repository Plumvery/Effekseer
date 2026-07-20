local Converter = {}

local RENDERER_TYPES = {
	[0] = "None",
	[2] = "Sprite",
	[3] = "Ribbon",
	[4] = "Ring",
	[5] = "Model",
	[6] = "Track",
}

local SUPPORTED_RENDERERS = {
	Sprite = true,
	Ribbon = true,
	Ring = true,
	Track = true,
	Model = true,
}

local LUA_RESERVED = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

local function decodeXmlEntities(value: string): string
	return value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function parseXml(xml: string)
	local root = { name = "__root__", text = "", children = {} }
	local stack = { root }
	local index = 1
	local length = #xml

	while index <= length do
		local nextTag = string.find(xml, "<", index, true)
		if not nextTag then
			stack[#stack].text ..= decodeXmlEntities(string.sub(xml, index))
			break
		end

		if nextTag > index then
			stack[#stack].text ..= decodeXmlEntities(string.sub(xml, index, nextTag - 1))
		end

		if string.sub(xml, nextTag, nextTag + 3) == "<!--" then
			local close = string.find(xml, "-->", nextTag + 4, true)
			if not close then
				error("Malformed XML: unclosed comment")
			end
			index = close + 3
		elseif string.sub(xml, nextTag, nextTag + 1) == "<?" then
			local close = string.find(xml, "?>", nextTag + 2, true)
			if not close then
				error("Malformed XML: unclosed processing instruction")
			end
			index = close + 2
		elseif string.sub(xml, nextTag, nextTag + 8) == "<![CDATA[" then
			local close = string.find(xml, "]]>", nextTag + 9, true)
			if not close then
				error("Malformed XML: unclosed CDATA")
			end
			stack[#stack].text ..= string.sub(xml, nextTag + 9, close - 1)
			index = close + 3
		else
			local close = string.find(xml, ">", nextTag + 1, true)
			if not close then
				error("Malformed XML: unclosed tag")
			end

			local token = string.sub(xml, nextTag + 1, close - 1)
			local trimmed = string.match(token, "^%s*(.-)%s*$")
			if string.sub(trimmed, 1, 1) == "/" then
				local name = string.match(string.sub(trimmed, 2), "^%s*([^%s]+)")
				local current = table.remove(stack)
				if not current or current.name ~= name then
					error(
						("Malformed XML: expected </%s>, got </%s>"):format(
							current and current.name or "?",
							name or "?"
						)
					)
				end
			elseif string.sub(trimmed, 1, 1) ~= "!" then
				local selfClosing = string.sub(trimmed, -1) == "/"
				if selfClosing then
					trimmed = string.match(string.sub(trimmed, 1, -2), "^%s*(.-)%s*$")
				end
				local name = string.match(trimmed, "^([^%s/]+)")
				if name and name ~= "" then
					local node = { name = name, text = "", children = {} }
					table.insert(stack[#stack].children, node)
					if not selfClosing then
						table.insert(stack, node)
					end
				end
			end
			index = close + 1
		end
	end

	if #stack ~= 1 then
		error(("Malformed XML: unclosed <%s>"):format(stack[#stack].name))
	end
	if #root.children ~= 1 then
		error("XML document must have exactly one root element")
	end
	return root.children[1]
end

local function child(node, name: string)
	for _, candidate in ipairs(node.children) do
		if candidate.name == name then
			return candidate
		end
	end
	return nil
end

local function children(node, name: string)
	local result = {}
	for _, candidate in ipairs(node.children) do
		if candidate.name == name then
			table.insert(result, candidate)
		end
	end
	return result
end

local function find(node, xmlPath: string)
	local current = node
	for segment in string.gmatch(xmlPath, "[^/]+") do
		if not current then
			return nil
		end
		current = child(current, segment)
	end
	return current
end

local function trim(value: string): string
	return string.match(value, "^%s*(.-)%s*$")
end

local function textAt(node, xmlPath: string)
	local found = find(node, xmlPath)
	if not found then
		return nil
	end
	local value = trim(found.text or "")
	return if value == "" then nil else value
end

local function numberAt(node, xmlPath: string, defaultValue: number): number
	local value = textAt(node, xmlPath)
	if value == nil then
		return defaultValue
	end
	local parsed = tonumber(value)
	return if parsed ~= nil then parsed else defaultValue
end

local function intAt(node, xmlPath: string, defaultValue: number): number
	return math.floor(numberAt(node, xmlPath, defaultValue) + 0.5)
end

local function boolAt(node, xmlPath: string, defaultValue: boolean): boolean
	local value = textAt(node, xmlPath)
	if value == nil then
		return defaultValue
	end
	local lower = string.lower(value)
	return value == "1" or lower == "true" or lower == "yes"
end

local function randomNumberAt(node, xmlPath: string, defaultValue: number)
	local base = find(node, xmlPath)
	if not base then
		return { center = defaultValue, min = defaultValue, max = defaultValue }
	end

	local directText = trim(base.text or "")
	local direct = if directText == "" then nil else tonumber(directText)
	local minValue = tonumber(textAt(base, "Min") or "")
	local maxValue = tonumber(textAt(base, "Max") or "")
	local centerValue = tonumber(textAt(base, "Center") or "")

	if centerValue == nil and minValue ~= nil and maxValue ~= nil then
		centerValue = (minValue + maxValue) * 0.5
	end
	if centerValue == nil then
		centerValue = direct or defaultValue
	end
	if minValue == nil then
		minValue = centerValue
	end
	if maxValue == nil then
		maxValue = centerValue
	end
	if minValue > maxValue then
		minValue, maxValue = maxValue, minValue
	end

	return { center = centerValue, min = minValue, max = maxValue }
end

local function fixedVectorAt(node, xmlPath: string, defaultValue)
	return {
		x = numberAt(node, xmlPath .. "/X", defaultValue.x),
		y = numberAt(node, xmlPath .. "/Y", defaultValue.y),
		z = numberAt(node, xmlPath .. "/Z", defaultValue.z),
	}
end

local function randomVectorAt(node, xmlPath: string, defaultValue)
	local axes = {
		x = randomNumberAt(node, xmlPath .. "/X", defaultValue.x),
		y = randomNumberAt(node, xmlPath .. "/Y", defaultValue.y),
		z = randomNumberAt(node, xmlPath .. "/Z", defaultValue.z),
	}
	return {
		center = { x = axes.x.center, y = axes.y.center, z = axes.z.center },
		min = { x = axes.x.min, y = axes.y.min, z = axes.z.min },
		max = { x = axes.x.max, y = axes.y.max, z = axes.z.max },
	}
end

local function vectorRangeFromVector(vector)
	return {
		center = { x = vector.x, y = vector.y, z = vector.z },
		min = { x = vector.x, y = vector.y, z = vector.z },
		max = { x = vector.x, y = vector.y, z = vector.z },
	}
end

local function vectorMagnitude(vector): number
	return math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
end

local function dominantDirection(vector): string
	local axis = "Top"
	local value = vector.y
	if math.abs(vector.x) > math.abs(value) then
		axis = "Right"
		value = vector.x
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

local function spreadFromRange(velocity): number
	local center = velocity.center
	local maxDelta = 0
	for _, axis in ipairs({ "x", "y", "z" }) do
		maxDelta =
			math.max(maxDelta, math.abs(velocity.max[axis] - center[axis]), math.abs(center[axis] - velocity.min[axis]))
	end
	local speed = math.max(vectorMagnitude(center), 1e-6)
	return math.clamp((math.atan(maxDelta / speed) * 180 * 2) / math.pi, 0, 180)
end

local function subtractVectors(a, b)
	return {
		x = (a.x or 0) - (b.x or 0),
		y = (a.y or 0) - (b.y or 0),
		z = (a.z or 0) - (b.z or 0),
	}
end

local function addVectors(a, b)
	return {
		x = (a.x or 0) + (b.x or 0),
		y = (a.y or 0) + (b.y or 0),
		z = (a.z or 0) + (b.z or 0),
	}
end

local function divideVector(vector, divisor: number)
	local safeDivisor = if math.abs(divisor) > 1e-6 then divisor else 1
	return {
		x = (vector.x or 0) / safeDivisor,
		y = (vector.y or 0) / safeDivisor,
		z = (vector.z or 0) / safeDivisor,
	}
end

local function vectorVelocityFromRanges(start, finish, frames: number)
	return {
		center = divideVector(subtractVectors(finish.center, start.center), frames),
		min = divideVector(subtractVectors(finish.min, start.min), frames),
		max = divideVector(subtractVectors(finish.max, start.max), frames),
	}
end

local function addVectorRanges(a, b)
	return {
		center = addVectors(a.center, b.center),
		min = addVectors(a.min, b.min),
		max = addVectors(a.max, b.max),
	}
end

local function numberVelocityFromRanges(start, finish, frames: number)
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

local function averageXY(vector): number
	return (math.abs(vector.x or 0) + math.abs(vector.y or 0)) * 0.5
end

local function scaleVector(vector)
	return {
		x = math.abs(vector.x or 0),
		y = math.abs(vector.y or 0),
		z = math.abs(vector.z or 0),
	}
end

local function singleScaleVector(value: number)
	local safeValue = math.abs(value or 0)
	return { x = safeValue, y = safeValue, z = safeValue }
end

local function scaleVectorRange(range, factor: number)
	local function scale(vector)
		return {
			x = (vector.x or 0) * factor,
			y = (vector.y or 0) * factor,
			z = (vector.z or 0) * factor,
		}
	end
	return { center = scale(range.center), min = scale(range.min), max = scale(range.max) }
end

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
			frame = numberAt(keyNode, "Frame", 0),
			value = numberAt(keyNode, "Value", 0),
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

local FCURVE_MAX_SAMPLES = 24

local function bakeFCurveVector(container, life, defaults)
	local keysNode = find(container, "Keys")
	if not keysNode then
		return nil
	end

	local axes = {
		x = parseFCurveKeys(child(keysNode, "X")),
		y = parseFCurveKeys(child(keysNode, "Y")),
		z = parseFCurveKeys(child(keysNode, "Z")),
		s = parseFCurveKeys(child(keysNode, "S")),
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

local function fcurveContainerAt(node, candidates)
	for _, candidate in ipairs(candidates) do
		local found = find(node, candidate)
		if found and find(found, "Keys") then
			return found
		end
	end
	return nil
end

local function warning(code: string, message: string, nodeName: string?)
	local value = { code = code, message = message }
	if nodeName then
		value.node = nodeName
	end
	return value
end

local function uvPayload(node, warnings, nodeName: string)
	local uvType = intAt(node, "RendererCommonValues/UV", 0)
	if uvType == 0 then
		return nil
	end
	local base = find(node, "RendererCommonValues")
	if not base then
		return nil
	end

	if uvType == 1 then
		return {
			type = 1,
			start = { x = numberAt(base, "UVFixed/Start/X", 0), y = numberAt(base, "UVFixed/Start/Y", 0) },
			size = { x = numberAt(base, "UVFixed/Size/X", 0), y = numberAt(base, "UVFixed/Size/Y", 0) },
		}
	end

	if uvType == 2 then
		local animation = find(base, "UVAnimation/AnimationParams") or find(base, "UVAnimation")
		if not animation then
			return nil
		end
		-- FrameLength is an IntWithInfinite in newer saves (nested Value element) and plain text in older ones.
		local directFrameLength = tonumber(textAt(animation, "FrameLength") or "")
		local frameLength = directFrameLength or numberAt(animation, "FrameLength/Value", 1)
		return {
			type = 2,
			start = { x = numberAt(animation, "Start/X", 0), y = numberAt(animation, "Start/Y", 0) },
			size = { x = numberAt(animation, "Size/X", 0), y = numberAt(animation, "Size/Y", 0) },
			animation = {
				frameLength = math.max(1, frameLength),
				countX = math.max(1, intAt(animation, "FrameCountX", 1)),
				countY = math.max(1, intAt(animation, "FrameCountY", 1)),
				loopType = intAt(animation, "LoopType", 0),
				startSheet = intAt(animation, "StartSheet", 0),
			},
		}
	end

	if uvType == 3 then
		return {
			type = 3,
			start = {
				x = randomNumberAt(base, "UVScroll/Start/X", 0).center,
				y = randomNumberAt(base, "UVScroll/Start/Y", 0).center,
			},
			size = {
				x = randomNumberAt(base, "UVScroll/Size/X", 0).center,
				y = randomNumberAt(base, "UVScroll/Size/Y", 0).center,
			},
			scroll = {
				speed = {
					x = randomNumberAt(base, "UVScroll/Speed/X", 0).center,
					y = randomNumberAt(base, "UVScroll/Speed/Y", 0).center,
				},
			},
		}
	end

	table.insert(
		warnings,
		warning(
			"uv_unsupported",
			"UV type " .. tostring(uvType) .. " (FCurve) is not supported; default UVs are used.",
			nodeName
		)
	)
	return nil
end

local function rangeIsZero(range): boolean
	for _, key in ipairs({ "center", "min", "max" }) do
		local vector = range[key] or {}
		if math.abs(vector.x or 0) > 1e-9 or math.abs(vector.y or 0) > 1e-9 or math.abs(vector.z or 0) > 1e-9 then
			return false
		end
	end
	return true
end

local function spawnPayload(node, warnings, nodeName: string)
	local base = find(node, "GenerationLocationValues")
	if not base then
		return nil
	end
	local spawnType = intAt(base, "Type", 0)
	local effectsRotation = boolAt(base, "EffectsRotation", false)

	if spawnType == 0 then
		-- Point offsets are merged into transform.positionRange by convertNode.
		local location = randomVectorAt(base, "Point/Location", { x = 0, y = 0, z = 0 })
		if rangeIsZero(location) then
			return nil
		end
		return { type = 0, effectsRotation = effectsRotation, point = { location = location } }
	end

	if spawnType == 1 then
		return {
			type = 1,
			effectsRotation = effectsRotation,
			sphere = {
				radius = randomNumberAt(base, "Sphere/Radius", 0),
				rotationX = randomNumberAt(base, "Sphere/RotationX", 0),
				rotationY = randomNumberAt(base, "Sphere/RotationY", 0),
			},
		}
	end

	if spawnType == 3 then
		return {
			type = 3,
			effectsRotation = effectsRotation,
			circle = {
				radius = randomNumberAt(base, "Circle/Radius", 0),
				axis = intAt(base, "Circle/AxisDirection", 2),
				division = math.max(1, intAt(base, "Circle/Division", 8)),
				angleStart = randomNumberAt(base, "Circle/AngleStart", 0),
				angleEnd = randomNumberAt(base, "Circle/AngleEnd", 360),
				angleNoise = randomNumberAt(base, "Circle/AngleNoize", 0),
				order = intAt(base, "Circle/Type", 0),
			},
		}
	end

	if spawnType == 4 then
		return {
			type = 4,
			effectsRotation = effectsRotation,
			line = {
				from = randomVectorAt(base, "Line/PositionStart", { x = 0, y = 0, z = 0 }),
				to = randomVectorAt(base, "Line/PositionEnd", { x = 0, y = 0, z = 0 }),
				division = math.max(1, intAt(base, "Line/Division", 8)),
				noise = randomNumberAt(base, "Line/PositionNoize", 0),
				order = intAt(base, "Line/Type", 0),
			},
		}
	end

	table.insert(
		warnings,
		warning(
			"spawn_unsupported",
			"Generation location type " .. tostring(spawnType) .. " is not supported; point emission is used.",
			nodeName
		)
	)
	return nil
end

local function soundPayload(node, context, nodeName: string)
	local base = find(node, "SoundValues")
	if not base or intAt(base, "Type", 0) ~= 1 then
		return nil
	end
	local wave = textAt(base, "Sound/Wave")
	if not wave then
		return nil
	end

	context.dependencies.sounds[wave] = true
	local asset = nil
	if context.assetMap then
		asset = context.assetMapLookup(wave)
	end
	if not asset then
		table.insert(
			context.warnings,
			warning("sound_unmapped", "No Roblox asset id mapped for sound '" .. wave .. "'.", nodeName)
		)
	end
	return {
		wave = wave,
		asset = asset,
		volume = randomNumberAt(base, "Sound/Volume", 1),
		pitch = randomNumberAt(base, "Sound/Pitch", 0),
		delay = randomNumberAt(base, "Sound/Delay", 0),
	}
end

local LOCAL_FORCE_FIELD_NAMES = {
	[1] = "Turbulence",
	[2] = "Force",
	[3] = "Wind",
	[4] = "Vortex",
	[7] = "Drag",
	[9] = "AttractiveForce",
}

local function colorAt(node, candidates)
	for _, xmlPath in ipairs(candidates) do
		local base = find(node, xmlPath)
		if base then
			return {
				r = intAt(base, "R", 255),
				g = intAt(base, "G", 255),
				b = intAt(base, "B", 255),
				a = intAt(base, "A", 255),
			}
		end
	end
	return { r = 255, g = 255, b = 255, a = 255 }
end

local function colorRangeAt(node, xmlPath: string, defaultColor)
	local base = find(node, xmlPath)
	if not base then
		return defaultColor
	end
	return {
		r = math.floor(randomNumberAt(base, "R", defaultColor.r).center + 0.5),
		g = math.floor(randomNumberAt(base, "G", defaultColor.g).center + 0.5),
		b = math.floor(randomNumberAt(base, "B", defaultColor.b).center + 0.5),
		a = math.floor(randomNumberAt(base, "A", defaultColor.a).center + 0.5),
	}
end

local function rendererValueAt(node, propertyName: string, defaultValue: number): number
	for _, rendererName in ipairs({ "Sprite", "Ribbon", "Ring", "Track", "Model" }) do
		local value = textAt(node, "DrawingValues/" .. rendererName .. "/" .. propertyName)
		if value ~= nil then
			return tonumber(value) or defaultValue
		end
	end
	return defaultValue
end

local function alphaBlendAt(node): number
	local common = textAt(node, "RendererCommonValues/AlphaBlend")
	if common ~= nil then
		return math.floor((tonumber(common) or 1) + 0.5)
	end
	return math.floor(rendererValueAt(node, "AlphaBlend", 1) + 0.5)
end

local function fadeFrameAt(node, name: string): number
	local typeValue = intAt(node, "RendererCommonValues/" .. name .. "Type", 1)
	if typeValue == 0 or find(node, "RendererCommonValues/" .. name .. "None") then
		return 0
	end
	return numberAt(node, "RendererCommonValues/" .. name .. "/Frame", 0)
end

local function colorPayload(node, warnings, nodeName: string)
	-- Effekseer 1.5+ saves Sprite/Model colors as a StandardColor at DrawingValues/ColorAll.
	local standard = find(node, "DrawingValues/ColorAll")
	if standard and #standard.children > 0 then
		local mode = intAt(standard, "Type", 0)
		local fixed = colorAt(node, { "DrawingValues/ColorAll/Fixed" })
		if mode == 2 and find(standard, "Easing") then
			local start = colorRangeAt(standard, "Easing/Start", fixed)
			local finish = colorRangeAt(standard, "Easing/End", start)
			return {
				color = start,
				colorOverLife = { start = start, finish = finish },
			}
		end
		if mode == 1 and find(standard, "Random") then
			return {
				color = colorRangeAt(standard, "Random", fixed),
				colorOverLife = nil,
			}
		end
		if mode == 3 or mode == 4 then
			table.insert(
				warnings,
				warning(
					"color_unsupported",
					"Color mode "
						.. (if mode == 3 then "FCurve" else "Gradient")
						.. " is approximated with a fixed color.",
					nodeName
				)
			)
		end
		return { color = fixed, colorOverLife = nil }
	end

	for _, rendererName in ipairs({ "Sprite", "Ribbon", "Ring", "Track", "Model" }) do
		local basePath = "DrawingValues/" .. rendererName
		if find(node, basePath) then
			local mode = intAt(node, basePath .. "/ColorAll", 0)
			local fixed = colorAt(node, { basePath .. "/ColorAll_Fixed" })
			if mode == 2 and find(node, basePath .. "/ColorAll_Easing") then
				local start = colorRangeAt(node, basePath .. "/ColorAll_Easing/Start", fixed)
				local finish = colorRangeAt(node, basePath .. "/ColorAll_Easing/End", start)
				return {
					color = start,
					colorOverLife = {
						start = start,
						finish = finish,
					},
				}
			end
			if mode == 1 and find(node, basePath .. "/ColorAll_Random") then
				return {
					color = colorRangeAt(node, basePath .. "/ColorAll_Random", fixed),
					colorOverLife = nil,
				}
			end
			if find(node, basePath .. "/ColorAll_Fixed") then
				return {
					color = fixed,
					colorOverLife = nil,
				}
			end
		end
	end

	return {
		color = colorAt(node, {
			"DrawingValues/ColorAll/Fixed",
			"DrawingValues/Sprite/ColorAll_Fixed",
			"DrawingValues/Ribbon/ColorAll_Fixed",
			"DrawingValues/Ring/ColorAll_Fixed",
			"DrawingValues/Track/ColorCenterMiddle_Fixed",
			"DrawingValues/Model/Color_Fixed",
		}),
		colorOverLife = nil,
	}
end

local function rendererTypeFor(node): string
	local rendererId = intAt(node, "DrawingValues/Type", 2)
	return RENDERER_TYPES[rendererId] or ("Unknown" .. tostring(rendererId))
end

local function generationTime(node)
	local common = find(node, "CommonValues")
	if not common then
		return { center = 1, min = 1, max = 1 }
	end
	local nested = randomNumberAt(common, "Generation/GenerationTime", 1)
	local legacy = randomNumberAt(common, "GenerationTime", nested.center)
	return if find(common, "Generation/GenerationTime") or not find(common, "GenerationTime") then nested else legacy
end

local function generationOffset(node)
	local common = find(node, "CommonValues")
	if not common then
		return { center = 0, min = 0, max = 0 }
	end
	local nested = randomNumberAt(common, "Generation/GenerationTimeOffset", 0)
	local legacy = randomNumberAt(common, "GenerationTimeOffset", nested.center)
	return if find(common, "Generation/GenerationTimeOffset") or not find(common, "GenerationTimeOffset")
		then nested
		else legacy
end

local function nodeLife(node)
	local common = find(node, "CommonValues")
	local life = if common then randomNumberAt(common, "Life", 100) else { center = 100, min = 100, max = 100 }
	if common then
		-- Modern saves nest removal flags under Removal; legacy saves keep flat RemoveWhen* elements.
		local removalNested = boolAt(common, "Removal/WhenLifeIsExtinct", true)
		local removalLegacy = boolAt(common, "RemoveWhenLifeIsExtinct", true)
		if not removalNested or not removalLegacy then
			life.infinite = true
		end
	end
	return life
end

local function maxGeneration(node): number
	local common = find(node, "CommonValues")
	if not common then
		return 1
	end
	if boolAt(common, "MaxGeneration/Infinite", false) then
		return 0
	end
	return math.max(0, intAt(common, "MaxGeneration/Value", 1))
end

local function fieldAcceleration(node, warnings, nodeName: string)
	local acceleration = randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local abs = find(node, "LocationAbsValues")
	if not abs then
		return acceleration
	end

	-- Legacy (pre-1.6) layout: Type selects None(0)/Gravity(1)/AttractiveForce(2).
	local legacyType = intAt(abs, "Type", if find(abs, "Gravity") then 1 else 0)
	if legacyType == 1 and find(abs, "Gravity") then
		acceleration = addVectorRanges(acceleration, randomVectorAt(abs, "Gravity/Gravity", { x = 0, y = 0, z = 0 }))
	elseif legacyType == 2 then
		table.insert(
			warnings,
			warning("force_field_unsupported", "Attractive force is not supported by the Roblox runtime.", nodeName)
		)
	end

	-- Modern (1.6+) layout: up to four LocalForceField slots.
	for index = 1, 4 do
		local field = find(abs, "LocalForceField" .. tostring(index))
		if field then
			local fieldType = intAt(field, "Type", 0)
			if fieldType == 8 then
				local power = numberAt(field, "Power", 1)
				acceleration = addVectorRanges(
					acceleration,
					scaleVectorRange(randomVectorAt(field, "Gravity/Gravity", { x = 0, y = 0, z = 0 }), power)
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

local function locationPayload(node, warnings, nodeName: string, life)
	local locationType = intAt(node, "LocationValues/Type", 0)
	local position = { x = 0, y = 0, z = 0 }
	local positionRange = vectorRangeFromVector(position)
	local velocity = randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local acceleration = randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local positionKeys = nil

	if locationType == 0 then
		position = fixedVectorAt(node, "LocationValues/Fixed/Location", { x = 0, y = 0, z = 0 })
		positionRange = vectorRangeFromVector(position)
	elseif locationType == 1 then
		positionRange = randomVectorAt(node, "LocationValues/PVA/Location", { x = 0, y = 0, z = 0 })
		position = positionRange.center
		velocity = randomVectorAt(node, "LocationValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		acceleration = randomVectorAt(node, "LocationValues/PVA/Acceleration", { x = 0, y = 0, z = 0 })
	elseif locationType == 2 then
		local start = randomVectorAt(node, "LocationValues/Easing/Start", { x = 0, y = 0, z = 0 })
		local finish = randomVectorAt(node, "LocationValues/Easing/End", start.center)
		position = start.center
		positionRange = start
		velocity = vectorVelocityFromRanges(start, finish, math.max(1, life.center or 1))
	elseif locationType == 3 then
		local container = fcurveContainerAt(node, {
			"LocationValues/LocationFCurve/FCurve",
			"LocationValues/FCurve/FCurve",
			"LocationValues/LocationFCurve",
			"LocationValues/FCurve",
		})
		local baked = if container then bakeFCurveVector(container, life, { x = 0, y = 0, z = 0 }) else nil
		if baked then
			positionKeys = baked
			position = baked.values[1]
			positionRange = vectorRangeFromVector(position)
			local last = baked.values[#baked.values]
			local frames = math.max(1, baked.frames[#baked.frames] - baked.frames[1])
			velocity = vectorRangeFromVector(divideVector(subtractVectors(last, position), frames))
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

	acceleration = addVectorRanges(acceleration, fieldAcceleration(node, warnings, nodeName))

	return {
		type = locationType,
		position = position,
		positionRange = positionRange,
		positionKeys = positionKeys,
		velocity = velocity,
		acceleration = acceleration,
		emissionDirection = dominantDirection(velocity.center),
		spreadAngle = spreadFromRange(velocity),
	}
end

local function rotationPayload(node, life, warnings, nodeName: string)
	local rotationType = intAt(node, "RotationValues/Type", 0)
	local rotation = { center = 0, min = 0, max = 0 }
	local speed = { center = 0, min = 0, max = 0 }
	local rotation3 = randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local speed3 = randomVectorAt(node, "__missing__", { x = 0, y = 0, z = 0 })
	local rotationKeys = nil

	if rotationType == 0 then
		local fixed = fixedVectorAt(node, "RotationValues/Fixed/Rotation", { x = 0, y = 0, z = 0 })
		rotation3 = vectorRangeFromVector(fixed)
		rotation = { center = fixed.z, min = fixed.z, max = fixed.z }
	elseif rotationType == 1 then
		rotation3 = randomVectorAt(node, "RotationValues/PVA/Rotation", { x = 0, y = 0, z = 0 })
		speed3 = randomVectorAt(node, "RotationValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		rotation = randomNumberAt(node, "RotationValues/PVA/Rotation/Z", 0)
		speed = randomNumberAt(node, "RotationValues/PVA/Velocity/Z", 0)
	elseif rotationType == 2 then
		local start3 = randomVectorAt(node, "RotationValues/Easing/Start", { x = 0, y = 0, z = 0 })
		local finish3 = randomVectorAt(node, "RotationValues/Easing/End", start3.center)
		local frames = math.max(1, life.center or 1)
		rotation3 = start3
		speed3 = vectorVelocityFromRanges(start3, finish3, frames)
		rotation = { center = start3.center.z, min = start3.min.z, max = start3.max.z }
		speed = numberVelocityFromRanges(
			{ center = start3.center.z, min = start3.min.z, max = start3.max.z },
			{ center = finish3.center.z, min = finish3.min.z, max = finish3.max.z },
			frames
		)
	elseif rotationType == 3 then
		rotation = randomNumberAt(node, "RotationValues/AxisPVA/Rotation", 0)
		speed = randomNumberAt(node, "RotationValues/AxisPVA/Velocity", 0)
	elseif rotationType == 4 then
		rotation = randomNumberAt(node, "RotationValues/AxisEasing/Easing/Start", 0)
		local finish = randomNumberAt(node, "RotationValues/AxisEasing/Easing/End", rotation.center)
		speed = numberVelocityFromRanges(rotation, finish, math.max(1, life.center or 1))
	elseif rotationType == 5 then
		local container = fcurveContainerAt(node, {
			"RotationValues/RotationFCurve/FCurve",
			"RotationValues/FCurve/FCurve",
			"RotationValues/RotationFCurve",
		})
		local baked = if container then bakeFCurveVector(container, life, { x = 0, y = 0, z = 0 }) else nil
		if baked then
			rotationKeys = baked
			local first = baked.values[1]
			local last = baked.values[#baked.values]
			local frames = math.max(1, baked.frames[#baked.frames] - baked.frames[1])
			local averageSpeed = divideVector(subtractVectors(last, first), frames)
			rotation3 = vectorRangeFromVector(first)
			speed3 = vectorRangeFromVector(averageSpeed)
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
	}
end

local function scalePayload(node, life, warnings, nodeName: string)
	local scaleType = intAt(node, "ScalingValues/Type", 0)
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
		local scale = fixedVectorAt(node, "ScalingValues/Fixed/Scale", { x = 1, y = 1, z = 1 })
		start = math.max(0, averageXY(scale))
		finish = start
		startVector = scaleVector(scale)
		finishVector = startVector
	elseif scaleType == 1 then
		local base = randomVectorAt(node, "ScalingValues/PVA/Scale", { x = 1, y = 1, z = 1 })
		local velocity = randomVectorAt(node, "ScalingValues/PVA/Velocity", { x = 0, y = 0, z = 0 })
		local acceleration = randomVectorAt(node, "ScalingValues/PVA/Acceleration", { x = 0, y = 0, z = 0 })
		local lifeFrames = life.center
		start = math.max(0, averageXY(base.center))
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
		startVector = scaleVector(base.center)
		finishVector = scaleVector({ x = endX, y = endY, z = endZ })
		pva = { scale = base, velocity = velocity, acceleration = acceleration }
	elseif scaleType == 2 then
		local startRange = randomVectorAt(node, "ScalingValues/Easing/Start", { x = 1, y = 1, z = 1 })
		local finishRange = randomVectorAt(node, "ScalingValues/Easing/End", startRange.center)
		start = math.max(0, averageXY(startRange.center))
		finish = math.max(0, averageXY(finishRange.center))
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
		startVector = scaleVector(startRange.center)
		finishVector = scaleVector(finishRange.center)
		easing = { start = startRange, finish = finishRange }
	elseif scaleType == 3 then
		local base = randomNumberAt(node, "ScalingValues/SinglePVA/Scale", 1)
		local velocity = randomNumberAt(node, "ScalingValues/SinglePVA/Velocity", 0)
		local acceleration = randomNumberAt(node, "ScalingValues/SinglePVA/Acceleration", 0)
		local lifeFrames = life.center
		start = math.max(0, math.abs(base.center))
		finish = math.max(
			0,
			math.abs(base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames)
		)
		envelope = math.max(0, (base.max - base.min) * 0.5)
		startVector = singleScaleVector(base.center)
		finishVector = singleScaleVector(
			base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames
		)
		singlePva = { scale = base, velocity = velocity, acceleration = acceleration }
	elseif scaleType == 4 then
		local startRange = randomNumberAt(node, "ScalingValues/SingleEasing/Start", 1)
		local finishRange = randomNumberAt(node, "ScalingValues/SingleEasing/End", startRange.center)
		start = math.max(0, math.abs(startRange.center))
		finish = math.max(0, math.abs(finishRange.center))
		envelope = math.max(0, math.max(startRange.max - startRange.min, finishRange.max - finishRange.min) * 0.5)
		startVector = singleScaleVector(startRange.center)
		finishVector = singleScaleVector(finishRange.center)
		singleEasing = { start = startRange, finish = finishRange }
	elseif scaleType == 5 or scaleType == 6 then
		local container = if scaleType == 5
			then fcurveContainerAt(node, { "ScalingValues/FCurve/FCurve", "ScalingValues/FCurve" })
			else fcurveContainerAt(node, { "ScalingValues/SingleFCurve/FCurve", "ScalingValues/SingleFCurve" })
		local baked = if container then bakeFCurveVector(container, life, { x = 1, y = 1, z = 1 }) else nil
		if baked then
			scaleKeys = baked
			local first = baked.values[1]
			local last = baked.values[#baked.values]
			start = math.max(0, averageXY(first))
			finish = math.max(0, averageXY(last))
			startVector = scaleVector(first)
			finishVector = scaleVector(last)
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

local function texturePathFor(node): string
	return textAt(node, "RendererCommonValues/ColorTexture")
		or textAt(node, "DrawingValues/Sprite/ColorTexture")
		or textAt(node, "DrawingValues/Ribbon/ColorTexture")
		or textAt(node, "DrawingValues/Ring/ColorTexture")
		or textAt(node, "DrawingValues/Track/ColorTexture")
		or ""
end

local function modelPathFor(node): string
	return textAt(node, "DrawingValues/Model/Model") or ""
end

local function spritePositionPayload(node)
	if intAt(node, "DrawingValues/Sprite/Position", 0) ~= 1 then
		return nil
	end

	local points = {
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LL", { x = -0.5, y = -0.5, z = 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LR", { x = 0.5, y = -0.5, z = 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UL", { x = -0.5, y = 0.5, z = 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UR", { x = 0.5, y = 0.5, z = 0 }),
	}
	local minX = math.huge
	local maxX = -math.huge
	local minY = math.huge
	local maxY = -math.huge

	for _, point in ipairs(points) do
		minX = math.min(minX, point.x or 0)
		maxX = math.max(maxX, point.x or 0)
		minY = math.min(minY, point.y or 0)
		maxY = math.max(maxY, point.y or 0)
	end

	return {
		center = {
			x = (minX + maxX) * 0.5,
			y = (minY + maxY) * 0.5,
		},
		size = {
			x = math.max(0.01, maxX - minX),
			y = math.max(0.01, maxY - minY),
		},
	}
end

local function builtInTextureFor(texturePath: string): string
	local name = string.lower(string.match(texturePath, "[^/\\]+$") or texturePath)
	if string.find(name, "flame", 1, true) or string.find(name, "fire", 1, true) then
		return "rbxasset://textures/particles/fire_main.dds"
	end
	if
		string.find(name, "cloud", 1, true)
		or string.find(name, "smoke", 1, true)
		or string.find(name, "wind", 1, true)
	then
		return "rbxasset://textures/particles/smoke_main.dds"
	end
	return "rbxasset://textures/particles/sparkles_main.dds"
end

local function assetMapValue(assetMap, assetPath: string): string?
	local direct = assetMap[assetPath]
	if direct and direct ~= "" then
		return direct
	end

	local basename = string.match(assetPath, "[^/\\]+$")
	if basename then
		local named = assetMap[basename]
		if named and named ~= "" then
			return named
		end

		local textureNamed = assetMap["Texture/" .. basename]
		if textureNamed and textureNamed ~= "" then
			return textureNamed
		end

		local modelNamed = assetMap["Model/" .. basename]
		if modelNamed and modelNamed ~= "" then
			return modelNamed
		end
	end

	local lowered = string.lower(assetPath)
	local lowerDirect = assetMap[lowered]
	if lowerDirect and lowerDirect ~= "" then
		return lowerDirect
	end

	if basename then
		local lowerBasename = string.lower(basename)
		local lowerNamed = assetMap[lowerBasename]
		if lowerNamed and lowerNamed ~= "" then
			return lowerNamed
		end

		local lowerTextureNamed = assetMap["texture/" .. lowerBasename]
		if lowerTextureNamed and lowerTextureNamed ~= "" then
			return lowerTextureNamed
		end

		local lowerModelNamed = assetMap["model/" .. lowerBasename]
		if lowerModelNamed and lowerModelNamed ~= "" then
			return lowerModelNamed
		end
	end

	return nil
end

local function ringRadiusPayload(ringNode, name: string, defaultValue: number, life)
	if not ringNode then
		return { start = defaultValue, finish = defaultValue }
	end
	local radiusType = intAt(ringNode, name, 0)
	if radiusType == 1 then
		local location = randomNumberAt(ringNode, name .. "_PVA/Location/X", defaultValue)
		local velocity = randomNumberAt(ringNode, name .. "_PVA/Velocity/X", 0)
		local acceleration = randomNumberAt(ringNode, name .. "_PVA/Acceleration/X", 0)
		local frames = math.max(1, life.center or 1)
		return {
			start = location.center,
			finish = location.center + velocity.center * frames + 0.5 * acceleration.center * frames * frames,
		}
	end
	if radiusType == 2 then
		local start = randomNumberAt(ringNode, name .. "_Easing/Start/X", defaultValue)
		local finish = randomNumberAt(ringNode, name .. "_Easing/End/X", start.center)
		return { start = start.center, finish = finish.center }
	end
	local fixed = numberAt(ringNode, name .. "_Fixed/Location/X", defaultValue)
	return { start = fixed, finish = fixed }
end

local function visualPayload(node, rendererType: string, modelPath: string, modelAsset: string?, life)
	local size = {}

	if rendererType == "Sprite" then
		size.sprite = {
			billboard = intAt(node, "DrawingValues/Sprite/Billboard", 0),
			position = spritePositionPayload(node),
		}
	elseif rendererType == "Ribbon" then
		local left = numberAt(node, "DrawingValues/Ribbon/Position_Fixed_L", -0.5)
		local right = numberAt(node, "DrawingValues/Ribbon/Position_Fixed_R", 0.5)
		size.beam = {
			width = math.max(0.01, math.abs(right - left)),
			length = math.max(0.25, math.abs(right - left) * 6),
		}
	elseif rendererType == "Track" then
		local front = numberAt(node, "DrawingValues/Track/TrackSizeFor_Fixed", 0)
		local middle = numberAt(node, "DrawingValues/Track/TrackSizeMiddle_Fixed", 1)
		local back = numberAt(node, "DrawingValues/Track/TrackSizeBack_Fixed", front)
		local width = math.max(0.01, middle ~= 0 and middle or front ~= 0 and front or back ~= 0 and back or 1)
		size.beam = {
			width = width,
			length = math.max(0.25, math.abs(front - back) ~= 0 and math.abs(front - back) or width * 8),
		}
	elseif rendererType == "Ring" then
		local ring = find(node, "DrawingValues/Ring")
		local outer = ringRadiusPayload(ring, "Outer", 1, life)
		local inner = ringRadiusPayload(ring, "Inner", 0, life)
		size.ring = {
			vertexCount = intAt(node, "DrawingValues/Ring/VertexCount", 32),
			outerRadius = math.max(0.01, math.abs(if outer.start ~= 0 then outer.start else 1)),
			innerRadius = math.max(0, math.abs(inner.start)),
			outerRadiusFinish = math.max(
				0.01,
				math.abs(if outer.finish ~= 0 then outer.finish else outer.start ~= 0 and outer.start or 1)
			),
			innerRadiusFinish = math.max(0, math.abs(inner.finish)),
			billboard = intAt(node, "DrawingValues/Ring/Billboard", 0),
		}
	elseif rendererType == "Model" then
		size.model = {
			path = modelPath,
			asset = modelAsset,
		}
	end

	return size
end

local function sortedKeys(setTable)
	local result = {}
	for key in pairs(setTable) do
		table.insert(result, key)
	end
	table.sort(result)
	return result
end

local function convertNode(node, context, idPrefix: string)
	local nodeName = textAt(node, "Name") or ("Node" .. idPrefix)
	local rendererType = rendererTypeFor(node)
	local rendered = boolAt(node, "IsRendered", true) and rendererType ~= "None"
	local life = nodeLife(node)
	local color = colorPayload(node, context.warnings, nodeName)
	local texturePath = texturePathFor(node)
	local texture = nil
	if texturePath ~= "" then
		context.dependencies.textures[texturePath] = true
		texture = assetMapValue(context.assetMap, texturePath)
		if not texture and context.useFallbackTextures then
			texture = builtInTextureFor(texturePath)
		end
	end

	local modelPath = if rendererType == "Model" then modelPathFor(node) else ""
	local modelAsset = nil
	if modelPath ~= "" then
		context.dependencies.models[modelPath] = true
		modelAsset = assetMapValue(context.assetMap, modelPath)
	end

	if rendered and not SUPPORTED_RENDERERS[rendererType] then
		table.insert(
			context.warnings,
			warning(
				"renderer_unsupported",
				"Renderer " .. rendererType .. " is not supported by the Roblox runtime.",
				nodeName
			)
		)
		rendered = false
	end
	if rendered and texturePath ~= "" and not texture then
		table.insert(
			context.warnings,
			warning("texture_unmapped", "No Roblox asset id mapped for texture '" .. texturePath .. "'.", nodeName)
		)
	end
	if rendered and rendererType == "Model" and modelPath ~= "" and not modelAsset then
		table.insert(
			context.warnings,
			warning(
				"model_unmapped",
				"No Roblox asset id mapped for model '" .. modelPath .. "'. A placeholder part will be used.",
				nodeName
			)
		)
	end

	local uv = if rendered then uvPayload(node, context.warnings, nodeName) else nil
	local spawn = spawnPayload(node, context.warnings, nodeName)
	local sound = soundPayload(node, context, nodeName)
	local alphaBlend = alphaBlendAt(node)

	if rendered then
		local materialType = intAt(node, "RendererCommonValues/Material", 0)
		if materialType == 6 or boolAt(node, "RendererCommonValues/Distortion", false) then
			table.insert(
				context.warnings,
				warning("distortion_unsupported", "Background distortion is rendered as a plain texture.", nodeName)
			)
		elseif materialType == 128 then
			table.insert(
				context.warnings,
				warning(
					"material_unsupported",
					"Custom material files are not supported; textures may be missing.",
					nodeName
				)
			)
		elseif materialType == 7 then
			table.insert(
				context.warnings,
				warning("material_unsupported", "Lighting material is approximated with unlit rendering.", nodeName)
			)
		end
		if alphaBlend == 3 or alphaBlend == 4 then
			table.insert(
				context.warnings,
				warning(
					"blend_unsupported",
					(if alphaBlend == 3 then "Subtract" else "Multiply")
						.. " blending is approximated with normal blending.",
					nodeName
				)
			)
		end
	end

	local location = locationPayload(node, context.warnings, nodeName, life)
	if spawn and spawn.type == 0 and spawn.point then
		location.position = addVectors(location.position, spawn.point.location.center)
		location.positionRange = addVectorRanges(location.positionRange, spawn.point.location)
		spawn = nil
	end
	local speedMin = vectorMagnitude(location.velocity.min)
	local speedMax = vectorMagnitude(location.velocity.max)
	if speedMin > speedMax then
		speedMin, speedMax = speedMax, speedMin
	end

	-- Evaluate rotation/scale before recursing so warning order matches converter.js.
	local rotation = rotationPayload(node, life, context.warnings, nodeName)
	local size = scalePayload(node, life, context.warnings, nodeName)

	local childRoot = find(node, "Children")
	local childNodes = if childRoot then children(childRoot, "Node") else {}
	local convertedChildren = {}
	for index, childNode in ipairs(childNodes) do
		table.insert(convertedChildren, convertNode(childNode, context, idPrefix .. "_" .. tostring(index)))
	end

	return {
		id = idPrefix,
		name = nodeName,
		rendererType = rendererType,
		rendered = rendered,
		texturePath = texturePath,
		texture = texture,
		alphaBlend = alphaBlend,
		zTest = boolAt(node, "RendererCommonValues/ZTest", true),
		fadeIn = fadeFrameAt(node, "FadeIn"),
		fadeOut = fadeFrameAt(node, "FadeOut"),
		color = color.color,
		colorOverLife = color.colorOverLife,
		uv = uv,
		spawn = spawn,
		sound = sound,
		visual = visualPayload(node, rendererType, modelPath, modelAsset, life),
		life = life,
		generation = {
			max = maxGeneration(node),
			time = generationTime(node),
			offset = generationOffset(node),
		},
		transform = {
			position = location.position,
			positionRange = location.positionRange,
			positionKeys = location.positionKeys,
			velocity = location.velocity,
			acceleration = location.acceleration,
			speed = { min = speedMin, max = speedMax },
			emissionDirection = location.emissionDirection,
			spreadAngle = location.spreadAngle,
			rotation = rotation,
			size = size,
		},
		children = convertedChildren,
	}
end

function Converter.convertProject(xml: string, options)
	options = options or {}
	local projectRoot = parseXml(xml)
	if projectRoot.name ~= "EffekseerProject" then
		error("Expected EffekseerProject XML root, got " .. projectRoot.name)
	end

	local context = {
		warnings = {},
		dependencies = {
			textures = {},
			models = {},
			sounds = {},
		},
		assetMap = options.assetMap or {},
		useFallbackTextures = options.useFallbackTextures == true,
	}
	context.assetMapLookup = function(assetPath: string)
		return assetMapValue(context.assetMap, assetPath)
	end

	local childRoot = find(projectRoot, "Root/Children")
	local rootNodes = if childRoot then children(childRoot, "Node") else {}
	local nodes = {}
	for index, node in ipairs(rootNodes) do
		table.insert(nodes, convertNode(node, context, tostring(index)))
	end
	local startFrame = numberAt(projectRoot, "StartFrame", 0)
	local endFrame = numberAt(projectRoot, "EndFrame", 0)

	return {
		format = "EffekseerRobloxEffect",
		formatVersion = 2,
		name = options.moduleName or "ImportedEffect",
		source = options.source or "Studio import",
		frameRate = options.frameRate or 60,
		startFrame = startFrame,
		endFrame = endFrame,
		durationFrames = math.max(0, endFrame - startFrame),
		isLoop = boolAt(projectRoot, "IsLoop", false),
		unitScale = options.unitScale or 0.2,
		particleSizeScale = options.particleSizeScale or 1,
		dependencies = {
			textures = sortedKeys(context.dependencies.textures),
			models = sortedKeys(context.dependencies.models),
			sounds = sortedKeys(context.dependencies.sounds),
		},
		warnings = context.warnings,
		nodes = nodes,
	}
end

local function luaKey(key: string): string
	return if string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") and not LUA_RESERVED[key]
		then key
		else "[" .. string.format("%q", key) .. "]"
end

local function luaNumber(value: number): string
	if value % 1 == 0 then
		return tostring(value)
	end
	return string.format("%.9g", value)
end

function Converter.toLuau(value, depth: number?): string
	depth = depth or 0
	local pad = string.rep("\t", depth)
	local childPad = string.rep("\t", depth + 1)

	if value == nil then
		return "nil"
	end
	if type(value) == "boolean" then
		return if value then "true" else "false"
	end
	if type(value) == "number" then
		return luaNumber(value)
	end
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) == "table" then
		local isArray = true
		local count = 0
		for key in pairs(value) do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				isArray = false
			end
		end
		if count == 0 then
			return "{}"
		end

		local lines = {}
		if isArray then
			for index = 1, count do
				table.insert(lines, childPad .. Converter.toLuau(value[index], depth + 1) .. ",")
			end
		else
			local keys = {}
			for key, item in pairs(value) do
				if item ~= nil then
					table.insert(keys, key)
				end
			end
			table.sort(keys, function(left, right)
				return tostring(left) < tostring(right)
			end)
			for _, key in ipairs(keys) do
				table.insert(
					lines,
					childPad .. luaKey(tostring(key)) .. " = " .. Converter.toLuau(value[key], depth + 1) .. ","
				)
			end
		end

		return "{\n" .. table.concat(lines, "\n") .. "\n" .. pad .. "}"
	end
	error("Cannot serialize " .. type(value) .. " to Luau")
end

function Converter.toModuleSource(effect): string
	return table.concat({
		"-- Generated by EffekseerForRoblox Studio plugin.",
		"-- Regenerate this file from the source Effekseer project instead of editing by hand.",
		"-- Source: " .. tostring(effect.source),
		"",
		"return " .. Converter.toLuau(effect),
		"",
	}, "\n")
end

return Converter
