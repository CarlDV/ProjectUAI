-- Layout and interaction primitives.
--
-- Everything visible is built from these, and they all take the same shape of
-- props table, so a panel reads as a description of what it is rather than a
-- hundred lines of instance plumbing. Three rules are enforced here rather than
-- left to each caller: nothing is positioned by hand-computed offsets, every
-- interactive element has a full state set, and every hit target respects the
-- platform minimum.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")

	local P = {}

	-- Shared helpers ---------------------------------------------------------

	function P.corner(instance, radius)
		local corner = Instance.new("UICorner", instance)
		corner.CornerRadius = UDim.new(0, radius == nil and theme.radius.md or radius)
		return corner
	end

	function P.stroke(instance, colour, thickness)
		local stroke = Instance.new("UIStroke", instance)
		stroke.Color = colour or theme.color.borderSubtle
		stroke.Thickness = thickness or theme.stroke.hair
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		return stroke
	end

	function P.pad(instance, spec)
		local padding = Instance.new("UIPadding", instance)
		if type(spec) == "number" then
			padding.PaddingTop = UDim.new(0, spec)
			padding.PaddingBottom = UDim.new(0, spec)
			padding.PaddingLeft = UDim.new(0, spec)
			padding.PaddingRight = UDim.new(0, spec)
		elseif type(spec) == "table" then
			local x = spec.x or spec.horizontal
			local y = spec.y or spec.vertical
			padding.PaddingTop = UDim.new(0, spec.top or y or 0)
			padding.PaddingBottom = UDim.new(0, spec.bottom or y or 0)
			padding.PaddingLeft = UDim.new(0, spec.left or x or 0)
			padding.PaddingRight = UDim.new(0, spec.right or x or 0)
		end
		return padding
	end

	local AUTO = {
		X = Enum.AutomaticSize.X,
		Y = Enum.AutomaticSize.Y,
		XY = Enum.AutomaticSize.XY,
	}

	-- Applies the props every visual element shares. Kept in one place so adding a
	-- shared concern (a token, an accessibility flag) is one edit.
	local function base(instance, props)
		props = props or {}
		if props.name then instance.Name = props.name end
		instance.BorderSizePixel = 0
		if props.size then instance.Size = props.size end
		if props.position then instance.Position = props.position end
		if props.anchor then instance.AnchorPoint = props.anchor end
		if props.auto then instance.AutomaticSize = AUTO[props.auto] or Enum.AutomaticSize.None end
		if props.zIndex then instance.ZIndex = props.zIndex end
		if props.layoutOrder then instance.LayoutOrder = props.layoutOrder end
		if props.clip ~= nil then instance.ClipsDescendants = props.clip == true end
		if props.visible ~= nil then instance.Visible = props.visible == true end
		if props.rotation then instance.Rotation = props.rotation end

		if props.bg then
			instance.BackgroundColor3 = props.bg
			instance.BackgroundTransparency = props.bgTransparency or 0
		else
			instance.BackgroundTransparency = 1
		end
		if props.radius ~= nil then P.corner(instance, props.radius) end
		if props.stroke then P.stroke(instance, props.strokeColor, props.strokeWidth) end
		if props.padding then P.pad(instance, props.padding) end
		if props.minSize or props.maxSize then
			local constraint = Instance.new("UISizeConstraint", instance)
			if props.minSize then constraint.MinSize = props.minSize end
			if props.maxSize then constraint.MaxSize = props.maxSize end
		end
		if props.aspect then
			Instance.new("UIAspectRatioConstraint", instance).AspectRatio = props.aspect
		end
		if props.flex then
			local item = Instance.new("UIFlexItem", instance)
			item.FlexMode = Enum.UIFlexMode[props.flex] or Enum.UIFlexMode.Fill
		end
		return instance
	end

	function P.frame(parent, props)
		local frame = Instance.new("Frame", parent)
		return base(frame, props)
	end

	local function stack(parent, props, direction)
		props = props or {}
		local frame = P.frame(parent, props)
		local layout = Instance.new("UIListLayout", frame)
		layout.FillDirection = direction
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, props.gap or theme.space.sm)
		layout.HorizontalAlignment = Enum.HorizontalAlignment[props.alignX or "Left"]
		layout.VerticalAlignment = Enum.VerticalAlignment[props.alignY or "Top"]
		if props.wrap then layout.Wraps = true end
		if props.stretch then layout.ItemLineAlignment = Enum.ItemLineAlignment.Stretch end
		return frame, layout
	end

	function P.column(parent, props)
		return stack(parent, props, Enum.FillDirection.Vertical)
	end

	function P.row(parent, props)
		props = props or {}
		props.alignY = props.alignY or "Center"
		return stack(parent, props, Enum.FillDirection.Horizontal)
	end

	-- A gap, or -- with `grow` -- whatever is left over on the line.
	--
	-- A growing spacer starts at nothing. UIFlexItem.Grow only ever hands out the
	-- space a line has left, and it never shrinks a child below its own size, so a
	-- spacer that began at full width left nothing over and pushed every sibling
	-- after it past the parent's edge. That is how a profile row loses its chevron
	-- and a card header loses its right-hand pills.
	function P.spacer(parent, props)
		props = props or {}
		local size = props.size
		if not size then
			if props.grow then
				size = UDim2.fromOffset(0, 0)
			else
				size = UDim2.new(1, 0, 0, props.height or theme.space.sm)
			end
		end
		local frame = P.frame(parent, {
			name = "Spacer",
			size = size,
			layoutOrder = props.layoutOrder,
		})
		if props.grow then
			local item = Instance.new("UIFlexItem", frame)
			item.FlexMode = Enum.UIFlexMode.Grow
		end
		return frame
	end

	function P.divider(parent, props)
		props = props or {}
		return P.frame(parent, {
			name = "Divider",
			size = props.vertical and UDim2.new(0, 1, 1, 0) or UDim2.new(1, 0, 0, 1),
			bg = props.color or theme.color.borderSubtle,
			layoutOrder = props.layoutOrder,
		})
	end

	-- Text -------------------------------------------------------------------

	-- `size` is the UDim2 every element shares; the font size comes from the role,
	-- or from `textSize` when one label genuinely has to differ. Overloading `size`
	-- for both would assign a number to Size, which Roblox rejects outright.
	--
	-- Two font properties, applied in order. `Font` is the legacy enum and always
	-- takes; `FontFace` is the modern family-plus-weight pair and is layered over it
	-- only when the theme resolved one, so a client without the newer type stack keeps
	-- rendering rather than being assigned nil. Assigning Font *after* FontFace would
	-- undo it -- the two are the same underlying property with different resolutions --
	-- which is why the order here is not arbitrary.
	local function applyFont(label, role, props)
		label.Font = props.font or role.font
		if props.font then return end
		local face = props.face or role.face
		if face then pcall(function() label.FontFace = face end) end
	end

	function P.text(parent, props)
		props = props or {}
		local role = theme.textRole(props.role or "body")
		local label = Instance.new("TextLabel", parent)
		base(label, props)
		label.Text = tostring(props.text or "")
		label.TextColor3 = props.color or theme.color.text
		applyFont(label, role, props)
		label.TextSize = props.textSize or role.size
		label.LineHeight = props.line or role.line
		label.TextXAlignment = Enum.TextXAlignment[props.align or "Left"]
		label.TextYAlignment = Enum.TextYAlignment[props.alignY or "Center"]
		label.TextWrapped = props.wrap == true
		label.RichText = props.rich == true
		if props.transparency then label.TextTransparency = props.transparency end
		if props.truncate then label.TextTruncate = Enum.TextTruncate.AtEnd end
		-- A label with no explicit size collapses to nothing inside a list layout,
		-- which is the single most common way an interface silently loses text.
		-- `auto` only covers the axes it names, so it does not save us here: with
		-- `auto = "Y"` the width is still ours to set, and a zero-width label does
		-- not vanish so much as wrap to one character per line -- the same bug
		-- wearing a costume that reads as a rendering glitch instead of a layout one.
		-- The caller owns the width only when `auto` includes X.
		if not props.size then
			if props.auto == "XY" then
				label.Size = UDim2.fromOffset(0, 0)
			elseif props.auto == "X" then
				-- Width from the text, height from the role. A zero on both axes is what
				-- `auto = "X"` used to produce, and AutomaticSize.X grows the width only --
				-- so the label came out one rendered line wide and no pixels tall, which
				-- is a label that is not there at all. Twenty-odd call sites papered over
				-- it by assigning Size on the next line; the ones that forgot simply
				-- vanished.
				label.Size = UDim2.fromOffset(0, role.height or (role.size + 4))
			elseif props.auto == "Y" then
				label.Size = UDim2.new(1, 0, 0, 0)
			else
				-- One rendered line plus a little slack. Sized from the role's line
				-- height, not its font size: at a 1.5 line height the two differ by
				-- seven pixels and the descenders go missing.
				local single = props.textSize and math.ceil(props.textSize * (props.line or role.line))
					or role.height or (role.size + 4)
				label.Size = UDim2.new(1, 0, 0, single + 4)
			end
		end
		return label
	end

	-- A heading with an optional trailing description, which is the pattern every
	-- settings group uses.
	--
	-- Sentence case, not upper. Small-caps headings were doing the work of separating
	-- groups, and spacing does that better: SHOUTED LABELS every hundred pixels are
	-- what makes an interface read as a control panel rather than as a page.
	function P.sectionHeader(parent, props)
		local holder = P.column(parent, {
			name = "Section",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			layoutOrder = props.layoutOrder,
		})
		P.text(holder, {
			text = tostring(props.title or ""),
			role = "label",
			color = theme.color.text,
			auto = "Y",
			wrap = true,
		})
		if props.description then
			P.text(holder, {
				text = props.description,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
		end
		return holder
	end

	-- Interaction ------------------------------------------------------------

	-- Button variants.
	--
	-- `primary` is a cream fill with dark text rather than an accent fill. There is
	-- normally one of them per view -- send, save, confirm -- and making it the
	-- brightest thing on the page rather than the most colourful is what leaves the
	-- accent free to mean something: inline code, a running turn, a risk level. Use
	-- `accent` when the colour itself is the message.
	local VARIANTS = {
		primary = function()
			return {
				bg = theme.color.solid, bgHover = theme.color.solidHover, bgPress = theme.color.solidPress,
				text = theme.color.onSolid, stroke = nil, font = "bodyStrong",
			}
		end,
		accent = function()
			return {
				bg = theme.color.accent, bgHover = theme.color.accentHot, bgPress = theme.color.accentMuted,
				text = theme.color.textOnAccent, stroke = nil, font = "bodyStrong",
			}
		end,
		-- No fill at rest, only a hairline. A dark-grey fill on a dark-grey panel adds
		-- a rectangle without adding contrast; the outline is what says "control".
		secondary = function()
			return {
				bg = nil, bgHover = theme.color.surfaceHover, bgPress = theme.color.surfaceActive,
				text = theme.color.text, stroke = theme.color.border, font = "bodyStrong",
			}
		end,
		ghost = function()
			return {
				bg = nil, bgHover = theme.color.surfaceHover, bgPress = theme.color.surfaceActive,
				text = theme.color.textSecondary, stroke = nil, font = "body",
			}
		end,
		-- Text and outline only until it is pressed. A pre-filled danger button reads
		-- as already-dangerous and gets clicked past; the fill arriving on hover is the
		-- moment it is worth noticing.
		danger = function()
			return {
				bg = nil, bgHover = theme.color.dangerSurface, bgPress = theme.color.danger,
				text = theme.color.danger, textHover = theme.color.danger,
				stroke = theme.color.dangerBorder, font = "bodyStrong",
			}
		end,
	}

	local HEIGHTS = { sm = "controlSmall", md = "control", lg = "controlLarge" }

	-- One button implementation with a full state set: rest, hover, press, focus,
	-- disabled and loading. Roblox gives none of that, and a project that hand-rolls
	-- it per call site ends up with buttons that behave differently from each other.
	function P.button(parent, props)
		props = props or {}
		local variant = (VARIANTS[props.variant or "secondary"])()
		local height = math.max(theme.size[HEIGHTS[props.size or "md"]], responsive.minTarget())
		-- A button with neither a fixed width nor fill sizes to its label. That means
		-- the content row has to size to its own children too: AutomaticSize ignores
		-- a child whose width is a scale, so a (1, 0) row inside an auto-width button
		-- collapses the button to nothing.
		local autoWidth = not props.width and not props.fill

		local button = Instance.new("TextButton", parent)
		button.Text = ""
		button.AutoButtonColor = false
		button.Active = true
		button.Selectable = true
		base(button, {
			name = props.name or "Button",
			size = props.width and UDim2.new(0, props.width, 0, height)
				or (props.fill and UDim2.new(1, 0, 0, height) or UDim2.new(0, 0, 0, height)),
			auto = autoWidth and "X" or nil,
			position = props.position,
			anchor = props.anchor,
			layoutOrder = props.layoutOrder,
			bg = variant.bg,
			radius = props.radius or theme.radius.md,
			zIndex = props.zIndex,
		})
		if variant.stroke then P.stroke(button, variant.stroke) end
		if not variant.bg then button.BackgroundTransparency = 1 end

		local content, layout = P.row(button, {
			name = "Content",
			size = autoWidth and UDim2.new(0, 0, 1, 0) or UDim2.new(1, 0, 1, 0),
			auto = autoWidth and "X" or nil,
			gap = theme.space.xs,
			alignX = props.align or "Center",
			alignY = "Center",
			padding = { x = props.tight and theme.space.xs or theme.space.md },
		})
		layout.SortOrder = Enum.SortOrder.LayoutOrder

		local icons = env.require("ui/icons")
		local iconHolder
		if props.icon then
			iconHolder = P.frame(content, {
				name = "IconSlot",
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
				layoutOrder = 1,
			})
			icons.draw(props.icon, iconHolder, theme.size.icon, props.iconColor or variant.text, props.iconDirection)
		end

		local label
		if props.text and props.text ~= "" then
			label = P.text(content, {
				text = props.text,
				role = variant.font,
				color = variant.text,
				align = "Center",
				auto = "XY",
				layoutOrder = 2,
			})
			label.Size = UDim2.fromOffset(0, 0)
		end

		local handle = { instance = button, label = label, enabled = true, busy = false }

		local function paint(state)
			local target = variant.bg
			local textColour = variant.text
			if not handle.enabled then
				target = theme.color.surfaceRaised
				textColour = theme.color.textDisabled
			elseif state == "hover" then
				target = variant.bgHover or variant.bg
				textColour = variant.textHover or variant.text
			elseif state == "press" then
				target = variant.bgPress or variant.bgHover or variant.bg
				textColour = variant.textHover or variant.text
			end
			if target then
				button.BackgroundTransparency = 0
				env.tween:Create(button, theme.tween("hover"), { BackgroundColor3 = target }):Play()
			else
				env.tween:Create(button, theme.tween("hover"), { BackgroundTransparency = 1 }):Play()
			end
			if label then
				env.tween:Create(label, theme.tween("hover"), { TextColor3 = textColour }):Play()
			end
		end

		button.MouseEnter:Connect(function() if handle.enabled then paint("hover") end end)
		button.MouseLeave:Connect(function() paint("rest") end)
		button.MouseButton1Down:Connect(function() if handle.enabled then paint("press") end end)
		button.MouseButton1Up:Connect(function() if handle.enabled then paint("hover") end end)
		-- Gamepad focus has to look like hover or a console user cannot see where
		-- they are.
		button.SelectionGained:Connect(function() if handle.enabled then paint("hover") end end)
		button.SelectionLost:Connect(function() paint("rest") end)

		button.Activated:Connect(function()
			if not handle.enabled or handle.busy then return end
			if props.onClick then
				local ok, err = pcall(props.onClick, handle)
				if not ok then
					env.require("runtime/log").warn("ui", "button handler failed", err)
				end
			end
		end)

		function handle.setEnabled(value)
			handle.enabled = value ~= false
			button.Active = handle.enabled
			button.Selectable = handle.enabled
			paint("rest")
		end

		function handle.setText(text)
			if label then label.Text = tostring(text) end
		end

		function handle.setVariant(name)
			variant = (VARIANTS[name] or VARIANTS.secondary)()
			paint("rest")
		end

		paint("rest")
		return handle
	end

	function P.iconButton(parent, props)
		props = props or {}
		local size = math.max(props.diameter or theme.size.control, responsive.minTarget())
		-- Shallow, deliberately. `util.merge` deep-copies, and a deep copy of a UDim2 or
		-- a Vector2 is a plain table with the same fields and none of the type -- so an
		-- icon button given a position lost it, silently, on the way through.
		local merged = util.copy(props)
		merged.variant = props.variant or "ghost"
		merged.text = nil
		merged.width = size
		merged.tight = true
		merged.radius = props.radius or theme.radius.md
		local handle = P.button(parent, merged)
		handle.instance.Size = UDim2.fromOffset(size, size)
		handle.instance.AutomaticSize = Enum.AutomaticSize.None
		return handle
	end

	-- A whole row that is one hit target, with the row's own layout inside it.
	--
	-- The wrong way to make a row clickable -- and the way most of the rows in the
	-- sidebar, the composer and the settings dialog were built -- is to drop a
	-- transparent full-size TextButton into the row alongside its contents. A
	-- UIListLayout does not layer its children, it lays them out: the button takes a
	-- full-width slot of its own and pushes the icon and the label it was meant to
	-- cover out past the row's right edge, where they are still drawn because nothing
	-- clips them. What that renders as is an empty pill with its contents floating
	-- beside it, and the only part that answers a click is the empty part.
	--
	-- So the button *is* the row: the layout goes inside it. Which is what P.button
	-- has always done, and what the transcript's own rows already did correctly.
	function P.rowButton(parent, props)
		props = props or {}
		local height = math.max(props.height or theme.size.rowSmall, responsive.minTarget())
		-- The content row is as tall as the button actually is, not as tall as the
		-- floored minimum.
		--
		-- A caller that states its own `size` -- every chip in the composer, every pill on
		-- the home card, both segments of the sidebar's mode switch -- takes that size for
		-- the button while the row inside it kept the floored one. A 22px chip therefore
		-- held a 28px content row, 44 on a touch device, top-anchored: the icon and label
		-- centred three pixels below the chip's own centre line and drew through its
		-- bottom border. The hit-target floor still applies to any button that did not
		-- state a size, which is the case it exists for.
		local stated = props.size and props.size.Y.Scale == 0 and props.size.Y.Offset > 0
		local contentHeight = stated and props.size.Y.Offset or height
		local button = Instance.new("TextButton", parent)
		button.Text = ""
		button.AutoButtonColor = false
		button.Active = true
		button.Selectable = true
		base(button, {
			name = props.name or "Row",
			size = props.size or UDim2.new(1, 0, 0, height),
			auto = props.auto,
			position = props.position,
			anchor = props.anchor,
			layoutOrder = props.layoutOrder,
			zIndex = props.zIndex,
			bg = props.bg,
			radius = props.radius == nil and theme.radius.sm or props.radius,
			clip = props.clip,
			flex = props.flex,
		})
		if props.stroke then P.stroke(button, props.strokeColor) end

		local inner = P.row
		if props.vertical then inner = P.column end
		local row = inner(button, {
			name = "Content",
			size = props.auto and UDim2.new(0, 0, 0, contentHeight) or UDim2.fromScale(1, 1),
			auto = props.auto,
			gap = props.gap or theme.space.xs,
			padding = props.padding or { x = theme.space.xs },
			alignX = props.alignX,
			alignY = props.alignY or "Center",
		})

		local handle = { instance = button, row = row, selected = props.selected == true }

		local function paint(state)
			local target = props.bg
			if handle.selected then target = props.bgSelected or theme.color.surfaceActive end
			if state == "hover" and not handle.selected then target = props.bgHover or theme.color.surfaceHover end
			if state == "press" then target = props.bgPress or theme.color.surfaceActive end
			if target then
				button.BackgroundColor3 = target
				button.BackgroundTransparency = 0
			else
				button.BackgroundTransparency = 1
			end
		end

		button.MouseEnter:Connect(function() paint("hover") end)
		button.MouseLeave:Connect(function() paint("rest") end)
		button.MouseButton1Down:Connect(function() paint("press") end)
		button.MouseButton1Up:Connect(function() paint("hover") end)
		button.SelectionGained:Connect(function() paint("hover") end)
		button.SelectionLost:Connect(function() paint("rest") end)
		button.Activated:Connect(function()
			if props.onClick then
				local ok, err = pcall(props.onClick, handle)
				if not ok then env.require("runtime/log").warn("ui", "row handler failed", err) end
			end
		end)

		function handle.setSelected(value)
			handle.selected = value == true
			paint("rest")
		end

		-- The two things every one of these rows puts in itself, so a caller does not
		-- have to remember that an auto-width label needs a height and that an icon
		-- needs a square to be drawn into.
		function handle.icon(name, order, colour, size)
			local diameter = size or theme.size.icon
			local slot = P.frame(row, {
				name = "IconSlot",
				size = UDim2.fromOffset(diameter, diameter),
				layoutOrder = order or 1,
			})
			local icons = env.require("ui/icons")
			icons.draw(name, slot, diameter, colour or theme.color.textSecondary)
			return slot
		end

		function handle.label(text, order, colour, role)
			return P.text(row, {
				name = "Label",
				text = text,
				role = role or "caption",
				color = colour or theme.color.textSecondary,
				size = UDim2.new(0, 0, 0, theme.textRole(role or "caption").height),
				flex = "Fill",
				truncate = true,
				layoutOrder = order or 2,
			})
		end

		paint("rest")
		return handle
	end

	-- Input -----------------------------------------------------------------

	-- A text field with a real focus state. The reference client's prompt box gave
	-- no sign it had focus at all, which on a dark panel means typing into nothing;
	-- the border picking up the accent is the whole fix.
	--
	-- `bare` drops the field's own background, outline and corner so it can sit
	-- inside a container that owns them -- the composer puts the field and the send
	-- button in one bordered box, which is one control to look at rather than two.
	-- In that mode the caller paints focus itself, from onFocus and onBlur.
	function P.field(parent, props)
		props = props or {}
		local role = theme.textRole(props.role or "body")
		local multiline = props.multiline == true
		local bare = props.bare == true
		local height = multiline
			and (props.height or theme.size.control * 2)
			or math.max(theme.size.control, responsive.minTarget())

		local shell = P.frame(parent, {
			name = props.name or "Field",
			size = props.size or UDim2.new(1, 0, 0, height),
			auto = props.auto,
			layoutOrder = props.layoutOrder,
			bg = (not bare) and (props.bg or theme.color.surfaceRaised) or nil,
			radius = (not bare) and (props.radius or theme.radius.md) or nil,
			clip = true,
			flex = props.flex,
		})
		local stroke = (not bare) and P.stroke(shell, theme.color.border) or nil

		local box = Instance.new("TextBox", shell)
		box.BackgroundTransparency = 1
		box.Size = UDim2.new(1, 0, 1, 0)
		box.Text = tostring(props.text or "")
		box.PlaceholderText = tostring(props.placeholder or "")
		box.PlaceholderColor3 = theme.color.textTertiary
		box.TextColor3 = theme.color.text
		box.Font = role.font
		if role.face then pcall(function() box.FontFace = role.face end) end
		box.TextSize = role.size
		box.LineHeight = role.line
		box.ClearTextOnFocus = false
		box.TextXAlignment = Enum.TextXAlignment[props.align or "Left"]
		box.TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
		box.MultiLine = multiline
		box.TextWrapped = multiline
		box.ClipsDescendants = true
		box.Selectable = true
		P.pad(box, {
			x = props.padX or (bare and theme.space.none or theme.space.md),
			y = multiline and theme.space.sm or 0,
		})

		local handle = { instance = box, shell = shell, stroke = stroke }

		box.Focused:Connect(function()
			if stroke then
				env.tween:Create(stroke, theme.tween("hover"), { Color = theme.color.accentBorder }):Play()
				env.tween:Create(shell, theme.tween("hover"), { BackgroundColor3 = theme.color.surfaceOverlay }):Play()
			end
			if props.onFocus then pcall(props.onFocus, handle) end
		end)

		box.FocusLost:Connect(function(enterPressed)
			if stroke then
				env.tween:Create(stroke, theme.tween("hover"), { Color = theme.color.border }):Play()
				env.tween:Create(shell, theme.tween("hover"), {
					BackgroundColor3 = props.bg or theme.color.surfaceRaised,
				}):Play()
			end
			-- On a multiline box Enter inserts a newline, so submit is the caller's
			-- job there; on a single line it means "go".
			if enterPressed and not multiline and props.onSubmit then
				pcall(props.onSubmit, box.Text, handle)
			end
			if props.onBlur then pcall(props.onBlur, box.Text, handle) end
		end)

		if props.onChange then
			box:GetPropertyChangedSignal("Text"):Connect(function()
				pcall(props.onChange, box.Text, handle)
			end)
		end

		function handle.get() return box.Text end
		function handle.set(value) box.Text = tostring(value or "") end
		function handle.focus() pcall(function() box:CaptureFocus() end) end
		function handle.clear() box.Text = "" end

		return handle
	end

	-- Containers -------------------------------------------------------------

	-- A group of related controls. One step above the surface it sits on plus a
	-- hairline, and nothing else -- no shadow, no heavier fill. `stroke = false`
	-- drops the outline for a card that is only there to hold padding.
	function P.card(parent, props)
		props = props or {}
		local card, layout = P.column(parent, {
			name = props.name or "Card",
			size = props.size or UDim2.new(1, 0, 0, 0),
			auto = props.auto or "Y",
			layoutOrder = props.layoutOrder,
			bg = props.bg or theme.color.surfaceRaised,
			radius = props.radius or theme.radius.lg,
			gap = props.gap or theme.space.md,
			padding = props.padding or theme.space.lg,
			clip = props.clip,
		})
		if props.stroke ~= false then
			P.stroke(card, props.strokeColor or theme.color.borderSubtle)
		end
		return card, layout
	end

	-- A small label for a fact or a status. Neutral unless it is given a tone: most
	-- of these are a model id or an auth style, and colouring those blue because
	-- "info" was the default made a row of plain facts look like a row of warnings.
	function P.badge(parent, props)
		props = props or {}
		local tone = props.tone or "neutral"
		local holder = P.row(parent, {
			name = "Badge",
			size = UDim2.fromOffset(0, theme.size.controlSmall - theme.space.xs),
			auto = "X",
			bg = props.bg or theme.toneSurface(tone),
			radius = theme.radius.sm,
			gap = theme.space.xxs,
			padding = { x = theme.space.xs },
			layoutOrder = props.layoutOrder,
		})
		if props.dot then
			local dot = P.frame(holder, {
				name = "Dot",
				size = UDim2.fromOffset(theme.space.xs, theme.space.xs),
				bg = props.dotColor or theme.toneColor(tone),
				radius = theme.radius.pill,
			})
			dot.LayoutOrder = 1
		end
		local label = P.text(holder, {
			text = tostring(props.text or ""),
			role = "caption",
			color = props.color or theme.toneColor(tone),
			auto = "XY",
			layoutOrder = 2,
		})
		label.Size = UDim2.fromOffset(0, 0)
		return holder, label
	end

	-- A scroll region with the two things Roblox does not give you: a canvas that
	-- sizes itself from its contents, and edge fades so a long list reads as
	-- continuing rather than as ending at a hard line.
	function P.scroll(parent, props)
		props = props or {}
		local scroll = Instance.new("ScrollingFrame", parent)
		base(scroll, {
			name = props.name or "Scroll",
			size = props.size or UDim2.new(1, 0, 1, 0),
			position = props.position,
			layoutOrder = props.layoutOrder,
			bg = props.bg,
			-- Forwarded like every other layout prop. It was not, so a scroll region asked
			-- to fill its line kept whatever size it was given -- which for the intended
			-- `UDim2.new(0, 0, 1, 0)` is no width at all. Three call sites had already
			-- worked around it by attaching a UIFlexItem by hand afterwards.
			flex = props.flex,
			clip = true,
		})
		scroll.ScrollBarThickness = props.bar or theme.size.scrollbar
		scroll.ScrollBarImageColor3 = theme.color.border
		scroll.ScrollBarImageTransparency = theme.opacity.scrollbar
		scroll.BorderSizePixel = 0
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.AutomaticCanvasSize = props.horizontal and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
		scroll.ScrollingDirection = props.horizontal and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
		scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		scroll.Selectable = false

		local layout = Instance.new("UIListLayout", scroll)
		layout.FillDirection = props.horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, props.gap or theme.space.sm)
		if props.alignX then layout.HorizontalAlignment = Enum.HorizontalAlignment[props.alignX] end

		if props.padding then P.pad(scroll, props.padding) end

		local handle = { instance = scroll, layout = layout }

		function handle.toBottom()
			scroll.CanvasPosition = Vector2.new(0, math.max(scroll.AbsoluteCanvasSize.Y, 1e6))
		end

		function handle.atBottom(slack)
			local visible = scroll.AbsoluteWindowSize.Y
			local total = scroll.AbsoluteCanvasSize.Y
			if total <= visible then return true end
			return (total - visible - scroll.CanvasPosition.Y) <= (slack or theme.space.huge)
		end

		function handle.clear()
			for _, child in ipairs(scroll:GetChildren()) do
				if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
			end
		end

		if props.fade then
			for _, spec in ipairs({
				{ name = "FadeTop", anchor = Vector2.new(0, 0), position = UDim2.fromScale(0, 0), rotation = 90 },
				{ name = "FadeBottom", anchor = Vector2.new(0, 1), position = UDim2.fromScale(0, 1), rotation = -90 },
			}) do
				local fade = P.frame(parent, {
					name = spec.name,
					size = UDim2.new(1, 0, 0, theme.space.xl),
					anchor = spec.anchor,
					position = spec.position,
					bg = props.fadeColor or theme.color.surface,
					zIndex = (props.zIndex or 1) + 5,
				})
				local gradient = Instance.new("UIGradient", fade)
				gradient.Rotation = spec.rotation
				gradient.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				})
			end
		end

		return handle
	end

	-- A small coloured dot used for provider health and busy state. Separate from
	-- badge because it is used inline in dense rows where a pill is too heavy.
	function P.statusDot(parent, props)
		props = props or {}
		return P.frame(parent, {
			name = "Status",
			size = UDim2.fromOffset(props.diameter or theme.size.dot, props.diameter or theme.size.dot),
			bg = props.color or theme.color.textTertiary,
			radius = theme.radius.pill,
			layoutOrder = props.layoutOrder,
			anchor = props.anchor,
			position = props.position,
		})
	end

	return P
end
