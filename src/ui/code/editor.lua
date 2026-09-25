-- A native TextBox owns editing, hit testing, selection and IME. Its raw text
-- stays separate from the syntax layer; visible caret/selection follow native
-- byte offsets so focusing the editor never removes the syntax colours.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local store = env.require("runtime/code_store")
	local sources = env.require("runtime/script_sources")
	local lexer = env.require("runtime/code_lexer")
	local codeText = env.require("runtime/code_text")
	local metrics = env.require("ui/code/metrics")
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
		local measurements, widthCounts, maxLineWidth = {}, {}, 0
		local searchState = { query = "", options = { caseSensitive = true }, items = {}, total = 0, current = 0 }
		local caretMovedAt = clock.ms()
		local findBar, findField, findCount
		local function pinSource()
			sources.release(handle)
			if document and document.sourceId and handle.visible then
				local item = sources.pin(document.sourceId, handle)
				document.snapshotState = item and item.status or "expired"
			end
		end
		local function colorHex(color) return string.format("#%02x%02x%02x", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5)) end
		local palette = {}; for _, key in ipairs({ "keyword", "string", "number", "comment", "call" }) do palette[key] = colorHex(theme.code[key]) end
		local function lineAt(offset)
			return codeText.lineAt(cache.starts, codeText.clamp(box.Text, offset))
		end
		local function advance(index, offset)
			local line = cache.lines[index]
			return metrics.at(measurements[line], line, offset - cache.starts[index] + 1)
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
		local function matchCount()
			local cursor = math.max(1, box.CursorPosition)
			searchState.current = 0
			for i, match in ipairs(searchState.items) do
				if match.first <= cursor and match.after >= cursor then searchState.current = i; break end
				if match.first > cursor then break end
			end
			if findCount then findCount.Text = searchState.current .. " / " .. #searchState.items .. (searchState.complete == false and "+ matches (limit)" or " matches") end
		end
		local function firstMatch(offset)
			local low, high = 1, #searchState.items + 1
			while low < high do local mid = math.floor((low + high) / 2); if searchState.items[mid].after <= offset then low = mid + 1 else high = mid end end
			return low
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
				for _, mark in ipairs(row.matches or {}) do mark.Visible = false end
				if value then
					local top = theme.space.sm + (index - 1) * lineHeight
					row.number.Position, row.number.Size, row.number.Text = UDim2.fromOffset(theme.space.xs, top), UDim2.fromOffset(gutterWidth - theme.space.md, lineHeight), tostring(index)
					local left, firstByte, afterByte = metrics.window(measurements[value], value, x, scroll.instance.AbsoluteSize.X)
					row.text.Position, row.text.Size = UDim2.fromOffset(gutterWidth + theme.space.sm + left, top), UDim2.fromOffset(math.max(1, width - left), lineHeight)
					if row.source ~= value or row.spans ~= cache.spans[index] or row.first ~= firstByte or row.after ~= afterByte then
						row.text.Text = lexer.richWindow(value, cache.spans[index], palette, firstByte, afterByte - 1)
						row.source, row.spans, row.first, row.after = value, cache.spans[index], firstByte, afterByte
					end
					local start, finish = cache.starts[index], cache.starts[index] + #value
					row.matches = row.matches or {}
					local painted = 0
					for matchIndex = firstMatch(start), #searchState.items do
						local match = searchState.items[matchIndex]
						if match.first > finish or painted >= 64 then break end
						if match.after > start and painted < 64 then
							painted = painted + 1
							local mark = row.matches[painted]
							if not mark then mark = P.frame(scroll.instance, { name = "SearchMatch", bg = theme.mix(theme.color.codeSurface, theme.color.accent, 0.25), zIndex = 1 }); mark.Active = false; row.matches[painted] = mark end
							local left, right = advance(index, math.max(start, match.first)), advance(index, math.min(finish, match.after))
							mark.Position, mark.Size, mark.Visible = UDim2.fromOffset(gutterWidth + theme.space.sm + left, top), UDim2.fromOffset(math.max(3, right - left), lineHeight), true
						end
					end
					for i = painted + 1, #row.matches do row.matches[i].Visible = false end
					if selecting and selectionFirst <= finish and selectionLast > start then
						local left = advance(index, math.max(start, selectionFirst))
						local right = advance(index, math.min(finish, selectionLast))
						if selectionLast > finish then right = right + math.max(6, role.size * 0.6) end
						row.selection.Position = UDim2.fromOffset(gutterWidth + theme.space.sm + left, top)
						row.selection.Size, row.selection.Visible = UDim2.fromOffset(math.max(2, right - left), lineHeight), true
					end
				end
			end
			for i = count + 1, #pool do
				pool[i].number.Visible, pool[i].text.Visible, pool[i].selection.Visible = false, false, false
				for _, mark in ipairs(pool[i].matches or {}) do mark.Visible = false end
			end
			box.TextTransparency = #box.Text == 0 and 0 or 1
			drawCaret()
		end
		local function layout()
			if not handle.alive or layingOut then return end
			layingOut = true
			local previous = cache
			cache = lexer.scan(box.Text, cache)
			if previous ~= cache then
				for _, line in ipairs(cache.removed) do
					local measure = measurements[line]
					if measure then measure.count = measure.count - 1; widthCounts[measure.width] = (widthCounts[measure.width] or 1) - 1; if widthCounts[measure.width] <= 0 then widthCounts[measure.width] = nil end; if measure.count == 0 then measurements[line] = nil end end
				end
				for _, line in ipairs(cache.added) do
					local measure = measurements[line]
					if not measure then measure = metrics.line(line); measure.count = 0 end
					measure.count = measure.count + 1; measurements[line] = measure
					widthCounts[measure.width] = (widthCounts[measure.width] or 0) + 1; maxLineWidth = math.max(maxLineWidth, measure.width)
				end
				if (widthCounts[maxLineWidth] or 0) == 0 then maxLineWidth = 0; for value, count in pairs(widthCounts) do if count > 0 then maxLineWidth = math.max(maxLineWidth, value) else widthCounts[value] = nil end end end
				if searchState.query ~= "" then
					local found = codeText.search(box.Text, searchState.query, searchState.options)
					searchState.items, searchState.total, searchState.complete = found and found.items or {}, found and found.total or 0, found and found.complete
					matchCount()
				end
			end
			-- Match the native line advance, including its fractional spacing. A
			-- rounded-up theme height drifts by hundreds of pixels in a long file.
			local measured = P.measureText("Mg", { role = "mono", line = 1 }).Y
			lineHeight = math.max(1, measured * box.LineHeight)
			gutterWidth = math.max(theme.size.codeGutter, P.measureText(tostring(#cache.lines), { role = "mono" }).X + theme.space.lg)
			width = math.max(1, scroll.instance.AbsoluteSize.X - gutterWidth - theme.space.lg)
			width = math.max(width, maxLineWidth + theme.space.lg)
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
		local syntaxGeneration, syntaxWorker = 0, nil
		local function checkSyntax()
			syntaxGeneration = syntaxGeneration + 1; local generation = syntaxGeneration
			if syntaxWorker and task.cancel then pcall(task.cancel, syntaxWorker); syntaxWorker = nil end
			if not handle.visible or not caps.exec then handle.syntax = "Syntax checking unavailable"; return end
			handle.syntax = caps.exec and "Checking…" or "Syntax checking unavailable"
			if options.onStatus then options.onStatus(handle.syntax) end
			local revision, key = document and document.revision, document and document.id
			syntaxWorker = clock.delay(0.5, function()
				if not handle.alive or generation ~= syntaxGeneration or not document or document.id ~= key or document.revision ~= revision then return end
				local source = box.Text
				local result = util.trim(source) == "" and { ok = true, text = "Empty document" } or execution.check(source)
				if not handle.alive or generation ~= syntaxGeneration or not document or document.id ~= key or document.revision ~= revision then return end
				syntaxWorker = nil
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
		box:GetPropertyChangedSignal("CursorPosition"):Connect(function() caretMovedAt = clock.ms(); revealCursor(); matchCount(); draw(); saveView(); if options.onStatus then options.onStatus(handle.syntax) end end)
		box:GetPropertyChangedSignal("SelectionStart"):Connect(function() caretMovedAt = clock.ms(); draw(); saveView() end)
		local blink = env.run.Heartbeat:Connect(function() if handle.alive and handle.visible and focused then drawCaret() end end)
		scroll.instance:GetPropertyChangedSignal("CanvasPosition"):Connect(function() draw(); saveView() end)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(queue)
		function handle.select(doc, requestedView)
			if not requestedView then saveView() end
			restoring = true; document = doc
			pinSource()
			local view = doc and util.copy(store.view(doc.id))
			ignore = true; box.Text = doc and doc.source or ""; ignore = false
			box.TextEditable = doc ~= nil and not doc.readOnly; box.PlaceholderText = doc and (doc.readOnly and "-- Empty read-only source" or "-- Write Luau here") or "Open a file from Files or create a script with +"
			layout()
			if view then
				box.CursorPosition, box.SelectionStart = view.cursor or -1, view.selection or -1
				if view.sourceSearch then searchState.query = view.sourceSearch; local found = codeText.search(box.Text, view.sourceSearch); searchState.items, searchState.total, searchState.complete = found.items, found.total, found.complete; matchCount(); draw() end
				scroll.instance.CanvasPosition = Vector2.new(view.x or 0, view.y or 0)
				if requestedView and box.CursorPosition > 0 then
					local line = codeText.lineAt(cache.starts, codeText.clamp(box.Text, box.CursorPosition))
					scroll.instance.CanvasPosition = Vector2.new(0, math.max(0, (line - 1) * lineHeight - theme.space.sm))
				end
			end
			restoring = false
			checkSyntax()
		end
		function handle.gotoLine(line)
			if not cache then return end
			line = math.max(1, math.min(#cache.lines, math.floor(tonumber(line) or 1)))
			pcall(function() box:CaptureFocus() end)
			box.CursorPosition, box.SelectionStart = cache.starts[line], -1
			scroll.instance.CanvasPosition = Vector2.new(0, math.max(0, (line - 1) * lineHeight))
		end
		function handle.find(query, backwards, options)
			if not document or type(query) ~= "string" or query == "" then return nil, "Enter a search" end
			layout()
			searchState.options, searchState.query = options or searchState.options, query
			local result, why = codeText.search(document.source, query, searchState.options); if not result then return nil, why end
			searchState.items, searchState.total, searchState.complete = result.items, result.total, result.complete
			local cursor = codeText.clamp(box.Text, box.CursorPosition > 0 and box.CursorPosition or store.view(document.id).cursor)
			local current = backwards and #result.items or 1
			if backwards then
				local before = box.SelectionStart > 0 and math.min(cursor, box.SelectionStart) or cursor
				for i, match in ipairs(result.items) do if match.first < before then current = i else break end end
			else for i, match in ipairs(result.items) do if match.first >= cursor then current = i; break end end end
			local match = result.items[current]; searchState.current = match and current or 0
			if findCount then findCount.Text = searchState.current .. " / " .. #result.items .. (result.complete and " matches" or "+ matches (limit)") end
			if not match then draw(); return nil, "No match" end
			handle.gotoLine(codeText.lineAt(cache.starts, match.first)); box.SelectionStart, box.CursorPosition = match.first, match.after
			draw(); return true
		end
		function handle.matches() return { current = searchState.current, total = searchState.total, complete = searchState.complete ~= false } end
		function handle.indent(outdent)
			if not document or document.readOnly then return end
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
			if cache then line = codeText.lineAt(cache.starts, offset) end
			return line, codeText.column(box.Text, cache and cache.starts[line] or 1, offset)
		end
		findBar = P.frame(root, { name = "EditorFind", size = UDim2.new(1, 0, 0, common.barHeight() * 2), bg = theme.color.codeBar, visible = false, zIndex = 6 })
		findCount = P.text(findBar, { name = "FindMatchCount", text = "0 matches", role = "caption", position = UDim2.fromOffset(8, common.barHeight()), size = UDim2.new(1, -180, 0, common.barHeight()), zIndex = 7 })
		local function findNext(backwards)
			local ok, why = handle.find(findField.get(), backwards)
			if not ok then common.message(nil, why) end
		end
		findField = P.field(findBar, { name = "FindSourceText", placeholder = "Find in this file", role = "small", onSubmit = function() findNext(false) end })
		local previous = common.button(findBar, { name = "FindPrevious", text = "", icon = "arrowLeft", tight = true, fill = true, variant = "ghost", onClick = function() findNext(true) end })
		local nextButton = common.button(findBar, { name = "FindNext", text = "", icon = "arrowRight", tight = true, fill = true, variant = "ghost", onClick = function() findNext(false) end })
		local close = common.button(findBar, { name = "CloseFind", text = "", icon = "x", tight = true, fill = true, variant = "ghost", onClick = function() handle.closeFind() end })
		local caseButton, wordButton
		caseButton = common.button(findBar, { name = "FindCaseSensitive", text = "Aa: on", tight = true, onClick = function()
			searchState.options.caseSensitive = not searchState.options.caseSensitive; caseButton.setText(searchState.options.caseSensitive and "Aa: on" or "Aa: off"); findNext(false)
		end })
		wordButton = common.button(findBar, { name = "FindWholeWord", text = "Word: off", tight = true, onClick = function()
			searchState.options.wholeWord = not searchState.options.wholeWord; wordButton.setText(searchState.options.wholeWord and "Word: on" or "Word: off"); findNext(false)
		end })
		local function layoutFind()
			local target, gap, padding = common.controlHeight(), common.gap(), common.inset()
			local top = math.max(4, math.floor((common.barHeight() - target) / 2))
			local actionsWidth = target * 3 + gap * 3 + padding
			caseButton.instance.Position, caseButton.instance.Size = UDim2.new(1, -170, 0, common.barHeight() + top), UDim2.fromOffset(76, target)
			wordButton.instance.Position, wordButton.instance.Size = UDim2.new(1, -90, 0, common.barHeight() + top), UDim2.fromOffset(82, target)
			findField.shell.Position, findField.shell.Size = UDim2.fromOffset(padding, top), UDim2.new(1, -padding - actionsWidth, 0, target)
			for index, button in ipairs({ previous, nextButton, close }) do
				button.instance.Position = UDim2.new(1, -padding - target * (4 - index) - gap * (3 - index), 0, top)
				button.instance.Size = UDim2.fromOffset(target, target)
			end
		end
		findBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutFind); layoutFind()
		function handle.openFind()
			if box.SelectionStart > 0 and box.CursorPosition > 0 and box.SelectionStart ~= box.CursorPosition then
				local selected = codeText.slice(box.Text, box.SelectionStart, box.CursorPosition)
				if not selected:find("\n", 1, true) then findField.set(selected) end
			end
			findBar.Visible = true; scroll.instance.Position, scroll.instance.Size = UDim2.fromOffset(0, common.barHeight() * 2), UDim2.new(1, 0, 1, -common.barHeight() * 2)
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
			if event.kind == "source_navigation" and active and event.documentId == active.id then handle.select(active, true); return end
			if document and event.documentId == document.id and event.kind == "metadata" then pinSource(); box.TextEditable = not document.readOnly end
			if not document or not active or document.id ~= active.id then handle.select(active)
			elseif event.documentId == document.id and event.kind == "source" and event.origin ~= "typing" and box.Text ~= document.source then
				local cursor, selection = box.CursorPosition, box.SelectionStart; ignore = true; box.Text = document.source; ignore = false
				box.CursorPosition, box.SelectionStart = math.min(cursor, #box.Text + 1), math.min(selection, #box.Text + 1); queue(); checkSyntax()
			end
		end)
		function handle.destroy()
			if not handle.alive then return end; saveView(); handle.alive = false; syntaxGeneration = syntaxGeneration + 1
			sources.release(handle)
			if syntaxWorker and task.cancel then pcall(task.cancel, syntaxWorker) end
			blink:Disconnect(); findInput:Disconnect(); off(); root:Destroy()
		end
		function handle.setVisible(visible)
			if handle.visible == visible then return end
			handle.visible = visible
			pinSource()
			if visible then handle.needsLayout = nil; layout(); checkSyntax()
			else syntaxGeneration = syntaxGeneration + 1; if syntaxWorker and task.cancel then pcall(task.cancel, syntaxWorker); syntaxWorker = nil end; saveView(); caret.Visible = false; if focused then pcall(function() box:ReleaseFocus() end) end end
		end
		handle.select(store.active())
		return handle
	end
	return M
end
