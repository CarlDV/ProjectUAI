-- File bindings belong to Code. Opening a file never executes it or replaces an
-- edited document; saving checks the disk version that was actually opened.
return function(env)
	local fs = env.require("runtime/fsx")
	local caps = env.require("runtime/caps")
	local store = env.require("runtime/code_store")
	local sources = env.require("runtime/script_sources")
	local util = env.require("runtime/util")
	local M = { root = fs.root, view = { expanded = { [""] = true }, pages = {}, y = 0 }, bindings = {} }
	local function clean(path, allowRoot)
		path = tostring(path or ""):gsub("\\", "/"):gsub("/+$", "")
		if path == fs.root then path = "" elseif path:sub(1, #fs.root + 1) == fs.root .. "/" then path = path:sub(#fs.root + 2) end
		if path == "" and allowRoot then return "" end
		return fs.sanitise(path)
	end
	function M.children(path)
		if not fs.enabled or not caps.fn.listfiles then return nil, "This host does not provide workspace file browsing." end
		local folder, why = clean(path, true); if folder == nil then return nil, why end
		local entries, err = fs.list(folder); if err then return nil, err end
		local prefix = folder == "" and "" or folder .. "/"
		local unique = {}
		for _, entry in ipairs(entries) do
			local candidate = clean(entry.path, false)
			if candidate then
				-- Some hosts return child names; others return recursive/full paths.
				if folder ~= "" and not candidate:find("/", 1, true) then candidate = prefix .. candidate end
				if candidate:sub(1, #prefix) == prefix then
					local suffix = candidate:sub(#prefix + 1)
					local name, rest = suffix:match("^([^/]+)(.*)$")
					if name then
						local child = prefix .. name
						local directory = rest ~= "" or entry.isDir or fs.isDir(child)
						local item = unique[child]
						if not item then item = { id = "file:" .. child, path = child, name = name, isDir = directory }; unique[child] = item
						elseif directory then item.isDir = true end
					end
				end
			end
		end
		local items = {}; for _, item in pairs(unique) do items[#items + 1] = item end
		table.sort(items, function(a, b) if a.isDir ~= b.isDir then return a.isDir end; return a.name:lower() < b.name:lower() end)
		return items
	end
	function M.binding(id) return M.bindings[id] end
	function M.dirty(id)
		local binding, doc = M.bindings[id], store.resolve(id)
		return binding ~= nil and doc ~= nil and doc.source ~= binding.base
	end
	function M.open(path)
		local file, why = clean(path); if not file then return nil, why end
		for id, binding in pairs(M.bindings) do
			if binding.path == file and store.resolve(id) then
				store.workspace.sourceId = nil
				local selected, err = store.select(id); if not selected then return nil, err end
				return { documentId = id, path = file }
			end
		end
		local source, err = fs.read(file); if source == nil then return nil, err end
		if source:find("%z") then return nil, "This file contains binary data. Choose a text or source file." end
		local snapshot, problem = sources.keep(source, "File snapshot · " .. fs.root .. "/" .. file, file:match("[^/]+$"), fs.root .. "/" .. file)
		if not snapshot then return nil, problem end
		local result, openWhy = env.require("tools/source_documents").open({ sourceId = snapshot.id, focus = true })
		if not result then return nil, openWhy end
		if result.documentId then M.bindings[result.documentId] = { path = file, base = source } end
		M.view.selected = file; return result
	end
	function M.save(id, path)
		local doc, why = store.resolve(id); if not doc then return nil, why end
		local binding = M.bindings[doc.id]
		local file, err = clean(path or (binding and binding.path)); if not file then return nil, err or "Choose a file name" end
		if fs.isDir(file) then return nil, "Choose a file name, not a folder." end
		local existing, readWhy = fs.read(file)
		if fs.exists(file) and existing == nil then return nil, readWhy end
		if binding and binding.path == file then
			if existing ~= binding.base then return nil, "The file changed on disk. Your draft is kept; reopen a disk copy or save to a different file." end
		elseif existing ~= nil then return nil, "That file already exists. Open it first or choose another name." end
		local source, revision = doc.source, doc.revision
		local saved, saveWhy = fs.write(file, source); if not saved then return nil, saveWhy end
		if fs.read(file) ~= source then return nil, "File verification failed. Your editor draft is still available." end
		M.bindings[doc.id] = { path = file, base = source }
		M.view.selected, M.view.pages = file, {}
		store.changed:fire({ kind = "file_saved", documentId = doc.id, revision = revision })
		return { path = fs.root .. "/" .. file, revision = revision }
	end
	function M.create(path, folder)
		local file, why = clean(path); if not file then return nil, why end
		if fs.exists(file) or fs.isDir(file) then return nil, "That name is already in use." end
		if folder then
			if not fs.ensure(fs.root .. "/" .. file) then return nil, "This host could not create the folder." end
		else
			local saved, err = fs.write(file, ""); if not saved then return nil, err end
			if fs.read(file) ~= "" then return nil, "The new file could not be verified." end
		end
		M.view.pages = {}; return { path = file, isDir = folder == true }
	end
	function M.reveal(path)
		local file = clean(path); if not file then return end
		M.view.expanded[""] = true
		local walk = ""
		local parent = file:match("^(.*)/[^/]+$") or ""
		for part in parent:gmatch("[^/]+") do walk = walk == "" and part or walk .. "/" .. part; M.view.expanded[walk] = true end
		M.view.selected = file
	end
	return M
end
