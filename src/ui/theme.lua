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

	local BASE_TEXT = {
		display = { size = 20, font = Enum.Font.GothamBold, line = 1.15 },
		title = { size = 16, font = Enum.Font.GothamBold, line = 1.2 },
		heading = { size = 14, font = Enum.Font.GothamMedium, line = 1.25 },
		body = { size = 13, font = Enum.Font.Gotham, line = 1.35 },
		bodyStrong = { size = 13, font = Enum.Font.GothamMedium, line = 1.35 },
		small = { size = 12, font = Enum.Font.Gotham, line = 1.35 },
		label = { size = 11, font = Enum.Font.GothamMedium, line = 1.2 },
		caption = { size = 10, font = Enum.Font.Gotham, line = 1.3 },
		overline = { size = 10, font = Enum.Font.GothamBold, line = 1.2 },
		mono = { size = 12, font = Enum.Font.Code, line = 1.4 },
		monoSmall = { size = 11, font = Enum.Font.Code, line = 1.4 },
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
	}

	M.z = { base = 1, raised = 10, header = 20, dropdown = 60, overlay = 100, toast = 140, modal = 160 }

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
			borderSubtle = NEUTRAL[3],
			border = NEUTRAL[5],
			borderStrong = NEUTRAL[6],

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
			M.text[role] = {
				size = math.max(math.floor(spec.size * textScale + 0.5), 8),
				font = spec.font,
				line = spec.line,
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

	-- Density, accent and scale live in config, so the theme rebuilds itself when
	-- any of them is written rather than every panel having to remember to.
	config.changed:connect(function(path)
		if path == nil or util.startsWith(tostring(path), "ui.") then
			M.rebuild()
		end
	end)

	return M
end
