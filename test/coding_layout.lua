-- Source-only Coding geometry checks. Native text rendering and touch gestures
-- still need in-game testing; the mock resolves explicit sizes, not UIListLayout.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Coding layout")
local case, check = suite.case, suite.check
local function ui(width, height, touch, scale, density)
	local f = F.ui(width, height)
	local input = f.h.services.UserInputService
	input.TouchEnabled, input.MouseEnabled, input.KeyboardEnabled = touch, not touch, not touch
	local config = f.env.require("runtime/config")
	config.set("ui.fontScale", scale or 1); config.set("ui.density", density or "comfortable")
	f.env.require("ui/responsive").init(f.env.root)
	return f
end
local function settle(f, root)
	f.h.sched.advance(0.15)
	-- Parent geometry changes do not cascade signals in the mock.
	root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	for _, node in ipairs(root:GetDescendants()) do
		if node:IsA("GuiObject") then node:GetPropertyChangedSignal("AbsoluteSize"):Fire() end
	end
	f.h.sched.advance(0.05)
end
local function visible(node, root)
	while node do
		if node:IsA("GuiObject") and not node.Visible then return false end
		if node == root then return true end
		node = node.Parent
	end
	return false
end
local function controls(parent)
	local items = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("TextButton") and child.Visible then items[#items + 1] = child end
	end
	table.sort(items, function(a, b) return a.Position.X.Offset < b.Position.X.Offset end)
	return items
end
local function auditBars(f, root)
	local count = 0
	for _, strip in ipairs(root:GetDescendants()) do
		if strip.Name == "ToolbarControls" and visible(strip, root) then
			local right = 4
			for _, button in ipairs(controls(strip)) do
				local x, y, size = button.Position.X.Offset, button.Position.Y.Offset, button.AbsoluteSize
				check(button.Name .. " has space beside its neighbour", x - right >= 4)
				check(button.Name .. " has top/bottom clearance", y >= 4 and strip.AbsoluteSize.Y - y - size.Y >= 4)
				check(button.Name .. " stays inside the padded canvas", x >= 8 and x + size.X <= strip.CanvasSize.X.Offset - 8 + 0.01)
				local content = button:FindFirstChild("Content")
				local padding = assert(content:FindFirstChildOfClass("UIPadding"))
				check(button.Name .. " leaves room around its content", size.X >= padding.PaddingLeft.Offset + padding.PaddingRight.Offset + 12)
				right, count = x + size.X, count + 1
			end
			check("overflow stays reachable", strip.CanvasSize.X.Offset <= strip.AbsoluteSize.X + 0.01 or strip.ScrollingEnabled)
		end
	end
	return count
end
local function auditList(list)
	for _, row in ipairs(list.rows) do
		if row.item and row.detail then
			local label, detail = row.button.label, row.detail
			check("row title and detail never overlap", detail.Position.Y.Offset - label.Position.Y.Offset - label.AbsoluteSize.Y >= 4)
			check("row text has vertical padding", label.Position.Y.Offset >= 4 and row.button.instance.AbsoluteSize.Y - detail.Position.Y.Offset - detail.AbsoluteSize.Y >= 4)
		end
	end
end
local function activate(list, id)
	for index, item in ipairs(list.items) do
		if item.id == id or item.instanceId == id then list.selected = index; list.activate(); return end
	end
	error("Missing row " .. tostring(id))
end
local function section(f, root, text)
	for _, node in ipairs(root:GetDescendants()) do
		if node.Name == "TabButton" and f.h.textOf(node) == text then f.h.click(node); return end
	end
	error("Missing section " .. text)
end

case("crowded toolbars preserve action labels and reveal keyboard focus", function()
	local f = ui(240, 300, true, 1.4, "compact")
	local common = f.env.require("ui/code/common")
	local bar = common.toolbar(f.host)
	bar.add("A long source name with pending changes", function() end, { flex = true })
	local run = bar.add("Run", function() end)
	local save = bar.add("Save file", function() end)
	local more = bar.add("", function() end, { icon = "ellipsis", iconOnly = true })
	auditBars(f, f.host)
	check("command text keeps its full width", save.instance.Size.X.Offset >= f.env.require("ui/primitives").measureText("Save file", { role = "small" }).X + 16)
	check("crowded strip has a scroll range", bar.controls.CanvasSize.X.Offset > bar.controls.AbsoluteSize.X)
	more.instance.SelectionGained:Fire()
	check("focusing the last action reveals its padded edge", more.instance.Position.X.Offset + more.instance.Size.X.Offset + 8 <= bar.controls.CanvasPosition.X + bar.controls.AbsoluteSize.X + 0.01)
	run.instance.Visible = false; save.setText("Save file as")
	auditBars(f, f.host)
	f.host.Size = f.h.sandbox.UDim2.fromOffset(960, 300); settle(f, f.host)
	check("growing the pane clears the scroll offset", not bar.controls.ScrollingEnabled and bar.controls.CanvasPosition.X == 0)
	f.healthy(); f.host:Destroy(); f.close()
end)

case("narrow document tabs keep a readable label and reveal focused close buttons", function()
	local f = ui(100, 300, true, 1.4, "compact")
	local common = f.env.require("ui/code/common")
	local tabs = f.env.require("ui/code/tabs").new(f.host, { size = f.h.sandbox.UDim2.new(1, 0, 0, common.barHeight()), onClose = function() end })
	tabs.set({ { id = "one", label = "First source file.lua" }, { id = "two", label = "Another source file.lua" } }, "one")
	local first, second = tabs.cells.one, tabs.cells.two
	check("document label retains a readable slice", first.label.AbsoluteSize.X >= 36)
	check("tabs have outer and inter-tab spacing", first.root.Position.X.Offset >= 8 and second.root.Position.X.Offset - first.root.Position.X.Offset - first.root.AbsoluteSize.X >= 4)
	check("tab and close keep vertical padding", first.root.Position.Y.Offset >= 4 and first.close.AbsoluteSize.Y >= 44 and first.root.AbsoluteSize.Y <= tabs.root.AbsoluteSize.Y - 8)
	second.button.SelectionGained:Fire()
	local function revealed(button, at)
		return at >= tabs.root.CanvasPosition.X + 8 - 0.01 and at + button.AbsoluteSize.X <= tabs.root.CanvasPosition.X + tabs.root.AbsoluteSize.X - 8 + 0.01
	end
	check("keyboard navigation reveals a document label", revealed(second.button, second.x))
	second.close.SelectionGained:Fire()
	check("keyboard navigation reveals the close target", revealed(second.close, second.x + second.width - second.close.AbsoluteSize.X))
	f.healthy(); tabs.root:Destroy(); f.close()
end)

for _, width in ipairs({ 320, 390, 620, 960 }) do
	for _, touch in ipairs({ false, true }) do
		for _, profile in ipairs({ { scale = 1, density = "comfortable" }, { scale = 1.4, density = "compact" } }) do
			case(width .. "px " .. (touch and "touch" or "pointer") .. " " .. profile.density .. " " .. profile.scale, function()
				local f = ui(width, width <= 390 and 500 or 660, touch, profile.scale, profile.density)
				local h, env = f.h, f.env
				local store, refs, values = env.require("runtime/code_store"), env.require("runtime/instance_refs"), env.require("runtime/values")
				local doc = store.active(); assert(store.update(doc.id, "return 1"))
				local version = assert(store.saveVersion(doc.id, "Saved movement"))
				assert(store.update(doc.id, "return 2"))
				local folder = h.Instance.new("Folder", h.workspace); folder.Name = "Workspace files"
				local part = h.Instance.new("Part", folder); part.Name, part.Transparency = "Selected object", 0
				local edit = assert(env.require("runtime/instance_edits").apply({ { instanceId = refs.id(part), kind = "property", key = "Transparency", expected = values.node(0), value = values.node(0.5) } }, { origin = "Explorer" }))
				assert(edit.ok, edit.text)
				local remote = h.Instance.new("RemoteEvent", folder); remote.Name = "MovementRemote"
				local call = env.require("runtime/remote_store").begin({ name = remote.Name, remoteId = refs.id(remote), className = "RemoteEvent", method = "FireServer", direction = "outgoing", origin = "uai", sessionId = "fixture", outcome = "forwarded" }, values.pack(1, "move"))
				local fs = env.require("runtime/fsx"); assert(fs.write("files/layout/main.lua", "return true"))
				local panel = env.require("ui/panels/code").new(f.host)
				for _, destination in ipairs({ "Editor", "Files", "Explorer", "Remotes", "Output", "History", "Library", "Game changes" }) do
					panel.navigate(destination); settle(f, panel.root)
					local view = assert(panel.views[destination])
					check(destination .. " body remains usable", view.root.AbsoluteSize.Y > 200 and view.root.AbsoluteSize.X > 0)
					auditBars(f, panel.root)
					if view.list then auditList(view.list) end
					if destination == "Editor" then
						view.openFind(); settle(f, panel.root)
						local field = h.byName("FindSourceText", view.root)
						check("Find field has typing room", field.AbsoluteSize.X >= 100)
						local edge = field.AbsolutePosition.X + field.AbsoluteSize.X
						for _, name in ipairs({ "FindPrevious", "FindNext", "CloseFind" }) do
							local button = h.byName(name, view.root)
							check(name .. " leaves a gap", button.AbsolutePosition.X - edge >= 4)
							check(name .. " keeps a full hit target", button.AbsoluteSize.X >= env.require("ui/responsive").minTarget())
							edge = button.AbsolutePosition.X + button.AbsoluteSize.X
						end
						view.closeFind()
					elseif destination == "Explorer" then
						activate(view.list, refs.id(h.workspace)); activate(view.list, refs.id(folder)); settle(f, panel.root)
						for _, row in ipairs(view.list.rows) do
							if row.chevronSlot and row.chevronSlot.Visible then check("tree expanders keep a full hit target", row.chevronSlot.AbsoluteSize.X >= env.require("ui/responsive").minTarget()) end
						end
						activate(view.list, refs.id(part)); settle(f, panel.root); auditBars(f, panel.root)
					elseif destination == "Remotes" then
						local follow = h.byName("FollowLatestCalls", view.root)
						check("Following label fits its padded button", follow.AbsoluteSize.X >= env.require("ui/primitives").measureText("Following", { role = "small" }).X + 16)
						activate(view.list, call.id); settle(f, panel.root); auditBars(f, panel.root)
						section(f, h.byName("RemoteDetailTabs", view.root), "Replay draft"); settle(f, panel.root); auditBars(f, panel.root)
					elseif destination == "History" or destination == "Game changes" then
						activate(view.list, destination == "History" and version.id or edit.batchId)
						settle(f, panel.root); auditBars(f, panel.root)
						if view.fields then auditList(view.fields) end
					end
				end
				assert(fs.write("files/layout/large.lua", string.rep("-- line\n", 40000)))
				assert(env.require("runtime/code_files").open("files/layout/large.lua"))
				panel.navigate("Editor"); settle(f, panel.root)
				check("large-source navigation is audited", auditBars(f, panel.root) >= 3)
				f.healthy(); panel.destroy(); f.close()
			end)
		end
	end
end

case("Coding dialogs reserve footer space for larger controls", function()
	local f = ui(320, 640, true, 1.4, "compact")
	local env = f.env
	local forms, theme = env.require("ui/code/forms"), env.require("ui/theme")
	local form = forms.form("Edit field", { { key = "enabled", label = "Enabled", type = "boolean" }, { key = "name", label = "Name", required = true } }, function() return true end, { submit = "Save changes" })
	local function audit(modal)
		settle(f, modal.card)
		local height = 0
		for _, button in ipairs(controls(modal.footer)) do
			check("footer button leaves space around larger text", button.AbsoluteSize.Y >= theme.text.small.height + 8)
			height = math.max(height, button.AbsoluteSize.Y)
		end
		check("footer reserves vertical padding", modal.footer.AbsoluteSize.Y >= height + theme.space.sm * 2)
		check("dialog body stays above footer", modal.scroll.instance.Position.Y.Offset + modal.scroll.instance.Size.Y.Offset <= modal.card.Size.Y.Offset - modal.footer.Size.Y.Offset)
		auditBars(f, modal.card); modal.close()
	end
	audit(form.modal)
	audit(env.require("ui/code/compare").open("return 1", "return 2", "Compare changes", function() return true end))
	env.require("ui/code/library").saveAction(env.require("runtime/code_store").active())
	local overlay = env.require("ui/overlay"); audit(overlay.open[#overlay.open])
	f.healthy(); f.close()
end)

suite.finish()
