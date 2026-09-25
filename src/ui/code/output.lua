return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local runner = env.require("tools/code_runner")
	local store = env.require("runtime/code_store")
	local common = env.require("ui/code/common")
	local overlay = env.require("ui/overlay")
	local M = {}
	function M.new(parent)
		local root = P.frame(parent, { name = "CodeOutput", size = UDim2.fromScale(1, 1) })
		local header = common.toolbar(root)
		local picker, selected = nil, store.workspace.outputRun
		local scroll = P.scroll(root, { position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 1, -common.barHeight()), padding = theme.space.sm, bg = theme.color.codeSurface })
		local label = P.text(scroll.instance, { text = "Run a document to see its output here.", role = "mono", auto = "Y", wrap = true, color = theme.color.codeText })
		local handle = { root = root, visible = true, alive = true }
		local rawOutput = label.Text
		local palette = {}; for _, key in ipairs({ "keyword", "string", "number", "comment", "call" }) do palette[key] = "#" .. theme.code[key]:ToHex() end
		label.RichText = true
		local function render()
			if not handle.alive or not handle.visible then return end
			local run
			for _, item in ipairs(runner.runs) do if item.id == selected then run = item end end
			run = run or runner.runs[#runner.runs]; if not run then return end
			selected = run.id; store.workspace.outputRun = selected; local follow = scroll.atBottom()
			local doc = run.documentId and store.resolve(run.documentId)
			picker.setText(run.name .. " · r" .. run.revision .. " · " .. run.status)
			rawOutput = "Run " .. run.id .. (doc and doc.revision ~= run.revision and ("\nRan revision " .. run.revision .. "; current revision " .. doc.revision) or "")
				.. "\n" .. (run.result and run.result.text or table.concat(run.output, "\n")) .. (#run.output == 0 and run.status ~= "running" and "\nNo printed output." or "")
			label.Text = env.require("runtime/code_lexer").highlight(rawOutput, palette)
			if follow then scroll.toBottom() end
		end
		picker = header.add("Run output", function()
			local options = {}; for i = #runner.runs, 1, -1 do local run = runner.runs[i]; options[#options + 1] = { label = run.name .. " · r" .. run.revision .. " · " .. run.status, value = run.id } end
			common.menu(picker, "Runs", options, function(key) selected = key; render() end)
		end, { flex = true })
		header.add("More", function(button) common.menu(button, "Output actions", { { label = "Copy output", value = "copy" }, { label = "Expand output", value = "expand" }, { label = "Latest run", value = "latest" } }, function(action)
			if action == "copy" then common.copy(rawOutput) elseif action == "expand" then overlay.code({ title = "Run output", code = rawOutput }) else selected = nil; render(); scroll.toBottom() end
		end) end, { icon = "ellipsis" })
		local queued = false
		local off = runner.changed:connect(function() if queued or not handle.visible then return end; queued = true; env.require("runtime/clock").delay(0.1, function() queued = false; render() end) end)
		function handle.setVisible(visible) handle.visible = visible; if visible then render() end end
		function handle.destroy() handle.alive = false; store.workspace.outputY = scroll.instance.CanvasPosition.Y; off(); root:Destroy() end
		scroll.instance.CanvasPosition = Vector2.new(0, store.workspace.outputY or 0)
		handle.render = render; render(); return handle
	end
	return M
end
