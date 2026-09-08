-- Ready-made recipes the agent can execute instead of re-deriving them.
--
-- The agent already has run_luau, and it is a sharp tool: every template here is
-- a proven invocation that replaces ten attempts at composing the same idea.
-- A template is not a privilege escalation -- running one stamps out a real tool
-- call with the same arguments the model would have written, which means it goes
-- through the same permission prompt, the same hooks and the same timeouts. The
-- user sees exactly what a template will run before it runs.
--
-- Every template stores an `arguments` table. A {FIELD} token inside a string is
-- replaced with the value the model supplies. Substitution is plain token
-- replacement, not code generation, so what the user approves in the permission
-- prompt is exactly the code that executes.
return function(env)
	local util = env.require("runtime/util")
	local registry = env.require("agent/registry")
	local H = env.require("tools/helpers")

	-- Replacement is deliberately boring: find a {TOKEN}, look it up, splice the
	-- value in. A missing value is a failure rather than an empty string, because
	-- code that runs with a literal "{PATH}" inside it fails somewhere far from
	-- the cause, in a way the model cannot read back.
	local function fill(source, values)
		if type(source) ~= "string" or type(values) ~= "table" then return source end
		local missing = {}
		local filled = source:gsub("{(%w+)}", function(token)
			local value = values[token]
			if value == nil then
				missing[#missing + 1] = token
				return "{" .. token .. "}"
			end
			return tostring(value)
		end)
		if #missing > 0 then
			return nil, string.format("missing a value for %s", table.concat(missing, ", "))
		end
		return filled
	end

	-- The templates. Fields:
	--   id        stable identifier the model calls template_run with
	--   title     one line, for the listing
	--   tool      the tool this template invokes
	--   arguments the call's arguments; {TOKEN}s are filled from `values`
	--   params    parameter descriptions shown by template_list
	--   notes     limitations worth knowing before running
	local TEMPLATES = {
		{
			id = "nearest_players",
			title = "List the players closest to you, with distances",
			tool = "run_luau",
			arguments = { code = [[
local me = game:GetService("Players").LocalPlayer
local root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
if not root then return "No character yet." end
local rows = {}
for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
	if p ~= me and p.Character then
		local their = p.Character:FindFirstChild("HumanoidRootPart")
		if their then
			rows[#rows + 1] = string.format("%s (%d studs)", p.Name, (their.Position - root.Position).Magnitude)
		end
	end
end
table.sort(rows)
return #rows == 0 and "Nobody else has a character." or table.concat(rows, "\n")
]] },
			params = {},
			notes = "Everyone needs a HumanoidRootPart; ghosts report no distance.",
		},
		{
			id = "esp_players",
			title = "Highlight every player's character through walls",
			tool = "run_luau",
			arguments = { code = [[
local Players = game:GetService("Players")
local made = 0
for _, p in ipairs(Players:GetPlayers()) do
	if p ~= Players.LocalPlayer and p.Character then
		local old = p.Character:FindFirstChild("UAI_ESP")
		if old then old:Destroy() end
		local hl = Instance.new("Highlight")
		hl.Name = "UAI_ESP"
		hl.FillColor = Color3.fromRGB(255, 60, 60)
		hl.FillTransparency = 0.5
		hl.OutlineColor = Color3.fromRGB(255, 255, 255)
		hl.Parent = p.Character
		made = made + 1
		p.Character.AncestryChanged:Connect(function()
			if hl.Parent ~= p.Character then hl:Destroy() end
		end)
	end
end
return "Highlighted " .. made .. " character(s). Re-run to refresh."
]] },
			params = {},
			notes = "Client-side only. Destroyed by respawns; re-run after anyone respawns.",
		},
		{
			id = "fps_monitor",
			title = "Measure real frame times over 5 seconds and report FPS statistics",
			tool = "run_luau",
			arguments = { code = [[
local RunService = game:GetService("RunService")
local times = {}
local t0 = os.clock()
local connection
connection = RunService.RenderStepped:Connect(function(dt)
	times[#times + 1] = dt
end)
while os.clock() - t0 < 5 do task.wait(0.25) end
connection:Disconnect()
table.sort(times)
if #times == 0 then return "No frames rendered." end
local total = 0
for _, dt in ipairs(times) do total = total + dt end
local median = times[math.floor(#times / 2) + 1]
return string.format(
	"Frames: %d\nMean: %.1f FPS\nMedian: %.1f FPS\nWorst: %.1f FPS\nBest: %.1f FPS",
	#times, #times / total, 1 / median, 1 / times[#times], 1 / times[1])
]] },
			params = {},
			notes = "Uses RenderStepped; the client must be rendering frames.",
		},
		{
			id = "remote_spam",
			title = "Fire a remote on an interval for a duration",
			tool = "run_luau",
			arguments = { code = [[
local remote = {REMOTE}
local action = {ACTION}
local seconds = {SECONDS}
local count = 0
local t0 = os.clock()
while os.clock() - t0 < seconds do
	remote:FireServer(action)
	count = count + 1
	task.wait(0.5)
end
return "Fired " .. count .. " times."
]] },
			params = {
				REMOTE = "Dotted path to the RemoteEvent, e.g. ReplicatedStorage.Remotes.Purchase",
				ACTION = "What to send each time, e.g. an item name or id",
				SECONDS = "How long to keep firing, in seconds",
			},
			notes = "A real server call every 0.5s. Repeated firing can be logged by anticheat.",
		},
		{
			id = "json_roundtrip",
			title = "Validate and re-encode a JSON string",
			tool = "run_luau",
			arguments = { code = [[
local raw = [==[{JSON}]==]
local HttpService = game:GetService("HttpService")
local data = HttpService:JSONDecode(raw)
return HttpService:JSONEncode(data)
]] },
			params = {
				JSON = "The JSON text to check",
			},
			notes = "Decodes then re-encodes: a syntax error in the JSON is the failure you get.",
		},
	}

	local function byId(id)
		for _, t in ipairs(TEMPLATES) do
			if t.id == id then return t end
		end
		return nil
	end

	return {
		{
			name = "template_list",
			risk = "read",
			description = "List the ready-made script templates this client ships with. A template is a pre-written tool invocation for a common job -- player distances, ESP, FPS statistics, remote automation. Call with no arguments for the index; pass an id for one template's full detail.",
			parameters = {
				type = "object",
				properties = {
					id = { type = "string", description = "Show this one template's code and parameters." },
				},
				required = {},
			},
			run = function(args)
				local id = util.trim(tostring(args.id or ""))
				if id ~= "" then
					local t = byId(id)
					if not t then return H.fail("no template named '" .. id .. "'") end
					local lines = { t.title, "Runs tool: " .. t.tool }
					local names = {}
					for name in pairs(t.params or {}) do names[#names + 1] = name end
					if #names > 0 then
						table.sort(names)
						lines[#lines + 1] = "Parameters:"
						for _, name in ipairs(names) do
							lines[#lines + 1] = string.format("  %s: %s", name, t.params[name])
						end
					end
					if t.notes then lines[#lines + 1] = "Notes: " .. t.notes end
					lines[#lines + 1] = "Code:"
					lines[#lines + 1] = tostring(t.arguments.code)
					return table.concat(lines, "\n")
				end

				local rows = {}
				for _, t in ipairs(TEMPLATES) do
					local count = 0
					for _ in pairs(t.params or {}) do count = count + 1 end
					rows[#rows + 1] = string.format("%s - %s (%s)", t.id, t.title,
						count > 0 and util.pluralise(count, "parameter") or "no parameters")
				end
				return string.format("%d template(s):\n%s\nCall template_run with an id and values.",
					#rows, table.concat(rows, "\n"))
			end,
		},
		{
			name = "template_run",
			risk = "danger",
			needs = { "exec" },
			description = "Run a script template by id with the given values. The expanded code appears in the permission prompt before it runs -- what you approve is what runs, because placeholders are filled before the permission decision, not after.",
			parameters = {
				type = "object",
				properties = {
					id = { type = "string", description = "Template id from template_list." },
					values = {
						type = "object",
						description = "The template's values. Keys are the parameter names template_list showed.",
					},
				},
				required = { "id" },
			},
			run = function(args, ctx)
				local t = byId(util.trim(tostring(args.id or "")))
				if not t then return H.fail("no template named '" .. tostring(args.id) .. "'") end
				local values = type(args.values) == "table" and args.values or {}
				local final = {}
				for key, pattern in pairs(t.arguments) do
					if type(pattern) == "string" and pattern:find("{", 1, true) then
						local filled, err = fill(pattern, values)
						if not filled then return H.fail(err) end
						final[key] = filled
					else
						final[key] = pattern
					end
				end
				local call = {
					id = "template:" .. t.id,
					["function"] = { name = t.tool, arguments = util.encode(final) },
				}
				local result = registry.dispatch(call, ctx)
				if type(result) == "table" then
					return result.text or tostring(result)
				end
				return tostring(result)
			end,
		},
	}
end
