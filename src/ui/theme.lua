-- Design tokens.
--
-- Every colour, size, radius, weight and duration in the interface comes from
-- here. No use site writes a literal, which is the only way a project this size
-- stays coherent -- and it is what lets density, accent and text scale change at
-- runtime without hunting through forty files.
--
-- The palette is a neutral with a cool undertone rather than pure black: on an
-- OLED phone pure black next to a 1px hairline reads as a seam, and a slight
-- undertone keeps the surface hierarchy legible at low brightness.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local signal = env.require("runtime/signal")

	local M = { changed = signal.new("theme") }

	local function rgb(r, g, b)
		return Color3.fromRGB(r, g, b)
	end

	-- Roblox has no alpha on Color3, so anything that would be a translucent
	-- overlay is pre-blended against the surface it sits on.
	function M.mix(from, to, alpha)
		return from:Lerp(to, util.clamp(alpha, 0, 1))
	end

	local NEUTRAL = {
		[0] = rgb(9, 10, 13),
		[1] = rgb(13, 15, 19),
		[2] = rgb(18, 20, 26),
		[3] = rgb(23, 26, 33),
		[4] = rgb(29, 33, 42),
		[5] = rgb(36, 41, 51),
		[6] = rgb(48, 54, 66),
		[7] = rgb(64, 71, 85),
		[8] = rgb(96, 104, 120),
		[9] = rgb(138, 146, 162),
		[10] = rgb(186, 192, 205),
		[11] = rgb(226, 230, 238),
	}

	-- Four accents, all landing in the same lightness band so switching one does
	-- not change how loud the interface feels.
	local ACCENTS = {
		aurora = { base = rgb(58, 205, 186), hot = rgb(96, 226, 208), label = "Aurora" },
		indigo = { base = rgb(112, 126, 255), hot = rgb(146, 158, 255), label = "Indigo" },
		amber = { base = rgb(226, 160, 74), hot = rgb(243, 184, 108), label = "Amber" },
		rose = { base = rgb(240, 108, 138), hot = rgb(249, 142, 166), label = "Rose" },
	}

	M.ACCENTS = ACCENTS

	-- Roblox's current UI family. Resolved defensively: on a client old enough not to
	-- have it the enum member is simply absent, and assigning nil to Font would take
	-- the whole interface down, so each weight falls back to its Gotham equivalent.
	-- Gotham is what made this look like a 2016 forum in the first place.
	local function fontOr(name, fallback)
		local ok, item = pcall(function() return Enum.Font[name] end)
		if ok and item then return item end
		return fallback
	end

	local SANS = fontOr("BuilderSans", Enum.Font.Gotham)
	local SANS_MEDIUM = fontOr("BuilderSansMedium", Enum.Font.GothamMedium)
	local SANS_BOLD = fontOr("BuilderSansBold", Enum.Font.GothamBold)

	-- Sizes are a step up from where they were and the line heights are looser. At
	-- 13px on 1.35 a reply arrived as a dense grey slab; body text is the one thing
	-- in here a person actually reads, so it gets the room.
	local BASE_TEXT = {
		display = { size = 22, font = SANS_BOLD, line = 1.2 },
		title = { size = 17, font = SANS_BOLD, line = 1.25 },
		heading = { size = 15, font = SANS_MEDIUM, line = 1.3 },
		body = { size = 14, font = SANS, line = 1.5 },
		bodyStrong = { size = 14, font = SANS_MEDIUM, line = 1.5 },
		small = { size = 13, font = SANS, line = 1.45 },
		label = { size = 12, font = SANS_MEDIUM, line = 1.2 },
		caption = { size = 11, font = SANS, line = 1.3 },
		overline = { size = 11, font = SANS_BOLD, line = 1.2 },
		mono = { size = 13, font = Enum.Font.Code, line = 1.5 },
		monoSmall = { size = 12, font = Enum.Font.Code, line = 1.45 },
	}

	local BASE_SPACE = {
		none = 0, hair = 2, xxs = 4, xs = 6, sm = 8, md = 12, lg = 16, xl = 20, xxl = 28, huge = 40,
	}

	local BASE_SIZE = {
		control = 32,      -- default button / field height
		controlSmall = 26,
		controlLarge = 40,
		icon = 16,
		iconLarge = 20,
		row = 36,
		header = 44,
		rail = 52,
		tab = 32,
		launcher = 46,
		scrollbar = 4,
		avatar = 28,
	}

	M.radius = { none = 0, sm = 4, md = 7, lg = 11, xl = 16, pill = 999 }
	M.stroke = { hair = 1, focus = 2 }

	M.motion = {
		instant = 0,
		fast = 0.12,
		base = 0.18,
		slow = 0.3,
		enter = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		exit = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		hover = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		press = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		slide = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		-- The repeating pair. These are the only tweens here with a negative repeat
		-- count, and they deliberately do not go through M.tween: collapsing the
		-- duration to 0.01s for reduced motion would spin them at a hundred hertz
		-- rather than stop them. Callers check responsive.reduceMotion themselves and
		-- skip the tween entirely.
		spin = TweenInfo.new(0.9, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		pulse = TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true),
	}

	-- A dropdown is always opened from something, so it has to sit above whatever
	-- opened it -- including a modal. It used to rank below one, which is why the
	-- preset menu in the Add provider dialog opened behind the dialog.
	M.z = { base = 1, raised = 10, header = 20, overlay = 100, modal = 160, dropdown = 200, quick = 210, toast = 240 }

	-- Recomputed whenever density, accent or text scale changes.
	function M.rebuild()
		local accentName = config.get("ui.accent", "aurora")
		local accent = ACCENTS[accentName] or ACCENTS.aurora
		local density = config.get("ui.density", "comfortable")
		local compact = density == "compact"
		local textScale = util.clamp(tonumber(config.get("ui.fontScale", 1)) or 1, 0.85, 1.4)
		local spaceScale = compact and 0.78 or 1
		local sizeScale = compact and 0.86 or 1

		M.accentName = accentName
		M.density = density

		M.color = {
			-- Surfaces, darkest to lightest.
			canvas = NEUTRAL[0],
			surface = NEUTRAL[1],
			surfaceRaised = NEUTRAL[2],
			surfaceOverlay = NEUTRAL[3],
			surfaceHover = NEUTRAL[4],
			surfaceActive = NEUTRAL[5],
			scrim = NEUTRAL[0],

			-- Lines.
			-- Outlines sit three to five steps above the surface they are drawn on.
			-- borderSubtle used to be NEUTRAL[3], one step above surfaceRaised, which
			-- is a contrast ratio of about 1.05 to 1 -- every card edge, every
			-- segmented outline and the header rule were all invisible, and the
			-- interface read as untitled blocks of near-black rather than as panels.
			borderSubtle = NEUTRAL[5],
			border = NEUTRAL[6],
			borderStrong = NEUTRAL[7],

			-- Type.
			text = NEUTRAL[11],
			textSecondary = NEUTRAL[9],
			textTertiary = NEUTRAL[8],
			textDisabled = NEUTRAL[7],
			textOnAccent = NEUTRAL[0],

			-- Accent and its quiet variants.
			accent = accent.base,
			accentHot = accent.hot,
			accentMuted = M.mix(NEUTRAL[1], accent.base, 0.45),
			accentSurface = M.mix(NEUTRAL[2], accent.base, 0.16),
			accentBorder = M.mix(NEUTRAL[5], accent.base, 0.55),

			-- Status. Kept in the same lightness band as the accent so a row of
			-- badges reads as one set.
			success = rgb(74, 205, 138),
			successSurface = M.mix(NEUTRAL[2], rgb(74, 205, 138), 0.14),
			warn = rgb(228, 176, 70),
			warnSurface = M.mix(NEUTRAL[2], rgb(228, 176, 70), 0.14),
			danger = rgb(240, 96, 108),
			dangerSurface = M.mix(NEUTRAL[2], rgb(240, 96, 108), 0.14),
			dangerBorder = M.mix(NEUTRAL[5], rgb(240, 96, 108), 0.5),
			info = rgb(96, 158, 240),
			infoSurface = M.mix(NEUTRAL[2], rgb(96, 158, 240), 0.14),

			-- Message surfaces. The user's turn is the lighter one, because it is
			-- the shorter one and the eye should land on it first when scanning back.
			bubbleUser = NEUTRAL[4],
			bubbleUserBorder = NEUTRAL[6],
			bubbleAgent = NEUTRAL[1],
			bubbleTool = NEUTRAL[2],
			codeSurface = NEUTRAL[0],
			codeBorder = NEUTRAL[4],
		}

		M.text = {}
		for role, spec in pairs(BASE_TEXT) do
			local size = math.max(math.floor(spec.size * textScale + 0.5), 8)
			M.text[role] = {
				size = size,
				font = spec.font,
				line = spec.line,
				-- One rendered line, rounded up. A fixed-height label sized from `size`
				-- alone clips its descenders the moment the line height goes past 1.3,
				-- so the height a caller needs is published rather than recomputed.
				height = math.ceil(size * spec.line),
			}
		end

		M.space = {}
		for name, value in pairs(BASE_SPACE) do
			M.space[name] = (value == 0) and 0 or math.max(math.floor(value * spaceScale + 0.5), 1)
		end

		M.size = {}
		for name, value in pairs(BASE_SIZE) do
			M.size[name] = math.max(math.floor(value * sizeScale + 0.5), 8)
		end

		M.changed:fire(M)
		return M
	end

	-- Convenience accessors so a use site reads as prose.
	function M.textRole(role)
		return M.text[role] or M.text.body
	end

	function M.riskColor(risk)
		if risk == "read" then return M.color.textSecondary end
		if risk == "danger" then return M.color.danger end
		return M.color.warn
	end

	function M.toneColor(tone)
		if tone == "good" then return M.color.success end
		if tone == "warn" then return M.color.warn end
		if tone == "bad" then return M.color.danger end
		return M.color.info
	end

	function M.toneSurface(tone)
		if tone == "good" then return M.color.successSurface end
		if tone == "warn" then return M.color.warnSurface end
		if tone == "bad" then return M.color.dangerSurface end
		return M.color.infoSurface
	end

	-- Motion respects the platform preference: GuiService.ReducedMotionEnabled is
	-- a real accessibility setting, and an interface that ignores it is the sort of
	-- thing that makes people close it.
	function M.tween(name)
		local responsive = env.require("ui/responsive")
		if responsive.reduceMotion then
			return TweenInfo.new(0.01, Enum.EasingStyle.Linear)
		end
		return M.motion[name] or M.motion.base
	end

	function M.duration(name)
		local responsive = env.require("ui/responsive")
		if responsive.reduceMotion then return 0.01 end
		return M.motion[name] or M.motion.base
	end

	M.rebuild()

	-- Density, accent and scale live in config, so the theme rebuilds itself when any
	-- of them is written rather than every panel having to remember to.
	--
	-- Only those three, though. A rebuild fires theme.changed, which the app answers
	-- by destroying and reconstructing every panel, the window and the launcher --
	-- so accepting the whole `ui.` namespace meant that maximising the window, moving
	-- the launcher, switching panel or pinning the layout each tore the interface
	-- down and built it again. Anything not in this table cannot change a token, and
	-- so has no business rebuilding anything.
	local TOKEN_KEYS = { ["ui.accent"] = true, ["ui.density"] = true, ["ui.fontScale"] = true }

	config.changed:connect(function(path)
		-- nil is a whole-file load; "ui" is a namespace reset, which startsWith("ui.")
		-- does not match and which used to leave the interface on the old tokens.
		if path == nil or path == "ui" or TOKEN_KEYS[tostring(path)] then
			M.rebuild()
		end
	end)

	return M
end
