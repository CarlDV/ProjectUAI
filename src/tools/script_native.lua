return function(env)
	local refs = env.require("runtime/instance_refs")
	local sources = env.require("runtime/script_sources")
	local explorer = env.require("runtime/explorer")
	local H = env.require("tools/helpers")
	local N = env.require("tools/native_helpers").forGroup("script")
	local M = {}
	function M.extend(tool)
		if tool.name == "script_list" then
			tool.run = function(args, ctx)
				local root, why = H.resolve(args.root or "game"); if not root then return N.fail(why) end
				local result, err = explorer.query({ rootId = refs.id(root), class = args.kind and args.kind ~= "any" and args.kind or "LuaSourceContainer", limit = math.min(args.limit or 5, 5), cursor = args.cursor }, ctx)
				return N.result(N.page(result), err or "Script source references")
			end
			tool.parameters.properties.cursor = { type = "string" }
		elseif tool.name == "script_source" then
			tool.parameters.properties.instance_id, tool.parameters.properties.source_id = { type = "string" }, { type = "string" }
			tool.parameters.required = {}
			tool.parameters.properties.decompile, tool.parameters.properties.refresh = { type = "boolean" }, { type = "boolean" }
			tool.run = function(args, ctx)
				if args.source_id and (args.instance_id or args.path) then return N.fail("Choose exactly one source_id, instance_id, or path") end
				local item, why, detail
				if args.source_id then item, why, detail = sources.get(args.source_id)
				else local object, err = refs.select(args); if not object then return N.fail(err) end; item, why, detail = sources.inspect(refs.id(object), ctx, { decompile = args.decompile, refresh = args.refresh }) end
				if not item then local result = N.fail(why); result.data = detail; return result end
				local result = H.readSlice(item.name, item.source, { offset = args.offset, limit = math.min(args.limit or 3000, 6000) }, 3000)
				result.data = result.data or {}; result.data.sourceId, result.data.provenance, result.data.path = item.id, item.provenance, item.path
				result.data.source = sources.describe(item)
				return result
			end
		end
	end
	return M
end
