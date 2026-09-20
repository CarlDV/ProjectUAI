-- The identity shared by the sidebar profile control and its menu.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local providers = env.require("provider/registry")
	local M = {}

	function M.identity()
		local username, display, userId = "", "", 0
		if env.plr then
			pcall(function() username = util.trim(tostring(env.plr.Name or "")) end)
			pcall(function() display = util.trim(tostring(env.plr.DisplayName or "")) end)
			pcall(function() userId = tonumber(env.plr.UserId) or 0 end)
		end
		local name = display ~= "" and display or (username ~= "" and username or "you")
		-- Preserve the first UTF-8 character, including non-Latin display names.
		local initial = name:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
		local image
		if userId > 0 and userId < math.huge and userId == math.floor(userId) then
			image = string.format("rbxthumb://type=AvatarHeadShot&id=%.0f&w=150&h=150", userId)
		end
		return { name = name, username = username, initial = initial:upper(), image = image, userId = image and userId or nil }
	end

	function M.providerLabel()
		local record = providers.active()
		local label = record and util.trim(tostring(record.label or "")) or ""
		return label ~= "" and label or "No provider selected"
	end

	function M.avatar(parent, identity, diameter, order)
		local avatar = P.frame(parent, {
			name = "ProfileAvatar",
			size = UDim2.fromOffset(diameter, diameter),
			bg = theme.color.accentSurface,
			radius = diameter / 2,
			layoutOrder = order,
		})
		P.stroke(avatar, theme.color.accentBorder)
		local fallback = P.text(avatar, {
			name = "AvatarInitial",
			text = identity.initial,
			role = "title",
			color = theme.color.text,
			size = UDim2.fromScale(1, 1),
			align = "Center",
		})
		if identity.image then
			local photo = Instance.new("ImageLabel", avatar)
			photo.Name = "AvatarImage"
			photo.BackgroundTransparency = 1
			photo.BorderSizePixel = 0
			photo.Size = UDim2.fromScale(1, 1)
			photo.ScaleType = Enum.ScaleType.Fit
			-- Let the image render as soon as it arrives. Keeping it fully transparent
			-- until IsLoaded changes can leave loading dependent on an invisible image.
			photo.ImageTransparency = 0
			P.corner(photo, diameter / 2)
			local alive = true
			local function syncImage()
				if alive then fallback.Visible = photo.IsLoaded ~= true end
			end
			avatar.Destroying:Connect(function()
				alive = false
			end)
			photo:GetPropertyChangedSignal("IsLoaded"):Connect(syncImage)
			photo.Image = identity.image
			syncImage()
			-- Resolve a ready headshot and explicitly request its pixels. Both calls
			-- can yield, so the UI is built first; failures retain the initial and retry
			-- a bounded number of times. A destroyed view discards late results. Never
			-- task.cancel a thumbnail/preload waiter: Roblox still owns its resumption.
			task.defer(function()
				for attempt = 1, 3 do
					if attempt > 1 then task.wait(attempt - 1) end
					if not alive or photo.IsLoaded then return end
					if identity.userId then
						local ok, url, ready = pcall(function()
							return env.services.Players:GetUserThumbnailAsync(identity.userId,
								Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
						end)
						if not alive then return end
						if ok and ready == true and type(url) == "string" and url ~= "" then photo.Image = url end
					end
					pcall(function() env.services.ContentProvider:PreloadAsync({ photo }) end)
					if not alive then return end
					syncImage()
					if photo.IsLoaded then return end
				end
			end)
		end
		return avatar
	end

	function M.menuHeader()
		local identity = M.identity()
		local identityHeight = math.max(theme.size.profileAvatarLarge,
			theme.text.title.height + theme.text.caption.height + theme.space.hair)
		local providerHeight = theme.text.caption.height + theme.space.xs * 2
		local height = identityHeight + providerHeight + theme.space.sm * 3
		return {
			isHeader = true,
			title = identity.name,
			height = height,
			render = function(parent)
				local header = P.column(parent, {
					name = "ProfileMenuHeader",
					size = UDim2.fromScale(1, 1),
					padding = theme.space.sm,
					gap = theme.space.sm,
				})
				local row = P.row(header, {
					size = UDim2.new(1, 0, 0, identityHeight),
					gap = theme.space.md,
					layoutOrder = 1,
				})
				M.avatar(row, identity, theme.size.profileAvatarLarge, 1)
				local text = P.column(row, {
					name = "ProfileIdentity",
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					gap = theme.space.hair,
					alignY = "Center",
					layoutOrder = 2,
				})
				P.text(text, {
					name = "ProfileName",
					text = identity.name,
					role = "title",
					size = UDim2.new(1, 0, 0, theme.text.title.height),
					truncate = true,
					layoutOrder = 1,
				})
				P.text(text, {
					name = "ProfileUsername",
					text = identity.username ~= "" and ("@" .. identity.username) or "Your profile",
					role = "caption",
					color = theme.color.textTertiary,
					size = UDim2.new(1, 0, 0, theme.text.caption.height),
					truncate = true,
					layoutOrder = 2,
				})
				local provider = P.row(header, {
					name = "ProfileProviderCard",
					size = UDim2.new(1, 0, 0, providerHeight),
					bg = theme.color.surface,
					radius = theme.radius.sm,
					padding = { x = theme.space.sm },
					gap = theme.space.sm,
					layoutOrder = 2,
				})
				P.text(provider, {
					text = "Provider",
					role = "overline",
					color = theme.color.textTertiary,
					auto = "X",
					layoutOrder = 1,
				})
				local label = P.text(provider, {
					name = "ProfileProvider",
					text = M.providerLabel(),
					role = "caption",
					color = theme.color.textSecondary,
					size = UDim2.new(0, 0, 0, theme.text.caption.height),
					flex = "Fill",
					truncate = true,
					layoutOrder = 2,
				})
				local release = providers.changed:connect(function()
					label.Text = M.providerLabel()
				end)
				header.Destroying:Connect(release)
			end,
		}
	end

	return M
end
