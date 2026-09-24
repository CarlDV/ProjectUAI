-- Conversation store.
--
-- The system prompt is not kept here. It is rebuilt for every request, because it
-- carries the environment, the task list and the memory block, all of which move
-- while a session runs -- a prompt pinned at index one goes stale within minutes.
--
-- Trimming works in blocks rather than messages. A tool result whose assistant
-- tool_calls message has been dropped is a hard 400 from every provider, so the
-- unit of removal is "a user turn and everything that answered it", which can
-- never split that pair.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local usage = env.require("agent/usage")

	local M = {}
	-- Compact references only; querying context never initializes a workspace or hook.
	function M.workspaceSummary()
		local loaded = env.loadedModules or {}
		local store, explorer, capture = loaded["runtime/code_store"], loaded["runtime/explorer"], loaded["runtime/remote_capture"]
		local out = {}
		if store and store.initialized then
			local doc = store.active()
			out.destination, out.documentId, out.sourceRevision = store.workspace.destination, doc and doc.id, doc and doc.revision
			out.sourceId = store.workspace.sourceId
		end
		if explorer and #explorer.selectedIds > 0 then out.selection = util.slice(explorer.selectedIds, 1, 5); out.selectionCount, out.selectionRevision = #explorer.selectedIds, explorer.selectionRevision end
		if capture and capture.status ~= "idle" then
			local records = loaded["runtime/remote_store"]
			out.captureId, out.captureStatus, out.captureRevision, out.ruleCount = capture.sessionId, capture.status, capture.revision, #capture.rules
			out.recordId = capture.selectedId
			if capture.view.record and capture.view.record.id == capture.selectedId then out.recordRevision = capture.view.record.revision end
			if records then local state = records.state(); out.retained, out.evicted = state.retained, state.counters.evicted end
		end
		return next(out) and util.encode(out) or nil
	end

	function M.new()
		local ctx = {
			messages = {},
			summary = nil,
			compactions = 0,
			dropped = 0,
			-- The tokens a request spends beyond the message estimate: the system
			-- prompt and tool schemas ctx.tokens() does not see. Learned from what the
			-- provider actually counted, so the budget check reflects the real prompt.
			overhead = 0,
			calibrated = false,
		}

		function ctx.push(message)
			message.at = message.at or clock.ms()
			ctx.messages[#ctx.messages + 1] = message
			return message
		end

		function ctx.pushUser(text)
			return ctx.push({ role = "user", content = tostring(text) })
		end

		-- Reasoning text is kept locally for the transcript and replayed on
		-- subsequent turns for models in thinking mode (DeepSeek-R1, Claude thinking,
		-- QwQ, etc.) which require stateful chain-of-thought context.
		function ctx.pushAssistant(result)
			return ctx.push({
				role = "assistant",
				content = result.content or "",
				toolCalls = (result.toolCalls and #result.toolCalls > 0) and result.toolCalls or nil,
				reasoning = (result.reasoning ~= "" ) and result.reasoning or nil,
				-- The provider's own content blocks, when it has them. Only the
				-- Anthropic adapter sets this, and only it reads them back: a thinking
				-- block carries a signature that has to return unchanged, and there is
				-- no way to rebuild that from the text. Deliberately not persisted --
				-- see ctx.serialise -- so a reloaded conversation falls back to the
				-- reconstructed form, which the API accepts.
				raw = result.raw,
				model = result.model,
				provider = result.provider,
				ms = result.ms,
			})
		end

		function ctx.pushToolResult(callId, name, text)
			return ctx.push({
				role = "tool",
				tool_call_id = callId,
				name = name,
				content = tostring(text),
			})
		end

		function ctx.last(role)
			for index = #ctx.messages, 1, -1 do
				if not role or ctx.messages[index].role == role then return ctx.messages[index], index end
			end
			return nil
		end

		-- Blocks: index of every user message, which is where a block starts.
		local function blockStarts()
			local starts = {}
			for index, message in ipairs(ctx.messages) do
				if message.role == "user" then starts[#starts + 1] = index end
			end
			return starts
		end

		function ctx.tokens()
			local total = usage.estimateMessages(ctx.messages)
			if ctx.summary then total = total + usage.estimateText(ctx.summary) end
			return total
		end

		-- The whole-prompt token budget at which older turns get summarised. The
		-- manual "Context budget" setting is a hard ceiling; when the model's own
		-- context window is known, compaction starts at a fraction of it, so a small-
		-- window model compacts on its own without the user tuning a number for it.
		function ctx.limitFor(model)
			local configured = math.max(tonumber(config.get("agent.contextTokens", 24000)) or 24000, 1000)
			local window = model and env.require("provider/traits").contextWindow(model) or nil
			if not window then return configured end
			local fraction = tonumber(config.get("agent.contextFraction", 0.8)) or 0.8
			fraction = math.max(0.3, math.min(fraction, 0.95))
			return math.max(1000, math.min(configured, math.floor(window * fraction)))
		end

		-- What the next request is expected to actually cost the window: the message
		-- estimate plus the measured overhead of the system prompt and tool schemas.
		function ctx.pressure()
			return ctx.tokens() + math.max(ctx.overhead or 0, 0)
		end

		-- Fold the provider's reported prompt-token count for the request just sent
		-- into the overhead estimate. Called before the reply is stored, so
		-- ctx.tokens() still reflects exactly what was on the wire.
		function ctx.calibrate(promptTokens)
			local real = tonumber(promptTokens)
			if not real or real <= 0 then return end
			ctx.overhead = math.max(0, real - ctx.tokens())
			ctx.calibrated = true
		end

		function ctx.stats()
			local counts = { user = 0, assistant = 0, tool = 0 }
			for _, message in ipairs(ctx.messages) do
				counts[message.role] = (counts[message.role] or 0) + 1
			end
			return {
				messages = #ctx.messages,
				tokens = ctx.tokens(),
				pressure = ctx.pressure(),
				overhead = ctx.overhead or 0,
				turns = counts.user,
				toolResults = counts.tool,
				compactions = ctx.compactions,
				dropped = ctx.dropped,
			}
		end

		-- Removes whole blocks from the front until the estimate fits, always
		-- keeping the most recent `keep` blocks. Returns the removed messages so a
		-- caller can summarise them.
		function ctx.trim(tokenLimit, keepBlocks, force)
			local limit = tokenLimit or config.get("agent.contextTokens", 24000)
			local keep = math.max(keepBlocks or 2, 1)
			local removed = {}

			while force or ctx.tokens() > limit do
				local starts = blockStarts()
				if #starts <= keep then break end
				local cutTo = starts[2] and (starts[2] - 1) or 0
				if cutTo <= 0 then break end
				local kept = {}
				for index, message in ipairs(ctx.messages) do
					if index <= cutTo then
						removed[#removed + 1] = message
					else
						kept[#kept + 1] = message
					end
				end
				ctx.messages = kept
			end

			-- A single block can exceed the budget on its own -- one enormous tool
			-- result will do it. Shrink the oldest tool results in place rather than
			-- dropping the block and losing the user's actual question. A forced pass
			-- (Compact now) skips this: it is folding history, not rescuing a request,
			-- and must not gut the recent turns it deliberately keeps.
			if not force and ctx.tokens() > limit then
				for _, message in ipairs(ctx.messages) do
					if message.role == "tool" and #tostring(message.content) > 400 then
						message.content = util.truncate(message.content, 400, "trimmed to fit the context budget")
						if ctx.tokens() <= limit then break end
					end
				end
			end

			ctx.dropped = ctx.dropped + #removed
			if #removed > 0 then
				log.info("context", util.pluralise(#removed, "message") .. " trimmed to fit the budget")
			end
			return removed
		end

		-- Compaction replaces dropped turns with one summary line rather than
		-- letting them vanish, so the agent still knows what it already did.
		-- `summarise` is injected (the loop passes a cheap provider call) so this
		-- module stays free of provider knowledge and stays testable.
		function ctx.compact(summarise, opts)
			opts = opts or {}
			local budget = opts.tokenLimit or ctx.limitFor(opts.model)
			local force = opts.force == true
			-- Messages are the trimmable part; the measured overhead is not, so the
			-- message budget is the whole-prompt budget minus that fixed overhead.
			local msgLimit = math.max(1000, budget - math.max(ctx.overhead or 0, 0))
			if not force and ctx.tokens() <= msgLimit then return nil end

			local removed = ctx.trim(force and 0 or msgLimit, opts.keepBlocks or 2, force)
			if #removed == 0 then return nil end

			if type(summarise) ~= "function" then
				ctx.summary = (ctx.summary and (ctx.summary .. "\n") or "") ..
					string.format("[%d earlier messages were dropped to fit the context budget]", #removed)
				ctx.compactions = ctx.compactions + 1
				return ctx.summary
			end

			local transcript = {}
			local previousSummary = ctx.summary and util.trim(ctx.summary) or ""
			if previousSummary ~= "" then
				transcript[#transcript + 1] = "Summary so far:\n" .. previousSummary
				transcript[#transcript + 1] = "\nNewer messages to fold into that summary:"
			end
			for _, message in ipairs(removed) do
				local label = message.role
				local text = tostring(message.content or "")
				if message.toolCalls then
					local names = {}
					for _, call in ipairs(message.toolCalls) do
						names[#names + 1] = call["function"] and call["function"].name or "tool"
					end
					text = text .. " [called: " .. table.concat(names, ", ") .. "]"
				end
				transcript[#transcript + 1] = label .. ": " .. util.ellipsis(text, 700)
			end

			local ok, note = pcall(summarise, table.concat(transcript, "\n"))
			if ok and type(note) == "string" and util.trim(note) ~= "" then
				ctx.summary = util.trim(note)
			elseif previousSummary ~= "" then
				ctx.summary = previousSummary .. "\n"
					.. string.format("[%d more earlier messages were dropped; no summary was available]", #removed)
			else
				ctx.summary = string.format("[%d earlier messages were dropped; no summary was available]", #removed)
			end
			ctx.compactions = ctx.compactions + 1
			return ctx.summary
		end

		-- Tool pairing, repaired in place.
		--
		-- Every provider rejects, hard, a tool result whose call is not in the message
		-- immediately before it. Anthropic words it "unexpected tool_use_id found in
		-- tool_result blocks"; OpenAI says a `tool` message must answer a preceding
		-- `tool_calls`. Nothing here checked, and the consequence is not one failed turn:
		-- a 400 is not retried, three of them bench the provider, the chain then walks the
		-- same broken history to the next provider, and `ctx.serialise` keeps both halves
		-- of the pairing -- so the conversation stays poisoned across a restart.
		--
		-- Trimming cannot produce this, because it removes whole blocks. What can: a turn
		-- that dies between dispatching tools and recording their outcomes (leaving a call
		-- with no result), and a gateway that translates between the two wire shapes and
		-- drops an assistant turn whose content is the empty string -- which is exactly
		-- what this client sends for a tool-only turn (leaving a result with no call).
		--
		-- Both directions are repaired, differently. An orphaned result is dropped: there
		-- is nothing it can be attached to. An unanswered call is *answered*, because
		-- dropping it instead would discard what the model actually did.
		function ctx.repair()
			local kept, dropped = {}, 0
			for _, message in ipairs(ctx.messages) do
				if message.role == "tool" then
					-- The nearest assistant turn behind this one, looking past the sibling
					-- results that arrived with it.
					local owner = nil
					for back = #kept, 1, -1 do
						local candidate = kept[back]
						if candidate.role == "assistant" then
							owner = candidate
							break
						elseif candidate.role ~= "tool" then
							break
						end
					end
					local matched = false
					for _, call in ipairs((owner and owner.toolCalls) or {}) do
						if call.id ~= nil and tostring(call.id) == tostring(message.tool_call_id) then
							matched = true
						end
					end
					if matched then
						kept[#kept + 1] = message
					else
						dropped = dropped + 1
					end
				else
					kept[#kept + 1] = message
				end
			end

			local out, index, filled = {}, 1, 0
			while index <= #kept do
				local message = kept[index]
				out[#out + 1] = message
				index = index + 1
				if message.role == "assistant" and message.toolCalls and #message.toolCalls > 0 then
					local answered = {}
					while index <= #kept and kept[index].role == "tool" do
						answered[tostring(kept[index].tool_call_id)] = true
						out[#out + 1] = kept[index]
						index = index + 1
					end
					for _, call in ipairs(message.toolCalls) do
						if call.id ~= nil and not answered[tostring(call.id)] then
							out[#out + 1] = {
								role = "tool",
								tool_call_id = call.id,
								name = (call["function"] and call["function"].name) or call.name or "tool",
								content = "This call did not complete: the turn ended before a result "
									.. "was recorded.",
								at = message.at,
							}
							filled = filled + 1
						end
					end
				end
			end

			if dropped > 0 or filled > 0 then
				ctx.messages = out
				log.warn("context", string.format(
					"repaired tool pairing: %s dropped, %s filled in",
					util.pluralise(dropped, "orphaned result"),
					util.pluralise(filled, "unanswered call")))
			end
			return dropped, filled
		end

		-- Wire form. The summary rides as a second system message so it cannot be
		-- confused with the live instructions and is trivially droppable.
		function ctx.wire(systemText)
			-- Repaired here rather than at each adapter: this is the single funnel both of
			-- them are fed from, and doing it to the store rather than to a copy means one
			-- broken turn is fixed once instead of warned about on every request.
			ctx.repair()
			local out = {}
			if systemText and util.trim(systemText) ~= "" then
				out[#out + 1] = { role = "system", content = systemText }
			end
			if ctx.summary then
				out[#out + 1] = { role = "system", content = "Earlier in this conversation:\n" .. ctx.summary }
			end
			for _, message in ipairs(ctx.messages) do out[#out + 1] = message end
			return out
		end

		function ctx.clear()
			ctx.messages = {}
			ctx.summary = nil
			ctx.compactions = 0
			ctx.dropped = 0
			ctx.overhead = 0
			ctx.calibrated = false
		end

		-- Persistence keeps the fields a reload needs and drops the derived ones.
		function ctx.serialise()
			local out = { summary = ctx.summary, messages = {} }
			for _, message in ipairs(ctx.messages) do
				out.messages[#out.messages + 1] = {
					role = message.role,
					content = message.content,
					toolCalls = message.toolCalls,
					tool_call_id = message.tool_call_id,
					name = message.name,
					reasoning = message.reasoning,
					at = message.at,
				}
			end
			return out
		end

		function ctx.restore(data)
			if type(data) ~= "table" then return false end
			ctx.clear()
			ctx.summary = data.summary
			for _, message in ipairs(data.messages or {}) do
				if type(message) == "table" and message.role then ctx.push(message) end
			end
			return true
		end

		return ctx
	end

	return M
end
