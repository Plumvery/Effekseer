local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")

local Converter = require(script.Parent:WaitForChild("PluginConverter"))

local RUNTIME_NAME = "EffekseerRoblox"
local EFFECTS_NAME = "EffekseerEffects"
local PREVIEW_ANCHOR_NAME = "EffekseerPluginPreviewAnchor"

local THEME = {
	background = Color3.fromRGB(30, 33, 38),
	header = Color3.fromRGB(22, 24, 29),
	surface = Color3.fromRGB(39, 43, 50),
	surfaceRaised = Color3.fromRGB(48, 53, 62),
	surfaceHover = Color3.fromRGB(57, 64, 75),
	stroke = Color3.fromRGB(70, 76, 88),
	text = Color3.fromRGB(244, 247, 251),
	muted = Color3.fromRGB(174, 182, 194),
	subtle = Color3.fromRGB(126, 136, 151),
	accent = Color3.fromRGB(83, 160, 255),
	success = Color3.fromRGB(82, 190, 128),
	warning = Color3.fromRGB(247, 183, 79),
	danger = Color3.fromRGB(236, 112, 99),
}

local toolbar = plugin:CreateToolbar("Effekseer")
local openWindowButton = toolbar:CreateButton(
	"OpenEffekseerForRoblox",
	"Open the Effekseer for Roblox plugin window",
	"",
	"Effekseer"
)
local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 380, 520, 320, 360)
local pluginWidget = plugin:CreateDockWidgetPluginGui("EffekseerForRobloxImporter", widgetInfo)
pluginWidget.Title = "Effekseer for Roblox"

local activeController = nil
local activeAnchor: BasePart? = nil
local lastImportedModule: ModuleScript? = nil
local sessionAssetMap: { [string]: any } = {}
local heldImportedFiles = {}
local heldPreviewImages = {}
local importedTextureCount = 0
local previewModuleName: string? = nil
local statusLabel: TextLabel? = nil
local runtimeValueLabel: TextLabel? = nil
local texturesValueLabel: TextLabel? = nil
local effectValueLabel: TextLabel? = nil
local previewValueLabel: TextLabel? = nil
local actionButtons: { TextButton } = {}
local isBusy = false

local function setStatus(message: string, isWarning: boolean?)
	if statusLabel then
		statusLabel.Text = message
		statusLabel.TextColor3 = if isWarning then THEME.warning else THEME.muted
	end
end

local function log(message: string)
	print("[EffekseerForRoblox] " .. message)
	setStatus(message, false)
end

local function warnLog(message: string)
	warn("[EffekseerForRoblox] " .. message)
	setStatus(message, true)
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

local function mapAssetValue(prefix: string, name: string, value)
	local basename = name:gsub("\\", "/"):match("([^/]+)$") or name
	sessionAssetMap[prefix .. basename] = value
	sessionAssetMap[prefix .. "Texture/" .. basename] = value
	sessionAssetMap[prefix .. "Model/" .. basename] = value

	local lowerBasename = string.lower(basename)
	sessionAssetMap[prefix .. lowerBasename] = value
	sessionAssetMap[prefix .. "texture/" .. lowerBasename] = value
	sessionAssetMap[prefix .. "model/" .. lowerBasename] = value
end

local function mapAssetName(name: string, temporaryId: string, additivePreviewContent)
	mapAssetValue("", name, temporaryId)
	if additivePreviewContent then
		mapAssetValue("additive:", name, additivePreviewContent)
	end
end

local function assetMapValue(assetPath: string): any
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

local function createAdditivePreviewContent(temporaryId: string)
	local ok, content = pcall(function()
		if not Content or not Content.fromUri or not Content.fromObject then
			return nil
		end
		if not AssetService.CreateEditableImageAsync or not buffer then
			return nil
		end

		local image = AssetService:CreateEditableImageAsync(Content.fromUri(temporaryId))
		if not image then
			return nil
		end
		local size = image.Size
		local width = math.floor(size.X)
		local height = math.floor(size.Y)
		if width <= 0 or height <= 0 or width * height > 4194304 then
			return nil
		end

		local pixels = image:ReadPixelsBuffer(Vector2.zero, size)
		for pixel = 0, width * height - 1 do
			local index = pixel * 4
			local r = buffer.readu8(pixels, index)
			local g = buffer.readu8(pixels, index + 1)
			local b = buffer.readu8(pixels, index + 2)
			local a = buffer.readu8(pixels, index + 3)
			local luminance = math.floor(r * 0.2126 + g * 0.7152 + b * 0.0722 + 0.5)
			local alpha = math.floor((a * luminance + 127) / 255)
			buffer.writeu8(pixels, index + 3, alpha)
		end

		image:WritePixelsBuffer(Vector2.zero, size, pixels)
		table.insert(heldPreviewImages, image)
		return Content.fromObject(image)
	end)
	return if ok then content else nil
end

local function importTextureFiles(files): number
	local count = 0
	for _, file in ipairs(files) do
		local ok, temporaryId = pcall(function()
			return file:GetTemporaryId()
		end)
		if ok and temporaryId and temporaryId ~= "" then
			local additivePreviewContent = createAdditivePreviewContent(temporaryId)
			table.insert(heldImportedFiles, file)
			mapAssetName(fileName(file, "Texture.png"), temporaryId, additivePreviewContent)
			count += 1
			importedTextureCount += 1
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
	-- .efkproj is the editor's XML project; .efkefc is the packaged binary whose
	-- EDIT chunk PluginConverter inflates and decodes directly.
	local file = promptImportFile({ "efkproj", "efkefc" })
	if not file then
		return
	end

	installRuntime(false)
	local name = safeName(fileName(file, "ImportedEffect.efkproj"), "ImportedEffect")
	local sourceName = fileName(file, name .. ".efkproj")
	local contents = readFile(file)
	local effect = Converter.convertProject(contents, {
		moduleName = name,
		source = sourceName,
		assetMap = sessionAssetMap,
		useFallbackTextures = false,
	})
	if promptImportMissingTextures(effect) then
		effect = Converter.convertProject(contents, {
			moduleName = name,
			source = sourceName,
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

local function refreshUiState()
	if runtimeValueLabel then
		runtimeValueLabel.Text = if ReplicatedStorage:FindFirstChild(RUNTIME_NAME) then "Installed" else "Not installed"
		runtimeValueLabel.TextColor3 = if ReplicatedStorage:FindFirstChild(RUNTIME_NAME) then THEME.success else THEME.subtle
	end

	if texturesValueLabel then
		texturesValueLabel.Text = tostring(importedTextureCount) .. " session file(s)"
		texturesValueLabel.TextColor3 = if importedTextureCount > 0 then THEME.success else THEME.subtle
	end

	if effectValueLabel then
		local module = selectedEffectModule()
		effectValueLabel.Text = if module then module.Name else "None"
		effectValueLabel.TextColor3 = if module then THEME.text else THEME.subtle
	end

	if previewValueLabel then
		previewValueLabel.Text = if activeController then "Running" else "Stopped"
		if activeController and previewModuleName then
			previewValueLabel.Text ..= " - " .. previewModuleName
		end
		previewValueLabel.TextColor3 = if activeController then THEME.success else THEME.subtle
	end
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
	previewModuleName = nil
	refreshUiState()
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
		unitScale = (effect.unitScale or 0.2) * 10,
		particleSizeScale = 0.45,
		burstTaskLimit = 500,
		useAdditiveSpriteParts = true,
		useAdditivePreviewTexture = true,
	})
	previewModuleName = module.Name
	refreshUiState()
	log("Previewing " .. module:GetFullName())
end

local function createInstance(className: string, properties: { [string]: any }?): Instance
	local instance: any = Instance.new(className)
	for property, value in pairs(properties or {}) do
		instance[property] = value
	end
	return instance
end

local function addCorner(instance: Instance, radius: number)
	local corner = createInstance("UICorner", {
		CornerRadius = UDim.new(0, radius),
	})
	corner.Parent = instance
end

local function addStroke(instance: Instance, color: Color3, transparency: number?)
	local stroke = createInstance("UIStroke", {
		Color = color,
		Transparency = transparency or 0,
		Thickness = 1,
	})
	stroke.Parent = instance
end

local function createText(parent: Instance, properties: { [string]: any }): TextLabel
	local label = createInstance("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextColor3 = THEME.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}) :: TextLabel
	for property, value in pairs(properties) do
		(label :: any)[property] = value
	end
	label.Parent = parent
	return label
end

local function createSection(parent: Instance, title: string): Frame
	local section = createInstance("Frame", {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.surface,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
	}) :: Frame
	section.Parent = parent
	addCorner(section, 8)
	addStroke(section, THEME.stroke, 0.25)

	local padding = createInstance("UIPadding", {
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 10),
	})
	padding.Parent = section

	local layout = createInstance("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	layout.Parent = section

	createText(section, {
		Font = Enum.Font.GothamSemibold,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Text = title,
		TextColor3 = THEME.text,
		TextSize = 14,
	})

	return section
end

local function createStatRow(parent: Instance, labelText: string): TextLabel
	local row = createInstance("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 10,
		Size = UDim2.new(1, 0, 0, 24),
	})
	row.Parent = parent

	createText(row, {
		Size = UDim2.new(0.42, -4, 1, 0),
		Text = labelText,
		TextColor3 = THEME.muted,
		TextSize = 12,
	})

	local value = createText(row, {
		Font = Enum.Font.GothamSemibold,
		Position = UDim2.new(0.42, 4, 0, 0),
		Size = UDim2.new(0.58, -4, 1, 0),
		Text = "",
		TextColor3 = THEME.subtle,
		TextSize = 12,
	})

	return value
end

local function setActionsEnabled(enabled: boolean)
	for _, button in ipairs(actionButtons) do
		button.Active = enabled
		button.AutoButtonColor = false
		button.BackgroundColor3 = if enabled then THEME.surfaceRaised else THEME.surface
	end
end

local function runPluginAction(actionName: string, action)
	if isBusy then
		return
	end

	isBusy = true
	setActionsEnabled(false)
	local pendingMessage = actionName .. "..."
	setStatus(pendingMessage, false)

	local ok, err = pcall(action)
	if not ok then
		warnLog(tostring(err))
	elseif statusLabel and statusLabel.Text == pendingMessage then
		setStatus("Ready", false)
	end

	isBusy = false
	setActionsEnabled(true)
	refreshUiState()
end

local function createActionButton(
	parent: Instance,
	title: string,
	detail: string,
	accentColor: Color3,
	onClick: () -> ()
)
	local button = createInstance("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = THEME.surfaceRaised,
		BorderSizePixel = 0,
		LayoutOrder = 10,
		Size = UDim2.new(1, 0, 0, 58),
		Text = "",
	}) :: TextButton
	button.Parent = parent
	addCorner(button, 6)

	local accent = createInstance("Frame", {
		BackgroundColor3 = accentColor,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(0, 4, 1, 0),
	})
	accent.Parent = button

	createText(button, {
		Font = Enum.Font.GothamSemibold,
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -44, 0, 20),
		Text = title,
		TextColor3 = THEME.text,
		TextSize = 13,
	})

	createText(button, {
		Position = UDim2.fromOffset(16, 30),
		Size = UDim2.new(1, -44, 0, 18),
		Text = detail,
		TextColor3 = THEME.muted,
		TextSize = 12,
	})

	createText(button, {
		Font = Enum.Font.GothamSemibold,
		Position = UDim2.new(1, -26, 0, 0),
		Size = UDim2.new(0, 18, 1, 0),
		Text = ">",
		TextColor3 = THEME.subtle,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	button.MouseEnter:Connect(function()
		if not isBusy then
			button.BackgroundColor3 = THEME.surfaceHover
		end
	end)
	button.MouseLeave:Connect(function()
		if not isBusy then
			button.BackgroundColor3 = THEME.surfaceRaised
		end
	end)
	button.MouseButton1Click:Connect(onClick)
	table.insert(actionButtons, button)
end

local function buildPluginGui()
	pluginWidget:ClearAllChildren()
	table.clear(actionButtons)

	local root = createInstance("Frame", {
		BackgroundColor3 = THEME.background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	})
	root.Parent = pluginWidget

	local header = createInstance("Frame", {
		BackgroundColor3 = THEME.header,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, 72),
	})
	header.Parent = root

	local headerPadding = createInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		PaddingTop = UDim.new(0, 11),
	})
	headerPadding.Parent = header

	createText(header, {
		Font = Enum.Font.GothamSemibold,
		Size = UDim2.new(1, 0, 0, 26),
		Text = "Effekseer for Roblox",
		TextColor3 = THEME.text,
		TextSize = 18,
	})

	createText(header, {
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 20),
		Text = "Studio Importer",
		TextColor3 = THEME.muted,
		TextSize = 12,
	})

	local scroller = createInstance("ScrollingFrame", {
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 72),
		ScrollBarImageColor3 = THEME.stroke,
		ScrollBarThickness = 6,
		Size = UDim2.new(1, 0, 1, -120),
	})
	scroller.Parent = root

	local content = createInstance("Frame", {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -26, 0, 0),
	})
	content.Parent = scroller

	local contentLayout = createInstance("UIListLayout", {
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	contentLayout.Parent = content

	local sessionSection = createSection(content, "Session")
	sessionSection.LayoutOrder = 1
	runtimeValueLabel = createStatRow(sessionSection, "Runtime")
	texturesValueLabel = createStatRow(sessionSection, "Textures")
	effectValueLabel = createStatRow(sessionSection, "Selected effect")
	previewValueLabel = createStatRow(sessionSection, "Preview")

	local setupSection = createSection(content, "Setup")
	setupSection.LayoutOrder = 2
	createActionButton(setupSection, "Install / Update Runtime", "ReplicatedStorage." .. RUNTIME_NAME, THEME.success, function()
		runPluginAction("Installing runtime", function()
			installRuntime(true)
			log("Runtime installed in ReplicatedStorage.")
		end)
	end)

	local importSection = createSection(content, "Import")
	importSection.LayoutOrder = 3
	createActionButton(importSection, "Import .efkproj / .efkefc", "Convert and add to " .. EFFECTS_NAME, THEME.accent, function()
		runPluginAction("Importing effect", importEfkproj)
	end)
	createActionButton(importSection, "Import Textures", "Load local images for this Studio session", THEME.warning, function()
		runPluginAction("Importing textures", importTextures)
	end)
	createActionButton(importSection, "Import .luau", "Add an already generated ModuleScript", THEME.accent, function()
		runPluginAction("Importing .luau", importGeneratedLuau)
	end)

	local previewSection = createSection(content, "Preview")
	previewSection.LayoutOrder = 4
	createActionButton(previewSection, "Preview Selection", "Loop the selected effect at the preview anchor", THEME.success, function()
		runPluginAction("Starting preview", previewSelected)
	end)
	createActionButton(previewSection, "Stop Preview", "Remove the active Studio preview objects", THEME.danger, function()
		runPluginAction("Stopping preview", function()
			destroyPreview()
			log("Preview stopped.")
		end)
	end)

	local footer = createInstance("Frame", {
		BackgroundColor3 = THEME.header,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -48),
		Size = UDim2.new(1, 0, 0, 48),
	})
	footer.Parent = root

	local footerPadding = createInstance("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	})
	footerPadding.Parent = footer

	statusLabel = createText(footer, {
		Size = UDim2.new(1, 0, 1, 0),
		Text = "Ready",
		TextColor3 = THEME.muted,
		TextSize = 12,
	})

	refreshUiState()
end

buildPluginGui()
openWindowButton:SetActive(pluginWidget.Enabled)

openWindowButton.Click:Connect(function()
	pluginWidget.Enabled = not pluginWidget.Enabled
end)

pluginWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	openWindowButton:SetActive(pluginWidget.Enabled)
end)

Selection.SelectionChanged:Connect(refreshUiState)
ReplicatedStorage.ChildAdded:Connect(refreshUiState)
ReplicatedStorage.ChildRemoved:Connect(refreshUiState)
plugin.Unloading:Connect(destroyPreview)
