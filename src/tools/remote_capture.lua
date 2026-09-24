return function(env)
	local capture = env.require("runtime/remote_capture")
	local records = env.require("runtime/remote_store")
	local replay = env.require("tools/remote_replay")
	local exports = env.require("runtime/native_exports")
	local N = env.require("tools/native_helpers").forGroup("remotes")
	local util = env.require("runtime/util")
	local tools = {}
	local str, num, boolean = { type = "string" }, { type = "integer" }, { type = "boolean" }
	local ids = { type = "array", items = str, maxItems = 128 }
	local watching
	local function watchRevocation()
		if watching then return end; watching = true
		local registry = env.require("agent/registry")
		local permissions = env.require("agent/permissions")
		local config = env.require("runtime/config")
		local sessions = env.require("agent/session")
		local clock = env.require("runtime/clock")
		local alive = true
		local previous = { capture = permissions.check({ name = "remotes_capture", risk = "write" }), rule = permissions.check({ name = "remote_rule", risk = "danger" }) }
		local function check()
			local current = { capture = permissions.check({ name = "remotes_capture", risk = "write" }), rule = permissions.check({ name = "remote_rule", risk = "danger" }) }
			if not registry.groupEnabled("remotes") or current.capture == "deny" or current.rule == "deny" or (previous.capture == "allow" and current.capture ~= "allow") or (previous.rule == "allow" and current.rule ~= "allow") then capture.revokeAgent() end
			previous = current
			local owners = {}; if capture.ownerSessionId then owners[capture.ownerSessionId] = "remotes_capture" end
			for _, rule in ipairs(capture.rules) do if rule.ownerSessionId then owners[rule.ownerSessionId] = "remote_rule" end end
			for id, name in pairs(owners) do
				local session = sessions.threads[id]
				if not session or session.removed or session.abortFlag or (session.toolGroups and not session.toolGroups.remotes) or (session.toolFilter and not session.toolFilter[name]) or (session.toolExclude and session.toolExclude[name]) then capture.revokeAgent(id) end
			end
		end
		local off = config.changed:connect(function(path) if path == nil or path == "agent" or path == "agent.disabledGroups" or tostring(path):match("^permissions") then check() end end)
		local offSession = sessions.anyEvent:connect(function(session, event) if event.kind == "abort" then capture.revokeAgent(session.id) end end)
		local function tick() if not alive then return end; check(); clock.delay(0.5, tick) end
		clock.delay(0.5, tick)
		env.require("runtime/dispose").add(function() alive = false; off(); offSession() end, "capture authorization")
	end
	N.add(tools, "remotes_state", "read", "Read capture state, actual coverage, scope, counts and traffic-rule status. Does not start capture or send traffic.", {}, {}, function() return N.result(capture.state(), "Shared Remotes state") end)
	N.add(tools, "remotes_capture", "write", "Explicit capture lifecycle. Start requires supported mode and exact scope. Tool default lifetime is 30 seconds; persistent is explicit. Stop/Clear remain available if hooks fail.",
		{ action = str, mode = str, instance_ids = ids, root_id = str, backend = str, duration = { type = "number" }, persistent = boolean, session_id = str, expected_revision = num }, { "action" }, function(args, ctx)
		local data, why
		if args.action == "start" then
			watchRevocation(); data, why = capture.start({ mode = args.mode or "uai", ids = args.instance_ids, rootId = args.root_id, backend = args.backend,
				duration = args.duration, persistent = args.persistent, expected_revision = args.expected_revision }, { origin = "tool", sessionId = ctx.session and ctx.session.id, aborted = ctx.aborted })
		else data, why = capture.control(args.action, args.session_id, args.expected_revision) end
		return N.result(data, why or (data.status .. (args.persistent and "; capture remains running until explicitly stopped or revoked" or "")))
	end)
	N.add(tools, "remotes_calls", "read", "Read captured call summaries with sequence gaps and continuation. Arguments/results are separate bounded reads.",
		{ session_id = str, cursor = str, after_sequence = num, name = str, direction = str, method = str, origin = str, outcome = str, remote_id = str, limit = num }, { "session_id" }, function(args)
		args.limit = math.min(args.limit or 6, 6); local data, why = records.page(args); return N.result(data, why or "Capture summary page")
	end)
	N.add(tools, "remote_capture_read", "read", "Read a capture's summary, arguments, results or caller as bounded graph pages. Table nodes reference node_id; no remote calls occur.",
		{ record_id = str, record_revision = num, section = str, node_id = num, offset = num }, { "record_id", "section" }, function(args)
		local data, why = records.read(args.record_id, args.section, args.node_id, args.offset, args.record_revision); return N.result(data, why or "Captured value page")
	end)
	N.add(tools, "remote_capture_bytes", "read", "Read retained text/binary bytes from a large captured value. Offsets address original bytes; hex output is explicit. Truncated prefixes never imply complete original data.",
		{ record_id = str, record_revision = num, section = str, node_id = num, index = num, field = str, byte_offset = num, byte_limit = num }, { "record_id", "section", "index" }, function(args)
		local data, why = records.readBytes(args); return N.result(data, why or "Retained value byte page")
	end)
	N.add(tools, "remotes_filter", "write", "Change admission filtering for future recordings. Excluded past calls cannot be recovered. This never blocks traffic.",
		{ session_id = str, expected_revision = num, include = ids, exclude = ids, method = str }, { "session_id", "expected_revision" }, function(args)
		if args.session_id ~= capture.sessionId then return N.fail("stale capture session") end
		local data, why = capture.setFilter(args, args.expected_revision); return N.result(data, why or "Admission filter updated; ignored past calls cannot be recovered")
	end)
	N.add(tools, "remote_replay_prepare", "write", "Prepare an immutable five-minute replay plan from a captured revision or explicit remote/method and packed typed arguments. Preparation sends nothing.",
		{ record_id = str, record_revision = num, instance_id = str, method = str, arguments = { type = "object" } }, {}, function(args)
		local plan, why = replay.prepare({ recordId = args.record_id, recordRevision = args.record_revision, remoteId = args.instance_id, method = args.method, arguments = args.arguments })
		if not plan then return N.fail(why) end
		return N.result({ planId = plan.id, digest = plan.digest, remoteId = plan.remoteId, method = plan.method, argumentCount = plan.arguments.count, expiresAt = plan.at + 300000, target = N.projection(plan.target), status = "prepared" }, "Replay prepared; no traffic sent")
	end)
	local run = N.add(tools, "remote_replay", "danger", "Dispatch a reviewed replay plan once. A timed-out InvokeServer remains outstanding and must not be automatically retried.",
		{ plan_id = str, digest = str, timeout = { type = "number", minimum = 1, maximum = 60 } }, { "plan_id", "digest" }, function(args, ctx)
		local result = replay.run(args.plan_id, args.digest, ctx, args.timeout); result.results = nil; return result
	end); run.timeout = 65
	local export = N.add(tools, "remotes_export", "write", "Export explicit captures or a frozen bounded session snapshot to verified files. Large exports use numbered parts and a completion manifest.",
		{ record_ids = { type = "array", items = str, maxItems = 1000 }, destination = str }, {}, function(args)
		local data, why = exports.captures(args.record_ids, args.destination); return N.result(data, why or "Verified capture export")
	end); export.needs = { "fs" }
	local import = N.add(tools, "remotes_import", "write", "Open a validated capture file as offline records. Import never starts capture, resolves stale identities, or sends traffic.", { path = str }, { "path" }, function(args)
		local count, why = exports.import(args.path); if not count then return N.fail(why) end; return N.result({ imported = count, offline = true, sessionId = records.state().offlineSessionId }, "Imported offline captures")
	end); import.needs = { "fs" }
	N.add(tools, "remote_rule", "danger", "Explicit exact-target outgoing blocking rule. InvokeServer requires local_error policy. Stop disarms all rules; excluding logs is a separate operation.",
		{ action = str, session_id = str, expected_revision = num, instance_id = str, method = str, policy = str, rule_id = str }, { "action", "session_id", "expected_revision" }, function(args, ctx)
		watchRevocation(); local state, why = capture.setRule(args.action, { sessionId = args.session_id, revision = args.expected_revision, remoteId = args.instance_id, method = args.method, policy = args.policy, ruleId = args.rule_id, ownerSessionId = ctx.session and ctx.session.id }, "tool")
		return N.result(state, why or "Traffic rules updated")
	end)
	return tools
end
