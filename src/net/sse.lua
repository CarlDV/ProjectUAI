-- Server-sent-events parsing and delta assembly for chat completions.
--
-- No Roblox transport can read a response body incrementally, so `stream = true`
-- does not buy token-by-token delivery here -- the whole SSE stream arrives at
-- once. It is still worth asking for: the streamed shape is where providers put
-- reasoning text, and its per-chunk usage block is the only place some gateways
-- report token counts at all. This module replays a finished stream into the same
-- deltas a real stream would have produced, so the assembler below is also what
-- net/ws feeds when a genuine socket is available.
return function(env)
	local util = env.require("runtime/util")

	local M = { limits = { body = 8 * 1024 * 1024, frame = 1024 * 1024, chunks = 10000, calls = 64, arguments = 256000 } }

	-- Incremental SSE framing. A socket message may contain several events or a
	-- fraction of one, including a CRLF split between messages. HTTP reuses it for
	-- buffered bodies so the two transports accept exactly the same SSE syntax.
	function M.decoder(onFrame)
		local self = {}
		local buffer, data, eventName = "", {}, nil
		local bytes, blockBytes, chunks = 0, 0, 0
		local skipLF, first, failure, prefix = false, true, nil, ""
		local function fail(message)
			failure = failure or ("malformed_stream: " .. message)
			return false, failure
		end
		local function dispatch()
			if #data > 0 then
				chunks = chunks + 1
				if chunks > M.limits.chunks then return fail("frame count exceeded") end
				local ok, accepted, why = pcall(onFrame, { event = eventName, data = table.concat(data, "\n") })
				if not ok or accepted == false then return fail(why or "frame callback failed") end
			end
			data, eventName, blockBytes = {}, nil, 0
			return true
		end
		local function line(text)
			if text == "" then return dispatch() end
			blockBytes = blockBytes + #text + 1
			if blockBytes > M.limits.frame then return fail("frame exceeds 1 MiB") end
			local field, value = text:match("^([^:]+): ?(.*)$")
			if not field then field, value = text, "" end
			if field == "data" then data[#data + 1] = value
			elseif field == "event" then eventName = value end
			return true
		end
		function self.push(fragment)
			if failure then return false, failure end
			if type(fragment) ~= "string" then return fail("body is not text") end
			bytes = bytes + #fragment
			if bytes > M.limits.body then return fail("body exceeds 8 MiB") end
			if first then
				prefix = prefix .. fragment
				if #prefix < 3 and ("\239\187\191"):sub(1, #prefix) == prefix then return true end
				fragment = prefix:gsub("^\239\187\191", "")
				prefix, first = "", false
			end
			if skipLF and fragment ~= "" then
				if fragment:sub(1, 1) == "\n" then fragment = fragment:sub(2) end
				skipLF = false
			end
			if fragment:sub(-1) == "\r" then skipLF = true end
			buffer = buffer .. fragment:gsub("\r\n", "\n"):gsub("\r", "\n")
			local from = 1
			while true do
				local at = buffer:find("\n", from, true)
				if not at then break end
				local ok, why = line(buffer:sub(from, at - 1))
				if not ok then return false, why end
				from = at + 1
			end
			buffer = buffer:sub(from)
			if #buffer + blockBytes > M.limits.frame then return fail("frame exceeds 1 MiB") end
			return true
		end
		function self.finish()
			if failure then return false, failure end
			if first and prefix ~= "" then return fail("incomplete UTF-8 BOM") end
			if buffer ~= "" then
				local ok, why = line(buffer); buffer = ""
				if not ok then return false, why end
			end
			return dispatch()
		end
		function self.idle() return buffer == "" and #data == 0 and blockBytes == 0 end
		return self
	end

	function M.frames(body)
		local out = {}
		local decoder = M.decoder(function(frame) out[#out + 1] = frame end)
		local ok, err = decoder.push(body)
		if ok then ok, err = decoder.finish() end
		return ok and out or {}, err
	end

	-- Accumulates streamed chunks into one assistant message.
	--
	-- The tool_calls contract is the fiddly part: `index` identifies the call,
	-- `id` and `function.name` arrive once (usually on the first fragment) and
	-- `function.arguments` arrives as string fragments that must be concatenated
	-- in order. Providers also disagree about whether index starts at 0, so the
	-- slots are keyed by the raw index and only flattened at the end.
	function M.assembler()
		local self = {
			content = {},
			reasoning = {},
			slots = {},
			order = {},
			finish = nil,
			model = nil,
			id = nil,
			usage = nil,
			chunks = 0,
			bytes = 0,
			streamError = nil,
		}

		local function slotFor(index)
			local key = tostring(index or 0)
			if not self.slots[key] then
				if #self.order >= M.limits.calls then error("too many tool calls", 0) end
				self.slots[key] = { id = nil, name = nil, args = {}, bytes = 0, index = tonumber(index) or 0 }
				self.order[#self.order + 1] = key
			end
			return self.slots[key]
		end

		local function feed(chunk)
			if type(chunk) ~= "table" then error("chunk is not an object", 0) end
			local size = #util.encode(chunk)
			if size > M.limits.frame or self.bytes + size > M.limits.body or self.chunks >= M.limits.chunks then error("stream budget exceeded", 0) end
			self.bytes = self.bytes + size
			self.chunks = self.chunks + 1
			self.id = self.id or chunk.id
			self.model = self.model or chunk.model
			if type(chunk.usage) == "table" then self.usage = chunk.usage end

			if chunk.choices ~= nil and type(chunk.choices) ~= "table" then error("choices is not an array", 0) end
			local choice = chunk.choices and chunk.choices[1]
			if type(choice) ~= "table" then return end
			if choice.finish_reason and choice.finish_reason ~= "" then
				self.finish = choice.finish_reason
			end

			-- A non-streamed response is a `message`; a streamed one is a `delta`.
			-- Accepting both means one code path assembles either.
			local part = choice.delta or choice.message
			if type(part) ~= "table" then return end

			if type(part.content) == "string" and part.content ~= "" then
				self.content[#self.content + 1] = part.content
			elseif type(part.content) == "table" then
				-- Multi-part content: text segments go to content, thinking blocks to reasoning.
				for _, piece in ipairs(part.content) do
					if type(piece) == "table" then
						if piece.type == "thinking" then
							local think = piece.thinking or piece.text
							if type(think) == "string" and think ~= "" then
								self.reasoning[#self.reasoning + 1] = think
							end
						elseif type(piece.text) == "string" and piece.text ~= "" then
							self.content[#self.content + 1] = piece.text
						end
					end
				end
			end

			local reasoning = part.reasoning_content or part.reasoning or part.thinking
				or (choice and (choice.reasoning_content or choice.reasoning))
			if type(reasoning) == "string" and reasoning ~= "" then
				self.reasoning[#self.reasoning + 1] = reasoning
			elseif type(reasoning) == "table" then
				local text = reasoning.text or reasoning.thinking
				if type(text) == "string" and text ~= "" then
					self.reasoning[#self.reasoning + 1] = text
				end
			end

			if type(part.tool_calls) == "table" then
				for position, call in ipairs(part.tool_calls) do
					-- Streamed fragments carry index; a whole message does not, so its
					-- array position stands in.
					if type(call) ~= "table" then error("tool call is not an object", 0) end
					local index = call.index or (position - 1)
					if type(index) ~= "number" or index < 0 or index > 1024 or index ~= math.floor(index) then error("tool call index is invalid", 0) end
					local slot = slotFor(index)
					if call.id and (type(call.id) ~= "string" or #call.id > 256) then error("tool call ID is invalid", 0) end
					if call.id and call.id ~= "" then slot.id = call.id end
					local fn = call["function"]
					if type(fn) == "table" then
						if fn.name and (type(fn.name) ~= "string" or #fn.name > 256) then error("tool name is invalid", 0) end
						if fn.name and fn.name ~= "" then slot.name = fn.name end
						local arguments = fn.arguments
						if type(arguments) == "table" then
							-- Some compatible servers send a whole argument object. It
							-- is a single value, never a fragment to merge or ignore.
							if slot.bytes > 0 then error("mixed object and fragmented tool arguments", 0) end
							if next(arguments) ~= nil and util.isArray(arguments) then error("tool arguments must be an object, not an array", 0) end
							arguments = next(arguments) == nil and "{}" or util.encode(arguments)
							slot.objectArgs = true
						elseif arguments ~= nil and type(arguments) ~= "string" then
							error("tool arguments must be a string or object", 0)
						elseif slot.objectArgs and arguments and arguments ~= "" then
							error("mixed object and fragmented tool arguments", 0)
						end
						if type(arguments) == "string" and arguments ~= "" then
							slot.bytes = slot.bytes + #arguments
							if slot.bytes > M.limits.arguments then error("tool arguments exceed 256000 bytes", 0) end
							slot.args[#slot.args + 1] = arguments
						end
					end
				end
			end
		end

		function self.feedChunk(chunk)
			if self.streamError then return false, self.streamError end
			local ok = pcall(feed, chunk)
			if not ok then self.streamError = "malformed_stream: invalid chunk or stream budget exceeded" end
			return ok, self.streamError
		end

		-- Returns the assembled assistant message plus what the loop needs to
		-- decide the next step.
		function self.result()
			local calls = {}
			table.sort(self.order, function(a, b)
				return (self.slots[a].index or 0) < (self.slots[b].index or 0)
			end)
			for _, key in ipairs(self.order) do
				local slot = self.slots[key]
				if slot.name then
					calls[#calls + 1] = {
						id = slot.id or ("call_" .. tostring(slot.index) .. "_" .. tostring(#calls + 1)),
						type = "function",
						["function"] = {
							name = slot.name,
							arguments = table.concat(slot.args),
						},
					}
				end
			end
			return {
				role = "assistant",
				content = table.concat(self.content),
				reasoning = table.concat(self.reasoning),
				toolCalls = calls,
				finish = self.finish,
				model = self.model,
				id = self.id,
				usage = self.usage,
				chunks = self.chunks,
				streamError = self.streamError,
			}
		end

		return self
	end

	-- Whole SSE body -> assembled message. `[DONE]` ends the stream; a frame that
	-- carries an error object is surfaced rather than silently dropped, because
	-- several gateways report mid-stream failures that way and a client that
	-- ignores them reports "empty reply" instead of the real reason.
	function M.parse(body)
		local assembler = M.assembler()
		local frames, streamError = M.frames(body)
		local done = false
		for _, frame in ipairs(frames) do
			local payload = util.trim(frame.data)
			if payload == "[DONE]" then done = true; break end
			if payload ~= "" then
				local decoded = util.decode(payload)
				if type(decoded) == "table" then
					if decoded.error then
						streamError = "malformed_stream: provider reported a stream error"
					else
						assembler.feedChunk(decoded)
					end
				else streamError = "malformed_stream: invalid JSON frame" end
			end
		end
		local result = assembler.result()
		result.frames = #frames
		result.streamError = streamError or result.streamError or (not done and not result.finish and "malformed_stream: stream ended before completion" or nil)
		return result
	end

	-- A plain (non-streamed) JSON response goes through the same assembler so both
	-- paths return one shape.
	function M.fromResponse(decoded)
		local assembler = M.assembler()
		assembler.feedChunk(decoded)
		local result = assembler.result()
		result.frames = 0
		return result
	end

	-- True when the body looks like an event stream rather than a JSON document.
	function M.looksStreamed(body)
		if type(body) ~= "string" then return false end
		body = body:gsub("^\239\187\191", "")
		return body:find("^%s*data:") ~= nil or body:find("[\r\n]data:") ~= nil
	end

	return M
end
