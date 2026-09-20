-- Running and reading Luau.
--
-- Execution stays behind the danger permission, with captured output, cooperative
-- loop checkpoints and a deadline shared by the script and its spawned tasks.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local H = env.require("tools/helpers")
	local execution = env.require("tools/execution")

	return {
		{
			name = "run_luau",
			risk = "danger",
			needs = { "exec" },
			description = "Run bounded Luau on the local client. Provide inline source in 'code', or 'path' to run a workspace file directly without reading it back first. Captures print/warn, tables and all return values; waits for functions started with task.spawn/defer/delay. Stop or the deadline cancels managed tasks. Loop checkpoints yield automatically. Prefer a specific tool when one exists. This is not a security sandbox; dynamically loaded code and engine calls can bypass cooperative guards.",
			timeout = function(args) return execution.timeout(args) + 1 end,
			parameters = {
				type = "object",
				properties = {
					code = { type = "string", minLength = 1, maxLength = 256000, description = "The source to run inline. Use print() for output; return values or tables to report results. Provide this or 'path', not both." },
					path = { type = "string", description = "Path to a workspace file to run, e.g. 'scripts/build.lua'. The client reads and runs it locally without loading its contents into the conversation. Provide this or 'code', not both." },
					timeout = { type = "number", minimum = 1, maximum = 60, description = "Execution deadline in seconds, including spawned tasks. Default 10. Use managed chat tools for persistent chat automation." },
				},
				required = {},
			},
			run = execution.run,
		},
		{
			name = "check_luau",
			risk = "read",
			needs = { "exec" },
			description = "Check Luau syntax without executing code or changing the game. Provide inline 'code' or a saved file 'path', not both. Prefer path for scripts you wrote or edited so their source need not be sent again. Returns compile errors for correction before run_luau.",
			parameters = {
				type = "object",
				properties = {
					code = { type = "string", minLength = 1, maxLength = 256000, description = "Inline Luau source to compile without running it. Provide this or path." },
					path = { type = "string", minLength = 1, description = "Workspace file or saved paste to compile locally, e.g. scripts/build.lua. Provide this or code." },
				},
				required = {},
			},
			run = execution.checkSource,
		},
		{
			name = "script_list",
			risk = "read",
			description = "List script instances in the place, with their paths. Useful for finding where behaviour lives before reading it.",
			parameters = {
				type = "object",
				properties = {
					root = { type = "string", description = "Where to search. Defaults to game." },
					kind = { type = "string", enum = { "any", "Script", "LocalScript", "ModuleScript" } },
					limit = { type = "integer", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = function(args)
				local root, err = H.resolve(args.root or "game")
				if not root then return H.fail(err) end
				local wanted = args.kind
				if not wanted or wanted == "any" then wanted = "LuaSourceContainer" end

				local ok, descendants = pcall(function() return root:GetDescendants() end)
				if not ok then return H.fail("could not read that subtree") end

				local hits = {}
				for _, node in ipairs(descendants) do
					local okA, isA = pcall(function() return node:IsA(wanted) end)
					if okA and isA then hits[#hits + 1] = node end
				end
				if #hits == 0 then return "No scripts found under " .. H.pathOf(root) .. "." end
				return string.format("%d script(s):\n%s", #hits,
					H.list(hits, H.limit(args.limit, 30, 100), function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "]"
					end))
			end,
		},
		{
			name = "script_source",
			risk = "read",
			description = "Read a script's source. Works when the host can read or decompile it; many live scripts cannot be read at all.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to the script instance." },
					limit = { type = "integer", description = "Maximum bytes in this slice. Default 3000; also bounded by the tool result budget.", minimum = 200, maximum = 64000 },
					offset = { type = "integer", minimum = 1, description = "1-based byte offset. Use the continuation offset from the previous result to read the next slice." },
				},
				required = { "path" },
			},
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local okA, isScript = pcall(function() return instance:IsA("LuaSourceContainer") end)
				if not okA or not isScript then
					return H.fail(instance.ClassName .. " is not a script")
				end

				local source
				local okSource, value = pcall(function() return instance.Source end)
				if okSource and type(value) == "string" and value ~= "" then
					source = value
				elseif caps.fn.decompile then
					local okDecomp, decompiled = pcall(caps.fn.decompile, instance)
					if okDecomp and type(decompiled) == "string" then source = decompiled end
				end

				if not source or util.trim(source) == "" then
					return "The source is not readable from here. Roblox hides Source from client scripts, and this host has no decompiler."
				end

				return H.readSlice(H.pathOf(instance), source, args, 3000)
			end,
		},
	}
end
