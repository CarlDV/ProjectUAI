-- The question prompt.
--
-- ask_user raises one of these: the model has met a fork it cannot resolve from the
-- world and the turn is parked on a thread until it is answered. Same contract as the
-- permission prompt -- one at a time, queued, always resolved, closing counts as
-- dismissed -- because the failure mode is the same too: an unresolved question parks
-- the agent until its own timeout.
--
-- It listens to every conversation rather than the open one, for the same reason the
-- permission prompt does: a second conversation left running in the background can
-- ask into a stream nobody is subscribed to, and a question nobody can see is ten
-- minutes of a turn spent for nothing.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")

	local M = { queue = {}, showing = false }

	local function present(request)
		M.showing = true

		local answered = false
		local function reply(text)
			if answered then return end
			answered = true
			pcall(request.resolve, text)
			M.showing = false
			-- Drain the next question on the same frame, so a batch of asks does not
			-- make the user wait between answers.
			local next_request = table.remove(M.queue, 1)
			if next_request then present(next_request) end
		end

		local options = {}
		for _, value in ipairs(type(request.options) == "table" and request.options or {}) do
			local clean = util.trim(tostring(value))
			if clean ~= "" and #options < 4 then options[#options + 1] = clean end
		end

		local modal = overlay.modal({
			title = "The agent is asking",
			description = tostring(request.question or ""),
			width = theme.size.modalWide,
			dismissable = true,
			-- Dismissed rather than cancelled: a question is not a permission, and the
			-- difference between "no" and "never mind" is one the model cannot act on.
			-- The tool result says the question was dismissed, which is a fact the
			-- next turn can work with.
			onClose = function() reply("") end,
		})
		if not modal then
			reply("")
			return
		end

		-- Which conversation is asking, for the same reason the permission prompt
		-- states it: with one queue serving every open conversation, a question on its
		-- own does not say whose turn it belongs to.
		if request.sessionTitle then
			P.text(modal.content, {
				name = "AskingIn",
				text = "in " .. tostring(request.sessionTitle),
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 1,
			}).Size = UDim2.new(1, 0, 0, 0)
		end

		-- The concrete options, each a full-width row rather than a menu item: a menu
		-- hides every answer but the one on top, and a choice the reader has to scroll
		-- to discover is a choice they did not know they had.
		for index, option in ipairs(options) do
			P.button(modal.content, {
				name = "AskOption" .. tostring(index),
				text = option,
				variant = "secondary",
				fill = true,
				layoutOrder = index + 1,
				onClick = function()
					reply(option)
					modal.close()
				end,
			})
		end

		-- The open answer. Always offered -- an option list is the model's guess at
		-- the answers worth having, and the real answer is allowed to be none of them.
		local field
		field = P.field(modal.content, {
			name = "AskField",
			placeholder = "Or type an answer",
			size = UDim2.new(1, 0, 0, 0),
			layoutOrder = #options + 2,
			onSubmit = function(text)
				reply(util.trim(text))
				modal.close()
			end,
		})
		P.button(modal.footer, {
			name = "AskDismiss",
			text = "Dismiss",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function() modal.close() end,
		})
		P.button(modal.footer, {
			name = "AskSend",
			text = "Send",
			variant = "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				reply(util.trim(field.get()))
				modal.close()
			end,
		})
	end

	local function onEvent(session, event)
		if event.kind ~= "ask:user" then return end
		-- Headless sessions never emit this far -- the tool refuses them in words --
		-- but the guard is cheap insurance against a host wiring one in.
		if session and session.headless then return end
		local request = {
			question = event.question,
			options = event.options,
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
			sessions.anyEvent:connect(onEvent), "ask.watch")
		return M
	end

	return M
end
