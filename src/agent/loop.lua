-- The turn loop.
--
-- Send the conversation, run whatever tools come back, repeat until the model
-- answers in prose or a limit stops it. Everything around that -- provider
-- failover, compaction, repeat detection, usage, the event stream -- is here
-- because it all has to interleave with the same loop, and splitting it would
-- mean threading state through five modules to achieve the same thing.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local prompt = env.require("agent/prompt")
	local registry = env.require("agent/registry")
	local usage = env.require("agent/usage")
	local hooks = env.require("agent/hooks")
	local providers = env.require("provider/registry")
	local openai = env.require("provider/openai")

	local M = {}

	local function callSignature(calls)
		local parts = {}
		for _, call in ipairs(calls or {}) do
			local fn = call["function"] or {}
			parts[#parts + 1] = tostring(fn.name) .. "(" .. tostring(fn.arguments) .. ")"
		end
		table.sort(parts)
		return table.concat(parts, "|")
	end

	-- One completion, walking the provider chain. Returns result, error, record.
	--
	-- A provider that fails is demoted by the registry and the next one is tried,
	-- so a rate-limited primary does not end the turn. Only when every candidate
	-- has failed does the turn fail, and the message names the first failure --
	-- which is almost always the informative one.
	local function complete(session, request)
		local chain = providers.chain()
		if #chain == 0 then
			return nil, "No provider is configured. Open the Providers panel and add one."
		end

		local firstError
		for index, record in ipairs(chain) do
			if session.aborted() then return nil, "aborted" end
			if index > 1 then
				session.emit("provider:switch", {
					from = chain[index - 1].label,
					to = record.label,
					reason = firstError,
				})
			end

			local payload = { record = record, request = request, session = session }
			hooks.run("preRequest", payload)

			session.emit("request:start", {
				provider = record.label,
				providerId = record.id,
				model = record.model,
				attempt = index,
				messages = #request.messages,
				stream = request.stream,
			})

			local started = clock.ms()
			local result, err = openai.complete(record, {
				messages = payload.request.messages,
				tools = payload.request.tools,
				toolChoice = payload.request.toolChoice,
				stream = payload.request.stream,
				temperature = payload.request.temperature,
				maxTokens = payload.request.maxTokens,
				extra = payload.request.extra,
				aborted = session.aborted,
				onRetry = function(info)
					session.emit("request:retry", {
						provider = record.label,
						attempt = info.attempt,
						attempts = info.attempts,
						wait = info.wait,
						status = info.status,
						reason = info.reason,
					})
				end,
				onFrame = request.onFrame,
			})

			if result then
				session.emit("request:done", {
					provider = record.label,
					model = result.model or record.model,
					ms = clock.since(started),
					streamed = result.streamed,
					via = result.via,
				})
				local after = { result = result, record = record, session = session }
				hooks.run("postResponse", after)
				return after.result, nil, record
			end

			firstError = firstError or err
			session.emit("request:done", {
				provider = record.label,
				model = record.model,
				ms = clock.since(started),
				error = err,
			})
			if err == "aborted" then return nil, "aborted" end
		end

		return nil, firstError or "every provider failed"
	end

	-- Compaction uses whatever provider is healthy, with no tools and a tight
	-- ceiling: it is a cheap call whose only job is to keep the transcript
	-- affordable. If it fails, the context still trims -- it just loses the note.
	local function summariser(session)
		return function(transcript)
			local record = providers.active()
			if not record then return nil end
			local result = openai.complete(record, {
				messages = {
					{ role = "system", content = prompt.compaction() },
					{ role = "user", content = transcript },
				},
				stream = false,
				temperature = 0,
				maxTokens = 400,
				attempts = 1,
				aborted = session.aborted,
			})
			return result and result.content or nil
		end
	end

	-- Runs one user prompt to completion. Returns the assistant's final text.
	function M.run(session, text)
		local ctx = session.ctx
		local maxTurns = session.maxTurns or config.get("agent.maxTurns", 24)
		local repeatLimit = config.get("agent.repeatLimit", 3)
		local deadline = clock.ms() + (session.budgetSeconds or 900) * 1000

		usage.startTurn()
		ctx.pushUser(text)
		session.emit("turn:start", { turns = maxTurns })

		local lastSignature, streak = "", 0
		local finalText = nil

		for turn = 1, maxTurns do
			if session.aborted() then
				session.emit("abort", {})
				return "Stopped."
			end
			if clock.ms() > deadline then
				session.emit("error", { message = "This turn ran out of time.", fatal = false })
				return "I ran out of time on this turn. Ask me to continue if you want me to keep going."
			end

			session.emit("status", { text = turn == 1 and "Thinking" or ("Working (step " .. turn .. ")") })

			local before = ctx.tokens()
			local summary = ctx.compact(summariser(session), { tokenLimit = config.get("agent.contextTokens", 24000) })
			if summary then
				session.emit("compact", { summary = summary, before = before, after = ctx.tokens() })
			end

			local record = providers.active()
			-- A session may carry its own brief. A subagent does: it answers to the
			-- parent agent rather than to the user, so inheriting the main prompt
			-- would have it write a chat reply instead of a report.
			local systemText
			if type(session.systemPrompt) == "function" then
				systemText = session.systemPrompt()
			elseif type(session.systemPrompt) == "string" and util.trim(session.systemPrompt) ~= "" then
				systemText = session.systemPrompt
			else
				systemText = prompt.build({
					model = record and record.model or nil,
					provider = record and record.label or nil,
				})
			end

			local request = {
				messages = ctx.wire(systemText),
				tools = registry.definitions({ only = session.toolFilter, groups = session.toolGroups }),
				stream = session.stream,
				onFrame = session.onFrame,
			}

			local result, err = complete(session, request)

			if not result then
				if err == "aborted" then
					session.emit("abort", {})
					return "Stopped."
				end
				session.emit("error", { message = err, fatal = true })
				return "I could not reach a provider. " .. tostring(err)
			end

			usage.record(result.usage, result.model or (record and record.model), {
				prompt = usage.estimateMessages(request.messages),
				completion = usage.estimateText(result.content) + usage.estimateText(result.reasoning),
			})
			session.emit("usage", { session = usage.session, turn = usage.turn })

			if util.trim(result.reasoning) ~= "" then
				session.emit("assistant:reasoning", { text = result.reasoning })
			end
			if util.trim(result.content) ~= "" then
				session.emit("assistant:text", { text = result.content, final = #result.toolCalls == 0 })
			end

			ctx.pushAssistant(result)

			if #result.toolCalls == 0 then
				finalText = result.content
				if result.finish == "length" then
					finalText = finalText .. "\n\n[the reply was cut off by the token limit]"
				elseif result.finish == "content_filter" then
					finalText = (util.trim(finalText) ~= "" and finalText or "") ..
						"\n\n[the provider filtered part of this reply]"
				end
				break
			end

			-- Identical batches mean the model is stuck. Rather than let it burn the
			-- turn budget, the results are replaced with a refusal that names the
			-- problem, which is enough for most models to change tack.
			local signature = callSignature(result.toolCalls)
			if signature == lastSignature then
				streak = streak + 1
			else
				lastSignature, streak = signature, 1
			end

			if streak >= repeatLimit then
				for _, call in ipairs(result.toolCalls) do
					local name = (call["function"] or {}).name or "tool"
					ctx.pushToolResult(call.id, name,
						"This exact call has already been made " .. tostring(streak) ..
						" times with the same arguments. It will not be run again. Change the approach, or answer with what you already know.")
				end
				session.emit("status", { text = "Breaking a repeat loop" })
				log.warn("loop", "repeat limit hit on " .. util.ellipsis(signature, 120))
			else
				for _, call in ipairs(result.toolCalls) do
					local fn = call["function"] or {}
					local tool = registry.get(fn.name)
					session.emit("tool:call", {
						id = call.id,
						name = fn.name,
						group = tool and tool.group or nil,
						risk = tool and tool.risk or "write",
						arguments = fn.arguments,
					})
				end

				session.emit("status", { text = #result.toolCalls == 1
					and ("Running " .. ((result.toolCalls[1]["function"] or {}).name or "tool"))
					or ("Running " .. util.pluralise(#result.toolCalls, "tool")) })

				local results = registry.runAll(result.toolCalls, session.toolContext())

				for index, call in ipairs(result.toolCalls) do
					local outcome = results[index] or {
						id = call.id,
						name = (call["function"] or {}).name or "tool",
						ok = false,
						text = "The tool produced no result.",
					}
					ctx.pushToolResult(call.id, outcome.name, outcome.text)
					if outcome.ok then
						session.emit("tool:result", outcome)
					else
						session.emit("tool:error", outcome)
					end
				end
			end
		end

		if finalText == nil then
			session.emit("error", {
				message = "Reached the step limit of " .. tostring(maxTurns) .. ".",
				fatal = false,
			})
			finalText = "I reached this session's step limit before finishing. Tell me to continue and I will pick up where I stopped."
		end

		session.emit("turn:end", { text = finalText })
		session.emit("status", { text = "Ready" })
		return finalText
	end

	return M
end
