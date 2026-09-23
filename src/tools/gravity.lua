-- Dedicated Gravity tools use the normal UAI permissions and result budgets.
return function(env)
	local util = env.require("runtime/util")
	local gravity = env.require("runtime/gravity")
	local plugins = env.require("tools/gravity_plugins")
	local parts = env.require("tools/gravity_parts")
	local docs = env.require("runtime/gravity_docs")
	local H = env.require("tools/helpers")
	local function result(value, err)
		if not value then return H.fail(err) end
		return { text = util.encode(value), data = value }
	end
	return {
		{ name = "gravity_status", risk = "read", description = "Inspect the connected Project Gravity engine, selected shape, targets, held part count and settings. Reports when Gravity is not loaded.",
			parameters = { type = "object", properties = {}, required = {} }, run = function() return result(gravity.status()) end },
		{ name = "gravity_shapes", risk = "read", needs = { "gravity" },
			description = "List the live Gravity shape catalog, or pass name to inspect a shape's real control keys, values, buttons and stored-unit slider ranges. No hardcoded catalog.",
			parameters = { type = "object", properties = {
				name = { type = "string" }, query = { type = "string" },
				offset = { type = "integer", minimum = 1 }, limit = { type = "integer", minimum = 1, maximum = 50 },
			}, required = {} }, run = function(args) return result(gravity.shapes(args)) end },
		{ name = "gravity_control", risk = "write", needs = { "gravity" },
			description = "Control Gravity using native handlers: start/recenter (defaults to your character), stop and release parts, pause/resume, enable/disable, reroll, reset_settings (all engine/shape settings and keybinds to defaults), or launch/charge a manually controlled Slingshot.",
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "start", "recenter", "stop", "pause", "resume", "enable", "disable", "reroll", "reset_settings", "launch", "charge" } },
				position = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } }, required = { "x", "y", "z" } },
				persist = { type = "boolean", description = "For reset_settings: defaults to true." },
			}, required = { "action" } }, run = function(args, ctx) return result(gravity.control(args, ctx)) end },
		{ name = "gravity_configure", risk = "write", needs = { "gravity" },
			description = "Change Gravity engine, formation, interface, performance and Part Control panel defaults using native names. Validates the whole batch, applies native effects, refreshes controls and requests a save. PartCtl* are panel defaults; use gravity_part_control to change selected parts. Read gravity_status first.",
			parameters = { type = "object", properties = {
				values = { type = "object", properties = gravity.fields, additionalProperties = false },
				persist = { type = "boolean", description = "Default true requests a save; false changes this session only." },
			}, required = { "values" } }, run = function(args, ctx) return result(gravity.configure(args, ctx)) end },
		{ name = "gravity_shape", risk = "write", needs = { "gravity" },
			description = "Select a Gravity shape, configure its control keys, or press one real Button. Inspect gravity_shapes(name=...) first. Values use stored units (display divided by Div). Buttons require that shape to be selected and never become settings.",
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "select", "configure", "button" } },
				shape = { type = "string", description = "Exact shape name; defaults to current shape." },
				values = { type = "object", properties = {}, additionalProperties = true }, button = { type = "string", description = "Button key or its Name when no Key exists." },
				persist = { type = "boolean" },
			}, required = { "action" } }, run = function(args, ctx) return result(gravity.changeShape(args, ctx)) end },
		{ name = "gravity_target", risk = "write", needs = { "gravity" },
			description = "Set Gravity's anchor to yourself or all players, add/remove a specific target, or clear targeting. Ambiguous player names are refused. Preserves the native Targets table.",
			parameters = { type = "object", properties = {
				mode = { type = "string", enum = { "self", "all", "add", "remove", "clear" } },
				player = { type = "string", description = "Exact username or user ID preferred; unique username prefixes and display names also work." },
			}, required = { "mode" } }, run = function(args, ctx) return result(gravity.target(args, ctx)) end },
		{ name = "gravity_keybind", risk = "write", needs = { "gravity" },
			description = "Set or clear one native Gravity hotkey on desktop or mobile. Provide action or shape, and a Roblox KeyCode name (e.g. E, F5); key=\"\" unbinds it. Refuses conflicts with other core/shape bindings. Read current keybinds in gravity_status.",
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "Recenter", "Reset", "Pause", "Disable" } }, shape = { type = "string" },
				key = { type = "string", maxLength = 50 }, persist = { type = "boolean" },
			}, required = { "key" } }, run = function(args, ctx) return result(gravity.keybind(args, ctx)) end },
		{ name = "gravity_favorite", risk = "write", needs = { "gravity" },
			description = "Add/remove shape favorites or clear all favorites in Gravity's native selector. List favorite flags with gravity_shapes. Saves by default; persist=false keeps this session only.",
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "add", "remove", "clear" } },
				shapes = { type = "array", items = { type = "string" }, minItems = 1, maxItems = 50 }, persist = { type = "boolean" },
			}, required = { "action" } }, run = function(args, ctx) return result(gravity.favorite(args, ctx)) end },
		{ name = "gravity_parts", risk = "read", needs = { "gravity" },
			description = "Inspect held Gravity parts with stable session-scoped IDs, paths, positions, selections and overrides. Paginated and sorted by claim ID; read nextOffset for more. IDs expire when the part is released or Gravity reloads.",
			parameters = { type = "object", properties = {
				filter = { type = "string", enum = { "all", "selected", "overridden" } }, query = { type = "string", maxLength = 120 },
				offset = { type = "integer", minimum = 1 }, limit = { type = "integer", minimum = 1, maximum = 25 },
			}, required = {} }, run = function(args) return result(parts.list(args)) end },
		{ name = "gravity_part_control", risk = "write", needs = { "gravity" },
			description = "Use native Gravity Part Control. select/add/deselect require IDs from gravity_parts; clear deselects without releasing overrides. select_all/select_overridden/invert replace the selection, capped at Gravity's native 512 parts. assign/move/ride/physics/release affect the current selection. assign supports pin/manual/shape/normal; a supplied position is shared by all assigned parts. move preserves group offsets and sets manual targets: use position for the group's center or offset for relative movement. physics replaces overrides; {} restores inheritance. release_all clears even unselected overrides. Selection and overrides are live session state.",
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "select", "add", "deselect", "clear", "select_all", "select_overridden", "invert", "assign", "move", "ride", "physics", "release", "release_all" } },
				ids = { type = "array", items = { type = "string", maxLength = 128 }, minItems = 1, maxItems = 512 },
				mode = { type = "string", enum = { "normal", "pin", "manual", "shape" } }, shape = { type = "string" },
				position = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } }, required = { "x", "y", "z" } },
				offset = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } }, required = { "x", "y", "z" } },
				ride = { type = "boolean" }, physics = { type = "object", properties = parts.physics, additionalProperties = false },
			}, required = { "action" } }, run = function(args, ctx) return result(parts.control(args, ctx)) end },
		{ name = "gravity_plugin_read", risk = "read",
			description = "Read Gravity's module guide/template (omit plugin), or real local/official shape source. Bounded source slices include continuation offsets. Read the guide before authoring a plugin; section=template returns a working module.",
			parameters = { type = "object", properties = {
				plugin = { type = "string" }, section = { type = "string", enum = { "guide", "template" } },
				origin = { type = "string", enum = { "auto", "local" } },
				offset = { type = "integer", minimum = 1 }, limit = { type = "integer", minimum = 200, maximum = 6000 },
			}, required = {} }, run = function(args, ctx)
				if not args.plugin then return H.readSlice("Gravity " .. (args.section or "guide"), args.section == "template" and docs.template or docs.guide, args, 4000) end
				local source, err, path = plugins.read(args, ctx)
				if not source then return H.fail(err) end
				return H.readSlice(path, source, args, 4000)
			end },
		{ name = "gravity_plugin_write", risk = "danger", needs = { "fs", "exec" }, timeout = 30,
			description = "Create/update a real GravityShapes/<plugin>.lua file from a saved source path or inline source. Prefer path for long scripts. Checks syntax and verifies disk contents. By default evaluates setup once with a deadline, validates f2/Controls and registers the module in Gravity. load=false saves without executing. overwrite=true is required for replacement. Does not select an inactive shape; existing active shapes reload with cleanup. Plugin callbacks need their own cleanup.",
			parameters = { type = "object", properties = {
				plugin = { type = "string", minLength = 1, maxLength = 104 }, source = { type = "string", minLength = 1, maxLength = 2 * 1024 * 1024 },
				path = { type = "string", description = "Workspace or pastes/ path containing the full module source. Use source or path, not both." },
				overwrite = { type = "boolean" }, load = { type = "boolean", description = "Default true loads the module into Gravity; false only saves syntax-checked source." },
			}, required = { "plugin" } }, run = function(args, ctx) return result(plugins.write(args, ctx)) end },
	}
end
