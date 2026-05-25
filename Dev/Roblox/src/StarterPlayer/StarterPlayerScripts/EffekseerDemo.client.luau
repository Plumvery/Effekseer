local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Effekseer = require(ReplicatedStorage:WaitForChild("EffekseerRoblox"))
local effectsFolder = ReplicatedStorage:WaitForChild("EffekseerEffects")
local sampleModule = effectsFolder:FindFirstChild("SnowstormSample")

if not sampleModule then
	return
end

local effect = require(sampleModule)
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local rootPart = character:WaitForChild("HumanoidRootPart")

Effekseer.play(effect, rootPart, {
	loop = false,
	autoDestroy = true,
})
