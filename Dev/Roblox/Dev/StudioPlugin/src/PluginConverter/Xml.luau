--!nonstrict
-- Minimal XML parser plus typed readers for Effekseer project trees.
-- Parsed nodes are plain tables: { name: string, text: string, children: {node} }.

local Xml = {}

local function decodeXmlEntities(value: string): string
	return value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

function Xml.parseXml(xml: string)
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

function Xml.child(node, name: string)
	for _, candidate in ipairs(node.children) do
		if candidate.name == name then
			return candidate
		end
	end
	return nil
end

function Xml.children(node, name: string)
	local result = {}
	for _, candidate in ipairs(node.children) do
		if candidate.name == name then
			table.insert(result, candidate)
		end
	end
	return result
end

function Xml.find(node, xmlPath: string)
	local current = node
	for segment in string.gmatch(xmlPath, "[^/]+") do
		if not current then
			return nil
		end
		current = Xml.child(current, segment)
	end
	return current
end

local function trim(value: string): string
	return string.match(value, "^%s*(.-)%s*$")
end

function Xml.textAt(node, xmlPath: string)
	local found = Xml.find(node, xmlPath)
	if not found then
		return nil
	end
	local value = trim(found.text or "")
	return if value == "" then nil else value
end

function Xml.numberAt(node, xmlPath: string, defaultValue: number): number
	local value = Xml.textAt(node, xmlPath)
	if value == nil then
		return defaultValue
	end
	local parsed = tonumber(value)
	return if parsed ~= nil then parsed else defaultValue
end

function Xml.intAt(node, xmlPath: string, defaultValue: number): number
	return math.floor(Xml.numberAt(node, xmlPath, defaultValue) + 0.5)
end

function Xml.boolAt(node, xmlPath: string, defaultValue: boolean): boolean
	local value = Xml.textAt(node, xmlPath)
	if value == nil then
		return defaultValue
	end
	local lower = string.lower(value)
	return value == "1" or lower == "true" or lower == "yes"
end

function Xml.randomNumberAt(node, xmlPath: string, defaultValue: number)
	local base = Xml.find(node, xmlPath)
	if not base then
		return { center = defaultValue, min = defaultValue, max = defaultValue }
	end

	local directText = trim(base.text or "")
	local direct = if directText == "" then nil else tonumber(directText)
	local minValue = tonumber(Xml.textAt(base, "Min") or "")
	local maxValue = tonumber(Xml.textAt(base, "Max") or "")
	local centerValue = tonumber(Xml.textAt(base, "Center") or "")

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

function Xml.fixedVectorAt(node, xmlPath: string, defaultValue)
	return {
		x = Xml.numberAt(node, xmlPath .. "/X", defaultValue.x),
		y = Xml.numberAt(node, xmlPath .. "/Y", defaultValue.y),
		z = Xml.numberAt(node, xmlPath .. "/Z", defaultValue.z),
	}
end

function Xml.randomVectorAt(node, xmlPath: string, defaultValue)
	local axes = {
		x = Xml.randomNumberAt(node, xmlPath .. "/X", defaultValue.x),
		y = Xml.randomNumberAt(node, xmlPath .. "/Y", defaultValue.y),
		z = Xml.randomNumberAt(node, xmlPath .. "/Z", defaultValue.z),
	}
	return {
		center = { x = axes.x.center, y = axes.y.center, z = axes.z.center },
		min = { x = axes.x.min, y = axes.y.min, z = axes.z.min },
		max = { x = axes.x.max, y = axes.y.max, z = axes.z.max },
	}
end

return Xml
