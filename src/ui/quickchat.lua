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

		local card = P.column(M.root, {
			name = "QuickCard",
			size = UDim2.new(0, math.min(math.max(responsive.viewport.X * 0.5, theme.size.modal), theme.size.reading * 0.6), 0, 0),
			auto = "Y",
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.42),
			bg = theme.color.surface,
			radius = theme.radius.xl,
			gap = theme.space.md,
			padding = theme.space.lg,
			zIndex = theme.z.quick + 1,
		})
		P.stroke(card, theme.color.borderStrong)
		M.card = card
		M.scale = Instance.new("UIScale", card)
		M.scale.Scale = theme.scale.enter

		local head = P.row(card, {
			name = "QuickHeader",
			size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget())),
			gap = theme.space.sm,
			layoutOrder = 1,
		})
		local mark = P.frame(head, {
			name = "QuickBrand", size = UDim2.fromOffset(theme.size.icon, theme.size.icon), layoutOrder = 0,
		})
		env.require("ui/brand").draw(mark, theme.size.icon)
		P.text(head, {
			text = "Quick message",
			role = "label",
			size = UDim2.new(0, 0, 0, theme.text.label.height),
			flex = "Fill",
			layoutOrder = 1,
		})
		P.iconButton(head, {
			name = "DismissQuickChat", icon = "close",
			diameter = theme.size.controlSmall, layoutOrder = 2,
			onClick = function() M.hide() end,
		})

		M.field = P.field(card, {
			name = "QuickPrompt",
			placeholder = "Ask a question or describe a change…",
			height = theme.size.controlLarge,
			layoutOrder = 2,
			onSubmit = function(text) M.submit(text) end,
		})

		local footer = P.row(card, {
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
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			wrap = true,
			flex = "Fill",
			layoutOrder = 1,
		})
		P.button(footer, {
			name = "SendQuickChat", text = "Send", icon = "send",
			variant = "primary", size = "sm", layoutOrder = 2,
			onClick = function() M.submit(M.field.get()) end,
		})
		local function layoutCard()
			local width = math.min(responsive.viewport.X - theme.space.xl * 2,
				math.max(responsive.viewport.X * 0.5, theme.size.modal), theme.size.reading * 0.6)
			card.Size = UDim2.fromOffset(math.max(math.floor(width), 1), 0)
			local available = responsive.viewport.Y - responsive.inset.Y - responsive.bottomObstruction()
			card.Position = UDim2.new(0.5, 0, 0, math.floor(available * 0.42))
		end
		M.layout = layoutCard
		layoutCard()
		local unsubscribe = responsive.changed:connect(layoutCard)
		M.root.Destroying:Connect(function() pcall(unsubscribe) end)

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
		M.field.set("")
		M.root.Visible = true
		if responsive.reduceMotion then
			M.scale.Scale = 1
			M.scrim.BackgroundTransparency = theme.opacity.scrim
		else
			M.scale.Scale = theme.scale.enter
			M.scrim.BackgroundTransparency = 1
			-- Snapped on completion: a card left mid-tween keeps its field laid out at
			-- 98% of its metrics until the next time it opens.
			local grow = env.tween:Create(M.scale, theme.tween("enter"), { Scale = 1 })
			grow.Completed:Connect(function()
				if M.visible then M.scale.Scale = 1 end
			end)
			grow:Play()
			env.tween:Create(M.scrim, theme.tween("enter"), { BackgroundTransparency = theme.opacity.scrim }):Play()
		end
		-- One frame late: capturing focus in the same frame the surface becomes
		-- visible is unreliable.
		clock.delay(theme.motion.fast, function()
			if M.visible then M.field.focus() end
		end)
	end

	function M.hide()
		if not M.mounted or not M.visible then return end
		M.visible = false
		pcall(function() M.field.instance:ReleaseFocus() end)
		if responsive.reduceMotion then
			M.root.Visible = false
			return
		end
		env.tween:Create(M.scale, theme.tween("exit"), { Scale = theme.scale.enter }):Play()
		local out = env.tween:Create(M.scrim, theme.tween("exit"), { BackgroundTransparency = 1 })
		out.Completed:Connect(function()
			-- Only hide if nothing reopened it while the tween ran.
			if not M.visible and M.root then M.root.Visible = false end
		end)
		out:Play()
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

		-- Clicking the scrim dismisses without sending.
		if M.scrim then
			M.scrim.Activated:Connect(function() M.hide() end)
		end
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
