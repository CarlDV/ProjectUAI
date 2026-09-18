-- Quick chat: one keypress, one message, gone again.
--
-- The window is the place to read a conversation; this is the place to start one
-- without leaving what you were doing. It floats in the middle of the screen, takes
-- a single line, sends to the same session the Chat panel shows -- so whatever is
-- typed here appears there -- and dismisses itself. Nothing about it is a second
-- transcript.
--
-- The key is captured rather than typed into a field: a user thinks "this key", not
-- "Enum.KeyCode.Semicolon", and capturing it also sidesteps mapping characters to
-- key codes across keyboard layouts.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local dispose = env.require("runtime/dispose")
	local P = env.require("ui/primitives")
	local sessions = env.require("agent/session")

	local M = { visible = false, mounted = false }

	local DEFAULT_KEY = "Semicolon"

	-- The bound key as an EnumItem, or nil when the stored name no longer exists.
	function M.keyCode()
		local name = tostring(config.get("ui.quickKey", DEFAULT_KEY))
		local ok, item = pcall(function() return Enum.KeyCode[name] end)
		if ok and item then return item end
		return Enum.KeyCode.Semicolon
	end

	function M.keyName()
		return tostring(config.get("ui.quickKey", DEFAULT_KEY))
	end

	function M.setKey(keyCode)
		local name = keyCode and keyCode.Name or DEFAULT_KEY
		config.set("ui.quickKey", name)
		return name
	end

	function M.mount(layer)
		if M.mounted and M.root and M.root.Parent then return M.root end
		M.visible = false

		M.root = P.frame(layer, {
			name = "QuickChat",
			size = UDim2.fromScale(1, 1),
			zIndex = theme.z.quick,
			visible = false,
		})
		M.root.Active = false

		-- A scrim, so the rest of the screen recedes and a click outside dismisses.
		local scrim = Instance.new("TextButton", M.root)
		scrim.Name = "QuickScrim"
		scrim.Text = ""
		scrim.AutoButtonColor = false
		scrim.BorderSizePixel = 0
		scrim.Size = UDim2.fromScale(1, 1)
		scrim.BackgroundColor3 = theme.color.scrim
		scrim.BackgroundTransparency = 1
		scrim.ZIndex = theme.z.quick
		M.scrim = scrim
		scrim.Activated:Connect(function() M.hide() end)

		local card = P.frame(M.root, {
			name = "QuickCard",
			size = UDim2.new(0, math.min(math.max(responsive.viewport.X * 0.5, theme.size.modal), theme.size.reading * 0.6), 0, 0),
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.42),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			clip = true,
			zIndex = theme.z.quick + 1,
		})
		card.Active = true
		local outline = P.stroke(card, theme.color.borderStrong)
		M.card = card
		M.scale = Instance.new("UIScale", card)
		M.scale.Scale = theme.scale.enter
		local scroll = P.scroll(card, { name = "QuickBody", size = UDim2.fromScale(1, 1), padding = theme.space.md, gap = 0 })
		local content, contentLayout = P.column(scroll.instance, {
			name = "QuickContent", size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm,
		})

		local head = P.row(content, {
			name = "QuickHeader",
			size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget())),
			gap = theme.space.sm,
			layoutOrder = 1,
		})
		local mark = P.frame(head, {
			name = "QuickBrand", size = UDim2.fromOffset(theme.size.iconLarge, theme.size.iconLarge), layoutOrder = 0,
		})
		env.require("ui/brand").draw(mark, theme.size.iconLarge)
		P.text(head, {
			text = "A thought? A task?",
			role = "heading",
			size = UDim2.new(0, 0, 0, theme.text.heading.height),
			flex = "Fill",
			truncate = true,
			layoutOrder = 1,
		})
		P.iconButton(head, {
			name = "DismissQuickChat", icon = "close",
			diameter = theme.size.controlSmall, layoutOrder = 2,
			onClick = function() M.hide() end,
		})

		M.field = P.field(content, {
			name = "QuickPrompt",
			placeholder = "Tell your agent what you have in mind…",
			bare = true,
			height = theme.size.control,
			layoutOrder = 2,
			onFocus = function() P.animate(outline, "hover", { Color = theme.color.accent }) end,
			onBlur = function() P.animate(outline, "hover", { Color = theme.color.borderStrong }) end,
			onSubmit = function(text) M.submit(text) end,
		})

		local footer = P.row(content, {
			name = "QuickFooter",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.md,
			layoutOrder = 3,
		})
		M.hint = P.text(footer, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			size = UDim2.new(0, 0, 0, theme.text.caption.height),
			truncate = true,
			flex = "Fill",
			layoutOrder = 1,
		})
		P.iconButton(footer, {
			name = "OpenFullChat", icon = "windowMaximize", diameter = theme.size.controlSmall, layoutOrder = 2,
			onClick = function()
				local text = M.field.get()
				local app = env.require("ui/app")
				app.show("chat")
				if app.chatPanel and app.chatPanel.composer then
					if text ~= "" then app.chatPanel.composer.insert(text) end
					M.field.clear()
					M.hide()
					app.chatPanel.composer.focus()
				end
			end,
		})
		P.button(footer, {
			name = "SendQuickChat", text = "Send", icon = "send",
			variant = "primary", size = "sm", layoutOrder = 3,
			onClick = function() M.submit(M.field.get()) end,
		})
		local function layoutCard()
			local bounds = responsive.usableRect(layer, theme.space.md)
			local width = math.min(bounds.width,
				math.max(responsive.viewport.X * 0.5, theme.size.modal), theme.size.reading * 0.6)
			local measured = contentLayout.AbsoluteContentSize
			-- Layout initially reports zero, including while hidden. Keep enough room
			-- for the fixed controls until the first measured pass arrives.
			local minimum = head.Size.Y.Offset + M.field.shell.Size.Y.Offset
				+ math.max(theme.size.controlSmall, responsive.minTarget()) + theme.space.sm * 2
			local wanted = math.max(minimum, measured and measured.Y or 0)
			local height = math.max(1, math.min(bounds.height, wanted + theme.space.md * 2))
			card.Size = UDim2.fromOffset(math.max(math.floor(width), 1), math.floor(height))
			local half = height / 2
			local y = util.clamp(bounds.height * 0.42, math.min(half, bounds.height / 2), math.max(bounds.height / 2, bounds.height - half))
			card.Position = UDim2.fromOffset(math.floor(bounds.x + bounds.width / 2), math.floor(bounds.y + y))
		end
		M.layout = layoutCard
		contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(layoutCard)
		layoutCard()
		local unsubscribe = dispose.add(responsive.changed:connect(layoutCard), "quick chat layout")
		local root = M.root
		root.Destroying:Connect(function()
			unsubscribe()
			if M.root == root then M.mounted = false; M.visible = false end
		end)
		local function rebuild()
			if M.root ~= root or not M.mounted then return end
			local text, visible = M.field.get(), M.visible
			root:Destroy()
			M.mount(layer)
			M.field.set(text)
			if visible then M.show() end
		end
		local queueRebuild, cancelRebuild = clock.debounce(rebuild, theme.duration("fast"))
		local stopTheme = dispose.add(theme.changed:connect(queueRebuild), "quick chat theme")
		local stopMode = dispose.add(responsive.modeChanged:connect(queueRebuild), "quick chat mode")
		root.Destroying:Connect(function()
			cancelRebuild()
			stopTheme()
			stopMode()
		end)

		M.mounted = true
		return M.root
	end

	local function refreshHint()
		if not M.hint then return end
		local providers = env.require("provider/registry")
		local record = providers.active()
		M.hint.TextColor3 = theme.color.textTertiary
		M.hint.Text = record
			and string.format("%s  ·  Enter to send  ·  Esc to close",
				tostring(record.label))
			or "No provider configured yet -- open the window and add one."
	end

	function M.show()
		if not M.mounted or M.visible then return end
		M.visible = true
		refreshHint()
		if M.layout then M.layout() end
		M.root.Visible = true
		if responsive.reduceMotion then
			P.animate(M.scale, "instant", { Scale = 1 })
			P.animate(M.scrim, "instant", { BackgroundTransparency = theme.opacity.scrim })
		else
			M.scale.Scale = theme.scale.enter
			M.scrim.BackgroundTransparency = 1
			-- Snapped on completion: a card left mid-tween keeps its field laid out at
			-- 98% of its metrics until the next time it opens.
			P.animate(M.scale, "enter", { Scale = 1 }, function()
				if M.visible then M.scale.Scale = 1 end
			end)
			P.animate(M.scrim, "enter", { BackgroundTransparency = theme.opacity.scrim })
		end
		-- One frame late: capturing focus in the same frame the surface becomes
		-- visible is unreliable.
		local root = M.root
		clock.delay(theme.duration("fast"), function()
			if M.visible and M.root == root then M.field.focus() end
		end)
	end

	function M.hide()
		if not M.mounted or not M.visible then return end
		M.visible = false
		pcall(function() M.field.instance:ReleaseFocus() end)
		if responsive.reduceMotion then
			P.animate(M.scale, "instant", { Scale = 1 })
			P.animate(M.scrim, "instant", { BackgroundTransparency = 1 })
			M.root.Visible = false
			return
		end
		P.animate(M.scale, "exit", { Scale = theme.scale.enter })
		local root = M.root
		P.animate(M.scrim, "exit", { BackgroundTransparency = 1 }, function()
			-- Only hide if nothing reopened it while the tween ran.
			if not M.visible and M.root == root then root.Visible = false end
		end)
	end

	function M.toggle()
		if M.visible then M.hide() else M.show() end
	end

	function M.submit(text)
		local message = util.trim(tostring(text or ""))
		if message == "" then return end
		-- The same session the Chat panel is bound to, so the message and its reply
		-- land in the transcript rather than in a parallel conversation.
		local ok, reason = sessions.current().send(message)
		if ok then
			M.field.clear()
			M.hide()
		else
			-- Rejection is recoverable: keep the prompt in place for a retry instead of
			-- closing and clearing it on the next open.
			if M.hint then
				M.hint.Text = tostring(reason)
				M.hint.TextColor3 = theme.color.warn
			end
			if M.visible and M.field then M.field.focus() end
		end
	end

	-- Bound once, on the service, because the point of the shortcut is that it works
	-- when nothing of this interface has focus.
	function M.bind()
		if M.bound then return end
		M.bound = true

		dispose.connection(env.uis.InputBegan:Connect(function(input, processed)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

			if M.visible then
				if input.KeyCode == Enum.KeyCode.Escape then M.hide() end
				return
			end

			-- `processed` means the keystroke already went somewhere -- a text box, a
			-- CoreGui field. Opening on it would fire every time the bound character is
			-- typed into the composer, which is the one thing that would make this
			-- feature intolerable.
			if processed then return end
			local focused = nil
			pcall(function() focused = env.uis:GetFocusedTextBox() end)
			if focused then return end

			if M.capture then
				local pending = M.capture
				M.capture = nil
				pending(input.KeyCode)
				return
			end

			if input.KeyCode == M.keyCode() then M.show() end
		end))

	end

	-- Settings asks for the next keypress rather than parsing a typed character.
	function M.captureNext(callback)
		M.capture = function(keyCode)
			local name = M.setKey(keyCode)
			if callback then pcall(callback, name) end
		end
	end

	function M.cancelCapture()
		M.capture = nil
	end

	return M
end
