-- The What's New modal: release notes as cards with category badges.
--
-- Reads runtime/changelog, one card per version, newest first. The whole list
-- sits in a scrolling modal body, so any amount of history fits any viewport
-- -- overlay.modal does the clamping (bounded height, sheet mode on a phone)
-- and this module only has to not fight it.
--
-- Responsiveness here is about the card header, which is the one row with
-- three competing elements: a version pill, a title, and a date. On a wide
-- viewport they share the line; on a narrow one the pill and date shrink to
-- caption size and the title wraps beneath them rather than truncating --
-- a release title is the thing the reader is here for.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")
	local changelog = env.require("runtime/changelog")

	local M = {}

	-- Category -> tone. The theme's tone system already owns the palette, so
	-- the badges match every other coloured chip in the client for free.
	local CATEGORY_TONE = {
		added = "good",
		improved = "accent",
		fixed = "warn",
	}

	function M.show()
		local modal = overlay.modal({
			title = "What's new",
			description = "Every release this client has shipped, newest first.",
			width = theme.size.modalWide,
			height = 580,
			scroll = true,
		})
		if not modal then return nil end

		-- Opening the list is what marks it read; the marker on the menu row
		-- exists so a returning user knows to do exactly this.
		changelog.markRead()

		local releases = changelog.all()

		for index, release in ipairs(releases) do
			local card = P.column(modal.content, {
				name = "Release_" .. release.version,
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				bg = theme.color.canvas,
				radius = theme.radius.lg,
				padding = { x = theme.space.lg, y = theme.space.lg },
				gap = theme.space.md,
				layoutOrder = index,
			})
			P.stroke(card, theme.color.borderSubtle)

			-- The header: top metadata row with version pill, optional latest badge,
			-- spacer, and release date cleanly right-aligned.
			local header = P.row(card, {
				name = "Head",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				alignY = "Center",
				layoutOrder = 1,
			})
			local pill = P.frame(header, {
				name = "VersionPill",
				size = UDim2.new(0, 0, 0, 0),
				auto = "XY",
				bg = theme.color.accentSurface,
				radius = theme.radius.pill,
				padding = { x = theme.space.sm, y = theme.space.hair },
				layoutOrder = 1,
			})
			P.stroke(pill, theme.color.accentBorder)
			P.text(pill, {
				text = "v" .. release.version,
				role = "label",
				color = theme.color.accent,
			})

			if index == 1 then
				local latestBadge = P.frame(header, {
					name = "LatestBadge",
					size = UDim2.new(0, 0, 0, 0),
					auto = "XY",
					bg = theme.toneSurface("good"),
					radius = theme.radius.pill,
					padding = { x = theme.space.xs, y = theme.space.hair },
					layoutOrder = 2,
				})
				P.stroke(latestBadge, theme.toneColor("good"))
				P.text(latestBadge, {
					text = "LATEST",
					role = "overline",
					color = theme.toneColor("good"),
				})
			end

			P.spacer(header, { grow = true, layoutOrder = 3 })

			P.text(header, {
				text = release.date,
				role = "caption",
				color = theme.color.textTertiary,
				auto = "XY",
				layoutOrder = 4,
			})

			-- Release title: dedicated line across the full card width
			P.text(card, {
				name = "Title",
				text = release.title,
				role = "title",
				color = theme.color.text,
				wrap = true,
				auto = "Y",
				size = UDim2.new(1, 0, 0, 0),
				layoutOrder = 2,
			})

			-- Highlights callout box
			if release.highlights and release.highlights ~= "" then
				local callout = P.frame(card, {
					name = "Highlights",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					bg = theme.color.surface,
					radius = theme.radius.md,
					padding = { x = theme.space.md, y = theme.space.sm },
					layoutOrder = 3,
				})
				P.stroke(callout, theme.color.borderSubtle)
				P.text(callout, {
					text = release.highlights,
					role = "small",
					line = theme.line.reading,
					color = theme.color.textSecondary,
					wrap = true,
					auto = "Y",
					size = UDim2.new(1, 0, 0, 0),
				})
			end

			for sectionIndex, section in ipairs(release.sections or {}) do
				local tone = CATEGORY_TONE[section.category] or "neutral"
				local badgeColor = theme.toneColor(tone)

				-- Category title: pure colored text without pill background or outline
				P.text(card, {
					name = "Section_" .. section.category,
					text = section.label or section.category,
					role = "heading",
					color = badgeColor,
					auto = "Y",
					size = UDim2.new(1, 0, 0, 0),
					layoutOrder = 10 + sectionIndex * 2,
				})

				local list = P.column(card, {
					name = "Items_" .. section.category,
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					padding = { left = theme.space.xs },
					layoutOrder = 10 + sectionIndex * 2 + 1,
				})

				local smallRole = theme.textRole("small")
				local markerWidth = 10
				for _, item in ipairs(section.items or {}) do
					local itemRow = P.row(list, {
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.xs,
						alignY = "Top",
					})
					P.text(itemRow, {
						name = "Marker",
						text = "\194\183",
						role = "small",
						line = smallRole.line,
						color = badgeColor,
						align = "Right",
						alignY = "Top",
						size = UDim2.new(0, markerWidth, 0, smallRole.height),
						layoutOrder = 1,
					})
					P.text(itemRow, {
						text = item,
						role = "small",
						line = smallRole.line,
						color = theme.color.textSecondary,
						wrap = true,
						auto = "Y",
						alignY = "Top",
						size = UDim2.new(1, -(markerWidth + theme.space.xs), 0, 0),
						layoutOrder = 2,
					})
				end
			end
		end

		P.button(modal.footer, {
			text = "Close",
			variant = "secondary",
			size = "sm",
			onClick = function() modal.close() end,
		})
		return modal
	end

	-- The menu row's label, with the unread marker when the running version
	-- has notes the user has not opened. Kept here so the menu and the modal
	-- cannot drift apart on what "new" means.
	function M.menuLabel()
		if changelog.isUnread() then
			return "What's new \226\128\162"
		end
		return "What's new"
	end

	return M
end
