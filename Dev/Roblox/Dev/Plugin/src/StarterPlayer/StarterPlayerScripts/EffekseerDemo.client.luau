local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Effekseer = require(ReplicatedStorage:WaitForChild("EffekseerRoblox"))
local effectsFolder = ReplicatedStorage:WaitForChild("EffekseerEffects")
local assetsFolder = ReplicatedStorage:FindFirstChild("EffekseerAssets")
local previewAssetMap = {}

if assetsFolder then
	local assetMapModule = assetsFolder:FindFirstChild("Effekseer01PreviewAssetMap")
	if assetMapModule then
		previewAssetMap = require(assetMapModule)
	end
end

local effects = {}
local packageFolder = effectsFolder:FindFirstChild("Effekseer01")
local manifestModule = effectsFolder:FindFirstChild("Effekseer01Manifest")

if packageFolder and manifestModule then
	local manifest = require(manifestModule)
	for _, entry in manifest.effects or {} do
		local module = packageFolder:FindFirstChild(entry.moduleName)
		if module then
			table.insert(effects, {
				name = entry.name,
				module = module,
			})
		end
	end
else
	local sampleModule = effectsFolder:FindFirstChild("SnowstormSample")
	if sampleModule then
		table.insert(effects, {
			name = "SnowstormSample",
			module = sampleModule,
		})
	end
end

if #effects == 0 then
	return
end

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local rootPart = character:WaitForChild("HumanoidRootPart")

local gui = Instance.new("ScreenGui")
gui.Name = "EffekseerPreviewGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.fromScale(0.5, 0.96)
panel.Size = UDim2.fromOffset(420, 58)
panel.BackgroundColor3 = Color3.fromRGB(20, 24, 31)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = gui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Position = UDim2.fromOffset(12, 8)
title.Size = UDim2.new(1, -144, 0, 18)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamMedium
title.TextColor3 = Color3.fromRGB(245, 247, 250)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextTruncate = Enum.TextTruncate.AtEnd
title.Parent = panel

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Position = UDim2.fromOffset(12, 30)
status.Size = UDim2.new(1, -24, 0, 16)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextColor3 = Color3.fromRGB(164, 174, 190)
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Parent = panel

local function button(name: string, text: string, x: number): TextButton
	local control = Instance.new("TextButton")
	control.Name = name
	control.Position = UDim2.new(1, x, 0, 10)
	control.Size = UDim2.fromOffset(36, 36)
	control.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
	control.BorderSizePixel = 0
	control.Font = Enum.Font.GothamMedium
	control.Text = text
	control.TextColor3 = Color3.fromRGB(255, 255, 255)
	control.TextSize = 16
	control.Parent = panel
	return control
end

local prevButton = button("Previous", "<", -128)
local replayButton = button("Replay", "R", -84)
local nextButton = button("Next", ">", -40)

local activeController = nil
local activeAnchor: BasePart? = nil
local currentIndex = 1

local function destroyActive()
	if activeController then
		activeController:Destroy()
		activeController = nil
	end
	if activeAnchor then
		activeAnchor:Destroy()
		activeAnchor = nil
	end
end

local function makeAnchor(): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "EffekseerPreviewAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = rootPart.CFrame * CFrame.new(0, 2, -8)
	anchor.Parent = workspace
	return anchor
end

local function play(index: number)
	currentIndex = ((index - 1) % #effects) + 1
	local entry = effects[currentIndex]
	destroyActive()

	title.Text = string.format("%02d/%02d  %s", currentIndex, #effects, entry.name)
	status.Text = "Loading"

	local ok, result = pcall(function()
		local effect = require(entry.module)
		activeAnchor = makeAnchor()
		activeController = Effekseer.play(effect, activeAnchor, {
			loop = true,
			autoDestroy = false,
			assetMap = previewAssetMap,
			particleSizeScale = 0.45,
			burstTaskLimit = 500,
			hideTarget = true,
		})
	end)

	if ok then
		status.Text = "Playing"
	else
		status.Text = tostring(result)
	end
end

prevButton.Activated:Connect(function()
	play(currentIndex - 1)
end)

replayButton.Activated:Connect(function()
	play(currentIndex)
end)

nextButton.Activated:Connect(function()
	play(currentIndex + 1)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Left then
		play(currentIndex - 1)
	elseif input.KeyCode == Enum.KeyCode.Right then
		play(currentIndex + 1)
	elseif input.KeyCode == Enum.KeyCode.R then
		play(currentIndex)
	end
end)

player.CharacterAdded:Connect(function(nextCharacter)
	character = nextCharacter
	rootPart = character:WaitForChild("HumanoidRootPart")
	play(currentIndex)
end)

play(currentIndex)
