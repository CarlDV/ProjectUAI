-- Shared Roblox chat transport and bounded, deduplicated incoming history.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local dispose = env.require("runtime/dispose")
	local signal = env.require("runtime/signal")
	local M = { history = {}, received = signal.new("game chat") }
	local sequence = 0

	function M.channel(name)
		name = util.trim(tostring(name or ""))
		if name == "" or name == "All" or name == "General" then return "RBXGeneral" end
		if name == "Team" then return "RBXTeam" end
		return name
	end

	function M.validate(text)
		if type(text) ~= "string" or util.trim(text) == "" then return nil, "Message cannot be empty." end
		text = util.trim(text)
		if not util.validUtf8(text) then return nil, "Message must be valid UTF-8." end
		local count = 0
		for index = 1, #text do
			local byte = text:byte(index)
			if byte < 128 or byte >= 192 then count = count + 1 end
		end
		if count > 200 then return nil, "Keep each chat message within 200 characters." end
		return text
	end

	local function receive(sender, text, channel, userId, messageId, outgoing)
		if type(text) ~= "string" or util.trim(text) == "" then return end
		local entry = { sender = sender or "Unknown", text = util.trim(text), channel = M.channel(channel),
			userId = userId, id = messageId, at = clock.ms(), time = clock.stamp(), outgoing = outgoing == true }
		for index = #M.history, 1, -1 do
			local previous = M.history[index]
			if messageId ~= nil and messageId ~= "" and previous.id == messageId and previous.channel == entry.channel then return end
			if entry.at - previous.at <= 2000 and previous.sender == entry.sender and previous.text == entry.text
				and previous.channel == entry.channel and (previous.outgoing or entry.outgoing) then return end
		end
		sequence = sequence + 1
		entry.sequence = sequence
		M.history[#M.history + 1] = entry
		if #M.history > 100 then table.remove(M.history, 1) end
		M.received:fire(entry)
	end

	local function modernEnabled()
		local ok, enabled = pcall(function()
			return env.services.TextChatService and env.services.TextChatService.ChatVersion ~= Enum.ChatVersion.LegacyChatService
		end)
		return ok and enabled
	end
	local modern = false
	pcall(function()
		if not modernEnabled() then return end
		local service = env.services.TextChatService
		if not service or not service.MessageReceived then return end
		dispose.connection(service.MessageReceived:Connect(function(msg)
			local userId = msg.TextSource and msg.TextSource.UserId
			local name = msg.PrefixText and msg.PrefixText:gsub("<[^>]+>", ""):gsub(":$", "") or "System"
			if userId then
				pcall(function()
					local player = env.players:GetPlayerByUserId(userId)
					if player then name = player.Name end
				end)
			end
			receive(name, msg.Text, msg.TextChannel and msg.TextChannel.Name, userId, msg.MessageId)
		end), "game chat listener")
		modern = true
	end)
	if not modern then
		pcall(function()
			local events = env.services.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
			local event = events and events:FindFirstChild("OnMessageDoneFiltering")
			if event then
				dispose.connection(event.OnClientEvent:Connect(function(data)
					if type(data) == "table" then receive(data.FromSpeaker, data.Message, data.OriginalChannel, data.SpeakerUserId, data.ID) end
				end), "legacy chat listener")
			end
		end)
	end

	-- Resolve before starting a loop, and again before each send as channels can change.
	function M.route(channelName)
		local name = M.channel(channelName)
		local ok, route = pcall(function()
			local service = env.services.TextChatService
			local channels = modernEnabled() and service and service:FindFirstChild("TextChannels")
			if channels then
				local channel = channels:FindFirstChild(name)
				if not channel then return nil end
				return { name = name, send = function(text)
					local message = channel:SendAsync(text)
					if message and message.Status and message.Status ~= Enum.TextChatMessageStatus.Success then
						return false, "Chat rejected the message: " .. tostring(message.Status)
					end
					return true
				end }
			end
			local events = env.services.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
			local request = events and events:FindFirstChild("SayMessageRequest")
			if request then
				local legacy = name == "RBXGeneral" and "All" or (name == "RBXTeam" and "Team" or name)
				return { name = name, send = function(text) request:FireServer(text, legacy); return true end }
			end
		end)
		if ok and route then return route end
		return nil, "No sendable chat channel: " .. name
	end

	function M.send(text, channel)
		local clean, err = M.validate(text)
		if not clean then return false, err end
		local route, reason = M.route(channel)
		if not route then return false, reason end
		local ok, sent, failure = pcall(route.send, clean)
		if not ok or not sent then return false, tostring(ok and failure or sent) end
		receive(env.plr and env.plr.Name or "Me", clean, route.name, env.plr and env.plr.UserId, nil, true)
		return true, route.name
	end
	return M
end
