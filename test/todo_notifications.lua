-- Geometry, disclosure and notification interaction regressions.
-- Native font rasterization is not modelled; line boxes and control geometry are.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, luau = require("env"), require("luau")
local passed, failed = 0, 0
local function check(label, value) assert(value, label); passed = passed + 1 end
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function scenario(name, fn)
	local ok, err = pcall(fn)
	if ok then print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function fixture()
	local h, cache, settings = envMock.new(), {}, {}
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer,
		uis = h.services.UserInputService, guisvc = h.services.GuiService, tween = h.services.TweenService,
		info = { folder = "UAI", version = "test" } }
	function env.require(id)
		if cache[id] then return cache[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb"))
		local source = file:read("*a"); file:close()
		local chunk = assert(luau.load(source, id)); setfenv(chunk, h.sandbox)
		cache[id] = chunk()(env)
		return cache[id]
	end
	cache["runtime/config"] = {
		get = function(path, default) if settings[path] ~= nil then return settings[path] end return default end,
		set = function(path, value) settings[path] = value end,
		changed = env.require("runtime/signal").new("settings"),
	}
	local responsive = env.require("ui/responsive")
	local root = h.Instance.new("Frame", h.coreGui)
	local function viewport(width, height, touch, keyboard)
		responsive.viewport = h.dt.Vector2.new(width, height)
		responsive.inset = h.dt.Vector2.new(0, 0)
		responsive.bottomInset, responsive.keyboardHeight = 0, keyboard or 0
		responsive.touch, responsive.console = touch == true, false
		responsive.mode = width < 520 and "sheet" or "window"
		root.Size = h.dt.UDim2.fromOffset(width, height)
		responsive.changed:fire({ reason = "test" })
	end
	viewport(720, 600)
	return h, env, root, settings, viewport
end
local function centreY(node) return node.AbsolutePosition.Y + node.AbsoluteSize.Y / 2 end

scenario("todo markers stay centred at every text scale and density", function()
	local h, env, root, settings = fixture()
	local state, theme = env.require("agent/state"), env.require("ui/theme")
	for _, density in ipairs({ "comfortable", "compact" }) do
		for _, scale in ipairs({ 0.85, 1, 1.4 }) do
			settings["ui.density"], settings["ui.fontScale"] = density, scale
			theme.rebuild()
			local session = {}
			state.setTodos({ { text = "Pending", status = "pending" }, { text = "Active", status = "active" },
				{ text = "Done", status = "done" }, { text = "Skipped", status = "dropped" } }, session)
			local plan = env.require("ui/chat/todo").new(root, { session = session })
			for index = 1, 4 do
				local row = plan.shell:FindFirstChild("TodoItem" .. index, true)
				local marker, label = row:FindFirstChild("TodoMarker"), row:FindFirstChild("TodoText")
				check("status marker shares the text centre", math.abs(centreY(marker) - centreY(label)) < 0.01)
				check("one line has room for scaled text", label.AbsoluteSize.Y >= theme.text.small.height)
				check("wrapped task retains the full available text width", label.TextWrapped and label.Size.X.Scale == 1)
				local glyph = marker:FindFirstChild("Status") or marker:FindFirstChild("IconCheck") or marker:FindFirstChild("IconMinus")
				check("glyph is centred within its marker column", glyph and math.abs(centreY(glyph) - centreY(marker)) < 0.01)
			end
			plan.destroy()
		end
	end
	check("destroyed todo strips release subscriptions", state.todosChanged:count() == 0)
	check("no UI property type errors", #h.instanceState.typeErrors == 0)
end)

scenario("todo disclosure survives updates and switching without taking over the chat", function()
	local h, env, root = fixture()
	local state = env.require("agent/state")
	local alpha, beta = {}, {}
	state.setTodos({ { text = "Working on alpha", status = "active" } }, alpha)
	state.setTodos({ { text = "Working on beta", status = "active" } }, beta)
	local plan = env.require("ui/chat/todo").new(root, { session = alpha })
	local list = plan.shell:FindFirstChild("Items")
	local toggle = plan.shell:FindFirstChild("PlanToggle")
	check("new active task opens automatically", list.Visible)
	toggle.Activated:Fire()
	state.setTodos({ { text = "Updated alpha", status = "active" } }, alpha)
	check("updates respect manual collapse", not list.Visible)
	plan.destroy()
	plan = env.require("ui/chat/todo").new(root, { session = alpha })
	list, toggle = plan.shell:FindFirstChild("Items"), plan.shell:FindFirstChild("PlanToggle")
	check("rebuilding the strip preserves its disclosure", not list.Visible)
	plan.attach(beta)
	check("other conversation has its own disclosure", list.Visible)
	plan.attach(alpha)
	check("returning preserves manual collapse", not list.Visible)
	state.setTodos({ { text = "Orphan task", status = "active" } })
	check("sessionless updates do not replace this plan", has(plan.shell:FindFirstChild("TodoText", true).Text, "alpha"))
	toggle.Activated:Fire()
	list:FindFirstChildOfClass("UIListLayout").AbsoluteContentSize = h.dt.Vector2.new(720, 2000)
	check("long plan is capped to a third of the conversation", list.Size.Y.Offset <= root.AbsoluteSize.Y / 3)
	root.AbsoluteSize = h.dt.Vector2.new(360, 240)
	check("plan shrinks with available chat height", list.Size.Y.Offset <= 80)
	state.setTodos({ { text = "Completed", status = "done" }, { text = "Skipped", status = "dropped" } }, alpha)
	h.sched.advance(0.3)
	check("skipped tasks do not leave progress incomplete", plan.shell:FindFirstChild("Completed", true).Size.X.Scale == 1)
	check("summary distinguishes completed and skipped tasks", has(plan.shell:FindFirstChild("PlanSummary", true).Text, "1 of 1 complete") and has(plan.shell:FindFirstChild("PlanSummary", true).Text, "1 skipped"))
	state.clearTodos(alpha)
	check("empty plan disappears", not plan.shell.Visible)
	state.setTodos({ { text = "New task", status = "active" } }, alpha)
	check("a new plan starts with automatic disclosure", list.Visible)
	plan.destroy()
end)

scenario("toast text, status icons and dismissal controls align and fit", function()
	local h, env, root, settings, viewport = fixture()
	local theme, overlay = env.require("ui/theme"), env.require("ui/overlay")
	overlay.mount(root)
	for _, density in ipairs({ "comfortable", "compact" }) do
		for _, scale in ipairs({ 0.85, 1, 1.4 }) do
			settings["ui.density"], settings["ui.fontScale"] = density, scale
			theme.rebuild()
			for _, touch in ipairs({ false, true }) do
				viewport(360, 480, touch)
				local entry = overlay.toast("Saved", "good", 100)
				h.sched.advance(0.3)
				local indicator = entry.card:FindFirstChild("Indicator")
				local label = entry.card:FindFirstChild("Message", true)
				local dismiss = entry.card:FindFirstChild("DismissNotification")
				check("short message centres with its icon", math.abs(centreY(indicator) - centreY(label)) < 0.01)
				check("dismiss control shares that centre", math.abs(centreY(dismiss) - centreY(label)) < 0.01)
				check("dismiss target respects input mode", dismiss.AbsoluteSize.Y >= (touch and 44 or 28))
				entry.close(true)
			end
		end
	end
	check("no notification property errors", #h.instanceState.typeErrors == 0)
end)

scenario("long actionable toasts retain content, bound the stack and pause expiry", function()
	local h, env, root, settings, viewport = fixture()
	local theme, overlay, responsive = env.require("ui/theme"), env.require("ui/overlay"), env.require("ui/responsive")
	overlay.mount(root)
	viewport(360, 400, true)
	local long = string.rep("A detailed notification. ", 50)
	local activated = 0
	local first
	for index = 1, 4 do
		local entry = overlay.toast(long, "info", 100, { title = "Conversation " .. index, actionText = "Open chat", onActivate = function() activated = activated + 1 end })
		first = first or entry
	end
	check("oldest toast is evicted", first.closed)
	local function fits()
		local height = math.max(0, #overlay.toasts - 1) * theme.space.sm
		for _, entry in ipairs(overlay.toasts) do
			height = height + entry.slot.AbsoluteSize.Y
			local body = entry.card:FindFirstChild("ToastMessage")
			local action = entry.card:FindFirstChild("NotificationAction")
			check("body cannot overlap its action", body.Position.Y.Offset + body.Size.Y.Offset <= action.Position.Y.Offset)
			check("complete long message remains scrollable", entry.card:FindFirstChild("Message", true).Text == long and body.ScrollingDirection == h.sandbox.Enum.ScrollingDirection.Y)
		end
		check("stack fits available room", height <= responsive.usableRect(overlay.layer, theme.space.md).height)
	end
	fits()
	viewport(360, 400, true, 160)
	fits()
	local entry = overlay.toasts[#overlay.toasts]
	entry.card:FindFirstChild("NotificationAction").Activated:Fire()
	entry.activate()
	check("action fires once", activated == 1 and entry.closed)
	while #overlay.toasts > 0 do overlay.toasts[1].close(true) end
	viewport(720, 600, false)
	local timed = overlay.toast("Read this", "info", 1)
	h.sched.advance(0.4)
	timed.card.MouseEnter:Fire()
	h.sched.advance(2)
	check("hover pauses expiration", not timed.closed)
	timed.card.MouseLeave:Fire()
	h.sched.advance(0.4)
	check("remaining reading time is retained", not timed.closed)
	h.sched.advance(0.3)
	check("toast expires after remaining time", timed.closed)
	local dismissed = overlay.toast("Dismiss this", "warn", 5, { title = "Notice", onActivate = function() activated = activated + 1 end })
	dismissed.card:FindFirstChild("DismissNotification").Activated:Fire()
	check("dismiss does not activate", dismissed.closed and activated == 1)
	h.sched.advance(6)
	check("all timers and fades finish without errors", #h.errors() == 0)
end)

scenario("notification actions open their conversation and acknowledge only that conversation", function()
	local h = envMock.new()
	local handle = assert(h.boot())
	h.settle(0.5)
	local app, sessions = handle.app, handle.sessions
	local alpha = sessions.current(); alpha.title = "Alpha"
	local beta = sessions.newThread(); beta.title = "Beta"
	app.openSession(alpha.id)
	app.hide()
	sessions.anyEvent:fire(alpha, { kind = "turn:end", text = "**Alpha** finished" })
	sessions.anyEvent:fire(beta, { kind = "turn:end", text = "**Beta** finished" })
	check("both missed replies are counted", #app.notifications == 2 and app.launcherBadgeCount.Text == "2")
	app.rebuild("notification regression")
	check("unread badge survives rebuilding the window", app.launcherBadge.Visible and app.launcherBadgeCount.Text == "2")
	local betaToast = app.notifications[2].toast
	check("preview removes markdown syntax", betaToast.card:FindFirstChild("Message", true).Text == "Beta finished")
	check("notification names outcome and conversation", has(betaToast.card:FindFirstChild("ToastTitle").Text, "Reply ready") and has(betaToast.card:FindFirstChild("ToastTitle").Text, "Beta"))
	betaToast.card:FindFirstChild("NotificationAction").Activated:Fire()
	check("action opens the correct chat", sessions.activeId == beta.id and app.panel == "chat" and app.window.visible)
	check("other conversation stays unread", #app.notifications == 1 and app.notifications[1].sessionId == alpha.id and app.launcherBadgeCount.Text == "1")
	app.show("settings")
	check("opening settings does not clear unread replies", #app.notifications == 1)
	app.openSession(alpha.id)
	check("reading alpha clears its badge and toast", #app.notifications == 0 and not app.launcherBadge.Visible)
	sessions.anyEvent:fire(beta, { kind = "error", message = "Try again later" })
	check("background errors are visible even with the window open", #app.notifications == 1)
	app.notifications[1].toast.card:FindFirstChild("DismissNotification").Activated:Fire()
	check("dismissal preserves unread state", #app.notifications == 1)
	app.openSession(beta.id)
	sessions.anyEvent:fire(beta, { kind = "turn:end", text = "Visible reply" })
	check("current visible conversation does not duplicate notices", #app.notifications == 0)
	beta.busy = true
	app.hide()
	check("minimizing an active turn starts the busy pulse", app.launcherPulse.Visible)
	beta.busy = false
	sessions.listChanged:fire()
	check("finished work stops the busy pulse", not app.launcherPulse.Visible)
	h.settle(1)
	check("no application notification errors", #h.errors() == 0)
end)

print(string.format("Todo and notifications: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
