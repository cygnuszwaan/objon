extends Node2D
class_name WaterManager

# Particle manager core (water-mechanic.md, Phase 2). One instance placed per level scene — NOT an
# autoload, since particle/basin-fill state shouldn't persist across a level reload the way
# Audio/Game's global concerns do (see "Manager placement" in the Decided section). Basins find
# their level's manager via the "water_manager" group this node adds itself to, the same lookup
# convention "world_tilemap" already uses elsewhere in the project.
#
# STATUS (roadmap step 9.3): pooled particle storage (2.1), MultiMeshInstance2D rendering (2.2),
# basin registration (2.3), gravity + raycast world collision (3.1), non-basin ground creep + lifetime
# cap (3.2), basin settle/absorb (3.3), full-basin overflow via creep (3.4), the player-push query
# (4.1), the whole-tile melt-spawn API (6.1b), and registered non-tilemap solid collision + carry +
# drop-release (9.1-9.3) are all in place. Overflow is NOT an authored spill
# point: a particle over a FULL basin's columns is fed a synthesized "floor" contact at the basin's
# own surface line instead of being absorbed, and creeps along it with the ordinary 3.2 creep rules —
# it walks itself out over whichever wall is shorter (the water surface at 100% capacity sits exactly
# level with that wall's top, by definition of _capacity_volume in basin.gd, so nothing separate needs
# to pick a direction), then falls and is picked up by 3.3's absorb check again wherever it lands next.
# Push is a per-frame radius query against the player (found via the "player" group), summed and
# capped — both by a flat PUSH_CAP and by the fastest contributing particle's own speed (Phase 4.3;
# see PUSH_CAP's and _push_max_speed's own comments for why the flat cap alone let a large flood of
# slow particles push the player faster than the water itself was moving) — read by player.gd through
# get_player_push() — see _accumulate_push()/get_player_push() below and player.gd's
# _water_push_speed() (4.2) for the other half of the contract. The whole pipeline above (2.1 through
# 5.1) is user-verified working in-editor via the WaterFaucet test source (6.1a).
# spawn_melt_particles() (6.1b) is new and has no caller yet — nothing but the faucet has exercised it,
# since the ice/laser chain it's meant for isn't built.
#
# Registered non-tilemap solids (9.1-9.3): any body that opts into the "water_solid" group (moving_
# platform.gd's root, crusher.gd's $ArmBody, cannon.gd's $StaticBody2D, drop_platform.gd's root) is
# discovered the same way _world_tilemap/_player are, and _step_particle_physics()'s "is this hit one
# I act on" check now accepts either — the collision/bounce/creep math itself is untouched, only the
# collider-identity check widens. Carry (9.2) falls out of the same registration rather than being
# platform-specific code: every registered solid's per-frame transform change is tracked the same way
# player.gd's _follow_hang_platform() tracks a hung platform, and a particle currently resting on one
# is moved by that change each frame (a translation for a platform, a rotation about the pivot for the see-
# saw, per rotating-bodies roadmap 2.1) — for crusher/cannon, whose registered body never actually
# moves, the change is always nil and the mechanism is simply inert. Drop-platform release (9.3)
# needed no code of its own: once its collision shape is disabled mid-drop, the very next frame's
# raycast just stops finding it, and a "resting" particle already re-casts fresh from its own position
# every frame (see _step_particle_physics()) — it starts falling exactly as if the platform had
# vanished, the same "no code needed" outcome 3.2 already found for creeping off a floor's edge.
# NOT yet exercised in-editor — nothing in the test level currently has water raining onto a moving
# platform/crusher/cannon/drop platform to confirm the carry/collision/release paths against real
# gameplay, only read against each target script's actual node layout.
#
# LIQUID TYPES (water/slag/steam), NOT yet exercised in-editor: particles now carry a per-particle
# `_liquid_type` (LiquidConstants.LiquidType), and every physical property that used to be a flat
# constant here — creep speed, bounce restitution, slope friction, push force, hazard, color,
# lifetime — is now read per-particle from `LiquidConstants.profile(type)` instead, so this script
# has exactly one implementation of the particle simulation regardless of which liquid is flowing,
# per the "minimal bifurcation" design goal. `_try_absorb()` now branches on whether a particle's own
# type matches the basin's native `liquid_type`: a match behaves exactly as before (credits
# `fill_volume`); a mismatch — if the basin already has some of ITS OWN native liquid settled —
# solidifies a slice of that settled liquid into the basin's crust via `basin.convert_to_crust()` and spawns
# steam (`emit_steam()`, the one entry point) at the contact point, consuming the incoming particle either
# way. STEAM is a third LiquidType marked `is_gas` in its profile: gas particles skip absorb/push/hazard
# entirely (`_step_gas_particle()`): each rises at a constant speed inside a narrow cone, casts one ray per
# frame and dies on the first solid it meets (a catwalk tile doesn't count), or when its type-specific
# lifetime runs out. Not saved: after a restore a column rebuilds over about one lifetime.

@export_flags_2d_physics var tile_collision_mask: int = 3
	# Which physics layers the collision raycast (_step_particle_physics(), below) checks. Defaulted
	# to 3 (bits 1+2) — the same value player.gd's hang_probe_mask uses. Confirmed working for this use
	# via the faucet test (6.1a): particles land on and collide with world_tilemap geometry correctly
	# at this default; adjust here only if a future level's TileSet uses different physics layers. Safe
	# to leave broader than just the tilemap's own layer: a hit only ever gets acted on if its collider
	# IS `_world_tilemap` OR is one of `_registered_solids` (Phase 9.1) — anything else this mask happens
	# to also hit (an unregistered body, e.g. a conveyor belt) is discarded the same as a miss.

@export var kill_y: float = 10000.0
	# World-space y (pixels, +y is down) below which a LIQUID particle is despawned immediately —
	# the per-level "fell off the map" floor. Set it a little below the lowest thing in the level
	# (the lifetime timer alone otherwise leaves off-map particles simulating for up to 20s). Compared
	# against the particle's center. Steam is exempt: gas drifts upward, so a floor means nothing to it.
	# The default is far below any current level, i.e. effectively off until set per level.

@export var debug_log_reversals: bool = false
	# Prints the position and hit normal every time a particle's creep is blocked. Turn on to see WHERE
	# the system thinks it's hitting an obstacle if creep still behaves oddly at a particular junction.

@export var debug_steam_lift: bool = false
	# Shows an on-screen readout of get_steam_lift() for the player's current collider rect: the raw reading and
	# the smoothed value (instant rise, linear decay), for tuning the steam column against the surfer's lift
	# (roadmap 4.2, 4.3). Read only; leave off outside tuning.

const MAX_PARTICLES := 1024
	# Flat constant, not derived from level content (max simultaneous ice melt, etc.) — per the
	# "Particle budget — flat constant, silent drop" decision: simpler to reason about, matches the
	# project's existing lean-and-simple bias elsewhere (e.g. the flat particle lifetime cap Phase 3.2
	# will add). Placeholder pending an in-editor tuning pass (Phase 7.1) once particles are actually
	# visible and a real flood can be eyeballed against it — not a considered final number yet.

const PARTICLE_GRAVITY := 900.0
	# px/s^2, matching player.gd's own `gravity` default exactly — a reasonable starting point for
	# "falls like the rest of this game's physics feels," not a considered final value. Lives here
	# rather than LiquidConstants for the same reason PARTICLE_COLOR_JITTER does: nothing else cascades
	# from it, it's a standalone physics tuning constant, not part of the size/count/volume/push
	# exchange-rate chain. Shared across liquid types — gravity isn't a material property here.
	# Placeholder pending Phase 7.1, same as MAX_PARTICLES above.

const BOUNCE_MIN_IMPACT_SPEED := 10.0
	# px/s of into-surface speed (velocity's component AGAINST the hit normal) below which an impact
	# is resolved as a landing/slide rather than a bounce — see _step_particle_physics() below.
	# Without a threshold, a particle resting on a slope would re-trigger a tiny "bounce" every frame
	# forever as gravity re-accelerates it into the surface, never actually settling. Shared across
	# every liquid type (not part of LiquidConstants' per-type profile) — it's "how hard counts as
	# hard," not a material property; both water's and slag's own creep speeds are kept below this so
	# ordinary creeping never misclassifies as a bounce. Placeholder pending Phase 7.1 tuning.
	#
	# bounce_restitution, slope_slide_friction, and creep speed are now per-LiquidType — see
	# LiquidConstants.profile()'s creep_speed/bounce_restitution/slope_slide_friction fields, read
	# per-particle in _resolve_surface_contact() below via LiquidConstants.profile(_liquid_type[i]).
const MAX_CREEP_REVERSALS := -1
	# How many times a blocked particle may flip its creep direction before it gives up and stops.
	# 1 = the original "reverse at most once" rule (an enclosed span can't ping-pong forever). Set to
	# -1 for UNLIMITED — particles keep creeping back and forth indefinitely (useful once moving
	# puzzle elements should keep water in motion). Only each type's own LiquidConstants.profile()
	# .lifetime then bounds how long a trapped particle lives, so revisit that too if unlimited is used.
	# Shared across liquid types — not a material property, just a simulation safety valve.
const FLOOR_NORMAL_MAX_Y := -0.1
	# A hit counts as FLOOR (something a particle can rest/creep on) when hit.normal.y is below this —
	# deliberately permissive (anything up to ~84 degrees from flat), so steep slopes read as floor, not
	# wall. An earlier -0.5 cutoff classified a ~63 degree slope tile as a wall. Whether a floor is
	# walkable in the creep direction is decided separately, by UPHILL_MIN_NORMAL_X below.
const UPHILL_MIN_NORMAL_X := 0.1
	# A surface whose normal leans against the creep direction by more than this (abs(normal.x), ~6
	# degrees off flat) is "uphill" in that direction — or a wall — and blocks creep. Below it the
	# surface is treated as flat, so float noise / a 1px seam can't block a particle.

const BOUNCE_CREEP_BLEND := 0.5
	# Fraction of profile.creep_speed added as a tangential velocity nudge, in the particle's already-
	# chosen creep direction, on every bounce above BOUNCE_MIN_IMPACT_SPEED — see
	# _resolve_surface_contact()'s bounce branch. Lets a particle start visibly drifting toward its
	# eventual creep direction WHILE it's still bouncing, instead of only once it settles below the
	# bounce threshold and enters the ordinary creep branch. 0.5 is untuned; 0 disables the effect
	# entirely (particles bounce in place, drifting only however their own pre-existing tangential
	# velocity carries them, the original behavior) and 1.0 means a bounce already picks up a full
	# creep_speed's worth of sideways drift on top of its vertical bounce.

const REST_TOLERANCE := 0.05
	# px. A particle resting on a synthesized (full-basin) surface sits at exactly surface_y - half, so
	# its leading edge equals the surface line to within float32 rounding of the stored position; without
	# a tolerance that comparison can land a hair "above" the line on some frames, and the particle
	# falls one step of gravity before being snapped back.
const CREEP_STOPPED := 255
	# Sentinel stored in _creep_reversals for a particle that has stopped creeping.

const PLAYER_PUSH_RADIUS := 8.0
	# px, measured from the player's origin. Any active particle within this radius contributes to
	# the push total below — binary in/out, no falloff with distance (see "Player push — model and
	# cap" in water-mechanic.md). Retuned down from an initial 28px placeholder (roughly one and a
	# half tiles), which reached well past the player's own collider and pushed/damaged the player
	# from particles that weren't visibly touching them; 8px sits close to the player's own
	# half-width, so contact now roughly tracks visible contact. Also doubles as the hazard-contact
	# radius for a hazardous LiquidType (see _accumulate_push_and_hazard() below) — the same fix
	# serves both purposes together.
const SLAG_PARTICLE_DAMAGE := 1
	# Passed to player.gd's take_hit() each physics frame a hazardous-type particle is within
	# PLAYER_PUSH_RADIUS (see _accumulate_push_and_hazard()) — take_hit()'s own i-frames prevent this
	# from being a full point of damage every single frame of contact, the same polling posture
	# sawwheel.gd/crusher.gd already use for their own hazards. Untuned placeholder.

# PUSH_CAP, per-type creep/bounce/friction/push-force, and per-type particle color all moved to
# LiquidConstants (profile()) once a second liquid type existed — see that file for the full
# per-LiquidType profile. PARTICLE_COLOR_JITTER stays here: it's a rendering-only per-particle
# variance applied on top of whichever profile color a particle spawns with, not itself a material
# property of any one liquid.
const PARTICLE_COLOR_JITTER := 0.15
	# Per-particle random offset applied to color VALUE (HSV brightness) only, hue/saturation held
	# fixed — keeps every particle recognizably "the same liquid" while still breaking up what would
	# otherwise be a flat field of identical squares. Applied once at spawn, never touched again (no
	# per-particle appearance state beyond that, per the "Rendering" decision).

const PARTICLE_SCALE_JITTER_MIN := 0.7
const PARTICLE_SCALE_JITTER_MAX := 1.3
	# Per-particle RENDER-ONLY size multiplier on top of LiquidConstants.PARTICLE_PIXEL_SIZE — a flat
	# field of identically sized particles creeping at an identical rate reads as a single rigid
	# "snake" rather than a flood, and this (plus CREEP_SPEED_JITTER below) is the cheapest way to
	# break that up. Purely cosmetic: it only scales the multimesh quad each particle is drawn as (see
	# _process() below); PARTICLE_VOLUME, half_particle (collision/absorb math), and everything else
	# physical still uses the unscaled PARTICLE_PIXEL_SIZE, so represented volume and collision
	# behavior are completely unaffected. Applied once at spawn into _visual_scale, same posture as
	# PARTICLE_COLOR_JITTER above — no per-frame recomputation, no per-particle appearance state
	# beyond the one stored value.
	#
	# Deliberately NOT z-sorted so smaller particles draw in front of larger ones: doing that would
	# mean decoupling multimesh instance slot from particle array index (today they're the same
	# number, which is exactly what makes despawn_particle()'s swap-and-shrink a single O(1) move per
	# parallel array), replacing that with a per-frame sort of up to MAX_PARTICLES indices, and
	# reworking color/transform writes to go through the sorted mapping instead of direct index — a
	# real architectural change, not a cheap tweak, for a visual effect most players will never
	# consciously notice.

const GRAVITY_JITTER := 0.15
	# Per-particle random multiplier on PARTICLE_GRAVITY, ± this fraction, rolled once at spawn into
	# _gravity_mult — same "creeping snake" motivation as PARTICLE_SCALE_JITTER/CREEP_SPEED_JITTER
	# above: identical fall arcs are one more thing making many particles read as one rigid mass
	# rather than an uneven flow. Unlike those two, this ISN'T purely cosmetic — it changes actual
	# fall acceleration — but it's still cheap and self-contained: nothing downstream (impact speed
	# threshold, bounce restitution, absorb/push) assumes gravity is uniform across particles, they
	# all just read whatever velocity a particle already has.

const CREEP_SPEED_JITTER := 0.2
	# Per-particle random multiplier on profile.creep_speed (see _step_particle_physics() below),
	# ± this fraction — e.g. 0.2 means each particle creeps at 80%-120% of its liquid type's nominal
	# rate. Same "creeping snake" problem as size above: a shared exact creep_speed is what makes many
	# particles read as one moving band rather than an uneven flow. Applied once at spawn into
	# _creep_speed_mult, never touched again.

var _position: PackedVector2Array = PackedVector2Array()
var _velocity: PackedVector2Array = PackedVector2Array()
	# Fixed-size (MAX_PARTICLES) parallel arrays, allocated once in _ready() and never resized after —
	# per the "Particles are data, not nodes" decision: no per-particle CharacterBody2D/
	# CollisionShape2D/move_and_slide(), just plain arrays a later phase steps in one loop per physics
	# frame (Phase 3). Positions/velocities are world-space. `_position` is each particle's CENTER —
	# the multimesh's quad is centered on its instance transform's origin, so this is the natural
	# convention to settle on now, before Phase 3's collision/absorb sampling starts reading it.
	#
	# DENSE PACKING, deliberately no separate "active" flags array: a particle is live if and only if
	# its index is < _active_count. spawn_particle() always appends at index _active_count (then
	# increments it); despawn_particle() swaps the removed slot with whatever currently sits at
	# _active_count - 1 (then decrements) — the swap-and-shrink removal the roadmap calls for. This
	# keeps [0, _active_count) exactly the live particles with no gaps, so every future per-frame step
	# can loop `for i in _active_count` directly instead of also checking a flag per slot — a flags
	# array would be redundant state to keep in sync, not an extra safety net.
	#
	# Per-particle COLOR lives on `_multimesh` itself (set_instance_color/get_instance_color) rather
	# than a third parallel array here — the multimesh already has to hold one Color per slot for
	# rendering, so a separate _color array would just be the same data duplicated. The swap-and-shrink
	# in despawn_particle() below moves color the same way it moves position/velocity, just by reading/
	# writing through the multimesh's own accessors instead of a local array.

var _age: PackedFloat32Array = PackedFloat32Array()
	# Seconds since spawn, per particle. Swapped in despawn_particle() like position/velocity. Drives
	# each particle's own LiquidConstants.profile(type).lifetime force-despawn in _physics_process().

var _visual_scale: PackedFloat32Array = PackedFloat32Array()
	# Render-only per-particle size multiplier, randomized once at spawn between
	# PARTICLE_SCALE_JITTER_MIN/MAX — see that constant's own comment. Read only by _process()'s
	# multimesh transform write; nothing physical ever looks at this.

var _creep_speed_mult: PackedFloat32Array = PackedFloat32Array()
	# Per-particle multiplier on profile.creep_speed, randomized once at spawn within
	# ±CREEP_SPEED_JITTER — see that constant's own comment.

var _gravity_mult: PackedFloat32Array = PackedFloat32Array()
	# Per-particle multiplier on PARTICLE_GRAVITY, randomized once at spawn within ±GRAVITY_JITTER —
	# see that constant's own comment.

var _liquid_type: PackedInt32Array = PackedInt32Array()
	# LiquidConstants.LiquidType per particle (WATER/SLAG/STEAM), set at spawn_particle() and swapped
	# in despawn_particle() like every other per-particle array. Every physical property that used to
	# be a flat constant in this file — creep speed, bounce, friction, push force, hazard, color,
	# lifetime — is looked up per-particle from LiquidConstants.profile(_liquid_type[i]) instead, so
	# the rest of this script needn't know or care which liquid a given particle is.
var _creep_dir: PackedInt32Array = PackedInt32Array()
var _creep_reversals: PackedByteArray = PackedByteArray()
	# Per-particle ground-creep state (3.2). _creep_dir is 0 until the particle first lands on a floor,
	# then -1/+1 (chosen once, from its own horizontal velocity if it has any, else at random).
	# _creep_reversals: how many times this particle has flipped direction so far (capped below
	# CREEP_STOPPED so unlimited mode can't overflow the byte), or CREEP_STOPPED once it has run out of
	# allowed reversals and stopped for good (no more creep, just rests/slides under gravity until its
	# lifetime runs out). All persist across falls/bounces — a particle that creeps off an edge keeps
	# its direction.

var _resting_body: Array[Node2D] = []
	# Per-particle (parallel to _position/_velocity/etc., swapped the same way in despawn_particle()):
	# which registered solid (Phase 9.1's _registered_solids) this particle is CURRENTLY resting/creeping
	# on, or null if it's resting on _world_tilemap (or not resting on anything right now). Set in
	# _step_particle_physics() whenever a frame's raycast hits a registered solid rather than the
	# tilemap; cleared the moment a raycast hits the tilemap instead, hits nothing, or hits something
	# unregistered. This one flag is all Phase 9.2's carry needs — "what did this particle last land on"
	# already answers "should it be carried, and by how much" via a _solid_motion lookup.

var _active_count: int = 0

var _world_tilemap: TileMapLayer
	# Found via the "world_tilemap" group in _ready(), the exact same lookup player.gd's own _ready()
	# uses — same convention, deliberately not deferred: unlike "water_manager" (added to its group by
	# WaterManager's own runtime code, hence basin.gd's deferred registration), world_tilemap group
	# membership is assigned in the editor's Groups panel and baked into the scene, so it's already
	# present on every node before ANY node's _ready() runs — no ordering hazard to guard against.

var _player: Node2D
	# Found via the "player" group: tried in _ready() and again at the top of every _physics_process() while it is
	# still null. Unlike _world_tilemap above, the player's group is NOT baked into its scene: player.gd adds
	# itself to it in its own _ready(), which runs after this node's when the Player sits below the manager in the
	# level tree, so a lookup in _ready() alone left the reference null (no push, no slag hazard). Typed as plain Node2D rather than a
	# Player-specific type — this manager only ever reads `.global_position` off it, the same
	# loose-coupling posture the belt/jump-pad duck-typed contracts use elsewhere in the project, just
	# in the opposite direction (player.gd calls IN to get_player_push() below, rather than this script
	# calling a method player.gd exposes). A level with no player in the scene (a basin-only test level,
	# say) just never accumulates push — not an error, since nothing here requires a player to exist for
	# the rest of the particle simulation to run.

var _registered_solids: Array[Node2D] = []
	# Phase 9.1: non-tilemap bodies water can collide with/rest on/be carried by, discovered via the
	# "water_solid" group the same way _world_tilemap/_player are discovered via their own groups —
	# anything that self-registers into it (moving_platform.gd's root, crusher.gd's $ArmBody, cannon.gd's
	# $StaticBody2D, drop_platform.gd's root) becomes a collider _step_particle_physics() below acts on
	# the same way it already acts on _world_tilemap; the bounce/creep math in _resolve_surface_contact()
	# needed no changes at all, only the "which colliders count" check widened. A NodePath-per-level
	# export was considered and rejected in favor of self-registration — matches this project's existing
	# convention of a body opting itself into a group ("ground"/"catwalk" for hangability) rather than a
	# level scene having to know about and wire up every water-relevant body by hand.
	#
	# UNLIKE _world_tilemap/_player below, "water_solid" membership is assigned by each body's OWN
	# runtime code in ITS _ready() — not baked into the scene the way an editor-assigned group is — so
	# it has exactly the same ordering hazard "water_manager" membership does for basin.gd, and needs
	# the same fix: populated via a DEFERRED call (_collect_registered_solids(), scheduled from _ready()
	# below), not read directly inside _ready() itself. Reading it directly there was the original bug —
	# it happened to work for moving_platform (came before this node in the scene tree, so its _ready()
	# — and thus its own add_to_group() call — had already run) and silently failed for crusher/cannon/
	# drop_platform (came after this node, so their _ready() hadn't run yet: the group was still empty
	# when this manager looked). A deferred call runs after every node's _ready() in the current frame
	# has finished, regardless of tree order — the same guarantee basin.gd's own deferred registration
	# relies on — so by the time _collect_registered_solids() actually runs, all four have already
	# self-registered no matter where they sit in the tree.
var _registered_solid_prev_xform: Array[Transform2D] = []
	# Parallel to _registered_solids: each body's global_transform as of the END of last frame's update
	# below, so this frame's motion is "how did it move since I last looked" — same technique
	# player.gd's _hang_platform_last_pos/_follow_hang_platform() already uses to carry a hung player
	# along a moving platform, reused here to carry a resting particle instead. The whole transform, not
	# just the position (rotating-bodies roadmap 2.1), so a body that rotates about a pivot (the see-saw)
	# carries its particles round the pivot; a translation-only body gives the same shift as before.
var _solid_motion: Dictionary = {}
	# Node2D (one of _registered_solids) -> the Transform2D that maps a point on it as of last frame to the
	# same point on it now (new * old.affine_inverse()), THIS physics frame. Rebuilt from scratch at the
	# top of every _physics_process() (see below), before the particle loop reads it — a body whose
	# transform didn't change this frame (crusher's ArmBody, cannon's StaticBody2D: registered for
	# collision only, neither one's own root actually moves; a see-saw at rest) is simply never entered,
	# so a lookup for it falls through to "not carrying" with no special-casing needed.

var _resting_torque: Dictionary = {}
	# Node2D (a registered solid that has get_pivot_global(): a RotatingBody) -> the torque, about its pivot, of the
	# particles resting on it THIS physics frame (weight x horizontal offset from the pivot, positive = clockwise on
	# screen, the same units and sign as a rider's torque). Rebuilt from scratch every frame like _solid_motion;
	# read through get_resting_torque(). A body without a pivot (a platform, crusher) is never entered.

var _steam_arrivals: Dictionary = {}
	# Node2D (a registered solid with get_pivot_global()) -> the summed torque of the steam particles that died on its
	# underside THIS physics frame (negative = counter-clockwise, an upward push right of the pivot). Cleared at the top
	# of every frame, folded into _steam_push at the end of the particle loop. Roadmap N3.5.
var _steam_push: Dictionary = {}
	# Node2D -> Array[Vector2], one entry per frame that had an arrival: x = age in seconds, y = that frame's summed
	# torque. A body's steam torque is the sum of y * (1 - x / STEAM_PUSH_DECAY_TIME) over its live entries, so every
	# arrival is a ramp that starts at full value and falls linearly to nothing, and the ramps ADD (a denser column
	# pushes harder). Kept apart from _resting_torque so liquid load and steam push do not share a clock. Runtime only,
	# never saved; forget_motion() drops a body's entries.

var _push_total: Vector2 = Vector2.ZERO
	# Phase 4.1: this frame's summed push contribution, read by player.gd's _water_push_speed() via
	# get_player_push() below. Reset to zero at the top of every _physics_process() and rebuilt from
	# scratch each frame — not accumulated across frames — since it's meant to represent "how much push
	# is happening right now," not a running total.
var _push_max_speed: float = 0.0
	# The fastest speed among this frame's contributing particles (i.e. the highest
	# `_velocity[i].length()` seen by _accumulate_push() below), reset alongside _push_total. Used to
	# clamp the final push magnitude so a flood of many slow, low-speed particles can never push the
	# player faster than the water is actually moving — see the clamp at the end of
	# _physics_process() and "Player push — model and cap" in water-mechanic.md. A frame with no
	# contributors leaves this at 0.0, which is harmless: _push_total is also zero then, so there's
	# nothing to clamp.

var _multimesh: MultiMesh
var _multimesh_instance: MultiMeshInstance2D
	# One draw call for every active particle, per the "Rendering" decision. `visible_instance_count`
	# (set each frame in _process(), below) is what actually limits drawing to [0, _active_count) —
	# `instance_count` itself is allocated once at MAX_PARTICLES and never changed, so slots beyond
	# _active_count just sit there unused/stale rather than needing to be cleared.

var _basins: Array[WaterBasin] = []
	# Registered basins, in registration order — a basin's ID (returned by register_basin() below,
	# and the value stored in _column_basin_id) IS its index into this array. No separate ID field
	# needed: index-as-ID is enough since basins only ever get ADDED here, never removed (a level's
	# basin set is fixed at load time, nothing currently despawns/re-registers one at runtime).
	# Holding the actual WaterBasin references (not just their structural data) is deliberate — Phase
	# 3.3+ still needs to call each basin's own live-state API (add_volume()/remove_volume()/
	# get_surface_row()/is_full()), since fill_volume is mutable per-basin state that lives on the
	# basin node itself (see "Basin fill state" in water-mechanic.md), not something this manager
	# could sensibly copy out and own instead.

var _column_basin_id: Dictionary = {}   # absolute tilemap column (int) -> Array[int] of basin IDs registered on
	# that column, in registration order. Almost always one entry; more than one means basins are
	# stacked in that column (one's floor sitting directly above another's rim — e.g. a drain faucet's
	# tile), and get_basin_for_column()'s world_y param picks the right one via WaterBasin.owns_world_point().
var _column_floor_row: Dictionary = {}  # absolute tilemap column (int) -> that column's floor row (float, sub-tile precision as of basin.gd's Phase 10.1)
	# The "per-column basin membership" / "per-column floor height" half of the fixed data shape the
	# "kept swappable by design" decision describes — this manager's OWN copy, built once at
	# registration from whatever get_registration_data() below hands over, rather than something
	# downstream queries back through the basin node. Only INTERIOR (open-water) columns are entered
	# — walls are never a particle's column, so they'd just be dead entries. Two Dictionaries rather
	# than one holding a combined value: both are written together, at the same time, for the same
	# columns, in register_basin() below and never independently after — no real drift risk — and
	# keeping them separate means a caller that only wants one (e.g. a future pass that wants floor
	# height without needing to resolve which basin owns it) doesn't have to unpack a compound value
	# to get it. Floor row is copied out even though nothing downstream reads it yet (Phase 3.1's
	# collision probe walks the tilemap directly and will hit a basin's floor tile the same way it
	# hits any other solid tile, with no basin-specific lookup needed) — kept anyway because the
	# roadmap's fixed data shape names it explicitly, and because the "Accurate basin floor mapping"
	# v2 goal is exactly about NOT discarding per-column floor data once a flat reference exists
	# elsewhere; may as well start the habit here rather than retrofit it later.

func register_basin(basin: WaterBasin) -> int:
	# Called by each basin in the scene at its own _ready() (deferred — see WaterBasin's own comment
	# on why) once this manager is guaranteed to exist in the "water_manager" group. Converts
	# whatever the source is (an authored WaterBasin node, today) into this manager's own fixed
	# per-column data shape; per the "kept swappable by design" decision, a future auto-detection
	# population pass would call this same function (or populate the same two Dictionaries directly)
	# without any of Phase 3+'s per-particle code needing to change.
	var basin_id := _basins.size()
	_basins.append(basin)
	var data := basin.get_registration_data()
	var columns: Array = data["columns"]
	var floor_rows: Array = data["floor_rows"]
	for i in columns.size():
		var col: int = columns[i]
		if not _column_basin_id.has(col):
			_column_basin_id[col] = []
		(_column_basin_id[col] as Array).append(basin_id)
		_column_floor_row[col] = floor_rows[i]
		# Overwritten by a later-registering stacked basin sharing this column — unread today (see
		# this dict's own comment above), so left as a single value rather than a list; if something
		# ever reads it, it needs the same per-id treatment _column_basin_id just got.
	return basin_id

func get_basin_for_column(map_col: int, world_y: float, rim_margin: float = 0.0) -> WaterBasin:
	# The "is this point inside a basin, and if so which one" lookup Phase 3.3's settle check and
	# Phase 4's push query both need. Almost always O(1) against a single-entry list; the loop only
	# runs more than once when basins are stacked in this column, in which case world_y is what
	# distinguishes them (see WaterBasin.owns_world_point()). Returns null for a column no
	# registered basin claims (open ground, or a wall column — walls are deliberately never entered
	# into _column_basin_id, see its own comment above) or where world_y falls in neither candidate's
	# range (e.g. still above the topmost basin's rim, mid-fall).
	if not _column_basin_id.has(map_col):
		return null
	for basin_id in (_column_basin_id[map_col] as Array):
		var basin: WaterBasin = _basins[basin_id]
		if basin.owns_world_point(map_col, world_y, rim_margin):
			return basin
	return null

func find_basin_at_point(world_point: Vector2) -> WaterBasin:
	# The basin (if any) whose interior contains a world point: the column from the world tilemap, then the same
	# get_basin_for_column() the player's swim probe uses. A spark asks this each frame to know whether it is over a pool.
	if _world_tilemap == null:
		return null
	var col := _world_tilemap.local_to_map(_world_tilemap.to_local(world_point)).x
	return get_basin_for_column(col, world_point.y)

func get_basin_count() -> int:
	return _basins.size()

func _ready() -> void:
	add_to_group("water_manager")
	_position.resize(MAX_PARTICLES)
	_velocity.resize(MAX_PARTICLES)
	_age.resize(MAX_PARTICLES)
	_creep_dir.resize(MAX_PARTICLES)
	_creep_reversals.resize(MAX_PARTICLES)
	_resting_body.resize(MAX_PARTICLES)
	_liquid_type.resize(MAX_PARTICLES)
	_visual_scale.resize(MAX_PARTICLES)
	_creep_speed_mult.resize(MAX_PARTICLES)
	_gravity_mult.resize(MAX_PARTICLES)
	_setup_multimesh()
	_world_tilemap = get_tree().get_first_node_in_group("world_tilemap")
	if _world_tilemap == null:
		push_warning("WaterManager: no TileMapLayer found in group 'world_tilemap' — particles will fall forever with nothing to land on")
	_player = get_tree().get_first_node_in_group("player")
		# No push_warning if missing, unlike _world_tilemap above: a level can legitimately have no
		# player (a standalone basin/particle test scene), and the rest of the simulation doesn't
		# depend on one existing — only push accumulation below silently no-ops without it.

	# Phase 9.1: deferred — see _registered_solids' own comment above for why this can't just run here
	# inline the way _world_tilemap/_player's lookups do.
	call_deferred("_collect_registered_solids")

func _collect_registered_solids() -> void:
	# No push_warning for an empty result, same reasoning as _player in _ready() above — a level with no
	# moving platforms/crushers/cannons/drop platforms legitimately registers nothing here, and the rest
	# of the simulation (tilemap collision, basins) doesn't depend on any existing.
	for node in get_tree().get_nodes_in_group("water_solid"):
		var solid := node as Node2D
		if solid != null:
			_registered_solids.append(solid)
	_registered_solid_prev_xform.resize(_registered_solids.size())
	for i in _registered_solids.size():
		_registered_solid_prev_xform[i] = _registered_solids[i].global_transform

func _setup_multimesh() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(LiquidConstants.PARTICLE_PIXEL_SIZE, LiquidConstants.PARTICLE_PIXEL_SIZE)
		# Centered on its own origin by default — matches the "_position is each particle's center"
		# convention noted above, so a transform with no rotation/scale and origin = _position[i]
		# places the square exactly where it should be with no extra offset math.

	_multimesh = MultiMesh.new()
	_multimesh.mesh = quad
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
		# mesh / transform_format / use_colors all have to be set BEFORE instance_count — instance_count
		# is what actually allocates the per-instance buffer, sized according to whatever format flags
		# are already in place.
	_multimesh.instance_count = MAX_PARTICLES
	_multimesh.visible_instance_count = 0
		# Starts at 0 (nothing active yet); _process() keeps this synced to _active_count every frame.

	_multimesh_instance = MultiMeshInstance2D.new()
	_multimesh_instance.name = "ParticleMultiMesh"
	_multimesh_instance.multimesh = _multimesh
	add_child(_multimesh_instance)

func _process(_delta: float) -> void:
	# Rendering-only sync, deliberately in _process() rather than _physics_process(): this loop just
	# copies whatever the position array currently holds into the multimesh's transform buffer, it
	# doesn't mutate simulation state — actual per-particle stepping (gravity/collision/etc., Phase 3,
	# below in _physics_process()) is a physics-frame concern kept separate from this rendering sync.
	_multimesh.visible_instance_count = _active_count
	for i in _active_count:
		var s := _visual_scale[i]
		var profile := LiquidConstants.profile(_liquid_type[i])
		if not profile.is_gas:
			# Liquids shrink to nothing over their last PARTICLE_SHRINK_TIME seconds (render-only).
			s *= clampf((profile.lifetime - _age[i]) / LiquidConstants.PARTICLE_SHRINK_TIME, 0.0, 1.0)
		_multimesh.set_instance_transform_2d(i, Transform2D(Vector2(s, 0.0), Vector2(0.0, s), _position[i]))
			# Built from basis vectors directly, not Transform2D(rotation, position).scaled(v): that
			# form's scale defaults to (1,1) with no way to set it in the same constructor, and
			# Transform2D.scaled() scales relative to the origin, which — for an unrotated transform
			# whose origin already IS _position[i] — happens to work out the same here, but building
			# the basis directly is one line, doesn't depend on that coincidence, and stays correct if
			# rotation is ever added later.

func _physics_process(delta: float) -> void:
	# Phase 3.1 (reworked): integrate gravity, then a single raycast along each particle's motion for
	# this frame, against the tilemap's ACTUAL collision shapes — not a flat per-tile-cell sample.
	# This is what makes slopes work: the hit normal is real (not always straight up), so resting
	# position, bounce, and sliding all fall out of standard reflect/project-onto-normal vector math
	# instead of needing separate slope-specific logic. This does mean `_step_particle_physics()`
	# below is a physics-server query, which "Particle world collision is custom, not physics" in
	# Decided originally ruled out — that bullet has been revised (see Decided above) once the flat
	# approximation turned out not to deliver the "shared slope-following" that same bullet already
	# promised. Collides against `_world_tilemap` and whatever's registered into `_registered_solids`
	# (Phase 9.1 — moving platforms, crusher's arm, cannon's static body, drop platforms), checked
	# per-hit below; still no particle-vs-particle collision, per the rest of that same bullet.
	#
	# One more change from the first pass: solidity is now whatever the tileset's own physics layer
	# says is solid, not a `surface_type == "ground" or "catwalk"` tag check. The old check matched
	# `basin.gd`/`player.gd`'s convention for "which tiles are grabbable/count-as-basin-floor," a
	# narrower, purpose-specific question than "is this tile solid at all" — a solid-but-untagged tile
	# (a wall, a ceiling) would previously have let water fall straight through it. Trusting the actual
	# collision shape is both simpler (no tag lookup at all) and strictly more correct for "what does
	# water bump into," at the cost of no longer being able to special-case a solid tile that ISN'T
	# meant to stop water — nothing currently needs that distinction, so this is a net simplification.
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")  # see the note on _player: its group is assigned at runtime
	_update_steam_lift_debug(delta)
	_push_total = Vector2.ZERO
	_push_max_speed = 0.0
	_resting_torque.clear()
	_steam_arrivals.clear()
	_age_steam_push(delta)  # before the early-out below, so a body's old steam fades even in a level with no tilemap
		# Reset before the early-outs below, not after — either one skips the per-particle loop
		# entirely for this frame, and a stale nonzero total from some earlier frame must never leak
		# through to player.gd's next get_player_push() call.
	if _world_tilemap == null:
		return  # nothing to collide against — see the _ready() warning; particles would just fall forever
	_update_solid_motions()  # Phase 9.2: must run before the particle loop below reads _solid_motion
	var space_state := get_world_2d().direct_space_state
	var half_particle := LiquidConstants.PARTICLE_PIXEL_SIZE * 0.5
	# while-loop rather than `for i in _active_count`: despawn_particle() swap-and-shrinks, moving the
	# last active particle INTO slot i, so after a despawn that same slot i must be processed again
	# (and the range shrinks under us). 3.3's basin absorb will despawn from this loop the same way.
	var i := 0
	while i < _active_count:
		_age[i] += delta
		var profile := LiquidConstants.profile(_liquid_type[i])
		if profile.is_gas:
			# STEAM: no absorb, no push, no hazard — rises on its spawn velocity until it hits a solid or its
			# own lifetime removes it. See _step_gas_particle()'s own comment.
			if _step_gas_particle(i, delta, space_state, half_particle) or _age[i] >= profile.lifetime:
				despawn_particle(i)
				continue  # slot i now holds a different particle — don't advance
			i += 1
			continue
		# Phase 4.1: push/hazard contribution is checked here, before either despawn path below, per
		# the "computed in the same per-frame loop that also runs the settle/absorb check, before
		# removal" decision — a particle that gets absorbed or times out THIS frame still counts for
		# the one frame it was still active.
		if _position[i].y > kill_y:
			despawn_particle(i)  # fell off the level — see kill_y
			continue  # slot i now holds a different particle — don't advance
		if _player != null:
			_accumulate_push_and_hazard(i, profile)
		if _age[i] >= profile.lifetime:
			despawn_particle(i)
			continue  # slot i now holds a different particle — don't advance
		if _try_absorb(i, half_particle):
			despawn_particle(i)
			continue  # slot i now holds a different particle — don't advance
		_velocity[i].y += PARTICLE_GRAVITY * _gravity_mult[i] * delta
		if not _handle_basin_surface(i, half_particle, delta):
			# Phase 9.2: carry happens BEFORE this frame's raycast, same ordering _follow_hang_platform()
			# uses for a hung player — shift first, then let the raycast re-settle against the surface
			# from the shifted position, so a particle riding a platform stays glued to it rather than
			# lagging a frame behind.
			if _resting_body[i] != null and _solid_motion.has(_resting_body[i]):
				_position[i] = _solid_motion[_resting_body[i]] * _position[i]  # translation, rotation or both
			_step_particle_physics(i, delta, space_state, half_particle)
		_accumulate_resting_torque(i)
		i += 1
	_fold_steam_arrivals()  # this frame's arrivals enter the history at age 0, so a reader sees them at full value
	# Two independent ceilings on the final push magnitude, tightest wins: LiquidConstants.PUSH_CAP is
	# the absolute outer bound regardless of what's contributing (see its own comment);
	# _push_max_speed keeps the player from ever being pushed faster than the fastest particle
	# currently pushing them, which is what actually prevents a large flood of slow, low-speed
	# particles from summing to an out-of-proportion push (see "Player push — model and cap" in
	# water-mechanic.md). With zero contributors this frame, _push_max_speed is 0.0 and _push_total is
	# already Vector2.ZERO, so the clamp is a no-op rather than zeroing anything that wasn't already
	# zero.
	var push_speed_cap := minf(LiquidConstants.PUSH_CAP, _push_max_speed)
	if _push_total.length_squared() > push_speed_cap * push_speed_cap:
		_push_total = _push_total.normalized() * push_speed_cap

func _step_gas_particle(i: int, delta: float, space_state: PhysicsDirectSpaceState2D, half_particle: float) -> bool:
	# STEAM's entire "physics": no gravity, no resting/creep state — move by the constant velocity emit_steam()
	# gave it, which nothing here ever changes. One ray per frame along this frame's motion (extended half a
	# particle, like a liquid's) finds a solid: the world tilemap or a registered "water_solid" body, with
	# catwalk tiles stepped past exactly as for liquid (_cast_ignoring_catwalks()) and any other collider
	# ignored. Returns true when the particle hit one, and the caller despawns it, so a column stops at a ceiling.
	var from := _position[i]
	var motion := _velocity[i] * delta
	_position[i] = from + motion
	if motion.length_squared() < 0.0001:
		return false
	var hit := _cast_ignoring_catwalks(space_state, from, from + motion + motion.normalized() * half_particle)
	if hit.is_empty():
		return false
	var collider: Object = hit.collider
	if collider == _world_tilemap:
		return true
	if collider in _registered_solids:
		_note_steam_arrival(collider, hit.normal, _velocity[i], _position[i].x)  # N3.5: the death is also a push
		return true
	return false

func _accumulate_resting_torque(i: int) -> void:
	# Rotating-bodies roadmap 2.2: a particle resting on a registered body that has a pivot (a RotatingBody, duck-typed
	# on get_pivot_global()) loads it like a rider would — its weight (the liquid's weight per tile of volume x the
	# particle's volume, in block-mass units) times its horizontal offset from the pivot. Read after this frame's
	# step, so _resting_body[i] is what the particle is on now; a full basin's synthesized surface or a miss leaves
	# it null and adds nothing.
	var body := _resting_body[i]
	if body == null or not body.has_method("get_pivot_global"):
		return
	var weight := LiquidConstants.profile(_liquid_type[i]).weight_per_tile_volume * LiquidConstants.PARTICLE_VOLUME
	if weight <= 0.0:
		return
	var pivot: Vector2 = body.call("get_pivot_global")
	_resting_torque[body] = float(_resting_torque.get(body, 0.0)) + weight * (_position[i].x - pivot.x)

const STEAM_TORQUE_PER_PARTICLE := 1.17
	# Torque a dying steam particle adds per pixel of its horizontal lever arm from the pivot (so a particle at 16 px
	# adds about 19, one at 8 px about 9), before the body's steam_torque_scale. Calibrated against the default
	# boil: a boilable pool at BOIL_STEAM_VOLUME_PER_SEC (1 tile/s, so 16 particles/s) with its whole column
	# arriving at the tip of a 2-tile plank (16 px) settles at 16 x 16 x 1.17 x (STEAM_PUSH_DECAY_TIME / 2) = about 45,
	# more than the player's weight at the tip (2 x 16 = 32) and less than a 1x1 metal block's (4 x 16 = 64). One
	# puff does almost nothing; the number is the arrival rate times the lever arm. Roadmap N3.5; tune by feel.
const STEAM_PUSH_DECAY_TIME := 0.3
	# s over which one arrival's push falls linearly from full to nothing (the same time as STEAM_LIFT_DECAY_TIME).
const STEAM_PUSH_FACE_DOT := -0.5
	# A steam particle pushes only if the surface it died on faces it: the hit normal's dot with the particle's
	# direction of travel must be at or below this (-0.5 = within 60 degrees of head-on). The underside of a plank
	# at its 25 degree stop reads about -0.9; an end face reads about 0, and does not count.

## Roadmap N3.5: called when a steam particle dies on a registered solid. A body with a pivot (a RotatingBody) whose
## struck face opposes the particle's motion (only the underside of a plank) receives an UPWARD push: STEAM_TORQUE_PER_
## PARTICLE x the particle's horizontal offset from the pivot, with the sign of an upward push at that lever arm
## (counter-clockwise right of the pivot, clockwise left of it). Anything else, a platform or the world tilemap, is
## ignored. A ray that starts inside a body reports a zero normal and is ignored too.
func _note_steam_arrival(body: Object, normal: Vector2, velocity: Vector2, x: float) -> void:
	if not body.has_method("get_pivot_global") or velocity.length_squared() < 0.0001:
		return
	if normal.dot(velocity.normalized()) > STEAM_PUSH_FACE_DOT:
		return
	var pivot: Vector2 = body.call("get_pivot_global")
	_steam_arrivals[body] = float(_steam_arrivals.get(body, 0.0)) - STEAM_TORQUE_PER_PARTICLE * (x - pivot.x)

func _age_steam_push(delta: float) -> void:
	for body in _steam_push.keys():
		if not is_instance_valid(body):
			_steam_push.erase(body)
			continue
		var kept: Array[Vector2] = []
		for entry: Vector2 in _steam_push[body]:
			if entry.x + delta < STEAM_PUSH_DECAY_TIME:
				kept.append(Vector2(entry.x + delta, entry.y))
		if kept.is_empty():
			_steam_push.erase(body)
		else:
			_steam_push[body] = kept

func _fold_steam_arrivals() -> void:
	for body in _steam_arrivals:
		var entries: Array[Vector2] = _steam_push.get(body, [] as Array[Vector2])
		entries.append(Vector2(0.0, float(_steam_arrivals[body])))
		_steam_push[body] = entries

## Roadmap N3.5: the torque, about its pivot (positive = clockwise on screen, so an upward push on the right end is
## negative), of the steam that has died on `body`'s underside within the last STEAM_PUSH_DECAY_TIME: the sum of every
## arrival's ramp, so it rises at once and a denser column reads higher. 0.0 for a body steam has not touched.
## RotatingBody scales it by `steam_torque_scale`.
func get_steam_torque(body: Node2D) -> float:
	var total := 0.0
	for entry: Vector2 in _steam_push.get(body, [] as Array[Vector2]):
		total += entry.y * (1.0 - entry.x / STEAM_PUSH_DECAY_TIME)
	return total

## Torque about its pivot (positive = clockwise on screen) of the liquid resting on `body` this physics frame, in the
## same units as a rider's torque; 0.0 for a body with nothing on it or no pivot. RotatingBody adds it to its net torque.
func get_resting_torque(body: Node2D) -> float:
	return float(_resting_torque.get(body, 0.0))

## Rotating-bodies roadmap 3.1: makes `body`'s stored previous transform its current one and drops this frame's
## motion for it, so a teleport (a checkpoint restore snapping a see-saw to its saved angle) isn't carried to the
## particles resting on it as if it were an ordinary frame's movement. A body not registered yet (the registration is
## deferred, and a restore runs before it) has nothing stored and is ignored: its transform is taken fresh when it is.
func forget_motion(body: Node2D) -> void:
	var index := _registered_solids.find(body)
	if index >= 0:
		_registered_solid_prev_xform[index] = body.global_transform
	_solid_motion.erase(body)
	_steam_push.erase(body)  # N3.5: a restored plank comes back level and the column rebuilds

func _update_solid_motions() -> void:
	# Phase 9.2: rebuilt from scratch every physics frame, before the particle loop reads it. A freed
	# registered solid (nothing currently frees one at runtime, but a future destructible might) is
	# skipped rather than crashing — its last-known motion simply stops updating, which only matters for
	# a particle still marked as resting on it, and that particle's next failed raycast against the now-
	# gone body clears _resting_body[i] the normal way (see _step_particle_physics()).
	_solid_motion.clear()
	for i in _registered_solids.size():
		var body := _registered_solids[i]
		if not is_instance_valid(body):
			continue
		var now := body.global_transform
		var before := _registered_solid_prev_xform[i]
		_registered_solid_prev_xform[i] = now
		if now != before:
			_solid_motion[body] = now * before.affine_inverse()

func _accumulate_push_and_hazard(i: int, profile: LiquidConstants.LiquidProfile) -> void:
	# Phase 4.1 push, extended for a hazardous LiquidType (slag): both checks share the same radius
	# query against the player, since "close enough to shove" and "close enough to burn" are the same
	# proximity question for a flowing hazard — see PLAYER_PUSH_RADIUS's own comment for the one open
	# question about whether that should eventually be two separate radii.
	if _position[i].distance_squared_to(_player.global_position) > PLAYER_PUSH_RADIUS * PLAYER_PUSH_RADIUS:
		return
	if profile.is_hazardous and _player.has_method("take_hit"):
		# Duck-typed like every other hazard/interactable in this project (take_hit()/collect_gem()/
		# get_conveyor_speed()/launch()). Called every physics frame a hazardous particle is in range,
		# the same poll-every-frame posture sawwheel.gd/crusher.gd use for their own hazards —
		# take_hit()'s own i-frames are what keep this from being a full hit every single frame of
		# contact, not anything on this end.
		_player.take_hit(SLAG_PARTICLE_DAMAGE, _position[i])
	# Direction from the PARTICLE'S OWN velocity rather than its position relative to the player. A
	# stationary/settled particle (creep stopped, resting on a full basin's floor with nothing left to
	# do) has no velocity to take a direction from and correctly contributes nothing to push even while
	# touching the player — matches the intended fantasy of moving liquid shoving the player, not every
	# nearby drop doing so regardless of whether it's actually flowing. (Hazard above is NOT gated on
	# this — a puddle of settled-adjacent slag that's stopped moving should still burn on contact, only
	# push cares whether it's still in motion.)
	var speed := _velocity[i].length()
	if speed < 0.01:
		return
	var push_per_particle := profile.push_force_per_tile_volume * LiquidConstants.PARTICLE_VOLUME
	_push_total += _velocity[i] / speed * push_per_particle
	_push_max_speed = maxf(_push_max_speed, speed)
		# Tracked from EVERY contributor, not just whichever ends up fastest overall in isolation —
		# this is what _physics_process()'s final clamp uses to keep the summed push from outrunning
		# the liquid that's actually producing it (see that clamp's own comment).

# --- Surfing queries (player.gd, stage 4) ------------------------------------------------------
# Both are pulled by the player only while it surfs, so they cost nothing the rest of the time.
const WET_BAND_ABOVE := 8.0
	# px above the feet within which a particle counts as lying on the floor (a film is one or two particles deep).
const WET_BAND_BELOW := 2.0
	# px below the feet still counted, for contact noise.
const WET_MIN_SPEED := 8.0
	# px/s: a particle slower than this is settled, not running, and does not wet the floor.
const WET_MAX_VERTICAL_SPEED := 60.0
	# px/s: a particle moving faster than this vertically is falling or bouncing (a waterfall overhead, a splash), not a film.
const WET_FULL_COVERAGE := 0.5
	# Fraction of the footprint's width that running particles must cover for the floor to read fully wet.

func get_floor_wetness(feet: Vector2, half_width: float) -> float:
	# 0..1: how wet the floor under a footprint is right now. Counts non-hazardous liquid particles that are
	# running (above WET_MIN_SPEED, not falling) in a thin band just above the feet; slag is a hazard, not a surface,
	# and steam is a gas, so neither counts. Coverage is the summed particle width over the footprint's width, so
	# the reading does not depend on ACTIVE_PRESET. Noisy as particles come and go: the caller smooths it.
	var reach := half_width + LiquidConstants.PARTICLE_PIXEL_SIZE * 0.5
	var covered := 0.0
	for i in _active_count:
		var profile := LiquidConstants.profile(_liquid_type[i])
		if profile.is_gas or profile.is_hazardous:
			continue
		var p := _position[i]
		if absf(p.x - feet.x) > reach or p.y > feet.y + WET_BAND_BELOW or p.y < feet.y - WET_BAND_ABOVE:
			continue
		var v := _velocity[i]
		if v.length() < WET_MIN_SPEED or absf(v.y) > WET_MAX_VERTICAL_SPEED:
			continue
		covered += LiquidConstants.PARTICLE_PIXEL_SIZE
	return clampf(covered / maxf(half_width * 2.0, 1.0) / WET_FULL_COVERAGE, 0.0, 1.0)

const STEAM_LIFT_FULL_COVERAGE := 0.5
	# Fraction of the rect's width that steam must cover for the lift to read 1. Placeholder: retune with the
	# column's density (STEAM_PUFFS_PER_TILE_VOLUME) and the surfer's lift (roadmap 4.3).
const STEAM_LIFT_DECAY_TIME := 0.3
	# s for a smoothed reading to fall from 1 to 0 once the steam is gone (it rises at once). Placeholder.
const STEAM_LIFT_MAX_BINS := 32
	# The rect's width is split into at most this many equal bins; a bin counts as covered if any steam
	# particle's footprint touches it (at most 32, so the coverage mask fits in one int).

## 0..1: how much of `rect` (world space, e.g. the board's footprint) steam covers right now. Steam particles
## whose footprint overlaps the rect's height count by the horizontal span they cover, merged, so a dense
## column doesn't read stronger than a thin one that spans the same width, and the reading does not depend on
## the particle preset or the rect's height. Edge particles cover only the bins they touch, so the reading
## changes by a bin at a time as the rect slides across the column's edge.
##
## The raw reading is noisy as particles come and go. A caller that wants it steady passes its previous
## smoothed value and the frame time: the result is then `max(reading, previous - delta / STEAM_LIFT_DECAY_TIME)`
## (instant rise, linear decay, like the surf's wetness). With the defaults (`previous` 0, `delta` 0) it is the
## raw reading. Stateless: the manager keeps no per-caller value, so several callers can use it at once.
func get_steam_lift(rect: Rect2, previous: float = 0.0, delta: float = 0.0) -> float:
	var reading := _steam_coverage(rect) / STEAM_LIFT_FULL_COVERAGE
	return clampf(maxf(reading, previous - delta / maxf(STEAM_LIFT_DECAY_TIME, 0.001)), 0.0, 1.0)

func _steam_coverage(rect: Rect2) -> float:
	# Fraction (0..1) of the rect's width covered by steam particles inside its height. See get_steam_lift().
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return 0.0
	var half := LiquidConstants.PARTICLE_PIXEL_SIZE * 0.5
	var bins := clampi(ceili(rect.size.x), 1, STEAM_LIFT_MAX_BINS)
	var bin_width := rect.size.x / float(bins)
	var mask := 0
	for i in _active_count:
		if not LiquidConstants.profile(_liquid_type[i]).is_gas:
			continue
		var p := _position[i]
		if p.y + half < rect.position.y or p.y - half > rect.end.y:
			continue
		var lo := floori((p.x - half - rect.position.x) / bin_width)
		var hi := floori((p.x + half - rect.position.x) / bin_width)
		if hi < 0 or lo >= bins:
			continue
		lo = maxi(lo, 0)
		hi = mini(hi, bins - 1)
		mask |= ((1 << (hi - lo + 1)) - 1) << lo
	var covered := 0
	for b in bins:
		if (mask & (1 << b)) != 0:
			covered += 1
	return float(covered) / float(bins)

# --- Steam lift debug readout (debug_steam_lift) -------------------------------------------------
var _debug_steam_lift: float = 0.0
var _debug_steam_layer: CanvasLayer
var _debug_steam_label: Label

func _update_steam_lift_debug(delta: float) -> void:
	# Queries get_steam_lift() for the player's current collider rect each physics frame and shows the raw and
	# smoothed readings. Nothing else reads them; with the flag off it only hides the label.
	if not debug_steam_lift or _player == null or not is_instance_valid(_player):
		if _debug_steam_layer != null:
			_debug_steam_layer.visible = false
		return
	var shape_node := _player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null or shape_node.shape == null:
		return
	var size := Vector2.ZERO
	if shape_node.shape is RectangleShape2D:
		size = (shape_node.shape as RectangleShape2D).size
	elif shape_node.shape is CapsuleShape2D:
		var capsule := shape_node.shape as CapsuleShape2D
		size = Vector2(capsule.radius * 2.0, capsule.height)
	var rect := Rect2(shape_node.global_position - size * 0.5, size)
	var raw := get_steam_lift(rect)
	_debug_steam_lift = get_steam_lift(rect, _debug_steam_lift, delta)
	if _debug_steam_layer == null:
		_debug_steam_layer = CanvasLayer.new()
		_debug_steam_layer.layer = 100
		_debug_steam_label = Label.new()
		_debug_steam_label.position = Vector2(12, 12)
		_debug_steam_layer.add_child(_debug_steam_label)
		add_child(_debug_steam_layer)
	_debug_steam_layer.visible = true
	_debug_steam_label.text = "steam lift  raw %.2f  smoothed %.2f" % [raw, _debug_steam_lift]

func find_skim_basin(world_x: float, feet_y: float, catch_depth: float) -> WaterBasin:
	# The basin whose settled liquid a surfer at (world_x, feet_y) can skim: in that column, holding liquid that is not
	# hazardous right now (slag, or water a spark has electrified) with no crust over it, with its surface at or below the feet (or up to catch_depth px above them), and
	# the feet not below its seabed. With basins stacked in one column the nearest surface below wins. Null if none.
	if _world_tilemap == null:
		return null
	var col := _world_tilemap.local_to_map(_world_tilemap.to_local(Vector2(world_x, feet_y))).x
	if not _column_basin_id.has(col):
		return null
	var best: WaterBasin = null
	var best_gap := INF
	for basin_id in (_column_basin_id[col] as Array):
		var basin: WaterBasin = _basins[basin_id]
		if basin.has_crust or not basin.has_liquid_at_column(col):
			continue
		if basin.is_hazardous_now():
			continue
		if feet_y > basin.get_column_seabed_world_y(col):
			continue
		var gap := basin.get_liquid_surface_world_y() - feet_y  # >= 0: the surface is below the feet
		if gap < -catch_depth or gap >= best_gap:
			continue
		best = basin
		best_gap = gap
	return best

func get_player_push() -> Vector2:
	# Phase 4.2: player.gd's _water_push_speed() reads this each physics frame and adds its .x
	# component onto velocity.x, the same call shape as _conveyor_push_speed(). Returned as a full
	# Vector2 (rather than pre-collapsing to a scalar here) so a later phase that wants the vertical
	# component too — none currently does — doesn't need this signature to change.
	return _push_total

func _basin_for_particle(i: int) -> WaterBasin:
	# Shared by _try_absorb() and _handle_basin_surface() below — both need "which basin (if any) is
	# this particle's column part of," they just react to it differently depending on whether that
	# basin is currently full.
	#
	# A particle whose TOP edge is below its column's seabed has left the basin through the bottom
	# (a drain faucet's outlet, or simply falling past a basin's floor from above into a lower
	# level) — it isn't in the basin any more, so this returns null for it. Without this, a drained
	# particle spawned in its own basin's column would satisfy the "reached the surface" check on its
	# first frame and be absorbed straight back in, and a full basin's
	# synthesized surface contact would snap it up to the waterline. The seabed used is each
	# column's DEEPEST floor point, so a particle resting on a sloped floor tile is never mistaken
	# for one that has left.
	var map_col: int = _world_tilemap.local_to_map(_world_tilemap.to_local(_position[i])).x
	var half_particle := LiquidConstants.PARTICLE_PIXEL_SIZE * 0.5
	# The rim margin is the particle's own half-size (plus a hair for float error): a particle resting
	# on a full basin's surface has its centre half a particle above that surface, and the surface is
	# level with the rim whenever the basin's shorter wall starts at its origin row. Without the margin
	# such a particle is "outside" the basin, so _handle_basin_surface() never holds it on the surface —
	# it sinks until its centre crosses the rim, gets snapped back up, and repeats (visible jitter while
	# creeping on settled liquid; solid ground is unaffected since a raycast always finds it).
	var basin := get_basin_for_column(map_col, _position[i].y, half_particle + REST_TOLERANCE)
	if basin == null:
		return null
	if _position[i].y - half_particle > basin.get_column_seabed_world_y(map_col):
		return null
	return basin

func world_to_cell(world_pos: Vector2) -> Vector2i:
	# World position -> tilemap cell, through the tilemap's own transform (the same conversion
	# _basin_for_particle() uses). For anything placed on the tile grid that needs to know which cell
	# it occupies — currently WaterFaucet's drain link. (0,0) with no tilemap registered.
	if _world_tilemap == null:
		return Vector2i.ZERO
	return _world_tilemap.local_to_map(_world_tilemap.to_local(world_pos))

func get_tile_size() -> Vector2:
	if _world_tilemap != null and _world_tilemap.tile_set != null:
		return Vector2(_world_tilemap.tile_set.tile_size)
	return Vector2(16, 16)

func _try_absorb(i: int, half_particle: float) -> bool:
	# Phase 3.3: is this particle over a registered basin's interior, has it sunk to (or past) that
	# basin's current surface, AND does it belong there? If so, resolve it immediately (one of two
	# ways — see below) and report true so the caller despawns it. Checked BEFORE this frame's
	# gravity/collision step (same spot 4.1's push query will slot into later), so a resolved particle
	# never gets a chance to collide with the basin floor tile it's about to interact with instead.
	var basin := _basin_for_particle(i)
	if basin == null:
		return false
	# Compare the particle's LEADING (bottom) edge against the surface line, not its center — the
	# same "half a particle out from the surface" convention _step_particle_physics() rests a particle
	# by. Comparing centers was the bug found in-editor: at zero fill, get_surface_world_y() equals the
	# basin floor's own top edge, and a particle resting on that floor settles with its CENTER
	# half_particle above it (by construction, so its body doesn't poke through) — so a center
	# comparison could never be satisfied, and particles just sank to the physical floor and crept
	# there forever, never absorbing. The bottom edge reaches the surface line exactly when the
	# particle's body would otherwise start overlapping the settled liquid, at any fill level, empty
	# or not. get_surface_world_y() is the basin's OUTER surface (the crust's top face when crusted, else the
	# liquid surface), which is exactly the line a particle has to reach either way.
	if _position[i].y + half_particle < basin.get_surface_world_y():
		return false  # still above the current surface — falls/creeps as normal until it reaches it
	if basin.has_crust:
		# The outer surface here is a rigid crust, not liquid, so nothing is ever absorbed into it. An
		# opposite-type particle reaching it (water on a slag basin's crust, say) evaporates on contact into
		# a steam puff, whether or not liquid still touches the crust's underside: the crust is fixed once
		# formed, so this is purely a particle sink with an effect. Same-type liquid arriving on top just rests
		# on the crust body (registered "water_solid") and creeps along it like on any other solid.
		if _liquid_type[i] != basin.liquid_type:
			emit_steam(_steam_origin(i, basin, half_particle), LiquidConstants.PARTICLE_VOLUME)
			return true
		return false
	if basin.fill_volume <= 0.0:
		# Empty (and crust-free, guaranteed above) — fluid-agnostic: whichever liquid arrives first
		# claims the basin, so the same-type branch just below is guaranteed to run. This is also why
		# the MISMATCHED branch further down can assume "no fill_volume means nothing to react with":
		# an empty basin can never disagree with an incoming particle, only an already-claimed one can.
		basin.liquid_type = _liquid_type[i]
	if _liquid_type[i] == basin.liquid_type:
		# SAME type as this basin's native liquid: the ordinary case. A FULL basin never absorbs
		# here — see _handle_basin_surface() below, which is what a full basin's particles hit
		# instead; this is the one case where is_full() still needs its own check, since a
		# same-type particle reaching a full basin's surface is meant to creep out, not be credited.
		if basin.is_full():
			return false
		basin.add_volume(LiquidConstants.PARTICLE_VOLUME)
		# Cosmetic: the landing stirs the settled surface (see basin.gd, "Surface ripple"). Scaled by particle
		# volume so a finer ACTIVE_PRESET (more, lighter particles) disturbs it the same in total.
		basin.disturb(_position[i].x, -absf(_velocity[i].y) * LiquidConstants.RIPPLE_PARTICLE_IMPULSE
				* LiquidConstants.PARTICLE_VOLUME * LiquidConstants.RIPPLE_REFERENCE_PARTICLES_PER_TILE)
		return true
	# MISMATCHED type meeting an as-yet crust-free body: converts the top layer of whatever's settled
	# into the basin's first crust. Deliberately NOT gated on is_full() — the reaction is with
	# whatever fill_volume holds, full or not.
	if basin.fill_volume <= 0.0:
		return false  # unreachable in practice now (an empty basin claims _liquid_type[i] above and
		# takes the SAME-type branch instead) — left as a defensive fallback, not deleted.
	basin.convert_to_crust(LiquidConstants.PARTICLE_VOLUME)
	emit_steam(_steam_origin(i, basin, half_particle), LiquidConstants.PARTICLE_VOLUME)
	return true

func _handle_basin_surface(i: int, half_particle: float, delta: float) -> bool:
	# Phase 3.4: the full-basin counterpart to _try_absorb() above. A full basin's surface is not real
	# tilemap geometry, so _step_particle_physics()'s raycast can never find it — instead, once a
	# particle over a full basin's columns reaches that surface line, this synthesizes exactly the
	# "hit" a real raycast would have produced (a floor-normal hit at the surface line) and feeds it
	# into the SAME _resolve_surface_contact() a real hit uses, rather than teaching creep/bounce/slide
	# a second, parallel implementation. Returns true if it handled the particle this frame, in which
	# case the caller skips the real collision raycast entirely for this particle this frame.
	#
	# No authored spill point, no picked-in-code exit direction: the water surface at 100% capacity
	# sits exactly level with the SHORTER wall's own top (that's the definition of _capacity_volume in
	# basin.gd — capacity is whatever volume brings the surface up to the spill column's height), so a
	# particle creeping along this surface with the ordinary 3.2 rules walks itself into that wall's
	# TOP as a non-obstacle (the surface line passes right over it) and off the far side, while the
	# TALLER wall still physically rises above this line and blocks/reverses it exactly like any other
	# wall — both for free, no basin-specific direction logic needed.
	var basin := _basin_for_particle(i)
	if basin == null or not basin.is_full():
		return false
	var surface_y := basin.get_surface_world_y()
	if _position[i].y + half_particle < surface_y - REST_TOLERANCE:
		return false  # still above the surface line — falls normally until it reaches it
	# The synthesized hit's x must be ADVANCED by this frame's velocity, not just read off the
	# particle's current (pre-motion) x — a real raycast hit naturally carries this motion because it's
	# found by casting along `from -> to` (see _step_particle_physics()), but a synthesized hit has no
	# such cast to inherit it from. Missing this was the bug found in-editor: `_resolve_surface_contact()`
	# always overwrites `_position[i]` outright from the hit position it's given, so without advancing
	# x here, every frame just re-pinned the particle to the same x it already had — velocity was being
	# assigned correctly (creep, not zero) but never actually got to move anything, which is exactly
	# why it looked like a static float rather than a missing creep case. This is also why it visibly
	# dipped one frame first: the frame BEFORE first reaching the surface, nothing here caught it yet
	# (still "above" by this check) so the real raycast ran instead, found nothing solid at that shallow
	# height, and let it fall its full unclamped `to` for that frame — straight past the surface line —
	# before this function caught it the following frame and snapped it back up to rest height.
	var advanced_x := _position[i].x + _velocity[i].x * delta
	_resolve_surface_contact(i, Vector2(advanced_x, surface_y), Vector2.UP, half_particle, false)
	_resting_body[i] = null  # Phase 9.2: a full basin's synthesized surface is never a registered solid
	return true

func _step_particle_physics(i: int, delta: float, space_state: PhysicsDirectSpaceState2D, half_particle: float) -> void:
	var from := _position[i]
	var to := from + _velocity[i] * delta
	if _velocity[i].length_squared() < 0.0001:
		_position[i] = to
		return  # not moving — nothing to cast along

	# The ray is extended half a particle PAST this frame's motion, along the direction of travel. A
	# particle's center rests half_particle off the surface (see below), so a ray that only reached
	# `to` would miss a resting particle entirely — it would sink until its center touched the surface
	# (half embedded), get popped back out as a hard "impact", and hop every few frames. Casting to the
	# particle's leading edge instead makes a resting particle re-hit the same surface every frame.
	var probe_to := to + _velocity[i].normalized() * half_particle
	# Catwalk tiles are invisible to water: _cast_ignoring_catwalks() steps past them, so a hit that
	# comes back is never one.
	var hit := _cast_ignoring_catwalks(space_state, from, probe_to)

	if hit.is_empty():
		_resting_body[i] = null
		_position[i] = to
		return  # nothing solid along this frame's motion — keep falling/moving

	# Phase 9.1: "which colliders count" now accepts _world_tilemap OR anything self-registered into
	# _registered_solids — everything else the mask happens to also hit (an unregistered body) is
	# discarded the same as a miss, exactly as an untracked collider already was before this phase.
	# _resting_body[i] records which kind of surface this is, for Phase 9.2's carry lookup next frame —
	# null for the tilemap (never carried; it doesn't move) or nothing, the registered body otherwise.
	var collider: Object = hit.collider
	if collider == _world_tilemap:
		_resting_body[i] = null
	elif collider in _registered_solids:
		_resting_body[i] = collider
	else:
		_resting_body[i] = null
		_position[i] = to
		return

	# `hit` is a Dictionary (intersect_ray()'s return type), so its values are statically Variant —
	# pulled into explicitly-typed locals before handing off, so _resolve_surface_contact() can stay
	# statically typed regardless of whether its caller got here via a real raycast or (3.4) a
	# synthesized full-basin surface contact.
	_resolve_surface_contact(i, hit.position, hit.normal, half_particle)

# Water has no physics interaction at all with tiles whose surface_type is "catwalk": particles fall
# through them, don't rest on them, and never bounce or creep along them. (Catwalks stay solid for the
# player, and WaterBasin ignores them when deriving floors and walls — see basin.gd.) A ray can't be
# filtered per tile, so a hit on a catwalk cell is stepped past and the ray re-cast from just beyond
# it, up to MAX_CATWALK_PASSES times per particle per frame.
const MAX_CATWALK_PASSES := 4
const CATWALK_PASS_NUDGE := 1.0

func _cast_ignoring_catwalks(space_state: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2) -> Dictionary:
	var dir := (to - from).normalized()
	var reach := from.distance_to(to)
	var origin := from
	for _pass in MAX_CATWALK_PASSES + 1:
		var hit := space_state.intersect_ray(PhysicsRayQueryParameters2D.create(origin, to, tile_collision_mask))
		if hit.is_empty() or not _is_catwalk_hit(hit):
			return hit
		origin = hit.position + dir * CATWALK_PASS_NUDGE
		if from.distance_to(origin) >= reach:
			return {}  # stepped past the end of this frame's motion
	return {}  # a pathological run of catwalk hits: treat as a miss

# Whether a hit landed on a catwalk tile of the world tilemap (SurfaceTypes owns the surface_type test and the
# nudge into the tile). Bodies in group "catwalk" are not stepped past: only tiles are.
func _is_catwalk_hit(hit: Dictionary) -> bool:
	if hit.collider != _world_tilemap:
		return false
	return SurfaceTypes.is_catwalk(SurfaceTypes.surface_at_hit(_world_tilemap, hit.position, hit.normal))

func _resolve_surface_contact(i: int, hit_position: Vector2, hit_normal: Vector2, half_particle: float, allow_bounce: bool = true) -> void:
	# Everything that happens once SOMETHING solid has been contacted, real or synthesized — bounce vs.
	# land, creep direction/blocking, sliding. Split out from _step_particle_physics() (which finds the
	# contact) so that 3.4's full-basin surface — not real tilemap geometry, so never something a
	# raycast can find — can be fed through the exact same landing/creep rules a real wall or floor hit
	# already uses, via _handle_basin_surface() constructing a straight-up-normal "hit" at the basin's
	# current surface line and calling this directly, instead of teaching creep/bounce/slide a second,
	# parallel implementation.
	#
	# `allow_bounce` defaults on (a real wall/floor hit should still bounce a fast-falling particle the
	# same as always) but `_handle_basin_surface()` passes false — there's no solid surface to bounce
	# off at a full basin's water line, just more water, so a particle arriving with real fall speed
	# should settle immediately rather than be reflected. Without this, a particle that had fallen any
	# real distance before reaching a full basin would exceed BOUNCE_MIN_IMPACT_SPEED, bounce upward,
	# leave the synthesized surface's height, fall back into it, bounce again, and so on — decaying
	# slowly enough via its own type's bounce_restitution each cycle to read as "floating"/jittering at
	# the surface for a long time rather than ever reaching the creep code below. Found in-editor: this
	# was exactly what "particles just float and don't creep" turned out to be.

	# Rest half the particle's own size OUT from the surface along its normal, not exactly at the hit
	# point — otherwise the particle's body would still poke through whatever it just landed on. On
	# flat ground hit_normal is straight up and this is "bottom edge on the floor".
	_position[i] = hit_position + hit_normal * half_particle
	var profile := LiquidConstants.profile(_liquid_type[i])
		# bounce_restitution/slope_slide_friction/creep_speed below are all per-LiquidType — see
		# LiquidConstants.profile() for water's/slag's own values (slag creeps slower, barely bounces,
		# and loses more speed to friction, per the "slag flows more slowly" design goal).
	var is_floor := hit_normal.y < FLOOR_NORMAL_MAX_Y

	# First floor contact: choose the creep direction — moved ahead of the bounce check below so a
	# direction is picked on the very FIRST floor contact, bounce or not, rather than waiting for
	# bounces to fully decay first (see BOUNCE_CREEP_BLEND just below for why that wait mattered). On
	# a slope, DOWNHILL (the way the surface leans); otherwise the particle's own horizontal velocity
	# if it has any (read before any bounce reflection touches _velocity[i]), else random.
	if is_floor and _creep_dir[i] == 0:
		if absf(hit_normal.x) > UPHILL_MIN_NORMAL_X:
			_creep_dir[i] = 1 if hit_normal.x > 0.0 else -1
		elif absf(_velocity[i].x) > 5.0:
			_creep_dir[i] = 1 if _velocity[i].x > 0.0 else -1
		else:
			_creep_dir[i] = 1 if randf() < 0.5 else -1

	# Blocked ahead = this surface leans AGAINST the creep direction, i.e. continuing means going
	# uphill (any slope) or into a wall. One rule covers both, so a slope and a wall can't be
	# classified differently by an arbitrary angle cutoff. A floor-like surface always blocks (a
	# particle must never creep up it); a wall-ish surface only counts if the particle is actually
	# moving into it, so one sliding down alongside a wall doesn't burn its reversal.
	#
	# Computed BEFORE the bounce check below, and checked there too — not just here — because a
	# creeping particle's own speed can easily exceed BOUNCE_MIN_IMPACT_SPEED (water's creep_speed is
	# 24, the threshold is 10), so a creeping particle arriving square at a wall used to ALWAYS take
	# the bounce branch and `return` before ever reaching this check: the reversal below (and
	# MAX_CREEP_REVERSALS along with it) was unreachable for that case no matter how it was tuned,
	# and every bounce just reflected velocity in place without ever flipping `_creep_dir`, so the
	# particle walked straight back into the same wall next frame and bounced again forever — the
	# reported "stuck in the corner" bug. A wall hit before a particle has ever creeped (no
	# `_creep_dir` yet, e.g. an airborne particle splashing into a wall) still bounces normally: `dir`
	# is 0 until a floor contact sets it, so `opposes` is false and this never blocks it.
	var dir := _creep_dir[i]
	var tangent_velocity := _velocity[i] - hit_normal * _velocity[i].dot(hit_normal)
	var opposes := dir != 0 and absf(hit_normal.x) > UPHILL_MIN_NORMAL_X \
			and signf(hit_normal.x) == -float(dir)
	var blocked := opposes and (is_floor or _velocity[i].x * dir > 0.0)

	if allow_bounce and not blocked:
		var impact_speed := -_velocity[i].dot(hit_normal)  # how hard it's hitting, along the normal
		if impact_speed > BOUNCE_MIN_IMPACT_SPEED:
			_velocity[i] = _velocity[i].bounce(hit_normal) * profile.bounce_restitution
			# Blend in a bit of creep now, mid-bounce, rather than only once impact speed finally decays
			# below BOUNCE_MIN_IMPACT_SPEED — a particle that only gets one shot at moving per FULL bounce
			# cycle (which can take several frames to decay) reads as hopping in place far longer than it
			# should before it visibly starts flowing. `is_floor` guards this: a wall bounce never had a
			# creep_dir assigned above (creep is floor-only), so this is a no-op there, same as always. No
			# separate opposes-guard needed here any more — `not blocked` above already guarantees this
			# bounce isn't heading into a wall/uphill slope the particle is meant to reverse away from.
			if is_floor and dir != 0:
				var bounce_tangent := Vector2(-hit_normal.y, hit_normal.x)
				if bounce_tangent.x * dir < 0.0:
					bounce_tangent = -bounce_tangent
				_velocity[i] += bounce_tangent * profile.creep_speed * _creep_speed_mult[i] * BOUNCE_CREEP_BLEND
			return

	if blocked:
		if debug_log_reversals:
			print("WaterManager: creep blocked at ", _position[i], " normal ", hit_normal, " dir ", dir, " reversed ", _creep_reversals[i])
		if MAX_CREEP_REVERSALS < 0 or _creep_reversals[i] < MAX_CREEP_REVERSALS:
			_creep_dir[i] = -dir
			_creep_reversals[i] = mini(_creep_reversals[i] + 1, CREEP_STOPPED - 1)
		else:
			_creep_reversals[i] = CREEP_STOPPED  # out of reversals: stop creeping for good
		_velocity[i] = tangent_velocity * profile.slope_slide_friction
		return

	if is_floor and _creep_reversals[i] != CREEP_STOPPED:
		# Creep along the surface tangent in the creep direction (follows slopes; by the check above
		# this is never uphill). A particle already sliding downhill faster than its own type's
		# creep_speed keeps its friction-damped speed rather than being slowed to a crawl.
		var tangent := Vector2(-hit_normal.y, hit_normal.x)
		if tangent.x * dir < 0.0:
			tangent = -tangent
		var along := tangent_velocity.dot(tangent)
		_velocity[i] = tangent * maxf(profile.creep_speed * _creep_speed_mult[i], along * profile.slope_slide_friction)
	else:
		_velocity[i] = tangent_velocity * profile.slope_slide_friction

	# Deliberately not resolved further within this same frame (no "slide the remaining distance
	# budget," the way move_and_slide() would) — leftover velocity carries into next frame's raycast.

func get_active_count() -> int:
	return _active_count

func spawn_particle(pos: Vector2, vel: Vector2, liquid_type: int = LiquidConstants.LiquidType.WATER) -> int:
	# Adds one particle at the next free dense slot. Returns its index (for a caller that wants to
	# keep touching it the same frame — e.g. spawn_melt_particles() spawning
	# several at once), or -1 if the pool is already full. Returning -1 rather than pushing a warning
	# is deliberate: a full pool silently dropping a spawn is the accepted failure mode per the
	# "Particle budget" decision, not an error condition worth flagging every frame under sustained
	# heavy load. `liquid_type` defaults to WATER so every pre-existing caller (faucet.gd) keeps
	# working unchanged.
	if _active_count >= MAX_PARTICLES:
		return -1
	var index := _active_count
	_position[index] = pos
	_velocity[index] = vel
	_age[index] = 0.0
	_creep_dir[index] = 0
	_creep_reversals[index] = 0
	_resting_body[index] = null
	_liquid_type[index] = liquid_type
	_visual_scale[index] = randf_range(PARTICLE_SCALE_JITTER_MIN, PARTICLE_SCALE_JITTER_MAX)
	_creep_speed_mult[index] = 1.0 + randf_range(-CREEP_SPEED_JITTER, CREEP_SPEED_JITTER)
	_gravity_mult[index] = 1.0 + randf_range(-GRAVITY_JITTER, GRAVITY_JITTER)
	_multimesh.set_instance_color(index, _jittered_color(liquid_type))
	_active_count += 1
	return index

func spawn_melt_particles(tile_pos: Vector2i, liquid_type: int = LiquidConstants.LiquidType.WATER, world_center: Vector2 = Vector2.INF, cell_rotation: float = 0.0) -> void:
	# Whole-tile burst spawn (roadmap 6.1b) for the not-yet-built laser/ice/metal chain: one melting
	# tile becomes LiquidConstants.PARTICLES_PER_TILE particles at once, via PARTICLES_PER_TILE calls
	# to the same spawn_particle() primitive above — a different SHAPE of spawn than 6.1a's metered
	# faucet drip, not a variant of it, so it deliberately doesn't reuse FAUCET_DRIP_INTERVAL/
	# FAUCET_JITTER_SPEED at all. `liquid_type` defaults to WATER (ice→water, the original caller);
	# the same primitive now also serves metal→slag by passing LiquidConstants.LiquidType.SLAG —
	# nothing else about the burst shape differs between the two.
	#
	# `world_center` / `cell_rotation` (rotating-bodies roadmap 2.3, optional): where the cell really is, and how the
	# block that is melting is turned. A block resting off the tile grid (on a see-saw, a moving platform) has cells
	# up to half a tile from the snapped cell centre `tile_pos` gives, and a spread over the snapped, axis-aligned
	# tile can put particles inside the solid under the block, where a raycast starting inside a shape doesn't hit
	# it and they fall straight through. With a finite `world_center` the burst spawns there instead, spread over the
	# cell in the block's own rotated frame and shrunk a little (SPAWN_INSET), so every particle starts inside the
	# block's volume — above whatever it rests on. Without it (nothing else calls this yet) the old snapped,
	# axis-aligned spread is unchanged.
	#
	# No-op (with a warning) if `_world_tilemap` never resolved — matches spawn_particle()'s own
	# silent-drop-on-full-pool posture: a bad call here shouldn't crash whatever's driving the melt.
	if _world_tilemap == null:
		push_warning("WaterManager: spawn_melt_particles() called with no world_tilemap registered")
		return

	# map_to_local() returns the CELL'S CENTER in the tilemap's local space (Godot 4 TileMapLayer
	# convention) — exactly the point _position's own "particle position is its center" convention
	# wants as a spawn origin, so no extra offset math is needed to land particles inside the tile.
	var tile_center := _world_tilemap.to_global(_world_tilemap.map_to_local(tile_pos))
		# Converts through `_world_tilemap`'s OWN transform, not this manager's — WaterManager and the
		# tilemap are siblings, not parent/child, so `self.to_global()` here would silently be wrong
		# the moment the two nodes' transforms ever differ (mirrors the existing convention
		# `_try_absorb()` already uses in reverse: `_world_tilemap.local_to_map(_world_tilemap.to_local(pos))`).
	var tile_size := Vector2(_world_tilemap.tile_set.tile_size) if _world_tilemap.tile_set else Vector2(16, 16)

	# Spread spawn POSITIONS across the tile's own footprint (half-extent jitter, clamped to the tile
	# itself) rather than dropping every particle from this burst on the exact same point — with no
	# particle-vs-particle collision (see "Particles are data, not nodes"), stacking them all at one
	# spot would read as a single fat particle for the first several frames instead of a burst. This is
	# a local spread computed from the tile's own size, not a new named LiquidConstants entry — per the
	# roadmap's own note that this API "doesn't reuse FAUCET_JITTER_SPEED at all."
	var exact := world_center.is_finite()
	if exact:
		tile_center = world_center
	for i in LiquidConstants.PARTICLES_PER_TILE:
		var offset := Vector2(
			randf_range(-tile_size.x, tile_size.x) * 0.5,
			randf_range(-tile_size.y, tile_size.y) * 0.5
		)
		if exact:
			offset = (offset * SPAWN_INSET).rotated(cell_rotation)
		spawn_particle(tile_center + offset, Vector2.ZERO, liquid_type)
			# Zero initial velocity, same as every other particle in this system at spawn — gravity
			# (Phase 3.1) does the rest starting next physics frame.

const SPAWN_INSET := 0.85
	# How far a melt burst's spread is shrunk toward the cell's centre when the caller gives the cell's exact
	# position and rotation (see spawn_melt_particles()), so particles start clear of the block's edges.

const STEAM_PUFFS_PER_TILE_VOLUME := 16.0
	# Steam particles per tile of volume that reacted: at the 16-per-tile preset one arriving particle makes one
	# puff, so a stronger faucet (more particles a second) makes a denser column. Counts are rounded at random,
	# so a finer preset keeps the same density in total. Untuned placeholder.
const STEAM_CONE_DEGREES := 6.0
	# Half-angle of the upward cone a puff leaves in: narrow, so a column is a column (10 px of spread at 100 px).
const STEAM_SPEED_JITTER := 0.1
	# +/- fraction of STEAM_RISE_SPEED per particle, so the top of a column is ragged rather than a clean edge.
const STEAM_POOL_RESERVE := 256
	# Steam is only emitted while at least this many pool slots are free, so a dense column can never starve
	# the liquid of particles (a full pool drops spawns silently). Steam can therefore fill the pool to
	# MAX_PARTICLES - this and no further.

## The one entry point for steam: `amount` is the volume (in tiles) that reacted at `world_pos`, which is
## where the column starts (callers keep it clear of the solid it rises from: see _steam_origin()). The crust
## reaction and laser boiling (boil_along_beam()) call it. Each puff rises at STEAM_RISE_SPEED inside a
## +/- STEAM_CONE_DEGREES cone about straight up.
func emit_steam(world_pos: Vector2, amount: float) -> void:
	var wanted := amount * STEAM_PUFFS_PER_TILE_VOLUME
	var count := int(floor(wanted))
	if randf() < wanted - float(count):
		count += 1
	for _n in count:
		if _active_count >= MAX_PARTICLES - STEAM_POOL_RESERVE:
			return
		var angle := deg_to_rad(randf_range(-STEAM_CONE_DEGREES, STEAM_CONE_DEGREES))
		var speed := LiquidConstants.STEAM_RISE_SPEED * (1.0 + randf_range(-STEAM_SPEED_JITTER, STEAM_SPEED_JITTER))
		spawn_particle(world_pos, Vector2.UP.rotated(angle) * speed, LiquidConstants.LiquidType.STEAM)

# --- laser boiling (roadmap 5.4) ---------------------------------------------------------------------

## Steam a boiled basin emits, in volume (tiles) per second of beam contact; emit_steam() turns it into puffs. Not
## scaled by the basin's boil_volume_scale. Untuned placeholder, like the rest of the steam constants.
const BOIL_STEAM_VOLUME_PER_SEC := 1.0
## Nominal drain of a boiled basin (WaterBasin.fill_volume units per second); the basin's boil_volume_scale multiplies it.
## Faucet flow_rate is in the same units (default 10), so a faucet below this rate cannot keep a boiled pool up.
const BOIL_DRAIN_VOLUME_PER_SEC := 1.0
## How far (px) along the beam the crossing is nudged so the steam starts inside the liquid's columns, not on a wall edge.
const BOIL_ENTRY_NUDGE := 1.0

## The turret's call. `points` is the beam polyline (world space, LaserBeam.Result.points). Every basin that is
## `boilable`, currently holds WATER and has liquid its beam crosses boils for `delta` seconds: it emits steam at the
## crossing (the first point the beam enters the liquid, over the liquid's own surface) and loses
## BOIL_DRAIN_VOLUME_PER_SEC * boil_volume_scale * delta of volume (through remove_volume(), never an export). Slag is
## skipped, and so is liquid sealed under a crust it touches (no void to rise into; the crust also stops the beam).
## Returns how many basins boiled.
func boil_along_beam(points: PackedVector2Array, delta: float) -> int:
	if points.size() < 2 or delta <= 0.0:
		return 0
	var boiled := 0
	var half_particle := LiquidConstants.PARTICLE_PIXEL_SIZE * 0.5
	for basin in _basins:
		if not is_instance_valid(basin) or not basin.boilable:
			continue
		if basin.liquid_type != LiquidConstants.LiquidType.WATER or basin.fill_volume <= 0.0:
			continue
		if basin.has_crust and basin.liquid_touches_crust():
			continue
		var crossing := _beam_liquid_crossing(points, basin.get_body_polygon_world())
		if crossing.is_empty():
			continue
		var origin := Vector2(crossing[0].x, basin.get_liquid_surface_world_y() - half_particle)
		emit_steam(origin, BOIL_STEAM_VOLUME_PER_SEC * delta)
		if basin.boil_volume_scale > 0.0:
			basin.remove_volume(BOIL_DRAIN_VOLUME_PER_SEC * basin.boil_volume_scale * delta)
		boiled += 1
	return boiled

# --- freeze ray (roadmap N3.2) ---------------------------------------------------------------------

## The freeze turret's call. `points` is the beam polyline (world space, LaserBeam.Result.points). Every basin that is
## `freezable` (WaterBasin.can_freeze(): opted in, holds liquid, no crust) and has liquid the beam crosses gains `delta`
## seconds of frost (WaterBasin.add_frost()), and freezes when it has `freeze_time` of it. Liquid is not a collider, so the
## beam passes through it as it does for boiling. Returns how many basins the beam is on.
func freeze_along_beam(points: PackedVector2Array, delta: float) -> int:
	if points.size() < 2 or delta <= 0.0:
		return 0
	var touched := 0
	for basin in _basins:
		if not is_instance_valid(basin) or not basin.can_freeze():
			continue
		if _beam_liquid_crossing(points, basin.get_body_polygon_world()).is_empty():
			continue
		basin.add_frost(delta)
		touched += 1
	return touched

## The first point along `points` that is inside one of `polygons`, nudged BOIL_ENTRY_NUDGE px further along the beam;
## empty when the beam never touches them. A beam that starts inside counts from its first point.
func _beam_liquid_crossing(points: PackedVector2Array, polygons: Array[PackedVector2Array]) -> PackedVector2Array:
	for s in points.size() - 1:
		var a := points[s]
		var b := points[s + 1]
		var dir := (b - a).normalized()
		if s == 0:
			for poly in polygons:
				if Geometry2D.is_point_in_polygon(a, poly):
					return PackedVector2Array([a + dir * BOIL_ENTRY_NUDGE])
		var best_dist := INF
		var best := Vector2.ZERO
		for poly in polygons:
			for j in poly.size():
				var hit: Variant = Geometry2D.segment_intersects_segment(a, b, poly[j], poly[(j + 1) % poly.size()])
				if hit == null:
					continue
				var hit_point: Vector2 = hit
				if a.distance_to(hit_point) < best_dist:
					best_dist = a.distance_to(hit_point)
					best = hit_point
		if best_dist < INF:
			return PackedVector2Array([best + dir * BOIL_ENTRY_NUDGE])
	return PackedVector2Array()

## Where a reacting particle's steam starts: its own x, and no lower than half a particle above the basin's outer
## surface (the crust's top face), since the particle's centre may have sunk a few px into it on the frame it
## reacted, and a puff that starts inside a solid would have its first ray ignore that solid.
func _steam_origin(i: int, basin: WaterBasin, half_particle: float) -> Vector2:
	return Vector2(_position[i].x, minf(_position[i].y, basin.get_surface_world_y() - half_particle))

func despawn_particle(index: int) -> void:
	# Swap-and-shrink removal: whatever was in the last active slot moves into the removed slot's
	# place, then the active count shrinks by one — keeps [0, _active_count) gap-free while only ever
	# touching one other particle's data, regardless of pool size. Order among active particles is NOT
	# preserved by this — nothing in the design depends on particle order, only on dense packing.
	# Color moves along with position/velocity via the multimesh's own get/set, for the same reason.
	if index < 0 or index >= _active_count:
		return
	var last := _active_count - 1
	_position[index] = _position[last]
	_velocity[index] = _velocity[last]
	_age[index] = _age[last]
	_creep_dir[index] = _creep_dir[last]
	_creep_reversals[index] = _creep_reversals[last]
	_resting_body[index] = _resting_body[last]
	_liquid_type[index] = _liquid_type[last]
	_visual_scale[index] = _visual_scale[last]
	_creep_speed_mult[index] = _creep_speed_mult[last]
	_gravity_mult[index] = _gravity_mult[last]
	_multimesh.set_instance_color(index, _multimesh.get_instance_color(last))
	_active_count = last

func _jittered_color(liquid_type: int) -> Color:
	var hsv_offset := randf_range(-PARTICLE_COLOR_JITTER, PARTICLE_COLOR_JITTER)
	var jittered: Color = LiquidConstants.profile(liquid_type).color_base
	jittered.v = clampf(jittered.v + hsv_offset, 0.0, 1.0)
	return jittered
