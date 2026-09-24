-- A native TextBox owns editing, hit testing, selection and IME. Its raw text
-- stays separate from the syntax layer; visible caret/selection follow native
-- byte offsets so focusing the editor never removes the syntax colours.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local store = env.require("runtime/code_store")
	local lexer = env.require("runtime/code_lexer")
	local execution = env.require("tools/execution")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local util = env.require("runtime/util")
	local common = env.require("ui/code/common")
	local M = {}
	function M.new(parent, options)
		options = options or {}; local role = theme.text.mono
		local root = P.frame(parent, { name = "CodeEditor", size = UDim2.fromScale(1, 1), bg = theme.color.codeSurface, clip = true })
		local scroll = P.scroll(root, { name = "SourceScroll", bg = theme.color.codeSurface })
		scroll.layout:Destroy(); scroll.instance.AutomaticCanvasSize = Enum.AutomaticSize.None; scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY
		local box = Instance.new("TextBox", scroll.instance)
		box.Name, box.BackgroundTransparency, box.BorderSizePixel = "SourceInput", 1, 0
		box.MultiLine, box.ClearTextOnFocus, box.RichText, box.TextWrapped = true, false, false, false
		box.TextXAlignment, box.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
		box.Text, box.PlaceholderText, box.PlaceholderColor3 = "", "-- Write Luau here", theme.color.codeGutter
		box.Font, box.TextSize, box.LineHeight, box.TextColor3 = role.font, role.size, role.line, theme.color.codeText
		box.Active, box.Selectable, box.ZIndex = true, true, 3
		box.TextTransparency, box.TextStrokeTransparency = 0, 1
		box.CursorPosition, box.SelectionStart = -1, -1
		if role.face then pcall(function() box.FontFace = role.face end) end
		local gutter = P.frame(scroll.instance, { name = "Gutter", bg = theme.color.codeBar, zIndex = 4 })
		P.frame(gutter, { name = "GutterRule", size = UDim2.new(0, theme.stroke.hair, 1, 0), position = UDim2.new(1, -theme.stroke.hair, 0, 0), bg = theme.color.codeBorder, zIndex = 5 })
		local caret = P.frame(scroll.instance, { name = "SourceCaret", bg = theme.color.codeText, size = UDim2.fromOffset(2, role.height), zIndex = 4, visible = false })
		caret.Active, caret.Selectable = false, false
		local handle = { root = root, box = box, scroll = scroll.instance, alive = true, syntax = "", visible = true }
		local document, ignore, focused, cache, pending = nil, false, false, nil, false
		local restoring, layingOut = false, false
		local pool, lineHeight, width, gutterWidth = {}, role.height, 0, theme.size.codeGutter
		local measurements = {}
		local caretMovedAt = clock.ms()
		local findBar, findField
		local function colorHex(color) return string.format("#%02x%02x%02x", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5)) end
		local palette = {}; for _, key in ipairs({ "keyword", "string", "number", "comment" }) do palette[key] = colorHex(theme.code[key]) end
		local function lineAt(offset)
			local low, high = 1, #cache.starts
			while low < high do local mid = math.ceil((low + high) / 2); if cache.starts[mid] <= offset then low = mid else high = mid - 1 end end
			return low
		end
		local function advance(index, offset)
			return P.measureText(cache.lines[index]:sub(1, math.max(0, offset - cache.starts[index])), { role = "mono" }).X
		end
		local function drawCaret()
			local offset = box.CursorPosition
			caret.Visible = focused and handle.visible and document ~= nil and offset > 0 and (clock.ms() - caretMovedAt) % 1000 < 550
			if caret.Visible and cache then
				local index = lineAt(offset)
				caret.Position = UDim2.fromOffset(gutterWidth + theme.space.sm + advance(index, offset), theme.space.sm + (index - 1) * lineHeight)
				caret.Size = UDim2.fromOffset(2, math.max(role.size, lineHeight))
			end
		end
		local function saveView()
			if not document or restoring then return end
			local view = store.view(document.id); if not view then return end
			if box.CursorPosition > 0 then view.cursor, view.selection = box.CursorPosition, box.SelectionStart end
			view.x, view.y = scroll.instance.CanvasPosition.X, scroll.instance.CanvasPosition.Y
		end
		local function draw()
			if not handle.alive or not handle.visible or not cache then return end
			local x, y = scroll.instance.CanvasPosition.X, scroll.instance.CanvasPosition.Y
			gutter.Position = UDim2.fromOffset(x, 0); gutter.Size = UDim2.fromOffset(gutterWidth, math.max(scroll.instance.AbsoluteSize.Y, #cache.lines * lineHeight + theme.space.sm * 2))
			local first = math.max(1, math.floor(y / lineHeight) + 1 - theme.size.codeOverscan)
			local count = math.min(160, math.ceil(math.max(1, scroll.instance.AbsoluteSize.Y) / lineHeight) + theme.size.codeOverscan * 2)
			local cursor, anchor = box.CursorPosition, box.SelectionStart
			local selecting = focused and cursor > 0 and anchor > 0 and cursor ~= anchor
			local selectionFirst, selectionLast = math.min(cursor, anchor), math.max(cursor, anchor)
			for slot = 1, count do
				local row = pool[slot]
				if not row then
					row = { number = P.text(gutter, { text = "", role = "mono", color = theme.color.codeGutter, align = "Right", zIndex = 5 }),
						text = P.text(scroll.instance, { name = "SyntaxLine", text = "", role = "mono", color = theme.color.codeText, rich = true, zIndex = 2 }),
						selection = P.frame(scroll.instance, { name = "SourceSelection", bg = theme.mix(theme.color.codeSurface, theme.color.accent, 0.38), zIndex = 1, visible = false }) }
					row.text.RichText = true; row.text.TextYAlignment, row.number.TextYAlignment = Enum.TextYAlignment.Top, Enum.TextYAlignment.Top
					row.text.Active, row.number.Active = false, false
					row.selection.Active, row.selection.Selectable = false, false
					pool[slot] = row
				end
				local index = first + slot - 1; local value = cache.lines[index]
				row.number.Visible, row.text.Visible, row.selection.Visible = value ~= nil, value ~= nil, false
				if value then
					local top = theme.space.sm + (index - 1) * lineHeight
					row.number.Position, row.number.Size, row.number.Text = UDim2.fromOffset(theme.space.xs, top), UDim2.fromOffset(gutterWidth - theme.space.md, lineHeight), tostring(index)
					row.text.Position, row.text.Size = UDim2.fromOffset(gutterWidth + theme.space.sm, top), UDim2.fromOffset(width, lineHeight)
					if row.source ~= value or row.spans ~= cache.spans[index] then
						row.text.Text = #value <= 32000 and lexer.rich(value, cache.spans[index], palette) or lexer.escape(value)
						row.source, row.spans = value, cache.spans[index]
					end
					local start, finish = cache.starts[index], cache.starts[index] + #value
					if selecting and selectionFirst <= finish and selectionLast > start then
						local left = advance(index, math.max(start, selectionFirst))
						local right = advance(index, math.min(finish, selectionLast))
						if selectionLast > finish then right = right + math.max(6, role.size * 0.6) end
						row.selection.Position = UDim2.fromOffset(gutterWidth + theme.space.sm + left, top)
						row.selection.Size, row.selection.Visible = UDim2.fromOffset(math.max(2, right - left), lineHeight), true
					end
				end
			end
			for i = count + 1, #pool do pool[i].number.Visible, pool[i].text.Visible, pool[i].selection.Visible = false, false, false end
			box.TextTransparency = #box.Text == 0 and 0 or 1
			drawCaret()
		end
		local function layout()
			if not handle.alive or layingOut then return end
			layingOut = true
			cache = lexer.scan(box.Text, cache)
			-- Match the native line advance, including its fractional spacing. A
			-- rounded-up theme height drifts by hundreds of pixels in a long file.
			local measured = P.measureText("Mg", { role = "mono", line = 1 }).Y
			lineHeight = math.max(1, measured * box.LineHeight)
			gutterWidth = math.max(theme.size.codeGutter, P.measureText(tostring(#cache.lines), { role = "mono" }).X + theme.space.lg)
			width = math.max(1, scroll.instance.AbsoluteSize.X - gutterWidth - theme.space.lg)
			local nextMeasurements = {}
			for _, line in ipairs(cache.lines) do
				local measured = measurements[line]
				if not measured then measured = P.measureText(line, { role = "mono" }).X end
				nextMeasurements[line] = measured; width = math.max(width, measured + theme.space.lg)
			end
			measurements = nextMeasurements
			local height = math.max(scroll.instance.AbsoluteSize.Y - theme.space.md, #cache.lines * lineHeight + theme.space.lg)
			box.Position, box.Size = UDim2.fromOffset(gutterWidth + theme.space.sm, theme.space.sm), UDim2.fromOffset(width, height)
			scroll.instance.CanvasSize = UDim2.fromOffset(width + gutterWidth + theme.space.md, height + theme.space.md)
			local pos = scroll.instance.CanvasPosition
			scroll.instance.CanvasPosition = Vector2.new(math.min(pos.X, math.max(0, width + gutterWidth + theme.space.md - scroll.instance.AbsoluteSize.X)), math.min(pos.Y, math.max(0, height + theme.space.md - scroll.instance.AbsoluteSize.Y)))
			draw()
			layingOut = false
		end
		local function queue()
			if not handle.visible then handle.needsLayout = true; return end
			if pending then return end; pending = true
			clock.delay(0.015, function() pending = false; if handle.alive and handle.visible then layout(); if handle.revealCursor then handle.revealCursor() end end end)
		end
		local syntaxGeneration = 0
		local function checkSyntax()
			syntaxGeneration = syntaxGeneration + 1; local generation = syntaxGeneration
			handle.syntax = caps.exec and "Checking…" or "Syntax checking unavailable"
			if options.onStatus then options.onStatus(handle.syntax) end
			local source, revision, key = box.Text, document and document.revision, document and document.id
			clock.delay(0.5, function()
				if not handle.alive or generation ~= syntaxGeneration or not document or document.id ~= key or document.revision ~= revision then return end
				local result = util.trim(source) == "" and { ok = true, text = "Empty document" } or execution.check(source)
				handle.syntax = result.ok and (source == "" and "Empty document" or "Syntax valid") or result.text
				if not caps.exec then handle.syntax = "Syntax checking unavailable" end
				if options.onStatus then options.onStatus(handle.syntax) end
			end)
		end
		box:GetPropertyChangedSignal("Text"):Connect(function()
			box.TextTransparency = #box.Text == 0 and 0 or 1
			caretMovedAt = clock.ms()
			if ignore or not document then return end
			local updated, why = store.update(document.id, box.Text, { origin = "typing" })
			if not updated then ignore = true; box.Text = document.source; ignore = false; env.require("ui/overlay").toast(why, "warn"); return end
			queue(); checkSyntax()
		end)
		box.Focused:Connect(function() focused = true; caretMovedAt = clock.ms(); draw() end)
		box.FocusLost:Connect(function() focused = false; saveView(); draw() end)
		local function revealCursor()
			if restoring or not focused or not handle.visible or not document or box.CursorPosition < 1 then return end
			if not cache then return end
			local line = lineAt(box.CursorPosition)
			local x = gutterWidth + theme.space.sm + advance(line, box.CursorPosition)
			local y, pos = theme.space.sm + (line - 1) * lineHeight, scroll.instance.CanvasPosition
			local left, top = pos.X, pos.Y
			if x < left + gutterWidth + theme.space.sm then left = math.max(0, x - gutterWidth - theme.space.sm)
			elseif x > left + scroll.instance.AbsoluteSize.X - theme.space.lg then left = math.max(0, x - scroll.instance.AbsoluteSize.X + theme.space.lg) end
			if y < top then top = y elseif y + lineHeight > top + scroll.instance.AbsoluteSize.Y then top = math.max(0, y + lineHeight - scroll.instance.AbsoluteSize.Y) end
			scroll.instance.CanvasPosition = Vector2.new(left, top)
		end
		handle.revealCursor = revealCursor
		box:GetPropertyChangedSignal("CursorPosition"):Connect(function() caretMovedAt = clock.ms(); revealCursor(); draw(); saveView(); if options.onStatus then options.onStatus(handle.syntax) end end)
		box:GetPropertyChangedSignal("SelectionStart"):Connect(function() caretMovedAt = clock.ms(); draw(); saveView() end)
		local blink = env.run.Heartbeat:Connect(function() if handle.alive and handle.visible and focused then drawCaret() end end)
		scroll.instance:GetPropertyChangedSignal("CanvasPosition"):Connect(function() draw(); saveView() end)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(queue)
		function handle.select(doc)
			saveView(); restoring = true; document = doc
			local view = doc and util.copy(store.view(doc.id))
			ignore = true; box.Text = doc and doc.source or ""; ignore = false
			box.TextEditable = doc ~= nil; box.PlaceholderText = doc and "-- Write Luau here" or "Open a file from Files or create a script with +"
			layout()
			if view then
				box.CursorPosition, box.SelectionStart = view.cursor or -1, view.selection or -1
				scroll.instance.CanvasPosition = Vector2.new(view.x or 0, view.y or 0)
			end
			restoring = false
			checkSyntax()
		end
		function handle.gotoLine(line)
			if not cache then return end
			line = math.max(1, math.min(#cache.lines, tonumber(line) or 1))
			pcall(function() box:CaptureFocus() end)
			box.CursorPosition, box.SelectionStart = cache.starts[line], -1
			scroll.instance.CanvasPosition = Vector2.new(0, math.max(0, (line - 1) * lineHeight))
		end
		function handle.find(query, backwards)
			if not document or type(query) ~= "string" or query == "" then return nil, "Enter a search" end
			layout()
			local first, last
			local cursor = box.CursorPosition > 0 and box.CursorPosition or (store.view(document.id).cursor or 1)
			if backwards then
				local before = box.SelectionStart > 0 and math.min(cursor, box.SelectionStart) or cursor
				local at = 1
				while true do local a, b = document.source:find(query, at, true); if not a or a >= before then break end; first, last, at = a, b, b + 1 end
				if not first then
					at = 1; while true do local a, b = document.source:find(query, at, true); if not a then break end; first, last, at = a, b, b + 1 end
				end
			else
				first, last = document.source:find(query, math.max(1, cursor), true)
				if not first then first, last = document.source:find(query, 1, true) end
			end
			if not first then return nil, "No match" end
			local line = 1; for i, at in ipairs(cache.starts) do if at <= first then line = i else break end end
			handle.gotoLine(line); box.SelectionStart, box.CursorPosition = first, last + 1; return true
		end
		function handle.indent(outdent)
			if not document then return end
			local cursor, selection = math.max(1, box.CursorPosition), box.SelectionStart
			if not outdent and (selection < 1 or selection == cursor) then
				box.Text = box.Text:sub(1, cursor - 1) .. "\t" .. box.Text:sub(cursor)
				box.CursorPosition, box.SelectionStart = cursor + 1, -1
				queue(); return
			end
			local first, last = cursor, cursor; if selection > 0 then first, last = math.min(cursor, selection), math.max(cursor, selection) end
			local lines, starts = lexer.lines(box.Text); local a, b = 1, #lines
			local boundary = selection > 0 and last > first and last - 1 or last
			for i, at in ipairs(starts) do if at <= first then a = i end; if at <= boundary then b = i end end
			local cursorDelta, selectionDelta = 0, 0
			for i = a, b do
				local before = #lines[i]
				if outdent then lines[i] = lines[i]:sub(1, 1) == "\t" and lines[i]:sub(2) or lines[i]:gsub("^    ", "", 1) else lines[i] = "\t" .. lines[i] end
				local delta = #lines[i] - before
				if starts[i] <= cursor then cursorDelta = cursorDelta + delta end
				if selection > 0 and starts[i] <= selection then selectionDelta = selectionDelta + delta end
			end
			box.Text = table.concat(lines, "\n"); box.CursorPosition = math.max(1, cursor + cursorDelta); box.SelectionStart = selection > 0 and math.max(1, selection + selectionDelta) or -1; queue()
		end
		function handle.position()
			local offset, line = math.max(1, box.CursorPosition), 1
			if cache then for i, at in ipairs(cache.starts) do if at <= offset then line = i else break end end end
			local prefix = cache and box.Text:sub(cache.starts[line], offset - 1) or ""
			local _, characters = prefix:gsub("[^\128-\191]", "")
			return line, characters + 1
		end
		findBar = P.frame(root, { name = "EditorFind", size = UDim2.new(1, 0, 0, common.barHeight()), bg = theme.color.codeBar, visible = false, zIndex = 6 })
		local function findNext(backwards)
			local ok, why = handle.find(findField.get(), backwards)
			if not ok then common.message(nil, why) end
		end
		findField = P.field(findBar, { name = "FindSourceText", placeholder = "Find in this file", role = "small", onSubmit = function() findNext(false) end })
		local previous = common.button(findBar, { name = "FindPrevious", text = "", icon = "arrowLeft", tight = true, fill = true, variant = "ghost", onClick = function() findNext(true) end })
		local nextButton = common.button(findBar, { name = "FindNext", text = "", icon = "arrowRight", tight = true, fill = true, variant = "ghost", onClick = function() findNext(false) end })
		local close = common.button(findBar, { name = "CloseFind", text = "", icon = "x", tight = true, fill = true, variant = "ghost", onClick = function() handle.closeFind() end })
		local function layoutFind()
			local target, gap, padding = common.controlHeight(), common.gap(), common.inset()
			local top = math.max(4, math.floor((common.barHeight() - target) / 2))
			local actionsWidth = target * 3 + gap * 3 + padding
			findField.shell.Position, findField.shell.Size = UDim2.fromOffset(padding, top), UDim2.new(1, -padding - actionsWidth, 0, target)
			for index, button in ipairs({ previous, nextButton, close }) do
				button.instance.Position = UDim2.new(1, -padding - target * (4 - index) - gap * (3 - index), 0, top)
				button.instance.Size = UDim2.fromOffset(target, target)
			end
		end
		findBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutFind); layoutFind()
		function handle.openFind()
			if box.SelectionStart > 0 and box.CursorPosition > 0 and box.SelectionStart ~= box.CursorPosition then
				local selected = box.Text:sub(math.min(box.SelectionStart, box.CursorPosition), math.max(box.SelectionStart, box.CursorPosition) - 1)
				if not selected:find("\n", 1, true) then findField.set(selected) end
			end
			findBar.Visible = true; scroll.instance.Position, scroll.instance.Size = UDim2.fromOffset(0, common.barHeight()), UDim2.new(1, 0, 1, -common.barHeight())
			layout(); findField.focus()
		end
		function handle.closeFind()
			findBar.Visible = false; scroll.instance.Position, scroll.instance.Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
			layout(); if document then local view = util.copy(store.view(document.id)); pcall(function() box:CaptureFocus() end); box.CursorPosition, box.SelectionStart = view.cursor, view.selection end
		end
		local findInput = env.uis.InputBegan:Connect(function(input)
			if handle.visible and findBar.Visible and input.KeyCode == Enum.KeyCode.Escape and (env.uis:GetFocusedTextBox() == findField.instance or focused) then handle.closeFind() end
		end)
		local off = store.changed:connect(function(event)
			if not handle.alive then return end
			local active = store.active()
			if not document or not active or document.id ~= active.id then handle.select(active)
			elseif event.documentId == document.id and event.kind == "source" and event.origin ~= "typing" and box.Text ~= document.source then
				local cursor, selection = box.CursorPosition, box.SelectionStart; ignore = true; box.Text = document.source; ignore = false
				box.CursorPosition, box.SelectionStart = math.min(cursor, #box.Text + 1), math.min(selection, #box.Text + 1); queue(); checkSyntax()
			end
		end)
		function handle.destroy() if not handle.alive then return end; saveView(); handle.alive = false; syntaxGeneration = syntaxGeneration + 1; blink:Disconnect(); findInput:Disconnect(); off(); root:Destroy() end
		function handle.setVisible(visible)
			if handle.visible == visible then return end
			handle.visible = visible
			if visible then handle.needsLayout = nil; layout(); checkSyntax()
			else saveView(); caret.Visible = false; if focused then pcall(function() box:ReleaseFocus() end) end end
		end
		handle.select(store.active())
		return handle
	end
	return M
end
