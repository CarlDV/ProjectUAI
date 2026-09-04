-- The permission prompt.
--
-- The loop blocks on a thread while this is open, so it has to be reliable: one
-- prompt at a time, queued, and always resolved -- closing it counts as a refusal.
-- An unresolved prompt would park the agent until its own timeout.
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
			width = 400,
			dismissable = true,
			onClose = function() answer(false) end,
		})
		if not modal then
			answer(false)
			return
		end

		P.badge(modal.content, {
			text = tostring(request.risk or "write"),
			tone = RISK_TONE[request.risk or "write"] or "warn",
			layoutOrder = 1,
		})

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
			size = UDim2.new(1, -46, 0, 0),
			auto = "Y",
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

		P.button(modal.footer, {
			text = "Deny",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function()
				modal.close()
			end,
		})
		P.button(modal.footer, {
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

	-- Subscribes to a session. Safe to call again on a new session; the old
	-- subscription is dropped.
	function M.attach(session)
		if M.unsubscribe then
			M.unsubscribe()
			M.unsubscribe = nil
		end
		if not session then return end
		M.unsubscribe = session.events:connect(function(event)
			if event.kind ~= "permission:ask" then return end
			if M.showing then
				M.queue[#M.queue + 1] = event
			else
				present(event)
			end
		end)
	end

	return M
end
