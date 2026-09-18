return function(env)
	local loops = env.require("runtime/chatloops")
	local H = env.require("tools/helpers")
	local util = env.require("runtime/util")
	local function parameters(extra, required)
		local properties = {
			channel = { type = "string", description = "Roblox chat channel, default RBXGeneral." },
			interval = { type = "number", minimum = 5, maximum = 3600, description = "Seconds between messages; quiz answer window. Default 15 (quiz 30)." },
			count = { type = "integer", minimum = 1, maximum = 100, description = "Messages/replies/quiz rounds before completing; default 10 or number of questions." },
			duration = { type = "number", minimum = 10, maximum = 3600, description = "Maximum run time in seconds, default 600." },
		}
		for key, value in pairs(extra) do properties[key] = value end
		return { type = "object", properties = properties, required = required }
	end
	local function start(kind)
		return function(args, ctx)
			local job, err = loops.start(kind, args, ctx)
			if not job then return H.fail(err) end
			return { text = string.format("Started %s loop %s in %s. %d rounds/messages, interval %gs. Runs in the background; use chat_loop_status or chat_loop_stop.",
				kind, job.id, job.channel, job.count, job.interval), data = { id = job.id, state = job.state } }
		end
	end
	return {
		{ name = "chat_bot", risk = "write", description = "Start an independent AI chatbot in Roblox chat using the currently selected provider/model. Maintains its own conversation memory and replies to new player messages without keeping this agent turn open. Batches rapid messages, ignores self/system echoes, and suppresses duplicate inputs and repeated replies. Do not also reply with chat_send. Stop/status through chat_loop_stop/chat_loop_status.",
			parameters = parameters({
				instructions = { type = "string", maxLength = 4000, description = "Chatbot personality and topic instructions. Defaults to friendly, casual, helpful conversation." },
				prefix = { type = "string", maxLength = 32, description = "Reply prefix, default [AGENT]. Use an empty string for no prefix." },
				user_ids = { type = "array", minItems = 1, maxItems = 20, items = { type = "integer", minimum = 1 }, description = "Only reply to these players; omitted means everyone except self/system/tagged bots." },
				interval = { type = "number", minimum = 5, maximum = 3600, description = "Minimum seconds between replies; default 5." },
				count = { type = "integer", minimum = 1, maximum = 100, description = "Maximum replies; default 100. Inference attempts are capped at three times this count." },
			}, {}), run = start("bot") },
		{ name = "auto_chat", risk = "write", description = "Start a background loop cycling through supplied Roblox chat messages. Returns immediately. Stop with chat_loop_stop.",
			parameters = parameters({ messages = { type = "array", minItems = 1, maxItems = 30, items = { type = "string" } } }, { "messages" }), run = start("auto") },
		{ name = "quiz_bot", risk = "write", description = "Host a quiz in Roblox chat: ask questions, detect the first correct player answer, keep scores, reveal unanswered answers, and repeat. Supply questions and answers. Returns a managed loop ID.",
			parameters = parameters({ questions = { type = "array", minItems = 1, maxItems = 30, items = { type = "object", properties = {
				question = { type = "string" }, answer = { type = "string" }, aliases = { type = "array", maxItems = 10, items = { type = "string" } },
			}, required = { "question", "answer" } } } }, { "questions" }), run = start("quiz") },
		{ name = "auto_reply", risk = "write", description = "Start keyword-based auto-replies to other players in Roblox chat. Uses supplied rules, ignores self/system messages, and sends at most one reply per interval. No ongoing inference requests.",
			parameters = parameters({ rules = { type = "array", minItems = 1, maxItems = 20, items = { type = "object", properties = {
				trigger = { type = "string" }, response = { type = "string" }, exact = { type = "boolean", description = "Match the whole message instead of a substring." },
			}, required = { "trigger", "response" } } } }, { "rules" }), run = start("reply") },
		{ name = "chat_loop_status", risk = "read", description = "List managed chat loops and independent chatbots, progress, failures, and quiz scores.",
			parameters = { type = "object", properties = { id = { type = "string" } }, required = {} },
			run = function(args)
				local lines, records = {}, {}
				for _, job in ipairs(loops.list()) do
					if not args.id or job.id == args.id then
						lines[#lines + 1] = string.format("%s | %s | %s | %s | %d/%d completed | %d sent | %s", job.id, job.kind, job.channel,
							job.state, job.completed, job.count, job.sent, job.reason or "running")
						for _, score in pairs(job.scores) do lines[#lines + 1] = score.name .. ": " .. score.points .. " points" end
						records[#records + 1] = { id = job.id, kind = job.kind, state = job.state, completed = job.completed, sent = job.sent, scores = util.deepCopy(job.scores) }
						if job.bot then
							local bot = job.bot
							local state = job.state ~= "running" and job.state or (bot.generating and "thinking" or (job.pending and "waiting to send" or "listening"))
							lines[#lines + 1] = string.format("Chatbot %s | %d requests | %d skipped | %d queued | %d dropped | %s",
								bot.model, bot.requests, bot.skipped, #bot.queue, bot.dropped, state)
							records[#records].bot = { model = bot.model, requests = bot.requests, skipped = bot.skipped,
								queued = #bot.queue, dropped = bot.dropped, generating = bot.generating }
						end
					end
				end
				return { text = #lines == 0 and "No matching chat loops." or table.concat(lines, "\n"), data = records }
			end },
		{ name = "chat_loop_stop", risk = "read", description = "Stop a managed chat loop immediately, or use id='all' to stop every chat loop. An already submitted message cannot be recalled.",
			parameters = { type = "object", properties = { id = { type = "string" } }, required = { "id" } },
			run = function(args) return "Stopped " .. loops.stop(args.id) .. " chat loop(s)." end },
	}
end
