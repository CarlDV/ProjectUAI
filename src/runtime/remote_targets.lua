-- One resolver for capture controls and Explorer-derived target scopes.
return function(env)
	local explorer = env.require("runtime/explorer")
	local refs = env.require("runtime/instance_refs")
	local M = {}
	function M.resolve(scope, remoteId, snapshot)
		local result = { ids = {}, selection = snapshot or explorer.state() }
		if scope == "Game subtree" then result.rootId = refs.id(game); return result end
		if scope == "Explorer selection" or scope == "Selected subtree" then
			local valid, why = explorer.validateSelection(result.selection); if not valid then return nil, why end
			if not result.selection.primaryId then return nil, "Choose an Explorer object first" end
			if scope == "Selected subtree" then result.rootId = result.selection.primaryId; return result end
			for _, key in ipairs(result.selection.selectedIds) do result.ids[#result.ids + 1] = key end
		elseif scope == "Selected remote" then
			if not remoteId then local valid, why = explorer.validateSelection(result.selection); if not valid then return nil, why end end
			remoteId = remoteId or result.selection.primaryId
			if not remoteId then return nil, "Choose a remote in Explorer or the Remotes list before starting" end
			result.ids = { remoteId }
		else return nil, "Choose an explicit capture scope" end
		for _, key in ipairs(result.ids) do
			local object, why = refs.resolve(key); if not object then return nil, why end
			if object.ClassName ~= "RemoteEvent" and object.ClassName ~= "RemoteFunction" and object.ClassName ~= "UnreliableRemoteEvent" then return nil, "Explorer selection must contain only remotes; choose Selected subtree for a folder" end
		end
		return result
	end
	return M
end
