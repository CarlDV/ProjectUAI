-- Project-Gravity-02 module contract, shared by desktop and mobile (2026-09-23).
return function(env)
	local M = {}
	M.guide = [[Project Gravity shape modules
Source reference: https://github.com/CarlDV/Project-Gravity-02/blob/main/docs/PLUGINS.md

Return a module table M. Required: M.f2(p, cen, d, t, c, x1, x6, x9).
Return two Vector3 values: velocity correction, exact target position.
p is the held BasePart, cen the current center, d a persistent per-part record,
t the scaled formation clock, c this shape's settings, x1 engine settings,
x6 runtime state and x9 constants. Pull is normally (target - p.Position) *
(x1.k10 * x9.c1). Use d.slot or d.id or 1 for stable slots, d.slot_n for counts.
Optional M.px(t, c, x6, x9, x1) runs once per frame (no cen argument).
Optional M.cleanup(x6, x1) releases owned state, connections and instances.
Own a namespaced x6.pre[NAME]. Cleanup must be idempotent. Do not delete objects
by broad name searches or clear another plugin's state. Avoid setup side effects.
Parts arrive late and may skip frames; use shared timestamps for timed actions.
d.claim_t uses wall time, not the scaled t. Guard all divisors and nonfinite math.

M.Controls is an array. Supported entries:
Slider: Type, Name, Key, Min, Max; optional Default, Div, IntOnly, ExactMax, Desc.
Toggle: Type, Name, Key; boolean Default (otherwise false), optional Desc.
TextBox: Type, Name, Key; string Default (otherwise empty), MaxChars, Desc.
Button: Type, Name, Callback(c, x6, x1); optional stable Key, Desc.
Buttons are actions, never saved settings. Callbacks should finish quickly.
Min/Max are display units; Default and c[Key] are stored units. Div=10 and
Default=1.6 displays 16. IntOnly rounds the display, not the stored value.
A slider whose Name contains "speed" gains +300 display units unless ExactMax=true.
Use gravity_shapes(name=...) to inspect actual keys and stored value ranges.

Optional flags: ContinuousMotion adds a real-time x6.motion_offset that the
plugin must add to its target; NoBlend opts interactive/physics-mutating shapes
out of blending; AlwaysProcess bypasses distance culling, not processing buckets.
FrameTracking evaluates every held part each physics frame and drives it straight
to its exact target through the velocity constraint, with global/per-part speed
limits, bypassing the usual damping, smoothing and integral feedback that distort
rapid rigid orbits. Pair it with NoBlend and continuous targets; it costs a full
part sweep each frame. For uneven debris, use compact silhouettes and handle low/variable part counts.

Natural release: d.free_physics=true disables actuators and restores normal
physics while retaining the record. Clear to nil to regrab. With free_physics,
d.launch_velocity applies one impulse and is consumed. d.angular_velocity sets
world-space radians/second. d.collisions is false/true/nil for noclip/original/policy.
d.unclaim=true removes the record; use d.keep_velocity=true or explicit
d.release_velocity and d.release_spin to preserve/specify release momentum.
Let Roblox simulate gravity on released parts. For an immediate button action,
set fields on the real held record and call x6.apply_shape_physics(p, d) if present.
Leave Part Control overrides (d.pc_mode) alone.

Mobile: M.MobileControls={Action="FIRE", Range=600} opts in to the circular stick
and separate action button. Read x6.mobile_input inside px/f2 only when active
and input.shape==NAME. direction is world direction; aim/base_aim are world points;
x/y are normalized axes; yaw/pitch are radians; held is the action finger;
presses is an edge counter and generation changes on reset. Compare both
generation and presses for a new action. Keep a desktop fallback. Focus loss,
stop, pause, disable, shape changes and unload reset mobile input.

gravity_plugin_write saves to GravityShapes/<name>.lua. Use path for saved inputs
or workspace source. overwrite=true is required for replacement. load=false
checks syntax and saves without executing; load=true validates setup and makes
the module available. It does not select an inactive shape. Select explicitly
with gravity_shape(action="select", shape=...). Live physics and touch behavior
still need in-game testing. Core stop releases parts; the Gravity X fully unloads.
]]
	M.template = [[local M = { ContinuousMotion = true }
local NAME = "Orbit Bloom"

local function state(x6)
	x6.pre = x6.pre or {}
	local st = x6.pre[NAME]
	if not st then st = { phase = 0 }; x6.pre[NAME] = st end
	return st
end

function M.px(t, c, x6, x9, x1)
	local st = state(x6)
	local dt = st.last_t and (t - st.last_t) or 0
	st.last_t = t
	st.phase = st.phase + dt * math.clamp(c.speed or 8, 0, 40) * x9.c2
end

function M.f2(p, cen, d, t, c, x1, x6, x9)
	local st = state(x6)
	local id = d.slot or d.id or 1
	local a = id * 2.399963229728653 + st.phase
	local radius = math.clamp(c.radius or 40, 0, 150)
	local target = cen + Vector3.new(math.cos(a) * radius,
		20 + (c.bob and math.sin(a * 3 + st.phase) * 8 or 0), math.sin(a) * radius)
	if x6.motion_offset then target = target + x6.motion_offset end
	return (target - p.Position) * (x1.k10 * x9.c1), target
end

M.Controls = {
	{ Type = "Slider", Name = "Radius", Key = "radius", Min = 0, Max = 150, Default = 40 },
	{ Type = "Slider", Name = "Orbit Speed", Key = "speed", Min = 0, Max = 40, Default = 8, ExactMax = true },
	{ Type = "Toggle", Name = "Petal Wave", Key = "bob", Default = true },
	{ Type = "Button", Name = "Restart Orbit", Key = "restart", Callback = function(c, x6)
		state(x6).phase = 0
	end },
}

function M.cleanup(x6, x1)
	if x6.pre then x6.pre[NAME] = nil end
end

return M
]]
	return M
end
