--!nonstrict
-- Pure-Luau zlib/DEFLATE decompressor (RFC 1950/1951) used for .efkefc EDIT chunks.

local Inflate = {}

local INFLATE_LENGTH_BASE = {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
local INFLATE_LENGTH_EXTRA = {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}
local INFLATE_DIST_BASE = {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
local INFLATE_DIST_EXTRA = {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}
local INFLATE_CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function buildHuffmanTree(lengths: { number }, symbolCount: number)
	local bitLengthCounts = {}
	local maxBits = 0
	for symbol = 1, symbolCount do
		local length = lengths[symbol] or 0
		if length > 0 then
			bitLengthCounts[length] = (bitLengthCounts[length] or 0) + 1
			if length > maxBits then
				maxBits = length
			end
		end
	end

	local nextCode = {}
	local code = 0
	for bits = 1, maxBits do
		code = (code + (bitLengthCounts[bits - 1] or 0)) * 2
		nextCode[bits] = code
	end

	local codes = {}
	for bits = 1, maxBits do
		codes[bits] = {}
	end
	for symbol = 1, symbolCount do
		local length = lengths[symbol] or 0
		if length > 0 then
			codes[length][nextCode[length]] = symbol - 1
			nextCode[length] += 1
		end
	end
	return { codes = codes, maxBits = maxBits }
end

local function inflateBitReader(data: buffer, offset: number)
	return { data = data, offset = offset, currentByte = 0, bitCount = 0 }
end

local function readBit(reader): number
	if reader.bitCount == 0 then
		reader.currentByte = buffer.readu8(reader.data, reader.offset)
		reader.offset += 1
		reader.bitCount = 8
	end
	local bit = reader.currentByte % 2
	reader.currentByte = (reader.currentByte - bit) / 2
	reader.bitCount -= 1
	return bit
end

local function readBitsValue(reader, count: number): number
	local value = 0
	local scale = 1
	for _ = 1, count do
		value += readBit(reader) * scale
		scale *= 2
	end
	return value
end

local function decodeSymbol(reader, tree): number
	local code = 0
	for bits = 1, tree.maxBits do
		code = code * 2 + readBit(reader)
		local symbol = tree.codes[bits] and tree.codes[bits][code]
		if symbol ~= nil then
			return symbol
		end
	end
	error("Invalid Huffman code in compressed effect data")
end

local FIXED_LITERAL_TREE = nil
local FIXED_DISTANCE_TREE = nil

local function fixedTrees()
	if not FIXED_LITERAL_TREE then
		local literalLengths = {}
		for symbol = 0, 287 do
			local length
			if symbol <= 143 then
				length = 8
			elseif symbol <= 255 then
				length = 9
			elseif symbol <= 279 then
				length = 7
			else
				length = 8
			end
			literalLengths[symbol + 1] = length
		end
		FIXED_LITERAL_TREE = buildHuffmanTree(literalLengths, 288)

		local distanceLengths = {}
		for symbol = 1, 30 do
			distanceLengths[symbol] = 5
		end
		FIXED_DISTANCE_TREE = buildHuffmanTree(distanceLengths, 30)
	end
	return FIXED_LITERAL_TREE, FIXED_DISTANCE_TREE
end

-- Inflates a zlib stream (2-byte header + DEFLATE blocks) into a buffer.
function Inflate.inflateZlib(data: buffer, offset: number): buffer
	local cmf = buffer.readu8(data, offset)
	local flg = buffer.readu8(data, offset + 1)
	if cmf % 16 ~= 8 then
		error("Unsupported zlib compression method in .efkefc data")
	end
	local reader = inflateBitReader(data, offset + 2)
	if flg >= 32 and math.floor(flg / 32) % 2 == 1 then
		reader.offset += 4
	end

	local capacity = 65536
	local output = buffer.create(capacity)
	local outputLength = 0
	local function ensureCapacity(extra: number)
		if outputLength + extra <= capacity then
			return
		end
		repeat
			capacity *= 2
		until outputLength + extra <= capacity
		local grown = buffer.create(capacity)
		buffer.copy(grown, 0, output, 0, outputLength)
		output = grown
	end
	local function writeByte(value: number)
		ensureCapacity(1)
		buffer.writeu8(output, outputLength, value)
		outputLength += 1
	end

	while true do
		local finalBlock = readBit(reader)
		local blockType = readBitsValue(reader, 2)

		if blockType == 0 then
			-- Stored: skip to the byte boundary, then LEN/NLEN + raw bytes.
			reader.bitCount = 0
			local length = buffer.readu16(reader.data, reader.offset)
			reader.offset += 4
			ensureCapacity(length)
			buffer.copy(output, outputLength, reader.data, reader.offset, length)
			outputLength += length
			reader.offset += length
		elseif blockType == 1 or blockType == 2 then
			local literalTree, distanceTree
			if blockType == 1 then
				literalTree, distanceTree = fixedTrees()
			else
				local literalCount = readBitsValue(reader, 5) + 257
				local distanceCount = readBitsValue(reader, 5) + 1
				local codeLengthCount = readBitsValue(reader, 4) + 4
				local codeLengthLengths = {}
				for index = 1, codeLengthCount do
					codeLengthLengths[INFLATE_CODE_LENGTH_ORDER[index] + 1] = readBitsValue(reader, 3)
				end
				local codeLengthTree = buildHuffmanTree(codeLengthLengths, 19)

				local lengths = {}
				local position = 1
				while position <= literalCount + distanceCount do
					local symbol = decodeSymbol(reader, codeLengthTree)
					if symbol < 16 then
						lengths[position] = symbol
						position += 1
					elseif symbol == 16 then
						local previous = lengths[position - 1] or 0
						for _ = 1, 3 + readBitsValue(reader, 2) do
							lengths[position] = previous
							position += 1
						end
					elseif symbol == 17 then
						for _ = 1, 3 + readBitsValue(reader, 3) do
							lengths[position] = 0
							position += 1
						end
					else
						for _ = 1, 11 + readBitsValue(reader, 7) do
							lengths[position] = 0
							position += 1
						end
					end
				end

				local literalLengths = table.move(lengths, 1, literalCount, 1, {})
				local distanceLengths = table.move(lengths, literalCount + 1, literalCount + distanceCount, 1, {})
				literalTree = buildHuffmanTree(literalLengths, literalCount)
				distanceTree = buildHuffmanTree(distanceLengths, distanceCount)
			end

			while true do
				local symbol = decodeSymbol(reader, literalTree)
				if symbol < 256 then
					writeByte(symbol)
				elseif symbol == 256 then
					break
				else
					local lengthIndex = symbol - 256
					local length = INFLATE_LENGTH_BASE[lengthIndex]
						+ readBitsValue(reader, INFLATE_LENGTH_EXTRA[lengthIndex])
					local distanceSymbol = decodeSymbol(reader, distanceTree)
					local distance = INFLATE_DIST_BASE[distanceSymbol + 1]
						+ readBitsValue(reader, INFLATE_DIST_EXTRA[distanceSymbol + 1])
					ensureCapacity(length)
					for _ = 1, length do
						buffer.writeu8(output, outputLength, buffer.readu8(output, outputLength - distance))
						outputLength += 1
					end
				end
			end
		else
			error("Invalid DEFLATE block type in .efkefc data")
		end

		if finalBlock == 1 then
			break
		end
	end

	local result = buffer.create(outputLength)
	buffer.copy(result, 0, output, 0, outputLength)
	return result
end

return Inflate
