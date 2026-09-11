-- The overlay layer: toasts, modals, confirmations and anchored menus.
--
-- One layer above everything, owned here, so z-order is decided in one place and a
-- dropdown can never end up behind the window that opened it. Every surface closes
-- on scrim click and on Escape, because a modal you cannot dismiss is the fastest
-- way to make someone force-quit a game.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local dispose = env.require("runtime/dispose")
	local caps = env.require("runtime/caps")
	local P = env.require("ui/primitives")
	local icons = env.require("ui/icons")

	local TOAST_SECONDS = 4.5
	local TOAST_LIMIT = 3

	local M = { toasts = {}, open = {} }

	function M.mount(screenGui)
		if M.layer and M.layer.Parent then return M.layer end
		M.layer = P.frame(screenGui, {
			name = "Overlay",
			size = UDim2.fromScale(1, 1),
			zIndex = theme.z.overlay,
		})
		M.layer.Active = false

		M.toastColumn = P.column(M.layer, {
			name = "Toasts",
			size = UDim2.new(0, theme.size.menuWide, 0, 0),
			auto = "Y",
			anchor = Vector2.new(0.5, 0),
			position = UDim2.new(0.5, 0, 0, theme.space.lg + responsive.inset.Y),
			gap = theme.space.xs,
			zIndex = theme.z.toast,
		})

		-- Escape closes the topmost surface. Bound once, on the layer's lifetime.
		dispose.connection(env.uis.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.ButtonB then return end
			local topmost = M.open[#M.open]
			if topmost then topmost.close() end
		end))

		return M.layer
	end

	local function ensure()
		if not M.layer or not M.layer.Parent then
			local app = env.require("ui/app")
			if app.screen then M.mount(app.screen) end
		end
		return M.layer
	end

	-- Toasts -----------------------------------------------------------------

	function M.toast(text, tone, seconds)
		if not ensure() then return nil end
		-- Old toasts leave rather than stack forever; three is as many as anyone
		-- reads.
		while #M.toasts >= TOAST_LIMIT do
			local oldest = table.remove(M.toasts, 1)
			if oldest then oldest.close() end
		end

		local toneKey = tone or "info"
		local toneColor = theme.toneColor(toneKey)

		-- The card is a self-contained clickable notification surface.
		-- Width is 100% of M.toastColumn (theme.size.menuWide = 320px).
		-- Children use concrete parent-relative sizing to prevent Roblox's
		-- UIFlexItem AutomaticSize.Y 0-width text wrap bug.
		local card = Instance.new("TextButton", M.toastColumn)
		card.Name = "Toast"
		card.Text = ""
		card.AutoButtonColor = false
		card.BorderSizePixel = 0
		card.BackgroundColor3 = theme.color.surfaceRaised
		card.Size = UDim2.new(1, 0, 0, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.ZIndex = theme.z.toast
		card.BackgroundTransparency = 1
		card.Position = UDim2.new(0, 0, 0, -10)
		card.ClipsDescendants = true
		Instance.new("UICorner", card).CornerRadius = UDim.new(0, theme.radius.md)

		local stroke = Instance.new("UIStroke", card)
		stroke.Color = theme.color.borderSubtle
		stroke.Thickness = theme.stroke.hair
		stroke.Transparency = 1

		local pad = Instance.new("UIPadding", card)
		pad.PaddingLeft = UDim.new(0, theme.space.md)
		pad.PaddingRight = UDim.new(0, theme.space.md)
		pad.PaddingTop = UDim.new(0, theme.space.sm + 2)
		pad.PaddingBottom = UDim.new(0, theme.space.sm + 2)

		-- Minimum height constraint ensures comfortable touch target
		local sizeConstraint = Instance.new("UISizeConstraint", card)
		sizeConstraint.MinSize = Vector2.new(0, 42)

		-- Distinct 22x22 tone badge on the left
		local indicator = Instance.new("Frame", card)
		indicator.Name = "Indicator"
		indicator.Size = UDim2.fromOffset(22, 22)
		indicator.Position = UDim2.new(0, 0, 0, 0)
		indicator.BackgroundColor3 = theme.color[toneKey .. "Surface"] or theme.color.surfaceOverlay
		indicator.BackgroundTransparency = 1
		indicator.BorderSizePixel = 0
		indicator.ZIndex = theme.z.toast + 1
		Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)

		if toneKey == "good" then
			icons.check(indicator, 12, theme.color.success)
		elseif toneKey == "danger" or toneKey == "bad" then
			icons.close(indicator, 10, theme.color.danger)
		elseif toneKey == "warn" then
			icons.spark(indicator, 12, theme.color.warn)
		else
			P.statusDot(indicator, {
				color = toneColor,
				diameter = theme.size.dot,
				anchor = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.5),
			})
		end

		-- Close slot on the right
		local closeSlot = Instance.new("Frame", card)
		closeSlot.Name = "CloseSlot"
		closeSlot.Size = UDim2.fromOffset(14, 14)
		closeSlot.AnchorPoint = Vector2.new(1, 0)
		closeSlot.Position = UDim2.new(1, 0, 0, 3)
		closeSlot.BackgroundTransparency = 1
		closeSlot.BorderSizePixel = 0
		closeSlot.ZIndex = theme.z.toast + 1
		icons.close(closeSlot, 10, theme.color.textTertiary)

		-- Label is explicitly positioned between indicator and close button.
		-- Size width is strictly parent-relative (1, -54), giving Roblox's text engine
		-- a guaranteed concrete width (~242px) so text wrapped lines wrap cleanly and
		-- NEVER measure at 0-width (which produced the 1-character vertical text bug).
		local label = Instance.new("TextLabel", card)
		label.Name = "Message"
		label.Text = tostring(text)
		label.TextColor3 = theme.color.text
		label.TextTransparency = 1
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Position = UDim2.new(0, 32, 0, 1)
		label.Size = UDim2.new(1, -54, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.ZIndex = theme.z.toast + 1

		local role = theme.text.small
		label.TextSize = role.size
		label.Font = role.font
		if role.face then pcall(function() label.FontFace = role.face end) end

		local entry = { card = card, closed = false }

		function entry.close()
			if entry.closed then return end
			entry.closed = true
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) end
			end
			local out = env.tween:Create(card, theme.tween("exit"), {
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 0, 0, -10),
			})
			out.Completed:Connect(function() pcall(function() card:Destroy() end) end)
			out:Play()
			env.tween:Create(stroke, theme.tween("exit"), { Transparency = 1 }):Play()
			env.tween:Create(indicator, theme.tween("exit"), { BackgroundTransparency = 1 }):Play()
			env.tween:Create(label, theme.tween("exit"), { TextTransparency = 1 }):Play()
		end

		card.Activated:Connect(entry.close)

		-- Subtle hover feedback
		card.MouseEnter:Connect(function()
			env.tween:Create(stroke, theme.tween("quick"), { Color = theme.color.border }):Play()
		end)
		card.MouseLeave:Connect(function()
			env.tween:Create(stroke, theme.tween("quick"), { Color = theme.color.borderSubtle }):Play()
		end)

		M.toasts[#M.toasts + 1] = entry
		env.tween:Create(card, theme.tween("enter"), {
			BackgroundTransparency = 0,
			Position = UDim2.new(0, 0, 0, 0),
		}):Play()
		env.tween:Create(stroke, theme.tween("enter"), { Transparency = 0 }):Play()
		env.tween:Create(indicator, theme.tween("enter"), { BackgroundTransparency = 0 }):Play()
		env.tween:Create(label, theme.tween("enter"), { TextTransparency = 0 }):Play()
		clock.delay(seconds or TOAST_SECONDS, entry.close)
		return entry
	end

	-- Modals -----------------------------------------------------------------

	-- Returns a handle with `content` (a column to fill) and `close`. The caller
	-- builds the body; this owns the scrim, the card, the animation and dismissal.
	--
	-- `scroll = true` is for a modal holding a form rather than a sentence.
	--
	-- An auto-height card has no ceiling: it is as tall as whatever is put in it, and
	-- since it is centred, anything past the viewport goes off *both* edges at once. The
	-- provider editor is seven labelled rows and a footer, so on a phone in landscape --
	-- 720 tall, which is an ordinary Roblox client -- its title and preset row were cut
	-- off above the screen and its key row and Save button below it, with no way to reach
	-- either: nothing scrolled, because nothing knew it was too big. In this mode the
	-- card takes a bounded height instead, the header and footer stay put, and the body
	-- between them scrolls.
	--
	-- Bounded rather than measured. Roblox will report a UIListLayout's content size, but
	-- only after a frame, and driving a card's height off it means the modal resizes
	-- under the pointer as rows are built -- so the height here is a cap the caller
	-- states, clamped to what the screen has.
	function M.modal(props)
		props = props or {}
		if not ensure() then return nil end

		local scrim = P.frame(M.layer, {
			name = "Scrim",
			size = UDim2.fromScale(1, 1),
			bg = theme.color.scrim,
			bgTransparency = 1,
			zIndex = theme.z.modal,
		})
		scrim.Active = true

		local sheetMode = responsive.mode == "sheet"
		local widest = math.max(responsive.viewport.X - theme.space.xxl * 2, theme.size.modalMin)
		local scrolls = props.scroll == true
		-- Everything the screen has, less the margin a floating card keeps and whatever
		-- the platform is covering: the top inset, and the on-screen keyboard, which is
		-- the case that matters most here because a form is a thing you type into.
		local bottomObstruction = responsive.bottomObstruction()
		local room = responsive.viewport.Y - responsive.inset.Y
			- bottomObstruction - theme.space.lg * 2
		local height = 0
		if scrolls then
			local preferred = props.height or 620
			height = math.floor(util.clamp(preferred,
				theme.size.modalMin, math.max(room, theme.size.modalMin)))
		end

		local dismiss
		if props.dismissable ~= false then
			-- Clicking the scrim is the way out. Placed behind the card, which is
			-- Active and consumes its own clicks.
			dismiss = Instance.new("TextButton", scrim)
			dismiss.Name = "Dismiss"
			dismiss.Text = ""
			dismiss.BackgroundTransparency = 1
			dismiss.Size = UDim2.fromScale(1, 1)
			dismiss.ZIndex = theme.z.modal
			dismiss.AutoButtonColor = false
		end

		local cardProps = {
			name = "Modal",
			size = sheetMode
				and UDim2.new(1, -theme.space.md * 2, 0, scrolls and height or 0)
				or UDim2.new(0, util.clamp(props.width or theme.size.modal, theme.size.modalMin, widest),
					0, scrolls and height or 0),
			auto = (not scrolls) and "Y" or nil,
			anchor = sheetMode and Vector2.new(0.5, 1) or Vector2.new(0.5, 0.5),
			position = sheetMode and UDim2.new(0.5, 0, 1, -(theme.space.lg + bottomObstruction)) or UDim2.fromScale(0.5, 0.5),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			padding = (not scrolls) and theme.space.lg or nil,
			zIndex = theme.z.modal + 1,
		}

		local card
		if scrolls then
			card = P.frame(scrim, cardProps)
		else
			cardProps.gap = theme.space.md
			card = P.column(scrim, cardProps)
		end
		-- Active so clicks and touches inside the card never fall through to the dismiss button.
		card.Active = true
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = theme.scale.enter

		local closeDiameter = math.max(theme.size.control, responsive.minTarget())
		local descLines = props.description and math.ceil(#tostring(props.description) / 38) or 0
		local headerContentHeight = math.max(closeDiameter,
			theme.text.title.height + (props.description and (theme.space.xs + descLines * theme.text.small.height) or 0))
		local footerContentHeight = math.max(theme.size.control, responsive.minTarget())
		local pad = theme.space.lg
		local headerTotal = headerContentHeight + pad
		local footerTotal = footerContentHeight + pad

		local header = P.row(card, {
			name = "Header",
			size = scrolls and UDim2.new(1, 0, 0, headerTotal) or UDim2.new(1, 0, 0, 0),
			position = scrolls and UDim2.new(0, 0, 0, 0) or nil,
			padding = scrolls and { x = pad, top = pad } or nil,
			auto = (not scrolls) and "Y" or nil,
			gap = theme.space.sm,
			alignY = "Top",
			layoutOrder = 1,
		})
		local titleColumn = P.column(header, {
			-- Fills rather than reserving control + sm for the close button, which is
			-- sized to max(control, minTarget()) and so is 44 on touch.
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			flex = "Fill",
			gap = theme.space.hair,
			layoutOrder = 1,
		})
		P.text(titleColumn, {
			text = tostring(props.title or ""),
			role = "title",
			wrap = true,
			auto = "Y",
		})
		if props.description then
			P.text(titleColumn, {
				text = props.description,
				role = "small",
				color = theme.color.textSecondary,
				wrap = true,
				auto = "Y",
			})
		end

		local handle = { card = card, scrim = scrim, closed = false }
		local unbindResponsive

		function handle.close()
			if handle.closed then return end
			handle.closed = true
			if unbindResponsive then
				pcall(unbindResponsive)
				unbindResponsive = nil
			end
			for index, item in ipairs(M.open) do
				if item == handle then table.remove(M.open, index) end
			end
			env.tween:Create(scale, theme.tween("exit"), { Scale = theme.scale.enter }):Play()
			local out = env.tween:Create(scrim, theme.tween("exit"), { BackgroundTransparency = 1 })
			out.Completed:Connect(function() pcall(function() scrim:Destroy() end) end)
			out:Play()
			if props.onClose then pcall(props.onClose) end
		end

		local function relayout()
			if handle.closed then return end
			local isSheet = responsive.mode == "sheet"
			local curWidest = math.max(responsive.viewport.X - theme.space.xxl * 2, theme.size.modalMin)
			local curObstruction = responsive.bottomObstruction()
			local curRoom = responsive.viewport.Y - responsive.inset.Y
				- curObstruction - theme.space.lg * 2
			local curHeight = 0
			if scrolls then
				local preferred = props.height or 620
				curHeight = math.floor(util.clamp(preferred,
					theme.size.modalMin, math.max(curRoom, theme.size.modalMin)))
			end

			card.AnchorPoint = isSheet and Vector2.new(0.5, 1) or Vector2.new(0.5, 0.5)
			card.Position = isSheet
				and UDim2.new(0.5, 0, 1, -(theme.space.lg + curObstruction))
				or UDim2.fromScale(0.5, 0.5)
			card.Size = isSheet
				and UDim2.new(1, -theme.space.md * 2, 0, scrolls and curHeight or 0)
				or UDim2.new(0, util.clamp(props.width or theme.size.modal, theme.size.modalMin, curWidest),
					0, scrolls and curHeight or 0)
		end

		unbindResponsive = responsive.changed:connect(relayout)

		if dismiss then
			dismiss.Activated:Connect(handle.close)
		end

		if props.dismissable ~= false then
			local closeButton = P.iconButton(header, {
				name = "Close",
				icon = "close",
				diameter = theme.size.control,
				onClick = handle.close,
				layoutOrder = 2,
			})
			closeButton.instance.LayoutOrder = 2
		end

		-- The body. In bounded scroll mode, it takes the region between the fixed-height
		-- header and pinned footer without layout-fighting UIFlexItem.
		if scrolls then
			handle.scroll = P.scroll(card, {
				name = "BodyScroll",
				position = UDim2.new(0, 0, 0, headerTotal),
				size = UDim2.new(1, 0, 1, -(headerTotal + footerTotal)),
				gap = theme.space.sm,
				padding = { left = pad, right = pad },
			})
			handle.scroll.instance.CanvasPosition = Vector2.new(0, 0)
			handle.content = P.column(handle.scroll.instance, {
				name = "Body",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				layoutOrder = 1,
			})
			handle.footer = P.row(card, {
				name = "Footer",
				size = UDim2.new(1, 0, 0, footerTotal),
				anchor = Vector2.new(0, 1),
				position = UDim2.new(0, 0, 1, 0),
				padding = { x = pad, bottom = pad },
				gap = theme.space.sm,
				alignX = "Right",
			})
		else
			handle.content = P.column(card, {
				name = "Body",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				layoutOrder = 2,
			})
			handle.footer = P.row(card, {
				name = "Footer",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				alignX = "Right",
				layoutOrder = 3,
			})
		end

		M.open[#M.open + 1] = handle
		env.tween:Create(scrim, theme.tween("enter"), { BackgroundTransparency = theme.opacity.scrim }):Play()
		-- Snapped on completion. A card left mid-tween sits at 0.98 for as long as it is
		-- open, which re-lays-out every label inside it at 98% of its metrics -- the same
		-- family of bug as the window's own scale, one step less visible.
		local grow = env.tween:Create(scale, theme.tween("enter"), { Scale = 1 })
		grow.Completed:Connect(function()
			if not handle.closed then scale.Scale = 1 end
		end)
		grow:Play()
		return handle
	end

	function M.confirm(props)
		props = props or {}
		local modal = M.modal({
			title = props.title or "Are you sure?",
			description = props.description,
			width = props.width or theme.size.modal,
			onClose = props.onCancel,
		})
		if not modal then
			if props.onConfirm then props.onConfirm() end
			return nil
		end

		P.button(modal.footer, {
			text = props.cancelText or "Cancel",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function()
				modal.close()
			end,
		})
		P.button(modal.footer, {
			text = props.confirmText or "Confirm",
			variant = props.danger and "danger" or "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				modal.closed = true
				for index, item in ipairs(M.open) do
					if item == modal then table.remove(M.open, index) end
				end
				pcall(function() modal.scrim:Destroy() end)
				if props.onConfirm then pcall(props.onConfirm) end
			end,
		})
		return modal
	end

	-- A one-field prompt. Used wherever a value has to be typed without opening a
	-- whole editor -- adding a model id from the header, for instance.
	--
	-- `multiline` swaps the field for a taller box that keeps newlines, for the
	-- one case where the value is legitimately several lines: a provider's key
	-- pool, pasted one key per line.
	function M.prompt(props)
		props = props or {}
		local modal = M.modal({
			title = props.title or "Enter a value",
			description = props.description,
			width = props.width or theme.size.modal,
		})
		if not modal then return nil end

		local field = P.field(modal.content, {
			name = "PromptField",
			placeholder = props.placeholder or "",
			text = props.value or "",
			multiline = props.multiline == true,
			height = props.multiline and (props.height or 120) or nil,
			layoutOrder = 1,
			onSubmit = props.multiline and nil or function(text)
				modal.close()
				if props.onConfirm then pcall(props.onConfirm, util.trim(text)) end
			end,
		})
		clock.delay(theme.motion.fast, function() field.focus() end)

		P.button(modal.footer, {
			text = props.cancelText or "Cancel",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function() modal.close() end,
		})
		P.button(modal.footer, {
			text = props.confirmText or "Add",
			variant = "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				-- A multiline paste is trimmed at the edges only: the newlines
				-- inside are the pool separator, not whitespace to tidy away.
				local value = props.multiline and field.get() or util.trim(field.get())
				modal.close()
				if props.onConfirm then pcall(props.onConfirm, value) end
			end,
		})
		return modal
	end

	-- A read-only code viewer: monospace, scrolled, with a copy action in the
	-- footer. Used for the code tab's run output, where the transcript's own
	-- rendering is the wrong surface -- the user pressed Run and wants the result
	-- as a block they can scroll and copy, not a turn in the conversation.
	function M.code(props)
		props = props or {}
		local modal = M.modal({
			title = props.title or "Output",
			width = props.width or theme.size.modalWide,
			height = props.height or 420,
			scroll = true,
		})
		if not modal then return nil end

		local body = P.frame(modal.content, {
			name = "CodeBody",
			size = UDim2.new(1, 0, 0, 0),
			bg = theme.color.codeSurface,
			clip = true,
		})

		P.text(body, {
			name = "CodeText",
			text = tostring(props.code or ""),
			role = "monoSmall",
			line = theme.line.normal,
			color = theme.color.codeText,
			size = UDim2.new(1, 0, 0, 0),
			wrap = false,
			auto = "Y",
			alignX = "Left",
			padding = { x = theme.space.md, y = theme.space.sm },
		})

		if caps.clipboard then
			P.button(modal.footer, {
				text = "Copy",
				variant = "secondary",
				size = "sm",
				layoutOrder = 1,
				onClick = function()
					local ok = pcall(caps.fn.clipboard, tostring(props.code or ""))
					M.toast(ok and "Copied" or "Could not reach the clipboard",
						ok and "good" or "warn", 2)
				end,
			})
		end
		P.button(modal.footer, {
			text = "Close",
			variant = "ghost",
			size = "sm",
			layoutOrder = 2,
			onClick = function() modal.close() end,
		})
		return modal
	end

	-- A dialog: a large fixed surface with two panes and its own scrim.
	--
	-- Not a modal. `M.modal` is a narrow auto-height card built around a title and a
	-- footer, which is right for a confirmation and wrong for a settings window -- the
	-- one the settings dialog used to build by hand had no scrim dismissal and was not
	-- registered here, so Escape did nothing and clicking beside it did nothing.
	function M.dialog(props)
		props = props or {}
		if not ensure() then return nil end

		local margin = theme.space.lg * 2
		local width = math.min(props.width or theme.size.dialog, responsive.viewport.X - margin)
		local height = math.min(props.height or theme.size.dialogTall,
			responsive.viewport.Y - margin - responsive.inset.Y)

		local scrim = P.frame(M.layer, {
			name = "Scrim",
			size = UDim2.fromScale(1, 1),
			bg = theme.color.scrim,
			bgTransparency = 1,
			zIndex = theme.z.modal,
		})
		scrim.Active = true

		local dismiss = Instance.new("TextButton", scrim)
		dismiss.Name = "Dismiss"
		dismiss.Text = ""
		dismiss.BackgroundTransparency = 1
		dismiss.Size = UDim2.fromScale(1, 1)
		dismiss.AutoButtonColor = false
		dismiss.ZIndex = theme.z.modal

		local card = P.frame(scrim, {
			name = props.name or "Dialog",
			size = UDim2.fromOffset(width, height),
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
			bg = theme.color.surface,
			radius = theme.radius.xl,
			zIndex = theme.z.modal + 1,
			clip = true,
		})
		card.Active = true
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = theme.scale.enter

		local handle = { card = card, scrim = scrim, closed = false, width = width, height = height }

		function handle.close()
			if handle.closed then return end
			handle.closed = true
			for index, item in ipairs(M.open) do
				if item == handle then table.remove(M.open, index) end
			end
			env.tween:Create(scale, theme.tween("exit"), { Scale = theme.scale.enter }):Play()
			local out = env.tween:Create(scrim, theme.tween("exit"), { BackgroundTransparency = 1 })
			out.Completed:Connect(function() pcall(function() scrim:Destroy() end) end)
			out:Play()
			if props.onClose then pcall(props.onClose) end
		end

		dismiss.Activated:Connect(handle.close)

		local closeDiameter = math.max(theme.size.control, responsive.minTarget())
		local close = P.iconButton(card, {
			name = "DialogClose",
			icon = "close",
			diameter = theme.size.control,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -theme.space.sm, 0, theme.space.sm),
			zIndex = theme.z.modal + 4,
			onClick = handle.close,
		})
		close.instance.ZIndex = theme.z.modal + 4
		-- How much of the card's top-right corner the close button owns.
		--
		-- It is absolutely positioned over whatever the caller fills the card with, and
		-- the dialog has no title bar to keep it out of, so a caller that starts its
		-- content at the top edge draws under it -- which on a narrow layout put the
		-- button on top of the last category row and made it unreachable. Published
		-- rather than left for each caller to re-derive from two tokens.
		handle.closeInset = closeDiameter + theme.space.sm * 2

		M.open[#M.open + 1] = handle
		env.tween:Create(scrim, theme.tween("enter"), { BackgroundTransparency = theme.opacity.scrim }):Play()
		local grow = env.tween:Create(scale, theme.tween("enter"), { Scale = 1 })
		grow.Completed:Connect(function()
			if not handle.closed then scale.Scale = 1 end
		end)
		grow:Play()
		return handle
	end

	-- Anchored menu ----------------------------------------------------------

	-- Opens below the target, or above it when there is not enough room. Options are
	-- { label, value, detail, selected, tone }.
	function M.menu(props)
		props = props or {}
		if not ensure() then return nil end
		local target = props.target
		if not target then return nil end

		local scrim = P.frame(M.layer, {
			name = "MenuLayer",
			size = UDim2.fromScale(1, 1),
			zIndex = theme.z.dropdown,
		})
		local dismiss = Instance.new("TextButton", scrim)
		dismiss.Text = ""
		dismiss.BackgroundTransparency = 1
		dismiss.Size = UDim2.fromScale(1, 1)
		dismiss.AutoButtonColor = false

		local width = math.max(props.width or target.AbsoluteSize.X, theme.size.menuMin)

		-- The row height is derived from what the rows actually contain, not from a
		-- control token. An option with a detail line stacks a `small` label over a
		-- `caption` one, and the two together outgrow theme.size.row -- which is how
		-- every menu in the app ended up with its detail text overlapping the label of
		-- the row beneath it.
		local hasDetail = false
		for _, option in ipairs(props.options or {}) do
			if option.detail then hasDetail = true end
		end
		local content = theme.text.small.height + theme.space.xxs
		if hasDetail then content = content + theme.text.caption.height + theme.space.hair end
		local rowHeight = math.max(theme.size.row, responsive.minTarget(), content + theme.space.xs)

		-- Measured rather than counted: a divider is one pixel and a header is its own
		-- height, and treating both as a full row made the profile menu tall enough to
		-- scroll when everything in it already fitted.
		local headerHeight = theme.text.bodyStrong.height + theme.text.caption.height + theme.space.sm
		local bodyHeight = theme.space.xs * 2
		for _, option in ipairs(props.options or {}) do
			if option.divider then
				bodyHeight = bodyHeight + 1 + theme.space.hair
			elseif option.isHeader then
				bodyHeight = bodyHeight + headerHeight + theme.space.hair
			else
				bodyHeight = bodyHeight + rowHeight + theme.space.hair
			end
		end
		bodyHeight = math.min(bodyHeight, theme.size.menuMax)

		local layerOrigin = M.layer.AbsolutePosition
		local layerSize = M.layer.AbsoluteSize
		local targetX = target.AbsolutePosition.X - layerOrigin.X
		local targetY = target.AbsolutePosition.Y - layerOrigin.Y
		local below = targetY + target.AbsoluteSize.Y + theme.space.xxs

		local topLimit = theme.space.xs
		local bottomObstruction = responsive.bottomObstruction()
		local bottomLimit = math.max(topLimit + 60, layerSize.Y - bottomObstruction - theme.space.xs)

		local spaceBelow = math.max(0, bottomLimit - below)
		local spaceAbove = math.max(0, targetY - theme.space.xxs - topLimit)

		-- Only flip upward if it cannot fit below AND there is strictly more room above than below.
		local flip = (spaceBelow < bodyHeight) and (spaceAbove > spaceBelow)

		local anchorY
		if flip then
			local maxH = math.max(120, spaceAbove)
			bodyHeight = math.min(bodyHeight, maxH)
			anchorY = targetY - theme.space.xxs - bodyHeight
		else
			local maxH = math.max(120, spaceBelow)
			bodyHeight = math.min(bodyHeight, maxH)
			anchorY = below
		end

		anchorY = util.clamp(anchorY, topLimit, math.max(topLimit, bottomLimit - bodyHeight))
		local maxWidth = math.max(theme.size.menuMin, layerSize.X - theme.space.sm * 2)
		width = math.min(width, maxWidth)
		local anchorX = util.clamp(targetX, theme.space.sm, math.max(theme.space.sm, layerSize.X - width - theme.space.sm))

		local card = P.frame(scrim, {
			name = "Menu",
			size = UDim2.fromOffset(width, bodyHeight),
			position = UDim2.fromOffset(anchorX, anchorY),
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.md,
			zIndex = theme.z.dropdown + 1,
			clip = true,
		})
		P.stroke(card, theme.color.border)

		local handle = { closed = false }

		function handle.close()
			if handle.closed then return end
			handle.closed = true
			for index, item in ipairs(M.open) do
				if item == handle then table.remove(M.open, index) end
			end
			pcall(function() scrim:Destroy() end)
			if props.onClose then pcall(props.onClose) end
		end

		dismiss.Activated:Connect(handle.close)

		local list = P.scroll(card, {
			name = "Options",
			size = UDim2.fromScale(1, 1),
			gap = theme.space.hair,
			padding = theme.space.xs,
			zIndex = theme.z.dropdown + 2,
		})

		for index, option in ipairs(props.options or {}) do
			if option.divider then
				local div = P.divider(list.instance, {
					color = theme.color.borderSubtle,
					layoutOrder = index,
				})
				div.Size = UDim2.new(1, 0, 0, 1)
			elseif option.isHeader then
				-- The height the menu already reserved for it, sixty lines up. This was a
				-- literal 36 against 46 pixels of content, so every menu with a header --
				-- the profile menu, the conversation menu -- drew its subtitle ten pixels
				-- into the first option below it, while the menu as a whole still reserved
				-- the correct 48 and left the difference floating at the bottom.
				local headRow = P.column(list.instance, {
					size = UDim2.new(1, 0, 0, headerHeight),
					padding = { x = theme.space.sm, top = theme.space.xs },
					gap = 0,
					layoutOrder = index,
				})
				local title = P.text(headRow, {
					text = tostring(option.title or ""),
					role = "bodyStrong",
					color = theme.color.text,
					auto = "X",
					layoutOrder = 1,
				})
				title.Size = UDim2.fromOffset(0, theme.text.bodyStrong.height)
				if option.subtitle then
					local sub = P.text(headRow, {
						text = tostring(option.subtitle or ""),
						role = "caption",
						color = theme.color.textTertiary,
						auto = "X",
						layoutOrder = 2,
					})
					sub.Size = UDim2.fromOffset(0, theme.text.caption.height)
				end
			else
				local button = Instance.new("TextButton", list.instance)
				-- Named after the value it carries. A menu is where most of this
				-- interface's actions actually live, so an unnamed row is an action
				-- nothing outside the click handler can reach -- including a test.
				button.Name = "Option_" .. tostring(option.value ~= nil and option.value or option.label)
				button.Text = ""
				button.AutoButtonColor = false
				button.BackgroundColor3 = option.selected and theme.color.surfaceActive or theme.color.surfaceOverlay
				button.BackgroundTransparency = option.selected and 0 or 1
				button.BorderSizePixel = 0
				button.Size = UDim2.new(1, 0, 0, rowHeight)
				button.LayoutOrder = index
				button.Selectable = true
				P.corner(button, theme.radius.sm)

				local row = P.row(button, {
					size = UDim2.fromScale(1, 1),
					gap = theme.space.xs,
					padding = { x = theme.space.sm },
				})

				if option.icon then
					local iconHolder = P.frame(row, {
						size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
						layoutOrder = 1,
					})
					local iconTint = option.tone and theme.toneColor(option.tone) or theme.color.textSecondary
					icons.draw(option.icon, iconHolder, theme.size.icon, iconTint)
				end

				local labelColumn = P.column(row, {
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					gap = 0,
					alignY = "Center",
					layoutOrder = 2,
				})
				P.text(labelColumn, {
					text = tostring(option.label or option.value or ""),
					role = "small",
					color = option.tone and theme.toneColor(option.tone) or theme.color.text,
					truncate = true,
				})
				if option.detail then
					P.text(labelColumn, {
						text = option.detail,
						role = "caption",
						color = theme.color.textTertiary,
						truncate = true,
					})
				end

				if option.shortcut then
					local keycap = P.frame(row, {
						name = "Keycap",
						bg = theme.color.surfaceRaised,
						radius = theme.radius.xs,
						padding = { x = theme.space.xs, y = 1 },
						auto = "X",
						layoutOrder = 3,
					})
					P.stroke(keycap, theme.color.borderSubtle)
					local scLabel = P.text(keycap, {
						text = tostring(option.shortcut),
						role = "caption",
						color = theme.color.textSecondary,
						auto = "X",
					})
					scLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)
				elseif option.chevron then
					local chSlot = P.frame(row, {
						size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
						layoutOrder = 3,
					})
					icons.chevron(chSlot, theme.size.icon, theme.color.textTertiary, "right")
				elseif option.selected then
					local mark = P.frame(row, {
						size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
						layoutOrder = 3,
					})
					icons.check(mark, theme.size.icon, theme.color.accent)
				end

				button.MouseEnter:Connect(function()
					if not option.selected then
						env.tween:Create(button, theme.tween("hover"), {
							BackgroundTransparency = 0, BackgroundColor3 = theme.color.surfaceHover,
						}):Play()
					end
				end)
				button.MouseLeave:Connect(function()
					if not option.selected then
						env.tween:Create(button, theme.tween("hover"), { BackgroundTransparency = 1 }):Play()
					end
				end)
				button.Activated:Connect(function()
					handle.close()
					if props.onSelect then pcall(props.onSelect, option.value ~= nil and option.value or option.label, option) end
				end)
			end
		end

		M.open[#M.open + 1] = handle
		return handle
	end

	function M.closeAll()
		for index = #M.open, 1, -1 do
			local item = M.open[index]
			if item and item.close then item.close() end
		end
	end

	return M
end
