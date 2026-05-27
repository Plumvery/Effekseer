local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")
local Workspace = game:GetService("Workspace")

local Converter = require(script.Parent:WaitForChild("PluginConverter"))

local RUNTIME_NAME = "EffekseerRoblox"
local EFFECTS_NAME = "EffekseerEffects"
local PREVIEW_ANCHOR_NAME = "EffekseerPluginPreviewAnchor"

local toolbar = plugin:CreateToolbar("Effekseer")
local installButton = toolbar:CreateButton(
	"InstallRuntime",
	"Install or update the Effekseer runtime in ReplicatedStorage",
	"",
	"Install Runtime"
)
local importProjectButton =
	toolbar:CreateButton("ImportEfkproj", "Import an Effekseer .efkproj file", "", "Import .efkproj")
local importTexturesButton =
	toolbar:CreateButton("ImportTextures", "Import local texture files for Studio preview", "", "Import Textures")
local importLuauButton =
	toolbar:CreateButton("ImportLuau", "Import an Effekseer generated .luau ModuleScript", "", "Import .luau")
local previewButton =
	toolbar:CreateButton("PreviewEffect", "Preview the selected Effekseer ModuleScript in Studio", "", "Preview")

local activeController = nil
local activeAnchor: BasePart? = nil
local lastImportedModule: ModuleScript? = nil
local sessionAssetMap: { [string]: string } = {}
local heldImportedFiles = {}

local function log(message: string)
	print("[EffekseerForRoblox] " .. message)
end

local function warnLog(message: string)
	warn("[EffekseerForRoblox] " .. message)
end

local function safeName(value: string?, fallback: string): string
	local name = value or fallback
	name = name:gsub("\\", "/")
	name = name:match("([^/]+)$") or name
	name = name:gsub("%.[^.]+$", "")
	name = name:gsub("[^%w_]", "_")
	if name == "" then
		name = fallback
	end
	if not name:match("^[A-Za-z_]") then
		name = "Effect_" .. name
	end
	return name
end

local function uniqueChildName(parent: Instance, desiredName: string): string
	if not parent:FindFirstChild(desiredName) then
		return desiredName
	end

	local index = 2
	while parent:FindFirstChild(desiredName .. "_" .. tostring(index)) do
		index += 1
	end
	return desiredName .. "_" .. tostring(index)
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function installRuntime(force: boolean)
	local existing = ReplicatedStorage:FindFirstChild(RUNTIME_NAME)
	if existing and force then
		existing:Destroy()
		existing = nil
	end
	if existing then
		return existing
	end

	local template = script.Parent:FindFirstChild(RUNTIME_NAME)
	if not template then
		error("Plugin package is missing " .. RUNTIME_NAME)
	end

	local runtime = template:Clone()
	runtime.Name = RUNTIME_NAME
	runtime.Parent = ReplicatedStorage
	return runtime
end

local function promptImportFile(fileTypes)
	local ok, file = pcall(function()
		if StudioService.PromptImportFileAsync then
			return StudioService:PromptImportFileAsync(fileTypes)
		end
		return StudioService:PromptImportFile(fileTypes)
	end)
	if not ok then
		error(file)
	end
	return file
end

local function promptImportFiles(fileTypes)
	local ok, files = pcall(function()
		if StudioService.PromptImportFilesAsync then
			return StudioService:PromptImportFilesAsync(fileTypes)
		end
		return StudioService:PromptImportFiles(fileTypes)
	end)
	if not ok then
		error(files)
	end
	return files
end

local function readFile(file): string
	local ok, contents = pcall(function()
		return file:GetBinaryContents()
	end)
	if not ok then
		error(contents)
	end
	return contents
end

local function fileName(file, fallback: string): string
	local ok, value = pcall(function()
		return file.Name
	end)
	return if ok and type(value) == "string" and value ~= "" then value else fallback
end

local function mapAssetName(name: string, temporaryId: string)
	local basename = name:gsub("\\", "/"):match("([^/]+)$") or name
	sessionAssetMap[basename] = temporaryId
	sessionAssetMap["Texture/" .. basename] = temporaryId
	sessionAssetMap["Model/" .. basename] = temporaryId

	local lowerBasename = string.lower(basename)
	sessionAssetMap[lowerBasename] = temporaryId
	sessionAssetMap["texture/" .. lowerBasename] = temporaryId
	sessionAssetMap["model/" .. lowerBasename] = temporaryId
end

local function assetMapValue(assetPath: string): string?
	local direct = sessionAssetMap[assetPath]
	if direct and direct ~= "" then
		return direct
	end

	local basename = assetPath:gsub("\\", "/"):match("([^/]+)$")
	if basename then
		local named = sessionAssetMap[basename]
		if named and named ~= "" then
			return named
		end

		local textureNamed = sessionAssetMap["Texture/" .. basename]
		if textureNamed and textureNamed ~= "" then
			return textureNamed
		end
	end

	local lowered = string.lower(assetPath)
	local lowerDirect = sessionAssetMap[lowered]
	if lowerDirect and lowerDirect ~= "" then
		return lowerDirect
	end

	if basename then
		local lowerBasename = string.lower(basename)
		local lowerNamed = sessionAssetMap[lowerBasename]
		if lowerNamed and lowerNamed ~= "" then
			return lowerNamed
		end

		local lowerTextureNamed = sessionAssetMap["texture/" .. lowerBasename]
		if lowerTextureNamed and lowerTextureNamed ~= "" then
			return lowerTextureNamed
		end
	end

	return nil
end

local function missingTexturePaths(effect): { string }
	local missing = {}
	for _, texturePath in ipairs(effect.dependencies and effect.dependencies.textures or {}) do
		if not assetMapValue(texturePath) then
			table.insert(missing, texturePath)
		end
	end
	return missing
end

local function importTextureFiles(files): number
	local count = 0
	for _, file in ipairs(files) do
		local ok, temporaryId = pcall(function()
			return file:GetTemporaryId()
		end)
		if ok and temporaryId and temporaryId ~= "" then
			table.insert(heldImportedFiles, file)
			mapAssetName(fileName(file, "Texture.png"), temporaryId)
			count += 1
		else
			warnLog("Failed to create temporary texture id for " .. fileName(file, "Texture.png"))
		end
	end
	return count
end

local function promptImportMissingTextures(effect): boolean
	local missing = missingTexturePaths(effect)
	if #missing == 0 then
		return false
	end

	warnLog(
		("This effect references %d texture file(s). Select the files from the effect Texture folder to preview correctly."):format(
			#missing
		)
	)
	for _, texturePath in ipairs(missing) do
		warnLog("Missing texture: " .. texturePath)
	end

	local ok, files = pcall(function()
		return promptImportFiles({ "png", "jpg", "jpeg", "bmp", "tga" })
	end)
	if not ok or not files or #files == 0 then
		warnLog("Texture import was skipped; textured nodes will not be shown instead of using a white fallback.")
		return false
	end

	local count = importTextureFiles(files)
	log(("Imported %d local texture file(s)."):format(count))
	return count > 0
end

local function createEffectModule(moduleName: string, source: string): ModuleScript
	local effectsFolder = ensureFolder(ReplicatedStorage, EFFECTS_NAME)
	local module = Instance.new("ModuleScript")
	module.Name = uniqueChildName(effectsFolder, moduleName)
	module.Source = source
	module.Parent = effectsFolder
	lastImportedModule = module
	Selection:Set({ module })
	return module
end

local function reportWarnings(effect)
	if #effect.warnings == 0 then
		return
	end
	for _, item in ipairs(effect.warnings) do
		local node = item.node and ("[" .. item.node .. "] ") or ""
		warnLog(item.code .. ": " .. node .. item.message)
	end
end

local function importEfkproj()
	local file = promptImportFile({ "efkproj" })
	if not file then
		return
	end

	installRuntime(false)
	local name = safeName(fileName(file, "ImportedEffect.efkproj"), "ImportedEffect")
	local contents = readFile(file)
	local effect = Converter.convertProject(contents, {
		moduleName = name,
		source = fileName(file, name .. ".efkproj"),
		assetMap = sessionAssetMap,
		useFallbackTextures = false,
	})
	if promptImportMissingTextures(effect) then
		effect = Converter.convertProject(contents, {
			moduleName = name,
			source = fileName(file, name .. ".efkproj"),
			assetMap = sessionAssetMap,
			useFallbackTextures = false,
		})
	end
	local module = createEffectModule(name, Converter.toModuleSource(effect))
	reportWarnings(effect)
	log("Imported " .. module:GetFullName())
end

local function importTextures()
	local files = promptImportFiles({ "png", "jpg", "jpeg", "bmp", "tga" })
	if not files or #files == 0 then
		return
	end

	local count = importTextureFiles(files)
	log(("Imported %d local texture file(s). Re-preview the effect to apply them."):format(count))
end

local function importGeneratedLuau()
	local file = promptImportFile({ "luau", "lua" })
	if not file then
		return
	end

	installRuntime(false)
	local name = safeName(fileName(file, "ImportedEffect.luau"), "ImportedEffect")
	local module = createEffectModule(name, readFile(file))
	log("Imported " .. module:GetFullName())
end

local function selectedEffectModule(): ModuleScript?
	for _, instance in ipairs(Selection:Get()) do
		if instance:IsA("ModuleScript") then
			return instance
		end
	end
	return lastImportedModule
end

local function destroyPreview()
	if activeController then
		activeController:Destroy()
		activeController = nil
	end
	if activeAnchor then
		activeAnchor:Destroy()
		activeAnchor = nil
	end
end

local function createPreviewAnchor(): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = PREVIEW_ANCHOR_NAME
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(0, 4, 0)
	anchor.Parent = Workspace
	return anchor
end

local function previewSelected()
	local module = selectedEffectModule()
	if not module then
		warnLog("Select an imported Effekseer ModuleScript first.")
		return
	end

	local runtime = installRuntime(false)
	local ok, effect = pcall(require, module)
	if not ok then
		warnLog("Failed to require " .. module:GetFullName() .. ": " .. tostring(effect))
		return
	end
	local runtimeOk, player = pcall(require, runtime)
	if not runtimeOk then
		warnLog("Failed to require " .. runtime:GetFullName() .. ": " .. tostring(player))
		return
	end

	destroyPreview()
	activeAnchor = createPreviewAnchor()
	activeController = player.play(effect, activeAnchor, {
		loop = true,
		autoDestroy = false,
		assetMap = sessionAssetMap,
		hideTarget = true,
		particleSizeScale = 0.45,
		burstTaskLimit = 500,
	})
	log("Previewing " .. module:GetFullName())
end

installButton.Click:Connect(function()
	local ok, err = pcall(function()
		installRuntime(true)
		log("Runtime installed in ReplicatedStorage.")
	end)
	if not ok then
		warnLog(tostring(err))
	end
end)

importProjectButton.Click:Connect(function()
	local ok, err = pcall(importEfkproj)
	if not ok then
		warnLog(tostring(err))
	end
end)

importTexturesButton.Click:Connect(function()
	local ok, err = pcall(importTextures)
	if not ok then
		warnLog(tostring(err))
	end
end)

importLuauButton.Click:Connect(function()
	local ok, err = pcall(importGeneratedLuau)
	if not ok then
		warnLog(tostring(err))
	end
end)

previewButton.Click:Connect(function()
	local ok, err = pcall(previewSelected)
	if not ok then
		warnLog(tostring(err))
	end
end)

plugin.Unloading:Connect(destroyPreview)
