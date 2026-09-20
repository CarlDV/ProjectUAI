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

local function pointer(h, kind, x, y)
	return { UserInputType = h.sandbox.Enum.UserInputType[kind],
		UserInputState = h.sandbox.Enum.UserInputState.Begin,
		Position = h.dt.Vector3.new(x, y, 0), Changed = require("instance").newSignal("pointer") }
end

scenario("launcher dragging preserves the grab offset and separates clicks from drags", function()
	local h, env, root, settings = fixture()
	local responsive, app = env.require("ui/responsive"), env.require("ui/app")
	responsive.viewport, responsive.inset = h.dt.Vector2.new(1000, 700), h.dt.Vector2.new(0, 36)
	root.Size, root.Position = h.dt.UDim2.fromOffset(800, 550), h.dt.UDim2.fromOffset(100, 36)
	local toggles = 0
	app.screen, app.toggle = root, function() toggles = toggles + 1 end
	app.buildLauncher()
	local button, uis = app.launcher, env.uis
	local start = button.AbsolutePosition
	local press = pointer(h, "MouseButton1", start.X + 31, start.Y + 28)
	button.InputBegan:Fire(press)
	uis.InputChanged:Fire(pointer(h, "MouseMovement", press.Position.X - 2, press.Position.Y - 2))
	check("small pointer movement leaves the launcher exactly in place", button.AbsolutePosition.X == start.X and button.AbsolutePosition.Y == start.Y)
	uis.InputChanged:Fire(pointer(h, "MouseMovement", press.Position.X - 60, press.Position.Y - 45))
	check("drag follows the mouse without adding the parent or GUI inset", button.AbsolutePosition.X == start.X - 60 and button.AbsolutePosition.Y == start.Y - 45)
	check("the original grab offset is preserved", press.Position.X - 60 - button.AbsolutePosition.X == 31 and press.Position.Y - 45 - button.AbsolutePosition.Y == 28)
	press.UserInputState = h.sandbox.Enum.UserInputState.End; press.Changed:Fire()
	button.Activated:Fire(press)
	check("drag release does not toggle the window", toggles == 0 and press.Changed:Count() == 0)
	check("only released placement is saved in parent coordinates", settings["ui.launcher.placed"] and settings["ui.launcher.x"] == button.Position.X.Offset and settings["ui.launcher.y"] == button.Position.Y.Offset)
	local click = pointer(h, "MouseButton1", button.AbsolutePosition.X + 10, button.AbsolutePosition.Y + 10)
	button.InputBegan:Fire(click)
	click.UserInputState = h.sandbox.Enum.UserInputState.End; uis.InputEnded:Fire(click)
	button.Activated:Fire(click)
	check("the next ordinary click opens or minimizes once", toggles == 1)
	button:Destroy()
	app.buildLauncher()
	check("rebuilding restores the saved placement without an inset jump", app.launcher.AbsolutePosition.X == start.X - 60 and app.launcher.AbsolutePosition.Y == start.Y - 45)
	app.launcher:Destroy()
	h.sched.advance(1)
	check("launcher gestures have no scheduler or property errors", #h.errors() == 0 and #h.instanceState.typeErrors == 0)
end)

scenario("launcher owns one pointer and releases every listener on cancellation or rebuild", function()
	local h, env, root, settings = fixture()
	local app, responsive = env.require("ui/app"), env.require("ui/responsive")
	local uis, E = env.uis, h.sandbox.Enum
	local moves, ends, focus, layouts = uis.InputChanged:Count(), uis.InputEnded:Count(), uis.WindowFocusReleased:Count(), responsive.changed:count()
	local toggles = 0
	app.screen, app.toggle = root, function() toggles = toggles + 1 end
	app.buildLauncher()
	local button = app.launcher
	local start = button.Position
	local owner, other = pointer(h, "Touch", 650, 550), pointer(h, "Touch", 660, 560)
	button.InputBegan:Fire(owner); button.InputBegan:Fire(other)
	other.Position = h.dt.Vector3.new(20, 20, 0); uis.InputChanged:Fire(other)
	uis.InputChanged:Fire(pointer(h, "MouseMovement", 20, 20))
	check("other fingers and mouse movement cannot hijack a touch drag", button.Position == start)
	owner.Position = h.dt.Vector3.new(620, 525, 0); uis.InputChanged:Fire(owner)
	check("the initiating finger controls the drag", button.Position.X.Offset == start.X.Offset - 30 and button.Position.Y.Offset == start.Y.Offset - 25)
	owner.UserInputState = E.UserInputState.Cancel; owner.Changed:Fire()
	button.Activated:Fire(owner); button.Activated:Fire(other)
	check("cancelled and ignored touches never restore the window", toggles == 0 and owner.Changed:Count() == 0)
	check("a cancelled placement is not persisted", settings["ui.launcher.placed"] == nil)
	local press = pointer(h, "MouseButton1", 600, 500)
	button.InputBegan:Fire(press)
	uis.WindowFocusReleased:Fire()
	local lostPosition = button.Position
	uis.InputChanged:Fire(pointer(h, "MouseMovement", 50, 50))
	button.Activated:Fire(press)
	check("focus loss ends the gesture and prevents a late activation", button.Position == lostPosition and press.Changed:Count() == 0 and toggles == 0)
	button.Activated:Fire(pointer(h, "Gamepad1", 0, 0))
	check("keyboard and gamepad activation is not swallowed by a previous drag", toggles == 1)
	local last = pointer(h, "Touch", 600, 500)
	button.InputBegan:Fire(last)
	button:Destroy()
	check("destroying the launcher releases its active input", last.Changed:Count() == 0 and app.launcher == nil)
	for index = 1, 5 do app.buildLauncher(); app.launcher:Destroy() end
	check("rebuilds leave no extra service or layout listeners", uis.InputChanged:Count() == moves and uis.InputEnded:Count() == ends and uis.WindowFocusReleased:Count() == focus and responsive.changed:count() == layouts)
	h.sched.advance(1)
	check("cancelled gestures leave no asynchronous errors", #h.errors() == 0)
end)

scenario("launcher remains reachable above the keyboard and restores its preferred position", function()
	local h, env, root, settings, viewport = fixture()
	local app, responsive, theme = env.require("ui/app"), env.require("ui/responsive"), env.require("ui/theme")
	settings["ui.launcher.placed"], settings["ui.launcher.x"], settings["ui.launcher.y"] = true, 650, 530
	app.screen = root; app.buildLauncher()
	local original = app.launcher.Position
	viewport(360, 600, true, 300)
	local bounds, size = responsive.usableRect(root, theme.space.xs), app.launcher.AbsoluteSize
	check("resized launcher stays inside the usable rectangle", app.launcher.Position.X.Offset >= bounds.x and app.launcher.Position.Y.Offset >= bounds.y
		and app.launcher.Position.X.Offset + size.X <= bounds.x + bounds.width and app.launcher.Position.Y.Offset + size.Y <= bounds.y + bounds.height)
	check("keyboard adjustment does not overwrite the saved placement", settings["ui.launcher.x"] == 650 and settings["ui.launcher.y"] == 530)
	viewport(720, 600, false, 0)
	check("restoring the viewport restores the preferred position", app.launcher.Position == original)
	app.launcher:Destroy()
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
	sessions.anyEvent:fire(beta, { kind = "turn:end", text = "Failed", failed = true })
	check("failed turn cleanup does not add a success notification", #app.notifications == 1)
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
