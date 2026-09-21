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

	local layingOutToasts = false
	local function layoutToasts()
		if layingOutToasts or not M.toastColumn or not M.toastColumn.Parent then return end
		layingOutToasts = true
		local narrow = responsive.isNarrow()
		local bounds = responsive.usableRect(M.layer, narrow and theme.space.md or theme.space.lg)
		local width = math.max(1, math.min(theme.size.modal, bounds.width))
		M.toastColumn.Size = UDim2.new(0, width, 0, 0)
		M.toastColumn.AnchorPoint = narrow and Vector2.new(0.5, 0) or Vector2.new(1, 0)
		M.toastColumn.Position = UDim2.fromOffset(math.floor(bounds.x + bounds.width * (narrow and 0.5 or 1)), bounds.y)
		local minimum = 0
		for _, entry in ipairs(M.toasts) do
			entry.measure(width)
			minimum = minimum + entry.minimum
		end
		-- Count the actual title, message and action heights. Three tall actionable
		-- notices cannot share the budget of three one-line status messages.
		while #M.toasts > TOAST_LIMIT or (#M.toasts > 1 and minimum + (#M.toasts - 1) * theme.space.sm > bounds.height) do
			local oldest = M.toasts[1]
			minimum = minimum - oldest.minimum
			oldest.close(true)
		end
		local spare = math.max(0, bounds.height - minimum - math.max(0, #M.toasts - 1) * theme.space.sm)
		for index, entry in ipairs(M.toasts) do
			local extra = math.min(math.max(0, entry.wanted - entry.minimum), math.floor(spare / (#M.toasts - index + 1)))
			spare = spare - extra
			entry.layout(math.max(0, math.min(bounds.height, entry.minimum + extra)), width)
		end
		layingOutToasts = false
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

		layoutToasts()
		local unbindToasts = dispose.add(responsive.changed:connect(layoutToasts), "toast layout")
		M.toastColumn.Destroying:Connect(unbindToasts)

		-- Escape closes the topmost surface. Bound once, on the layer's lifetime.
		local unbindEscape = dispose.connection(env.uis.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.ButtonB then return end
			local topmost = M.open[#M.open]
			if topmost and topmost.dismissable ~= false then topmost.close() end
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

	function M.toast(text, tone, seconds, options)
		if not ensure() then return nil end
		options = options or {}

		local toneKey = tone or "info"
		if toneKey == "danger" then toneKey = "bad" end
		if toneKey == "success" then toneKey = "good" end
		local toneColor = theme.toneColor(toneKey)
		local pad = theme.space.md
		local closeSize = math.max(theme.size.controlSmall, responsive.minTarget())
		local badgeSize = theme.size.avatar
		local inset = pad + badgeSize + theme.space.sm
		local trailing = pad + closeSize + theme.space.xs
		local titleText = util.trim(tostring(options.title or ""))
		local actionable = type(options.onActivate) == "function"
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
			size = UDim2.new(1, 0, 0, theme.text.small.height),
			wrap = true,
			auto = "Y",
			zIndex = theme.z.toast + 1,
		})
		local title
		if titleText ~= "" then
			title = P.text(card, { name = "ToastTitle", text = titleText, role = "label", color = theme.color.text,
				truncate = true, zIndex = theme.z.toast + 1 })
		end

		local entry = { card = card, slot = slot, closed = false }
		local hovered, focused = false, false
		local remaining = math.max(0, seconds or TOAST_SECONDS)
		local started = clock.ms()
		local generation = 0
		local action, close
		local headerHeight, footerHeight, bodyHeight
		function entry.measure(width)
			closeSize = math.max(theme.size.controlSmall, responsive.minTarget())
			trailing = pad + closeSize + theme.space.xs
			headerHeight = math.max(badgeSize, closeSize, theme.text.small.height)
			footerHeight = actionable and (closeSize + theme.space.xs) or 0
			local measured = P.measureText(label.Text, { role = "small", width = math.max(1, width - inset - trailing - theme.size.scrollbar) })
			bodyHeight = math.max(theme.text.small.height, label.TextBounds.Y > 0 and math.ceil(label.TextBounds.Y) or measured.Y)
			-- Centre the label itself inside the reading area, including before the
			-- engine publishes TextBounds. A taller viewport around a short label
			-- otherwise leaves the text above the icon's centre line.
			label.Size = UDim2.new(1, 0, 0, bodyHeight)
			entry.minimum = pad * 2 + headerHeight + footerHeight + (title and (theme.space.xs + theme.text.small.height) or 0)
			entry.wanted = pad * 2 + footerHeight + (title and (headerHeight + theme.space.xs) or 0)
				+ math.max(title and 0 or headerHeight, math.min(bodyHeight, theme.text.small.height * 5))
		end
		function entry.layout(height, width)
			if entry.closed then return end
			slot.Size = UDim2.new(1, 0, 0, height)
			local mainHeight = math.max(0, height - pad * 2 - footerHeight)
			local topHeight = title and math.min(headerHeight, mainHeight) or mainHeight
			indicator.Position = UDim2.fromOffset(pad, pad + math.max(0, (topHeight - badgeSize) / 2))
			close.instance.Size = UDim2.fromOffset(closeSize, closeSize)
			close.instance.Position = UDim2.new(1, -pad, 0, pad + math.max(0, (topHeight - closeSize) / 2))
			local contentWidth = math.max(1, width - inset - trailing)
			local messageY, messageHeight
			if title then
				title.Size = UDim2.fromOffset(contentWidth, topHeight)
				title.Position = UDim2.fromOffset(inset, pad)
				messageY = pad + topHeight + theme.space.xs
				messageHeight = math.max(0, mainHeight - topHeight - theme.space.xs)
			else
				messageHeight = math.min(bodyHeight, mainHeight)
				messageY = pad + (mainHeight - messageHeight) / 2
			end
			message.instance.Position = UDim2.fromOffset(inset, messageY)
			message.instance.Size = UDim2.fromOffset(contentWidth, messageHeight)
			if action then
				action.instance.Position = UDim2.fromOffset(inset, math.max(pad, height - pad - closeSize))
				action.instance.Size = UDim2.fromOffset(contentWidth, closeSize)
			end
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(layoutToasts)

		function entry.close(immediate)
			if entry.closed then return end
			entry.closed = true
			generation = generation + 1
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) break end
			end
			if immediate then slot:Destroy()
			else
				-- Leave the list before fading, so a dismissed card does not reserve an
				-- invisible row or push a new toast past the screen's safe bounds.
				local origin, size = slot.AbsolutePosition, slot.AbsoluteSize
				local layerOrigin = M.layer.AbsolutePosition
				slot.Parent = M.layer
				slot.Size = UDim2.fromOffset(size.X, size.Y)
				slot.Position = UDim2.fromOffset(origin.X - layerOrigin.X, origin.Y - layerOrigin.Y)
				card.Active, card.Selectable = false, false
				if action then action.instance.Active, action.instance.Selectable = false, false end
				P.animate(group, "exit", {
					GroupTransparency = 1,
					Position = UDim2.fromOffset(0, responsive.reduceMotion and 0 or -theme.space.xs),
				}, function() slot:Destroy() end)
			end
			layoutToasts()
		end
		slot.Destroying:Connect(function()
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) break end
			end
			entry.closed = true
			generation = generation + 1
		end)

		close = P.iconButton(card, {
			name = "DismissNotification",
			icon = "close",
			diameter = closeSize,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -pad, 0, pad),
			zIndex = theme.z.toast + 2,
			onClick = function() entry.close() end,
		})
		close.instance.ZIndex = theme.z.toast + 2
		local activating = false
		function entry.activate()
			if entry.closed or activating then return end
			activating = true
			if actionable then
				local ok, err = pcall(options.onActivate)
				if not ok then env.require("runtime/log").warn("notification", "could not open notification", err) end
			end
			entry.close()
		end
		card.Activated:Connect(entry.activate)
		if actionable then
			action = P.button(card, { name = "NotificationAction", text = options.actionText or "Open",
				variant = "ghost", size = "sm", fill = true, align = "Left", zIndex = theme.z.toast + 2,
				onClick = entry.activate })
		end

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
		if action then
			action.instance.SelectionGained:Connect(focus)
			action.instance.SelectionLost:Connect(blur)
		end

		M.toasts[#M.toasts + 1] = entry
		layoutToasts()
		P.animate(group, "enter", { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
		schedule()
		return entry
	end

	-- Modals -----------------------------------------------------------------

	-- Returns a handle with `content` (a column to fill) and `close`. The caller
	-- builds the body; this owns the scrim, the card, the animation and dismissal.
	--
	-- `scroll = true` reserves a stable preferred height for forms. Short prompts
	-- fit their contents up to the same usable-room ceiling. Both have a scrolling
	-- body, so opening a keyboard never makes a field or action unreachable.
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

		local rect = responsive.usableRect(M.layer, theme.space.lg)

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

		local card = P.frame(scrim, {
			name = "Modal",
			size = UDim2.fromOffset(math.min(props.width or theme.size.modal, rect.width), math.min(props.height or 620, rect.height)),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			zIndex = theme.z.modal + 1,
			clip = true,
		})
		-- Active so clicks and touches inside the card never fall through to the dismiss button.
		card.Active = true
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = responsive.reduceMotion and 1 or theme.scale.enter

		local closeDiameter = math.max(theme.size.control, responsive.minTarget())
		local headerContentHeight = math.max(closeDiameter,
			theme.text.title.height + (props.description and (theme.space.hair + theme.text.small.height) or 0))
		local footerContentHeight = math.max(theme.size.control, responsive.minTarget())
		local pad = responsive.isMobile() and theme.space.md or theme.space.lg
		local headerTotal = headerContentHeight + pad * 2
		local footerTotal = footerContentHeight + theme.space.sm * 2

		local header = P.row(card, {
			name = "Header",
			size = UDim2.new(1, 0, 0, headerTotal),
			padding = { x = pad, y = pad },
			gap = theme.space.sm,
			alignY = "Top",
			layoutOrder = 1,
		})
		local titleScroll = P.scroll(header, {
			name = "TitleScroll",
			size = UDim2.new(1, -(props.dismissable ~= false and (closeDiameter + theme.space.sm) or 0), 1, 0),
			gap = 0,
			bar = 0,
			layoutOrder = 1,
		})
		local titleColumn = P.column(titleScroll.instance, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
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

		local handle = { card = card, scrim = scrim, closed = false, dismissable = props.dismissable ~= false }
		local unbindResponsive
		local fitChrome
		local function unregister()
			if unbindResponsive then unbindResponsive(); unbindResponsive = nil end
			for index = #M.open, 1, -1 do
				if M.open[index] == handle then table.remove(M.open, index) end
			end
		end
		scrim.Destroying:Connect(function()
			local notify = not handle.closed
			handle.closed = true
			unregister()
			if notify and props.onClose then pcall(props.onClose) end
		end)

		function handle.close(confirmed)
			if handle.closed then return end
			handle.closed = true
			unregister()
			P.animate(scale, "exit", { Scale = responsive.reduceMotion and 1 or theme.scale.enter })
			P.animate(scrim, "exit", { BackgroundTransparency = 1 }, function() scrim:Destroy() end)
			if confirmed ~= true and props.onClose then pcall(props.onClose) end
		end

		local function relayout()
			if handle.closed then return end
			local isSheet = responsive.mode == "sheet"
			local bounds = responsive.usableRect(M.layer, responsive.isMobile() and theme.space.sm
				or (isSheet and theme.space.md or theme.space.lg))
			card.AnchorPoint = isSheet and Vector2.new(0.5, 1) or Vector2.new(0.5, 0.5)
			card.Position = UDim2.fromOffset(math.floor(bounds.x + bounds.width / 2),
				math.floor(bounds.y + bounds.height * (isSheet and 1 or 0.5)))
			card.Size = UDim2.fromOffset(math.floor(isSheet and bounds.width or math.min(props.width or theme.size.modal, bounds.width)),
				math.floor(math.min(props.height or 620, bounds.height)))
			if fitChrome then fitChrome(bounds.height) end
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
		do
			handle.scroll = P.scroll(card, {
				name = "BodyScroll",
				position = UDim2.new(0, 0, 0, headerTotal),
				size = UDim2.new(1, 0, 1, -(headerTotal + footerTotal)),
				gap = theme.space.sm,
				padding = { left = pad, right = pad, top = theme.space.xxs, bottom = theme.space.sm },
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
				padding = { x = pad, y = theme.space.sm },
				bg = theme.color.surface,
				gap = theme.space.sm,
				alignX = "Right",
				wrap = true,
			})
			P.frame(card, {
				name = "FooterDivider",
				size = UDim2.new(1, 0, 0, theme.stroke.hair),
				position = UDim2.new(0, 0, 1, -footerTotal),
				bg = theme.color.borderSubtle,
			})
		end

		do
			local divider = card:FindFirstChild("FooterDivider")
			local fitting = false
			local footerEnabled = true
			local footerShown = true
			local footerLayout = handle.footer:FindFirstChildOfClass("UIListLayout")
			local bodyLayout = handle.content:FindFirstChildOfClass("UIListLayout")
			fitChrome = function(roomHeight)
				if handle.closed or fitting then return end
				fitting = true
				local roomNow = roomHeight or responsive.usableRect(M.layer, responsive.isMobile() and theme.space.sm
					or (responsive.mode == "sheet" and theme.space.md or theme.space.lg)).height
				local width = math.max(1, card.Size.X.Offset - pad * 2
					- (props.dismissable ~= false and (closeDiameter + theme.space.sm) or 0))
				local function textHeight(label, role)
					local measured = P.measureText(label.Text, { role = role, width = width }).Y
					return math.max(theme.textRole(role).height, math.ceil(label.TextBounds.Y), math.ceil(measured))
				end
				local titleHeight = textHeight(titleLabel, "title")
				if descriptionLabel then titleHeight = titleHeight + theme.space.hair + textHeight(descriptionLabel, "small") end
				local hasFooter, footerHeight = false, 0
				for _, child in ipairs(handle.footer:GetChildren()) do
					if footerEnabled and child:IsA("GuiObject") and child.Visible then
						hasFooter = true
						footerHeight = math.max(footerHeight, child.AbsoluteSize.Y, child.Size.Y.Offset)
					end
				end
				local footerBounds = footerLayout.AbsoluteContentSize
				if footerBounds then footerHeight = math.max(footerHeight, footerBounds.Y) end
				footerTotal = hasFooter and (footerHeight + theme.space.sm * 2) or 0
				local bodyBounds = bodyLayout.AbsoluteContentSize
				local bodyHeight = bodyBounds and bodyBounds.Y or handle.content.AbsoluteSize.Y
				local chromePad = responsive.isMobile() and theme.space.xs
					or (roomNow < (headerTotal + footerTotal + closeDiameter) and theme.space.xs or pad)
				local wantedHeader = math.max(closeDiameter, titleHeight) + chromePad * 2
				local preferred = props.height or (props.scroll == true and 620
					or (wantedHeader + footerTotal + bodyHeight + theme.space.sm + theme.space.xxs))
				local cardHeight = math.max(1, math.floor(math.min(preferred, roomNow)))
				local measured = math.min(cardHeight, wantedHeader, math.max(closeDiameter + chromePad * 2,
					cardHeight - footerTotal - closeDiameter))
				footerTotal = math.min(footerTotal, math.max(0, cardHeight - measured - 1))
				card.Size = UDim2.fromOffset(card.Size.X.Offset, cardHeight)
				local padding = header:FindFirstChildOfClass("UIPadding")
				padding.PaddingTop = UDim.new(0, chromePad)
				padding.PaddingBottom = UDim.new(0, chromePad)
				header.Size = UDim2.new(1, 0, 0, measured)
				handle.scroll.instance.Position = UDim2.fromOffset(0, measured)
				handle.scroll.instance.Size = UDim2.new(1, 0, 0, math.max(0, cardHeight - measured - footerTotal))
				handle.footer.Size = UDim2.new(1, 0, 0, footerTotal)
				footerShown = hasFooter
				handle.footer.Visible = footerShown
				if divider then
					divider.Visible = hasFooter
					divider.Position = UDim2.new(0, 0, 1, -footerTotal)
				end
				fitting = false
			end
			local scheduled = false
			local function scheduleFit()
				if scheduled or handle.closed then return end
				scheduled = true
				task.defer(function()
					scheduled = false
					if not handle.closed then fitChrome() end
				end)
			end
			for _, layout in ipairs({ bodyLayout, footerLayout }) do
				layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(scheduleFit)
			end
			-- A collapsed footer has no layout pass to report a child becoming visible.
			-- Observe child state directly so hiding/showing actions always returns room
			-- to the body and can revive an initially empty footer.
			local childConnections = {}
			local function unwatchChild(child)
				for _, connection in ipairs(childConnections[child] or {}) do connection:Disconnect() end
				childConnections[child] = nil
			end
			local function watchChild(child)
				if child:IsA("GuiObject") and not childConnections[child] then
					local connections = {}
					childConnections[child] = connections
					for _, property in ipairs({ "Visible", "AbsoluteSize", "Size", "LayoutOrder" }) do
						connections[#connections + 1] = child:GetPropertyChangedSignal(property):Connect(scheduleFit)
					end
				end
				scheduleFit()
			end
			for _, child in ipairs(handle.footer:GetChildren()) do watchChild(child) end
			handle.footer.ChildAdded:Connect(watchChild)
			handle.footer.ChildRemoved:Connect(function(child) unwatchChild(child); scheduleFit() end)
			handle.footer:GetPropertyChangedSignal("Visible"):Connect(function()
				if fitting or handle.closed or handle.footer.Visible == footerShown then return end
				footerEnabled = handle.footer.Visible
				scheduleFit()
			end)
			handle.footer.Destroying:Connect(function()
				for child in pairs(childConnections) do unwatchChild(child) end
			end)
			titleLabel:GetPropertyChangedSignal("TextBounds"):Connect(scheduleFit)
			if descriptionLabel then descriptionLabel:GetPropertyChangedSignal("TextBounds"):Connect(scheduleFit) end
			handle.relayout = relayout
		end

		relayout()
		M.open[#M.open + 1] = handle
		P.animate(scrim, "enter", { BackgroundTransparency = theme.opacity.scrim })
		-- Snapped on completion. A card left mid-tween sits at 0.98 for as long as it is
		-- open, which re-lays-out every label inside it at 98% of its metrics -- the same
		-- family of bug as the window's own scale, one step less visible.
		P.animate(scale, "enter", { Scale = 1 }, function()
			if not handle.closed then scale.Scale = 1 end
		end)
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
			local bounds = responsive.usableRect(M.layer, responsive.isMobile() and theme.space.sm or theme.space.lg)
			handle.width = math.min(props.width or theme.size.dialog, bounds.width)
			handle.height = math.min(props.height or theme.size.dialogTall, bounds.height)
			card.Size = UDim2.fromOffset(handle.width, handle.height)
			card.Position = UDim2.fromOffset(math.floor(bounds.x + bounds.width / 2), math.floor(bounds.y + bounds.height / 2))
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
			P.animate(scale, "exit", { Scale = responsive.reduceMotion and 1 or theme.scale.enter })
			P.animate(scrim, "exit", { BackgroundTransparency = 1 }, function() scrim:Destroy() end)
			if props.onClose then pcall(props.onClose) end
		end
		scrim.Destroying:Connect(function()
			local notify = not handle.closed
			handle.closed = true
			if unbindResponsive then unbindResponsive() end
			for index = #M.open, 1, -1 do
				if M.open[index] == handle then table.remove(M.open, index) end
			end
			if notify and props.onClose then pcall(props.onClose) end
		end)

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
		P.animate(scrim, "enter", { BackgroundTransparency = theme.opacity.scrim })
		P.animate(scale, "enter", { Scale = 1 }, function()
			if not handle.closed then scale.Scale = 1 end
		end)
		return handle
	end

	-- Anchored menu ----------------------------------------------------------

	-- Opens below the target, or above it when there is not enough room. Options are
	-- { label, value, detail, selected, tone }. A custom header supplies both its
	-- height and render callback so the reserved space matches its contents.
	function M.menu(props)
		props = props or {}
		if not ensure() then return nil end
		local mobile = responsive.isMobile()
		local target = props.target
		if not target or not target.Parent or not target.Visible then return nil end

		local scrim = P.frame(M.layer, {
			name = "MenuLayer",
			size = UDim2.fromScale(1, 1),
			bg = mobile and theme.color.scrim or nil,
			bgTransparency = mobile and theme.opacity.scrim or nil,
			zIndex = theme.z.dropdown,
		})
		local dismiss = Instance.new("TextButton", scrim)
		dismiss.Text = ""
		dismiss.BackgroundTransparency = 1
		dismiss.Size = UDim2.fromScale(1, 1)
		dismiss.AutoButtonColor = false

		local width = math.max(props.width or target.AbsoluteSize.X, theme.size.menuMin)
		if not props.width then
			for _, option in ipairs(props.options or {}) do
				local labelWidth = P.measureText(option.label or option.title or option.value or "", {
					role = option.isHeader and "bodyStrong" or "small",
				}).X
				local detailWidth = P.measureText(option.detail or option.subtitle or "", { role = "caption" }).X
				local trailing = (option.chevron or option.selected) and (theme.size.icon + theme.space.xs) or 0
				if option.shortcut then trailing = P.measureText(option.shortcut, { role = "caption" }).X + theme.space.xs * 3 end
				width = math.max(width, math.max(labelWidth, detailWidth) + trailing + theme.space.sm * 2
					+ theme.space.xs * 2 + theme.size.scrollbar + (option.icon and (theme.size.icon + theme.space.xs) or 0))
			end
		end

		-- The row height is derived from what the rows actually contain, not from a
		-- control token. An option with a detail line stacks a `small` label over a
		-- `caption` one, and the two together outgrow theme.size.row -- which is how
		-- every menu in the app ended up with its detail text overlapping the label of
		-- the row beneath it.
		local hasDetail = false
		for _, option in ipairs(props.options or {}) do
			if option.detail then hasDetail = true end
		end
		local content = theme.text.small.height
		if hasDetail then content = content + theme.text.caption.height end
		local rowHeight = math.max(props.rowHeight or theme.size.row, responsive.minTarget(), content + theme.space.xs)

		-- Measured rather than counted: a divider is one pixel and a header is its own
		-- height, and treating both as a full row made the profile menu tall enough to
		-- scroll when everything in it already fitted.
		local headerHeight = theme.text.bodyStrong.height + theme.text.caption.height + theme.space.sm
		local bodyHeight = theme.space.xs * 2
		for _, option in ipairs(props.options or {}) do
			if option.divider then
				bodyHeight = bodyHeight + 1 + theme.space.hair
			elseif option.isHeader then
				bodyHeight = bodyHeight + (option.height or headerHeight) + theme.space.hair
			else
				bodyHeight = bodyHeight + rowHeight + theme.space.hair
			end
		end
		if #(props.options or {}) > 0 then bodyHeight = bodyHeight - theme.space.hair end
		bodyHeight = math.min(bodyHeight, props.maxHeight or theme.size.menuMax)
		local menuHeader = mobile and (responsive.minTarget() + theme.space.xxs * 2) or 0
		local preferredWidth, preferredHeight = math.ceil(width), bodyHeight + menuHeader

		local card = P.frame(scrim, {
			name = "Menu",
			size = UDim2.fromOffset(width, bodyHeight),
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.lg,
			zIndex = theme.z.dropdown + 1,
			clip = true,
		})
		card.Active = true
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = responsive.reduceMotion and 1 or theme.scale.enter

		local handle = { closed = false, card = card, scrim = scrim }
		local releases = {}
		local function cleanup()
			for _, release in ipairs(releases) do release() end
			releases = {}
			for index = #M.open, 1, -1 do
				if M.open[index] == handle then table.remove(M.open, index) end
			end
		end

		function handle.close()
			if handle.closed then return end
			handle.closed = true
			cleanup()
			pcall(function() scrim:Destroy() end)
			if props.onClose then pcall(props.onClose) end
		end
		scrim.Destroying:Connect(function()
			local notify = not handle.closed
			handle.closed = true
			cleanup()
			if notify and props.onClose then pcall(props.onClose) end
		end)
		local function relayout()
			if handle.closed then return end
			if not target.Parent or not target.Visible then handle.close(); return end
			local ancestor = target.Parent
			while ancestor do
				if ancestor:IsA("GuiObject") and not ancestor.Visible then handle.close(); return end
				ancestor = ancestor.Parent
			end
			local bounds = responsive.usableRect(M.layer, theme.space.xs)
			if mobile then
				local w = math.min(bounds.width, math.max(preferredWidth, theme.size.modelPicker))
				local h = math.min(preferredHeight, bounds.height)
				card.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
				card.Position = UDim2.fromOffset(math.floor(bounds.x + (bounds.width - w) / 2),
					math.floor(bounds.y + bounds.height - h))
				return
			end
			local origin = M.layer.AbsolutePosition
			local x, y = target.AbsolutePosition.X - origin.X, target.AbsolutePosition.Y - origin.Y
			local bottom = bounds.y + bounds.height
			local belowY = y + target.AbsoluteSize.Y + theme.space.xxs
			local belowRoom = math.max(0, bottom - math.max(bounds.y, belowY))
			local aboveRoom = math.max(0, math.min(bottom, y - theme.space.xxs) - bounds.y)
			local upward = belowRoom < preferredHeight and aboveRoom > belowRoom
			local h = math.min(preferredHeight, bounds.height, upward and aboveRoom or belowRoom)
			local w = math.min(preferredWidth, bounds.width)
			local yPosition = upward and (y - theme.space.xxs - h) or belowY
			-- If neither side can show even one option, overlap the anchor within the
			-- safe rectangle. A one-pixel anchored list cannot be read or scrolled.
			if h < math.min(preferredHeight, rowHeight + theme.space.xs * 2) then
				h = math.min(preferredHeight, bounds.height)
				yPosition = y + (target.AbsoluteSize.Y - h) / 2
			end
			h = math.max(1, h)
			card.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
			card.Position = UDim2.fromOffset(math.floor(util.clamp(x, bounds.x, bounds.x + bounds.width - w)),
				math.floor(util.clamp(yPosition, bounds.y, math.max(bounds.y, bottom - h))))
		end
		releases[#releases + 1] = dispose.add(responsive.changed:connect(relayout), "menu layout")
		for _, property in ipairs({ "AbsolutePosition", "AbsoluteSize", "Visible" }) do
			releases[#releases + 1] = dispose.connection(target:GetPropertyChangedSignal(property):Connect(relayout), "menu anchor")
		end
		releases[#releases + 1] = dispose.connection(target.Destroying:Connect(handle.close), "menu target")
		local ancestor = target.Parent
		while ancestor do
			if ancestor:IsA("GuiObject") then
				releases[#releases + 1] = dispose.connection(ancestor:GetPropertyChangedSignal("Visible"):Connect(relayout), "menu visibility")
			end
			ancestor = ancestor.Parent
		end
		relayout()
		if handle.closed then return handle end

		dismiss.Activated:Connect(handle.close)

		if mobile then
			P.text(card, { name = "MenuTitle", text = props.title or "Options", role = "bodyStrong",
				position = UDim2.fromOffset(theme.space.md, 0),
				size = UDim2.new(1, -menuHeader - theme.space.md, 0, menuHeader) })
			P.iconButton(card, { name = "MenuClose", icon = "close", diameter = responsive.minTarget(),
				anchor = Vector2.new(1, 0), position = UDim2.new(1, -theme.space.xxs, 0, theme.space.xxs),
				onClick = handle.close })
			P.frame(card, { name = "MenuDivider", position = UDim2.fromOffset(0, menuHeader - theme.stroke.hair),
				size = UDim2.new(1, 0, 0, theme.stroke.hair), bg = theme.color.borderSubtle })
		end

		local list = P.scroll(card, {
			name = "Options",
			size = UDim2.new(1, 0, 1, -menuHeader),
			position = mobile and UDim2.fromOffset(0, menuHeader) or nil,
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
			elseif option.isHeader and option.render then
				local head = P.frame(list.instance, {
					name = "MenuHeader",
					size = UDim2.new(1, 0, 0, option.height or headerHeight),
					layoutOrder = index,
				})
				option.render(head)
			elseif option.isHeader then
				-- The height the menu already reserved for it, sixty lines up. This was a
				-- literal 36 against 46 pixels of content, so every menu with a header --
				-- the profile menu, the conversation menu -- drew its subtitle ten pixels
				-- into the first option below it, while the menu as a whole still reserved
				-- the correct 48 and left the difference floating at the bottom.
				local headRow = P.column(list.instance, {
					size = UDim2.new(1, 0, 0, option.height or headerHeight),
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
					size = UDim2.new(1, 0, 0, theme.text.small.height),
					truncate = true,
				})
				if option.detail then
					P.text(labelColumn, {
						text = option.detail,
						role = "caption",
						color = theme.color.textTertiary,
						size = UDim2.new(1, 0, 0, theme.text.caption.height),
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
					local shortcutWidth = P.measureText(option.shortcut, { role = "caption" }).X + theme.space.xs * 2
					local function fitShortcut()
						-- Optional key hints must not take the action label's entire width
						-- when the menu is clamped to a phone or a split-screen viewport.
						local room = card.Size.X.Offset - theme.space.xs * 2 - theme.space.sm * 2 - theme.size.scrollbar
							- (option.icon and (theme.size.icon + theme.space.xs) or 0)
						local labelRoom = math.min(theme.size.menuMin,
							P.measureText(option.label or option.value or "", { role = "small" }).X)
						keycap.Visible = room >= shortcutWidth + theme.space.xs + labelRoom
					end
					card:GetPropertyChangedSignal("Size"):Connect(fitShortcut)
					fitShortcut()
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
		P.animate(scale, "enter", { Scale = 1 }, function()
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
