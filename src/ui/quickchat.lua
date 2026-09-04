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
			size = UDim2.new(0, math.min(math.max(responsive.viewport.X * 0.5, 360), 720), 0, 0),
			auto = "Y",
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.42),
			bg = theme.color.surface,
			radius = theme.radius.xl,
			gap = theme.space.xs,
			padding = theme.space.md,
			zIndex = theme.z.quick + 1,
		})
		P.stroke(card, theme.color.accentBorder)
		M.card = card
		M.scale = Instance.new("UIScale", card)
		M.scale.Scale = 0.96

		M.field = P.field(card, {
			name = "QuickPrompt",
			placeholder = "Ask, or tell it what to change",
			layoutOrder = 1,
			onSubmit = function(text) M.submit(text) end,
		})

		M.hint = P.text(card, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			layoutOrder = 2,
		})

		M.mounted = true
		return M.root
	end

	local function refreshHint()
		if not M.hint then return end
		local providers = env.require("provider/registry")
		local record = providers.active()
		M.hint.Text = record
			and string.format("Enter to send to %s  ·  Esc to close  ·  %s reopens",
				tostring(record.label), M.keyName())
			or "No provider configured yet -- open the window and add one."
	end

	function M.show()
		if not M.mounted or M.visible then return end
		M.visible = true
		refreshHint()
		M.field.set("")
		M.root.Visible = true
		if responsive.reduceMotion then
			M.scale.Scale = 1
			M.scrim.BackgroundTransparency = 0.5
		else
			M.scale.Scale = 0.96
			M.scrim.BackgroundTransparency = 1
			env.tween:Create(M.scale, theme.tween("enter"), { Scale = 1 }):Play()
			env.tween:Create(M.scrim, theme.tween("enter"), { BackgroundTransparency = 0.5 }):Play()
		end
		-- One frame late: capturing focus in the same frame the surface becomes
		-- visible is unreliable.
		clock.delay(0.05, function()
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
		env.tween:Create(M.scale, theme.tween("exit"), { Scale = 0.96 }):Play()
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
		M.hide()
		if message == "" then return end
		-- The same session the Chat panel is bound to, so the message and its reply
		-- land in the transcript rather than in a parallel conversation.
		local ok, reason = sessions.current().send(message)
		if not ok then
			env.require("ui/overlay").toast(tostring(reason), "warn", 3)
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
