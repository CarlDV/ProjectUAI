-- Transient previews from real transport frames; buffered replies bypass this.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local sse = env.require("net/sse")
	local text = env.require("runtime/code_text")
	local M = { previewBytes = 65536 }
	function M.new(session, model, aborted)
		local handle = { id = util.uid("stream") }
		local assembly, content, reasoning = sse.assembler(), "", ""
		local closed, pending, limited, last, generation = false, false, false, nil, 0
		local full = {}
		local function append(value, parts, channel)
			if full[channel] or #parts == 0 then return value end
			local joined = value .. table.concat(parts)
			if #joined > M.previewBytes then
				limited, full[channel] = true, true
				return joined:sub(1, text.clamp(joined, M.previewBytes + 1) - 1)
			end
			return joined
		end
		local function flush()
			pending = false; generation = generation + 1
			if closed or aborted() then return end
			last = clock.ms()
			session.emit("assistant:preview", { streamId = handle.id, model = model,
				text = content, reasoning = reasoning, limited = limited })
		end
		function handle.feed(frame)
			if closed or aborted() then return end
			local chunk = type(frame) == "table" and frame or util.decode(frame)
			if type(chunk) ~= "table" or chunk.error or not assembly.feedChunk(chunk) then return end
			if type(assembly.model) == "string" and util.trim(assembly.model) ~= "" then model = assembly.model end
			local priorContent, priorReasoning, priorLimit = content, reasoning, limited
			content, reasoning = append(content, assembly.content, "content"), append(reasoning, assembly.reasoning, "reasoning")
			assembly.content, assembly.reasoning = {}, {}
			if content == priorContent and reasoning == priorReasoning and limited == priorLimit then return end
			if not last or clock.ms() - last >= 100 then flush()
			elseif not pending then
				pending = true; local queued = generation
				clock.delay(0.1, function() if queued == generation then flush() end end)
			end
		end
		function handle.close() closed, pending, assembly = true, false, nil; generation = generation + 1 end
		return handle
	end
	return M
end
