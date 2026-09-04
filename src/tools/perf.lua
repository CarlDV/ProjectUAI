-- Diagnostics: frame rate, memory, and what the place is actually made of.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local SCAN_CAP = 60000

	return {
		{
			name = "performance",
			risk = "read",
			description = "Measure frame rate over a short sample and report memory and network stats.",
			parameters = {
				type = "object",
				properties = {
					sample = { type = "number", description = "Seconds to sample the frame rate, 0.2-3. Default 1.", minimum = 0.2, maximum = 3 },
				},
				required = {},
			},
			run = function(args)
				local sample = util.clamp(tonumber(args.sample) or 1, 0.2, 3)
				local frames, elapsed = 0, 0
				-- Counting Heartbeat deltas measures real frames rather than dividing
				-- by a clock read, which on a stuttering client reads very differently.
				local connection = env.run.Heartbeat:Connect(function(delta)
					frames = frames + 1
					elapsed = elapsed + delta
				end)
				clock.wait(sample)
				pcall(function() connection:Disconnect() end)

				local rows = {
					{ "FPS", elapsed > 0 and string.format("%.1f", frames / elapsed) or "unknown" },
					{ "Frames sampled", tostring(frames) },
				}

				local stats = env.services.Stats
				local okMemory, memory = pcall(function() return stats:GetTotalMemoryUsageMb() end)
				if okMemory then rows[#rows + 1] = { "Memory", string.format("%.0f MB", memory) } end
				for _, field in ipairs({ "DataReceiveKbps", "DataSendKbps", "HeartbeatTimeMs", "PhysicsStepTimeMs", "InstanceCount" }) do
					local ok, value = pcall(function() return stats[field] end)
					if ok and type(value) == "number" then
						rows[#rows + 1] = { field, string.format("%.2f", value) }
					end
				end

				local okPing, ping = pcall(function()
					return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
				end)
				if okPing and type(ping) == "number" then
					rows[#rows + 1] = { "Ping", string.format("%.0f ms", ping) }
				end

				return H.keyValues(rows)
			end,
		},
		{
			name = "class_counts",
			risk = "read",
			description = "Count instances by class under a subtree. Good for sizing up an unfamiliar place before walking it.",
			parameters = {
				type = "object",
				properties = {
					root = { type = "string", description = "Where to count. Defaults to Workspace." },
					limit = { type = "integer", description = "Classes to list, 1-40. Default 20.", minimum = 1, maximum = 40 },
				},
				required = {},
			},
			run = function(args)
				local root, err = H.resolve(args.root or "Workspace")
				if not root then return H.fail(err) end

				local ok, descendants = pcall(function() return root:GetDescendants() end)
				if not ok then return H.fail("could not read that subtree") end

				local counts, total = {}, 0
				for _, node in ipairs(descendants) do
					total = total + 1
					if total > SCAN_CAP then break end
					counts[node.ClassName] = (counts[node.ClassName] or 0) + 1
				end

				local rows = {}
				for class, count in pairs(counts) do rows[#rows + 1] = { class = class, count = count } end
				table.sort(rows, function(a, b)
					if a.count ~= b.count then return a.count > b.count end
					return a.class < b.class
				end)

				if total == 0 then return H.pathOf(root) .. " is empty." end
				return string.format("%s contains %s across %d classes:\n%s",
					H.pathOf(root), util.pluralise(total, "instance"), #rows,
					H.list(rows, H.limit(args.limit, 20, 40), function(row)
						return string.format("%-28s %s", row.class, util.formatNumber(row.count))
					end))
			end,
		},
		{
			name = "agent_status",
			risk = "read",
			description = "Report the agent's own state: provider, model, token spend this session, context size, host capabilities and how many tools are available.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function(_, ctx)
				local caps = env.require("runtime/caps")
				local usage = env.require("agent/usage")
				local providers = env.require("provider/registry")
				local registry = env.require("agent/registry")
				local permissions = env.require("agent/permissions")
				local ua = env.require("net/ua")

				local record = providers.active()
				local stats = registry.stats()
				local rows = {
					{ "Provider", record and (record.label .. " (" .. record.id .. ")") or "none configured" },
					{ "Model", record and record.model or "-" },
					{ "Identity", ua.enabled() and ua.userAgent() or "client identity disabled" },
					{ "Transport", caps.http .. (caps.uaSupported and "" or " (cannot set User-Agent)") },
					{ "Permissions", permissions.mode() },
					{ "Tools", string.format("%d available, %d unavailable here", stats.total, #stats.unavailable) },
					{ "Session tokens", usage.line() },
				}
				if ctx and ctx.session then
					local contextStats = ctx.session.ctx.stats()
					rows[#rows + 1] = { "Context", string.format("%d messages, about %s tokens, %d compaction(s)",
						contextStats.messages, util.formatNumber(contextStats.tokens), contextStats.compactions) }
				end
				return H.keyValues(rows)
			end,
		},
	}
end
