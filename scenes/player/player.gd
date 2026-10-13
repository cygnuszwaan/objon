extends CharacterBody2D

enum State { IDLE, RUN, JUMP, FALL, CROUCH, KICK, SURF, CLIMB, HANG, SWIM, HURT, DEAD, DANCE, SNEAK }
enum OneShotAction { NONE, UNCROUCHING, KICKING, MANTLING, HURT, CLIMBING_DOWN }

signal health_changed(current: int, maximum: int)  # the HealthBar (a child of this scene) listens
signal died
signal gem_collected(count: int, total: int)  # total = gems in the level at load; Finish and the GemDisplay (a child of this scene) listen
signal gems_counted(total: int)  # the level's gem total was just counted at load (not emitted when a restore supplied it); the GemDisplay redraws on it
signal points_changed(total: int, delta: int)  # the PointsDisplay (a child of this scene) listens
signal won  # emitted by start_dance()
signal cue_ended(source: Object)  # a camera cue finished, was replaced by another, or was cut short; `source` is the `source` the cue was shown with (null if none): a CameraCue starts its cooldown on it

var state: State = State.IDLE
var one_shot_action: OneShotAction = OneShotAction.NONE
var _air_kick := false  # the current KICKING one-shot was started airborne: it keeps horizontal control and carried momentum (a ground kick roots you). Only meaningful while one_shot_action == KICKING

var speed: float = 150.0

@export var step_height: float = 4.0  # px: the tallest step the player walks up without jumping (a quarter of a 16 px tile); 0 turns it off. Needs slope_snap_length >= step_height, which settles the body back down onto the step
@export var slope_snap_length: float = 8.0
	# CharacterBody2D.floor_snap_length defaults to 1px, which is far too small for this game:
	# walking down a slope moves the body horizontally first, leaving the floor up to
	# (horizontal_speed * tan(slope_angle) / physics_ticks) pixels below it each physics tick —
	# ~2.5px at walk speed on a 45-degree slope, more at higher speeds. When that gap exceeds the
	# snap length, snapping fails, is_on_floor() flips false for a frame or two, and the player
	# visibly "skips" down the slope (gravity then only accumulates while airborne, which is why
	# raising gravity never helped). 8px (half a tile) covers a 45-degree slope at speeds up to about 2.5x walk speed.
	# Trade-off: any step DOWN of less than this many pixels is now walked down rather than fallen
	# off. Snapping is automatically skipped while velocity.y is negative, so jumping is unaffected.

var jump_velocity: float = -240.0
var gravity: float = 900.0
var air_kick_halts_ascent := false  # an airborne kick cancels any upward speed (it never slows a fall), so kicking out of a jump ends the rise; false = the kick leaves vertical speed alone
var coyote_time: float = 0.12
var coyote_timer: float = 0.0
var jump_buffer_time: float = 0.12
var jump_buffer_timer: float = 0.0

var _pending_launch: Vector2 = Vector2.ZERO
var _has_pending_launch: bool = false
var _walk_push_active: bool = false  # a block took this frame's walk push (see _walk_push_limited()); read next frame by the wall check that zeroes _slide_vx
var _slide_vx: float = 0.0  # the player's OWN horizontal velocity (no conveyor/water push), carried frame to frame so a slippery floor can build/decay it
	# set by launch() (jump pads); consumed once near the end of this frame's velocity math in
	# _physics_process, rather than written to velocity directly inside launch() itself — see the
	# comment there for why.

var crouch_shape: Shape2D  # built once in _ready(); null if the collider type isn't supported
var crouch_offset_y: float = 0.0  # how far CollisionShape2D moves DOWN while crouched so the feet stay planted; computed in _ready()
var is_crouching: bool = false

var swim_shape_bulge_x: float = 0.0  # how far EACH side of the collider bulges outward once
	# _set_swim_collider() rotates it 90 degrees; computed in _ready() from standing_shape's own
	# height and width. See _set_swim_collider() for how this keeps a touched wall's edge from either
	# clipping in (on swim entry) or leaving a gap (on swim exit).


# --- health / hurt / dead ---
@export var max_health: int = 4  # the health bar art has 4 segments
@export var hurt_knockback: Vector2 = Vector2(180.0, -150.0)
	# x = horizontal speed away from the hazard (direction is chosen at hit time from which side
	# the hazard is on), y = upward pop (negative = up). Applied to the fatal hit too.
@export var hurt_friction: float = 400.0  # px/s^2 the lurch decays by while hurt/dead; also stops the dead body sliding forever
@export var ice_accel: float = 450.0
	# px/s^2 the run speed builds toward its target while standing on a slippery floor (see
	# is_slippery() contract near _conveyor_push_speed()). Normal floors reach full speed instantly.
@export var sneak_speed: float = 50.0
	# px/s while crouched and holding left/right (the SNEAK state). Walk speed is 150. Starts once the crouch-down
	# animation has finished; applies on ice as a target speed approached at ice_accel / ice_friction.
@export var ice_friction: float = 120.0
	# px/s^2 the slide decays by on a slippery floor when there's no input (or while crouching/kicking).
	# At walk speed 150 that's ~1.25s and ~94px to stop.
@export var hurt_invincibility_duration: float = 1.0
@export var respawn_delay: float = 3.0  # seconds after the death animation finishes before Game.respawn()
	# grace period starting at the moment of the hit (so it outlasts the hurt animation). Without
	# it a saw the player is still overlapping would land a fresh hit every physics frame.
const HURT_BLINK_RATE: float = 16.0  # sprite flicker while the grace period runs
var health: int = 4  # reset to max_health in _ready()
var is_dead: bool = false  # terminal for this Player instance: respawning reloads the scene, which builds a fresh one
var hurt_invincibility_timer: float = 0.0

# --- gems / win condition ---
var points: int = 0  # the score; add_points() is the only writer, and it travels through checkpoints (save_state)
var gems_collected: int = 0
var gems_total: int = 0  # every node in group "gem" at load (counted in _count_gems(), deferred so all gems have joined)
var _gems_restored: bool = false  # load_state() set both gem numbers, so _count_gems() must not recount
var is_dancing: bool = false  # terminal, like is_dead — set by start_dance(), which the level's Finish calls (via dance_through()) on entry
var _dance_tween: Tween  # dance_through()'s slide-then-shrink
const DANCE_SHRINK_TO := 0.02  # not 0: a zero scale makes the sprite's transform non-invertible

var climb_speed: float = 100.0
var is_climbing: bool = false

var world_tilemap: TileMapLayer
# Ladders live on their own layers (group "ladder_tilemap") so a ladder can share a cell with a catwalk tile; a tile present = ladder
# cell. There can be several: the level's static `Ladders` layer and any `PoweredLadderLayer`, which is in the group only while out.
# `_ladder_layers()` reads the group every call, so a layer that retracts or extends is seen at once. These remember which layer
# the last `_ladder_cell_overlapping()` / `_ladder_cell_under_feet()` hit was on, for the x-snap on mount.
var _ladder_hit_layer: TileMapLayer
var _ladder_mount_layer: TileMapLayer
var water_manager: WaterManager
	# Found via the "water_manager" group in _ready(), same lookup convention as world_tilemap/
	# ladder_tilemap above. Unlike those two, no push_warning if missing — a level with no water in it
	# has no WaterManager node at all, and that's a normal, expected case, not a broken one.

# --- swim (Phase 8.1: entry/exit detection only — movement lands in 8.2) ---
var _swim_rotated: bool = false  # true while collision_shape is actually in the rotated swim pose; can be false
	# while is_swimming is true when the swim pose doesn't fit (see _set_swim_collider())
var is_swimming: bool = false  # held state, same convention as is_hanging/is_climbing — its own
	# lifetime, decided each frame from physics reality (here: a surface-height query) rather than
	# tracked as part of `state`/`OneShotAction`.
@export var swim_probe_offset_y: float = -4.0
	# World-space vertical offset (negative = up) from collision_shape's center used as the "how deep
	# am I" reference point — a raised "chest height" point rather than the collider's dead center, so
	# a very shallow basin doesn't immediately read as swimmable. Placeholder pending in-editor tuning
	# once a basin with real depth exists to test against.
@export var swim_enter_depth: float = 0.0
	# px the swim probe point must be BELOW a basin's surface (see _water_surface_depth()) before
	# swimming starts. Shifted down 8px (half a tile) from an initial 8.0 placeholder, which put the
	# actual trigger point well above the player's head — the probe's own offset already accounts for
	# "raised chest point", so the extra depth on top of it only needs to be small.
@export var swim_exit_depth: float = -4.0
	# px BELOW the surface the probe must fall to before swimming ends — negative means the probe must
	# actually rise back ABOVE the surface by this much, not just approach it. Kept smaller than
	# swim_enter_depth on purpose — entering needs more depth than leaving needs shallowness, so
	# hovering right at the surface line can't flip the state every frame. Same hysteresis instinct as
	# climb_up_latched/hurt_invincibility_timer elsewhere in this file. Shifted down from an initial 2.0
	# (which fired while most of the body, down to the feet, was still fully submerged), then nudged
	# from -6.0 up to -4.0 after in-editor tuning. Both thresholds remain placeholders pending
	# further in-editor tuning, same as swim_probe_offset_y above.
@export var swim_speed: float = 120.0
	# px/s for horizontal movement AND the swim-down axis (Phase 8.2) — slower than ground `speed`
	# (150), faster than the ladder's vertical `climb_speed` (100), per the design notes' own feel
	# target. Originally shared with swim-up too ("one shared speed... since there's no reason yet to
	# think they'd want to diverge"), but in-editor testing found the shared speed felt right
	# horizontally and going down, just too fast coming up — swim-up now has its own swim_up_speed
	# below instead.
@export var swim_up_speed: float = 80.0
	# px/s for the swim vertical-UP axis only (climb_up/jump while swimming) — split out from
	# swim_speed once in-editor testing found one shared speed rose too fast even though it felt right
	# for horizontal movement and swim-down. Placeholder pending further in-editor tuning of the exact
	# feel target, same as swim_speed originally was.
@export var swim_gravity: float = 150.0
	# px/s² — the RATE at which velocity.y approaches swim_sink_speed (via move_toward()) whenever no
	# vertical input is held, in either direction: it decelerates a fast residual velocity (entering
	# from a long fall, or coasting after releasing up/jump) down toward the target just as much as it
	# accelerates a still player down into a slow sink. Deliberately NOT applied by simple accumulation
	# (`velocity.y += swim_gravity * delta`, the original v1 approach) — that has no fixed point to
	# settle at, so a large residual velocity.y (a long fall carried into the water, held-up velocity
	# right after release) barely changes frame to frame, reading as "full gravity" for a while and,
	# since the same constant was the only brake on that residual, made lowering it look like it mostly
	# extended a jump/swim-up's coast instead of visibly slowing the passive sink. move_toward() give
	# both directions one fixed target to head for, so this constant only ever controls HOW FAST that
	# convergence happens, not what it converges to (that's swim_sink_speed below) — the two can now be
	# tuned independently.
@export var swim_sink_speed: float = 30.0
	# px/s — the speed velocity.y settles at while idling underwater with no input held (a quarter of
	# swim_speed, i.e. a slow drift rather than a free hover). This is the number to lower for a
	# gentler passive sink; swim_gravity above only controls how quickly velocity.y gets there, not the
	# resting speed itself, so changing this doesn't also touch how far a jump/swim-up press carries.
	# Placeholder pending in-editor tuning.

const POINTS_POPUP: PackedScene = preload("res://scenes/effects/points_popup.tscn")
@export var points_popup_offset: Vector2 = Vector2(0, -20)
	# where the "+N" feedback spawns, relative to the player's origin (above the head; the art then rises on its own).

const ELECTRIC_CONTACT_DAMAGE := 1
	# The same, for water a spark has electrified (WaterBasin.is_electrified()). Untuned placeholder.
	# (Chill, the freeze ray's effect, is the shared ChillState model in scripts/chill_state.gd, the one every enemy keeps too.)

const SLAG_CONTACT_DAMAGE := 1
	# Passed to take_hit() every physics frame the player is submerged in a hazardous-LiquidType
	# basin (see _update_swim_state()'s hazard branch below) — take_hit()'s own hurt_invincibility_timer
	# is what keeps this from being a full hit every single frame of contact, not anything here.
	# Mirrors water_manager.gd's SLAG_PARTICLE_DAMAGE (the same hazard, but for flowing particles
	# rather than a settled body); untuned placeholder, same as that one.

@export var ladder_mount_sink: float = 4.0
	# px the body is nudged DOWN when mounting a ladder from the surface above. Standing on a one-way
	# catwalk tile, the feet rest on it and would just stay there; sinking them past the tile's
	# one-way margin (default 1px, set per polygon in the TileSet) lets the collider descend
	# through it. If the player gets caught standing on the catwalk after pressing down (bobbing
	# between climb and idle), raise this; it only needs to exceed that margin.

@export var landing_catch: float = 3.0
	# px: while climbing UP through a floor the ladder passes through, the player lands on that floor
	# once the feet are within this distance below its top surface. Keep it above climb_speed *
	# physics delta (100 / 60 = ~1.7px) or a frame can step straight over the catch zone.
var climb_up_latched := false
var climb_down_latched := false
	# set when a climb ends on a landing while the key is still held, so the same held key can't
	# instantly re-grab (up) or start a crouch / re-mount (down); each clears when its key is released

# --- hang / ledge-grab ---
var is_hanging: bool = false
var hang_facing: float = 1.0    # which way the player was facing when they grabbed on
var hang_anchor: Vector2 = Vector2.ZERO   # exact world-space point the sprite's hand is pinned to while hanging
var mantle_target: Vector2 = Vector2.ZERO # world-space position the player ends up at once the
	# active mantle-up OR catwalk climb-down finishes — shared between both directions (see
	# _begin_mantle() and _begin_catwalk_climb_down()), since it was already just "the tween's
	# target" with nothing mantle-specific about it
var _mantle_tween: Tween  # the active position tween, mantle-up or climb-down; kept so a hit
	# mid-transition can kill it (otherwise it keeps dragging the body toward mantle_target)
var _mantle_start: Vector2 = Vector2.ZERO  # world-space start of the active tween; shifted along
	# with mantle_target when a moving platform carries the hang
var hang_platform: PhysicsBody2D  # the moving body (AnimatableBody2D platform, IceBlock's CharacterBody2D...) the current hang is attached to; null for tiles. Only read while is_hanging
var _hang_platform_last_xf: Transform2D = Transform2D.IDENTITY  # the platform's transform as of the last follow, so the follow applies only what changed (translation AND rotation)
var hang_lockout_timer: float = 0.0
@export var debug_log_stuck: bool = false  # prints the player's state once a second while airborne and nearly motionless, to diagnose a stuck-in-the-air report
const UNEMBED_CLEARANCE := 0.5  # px of gap left between a crust's underside and the head when _unembed_from_crust() moves the body out
var _stuck_log_timer: float = 0.0
var _stuck_log_pos: Vector2 = Vector2.INF
var _skip_buffered_jump := false  # set when a hang's own jump (rail, catwalk or crust underside) was this press, so the same frame's buffered-jump consume is skipped
var _chill := ChillState.new()  # runtime only, never saved (see apply_chill())
var _crust_pass_body: PhysicsBody2D = null  # the crust body the player is jumping up through (a collision exception while set); see _update_crust_pass()
var hang_regrab_lockout: float = 0.3  # prevents an instant re-grab right after dropping/jumping off
var time_since_airborne: float = 0.0  # seconds since is_on_floor() last true; reset to 0 while grounded
var fall_anim_delay_timer: float = 0.0  # see _finish_mantle / post_mantle_fall_anim_delay
var _debug_hang_probes: Dictionary = {}   # cached each physics frame for _draw(); empty until first computed
var _debug_hang_corner: Vector2 = Vector2.ZERO

@export_flags_2d_physics var hang_probe_mask: int = 3  # bit 1 (old default layer, e.g. drillbot's body) + bit 2 (ground,
	# moved here so drillbot.gd could stop colliding with the player without also going blind to the
	# floor — see the Drillbot roadmap entry). Tunable in the Inspector; if this scene predates that
	# change, its Inspector value may still be 1 and needs bumping to 3 by hand.
@export var hang_min_airborne_time: float = 0.15
	# guards against a false grab the instant you step off a ledge: is_on_wall() can briefly read
	# true against the side face of the tile you just left, and if you reverse facing in that same
	# frame the probes below all read "clear" too (your hand is trivially above a tile you were just
	# standing on), producing a hang anchored to nothing. A real wall-slide grab only ever happens
	# after actually falling for a bit, so require a short armed-delay since leaving the floor rather
	# than trying to geometrically distinguish the two cases.
@export var hang_min_fall_speed: float = 0.0     # velocity.y must exceed this (i.e. be descending) to grab — stops grabbing walls you're about to clear on the way up
@export var hang_forward_probe: float = 10.0     # how far ahead (at hand height) must be clear, and how far the wall/corner-finding rays sweep
@export var hang_probe_rise: float = 6.0         # slight upward tilt on the forward clearance probe, like the original's diagonal ray
@export var hang_headroom_check: float = 20.0    # how far up from the ledge point must be clear
@export var hang_top_probe_margin: float = 8.0   # how far below hand height the corner-finding ray sweeps, to guarantee it actually crosses the ledge top
@export var hang_hand_local_offset: Vector2 = Vector2(3.0, -7.0)
	# measured from the "hang" sprite frame (16x16, AnimatedSprite2D "Centered" pivot assumed):
	# the hand/fingertip pixel sits ~3px toward the facing direction and ~7px above the sprite's
	# local origin. Re-measure this if the sprite's centering or the art itself changes.
@export var hang_grip_inset: float = 7.0   # pulls the grip point back from the wall face, toward open space, so the hand doesn't clip into the wall
@export var hang_grip_lift: float = 1.0    # pulls the grip point up from the ledge top surface, so the hand doesn't clip into the floor
@export var mantle_offset: Vector2 = Vector2(3.0, -7.0)
	# where the player's origin ends up standing, relative to hang_anchor (not to wherever the body
	# physically ended up) — tune this to place the player standing on the ledge once mantling completes
@export var post_mantle_fall_anim_delay: float = 0.08
	# mantle_target is an approximation of "standing on the ledge" (see mantle_offset above), so the
	# player often lands a hair above the actual surface and reads as airborne for a frame or two
	# before gravity closes the gap. Without this, _finish_mantle would flash straight into the fall
	# animation for those couple of frames. Tune upward if the flash still slips through on a bigger
	# gap; keep it short — this is meant to be invisible on an actual fall, which is why it's only
	# applied at mantle-exit rather than on every transition into State.FALL.
@export var debug_draw_hang_probes: bool = false  # draws the ledge-grab raycasts (green = clear, red = blocked) and the detected corner/anchor; flip off for release builds

# --- catwalk underside hang (additive to the ledge-hang system above, not a replacement) ---
# Lets the player grab and hang from the UNDERSIDE of a one-way catwalk — e.g. jumping up through
# one without quite reaching high enough to land on top, then grabbing on the way back down —
# with no wall contact involved at all. Deliberately kept as its own detection path rather than
# folded into _try_grab_ledge()/_is_hangable_surface() above: those are gated on is_on_wall(),
# which a catwalk's one-way collision never produces from underneath (the body passes straight
# through while ascending), and this needs to stay a plain overhead grab, not a sideways corner
# grab, so a future "brachiate" state (traversing hand-over-hand along a catwalk's underside) has
# a clean, distinct hang to build on rather than one entangled with the ledge-corner math above.
# hang_style below is how the rest of the hang code (mantle, letting go) tells the two apart while
# sharing everything else (is_hanging, move_and_slide skip, moving-platform follow, kick-hitbox
# facing, the hurt/interrupt teardown) unchanged.
enum HangStyle { LEDGE, CATWALK_UNDER, SWING, RAIL }
var hang_style: HangStyle = HangStyle.LEDGE  # which kind of hang is_hanging currently refers to; only read while is_hanging

# --- swing / trapeze (see swing.gd) ---
var hang_swing: Swing  # the swing a SWING hang is attached to; only meaningful while is_hanging and hang_style == SWING
@export var swing_jump_boost: float = 1.0
	# jumping off a swing adds `jump_velocity * swing_jump_boost` to the vertical velocity the swing carried you with
	# (1 = a full jump on top of the swing's motion, 0 = jumping off is the same as dropping off)
@export var carry_air_accel: float = 400.0
	# px/s^2 of air control while carrying momentum (after a swing, or a surf dismount); with no input it is kept untouched
var _air_carry_active: bool = false  # airborne with carried momentum: horizontal velocity is _air_carry_vx, not input * speed
var _air_carry_vx: float = 0.0
var _air_carry_steers: bool = true  # true: left/right steer the carry (swing release, dismount); false: they don't (surfing, where they will tilt the board)

# --- surf (objon.md, Planned: surfboard; stages 1-2 = ground, air, slopes, ramps and the board tilt; no bowling/water yet) ---
@export var surf_start_speed: float = 240.0  # px/s given on mounting
@export var surf_friction: float = 320.0  # px/s^2 lost on the ground, flat or sloped (the dry value; about 5 tiles of coasting from the start speed); there is no air drag
@export var surf_min_speed: float = 40.0  # below this on the ground the surf ends
@export var surf_top_speed: float = 600.0  # cap on the ground (and at landing); the air has none
@export var surf_slope_gain: float = 1.25  # multiplies gravity along the slope (negative uphill): downhill gains, uphill kills the speed fast
@export var surf_drag_wrong: float = 400.0  # extra px/s^2 while the board tilt has the wrong sign for the ground (nose down uphill, nose up downhill, nose up or down on the flat)
@export var surf_drag_level: float = 150.0  # extra px/s^2 while the board is level on a slope
@export var surf_flat_threshold_degrees: float = 8.0  # a floor shallower than this counts as flat for the tilt match
@export var surf_tilt_down_degrees: float = 26.57  # the board's drawn angle with the nose down (2:1, so it never digs into a common slope)
@export var surf_tilt_up_degrees: float = 45.0  # the board's drawn angle with the nose up (1:1)
@export var surf_tilt_ease_degrees_per_second: float = 720.0  # how fast the drawn board turns to its target (looks only: the match uses the target at once)
@export var surf_launch_pop_degrees: float = 12.0  # leaving the ground with the nose up rotates the velocity upward by this (more height, a shorter jump)
@export var surf_launch_dive_degrees: float = 10.0  # leaving the ground with the nose down rotates it downward by this (flatter, longer)
@export var surf_landing_wrong: float = 0.5  # speed kept on landing with the wrong tilt sign for the ground
@export var surf_landing_level: float = 0.85  # speed kept on landing level on a slope
@export var surf_landing_min_air_time: float = 0.6  # s in the air before a clean landing earns anything (bonus, conversion, points); a plain surf hop is about 0.53 s, so only a ramp, a ledge, a pad or steam qualifies and hopping can't be farmed
@export var surf_landing_clean_bonus: float = 1.1  # speed multiplier for a clean landing on a slope (tilt sign matches the ground's, ground not flat) after the minimum air time; the top speed still caps it
@export var surf_landing_downhill_convert: float = 0.5  # a clean landing on a downhill (after the minimum air time) adds this share of the speed that was going into the floor to the forward speed; the top speed still caps it
@export var surf_landing_points: Array[int] = [5, 10, 20]  # points for a clean landing, one per entry of surf_landing_points_air_times (each value needs a p<N> popup animation)
@export var surf_landing_points_air_times: Array[float] = [0.6, 1.0, 1.5]  # s of air time at which each landing tier is reached (ascending)
@export var surf_bowl_points: Array[int] = [5, 10, 20]  # points for the 1st, 2nd and 3rd-and-later enemy bowled in one chain (each value needs a p<N> popup animation)
@export var surf_bowl_chain_window: float = 2.0  # s after a bowled enemy within which the next one continues the chain
@export var surf_skim_points: int = 5  # points per surf_skim_points_distance skimmed over a basin's surface
@export var surf_skim_points_distance: float = 128.0  # px skimmed per award (8 tiles); 0 turns the reward off
@export var surf_bowl_speed: float = 300.0  # at or above this speed (ground speed, or horizontal speed in the air) the board bowls over what it hits, if that opts in with bowled_over()
const SURF_TILT_DEADZONE := 0.3
const SURF_BOWL_LEAD := 8.0  # px ahead of the swept motion that the bowl query reaches, so a target is hit before the body touches it
const SURF_BOWL_MASK := 1  # collision layer of actors (enemies and other bodies the player stands on or kicks)
const SURF_FLOOR_PRESS := 60.0  # px/s pressed into the floor while surfing: a velocity exactly along an uphill slope never touches it, so is_on_floor() would flicker false (and the floor snap is off while moving up)
const SURF_FLAT_NORMAL_X := 0.052  # a floor normal with |x| below this (about 3 degrees) is treated as exactly flat: contact normals are noisy, and a tiny upward tangent would cancel the floor snap
@export var surf_jump_boost: float = 1.0
	# jumping while surfing adds `jump_velocity * surf_jump_boost` to the vertical velocity the board had (same rule as
	# swing_jump_boost); the player stays on the board in the air and lands back into the surf
@export var surf_friction_wet: float = 80.0  # px/s^2 lost on a wet floor (running water on the floor, or a basin's surface); the ground value eases between this and surf_friction by the wetness
@export var surf_top_speed_wet: float = 800.0  # cap on a wet floor; eases from surf_top_speed by the wetness (a surfer leaving the water is eased back down, not cut)
@export var surf_wet_decay_time: float = 0.4  # s for the wetness to fade from full to dry once the floor stops being wet (it rises at once); smooths the noisy particle reading
@export var surf_water_push_scale: float = 1.0  # multiplies the flowing-water push while surfing (with the current: faster, against it: slower)
@export var surf_skim_min_speed: float = 180.0  # at or above this a surfer skims a settled basin's surface; below it the board sinks and the player swims
@export var surf_skim_drag: float = 160.0  # extra px/s^2 while skimming, on top of the wet friction
@export var surf_steam_lift: float = 1500.0  # px/s^2 of upward acceleration at full steam lift (WaterManager.get_steam_lift() = 1), on top of gravity; above `gravity` a surfer in full steam leaves the floor and rises. Placeholder, tune with the column
@export var surf_steam_max_rise: float = 120.0  # px/s: steam never accelerates the board upward beyond this (a faster upward speed, from a jump pad, is left alone)
@export var camera_lead_start_speed: float = 200.0  # px/s: horizontal speed below which the camera doesn't lead (walking, 150, never does; a surf starts at 240)
@export var camera_lead_gain: float = 0.25  # s: px of lead per px/s of horizontal speed above the start speed
@export var camera_lead_max: float = 96.0  # px: the most the camera leads ahead (the view is 512 px wide at zoom 2.5, so the player stays well inside it)
@export var camera_lead_smoothing: float = 4.0  # 1/s: how fast the horizontal lead eases toward its target (also how fast it swings over on a reversal)
@export var camera_fall_start_speed: float = 320.0  # px/s: downward speed above which the camera looks down (about 6 tiles of free fall)
@export var camera_fall_gain: float = 0.2  # s: px of look-down per px/s of downward speed above the start speed
@export var camera_fall_max: float = 80.0  # px: the most the camera looks down (the view is 288 px tall at zoom 2.5)
@export var camera_fall_smoothing: float = 6.0  # 1/s: how fast the look-down eases toward its target, and back after the landing
const SURF_FRICTION_TILE_DATA := &"surf_friction"  # optional float custom-data layer on the ground TileSet: a tile's surf friction scale (0 or unset = 1)
const SURF_FRICTION_SCALE_MIN := 0.05  # clamp on any floor's scale (a scale of 0 would never stop the board)
const SURF_FRICTION_SCALE_MAX := 10.0
const SKIM_CATCH_DEPTH := 6.0  # px: a board whose feet are this far under the surface is still caught by the skim floor
const SKIM_WAKE_IMPULSE := 0.004  # like SWIM_WAKE_IMPULSE: px/s of surface kick per px/s of skim speed, each frame, behind the board
const SKIM_ON_SURFACE_TOLERANCE := 2.0  # px: feet this close to the liquid line, on the floor, count as standing on the skim floor
const SKIM_FLOOR_MASK_LAYER := 3  # physics layer of WaterBasin's skim floor; added to this body's mask in _ready()
var is_surfing: bool = false  # held state, same convention as is_hanging/is_swimming; owns the crouch collider while true
var _surf_speed: float = 0.0  # px/s along _surf_facing, on the ground (in the air the speed lives in _air_carry_vx)
var _surf_facing: float = 1.0  # locked at mounting
var _surf_belt_vx: float = 0.0  # a conveyor belt's horizontal speed under the board this frame (0 off belts and in the air); see _surf_move()
var _pending_launch_keeps_surf: bool = false  # the buffered launch came while surfing: apply it as a surf launch, see launch()
var _surf_shoved_bodies: Dictionary = {}  # instance id -> {"body", "touched", "age"}: bodies the surf shoved (surf_shoved()), each with a collision exception held until the player's collider has overlapped it and then cleared it (or SURF_SHOVE_GIVE_UP seconds pass without ever touching)
const SURF_SHOVE_FOOT_CLEARANCE := 3.0  # px trimmed off the bottom of the shove test box: a block under the board's feet (riding it, or landing on it) is a floor, never shoved
const SURF_SHOVE_GIVE_UP := 0.6  # seconds a shoved body may stay un-overlapped before its exception is dropped anyway (it moved away faster than the board)
const SURF_SHOVE_CLEAR_MARGIN := 1.0  # px the overlap test is grown by before an exception is dropped, so the body isn't released while still touching
var _surf_prev_velocity: Vector2 = Vector2.ZERO  # the velocity the surf applied last frame (before move_and_slide() changed it): the launch and landing read it
var _surf_tilt_sign: int = 0  # the board's target tilt this frame, nose-up positive: +1 up, -1 down, 0 level (from left/right relative to the facing)
var _surf_board_angle: float = 0.0  # the drawn board's current tilt in degrees, nose-up positive; eases to the target
var _surf_air_time: float = 0.0  # s airborne on the current air carry (reset on leaving the ground, read and cleared at touchdown)
var _surf_bowl_chain: int = 0  # enemies bowled in the current chain (0 = none)
var _surf_bowl_chain_timer: float = 0.0  # s left to continue the chain (counts down while surfing)
var _surf_skim_distance: float = 0.0  # px skimmed since the last skim award, kept for the whole run
var _surf_jump_pending: bool = false  # a jump was consumed this frame: _surf_move() applies it together with the launch bias
var _surf_loop  # Audio.LoopPlayer: the board on the ground; silent in the air
var _surf_loop_base_db: float = 0.0  # the loop's volume at full level, including Audio's per-id tuning
var _surf_water_loop  # Audio.LoopPlayer: the board skimming a basin; silent otherwise
var _surf_water_loop_base_db: float = 0.0
var _surf_wetness: float = 0.0  # 0..1: how wet the floor under the board has been lately (instant rise, linear decay over surf_wet_decay_time)
var _surf_on_skim: bool = false  # standing on a basin's skim floor (set by _update_surf_wetness())
var _surf_steam_lift: float = 0.0  # 0..1: the steam under the board lately, as smoothed by WaterManager.get_steam_lift() (instant rise, linear decay); 0 whenever the surf isn't running
var _surf_steam_loop  # Audio.LoopPlayer: steam lifting the board; its volume follows the lift, silent without it
var _surf_steam_loop_base_db: float = 0.0
var _skim_basin: WaterBasin = null  # the basin whose skim floor is up for this surfer, or null
var _skim_was_on: bool = false  # on the skim floor last frame (the splash fires on the edge)
var surf_board: Node2D  # the separate board sprite (SurfBoard in player.tscn); stage 2 tilts it
# --- rail hang (HangStyle.RAIL): hanging from a Path2D in group "grab_rail" (see Rail hang in docs/player.md) ---
@export var rail_grab_radius: float = 6.0  # px: the hand catches a rail within this distance (widened by the frame's fall step so a fast fall can't tunnel past)
@export var rail_flat_degrees: float = 10.0  # a rail flatter than this is brachiated along (left/right travel); steeper is slid down with the hang sprite
@export var rail_max_grab_degrees: float = 80.0  # a rail steeper than this (a wall) is not grabbable
@export var rail_slide_gravity_scale: float = 0.6  # multiplies gravity along the rail's tangent while sliding
@export var rail_slide_max_speed: float = 220.0  # px/s cap on the slide
@export var rail_flat_friction: float = 600.0  # px/s^2 that slide speed decays by on a flat stretch (so sliding off a slope onto the flat coasts to a stop)
@export var rail_catch_momentum: float = 0.5  # fraction of the speed along the tangent kept when catching a sloped rail
@export var rail_grip_drop: float = 0.0  # px the hand sits below the rail's centre line
var hang_rail: Path2D  # the rail a RAIL hang is on; only meaningful while is_hanging and hang_style == RAIL
var _rail_offset: float = 0.0  # distance along hang_rail's baked curve, px
var _rail_speed: float = 0.0  # signed px/s along the curve (toward increasing offset is positive); slide and flat-coast speed
var _rail_jumped_off: bool = false  # jumped (or was thrown) off a rail: no catch until the fall begins, so the rise cannot re-grab

@export var catwalk_hang_probe_range: float = 8.0
	# how far above the hand the straight-up probe reaches looking for a catwalk's underside.
	# Raycasts ignore one_way_collision (that flag only affects body-vs-body resolution), so this
	# can see a catwalk's underside even though the player's own body physically passed through it.
	# Keep this SMALL — it's not a "reach," it's a near-miss tolerance for a jump that actually got
	# close to (or passed through) the tile. Too generous and it grabs jumps that never came near the
	# catwalk at all: with jump_velocity/gravity's defaults, a standing jump's apex is only ~32px, and
	# the old default of 20px let anything cresting within 20px of the underside grab it regardless of
	# whether it ever touched the tile — more than half the jump's whole height. 8px is a starting
	# retune, not a verified value; lower it further if standing jumps still snap onto catwalks they
	# shouldn't reach.
@export var catwalk_hang_min_fall_speed: float = 0.0  # velocity.y must exceed this to grab — mirrors
	# hang_min_fall_speed above: only grabs descending ("on the way down"), never on the way up
	# through the catwalk, so jumping through to land on top still works exactly as before.
@export var crust_hang_lift: float = 3.0
	# roadmap 6.1: extra px a hang from a basin's CRUST is anchored higher than a catwalk's, so the hands meet the
	# crust's drawn underside (its collision bottom sits a few px above the art's). In-editor tuned; applies to the
	# grab and everything after it (brachiating keeps the anchor's y), and _crust_mantle_target() works from the crust's
	# collision top, so a mantle still ends with the feet on the top face.
@export var catwalk_hang_grip_drop: float = 1.0
	# how far BELOW the detected underside surface the hand anchors, so the sprite doesn't clip up
	# into the tile — the mirror of hang_grip_lift above, in the opposite direction since this grips
	# from underneath rather than from on top.
@export var catwalk_thickness: float = 4.0
	# vertical distance from a catwalk's TOP (walkable) surface to its UNDERSIDE. The airborne
	# underside grab (_compute_catwalk_probe(), an upward ray) naturally hits the underside; the
	# crouch+jump climb-down (_compute_catwalk_feet_probe(), a downward ray from the feet) naturally
	# hits the TOP surface instead, since that's what the feet are resting on. Left uncorrected the
	# two entry points anchored the hang at two different y's — the "climbing down lands higher than
	# jumping into it" bug — so this converts the climb-down's top-face hit into the same underside y
	# the airborne grab uses. Starting guess is a 16px tile; retune to match the actual catwalk art/
	# collision height in-editor, the same way every other catwalk_* export here was tuned.
@export var catwalk_mantle_offset: Vector2 = Vector2(0.0, -13.1)
	# where the player's origin ends up standing once mantling UP through the catwalk onto its top,
	# relative to hang_anchor (the underside grip point) — start here and tune in-editor the same
	# hands-on way mantle_offset above was tuned. No facing multiplier: unlike the ledge mantle,
	# this isn't a sideways move around a wall corner, so it stays x-symmetric.
@export var catwalk_climb_down_skip_end_frames: int = 5
	# How many frames at the very END of "climb_up" (counting in its normal, forward, mantling-UP
	# order) to leave out when _begin_catwalk_climb_down() plays it backward. climb_up's tail is the
	# legs settling/straightening up after the mantle lands on top of the catwalk — there's no
	# matching motion to reverse INTO for a climb-down, which starts already standing there, so
	# those trailing frames would just be dead motion at the start of the reversed clip. 0 plays the
	# whole animation backward; raise it (in-editor, watching the reversed clip) until playback
	# starts right at "mid-descent" instead of "still finishing the landing."
@export var catwalk_brachiate_speed: float = 100.0
	# px/s the player travels hand-over-hand while brachiating along a catwalk's underside.
	# Deliberately its own export rather than reusing `speed`: this is an overhead traverse, not
	# ground movement, and the two will likely want to be tuned independently once there's an
	# actual catwalk long enough to try it on.
@export var catwalk_brachiate_floor_tolerance: float = 1.0
	# px the feet are raised for the brachiate's floor test (_brachiate_blocked_at()), so a hang whose feet rest exactly on
	# a flat floor or seabed is not read as overlapping it. A slope rising into the body still blocks, 1 px later per px.
var _brachiate_clearance_shape := RectangleShape2D.new()  # reused by _brachiate_blocked_at(); resized per call
var _debug_catwalk_probe: Dictionary = {}  # cached each physics frame for _draw(); empty until first computed

# --- audio (see scripts/audio.gd) ---
# Sounds tied to a specific animation frame: {animation: {frame: sound id}}. The frame numbers are
# a starting guess — open each animation in the SpriteFrames panel and set them to the frames where
# a foot actually lands. Ids with no sound file yet are skipped silently (Audio.PLANNED).
const FRAME_SOUNDS := {
	&"run": {1: &"player/footstep", 4: &"player/footstep"},
	&"climb": {0: &"player/climb_step", 2: &"player/climb_step"},
	&"sneak": {0: &"player/sneak_step", 4: &"player/sneak_step"},  # indices into the 8-entry ping-pong list (0 1 2 3 4 3 2 1)
}
@export var land_min_fall_speed: float = 120.0  # px/s: slower touchdowns (tiny hops, slope steps) make no landing sound
@export var land_full_volume_fall_speed: float = 400.0  # px/s: at or above this the landing plays at full volume
@export var land_quiet_volume_db: float = -12.0  # volume at land_min_fall_speed; scales up linearly from here
var _was_on_floor: bool = true
var _peak_fall_speed: float = 0.0  # fastest downward speed since leaving the floor; move_and_slide() zeroes velocity.y on impact, so it's tracked separately

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var standing_shape: Shape2D = collision_shape.shape  # capture the original at ready-time
@onready var kick_hitbox: Area2D = $KickHitbox
@onready var kick_hitbox_shape: CollisionShape2D = $KickHitbox/CollisionShape2D
const KICK_DAMAGE: int = 1  # dealt to anything with take_damage(amount) -> int that KickHitbox touches

# The offset that actually places KickHitbox to the player's right lives on its child
# CollisionShape2D's position (RectangleShape2D, so mirroring the position alone is enough — unlike
# the drillbot's ConvexPolygonShape2D, there's no asymmetric polygon here to re-mirror per-point).
# Captured once in _ready() (the scene is authored facing right, flip_h == false), then re-applied
# by _update_kick_hitbox_facing() every time sprite.flip_h changes, the same "mirror around local
# x = 0" idea used for the Drillbot's DrillHazard.
var _base_kick_hitbox_x: float
@onready var camera: Camera2D = $Camera2D
enum CuePhase { NONE, PAN, HOLD, RETURN }
var _lead_offset: Vector2 = Vector2.ZERO  # the eased camera lead and look-down; camera.offset follows it unless a cue plays
var _cue_phase: CuePhase = CuePhase.NONE
var _cue_time: float = 0.0  # seconds into the current phase
var _cue_target: Variant = null  # Vector2 or Node2D
var _cue_point_last: Vector2 = Vector2.ZERO
var _cue_source: Object = null
var _cue_pan_time: float = 0.6
var _cue_hold_time: float = 1.5
var _cue_return_time: float = 0.6
var _cue_ease: StringName = &"sine"
var _cue_from: Vector2 = Vector2.ZERO  # the offset the current phase eases from

func _update_kick_hitbox_facing() -> void:
	kick_hitbox_shape.position.x = -_base_kick_hitbox_x if sprite.flip_h else _base_kick_hitbox_x

func _reset_teleport_interpolation() -> void:
	# reset_physics_interpolation() only clears the CACHING node's own cached
	# previous/current transform — it does not propagate to children. Camera2D is a
	# child of Player, so when Player's global_position is hard-teleported, the
	# camera's global transform jumps too even though its *local* transform never
	# changed — but the camera's own interpolation state still holds the pre-teleport
	# global transform, so it blends across the jump for one rendered frame regardless
	# of resetting the player. That's the "world jumps toward the player and snaps
	# back" glitch. Fix: reset both nodes on every hard teleport.
	reset_physics_interpolation()
	if camera:
		camera.reset_physics_interpolation()

## Camera lead, in idle time so it is smooth at the display's rate (the offset isn't physics-interpolated). The camera
## looks ahead of fast horizontal travel (above `camera_lead_start_speed`, so walking never moves it) and down during a
## fast fall (above `camera_fall_start_speed`), easing both back as the speed drops. Reads the velocity the last physics
## step left; a wall hit zeroes it and the lead eases out. Dead or dancing: eases back to centre. The eased lead and
## look-down live in `_lead_offset`; `camera.offset` is that, or, while a camera cue plays, the cue's offset (below).
func _process(delta: float) -> void:
	_update_camera_lead(delta)

func _update_camera_lead(delta: float) -> void:
	if camera == null:
		return
	var target := Vector2.ZERO
	if not is_dead and not is_dancing:
		var lead := clampf((absf(velocity.x) - camera_lead_start_speed) * camera_lead_gain, 0.0, camera_lead_max)
		target.x = lead * signf(velocity.x)
		target.y = clampf((velocity.y - camera_fall_start_speed) * camera_fall_gain, 0.0, camera_fall_max)
	_lead_offset.x = lerpf(_lead_offset.x, target.x, 1.0 - exp(-camera_lead_smoothing * delta))
	_lead_offset.y = lerpf(_lead_offset.y, target.y, 1.0 - exp(-camera_fall_smoothing * delta))
	camera.offset = _cue_offset(delta) if _cue_phase != CuePhase.NONE else _lead_offset

# --- camera cue ----------------------------------------------------------------------------
# A cue pans the camera to a world point, holds, and returns (see Camera cue under Power). Public entry:
# show_cue(target, params). It is a timer-driven state advanced in `_process()` (idle time, so pause freezes it),
# not a Tween. It ends early only through `_end_cue()`, called from take_hit() (every damaging hit, death
# included) and start_dance(); it is NOT in `_interrupt_current_action()`, which a jump pad launch and a stomp
# bounce share, and those leave a cue playing. respawn_at() cancels it outright.

## Pans the camera onto `target` (a Vector2 world point, or a Node2D whose `global_position` is read every frame,
## so a cue parented to a moving platform tracks it), holds, and eases back to the player. `params` keys, all
## optional: `pan_time` (0.6 s), `hold_time` (1.5), `return_time` (0.6), `ease` (`&"linear"`, `&"sine"` (default) or
## `&"cubic"`), `source` (an Object handed back through `cue_ended`). A cue shown while another plays replaces it:
## the pan starts from the camera's current offset and the hold restarts; cues are never queued. Ignored while dead
## or dancing. No input is locked: the player can move, and be hit, while the camera is elsewhere.
func show_cue(target: Variant, params: Dictionary = {}) -> void:
	if camera == null or is_dead or is_dancing:
		return
	var is_point := typeof(target) == TYPE_VECTOR2
	if not is_point and not (is_instance_valid(target) and target is Node2D):
		return
	if _cue_phase != CuePhase.NONE:
		_finish_cue()  # replaced: the old source's cue has ended
	_cue_target = target
	_cue_source = params.get("source", null)
	_cue_pan_time = maxf(float(params.get("pan_time", 0.6)), 0.0)
	_cue_hold_time = maxf(float(params.get("hold_time", 1.5)), 0.0)
	_cue_return_time = maxf(float(params.get("return_time", 0.6)), 0.0)
	_cue_ease = StringName(params.get("ease", &"sine"))
	_cue_point_last = target if is_point else (target as Node2D).global_position
	_cue_from = camera.offset  # from wherever the camera is now, lead and look-down included
	_cue_time = 0.0
	_cue_phase = CuePhase.PAN

## True while a cue is panning, holding or returning.
func is_cue_playing() -> bool:
	return _cue_phase != CuePhase.NONE

## Ends the cue early: the camera eases back from where it is over the cue's `return_time`. No-op without a cue.
func _end_cue() -> void:
	if _cue_phase == CuePhase.NONE or _cue_phase == CuePhase.RETURN:
		return
	_cue_from = camera.offset
	_cue_time = 0.0
	_cue_phase = CuePhase.RETURN

## Drops the cue at once (a hard teleport), telling its source.
func _cancel_cue() -> void:
	if _cue_phase != CuePhase.NONE:
		_finish_cue()

func _finish_cue() -> void:
	var source := _cue_source
	_cue_phase = CuePhase.NONE
	_cue_target = null
	_cue_source = null
	cue_ended.emit(source)

## The cue point in world space; a freed node leaves the last known point.
func _cue_point() -> Vector2:
	if typeof(_cue_target) == TYPE_VECTOR2:
		_cue_point_last = _cue_target
	elif is_instance_valid(_cue_target):
		_cue_point_last = (_cue_target as Node2D).global_position
	return _cue_point_last

## Advances the cue by `delta` and returns the camera offset for this frame. The camera has no limits or smoothing
## node, so its view centre is its own position plus `offset`: the offset that centres the cue point is the point
## relative to the camera.
func _cue_offset(delta: float) -> Vector2:
	var aim := _cue_point() - camera.global_position
	_cue_time += delta
	match _cue_phase:
		CuePhase.PAN:
			if _cue_time >= _cue_pan_time:
				_cue_time = 0.0
				_cue_phase = CuePhase.HOLD
				return aim
			return _cue_from.lerp(aim, _cue_curve(_cue_time / _cue_pan_time))
		CuePhase.HOLD:
			if _cue_time >= _cue_hold_time:
				_cue_from = aim
				_cue_time = 0.0
				_cue_phase = CuePhase.RETURN
			return aim
		CuePhase.RETURN:
			if _cue_time >= _cue_return_time:
				_finish_cue()
				return _lead_offset
			return _cue_from.lerp(_lead_offset, _cue_curve(_cue_time / _cue_return_time))
	return _lead_offset

func _cue_curve(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	match _cue_ease:
		&"linear":
			return t
		&"cubic":
			return 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0
	return 0.5 - 0.5 * cos(PI * t)  # sine in-out, the default

func _ready() -> void:
	if camera != null:
		_lead_offset = camera.offset
	floor_snap_length = slope_snap_length
	health = max_health
	add_to_group("player")
	add_to_group("saveable")
	_count_gems.call_deferred()

	crouch_shape = _make_crouch_shape(standing_shape)
	if crouch_shape != null:
		crouch_offset_y = (_shape_height(standing_shape) - _shape_height(crouch_shape)) * 0.5
	else:
		push_warning("Crouch supports RectangleShape2D and CapsuleShape2D colliders only — crouching is disabled")
	swim_shape_bulge_x = (_shape_height(standing_shape) - _shape_width(standing_shape)) * 0.5
		# half the difference between standing_shape's own height and width: exactly how far EACH
		# side bulges outward once _set_swim_collider() rotates it 90 degrees (the unrotated height
		# becomes the new world-space width). Zero, and harmless, for a shape as wide as it is tall.
		# A negative result (a shape wider than it is tall to begin with) would mean swimming makes
		# the collider NARROWER, not wider — _set_swim_collider() below handles that sign correctly
		# too, since it's just "how far the touched edge needs to move to stay put."
	
	sprite.animation_finished.connect(_on_animation_finished)
	sprite.frame_changed.connect(_on_sprite_frame_changed)
	kick_hitbox.body_entered.connect(_on_kick_hitbox_body_entered)

	_base_kick_hitbox_x = kick_hitbox_shape.position.x
	_update_kick_hitbox_facing()

	# Hit twice already (Crouch, Kick): a one-shot animation left with Loop ON never fires
	# animation_finished, which here would leave the player stuck in HURT forever (or the death
	# animation looping instead of holding its last frame). Fail loudly instead of silently.
	# "dance" is checked for existence too, but NOT for Loop, since — unlike hurt/dead — dance
	# doesn't drive anything off animation_finished (is_dancing is terminal the moment it's set,
	# same as is_dead); Loop ON is actually the more natural choice here (a victory dance that
	# keeps dancing rather than freezing mid-pose) and won't cause a softlock either way.
	for anim_name in ["hurt", "dead"]:
		if not sprite.sprite_frames.has_animation(anim_name):
			push_warning("No '%s' animation in SpriteFrames — taking a hit will not display correctly" % anim_name)
		elif sprite.sprite_frames.get_animation_loop(anim_name):
			push_warning("'%s' animation has Loop enabled — turn it off in the SpriteFrames panel" % anim_name)
	if not sprite.sprite_frames.has_animation("dance"):
		push_warning("No 'dance' animation in SpriteFrames — winning will not display correctly")
	
	world_tilemap = get_tree().get_first_node_in_group("world_tilemap")
	if world_tilemap == null:
		push_warning("No TileMapLayer found in group 'world_tilemap' — hanging will not work")
	if get_tree().get_first_node_in_group("ladder_tilemap") == null:
		push_warning("No TileMapLayer found in group 'ladder_tilemap' — climbing will not work")
	water_manager = get_tree().get_first_node_in_group("water_manager")
	surf_board = get_node_or_null("SurfBoard") as Node2D
	if surf_board != null:
		surf_board.visible = false
	_surf_loop = Audio.make_loop(&"player/surf_loop")
	_surf_loop_base_db = _surf_loop.volume_db
	add_child(_surf_loop)
	_surf_water_loop = Audio.make_loop(&"player/surf_water_loop")
	_surf_water_loop_base_db = _surf_water_loop.volume_db
	add_child(_surf_water_loop)
	_surf_steam_loop = Audio.make_loop(&"player/surf_steam_loop")
	_surf_steam_loop_base_db = _surf_steam_loop.volume_db
	add_child(_surf_steam_loop)
	set_collision_mask_value(SKIM_FLOOR_MASK_LAYER, true)  # a basin's skim floor (only exists while a surfer is over it)

func _physics_process(delta: float) -> void:
	_update_hurt_invincibility(delta)
	_update_surf_shove_exceptions(delta)  # runs in every state: the surf may have ended while a shoved block still overlaps
	_update_crust_pass()  # runs in every state: a hit mid-pass must still clear the exception once the body is out of the crust
	_update_chill(delta)  # runs in every state, so the chill fades while hurt or hanging too

	# Hurt, dead, and dance all get the same minimal branch instead of being threaded through the
	# normal flow: everything below (jump buffer, crouch, climb...) runs on raw input every
	# frame, so the simplest way to guarantee the player has no control is to not reach any of it.
	if is_dead or is_dancing or one_shot_action == OneShotAction.HURT:
		_process_incapacitated(delta)
		return

	var input_dir := Input.get_axis("move_left", "move_right")

	# Ladder up/down as seen by everything below: a key that ended a climb at a landing is ignored
	# until released (see climb_up_latched), so the player stops there and can walk off.
	if climb_up_latched and not Input.is_action_pressed("climb_up"):
		climb_up_latched = false
	if climb_down_latched and not Input.is_action_pressed("crouch"):
		climb_down_latched = false
	var up_pressed := Input.is_action_pressed("climb_up") and not climb_up_latched
	var down_pressed := Input.is_action_pressed("crouch") and not climb_down_latched
	if is_surfing:
		up_pressed = false  # ladders (and the ladder mount from above) are suppressed while surfing,
		down_pressed = false  # and the surf owns the crouch collider, so down does nothing

	# Ladder membership = ANY part of the collider overlapping a ladder tile (not just the origin's
	# cell), so a ladder whose top is flush with a walking surface stays grabbed until the feet reach
	# that surface. Reaching a floor the ladder passes through while climbing up is handled by the
	# landing branch below (_ascending_landing_y); climbing down, the one-way tile physically catches
	# the feet and the floor-exit clause ends the climb.
	var ladder_cell := _ladder_cell_overlapping()
	var on_ladder := ladder_cell != Vector2i.MAX

	# Brachiating under a catwalk with a ladder running through the same cell (ladders share the
	# catwalk's cell, passing through it — see the Ladders-on-their-own-layer note): pressing up or
	# down hands off from the catwalk hang straight into the ladder mechanic instead of continuing to
	# traverse. Cleared here, before wants_climb_here below, for two reasons: so wants_climb's `not
	# is_hanging` guard doesn't block the hand-off this same frame, and so it can bypass
	# wants_climb_here's `not is_on_floor()` guard on down — that guard exists to stop a GROUNDED
	# player's held down from re-grabbing a ladder instead of crouching, which doesn't apply to a
	# hanging player, and is_on_floor() would read a stale value here anyway (frozen at whatever it
	# was before the hang started, since a hang skips move_and_slide() entirely).
	var wants_ladder_handoff := is_hanging and hang_style == HangStyle.CATWALK_UNDER and one_shot_action == OneShotAction.NONE and on_ladder and (up_pressed or down_pressed)
	if wants_ladder_handoff:
		is_hanging = false
		hang_style = HangStyle.LEDGE
		hang_platform = null

	# Mounting from above: standing on a surface with a ladder continuing through/below the feet. It
	# needs its own probe because standing there doesn't overlap that part of the ladder. Deliberately
	# NOT gated on on_ladder: on a floor the ladder passes through (a ladder spanning two floors),
	# the collider also overlaps the ladder ABOVE the surface, so on_ladder is true and gating on
	# "not on_ladder" made down crouch instead of descending. Down only — pressing up while standing
	# over a ladder's top shouldn't do anything (up at such a lower floor still climbs the part above).
	var mount_cell := Vector2i.MAX
	if down_pressed:
		mount_cell = _ladder_cell_under_feet()
	var can_mount_from_above := mount_cell != Vector2i.MAX

	# Ordinary entry from the side/bottom/mid-air. Down only grabs the ladder while airborne: on the
	# ground, down means crouch (otherwise standing at a ladder's base and holding down flipped
	# climb/crouch every frame, since the floor check below kicks you straight back off).
	var wants_climb_here := on_ladder and (up_pressed or (down_pressed and not is_on_floor()) or wants_ladder_handoff)
	var wants_climb := (wants_climb_here or can_mount_from_above) and one_shot_action == OneShotAction.NONE and not is_hanging

	# climbing UP through a floor the ladder passes through: is the feet's landing point here?
	var landing_y := INF
	if is_climbing and up_pressed and not down_pressed:
		landing_y = _ascending_landing_y()

	if wants_climb and not is_climbing:
		is_climbing = true
		# snap the player's x to the ladder tile's center column
		var snap_cell: Vector2i = mount_cell if can_mount_from_above else ladder_cell
		var snap_layer: TileMapLayer = _ladder_mount_layer if can_mount_from_above else _ladder_hit_layer
		global_position.x = snap_layer.to_global(snap_layer.map_to_local(snap_cell)).x
		if can_mount_from_above:
			global_position.y += ladder_mount_sink  # see ladder_mount_sink: lets the collider pass down through a one-way surface
		elif is_on_floor():
			# Mounting upward from a floor. A tile whose collider top sits below its cell top (the trim-depth
			# look) leaves the feet inside the floor's cell, which _ascending_landing_y() reads as "just
			# climbed up onto this floor" and ends the climb on the next frame. Lift the feet to just above
			# the surface, where that landing would have put them, so the climb starts clear of it.
			var floor_top := _ascending_landing_y()
			if floor_top != INF:
				var feet := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5
				global_position.y += (floor_top - 0.5) - feet
		_reset_teleport_interpolation()  # same reasoning as the hang-grab teleport below: a hard
			# position snap, not continuous motion — a couple of pixels, easy to miss, but the same
			# one-frame interpolation flash is possible if Physics Interpolation is on
	elif is_climbing and landing_y != INF:
		# Stop on the landing: put the feet on the floor's surface (a hair above it, so the next
		# climb-up from here doesn't count as arriving at it again) and let go. The latch keeps the
		# still-held up key from re-grabbing the ladder straight away.
		var feet_y := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5
		global_position.y += (landing_y - 0.5) - feet_y
		velocity.y = 0.0
		is_climbing = false
		climb_up_latched = true
		up_pressed = false
		_reset_teleport_interpolation()
	elif is_climbing and (not on_ladder or is_on_floor()):
		if is_on_floor() and down_pressed:
			# climbed down onto a landing/floor with down still held: stop here (no crouch, no
			# re-mount) until down is released
			climb_down_latched = true
			down_pressed = false
		is_climbing = false  # climbed off the top/bottom/side of the ladder

	if is_climbing:
		var climb_input := 0.0
		if Input.is_action_pressed("climb_up"):
			climb_input -= 1.0
		if Input.is_action_pressed("crouch"):
			climb_input += 1.0
		velocity.y = climb_input * climb_speed
		velocity.x = 0.0

		if climb_input != 0.0:
			if sprite.animation != "climb" or sprite.is_playing() == false:
				sprite.play("climb")
		else:
			sprite.pause()

		if Input.is_action_just_pressed("jump"):
			is_climbing = false
			velocity.y = jump_velocity
			Audio.play(&"player/jump")
	elif is_hanging:
		_follow_hang_platform()  # before input handling, so _begin_mantle() below starts from the up-to-date position
		velocity = Vector2.ZERO
		if is_hanging and one_shot_action == OneShotAction.NONE:  # is_hanging: the follow above may have just force-released it
			if hang_style == HangStyle.SWING:
				_update_swing_hang(input_dir)  # push with left/right, crouch drops off, jump jumps off; up does nothing
			elif hang_style == HangStyle.RAIL:
				_update_rail_hang(input_dir, delta)  # brachiate (flat) or slide (sloped); crouch drops, jump jumps and can re-catch on the way down
			elif hang_style == HangStyle.CATWALK_UNDER and _hang_crust_blocked():
				is_hanging = false  # liquid rose into the space under the crust (roadmap 6.1): let go and fall
				hang_lockout_timer = hang_regrab_lockout
			elif Input.is_action_just_pressed("crouch"):
				is_hanging = false  # let go, drop into a fall
				hang_lockout_timer = hang_regrab_lockout
			elif Input.is_action_just_pressed("jump"):
				is_hanging = false
				if hang_style == HangStyle.LEDGE:
					# a ledge jump pushes away from the wall
					hang_lockout_timer = hang_regrab_lockout
					velocity.y = jump_velocity
					velocity.x = -hang_facing * speed
					Audio.play(&"player/jump")
				else:
					_jump_up_through_underside()  # catwalk or crust: jump up through it, as a rail hang's jump leaves the rail
			elif Input.is_action_just_pressed("climb_up") or (hang_style == HangStyle.LEDGE and Input.is_action_just_pressed("move_right" if hang_facing > 0.0 else "move_left")):
				_begin_mantle()  # a ledge hang also mantles on a fresh press toward the wall; holding it through the grab does not
			elif hang_style == HangStyle.CATWALK_UNDER:
				_update_brachiate(input_dir, delta)
	elif is_swimming:
		# Phase 8.2: vertical axis reuses the same climb_up/crouch pair the ladder already reads
		# (per the design notes' own instruction to check for an existing vertical axis before adding
		# a new one) — "jump" is folded in as an additional up-source rather than triggering a normal
		# jump_velocity launch, per the design notes' "jump becomes swim up and breach the surface"
		# call. Direct velocity.y control while either is held (same convention as climbing), at
		# swim_up_speed going up and swim_speed going down — split into two exports after in-editor
		# testing found one shared speed too fast on the way up (see swim_up_speed's own comment). With
		# nothing held (or both held, canceling out), velocity.y instead eases toward swim_sink_speed
		# at swim_gravity's rate (see both exports' own comments for why it's move_toward() and not a
		# plain accumulation).
		var swim_up := Input.is_action_pressed("climb_up") or Input.is_action_pressed("jump")
		var swim_down := Input.is_action_pressed("crouch")
		var swim_chill := _chill_scale()  # chilled swimming is slower both ways (the passive sink is left alone)
		if swim_up and not swim_down:
			velocity.y = -swim_up_speed * swim_chill
		elif swim_down and not swim_up:
			velocity.y = swim_speed * swim_chill
		else:
			# nothing held, or up+down cancel each other out (same as the original swim_input == 0
			# case) — either way, ease toward the passive sink target.
			velocity.y = move_toward(velocity.y, _swim_passive_target(), swim_gravity * delta)
		velocity.x = input_dir * swim_speed * swim_chill
	else:
		# --- gravity ---
		if not is_on_floor():
			velocity.y += gravity * delta
		else:
			velocity.y = 0.0
	
	# --- coyote timer: counts down after leaving the floor ---
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		coyote_timer -= delta

	# --- airborne timer: counts UP while off the floor, resets on landing (see hang_min_airborne_time) ---
	if is_on_floor():
		time_since_airborne = 0.0
	else:
		time_since_airborne += delta

	# --- delayed fall animation after mantling (see _finish_mantle / post_mantle_fall_anim_delay) ---
	if fall_anim_delay_timer > 0.0:
		fall_anim_delay_timer -= delta
		if fall_anim_delay_timer <= 0.0 and state == State.FALL:
			sprite.play("fall")

	# --- jump buffer: counts down after pressing jump ---
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer -= delta

	# --- catwalk climb-down: crouch + jump while standing on a catwalk climbs straight down into
	# a catwalk hang on the surface underfoot, instead of the ordinary crouch-jump the buffered
	# jump below would otherwise fire. Checked here, ahead of that application, so it takes
	# priority for this same press; the buffered jump's velocity write is guarded with
	# `not is_hanging` below, which is what actually stops both from firing off one press instead
	# of just being a same-frame ordering accident. Deliberately keyed off "jump", not "down" — the
	# ladder-mount-from-above probe earlier in this function is keyed off down being held, so a
	# ladder sharing the same catwalk cell never interacts with this at all.
	if is_crouching and not is_surfing and is_on_floor() and one_shot_action == OneShotAction.NONE and hang_lockout_timer <= 0.0 and Input.is_action_just_pressed("jump"):
		_try_climb_down_to_catwalk_hang()

	# --- consume a buffered jump if coyote time still allows it ---
	if _skip_buffered_jump:
		_skip_buffered_jump = false
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
	elif jump_buffer_timer > 0.0 and coyote_timer > 0.0 and not is_hanging and not is_swimming:
		if is_surfing:
			_surf_jump_pending = true  # _surf_move() applies it: the board's own velocity (a slope's tangent) + the launch bias + jump_velocity * surf_jump_boost
		else:
			velocity.y = jump_velocity
		Audio.play(&"player/jump")
		jump_buffer_timer = 0.0
		coyote_timer = 0.0

	# --- surf: kick while crouching on the floor mounts the board, kick while surfing dismounts ---
	var kick_handled := false  # this press mounted or dismounted the board: it is not also a kick
	if Input.is_action_just_pressed("kick"):
		if is_surfing:
			_end_surf(true)
			kick_handled = true
		elif is_crouching and is_on_floor() and one_shot_action == OneShotAction.NONE and not is_climbing and not is_hanging and not is_swimming:
			_start_surf()
			kick_handled = true

	# --- kick ---
	if Input.is_action_just_pressed("kick") and is_on_floor() and one_shot_action == OneShotAction.NONE and not is_crouching and not is_swimming:
		one_shot_action = OneShotAction.KICKING
		_air_kick = false
		velocity.x = 0.0
		sprite.play("kick")
		Audio.play(&"player/kick")
		kick_hitbox.monitoring = true
	elif Input.is_action_just_pressed("kick") and not kick_handled and not is_on_floor() and one_shot_action == OneShotAction.NONE and not is_crouching and not is_climbing and not is_hanging and not is_swimming and not is_surfing:
		_start_air_kick()
	
	hang_lockout_timer -= delta

	# --- crouch ---
	var wants_crouch := crouch_shape != null and ((down_pressed and is_on_floor()) or is_surfing) and one_shot_action != OneShotAction.KICKING and not is_climbing and not is_hanging and not is_swimming  # is_surfing: the surf keeps the crouch collider in the air too
	# (not is_climbing: on the frame a from-above mount starts, is_on_floor() is still true from the
	# previous frame, so without this the same held down key would also start a crouch. not
	# is_hanging: the catwalk climb-down above can uncrouch and start a hang earlier in this same
	# frame, at which point is_on_floor() is still stale-true too — without this, a still-held
	# crouch key would immediately re-crouch the player it just uncrouched for the hang. not
	# is_swimming: down is also the swim-down input, and a shallow-enough basin floor has
	# is_on_floor() true while still fully submerged — without this, holding down to swim downward
	# once resting on the floor started a crouch instead. Worse than a cosmetic clash: releasing down
	# again ends the crouch through the normal UNCROUCHING one-shot, and that one-shot's own
	# animation-finished handler picks the next state/animation from is_on_floor()/velocity.y alone
	# with no is_swimming check at all, so it stomps state back to IDLE/RUN/FALL and the sprite off
	# "swim" — is_swimming itself stays true (physics/gravity/controls are unaffected), but the state
	# and animation desync from it and don't resync until an actual exit+re-entry retriggers the
	# is_swimming false→true edge that (re)plays "swim".)

	if wants_crouch and not is_crouching:
		is_crouching = true
		collision_shape.shape = crouch_shape
		collision_shape.position.y += crouch_offset_y
		sprite.play("crouch")
		Audio.play(&"player/crouch")
	elif not wants_crouch and is_crouching:
		if _can_stand_up():
			is_crouching = false
			one_shot_action = OneShotAction.UNCROUCHING
			collision_shape.shape = standing_shape
			collision_shape.position.y -= crouch_offset_y
			sprite.play("crouch", -1.0, sprite.animation == &"sneak")  # from the sneak clip a reverse would start at frame 0 and end at once: start from the held crouch frame
			Audio.play(&"player/crouch", -4.0)  # standing back up: same rustle, a bit softer

	# --- horizontal movement ---
	# On a slippery floor (ice) the player's own velocity builds and decays gradually instead of snapping
	# to input * speed. _slide_vx is that own velocity, kept apart from velocity.x because velocity.x
	# also gets the conveyor and water pushes added below each frame; it's refreshed from every branch
	# so stepping onto ice from a normal floor carries the momentum along.
	var chill_scale := _chill_scale()  # 1 unless chilled; walk and sneak speed follow it (a surf and a launch's carried momentum are exempt: they never read it)
	var walk_speed := speed * chill_scale
	var slippery := is_on_floor() and not is_climbing and not is_hanging and not is_swimming and _floor_is_slippery()
	if is_on_wall() and _slide_vx * get_wall_normal().x < 0.0 and not _walk_push_active:
		_slide_vx = 0.0  # ran into a wall: don't keep "sliding" into it and then take ages to reverse (a block that took last frame's push is not a wall)
	_walk_push_active = false
	if _air_carry_active and (is_on_floor() or is_climbing or is_hanging or is_swimming or (one_shot_action != OneShotAction.NONE and not (_air_kick and one_shot_action == OneShotAction.KICKING))):
		if is_surfing and is_on_floor():
			_surf_touchdown()  # landed on the board: the carried velocity becomes the ground surf speed again, and a clean landing pays out
		_air_carry_active = false  # landed, grabbed something or got into a one-shot: normal control again
	if is_climbing or is_hanging or is_swimming:
		pass  # velocity already fully set above; skip normal horizontal movement
	elif is_surfing:
		_surf_move(delta, input_dir)
	elif _air_carry_active:
		# Carried momentum (swing release, dismount): kept as is until landing. Input steers toward input * speed at
		# carry_air_accel, except that pushing the way you are already going faster than walk speed never slows you down.
		if _air_carry_steers and input_dir != 0.0 and not (signf(input_dir) == signf(_air_carry_vx) and absf(_air_carry_vx) > speed):
			_air_carry_vx = move_toward(_air_carry_vx, input_dir * speed, carry_air_accel * delta)
		velocity.x = _air_carry_vx
	elif is_crouching or one_shot_action == OneShotAction.UNCROUCHING or (one_shot_action == OneShotAction.KICKING and not _air_kick):
		# Crouched: creep at sneak_speed when left/right is held (_can_sneak()), otherwise rooted. The stand-up and the
		# ground kick stay rooted, except that a stand-up that starts in the air (sneaked off an edge) keeps the creep
		# velocity instead of stopping dead; a crouch-jump from a standstill has _slide_vx 0, so it is unchanged.
		var sneak_target := input_dir * sneak_speed * chill_scale if _can_sneak() else 0.0
		if one_shot_action == OneShotAction.UNCROUCHING and not is_on_floor():
			sneak_target = clampf(_slide_vx, -sneak_speed, sneak_speed)
		if slippery:
			var sneak_rate := ice_accel if sneak_target != 0.0 else ice_friction
			velocity.x = move_toward(clampf(_slide_vx, -speed, speed), sneak_target, sneak_rate * delta)
		else:
			velocity.x = sneak_target
	elif slippery:
		var rate := ice_accel if input_dir != 0.0 else ice_friction
		# capped at walk speed so momentum from anything faster doesn't turn into a 600px skate
		velocity.x = move_toward(clampf(_slide_vx, -speed, speed), input_dir * walk_speed, rate * delta)
	else:
		velocity.x = input_dir * walk_speed
	if _can_walk_push(input_dir):
		velocity.x = _walk_push_limited(velocity.x)  # a block that takes the push slows the walk to its own speed
	if not is_climbing and not is_hanging and not is_swimming:
		_slide_vx = velocity.x  # BEFORE the pushes below are added

	if is_on_floor() and not is_climbing and not is_hanging:
		velocity.x += _conveyor_push_speed()

	# --- water push: unlike the conveyor check above, deliberately NOT gated on is_on_floor() ------
	# A conveyor only pushes while standing in contact with it; water push is a radius query against
	# nearby particles regardless of contact, so it can shove the player while airborne too (falling
	# through a waterfall, say), not just while grounded. Still gated on climbing/hanging/swimming, same
	# reason as the conveyor: velocity.x is deliberately owned by those states elsewhere and isn't meant
	# to be nudged out from under them — a swimming player already owns velocity.x via its own input
	# handling above (Phase 8.3), so the ambient particle push shouldn't also be fighting it.
	if not is_climbing and not is_hanging and not is_swimming:
		velocity.x += _water_push_speed()

	# --- jump pads: apply a buffered launch last, overriding everything above ---------------------
	# See launch() below for why this is buffered instead of setting velocity directly there: a jump
	# pad's Area2D can fire mid physics-step, at an unpredictable point relative to this function's
	# own run for the frame. If it fires before this point, the "grounded -> velocity.y = 0" line in
	# the gravity branch above, and/or the input-driven "velocity.x = input_dir * speed" line just
	# above, would otherwise silently cancel the launch before move_and_slide() ever saw it — which
	# is exactly why walking onto a pad (grounded when the Area2D fires) didn't launch, while landing
	# on one from the air (already falling, so the gravity branch only adds to velocity.y instead of
	# zeroing it) did. Applying it here, after every other write to velocity this frame, means it
	# always wins regardless of call order.
	if _has_pending_launch:
		if _pending_launch_keeps_surf and is_surfing:
			_apply_surf_launch(_pending_launch)
		else:
			velocity = _pending_launch
			if absf(velocity.x) > 1.0:
				_begin_air_carry(velocity.x, true)  # else the input line above wipes the horizontal part next frame; steering and the walk-speed floor are the swing release's
		_has_pending_launch = false
		_pending_launch_keeps_surf = false

	if not is_hanging and not is_climbing and not is_swimming and not is_surfing:
		_unembed_from_crust()  # before the move: a body left inside crust can't be resolved by move_and_slide() (see the function)

	if not is_hanging:
		# move_and_slide() was previously called unconditionally here, including while hanging
		# (with velocity == Vector2.ZERO). That's the real cause of the "teleports into the tile,
		# then snaps back out" glitch, not physics interpolation: _try_grab_ledge() below writes
		# global_position straight to the analytic hang_anchor AFTER this frame's move_and_slide()
		# has already run, so that write never gets collision-resolved — if the anchor point puts
		# the CollisionShape2D even slightly overlapping the wall tile (plausible, since the grip
		# math is based on the sprite's hand pixel via hang_hand_local_offset/hang_grip_inset, not
		# the actual collision shape extents), the body sits embedded in the tile for that one
		# rendered frame. Next frame, move_and_slide() runs again — even at zero velocity it still
		# performs its built-in overlap/de-penetration recovery before applying velocity — and
		# silently shoves the body back out to a valid position. That's the "snaps back" frame.
		# While hanging, the body is pinned exactly where _start_hang() put it and has no reason to
		# be physics-resolved on any frame, so skip move_and_slide() entirely for the duration of
		# the hang (this also stops the pinned position from ever drifting on later frames due to
		# incidental overlap, not just the grab frame).
		_update_skim_floor()  # before the move: the floor has to be there for this frame's motion to meet it
		if is_surfing:
			_surf_bowl_sweep(delta)  # before the move, so a bowled body can't stop this frame's motion
		else:
			_try_step_up(delta)  # before the move: a wall of up to step_height is stepped onto instead of stopping the walk
		move_and_slide()
		_lead_rising_rigid_floor(delta)
		_update_skim_effects()
		if _air_carry_active and is_on_wall() and _air_carry_vx * get_wall_normal().x < 0.0:
			_air_carry_vx = 0.0  # ran into a wall with the carried momentum
		if is_surfing and is_on_floor() and is_on_wall() and _surf_facing * get_wall_normal().x < 0.0:
			_surf_speed = 0.0  # ran into a wall on the ground: the speed floor ends the surf next frame

	if input_dir != 0.0 and one_shot_action == OneShotAction.NONE and not is_hanging and not is_surfing:  # facing is locked while surfing
		sprite.flip_h = input_dir < 0.0
		_update_kick_hitbox_facing()
	_update_surf_board()

	# --- ledge-grab: checked every frame while touching a wall in the air and descending ---
	# (this deliberately differs from the original's OnCollisionEnter-only check — it's what lets you
	# jump up alongside a wall and grab a ledge that's above where you first made contact with it.
	# requiring velocity.y > hang_min_fall_speed means a jump that's about to clear the wall, still
	# rising, won't grab it — only a wall you're sliding down against will.) not is_swimming: matches
	# every other action already excluded while swimming (kick/crouch/water-push) — without it, a
	# grab could fire on the exact frame is_swimming is ABOUT to flip false (this check runs before
	# _update_swim_state() each frame, see the ordering comment above), using the still-wide, still-
	# rotated swim collider's geometry instead of the standing shape every hang constant is tuned for.
	# That's a timing coincidence (whether releasing up happens to swing velocity.y through zero on
	# the very same frame the depth threshold crosses), which is exactly why it read as flaky rather
	# than reliably broken: a grab one frame later, once the collider has reverted and been
	# wall-anchored, works; a grab caught mid-transition doesn't.
	if not is_climbing and not is_hanging and not is_swimming and not is_surfing and one_shot_action == OneShotAction.NONE and hang_lockout_timer <= 0.0 and not is_on_floor() and is_on_wall() and velocity.y > hang_min_fall_speed and time_since_airborne >= hang_min_airborne_time:
		_try_grab_ledge()

	# --- catwalk underside grab: same idea, but with NO wall requirement at all — this is what lets
	# a jump that doesn't quite clear a catwalk grab its underside on the way back down instead of
	# just falling straight through it. Independent of the ledge-grab check above (not an elif): if
	# that one already grabbed, is_hanging is true here and this is a no-op via the same guard.
	# not is_swimming for the same reason as the ledge-grab check above, even though a catwalk grab
	# has no wall geometry to get wrong — surfacing under a catwalk mid-swim shouldn't hang from it
	# before the swim collider has actually reverted either.
	if not is_climbing and not is_hanging and not is_swimming and not is_surfing and one_shot_action == OneShotAction.NONE and hang_lockout_timer <= 0.0 and not is_on_floor() and velocity.y > catwalk_hang_min_fall_speed and time_since_airborne >= hang_min_airborne_time:
		_try_grab_catwalk_underside()

	# --- swing grab: airborne, hand within a swing's grab radius of its bar. Same gates as the catwalk grab but no
	# velocity condition, so a jump can catch the bar on the way up too.
	if not is_climbing and not is_hanging and not is_swimming and one_shot_action == OneShotAction.NONE and hang_lockout_timer <= 0.0 and not is_on_floor() and time_since_airborne >= hang_min_airborne_time:
		_try_grab_swing()

	# --- rail grab: airborne, hand within reach of a grabbable rail. Catches on the way up too (a jump can reach a rail),
	# except right after jumping off one (_rail_jumped_off), when it waits for the fall.
	if not is_climbing and not is_hanging and not is_swimming and not is_surfing and one_shot_action == OneShotAction.NONE and hang_lockout_timer <= 0.0 and not is_on_floor():
		_try_grab_rail()

	_update_hang_debug_probes()
	_log_if_stuck(delta)
	_update_landing_sound()
	_update_swim_state()  # Phase 8.1: entry/exit detection only, after is_climbing/is_hanging are
		# both settled for this frame — see _update_swim_state()'s own comment for why it's gated on them.
	_poll_tile_hazards()  # roadmap 8.4: spike tiles, polled like the slag check above
	if is_dead or is_dancing:
		return  # slag and spikes call take_hit() above; a fatal hit there must not
			# fall through to the state decision below, which would replace "dead" with fall/idle.

	# --- decide state ---
	if is_climbing:
		if state != State.CLIMB:
			state = State.CLIMB
	elif is_hanging:
		if state != State.HANG:
			state = State.HANG
	elif is_swimming:
		if state != State.SWIM:
			state = State.SWIM
	elif one_shot_action == OneShotAction.NONE:
		var next_state: State
		if is_surfing:
			next_state = State.SURF
		elif is_crouching:
			next_state = State.SNEAK if (input_dir != 0.0 and _can_sneak()) else State.CROUCH
		elif not is_on_floor():
			next_state = State.JUMP if velocity.y < 0.0 else State.FALL
		else:
			next_state = State.RUN if input_dir != 0.0 else State.IDLE

		if next_state != state:
			state = next_state
			_play_animation_for_state()
	elif one_shot_action == OneShotAction.KICKING and state != State.KICK:
		state = State.KICK
		_play_animation_for_state()

# --- conveyor belts ---------------------------------------------------------------------------
# Belts are duck-typed like take_hit()/take_damage() below: a conveyor_belt.gd body exposes
# get_conveyor_speed() and doesn't know or care that the rider is specifically the player.
# --- small steps -------------------------------------------------------------------------------
## Walks up a step of at most `step_height` px without a jump. Runs just before move_and_slide(), only for an ordinary
## grounded walk (not climbing, hanging, swimming, surfing or rising). If this frame's horizontal motion would run into a
## wall (a surface too steep to walk, so slopes are left to move_and_slide()), the body is lifted by step_height; the lift is
## kept only if the lifted body can then move the full horizontal distance and has ground under it within step_height of
## the lift. move_and_slide()'s floor snap (slope_snap_length) settles it back down onto the step surface at the end of
## the move. A taller wall, a gap or a ceiling in the way leaves the body where it was, so it is stopped as before.
func _try_step_up(delta: float) -> void:
	if step_height <= 0.0 or is_climbing or is_hanging or is_swimming or is_surfing or not is_on_floor() or velocity.y < 0.0:
		return
	var dx := velocity.x * delta
	if absf(dx) < 0.01:
		return
	var motion := Vector2(dx, 0.0)
	var hit := KinematicCollision2D.new()
	if not test_move(global_transform, motion, hit):
		return
	if hit.get_angle(up_direction) <= floor_max_angle:
		return  # a slope the body can walk: not a step
	var lifted := global_transform.translated(Vector2(0.0, -step_height))
	if test_move(global_transform, Vector2(0.0, -step_height)):
		return  # a ceiling is in the way of the lift
	if test_move(lifted, motion):
		return  # still blocked at step_height: a wall, not a step
	var moved := lifted.translated(motion)
	if not test_move(moved, Vector2(0.0, step_height + 1.0)):
		return  # nothing to stand on past the lift
	global_position.y -= step_height

# --- walking into a block ----------------------------------------------------------------------
# Duck-typed contract: a body with walk_shoved(direction, walk_speed) -> float (MeltableBlock) is asked, while the player
# stands and walks into its side, how fast it can be pushed: it returns the speed it took, or -1 to refuse (ice and metal
# always do, so walking still can't move them; a wall or a refusing block in front of a carbon fiber block does too).
# Not a held state, so _interrupt_current_action() needs nothing. A crouched or sneaking player never pushes, and neither
# does one who is surfing, hanging, climbing, swimming, in a one-shot action or carrying launch momentum.
func _can_walk_push(input_dir: float) -> bool:
	return input_dir != 0.0 and signf(velocity.x) == signf(input_dir) and is_on_floor() and not is_crouching \
			and one_shot_action == OneShotAction.NONE and not is_climbing and not is_hanging and not is_swimming \
			and not is_surfing and not _air_carry_active and not _has_pending_launch

func _walk_push_limited(vx: float) -> float:
	var dir := signf(vx)
	var hit := KinematicCollision2D.new()
	if dir == 0.0 or not test_move(global_transform, Vector2(dir, 0.0), hit):
		return vx
	var normal := hit.get_normal()
	if absf(normal.x) < 0.7 or normal.x * dir > 0.0:
		return vx  # not a face the player is walking into
	var collider := hit.get_collider()
	if collider == null or not collider.has_method(&"walk_shoved"):
		return vx
	var taken: float = collider.walk_shoved(dir, absf(vx))
	if taken < 0.0:
		return vx
	_walk_push_active = true
	return dir * minf(absf(vx), taken)

# --- slippery floors ---------------------------------------------------------------------------
# Duck-typed contract, same style as get_conveyor_speed(): any body with is_slippery() -> bool that
# the player is standing on makes the floor slippery (IceBlock does). Uses a short downward test_move
# rather than last frame's slide collisions: grounded, velocity.y is 0 so the slide often records no
# floor contact at all, while test_move always reports what's directly underfoot.
func _floor_is_slippery() -> bool:
	var probe := KinematicCollision2D.new()
	if not test_move(global_transform, Vector2.DOWN * 2.0, probe):
		return false
	if probe.get_normal().dot(Vector2.UP) < 0.7:
		return false
	var collider := probe.get_collider()
	return collider is Node and collider.has_method("is_slippery") and collider.is_slippery()

const RISING_FLOOR_MIN_SPEED := 1.0  # px/s: a rigid floor rising slower than this isn't led (the engine's carry is enough)

## A rigid-body floor (an ice or metal block on a rising level) moves after the player's own step each tick: the
## engine carries the player by the floor's velocity, but its floor snap then puts the player back on the floor's
## current surface, so the block rises into a rider that stayed put and the contact resolution holds the block to a
## fraction of its speed (about 8 px/s however fast the level rose). So after move_and_slide() the player leads such
## a floor: it moves up by the floor's rise for this tick and sits where the surface will be after the step. Stops at
## a ceiling (move_and_collide), only for RigidBody2D floors rising faster than RISING_FLOOR_MIN_SPEED; other
## moving floors (platforms, belts, planks) are untouched.
func _lead_rising_rigid_floor(delta: float) -> void:
	if not is_on_floor() or get_platform_velocity().y > -RISING_FLOOR_MIN_SPEED:
		return
	var hit := KinematicCollision2D.new()
	if not test_move(global_transform, Vector2(0.0, 2.0), hit):
		return
	var floor_body := hit.get_collider() as RigidBody2D
	if floor_body == null or floor_body.linear_velocity.y > -RISING_FLOOR_MIN_SPEED:
		return
	move_and_collide(Vector2(0.0, floor_body.linear_velocity.y * delta))

func _conveyor_push_speed() -> float:
	# Checked every frame while grounded, using the PREVIOUS frame's slide collisions — this
	# frame's move_and_slide() hasn't run yet at this point in _physics_process, same one-frame-
	# lag tradeoff as every other per-frame floor check here, and not perceptible. Skips any
	# collision whose normal isn't roughly floor-like, so touching a conveyor's side face (if one
	# ever has one) doesn't also push you.
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		if collision.get_normal().dot(Vector2.UP) < 0.7:
			continue
		var collider := collision.get_collider()
		if collider is Node and collider.has_method("get_conveyor_speed"):
			return collider.get_conveyor_speed()
	return 0.0

# --- water push --------------------------------------------------------------------------------
# Not duck-typed like the conveyor/jump-pad/gem contracts above — WaterManager is a known, singular
# per-level node (found by group in _ready(), like world_tilemap/ladder_tilemap), not a body this
# collides with, so there's no "whatever I'm touching" lookup to do here.
func _water_push_speed() -> float:
	if water_manager == null:
		return 0.0
	return water_manager.get_player_push().x * (surf_water_push_scale if is_surfing else 1.0)

# --- hazard tiles (roadmap 8.4: spikes) -------------------------------------------------------------
# Spikes are tiles of the world tilemap with no collision, marked by TileSet custom data (see TileHazards). Like
# Sawwheel and Crusher this polls every physics frame rather than reacting to an entry, so a player still standing
# in them is hurt again once the i-frames end. take_hit() does everything else (knockback away from the tile's
# side, ending a surf, death), so the surf needs no spike code.
func _poll_tile_hazards() -> void:
	var size := Vector2(_shape_width(collision_shape.shape), _shape_height(collision_shape.shape))
	if absf(sin(collision_shape.rotation)) > 0.5:
		size = Vector2(size.y, size.x)  # the swim pose lies the collider on its side
	var rect := Rect2(collision_shape.global_position - size * 0.5, size)
	var hit := TileHazards.hit_in_rect(world_tilemap, rect)
	# Switchable spike layers (roadmap N1.2): every layer in the group, skipped while its spikes are retracted.
	for layer in get_tree().get_nodes_in_group(&"hazard_layer"):
		if not layer is TileMapLayer or not layer.has_method("is_hazard_active") or not layer.is_hazard_active():
			continue
		var layer_hit := TileHazards.hit_in_rect(layer, rect)
		if not layer_hit.is_empty() and (hit.is_empty() or int(layer_hit["damage"]) > int(hit["damage"])):
			hit = layer_hit
	if hit.is_empty():
		return
	if take_hit(int(hit["damage"]), hit["position"]):
		Audio.play_at(&"traps/spikes_hit", hit["position"])

# --- swim (Phase 8.1) --------------------------------------------------------------------------
func _water_probe_basin() -> WaterBasin:
	# The basin (if any) whose column the swim reference point currently sits in — factored out of
	# _water_surface_depth() below so _update_swim_state()'s hazard check can also ask "which basin,
	# if any, is at the probe point" without a second, separately-maintained probe calculation.
	# A probe BELOW the column's seabed is outside the basin altogether (e.g. standing in a room
	# under a drain), not "deep underwater" — those read as no basin, so they can never swim or take
	# settled-hazard damage from liquid that is on the other side of a floor. Passing the probe's own
	# world y (not just its column) also lets get_basin_for_column() pick correctly between two
	# basins stacked in the same column.
	if water_manager == null or world_tilemap == null:
		return null
	var probe := Vector2(collision_shape.global_position.x, collision_shape.global_position.y + swim_probe_offset_y)
	var col := world_tilemap.local_to_map(world_tilemap.to_local(probe)).x
	return water_manager.get_basin_for_column(col, probe.y)

func _water_surface_depth() -> float:
	# How far BELOW the local basin's actual LIQUID the swim reference point currently is (positive =
	# submerged), measured against basin.get_liquid_surface_world_y(). Crust is solid, walkable
	# ground, not water, and after a drain the liquid can sit well below a hanging crust, with open
	# air between — so the reference is the liquid's own surface, never the crust's faces: standing
	# on the crust or inside the void above the remaining liquid reads as dry, and only actually
	# entering the liquid counts. With no crust this is the plain surface, as it always was. Returns
	# -INF if the probe isn't inside any registered basin, so it can never satisfy swim_enter_depth
	# with no liquid present.
	var basin := _water_probe_basin()
	if basin == null:
		return -INF
	var probe := Vector2(collision_shape.global_position.x, collision_shape.global_position.y + swim_probe_offset_y)
	# The embedded player (a frozen crust formed around them, see WaterBasin.freeze()) measures against the crust's top face
	# instead, so the crust band counts as water for them: they swim up through it and leave swimming at the top.
	return probe.y - basin.get_swim_surface_world_y(self)

func _swim_pose_fits(x_nudge: float) -> bool:
	# Would the collider, rotated to the horizontal swim pose (and shifted by x_nudge), overlap any solid?
	# A real shape query rather than test_move(): test_move() only reports a hit for the body's CURRENT
	# rotation, and this asks about the one it is about to have. Exact touching is not overlap, so a gap
	# of precisely the swim pose's width still fits; anything narrower does not.
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = Transform2D(deg_to_rad(90.0), collision_shape.global_position + Vector2(x_nudge, 0.0))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	return get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()

func _set_swim_collider(active: bool) -> void:
	# Rotating to the swim pose is refused (the collider stays upright and swimming carries on with it)
	# whenever the wider pose wouldn't fit where the player is — a gap between two ice blocks, or a block
	# and a basin wall, narrower than the swim pose's length — because the rotated collider would start
	# out overlapping both sides at once and pin the player there for good. _update_swim_state() retries
	# every frame while swimming upright, so the pose is taken up as soon as there's room. Un-rotating
	# when the pose was never taken up is a no-op (it would otherwise apply the wall nudge below for a
	# bulge that never happened).
	if not active and not _swim_rotated:
		return
	if active and _swim_rotated:
		return
	# Swimming reorients the player to lie horizontal, so the collider needs to follow: rotating
	# collision_shape 90 degrees turns the standing collider (tall, narrow — a capsule in this
	# project, but this works the same for a RectangleShape2D standing_shape too) onto its side
	# (wide, short). With open space on both sides this needs no position offset — the rotation is
	# already centered on collision_shape's existing position (y=0), which is exactly the
	# "horizontal orientation centered around y=0" the design calls for. Next to a wall, though, that
	# same rotation bulges the collider outward by swim_shape_bulge_x on whichever side is touching
	# it — clipping into the wall on entry, or (once reverted) leaving a gap floating off it on exit.
	# So: check for a wall contact from whatever shape was JUST active (this runs before the rotation
	# changes, so is_on_wall()/get_last_slide_collision() still reflect the pre-transition shape from
	# the last move_and_slide() call — the narrow one on entry, the wide one on exit, exactly the one
	# that matters each time) and nudge global_position by the bulge along that wall's normal, so the
	# TOUCHED EDGE stays put across the shape change instead of the center. Same idea as
	# crouch_offset_y keeping the feet planted through crouch's shape swap, just along x instead of y,
	# and reacting to whichever side (if any) is actually in contact rather than a fixed direction —
	# a fixed direction would fix one wall side and break the other, since the bulge is symmetric.
	var x_nudge := 0.0
	if swim_shape_bulge_x != 0.0 and is_on_wall():
		var collision := get_last_slide_collision()
		if collision:
			var normal := collision.get_normal()
			if absf(normal.x) > 0.7:  # wall-like (mirrors the 0.7 floor-like dot-with-UP threshold
					# used for conveyors above) — skips floor/ceiling contacts, where the normal is
					# mostly vertical instead
				var wall_side := -signf(normal.x)  # +1 = wall to the right, -1 = wall to the left
					# (collision normals point away from whatever they hit, so a wall on the right
					# gives a leftward, negative-x normal)
				x_nudge = -wall_side * swim_shape_bulge_x * (1.0 if active else -1.0)
					# entering (active=true): move AWAY from the wall by the bulge, so the widening
					# collider's near edge doesn't clip into it. exiting (active=false): move BACK
					# toward the wall by the same amount, so the narrowing collider's near edge
					# doesn't leave a gap floating behind it — this is the fix for the "surface next
					# to a wall and hang a few pixels off the ledge" bug.
	if active and not _swim_pose_fits(x_nudge):
		return  # no room for the wide pose here; stay upright, retried next frame
	global_position.x += x_nudge
	collision_shape.rotation = deg_to_rad(90.0) if active else 0.0
	_swim_rotated = active

const SWIM_SPLASH_IMPULSE := 0.15
	# Cosmetic: px/s of downward surface kick per px/s of entry speed when the player dives in (basin.gd, "Surface ripple").
const SWIM_WAKE_IMPULSE := 0.006
	# Same, per px/s of horizontal speed each physics frame while swimming near the surface.
const SWIM_WAKE_MAX_DEPTH := 12.0
	# px below the surface within which a swimmer still stirs it.

func _update_swim_state() -> void:
	# Entry/exit via the depth hysteresis on swim_enter_depth/swim_exit_depth above. Swim entry/exit is gated off while
	# climbing or hanging (slag damage below is not): a ladder or ledge that happens to be partly submerged shouldn't fight with
	# those held states for control of is_swimming. Not gated on is_dead/is_dancing/hurt here — this
	# function is only ever reached after _physics_process's own early return for those already skips
	# the rest of the frame, same as every other check below it.
	# Slag damage applies in every held state (a ledge or ladder dipping into a slag basin isn't a safe
	# spot), so the hazard check runs before the climb/hang gate below.
	var basin := _water_probe_basin()
	if basin != null and basin.is_hazardous_now():
		# A hazardous settled liquid (slag, or water a spark has electrified: WaterBasin.is_hazardous_now()) is swimmable too (buoyant, see _swim_passive_target()) so the
		# player has a chance to climb out, but every frame of submersion calls take_hit(), whose own
		# i-frames pace the damage. from_position is the player's own position (no single point to be
		# knocked away from), which take_hit()'s on-top fallback handles.
		if _water_surface_depth() >= swim_enter_depth and take_hit(SLAG_CONTACT_DAMAGE if LiquidConstants.profile(basin.liquid_type).is_hazardous else ELECTRIC_CONTACT_DAMAGE, global_position):
			return  # take_hit() already dropped swim state (via _interrupt_current_action()); the
				# normal entry below re-enters it once the hurt animation ends, if still submerged.
	if is_climbing or is_hanging:
		if is_swimming:
			is_swimming = false
			_set_swim_collider(false)  # e.g. grabbing a ladder/ledge that dips into a basin —
				# the collider needs to un-rotate here too, not just on the depth-based exit below
		return
	var depth := _water_surface_depth()
	if is_swimming:
		if depth <= swim_exit_depth:
			is_swimming = false
			_set_swim_collider(false)
			Audio.play(&"player/swim_exit")
		elif basin != null and depth < SWIM_WAKE_MAX_DEPTH and absf(velocity.x) > 10.0:
			basin.disturb(collision_shape.global_position.x, -absf(velocity.x) * SWIM_WAKE_IMPULSE, 10.0)
	else:
		if depth >= swim_enter_depth:
			_end_surf(false)  # no skim floor was up (too slow, hazardous liquid, or a crust-free basin entered from below): the board is lost and the player swims
			is_swimming = true
			_set_swim_collider(true)
			if basin != null:
				basin.disturb(collision_shape.global_position.x, -absf(velocity.y) * SWIM_SPLASH_IMPULSE, 10.0)  # before the cap below
			velocity.y = minf(velocity.y, swim_speed)  # a "splash" absorb, not the whole story: this
				# hard-caps a large pre-entry fall speed (a body that fell for a while before reaching
				# the surface carries normal `gravity`-accumulated velocity.y, often several times
				# swim_speed) down to swim_speed the instant is_swimming flips true, so it can never
				# read as full-gravity on entry even for one frame. From there, 8.2's own swim branch
				# takes over and eases velocity.y the rest of the way down to the much slower
				# swim_sink_speed via move_toward() at swim_gravity's rate — this cap only needs to get
				# it into that gentler curve's range, not all the way to the resting speed itself.
			sprite.play("swim")  # played here, at the transition, rather than through
				# _play_animation_for_state() — same convention as _start_hang() playing "hang" directly;
				# SWIM isn't routed through that dispatcher, same as CLIMB/HANG aren't.
			Audio.play(&"player/swim_enter")
	if is_swimming and not _swim_rotated:
		_set_swim_collider(true)  # earlier entry was refused for lack of room; take up the pose once it fits

func _swim_passive_target() -> float:
	# Vertical velocity (px/s, + = down) a swimmer with no vertical input eases toward: the liquid's
	# own buoyancy if it has one (slag floats you up), else the ordinary slow sink.
	var basin := _water_probe_basin()
	if basin != null:
		var float_speed := LiquidConstants.profile(basin.liquid_type).swim_float_speed
		if float_speed > 0.0:
			return -float_speed
	return swim_sink_speed

## An airborne kick: the same one-shot, animation, sound and hitbox as the ground kick, but it does not root the player
## (air control and any carried swing or dismount momentum carry on, see `_air_kick`), and with `air_kick_halts_ascent`
## it cancels any upward speed so a kick out of a jump ends the rise. It only ever removes upward speed: kicking while
## falling leaves the fall alone, so spamming it cannot hover. Ledge, catwalk and swing grabs are gated on
## `one_shot_action == NONE`, so none can start until the kick animation ends.
func _start_air_kick() -> void:
	one_shot_action = OneShotAction.KICKING
	_air_kick = true
	if air_kick_halts_ascent:
		velocity.y = maxf(velocity.y, 0.0)
	sprite.play("kick")
	Audio.play(&"player/kick")
	kick_hitbox.monitoring = true

# --- dealing damage (kick) -------------------------------------------------------------------
# Mirrors the take_hit contract below but in the other direction. KickHitbox hits the target's
# actual physics body directly now (not a child Area2D carved out as "the vulnerable spot") — an
# enemy's whole body is meant to be kickable (and standable-on), with any hazardous part (a drill,
# a spike) modeled as its OWN separate Area2D instead, the same way this section's counterpart
# below treats the player as the vulnerable target and a hazard as the separate aggressor.
func _on_kick_hitbox_body_entered(body: Node2D) -> void:
	if body.has_method("take_damage"):
		body.take_damage(KICK_DAMAGE)
	# Second, optional kick contract for things that care WHICH WAY they were kicked (ice blocks
	# shunt along it): kicked(direction: float), -1.0 = left, 1.0 = right. Independent of take_damage.
	if body.has_method("kicked"):
		body.kicked(-1.0 if sprite.flip_h else 1.0)

# --- taking damage -------------------------------------------------------------------------
# Contract for anything that hurts the player (saws now; bullets, lasers, enemies later):
#     if body.has_method("take_hit"): body.take_hit(damage, global_position)
# from_position is the hazard's position; it decides which way the player is thrown. Returns true
# if the hit landed, false if it was ignored (dead / dancing / still in post-hit grace period) —
# a projectile can use that to decide whether to destroy itself. Deliberately NOT named
# take_damage: enemies are going to expose take_damage(amount) -> int (points), a different
# contract, and a hazard calling the wrong one on the wrong target should fail loudly, not quietly.
func take_hit(damage: int, from_position: Vector2) -> bool:
	if is_dead or is_dancing or hurt_invincibility_timer > 0.0:
		return false

	health = maxi(health - damage, 0)
	health_changed.emit(health, max_health)

	_interrupt_current_action()
	_end_cue()  # a hit (death included) ends a camera cue so the player can see what hurt them; deliberately not in _interrupt_current_action(), which jump pads and stomps share

	# throw the player away from the hazard: pick the side from the hazard's x relative to ours.
	# If we're almost exactly on top of it (dropped straight onto it), fall back to backing away
	# from where we're facing rather than picking an arbitrary side.
	var facing := -1.0 if sprite.flip_h else 1.0
	var dx := global_position.x - from_position.x
	var away := signf(dx) if absf(dx) > 1.0 else -facing
	velocity = Vector2(away * hurt_knockback.x, hurt_knockback.y)

	if health <= 0:
		is_dead = true
		state = State.DEAD
		hurt_invincibility_timer = 0.0
		sprite.modulate.a = 1.0
		sprite.play("dead")
		Audio.play(&"player/dead")
		died.emit()
		_schedule_respawn()
	else:
		one_shot_action = OneShotAction.HURT
		state = State.HURT
		hurt_invincibility_timer = hurt_invincibility_duration
		sprite.play("hurt")
		Audio.play(&"player/hurt")
	return true

# --- collecting gems / winning -------------------------------------------------------------
# Collecting gems only counts them; winning is the Finish's job (finish.gd). Contract for anything the
# player can pick up (gems now; medkits likely later, with a separate
# method — see Collectible notes in objon.md, not yet built): if body.has_method("collect_gem"):
# body.collect_gem(). Mirrors the take_hit contract above rather than a group check, so a gem
# doesn't need to know or care that "player" is the group name.
func collect_gem() -> void:
	if is_dead or is_dancing:
		return  # ignore a stray pickup once the run is already over
	# (the sound lives here rather than in gem.gd so an ignored pickup stays silent, per the guard above)
	# collectible1.wav is the gem sound. Files ending in digits normally count as random variants of one
	# sound, but collectible1-3 are distinct sounds for different collectibles, so pick by number
	# (variant 0 = collectible1, no random jitter) and never call this id without a variant.
	Audio.play(&"collectibles/collectible", 0.0, 0)
	gems_collected += 1
	gem_collected.emit(gems_collected, gems_total)

## Score contract, duck-typed like collect_gem()/collect_medkit(): `if body.has_method("add_points"): body.add_points(n)`. Adds `amount`
## to `points`, emits `points_changed` and spawns the floating "+N" above the head (world space, so it stays where it
## appeared). Returns false (nothing awarded) when dead or dancing, or for a non-positive amount.
func add_points(amount: int) -> bool:
	if is_dead or is_dancing or amount <= 0:
		return false
	points += amount
	points_changed.emit(points, amount)
	var popup: Node2D = POINTS_POPUP.instantiate()
	popup.points = amount
	get_parent().add_child(popup)  # the level root can be a plain Node, so no to_local(): set the world position after
	popup.global_position = global_position + points_popup_offset  # entering the tree (the popup starts its rise deferred)
	return true

## Medkit contract, duck-typed like collect_gem(): `if body.has_method("collect_medkit"): body.collect_medkit(heal, points)`.
## Restores up to `heal_amount` hit points (clamped to max_health, so nothing at full health), awards `points` either
## way (a bonus that depended on actually healing would reward getting hurt first), plays the pickup sound and
## returns true. Returns false (the medkit stays in the level) only when dead or dancing.
func collect_medkit(heal_amount: int, points_awarded: int) -> bool:
	if is_dead or is_dancing:
		return false
	if heal_amount > 0 and health < max_health:
		health = mini(health + heal_amount, max_health)
		health_changed.emit(health, max_health)
	Audio.play(&"collectibles/medkit")
	add_points(points_awarded)
	return true

## Deferred from _ready(): the level's total is whatever is in group "gem" once every node has entered the
## tree. Gems free themselves on pickup, so this must run once at load, never again.
func _count_gems() -> void:
	if _gems_restored:
		return  # a restore already put back the ORIGINAL total; recounting would only see the gems left
	gems_total = get_tree().get_nodes_in_group(&"gem").size()
	gems_counted.emit(gems_total)

# --- respawn / checkpoint save ------------------------------------------------------------
# Saveable contract (see game.gd). Only the gem tally and the points total travel through a checkpoint: position and health are
# deliberately not restored (respawn_at() puts the player on the checkpoint at full health), and everything
# else about the player starts fresh with the reloaded scene.
func save_state() -> Dictionary:
	return {"gems_collected": gems_collected, "gems_total": gems_total, "points": points}

func load_state(d: Dictionary) -> void:
	gems_collected = d.get("gems_collected", gems_collected)
	gems_total = d.get("gems_total", gems_total)
	points = d.get("points", points)  # the display reads it in its deferred sync, so no signal is needed here
	_gems_restored = true

## Called by Game after the snapshot has been applied: a hard teleport onto the checkpoint at full health.
func respawn_at(pos: Vector2) -> void:
	_chill.reset(sprite)
	_end_crust_pass()
	_cancel_cue()
	global_position = pos
	velocity = Vector2.ZERO
	health = max_health
	health_changed.emit(health, max_health)
	_reset_teleport_interpolation()

## Starts the countdown to Game.respawn() once the death animation has played out. Tween-based rather than
## `await`: the tween is bound to this node, so it dies quietly with it if R reloads the level first.
func _schedule_respawn() -> void:
	var wait := _dead_animation_length() + respawn_delay
	var tween := create_tween()
	tween.tween_interval(wait)
	tween.tween_callback(Game.respawn)

func _dead_animation_length() -> float:
	var frames := sprite.sprite_frames
	if frames == null or not frames.has_animation("dead"):
		return 0.0
	var speed := frames.get_animation_speed("dead") * absf(sprite.speed_scale)
	if speed <= 0.0:
		return 0.0
	var total := 0.0
	for i in frames.get_frame_count("dead"):
		total += frames.get_frame_duration("dead", i)
	return total / speed

# --- jump pads ----------------------------------------------------------------------------
# Contract for anything that wants to fling the player around, like a jump pad: if
# body.has_method("launch"): body.launch(vector). Mirrors the take_hit()/collect_gem() duck-typing
# convention above rather than a group check, so a jump pad doesn't need to know or care that
# "player" is the group name — and by the same token nothing else (drillbot, stingbot) responds to
# one unless it grows a launch() of its own.
## Chill contract (duck-typed, `has_method("apply_chill")`): called every physics frame by whatever is chilling the player
## (a FreezeTurret's beam, a WaterBasin's frozen crust around an embedded player), with a strength 0..1. Overlapping sources
## take the strongest, never the sum. Chill rises at once and fades over ChillState.DECAY_TIME; at full strength walk and
## sneak speed and swim speed are scaled by ChillState.MIN_SCALE. The sprite turns blue over ChillState.TINT_RISE_TIME
## (`self_modulate`, so the hurt blink on `modulate` is untouched). Surfing and a launch's carried momentum (jump pad, swing
## release) never read the scale, so they are exempt. It is never saved: a restore comes back unchilled.
func apply_chill(strength: float) -> void:
	_chill.apply(strength)

func _update_chill(delta: float) -> void:
	_chill.update(delta)
	_chill.apply_tint_to(sprite)

func _chill_scale() -> float:
	return _chill.speed_scale()

func get_chill() -> float:
	return _chill.level

func launch(vector: Vector2) -> void:
	if is_dead or is_dancing:
		return
	if is_surfing:
		# A pad under the board keeps the surf: nothing is torn down here, and the buffered vector is applied as a surf
		# launch (_apply_surf_launch(): its vertical part replaces the vertical velocity, its horizontal part adds to the
		# board's), so the board leaves the pad in the air carry and lands back into the surf.
		_pending_launch = vector
		_has_pending_launch = true
		_pending_launch_keeps_surf = true
		return
	_interrupt_current_action()  # drop out of hang/climb/crouch so the launch isn't
		# immediately overwritten later this same frame
	_pending_launch = vector
	_has_pending_launch = true
	_pending_launch_keeps_surf = false
	# NOT written to velocity directly here: this can be called from a jump pad's Area2D signal at
	# an unpredictable point in the physics step relative to THIS frame's own _physics_process —
	# sometimes before it's run its "grounded -> velocity.y = 0" gravity line and its unconditional
	# "velocity.x = input_dir * speed" line, sometimes after. Writing straight to velocity here means
	# either of those can silently cancel the launch if they haven't run yet this frame. Buffering it
	# and applying it once, after everything else that touches velocity (see _physics_process),
	# makes the launch land regardless of ordering. No state assigned here either: the decide-state
	# block at the end of the same frame already turns the resulting velocity.y < 0 into State.JUMP
	# on its own, the same reasoning as jumping off a ledge-hang above.

## Victory exit, called by the level's Finish on entry (duck-typed, `has_method("dance_through")`): starts the
## dance, slides the body to `center_x` over `slide_time`, then shrinks the SPRITE to nothing over `shrink_time`
## and hides it, so the player seems to dance away through the door. Scaling the sprite node (not the body)
## shrinks toward the art's centre, which is the node origin (the sprite is centred with no offset), so the feet
## lift off the floor as it shrinks; the collider, camera and kick hitbox are untouched. Returns the Tween so the
## caller can wait for it. Only the sprite's `scale` is touched; any future code that changes `sprite.scale` or
## `sprite.position` would fight this.
func dance_through(center_x: float, slide_time: float, shrink_time: float) -> Tween:
	start_dance()
	if _dance_tween != null and _dance_tween.is_valid():
		_dance_tween.kill()
	_dance_tween = create_tween()
	_dance_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)  # the body moves in the physics step
	_dance_tween.tween_property(self, "global_position:x", center_x, maxf(slide_time, 0.001)) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dance_tween.tween_property(sprite, "scale", Vector2.ONE * DANCE_SHRINK_TO, maxf(shrink_time, 0.001)) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_dance_tween.tween_callback(sprite.hide)
	return _dance_tween

## Victory pose. Terminal, like dying. dance_through() is what the Finish uses; this alone is the bare pose.
func start_dance() -> void:
	if is_dead or is_dancing:
		return
	is_dancing = true
	_interrupt_current_action()  # cancel whatever was in progress (mantle tween, crouch...)
	_end_cue()
	velocity.x = 0.0  # stop immediately rather than letting _process_incapacitated's shared
		# hurt_friction decay (meant for hurt/dead's knockback lurch) skid the dance to a halt.
		# velocity.y is left alone — a gem collected mid-air should still fall/settle normally.
	state = State.DANCE
	sprite.play("dance")
	Audio.play(&"player/win")
	won.emit()

func _interrupt_current_action() -> void:
	# Cancels whatever the player was in the middle of. Any NEW held state, one-shot action or
	# tween added to this script needs a line here, or a hit will leave it running underneath hurt.
	# (The camera cue is the one exception: it ends in take_hit() and start_dance() only, so a launch doesn't cut it.)
	if _mantle_tween and _mantle_tween.is_valid():
		_mantle_tween.kill()
	_mantle_tween = null
	fall_anim_delay_timer = 0.0
	hang_platform = null
	_detach_swing()
	_detach_rail()
	_rail_jumped_off = false
	_end_surf(false)  # a hit ends the surf (a jump pad doesn't come through here while surfing, see launch())
	_air_carry_active = false  # a hit or a launch replaces whatever momentum the swing gave

	is_climbing = false
	if is_hanging:
		is_hanging = false
		hang_lockout_timer = hang_regrab_lockout  # don't instantly re-grab the ledge we were just thrown off
	if is_swimming:
		is_swimming = false  # a hit while swimming shouldn't leave the player stuck mid-state; the
			# hurt knockback/gravity in _process_incapacitated() takes over from here same as any
			# other hit
		_set_swim_collider(false)  # un-rotate the collider back to standing orientation, same idea
			# as the crouch-shape restore just below

	if is_crouching and _can_stand_up():
		# instant, no reverse-crouch animation — the hurt animation is about to play instead. If
		# there's a ceiling overhead we stay crouched (as _physics_process's own stand-up does).
		is_crouching = false
		collision_shape.shape = standing_shape
		collision_shape.position.y -= crouch_offset_y

	one_shot_action = OneShotAction.NONE
	kick_hitbox.monitoring = false  # a hit landing mid-kick shouldn't leave the hitbox active
	# a stale buffered jump / coyote window would otherwise fire the instant control returns
	jump_buffer_timer = 0.0
	coyote_timer = 0.0

func _process_incapacitated(delta: float) -> void:
	_slide_vx = 0.0  # a hit/death ends any slide; don't resume old momentum afterwards
	# shared by HURT and DEAD: no input, just gravity, the lurch decaying, and collision
	var basin := _water_probe_basin()
	if basin != null and LiquidConstants.profile(basin.liquid_type).swim_float_speed > 0.0 and _water_surface_depth() >= swim_enter_depth:
		# hurt or dead inside a buoyant liquid (slag): float up instead of sinking like a stone
		velocity.y = move_toward(velocity.y, -LiquidConstants.profile(basin.liquid_type).swim_float_speed, swim_gravity * delta)
	elif not is_on_floor():
		velocity.y += gravity * delta
	velocity.x = move_toward(velocity.x, 0.0, hurt_friction * delta)
	move_and_slide()
	_update_landing_sound()  # a body thrown into the air by a hit still thuds when it lands

func _update_hurt_invincibility(delta: float) -> void:
	if hurt_invincibility_timer <= 0.0:
		return
	hurt_invincibility_timer -= delta
	if hurt_invincibility_timer <= 0.0:
		hurt_invincibility_timer = 0.0
		sprite.modulate.a = 1.0
	else:
		sprite.modulate.a = 0.4 if int(hurt_invincibility_timer * HURT_BLINK_RATE) % 2 == 0 else 1.0

func _shape_height(shape: Shape2D) -> float:
	# total vertical extent of a collider, for the collider types crouch supports
	if shape is RectangleShape2D:
		return (shape as RectangleShape2D).size.y
	if shape is CapsuleShape2D:
		return (shape as CapsuleShape2D).height  # Godot 4: height is the FULL height, caps included
	return 0.0

func _shape_width(shape: Shape2D) -> float:
	# total horizontal extent of a collider IN ITS OWN UNROTATED ORIENTATION — the counterpart to
	# _shape_height() above. Used only to work out how far the swim rotation's 90-degree turn bulges
	# the collider outward (that turn makes the unrotated height into the new world-space width, so
	# the difference between the two is the bulge on each side — see swim_shape_bulge_x below).
	if shape is RectangleShape2D:
		return (shape as RectangleShape2D).size.x
	if shape is CapsuleShape2D:
		return (shape as CapsuleShape2D).radius * 2.0
	return 0.0

func _make_crouch_shape(standing: Shape2D) -> Shape2D:
	# Halves the collider's height, keeping its width. Built from a duplicate so the standing shape
	# resource is never modified. A capsule can't be shorter than two radii (its two caps would
	# overlap), so its crouch height is clamped to that instead of a plain half.
	if standing is RectangleShape2D:
		var rect := standing.duplicate() as RectangleShape2D
		rect.size.y *= 0.5
		return rect
	if standing is CapsuleShape2D:
		var capsule := standing.duplicate() as CapsuleShape2D
		capsule.height = maxf(capsule.height * 0.5, capsule.radius * 2.0)
		return capsule
	return null

func _can_stand_up() -> bool:
	# temporarily test the standing shape's position without committing to it
	var space_state := get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = standing_shape
	query.transform = Transform2D(0, global_position)
	query.exclude = [self]
	var result := space_state.intersect_shape(query)
	return result.is_empty()

func _ladder_layers() -> Array[TileMapLayer]:
	# Every ladder layer that is live right now: the static one(s) and any powered ladder layer that is out (a retracted
	# one has left the group).
	var layers: Array[TileMapLayer] = []
	for node in get_tree().get_nodes_in_group("ladder_tilemap"):
		if node is TileMapLayer:
			layers.append(node as TileMapLayer)
	return layers

func _is_ladder_cell(layer: TileMapLayer, cell: Vector2i) -> bool:
	# a ladder layer holds nothing but ladders, so any tile at all counts
	return layer.get_cell_source_id(cell) != -1

func _ladder_cell_overlapping() -> Vector2i:
	# The ladder cell any part of the collider is overlapping, or Vector2i.MAX for none; `_ladder_hit_layer` is the layer
	# it was found on. Samples three points down the collider's centerline (middle, then just inside the bottom and top
	# edges) rather than testing the full rectangle: a ladder is one tile wide, the collider is
	# narrower than a tile, and the centerline keeps the x-snap on entry small. Uses the CURRENT
	# shape (crouching included).
	_ladder_hit_layer = null
	var center := collision_shape.global_position
	var half := _shape_height(collision_shape.shape) * 0.5
	var inset := maxf(half - 1.0, 0.0)
	for layer in _ladder_layers():
		for sample_y in [center.y, center.y + inset, center.y - inset]:
			var cell := layer.local_to_map(layer.to_local(Vector2(center.x, sample_y)))
			if _is_ladder_cell(layer, cell):
				_ladder_hit_layer = layer
				return cell
	return Vector2i.MAX

func _ladder_cell_under_feet() -> Vector2i:
	# Ladder-top mounting probe: while standing on a surface, the ladder cell starting just below the
	# feet (a ladder whose top is flush with the walking surface, sharing the catwalk tile's cell).
	# Vector2i.MAX if there isn't one; `_ladder_mount_layer` is the layer it was found on. At a ladder's BASE this looks
	# into the ground tile instead, which has no ladder in it, so down still just crouches there.
	_ladder_mount_layer = null
	if not is_on_floor() or is_crouching:
		return Vector2i.MAX
	var center := collision_shape.global_position
	var feet_y := center.y + _shape_height(collision_shape.shape) * 0.5
	for layer in _ladder_layers():
		var cell := layer.local_to_map(layer.to_local(Vector2(center.x, feet_y + 2.0)))  # +2px: a little under the feet, tolerant of float error
		if _is_ladder_cell(layer, cell):
			_ladder_mount_layer = layer
			return cell
	return Vector2i.MAX

func _ascending_landing_y() -> float:
	# While climbing up: if the feet have risen into a floor tile the ladder passes through and are
	# within landing_catch px of its top surface, returns that surface's world y; otherwise INF.
	# (One-way tiles let the collider pass up through them, so nothing physical stops the climb.)
	# The floor may be on the world tilemap or on a separate catwalk layer (a TileMapLayer in group "catwalk").
	var center := collision_shape.global_position
	var feet_y := center.y + _shape_height(collision_shape.shape) * 0.5
	var layers: Array[TileMapLayer] = []
	if world_tilemap != null:
		layers.append(world_tilemap)
	for node in get_tree().get_nodes_in_group("catwalk"):
		if node is TileMapLayer and node != world_tilemap:
			layers.append(node as TileMapLayer)
	for layer in layers:
		if layer.tile_set == null:
			continue
		var cell := layer.local_to_map(layer.to_local(Vector2(center.x, feet_y)))
		if layer.get_cell_source_id(cell) == -1:
			continue
		var half_tile_h := layer.tile_set.tile_size.y * 0.5
		var top_y := layer.to_global(layer.map_to_local(cell) - Vector2(0.0, half_tile_h)).y
		if feet_y - top_y > landing_catch:
			continue
		return top_y
	return INF

func _compute_hang_probes(facing: float) -> Dictionary:
	var space_state := get_world_2d().direct_space_state
	var hand_pos := global_position + Vector2(0.0, hang_hand_local_offset.y)

	# diagonal ray from hand height: nothing should be blocking ahead of the ledge
	var forward_to := hand_pos + Vector2(facing * hang_forward_probe, -hang_probe_rise)
	var forward_query := PhysicsRayQueryParameters2D.create(hand_pos, forward_to, hang_probe_mask, [self])
	var forward_hit := not space_state.intersect_ray(forward_query).is_empty()

	# vertical ray just past the wall: checks there's headroom to hang/stand here
	var probe_pos := hand_pos + Vector2(facing * hang_forward_probe, 0.0)
	var up_to := probe_pos + Vector2(0.0, -hang_headroom_check)
	var up_query := PhysicsRayQueryParameters2D.create(probe_pos, up_to, hang_probe_mask, [self])
	var up_hit := not space_state.intersect_ray(up_query).is_empty()

	return {
		"forward_from": hand_pos, "forward_to": forward_to, "forward_hit": forward_hit,
		"up_from": probe_pos, "up_to": up_to, "up_hit": up_hit,
	}

func _find_ledge_corner(facing: float) -> Vector2:
	# locates the physical ledge corner (wall face x, ledge top y) for the hang position, rather than just
	# using wherever move_and_slide happened to leave the body: the ledge top comes from a ray, the wall face
	# from the body's own contact with the wall (see below).
	#
	# Returns Vector2.INF (check with is_finite()) when no ledge top is found within reach.
	# The caller must NOT grab in that case. (Falling back to "assume the ledge top is at hand height" put the
	# anchor on empty air nearly a tile above the actual edge whenever the body's feet were brushing the top
	# corner of a wall, so the real ledge top sat 8-15px below the hand, beyond the top ray's reach.)
	var space_state := get_world_2d().direct_space_state
	var hand_pos := global_position + Vector2(0.0, hang_hand_local_offset.y)

	# The wall-face x is hand_pos.x + facing * hang_forward_probe: the grab only runs while the body is in contact with the
	# wall (is_on_wall()), so the player is already flush against it and the hang keeps the player's x. hang_grip_inset and
	# hang_hand_local_offset are tuned against exactly this value. A ray at hand height must not replace it: the hand is
	# within a pixel of the ledge top at the jump apex, so whether such a ray hits the wall at all depends on which side of the
	# top the hand is on, and a hit gives the true face, 8 px nearer than this value for a flush player, which shoved the
	# player off the wall and left the hands on air (it also reads a face that leans away as farther than the body that is
	# touching it lower down).
	var wall_face_x: float = hand_pos.x + facing * hang_forward_probe

	# find the ledge's top surface: sweep down from above it, at the far-side probe x
	var probe_x := hand_pos.x + facing * hang_forward_probe
	var top_from := Vector2(probe_x, hand_pos.y - hang_headroom_check)
	var top_to := Vector2(probe_x, hand_pos.y + hang_top_probe_margin)
	var top_query := PhysicsRayQueryParameters2D.create(top_from, top_to, hang_probe_mask, [self])
	var top_hit := space_state.intersect_ray(top_query)
	if top_hit.is_empty():
		return Vector2.INF  # no ledge surface within reach of the hand — see note above

	return Vector2(wall_face_x, top_hit.position.y)

func _try_grab_ledge() -> void:
	var collision := get_last_slide_collision()
	if collision == null or not _is_hangable_surface(collision):
		return
	var platform := collision.get_collider() as PhysicsBody2D
	if platform != null and platform.has_method(&"is_hangable") and not platform.call(&"is_hangable"):
		return  # a rotating block tilted or moving too much to grab

	# Facing comes from the actual wall contact, not sprite.flip_h — flip_h only updates on ACTIVE
	# horizontal input (see the input_dir != 0.0 gate above), so it goes stale whenever a wall is
	# approached with none held, e.g. swimming straight up alongside one on just climb_up/jump. A
	# stale facing sends _compute_hang_probes()/_find_ledge_corner() searching the wrong side of the
	# player for a wall that isn't there, producing a plausible-looking but physically wrong
	# hang_anchor/hang_facing — the grab still "succeeds", but the later mantle's offset then points
	# away from the real ledge and finds no floor, reading as the mantle rising straight up with no
	# sideways motion before dropping back down. The collision normal always points away from the
	# actual wall, so it's authoritative here regardless of whatever the player was last walking
	# toward; wall_normal.x == 0.0 (a perfectly vertical/ceiling-ish normal slipping past the caller's
	# is_on_wall() check) falls back to the sprite's facing rather than picking an arbitrary side.
	var wall_normal := collision.get_normal()
	var facing := -signf(wall_normal.x) if wall_normal.x != 0.0 else (-1.0 if sprite.flip_h else 1.0)
	var probes := _compute_hang_probes(facing)
	if probes.forward_hit or probes.up_hit:
		return

	var corner := _find_ledge_corner(facing)
	if not corner.is_finite():
		return  # no real ledge top within reach; keep falling, and try again next frame
	_start_hang(facing, corner, collision.get_collider() as PhysicsBody2D)  # `as` yields null for tiles (a TileMapLayer isn't a PhysicsBody2D)

func _compute_catwalk_probe() -> Dictionary:
	# A single straight-up ray from hand height — no wall-face/corner sweep needed, since a flat
	# underside grab doesn't have a "corner" the way a ledge does. Shared between the actual grab
	# check and the debug overlay, same pattern as _compute_hang_probes()/_find_ledge_corner() above.
	return _compute_catwalk_probe_at(global_position.x)

func _compute_catwalk_probe_at(x: float) -> Dictionary:
	# Same straight-up ray as _compute_catwalk_probe() above, but at an arbitrary x rather than the
	# player's current position — lets _update_brachiate() below test "is there still catwalk here"
	# at a candidate spot BEFORE actually moving there, so a run off the end of a catwalk stops at
	# the edge instead of grabbing an underside that isn't there.
	var space_state := get_world_2d().direct_space_state
	var hand_pos := Vector2(x, global_position.y + hang_hand_local_offset.y)
	if is_hanging and hang_style == HangStyle.CATWALK_UNDER:
		# A crust hang is anchored crust_hang_lift px higher than the crust's collision face (roadmap 6.1), which puts the
		# hand inside the solid, and a ray that starts inside a shape never hits it: the brachiate probe found nothing
		# and the player could not move. Start the ray from where a catwalk hang's hand would be instead.
		hand_pos.y += _crust_hang_lift_for(hang_platform)
	var probe_to := hand_pos + Vector2(0.0, -catwalk_hang_probe_range)
	var query := PhysicsRayQueryParameters2D.create(hand_pos, probe_to, hang_probe_mask, [self])
	var hit := space_state.intersect_ray(query)
	# "is_catwalk" is what the grab and the brachiate test read: any underside this hang style may take, which is a
	# catwalk's or (roadmap 6.1) a basin crust's with no liquid where the hanging body would be.
	return {"from": hand_pos, "to": probe_to, "hit": hit, "is_catwalk": _is_catwalk_ray_hit(hit) or _is_free_crust_hit(hit)}

func _try_grab_catwalk_underside() -> void:
	var probe := _compute_catwalk_probe()
	if not probe.is_catwalk:
		return
	var facing := -1.0 if sprite.flip_h else 1.0
	var anchor := Vector2(global_position.x, probe.hit.position.y + catwalk_hang_grip_drop - _crust_hang_lift_for(probe.hit.collider))
	_start_catwalk_hang(facing, anchor, probe.hit.collider)

func _compute_catwalk_feet_probe() -> Dictionary:
	# Downward counterpart to _compute_catwalk_probe() above: is the player currently standing on
	# a catwalk (as opposed to plain ground)? Feeds _try_climb_down_to_catwalk_hang() below, the
	# crouch+jump climb-down entry into a catwalk hang. Uses the CURRENT collision shape, so it
	# reads correctly while crouched (same reasoning as _ladder_cell_overlapping()'s use of the
	# current shape), and reuses _is_catwalk_ray_hit()'s tile/group check so "catwalk" means
	# exactly the same thing here as it does for the airborne underside grab above.
	var space_state := get_world_2d().direct_space_state
	var feet_y := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5
	var from := Vector2(global_position.x, feet_y - 2.0)
	var to := Vector2(global_position.x, feet_y + 2.0)
	var query := PhysicsRayQueryParameters2D.create(from, to, hang_probe_mask, [self])
	var hit := space_state.intersect_ray(query)
	# "is_crust" (roadmap 6.2): standing on a basin's crust whose underside could be hung from right now, i.e. a void under
	# it with no liquid where the hanging body would be. Over liquid it is false and the ordinary crouch-jump fires.
	var crust_basin: WaterBasin = _crust_basin_of(hit.collider) if not hit.is_empty() else null
	var is_crust := crust_basin != null and _crust_hang_is_free(crust_basin, hit.position.x, crust_basin.get_crust_underside_world_y_at(hit.position.x))
	return {"hit": hit, "is_catwalk": _is_catwalk_ray_hit(hit), "is_crust": is_crust}

func _try_climb_down_to_catwalk_hang() -> void:
	# Crouch + jump on a catwalk: climb straight down into a catwalk hang on the surface already
	# underfoot, instead of the ordinary crouch-jump. Lands at the SAME hang anchor as the airborne
	# underside grab above (see the catwalk_thickness correction below) — this is just a second,
	# deliberate way in, entered from a standstill rather than from a jump that missed clearing the
	# catwalk, now animated (via _begin_catwalk_climb_down()) rather than snapping there instantly.
	# No physical drop-through is needed to get there: is_hanging skips move_and_slide() for the
	# whole transition, so there's nothing to tunnel the collider past (unlike ladder_mount_sink's
	# from-above ladder mount, which does need one, since that entry keeps moving under ordinary
	# physics afterward).
	var probe := _compute_catwalk_feet_probe()
	if not probe.is_catwalk and not probe.is_crust:
		return  # crouched on plain ground (or nothing underfoot, or crust over liquid) — leave the ordinary crouch-jump to fire

	var facing := -1.0 if sprite.flip_h else 1.0
	# probe.hit lands on the catwalk's TOP surface (that's what the feet rest on), but the airborne
	# underside grab's anchor is built from the catwalk's UNDERSIDE (_compute_catwalk_probe() is an
	# upward ray, so its first hit is the far/bottom face). Left uncorrected, this path's anchor
	# landed catwalk_thickness px higher than the airborne path's — the "climbing down lands higher
	# than jumping into it" bug. catwalk_thickness converts the top-face hit to that same underside y.
	var anchor := Vector2(global_position.x, probe.hit.position.y + catwalk_thickness + catwalk_hang_grip_drop)
	if probe.is_crust:
		# Roadmap 6.2: the hit is the crust's top; the grip is its underside there, anchored exactly as the airborne grab
		# from below anchors it (grip drop, less crust_hang_lift), so both entries hang at the same height.
		var crust_basin := _crust_basin_of(probe.hit.collider)
		anchor.y = crust_basin.get_crust_underside_world_y_at(probe.hit.position.x) + catwalk_hang_grip_drop - crust_hang_lift

	# uncrouch first — the reverse mantle animation in _begin_catwalk_climb_down() below is what
	# visibly carries the player from here down into the hang, so there's no separate reverse-crouch
	# animation needed on top of it; leaving the crouch shape/offset in place would otherwise persist
	# pointlessly into that animation
	is_crouching = false
	collision_shape.shape = standing_shape
	collision_shape.position.y -= crouch_offset_y

	_begin_catwalk_climb_down(facing, anchor, probe.hit.collider)
	jump_buffer_timer = 0.0  # this press was consumed by the climb-down, not a real jump

func _update_brachiate(input_dir: float, delta: float) -> void:
	# Hand-over-hand traverse along a catwalk's underside while HangStyle.CATWALK_UNDER, called each
	# physics frame from the is_hanging branch below whenever no one-shot hang action (mantle, let-go)
	# is in progress. No wall-check involved, same as the grab itself — just walk hang_anchor/
	# global_position sideways and re-run the same upward catwalk probe the grab used, now at the
	# candidate x, to decide whether there's still catwalk to hang from there.
	var moved := false
	if input_dir != 0.0:
		var target_x := global_position.x + input_dir * catwalk_brachiate_speed * delta
		if _compute_catwalk_probe_at(target_x).is_catwalk and not _brachiate_blocked_into(target_x):
			hang_facing = input_dir
			sprite.flip_h = input_dir < 0.0
			_update_kick_hitbox_facing()
			global_position.x = target_x
			hang_anchor.x = target_x
			moved = true
		# else: the catwalk ends here, or terrain is in the way (see _brachiate_blocked_into()) — just block further
		# travel that direction, same as walking into a wall. No teleport/edge-snap needed since the probe already tests the exact spot
		# the player is about to move to, so global_position simply never reaches past the edge.

	# Animation only actually plays while the player is displacing — held-but-blocked (stuck at the
	# end) reads as "not moving" too, same as the crouch/ladder-climb animations above freezing when
	# their own driving input nets no motion.
	if moved:
		if sprite.animation != "brachiate" or not sprite.is_playing():
			sprite.play("brachiate")
	else:
		sprite.pause()

func _brachiate_blocked_into(x: float) -> bool:
	# Whether the brachiate may NOT move to `x`: the body there would overlap terrain, and it does not already overlap
	# some here (a hang that starts embedded can still move, rather than being pinned). A hang skips move_and_slide(), so
	# without this a hang under a crust or catwalk runs on into a floor that rises to meet the underside.
	return _brachiate_blocked_at(x) and not _brachiate_blocked_at(global_position.x)

func _brachiate_blocked_at(x: float) -> bool:
	# Whether the hanging body, centred on x, would overlap solid terrain BELOW the grip surface. Only the region under
	# the underside is tested, not the whole collider: a crust hang embeds the head crust_hang_lift + grip px inside the
	# crust and a catwalk hang puts it against the tile, and neither is a blocker. Not blockers: the crust (any basin's)
	# and the platform hung from, anything in group "catwalk" (one-way, never stops sideways travel), and actors and
	# blocks (CharacterBody2D) that move themselves. Tiles of the world tilemap block unless every tile the region
	# touches is a catwalk, since one body covers a whole tilemap and a shape query cannot say which tile it hit.
	var underside := hang_anchor.y - catwalk_hang_grip_drop + _crust_hang_lift_for(hang_platform)
	var top := underside + 1.0  # a hair below the underside, so the crust or catwalk itself is never in the region
	var feet_y := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5 - catwalk_brachiate_floor_tolerance
	if feet_y <= top:
		return false
	var width := _shape_width(collision_shape.shape)
	var center := Vector2(collision_shape.global_position.x + (x - global_position.x), (top + feet_y) * 0.5)
	_brachiate_clearance_shape.size = Vector2(width, feet_y - top)
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = _brachiate_clearance_shape
	query.transform = Transform2D(0.0, center)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var region := Rect2(center - _brachiate_clearance_shape.size * 0.5, _brachiate_clearance_shape.size)
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 16):
		var collider: Object = hit.collider
		if collider == null or collider == hang_platform or collider is CharacterBody2D or _crust_basin_of(collider) != null:
			continue
		if collider is Node and (collider as Node).is_in_group("catwalk"):
			continue
		if collider is TileMapLayer and not _region_has_non_catwalk_tile(collider as TileMapLayer, region):
			continue
		return true
	return false

func _region_has_non_catwalk_tile(layer: TileMapLayer, region: Rect2) -> bool:
	# Whether any cell of `layer` that `region` (world space) touches holds a tile that is not a catwalk.
	var from_cell := layer.local_to_map(layer.to_local(region.position))
	var to_cell := layer.local_to_map(layer.to_local(region.end))
	for cx in range(from_cell.x, to_cell.x + 1):
		for cy in range(from_cell.y, to_cell.y + 1):
			var cell := Vector2i(cx, cy)
			if layer.get_cell_source_id(cell) != -1 and not SurfaceTypes.is_catwalk(SurfaceTypes.surface_at_cell(layer, cell)):
				return true
	return false

func _log_if_stuck(delta: float) -> void:
	# Diagnostic (debug_log_stuck): while not on the floor and barely moving, print once a second everything that could hold
	# the player there. Nothing here changes behaviour.
	if not debug_log_stuck:
		return
	var airborne_still := not is_on_floor() and not is_hanging and not is_climbing and not is_swimming and global_position.distance_to(_stuck_log_pos) < 2.0
	_stuck_log_pos = global_position if not airborne_still else _stuck_log_pos
	if not airborne_still:
		_stuck_log_timer = 0.0
		return
	_stuck_log_timer += delta
	if _stuck_log_timer < 1.0:
		return
	_stuck_log_timer = 0.0
	var names: Array[String] = []
	for hit in _overlapping_bodies():
		names.append("%s(%s)" % [(hit.collider as Node).name if hit.collider is Node else str(hit.collider), "crust" if _crust_basin_of(hit.collider) != null else "other"])
	print("[stuck] pos=%s vel=%s state=%s floor=%s ceil=%s wall=%s one_shot=%s crouch=%s hang_style=%s lockout=%.2f coyote=%.2f buffer=%.2f carry=%s overlaps=%s slides=%d" % [
		global_position, velocity, State.keys()[state], is_on_floor(), is_on_ceiling(), is_on_wall(), OneShotAction.keys()[one_shot_action],
		is_crouching, HangStyle.keys()[hang_style], hang_lockout_timer, coyote_timer, jump_buffer_timer, _air_carry_active, names, get_slide_collision_count()])

func _update_hang_debug_probes() -> void:
	if not debug_draw_hang_probes:
		return
	var facing := -1.0 if sprite.flip_h else 1.0
	_debug_hang_probes = _compute_hang_probes(facing)
	_debug_hang_corner = _find_ledge_corner(facing)
	_debug_catwalk_probe = _compute_catwalk_probe()
	queue_redraw()

func _draw() -> void:
	if not debug_draw_hang_probes or _debug_hang_probes.is_empty():
		return
	var forward_color := Color.RED if _debug_hang_probes.forward_hit else Color.GREEN
	var up_color := Color.RED if _debug_hang_probes.up_hit else Color.GREEN
	var f_from: Vector2 = to_local(_debug_hang_probes.forward_from)
	var f_to: Vector2 = to_local(_debug_hang_probes.forward_to)
	var u_from: Vector2 = to_local(_debug_hang_probes.up_from)
	var u_to: Vector2 = to_local(_debug_hang_probes.up_to)
	draw_line(f_from, f_to, forward_color, 1.5)
	draw_circle(f_to, 2.0, forward_color)
	draw_line(u_from, u_to, up_color, 1.5)
	draw_circle(u_to, 2.0, up_color)
	# the detected ledge corner (absent = no ledge top in reach, so no grab) and, while actually
	# hanging, the pinned hand anchor
	if _debug_hang_corner.is_finite():
		draw_circle(to_local(_debug_hang_corner), 2.0, Color.MAGENTA)
	if is_hanging:
		draw_circle(to_local(hang_anchor), 2.0, Color.CYAN)
	if not _debug_catwalk_probe.is_empty():
		# green = would grab (a real catwalk underside in range), red = blocked/nothing there —
		# same convention as the forward/up probes above, just for the single upward ray
		var catwalk_color := Color.GREEN if _debug_catwalk_probe.is_catwalk else Color.RED
		draw_line(to_local(_debug_catwalk_probe.from), to_local(_debug_catwalk_probe.to), catwalk_color, 1.5)
		if _debug_catwalk_probe.hit:
			draw_circle(to_local(_debug_catwalk_probe.hit.position), 2.0, catwalk_color)

func _tile_contact_pos(collision: KinematicCollision2D) -> Vector2:
	# the raw contact point can land exactly ON a tile boundary — hitting a tile's *left* face
	# lands on the boundary it shares with the empty space before it, and local_to_map()'s floor()
	# happens to round that INTO the tile (working by coincidence); hitting a tile's *right* face
	# lands on the boundary it shares with the (typically empty) tile beyond it, and floor() rounds
	# that into the WRONG, adjacent cell. Nudging a hair into the wall along the inward normal
	# before mapping to a tile coordinate fixes this for both directions instead of relying on
	# which side of the boundary floor() happens to favor.
	return collision.get_position() - collision.get_normal() * 0.5

func _is_hangable_surface(collision: KinematicCollision2D) -> bool:
	var collider := collision.get_collider()
	if collider == world_tilemap:
		return SurfaceTypes.is_hangable(SurfaceTypes.surface_at_point(world_tilemap, _tile_contact_pos(collision)))
	if collider is Node:
		return collider.is_in_group("ground") or collider.is_in_group("catwalk")
	return false

func _is_catwalk_ray_hit(hit: Dictionary) -> bool:
	# Same "ground" vs "catwalk" tag check as _is_hangable_surface() above, but for a raycast hit
	# (Dictionary, not a KinematicCollision2D) and deliberately narrower: ONLY "catwalk" counts, not
	# "ground". Solid ground has no meaningful underside to hang from (a raycast can still find one
	# under a low ceiling/overhang, but that's a ceiling, not something to grab); only a one-way
	# catwalk should ever produce an underside grab.
	if hit.is_empty():
		return false
	var collider = hit.collider
	if collider == world_tilemap:
		# surface_at_hit() nudges the hit position into the tile along the inward normal before mapping to a
		# cell — the same boundary-rounding issue _tile_contact_pos() exists for on the slide-collision side
		return SurfaceTypes.is_catwalk(SurfaceTypes.surface_at_hit(world_tilemap, hit.position, hit.normal))
	if collider is Node:
		return collider.is_in_group("catwalk")
	return false

func _crust_basin_of(collider: Object) -> WaterBasin:
	# Roadmap 6.1: the basin a crust body belongs to (the body is its child and joins group "crust"), else null.
	if collider is Node and (collider as Node).is_in_group("crust"):
		return (collider as Node).get_parent() as WaterBasin
	return null

func _is_free_crust_hit(hit: Dictionary) -> bool:
	# Roadmap 6.1: a raycast hit on a basin's crust from underneath that the player may hang from: there must be no
	# liquid anywhere the hanging body would be, so it only works over a void (after a drain), never in slag.
	if hit.is_empty():
		return false
	var basin := _crust_basin_of(hit.collider)
	return basin != null and _crust_hang_is_free(basin, hit.position.x, hit.position.y)

func _crust_hang_is_free(basin: WaterBasin, x: float, underside_y: float) -> bool:
	# Roadmap 6.1/6.2: whether a hang gripping the crust's underside at `underside_y` would have no liquid in the span the
	# body fills, from the grip point down to the feet the STANDING collider has there (so it reads the same whether asked
	# from below while airborne or from above while crouched, when the collider is the short one).
	var grip_y := underside_y + catwalk_hang_grip_drop - crust_hang_lift
	var feet_offset := (collision_shape.global_position.y - global_position.y) - (crouch_offset_y if is_crouching else 0.0) + _shape_height(standing_shape) * 0.5
	return basin.is_underside_free(x, grip_y, grip_y - hang_hand_local_offset.y + feet_offset)

func _hang_crust_blocked() -> bool:
	# Roadmap 6.1: true while hanging from crust and liquid has come up into the space the body fills (a faucet refilling
	# the basin under it): the hang lets go. Always false for a catwalk or a ledge hang.
	var basin := _crust_basin_of(hang_platform)
	if basin == null:
		return false
	var feet_y := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5
	return not basin.is_underside_free(global_position.x, hang_anchor.y, feet_y)

func _unembed_from_crust() -> void:
	# A crust hang anchors the head crust_hang_lift + grip px INSIDE the crust's collider (the hang skips move_and_slide(), so
	# nothing resolves it). Let go there and move_and_slide() has to depenetrate: with a 4 px capsule next to a seam between
	# two column quads (the crust is one quad per tile column) it can't, and the body stays jammed with wall contacts while
	# gravity piles up an unbounded velocity.y. So any body whose collider overlaps a crust and whose centre is already below
	# the crust's underside is moved straight down until its top is just clear of it, before it moves. A body standing on a
	# crust (centre above the underside) is never touched, and neither is one rotated for the swim pose.
	if _swim_rotated:
		return
	var top_y := collision_shape.global_position.y - _shape_height(collision_shape.shape) * 0.5
	var shift := 0.0
	for hit in _overlapping_bodies():
		var basin := _crust_basin_of(hit.collider)
		if basin == null:
			continue
		if hit.collider == _crust_pass_body:
			continue  # the body is jumping up through this crust on purpose (see _update_crust_pass())
		if basin.is_player_embedded():
			continue  # a frozen crust formed around the player: they swim up through it (WaterBasin.get_swim_surface_world_y())
		var underside := _crust_underside_under_body(basin)
		if underside == -INF or collision_shape.global_position.y <= underside or top_y >= underside:
			continue
		shift = maxf(shift, underside - top_y + UNEMBED_CLEARANCE)
	if shift > 0.0:
		global_position.y += shift
		_reset_teleport_interpolation()

func _crust_underside_under_body(basin: WaterBasin) -> float:
	# The lowest crust bottom across the collider's width (neighbouring columns can differ), or -INF where the basin has no
	# crust under the body at all.
	var half_w := _shape_width(collision_shape.shape) * 0.5
	var underside := -INF
	for dx in [-half_w, 0.0, half_w]:
		var y := basin.get_crust_underside_world_y_at(global_position.x + dx)
		if y != INF:
			underside = maxf(underside, y)
	return underside

func _jump_up_through_underside() -> void:
	# A jump from a catwalk or crust underside hang goes UP through it, the way a rail hang's jump leaves the rail (the
	# ledge jump pushes off its wall and is separate). No lockout: the underside grab only takes a body that is falling
	# (catwalk_hang_min_fall_speed), so the rise cannot re-catch, and a jump that falls short (a low ceiling above)
	# catches the underside again on the way down. A catwalk is one-way, so the body rises through it by itself. Crust is
	# solid, so the body gets a collision exception with that crust until it is clear (see _update_crust_pass()).
	velocity = Vector2(0.0, jump_velocity)
	hang_lockout_timer = 0.0
	_skip_buffered_jump = true  # this press was the jump: the buffered-jump consume later this frame must not fire again
	if _crust_basin_of(hang_platform) != null:
		_crust_pass_body = hang_platform
		add_collision_exception_with(_crust_pass_body)
	Audio.play(&"player/jump")

func _update_crust_pass() -> void:
	# Ends the collision exception _jump_up_through_underside() set once the body no longer needs it: its feet are above the
	# crust's collision top (the crust is solid again, so a landing on it works), or its head is below the crust's underside
	# (a short jump fell back out of it; the catwalk grab then re-catches the underside on the way down), or it has gone
	# somewhere the crust is not at all (sideways out of the basin, a hang, a ladder, the water). Until then it stays on, even
	# through a hit, so a body knocked about inside the crust is never left embedded in a solid it collides with.
	if _crust_pass_body == null:
		return
	var basin := _crust_basin_of(_crust_pass_body) if is_instance_valid(_crust_pass_body) else null
	var done := basin == null or is_hanging or is_climbing or is_swimming
	if not done:
		var top_y := collision_shape.global_position.y - _shape_height(collision_shape.shape) * 0.5
		var feet_y := top_y + _shape_height(collision_shape.shape)
		var underside := _crust_underside_under_body(basin)
		done = feet_y <= basin.get_crust_collision_top_world_y() or underside == -INF or top_y >= underside
	if done:
		_end_crust_pass()

func _end_crust_pass() -> void:
	if _crust_pass_body != null and is_instance_valid(_crust_pass_body):
		remove_collision_exception_with(_crust_pass_body)
	_crust_pass_body = null

func _overlapping_bodies() -> Array[Dictionary]:
	# Everything the current collider overlaps right now (up to 8 hits), regardless of one-way flags.
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = collision_shape.global_transform
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var out: Array[Dictionary] = []
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 8):
		out.append(hit)
	return out

func _crust_hang_lift_for(collider: Object) -> float:
	# Roadmap 6.1: crust_hang_lift for a crust collider, 0 for anything else (a catwalk's anchor is unchanged).
	return crust_hang_lift if _crust_basin_of(collider) != null else 0.0

func _crust_mantle_target() -> Vector2:
	# Roadmap 6.1: where a mantle up from a crust hang ends, or Vector2.INF when the hang isn't from crust. A catwalk's
	# target is its underside + catwalk_hang_grip_drop + catwalk_mantle_offset.y, i.e. its top face + catwalk_thickness +
	# those two; crust is thicker and its anchor is raised by crust_hang_lift, so the same formula is applied to the
	# crust's own collision top (where the feet actually rest) and the feet land on it exactly.
	var basin := _crust_basin_of(hang_platform)
	if basin == null:
		return Vector2.INF
	var y := basin.get_crust_collision_top_world_y() + catwalk_thickness + catwalk_hang_grip_drop + catwalk_mantle_offset.y
	return Vector2(hang_anchor.x + catwalk_mantle_offset.x, y)

func _set_hang_platform(collider: Object) -> void:
	# Shared by every hang-start path (ledge grab, catwalk underside grab, catwalk climb-down):
	# records both the platform reference AND its position at the moment of grab, so
	# _follow_hang_platform()'s "how far did it move since last frame" delta starts at zero instead
	# of comparing against a stale position left over from whatever the LAST hang's platform was.
	# _start_hang() already did this inline; _start_catwalk_hang() never did — a latent bug (only
	# surfaces once a catwalk is itself a moving AnimatableBody2D, which none built so far are) that
	# would have caused a one-frame jump equal to however far that previous platform moved since its
	# own hang ended. Fixed by routing every hang-start through this one place instead of three
	# separate copies of the same two lines.
	hang_platform = collider as PhysicsBody2D  # `as` yields null for tiles
	if hang_platform:
		_hang_platform_last_xf = hang_platform.global_transform

func _start_hang(facing: float, corner: Vector2, platform: PhysicsBody2D = null) -> void:
	is_hanging = true
	hang_style = HangStyle.LEDGE  # must be reset here: _start_catwalk_hang()/_begin_catwalk_climb_down()
		# both set this to CATWALK_UNDER and nothing else ever sets it back, so without this an
		# ordinary ledge grab right after any catwalk hang would inherit CATWALK_UNDER and mantle
		# using catwalk_mantle_offset instead of mantle_offset — the "ledge mantle lands several
		# pixels above the ledge" bug. Latent since hang_style was introduced (item 62); only
		# surfaced once catwalk hangs actually got used enough to leave this stuck.
	hang_facing = facing
	velocity = Vector2.ZERO
	_set_hang_platform(platform)

	# nudge from the raw geometric corner to where the hand should actually grip (slightly
	# onto the top surface, slightly off the wall face), then place the player so the sprite's
	# hand pixel (hang_hand_local_offset) lands exactly on that point
	hang_anchor = corner + Vector2(-facing * hang_grip_inset, -hang_grip_lift)
	global_position = hang_anchor - Vector2(hang_hand_local_offset.x * facing, hang_hand_local_offset.y)
	_reset_teleport_interpolation()  # this is a hard teleport, not continuous motion — if Physics
		# Interpolation is on (Project Settings > Physics > Common), skipping this resets renders one
		# blended frame between the pre-grab and post-grab position, which looks like the world
		# flashing toward the player and snapping back. Must reset the camera too, not just self —
		# see _reset_teleport_interpolation()

	sprite.flip_h = facing < 0.0
	_update_kick_hitbox_facing()  # keeps KickHitbox correct if the player kicks right after a
		# mantle without any movement input in between to otherwise trigger the update
	sprite.play("hang")
	Audio.play(&"player/hang")

func _start_catwalk_hang(facing: float, anchor: Vector2, collider: Object) -> void:
	# Counterpart to _start_hang() above for the catwalk-underside grab. Sets hang_style so mantle
	# and the let-go jump know to treat this differently; everything else about being "hanging"
	# (is_hanging itself, the move_and_slide skip, moving-platform follow, the hurt/interrupt
	# teardown) is shared as-is with zero changes, since it was already generic over how the hang
	# started. No facing-based x offset here — anchor is already the overhead grip point directly
	# above wherever the player was, not a sideways corner grip.
	is_hanging = true
	hang_style = HangStyle.CATWALK_UNDER
	hang_facing = facing  # kept for bookkeeping/kick-hitbox facing only; not used to offset the grip
	velocity = Vector2.ZERO
	_set_hang_platform(collider)  # non-null only if this catwalk is itself a moving node

	hang_anchor = anchor
	global_position = hang_anchor - Vector2(hang_hand_local_offset.x * facing, hang_hand_local_offset.y)
	_reset_teleport_interpolation()  # same hard-teleport reasoning as _start_hang() above

	sprite.flip_h = facing < 0.0
	_update_kick_hitbox_facing()
	_start_brachiate_pose()

func _start_brachiate_pose() -> void:
	# Shared by every catwalk-hang entry point (airborne grab, climb-down finish): initializes on
	# "brachiate"'s own first frame, frozen, rather than the sideways ledge's "hang" pose — the two
	# grips look nothing alike (overhead vs. side-on), and this is what item 62 flagged as a TODO
	# before "brachiate" existed. _update_brachiate() takes over from here once horizontal input
	# actually starts the player moving; until then this stays paused on frame 0.
	if sprite.sprite_frames.has_animation("brachiate"):
		sprite.play("brachiate")
		sprite.frame = 0
		sprite.pause()
	else:
		push_warning("No 'brachiate' animation in SpriteFrames — catwalk hang falls back to 'hang'")
		sprite.play("hang")
	Audio.play(&"player/hang")

func _begin_catwalk_climb_down(facing: float, anchor: Vector2, collider: Object) -> void:
	# Animated counterpart to _start_catwalk_hang() above, used by the crouch+jump climb-down entry
	# (item 63) instead of the instant snap: plays the SAME "climb_up" animation used to mantle up
	# through a catwalk, but backward, while the position eases down into the grip — the reverse of
	# climbing up, as requested, rather than either a plain instant snap or a hand-authored second
	# animation. Structured as a two-phase begin/finish pair exactly like _begin_mantle()/
	# _finish_mantle() below (down to reusing their mantle_target/_mantle_start/_mantle_tween/
	# _mantle_step machinery — already generic over "the position being tweened toward," so it needed
	# no changes to serve both directions). All of the hang's usual bookkeeping and protections
	# (is_hanging itself, the move_and_slide skip, the horizontal-movement lock, moving-platform
	# follow, the hurt/interrupt teardown) are set up immediately, exactly as _start_catwalk_hang()
	# would set them — only the visible position snap and the "hang" pose/sound are deferred to
	# _finish_catwalk_climb_down(), once the reverse animation has actually finished playing.
	is_hanging = true
	hang_style = HangStyle.CATWALK_UNDER
	hang_facing = facing
	velocity = Vector2.ZERO
	_set_hang_platform(collider)
	hang_anchor = anchor

	sprite.flip_h = facing < 0.0
	_update_kick_hitbox_facing()

	one_shot_action = OneShotAction.CLIMBING_DOWN
	Audio.play(&"player/mantle")  # reusing the mantle effort sound; there's no dedicated climb-down
		# sound yet — flagged per the project's "clunky but functional, don't ship silently" convention
	mantle_target = hang_anchor - Vector2(hang_hand_local_offset.x * facing, hang_hand_local_offset.y)

	if sprite.sprite_frames.has_animation("climb_up"):
		var frame_count := sprite.sprite_frames.get_frame_count("climb_up")
		var fps := sprite.sprite_frames.get_animation_speed("climb_up")
		# Start partway through instead of at the true last frame, skipping
		# catwalk_climb_down_skip_end_frames off the end (climb_up's tail is the legs settling after
		# landing on top — nothing to reverse into here, since the climb-down starts already standing).
		var start_frame := maxi(frame_count - 1 - catwalk_climb_down_skip_end_frames, 0)
		sprite.play("climb_up", -1.0, true)  # negative speed + from_end = true: Godot's built-in way
			# to play an animation backward — no separate reversed-duplicate animation resource
			# needed to get the reverse motion requested. from_end lands on the true last frame first;
			# overriding .frame right after moves the actual starting point earlier per the skip above.
		sprite.frame = start_frame
		var played_frames := start_frame + 1  # start_frame down through 0 inclusive
		var duration := float(played_frames) / fps if fps > 0.0 else 0.0
		if duration > 0.0:
			_mantle_start = global_position
			_mantle_tween = create_tween()
			_mantle_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			_mantle_tween.tween_method(_mantle_step, 0.0, 1.0, duration/2)  # same duration/2 ratio
				# _begin_mantle() uses below; kept consistent rather than re-deriving a separate
				# number just for this direction — retune both together if that ratio ever changes
		else:
			global_position = mantle_target
			_reset_teleport_interpolation()
	else:
		push_warning("No 'climb_up' animation in SpriteFrames — catwalk climb-down snapping instantly with no transition; add one for a smoother entry")
		_finish_catwalk_climb_down()

func _finish_catwalk_climb_down() -> void:
	# Counterpart to _finish_mantle() below, for the reverse direction: snaps to the exact grip point
	# regardless of any small tween/animation-length mismatch, same self-correcting reasoning, then
	# starts the brachiate pose/sound that _start_catwalk_hang() would normally start immediately —
	# deferred until now so they land exactly when the reverse animation finishes, not before it.
	global_position = mantle_target
	_reset_teleport_interpolation()
	one_shot_action = OneShotAction.NONE
	_start_brachiate_pose()

func _mantle_step(t: float) -> void:
	global_position = _mantle_start.lerp(mantle_target, t)

func _follow_hang_platform() -> void:
	# Hang is pinned in world space (hang_anchor / mantle_target), so riding a moving ledge just means
	# carrying every pinned point along with the platform since last frame: the platform's change of
	# transform is applied to each point, which for a plain sliding platform is the old translation, and for
	# a rotating block (stage 3) swings the hang with it. Covers the whole hang including the mantle
	# sub-state (is_hanging stays true until _finish_mantle).
	if hang_platform == null:
		return
	if not is_instance_valid(hang_platform):
		hang_platform = null  # freed mid-hang: stay pinned where we are
		return
	if hang_platform.has_method(&"is_hangable") and not hang_platform.call(&"is_hangable"):
		_force_release_hang()  # a rotating block tilted or sped up past what can be held
		return
	var xf := hang_platform.global_transform
	if xf == _hang_platform_last_xf:
		return
	var change := xf * _hang_platform_last_xf.affine_inverse()
	_hang_platform_last_xf = xf
	global_position = change * global_position
	hang_anchor = change * hang_anchor
	mantle_target = change * mantle_target
	_mantle_start = change * _mantle_start

func release_hang_from_layer(layer: TileMapLayer) -> void:
	# Called by a PoweredCatwalkLayer as it retracts (duck-typed). A tile hang has no platform to follow (hang_platform is
	# null for a tile), so without this the player would stay pinned in the air under a catwalk that is gone. Lets go (and
	# stops a mantle onto it) only if the grip point, a pixel inside the underside, is in one of that layer's cells.
	if not is_hanging or hang_style != HangStyle.CATWALK_UNDER or hang_platform != null:
		return
	var underside := hang_anchor.y - catwalk_hang_grip_drop
	var cell := layer.local_to_map(layer.to_local(Vector2(hang_anchor.x, underside - 1.0)))
	if layer.get_cell_source_id(cell) != -1:
		_force_release_hang()

func _force_release_hang() -> void:
	# The platform made the hang untenable (see MeltableBlock.is_hangable()): let go the way crouch does, plus
	# stopping a mantle already under way, and don't instantly re-grab.
	if _mantle_tween and _mantle_tween.is_valid():
		_mantle_tween.kill()
	_mantle_tween = null
	one_shot_action = OneShotAction.NONE
	is_hanging = false
	hang_platform = null
	_detach_swing()
	_detach_rail()
	hang_lockout_timer = hang_regrab_lockout

# --- surf ---------------------------------------------------------------------------------------------------------
# Held state (is_surfing), mounted with kick while crouching, dismounted with kick again. Stage 1: the board runs at a
# speed along the locked facing, losing `surf_friction` on the ground and nothing in the air; it keeps the crouch collider
# throughout, and the airborne part reuses the shared air carry (non-steering) so landing resumes the surf. Exits: kick,
# a hit/launch/swing grab/water (all via _end_surf(false)), or the speed falling below surf_min_speed on the ground.

func _begin_air_carry(vx: float, steers: bool) -> void:
	_air_carry_vx = vx
	_air_carry_steers = steers
	_air_carry_active = true

func _start_surf() -> void:
	is_surfing = true
	_surf_facing = -1.0 if sprite.flip_h else 1.0
	_surf_speed = surf_start_speed
	_air_carry_active = false
	_surf_tilt_sign = 0
	_surf_board_angle = 0.0
	_surf_jump_pending = false
	_reset_surf_scoring()
	velocity.x = _surf_facing * _surf_speed
	_surf_prev_velocity = Vector2(velocity.x, 0.0)
	_surf_belt_vx = 0.0
	if surf_board != null:
		surf_board.visible = true
		_update_surf_board()
	_surf_wetness = 0.0
	_surf_on_skim = false
	_skim_was_on = false
	if _surf_loop != null:
		_surf_loop.start()
	if _surf_water_loop != null:
		_surf_water_loop.start()
	_surf_steam_lift = 0.0
	if _surf_steam_loop != null:
		_surf_steam_loop.start()
	Audio.play(&"player/surf_start")
	state = State.SURF
	_play_animation_for_state()

## Ends the surf. `keep_momentum`: a dismount, which in the air hands the board's speed to a steering carry; on the
## ground it just stops (the crouch logic then stands the player up). Everything else ends with the momentum dropped.
func _end_surf(keep_momentum: bool) -> void:
	if not is_surfing:
		return
	var airborne_vx := _air_carry_vx if _air_carry_active else _surf_facing * _surf_speed
	is_surfing = false
	_surf_speed = 0.0
	_surf_belt_vx = 0.0
	_surf_jump_pending = false
	_reset_surf_scoring()
	if surf_board != null:
		surf_board.visible = false
	if _surf_loop != null:
		_surf_loop.stop_loop()
	if _surf_water_loop != null:
		_surf_water_loop.stop_loop()
	if _surf_steam_loop != null:
		_surf_steam_loop.stop_loop()
	_surf_steam_lift = 0.0
	_release_skim_floor()
	_surf_wetness = 0.0
	_surf_on_skim = false
	_skim_was_on = false
	if keep_momentum and not is_on_floor():
		_begin_air_carry(airborne_vx, true)
	else:
		_air_carry_active = false
	if not is_on_floor():
		_stand_up_instantly()  # in the air there is no uncrouch animation: the normal one-shot would also cancel the carry

## Restores the standing collider at once (no UNCROUCHING one-shot), if there is room; otherwise stays crouched and the
## normal crouch logic stands up later, as _interrupt_current_action() does.
func _stand_up_instantly() -> void:
	if is_crouching and _can_stand_up():
		is_crouching = false
		collision_shape.shape = standing_shape
		collision_shape.position.y -= crouch_offset_y

## The surf's velocity for this frame (called from the horizontal movement block). On the ground the velocity is the
## floor's tangent times `_surf_speed`, so the board follows slopes and a ramp lip launches by itself (an upward tangent
## suppresses the floor snap). Left/right pick the board's tilt; matching the ground's sign is what keeps the speed.
func _surf_move(delta: float, input_dir: float) -> void:
	_surf_tilt_sign = 0 if absf(input_dir) < SURF_TILT_DEADZONE else int(-signf(input_dir) * _surf_facing)
	_update_surf_wetness(delta)
	_update_surf_steam_lift(delta)
	_surf_bowl_chain_timer = maxf(_surf_bowl_chain_timer - delta, 0.0)
	if _air_carry_active:
		_surf_air_time += delta
	var depart := false
	var jumped := false
	var steamed := false  # leaving the floor because the steam out-lifts gravity
	if _surf_jump_pending:
		_surf_jump_pending = false
		depart = true
		jumped = true
	elif not is_on_floor() and not _air_carry_active:
		depart = true  # rolled off a ledge or a ramp lip
	elif is_on_floor() and not _air_carry_active and surf_steam_lift * _surf_steam_lift > gravity:
		depart = true  # steam lifts the board off the floor
		steamed = true
	if depart:
		var from_ground := not _air_carry_active  # false: a coyote jump just after leaving, already airborne
		if from_ground:
			_surf_air_time = 0.0  # a coyote jump keeps counting from the moment the board left the floor
		var v := _surf_prev_velocity if from_ground else Vector2(_air_carry_vx, _surf_prev_velocity.y)
		if steamed:
			# No launch bias: the steam, not the tilt, takes the board off. The ground branch writes the velocity along the
			# floor, which downhill points into it, so keep only its upward part: the floor snap is off while moving up.
			v.y = minf(v.y, 0.0) + gravity * delta  # the floor frame skipped gravity; the lift below then nets out against it
		elif from_ground:
			v = _surf_launch_bias(v)
		if jumped:
			v.y = (v.y if from_ground else 0.0) + jump_velocity * surf_jump_boost
		velocity = v
		_begin_air_carry(v.x, false)  # non-steering: the shared carry holds the horizontal speed until landing
	elif is_on_floor() and not _air_carry_active:
		var n := _surf_floor_normal()
		var t := Vector2(-n.y, n.x) * _surf_facing  # t.y < 0 is uphill
		var friction := lerpf(surf_friction, surf_friction_wet, _surf_wetness) * _surf_floor_friction_scale()
		var accel := gravity * t.y * surf_slope_gain - friction - _surf_mismatch_drag(_surf_ground_sign(t))
		if _surf_on_skim:
			accel -= surf_skim_drag
		_surf_speed = clampf(_surf_speed + accel * delta, 0.0, _surf_top_speed())
		# A belt is a moving floor: friction, slope gain and the top speed stay relative to it (they act on the board's
		# own speed), the belt's speed adds on top of the ground velocity (the shared conveyor line in _physics_process()
		# does that add), and the speed over the ground along the travel direction is _surf_speed + belt * facing.
		_surf_belt_vx = _conveyor_push_speed()
		if _surf_speed < surf_min_speed or _surf_speed + _surf_belt_vx * _surf_facing < surf_min_speed:
			_end_surf(false)  # ran out of speed, hit a wall, or a belt against the board stalled it: stand up through the normal crouch logic
			velocity = Vector2.ZERO
			_surf_prev_velocity = Vector2.ZERO
			return
		_award_surf_skim(_surf_speed * delta)
		velocity = t * _surf_speed - n * SURF_FLOOR_PRESS
		_surf_prev_velocity = t * _surf_speed + Vector2(_surf_belt_vx, 0.0)  # the pure tangent plus the belt, without the press: what a launch or a landing should read
		return
	else:
		velocity.x = _air_carry_vx
	_apply_surf_steam_lift(delta)
	_surf_belt_vx = 0.0
	_surf_prev_velocity = velocity

## Smooths the steam under the board (WaterManager.get_steam_lift(): instant rise, linear decay) from the collider's rect,
## which while surfing is the board's footprint. Only the surf calls it, so the walking player, a swimmer and blocks never
## feel steam.
func _update_surf_steam_lift(delta: float) -> void:
	if water_manager == null:
		_surf_steam_lift = 0.0
		return
	var size := Vector2(_shape_width(collision_shape.shape), _shape_height(collision_shape.shape))
	_surf_steam_lift = water_manager.get_steam_lift(Rect2(collision_shape.global_position - size * 0.5, size), _surf_steam_lift, delta)

## The steam's upward acceleration for an airborne board (gravity already applied this frame), stopping at
## `surf_steam_max_rise`. A solid ceiling still stops the board: the lift only writes the velocity, move_and_slide()
## does the colliding.
func _apply_surf_steam_lift(delta: float) -> void:
	var lift := surf_steam_lift * _surf_steam_lift
	if lift <= 0.0 or velocity.y <= -surf_steam_max_rise:
		return
	velocity.y = maxf(velocity.y - lift * delta, -surf_steam_max_rise)

## A jump pad's launch while surfing (applied last in _physics_process(), see launch()): the pad's vertical part replaces the
## vertical velocity and its horizontal part is added to the board's horizontal velocity, so a straight-up pad sends the
## board up at the speed it was going. The result goes to the shared non-steering air carry, like a ramp lip, so the
## carry's per-frame velocity.x rewrite keeps the pad's push, and into _surf_prev_velocity for the landing. The tilt's
## launch bias isn't applied: the pad's own direction is the launch.
func _apply_surf_launch(vector: Vector2) -> void:
	if not _air_carry_active:
		_surf_air_time = 0.0  # launched from the floor: the air time starts here (already airborne: it keeps counting)
	var carried_vx := _air_carry_vx if _air_carry_active else velocity.x
	var out := Vector2(carried_vx + vector.x, vector.y)
	velocity = out
	_begin_air_carry(out.x, false)
	_surf_prev_velocity = out
	_surf_jump_pending = false
	_surf_belt_vx = 0.0

## The floor normal with near-flat normals snapped to exactly flat.
func _surf_floor_normal() -> Vector2:
	var n := get_floor_normal()
	return Vector2.UP if absf(n.x) < SURF_FLAT_NORMAL_X else n

## The floor's tangent in the travel direction (t.y < 0 is uphill).
func _surf_floor_tangent() -> Vector2:
	var n := _surf_floor_normal()
	return Vector2(-n.y, n.x) * _surf_facing

## The surf's current speed, px/s: the speed over the ground (the board's own speed plus a conveyor's share along the
## travel direction), or the horizontal carried speed in the air; 0 when not surfing.
## Public: the bowl threshold uses it, and the speed trap will.
func get_surf_speed() -> float:
	if not is_surfing:
		return 0.0
	if _air_carry_active:
		return absf(_air_carry_vx)
	return maxf(_surf_speed + _surf_belt_vx * _surf_facing, 0.0)  # over the ground: a belt with the board adds, one against takes away

## Bowling, run each frame just before move_and_slide() while surfing: at or above `surf_bowl_speed`, finds the
## actor bodies in the box this frame's motion will sweep (plus SURF_BOWL_LEAD ahead) and calls the optional
## `bowled_over(direction, surf_speed) -> bool` on each. An enemy opts in by having that method and decides for itself
## (Drillbot refuses from its drill side); one that returns false is left alone and stays solid. A swept query instead of
## a KickHitbox-style Area2D because the Area's overlap would only be seen a step late, after the player had already
## stopped against a solid target; and bowled bodies get a collision exception at once (a body only disables its own
## shape with set_deferred, which is too late for this frame's move).
func _surf_bowl_sweep(delta: float) -> void:
	var speed_now := get_surf_speed()
	if speed_now < surf_bowl_speed:
		return
	var half := Vector2(_shape_width(collision_shape.shape), _shape_height(collision_shape.shape)) * 0.5
	var motion := velocity * delta
	var start := collision_shape.global_position
	var lo := Vector2(minf(start.x, start.x + motion.x), minf(start.y, start.y + motion.y)) - half
	var hi := Vector2(maxf(start.x, start.x + motion.x), maxf(start.y, start.y + motion.y)) + half
	if _surf_facing > 0.0:
		hi.x += SURF_BOWL_LEAD
	else:
		lo.x -= SURF_BOWL_LEAD
	var box := RectangleShape2D.new()
	box.size = hi - lo
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = box
	query.transform = Transform2D(0.0, (lo + hi) * 0.5)
	query.collision_mask = SURF_BOWL_MASK
	query.exclude = [get_rid()]
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 8):
		var body := hit.get("collider") as PhysicsBody2D
		if body == null or _surf_shoved_bodies.has(body.get_instance_id()):  # already shoved and its exception still held: don't shove (or charge) it again
			continue
		if body.has_method("bowled_over") and body.bowled_over(_surf_facing, speed_now):
			add_collision_exception_with(body)
			Audio.play_at(&"player/surf_bowl", body.global_position, 4.0)
			if body.is_in_group("enemy"):
				_award_surf_bowl()  # enemies only: a barrier is a route obstacle, not a skill
		elif body.has_method("surf_shoved") and _surf_shove_reaches(body, Vector2(lo.x, start.y - half.y), Vector2(hi.x, start.y + half.y - SURF_SHOVE_FOOT_CLEARANCE)):
			var cost: float = body.surf_shoved(_surf_facing, speed_now)
			if cost >= 0.0:  # negative = refused: the body stays solid and stops the surf like a wall
				_apply_surf_shove_cost(cost)
				add_collision_exception_with(body)
				_surf_shoved_bodies[body.get_instance_id()] = {"body": body, "touched": false, "age": 0.0}

## True if `body` overlaps the box from `lo` to `hi` (world space). The shove test uses the player's own height with the
## feet trimmed and no vertical motion, so only a block in front of the board counts, not one it stands or lands on.
func _surf_shove_reaches(body: PhysicsBody2D, lo: Vector2, hi: Vector2) -> bool:
	var box := RectangleShape2D.new()
	box.size = hi - lo
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = box
	query.transform = Transform2D(0.0, (lo + hi) * 0.5)
	query.collision_mask = SURF_BOWL_MASK
	query.exclude = [get_rid()]
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 8):
		if hit.get("collider_id") == body.get_instance_id():
			return true
	return false

## Surf contract, shove half: `surf_shoved(direction, surf_speed) -> float` is the optional second contract (a block
## that takes the surf's speed as its own motion). It returns the surf speed the shove cost, or a negative number to
## refuse (immovable, or blocked ahead), in which case the surf stops against it. The cost comes off the ground speed
## or the carried air speed from the next frame's velocity (this frame's was already computed).
func _apply_surf_shove_cost(cost: float) -> void:
	if _air_carry_active:
		var vx := maxf(absf(_air_carry_vx) - cost, 0.0)
		_air_carry_vx = signf(_air_carry_vx) * vx if _air_carry_vx != 0.0 else 0.0
	else:
		_surf_speed = maxf(_surf_speed - cost, 0.0)

## Drops the collision exception with each shoved body once the player's collider (grown by SURF_SHOVE_CLEAR_MARGIN)
## has overlapped it and then no longer does. A block is solid and only gets out of the way over many frames, so the
## surfer passes through it on an exception and the block becomes solid again behind. The exception is added while the
## block is still up to a frame's motion plus SURF_BOWL_LEAD ahead, before any overlap, so a body is only released
## after it has been touched (otherwise the exception would drop the next frame, the sweep would shove and charge it
## again, and the board would be slowed every frame of the approach and then stopped by the solid block); one that
## never gets touched is released after SURF_SHOVE_GIVE_UP. intersect_shape() ignores collision exceptions, so this
## sees the overlap they hide.
func _update_surf_shove_exceptions(delta: float) -> void:
	if _surf_shoved_bodies.is_empty():
		return
	var overlapping := {}
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = collision_shape.global_transform
	query.margin = SURF_SHOVE_CLEAR_MARGIN
	query.collision_mask = SURF_BOWL_MASK
	query.exclude = [get_rid()]
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 16):
		overlapping[hit.get("collider_id")] = true
	for id in _surf_shoved_bodies.keys():
		var entry: Dictionary = _surf_shoved_bodies[id]
		var body := entry["body"] as PhysicsBody2D
		if not is_instance_valid(body):
			_surf_shoved_bodies.erase(id)
			continue
		entry["age"] += delta
		if overlapping.has(id):
			entry["touched"] = true
		elif entry["touched"] or entry["age"] > SURF_SHOVE_GIVE_UP:
			remove_collision_exception_with(body)
			_surf_shoved_bodies.erase(id)

## +1 uphill, -1 downhill, 0 flat, for a travel-direction tangent.
func _surf_ground_sign(t: Vector2) -> int:
	var degrees := rad_to_deg(atan2(-t.y, maxf(absf(t.x), 0.0001)))
	if absf(degrees) < surf_flat_threshold_degrees:
		return 0
	return 1 if degrees > 0.0 else -1

## Extra deceleration from the tilt: none when its sign matches the ground's, `surf_drag_level` for a level board on a
## slope, `surf_drag_wrong` for any other mismatch.
func _surf_mismatch_drag(ground_sign: int) -> float:
	if _surf_tilt_sign == ground_sign:
		return 0.0
	return surf_drag_level if _surf_tilt_sign == 0 else surf_drag_wrong

## Rotates the velocity the board leaves the ground with by the tilt: nose up pops it upward, nose down dives it, level
## leaves it alone. Magnitude is kept.
func _surf_launch_bias(v: Vector2) -> Vector2:
	var degrees := 0.0
	if _surf_tilt_sign > 0:
		degrees = surf_launch_pop_degrees
	elif _surf_tilt_sign < 0:
		degrees = -surf_launch_dive_degrees
	return v.rotated(-deg_to_rad(degrees) * _surf_facing)  # up is -angle moving right, +angle moving left

## Touchdown on the board after an air carry: sets the ground speed from the arrival velocity along the new floor's
## tangent (what is into the floor is lost), cut by the tilt mismatch and capped at the top speed, and pays the clean
## landing. *Clean* = the tilt's sign matches the ground's (level on the flat, nose down on a downhill, nose up on an
## uphill). A mismatch costs speed (`surf_landing_level` / `surf_landing_wrong`). A clean landing after at least
## `surf_landing_min_air_time` is *earned*: on a slope it multiplies the speed by `surf_landing_clean_bonus`, on a downhill
## it also adds `surf_landing_downhill_convert` of the speed that was going into the floor (fall speed becomes forward
## speed, so dips and half-pipes chain), and on any floor it pays the landing points. The flat gets no speed bonus (a level
## board is the default there, so it would be free) and the minimum air time is above a plain hop, so hopping pumps neither
## speed nor points; the top-speed cap bounds the rest.
func _surf_touchdown() -> void:
	_update_surf_wetness(0.0)  # the floor just reached may be wet, which raises the cap
	var t := _surf_floor_tangent()
	var ground_sign := _surf_ground_sign(t)
	var clean := _surf_tilt_sign == ground_sign
	var earned := clean and _surf_air_time >= surf_landing_min_air_time
	var along := maxf(_surf_prev_velocity.dot(t), 0.0)
	if not clean:
		along *= surf_landing_level if _surf_tilt_sign == 0 else surf_landing_wrong
	elif earned and ground_sign != 0:
		along *= surf_landing_clean_bonus
		if ground_sign < 0:
			along += surf_landing_downhill_convert * maxf(-_surf_prev_velocity.dot(_surf_floor_normal()), 0.0)
	_surf_speed = minf(along, _surf_top_speed())
	if earned:
		_award_surf_landing()
	_surf_air_time = 0.0

## The clean landing's reward: the highest tier whose air time was reached (`surf_landing_points` against
## `surf_landing_points_air_times`), through add_points() so the popup plays like a gem's.
func _award_surf_landing() -> void:
	var tier := -1
	for i in mini(surf_landing_points.size(), surf_landing_points_air_times.size()):
		if _surf_air_time >= surf_landing_points_air_times[i]:
			tier = i
	if tier >= 0:
		add_points(surf_landing_points[tier])
	Audio.play(&"player/surf_land_clean")

## An enemy bowled by the surf: continues the chain if the last one was within `surf_bowl_chain_window`, else starts one.
## The points step up the chain through `surf_bowl_points` (the last entry repeats).
func _award_surf_bowl() -> void:
	_surf_bowl_chain = _surf_bowl_chain + 1 if _surf_bowl_chain_timer > 0.0 else 1
	_surf_bowl_chain_timer = surf_bowl_chain_window
	if not surf_bowl_points.is_empty():
		add_points(surf_bowl_points[mini(_surf_bowl_chain, surf_bowl_points.size()) - 1])

## Skim distance: `surf_skim_points` each time `surf_skim_points_distance` px have been skimmed in the run (the remainder
## carries over; leaving the surface doesn't clear it).
func _award_surf_skim(distance: float) -> void:
	if not _surf_on_skim or surf_skim_points_distance <= 0.0:
		return
	_surf_skim_distance += distance
	if _surf_skim_distance >= surf_skim_points_distance:
		_surf_skim_distance -= surf_skim_points_distance
		add_points(surf_skim_points)

func _reset_surf_scoring() -> void:
	_surf_air_time = 0.0
	_surf_bowl_chain = 0
	_surf_bowl_chain_timer = 0.0
	_surf_skim_distance = 0.0

## Puts the board under the feet, facing the way the player faces, tilted to the current tilt target (it eases there).
func _update_surf_board() -> void:
	if surf_board == null or not surf_board.visible:
		return
	var feet_y := collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5
	surf_board.global_position = Vector2(global_position.x, feet_y)
	surf_board.scale.x = _surf_facing
	var target := 0.0
	if _surf_tilt_sign > 0:
		target = surf_tilt_up_degrees
	elif _surf_tilt_sign < 0:
		target = -surf_tilt_down_degrees
	_surf_board_angle = move_toward(_surf_board_angle, target, surf_tilt_ease_degrees_per_second * get_physics_process_delta_time())
	surf_board.rotation = -deg_to_rad(_surf_board_angle) * _surf_facing  # nose up is counter-clockwise facing right, clockwise facing left
	var skimming := _compute_on_skim()
	var loop_pitch := clampf(0.8 + absf(_surf_speed if is_on_floor() else _air_carry_vx) / 400.0, 0.8, 1.6)
	if _surf_loop != null:
		_surf_loop.volume_db = _surf_loop_base_db + (0.0 if is_on_floor() and not skimming else -80.0)
		_surf_loop.pitch_scale = loop_pitch
	if _surf_water_loop != null:
		_surf_water_loop.volume_db = _surf_water_loop_base_db + (0.0 if skimming else -80.0)
		_surf_water_loop.pitch_scale = loop_pitch
	if _surf_steam_loop != null:
		_surf_steam_loop.volume_db = _surf_steam_loop_base_db + (linear_to_db(_surf_steam_lift) if _surf_steam_lift > 0.01 else -80.0)

## How much the floor under the board scales the surf's ground friction (below 1 coasts further, above 1 stops sooner),
## from the surface it rides. Two sources, both optional, 1 when neither says anything:
##  - a body with `get_surf_friction_scale() -> float` (duck-typed like `is_slippery()`; IceBlock returns less than 1,
##    a future mud or gravel body would return more than 1), read off the collider found by a short downward probe;
##  - a tile of the world tilemap whose TileSet has a float custom-data layer named `surf_friction` (above 0).
## Only the friction is scaled: slope gain, the tilt-mismatch drag and the top speed are not. A basin's skim floor has no
## such method, so a skim is the ordinary wet friction.
func _surf_floor_friction_scale() -> float:
	var probe := KinematicCollision2D.new()
	if not test_move(global_transform, Vector2.DOWN * 3.0, probe):
		return 1.0
	if probe.get_normal().dot(Vector2.UP) < 0.5:
		return 1.0  # a wall or an overhang, not the floor underfoot
	var collider := probe.get_collider()
	var grip := 1.0
	if collider == world_tilemap and world_tilemap != null:
		if world_tilemap.tile_set != null and world_tilemap.tile_set.has_custom_data_layer_by_name(SURF_FRICTION_TILE_DATA):
			var tile_data := world_tilemap.get_cell_tile_data(world_tilemap.local_to_map(world_tilemap.to_local(_tile_contact_pos(probe))))
			if tile_data != null:
				var tile_scale: float = tile_data.get_custom_data(SURF_FRICTION_TILE_DATA)
				if tile_scale > 0.0:
					grip = tile_scale
	elif collider is Node and collider.has_method("get_surf_friction_scale"):
		grip = collider.get_surf_friction_scale()
	return clampf(grip, SURF_FRICTION_SCALE_MIN, SURF_FRICTION_SCALE_MAX)

## The top speed on the ground right now: the dry cap, eased up toward the wet one by the wetness.
func _surf_top_speed() -> float:
	return lerpf(surf_top_speed, maxf(surf_top_speed, surf_top_speed_wet), _surf_wetness)

## The point under the board: centre of the collider's bottom edge.
func _surf_feet_point() -> Vector2:
	return Vector2(global_position.x, collision_shape.global_position.y + _shape_height(collision_shape.shape) * 0.5)

## True while the player stands on its basin's skim floor (not on some other floor that happens to be near).
func _compute_on_skim() -> bool:
	if _skim_basin == null or not is_instance_valid(_skim_basin) or not is_on_floor():
		return false
	return absf(_surf_feet_point().y - _skim_basin.get_liquid_surface_world_y()) <= SKIM_ON_SURFACE_TOLERANCE

## Updates the wetness (instant rise, linear decay) and `_surf_on_skim`. A basin's surface reads fully wet; otherwise,
## on the floor, the manager counts running particles in a thin band above the feet (see WaterManager.get_floor_wetness()).
## In the air the wetness just decays, so a short hop keeps it.
func _update_surf_wetness(delta: float) -> void:
	_surf_on_skim = _compute_on_skim()
	var reading := 0.0
	if _surf_on_skim:
		reading = 1.0
	elif water_manager != null and is_on_floor():
		reading = water_manager.get_floor_wetness(_surf_feet_point(), _shape_width(collision_shape.shape) * 0.5)
	_surf_wetness = maxf(reading, _surf_wetness - delta / maxf(surf_wet_decay_time, 0.001))

## Skimming (called each frame just before move_and_slide()): at or above `surf_skim_min_speed`, the settled liquid of a
## non-hazardous, crust-free basin under the board gets a one-way floor on its surface (WaterBasin.set_skim_floor()), so
## the board lands on it, rides it and leaves it like any ground and the swim never starts. Below the minimum speed no
## floor is raised and the player falls into the swim (_update_swim_state() ends the surf); a surfer already riding the
## surface that drops below it sinks the same way. Hazardous liquid (slag) is never skimmed.
func _update_skim_floor() -> void:
	var wanted: WaterBasin = null
	if is_surfing and water_manager != null and world_tilemap != null:
		if get_surf_speed() >= surf_skim_min_speed:
			var feet := _surf_feet_point()
			wanted = water_manager.find_skim_basin(feet.x, feet.y, SKIM_CATCH_DEPTH)
		elif _skim_basin != null and _compute_on_skim():
			_release_skim_floor()  # slowed down on the surface: the board sinks
			_end_surf(false)
			velocity = Vector2.ZERO
			return
	if wanted != _skim_basin:
		_release_skim_floor()
	_skim_basin = wanted
	if wanted != null:
		wanted.set_skim_floor(true, SKIM_CATCH_DEPTH)

func _release_skim_floor() -> void:
	if _skim_basin != null and is_instance_valid(_skim_basin):
		_skim_basin.set_skim_floor(false)
	_skim_basin = null

## After move_and_slide(): a splash and sound on first touching the surface, then a wake behind the board each frame.
## Both are cosmetic (WaterBasin.disturb()); nothing here touches fill volume or physics.
func _update_skim_effects() -> void:
	var on_skim := is_surfing and _compute_on_skim()
	if on_skim:
		var feet := _surf_feet_point()
		if not _skim_was_on:
			_skim_basin.disturb(feet.x, -absf(_surf_prev_velocity.y) * SWIM_SPLASH_IMPULSE, 10.0)
			Audio.play_at(&"player/surf_splash", feet)
		_skim_basin.disturb(feet.x - _surf_facing * 6.0, -get_surf_speed() * SKIM_WAKE_IMPULSE, 10.0)
	_skim_was_on = on_skim

# --- swing / trapeze --------------------------------------------------------------------------------------------
# A SWING hang is a normal hang (is_hanging, no move_and_slide(), state HANG, the "hang" animation) with the hand pinned
# to a moving point, but the pin is done by the Swing, not by _follow_hang_platform(): the Swing moves the player right
# after it has moved itself (pin_to_swing()), so the hand is never a frame behind the bar. Everything the Swing needs
# from the player is public here: is_hanging, hang_swing, pin_to_swing(). Everything the player needs from the Swing:
# grab_radius, get_grip_global(), attach_rider()/detach_rider(), set_push(), get_velocity_at() (see swing.gd).

func _try_grab_swing() -> void:
	var facing := -1.0 if sprite.flip_h else 1.0
	var hand := global_position + Vector2(hang_hand_local_offset.x * facing, hang_hand_local_offset.y)
	var best: Swing = null
	var best_distance := INF
	for node in get_tree().get_nodes_in_group(&"swing"):
		var candidate := node as Swing
		if candidate == null:
			continue
		var distance := hand.distance_to(candidate.get_grip_global())
		if distance <= candidate.grab_radius and distance < best_distance:
			best = candidate
			best_distance = distance
	if best != null:
		_start_swing_hang(best, facing)

func _start_swing_hang(swing: Swing, facing: float) -> void:
	is_hanging = true
	hang_style = HangStyle.SWING  # every hang start sets this explicitly (see _start_hang())
	hang_facing = facing
	hang_platform = null  # the Swing pins us, not the platform follow
	hang_swing = swing
	swing.attach_rider(self)
	swing.catch_momentum(velocity)  # the speed the player arrived with (this frame's, after move_and_slide()) swings the bar
	_end_surf(false)  # grabbing a swing while surfing: the board vanishes, the swing took the surf's velocity
	velocity = Vector2.ZERO
	_air_carry_active = false
	pin_to_swing(swing.get_grip_global())
	_reset_teleport_interpolation()  # hard snap of the hand onto the bar, same reasoning as _start_hang()
	sprite.flip_h = facing < 0.0
	_update_kick_hitbox_facing()
	sprite.play("hang")
	Audio.play(&"player/hang")

## Called by the Swing every physics step after it has moved: puts the hand on the bar. Facing is fixed for the hang.
func pin_to_swing(anchor: Vector2) -> void:
	hang_anchor = anchor
	global_position = anchor - Vector2(hang_hand_local_offset.x * hang_facing, hang_hand_local_offset.y)

func _update_swing_hang(input_dir: float) -> void:
	if hang_swing == null or not is_instance_valid(hang_swing):
		is_hanging = false  # the swing is gone: just fall
		hang_swing = null
		return
	hang_swing.set_push(input_dir)
	if Input.is_action_just_pressed("crouch"):
		_release_swing(false)
	elif Input.is_action_just_pressed("jump"):
		_release_swing(true)

## Lets go of the swing, keeping the velocity of the player's body along the arc (the Swing's angular velocity about its
## pivot); `jump` adds a jump impulse on top. The horizontal part is carried through the air by _air_carry_vx.
func _release_swing(jump: bool) -> void:
	var carried := hang_swing.get_velocity_at(global_position)
	_detach_swing()
	is_hanging = false
	hang_lockout_timer = hang_regrab_lockout
	jump_buffer_timer = 0.0  # the press that jumped must not also buffer a hop for the landing
	velocity = carried
	if jump:
		velocity.y += jump_velocity * swing_jump_boost
		Audio.play(&"player/jump")
	_begin_air_carry(velocity.x, true)

func _detach_swing() -> void:
	if hang_swing != null and is_instance_valid(hang_swing):
		hang_swing.detach_rider(self)
	hang_swing = null

# --- rail hang ------------------------------------------------------------------------------------------------------
# A held hang (is_hanging, hang_style RAIL, no move_and_slide()) from a Path2D in group "grab_rail" (RailBot adds its rail).
# The hand is pinned to the curve at _rail_offset every frame. Where the rail is flatter than rail_flat_degrees the player
# brachiates along it (the "brachiate" animation, left/right); steeper, the "hang" sprite slides down it under
# rail_slide_gravity_scale of gravity. Jump leaves the rail upward and it can be caught again on the way down; crouch lets go.

## The rail's unit tangent in world space at `offset`, pointing toward increasing offset.
func _rail_tangent_at(path: Path2D, offset: float) -> Vector2:
	var curve := path.curve
	var a := curve.sample_baked(maxf(offset - 1.0, 0.0))
	var b := curve.sample_baked(minf(offset + 1.0, curve.get_baked_length()))
	var t := path.global_transform.basis_xform(b - a)
	return t.normalized() if t.length_squared() > 0.0001 else Vector2.RIGHT

func _rail_point_at(path: Path2D, offset: float) -> Vector2:
	return path.to_global(path.curve.sample_baked(offset))

func _try_grab_rail() -> void:
	if _rail_jumped_off:
		if velocity.y < 0.0:
			return
		_rail_jumped_off = false
	var hand := global_position + Vector2(0.0, hang_hand_local_offset.y)
	var reach := maxf(rail_grab_radius, velocity.y * get_physics_process_delta_time())
	var max_slope_y := sin(deg_to_rad(rail_max_grab_degrees))
	var best: Path2D = null
	var best_offset := 0.0
	var best_distance := INF
	for node in get_tree().get_nodes_in_group(&"grab_rail"):
		var path := node as Path2D
		if path == null or path.curve == null or path.curve.point_count < 2 or path.curve.get_baked_length() <= 0.0:
			continue
		var offset := path.curve.get_closest_offset(path.to_local(hand))
		var distance := hand.distance_to(_rail_point_at(path, offset))
		if distance > reach or distance >= best_distance:
			continue
		if absf(_rail_tangent_at(path, offset).y) > max_slope_y:
			continue  # a wall, not a rail
		best = path
		best_offset = offset
		best_distance = distance
	if best == null:
		return
	var anchor := _rail_point_at(best, best_offset) + Vector2(0.0, rail_grip_drop)
	if _rail_pose_hits_bot(anchor - Vector2(0.0, hang_hand_local_offset.y)):
		return  # the hanging body would sit inside a rail bot: fall past it instead
	_start_rail_hang(best, best_offset)

func _start_rail_hang(path: Path2D, offset: float) -> void:
	var tangent := _rail_tangent_at(path, offset)
	var sloped := absf(tangent.y) > sin(deg_to_rad(rail_flat_degrees))
	is_hanging = true
	hang_style = HangStyle.RAIL  # every hang start sets this explicitly (see _start_hang())
	hang_facing = -1.0 if sprite.flip_h else 1.0
	hang_platform = null
	hang_rail = path
	_rail_offset = offset
	# Momentum along the rail is kept only on a slope; on a flat rail a fall's sideways speed would just be a short skid.
	_rail_speed = clampf(tangent.dot(velocity) * rail_catch_momentum, -rail_slide_max_speed, rail_slide_max_speed) if sloped else 0.0
	_rail_jumped_off = false
	_end_surf(false)
	velocity = Vector2.ZERO
	_air_carry_active = false
	_pin_to_rail()
	_reset_teleport_interpolation()  # a hard snap of the hand onto the rail, same reasoning as _start_hang()
	_set_rail_pose(sloped, false)
	Audio.play(&"player/hang")

## Puts the hand on the rail at _rail_offset (the rail may have moved, so this runs every frame).
func _pin_to_rail() -> void:
	hang_anchor = _rail_point_at(hang_rail, _rail_offset) + Vector2(0.0, rail_grip_drop)
	global_position = hang_anchor - Vector2(0.0, hang_hand_local_offset.y)

func _update_rail_hang(input_dir: float, delta: float) -> void:
	if hang_rail == null or not is_instance_valid(hang_rail) or hang_rail.curve == null or hang_rail.curve.get_baked_length() <= 0.0:
		_detach_rail()  # the rail is gone: just fall
		is_hanging = false
		hang_lockout_timer = hang_regrab_lockout
		return
	var length := hang_rail.curve.get_baked_length()
	_rail_offset = clampf(_rail_offset, 0.0, length)
	var tangent := _rail_tangent_at(hang_rail, _rail_offset)
	var sloped := absf(tangent.y) > sin(deg_to_rad(rail_flat_degrees))

	if Input.is_action_just_pressed("crouch"):
		_release_rail(false, tangent)
		return
	if Input.is_action_just_pressed("jump"):
		_release_rail(true, tangent)
		return

	# Speed along the curve: gravity's component along the tangent on a slope (tangent.y is positive going downhill),
	# friction on the flat; on the flat, left/right add hand-over-hand travel on top.
	if sloped:
		_rail_speed = clampf(_rail_speed + gravity * rail_slide_gravity_scale * tangent.y * delta, -rail_slide_max_speed, rail_slide_max_speed)
	else:
		_rail_speed = move_toward(_rail_speed, 0.0, rail_flat_friction * delta)
	var travel := _rail_speed
	if not sloped and input_dir != 0.0:
		travel += input_dir * signf(tangent.x) * catwalk_brachiate_speed
	var new_offset := _rail_offset + travel * delta
	if new_offset < 0.0 or new_offset > length:
		if sloped:
			_release_rail(false, tangent)  # slid off the end: carry on through the air
			return
		new_offset = clampf(new_offset, 0.0, length)  # brachiating to the end: stop there
		_rail_speed = 0.0

	var moved := absf(new_offset - _rail_offset) > 0.001
	var step := new_offset - _rail_offset
	_rail_offset = new_offset
	_pin_to_rail()

	# Facing follows the way the body is actually going along the screen.
	var screen_dx := step * tangent.x
	if moved and absf(screen_dx) > 0.0001:
		hang_facing = signf(screen_dx)
		sprite.flip_h = hang_facing < 0.0
		_update_kick_hitbox_facing()
	_set_rail_pose(sloped, moved)

func _set_rail_pose(sloped: bool, moved: bool) -> void:
	if sloped:
		if sprite.animation != &"hang":
			sprite.play("hang")
		return
	if not sprite.sprite_frames.has_animation(&"brachiate"):
		if sprite.animation != &"hang":
			sprite.play("hang")
		return
	if sprite.animation != &"brachiate":
		sprite.play("brachiate")
		sprite.frame = 0
		sprite.pause()
	if moved:
		if not sprite.is_playing():
			sprite.play("brachiate")
	else:
		sprite.pause()

## Lets go of the rail. `jump` leaves upward and the rail can be caught again once the fall starts; otherwise it is a drop
## with the usual re-grab lockout. On a slope the slide's velocity is carried through the air.
func _release_rail(jump: bool, tangent: Vector2) -> void:
	var carried := tangent * _rail_speed
	var carry_x := carried.x
	var was_sloped := absf(tangent.y) > sin(deg_to_rad(rail_flat_degrees))
	_detach_rail()
	is_hanging = false
	velocity = carried if was_sloped else Vector2.ZERO
	if jump:
		velocity.y = jump_velocity
		_rail_jumped_off = true
		hang_lockout_timer = 0.0  # no lockout: _rail_jumped_off already holds the catch until the fall begins
		_skip_buffered_jump = true  # this press was the jump: the buffered-jump consume later this frame must not fire again
		Audio.play(&"player/jump")
	else:
		hang_lockout_timer = hang_regrab_lockout
	if was_sloped:
		_begin_air_carry(carry_x, true)

func _detach_rail() -> void:
	hang_rail = null
	_rail_speed = 0.0

## Would the standing collider, with the body origin at `pos`, overlap a rail bot? Only the grab asks: touching a bot hurts
## (see Contact in the rail bot), so a grab that would put the body inside one is refused rather than taken and hit. (Rail bots join group "rail_bot".)
func _rail_pose_hits_bot(pos: Vector2) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	var xf := collision_shape.global_transform
	xf.origin += pos - global_position
	query.transform = xf
	query.collision_mask = 1
	query.exclude = [get_rid()]
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 8):
		var body: Object = hit.get("collider")
		if body is Node and (body as Node).is_in_group(&"rail_bot"):
			return true
	return false

func _begin_mantle() -> void:
	one_shot_action = OneShotAction.MANTLING
	Audio.play(&"player/mantle")
	if hang_style == HangStyle.CATWALK_UNDER:
		# pushing straight up through the catwalk onto its own top surface — no facing multiplier,
		# since (unlike the ledge mantle below) this isn't a sideways move around a wall corner.
		mantle_target = hang_anchor + catwalk_mantle_offset
		var crust_target := _crust_mantle_target()
		if crust_target.is_finite():
			mantle_target = crust_target
	else:
		mantle_target = hang_anchor + Vector2(mantle_offset.x * hang_facing, mantle_offset.y)

	if sprite.sprite_frames.has_animation("climb_up"):
		sprite.play("climb_up")
		var frame_count := sprite.sprite_frames.get_frame_count("climb_up")
		var fps := sprite.sprite_frames.get_animation_speed("climb_up")
		var duration := float(frame_count) / fps if fps > 0.0 else 0.0
		if duration > 0.0:
			# smoothly translate over the animation's actual length, rather than a hard teleport
			# at the end — the source art shows continuous motion (a body-roll over the ledge),
			# not a static pose that jumps, so the position should move with it. Note this can't
			# be pixel-matched frame-by-frame: past the initial grab frame the art no longer has
			# a separately-trackable hand to pin against, so this is a smooth approximation of
			# the overall movement vector rather than an exact reproduction.
			# tween_method + lerp between two world-space points (rather than tween_property to a fixed
			# absolute target) so _follow_hang_platform() can shift BOTH endpoints each frame when the
			# ledge belongs to a moving platform; a fixed-target tween would overwrite the shift. Physics
			# process mode so every position write happens in the same step as the follow.
			_mantle_start = global_position
			_mantle_tween = create_tween()
			_mantle_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			_mantle_tween.tween_method(_mantle_step, 0.0, 1.0, duration/2)
		else:
			global_position = mantle_target
			_reset_teleport_interpolation()
	else:
		push_warning("No 'climb_up' animation in SpriteFrames — mantling instantly with no transition; add one for a smoother exit")
		_finish_mantle()

func _finish_mantle() -> void:
	# snap to the exact target regardless of whether a tween got us there — self-corrects
	# any small timing mismatch between the tween's duration and the animation's actual length
	global_position = mantle_target
	_reset_teleport_interpolation()
	is_hanging = false
	one_shot_action = OneShotAction.NONE
	var next_state := State.RUN if Input.get_axis("move_left", "move_right") != 0.0 else State.IDLE
	if not is_on_floor():
		next_state = State.JUMP if velocity.y < 0.0 else State.FALL
	state = next_state
	if state == State.FALL:
		# hold the climb_up end pose instead of playing "fall" yet — see post_mantle_fall_anim_delay.
		# If landing happens first, the normal state-decide block in _physics_process switches to
		# idle/run on its own and this timer's expiry (handled there too) becomes a no-op.
		fall_anim_delay_timer = post_mantle_fall_anim_delay
	else:
		_play_animation_for_state()

## True when the crouched player may creep: crouched on the floor with no one-shot running, not on the surf board, and the
## crouch-down animation has reached its last frame (or the sneak clip is already playing). Pure of input, so the
## horizontal movement and the state decision share it; callers add the left/right test.
func _can_sneak() -> bool:
	if not is_crouching or is_surfing or not is_on_floor() or one_shot_action != OneShotAction.NONE:
		return false
	if sprite.animation == &"sneak":
		return true
	return sprite.animation == &"crouch" and sprite.frame >= sprite.sprite_frames.get_frame_count(&"crouch") - 1

## Shows the crouch clip's last frame and holds it (the pose a finished crouch-down rests on).
func _hold_crouch_pose() -> void:
	sprite.play(&"crouch")
	sprite.set_frame_and_progress(sprite.sprite_frames.get_frame_count(&"crouch") - 1, 0.0)
	sprite.pause()

func _on_sprite_frame_changed() -> void:
	# frame-synced sounds (footsteps, ladder rungs): fires only when a frame actually advances, so a
	# paused climb animation is silent. Looked up in FRAME_SOUNDS at the top of the file.
	var frames: Dictionary = FRAME_SOUNDS.get(sprite.animation, {})
	var sound: StringName = frames.get(sprite.frame, &"")
	if sound == &"":
		return
	if sprite.animation == &"run" and not is_on_floor():
		return  # a run frame ticking over in the air isn't a footstep
	Audio.play(sound)

func _update_landing_sound() -> void:
	# There's no landing event to hook, so detect the airborne -> grounded transition. Called once per
	# physics frame after move_and_slide(). Climbing/hanging reset the peak, so mantling onto a ledge
	# or stepping off a ladder onto a floor doesn't count as a fall.
	var on_floor := is_on_floor()
	if is_climbing or is_hanging:
		_peak_fall_speed = 0.0
	elif not on_floor:
		_peak_fall_speed = maxf(_peak_fall_speed, velocity.y)
	else:
		if not _was_on_floor and _peak_fall_speed > land_min_fall_speed:
			var t := inverse_lerp(land_min_fall_speed, land_full_volume_fall_speed, _peak_fall_speed)
			Audio.play(&"player/land", lerpf(land_quiet_volume_db, 0.0, clampf(t, 0.0, 1.0)))
		_peak_fall_speed = 0.0
	_was_on_floor = on_floor

func _play_animation_for_state() -> void:
	match state:
		State.IDLE:
			sprite.play("idle")
		State.RUN:
			sprite.play("run")
		State.JUMP:
			sprite.play("jump")
		State.KICK:
			sprite.play("kick")
		State.FALL:
			sprite.play("fall")
		State.CROUCH:
			if sprite.animation == &"sneak":
				_hold_crouch_pose()  # stopped sneaking: back to the held crouch frame, not the crouch-down again
			else:
				sprite.play("crouch")
		State.SNEAK:
			sprite.play("sneak")
		State.SURF:
			sprite.play("fall")  # placeholder: reads as a surf pose with the board added; swap for a real "surf" animation
		State.HANG:
			sprite.play("hang")
		State.HURT:
			sprite.play("hurt")
		State.DEAD:
			sprite.play("dead")
		State.DANCE:
			sprite.play("dance")

func _on_animation_finished() -> void:
	if is_dead or is_dancing:
		return  # both are terminal; dead holds its last frame, dance is free to loop — either way
		# nothing should follow it
	if one_shot_action == OneShotAction.MANTLING:
		_finish_mantle()
		return
	if one_shot_action == OneShotAction.CLIMBING_DOWN:
		_finish_catwalk_climb_down()
		return
	if one_shot_action == OneShotAction.NONE:
		return
	if one_shot_action == OneShotAction.KICKING:
		kick_hitbox.monitoring = false
	one_shot_action = OneShotAction.NONE

	var next_state := State.RUN if Input.get_axis("move_left", "move_right") != 0.0 else State.IDLE
	if not is_on_floor():
		next_state = State.JUMP if velocity.y < 0.0 else State.FALL
	state = next_state
	_play_animation_for_state()
