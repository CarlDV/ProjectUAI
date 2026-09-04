-- The local character: read its state, change what a client is allowed to change,
-- and walk or teleport it.
--
-- Every write here is client-side. On a server that validates movement or stats
-- the change may be reverted, and the tool says so rather than reporting a success
-- the user will not see.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local function parts()
		local character = env.plr and env.plr.Character
		if not character then return nil, nil, nil end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
		return character, humanoid, root
	end

	local SETTABLE = {
		{ arg = "walk_speed", field = "WalkSpeed", min = 0, max = 500 },
		{ arg = "jump_power", field = "JumpPower", min = 0, max = 500 },
		{ arg = "jump_height", field = "JumpHeight", min = 0, max = 200 },
		{ arg = "hip_height", field = "HipHeight", min = 0, max = 20 },
		{ arg = "health", field = "Health", min = 0, max = 1e6 },
		{ arg = "max_health", field = "MaxHealth", min = 1, max = 1e6 },
	}

	return {
		{
			name = "character_state",
			risk = "read",
			description = "Read your character: position, health, movement values and what it is standing on.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local character, humanoid, root = parts()
				if not character then return "Your character is not loaded." end

				local rows = { { "Path", H.pathOf(character) } }
				if root then
					rows[#rows + 1] = { "Position", H.show(root.Position) }
					rows[#rows + 1] = { "Velocity", H.show(root.AssemblyLinearVelocity or root.Velocity) }
				end
				if humanoid then
					rows[#rows + 1] = { "Health", string.format("%s / %s", H.show(humanoid.Health), H.show(humanoid.MaxHealth)) }
					rows[#rows + 1] = { "WalkSpeed", H.show(humanoid.WalkSpeed) }
					rows[#rows + 1] = { "JumpPower", H.show(humanoid.JumpPower) }
					rows[#rows + 1] = { "Sitting", H.show(humanoid.Sit) }
					rows[#rows + 1] = { "MoveDirection", H.show(humanoid.MoveDirection) }
					local okState, state = pcall(function() return humanoid:GetState() end)
					if okState then rows[#rows + 1] = { "State", tostring(state.Name or state) } end
					local floor = humanoid.FloorMaterial
					if floor then rows[#rows + 1] = { "Standing on", tostring(floor.Name or floor) } end
				else
					rows[#rows + 1] = { "Humanoid", "missing" }
				end
				rows[#rows + 1] = { "Parts", tostring(#character:GetChildren()) }
				return H.keyValues(rows)
			end,
		},
		{
			name = "character_set",
			risk = "write",
			description = "Change movement or health values on your own character. Values a server owns will snap back.",
			parameters = {
				type = "object",
				properties = {
					walk_speed = { type = "number", description = "0-500." },
					jump_power = { type = "number", description = "0-500." },
					jump_height = { type = "number" },
					hip_height = { type = "number" },
					health = { type = "number" },
					max_health = { type = "number" },
					sit = { type = "boolean", description = "Sit or stand up." },
					jump = { type = "boolean", description = "Jump once, now." },
				},
				required = {},
			},
			run = function(args)
				local _, humanoid = parts()
				if not humanoid then return H.fail("your character has no Humanoid") end

				local changes = {}
				for _, spec in ipairs(SETTABLE) do
					local value = tonumber(args[spec.arg])
					if value then
						local clamped = util.clamp(value, spec.min, spec.max)
						local ok = pcall(function() humanoid[spec.field] = clamped end)
						if ok then
							changes[#changes + 1] = spec.field .. " = " .. H.show(clamped)
						else
							changes[#changes + 1] = spec.field .. " (rejected)"
						end
					end
				end
				if args.sit ~= nil then
					local ok = pcall(function() humanoid.Sit = args.sit == true end)
					changes[#changes + 1] = ok and ("Sit = " .. H.show(args.sit == true)) or "Sit (rejected)"
				end
				if args.jump == true then
					local ok = pcall(function() humanoid.Jump = true end)
					changes[#changes + 1] = ok and "jumped" or "jump (rejected)"
				end

				if #changes == 0 then return "Nothing to change. Pass at least one value." end
				return "Character: " .. table.concat(changes, ", ")
			end,
		},
		{
			name = "character_walk",
			risk = "write",
			description = "Walk your character to a position using normal pathing, waiting until it arrives or gives up. Use this rather than teleporting when the server watches movement.",
			parameters = {
				type = "object",
				properties = {
					position = { type = "string", description = "Target as 'x, y, z'." },
					timeout = { type = "number", description = "Seconds to wait, 1-20. Default 8.", minimum = 1, maximum = 20 },
				},
				required = { "position" },
			},
			run = function(args, ctx)
				local _, humanoid, root = parts()
				if not humanoid or not root then return H.fail("your character is not loaded") end

				local target = H.coerce(args.position, Vector3.new(0, 0, 0))
				if not target then return H.fail("position must be three numbers, e.g. '10, 5, -20'") end

				local startedAt = root.Position
				local ok = pcall(function() humanoid:MoveTo(target) end)
				if not ok then return H.fail("MoveTo was rejected") end

				local limit = util.clamp(tonumber(args.timeout) or 8, 1, 20)
				local waited = 0
				while waited < limit do
					if ctx and ctx.aborted and ctx.aborted() then break end
					local current = root.Position
					if (current - target).Magnitude < 4 then
						return string.format("Arrived at %s after %.1fs", H.show(current), waited)
					end
					waited = waited + (clock.wait(0.2) or 0.2)
				end

				local ended = root.Position
				return string.format("Stopped after %.0fs at %s (moved %.1f studs, target was %s)",
					waited, H.show(ended), (ended - startedAt).Magnitude, H.show(target))
			end,
		},
		{
			name = "character_teleport",
			risk = "write",
			description = "Move your character straight to a position. Client-side only, so a server with position checks may revert it.",
			parameters = {
				type = "object",
				properties = {
					position = { type = "string", description = "Target as 'x, y, z'." },
				},
				required = { "position" },
			},
			run = function(args)
				local _, _, root = parts()
				if not root then return H.fail("your character is not loaded") end
				local target = H.coerce(args.position, Vector3.new(0, 0, 0))
				if not target then return H.fail("position must be three numbers") end
				local from = root.Position
				local ok, err = pcall(function() root.CFrame = CFrame.new(target) end)
				if not ok then return H.fail(tostring(err)) end
				return string.format("Teleported from %s to %s", H.show(from), H.show(target))
			end,
		},
	}
end
