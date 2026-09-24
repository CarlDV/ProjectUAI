-- Native labelled controls for typed data. No ordinary workflow needs JSON input.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local overlay = env.require("ui/overlay")
	local common = env.require("ui/code/common")
	local values = env.require("runtime/values")
	local store = env.require("runtime/code_store")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local limits = env.require("runtime/code_limits")
	local M = {}
	store.workspace.forms = store.workspace.forms or {}
	local draftMeta = {}
	function M.discardDraft(key) store.workspace.forms[key], draftMeta[key] = nil, nil end
	function M.draft(key, initial)
		local now = clock.ms()
		for name, meta in pairs(draftMeta) do
			if (not meta.modal or meta.modal.closed) and now - meta.at > limits.ttl then M.discardDraft(name) end
		end
		if not store.workspace.forms[key] then
			while util.count(store.workspace.forms) >= limits.snapshots do
				local oldest, age
				for name in pairs(store.workspace.forms) do
					local meta = draftMeta[name]
					if (not meta or not meta.modal or meta.modal.closed) and (not age or (meta and meta.at or 0) < age) then oldest, age = name, meta and meta.at or 0 end
				end
				if not oldest then return nil, "Close an open form before creating another draft" end
				M.discardDraft(oldest)
			end
			store.workspace.forms[key] = initial or {}
		end
		draftMeta[key] = draftMeta[key] or {}; draftMeta[key].at = now
		return store.workspace.forms[key]
	end
	function M.holdDraft(key, modal)
		local meta = key and draftMeta[key]; if not meta then return end
		meta.modal = modal
		modal.scrim.Destroying:Connect(function() if meta.modal == modal then meta.modal, meta.at = nil, clock.ms() end end)
	end
	function M.stopControl(modal)
		local runner, capture = env.require("tools/code_runner"), env.require("runtime/remote_capture")
		if runner.busy() or capture.status == "running" or capture.status == "paused" or capture.status == "starting" then
			common.button(modal.footer, { text = "Stop", size = "sm", variant = "danger", layoutOrder = 3, onClick = function() runner.stop(); capture.stop("Stop from editor form") end })
		end
	end
	function M.form(title, definitions, onSubmit, options)
		options = options or {}
		local draft, why = options.draft or {}
		if options.key then draft, why = M.draft(options.key, draft); if not draft then common.message(nil, why); return end end
		local modal = overlay.modal({ title = title, description = options.description, width = options.width, height = options.height })
		if not modal then return end
		M.holdDraft(options.key, modal)
		M.stopControl(modal)
		local column = P.column(modal.content, { auto = "Y", size = UDim2.new(1, 0, 0, 0), gap = theme.space.sm })
		local errorLabel = P.text(column, { text = "", color = theme.color.danger, wrap = true, auto = "Y", layoutOrder = 10000 })
		for index, def in ipairs(definitions) do
			if draft[def.key] == nil and def.default ~= nil then draft[def.key] = def.default end
			local holder = P.column(column, { auto = "Y", size = UDim2.new(1, 0, 0, 0), gap = theme.space.xs, layoutOrder = index })
			if def.type == "boolean" then
				local choices = def.optional and { "Not supplied", "false", "true" } or { "false", "true" }
				local selected = draft[def.key] == nil and def.optional and "Not supplied" or tostring(draft[def.key] == true or draft[def.key] == "true")
				common.choice(holder, def.label or def.key, choices, selected, function(value) if value == "Not supplied" then draft[def.key] = nil else draft[def.key] = value == "true" end end)
			elseif def.type == "choice" then
				if not def.optional then
					if draft[def.key] == nil then draft[def.key] = def.choices[1] end
					common.choice(holder, def.label or def.key, def.choices, draft[def.key], function(value) draft[def.key] = value end)
				else
					local button; local function caption() return (def.label or def.key) .. ": " .. (draft[def.key] == nil and "Not supplied" or draft[def.key]) end
					button = common.button(holder, { text = caption(), fill = true, size = "sm", onClick = function()
						local choices = { { label = "Not supplied", value = false } }
						for _, value in ipairs(def.choices) do choices[#choices + 1] = { label = "Value: " .. value, value = value } end
						common.menu(button, def.label or def.key, choices, function(value) draft[def.key] = value ~= false and value or nil; button.setText(caption()) end)
					end })
				end
			else
				P.text(holder, { text = def.label or def.key, role = "small", auto = "Y", wrap = true, layoutOrder = 1 })
				local field = P.field(holder, { text = draft[def.key] ~= nil and tostring(draft[def.key]) or "", placeholder = def.placeholder,
					multiline = def.multiline, height = def.multiline and theme.size.control * 3 or nil, layoutOrder = 2,
					onChange = function(value) draft[def.key] = value end })
				if def.optional and def.type == "string" then
					local supplied = draft[def.key] ~= nil; field.shell.Visible = supplied
					common.choice(holder, "Include " .. (def.label or def.key), { "No", "Yes" }, supplied and "Yes" or "No", function(value)
						supplied = value == "Yes"; draft[def.key] = supplied and field.get() or nil; field.shell.Visible = supplied
					end, 3)
				end
				if def.type == "reference" then common.button(holder, { text = "Choose selected object / bookmark", fill = true, size = "sm", layoutOrder = 3, onClick = function(button)
					local explorer, refs = env.require("runtime/explorer"), env.require("runtime/instance_refs")
					local choices, seen = {}, {}
					for _, ids in ipairs({ explorer.selectedIds, explorer.bookmarks }) do for _, id in ipairs(ids) do local object = refs.resolve(id); if object and not seen[id] then seen[id] = true; choices[#choices + 1] = { label = object.Name .. " · " .. object.ClassName, value = id } end end end
					common.menu(button, "Object reference", choices, function(id) field.set(id) end)
				end }) end
			end
		end
		common.button(modal.footer, { text = "Cancel", variant = "ghost", size = "sm", layoutOrder = 1, onClick = function() modal.close() end })
		common.button(modal.footer, { text = options.submit or "Apply", variant = options.danger and "danger" or "primary", size = "sm", layoutOrder = 2, onClick = function()
			local data = {}
			for _, def in ipairs(definitions) do
				local value = draft[def.key]
				if def.type == "number" then
					if value == nil or value == "" then if def.required then errorLabel.Text = "Enter " .. (def.label or def.key); return end; value = nil
					else value = tonumber(value); if not values.finite(value) or (def.min and value < def.min) or (def.max and value > def.max) then errorLabel.Text = "Enter a valid number for " .. (def.label or def.key); return end end
				elseif def.type == "boolean" then if value ~= nil or not def.optional then value = value == true or value == "true" end
				elseif value == nil and not def.optional then value = "" end
				if def.required and type(value) == "string" and value == "" then errorLabel.Text = "Enter " .. (def.label or def.key); return end
				data[def.key] = value
			end
			local ok, result, why = pcall(onSubmit, data)
			if not ok or result == false or result == nil then errorLabel.Text = tostring(ok and why or result); return end
			if options.key then M.discardDraft(options.key) end
			modal.close(true)
		end })
		return { modal = modal, draft = draft }
	end
	local labels = { Vector2 = { "X", "Y" }, Vector3 = { "X", "Y", "Z" }, Color3 = { "Red (0–1)", "Green (0–1)", "Blue (0–1)" },
		CFrame = { "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22" },
		UDim = { "Scale", "Offset" }, UDim2 = { "X scale", "X offset", "Y scale", "Y offset" }, Rect = { "Minimum X", "Minimum Y", "Maximum X", "Maximum Y" }, NumberRange = { "Minimum", "Maximum" } }
	M.types = { "string", "number", "boolean", "nil", "Vector2", "Vector3", "Color3", "CFrame", "UDim", "UDim2", "Rect", "NumberRange", "BrickColor", "EnumItem", "Instance", "NumberSequence", "ColorSequence" }
	function M.typed(node, title, onSubmit, options)
		options = options or {}; node = util.deepCopy(node or { kind = "string", value = "" })
		local definitions, kind = {}, node.kind
		if labels[kind] then
			for i, label in ipairs(labels[kind]) do definitions[#definitions + 1] = { key = "component" .. i, label = label, type = "number", required = true, default = node.components and node.components[i] or (kind == "CFrame" and (i == 4 or i == 8 or i == 12) and 1 or 0) } end
		elseif kind == "Instance" then definitions = { { key = "instanceId", label = "Object reference", type = "reference", required = true, default = node.instanceId } }
		elseif kind == "EnumItem" then
			definitions = { { key = "enum", label = "Enum type", type = "string", required = true, default = node.enum }, { key = "name", label = "Item name", type = "string", required = true, default = node.name } }
		elseif kind == "NumberSequence" or kind == "ColorSequence" then
			local draftKey = "sequence:" .. (options.key or title)
			local points, why = M.draft(draftKey, node.keypoints or { { time = 0, value = values.node(kind == "NumberSequence" and 0 or Color3.new()) }, { time = 1, value = values.node(kind == "NumberSequence" and 1 or Color3.new(1, 1, 1)) } })
			if not points then common.message(nil, why); return end
			local modal = overlay.modal({ title = title, description = "Edit ordered keypoints. Endpoints remain at 0 and 1." }); if not modal then return end
			M.holdDraft(draftKey, modal)
			M.stopControl(modal)
			local column = P.column(modal.content, { size = UDim2.new(1, 0, 0, 0), auto = "Y" })
			local function render()
				for _, child in ipairs(column:GetChildren()) do if not child:IsA("UIComponent") then child:Destroy() end end
				for i, point in ipairs(points) do
					common.button(column, { text = "Keypoint " .. i .. " · " .. point.time .. " · " .. values.format(point.value), fill = true, size = "sm", layoutOrder = i, onClick = function()
						M.form("Keypoint " .. i, { { key = "time", label = "Time (0–1)", type = "number", min = 0, max = 1, default = point.time, required = true }, { key = "envelope", label = "Envelope", type = "number", min = 0, default = point.envelope or 0 } }, function(data)
							point.time, point.envelope = data.time, data.envelope; render()
							env.require("runtime/clock").delay(0, function() if not modal.closed then M.typed(point.value, "Keypoint value", function(value) point.value = value; if not modal.closed then render() end; return true end) end end)
							return true
						end)
					end })
				end
				common.button(column, { text = "Add keypoint", fill = true, size = "sm", layoutOrder = 100, onClick = function() if #points >= 64 then return end; table.insert(points, #points, { time = 0.5, value = values.node(kind == "NumberSequence" and 0 or Color3.new()), envelope = 0 }); render() end })
				common.button(column, { text = "Remove last interior keypoint", fill = true, size = "sm", layoutOrder = 101, onClick = function() if #points > 2 then table.remove(points, #points - 1); render() end end })
			end
			common.button(modal.footer, { text = "Apply", size = "sm", variant = "primary", onClick = function()
				table.sort(points, function(a, b) return a.time < b.time end); local value = { kind = kind, keypoints = points }; local valid, why = values.decodeNode(value)
				if not valid then common.message(nil, why); return end
				local applied, reason = onSubmit(value); if applied then M.discardDraft(draftKey); modal.close(true) else common.message(nil, reason) end
			end }); render(); return
		elseif kind ~= "nil" then
			definitions = { { key = "value", label = kind == "BrickColor" and "BrickColor number" or "Value", type = kind == "BrickColor" and "number" or kind, required = kind ~= "string", default = node.value, multiline = kind == "string" } }
		end
		return M.form(title, definitions, function(data)
			local value = { kind = kind }
			if labels[kind] then value.components = {}; for i = 1, #labels[kind] do value.components[i] = data["component" .. i] end
			elseif kind == "EnumItem" then value.enum, value.name = data.enum, data.name
			elseif kind == "Instance" then value.instanceId = data.instanceId
			elseif kind ~= "nil" then value.value = data.value; if kind == "string" then value.encoding, value.length = "utf8", #data.value end end
			local ok, why = values.decodeNode(value); if not ok then return nil, why end
			return onSubmit(value)
		end, { key = options.key, description = options.description, submit = options.submit or "Apply" })
	end
	function M.chooseType(target, title, callback)
		local options = {}; for _, kind in ipairs(M.types) do options[#options + 1] = { label = kind, value = kind } end
		common.menu(target, title, options, callback)
	end
	return M
end
