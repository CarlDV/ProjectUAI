-- The Claude Code client identity.
--
-- Requests are sent with the header set the Claude Code CLI presents: the
-- claude-cli User-Agent plus the Stainless client-metadata headers that every
-- Anthropic SDK build attaches. Gateways that gate on the CLI accept it; gateways
-- that do not simply ignore unknown X- headers.
--
-- It lives in its own module for one reason: net/http applies it centrally, so no
-- call site can forget to, and the version is one edit in one place when the
-- upstream CLI moves on.
return function(env)
	local util = env.require("runtime/util")

	local M = {}

	M.DEFAULT_VERSION = "2.0.14"
	M.SDK_VERSION = "0.68.0"
	M.NODE_VERSION = "v22.14.0"

	-- Roblox knows the platform; the identity should be plausible rather than
	-- always claiming Windows, because a mismatched OS is the sort of detail a
	-- gateway can reasonably log.
	local OS_BY_PLATFORM = {
		Windows = "Windows",
		OSX = "MacOS",
		IOS = "MacOS",
		Android = "Linux",
		Linux = "Linux",
		XBoxOne = "Windows",
		PS4 = "Linux",
		UWP = "Windows",
	}

	local ARCH_BY_PLATFORM = {
		IOS = "arm64",
		Android = "arm64",
		OSX = "arm64",
	}

	local platformName = "Windows"
	do
		local ok, platform = pcall(function()
			return env.uis:GetPlatform()
		end)
		if ok and type(platform) == "table" and type(platform.Name) == "string" then
			platformName = platform.Name
		end
	end

	M.platform = platformName
	M.osName = OS_BY_PLATFORM[platformName] or "Linux"
	M.arch = ARCH_BY_PLATFORM[platformName] or "x64"

	function M.version()
		local config = env.require("runtime/config")
		local value = config.get("identity.version", M.DEFAULT_VERSION)
		if type(value) ~= "string" or value == "" then return M.DEFAULT_VERSION end
		return value
	end

	function M.userAgent()
		return "claude-cli/" .. M.version() .. " (external, cli)"
	end

	-- `attempt` is one-based; Stainless reports the number of retries already
	-- spent, so the first attempt sends 0.
	function M.headers(opts)
		opts = opts or {}
		local headers = {
			["User-Agent"] = M.userAgent(),
			["x-app"] = "cli",
			["X-Stainless-Lang"] = "js",
			["X-Stainless-Package-Version"] = M.SDK_VERSION,
			["X-Stainless-OS"] = M.osName,
			["X-Stainless-Arch"] = M.arch,
			["X-Stainless-Runtime"] = "node",
			["X-Stainless-Runtime-Version"] = M.NODE_VERSION,
			["X-Stainless-Retry-Count"] = tostring(math.max((opts.attempt or 1) - 1, 0)),
		}
		if opts.timeout then
			headers["X-Stainless-Timeout"] = tostring(math.floor(opts.timeout))
		end
		local config = env.require("runtime/config")
		for key, value in pairs(config.get("identity.extraHeaders", {}) or {}) do
			if type(key) == "string" and type(value) == "string" and value ~= "" then
				headers[key] = value
			end
		end
		return headers
	end

	function M.enabled()
		local config = env.require("runtime/config")
		return config.get("identity.claudeUa", true) ~= false
	end

	-- Shown in Settings so the user can see exactly what is being sent, and in the
	-- capability badge when the transport cannot send it at all.
	function M.describe()
		local caps = env.require("runtime/caps")
		local lines = { M.userAgent() }
		for _, key in ipairs(util.keys(M.headers({ attempt = 1 }), true)) do
			if key ~= "User-Agent" then
				lines[#lines + 1] = key .. ": " .. M.headers({ attempt = 1 })[key]
			end
		end
		if not caps.uaSupported then
			table.insert(lines, 1, "[not sent: " .. caps.reason("ua") .. "]")
		end
		return table.concat(lines, "\n")
	end

	return M
end
