-- The composer: prompt field, send/stop, and the row of affordances under it.
--
-- Send behaviour differs by platform on purpose. With a keyboard, Enter sends --
-- that is what everyone expects and reaching for a button breaks the typing rhythm.
-- On touch there is no Enter worth the name, so the button is the primary action and
-- the field grows instead. The expand toggle switches to a multi-line field where
-- Enter inserts a newline and only the button sends.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")

	local M = {}

	function M.new(parent, props)
		props = props or {}

		local shell = P.column(parent, {
			name = "Composer",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1),
			bg = theme.color.surface,
			gap = theme.space.xs,
			padding = { x = theme.space.md, top = theme.space.sm, bottom = theme.space.sm },
			zIndex = theme.z.raised,
		})
		P.frame(shell, {
			name = "TopRule",
			size = UDim2.new(1, theme.space.md * 2, 0, 1),
			position = UDim2.new(0, -theme.space.md, 0, 0),
			bg = theme.color.borderSubtle,
		})

		local composer = { expanded = false, busy = false }

		local inputRow = P.row(shell, {
			name = "InputRow",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			alignY = "Bottom",
			layoutOrder = 1,
		})

		local fieldHolder = P.frame(inputRow, {
			name = "FieldHolder",
			size = UDim2.new(1, -(theme.size.control + theme.space.xs), 0, 0),
			auto = "Y",
			layoutOrder = 1,
		})

		local function submit()
			local text = util.trim(composer.field.get())
			if text == "" then return end
			composer.field.clear()
			if props.onSend then props.onSend(text) end
		end

		composer.field = P.field(fieldHolder, {
			name = "Prompt",
			placeholder = props.placeholder or "Ask, or tell it what to change",
			multiline = false,
			onSubmit = function()
				if not composer.expanded then submit() end
			end,
		})

		local sendButton = P.iconButton(inputRow, {
			name = "Send",
			icon = "send",
			variant = "primary",
			diameter = theme.size.control,
			layoutOrder = 2,
			onClick = function()
				if composer.busy then
					if props.onStop then props.onStop() end
				else
					submit()
				end
			end,
		})
		sendButton.instance.LayoutOrder = 2

		-- The affordance row below carries the things a user needs occasionally: how
		-- the model will be reached, what mode permissions are in, and the two
		-- toggles that change how much the transcript shows.
		local metaRow = P.row(shell, {
			name = "Meta",
			size = UDim2.new(1, 0, 0, theme.text.caption.size + 8),
			gap = theme.space.xs,
			layoutOrder = 2,
		})

		local statusLabel = P.text(metaRow, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			truncate = true,
			layoutOrder = 1,
		})
		statusLabel.Size = UDim2.new(1, -140, 1, 0)

		local expandButton = P.button(metaRow, {
			name = "Expand",
			text = "multiline",
			variant = "ghost",
			size = "sm",
			tight = true,
			layoutOrder = 2,
			onClick = function()
				composer.setExpanded(not composer.expanded)
			end,
		})
		expandButton.instance.LayoutOrder = 2

		local clearButton = P.button(metaRow, {
			name = "Clear",
			text = "clear",
			variant = "ghost",
			size = "sm",
			tight = true,
			layoutOrder = 3,
			onClick = function()
				if props.onClear then props.onClear() end
			end,
		})
		clearButton.instance.LayoutOrder = 3

		-- Rebuilding the field is the honest way to switch MultiLine: changing the
		-- property on a live TextBox leaves its alignment and height wrong.
		function composer.setExpanded(value)
			composer.expanded = value == true
			local carried = composer.field.get()
			pcall(function() composer.field.shell:Destroy() end)
			composer.field = P.field(fieldHolder, {
				name = "Prompt",
				placeholder = props.placeholder or "Ask, or tell it what to change",
				multiline = composer.expanded,
				height = composer.expanded and (theme.size.control * 3) or nil,
				text = carried,
				onSubmit = function()
					if not composer.expanded then submit() end
				end,
			})
			expandButton.setText(composer.expanded and "single line" or "multiline")
		end

		function composer.setBusy(value)
			composer.busy = value == true
			sendButton.instance:ClearAllChildren()
			-- The primary action becomes Stop while a turn is running, in place
			-- rather than as a second control, so there is only ever one thing to
			-- press.
			local content = P.row(sendButton.instance, {
				size = UDim2.fromScale(1, 1),
				alignX = "Center",
			})
			local holder = P.frame(content, {
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			})
			if composer.busy then
				icons.stop(holder, theme.size.icon, theme.color.textOnAccent)
				sendButton.setVariant("danger")
				sendButton.instance.BackgroundColor3 = theme.color.danger
			else
				icons.send(holder, theme.size.icon, theme.color.textOnAccent)
				sendButton.setVariant("primary")
			end
		end

		function composer.setStatus(text)
			statusLabel.Text = tostring(text or "")
		end

		function composer.focus()
			composer.field.focus()
		end

		-- The keyboard covering the field is the classic mobile bug. The window moves
		-- itself; this only has to stop showing the meta row when there is no height
		-- left for it.
		responsive.changed:connect(function()
			metaRow.Visible = not responsive.isCompactHeight()
		end)
		metaRow.Visible = not responsive.isCompactHeight()

		composer.shell = shell
		composer.setBusy(false)
		return composer
	end

	return M
end
