-- Cowork: the browser-shared conversation.
--
-- The mode switch in the sidebar offers "Cowork" beside "Code", and in the client
-- this is modelled on that means real-time pairing. There is exactly one thing here
-- that genuinely is two people in one conversation -- the local web bridge -- so that
-- is what this panel is: its live state, its switch, and the two values it needs.
--
-- A Roblox client cannot accept a connection, so both sides dial out to a small
-- process on the same machine. That is why this panel is mostly about whether that
-- process is reachable, and why it says so in those words rather than showing a
-- spinner.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local bridge = env.require("net/bridge")
	local sessions = env.require("agent/session")

	local M = {}

	function M.new(parent)
		local panel = {}
		local scroll = P.scroll(parent, {
			name = "Cowork",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.md,
			padding = theme.space.md,
		})

		P.sectionHeader(scroll.instance, {
			title = "Cowork",
			description = "Share this conversation with a browser on the same machine. "
				.. "Run bridge/server.js, paste the token it prints, and whoever opens the page "
				.. "joins the conversation that is already open here -- a turn begun in one place "
				.. "continues in the other, and a permission prompt can be answered from either.",
			layoutOrder = 1,
		})

		M.rows(scroll.instance, { layoutOrder = 2 })

		panel.scroll = scroll
		return panel
	end

	-- The live state and the two values it needs, as cards a caller drops into its own
	-- column. Both the Cowork panel and the settings dialog's Cowork pane use this, so
	-- there is one description of the bridge rather than two that can disagree.
	function M.rows(container, props)
		props = props or {}
		local order = (props.layoutOrder or 1) - 1
		local function nextOrder()
			order = order + 1
			return order
		end

		local statusCard = P.card(container, { layoutOrder = nextOrder(), gap = theme.space.sm })

		local statusRow = P.row(statusCard, {
			name = "Status",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 1,
		})
		local dot = P.statusDot(statusRow, {
			diameter = theme.size.dot,
			color = theme.color.textTertiary,
			layoutOrder = 1,
		})
		local statusText = P.text(statusRow, {
			name = "StatusText",
			text = "",
			role = "small",
			color = theme.color.text,
			wrap = true,
			auto = "Y",
			size = UDim2.new(0, 0, 0, 0),
			flex = "Fill",
			layoutOrder = 2,
		})

		local detail = P.text(statusCard, {
			name = "StatusDetail",
			text = "",
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
		})
		detail.Size = UDim2.new(1, 0, 0, 0)

		-- Everything on this row is a fact about the running bridge rather than a
		-- control, which is why it is text and not a badge: three of the four values are
		-- only interesting when something is wrong.
		local function describe()
			local status = bridge.status()
			local shared = sessions.current()
			if not status.running then
				dot.BackgroundColor3 = theme.color.textTertiary
				statusText.Text = "Off. Nothing is listening and nothing is being polled."
				detail.Text = string.format("%s\nwould share: %s", status.url, shared.title)
				return
			end
			if status.online then
				dot.BackgroundColor3 = theme.color.success
				statusText.Text = "Connected. Open the link the bridge printed in a browser."
				detail.Text = string.format("%s\nsharing: %s\nqueued: %d", status.url, shared.title, status.queued or 0)
				return
			end
			dot.BackgroundColor3 = theme.color.warn
			statusText.Text = "Polling, but nothing answered yet. Is bridge/server.js running?"
			detail.Text = string.format("%s\n%s", status.url, tostring(status.error or "no answer yet"))
		end

		local switchRow = P.row(statusCard, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 3,
		})
		local switchText = P.column(switchRow, {
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			flex = "Fill",
			gap = 0,
			layoutOrder = 1,
		})
		P.text(switchText, { text = "Enabled", role = "small" })
		P.text(switchText, {
			text = "Off until you turn it on: it is a second way in to an agent that can run code.",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		local toggle = C.switch(switchRow, {
			value = config.get("bridge.enabled", false) == true,
			onChange = function(value) config.set("bridge.enabled", value) end,
		})
		toggle.instance.LayoutOrder = 2

		if not caps.has("http") then
			local warning = P.text(statusCard, {
				text = "This host has no HTTP transport, so the bridge cannot be reached from here at all.",
				role = "caption",
				color = theme.color.warn,
				wrap = true,
				auto = "Y",
				layoutOrder = 4,
			})
			warning.Size = UDim2.new(1, 0, 0, 0)
		end

		-- Every row in here states its order.
		--
		-- All six were LayoutOrder 0, so the label above the port field, the field, the
		-- label above the token field, that field, the hint and the button row were sorted
		-- by whatever the tie-break happened to produce -- which is a card whose two
		-- labels can end up over the wrong two fields.
		local settings = P.card(container, { layoutOrder = nextOrder(), gap = theme.space.sm })
		P.text(settings, { text = "Port", role = "small", layoutOrder = 1 })
		P.field(settings, {
			name = "BridgePort",
			text = tostring(config.get("bridge.port", 8790)),
			placeholder = "8790",
			layoutOrder = 2,
			onBlur = function(text)
				local port = tonumber(util.trim(text))
				config.set("bridge.port", (port and port > 0 and port < 65536) and math.floor(port) or 8790)
			end,
		})
		P.text(settings, { text = "Token", role = "small", layoutOrder = 3 })
		P.field(settings, {
			name = "BridgeToken",
			text = tostring(config.get("bridge.token", "")),
			placeholder = "paste from the bridge console",
			layoutOrder = 4,
			onBlur = function(text) config.set("bridge.token", util.trim(text)) end,
		})
		local tokenHint = P.text(settings, {
			text = "The token is regenerated every time bridge/server.js starts, so a stale one left here grants nothing.",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = 5,
		})
		tokenHint.Size = UDim2.new(1, 0, 0, 0)

		local buttons = P.row(settings, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 6,
		})
		if caps.clipboard then
			P.button(buttons, {
				name = "CopyBridgeUrl",
				text = "Copy address",
				variant = "secondary",
				size = "sm",
				layoutOrder = 1,
				onClick = function()
					local ok = pcall(caps.fn.clipboard, bridge.status().url)
					overlay.toast(ok and "Address copied" or "Could not reach the clipboard",
						ok and "good" or "warn", 2)
				end,
			})
		end
		P.button(buttons, {
			name = "Reconnect",
			text = "Reconnect",
			variant = "ghost",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				-- Stop then sync: the poller backs off up to ten seconds between
				-- attempts, and after starting the server on the other side nobody wants
				-- to wait out the backoff.
				bridge.stop()
				local ok, why = bridge.sync()
				if not ok and why then overlay.toast(tostring(why), "warn", 3) end
				describe()
			end,
		})

		describe()
		local unsubscribeBridge = bridge.changed:connect(function()
			if not statusCard.Parent then return end
			describe()
		end)
		local unsubscribeSessions = sessions.listChanged:connect(function()
			if not statusCard.Parent then return end
			describe()
		end)
		statusCard.Destroying:Connect(function()
			pcall(unsubscribeBridge)
			pcall(unsubscribeSessions)
		end)

		return statusCard
	end

	return M
end
