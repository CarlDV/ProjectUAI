-- On-screen interfaces: read them, press them, mark things up, and tell the user
-- something.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local function guiRoots()
		local roots = {}
		local playerGui = env.plr and env.plr:FindFirstChild("PlayerGui")
		if playerGui then roots[#roots + 1] = playerGui end
		local okCore, coreGui = pcall(function() return env.services.CoreGui end)
		if okCore and coreGui then roots[#roots + 1] = coreGui end
		return roots
	end

	return {
		{
			name = "gui_tree",
			risk = "read",
			description = "List the on-screen interfaces: every ScreenGui in PlayerGui and CoreGui, with whether it is enabled.",
			parameters = {
				type = "object",
				properties = {
					limit = { type = "integer", minimum = 1, maximum = 80 },
				},
				required = {},
			},
			run = function(args)
				local found = {}
				for _, root in ipairs(guiRoots()) do
					for _, child in ipairs(root:GetChildren()) do
						local ok, isGui = pcall(function() return child:IsA("LayerCollector") end)
						if ok and isGui then found[#found + 1] = child end
					end
				end
				if #found == 0 then return "No screen interfaces are present." end
				return string.format("%d interface(s):\n%s", #found,
					H.list(found, H.limit(args.limit, 40, 80), function(gui)
						local okCount, descendants = pcall(function() return #gui:GetDescendants() end)
						return string.format("%s [%s] %s, %s",
							H.pathOf(gui), gui.ClassName,
							gui.Enabled and "enabled" or "disabled",
							okCount and util.pluralise(descendants, "element") or "unknown size")
					end))
			end,
		},
		{
			name = "gui_text",
			risk = "read",
			description = "Read the visible text under a GUI element, in layout order. Use it to find out what is actually on screen.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to a ScreenGui or frame. Defaults to every screen interface." },
					limit = { type = "integer", minimum = 1, maximum = 120 },
				},
				required = {},
			},
			run = function(args)
				local targets = {}
				if args.path and util.trim(args.path) ~= "" then
					local instance, err = H.resolve(args.path)
					if not instance then return H.fail(err) end
					targets[1] = instance
				else
					targets = guiRoots()
				end

				local rows = {}
				for _, root in ipairs(targets) do
					local ok, descendants = pcall(function() return root:GetDescendants() end)
					if ok then
						for _, node in ipairs(descendants) do
							local okText, text = pcall(function() return node.Text end)
							if okText and type(text) == "string" and util.trim(text) ~= "" then
								local visible = true
								pcall(function() visible = node.Visible end)
								rows[#rows + 1] = {
									text = util.ellipsis(text, 90),
									path = H.pathOf(node),
									class = node.ClassName,
									visible = visible,
								}
							end
						end
					end
				end

				if #rows == 0 then return "No text elements found." end
				return string.format("%d text element(s):\n%s", #rows,
					H.list(rows, H.limit(args.limit, 50, 120), function(row)
						return string.format("%q %s[%s] %s", row.text,
							row.visible and "" or "(hidden) ", row.class, row.path)
					end))
			end,
		},
		{
			name = "gui_click",
			risk = "write",
			needs = { "hooks" },
			description = "Press a GUI button by firing the handlers connected to it. Needs a host that exposes signal introspection.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to a TextButton or ImageButton." },
					signal = {
						type = "string",
						enum = { "Activated", "MouseButton1Click", "MouseButton1Down" },
						description = "Which signal to fire. Default Activated, which most modern interfaces use.",
					},
				},
				required = { "path" },
			},
			run = function(args)
				local button, err = H.resolve(args.path)
				if not button then return H.fail(err) end
				local okA, isButton = pcall(function() return button:IsA("GuiButton") end)
				if not okA or not isButton then
					return H.fail(button.ClassName .. " is not a button")
				end

				local signalName = args.signal or "Activated"
				local okSignal, signal = pcall(function() return button[signalName] end)
				if not okSignal or not signal then return H.fail("no signal named " .. signalName) end

				local okConn, connections = pcall(caps.fn.getconnections, signal)
				if not okConn or type(connections) ~= "table" then
					return H.fail("could not read the connections on that signal")
				end
				if #connections == 0 then
					return string.format("%s has no %s handlers, so pressing it would do nothing.",
						H.pathOf(button), signalName)
				end

				local fired = 0
				for _, connection in ipairs(connections) do
					local okFire = pcall(function() connection:Fire() end)
					if okFire then fired = fired + 1 end
				end
				return string.format("Fired %d of %d %s handler(s) on %s",
					fired, #connections, signalName, H.pathOf(button))
			end,
		},
		{
			name = "click_detector_fire",
			risk = "danger",
			needs = { "hooks" },
			description = "Trigger a ClickDetector or a part's TouchInterest as if the player had interacted with it. This reaches the server.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Path to the ClickDetector, or to a part containing one." },
					distance = { type = "number", description = "Reported click distance. Default 0." },
				},
				required = { "path" },
			},
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local detector = instance
				local okA, isDetector = pcall(function() return instance:IsA("ClickDetector") end)
				if not (okA and isDetector) then
					detector = instance:FindFirstChildOfClass("ClickDetector")
				end

				if detector and caps.fn.fireclickdetector then
					local ok, fireErr = pcall(caps.fn.fireclickdetector, detector, tonumber(args.distance) or 0)
					if not ok then return H.fail(tostring(fireErr)) end
					return "Clicked " .. H.pathOf(detector)
				end

				local prompt = instance:FindFirstChildOfClass("ProximityPrompt")
				if prompt then
					local ok = pcall(function() prompt:InputHoldBegin() end)
					if ok then
						clock.wait(math.min(prompt.HoldDuration or 0, 2) + 0.05)
						pcall(function() prompt:InputHoldEnd() end)
						return "Triggered the ProximityPrompt on " .. H.pathOf(prompt)
					end
				end

				if caps.fn.firetouchinterest then
					local root = env.plr and env.plr.Character
						and (env.plr.Character:FindFirstChild("HumanoidRootPart") or env.plr.Character.PrimaryPart)
					local okPart, isPart = pcall(function() return instance:IsA("BasePart") end)
					if root and okPart and isPart then
						pcall(caps.fn.firetouchinterest, root, instance, 0)
						clock.wait(0.05)
						pcall(caps.fn.firetouchinterest, root, instance, 1)
						return "Simulated a touch on " .. H.pathOf(instance)
					end
				end

				return H.fail("nothing interactable found at that path, or the host lacks the function to trigger it")
			end,
		},
		{
			name = "highlight",
			risk = "write",
			description = "Outline an instance on screen for a few seconds so the user can see which one you mean.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					seconds = { type = "number", description = "1-30. Default 6.", minimum = 1, maximum = 30 },
					colour = { type = "string", description = "Outline colour as 'r, g, b' or '#rrggbb'." },
				},
				required = { "path" },
			},
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local okNew, highlight = pcall(function() return Instance.new("Highlight") end)
				if not okNew or not highlight then return H.fail("this host has no Highlight class") end

				local colour = Color3.fromRGB(0, 225, 190)
				if args.colour and util.trim(args.colour) ~= "" then
					local parsed = H.coerce(args.colour, colour)
					if parsed then colour = parsed end
				end

				highlight.Name = "UAI_Highlight"
				highlight.FillColor = colour
				highlight.OutlineColor = colour
				highlight.FillTransparency = 0.65
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				highlight.Adornee = instance
				highlight.Parent = instance

				local seconds = util.clamp(tonumber(args.seconds) or 6, 1, 30)
				clock.delay(seconds, function()
					pcall(function() highlight:Destroy() end)
				end)
				return string.format("Highlighted %s for %.0f seconds", H.pathOf(instance), seconds)
			end,
		},
		{
			name = "notify",
			risk = "read",
			description = "Show a short message to the user as a toast in the agent's own interface. Use it for something worth noticing, not for your reply.",
			parameters = {
				type = "object",
				properties = {
					text = { type = "string", description = "One line, under about 90 characters." },
					tone = { type = "string", enum = { "info", "good", "warn", "bad" } },
				},
				required = { "text" },
			},
			run = function(args)
				local overlay = env.require("ui/overlay")
				local text = util.ellipsis(args.text, 140)
				overlay.toast(text, args.tone or "info")
				return "Shown to the user: " .. text
			end,
		},
		{
			name = "clipboard_set",
			risk = "write",
			needs = { "clipboard" },
			description = "Put text on the user's clipboard.",
			parameters = {
				type = "object",
				properties = { text = { type = "string" } },
				required = { "text" },
			},
			run = function(args)
				local text = tostring(args.text or "")
				if text == "" then return "Nothing to copy." end
				local ok, err = pcall(caps.fn.clipboard, text)
				if not ok then return H.fail(tostring(err)) end
				return string.format("Copied %d characters to the clipboard.", #text)
			end,
		},
	}
end
