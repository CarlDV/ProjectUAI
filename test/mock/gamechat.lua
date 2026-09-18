-- A TextChatService fixture with real event semantics and observable sends.
return function(harness)
	local emitter = harness.Instance.new("TextBox").FocusLost
	local sent, channels = {}, {}
	local fixture = { sent = sent }
	function fixture.addChannel(name, send)
		channels[name] = { Name = name, SendAsync = function(_, text)
			if send then return send(text) end
			sent[#sent + 1] = { text = text, channel = name, at = harness.sandbox.DateTime.now().UnixTimestampMillis }
			return nil
		end }
	end
	fixture.addChannel("RBXGeneral")
	fixture.addChannel("RBXTeam")
	harness.services.TextChatService = { MessageReceived = emitter, FindFirstChild = function(_, name)
		if name == "TextChannels" then return { FindFirstChild = function(_, channel) return channels[channel] end } end
	end }
	function fixture.receive(text, userId, name, channel, id)
		emitter:Fire({ Text = text, TextSource = userId and { UserId = userId } or nil,
			PrefixText = name or "Player", TextChannel = { Name = channel or "RBXGeneral" }, MessageId = id })
	end
	return fixture
end
