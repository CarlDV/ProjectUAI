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

		local card = P.row(M.toastColumn, {
			name = "Toast",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.md,
			gap = theme.space.sm,
			padding = { x = theme.space.md, y = theme.space.sm },
			alignY = "Top",
			zIndex = theme.z.toast,
		})
		P.stroke(card, theme.color.border)
		card.BackgroundTransparency = 1

		P.statusDot(card, {
			color = theme.toneColor(tone or "info"),
			layoutOrder = 1,
			diameter = theme.size.dot,
		})

		local label = P.text(card, {
			text = tostring(text),
			role = "small",
			color = theme.color.text,
			wrap = true,
			auto = "Y",
			size = UDim2.new(0, 0, 0, 0),
			flex = "Fill",
			layoutOrder = 2,
		})

		local entry = { card = card, closed = false }

		function entry.close()
			if entry.closed then return end
			entry.closed = true
			for index, item in ipairs(M.toasts) do
				if item == entry then table.remove(M.toasts, index) end
			end
			local out = env.tween:Create(card, theme.tween("exit"), { BackgroundTransparency = 1 })
			out.Completed:Connect(function() pcall(function() card:Destroy() end) end)
			out:Play()
			env.tween:Create(label, theme.tween("exit"), { TextTransparency = 1 }):Play()
		end

		M.toasts[#M.toasts + 1] = entry
		env.tween:Create(card, theme.tween("enter"), { BackgroundTransparency = 0 }):Play()
		clock.delay(seconds or TOAST_SECONDS, entry.close)
		return entry
	end

	-- Modals -----------------------------------------------------------------

	-- Returns a handle with `content` (a column to fill) and `close`. The caller
	-- builds the body; this owns the scrim, the card, the animation and dismissal.
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
		local card = P.column(scrim, {
			name = "Modal",
			size = sheetMode
				and UDim2.new(1, -theme.space.md * 2, 0, 0)
				or UDim2.new(0, util.clamp(props.width or theme.size.modal, theme.size.modalMin, widest), 0, 0),
			auto = "Y",
			anchor = sheetMode and Vector2.new(0.5, 1) or Vector2.new(0.5, 0.5),
			position = sheetMode and UDim2.new(0.5, 0, 1, -theme.space.lg) or UDim2.fromScale(0.5, 0.5),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			gap = theme.space.md,
			padding = theme.space.lg,
			zIndex = theme.z.modal + 1,
		})
		P.stroke(card, theme.color.border)
		local scale = Instance.new("UIScale", card)
		scale.Scale = theme.scale.enter

		local header = P.row(card, {
			name = "Header",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
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

		if props.dismissable ~= false then
			local closeButton = P.iconButton(header, {
				name = "Close",
				icon = "close",
				diameter = theme.size.control,
				onClick = handle.close,
				layoutOrder = 2,
			})
			closeButton.instance.LayoutOrder = 2
			-- Clicking the scrim is the other way out. The card swallows the click,
			-- so this only fires on the area around it.
			local dismiss = Instance.new("TextButton", scrim)
			dismiss.Text = ""
			dismiss.BackgroundTransparency = 1
			dismiss.Size = UDim2.fromScale(1, 1)
			dismiss.ZIndex = theme.z.modal
			dismiss.AutoButtonColor = false
			dismiss.Activated:Connect(handle.close)
		end

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
	function M.prompt(props)
		props = props or {}
		local modal = M.modal({
			title = props.title or "Enter a value",
			description = props.description,
			width = props.width or theme.size.modal,
		})
		if not modal then return nil end

		local field = P.field(modal.content, {
			placeholder = props.placeholder or "",
			text = props.value or "",
			layoutOrder = 1,
			onSubmit = function(text)
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
				local value = util.trim(field.get())
				modal.close()
				if props.onConfirm then pcall(props.onConfirm, value) end
			end,
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
		local anchorX = target.AbsolutePosition.X - layerOrigin.X
		local below = target.AbsolutePosition.Y - layerOrigin.Y + target.AbsoluteSize.Y + theme.space.xxs
		local flip = (below + bodyHeight) > (M.layer.AbsoluteSize.Y - theme.space.md)
		local anchorY = flip
			and (target.AbsolutePosition.Y - layerOrigin.Y - bodyHeight - theme.space.xxs)
			or below

		anchorX = util.clamp(anchorX, theme.space.sm, math.max(M.layer.AbsoluteSize.X - width - theme.space.sm, theme.space.sm))

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
					icons.draw(option.icon, iconHolder, theme.size.icon, theme.color.textSecondary)
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
					local scLabel = P.text(row, {
						text = tostring(option.shortcut),
						role = "caption",
						color = theme.color.textTertiary,
						auto = "X",
						layoutOrder = 3,
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
