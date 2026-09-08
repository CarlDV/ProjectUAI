-- The code tab: a multi-tab Luau editor the agent and the user share.
--
-- Modelled on the reference client's Code page -- a strip of tabs, a gutter, a
-- text area, a run button -- but rebuilt on this project's primitives: tabs that
-- rename in place and close with an X rather than a right-click nobody can
-- discover, a live syntax check that reports on the bar rather than in a toast
-- after the fact, and a run that goes through the same execution path as
-- run_luau (timeout, captured print, abandoned-thread honesty) rather than a
-- bare loadstring the interface can hang on.
--
-- Tabs persist to disk, so a draft survives an unload. The tool set in
-- tools/coding.lua operates on this state, which is why the state lives in a
-- module of its own rather than inside the panel -- a tool cannot reach a
-- closure, and the panel can be closed and reopened without losing anything.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local store = env.require("ui/panels/code_store")
	local coding = env.require("tools/coding")
	local M = {}

	local MAX_TABS = 10

	-- The little language label on a tab's context. Kept to the one language this
	-- client can actually execute.
	local function language()
		return "Luau"
	end

	-- Cheap syntax gate: compile without running. `loadstring` is probed at boot by
	-- caps and may be absent, in which case there is nothing to check and the bar
	-- says nothing rather than lying with a green tick.
	local function checkSyntax(code)
		if util.trim(code) == "" then return nil end
		local compile = caps.fn.loadstring
		if not compile then return nil end
		local ok, fnOrErr = pcall(compile, code)
		if ok and type(fnOrErr) == "function" then return nil end
		return tostring(select(2, pcall(compile, code)) or fnOrErr or "syntax error")
	end

	function M.new(parent)
		local panel = {}
		local connections = {}

		local column = P.column(parent, {
			name = "Code",
			size = UDim2.fromScale(1, 1),
			gap = 0,
		})

		-- Tab strip -----------------------------------------------------------

		-- The strip holds the tabs and the plus, and scrolls horizontally when there
		-- are more tabs than fit. It is a row inside a clipped frame rather than a
		-- P.scroll, because a vertical list layout is the wrong axis for tabs and the
		-- strip needs to sit beside the toolbar on one line.
		local stripHolder = P.frame(column, {
			name = "TabStrip",
			size = UDim2.new(1, 0, 0, theme.size.tab + theme.space.xs * 2),
			bg = theme.color.canvas,
			layoutOrder = 1,
		})

		local toolbar = P.row(column, {
			name = "Toolbar",
			size = UDim2.new(1, 0, 0, math.max(theme.size.control, responsive.minTarget())),
			gap = theme.space.sm,
			padding = { x = theme.space.sm },
			layoutOrder = 2,
		})

		local strip = P.row(stripHolder, {
			name = "Tabs",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.hair,
			padding = { x = theme.space.xs },
		})

		-- The editor ------------------------------------------------------------

		local holder = P.frame(column, {
			name = "EditorHolder",
			size = UDim2.new(1, 0, 1, 0),
			layoutOrder = 3,
		})
		local flex = Instance.new("UIFlexItem", holder)
		flex.FlexMode = Enum.UIFlexMode.Fill

		local surface = P.frame(holder, {
			name = "Editor",
			size = UDim2.fromScale(1, 1),
			bg = theme.color.codeSurface,
			clip = true,
		})
		P.corner(surface, 0)

		-- The gutter is a plain TextLabel whose text is rebuilt line numbers, the
		-- same approach as the reference client's, but sized and coloured from the
		-- code palette tokens so it follows the light/dark code theme setting.
		local monoRole = theme.textRole("monoSmall")
		local gutter = Instance.new("TextLabel", surface)
		gutter.Name = "Gutter"
		gutter.BackgroundTransparency = 1
		gutter.Size = UDim2.new(0, 44, 1, 0)
		gutter.Position = UDim2.new(0, 0, 0, 0)
		gutter.BackgroundColor3 = theme.color.codeBar
		gutter.BorderSizePixel = 0
		gutter.Font = monoRole.font
		if monoRole.face then pcall(function() gutter.FontFace = monoRole.face end) end
		gutter.TextSize = monoRole.size
		gutter.TextColor3 = theme.color.codeGutter
		gutter.TextXAlignment = Enum.TextXAlignment.Right
		gutter.TextYAlignment = Enum.TextYAlignment.Top
		gutter.RichText = false
		local gutterPad = Instance.new("UIPadding", gutter)
		gutterPad.PaddingTop = UDim.new(0, theme.space.sm)
		gutterPad.PaddingRight = UDim.new(0, theme.space.sm)
		gutterPad.PaddingLeft = UDim.new(0, theme.space.xxs)

		local gutterRule = P.frame(surface, {
			name = "GutterRule",
			size = UDim2.new(0, 1, 1, 0),
			position = UDim2.new(0, 44, 0, 0),
			bg = theme.color.codeBorder,
		})

		-- The text area. A real TextBox, not a rich label: the user can type here,
		-- and the agent's writes land in the same box the user is looking at.
		local box = Instance.new("TextBox", surface)
		box.Name = "CodeBox"
		box.BackgroundTransparency = 1
		box.Size = UDim2.new(1, -48, 1, 0)
		box.Position = UDim2.new(0, 48, 0, 0)
		box.Font = monoRole.font
		if monoRole.face then pcall(function() box.FontFace = monoRole.face end)
		end
		box.TextSize = monoRole.size
		box.TextColor3 = theme.color.codeText
		box.PlaceholderText = "-- Write Luau here, or ask the agent to."
		box.PlaceholderColor3 = theme.color.codeGutter
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.TextYAlignment = Enum.TextYAlignment.Top
		box.TextWrapped = false
		box.ClearTextOnFocus = false
		box.MultiLine = true
		box.Text = ""
		box.TextTruncate = Enum.TextTruncate.None
		local boxPad = Instance.new("UIPadding", box)
		boxPad.PaddingTop = UDim.new(0, theme.space.sm)
		boxPad.PaddingRight = UDim.new(0, theme.space.md)
		boxPad.PaddingBottom = UDim.new(0, theme.space.md)
		boxPad.PaddingLeft = UDim.new(0, theme.space.sm)

		-- Status bar ------------------------------------------------------------

		local bar = P.row(column, {
			name = "StatusBar",
			size = UDim2.new(1, 0, 0, theme.size.rowTight + theme.space.xxs * 2),
			gap = theme.space.sm,
			padding = { x = theme.space.sm },
			layoutOrder = 4,
		})

		local statusText = P.text(bar, {
			name = "Status",
			text = "",
			role = "monoSmall",
			color = theme.color.textTertiary,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			truncate = true,
			layoutOrder = 1,
		})

		local lineCount = P.text(bar, {
			name = "Lines",
			text = "0 lines",
			role = "monoSmall",
			color = theme.color.textTertiary,
			align = "Right",
			auto = "X",
			layoutOrder = 2,
		})
		lineCount.Size = UDim2.fromOffset(0, theme.text.monoSmall.height)

		-- Toolbar contents -------------------------------------------------------

		local runButton = P.button(toolbar, {
			name = "Run",
			text = "Run",
			variant = "primary",
			size = "sm",
			layoutOrder = 1,
			onClick = function()
				panel.run()
			end,
		})

		local copyButton = P.iconButton(toolbar, {
			name = "Copy",
			icon = "copy",
			diameter = theme.size.controlSmall,
			layoutOrder = 2,
			onClick = function()
				if util.trim(box.Text) == "" then return end
				local ok = pcall(caps.fn.clipboard, box.Text)
				overlay.toast(ok and "Copied" or "Could not reach the clipboard",
					ok and "good" or "warn", 2)
			end,
		})

		local clearButton = P.iconButton(toolbar, {
			name = "Clear",
			icon = "trash",
			diameter = theme.size.controlSmall,
			layoutOrder = 3,
			onClick = function()
				if util.trim(box.Text) == "" then return end
				overlay.confirm({
					title = "Clear this tab?",
					description = "The code in this tab is discarded. Other tabs are untouched.",
					confirmText = "Clear",
					onConfirm = function()
						box.Text = ""
					end,
				})
			end,
		})

		-- State ------------------------------------------------------------------

		local tabs = {}       -- { { id, name, code } }
		local active = nil    -- the tab object
		local order = 0
		local rebuilding = false

		local function nextOrder()
			order = order + 1
			return order
		end

		-- The strip is rebuilt rather than diffed. Ten tabs of four elements each is
		-- small enough that the teardown is invisible, and a diff here would be a
		-- second copy of the tab state to get wrong.
		local function renderStrip()
			for _, child in ipairs(strip:GetChildren()) do
				if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
					child:Destroy()
				end
			end

			for index, tab in ipairs(tabs) do
				local selected = tab == active
				local chip = P.rowButton(strip, {
					name = "Tab_" .. tab.id,
					size = UDim2.new(0, 0, 1, 0),
					height = theme.size.tab,
					auto = "X",
					bg = selected and theme.color.surfaceRaised or nil,
					radius = theme.radius.sm,
					selected = selected,
					gap = theme.space.xxs,
					padding = { x = theme.space.xs },
					layoutOrder = index,
					onClick = function()
						panel.select(tab.id)
					end,
				})

				P.text(chip.row, {
					name = "Label",
					text = tab.name,
					role = "caption",
					color = selected and theme.color.text or theme.color.textSecondary,
					auto = "X",
					truncate = true,
					layoutOrder = 1,
				})

				local close = P.iconButton(chip.row, {
					name = "Close",
					icon = "close",
					diameter = theme.size.controlSmall - theme.space.xs,
					layoutOrder = 2,
					onClick = function()
						panel.close(tab.id)
					end,
				})
				close.instance.LayoutOrder = 2

				tab.chip = chip
			end

			if #tabs < MAX_TABS then
				local add = P.iconButton(strip, {
					name = "AddTab",
					icon = "plus",
					diameter = theme.size.tab,
					layoutOrder = MAX_TABS + 1,
					onClick = function()
						panel.add()
					end,
				})
				add.instance.LayoutOrder = MAX_TABS + 1
			end
		end

		local function countLines(text)
			return select(2, tostring(text):gsub("\n", "\n")) + 1
		end

		local function renderStatus()
			local lines = countLines(box.Text)
			lineCount.Text = string.format("%d line%s  \194\183  %s",
				lines, lines == 1 and "" or "s", language())
			local problem = checkSyntax(box.Text)
			if problem then
				statusText.Text = util.ellipsis(problem, 160)
				statusText.TextColor3 = theme.color.danger
			else
				statusText.Text = active and (active.name .. "  \194\183  " .. language()) or ""
				statusText.TextColor3 = theme.color.textTertiary
			end
		end

		local function renderGutter()
			local lines = countLines(box.Text)
			local shown = math.min(lines, 400)
			local numbers = {}
			for index = 1, shown do numbers[index] = tostring(index) end
			if lines > shown then numbers[shown] = tostring(lines) end
			gutter.Text = table.concat(numbers, "\n")
		end

		local function commit()
			if rebuilding or not active then return end
			active.code = box.Text
			store.save(tabs, active and active.id or nil)
			renderStatus()
			renderGutter()
		end

		local saveDebounced = clock.debounce(commit, 0.5)

		connections[#connections + 1] = box:GetPropertyChangedSignal("Text"):Connect(function()
			if rebuilding then return end
			renderGutter()
			renderStatus()
			saveDebounced()
		end)

		-- Run --------------------------------------------------------------------

		-- The same contract as run_luau: a bounded wait, captured output, and an
		-- honest report when the timeout leaves a thread running. Reimplemented
		-- rather than dispatched through the tool because the tool's permission gate
		-- would ask the user to approve the code they just pressed Run on.
		function panel.run()
			local code = box.Text
			if util.trim(code) == "" then
				overlay.toast("Nothing to run", "warn", 2)
				return
			end

			local compile = caps.fn.loadstring
			if not compile then
				overlay.toast("This host cannot compile Luau", "bad", 3)
				return
			end

			local problem = checkSyntax(code)
			if problem then
				overlay.toast("Syntax error: " .. util.ellipsis(problem, 120), "bad", 4)
				return
			end

			local ok, fnOrErr = pcall(compile, code)
			if not ok or type(fnOrErr) ~= "function" then
				overlay.toast("Syntax error: " .. tostring(fnOrErr), "bad", 4)
				return
			end

			runButton.setText("Running")
			task.spawn(function()
				local output = coding.runWithCapture(fnOrErr, 10)
				runButton.setText("Run")
				panel.output = output
				overlay.code({
					title = active and (active.name .. "  \194\183  output") or "Output",
					code = output,
				})
				renderStatus()
			end)
		end

		-- Tab operations ----------------------------------------------------------

		function panel.select(id)
			if active and not rebuilding then active.code = box.Text end
			for _, tab in ipairs(tabs) do
				if tab.id == id then
					active = tab
					break
				end
			end
			rebuilding = true
			box.Text = active and active.code or ""
			rebuilding = false
			store.save(tabs, active and active.id or nil)
			renderStrip()
			renderStatus()
			renderGutter()
		end

		function panel.add(name, code, focus)
			if #tabs >= MAX_TABS then
				overlay.toast("Tab limit reached (" .. MAX_TABS .. ")", "warn", 2)
				return nil
			end
			local tab = {
				id = util.uid("tab"),
				name = name and name ~= "" and name or ("Tab " .. tostring(#tabs + 1)),
				code = code or "",
			}
			tabs[#tabs + 1] = tab
			store.save(tabs, tab.id)
			if focus ~= false then
				panel.select(tab.id)
			else
				renderStrip()
			end
			return tab
		end

		function panel.close(id)
			if #tabs <= 1 then
				-- One tab always remains, or the strip and the editor both point at
				-- nothing and every control in here needs a nil check.
				box.Text = ""
				active.code = ""
				store.save(tabs, active.id)
				renderStrip()
				renderStatus()
				renderGutter()
				return
			end
			local index
			for position, tab in ipairs(tabs) do
				if tab.id == id then index = position end
			end
			if not index then return end
			local wasActive = tabs[index] == active
			table.remove(tabs, index)
			if wasActive then
				local fallback = tabs[math.min(index, #tabs)]
				active = nil
				panel.select(fallback.id)
			else
				store.save(tabs, active and active.id or nil)
				renderStrip()
			end
		end

		function panel.rename(id)
			local tab
			for _, entry in ipairs(tabs) do
				if entry.id == id then tab = entry end
			end
			if not tab then return end
			overlay.prompt({
				title = "Rename this tab",
				description = "The code is untouched; only what the strip calls it changes.",
				placeholder = "tab name",
				value = tab.name,
				confirmText = "Rename",
				onConfirm = function(text)
					local trimmed = util.trim(text or "")
					if trimmed == "" then return end
					tab.name = trimmed
					store.save(tabs, active and active.id or nil)
					renderStrip()
					renderStatus()
				end,
			})
		end

		-- The bridge the tool set talks to. The store and this panel are one state:
		-- a write from a tool lands in the same box the user is looking at when the
		-- tab is open, and in the stored code when it is not.
		function panel.sync(reason)
			local stored = store.load()
			local byId = {}
			for _, tab in ipairs(stored) do byId[tab.id] = tab end

			if active then active.code = box.Text end
			tabs = stored
			active = nil
			for _, tab in ipairs(tabs) do
				if tab.id == store.activeId() then active = tab end
			end
			active = active or tabs[1]

			rebuilding = true
			box.Text = active and active.code or ""
			rebuilding = false
			renderStrip()
			renderStatus()
			renderGutter()
			if reason then log.debug("code", "synced for " .. tostring(reason)) end
		end

		store.changed:connect(function()
			if not surface.Parent then return end
			panel.sync("store")
		end)

		panel.sync("open")

		function panel.destroy()
			for _, connection in ipairs(connections) do
				pcall(function() connection:Disconnect() end)
			end
			connections = {}
		end

		panel.root = column
		panel.box = box
		return panel
	end

	return M
end
