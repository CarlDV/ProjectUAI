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

	local function toastCapacity()
		local height = math.max(theme.size.avatar, theme.size.controlSmall,
			responsive.minTarget(), theme.text.small.height) + theme.space.md * 2
		local room = responsive.viewport.Y - responsive.inset.Y
			- responsive.bottomObstruction() - theme.space.lg * 2
		return math.max(1, math.min(TOAST_LIMIT,
			math.floor((room + theme.space.sm) / (height + theme.space.sm))))
	end

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
			size = UDim2.new(0, theme.size.modal, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			zIndex = theme.z.toast,
		})

		local function layoutToasts()
			if not M.toastColumn or not M.toastColumn.Parent then return end
			while #M.toasts > toastCapacity() do
				local oldest = table.remove(M.toasts, 1)
				if oldest then oldest.close() end
			end
			local narrow = responsive.isNarrow()
			local width = math.max(theme.size.control, math.min(theme.size.modal,
				responsive.viewport.X - theme.space.md * 2))
			M.toastColumn.Size = UDim2.new(0, width, 0, 0)
			M.toastColumn.AnchorPoint = narrow and Vector2.new(0.5, 0) or Vector2.new(1, 0)
			M.toastColumn.Position = narrow
				and UDim2.new(0.5, 0, 0, theme.space.md + responsive.inset.Y)
				or UDim2.new(1, -theme.space.lg, 0, theme.space.lg + responsive.inset.Y)
		end
		layoutToasts()
		local unbindToasts = dispose.add(responsive.changed:connect(layoutToasts), "toast layout")
		M.toastColumn.Destroying:Connect(unbindToasts)

		-- Escape closes the topmost surface. Bound once, on the layer's lifetime.
		local unbindEscape = dispose.connection(env.uis.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.ButtonB then return end
			local topmost = M.open[#M.open]
			if topmost then topmost.close() end
		end))
		M.layer.Destroying:Connect(unbindEscape)

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
		while #M.toasts >= toastCapacity() do
			local oldest = table.remove(M.toasts, 1)
			if oldest then oldest.close() end
		end

		local toneKey = tone or "info"
		if toneKey == "danger" then toneKey = "bad" end
		if toneKey == "success" then toneKey = "good" end
		local toneColor = theme.toneColor(toneKey)
		local pad = theme.space.md
		local closeSize = math.max(theme.size.controlSmall, responsive.minTarget())
		local badgeSize = theme.size.avatar
		local inset = pad + badgeSize + theme.space.sm
		local trailing = pad + closeSize + theme.space.xs
		local minimum = math.max(badgeSize, closeSize, theme.text.small.height) + pad * 2

		-- The list owns this slot; only its child moves. Tweening the old toast's
		-- Position fought UIListLayout, while separately fading its parts left icons
		-- hanging in the air. An unscaled group fades every part together.
		local slot = P.frame(M.toastColumn, {
			name = "ToastSlot",
			size = UDim2.new(1, 0, 0, minimum),
			zIndex = theme.z.toast,
		})
		local group = Instance.new("CanvasGroup", slot)
		group.Name = "ToastSurface"
		group.BackgroundTransparency = 1
		group.BorderSizePixel = 0
		group.Size = UDim2.fromScale(1, 1)
		group.Position = UDim2.fromOffset(0, responsive.reduceMotion and 0 or -theme.space.sm)
		group.GroupTransparency = 1
		group.ZIndex = theme.z.toast
		P.corner(group, theme.radius.lg)

		local card = Instance.new("TextButton", group)
		card.Name = "Toast"
		card.Text = ""
		card.AutoButtonColor = false
		card.BorderSizePixel = 0
		card.BackgroundColor3 = theme.color.surfaceOverlay
		card.Size = UDim2.fromScale(1, 1)
		card.ZIndex = theme.z.toast
		card.Selectable = true
		P.corner(card, theme.radius.lg)
		local stroke = P.stroke(card, theme.color.border)

		local indicator = P.frame(card, {
			name = "Indicator",
			size = UDim2.fromOffset(badgeSize, badgeSize),
			position = UDim2.fromOffset(pad, pad),
			bg = theme.toneSurface(toneKey),
			radius = theme.radius.md,
			zIndex = theme.z.toast + 1,
		})
		if toneKey == "good" then
			icons.check(indicator, theme.size.icon, toneColor)
		elseif toneKey == "bad" then
			icons.close(indicator, theme.size.icon, toneColor)
		elseif toneKey == "warn" then
			P.text(indicator, {
				text = "!", role = "bodyStrong", color = toneColor,
				size = UDim2.fromScale(1, 1), align = "Center", alignY = "Center",
			})
		else
			P.statusDot(indicator, {
				color = toneColor,
				anchor = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.5),
			})
		end

		-- A bounded reading area retains the complete message even for a provider
		-- error containing a long response. It cannot push the stack off-screen.
		local message = P.scroll(card, {
			name = "ToastMessage",
			position = UDim2.fromOffset(inset, pad),
			size = UDim2.new(1, -(inset + trailing), 1, -pad * 2),
			gap = 0,
			zIndex = theme.z.toast + 1,
		})
		local label = P.text(message.instance, {
			name = "Message",
			text = tostring(text),
			role = "small",
			color = theme.color.text,
			size = UDim2.new(1, -theme.size.scrollbar, 0, 0),
			wrap = true,
			auto = "Y",
			zIndex = theme.z.toast + 1,
		})

		local entry = { card = card, closed = false }
		local hovered, focused = false, false
		local remaining = math.max(0, seconds or TOAST_SECONDS)
		local started = clock.ms()
		local generation = 0
		local unbindLayout

		local function layoutMessage()
			if entry.closed then return end
			local available = responsive.viewport.Y - responsive.inset.Y
				- responsive.bottomObstruction() - theme.space.lg * 2
			local ceiling = math.max(minimum, math.min(theme.text.small.height * 5 + pad * 2,
				math.floor(available / toastCapacity()) - theme.space.sm))
			local wanted = math.max(minimum, math.ceil(label.TextBounds.Y) + pad * 2)
			slot.Size = UDim2.new(1, 0, 0, math.min(wanted, ceiling))
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(layoutMessage)
		unbindLayout = dispose.add(responsive.changed:connect(layoutMessage), "toast size")
		layoutMessage()

		function entry.close()
			if entry.closed then return end
			entry.closed = true
			generation = generation + 1
			if unbindLayout then unbindLayout() end
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) break end
			end
			local out = P.animate(group, "exit", {
				GroupTransparency = 1,
				Position = UDim2.fromOffset(0, responsive.reduceMotion and 0 or -theme.space.xs),
			})
			out.Completed:Connect(function() pcall(function() slot:Destroy() end) end)
		end
		slot.Destroying:Connect(function()
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) break end
			end
			entry.closed = true
			generation = generation + 1
			if unbindLayout then unbindLayout() end
		end)

		local close = P.iconButton(card, {
			name = "DismissNotification",
			icon = "close",
			diameter = closeSize,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -pad, 0, pad),
			zIndex = theme.z.toast + 2,
			onClick = entry.close,
		})
		close.instance.ZIndex = theme.z.toast + 2
		card.Activated:Connect(entry.close)

		local function schedule()
			generation = generation + 1
			local mine = generation
			started = clock.ms()
			clock.delay(remaining, function()
				if not entry.closed and mine == generation and not hovered and not focused then entry.close() end
			end)
		end
		local function pause()
			remaining = math.max(0, remaining - clock.since(started) / 1000)
			generation = generation + 1
		end
		local function paint()
			if entry.closed then return end
			P.animate(stroke, "hover", { Color = focused and theme.color.accentBorder or theme.color.border })
			P.animate(card, "hover", {
				BackgroundColor3 = (hovered or focused) and theme.color.surfaceActive or theme.color.surfaceOverlay,
			})
		end
		card.MouseEnter:Connect(function()
			if not hovered and not focused then pause() end
			hovered = true
			paint()
		end)
		card.MouseLeave:Connect(function()
			hovered = false
			if not focused and not entry.closed then schedule() end
			paint()
		end)
		local function focus()
			if not hovered and not focused then pause() end
			focused = true
			paint()
		end
		local function blur()
			focused = false
			if not hovered and not entry.closed then schedule() end
			paint()
		end
		card.SelectionGained:Connect(focus)
		card.SelectionLost:Connect(blur)
		close.instance.SelectionGained:Connect(focus)
		close.instance.SelectionLost:Connect(blur)

		M.toasts[#M.toasts + 1] = entry
		P.animate(group, "enter", { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
		schedule()
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
		local widest = math.max(responsive.viewport.X - theme.space.lg * 2, theme.size.modalMin)
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
			position = sheetMode and UDim2.new(0.5, 0, 1, -(theme.space.lg + bottomObstruction))
				or UDim2.new(0.5, 0, 0.5, math.floor((responsive.inset.Y - bottomObstruction) / 2)),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			padding = (not scrolls) and theme.space.lg or nil,
			zIndex = theme.z.modal + 1,
			clip = true,
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
		scale.Scale = responsive.reduceMotion and 1 or theme.scale.enter

		local closeDiameter = math.max(theme.size.control, responsive.minTarget())
		local descLines = props.description and math.ceil(#tostring(props.description) / 38) or 0
		local headerContentHeight = math.max(closeDiameter,
			theme.text.title.height + (props.description and (theme.space.xs + descLines * theme.text.small.height) or 0))
		local footerContentHeight = math.max(theme.size.control, responsive.minTarget())
		local pad = theme.space.lg
		local headerTotal = headerContentHeight + pad * 2
		local footerTotal = footerContentHeight + pad * 2

		local header = P.row(card, {
			name = "Header",
			size = scrolls and UDim2.new(1, 0, 0, headerTotal) or UDim2.new(1, 0, 0, 0),
			position = scrolls and UDim2.new(0, 0, 0, 0) or nil,
			padding = scrolls and { x = pad, y = pad } or nil,
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
		local titleLabel = P.text(titleColumn, {
			text = tostring(props.title or ""),
			role = "title",
			wrap = true,
			auto = "Y",
		})
		local descriptionLabel
		if props.description then
			descriptionLabel = P.text(titleColumn, {
				text = props.description,
				role = "small",
				color = theme.color.textSecondary,
				wrap = true,
				auto = "Y",
			})
		end

		local handle = { card = card, scrim = scrim, closed = false }
		local unbindResponsive

		function handle.close(confirmed)
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
			if confirmed ~= true and props.onClose then pcall(props.onClose) end
		end

		local function relayout()
			if handle.closed then return end
			local isSheet = responsive.mode == "sheet"
			local curWidest = math.max(responsive.viewport.X - theme.space.lg * 2, theme.size.modalMin)
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
				or UDim2.new(0.5, 0, 0.5, math.floor((responsive.inset.Y - curObstruction) / 2))
			card.Size = isSheet
				and UDim2.new(1, -theme.space.md * 2, 0, scrolls and curHeight or 0)
				or UDim2.new(0, util.clamp(props.width or theme.size.modal, theme.size.modalMin, curWidest),
					0, scrolls and curHeight or 0)
		end

		unbindResponsive = dispose.add(responsive.changed:connect(relayout), "modal layout")
		card.Destroying:Connect(unbindResponsive)

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
				padding = { x = pad, y = pad },
				bg = theme.color.surface,
				gap = theme.space.sm,
				alignX = "Right",
			})
			P.frame(card, {
				name = "FooterDivider",
				size = UDim2.new(1, 0, 0, theme.stroke.hair),
				position = UDim2.new(0, 0, 1, -footerTotal),
				bg = theme.color.borderSubtle,
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

		if scrolls then
			local divider = card:FindFirstChild("FooterDivider")
			local function fitHeader()
				if handle.closed or titleLabel.AbsoluteSize.X <= theme.size.icon then return end
				local titleHeight = math.max(theme.text.title.height, math.ceil(titleLabel.TextBounds.Y))
				local descriptionHeight = descriptionLabel
					and (theme.space.hair + math.max(theme.text.small.height, math.ceil(descriptionLabel.TextBounds.Y))) or 0
				local measured = math.max(closeDiameter, titleHeight + descriptionHeight) + pad * 2
				header.Size = UDim2.new(1, 0, 0, measured)
				handle.scroll.instance.Position = UDim2.fromOffset(0, measured)
				handle.scroll.instance.Size = UDim2.new(1, 0, 1, -(measured + footerTotal))
				if divider then divider.Position = UDim2.new(0, 0, 1, -footerTotal) end
			end
			titleLabel:GetPropertyChangedSignal("TextBounds"):Connect(fitHeader)
			if descriptionLabel then descriptionLabel:GetPropertyChangedSignal("TextBounds"):Connect(fitHeader) end
			fitHeader()
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
				modal.close(true)
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
		clock.delay(theme.duration("fast"), function()
			if not modal.closed then field.focus() end
		end)

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

		-- The outer viewport owns both axes. Code keeps its indentation and long
		-- lines stay reachable instead of being clipped by an auto-height child.
		modal.scroll.instance.AutomaticCanvasSize = Enum.AutomaticSize.XY
		modal.scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY
		modal.scroll.instance.BackgroundColor3 = theme.color.codeSurface
		modal.scroll.instance.BackgroundTransparency = 0
		local body = P.frame(modal.content, {
			name = "CodeBody",
			size = UDim2.fromOffset(0, 0),
			auto = "XY",
			bg = theme.color.codeSurface,
		})
		modal.content.Size = UDim2.fromOffset(0, 0)
		modal.content.AutomaticSize = Enum.AutomaticSize.XY
		P.text(body, {
			name = "CodeText",
			text = tostring(props.code or ""),
			role = "mono",
			line = theme.line.normal,
			color = theme.color.codeText,
			size = UDim2.fromOffset(0, 0),
			wrap = false,
			auto = "XY",
			align = "Left",
			padding = { x = theme.space.sm, y = theme.space.md },
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
			responsive.viewport.Y - margin - responsive.inset.Y - responsive.bottomObstruction())

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
		scale.Scale = responsive.reduceMotion and 1 or theme.scale.enter

		local handle = { card = card, scrim = scrim, closed = false, width = width, height = height }
		local unbindResponsive
		local function relayout()
			if handle.closed then return end
			local usableWidth = math.max(theme.size.control, responsive.viewport.X - margin)
			local usableHeight = math.max(theme.size.control, responsive.viewport.Y - margin
				- responsive.inset.Y - responsive.bottomObstruction())
			handle.width = math.min(props.width or theme.size.dialog, usableWidth)
			handle.height = math.min(props.height or theme.size.dialogTall, usableHeight)
			card.Size = UDim2.fromOffset(handle.width, handle.height)
			card.Position = UDim2.new(0.5, 0, 0.5,
				math.floor((responsive.inset.Y - responsive.bottomObstruction()) / 2))
		end
		unbindResponsive = dispose.add(responsive.changed:connect(relayout), "dialog layout")
		card.Destroying:Connect(unbindResponsive)
		relayout()

		function handle.close()
			if handle.closed then return end
			handle.closed = true
			if unbindResponsive then unbindResponsive() end
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
			local maxH = math.max(rowHeight, spaceAbove)
			bodyHeight = math.min(bodyHeight, maxH)
			anchorY = targetY - theme.space.xxs - bodyHeight
		else
			local maxH = math.max(rowHeight, spaceBelow)
			bodyHeight = math.min(bodyHeight, maxH)
			anchorY = below
		end

		anchorY = util.clamp(anchorY, topLimit, math.max(topLimit, bottomLimit - bodyHeight))
		local maxWidth = math.max(theme.size.control, layerSize.X - theme.space.sm * 2)
		width = math.min(width, maxWidth)
		local anchorX = util.clamp(targetX, theme.space.sm, math.max(theme.space.sm, layerSize.X - width - theme.space.sm))

		local card = P.frame(scrim, {
			name = "Menu",
			size = UDim2.fromOffset(width, bodyHeight),
			position = UDim2.fromOffset(anchorX, anchorY),
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.lg,
			zIndex = theme.z.dropdown + 1,
			clip = true,
		})
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = responsive.reduceMotion and 1 or theme.scale.enter

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
					truncate = true,
					layoutOrder = 1,
				})
				title.Size = UDim2.new(1, 0, 0, theme.text.bodyStrong.height)
				if option.subtitle then
					local sub = P.text(headRow, {
						text = tostring(option.subtitle or ""),
						role = "caption",
						color = theme.color.textTertiary,
						truncate = true,
						layoutOrder = 2,
					})
					sub.Size = UDim2.new(1, 0, 0, theme.text.caption.height)
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
				P.corner(button, theme.radius.md)
				local focusStroke = P.stroke(button, theme.color.accentBorder)
				focusStroke.Transparency = 1

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
						size = UDim2.fromOffset(0, theme.text.caption.height + theme.space.hair * 2),
						bg = theme.color.surfaceRaised,
						radius = theme.radius.xs,
						padding = { x = theme.space.xs, y = theme.space.hair },
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

				local hovered, focused, pressed = false, false, false
				local function paint()
					if handle.closed then return end
					local active = option.selected or hovered or focused or pressed
					P.animate(button, pressed and "press" or "hover", {
						BackgroundTransparency = active and 0 or 1,
						BackgroundColor3 = (pressed or option.selected) and theme.color.surfaceActive or theme.color.surfaceHover,
					})
					P.animate(focusStroke, "hover", { Transparency = focused and 0 or 1 })
				end
				button.MouseEnter:Connect(function() hovered = true paint() end)
				button.MouseLeave:Connect(function() hovered = false pressed = false paint() end)
				button.SelectionGained:Connect(function() focused = true paint() end)
				button.SelectionLost:Connect(function() focused = false pressed = false paint() end)
				button.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.Touch then
						pressed = true
						paint()
					end
				end)
				button.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.Touch then
						pressed = false
						paint()
					end
				end)
				button.Activated:Connect(function()
					handle.close()
					if props.onSelect then pcall(props.onSelect, option.value ~= nil and option.value or option.label, option) end
				end)
			end
		end

		M.open[#M.open + 1] = handle
		local enter = P.animate(scale, "enter", { Scale = 1 })
		enter.Completed:Connect(function()
			if not handle.closed then scale.Scale = 1 end
		end)
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
