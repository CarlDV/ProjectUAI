-- The window shell: chrome, drag, resize, snap, maximise, and the three layout
-- modes it has to be able to become.
--
-- On a phone it is a bottom sheet that lifts above the on-screen keyboard. On a
-- small viewport it docks to the right edge full height. On a desktop it is a
-- floating window whose geometry is remembered. On a console it is a large centred
-- panel with no drag, because there is no pointer to drag with.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local dispose = env.require("runtime/dispose")
	local P = env.require("ui/primitives")

	local DRAG_SLOP = 6
	local SNAP_MARGIN = 18
	local RESIZE_GRIP = 18

	local M = {}

	function M.new(parent, props)
		props = props or {}
		local minWidth = props.minWidth or 320
		local minHeight = props.minHeight or 280

		local root = Instance.new("CanvasGroup", parent)
		root.Name = props.name or "Window"
		root.BackgroundColor3 = theme.color.canvas
		root.BorderSizePixel = 0
		root.GroupTransparency = 1
		root.Visible = false
		root.Active = true
		root.ZIndex = theme.z.raised
		P.corner(root, theme.radius.xl)
		local outline = P.stroke(root, theme.color.border)

		-- No UIScale on this, deliberately.
		--
		-- A CanvasGroup renders every child into one offscreen texture and then draws
		-- that texture. Drawing it at anything other than 1:1 resamples it -- so a
		-- UIScale of 0.98 on the way in did not make the window 2% smaller, it made
		-- every glyph in the entire interface soft for the length of the animation. And
		-- the scale only returned to 1 when the tween finished: interrupt it by hiding,
		-- rebuilding for a theme change, or opening twice inside a quarter of a second,
		-- and the window stayed at 0.98 for the rest of the session, blurry, with
		-- nothing on screen to explain why. A 2% zoom nobody can see is not worth that;
		-- the fade below is what a CanvasGroup is actually good at, because it
		-- composites the whole group at one alpha for free.

		local handle = {
			root = root,
			visible = false,
			maximised = config.get("ui.window.maximised", false) == true,
		}

		-- Everything this window leaves running outside its own instance tree, released
		-- together by handle.destroy.
		--
		-- A rebuild destroys the window and builds another, and the app now rebuilds for a
		-- sidebar toggle as well as for a mode or token change. Each of the three
		-- subscriptions below used to outlive its window: two InputChanged handlers
		-- registered with the global disposer and never unregistered, and a
		-- responsive.changed handler whose unsubscribe was discarded outright -- so after
		-- five rebuilds five dead handlers were still laying out five destroyed windows on
		-- every viewport change.
		local releases = {}

		-- Geometry ------------------------------------------------------------

		local function saveGeometry()
			if responsive.mode ~= "window" then return end
			config.set("ui.window.width", math.floor(root.AbsoluteSize.X), { quiet = true })
			config.set("ui.window.height", math.floor(root.AbsoluteSize.Y), { quiet = true })
			config.set("ui.window.x", math.floor(root.Position.X.Offset), { quiet = true })
			config.set("ui.window.y", math.floor(root.Position.Y.Offset), { quiet = true })
			config.set("ui.window.placed", true, { quiet = true })
		end

		local persistGeometry = clock.debounce(saveGeometry, 0.6)

		-- A size that leaves the window on whole pixels when it is centred.
		--
		-- The same texture problem as the scale, from the other direction: this window is
		-- centred with a 0.5 anchor, so its left edge lands at (available - width) / 2 --
		-- a half pixel whenever that difference is odd. Roblox then draws the group's
		-- texture at a half-pixel offset and resamples it, and the whole interface goes
		-- soft. Nothing about the window changed to cause it, which is what makes it
		-- baffling from the outside: one pixel of viewport, one drag of the resize grip
		-- or a restored size with the wrong parity is enough, and it stays that way.
		--
		-- So a centred dimension is nudged by one pixel to keep the space around it even.
		-- Nobody can see the pixel; everybody can see the blur.
		local function centred(available, wanted, floor)
			local value = math.floor(wanted)
			if (math.floor(available) - value) % 2 ~= 0 then
				if value - 1 >= (floor or 1) then value = value - 1 else value = value + 1 end
			end
			return value
		end
		handle.centred = centred

		-- Applies the layout for the current mode. Called on open, on a mode change,
		-- and when the on-screen keyboard appears.
		function handle.layout(reason)
			local geometry = responsive.geometry()
			local mode = responsive.mode
			local viewport = responsive.viewport
			local topInset = responsive.inset.Y
			local keyboard = responsive.bottomObstruction()
			-- The ScreenGui does not ignore the top inset, so the height the window is
			-- centred inside is the viewport minus it.
			local availableY = viewport.Y - topInset

			if mode == "sheet" then
				local available = viewport.Y - topInset - keyboard - theme.space.sm
				local height = math.min(geometry.height, math.max(available, 220))
				root.AnchorPoint = Vector2.new(0.5, 1)
				-- Width is the full measure less a fixed inset on both sides, so the space
				-- around it is that inset doubled -- even by construction.
				root.Size = UDim2.new(1, -theme.space.sm * 2, 0, math.floor(height))
				root.Position = UDim2.new(0.5, 0, 1, -(keyboard + theme.space.sm))
			elseif mode == "panel" then
				root.AnchorPoint = Vector2.new(1, 0)
				root.Size = UDim2.new(0, math.floor(geometry.width),
					0, math.floor(math.max(geometry.height - keyboard, 240)))
				root.Position = UDim2.new(1, -theme.space.sm, 0, topInset + theme.space.sm)
			elseif mode == "tv" then
				root.AnchorPoint = Vector2.new(0.5, 0.5)
				root.Size = UDim2.fromOffset(
					centred(viewport.X, geometry.width, minWidth),
					centred(availableY, geometry.height, minHeight))
				root.Position = UDim2.fromScale(0.5, 0.5)
			elseif handle.maximised then
				root.AnchorPoint = Vector2.new(0.5, 0)
				root.Size = UDim2.new(1, -theme.space.md * 2, 1, -(topInset + theme.space.md * 2 + keyboard))
				root.Position = UDim2.new(0.5, 0, 0, topInset + theme.space.md)
			else
				local width = util.clamp(config.get("ui.window.width", 0), 0, viewport.X - theme.space.md * 2)
				local height = util.clamp(config.get("ui.window.height", 0), 0, viewport.Y - theme.space.md * 2)
				if width < minWidth then width = geometry.width end
				if height < minHeight then height = geometry.height end
				root.AnchorPoint = Vector2.new(0.5, 0.5)
				root.Size = UDim2.fromOffset(
					centred(viewport.X, width, minWidth),
					centred(availableY, height, minHeight))
				if config.get("ui.window.placed", false) then
					root.Position = UDim2.new(0.5, config.get("ui.window.x", 0), 0.5, config.get("ui.window.y", 0))
					handle.clampIntoView()
				else
					root.Position = UDim2.fromScale(0.5, 0.5)
				end
			end

			if handle.onLayout then pcall(handle.onLayout, mode, reason) end
		end

		-- Keeps at least a corner of the window reachable after a viewport change,
		-- so a window dragged to the edge of a large screen does not become
		-- unreachable on a small one.
		function handle.clampIntoView()
			if responsive.mode ~= "window" then return end
			local viewport = responsive.viewport
			local size = root.AbsoluteSize
			local keep = math.min(56, size.X, size.Y)
			local halfX = size.X * 0.5
			local halfY = size.Y * 0.5
			local maxX = viewport.X * 0.5 - keep + halfX
			local minX = -(viewport.X * 0.5) + keep - halfX
			local maxY = viewport.Y * 0.5 - keep + halfY
			local minY = -(viewport.Y * 0.5) + halfY
			root.Position = UDim2.new(
				0.5, math.floor(util.clamp(root.Position.X.Offset, math.min(minX, maxX), math.max(minX, maxX))),
				0.5, math.floor(util.clamp(root.Position.Y.Offset, math.min(minY, maxY), math.max(minY, maxY))))
		end

		-- Chrome --------------------------------------------------------------

		-- Tall enough for the controls it holds. The window buttons are sized to
		-- max(control, minTarget()), which is 44 on a touch device, so a header fixed at
		-- the 42px token clipped two pixels off every one of them there. Published so
		-- the shell that fills the header uses the same number instead of the token.
		local headerHeight = math.max(theme.size.header, responsive.minTarget() + theme.space.sm)
		handle.headerHeight = headerHeight

		-- The header is a transparent top bar across the active pane that provides
		-- the drag handle and holds window controls.
		handle.header = P.row(root, {
			name = "Header",
			size = UDim2.new(1, 0, 0, headerHeight),
			gap = theme.space.sm,
			padding = { x = theme.space.sm },
			zIndex = theme.z.header,
		})
		handle.header.BackgroundTransparency = 1

		handle.body = P.frame(root, {
			name = "Body",
			size = UDim2.fromScale(1, 1),
			position = UDim2.new(0, 0, 0, 0),
		})

		-- Drag ----------------------------------------------------------------

		-- Bound to the header only. Making the whole surface a drag handle -- which
		-- Frame.Draggable did -- means the transcript cannot be dragged to scroll and
		-- text cannot be swiped to select, because both gestures move the window.
		local dragging, moved, origin, startPosition = false, false, nil, nil

		local function draggableNow()
			return responsive.mode == "window" and not handle.maximised
		end

		handle.header.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not draggableNow() then return end
			dragging, moved = true, false
			origin = input.Position
			startPosition = root.Position
			local connection
			connection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if connection then connection:Disconnect() end
					if moved then
						handle.snap()
						persistGeometry()
					end
				end
			end)
		end)

		releases[#releases + 1] = dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not dragging or not startPosition then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			local delta = input.Position - origin
			if math.abs(delta.X) > DRAG_SLOP or math.abs(delta.Y) > DRAG_SLOP then moved = true end
			root.Position = UDim2.new(
				startPosition.X.Scale, math.floor(startPosition.X.Offset + delta.X),
				startPosition.Y.Scale, math.floor(startPosition.Y.Offset + delta.Y))
			handle.clampIntoView()
		end))

		-- Snapping to an edge is what makes a floating window feel placed rather than
		-- dropped. Only the near edge snaps, and only within a small margin.
		function handle.snap()
			if not draggableNow() then return end
			local viewport = responsive.viewport
			local size = root.AbsoluteSize
			local x, y = root.Position.X.Offset, root.Position.Y.Offset
			local halfViewportX, halfViewportY = viewport.X * 0.5, viewport.Y * 0.5
			local leftGap = (x - size.X * 0.5) + halfViewportX
			local rightGap = halfViewportX - (x + size.X * 0.5)
			local topGap = (y - size.Y * 0.5) + halfViewportY - responsive.inset.Y
			local bottomGap = halfViewportY - (y + size.Y * 0.5)

			if leftGap < SNAP_MARGIN then x = x - leftGap + theme.space.sm end
			if rightGap < SNAP_MARGIN then x = x + rightGap - theme.space.sm end
			if topGap < SNAP_MARGIN then y = y - topGap + theme.space.sm end
			if bottomGap < SNAP_MARGIN then y = y + bottomGap - theme.space.sm end

			env.tween:Create(root, theme.tween("hover"), {
				Position = UDim2.new(0.5, math.floor(x), 0.5, math.floor(y)),
			}):Play()
		end

		-- Resize --------------------------------------------------------------

		local grip = Instance.new("TextButton", root)
		grip.Name = "ResizeGrip"
		grip.Text = ""
		grip.AutoButtonColor = false
		grip.BackgroundTransparency = 1
		grip.AnchorPoint = Vector2.new(1, 1)
		grip.Position = UDim2.fromScale(1, 1)
		grip.Size = UDim2.fromOffset(RESIZE_GRIP, RESIZE_GRIP)
		grip.ZIndex = theme.z.header + 2
		grip.Selectable = false
		for index = 1, 2 do
			local line = P.frame(grip, {
				name = "Grip" .. index,
				size = UDim2.fromOffset(index * 5 + 1, 1),
				anchor = Vector2.new(1, 1),
				position = UDim2.new(1, -4, 1, -(index * 4)),
				bg = theme.color.borderStrong,
				radius = theme.radius.pill,
			})
			line.Rotation = -45
		end

		local resizing, resizeOrigin, startSize = false, nil, nil

		grip.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not draggableNow() then return end
			resizing = true
			resizeOrigin = input.Position
			startSize = root.AbsoluteSize
			local connection
			connection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
					if connection then connection:Disconnect() end
					persistGeometry()
					if handle.onLayout then pcall(handle.onLayout, responsive.mode, "resize") end
				end
			end)
		end)

		releases[#releases + 1] = dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not resizing or not startSize then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			local delta = input.Position - resizeOrigin
			local viewport = responsive.viewport
			-- Through `centred` for the same reason the layout is: the window is centred
			-- while it is being resized, so a width one pixel out of parity puts the
			-- group's texture on a half pixel and softens every glyph in it. Dragging the
			-- grip was the easiest way to land there.
			root.Size = UDim2.fromOffset(
				centred(viewport.X,
					util.clamp(startSize.X + delta.X * 2, minWidth, viewport.X - theme.space.md * 2), minWidth),
				centred(viewport.Y - responsive.inset.Y,
					util.clamp(startSize.Y + delta.Y * 2, minHeight, viewport.Y - theme.space.md * 2), minHeight))
		end))

		function handle.setMaximised(value)
			handle.maximised = value == true
			-- Quiet, like every other geometry write here: this is a record of where
			-- the window is, not a setting anything else derives from, and a noisy
			-- write used to reach the theme's config subscription and rebuild the
			-- entire interface a fifth of a second after the maximise animation.
			config.set("ui.window.maximised", handle.maximised, { quiet = true })
			grip.Visible = draggableNow()
			handle.layout("maximise")
		end

		function handle.toggleMaximised()
			handle.setMaximised(not handle.maximised)
		end

		-- Visibility ----------------------------------------------------------

		function handle.show()
			if handle.visible then return end
			handle.visible = true
			handle.layout("show")
			root.Visible = true
			-- Snapped to the goal on completion. An interrupted fade on a CanvasGroup
			-- leaves the whole window part-transparent, and the group is the only thing
			-- between the interface and the game behind it.
			local fade = env.tween:Create(root, theme.tween("enter"), { GroupTransparency = 0 })
			fade.Completed:Connect(function()
				if handle.visible then root.GroupTransparency = 0 end
			end)
			fade:Play()
			if handle.onShow then pcall(handle.onShow) end
		end

		function handle.hide()
			if not handle.visible then return end
			handle.visible = false
			local fade = env.tween:Create(root, theme.tween("exit"), { GroupTransparency = 1 })
			fade.Completed:Connect(function()
				if not handle.visible then root.Visible = false end
			end)
			fade:Play()
			if handle.onHide then pcall(handle.onHide) end
		end

		function handle.toggle()
			if handle.visible then handle.hide() else handle.show() end
		end

		-- Everything this window leaves running outside its own tree, released together.
		function handle.destroy()
			for _, release in ipairs(releases) do pcall(release) end
			releases = {}
			handle.visible = false
			pcall(function() root:Destroy() end)
		end

		-- Re-layout on every viewport change. Continuous changes only move and
		-- resize; a mode change is what asks the contents to rebuild, and that is
		-- signalled separately by responsive.modeChanged.
		releases[#releases + 1] = responsive.changed:connect(function(info)
			if not handle.visible then return end
			grip.Visible = draggableNow()
			handle.layout(info and info.reason or "viewport")
		end)

		grip.Visible = draggableNow()
		handle.outline = outline
		return handle
	end

	return M
end
