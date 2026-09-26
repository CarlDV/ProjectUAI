-- Standalone entry point. The build supplies factories and release metadata.
-- No Project UAI client, network requests, icon downloads, or executor required
-- after this chunk has been loaded. A LocalScript can use the returned API too.
local environment = { metadata = __UI_METADATA }
environment.services = setmetatable({}, {
	__index = function(services, name)
		local service = game:GetService(name)
		rawset(services, name, service)
		return service
	end,
})
local cache, loading = {}, {}
function environment.require(id)
	if cache[id] ~= nil then return cache[id] end
	assert(__UI_MODULES[id], "UI LIB: missing module " .. tostring(id))
	assert(not loading[id], "UI LIB: circular module " .. tostring(id))
	loading[id] = true
	local ok, result = pcall(__UI_MODULES[id], environment)
	loading[id] = nil
	if not ok then error(result, 0) end
	cache[id] = result
	return result
end
local globals = _G
if type(getgenv) == "function" then
	local ok, value = pcall(getgenv)
	if ok and type(value) == "table" then globals = value end
end
local registry = rawget(globals, "__PROJECT_UAI_UI_LIB_V1")
if type(registry) ~= "table" or type(registry.Windows) ~= "table" then
	registry = { Windows = {} }
	rawset(globals, "__PROJECT_UAI_UI_LIB_V1", registry)
end
environment.windows = registry.Windows
environment.globals = globals
return environment.require("library")
