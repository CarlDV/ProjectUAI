-- The transcript.
--
-- It is a pure function of the session's event log: `attach` subscribes to a
-- session, replays whatever it missed, and renders each new event as it arrives.
-- That is what makes rebuilding on a layout-mode change safe -- switching a phone
-- from portrait to landscape rebuilds the whole view and loses nothing.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local message = env.require("ui/chat/message")

	local M = {}

	function M.new(parent, props)
		props = props or {}

		local scroll = P.scroll(parent, {
			name = "Transcript",
			size = props.size or UDim2.new(1, 0, 1, 0),
			gap = theme.space.md,
			padding = { x = theme.space.md, top = theme.space.md, bottom = theme.space.md },
			fade = false,
		})

		local view = {
			scroll = scroll,
			order = 0,
			tools = {},
			working = nil,
			agentHandle = nil,
			session = nil,
			unsubscribe = nil,
			pinned = true,
		}

		-- Autoscroll only when the user is already at the bottom. Yanking someone
		-- back down while they are reading earlier output is the most irritating
		-- thing a chat view can do.
		local function follow(force)
			if force or view.pinned then
				scroll.toBottom()
			end
		end

		scroll.instance:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			view.pinned = scroll.atBottom(56)
		end)

		local function nextOrder()
			view.order = view.order + 1
			return view.order
		end

		local function clearWorking()
			if view.working then
				pcall(function() view.working.root:Destroy() end)
				view.working = nil
			end
		end

		-- The working row is transient and always belongs at the end of the
		-- transcript, so it takes an order no real row will reach rather than the next
		-- sequential one. Otherwise a tool row created while it is up sorts below it
		-- and the indicator ends up stranded in the middle of the conversation.
		local WORKING_ORDER = 1e6

		local function ensureWorking()
			if not view.working then
				view.working = message.working(scroll.instance, WORKING_ORDER)
			end
			return view.working
		end

		-- Progressive reveal.
		--
		-- No Roblox HTTP transport reads a body incrementally, so a reply arrives whole
		-- and there is nothing to stream. The motion is manufactured here instead: the
		-- bubble is built empty and filled over a fixed number of ticks, so a long
		-- answer takes the same time to land as a short one rather than crawling.
		-- Revealed in chunks, not per character, because setText re-renders the whole
		-- markdown tree on each call.
		local REVEAL_TICKS = 40
		local REVEAL_STEP = 0.04

		local function stopReveal(complete)
			local reveal = view.reveal
			if not reveal then return end
			view.reveal = nil
			pcall(reveal.stop)
			-- Whatever interrupts a reveal, the full text still has to land: a half
			-- written answer left in the transcript would be a far worse bug than the
			-- missing animation this replaces.
			if complete and reveal.handle then
				pcall(reveal.handle.setText, reveal.text)
			end
		end

		local function revealAgent(text)
			local handle = message.agent(scroll.instance, "", nextOrder())
			view.agentHandle = handle
			if responsive.reduceMotion then
				handle.setText(text)
				follow()
				return handle
			end
			local shown = 0
			local step = math.max(1, math.ceil(#text / REVEAL_TICKS))
			local reveal = { handle = handle, text = text }
			reveal.stop = clock.interval(REVEAL_STEP, function()
				shown = math.min(#text, shown + step)
				handle.setText(text:sub(1, shown))
				follow()
				if shown >= #text then stopReveal(false) end
			end)
			view.reveal = reveal
			return handle
		end

		function view.empty()
			stopReveal(false)
			scroll.clear()
			view.order = 0
			view.tools = {}
			view.working = nil
			view.agentHandle = nil
			view.pinned = true
		end

		function view.greeting()
			local providers = env.require("provider/registry")
			local caps = env.require("runtime/caps")
			if providers.count() == 0 then
				C.emptyState(scroll.instance, {
					title = "No provider configured",
					description = "Add an OpenAI-compatible endpoint to start. Anything that speaks /v1/chat/completions works: a hosted API, a relay, or a local server.",
					action = "Open providers",
					onAction = function()
						env.require("ui/app").show("providers")
					end,
					layoutOrder = nextOrder(),
				})
				return
			end
			local record = providers.active()
			message.notice(scroll.instance, {
				tone = "info",
				text = string.format("Ready on %s. %s", providers.summary(record), caps.summary()),
			}, nextOrder())
		end

		-- One event in, one row out. Anything not listed is deliberately ignored:
		-- the log carries more than a transcript should show.
		function view.render(event)
			if event.kind == "user" then
				stopReveal(true)
				clearWorking()
				view.agentHandle = nil
				message.user(scroll.instance, event.text, nextOrder())
				view.pinned = true
				follow(true)
			elseif event.kind == "status" then
				if event.text and event.text ~= "Ready" then
					ensureWorking().set(event.text)
					follow()
				elseif event.text == "Ready" then
					clearWorking()
				end
			elseif event.kind == "request:start" then
				-- The entire HTTP round trip sits between this and request:done with no
				-- events in between, and it can run for the better part of a minute.
				-- Without a row here that whole wait looks like nothing is happening,
				-- which is the single largest gap in the turn.
				ensureWorking().set("Contacting " .. tostring(event.provider))
				follow()
			elseif event.kind == "assistant:reasoning" then
				message.reasoning(scroll.instance, event.text, nextOrder())
				follow()
			elseif event.kind == "assistant:text" then
				if util.trim(event.text) ~= "" then
					stopReveal(true)
					clearWorking()
					revealAgent(event.text)
					follow()
				end
			elseif event.kind == "tool:call" then
				-- The working row deliberately survives a tool call: it is the "this
				-- turn is still running" indicator and it sorts last, so it stays put
				-- below the tool rows instead of being destroyed and rebuilt -- which
				-- restarted the spinner's phase and left the following request with no
				-- indicator at all.
				local handle = message.toolCall(scroll.instance, event, nextOrder())
				view.tools[event.id or util.uid("tool")] = handle
				follow()
			elseif event.kind == "tool:progress" then
				-- Progress has no id: it belongs to whichever call is still open.
				for _, handle in pairs(view.tools) do
					if handle.progress then handle.progress(event.text) end
				end
			elseif event.kind == "tool:result" or event.kind == "tool:error" then
				local handle = view.tools[event.id]
				if handle then
					handle.finish(event)
					view.tools[event.id] = nil
				else
					message.notice(scroll.instance, {
						tone = event.kind == "tool:error" and "bad" or "info",
						text = string.format("%s: %s", tostring(event.name), util.ellipsis(event.text, 200)),
					}, nextOrder())
				end
				follow()
			elseif event.kind == "request:retry" then
				message.notice(scroll.instance, {
					tone = "warn",
					text = string.format("%s: %s, retrying in %.1fs (attempt %d of %d)",
						tostring(event.provider), tostring(event.reason), event.wait or 0,
						event.attempt or 1, event.attempts or 1),
				}, nextOrder())
				follow()
			elseif event.kind == "provider:switch" then
				message.notice(scroll.instance, {
					tone = "warn",
					text = string.format("%s failed, trying %s", tostring(event.from), tostring(event.to)),
				}, nextOrder())
				follow()
			elseif event.kind == "compact" then
				message.notice(scroll.instance, {
					tone = "info",
					text = "Older turns were summarised to stay inside the context budget.",
				}, nextOrder())
				follow()
			elseif event.kind == "error" then
				stopReveal(true)
				clearWorking()
				message.notice(scroll.instance, {
					tone = "bad",
					text = tostring(event.message),
				}, nextOrder())
				follow()
			elseif event.kind == "abort" then
				stopReveal(true)
				clearWorking()
				message.notice(scroll.instance, { tone = "warn", text = "Stopped." }, nextOrder())
				follow()
			elseif event.kind == "cleared" then
				view.empty()
				view.greeting()
			end
		end

		-- Replays the session's own log, so opening the panel mid-turn shows what
		-- has happened rather than an empty pane.
		function view.attach(session)
			if view.unsubscribe then
				view.unsubscribe()
				view.unsubscribe = nil
			end
			view.empty()
			view.session = session
			if not session then
				view.greeting()
				return
			end

			if #session.log == 0 then
				view.greeting()
			else
				for _, event in ipairs(session.log) do
					local ok, err = pcall(view.render, event)
					if not ok then env.require("runtime/log").warn("ui", "replay failed", err) end
				end
			end
			if not session.busy then clearWorking() end

			view.unsubscribe = session.events:connect(function(event)
				local ok, err = pcall(view.render, event)
				if not ok then env.require("runtime/log").warn("ui", "render failed", err) end
			end)
			follow(true)
		end

		function view.destroy()
			if view.unsubscribe then view.unsubscribe() end
			pcall(function() scroll.instance:Destroy() end)
		end

		return view
	end

	return M
end
