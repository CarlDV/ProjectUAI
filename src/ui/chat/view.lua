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

		local function ensureWorking()
			if not view.working then
				view.working = message.working(scroll.instance, nextOrder())
			end
			return view.working
		end

		function view.empty()
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
			elseif event.kind == "assistant:reasoning" then
				message.reasoning(scroll.instance, event.text, nextOrder())
				follow()
			elseif event.kind == "assistant:text" then
				if util.trim(event.text) ~= "" then
					clearWorking()
					view.agentHandle = message.agent(scroll.instance, event.text, nextOrder())
					follow()
				end
			elseif event.kind == "tool:call" then
				clearWorking()
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
				clearWorking()
				message.notice(scroll.instance, {
					tone = "bad",
					text = tostring(event.message),
				}, nextOrder())
				follow()
			elseif event.kind == "abort" then
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
