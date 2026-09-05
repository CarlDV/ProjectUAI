-- Design tokens.
--
-- Every colour, size, radius, weight and duration in the interface comes from
-- here. No use site writes a literal, which is the only way a project this size
-- stays coherent -- and it is what lets density, accent and text scale change at
-- runtime without hunting through forty files.
--
-- The palette is a warm neutral, not a cool one, and not pure black. Warm because
-- the whole ramp is one hue family with the accent -- a coral -- so a page of prose
-- with two inline code spans in it reads as one material rather than as grey with
-- orange stuck on. Not pure black because on an OLED phone pure black next to a 1px
-- hairline reads as a seam, and a slight lift keeps the surface hierarchy legible at
-- low brightness.
--
-- The lightness steps are deliberately close together at the dark end. The interface
-- it is modelled on separates a sidebar from a canvas from a card by two or three
-- percent of lightness and a hairline, never by a shadow or a heavy fill, and that is
-- what makes it read as flat rather than as a stack of boxes.
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
		[0] = rgb(19, 19, 18),
		[1] = rgb(26, 26, 24),
		[2] = rgb(31, 30, 29),
		[3] = rgb(38, 38, 36),
		[4] = rgb(47, 47, 44),
		[5] = rgb(58, 58, 55),
		[6] = rgb(74, 74, 71),
		[7] = rgb(92, 91, 86),
		[8] = rgb(108, 107, 102),
		[9] = rgb(152, 150, 142),
		[10] = rgb(176, 174, 166),
		[11] = rgb(245, 244, 238),
	}

	-- Accents, all landing in the same lightness band so switching one does not
	-- change how loud the interface feels. The coral is the default and the one the
	-- rest of the palette is tuned around; the others are kept because someone who
	-- picked teal a version ago should not have it silently taken away.
	local ACCENTS = {
		claude = { base = rgb(217, 119, 87), hot = rgb(232, 146, 117), label = "Coral" },
		aurora = { base = rgb(58, 205, 186), hot = rgb(96, 226, 208), label = "Aurora" },
		indigo = { base = rgb(122, 136, 255), hot = rgb(153, 165, 255), label = "Indigo" },
		amber = { base = rgb(226, 160, 74), hot = rgb(243, 184, 108), label = "Amber" },
		rose = { base = rgb(240, 108, 138), hot = rgb(249, 142, 166), label = "Rose" },
	}

	M.ACCENTS = ACCENTS

	-- Type resolution, in two layers.
	--
	-- `Enum.Font` is the legacy pairing of a family with one baked-in weight --
	-- BuilderSansMedium is a member, and there is no way to ask that family for
	-- anything else. `FontFace` is the modern one: a family asset plus an independent
	-- weight axis, so a single family yields Regular, Medium and SemiBold rather than
	-- whichever pairs somebody happened to enumerate. Having the weight axis is most
	-- of the difference between type that reads as an application and type that reads
	-- as a 2016 forum: hierarchy comes from 400/500/600 at one or two sizes, not from
	-- jumping the size every level because only two weights exist.
	--
	-- The family string is never written here. It is read back off the engine with
	-- Font.fromEnum, so a family this client cannot load can never be named. A
	-- hardcoded rbxasset path has the opposite failure mode: it constructs fine and
	-- renders nothing, and there is no way to detect that from Lua.
	local function enumFont(name)
		local ok, item = pcall(function() return Enum.Font[name] end)
		if ok and item then return item end
		return nil
	end

	local function fontOr(name, fallback)
		return enumFont(name) or fallback
	end

	local function familyOf(name)
		local item = enumFont(name)
		if not item then return nil end
		local ok, face = pcall(function() return Font.fromEnum(item) end)
		if ok and face and type(face.Family) == "string" and face.Family ~= "" then
			return face.Family
		end
		return nil
	end

	-- Which point on the weight axis each role asks for. `strong` is SemiBold rather
	-- than Bold: at 15 and 16 pixels Bold on a dark ground blooms and reads as shouting,
	-- and 600 is what the interface this follows uses for a title.
	local WEIGHTS = { regular = "Regular", medium = "Medium", strong = "SemiBold" }

	local function faceFor(family, weight)
		if not family then return nil end
		local ok, face = pcall(function()
			return Font.new(family,
				Enum.FontWeight[WEIGHTS[weight] or "Regular"],
				Enum.FontStyle.Normal)
		end)
		if ok and face then return face end
		return nil
	end

	local SANS = fontOr("BuilderSans", Enum.Font.Gotham)
	local SANS_MEDIUM = fontOr("BuilderSansMedium", Enum.Font.GothamMedium)

	-- The interface and code families a person can actually pick from.
	--
	-- A free-text font field is the one control in the reference client that cannot be
	-- honest here: Roblox renders from a fixed set of families and cannot load a name it
	-- was handed, so naming JetBrains Mono in a box would change nothing. What is
	-- offered instead is the set that exists *on this client*, discovered rather than
	-- declared -- every candidate below is probed against the engine and dropped if it
	-- does not resolve, so an older client shows a shorter list instead of a list with
	-- dead entries in it.
	--
	-- Every name here is a real member of Enum.Font. That is not a stylistic point: an
	-- invented one would be silently dropped by the probe on a real client and silently
	-- *accepted* by the test harness, whose Enum proxy resolves anything asked of it --
	-- so a typo would surface as a font option that exists only in the tests.
	local INTERFACE_CANDIDATES = {
		{ id = "builder", label = "Builder Sans", regular = "BuilderSans", medium = "BuilderSansMedium" },
		{ id = "arimo", label = "Arimo", regular = "Arimo", medium = "ArimoBold" },
		{ id = "roboto", label = "Roboto", regular = "Roboto", medium = "Roboto" },
		{ id = "nunito", label = "Nunito", regular = "Nunito", medium = "Nunito" },
		{ id = "titillium", label = "Titillium Web", regular = "TitilliumWeb", medium = "TitilliumWeb" },
		{ id = "ubuntu", label = "Ubuntu", regular = "Ubuntu", medium = "Ubuntu" },
		{ id = "source", label = "Source Sans", regular = "SourceSans", medium = "SourceSansSemibold" },
		{ id = "gotham", label = "Gotham", regular = "Gotham", medium = "GothamMedium" },
	}

	-- Two, because Enum.Font has two monospace families and no more. Anything else a
	-- code editor would reach for -- JetBrains Mono, Inconsolata, Fira -- is not in the
	-- engine, and offering it would be offering nothing.
	local CODE_CANDIDATES = {
		{ id = "code", label = "Source Code Pro", regular = "Code" },
		{ id = "roboto", label = "Roboto Mono", regular = "RobotoMono" },
	}

	-- Resolution happens once, at load. Probing is a dozen pcalls; doing it per rebuild
	-- would repeat them on every accent change.
	local function resolveFamilies(candidates, fallbackEnum)
		local byId, order = {}, {}
		for _, entry in ipairs(candidates) do
			local regular = enumFont(entry.regular)
			local family = familyOf(entry.regular)
			-- Kept when either layer works: the family gives the weight axis, the enum
			-- alone still renders. Dropped only when the client has neither.
			if regular or family then
				byId[entry.id] = {
					id = entry.id,
					label = entry.label,
					family = family,
					enumName = entry.regular,
					regular = regular or fallbackEnum,
					medium = fontOr(entry.medium or entry.regular, regular or fallbackEnum),
					faces = {
						regular = faceFor(family, "regular"),
						medium = faceFor(family, "medium"),
						strong = faceFor(family, "strong"),
					},
				}
				order[#order + 1] = entry.id
			end
		end
		return byId, order
	end

	local INTERFACE_FONTS, INTERFACE_ORDER = resolveFamilies(INTERFACE_CANDIDATES, SANS)
	local CODE_FONTS, CODE_ORDER = resolveFamilies(CODE_CANDIDATES, Enum.Font.Code)

	M.INTERFACE_FONTS = INTERFACE_FONTS
	M.INTERFACE_ORDER = INTERFACE_ORDER
	M.CODE_FONTS = CODE_FONTS
	M.CODE_ORDER = CODE_ORDER

	-- The first candidate that resolved, which is the most contemporary family this
	-- client has. Named rather than assumed: on a client old enough to be missing
	-- Builder Sans the default has to move, and a stored setting naming a family that
	-- is not here has to fall back to something rather than to nil.
	M.defaultInterfaceFont = INTERFACE_ORDER[1] or "gotham"
	M.defaultCodeFont = CODE_ORDER[1] or "code"

	-- The two code palettes the appearance pane previews and the transcript uses.
	--
	-- Light is a real option rather than a swatch: a code block on a light card in a
	-- dark interface is what the reference client does, and the setting has to change
	-- what a fenced block in the transcript looks like or it is decoration.
	local CODE_THEMES = {
		dark = {
			label = "Claude Dark",
			surface = NEUTRAL[0],
			border = NEUTRAL[4],
			bar = NEUTRAL[2],
			text = NEUTRAL[11],
			-- Line numbers and the language label. It has to clear 3:1 on the bar it
			-- sits on: a gutter nobody can read is a column of noise down the left.
			gutter = NEUTRAL[9],
			addSurface = rgb(24, 54, 34),
			addText = rgb(126, 217, 148),
			removeSurface = rgb(64, 28, 32),
			removeText = rgb(240, 138, 132),
		},
		light = {
			label = "Claude Light",
			surface = rgb(250, 249, 245),
			border = rgb(214, 211, 202),
			bar = rgb(237, 235, 228),
			text = rgb(38, 38, 36),
			gutter = rgb(112, 110, 103),
			addSurface = rgb(219, 245, 226),
			addText = rgb(21, 105, 55),
			removeSurface = rgb(252, 226, 226),
			removeText = rgb(163, 32, 32),
		},
	}
	local CODE_THEME_ORDER = { "dark", "light" }

	M.CODE_THEMES = CODE_THEMES
	M.CODE_THEME_ORDER = CODE_THEME_ORDER

	-- Line heights, named. Four of them were loose numbers inside the type table and
	-- three more were repeated at use sites that needed a label to sit on a control's
	-- centre line -- a title at the reading measure of 1.6 is 40px of box around 16px
	-- of glyph, which is why the window header's two lines had one pixel of air above
	-- and below them.
	M.line = { tight = 1.2, snug = 1.35, normal = 1.5, reading = 1.6 }

	-- Body text is the one thing in here a person actually reads, so it gets the
	-- room: 14 on a 1.6 line, which is a reading measure rather than a UI measure.
	-- Everything that is not prose is quieter and tighter than it used to be --
	-- headings a step down, labels one weight rather than bold-and-uppercase --
	-- because the interface this follows gets its hierarchy from spacing and colour,
	-- not from size. A 22px bold display over 13px body is a dashboard; this is a
	-- document with controls at the edges.
	--
	-- `weight` names a point on the family's weight axis rather than a font, because
	-- the family is a setting: the interface font and the code font are both pickable,
	-- and a resolved Enum.Font baked in here could not follow them.
	local BASE_TEXT = {
		display = { size = 19, weight = "strong", line = M.line.tight },
		title = { size = 16, weight = "strong", line = M.line.tight },
		heading = { size = 15, weight = "medium", line = M.line.snug },
		body = { size = 14, weight = "regular", line = M.line.reading },
		bodyStrong = { size = 14, weight = "medium", line = M.line.reading },
		small = { size = 13, weight = "regular", line = M.line.normal },
		label = { size = 12, weight = "medium", line = M.line.tight },
		caption = { size = 12, weight = "regular", line = M.line.snug },
		overline = { size = 11, weight = "medium", line = M.line.tight },
		mono = { size = 13, weight = "mono", line = M.line.normal },
		monoSmall = { size = 12, weight = "mono", line = M.line.normal },
	}

	local BASE_SPACE = {
		none = 0, hair = 2, xxs = 4, xs = 6, sm = 8, md = 12, lg = 16, xl = 20, xxl = 28, huge = 40,
	}

	local BASE_SIZE = {
		control = 32,      -- default button / field height
		controlSmall = 26,
		controlLarge = 38,
		icon = 16,
		iconLarge = 20,
		row = 34,
		-- Tall enough for two lines of chrome plus air. At 42 the window header's title
		-- and subtitle -- 40px of type between them at the reading measure -- had a
		-- single pixel above and below, so the title touched the window's top edge.
		header = 48,
		rail = 52,
		tab = 30,
		launcher = 44,
		scrollbar = 4,
		avatar = 26,
		-- The switch. `switchWide` is the width, kept as a token because it was a
		-- hardcoded 38 that four panels each reserved a hand-summed 46 for -- every one
		-- of which would have gone wrong the moment either number moved. Those rows now
		-- fill instead of reserving, but the size still belongs here.
		switch = 20,
		switchWide = 34,
		-- Slider and progress geometry.
		track = 3,
		knob = 12,
		-- The label column in a key/value list, wide enough for the longest key any
		-- panel in here uses.
		keyColumn = 104,
		-- Status dots, and the right-hand column a transcript row puts a duration or a
		-- progress count in. Both were literals repeated at five and three sites
		-- respectively, with two of the dot sizes disagreeing by a pixel.
		dot = 6,
		dotSmall = 4,
		metaColumn = 52,
		metaColumnWide = 88,
		-- Overlay widths. Twelve independent literals between 160 and 420 used to
		-- decide how wide a menu, a dropdown or a dialog was, which is why no two
		-- dialogs in here were the same width.
		menu = 200,
		menuMin = 160,
		menuWide = 320,
		menuMax = 320,
		modal = 380,
		modalWide = 420,
		modalMin = 260,
		-- The reading column. Past roughly this width a line of prose becomes a single
		-- sentence a foot long, which is unreadable however correct the layout is.
		-- Overridden by the transcript-width setting, which is why the three widths it
		-- offers are tokens too rather than numbers in a panel.
		reading = 1180,
		readingNarrow = 760,
		readingMedium = 980,
		sidebar = 240,
		-- Dense list furniture: a session row in the sidebar, a group header above it,
		-- the pinned profile bar at the bottom, a chip in the composer.
		rowSmall = 26,
		rowTight = 22,
		bar = 36,
		chip = 22,
		-- The home card: its column, one metric tile, and one cell of the activity
		-- grid. All three were literals in the surface that drew them.
		statCard = 560,
		statTile = 56,
		cell = 11,
		-- The settings dialog, which is a window of its own rather than a modal card.
		dialog = 760,
		dialogTall = 520,
		dialogNav = 190,
	}

	-- Corners are tighter than they were. A 16px radius on a card reads as a mobile
	-- widget; 6 to 10 reads as a document panel, which is what this is.
	M.radius = { none = 0, xs = 2, sm = 4, md = 6, lg = 10, xl = 14, pill = 999 }
	M.stroke = { hair = 1, focus = 2 }

	-- The visual constants that are neither a colour nor a size. They were literals
	-- at half a dozen use sites, which is how the modal scrim ended up at 0.45 and the
	-- quick-chat scrim -- the same effect, one layer up -- at 0.5.
	M.opacity = { scrollbar = 0.4, scrim = 0.5, dim = 0.6 }

	-- How far a surface is scaled down as it enters. Small on purpose: a panel that
	-- springs in from 0.9 is a phone app, and three surfaces here were each doing it
	-- by a slightly different amount.
	M.scale = { enter = 0.98 }

	M.motion = {
		-- Durations, in seconds, for a caller that needs a number rather than a tween.
		fast = 0.12,
		base = 0.18,
		slow = 0.3,
		-- Tweens. `instant` is a real TweenInfo rather than a zero, because the thing
		-- callers actually want from it is "apply this now" through the same
		-- TweenService path as every other paint -- a bare 0 is not a TweenInfo and
		-- cannot be passed to Create at all.
		instant = TweenInfo.new(0.01, Enum.EasingStyle.Linear),
		enter = TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		exit = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		hover = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		press = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		slide = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
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
		local accentName = config.get("ui.accent", "claude")
		local accent = ACCENTS[accentName] or ACCENTS.claude
		local density = config.get("ui.density", "comfortable")
		local compact = density == "compact"
		local textScale = util.clamp(tonumber(config.get("ui.fontScale", 1)) or 1, 0.85, 1.4)
		local spaceScale = compact and 0.78 or 1
		local sizeScale = compact and 0.86 or 1

		M.accentName = accentName
		M.density = density

		-- Families. Both layers resolve here: `enum` is what gets assigned to Font and
		-- always works, `face` is the FontFace that carries the weight axis and is
		-- applied over the top when the client has one. A stored id naming a family this
		-- client does not have falls back to the first that resolved rather than to nil.
		local family = INTERFACE_FONTS[config.get("ui.interfaceFont", M.defaultInterfaceFont)]
			or INTERFACE_FONTS[M.defaultInterfaceFont]
			or INTERFACE_FONTS[INTERFACE_ORDER[1]]
		local monoFamily = CODE_FONTS[config.get("ui.codeFont", M.defaultCodeFont)]
			or CODE_FONTS[M.defaultCodeFont]
			or CODE_FONTS[CODE_ORDER[1]]

		local enums = {
			regular = (family and family.regular) or SANS,
			medium = (family and family.medium) or SANS_MEDIUM,
			-- No legacy member is a semibold of anything except Source Sans, so `strong`
			-- degrades to medium rather than to bold: one step too heavy is louder than
			-- one step too light, and this is the fallback path.
			strong = (family and family.medium) or SANS_MEDIUM,
			mono = (monoFamily and monoFamily.regular) or Enum.Font.Code,
		}
		local faces = {
			regular = family and family.faces.regular or nil,
			medium = family and family.faces.medium or nil,
			strong = family and family.faces.strong or nil,
			mono = monoFamily and monoFamily.faces.regular or nil,
		}

		M.interfaceFontName = (family and family.label) or "Gotham"
		M.codeFontName = (monoFamily and monoFamily.label) or "Source Code Pro"
		-- The legacy enum name, for RichText's `face` attribute -- which takes an
		-- Enum.Font name string and knows nothing about FontFace. Inline code in a reply
		-- goes through it, so it has to follow the code-font setting rather than saying
		-- "Code" forever.
		M.codeFontEnumName = (monoFamily and monoFamily.enumName) or "Code"
		-- Whether the weight axis is live, so the appearance pane can say so instead of
		-- claiming a weight the client is not rendering.
		M.hasFontFace = faces.regular ~= nil

		local codeThemeName = config.get("ui.codeTheme", "dark")
		local code = CODE_THEMES[codeThemeName] or CODE_THEMES.dark
		M.codeThemeName = CODE_THEMES[codeThemeName] and codeThemeName or "dark"
		M.code = code

		M.color = {
			-- Surfaces, darkest to lightest. The canvas sits one step above the
			-- deepest tone rather than on it, so a code block can go *below* the page
			-- it is on -- which is how the interface this follows separates verbatim
			-- text from prose, and it needs a step in hand to do it.
			canvas = NEUTRAL[1],
			sidebar = NEUTRAL[0],
			sidebarActive = NEUTRAL[2],
			surface = NEUTRAL[2],
			surfaceRaised = NEUTRAL[3],
			surfaceOverlay = NEUTRAL[4],
			surfaceHover = NEUTRAL[4],
			surfaceActive = NEUTRAL[5],
			scrim = NEUTRAL[0],

			activityBlue = rgb(59, 130, 246),
			activityBlueLight = rgb(96, 165, 250),
			activityBlueDark = rgb(37, 99, 235),
			activityCell = NEUTRAL[2],

			-- Lines.
			-- Outlines sit three to five steps above the surface they are drawn on.
			-- borderSubtle used to be NEUTRAL[3], one step above surfaceRaised, which
			-- is a contrast ratio of about 1.05 to 1 -- every card edge, every
			-- segmented outline and the header rule were all invisible, and the
			-- interface read as untitled blocks of near-black rather than as panels.
			borderSubtle = NEUTRAL[5],
			border = NEUTRAL[6],
			borderStrong = NEUTRAL[7],

			-- Type. Secondary and tertiary each moved a step brighter: on a warm dark
			-- ramp the old pair sat at 3.1 and 2.4 to 1 against the canvas, and a
			-- caption nobody can read is a caption that may as well not be there.
			text = NEUTRAL[11],
			textSecondary = NEUTRAL[10],
			textTertiary = NEUTRAL[9],
			textDisabled = NEUTRAL[8],
			textOnAccent = NEUTRAL[0],

			-- The one loud action. A cream fill with dark text, which is what the
			-- interface this follows uses for its single primary control per view --
			-- and it is deliberately not the accent: reserving colour for meaning
			-- (inline code, a running turn, a risk) is what keeps the accent readable
			-- as meaning rather than as decoration.
			solid = NEUTRAL[11],
			solidHover = M.mix(NEUTRAL[11], rgb(255, 255, 255), 0.5),
			solidPress = NEUTRAL[10],
			onSolid = NEUTRAL[0],

			-- Accent and its quiet variants.
			accent = accent.base,
			accentHot = accent.hot,
			accentMuted = M.mix(NEUTRAL[2], accent.base, 0.4),
			accentSurface = M.mix(NEUTRAL[3], accent.base, 0.14),
			accentBorder = M.mix(NEUTRAL[5], accent.base, 0.5),

			-- Status. Saturated enough to read at caption size against a warm dark
			-- ramp, and pulled away from the coral in hue so a danger row and an
			-- accented row are not the same colour with a different label on it.
			success = rgb(94, 200, 124),
			successSurface = M.mix(NEUTRAL[3], rgb(94, 200, 124), 0.13),
			warn = rgb(226, 170, 78),
			warnSurface = M.mix(NEUTRAL[3], rgb(226, 170, 78), 0.13),
			danger = rgb(219, 82, 76),
			dangerSurface = M.mix(NEUTRAL[3], rgb(219, 82, 76), 0.13),
			dangerBorder = M.mix(NEUTRAL[5], rgb(219, 82, 76), 0.45),
			info = rgb(120, 162, 226),
			infoSurface = M.mix(NEUTRAL[3], rgb(120, 162, 226), 0.13),

			-- The one message surface. The agent's turn is the canvas itself -- a reply
			-- is the page, not an object on it -- and tool rows, subagent cards and
			-- reasoning are all flat now too, so the only fill left in a transcript is
			-- the user's own turn.
			--
			-- Tinted a few percent toward the accent rather than left on surfaceRaised.
			-- surfaceRaised is what a text field is filled with, so the user's own turn
			-- and the composer below it were the same colour with the same corner radius
			-- -- which is why a sent question read as an input box someone had typed into
			-- and not submitted.
			bubbleUser = M.mix(NEUTRAL[3], accent.base, 0.07),
			bubbleUserBorder = M.mix(NEUTRAL[5], accent.base, 0.18),
			-- The code palette, which is a setting: a fenced block in the transcript,
			-- the diff preview in the appearance pane and the identity readout all draw
			-- from these, so switching the code theme changes what code looks like
			-- rather than only what the preview looks like.
			codeSurface = code.surface,
			codeBorder = code.border,
			codeBar = code.bar,
			codeText = code.text,
			codeGutter = code.gutter,
			codeAddSurface = code.addSurface,
			codeAddText = code.addText,
			codeRemoveSurface = code.removeSurface,
			codeRemoveText = code.removeText,
		}

		M.text = {}
		for role, spec in pairs(BASE_TEXT) do
			local size = math.max(math.floor(spec.size * textScale + 0.5), 8)
			M.text[role] = {
				size = size,
				font = enums[spec.weight] or enums.regular,
				-- May be nil, and a nil FontFace is never assigned -- P.text applies the
				-- enum first and only layers the face over it when there is one.
				face = faces[spec.weight],
				weight = spec.weight,
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
			-- Floored at one, not at eight. The old floor predated the small tokens and
			-- silently clamped every one of them: a 3px slider track, a 4px scrollbar and
			-- a 6px status dot all came out as 8, which is why the scrollbar had never
			-- been the width it said it was.
			M.size[name] = math.max(math.floor(value * sizeScale + 0.5), 1)
		end

		-- The transcript column is the one size a setting names directly. Resolved after
		-- the ramp so the chosen width is the chosen width rather than the chosen width
		-- times the density scale.
		local widths = {
			narrow = M.size.readingNarrow,
			medium = M.size.readingMedium,
			wide = M.size.reading,
		}
		M.readingName = config.get("ui.transcriptWidth", "wide")
		if not widths[M.readingName] then M.readingName = "wide" end
		M.size.reading = widths[M.readingName]

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
		if tone == "accent" then return M.color.accent end
		-- "neutral" is a fact rather than a status -- a model id, an auth style -- and
		-- it is the default, because most chips in here are labels that happened to be
		-- given a colour by a tone system that had no way to say "no tone".
		if tone == "neutral" then return M.color.textSecondary end
		return M.color.info
	end

	function M.toneSurface(tone)
		if tone == "good" then return M.color.successSurface end
		if tone == "warn" then return M.color.warnSurface end
		if tone == "bad" then return M.color.dangerSurface end
		if tone == "accent" then return M.color.accentSurface end
		if tone == "neutral" then return M.color.surfaceOverlay end
		return M.color.infoSurface
	end

	-- Motion respects the platform preference: GuiService.ReducedMotionEnabled is
	-- a real accessibility setting, and an interface that ignores it is the sort of
	-- thing that makes people close it.
	function M.tween(name)
		local responsive = env.require("ui/responsive")
		if responsive.reduceMotion then
			return M.motion.instant
		end
		local info = M.motion[name]
		-- Only a TweenInfo may come back. The table also holds plain durations, and
		-- returning 0.18 to a caller about to pass it to TweenService is a crash a
		-- typo away.
		if typeof(info) == "TweenInfo" then return info end
		return M.motion.hover
	end

	function M.duration(name)
		local responsive = env.require("ui/responsive")
		if responsive.reduceMotion then return 0.01 end
		local value = M.motion[name]
		if type(value) == "number" then return value end
		return M.motion.base
	end

	M.rebuild()

	-- Density, accent and scale live in config, so the theme rebuilds itself when any
	-- of them is written rather than every panel having to remember to.
	--
	-- Only the keys that decide a token, though. A rebuild fires theme.changed, which
	-- the app answers by destroying and reconstructing every panel, the window and the
	-- launcher -- so accepting the whole `ui.` namespace meant that maximising the
	-- window, moving the launcher, switching panel or pinning the layout each tore the
	-- interface down and built it again. Anything not in this table cannot change a
	-- token, and so has no business rebuilding anything.
	local TOKEN_KEYS = {
		["ui.accent"] = true,
		["ui.density"] = true,
		["ui.fontScale"] = true,
		["ui.interfaceFont"] = true,
		["ui.codeFont"] = true,
		["ui.codeTheme"] = true,
		["ui.transcriptWidth"] = true,
	}

	config.changed:connect(function(path)
		-- nil is a whole-file load; "ui" is a namespace reset, which startsWith("ui.")
		-- does not match and which used to leave the interface on the old tokens.
		if path == nil or path == "ui" or TOKEN_KEYS[tostring(path)] then
			M.rebuild()
		end
	end)

	return M
end
