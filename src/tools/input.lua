-- Virtual input: keyboard and mouse simulation.
--
-- Supports VirtualInputManager (standard engine input injector), executor globals
-- (keypress, mouse1click, etc.) and VirtualUser as fallbacks.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local KEY_ALIASES = {
		["0"] = "Zero",
		["1"] = "One",
		["2"] = "Two",
		["3"] = "Three",
		["4"] = "Four",
		["5"] = "Five",
		["6"] = "Six",
		["7"] = "Seven",
		["8"] = "Eight",
		["9"] = "Nine",
		enter = "Return",
		space = "Space",
		esc = "Escape",
		escape = "Escape",
		tab = "Tab",
		backspace = "Backspace",
		shift = "LeftShift",
		lshift = "LeftShift",
		rshift = "RightShift",
		ctrl = "LeftControl",
		control = "LeftControl",
		lctrl = "LeftControl",
		rctrl = "RightControl",
		alt = "LeftAlt",
		lalt = "LeftAlt",
		ralt = "RightAlt",
		up = "Up",
		down = "Down",
		left = "Left",
		right = "Right",
	}

	local validKeyCodes = nil
	local function getValidKeyCodes()
		if validKeyCodes then return validKeyCodes end
		validKeyCodes = {}
		local ok, items = pcall(function() return Enum.KeyCode:GetEnumItems() end)
		if ok and type(items) == "table" then
			for _, item in ipairs(items) do
				validKeyCodes[item.Name:lower()] = item
			end
		end
		return validKeyCodes
	end

	local function resolveKeyCode(rawName)
		local cleaned = util.trim(rawName or "")
		if cleaned == "" then return nil, "no key specified" end

		local lower = cleaned:lower()
		local targetName = KEY_ALIASES[lower] or cleaned

		local codes = getValidKeyCodes()
		if codes[targetName:lower()] then
			return codes[targetName:lower()]
		end

		if #cleaned == 1 then
			local upper = cleaned:upper()
			if codes[upper:lower()] then
				return codes[upper:lower()]
			end
		end

		return nil, "unrecognised KeyCode: '" .. cleaned .. "'"
	end

	local function getVim()
		local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
		return (ok and vim) or nil
	end

	local function getVu()
		local ok, vu = pcall(function() return game:GetService("VirtualUser") end)
		return (ok and vu) or nil
	end

	local function getMousePos(customX, customY)
		local x = tonumber(customX)
		local y = tonumber(customY)
		if x and y then return x, y end

		if env.uis and env.uis.GetMouseLocation then
			local ok, loc = pcall(function() return env.uis:GetMouseLocation() end)
			if ok and loc then
				x = x or loc.X
				y = y or loc.Y
			end
		end

		if not x or not y then
			local camera = env.services.Workspace and env.services.Workspace.CurrentCamera
			if camera and camera.ViewportSize then
				x = x or math.floor(camera.ViewportSize.X / 2)
				y = y or math.floor(camera.ViewportSize.Y / 2)
			end
		end

		return x or 0, y or 0
	end

	local function sendKeyVim(vim, keyCode, action, duration)
		if action == "press" then
			vim:SendKeyEvent(true, keyCode, false, game)
			clock.wait(duration)
			vim:SendKeyEvent(false, keyCode, false, game)
			return true
		elseif action == "down" then
			vim:SendKeyEvent(true, keyCode, false, game)
			return true
		elseif action == "up" then
			vim:SendKeyEvent(false, keyCode, false, game)
			return true
		end
		return false
	end

	local function sendKeyExecutor(keyCode, action, duration)
		local hasKp = pcall(function() return keypress end)
		local hasKr = pcall(function() return keyrelease end)
		if not (hasKp and hasKr and type(keypress) == "function" and type(keyrelease) == "function") then
			return false
		end

		local value = keyCode.Value
		if action == "press" then
			keypress(value)
			clock.wait(duration)
			keyrelease(value)
			return true
		elseif action == "down" then
			keypress(value)
			return true
		elseif action == "up" then
			keyrelease(value)
			return true
		end
		return false
	end

	local function sendKeyVu(vu, keyCode, action)
		pcall(function() vu:CaptureController() end)
		local name = keyCode.Name
		if action == "down" or action == "press" then
			pcall(function() vu:SetKeyDown(name) end)
		end
		if action == "press" then
			clock.wait(0.05)
		end
		if action == "up" or action == "press" then
			pcall(function() vu:SetKeyUp(name) end)
		end
		return true
	end

	return {
		{
			name = "key_press",
			risk = "write",
			description = "Simulate pressing or holding a keyboard key (e.g. 'E', 'Space', 'Return', 'W', 'A', 'S', 'D', 'Tab', 'LeftShift', '1').",
			parameters = {
				type = "object",
				properties = {
					key = {
						type = "string",
						description = "Key name or character, e.g. 'E', 'Space', 'Return', 'W', '1', 'LeftShift'.",
					},
					action = {
						type = "string",
						enum = { "press", "down", "up" },
						description = "'press' taps key down and up. 'down' holds key. 'up' releases key. Default 'press'.",
					},
					duration = {
						type = "number",
						description = "Hold duration in seconds if action is 'press' (0.01 - 2.0, default 0.05).",
						minimum = 0.01,
						maximum = 2.0,
					},
				},
				required = { "key" },
			},
			run = function(args)
				local keyCode, keyErr = resolveKeyCode(args.key)
				if not keyCode then return H.fail(keyErr) end

				local action = args.action or "press"
				local duration = util.clamp(tonumber(args.duration) or 0.05, 0.01, 2.0)

				local vim = getVim()
				local ok = false

				if vim and vim.SendKeyEvent then
					local okVim = pcall(function()
						return sendKeyVim(vim, keyCode, action, duration)
					end)
					if okVim then ok = true end
				end

				if not ok then
					local okExec = pcall(function()
						return sendKeyExecutor(keyCode, action, duration)
					end)
					if okExec then ok = true end
				end

				if not ok then
					local vu = getVu()
					if vu then
						local okVu = pcall(function()
							return sendKeyVu(vu, keyCode, action)
						end)
						if okVu then ok = true end
					end
				end

				if not ok then
					return H.fail("no virtual input injection provider available on this host")
				end

				return string.format("Key %s: %s", keyCode.Name, action)
			end,
		},
		{
			name = "mouse_click",
			risk = "write",
			description = "Simulate mouse clicks or cursor movement on screen coordinates.",
			parameters = {
				type = "object",
				properties = {
					button = {
						type = "string",
						enum = { "left", "right", "middle" },
						description = "Mouse button to click. Default 'left'.",
					},
					action = {
						type = "string",
						enum = { "click", "down", "up", "move" },
						description = "'click' clicks down and up. 'down' holds button. 'up' releases button. 'move' positions cursor. Default 'click'.",
					},
					x = {
						type = "number",
						description = "Screen X coordinate in pixels. Defaults to current mouse location or viewport center.",
					},
					y = {
						type = "number",
						description = "Screen Y coordinate in pixels. Defaults to current mouse location or viewport center.",
					},
				},
				required = {},
			},
			run = function(args)
				local button = args.button or "left"
				local action = args.action or "click"
				local x, y = getMousePos(args.x, args.y)

				local vim = getVim()
				local vu = getVu()
				local ok = false

				local btnIndex = 0
				if button == "right" then btnIndex = 1 end
				if button == "middle" then btnIndex = 2 end

				if vim and vim.SendMouseButtonEvent then
					local okVim = pcall(function()
						if action == "move" then
							if vim.SendMouseMoveEvent then
								vim:SendMouseMoveEvent(x, y, game)
							end
						elseif action == "click" then
							vim:SendMouseButtonEvent(x, y, btnIndex, true, game, 0)
							clock.wait(0.05)
							vim:SendMouseButtonEvent(x, y, btnIndex, false, game, 0)
						elseif action == "down" then
							vim:SendMouseButtonEvent(x, y, btnIndex, true, game, 0)
						elseif action == "up" then
							vim:SendMouseButtonEvent(x, y, btnIndex, false, game, 0)
						end
						return true
					end)
					if okVim then ok = true end
				end

				if not ok and action == "click" then
					local hasM1 = pcall(function() return mouse1click end)
					local hasM2 = pcall(function() return mouse2click end)
					if button == "left" and hasM1 and type(mouse1click) == "function" then
						pcall(mouse1click)
						ok = true
					elseif button == "right" and hasM2 and type(mouse2click) == "function" then
						pcall(mouse2click)
						ok = true
					end
				end

				if not ok and vu then
					local okVu = pcall(function()
						vu:CaptureController()
						local pos = Vector2.new(x, y)
						if action == "click" then
							if button == "right" then
								vu:ClickButton2(pos)
							else
								vu:ClickButton1(pos)
							end
						elseif action == "down" then
							vu:Button1Down(pos)
						elseif action == "up" then
							vu:Button1Up(pos)
						end
						return true
					end)
					if okVu then ok = true end
				end

				if not ok then
					return H.fail("no mouse input injection provider available on this host")
				end

				return string.format("Mouse %s %s at (%.0f, %.0f)", button, action, x, y)
			end,
		},
	}
end
