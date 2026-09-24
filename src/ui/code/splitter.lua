-- Code-only pane resize handle. Global input listeners live exactly as long as
-- their owning pane, and releases outside the handle still end the drag.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local M = {}
	function M.new(parent, onMove, horizontal)
		local button = Instance.new("TextButton", parent)
		button.Name, button.Text, button.AutoButtonColor = "PaneDivider", "", false
		button.BackgroundTransparency, button.BorderSizePixel, button.ZIndex = 1, 0, 8
		button.Active, button.Selectable = true, false
		P.frame(button, { name = "Rule", bg = theme.color.borderSubtle, size = horizontal and UDim2.new(1, 0, 0, 1) or UDim2.new(0, 1, 1, 0), position = horizontal and UDim2.new(0, 0, 0.5, 0) or UDim2.new(0.5, 0, 0, 0) })
		local dragging, touch, alive = false, nil, true
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, touch = true, input.UserInputType == Enum.UserInputType.Touch and input or nil
			end
		end)
		local move = env.uis.InputChanged:Connect(function(input)
			if alive and dragging and button.Visible and ((touch and input == touch) or (not touch and input.UserInputType == Enum.UserInputType.MouseMovement)) then onMove(input.Position) end
		end)
		local ended = env.uis.InputEnded:Connect(function(input)
			if input == touch or input.UserInputType == Enum.UserInputType.MouseButton1 then dragging, touch = false, nil end
		end)
		button:GetPropertyChangedSignal("Visible"):Connect(function() if not button.Visible then dragging, touch = false, nil end end)
		local function destroy() if not alive then return end; alive = false; move:Disconnect(); ended:Disconnect(); button:Destroy() end
		return { root = button, destroy = destroy }
	end
	return M
end
