-- Coding tests add native focus and a real DataModel to the shared mock locally.
local base = require("workspace_fixture")
local signals = require("instance")
local M = { suite = base.suite }
function M.new(options)
	local f = base.new(options); local h = f.h
	local nativeNew, focused = h.Instance.new, nil
	local factory = { new = function(class, parent)
		local object = nativeNew(class)
		if class == "TextBox" then
			object.CaptureFocus = function()
				if focused == object then return end
				if focused then focused:ReleaseFocus() end
				focused = object
				object.CursorPosition, object.SelectionStart = #object.Text + 1, -1
				object.Focused:Fire()
			end
			object.ReleaseFocus = function(_, submitted)
				if focused ~= object then return end
				focused = nil
				object.CursorPosition, object.SelectionStart = -1, -1
				object.FocusLost:Fire(submitted == true)
			end
			object.IsFocused = function() return focused == object end
		elseif class == "RemoteEvent" or class == "UnreliableRemoteEvent" then
			object.OnClientEvent = signals.newSignal("OnClientEvent")
		end
		object.Parent = parent
		return object
	end }
	h.Instance, h.sandbox.Instance = factory, factory
	h.services.UserInputService.GetFocusedTextBox = function() return focused end
	local original = h.game
	local game = nativeNew("DataModel"); game.Name = "Game"
	for _, key in ipairs({ "PlaceId", "GameId", "JobId", "CreatorId", "CreatorType", "PlaceVersion", "GetService", "FindService", "IsLoaded", "HttpGet" }) do game[key] = original[key] end
	for _, service in pairs(h.services) do if h.sandbox.typeof(service) == "Instance" then service.Parent = game end end
	game.Workspace, game.Players, game.Lighting = h.workspace, h.services.Players, h.services.Lighting
	h.game, h.sandbox.game = game, game
	return f
end
function M.ui(width, height)
	local f = M.new(); local h = f.h
	h.setViewport(width or 900, height or 650)
	local screen = h.Instance.new("ScreenGui", h.services.CoreGui)
	f.env.root = screen
	f.env.require("ui/overlay").mount(screen)
	f.env.require("runtime/code_store").init()
	f.host = f.env.require("ui/primitives").frame(screen, { size = h.sandbox.UDim2.fromOffset(width or 900, height or 650) })
	return f
end
return M
