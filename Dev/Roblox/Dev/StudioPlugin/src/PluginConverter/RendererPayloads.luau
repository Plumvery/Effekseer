--!nonstrict
-- Renderer-facing payloads: colors, blending, fades, UVs, and per-renderer
-- visual geometry (sprite quads, beams, rings, models).

local Xml = require(script.Parent:WaitForChild("Xml"))
local Easing = require(script.Parent:WaitForChild("Easing"))
local Diagnostics = require(script.Parent:WaitForChild("Diagnostics"))

local warning = Diagnostics.warning

local RendererPayloads = {}

function RendererPayloads.colorAt(node, candidates)
	for _, xmlPath in ipairs(candidates) do
		local base = Xml.find(node, xmlPath)
		if base then
			return {
				r = Xml.intAt(base, "R", 255),
				g = Xml.intAt(base, "G", 255),
				b = Xml.intAt(base, "B", 255),
				a = Xml.intAt(base, "A", 255),
			}
		end
	end
	return { r = 255, g = 255, b = 255, a = 255 }
end

local colorAt = RendererPayloads.colorAt

local function colorRangeAt(node, xmlPath: string, defaultColor)
	local base = Xml.find(node, xmlPath)
	if not base then
		return defaultColor
	end
	return {
		r = math.floor(Xml.randomNumberAt(base, "R", defaultColor.r).center + 0.5),
		g = math.floor(Xml.randomNumberAt(base, "G", defaultColor.g).center + 0.5),
		b = math.floor(Xml.randomNumberAt(base, "B", defaultColor.b).center + 0.5),
		a = math.floor(Xml.randomNumberAt(base, "A", defaultColor.a).center + 0.5),
	}
end

local function rendererValueAt(node, propertyName: string, defaultValue: number): number
	for _, rendererName in ipairs({ "Sprite", "Ribbon", "Ring", "Track", "Model" }) do
		local value = Xml.textAt(node, "DrawingValues/" .. rendererName .. "/" .. propertyName)
		if value ~= nil then
			return tonumber(value) or defaultValue
		end
	end
	return defaultValue
end

function RendererPayloads.alphaBlendAt(node): number
	local common = Xml.textAt(node, "RendererCommonValues/AlphaBlend")
	if common ~= nil then
		return math.floor((tonumber(common) or 1) + 0.5)
	end
	return math.floor(rendererValueAt(node, "AlphaBlend", 1) + 0.5)
end

function RendererPayloads.fadeFrameAt(node, name: string): number
	local typeValue = Xml.intAt(node, "RendererCommonValues/" .. name .. "Type", 1)
	if typeValue == 0 or Xml.find(node, "RendererCommonValues/" .. name .. "None") then
		return 0
	end
	return Xml.numberAt(node, "RendererCommonValues/" .. name .. "/Frame", 0)
end

function RendererPayloads.colorPayload(node, warnings, nodeName: string)
	-- Effekseer 1.5+ saves Sprite/Model colors as a StandardColor at DrawingValues/ColorAll.
	local standard = Xml.find(node, "DrawingValues/ColorAll")
	if standard and #standard.children > 0 then
		local mode = Xml.intAt(standard, "Type", 0)
		local fixed = colorAt(node, { "DrawingValues/ColorAll/Fixed" })
		if mode == 2 and Xml.find(standard, "Easing") then
			local start = colorRangeAt(standard, "Easing/Start", fixed)
			local finish = colorRangeAt(standard, "Easing/End", start)
			return {
				color = start,
				colorOverLife = {
					start = start,
					finish = finish,
					progress = Easing.easingProgressValues(Xml.find(standard, "Easing")),
				},
			}
		end
		if mode == 1 and Xml.find(standard, "Random") then
			return {
				color = colorRangeAt(standard, "Random", fixed),
				colorOverLife = nil,
			}
		end
		if mode == 3 or mode == 4 then
			table.insert(
				warnings,
				warning(
					"color_unsupported",
					"Color mode "
						.. (if mode == 3 then "FCurve" else "Gradient")
						.. " is approximated with a fixed color.",
					nodeName
				)
			)
		end
		return { color = fixed, colorOverLife = nil }
	end

	for _, rendererName in ipairs({ "Sprite", "Ribbon", "Ring", "Track", "Model" }) do
		local basePath = "DrawingValues/" .. rendererName
		if Xml.find(node, basePath) then
			local mode = Xml.intAt(node, basePath .. "/ColorAll", 0)
			local fixed = colorAt(node, { basePath .. "/ColorAll_Fixed" })
			if mode == 2 and Xml.find(node, basePath .. "/ColorAll_Easing") then
				local start = colorRangeAt(node, basePath .. "/ColorAll_Easing/Start", fixed)
				local finish = colorRangeAt(node, basePath .. "/ColorAll_Easing/End", start)
				return {
					color = start,
					colorOverLife = {
						start = start,
						finish = finish,
						progress = Easing.easingProgressValues(Xml.find(node, basePath .. "/ColorAll_Easing")),
					},
				}
			end
			if mode == 1 and Xml.find(node, basePath .. "/ColorAll_Random") then
				return {
					color = colorRangeAt(node, basePath .. "/ColorAll_Random", fixed),
					colorOverLife = nil,
				}
			end
			if Xml.find(node, basePath .. "/ColorAll_Fixed") then
				return {
					color = fixed,
					colorOverLife = nil,
				}
			end
		end
	end

	return {
		color = colorAt(node, {
			"DrawingValues/ColorAll/Fixed",
			"DrawingValues/Sprite/ColorAll_Fixed",
			"DrawingValues/Ribbon/ColorAll_Fixed",
			"DrawingValues/Ring/ColorAll_Fixed",
			"DrawingValues/Track/ColorCenterMiddle_Fixed",
			"DrawingValues/Model/Color_Fixed",
		}),
		colorOverLife = nil,
	}
end

function RendererPayloads.uvPayload(node, warnings, nodeName: string)
	local uvType = Xml.intAt(node, "RendererCommonValues/UV", 0)
	if uvType == 0 then
		return nil
	end
	local base = Xml.find(node, "RendererCommonValues")
	if not base then
		return nil
	end

	if uvType == 1 then
		return {
			type = 1,
			start = { x = Xml.numberAt(base, "UVFixed/Start/X", 0), y = Xml.numberAt(base, "UVFixed/Start/Y", 0) },
			size = { x = Xml.numberAt(base, "UVFixed/Size/X", 0), y = Xml.numberAt(base, "UVFixed/Size/Y", 0) },
		}
	end

	if uvType == 2 then
		local animation = Xml.find(base, "UVAnimation/AnimationParams") or Xml.find(base, "UVAnimation")
		if not animation then
			return nil
		end
		-- FrameLength is an IntWithInfinite in newer saves (nested Value element) and plain text in older ones.
		local directFrameLength = tonumber(Xml.textAt(animation, "FrameLength") or "")
		local frameLength = directFrameLength or Xml.numberAt(animation, "FrameLength/Value", 1)
		return {
			type = 2,
			start = { x = Xml.numberAt(animation, "Start/X", 0), y = Xml.numberAt(animation, "Start/Y", 0) },
			size = { x = Xml.numberAt(animation, "Size/X", 0), y = Xml.numberAt(animation, "Size/Y", 0) },
			animation = {
				frameLength = math.max(1, frameLength),
				countX = math.max(1, Xml.intAt(animation, "FrameCountX", 1)),
				countY = math.max(1, Xml.intAt(animation, "FrameCountY", 1)),
				loopType = Xml.intAt(animation, "LoopType", 0),
				startSheet = Xml.intAt(animation, "StartSheet", 0),
			},
		}
	end

	if uvType == 3 then
		return {
			type = 3,
			start = {
				x = Xml.randomNumberAt(base, "UVScroll/Start/X", 0).center,
				y = Xml.randomNumberAt(base, "UVScroll/Start/Y", 0).center,
			},
			size = {
				x = Xml.randomNumberAt(base, "UVScroll/Size/X", 0).center,
				y = Xml.randomNumberAt(base, "UVScroll/Size/Y", 0).center,
			},
			scroll = {
				speed = {
					x = Xml.randomNumberAt(base, "UVScroll/Speed/X", 0).center,
					y = Xml.randomNumberAt(base, "UVScroll/Speed/Y", 0).center,
				},
			},
		}
	end

	table.insert(
		warnings,
		warning(
			"uv_unsupported",
			"UV type " .. tostring(uvType) .. " (FCurve) is not supported; default UVs are used.",
			nodeName
		)
	)
	return nil
end

local function spritePositionPayload(node)
	if Xml.intAt(node, "DrawingValues/Sprite/Position", 0) ~= 1 then
		return nil
	end

	local points = {
		Xml.fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LL", { x = -0.5, y = -0.5, z = 0 }),
		Xml.fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LR", { x = 0.5, y = -0.5, z = 0 }),
		Xml.fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UL", { x = -0.5, y = 0.5, z = 0 }),
		Xml.fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UR", { x = 0.5, y = 0.5, z = 0 }),
	}
	local minX = math.huge
	local maxX = -math.huge
	local minY = math.huge
	local maxY = -math.huge

	for _, point in ipairs(points) do
		minX = math.min(minX, point.x or 0)
		maxX = math.max(maxX, point.x or 0)
		minY = math.min(minY, point.y or 0)
		maxY = math.max(maxY, point.y or 0)
	end

	return {
		center = {
			x = (minX + maxX) * 0.5,
			y = (minY + maxY) * 0.5,
		},
		size = {
			x = math.max(0.01, maxX - minX),
			y = math.max(0.01, maxY - minY),
		},
	}
end

local function ringRadiusPayload(ringNode, name: string, defaultValue: number, life)
	if not ringNode then
		return { start = defaultValue, finish = defaultValue }
	end
	local radiusType = Xml.intAt(ringNode, name, 0)
	if radiusType == 1 then
		local location = Xml.randomNumberAt(ringNode, name .. "_PVA/Location/X", defaultValue)
		local velocity = Xml.randomNumberAt(ringNode, name .. "_PVA/Velocity/X", 0)
		local acceleration = Xml.randomNumberAt(ringNode, name .. "_PVA/Acceleration/X", 0)
		local frames = math.max(1, life.center or 1)
		return {
			start = location.center,
			finish = location.center + velocity.center * frames + 0.5 * acceleration.center * frames * frames,
		}
	end
	if radiusType == 2 then
		local start = Xml.randomNumberAt(ringNode, name .. "_Easing/Start/X", defaultValue)
		local finish = Xml.randomNumberAt(ringNode, name .. "_Easing/End/X", start.center)
		return { start = start.center, finish = finish.center }
	end
	local fixed = Xml.numberAt(ringNode, name .. "_Fixed/Location/X", defaultValue)
	return { start = fixed, finish = fixed }
end

function RendererPayloads.visualPayload(node, rendererType: string, modelPath: string, modelAsset: string?, life)
	local size = {}

	if rendererType == "Sprite" then
		size.sprite = {
			billboard = Xml.intAt(node, "DrawingValues/Sprite/Billboard", 0),
			position = spritePositionPayload(node),
		}
	elseif rendererType == "Ribbon" then
		local left = Xml.numberAt(node, "DrawingValues/Ribbon/Position_Fixed_L", -0.5)
		local right = Xml.numberAt(node, "DrawingValues/Ribbon/Position_Fixed_R", 0.5)
		size.beam = {
			width = math.max(0.01, math.abs(right - left)),
			length = math.max(0.25, math.abs(right - left) * 6),
		}
	elseif rendererType == "Track" then
		local front = Xml.numberAt(node, "DrawingValues/Track/TrackSizeFor_Fixed", 0)
		local middle = Xml.numberAt(node, "DrawingValues/Track/TrackSizeMiddle_Fixed", 1)
		local back = Xml.numberAt(node, "DrawingValues/Track/TrackSizeBack_Fixed", front)
		local width = math.max(0.01, middle ~= 0 and middle or front ~= 0 and front or back ~= 0 and back or 1)
		size.beam = {
			width = width,
			length = math.max(0.25, math.abs(front - back) ~= 0 and math.abs(front - back) or width * 8),
		}
	elseif rendererType == "Ring" then
		local ring = Xml.find(node, "DrawingValues/Ring")
		local outer = ringRadiusPayload(ring, "Outer", 1, life)
		local inner = ringRadiusPayload(ring, "Inner", 0, life)
		size.ring = {
			vertexCount = Xml.intAt(node, "DrawingValues/Ring/VertexCount", 32),
			outerRadius = math.max(0.01, math.abs(if outer.start ~= 0 then outer.start else 1)),
			innerRadius = math.max(0, math.abs(inner.start)),
			outerRadiusFinish = math.max(
				0.01,
				math.abs(if outer.finish ~= 0 then outer.finish else outer.start ~= 0 and outer.start or 1)
			),
			innerRadiusFinish = math.max(0, math.abs(inner.finish)),
			billboard = Xml.intAt(node, "DrawingValues/Ring/Billboard", 0),
		}
	elseif rendererType == "Model" then
		size.model = {
			path = modelPath,
			asset = modelAsset,
		}
	end

	return size
end

return RendererPayloads
