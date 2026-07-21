--!nonstrict
-- Roblox asset id lookup for Effekseer texture/model/sound paths, plus the
-- built-in placeholder textures used for Studio-only previews.

local AssetMap = {}

function AssetMap.builtInTextureFor(texturePath: string): string
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

function AssetMap.assetMapValue(assetMap, assetPath: string): string?
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

return AssetMap
