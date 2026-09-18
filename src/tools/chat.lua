return function(env)
	local util = env.require("runtime/util")
	local chat = env.require("runtime/gamechat")
	local H = env.require("tools/helpers")
	local tools = {
		{
			name = "chat_send", risk = "write",
			description = "Send a message into Roblox chat. Reports a failure if no channel is available.",
			parameters = { type = "object", properties = {
				message = { type = "string", description = "Message, at most 200 characters." },
				channel = { type = "string", description = "Channel name; defaults to RBXGeneral. All/Team aliases supported." },
			}, required = { "message" } },
			run = function(args)
				for _, job in ipairs(env.require("runtime/chatloops").running()) do
					if job.kind == "bot" and job.channel == chat.channel(args.channel) then
						return H.fail("chat_bot " .. job.id .. " owns this channel's replies. Stop it with chat_loop_stop before sending manually.")
					end
				end
				local ok, channel = chat.send(args.message, args.channel)
				if not ok then return H.fail(channel) end
				return "Sent to chat [" .. channel .. "]: " .. args.message
			end,
		},
		{
			name = "chat_history", risk = "read", description = "Read recent in-game chat messages.",
			parameters = { type = "object", properties = {
				limit = { type = "integer", minimum = 1, maximum = 50 },
				sender = { type = "string", description = "Case-insensitive sender substring." },
			}, required = {} },
			run = function(args)
				local lines = {}
				local sender = util.trim(args.sender or ""):lower()
				for index = #chat.history, 1, -1 do
					local entry = chat.history[index]
					if sender == "" or entry.sender:lower():find(sender, 1, true) then
						table.insert(lines, 1, string.format("[%s] <%s>: %s", entry.channel, entry.sender, entry.text))
						if #lines >= util.clamp(args.limit or 20, 1, 50) then break end
					end
				end
				return #lines == 0 and "No recent in-game chat messages recorded." or table.concat(lines, "\n")
			end,
		},
	}
	for _, tool in ipairs(env.require("tools/chatloops")) do tools[#tools + 1] = tool end
	return tools
end
