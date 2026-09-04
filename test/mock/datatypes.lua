-- Roblox datatypes and Enum, offline.
--
-- Only the surface the client actually touches is modelled, but what is modelled
-- behaves properly: Vector and UDim arithmetic, Color3 conversions, and an Enum
-- proxy that records every EnumItem the code asks for so a typo shows up as an
-- unknown enum in the harness report rather than as a silent nil.
local M = {}

local function class(name, fields)
	local proto = { __type = name }
	proto.__index = proto
	proto.__tostring = function(self)
		local parts = {}
		for _, key in ipairs(fields) do parts[#parts + 1] = tostring(self[key]) end
		return name .. "(" .. table.concat(parts, ", ") .. ")"
	end
	return proto
end

-- Vector2 -------------------------------------------------------------------
local Vector2 = class("Vector2", { "X", "Y" })
Vector2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
Vector2.__add = function(a, b) return M.Vector2.new(a.X + b.X, a.Y + b.Y) end
Vector2.__sub = function(a, b) return M.Vector2.new(a.X - b.X, a.Y - b.Y) end
Vector2.__unm = function(a) return M.Vector2.new(-a.X, -a.Y) end
Vector2.__mul = function(a, b)
	if type(b) == "number" then return M.Vector2.new(a.X * b, a.Y * b) end
	if type(a) == "number" then return M.Vector2.new(b.X * a, b.Y * a) end
	return M.Vector2.new(a.X * b.X, a.Y * b.Y)
end
Vector2.__div = function(a, b)
	if type(b) == "number" then return M.Vector2.new(a.X / b, a.Y / b) end
	return M.Vector2.new(a.X / b.X, a.Y / b.Y)
end
function Vector2:__len() return math.sqrt(self.X * self.X + self.Y * self.Y) end

M.Vector2 = {
	new = function(x, y)
		local self = setmetatable({ X = tonumber(x) or 0, Y = tonumber(y) or 0 }, Vector2)
		self.Magnitude = math.sqrt(self.X * self.X + self.Y * self.Y)
		return self
	end,
}
M.Vector2.zero = M.Vector2.new(0, 0)
M.Vector2.one = M.Vector2.new(1, 1)

-- Vector3 -------------------------------------------------------------------
local Vector3 = class("Vector3", { "X", "Y", "Z" })
Vector3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3.__add = function(a, b) return M.Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Vector3.__sub = function(a, b) return M.Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3.__unm = function(a) return M.Vector3.new(-a.X, -a.Y, -a.Z) end
Vector3.__mul = function(a, b)
	if type(b) == "number" then return M.Vector3.new(a.X * b, a.Y * b, a.Z * b) end
	if type(a) == "number" then return M.Vector3.new(b.X * a, b.Y * a, b.Z * a) end
	return M.Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then return M.Vector3.new(a.X / b, a.Y / b, a.Z / b) end
	return M.Vector3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
function Vector3:Dot(other) return self.X * other.X + self.Y * other.Y + self.Z * other.Z end
function Vector3:Cross(other)
	return M.Vector3.new(
		self.Y * other.Z - self.Z * other.Y,
		self.Z * other.X - self.X * other.Z,
		self.X * other.Y - self.Y * other.X
	)
end
function Vector3:Lerp(other, alpha)
	return M.Vector3.new(
		self.X + (other.X - self.X) * alpha,
		self.Y + (other.Y - self.Y) * alpha,
		self.Z + (other.Z - self.Z) * alpha
	)
end

-- Unit is built through `make` rather than `new`, because a recursive `new` would
-- compute the unit vector of the unit vector for ever.
local function makeVector3(x, y, z)
	local self = setmetatable({ X = x, Y = y, Z = z }, Vector3)
	self.Magnitude = math.sqrt(x * x + y * y + z * z)
	return self
end

M.Vector3 = {
	new = function(x, y, z)
		local vx, vy, vz = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
		local self = makeVector3(vx, vy, vz)
		local mag = self.Magnitude
		self.Unit = (mag > 0) and makeVector3(vx / mag, vy / mag, vz / mag) or self
		return self
	end,
}
M.Vector3.zero = M.Vector3.new(0, 0, 0)
M.Vector3.one = M.Vector3.new(1, 1, 1)
M.Vector3.yAxis = M.Vector3.new(0, 1, 0)

-- UDim / UDim2 --------------------------------------------------------------
local UDim = class("UDim", { "Scale", "Offset" })
UDim.__add = function(a, b) return M.UDim.new(a.Scale + b.Scale, a.Offset + b.Offset) end
UDim.__sub = function(a, b) return M.UDim.new(a.Scale - b.Scale, a.Offset - b.Offset) end
UDim.__eq = function(a, b) return a.Scale == b.Scale and a.Offset == b.Offset end
M.UDim = {
	new = function(scale, offset)
		return setmetatable({ Scale = tonumber(scale) or 0, Offset = tonumber(offset) or 0 }, UDim)
	end,
}

local UDim2 = class("UDim2", { "X", "Y" })
UDim2.__add = function(a, b) return M.UDim2.new(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset) end
UDim2.__sub = function(a, b) return M.UDim2.new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset) end
UDim2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
function UDim2:Lerp(other, alpha)
	return M.UDim2.new(
		self.X.Scale + (other.X.Scale - self.X.Scale) * alpha,
		self.X.Offset + (other.X.Offset - self.X.Offset) * alpha,
		self.Y.Scale + (other.Y.Scale - self.Y.Scale) * alpha,
		self.Y.Offset + (other.Y.Offset - self.Y.Offset) * alpha
	)
end
M.UDim2 = {
	new = function(sx, ox, sy, oy)
		return setmetatable({ X = M.UDim.new(sx, ox), Y = M.UDim.new(sy, oy) }, UDim2)
	end,
	fromScale = function(sx, sy) return M.UDim2.new(sx, 0, sy, 0) end,
	fromOffset = function(ox, oy) return M.UDim2.new(0, ox, 0, oy) end,
}

-- Color3 --------------------------------------------------------------------
local Color3 = class("Color3", { "R", "G", "B" })
Color3.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
function Color3:Lerp(other, alpha)
	return M.Color3.new(
		self.R + (other.R - self.R) * alpha,
		self.G + (other.G - self.G) * alpha,
		self.B + (other.B - self.B) * alpha
	)
end
function Color3:ToHex()
	return string.format("%02X%02X%02X",
		math.floor(self.R * 255 + 0.5), math.floor(self.G * 255 + 0.5), math.floor(self.B * 255 + 0.5))
end
M.Color3 = {
	new = function(r, g, b)
		return setmetatable({ R = tonumber(r) or 0, G = tonumber(g) or 0, B = tonumber(b) or 0 }, Color3)
	end,
	fromRGB = function(r, g, b)
		return M.Color3.new((tonumber(r) or 0) / 255, (tonumber(g) or 0) / 255, (tonumber(b) or 0) / 255)
	end,
	fromHex = function(hex)
		local clean = tostring(hex):gsub("#", "")
		return M.Color3.fromRGB(
			tonumber(clean:sub(1, 2), 16) or 0,
			tonumber(clean:sub(3, 4), 16) or 0,
			tonumber(clean:sub(5, 6), 16) or 0
		)
	end,
	fromHSV = function(h, s, v)
		local i = math.floor(h * 6)
		local f = h * 6 - i
		local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
		local mod = i % 6
		if mod == 0 then return M.Color3.new(v, t, p) end
		if mod == 1 then return M.Color3.new(q, v, p) end
		if mod == 2 then return M.Color3.new(p, v, t) end
		if mod == 3 then return M.Color3.new(p, q, v) end
		if mod == 4 then return M.Color3.new(t, p, v) end
		return M.Color3.new(v, p, q)
	end,
}

-- CFrame --------------------------------------------------------------------
-- Position-only. Rotation is not modelled: nothing in the client reads a basis
-- vector for anything but a raycast direction, and pretending otherwise would
-- invite tests that assert on made-up maths.
local CFrame = class("CFrame", { "Position" })
CFrame.__mul = function(a, b)
	if getmetatable(b) == getmetatable(M.Vector3.zero) then
		return a.Position + b
	end
	return M.CFrame.new(a.Position + b.Position)
end
CFrame.__add = function(a, b) return M.CFrame.new(a.Position + b) end
CFrame.__sub = function(a, b) return M.CFrame.new(a.Position - b) end
M.CFrame = {
	new = function(x, y, z)
		local position
		if type(x) == "table" and x.X then position = x else position = M.Vector3.new(x, y, z) end
		local self = setmetatable({ Position = position }, CFrame)
		self.p = position
		self.X, self.Y, self.Z = position.X, position.Y, position.Z
		self.LookVector = M.Vector3.new(0, 0, -1)
		self.RightVector = M.Vector3.new(1, 0, 0)
		self.UpVector = M.Vector3.new(0, 1, 0)
		return self
	end,
	lookAt = function(from, _to)
		return M.CFrame.new(from)
	end,
}
M.CFrame.identity = M.CFrame.new(0, 0, 0)

-- Misc value types ----------------------------------------------------------
local TweenInfo = class("TweenInfo", { "Time" })
M.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		return setmetatable({
			Time = tonumber(time) or 1,
			EasingStyle = style,
			EasingDirection = direction,
			RepeatCount = tonumber(repeatCount) or 0,
			Reverses = reverses and true or false,
			DelayTime = tonumber(delayTime) or 0,
		}, TweenInfo)
	end,
}

local Rect = class("Rect", { "Min", "Max" })
M.Rect = {
	new = function(minX, minY, maxX, maxY)
		if type(minX) == "table" then
			return setmetatable({ Min = minX, Max = minY }, Rect)
		end
		return setmetatable({ Min = M.Vector2.new(minX, minY), Max = M.Vector2.new(maxX, maxY) }, Rect)
	end,
}

local NumberRange = class("NumberRange", { "Min", "Max" })
M.NumberRange = {
	new = function(min, max)
		return setmetatable({ Min = min, Max = max or min }, NumberRange)
	end,
}

local Keypoint = class("NumberSequenceKeypoint", { "Time", "Value" })
M.NumberSequenceKeypoint = {
	new = function(time, value, envelope)
		return setmetatable({ Time = time, Value = value, Envelope = envelope or 0 }, Keypoint)
	end,
}
local NumberSequence = class("NumberSequence", { "Keypoints" })
M.NumberSequence = {
	new = function(a, b)
		local points = a
		if type(a) ~= "table" then
			points = {
				M.NumberSequenceKeypoint.new(0, a),
				M.NumberSequenceKeypoint.new(1, b or a),
			}
		end
		return setmetatable({ Keypoints = points }, NumberSequence)
	end,
}

local ColorKeypoint = class("ColorSequenceKeypoint", { "Time", "Value" })
M.ColorSequenceKeypoint = {
	new = function(time, value) return setmetatable({ Time = time, Value = value }, ColorKeypoint) end,
}
local ColorSequence = class("ColorSequence", { "Keypoints" })
M.ColorSequence = {
	new = function(a, b)
		local points = a
		if type(a) ~= "table" or a.R then
			points = {
				M.ColorSequenceKeypoint.new(0, a),
				M.ColorSequenceKeypoint.new(1, b or a),
			}
		end
		return setmetatable({ Keypoints = points }, ColorSequence)
	end,
}

local Font = class("Font", { "Family" })
M.Font = {
	new = function(family, weight, style)
		return setmetatable({ Family = family, Weight = weight, Style = style }, Font)
	end,
	fromEnum = function(item) return M.Font.new("rbxasset://fonts/" .. tostring(item and item.Name or "Gotham")) end,
	fromName = function(name, weight, style) return M.Font.new(name, weight, style) end,
	fromId = function(id, weight, style) return M.Font.new("rbxassetid://" .. tostring(id), weight, style) end,
}

-- Deterministic PRNG so a seeded run is reproducible.
local RandomProto = { __type = "Random" }
RandomProto.__index = RandomProto
function RandomProto:NextNumber(min, max)
	self.state = (1103515245 * self.state + 12345) % 2147483648
	local unit = self.state / 2147483648
	if min == nil then return unit end
	return min + unit * ((max or 1) - min)
end
function RandomProto:NextInteger(min, max)
	return math.floor(self:NextNumber(min, max + 1))
end
function RandomProto:Clone()
	return setmetatable({ state = self.state }, RandomProto)
end
M.Random = {
	new = function(seed) return setmetatable({ state = math.floor(tonumber(seed) or 1) % 2147483648 }, RandomProto) end,
}

-- Enum ----------------------------------------------------------------------
-- Known members are declared so a misspelling is visible; anything else still
-- resolves (the client may legitimately touch enums this harness has never heard
-- of) but is recorded in Enum.__unknown for the report.
local KNOWN = {
	Font = "Gotham GothamMedium GothamBold GothamSemibold GothamBlack Code RobotoMono SourceSans SourceSansBold SourceSansSemibold Arial ArialBold Legacy Nunito BuilderSans BuilderSansMedium BuilderSansBold BuilderSansExtraBold",
	EasingStyle = "Linear Sine Back Quad Quart Quint Exponential Circular Elastic Bounce Cubic",
	EasingDirection = "In Out InOut",
	TextXAlignment = "Left Center Right",
	TextYAlignment = "Top Center Bottom",
	TextTruncate = "None AtEnd SplitWord",
	AutomaticSize = "None X Y XY",
	FillDirection = "Horizontal Vertical",
	HorizontalAlignment = "Left Center Right",
	VerticalAlignment = "Top Center Bottom",
	SortOrder = "Name LayoutOrder Custom",
	UIFlexAlignment = "None Fill SpaceBetween SpaceAround SpaceEvenly",
	UIFlexMode = "None Grow Shrink Fill Custom",
	ItemLineAlignment = "Automatic Start Center End Stretch",
	ScrollingDirection = "X Y XY",
	ScrollBarInset = "None ScrollBar Always",
	ElasticBehavior = "WhenScrollable Always Never",
	ApplyStrokeMode = "Contextual Border",
	ZIndexBehavior = "Global Sibling",
	ScreenInsets = "None DeviceSafeInsets CoreUISafeInsets TopbarSafeInsets",
	SafeAreaCompatibility = "None FullscreenExtension",
	SelectionBehavior = "Escape Stop",
	UserInputType = "MouseButton1 MouseButton2 MouseButton3 MouseWheel MouseMovement Touch Keyboard Gamepad1 Gamepad2 Focus Accelerometer Gyro TextInput InputMethod None",
	UserInputState = "Begin Change End Cancel None",
	KeyCode = "Unknown Return Escape Backspace Tab Space Slash A B C D E F G H I J K L M N O P Q R S T U V W X Y Z Zero One Two Three Four Five Six Seven Eight Nine Up Down Left Right LeftShift RightShift LeftControl RightControl LeftAlt RightAlt Delete Home End PageUp PageDown F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 ButtonA ButtonB ButtonX ButtonY ButtonL1 ButtonR1 ButtonSelect ButtonStart DPadUp DPadDown DPadLeft DPadRight Thumbstick1 Thumbstick2",
	RaycastFilterType = "Include Exclude",
	Material = "Plastic SmoothPlastic Neon Glass ForceField Metal Wood Concrete Air Water",
	NormalId = "Top Bottom Left Right Front Back",
	HumanoidStateType = "Running Jumping Freefall Landed Seated Dead Climbing Swimming Physics GettingUp None",
	CoreGuiType = "PlayerList Health Backpack Chat EmotesMenu All",
	ThumbnailSize = "Size48x48 Size100x100 Size150x150 Size420x420",
	ThumbnailType = "HeadShot AvatarBust AvatarThumbnail",
	TeleportMethod = "TeleportToSpawnByName TeleportToPlaceInstance",
	DevTouchMovementMode = "UserChoice Thumbstick DPad Thumbpad",
	CameraType = "Custom Scriptable Follow Attach Fixed Track Watch",
	Platform = "Windows OSX IOS Android XBoxOne PS4 None",
	AspectType = "FitWithinMaxSize ScaleWithParentSize",
	DominantAxis = "Width Height",
	StudioStyleGuideColor = "MainBackground",
	FrameStyle = "Custom",
	BorderMode = "Outline Middle Inset",
	SizeConstraint = "RelativeXY RelativeXX RelativeYY",
	TextDirection = "Auto LeftToRight RightToLeft",
	LineJoinMode = "Round Bevel Miter",
	MouseBehavior = "Default LockCenter LockCurrentPosition",
	VirtualInputMode = "Recording Playing None",
	FontWeight = "Thin ExtraLight Light Regular Medium SemiBold Bold ExtraBold Heavy",
	FontStyle = "Normal Italic",
}

local function makeItem(enumName, itemName, value)
	return setmetatable({ Name = itemName, Value = value, EnumType = enumName }, {
		__type = "EnumItem",
		__tostring = function() return "Enum." .. enumName .. "." .. itemName end,
	})
end

function M.makeEnum()
	local unknown = {}
	local enums = {}
	local root = setmetatable({}, {
		__index = function(_, enumName)
			if enums[enumName] then return enums[enumName] end
			local declared = {}
			local index = 0
			for word in (KNOWN[enumName] or ""):gmatch("[%w_]+") do
				declared[word] = makeItem(enumName, word, index)
				index = index + 1
			end
			local counter = 900
			local proxy = setmetatable({}, {
				__index = function(_, itemName)
					if declared[itemName] then return declared[itemName] end
					if itemName == "GetEnumItems" then
						return function()
							local list = {}
							for _, item in pairs(declared) do list[#list + 1] = item end
							return list
						end
					end
					unknown[enumName .. "." .. itemName] = true
					counter = counter + 1
					declared[itemName] = makeItem(enumName, itemName, counter)
					return declared[itemName]
				end,
			})
			enums[enumName] = proxy
			return proxy
		end,
	})
	return root, unknown
end

function M.typeName(value)
	local meta = getmetatable(value)
	if type(meta) == "table" then
		if meta.__type then return meta.__type end
		if type(meta.__index) == "table" and meta.__index.__type then return meta.__index.__type end
	end
	return type(value)
end

return M
