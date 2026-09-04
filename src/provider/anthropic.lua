-- The Anthropic Messages adapter.
--
-- Same contract as provider/openai: one request in, one normalised result out. The
-- wire format is a different API rather than a dialect of the same one -- the system
-- prompt is hoisted to a top-level field, a tool declares `input_schema` instead of
-- nesting under `function`, a tool call arrives as a `tool_use` content block, and
-- its result goes back as a `tool_result` block inside a USER turn. All of that
-- conversion lives here so the context store, the loop and the transcript keep
-- speaking one internal shape.
--
-- Deliberately absent from the body: `temperature`, `top_p` and `top_k`. They were
-- removed on Opus 4.7 and answer 400 on every model since, and this client's
-- default is an Opus 5. A record that needs them on an older Claude can set them
-- through `record.params`, which is spread in last.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local http = env.require("net/http")
	local sse = env.require("net/sse")
	local registry = env.require("provider/registry")
	local openai = env.require("provider/openai")

	local M = {}

	local VERSION = "2023-06-01"

	-- Anthropic stop reasons mapped onto the finish reasons the loop already reads,
	-- so nothing downstream has to learn a second vocabulary.
	local FINISH = {
		end_turn = "stop",
		stop_sequence = "stop",
		pause_turn = "stop",
		max_tokens = "length",
		tool_use = "tool_calls",
		refusal = "refusal",
	}

	function M.endpoint(record)
		local base = util.trim(record.baseUrl or "")
		-- A base pasted as the full messages URL must not gain a second /messages,
		-- and one pasted as an OpenAI endpoint is still usable as a host.
		base = base:gsub("/messages$", ""):gsub("/chat/completions$", "")
		return registry.endpoint({ baseUrl = base, query = record.query }, "/messages")
	end

	function M.headers(record)
		local style = record.authStyle or "bearer"
		local key = util.trim(record.apiKey or "")
		local headers = {}
		if key ~= "" and style ~= "none" then
			if style == "bearer" then
				-- The Messages API authenticates with x-api-key. `bearer` is this
				-- client's default for every other provider, so a record carrying it
				-- means "the usual way" rather than a deliberate choice -- honouring it
				-- literally here would just produce a 401 nobody could explain.
				headers["x-api-key"] = key
			else
				headers = registry.authHeaders(record)
			end
		end
		headers["anthropic-version"] = VERSION
		for name, value in pairs(record.headers or {}) do headers[name] = value end
		return headers
	end

	-- Internal messages are OpenAI-shaped. Anthropic wants the system prompt lifted
	-- out, tool results carried inside user turns, and every result for one assistant
	-- turn merged into a SINGLE user message -- splitting them across several is
	-- documented to train the model out of calling tools in parallel.
	function M.wireMessages(messages)
		local system, out = {}, {}

		local function push(role, content)
			out[#out + 1] = { role = role, content = content }
		end

		for _, message in ipairs(messages or {}) do
			local role = message.role
			if role == "system" then
				local text = util.trim(tostring(message.content or ""))
				if text ~= "" then system[#system + 1] = text end
			elseif role == "tool" then
				local block = {
					type = "tool_result",
					tool_use_id = message.tool_call_id,
					content = tostring(message.content or ""),
				}
				local last = out[#out]
				if last and last.role == "user" and type(last.content) == "table"
					and last.content[1] and last.content[1].type == "tool_result" then
					last.content[#last.content + 1] = block
				else
					push("user", { block })
				end
			elseif role == "assistant" then
				if type(message.raw) == "table" and #message.raw > 0 then
					-- Replayed verbatim. Thinking blocks in particular have to come back
					-- unchanged on the same model -- they carry a signature that cannot
					-- be rebuilt -- and reassembling them from text would not be
					-- unchanged. The one repair is a tool_use input that decoded to an
					-- empty table, which would re-encode as [] and be rejected.
					local blocks = {}
					for index, block in ipairs(message.raw) do
						if type(block) == "table" and block.type == "tool_use"
							and (type(block.input) ~= "table" or util.count(block.input) == 0) then
							blocks[index] = util.merge(block, { input = util.emptyObject() })
						else
							blocks[index] = block
						end
					end
					push("assistant", blocks)
				else
					local blocks = {}
					local text = tostring(message.content or "")
					if util.trim(text) ~= "" then
						blocks[#blocks + 1] = { type = "text", text = text }
					end
					for _, call in ipairs(message.toolCalls or {}) do
						local fn = call["function"] or {}
						local input = util.decode(fn.arguments or call.arguments or "{}")
						-- `input` is a schema-shaped object, so an empty one has to encode
						-- as {} rather than as [].
						if type(input) ~= "table" or util.count(input) == 0 then
							input = util.emptyObject()
						end
						blocks[#blocks + 1] = {
							type = "tool_use",
							id = call.id,
							name = fn.name or call.name,
							input = input,
						}
					end
					if #blocks > 0 then push("assistant", blocks) end
				end
			else
				push("user", tostring(message.content or ""))
			end
		end

		-- The API requires the first turn to be a user one.
		if out[1] and out[1].role ~= "user" then
			table.insert(out, 1, { role = "user", content = "Continue." })
		end
		return out, table.concat(system, "\n\n")
	end

	-- A tool definition loses its `function` wrapper and its schema is renamed.
	function M.wireTools(tools)
		local out = {}
		for _, definition in ipairs(tools or {}) do
			local fn = definition["function"] or definition
			if fn.name then
				out[#out + 1] = {
					name = fn.name,
					description = fn.description,
					input_schema = fn.parameters or fn.input_schema or util.emptyObject(),
				}
			end
		end
		return out
	end

	function M.buildBody(record, request)
		local messages, system = M.wireMessages(request.messages)
		local maxTokens = request.maxTokens or config.get("agent.maxTokens", 4096)
		local body = {
			model = record.model,
			messages = messages,
			-- Required here, unlike chat completions, and it must be positive.
			max_tokens = (maxTokens and maxTokens > 0) and maxTokens or 4096,
		}
		if system ~= "" then body.system = system end
		local tools = M.wireTools(request.tools)
		if #tools > 0 then body.tools = tools end
		if request.stream then body.stream = true end
		for key, value in pairs(record.params or {}) do body[key] = value end
		for key, value in pairs(request.extra or {}) do body[key] = value end
		return body
	end

	-- Anthropic reports failures as {"type":"error","error":{"type":...,"message":...}},
	-- which is the shape provider/openai already extracts, so the status-to-prose
	-- table and the empty-body handling are shared rather than duplicated.
	function M.errorText(res, err)
		return openai.errorText(res, err)
	end

	local function normaliseUsage(usage)
		usage = usage or {}
		local input = usage.input_tokens or 0
		local output = usage.output_tokens or 0
		-- Renamed to the OpenAI keys the usage panel reads, originals kept alongside.
		return {
			prompt_tokens = input,
			completion_tokens = output,
			total_tokens = input + output,
			cache_read_input_tokens = usage.cache_read_input_tokens,
			cache_creation_input_tokens = usage.cache_creation_input_tokens,
		}
	end

	-- One whole Anthropic message -> the result shape provider/openai returns.
	function M.fromMessage(decoded)
		local content, reasoning, calls = {}, {}, {}
		for _, block in ipairs(decoded.content or {}) do
			if type(block) == "table" then
				if block.type == "text" and type(block.text) == "string" then
					content[#content + 1] = block.text
				elseif block.type == "thinking" and type(block.thinking) == "string" then
					reasoning[#reasoning + 1] = block.thinking
				elseif block.type == "tool_use" then
					calls[#calls + 1] = {
						id = block.id,
						type = "function",
						["function"] = {
							name = block.name,
							arguments = util.encode(block.input or util.emptyObject()),
						},
					}
				end
			end
		end
		return {
			role = "assistant",
			content = table.concat(content),
			reasoning = table.concat(reasoning),
			toolCalls = calls,
			finish = FINISH[tostring(decoded.stop_reason or "")] or decoded.stop_reason,
			stopReason = decoded.stop_reason,
			model = decoded.model,
			id = decoded.id,
			usage = normaliseUsage(decoded.usage),
			-- Kept so the next turn can replay this assistant message byte for byte.
			raw = decoded.content,
			chunks = 0,
			frames = 0,
		}
	end

	-- The streamed form. Frame splitting is shared with net/sse -- that part is the
	-- SSE spec, not a vendor decision -- but the events inside are Anthropic's own:
	-- message_start, content_block_start/delta/stop, message_delta, message_stop.
	function M.parseStream(body)
		local content, reasoning = {}, {}
		local slots, order = {}, {}
		local model, id, usage, stop, streamError
		local frames = sse.frames(body)

		local function slotFor(index)
			local key = tostring(index or 0)
			if not slots[key] then
				slots[key] = { index = tonumber(index) or 0, json = {} }
				order[#order + 1] = key
			end
			return slots[key]
		end

		for _, frame in ipairs(frames) do
			local payload = util.trim(frame.data)
			if payload ~= "" and payload ~= "[DONE]" then
				local event = util.decode(payload)
				if type(event) == "table" then
					local kind = event.type or frame.event
					if kind == "error" then
						streamError = (type(event.error) == "table" and event.error.message)
							or tostring(event.error)
					elseif kind == "message_start" and type(event.message) == "table" then
						model, id, usage = event.message.model, event.message.id, event.message.usage
					elseif kind == "content_block_start" and type(event.content_block) == "table" then
						local block = event.content_block
						if block.type == "tool_use" then
							local slot = slotFor(event.index)
							slot.id, slot.name = block.id, block.name
						elseif block.type == "text" and type(block.text) == "string" and block.text ~= "" then
							content[#content + 1] = block.text
						end
					elseif kind == "content_block_delta" and type(event.delta) == "table" then
						local delta = event.delta
						if delta.type == "text_delta" and type(delta.text) == "string" then
							content[#content + 1] = delta.text
						elseif delta.type == "thinking_delta" and type(delta.thinking) == "string" then
							reasoning[#reasoning + 1] = delta.thinking
						elseif delta.type == "input_json_delta" and type(delta.partial_json) == "string" then
							local slot = slotFor(event.index)
							slot.json[#slot.json + 1] = delta.partial_json
						end
					elseif kind == "message_delta" then
						if type(event.delta) == "table" and event.delta.stop_reason then
							stop = event.delta.stop_reason
						end
						if type(event.usage) == "table" then
							usage = usage and util.merge(usage, event.usage) or event.usage
						end
					end
				end
			end
		end

		local text = table.concat(content)
		local calls, raw = {}, {}
		if util.trim(text) ~= "" then raw[#raw + 1] = { type = "text", text = text } end
		table.sort(order, function(a, b) return slots[a].index < slots[b].index end)
		for _, key in ipairs(order) do
			local slot = slots[key]
			if slot.name then
				local arguments = table.concat(slot.json)
				if util.trim(arguments) == "" then arguments = "{}" end
				calls[#calls + 1] = {
					id = slot.id or ("toolu_" .. tostring(slot.index)),
					type = "function",
					["function"] = { name = slot.name, arguments = arguments },
				}
				local input = util.decode(arguments)
				if type(input) ~= "table" or util.count(input) == 0 then input = util.emptyObject() end
				raw[#raw + 1] = { type = "tool_use", id = slot.id, name = slot.name, input = input }
			end
		end

		return {
			role = "assistant",
			content = text,
			reasoning = table.concat(reasoning),
			toolCalls = calls,
			finish = FINISH[tostring(stop or "")] or stop,
			stopReason = stop,
			model = model,
			id = id,
			usage = normaliseUsage(usage),
			raw = raw,
			chunks = #frames,
			frames = #frames,
			streamError = streamError,
		}
	end

	-- Performs one completion against one provider. Same return contract as
	-- provider/openai: result, nil on success or nil, message, res on failure, so the
	-- chain in agent/loop cannot tell the two adapters apart.
	function M.complete(record, request)
		local wantStream = request.stream
		if wantStream == nil then
			wantStream = record.stream ~= false and config.get("agent.stream", true)
		end

		local body = M.buildBody(record, util.merge(request, { stream = wantStream }))
		local headers = M.headers(record)
		headers["Accept"] = wantStream and "text/event-stream" or "application/json"

		local started = clock.ms()
		local res, err = http.send({
			url = M.endpoint(record),
			method = "POST",
			headers = headers,
			body = util.encode(body),
			identity = (record.claudeUa ~= false) and "claude" or "none",
			attempts = request.attempts or config.get("agent.retries", 5),
			aborted = request.aborted,
			onRetry = request.onRetry,
			tag = "messages:" .. record.id,
			timeout = request.timeout,
		})

		if not res or not res.ok then
			local message = M.errorText(res, err)
			registry.markFail(record, message)
			return nil, message, res
		end

		local parsed
		if sse.looksStreamed(res.body) then
			parsed = M.parseStream(res.body)
		else
			local decoded, decodeErr = util.decode(res.body)
			if type(decoded) ~= "table" then
				local message = "provider returned a body that is not JSON: " .. tostring(decodeErr)
				registry.markFail(record, message)
				return nil, message, res
			end
			if decoded.type == "error" or decoded.error then
				local message = M.errorText(res, nil)
				registry.markFail(record, message)
				return nil, message, res
			end
			parsed = M.fromMessage(decoded)
		end

		if parsed.streamError then
			registry.markFail(record, parsed.streamError)
			return nil, "stream error: " .. parsed.streamError, res
		end

		-- A policy refusal is a 200 with nothing to act on, so it is reported as the
		-- reason rather than as an empty completion.
		if parsed.stopReason == "refusal" then
			local message = "the model declined this request (stop_reason refusal)"
			registry.markFail(record, message)
			return nil, message, res
		end

		local hasText = util.trim(parsed.content) ~= ""
		local hasCalls = #(parsed.toolCalls or {}) > 0
		if not hasText and not hasCalls and util.trim(parsed.reasoning) == "" then
			local message = "the provider returned an empty completion"
			registry.markFail(record, message)
			return nil, message, res
		end

		parsed.ms = clock.since(started)
		parsed.provider = record.id
		parsed.providerLabel = record.label
		parsed.via = res.via
		parsed.streamed = (parsed.frames or 0) > 0
		registry.markOk(record, parsed.ms)
		return parsed, nil, res
	end
	return M
end
