--!nonstrict
-- The play handle returned to callers: stops emitters/beams/quads and destroys
-- every instance the effect created.

local Controller = {}
Controller.__index = Controller

function Controller.new()
	return setmetatable({
		_alive = true,
		_instances = {},
		_emitters = {},
		_beams = {},
		_parts = {},
	}, Controller)
end

function Controller:Stop()
	self._alive = false
	for _, emitter in self._emitters do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end
	for _, beam in self._beams do
		if beam.Parent then
			beam.Enabled = false
		end
	end
	for _, part in self._parts do
		if part.Parent then
			part.Transparency = 1
			for _, child in part:GetDescendants() do
				if child:IsA("Decal") then
					child.Transparency = 1
				elseif child:IsA("ImageLabel") then
					child.ImageTransparency = 1
				end
			end
		end
	end
end

function Controller:Destroy()
	self:Stop()
	for _, instance in self._instances do
		if instance.Parent then
			instance:Destroy()
		end
	end
	table.clear(self._instances)
	table.clear(self._emitters)
	table.clear(self._beams)
	table.clear(self._parts)
end

return Controller
