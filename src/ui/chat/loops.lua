-- One compact, global indicator; details and per-job stops live behind its label.
return function(env)
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")
	local loops = env.require("runtime/chatloops")
	local M = {}
	local function kind(job) return job.kind == "bot" and "Chatbot" or job.kind end
	function M.open(target)
		local options = {}
		for _, job in ipairs(loops.list()) do
			local score = {}
			for _, entry in pairs(job.scores) do score[#score + 1] = entry.name .. " " .. entry.points end
			options[#options + 1] = { label = kind(job) .. " · " .. job.channel .. " · " .. job.state, value = job.id,
				detail = string.format("%d/%d · %s%s", job.completed, job.count, job.session.title or "Chat",
					#score > 0 and (" · " .. table.concat(score, ", ")) or (job.reason and (" · " .. job.reason) or "")) }
		end
		if #options == 0 then options[1] = { label = "No chat loops yet", detail = "Ask UAI to start a chatbot, quiz, or auto-chat.", value = "empty" } end
		overlay.menu({ target = target, width = theme.size.menuWide, options = options, onSelect = function(id)
			if id ~= "empty" then
				local stopped = loops.stop(id)
				overlay.toast(stopped > 0 and "Chat loop stopped" or "This loop has already finished", "info", 2)
			end
		end })
	end
	function M.new(parent)
		local height = math.max(theme.size.controlSmall, responsive.minTarget())
		local shell = P.frame(parent, { name = "ChatLoops", size = UDim2.new(1, 0, 0, height), visible = false })
		local label = P.button(shell, { name = "LoopDetails", text = "Chat loops", fill = true, align = "Left", variant = "ghost", size = "sm",
			onClick = function(button) M.open(button.instance) end })
		label.instance.Size = UDim2.new(1, -theme.size.metaColumnWide, 0, height)
		P.button(shell, { name = "StopChatLoops", text = "Stop all", width = theme.size.metaColumnWide,
			position = UDim2.new(1, -theme.size.metaColumnWide, 0, 0), variant = "ghost", size = "sm",
			onClick = function() loops.stop() end })
		local function refresh()
			local active = loops.running()
			shell.Visible = #active > 0
			label.setText(#active == 1 and (kind(active[1]) .. " · " .. active[1].completed .. "/" .. active[1].count .. " · " .. active[1].channel)
				or (#active .. " chat loops running"))
		end
		local unsubscribe = loops.changed:connect(refresh)
		shell.Destroying:Connect(unsubscribe)
		refresh()
		return { shell = shell }
	end
	return M
end
