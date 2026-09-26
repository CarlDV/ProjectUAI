return function(env)
	local C = env.require("core")
	local M = {}
	function M.ExportConfig(self)
		assert(self.Alive, "Window is destroyed")
		local values = {}
		for id, control in pairs(self.Controls) do
			if control._normalize and control.Persist ~= false then
				local value
				if control._encode then value = control._encode() else value = control:Get() end
				values[id] = { kind = control.Kind, value = value }
			end
		end
		return env.services.HttpService:JSONEncode({ format = "project-uai-ui", version = 1, window = self.Id, values = values })
	end
	function M.ImportConfig(self, source, options)
		options = options or {}
		if not self.Alive then return false, "Window is destroyed" end
		if type(source) ~= "string" or #source > 262144 then return false, "Configuration must be JSON under 256 KiB" end
		local ok, document = pcall(function() return env.services.HttpService:JSONDecode(source) end)
		if not ok or type(document) ~= "table" or document.format ~= "project-uai-ui" or document.version ~= 1 or type(document.values) ~= "table" then
			return false, "Unsupported or invalid UI configuration"
		end
		if document.window ~= self.Id then return false, "Configuration belongs to a different window Id" end
		local pending = {}
		for id, record in pairs(document.values) do
			local control = self.Controls[id]
			if control and control._normalize and control.Persist ~= false then
				if type(record) ~= "table" or record.kind ~= control.Kind then return false, "Control type changed: " .. tostring(id) end
				local valid, normalized = pcall(control._decode or control._normalize, record.value)
				if not valid then return false, "Invalid value for " .. tostring(id) .. ": " .. tostring(normalized) end
				pending[#pending + 1] = { control = control, value = normalized, changed = not C.equal(control._value, normalized) }
			end
		end
		table.sort(pending, function(a, b) return a.control.Id < b.control.Id end)
		-- All values validate before the first write. Callbacks see the complete
		-- restored configuration and are opt-in, so loading cannot start actions.
		local releases = {}
		for _, item in ipairs(pending) do
			if item.control._restore then
				local release = item.control._restore(item.value)
				if release then releases[#releases + 1] = release end
			else item.control:Set(item.value, true) end
		end
		-- End active key actions only after every value is restored. Cleanup
		-- callbacks may destroy controls without interrupting the transaction.
		for _, release in ipairs(releases) do release() end
		if options.Silent == false then
			for _, item in ipairs(pending) do if item.changed and item.control.Alive then item.control:_Emit() end end
		end
		return true, #pending
	end
	local function pathFor(self, name)
		assert(type(name) == "string" and #name > 0 and #name <= 48 and name:match("^[%w_-]+$"), "Profile name must be 1-48 letters, digits, underscores, or hyphens")
		local hash = 5381
		for index = 1, #self.Id do hash = (hash * 33 + self.Id:byte(index)) % 4294967296 end
		local folder = "ProjectUAI/UI/" .. self.Id:gsub("[^%w_-]", "_"):sub(1, 32) .. "-" .. string.format("%08x", hash)
		return folder .. "/" .. name .. ".json", folder
	end
	function M.SaveConfig(self, name)
		local write = env.globals.writefile or writefile
		local make = env.globals.makefolder or makefolder
		local exists = env.globals.isfolder or isfolder
		local read = env.globals.readfile or readfile
		if type(write) ~= "function" or type(make) ~= "function" then return false, "This host does not provide writefile and makefolder; use ExportConfig" end
		local ok, result = pcall(function()
			local path, folder = pathFor(self, name)
			for _, directory in ipairs({ "ProjectUAI", "ProjectUAI/UI", folder }) do
				if type(exists) ~= "function" or not exists(directory) then
					local made, why = pcall(make, directory)
					if not made and type(exists) == "function" and not exists(directory) then error(why, 0) end
				end
			end
			local json = self:ExportConfig()
			write(path, json)
			if type(read) == "function" then assert(read(path) == json, "Configuration read-back did not match") end
			return path
		end)
		return ok, result
	end
	function M.LoadConfig(self, name, options)
		local read = env.globals.readfile or readfile
		if type(read) ~= "function" then return false, "This host does not provide readfile; use ImportConfig" end
		local ok, result = pcall(function()
			local path = pathFor(self, name)
			return read(path)
		end)
		if not ok then return false, tostring(result) end
		return self:ImportConfig(result, options)
	end
	return M
end
