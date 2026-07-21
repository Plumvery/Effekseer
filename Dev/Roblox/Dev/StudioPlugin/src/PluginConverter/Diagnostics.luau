--!nonstrict
-- Conversion warning records shared by every payload extractor.

local Diagnostics = {}

function Diagnostics.warning(code: string, message: string, nodeName: string?)
	local value = { code = code, message = message }
	if nodeName then
		value.node = nodeName
	end
	return value
end

return Diagnostics
