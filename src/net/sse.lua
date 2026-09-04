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

	local M = {}

	-- Splits an SSE body into its data payloads. Frames are separated by a blank
	-- line; a frame may carry several data: lines which concatenate. Comment lines
	-- (starting ':') and unknown fields are ignored, as the spec requires.
	function M.frames(body)
		local out = {}
		if type(body) ~= "string" then return out end
		local normalised = body:gsub("\r\n", "\n"):gsub("\r", "\n")
		for block in (normalised .. "\n\n"):gmatch("(.-)\n\n") do
			local dataLines, eventName = {}, nil
			for _, line in ipairs(util.lines(block)) do
				local field, value = line:match("^([%w%-]+):%s?(.*)$")
				if field == "data" then
					dataLines[#dataLines + 1] = value
				elseif field == "event" then
					eventName = value
				end
			end
			if #dataLines > 0 then
				out[#out + 1] = { event = eventName, data = table.concat(dataLines, "\n") }
			end
		end
		return out
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
		}

		local function slotFor(index)
			local key = tostring(index or 0)
			if not self.slots[key] then
				self.slots[key] = { id = nil, name = nil, args = {}, index = tonumber(index) or 0 }
				self.order[#self.order + 1] = key
			end
			return self.slots[key]
		end

		function self.feedChunk(chunk)
			if type(chunk) ~= "table" then return end
			self.chunks = self.chunks + 1
			self.id = self.id or chunk.id
			self.model = self.model or chunk.model
			if type(chunk.usage) == "table" then self.usage = chunk.usage end

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
				-- Multi-part content: only the text segments concern us.
				for _, piece in ipairs(part.content) do
					if type(piece) == "table" and type(piece.text) == "string" then
						self.content[#self.content + 1] = piece.text
					end
				end
			end

			local reasoning = part.reasoning_content or part.reasoning
			if type(reasoning) == "string" and reasoning ~= "" then
				self.reasoning[#self.reasoning + 1] = reasoning
			elseif type(reasoning) == "table" and type(reasoning.text) == "string" then
				self.reasoning[#self.reasoning + 1] = reasoning.text
			end

			if type(part.tool_calls) == "table" then
				for position, call in ipairs(part.tool_calls) do
					-- Streamed fragments carry index; a whole message does not, so its
					-- array position stands in.
					local slot = slotFor(call.index or (position - 1))
					if call.id and call.id ~= "" then slot.id = call.id end
					local fn = call["function"]
					if type(fn) == "table" then
						if fn.name and fn.name ~= "" then slot.name = fn.name end
						if type(fn.arguments) == "string" and fn.arguments ~= "" then
							slot.args[#slot.args + 1] = fn.arguments
						end
					end
				end
			end
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
		local frames = M.frames(body)
		local streamError = nil
		for _, frame in ipairs(frames) do
			local payload = util.trim(frame.data)
			if payload == "[DONE]" then break end
			if payload ~= "" then
				local decoded = util.decode(payload)
				if type(decoded) == "table" then
					if decoded.error then
						streamError = (type(decoded.error) == "table" and decoded.error.message) or tostring(decoded.error)
					else
						assembler.feedChunk(decoded)
					end
				end
			end
		end
		local result = assembler.result()
		result.frames = #frames
		result.streamError = streamError
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
		return body:find("^%s*data:") ~= nil or body:find("\ndata:") ~= nil
	end

	return M
end
