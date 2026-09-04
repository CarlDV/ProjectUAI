-- Instance, signals and the class hierarchy, offline.
--
-- Property reads fall back to a per-class default table, so a Frame answers
-- Visible = true before anyone assigns it, exactly as the real thing does.
-- Reads of a name that is neither a known property nor a known event return nil
-- and are recorded, which is how a misspelled property gets caught here instead
-- of in a live game.
local M = {}

function M.newSignal(name)
	local handlers = {}
	local signal
	signal = {
		__type = "RBXScriptSignal",
		name = name,
		Connect = function(_, fn)
			local entry = { fn = fn, connected = true }
			handlers[#handlers + 1] = entry
			return {
				Connected = true,
				Disconnect = function(self)
					entry.connected = false
					if self then self.Connected = false end
				end,
				disconnect = function(self)
					entry.connected = false
					if self then self.Connected = false end
				end,
			}
		end,
		Once = function(self, fn)
			local conn
			conn = signal:Connect(function(...)
				conn:Disconnect()
				fn(...)
			end)
			return conn
		end,
		Wait = function() return nil end,
		Fire = function(_, ...)
			for _, entry in ipairs({ unpack(handlers) }) do
				if entry.connected then
					local ok, err = pcall(entry.fn, ...)
					if not ok and signal.onError then signal.onError(err) end
				end
			end
		end,
		Count = function()
			local n = 0
			for _, entry in ipairs(handlers) do
				if entry.connected then n = n + 1 end
			end
			return n
		end,
	}
	signal.connect = signal.Connect
	return signal
end

-- className -> immediate parent class. IsA walks this.
local PARENT = {
	GuiBase2d = "Instance", LayerCollector = "GuiBase2d", ScreenGui = "LayerCollector",
	BillboardGui = "LayerCollector", SurfaceGui = "LayerCollector",
	GuiObject = "GuiBase2d", Frame = "GuiObject", ScrollingFrame = "GuiObject",
	CanvasGroup = "GuiObject", VideoFrame = "GuiObject", ViewportFrame = "GuiObject",
	GuiLabel = "GuiObject", TextLabel = "GuiLabel", ImageLabel = "GuiLabel",
	GuiButton = "GuiObject", TextButton = "GuiButton", ImageButton = "GuiButton",
	TextBox = "GuiObject",
	UIComponent = "Instance", UILayout = "UIComponent", UIConstraint = "UIComponent",
	UIListLayout = "UILayout", UIGridLayout = "UILayout", UITableLayout = "UILayout",
	UIPageLayout = "UILayout", UIFlexItem = "UIComponent",
	UISizeConstraint = "UIConstraint", UIAspectRatioConstraint = "UIConstraint",
	UITextSizeConstraint = "UIConstraint",
	UICorner = "UIComponent", UIPadding = "UIComponent", UIStroke = "UIComponent",
	UIGradient = "UIComponent", UIScale = "UIComponent",
	PVInstance = "Instance", BasePart = "PVInstance", Part = "BasePart", MeshPart = "BasePart",
	WedgePart = "BasePart", TrussPart = "BasePart", SpawnLocation = "BasePart", Seat = "BasePart",
	Model = "PVInstance", Terrain = "BasePart", Attachment = "Instance",
	LuaSourceContainer = "Instance", BaseScript = "LuaSourceContainer", Script = "BaseScript",
	LocalScript = "Script", ModuleScript = "LuaSourceContainer",
	ValueBase = "Instance", StringValue = "ValueBase", IntValue = "ValueBase", NumberValue = "ValueBase",
	BoolValue = "ValueBase", ObjectValue = "ValueBase", Vector3Value = "ValueBase",
	CFrameValue = "ValueBase", Color3Value = "ValueBase", BrickColorValue = "ValueBase",
	RemoteEvent = "Instance", RemoteFunction = "Instance", UnreliableRemoteEvent = "Instance",
	BindableEvent = "Instance", BindableFunction = "Instance",
	Folder = "Instance", Configuration = "Instance", Humanoid = "Instance", Player = "Instance",
	Sound = "Instance", Highlight = "Instance", Beam = "Instance", Decal = "Instance",
	Texture = "Decal", Tool = "Model", Accessory = "Instance", Camera = "Instance",
	ClickDetector = "Instance", ProximityPrompt = "Instance", Team = "Instance",
	Animator = "Instance", Animation = "Instance", AnimationTrack = "Instance",
	BodyMover = "Instance", VectorForce = "Instance", LinearVelocity = "Instance",
	AlignPosition = "Instance", AlignOrientation = "Instance", BodyGyro = "Instance",
	DataModel = "Instance", Workspace = "Model", Players = "Instance", Lighting = "Instance",
	Atmosphere = "Instance", Sky = "Instance", BloomEffect = "Instance", BlurEffect = "Instance",
}

local GUI_OBJECT_DEFAULTS = {
	Visible = true, Active = false, Selectable = false, ClipsDescendants = false,
	BackgroundTransparency = 0, BorderSizePixel = 0, ZIndex = 1, LayoutOrder = 0,
	AutomaticSize = "None", Rotation = 0, Transparency = 0, Interactable = true,
	AnchorPoint = "Vector2.zero", Position = "UDim2.zero", Size = "UDim2.zero",
	BackgroundColor3 = "Color3.white", BorderColor3 = "Color3.black",
	AbsolutePosition = "Vector2.zero", AbsoluteSize = "Vector2.zero", AbsoluteRotation = 0,
	SelectionOrder = 0, NextSelectionUp = nil, SizeConstraint = "RelativeXY",
}

local TEXT_DEFAULTS = {
	Text = "", TextColor3 = "Color3.black", TextSize = 14, TextWrapped = false,
	TextScaled = false, TextTransparency = 0, RichText = false, LineHeight = 1,
	TextTruncate = "None", TextStrokeTransparency = 1, MaxVisibleGraphemes = -1,
	TextBounds = "Vector2.zero", TextFits = true, ContentText = "",
	TextXAlignment = "Center", TextYAlignment = "Center", Font = "SourceSans",
}

-- Names that resolve to a signal rather than a property. Reading one that is not
-- listed here returns nil, which surfaces as an "attempt to index a nil value"
-- at the :Connect call -- a loud failure, which is what we want.
local EVENTS = {}
for word in ([[
Changed ChildAdded ChildRemoved DescendantAdded DescendantRemoving AncestryChanged Destroying
MouseButton1Click MouseButton1Down MouseButton1Up MouseButton2Click MouseButton2Down MouseButton2Up
MouseEnter MouseLeave MouseMoved MouseWheelForward MouseWheelBackward Activated Deactivated
InputBegan InputChanged InputEnded TouchTap TouchPan TouchPinch TouchLongPress TouchSwipe
Focused FocusLost SelectionGained SelectionLost SelectionChanged
Completed Played Paused Stopped Ended DidLoop
Heartbeat RenderStepped Stepped PreRender PreSimulation PostSimulation PreAnimation
PlayerAdded PlayerRemoving CharacterAdded CharacterRemoving CharacterAppearanceLoaded Died
StateChanged Running Jumping Climbing Seated FreeFalling Touched TouchEnded
OnClientEvent OnServerEvent OnClientInvoke OnServerInvoke Event Fired Triggered
PromptButtonHoldBegan PromptTriggered MouseClick MouseHoverEnter MouseHoverLeave
WindowFocused WindowFocusReleased LastInputTypeChanged TextBoxFocused TextBoxFocusReleased
JumpRequest PointerAction ItemChanged PropertyChanged
GetPropertyChangedSignal
]]):gmatch("[%w_]+") do
	EVENTS[word] = true
end

-- Expected value type per property. Roblox rejects a wrong type outright, and a
-- property bag that accepts anything would hide exactly the bug that costs an hour
-- in a live game -- assigning a number to Size because a prop table overloaded the
-- name, for instance. Position and Size mean different types on a GUI object and on
-- a part, so those two are resolved by class.
local PROPERTY_TYPES = {
	AnchorPoint = "Vector2", AbsolutePosition = "Vector2", AbsoluteSize = "Vector2",
	CanvasPosition = "Vector2", AbsoluteCanvasSize = "Vector2", AbsoluteWindowSize = "Vector2",
	MinSize = "Vector2", MaxSize = "Vector2", OnScreenKeyboardSize = "Vector2",
	CanvasSize = "UDim2",
	CornerRadius = "UDim", PaddingTop = "UDim", PaddingBottom = "UDim",
	PaddingLeft = "UDim", PaddingRight = "UDim", Padding = "UDim",
	BackgroundColor3 = "Color3", TextColor3 = "Color3", BorderColor3 = "Color3",
	ImageColor3 = "Color3", PlaceholderColor3 = "Color3", ScrollBarImageColor3 = "Color3",
	GroupColor3 = "Color3", TextStrokeColor3 = "Color3", FillColor = "Color3",
	OutlineColor = "Color3", Ambient = "Color3", OutdoorAmbient = "Color3", FogColor = "Color3",
	TextSize = "number", ZIndex = "number", LayoutOrder = "number", Rotation = "number",
	Thickness = "number", Transparency = "number", BackgroundTransparency = "number",
	TextTransparency = "number", GroupTransparency = "number", LineHeight = "number",
	ScrollBarThickness = "number", Scale = "number", AspectRatio = "number",
	DisplayOrder = "number", MaxVisibleGraphemes = "number", SelectionOrder = "number",
	BorderSizePixel = "number", FieldOfView = "number", Brightness = "number",
	ClockTime = "number", Volume = "number", WalkSpeed = "number", JumpPower = "number",
	Health = "number", MaxHealth = "number", TextStrokeTransparency = "number",
	ImageTransparency = "number", GrowRatio = "number", HoldDuration = "number",
	Text = "string", PlaceholderText = "string", Name = "string", Image = "string",
	SoundId = "string", TimeOfDay = "string", ActionText = "string", ObjectText = "string",
	Visible = "boolean", Active = "boolean", Selectable = "boolean", ClipsDescendants = "boolean",
	TextWrapped = "boolean", RichText = "boolean", AutoButtonColor = "boolean",
	Enabled = "boolean", MultiLine = "boolean", ClearTextOnFocus = "boolean",
	TextEditable = "boolean", ScrollingEnabled = "boolean", ResetOnSpawn = "boolean",
	IgnoreGuiInset = "boolean", Anchored = "boolean", CanCollide = "boolean",
	Wraps = "boolean", Looped = "boolean", Playing = "boolean", Sit = "boolean",
	Font = "EnumItem", TextXAlignment = "EnumItem", TextYAlignment = "EnumItem",
	AutomaticSize = "EnumItem", FillDirection = "EnumItem", SortOrder = "EnumItem",
	HorizontalAlignment = "EnumItem", VerticalAlignment = "EnumItem",
	ApplyStrokeMode = "EnumItem", FlexMode = "EnumItem", ZIndexBehavior = "EnumItem",
	ScreenInsets = "EnumItem", SafeAreaCompatibility = "EnumItem",
	ScrollingDirection = "EnumItem", ElasticBehavior = "EnumItem",
	ItemLineAlignment = "EnumItem", TextTruncate = "EnumItem", CameraType = "EnumItem",
	DepthMode = "EnumItem", SizeConstraint = "EnumItem", ScaleType = "EnumItem",
	AutomaticCanvasSize = "EnumItem", FilterType = "EnumItem",
	CFrame = "CFrame", Velocity = "Vector3", AssemblyLinearVelocity = "Vector3",
	MoveDirection = "Vector3", WorldPosition = "Vector3", Orientation = "Vector3",
	Transparency_ = "number",
}

local GUI_GEOMETRY = { Position = "UDim2", Size = "UDim2" }
local WORLD_GEOMETRY = { Position = "Vector3", Size = "Vector3" }

function M.build(dt)
	local state = {
		created = {},
		unknownReads = {},
		typeErrors = {},
		count = 0,
	}

	local defaultsFor

	local function resolveDefault(spec)
		if spec == "Vector2.zero" then return dt.Vector2.new(0, 0) end
		if spec == "UDim2.zero" then return dt.UDim2.new(0, 0, 0, 0) end
		if spec == "Color3.white" then return dt.Color3.new(1, 1, 1) end
		if spec == "Color3.black" then return dt.Color3.new(0, 0, 0) end
		return spec
	end

	local Instance = {}

	local function isA(className, wanted)
		local current = className
		for _ = 1, 20 do
			if current == wanted then return true end
			current = PARENT[current]
			if not current then return false end
		end
		return false
	end

	local proto = {}

	function proto.GetChildren(self)
		local out = {}
		for i, child in ipairs(self.__children) do out[i] = child end
		return out
	end
	proto.GetChildren_ = proto.GetChildren

	function proto.GetDescendants(self)
		local out = {}
		local function walk(node)
			for _, child in ipairs(node.__children) do
				out[#out + 1] = child
				walk(child)
			end
		end
		walk(self)
		return out
	end

	function proto.FindFirstChild(self, name, recursive)
		for _, child in ipairs(self.__children) do
			if child.__props.Name == name then return child end
		end
		if recursive then
			for _, child in ipairs(self.__children) do
				local hit = proto.FindFirstChild(child, name, true)
				if hit then return hit end
			end
		end
		return nil
	end

	function proto.WaitForChild(self, name)
		return proto.FindFirstChild(self, name)
	end

	function proto.FindFirstChildOfClass(self, className)
		for _, child in ipairs(self.__children) do
			if child.__class == className then return child end
		end
		return nil
	end

	function proto.FindFirstChildWhichIsA(self, className, recursive)
		for _, child in ipairs(self.__children) do
			if isA(child.__class, className) then return child end
		end
		if recursive then
			for _, child in ipairs(self.__children) do
				local hit = proto.FindFirstChildWhichIsA(child, className, true)
				if hit then return hit end
			end
		end
		return nil
	end

	function proto.FindFirstAncestor(self, name)
		local node = self.__props.Parent
		while node do
			if node.__props.Name == name then return node end
			node = node.__props.Parent
		end
		return nil
	end

	function proto.FindFirstAncestorOfClass(self, className)
		local node = self.__props.Parent
		while node do
			if node.__class == className then return node end
			node = node.__props.Parent
		end
		return nil
	end

	function proto.IsA(self, className)
		return isA(self.__class, className)
	end

	function proto.IsDescendantOf(self, other)
		local node = self.__props.Parent
		while node do
			if node == other then return true end
			node = node.__props.Parent
		end
		return false
	end

	function proto.GetFullName(self)
		local parts = { self.__props.Name }
		local node = self.__props.Parent
		while node do
			table.insert(parts, 1, node.__props.Name)
			node = node.__props.Parent
		end
		return table.concat(parts, ".")
	end

	function proto.ClearAllChildren(self)
		for _, child in ipairs(proto.GetChildren(self)) do proto.Destroy(child) end
	end

	function proto.Destroy(self)
		self.__destroyed = true
		for _, child in ipairs(proto.GetChildren(self)) do proto.Destroy(child) end
		self.Parent = nil
		if self.__signals.Destroying then self.__signals.Destroying:Fire() end
	end
	proto.destroy = proto.Destroy

	function proto.Clone(self)
		local copy = Instance.new(self.__class)
		for key, value in pairs(self.__props) do
			if key ~= "Parent" then copy.__props[key] = value end
		end
		for _, child in ipairs(self.__children) do
			local childCopy = proto.Clone(child)
			childCopy.Parent = copy
		end
		return copy
	end

	function proto.GetAttribute(self, name) return self.__attributes[name] end
	function proto.SetAttribute(self, name, value) self.__attributes[name] = value end
	function proto.GetAttributes(self) return self.__attributes end
	function proto.AddTag(self, tag) self.__tags[tag] = true end
	function proto.RemoveTag(self, tag) self.__tags[tag] = nil end
	function proto.HasTag(self, tag) return self.__tags[tag] == true end
	function proto.GetTags(self)
		local out = {}
		for tag in pairs(self.__tags) do out[#out + 1] = tag end
		table.sort(out)
		return out
	end

	function proto.GetPropertyChangedSignal(self, name)
		local key = "__prop_" .. name
		if not self.__signals[key] then self.__signals[key] = M.newSignal(name) end
		return self.__signals[key]
	end

	function proto.SetSpecialProperty() end
	function proto.GetDebugId(self) return tostring(self.__id) end

	defaultsFor = function(className)
		local out = {}
		if isA(className, "GuiObject") then
			for key, value in pairs(GUI_OBJECT_DEFAULTS) do out[key] = value end
		end
		if isA(className, "TextLabel") or isA(className, "TextButton") or isA(className, "TextBox") then
			for key, value in pairs(TEXT_DEFAULTS) do out[key] = value end
		end
		if className == "TextBox" then
			out.ClearTextOnFocus = true
			out.MultiLine = false
			out.TextEditable = true
			out.PlaceholderText = ""
			out.CursorPosition = -1
		end
		if className == "ScrollingFrame" then
			out.CanvasPosition = "Vector2.zero"
			out.CanvasSize = "UDim2.zero"
			out.AbsoluteCanvasSize = "Vector2.zero"
			out.AbsoluteWindowSize = "Vector2.zero"
			out.ScrollBarThickness = 12
			out.AutomaticCanvasSize = "None"
			out.ScrollingEnabled = true
		end
		if className == "CanvasGroup" then out.GroupTransparency = 0 end
		if className == "UIStroke" then out.Thickness = 1 end
		if className == "UIScale" then out.Scale = 1 end
		if className == "ScreenGui" then
			out.Enabled = true
			out.DisplayOrder = 0
			out.IgnoreGuiInset = false
			out.ResetOnSpawn = true
		end
		return out
	end

	local meta = {}

	-- Absolute geometry, resolved on read.
	--
	-- Only scale-and-offset sizing is modelled: a UIListLayout or AutomaticSize
	-- reports the size the element was given rather than the size its contents
	-- would produce. That is enough for window and overlay geometry, which is what
	-- the scenarios assert on, and it is honest about what it does not know.
	local function viewport()
		return state.viewport or dt.Vector2.new(1280, 720)
	end

	local function isUDim2(value)
		return type(value) == "table" and type(value.X) == "table" and value.X.Scale ~= nil
	end

	local absoluteSize, absolutePosition

	function absoluteSize(node, depth)
		if not node or (depth or 0) > 24 then return viewport() end
		if node.__class == "ScreenGui" or node.__class == "Folder" then return viewport() end
		local size = node.__props.Size
		if not isUDim2(size) then return dt.Vector2.new(0, 0) end
		local parentSize = absoluteSize(node.__props.Parent, (depth or 0) + 1)
		return dt.Vector2.new(
			size.X.Scale * parentSize.X + size.X.Offset,
			size.Y.Scale * parentSize.Y + size.Y.Offset)
	end

	function absolutePosition(node, depth)
		if not node or (depth or 0) > 24 then return dt.Vector2.new(0, 0) end
		if node.__class == "ScreenGui" or node.__class == "Folder" then return dt.Vector2.new(0, 0) end
		local parent = node.__props.Parent
		local position = node.__props.Position
		local parentOrigin = absolutePosition(parent, (depth or 0) + 1)
		local parentSize = absoluteSize(parent, (depth or 0) + 1)
		local ownSize = absoluteSize(node, depth)
		local anchor = node.__props.AnchorPoint
		local anchorX = (type(anchor) == "table" and anchor.X) or 0
		local anchorY = (type(anchor) == "table" and anchor.Y) or 0
		if not isUDim2(position) then
			return dt.Vector2.new(parentOrigin.X - anchorX * ownSize.X, parentOrigin.Y - anchorY * ownSize.Y)
		end
		return dt.Vector2.new(
			parentOrigin.X + position.X.Scale * parentSize.X + position.X.Offset - anchorX * ownSize.X,
			parentOrigin.Y + position.Y.Scale * parentSize.Y + position.Y.Offset - anchorY * ownSize.Y)
	end

	meta.__index = function(self, key)
		local method = proto[key]
		if method then return method end
		local props = self.__props
		if props[key] ~= nil then return props[key] end
		if EVENTS[key] then
			if not self.__signals[key] then self.__signals[key] = M.newSignal(key) end
			return self.__signals[key]
		end
		if key == "AbsoluteSize" then return absoluteSize(self, 0) end
		if key == "AbsolutePosition" then return absolutePosition(self, 0) end
		local fallback = self.__defaults[key]
		if fallback ~= nil then return resolveDefault(fallback) end
		-- A child is reachable as a field, same as the real API.
		local child = proto.FindFirstChild(self, key)
		if child then return child end
		state.unknownReads[self.__class .. "." .. tostring(key)] =
			(state.unknownReads[self.__class .. "." .. tostring(key)] or 0) + 1
		return nil
	end

	local function valueType(value)
		local meta = getmetatable(value)
		if type(meta) == "table" then
			if meta.__type then return meta.__type end
			if type(meta.__index) == "table" and meta.__index.__type then return meta.__index.__type end
		end
		return type(value)
	end

	local function checkType(self, key, value)
		if value == nil then return end
		local expected = PROPERTY_TYPES[key]
		if not expected then
			local geometry = isA(self.__class, "GuiObject") and GUI_GEOMETRY
				or ((isA(self.__class, "BasePart") or isA(self.__class, "Attachment")) and WORLD_GEOMETRY)
			expected = geometry and geometry[key] or nil
		end
		if not expected then return end
		local actual = valueType(value)
		if actual == expected then return end
		-- An integer is acceptable wherever a number is, and a table standing in for
		-- a Roblox object the harness does not model is not worth failing over.
		if expected == "number" and actual == "number" then return end
		state.typeErrors[#state.typeErrors + 1] = string.format(
			"%s.%s expects %s, got %s (%s)",
			self.__class, tostring(key), expected, actual, tostring(value))
	end

	meta.__newindex = function(self, key, value)
		checkType(self, key, value)
		if key == "Parent" then
			local old = self.__props.Parent
			if old then
				for i, child in ipairs(old.__children) do
					if child == self then
						table.remove(old.__children, i)
						break
					end
				end
				if old.__signals.ChildRemoved then old.__signals.ChildRemoved:Fire(self) end
			end
			self.__props.Parent = value
			if value then
				value.__children[#value.__children + 1] = self
				if value.__signals.ChildAdded then value.__signals.ChildAdded:Fire(self) end
			end
		else
			self.__props[key] = value
		end
		local changed = self.__signals["__prop_" .. key]
		if changed then changed:Fire() end
		if self.__signals.Changed then self.__signals.Changed:Fire(key) end
	end

	meta.__tostring = function(self) return self.__props.Name end
	meta.__type = "Instance"

	function Instance.new(className, parent)
		state.count = state.count + 1
		local self = setmetatable({
			__class = className,
			__id = state.count,
			__children = {},
			__signals = {},
			__attributes = {},
			__tags = {},
			__defaults = defaultsFor(className),
			__props = { Name = className, ClassName = className, Parent = nil },
		}, meta)
		state.created[className] = (state.created[className] or 0) + 1
		if parent then self.Parent = parent end
		return self
	end

	-- Indented tree, for snapshot assertions on a built interface.
	function M.dump(root, opts)
		opts = opts or {}
		local lines = {}
		local function walk(node, depth)
			local props = {}
			for _, key in ipairs(opts.props or { "Text", "Visible" }) do
				local value = node.__props[key]
				if value ~= nil and value ~= "" then
					props[#props + 1] = key .. "=" .. tostring(value)
				end
			end
			lines[#lines + 1] = string.rep("  ", depth) .. node.__class ..
				(node.__props.Name ~= node.__class and (" '" .. tostring(node.__props.Name) .. "'") or "") ..
				(#props > 0 and ("  [" .. table.concat(props, " ") .. "]") or "")
			for _, child in ipairs(node.__children) do walk(child, depth + 1) end
		end
		walk(root, 0)
		return table.concat(lines, "\n")
	end

	return Instance, state, isA
end

return M
