-- Managed background chat jobs. A serial tick prevents overlapping SendAsync calls.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")
	local dispose = env.require("runtime/dispose")
	local config = env.require("runtime/config")
	local chat = env.require("runtime/gamechat")
	local sessions = env.require("agent/session")
	local permissions = env.require("agent/permissions")
	local chatbot = env.require("runtime/chatbot")
	local M = { jobs = {}, changed = signal.new("chat loops") }
	local alive, sending, nextSend = true, false, 0
	local cursor = 0
	local TOOL = { auto = "auto_chat", quiz = "quiz_bot", reply = "auto_reply", bot = "chat_bot" }
	local function normal(text)
		local clean = util.trim(tostring(text)):lower():gsub("%s+", " "):gsub("[%p]+$", "")
		return util.trim(clean)
	end
	local function publish(job)
		M.changed:fire(job)
	end
	local function finish(job, state, reason)
		if job.state ~= "running" then return end
		job.state, job.reason, job.finishedAt = state, reason, clock.ms()
		job.pending = nil
		if job.bot then
			job.bot.queue = {}
			job.bot.generating = false
		end
		publish(job)
	end
	local function active(job)
		if not alive or job.state ~= "running" then return false end
		local disabled = config.get("agent.disabledGroups", {}) or {}
		if sessions.threads[job.session.id] ~= job.session then finish(job, "stopped", "Conversation removed")
		elseif job.session.abortFlag then finish(job, "stopped", "Conversation stopped")
		elseif disabled.chat or permissions.mode() == "readonly" or permissions.ruleFor(TOOL[job.kind]) == "deny"
			or permissions.ruleFor("chat_send") == "deny" then finish(job, "stopped", "Chat disabled")
		elseif clock.ms() >= job.deadline then finish(job, "completed", "Duration reached")
		elseif job.bot and job.bot.inputs >= 2000 then finish(job, "completed", "Chatbot input budget reached") end
		return job.state == "running"
	end
	function M.list(session)
		local out = {}
		for _, job in ipairs(M.jobs) do if not session or job.session == session then out[#out + 1] = job end end
		return out
	end
	function M.running(session)
		local out = {}
		for _, job in ipairs(M.list(session)) do if job.state == "running" then out[#out + 1] = job end end
		return out
	end
	function M.stop(id, session)
		local count = 0
		for _, job in ipairs(M.list(session)) do
			if (not id or id == "all" or id == job.id) and job.state == "running" then
				finish(job, "stopped", "Stopped"); count = count + 1
			end
		end
		return count
	end
	local function number(value, default, low, high)
		value = value == nil and default or tonumber(value)
		if not value or value ~= value or value < low or value > high then return nil end
		return value
	end
	function M.start(kind, args, ctx)
		local session = ctx and ctx.session
		if not alive then return nil, "Chat loops are unloaded." end
		if not session or sessions.threads[session.id] ~= session or (ctx.depth or 0) > 0 then
			return nil, "Start chat loops from a main conversation." end
		if ctx.aborted and ctx.aborted() then return nil, "Conversation was stopped." end
		local disabled = config.get("agent.disabledGroups", {}) or {}
		if disabled.chat or permissions.mode() == "readonly" or permissions.ruleFor("chat_send") == "deny"
			or permissions.ruleFor(TOOL[kind] or "") == "deny" then return nil, "Chat is disabled." end
		if #M.running() >= 3 then return nil, "Three chat loops are already active. Stop one first." end
		local channel = chat.channel(args.channel)
		for _, job in ipairs(M.running()) do
			if job.channel == channel then return nil, "A loop already uses this channel: " .. job.id .. ". Stop it first." end
		end
		local route, reason = chat.route(channel)
		if not route then return nil, reason end
		local interval = number(args.interval, kind == "quiz" and 30 or (kind == "bot" and 5 or 15), 5, 3600)
		local duration = number(args.duration, 600, 10, 3600)
		local count = number(args.count, kind == "quiz" and type(args.questions) == "table" and #args.questions or (kind == "bot" and 100 or 10), 1, 100)
		if not interval or not duration or not count or count % 1 ~= 0 then return nil, "Invalid interval, duration, or count." end
		local job = { id = util.uid("chat"), kind = kind, session = session, channel = channel,
			state = "running", sent = 0, completed = 0, count = count, interval = interval,
			startedAt = clock.ms(), deadline = clock.ms() + duration * 1000, nextAt = clock.ms(), scores = {} }
		if kind == "auto" then
			if type(args.messages) ~= "table" or #args.messages < 1 or #args.messages > 30 then return nil, "Supply 1–30 messages." end
			job.messages = {}
			for _, text in ipairs(args.messages) do
				local clean, err = chat.validate(text)
				if not clean then return nil, err end
				job.messages[#job.messages + 1] = clean
			end
		elseif kind == "quiz" then
			if type(args.questions) ~= "table" or #args.questions < 1 or #args.questions > 30 then return nil, "Supply 1–30 questions." end
			job.questions, job.phase = {}, "question"
			for _, item in ipairs(args.questions) do
				if type(item) ~= "table" then return nil, "Each question needs a question and an answer." end
				local question, err = chat.validate(item.question)
				local answer, answerErr = chat.validate(item.answer)
				if not question or not answer then return nil, err or answerErr end
				if not chat.validate("Quiz 100: " .. question) or not chat.validate("Time's up! Answer: " .. answer) then
					return nil, "Shorten the question or answer to leave room for the quiz prefix." end
				local aliases = { normal(answer) }
				if aliases[1] == "" then return nil, "Answer needs letters or numbers." end
				if item.aliases ~= nil and (type(item.aliases) ~= "table" or #item.aliases > 10) then return nil, "Use at most 10 answer aliases." end
				for _, alias in ipairs(item.aliases or {}) do
					if not chat.validate(alias) then return nil, "Invalid answer alias." end
					if normal(alias) == "" then return nil, "Answer alias cannot be punctuation only." end
					aliases[#aliases + 1] = normal(alias)
				end
				job.questions[#job.questions + 1] = { question = question, answer = answer, aliases = aliases }
			end
		elseif kind == "reply" then
			if type(args.rules) ~= "table" or #args.rules < 1 or #args.rules > 20 then return nil, "Supply 1–20 reply rules." end
			job.rules = {}
			for _, rule in ipairs(args.rules) do
				if type(rule) ~= "table" then return nil, "Each rule needs a trigger and response." end
				local trigger, err = chat.validate(rule.trigger)
				local response, responseErr = chat.validate(rule.response)
				if not trigger or not response then return nil, err or responseErr end
				if normal(trigger) == "" then return nil, "Trigger needs letters or numbers." end
				job.rules[#job.rules + 1] = { trigger = normal(trigger), response = response, exact = rule.exact == true }
			end
		elseif kind == "bot" then
			local ok, err = chatbot.configure(job, args)
			if not ok then return nil, err end
		else return nil, "Unknown loop type." end
		-- Keep only recent finished records; running records are never evicted.
		while #M.jobs >= 20 do
			local removed = false
			for index, entry in ipairs(M.jobs) do
				if entry.state ~= "running" then table.remove(M.jobs, index); removed = true; break end
			end
			if not removed then break end
		end
		M.jobs[#M.jobs + 1] = job
		publish(job)
		return job
	end

	local disconnect = chat.received:connect(function(entry)
		if entry.outgoing or entry.sender == (env.plr and env.plr.Name) or (entry.userId and env.plr and entry.userId == env.plr.UserId)
			or not entry.userId or entry.userId <= 0 then return end
		local text = normal(entry.text)
		for _, job in ipairs(M.running()) do
			if entry.channel == job.channel and entry.at >= job.startedAt and active(job) then
				if job.kind == "bot" then chatbot.receive(job, entry)
				elseif job.kind == "quiz" and job.phase == "answer" and not job.winner and clock.ms() < job.nextAt then
					for _, answer in ipairs(job.current.aliases) do
						if text == answer then
							job.winner = { id = tostring(entry.userId), name = entry.sender }
							job.nextAt = clock.ms(); break
						end
					end
				elseif job.kind == "reply" and not job.pending and clock.ms() >= job.nextAt then
					for _, rule in ipairs(job.rules) do
						if (rule.exact and text == rule.trigger) or (not rule.exact and text:find(rule.trigger, 1, true)) then
							job.pending = rule.response; break
						end
					end
				end
			end
		end
	end)

	local function tick()
		if not alive then return end
		local now = clock.ms()
		for _, job in ipairs(M.running()) do
			if active(job) and job.kind == "bot" then chatbot.step(job, active, finish, publish) end
		end
		if sending or now < nextSend then return end
		-- Round-robin across channels so a five-second loop cannot starve another.
		for offset = 1, #M.jobs do
			local index = (cursor + offset - 1) % #M.jobs + 1
			local job = M.jobs[index]
			if job.state == "running" and now >= job.nextAt then
				local text
				if job.kind == "auto" then text = job.messages[job.completed % #job.messages + 1]
				elseif job.kind == "reply" or job.kind == "bot" then text = job.pending
				elseif job.phase == "question" then
					job.current = job.questions[job.completed % #job.questions + 1]
					text = "Quiz " .. (job.completed + 1) .. ": " .. job.current.question
				elseif job.winner then
					text = job.winner.name .. " got it right!"
				else text = "Time's up! Answer: " .. job.current.answer end
				if text then
					if job.kind == "bot" then
						if chatbot.duplicate(job, text) then
							job.pending = nil; job.bot.skipped = job.bot.skipped + 1
							job.nextAt = clock.ms() + job.interval * 1000
							publish(job); return
						end
						chatbot.reserve(job, text)
					end
					cursor = index
					sending = true
					local callOk, ok, reason = pcall(chat.send, text, job.channel)
					sending = false
					nextSend = clock.ms() + 5000
					if job.state ~= "running" or not alive then return end
					if not callOk or not ok then finish(job, "failed", tostring(callOk and reason or ok)); return end
					job.sent = job.sent + 1
					if job.kind == "bot" then chatbot.sent(job, text) end
					if job.kind == "quiz" and job.phase == "question" then
						job.phase = "answer"; job.nextAt = clock.ms() + job.interval * 1000
					else
						if job.winner then
							local winner = job.winner
							local score = job.scores[winner.id] or { name = winner.name, points = 0 }
							score.points = score.points + 1; job.scores[winner.id] = score; job.winner = nil
						end
						job.completed = job.completed + 1; job.pending = nil; job.phase = "question"
						job.nextAt = clock.ms() + job.interval * 1000
						if job.completed >= job.count then finish(job, "completed", "Finished") end
					end
					publish(job)
					return
				end
			end
		end
	end
	local stopTick = clock.interval(0.25, tick)
	dispose.add(function() alive = false; stopTick(); disconnect(); M.stop() end, "chat loops")
	local unsubscribe = sessions.anyEvent:connect(function(session, event)
		if event.kind == "cleared" or event.kind == "abort" then M.stop(nil, session) end
	end)
	dispose.add(unsubscribe, "chat loop session events")
	return M
end
