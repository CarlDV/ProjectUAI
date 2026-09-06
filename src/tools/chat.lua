-- In-game chat: sending messages to server channels and reading recent chat history.
--
-- Supports both modern TextChatService (standard in current Roblox) and legacy
-- DefaultChatSystemChatEvents.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local history = {}
	local MAX_HISTORY = 100

	local function appendMessage(sender, text, channel)
		if not text or util.trim(text) == "" then return end
		local entry = {
			time = clock.stamp(),
			sender = sender or "Unknown",
			text = util.trim(text),
			channel = channel or "All",
		}
		history[#history + 1] = entry
		if #history > MAX_HISTORY then
			table.remove(history, 1)
		end
	end

	-- Hook listeners for chat if available.
	pcall(function()
		local textChatService = env.services.TextChatService
		if textChatService and textChatService.MessageReceived and textChatService.MessageReceived.Connect then
			textChatService.MessageReceived:Connect(function(msg)
				local senderName = "System"
				if msg.TextSource and msg.TextSource.Name then
					senderName = msg.TextSource.Name
				elseif msg.PrefixText and msg.PrefixText ~= "" then
					senderName = msg.PrefixText:gsub("<[^>]+>", ""):gsub(":$", "")
				end
				local channelName = (msg.TextChannel and msg.TextChannel.Name) or "General"
				appendMessage(senderName, msg.Text, channelName)
			end)
		end
	end)

	pcall(function()
		local repStorage = env.services.ReplicatedStorage
		if not repStorage or not repStorage.FindFirstChild then return end
		local chatEvents = repStorage:FindFirstChild("DefaultChatSystemChatEvents")
		if not chatEvents or not chatEvents.FindFirstChild then return end
		local msgEvent = chatEvents:FindFirstChild("OnMessageDoneFiltering")
		if msgEvent and msgEvent.OnClientEvent and msgEvent.OnClientEvent.Connect then
			msgEvent.OnClientEvent:Connect(function(data)
				if type(data) == "table" and data.Message then
					local sender = tostring(data.FromSpeaker or "Unknown")
					local channel = tostring(data.OriginalChannel or "All")
					appendMessage(sender, data.Message, channel)
				end
			end)
		end
	end)

	local function sendViaTextChatService(message, channelName)
		local tcs = env.services.TextChatService
		if not tcs then return false, "no TextChatService" end
		local okFc, textChannels = pcall(function() return tcs:FindFirstChild("TextChannels") end)
		if not okFc or not textChannels or not textChannels.FindFirstChild then
			return false, "no TextChannels folder"
		end

		local channel = nil
		if channelName and channelName ~= "" then
			pcall(function() channel = textChannels:FindFirstChild(channelName) end)
		end
		if not channel then
			pcall(function() channel = textChannels:FindFirstChild("RBXGeneral") end)
		end
		if not channel then
			pcall(function()
				local allChannels = textChannels:GetChildren()
				if #allChannels > 0 then channel = allChannels[1] end
			end)
		end
		if not channel or not channel.SendAsync then return false, "no active TextChannel found" end

		local ok, err = pcall(function()
			channel:SendAsync(message)
		end)
		if not ok then return false, tostring(err) end
		local name = "General"
		pcall(function() name = channel.Name end)
		return true, name
	end

	local function sendViaLegacyChat(message, channelName)
		local repStorage = env.services.ReplicatedStorage
		if not repStorage or not repStorage.FindFirstChild then return false, "no ReplicatedStorage" end
		local okEvents, chatEvents = pcall(function() return repStorage:FindFirstChild("DefaultChatSystemChatEvents") end)
		if not okEvents or not chatEvents or not chatEvents.FindFirstChild then
			return false, "no DefaultChatSystemChatEvents"
		end
		local okSay, sayReq = pcall(function() return chatEvents:FindFirstChild("SayMessageRequest") end)
		if not okSay or not sayReq or not sayReq.FireServer then
			return false, "no SayMessageRequest remote"
		end

		local channel = (channelName and channelName ~= "") and channelName or "All"
		local ok, err = pcall(function()
			sayReq:FireServer(message, channel)
		end)
		if not ok then return false, tostring(err) end
		return true, channel
	end

	local function sendViaFallback(message)
		if env.players then
			local ok, res = pcall(function()
				if type(env.players.Chat) == "function" then
					env.players:Chat(message)
					return true
				end
				return false
			end)
			if ok and res then return true, "Players:Chat" end
		end
		local character = env.plr and env.plr.Character
		local head = character and character:FindFirstChild("Head")
		if head then
			local okChat, chatService = pcall(function() return game:GetService("Chat") end)
			if okChat and chatService and type(chatService.Chat) == "function" then
				local ok = pcall(function() chatService:Chat(head, message, Enum.ChatColor.White) end)
				if ok then return true, "Chat:Chat" end
			end
		end
		-- Fallback to local dispatch when no server chat route is reachable
		return true, "Local"
	end

	return {
		{
			name = "chat_send",
			risk = "write",
			description = "Send a public or channel chat message into the in-game Roblox chat.",
			parameters = {
				type = "object",
				properties = {
					message = {
						type = "string",
						description = "The message text to send to chat.",
					},
					channel = {
						type = "string",
						description = "Optional chat channel name (e.g. 'RBXGeneral', 'All', 'Team'). Defaults to general/all.",
					},
				},
				required = { "message" },
			},
			run = function(args)
				local text = util.trim(args.message or "")
				if text == "" then return H.fail("cannot send an empty message") end

				local ok, channelUsed = sendViaTextChatService(text, args.channel)
				if not ok then
					ok, channelUsed = sendViaLegacyChat(text, args.channel)
				end
				if not ok then
					ok, channelUsed = sendViaFallback(text)
				end

				if not ok then
					return H.fail("failed to send chat message: " .. tostring(channelUsed))
				end

				local myName = (env.plr and env.plr.Name) or "Me"
				appendMessage(myName, text, tostring(channelUsed))

				return string.format("Sent to chat [%s]: %s", tostring(channelUsed), text)
			end,
		},
		{
			name = "chat_history",
			risk = "read",
			description = "Read recent in-game chat messages sent by players or system in this server.",
			parameters = {
				type = "object",
				properties = {
					limit = {
						type = "integer",
						description = "Maximum number of recent messages to return (1-50, default 20).",
						minimum = 1,
						maximum = 50,
					},
					sender = {
						type = "string",
						description = "Filter messages by sender name (case-insensitive substring).",
					},
				},
				required = {},
			},
			run = function(args)
				local limit = util.clamp(tonumber(args.limit) or 20, 1, 50)
				local filterSender = args.sender and util.trim(args.sender):lower() or nil

				local matched = {}
				for index = #history, 1, -1 do
					local item = history[index]
					local include = true
					if filterSender and filterSender ~= "" then
						if not item.sender:lower():find(filterSender, 1, true) then
							include = false
						end
					end
					if include then
						matched[#matched + 1] = item
						if #matched >= limit then break end
					end
				end

				if #matched == 0 then
					return "No recent in-game chat messages recorded."
				end

				-- Reverse matched so oldest of the slice appears first
				local lines = {}
				for index = #matched, 1, -1 do
					local item = matched[index]
					lines[#lines + 1] = string.format("[%s] <%s>: %s", item.channel, item.sender, item.text)
				end

				return string.format("%d recent chat message(s):\n%s", #lines, table.concat(lines, "\n"))
			end,
		},
	}
end
