-- The permission prompt.
--
-- The loop blocks on a thread while this is open, so it has to be reliable: one
-- prompt at a time, queued, and always resolved -- closing it counts as a refusal.
-- An unresolved prompt would park the agent until its own timeout.
--
-- It listens to every conversation rather than to the open one. It used to attach to
-- whichever session the transcript was showing, which meant a second conversation
-- left running in the background asked for permission into a stream nobody was
-- subscribed to: no prompt appeared, its three-minute deadline expired, and every
-- write it had planned came back to the model as a refusal. Since a prompt can now
-- arrive from a conversation that is not on screen, the modal says which one.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")

	local M = { queue = {}, showing = false }

	local RISK_TONE = { read = "info", write = "warn", danger = "bad" }

	local RISK_TEXT = {
		read = "This only reads. Nothing changes.",
		write = "This changes something in the game or on disk.",
		danger = "This runs code, deletes data, or reaches the server. It cannot be undone.",
	}

	local function present(request)
		M.showing = true

		local remember = false
		local resolved = false

		local function answer(allowed)
			if resolved then return end
			resolved = true
			pcall(request.resolve, allowed, remember)
			M.showing = false
			-- Drain the next prompt on the same frame so a batch of tool calls does
			-- not make the user wait between decisions.
			local next_request = table.remove(M.queue, 1)
			if next_request then present(next_request) end
		end

		local modal = overlay.modal({
			title = "Allow " .. tostring(request.name) .. "?",
			description = RISK_TEXT[request.risk or "write"] or RISK_TEXT.write,
			width = theme.size.modalWide,
			dismissable = true,
			onClose = function() answer(false) end,
		})
		if not modal then
			answer(false)
			return
		end

		local badgeRow = P.row(modal.content, {
			name = "Asking",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			layoutOrder = 1,
		})
		P.badge(badgeRow, {
			text = tostring(request.risk or "write"),
			tone = RISK_TONE[request.risk or "write"] or "warn",
			layoutOrder = 1,
		})
		-- Which conversation is asking. With one prompt queue serving every open
		-- conversation, "Allow run_luau?" on its own does not say whose turn it
		-- belongs to -- and answering the wrong one is not recoverable.
		if request.sessionTitle then
			P.text(badgeRow, {
				name = "AskingIn",
				text = "in " .. tostring(request.sessionTitle),
				role = "caption",
				color = theme.color.textTertiary,
				truncate = true,
				size = UDim2.new(0, 0, 0, theme.text.caption.height),
				flex = "Fill",
				layoutOrder = 2,
			})
		end

		if request.description then
			local description = P.text(modal.content, {
				text = tostring(request.description),
				role = "small",
				color = theme.color.textSecondary,
				wrap = true,
				auto = "Y",
				layoutOrder = 2,
			})
			description.Size = UDim2.new(1, 0, 0, 0)
		end

		-- The arguments are the whole point of the prompt: "allow run_luau" means
		-- nothing without seeing the code.
		local argsText = ""
		local ok, encoded = pcall(util.encode, request.args or {})
		if ok then argsText = encoded end
		if util.trim(argsText) ~= "" and argsText ~= "[]" and argsText ~= "{}" then
			local box = P.frame(modal.content, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				bg = theme.color.codeSurface,
				radius = theme.radius.md,
				padding = theme.space.sm,
				layoutOrder = 3,
			})
			P.stroke(box, theme.color.codeBorder)
			local label = P.text(box, {
				text = (util.truncate(argsText, 900)),
				role = "monoSmall",
				color = theme.color.textSecondary,
				wrap = true,
				auto = "Y",
			})
			label.Size = UDim2.new(1, 0, 0, 0)
		end

		local rememberRow = P.row(modal.content, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 4,
		})
		local rememberText = P.column(rememberRow, {
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			flex = "Fill",
			gap = 0,
			layoutOrder = 1,
		})
		P.text(rememberText, { text = "Remember this answer", role = "small" })
		P.text(rememberText, {
			text = "Applies to every future " .. tostring(request.name) .. " call. Change it later in the Tools panel.",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		local switch = C.switch(rememberRow, {
			value = false,
			onChange = function(value) remember = value end,
		})
		switch.instance.LayoutOrder = 2

		-- Named, like every other control that decides something. Two buttons both
		-- called "Button" is unreadable from a dump and unreachable from a test, and
		-- this is the one dialog in the client where pressing the wrong one is not
		-- recoverable.
		P.button(modal.footer, {
			name = "PermissionDeny",
			text = "Deny",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function()
				modal.close()
			end,
		})
		P.button(modal.footer, {
			name = "PermissionAllow",
			text = "Allow",
			variant = request.risk == "danger" and "danger" or "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				answer(true)
				modal.closed = true
				pcall(function() modal.scrim:Destroy() end)
			end,
		})
	end

	-- Watches every conversation in the client.
	--
	-- `attach` is kept because the app calls it whenever the open conversation changes,
	-- but it no longer decides what is heard: the subscription is to the session
	-- module's own fan-out, made once and never dropped, so a prompt from a
	-- conversation nobody is looking at still reaches the screen.
	local function onEvent(session, event)
		if event.kind ~= "permission:ask" then return end
		-- A subagent is headless and its prompts are forwarded onto its parent's
		-- stream by agent/subagent, so the child's own copy would be a second modal
		-- for one decision.
		if session and session.headless then return end
		local request = {
			id = event.id,
			name = event.name,
			risk = event.risk,
			description = event.description,
			args = event.args,
			resolve = event.resolve,
			sessionTitle = session and session.title or nil,
		}
		if M.showing then
			M.queue[#M.queue + 1] = request
		else
			present(request)
		end
	end

	function M.watch()
		if M.watching then return M end
		local sessions = env.require("agent/session")
		M.watching = env.require("runtime/dispose").add(
			sessions.anyEvent:connect(onEvent), "permission.watch")
		return M
	end

	-- Kept for the app, which calls it on every conversation switch. Starting the
	-- global watch is all it has left to do.
	function M.attach()
		return M.watch()
	end

	return M
end
