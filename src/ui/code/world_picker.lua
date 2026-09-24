-- Explicit local picking. The picker owns only its highlight and input connections.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local explorer = env.require("runtime/explorer")
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local overlay = env.require("ui/overlay")
	local M = {}
	local connections, highlight, banner, callback, alive, selected = {}, nil, nil, nil, false, nil
	function M.stop()
		alive = false; selected, callback = nil, nil
		for _, connection in ipairs(connections) do connection:Disconnect() end; connections = {}
		if highlight then highlight:Destroy(); highlight = nil end
		if banner then banner:Destroy(); banner = nil end
	end
	function M.start(onSelected)
		M.stop()
		if not workspace.CurrentCamera then return nil, "World camera is unavailable" end
		local layer = overlay.layer or env.root; if not layer then return nil, "Open UAI before starting the picker" end
		alive, callback = true, onSelected
		banner = P.frame(layer, { name = "WorldPicker", size = UDim2.new(1, -theme.space.lg * 2, 0, common.barHeight()), position = UDim2.fromOffset(theme.space.lg, theme.space.sm), bg = theme.color.surfaceRaised, zIndex = theme.z.modal })
		local bar = common.toolbar(banner, { divider = false })
		local label = bar.add("Point at an object · click to select", function() end, { flex = true, trailing = false })
		local function choose()
			if not selected then return end
			local id, done = refs.id(selected), callback
			M.stop(); local result, why = explorer.select({ id })
			if common.message(result, why) and done then done(id) end
		end
		bar.add("Parent", function() if selected and selected.Parent then selected = selected.Parent; if highlight then pcall(function() highlight.Adornee = selected end) end; label.setText(selected.Name) end end)
		bar.add("Select", choose, { variant = "primary" })
		bar.add("Cancel", M.stop, { variant = "ghost" })
		pcall(function() highlight = Instance.new("Highlight"); highlight.Name = "UAI_Picker"; highlight.FillTransparency = 0.8; highlight.OutlineColor = theme.color.accent; highlight.Parent = layer end)
		local function ownGuiAt(position)
			local roots = { env.root and env.root.Parent, env.services.CoreGui }
			pcall(function() roots[#roots + 1] = env.plr:FindFirstChildOfClass("PlayerGui") end)
			for _, container in pairs(roots) do
				local ok, objects = pcall(function() return container:GetGuiObjectsAtPosition(position.X, position.Y) end)
				if ok then for _, gui in ipairs(objects) do if env.root and gui:IsDescendantOf(env.root) then return true end end end
			end
			-- The picker banner can live in a protected GUI parent without hit-test support.
			if banner then local at, size = banner.AbsolutePosition, banner.AbsoluteSize; if position.X >= at.X and position.X <= at.X + size.X and position.Y >= at.Y and position.Y <= at.Y + size.Y then return true end end
			return false
		end
		local function point(input, processed, aimed, commit)
			if not alive or processed or env.uis:GetFocusedTextBox() then return end
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local position = input.Position
			if not aimed and ownGuiAt(position) then return end
			local camera = workspace.CurrentCamera
			if not camera then return end
			local ray = aimed and camera:ViewportPointToRay(position.X, position.Y) or camera:ScreenPointToRay(position.X, position.Y)
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 10000)
			selected = hit and hit.Instance or nil
			if highlight then pcall(function() highlight.Adornee = selected end) end
			label.setText(selected and (selected.Name .. " · " .. selected.ClassName) or "No object under the pointer")
			if commit and selected then choose() end
		end
		connections[#connections + 1] = env.uis.InputBegan:Connect(function(input, processed)
			if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then M.stop(); return end
			if input.KeyCode == Enum.KeyCode.ButtonA and selected then choose(); return end
			if input.KeyCode == Enum.KeyCode.ButtonX and not env.uis:GetFocusedTextBox() then
				local camera = workspace.CurrentCamera; if not camera then return end; local pointAt = camera.ViewportSize / 2
				point({ UserInputType = Enum.UserInputType.MouseButton1, Position = pointAt }, false, true)
			else point(input, processed, false, true) end
		end)
		connections[#connections + 1] = env.uis.InputChanged:Connect(function(input, processed)
			if input.UserInputType == Enum.UserInputType.MouseMovement then point(input, processed, false, false) end
		end)
		pcall(function() connections[#connections + 1] = env.uis.WindowFocusReleased:Connect(M.stop) end)
		return true
	end
	env.require("runtime/dispose").add(M.stop, "world picker")
	return M
end
