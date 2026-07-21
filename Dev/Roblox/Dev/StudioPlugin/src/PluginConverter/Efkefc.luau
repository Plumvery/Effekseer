--!nonstrict
-- .efkefc container support: walks the EFKE chunk list and decodes the EDIT
-- chunk's binary XML (same layout converter.js reads) into a parsed node tree.

local Inflate = require(script.Parent:WaitForChild("Inflate"))

local Efkefc = {}

-- Decodes the EDIT chunk payload (shared key/value dictionaries + element tree).
local function decodeEditPayload(payload: buffer)
	local cursor = { offset = 0 }
	local function readI16(): number
		local value = buffer.readi16(payload, cursor.offset)
		cursor.offset += 2
		return value
	end
	local function readI32(): number
		local value = buffer.readi32(payload, cursor.offset)
		cursor.offset += 4
		return value
	end
	local function readUtf8Len16(): string
		local length = buffer.readu16(payload, cursor.offset)
		cursor.offset += 2
		local value = buffer.readstring(payload, cursor.offset, length)
		cursor.offset += length
		return value
	end

	local keys = {}
	for _ = 1, readI16() do
		local name = readUtf8Len16()
		keys[readI16()] = name
	end

	local values = {}
	for _ = 1, readI16() do
		local value = readUtf8Len16()
		values[readI16()] = value
	end

	local function readElements()
		local count = readI16()
		local result = {}
		for _ = 1, count do
			local node = { name = keys[readI16()] or "", text = "", children = {} }
			if readI32() > 0 then
				node.text = values[readI16()] or ""
			end
			if readI32() > 0 then
				node.children = readElements()
			end
			table.insert(result, node)
		end
		return result
	end

	local roots = readElements()
	if #roots ~= 1 then
		error("EDIT chunk did not contain exactly one XML root")
	end
	return roots[1]
end

function Efkefc.parseEfkefcRoot(binary: string)
	if #binary < 16 or string.sub(binary, 1, 4) ~= "EFKE" then
		error("Not an Effekseer .efkefc file")
	end

	local data = buffer.fromstring(binary)
	local offset = 8
	local total = buffer.len(data)
	while offset + 8 <= total do
		local chunkName = buffer.readstring(data, offset, 4)
		local chunkSize = buffer.readu32(data, offset + 4)
		offset += 8
		if chunkName == "EDIT" then
			return decodeEditPayload(Inflate.inflateZlib(data, offset))
		end
		offset += chunkSize
	end

	error("The .efkefc file does not contain an EDIT chunk")
end

return Efkefc
