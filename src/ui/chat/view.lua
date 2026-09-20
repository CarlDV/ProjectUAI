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
			gap = theme.space.lg,
			padding = { x = theme.space.lg, top = theme.space.xl, bottom = theme.space.lg },
			fade = false,
		})

		local view = {
			scroll = scroll,
			order = 0,
			tools = {},
			agents = {},
			working = nil,
			-- The open activity block, if the transcript is mid-run. Tool calls, the
			-- thinking between them and the notices they raise all go inside it; prose
			-- from either side closes it.
			run = nil,
			agentHandle = nil,
			session = nil,
			unsubscribe = nil,
			pinned = true,
		}

		local latest = P.button(parent, {
			name = "Latest",
			text = "Jump to latest",
			variant = "secondary",
			icon = "chevron",
			iconDirection = "down",
			radius = theme.radius.pill,
			size = "sm",
			anchor = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, -theme.space.sm),
			zIndex = theme.z.raised,
			onClick = function()
				view.pinned = true
				scroll.toBottom()
			end,
		})
		latest.instance.Visible = false

		-- Autoscroll only when the user is already at the bottom. Yanking someone
		-- back down while they are reading earlier output is the most irritating
		-- thing a chat view can do.
		local followQueued = false
		local function follow(force)
			if force then view.pinned = true end
			if view.welcomeCard then return end
			if not view.pinned or followQueued then return end
			followQueued = true
			-- Let text measurement settle before following; several events can land together.
			clock.delay(0, function()
				followQueued = false
				if scroll.instance.Parent and view.pinned and not view.welcomeCard then scroll.toBottom() end
			end)
		end
		scroll.layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() follow() end)
		scroll.instance:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() follow() end)

		-- Called when the window is shown again after being minimized. A hidden
		-- scroll frame's canvas position is not trustworthy and `pinned` may have
		-- been left false by a scroll that happened before the hide, so the newest
		-- message would be off-screen and waiting for a manual scroll. Pinning and
		-- jumping here is the "still at the bottom" the user left.
		function view.repin()
			view.pinned = true
			if view.welcomeCard then
				scroll.instance.CanvasPosition = Vector2.new(0, 0)
			else
				scroll.toBottom()
			end
		end

		scroll.instance:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			view.pinned = view.welcomeCard ~= nil or scroll.atBottom(theme.space.huge)
			latest.instance.Visible = not view.pinned
		end)

		local function nextOrder()
			view.order = view.order + 1
			return view.order
		end

		-- The activity block.
		--
		-- A turn's machinery -- the calls, the thinking between them, a retry notice --
		-- used to be a stack of top-level rows, and the transcript deliberately puts a
		-- paragraph's worth of air between top-level rows. Eight calls therefore read as
		-- eight separate events with the reply lost at the bottom, which is the "too much
		-- tool call" this fixes: one block, one paragraph gap around it, tight lines
		-- inside, and a header that folds the whole run once it has finished.
		--
		-- Only prose closes it, because prose is what a run is between. Closing on
		-- reasoning instead would give a step-per-call turn one block per call and change
		-- nothing, and putting a later row above an earlier one is not an option: the
		-- block takes its layout order when it opens, so anything that has to sort after
		-- the rows already in it has to go in it.
		local function openRun(name)
			if not view.run then
				view.run = message.toolRun(scroll.instance, nextOrder())
			end
			-- The run's header names the tools it holds, so the name of the call
			-- about to be added travels with the opening of its row.
			if name then view.run.pendingName = name end
			return view.run
		end

		local function closeRun()
			view.run = nil
		end

		-- Where a row belongs: inside the open block, or in the transcript itself.
		local function target()
			if view.run then return view.run.rows, view.run.slot() end
			return scroll.instance, nextOrder()
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
		-- Adaptive pacing keeps replies fluid and alive: typing progresses smoothly
		-- by word boundaries with an accent typing indicator.
		local function stopReveal(complete)
			if not view.reveal then return end
			local reveal = view.reveal
			view.reveal = nil
			if reveal.stop then pcall(reveal.stop) end
			if complete and reveal.handle and reveal.text then
				pcall(function()
					reveal.handle.finish(reveal.text)
				end)
			end
		end

		local function revealAgent(text, animate)
			local isHarness = (env.require("runtime/caps").executor or ""):find("OfflineHarness") ~= nil
			-- Structured replies render once. Rebuilding a table or code viewport at
			-- every reveal tick creates layout jumps and repeatedly resets its scroll.
			local structured = false
			for _, block in ipairs(env.require("ui/markdown").blocks(text)) do
				if block.kind == "table" or block.kind == "code" then structured = true; break end
			end
			if not animate or responsive.reduceMotion or isHarness or structured then
				stopReveal(false)
				local handle = message.agent(scroll.instance, text, nextOrder(), view.model, props)
				view.agentHandle = handle
				follow()
				return handle
			end

			stopReveal(true)
			local handle = message.agent(scroll.instance, "", nextOrder(), view.model, props)
			view.agentHandle = handle

			local len = #text
			local targetDuration = util.clamp(0.4 + (len / 1200) * 0.7, 0.45, 1.25)
			local tickInterval = 0.03
			local totalTicks = math.max(12, math.floor(targetDuration / tickInterval))
			local charsPerTick = math.max(1, math.ceil(len / totalTicks))

			local shown = 0
			local reveal = {
				handle = handle,
				text = text,
			}
			view.reveal = reveal

			reveal.stop = clock.interval(tickInterval, function()
				shown = math.min(len, shown + charsPerTick)
				if shown < len then
					local nextSpace = text:find("%s", shown)
					if nextSpace and nextSpace <= shown + 6 then
						shown = nextSpace
					end
				end

				if shown >= len then
					stopReveal(false)
					handle.finish(text)
				else
					-- Reveal only complete UTF-8 characters, including emoji and CJK text.
					local boundary = shown
					while boundary > 0 do
						local byte = text:byte(boundary + 1)
						if not byte or byte < 128 or byte >= 192 then break end
						boundary = boundary - 1
					end
					handle.stream(text:sub(1, boundary))
				end
				follow()
			end)

			handle.root.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					stopReveal(true)
				end
			end)

			follow()
			return handle
		end

		function view.empty()
			stopReveal(false)
			if view.welcomeCard then
				pcall(function() view.welcomeCard:Destroy() end)
				view.welcomeCard = nil
			end
			scroll.clear()
			view.order = 0
			view.tools = {}
			view.agents = {}
			view.working = nil
			view.run = nil
			view.agentHandle = nil
			view.model = nil
			view.pinned = true
			latest.instance.Visible = false
		end


		-- What an empty conversation shows: the greeting, the activity card, and -- on a
		-- client with nothing configured yet -- the one thing to do about that. The card
		-- itself lives in ui/panels/home, which reads agent/stats.
		function view.greeting()
			local providers = env.require("provider/registry")
			if view.welcomeCard then
				pcall(function() view.welcomeCard:Destroy() end)
				view.welcomeCard = nil
			end
			view.welcomeCard = env.require("ui/panels/home").card(scroll.instance, nextOrder(), props)
			scroll.instance.CanvasPosition = Vector2.new(0, 0)
			if providers.count() == 0 then
				C.emptyState(view.welcomeCard, {
					title = "No provider configured",
					description = "Add an OpenAI-compatible endpoint to start. Anything that speaks /v1/chat/completions works: a hosted API, a relay, or a local server.",
					action = "Open providers",
					onAction = function()
						env.require("ui/app").show("providers")
					end,
					layoutOrder = 5,
				})
			end
		end

		-- One event in, one row out. Anything not listed is deliberately ignored:
		-- the log carries more than a transcript should show.
		function view.render(event)
			if event.kind == "user" then
				stopReveal(true)
				clearWorking()
				closeRun()
				if view.welcomeCard then
					pcall(function() view.welcomeCard:Destroy() end)
					view.welcomeCard = nil
				end
				view.agentHandle = nil
				message.user(scroll.instance, event.text, nextOrder(), props)
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
				view.model = event.model or event.provider
				-- The entire HTTP round trip sits between this and request:done with no
				-- events in between, and it can run for the better part of a minute.
				-- Without a row here that whole wait looks like nothing is happening,
				-- which is the single largest gap in the turn.
				ensureWorking().set("Contacting " .. tostring(event.provider))
				follow()
			elseif event.kind == "assistant:reasoning" then
				if util.trim(event.text or "") == "" then return end
				local run = openRun()
				if run.thought then run.thought.append(event.text)
				else run.thought = message.reasoning(run.rows, event.text, run.slot()) end
				follow()
			elseif event.kind == "assistant:text" then
				local trimmed = util.trim(event.text or "")
				if trimmed ~= "" and trimmed ~= "..." and trimmed ~= "…" then
					stopReveal(true)
					clearWorking()
					closeRun()
					-- The reveal is for a reply that is landing now. A message replayed out
					-- of the log arrived long ago and goes up whole, or reopening a panel
					-- would re-type the entire conversation.
					revealAgent(event.text, view.replaying ~= true)
					follow()
				end
			elseif event.kind == "tool:call" then
				-- The working row deliberately survives a tool call: it is the "this
				-- turn is still running" indicator and it sorts last, so it stays put
				-- below the tool rows instead of being destroyed and rebuilt -- which
				-- restarted the spinner's phase and left the following request with no
				-- indicator at all.
				local run = openRun(event.name)
				run.thought = nil
				local handle = message.toolCall(run.rows, event, run.slot())
				handle.run = run
				run.opened()
				view.tools[event.id or util.uid("tool")] = handle
				follow()
			elseif event.kind == "tool:progress" then
				local handle = event.id and view.tools[event.id]
				-- Older hosts may emit unaddressed progress. It is only unambiguous
				-- when a single call is open; never copy it onto unrelated parallel work.
				if not event.id and util.count(view.tools) == 1 then
					local _, only = next(view.tools)
					handle = only
				end
				if handle and handle.progress then handle.progress(event.text) end
				follow()
			elseif event.kind == "tool:result" or event.kind == "tool:error" then
				local handle = view.tools[event.id]
				if handle then
					handle.finish(event)
					if handle.run then handle.run.closed(event.kind ~= "tool:error" and event.ok ~= false) end
					view.tools[event.id] = nil
				else
					local into, order = target()
					message.notice(into, {
						tone = event.kind == "tool:error" and "bad" or "info",
						text = string.format("%s: %s", tostring(event.name), util.ellipsis(event.text, 200)),
					}, order)
				end
				follow()
			elseif event.kind == "subagent:start" then
				-- Nested under the call that started it while that row is still tracked,
				-- so a delegated task reads as one block rather than as a card floating
				-- next to its own tool row. Standalone if the row is gone, which happens
				-- when the log has been trimmed past it.
				local host = event.call and view.tools[event.call] or nil
				if host and host.nest then
					view.agents[event.id] = message.subagent(host.nest(), event, 1, { nested = true })
				else
					local into, order = target()
					view.agents[event.id] = message.subagent(into, event, order, {})
				end
				follow()
			elseif event.kind == "subagent:status" then
				local handle = view.agents[event.id]
				if handle then handle.status(event) end
			elseif event.kind == "subagent:text" then
				local handle = view.agents[event.id]
				if handle then
					handle.say(event)
					follow()
				end
			elseif event.kind == "subagent:tool" then
				local handle = view.agents[event.id]
				if handle then
					handle.tool(event)
					follow()
				end
			elseif event.kind == "subagent:tool:done" then
				local handle = view.agents[event.id]
				if handle then handle.toolDone(event) end
			elseif event.kind == "subagent:done" then
				local handle = view.agents[event.id]
				if handle then
					handle.finish(event)
					view.agents[event.id] = nil
					follow()
				end
			elseif event.kind == "request:retry" then
				local into, order = target()
				message.notice(into, {
					tone = "warn",
					text = string.format("%s: %s, retrying in %.1fs (attempt %d of %d)",
						tostring(event.provider), tostring(event.reason), event.wait or 0,
						event.attempt or 1, event.attempts or 1),
				}, order)
				follow()
			elseif event.kind == "provider:switch" then
				local into, order = target()
				message.notice(into, {
					tone = "warn",
					text = string.format("%s failed, trying %s", tostring(event.from), tostring(event.to)),
				}, order)
				follow()
			elseif event.kind == "compact" then
				local into, order = target()
				message.notice(into, {
					tone = "info",
					text = "Older turns were summarised to stay inside the context budget.",
				}, order)
				follow()
			elseif event.kind == "error" then
				stopReveal(true)
				clearWorking()
				closeRun()
				message.notice(scroll.instance, {
					tone = "bad",
					text = tostring(event.message),
				}, nextOrder())
				follow()
			elseif event.kind == "abort" then
				stopReveal(true)
				clearWorking()
				closeRun()
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
			-- Re-showing the conversation that is already on screen must not tear the
			-- transcript down and replay every event again. On a long session that
			-- replay is hundreds of rows rebuilt from scratch on each open -- the lag
			-- when the window comes back -- and the half-built tree drawn over the old
			-- one for a frame is the overlap someone sees before it settles. Nothing
			-- changed, so the live view is already correct: just land at the bottom,
			-- the way `repin` does when the window is shown. The composer guards the
			-- same way on `draftId`.
			if session and view.session == session and view.unsubscribe then
				-- The transcript is already correct, but the working indicator is
				-- transient and not in the log, so a conversation that went busy while
				-- the panel was elsewhere has to have it restored here the same way a
				-- full replay would. Landing at the bottom is the rest of what a re-show
				-- owes the reader.
				if session.busy then
					ensureWorking().set(session.status or "Working")
				else
					clearWorking()
				end
				view.repin()
				return
			end
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
				view.replaying = true
				-- A restored conversation is replayed whole, and on a long one that is
				-- hundreds of rows built in one synchronous pass -- the freeze at the end
				-- of a boot, after the loader has already reached the interface. During
				-- the first mount the bootstrap sets this hook to yield the thread on a
				-- budget, so the replay renders in a few slices and the boot indicator
				-- keeps animating over it. Nil on every later attach, so switching a
				-- conversation by hand stays a single instant rebuild.
				local yield = env.onMountPhase
				local count = 0
				for _, event in ipairs(session.log) do
					local ok, err = pcall(view.render, event)
					if not ok then env.require("runtime/log").warn("ui", "replay failed", err) end
					count = count + 1
					if yield and count % 12 == 0 then yield("restoring your conversation") end
				end
				view.replaying = false
			end
			-- Anything still open after a replay is a call or a dispatch whose outcome is
			-- not in the log: trimmed away by the stored transcript's own ceiling, or lost
			-- because the turn died before it landed. On a live session those are genuinely
			-- in flight, so only a settled one is swept.
			if session.busy then
				ensureWorking().set(session.status or "Working")
			else
				clearWorking()
				closeRun()
				for id, handle in pairs(view.tools) do
					if handle.stale then pcall(handle.stale) end
					-- The block the row sits in is counting outstanding calls, and a row
					-- swept as stale is one it will never see a result for.
					if handle.run then pcall(handle.run.closed) end
					view.tools[id] = nil
				end
				for id, handle in pairs(view.agents) do
					if handle.stale then pcall(handle.stale) end
					view.agents[id] = nil
				end
			end

			view.unsubscribe = session.events:connect(function(event)
				local ok, err = pcall(view.render, event)
				if not ok then env.require("runtime/log").warn("ui", "render failed", err) end
			end)
			follow(true)
		end

		function view.destroy()
			stopReveal(false)
			pcall(function() latest.instance:Destroy() end)
			if view.unsubscribe then view.unsubscribe() end
			pcall(function() scroll.instance:Destroy() end)
		end

		return view
	end

	return M
end
