@tool
class_name MeltableBlock
extends RigidBody2D
## Base class for IceBlock and MetalBlock: a solid, heat-sensitive, kickable block that falls under gravity,
## floats or sinks in liquid, and bursts into liquid particles when it has melted. Subclasses supply what
## differs: how liquid acts on them (_apply_forces), what counts as touching slag (_touching_slag), what
## they melt into and how they sound and look (the small virtuals at the bottom).
##
## Body setup: a RigidBody2D on layers 1|2 / mask 1|2, rotation free (see `allow_rotation`). Layer 1 is what KickHitbox's default mask can see; layer 2 keeps it solid like ground. Sized in
## 16px tiles via `size_tiles`. Joins "water_solid" (water rests on and rides it while it's intact; the
## manager tolerates a freed registered solid) and "ground" (what makes its top edge ledge-hangable, same
## mechanism as moving_platform.gd). `_configure_body()` sets the engine side: gravity_scale 0 (gravity is
## integrated by hand, below), engine damping replaced with 0, no sleeping, a frictionless physics material,
## contact reporting on (the contact scan needs it).
##
## Motion model. The engine solves contacts; everything else is hand-written, so the tuned constants keep
## their meaning. `velocity` is a scratch copy that only exists inside _physics_process(): it starts as
## (own horizontal motion, vertical velocity), the subclass hook and floor friction edit it, and the result
## is written to linear_velocity as own motion + carry.
##   - Own motion (`_own_vx`): a kick and its decay, liquid drag, the underside push. Floor friction
##     (`slide_friction`) decays it while resting on a floor.
##   - Carry: the speed of the conveyor belt it rests on (any body with get_conveyor_speed(), the duck-typed
##     contract the player reads) plus the horizontal velocity of the world body under it (a moving platform,
##     another block). Added to the written velocity every frame but never stored in `_own_vx`, so own motion
##     never inherits it and slide friction never fights it. The block's physics material has friction 0, so
##     the engine contributes no carry or braking of its own. `carry_assist = false` turns the platform part off.
##   - Vertical: gravity or buoyancy through the hook; while resting on a floor a downward velocity is zeroed.
## _integrate_forces() runs first each tick (before every _physics_process()) and reads what the solver did
## to the written velocity: a wall or another body stopping it shows up as a change in horizontal velocity and
## is accepted into `_own_vx`. Contacts are the previous step's, so floor/wall/belt state lags by one tick.
##
## Heat: on_laser_hit() only stamps the physics frame (order-independent with the turret; a hit within
## LIT_GRACE_FRAMES counts as lit). Lit, `melt_progress` rises over `melt_time`; touching slag, over
## `slag_melt_time`; the faster wins. With neither, it drains at `cool_rate`. At 1.0 it melts (see _melt()).
##
## Kick: kicked(direction) is the optional contract player.gd calls alongside take_damage(). It sets
## own horizontal motion to `shunt_speed` away from the kicker; while on the floor that decays at
## `slide_friction`. It can slide off ledges and stops against walls and other bodies (a block it hits is
## pushed by the contact, heavier ones less). shunt_speed <= 0 makes a block unkickable.
##
## Launch: launch(vector) is the duck-typed contract a jump pad calls (the same one the player implements). The vector is
## scaled by `mass ^ -launch_weight_exponent` (a 1x1 ice block takes it whole, a 1x1 metal block about a quarter) and
## buffered, then applied in _physics_process() after everything else has edited `velocity` and just before it is
## written to linear_velocity, so it wins over gravity, floor friction and the held-block vertical zero.
##
## Material flags (exports, set per scene): `brittle` (ice, carbon fiber) means a bullet or a crusher's spike breaks the block
## (_break_apart(): ice bursts through its melt path, carbon fiber dissolves); `absorbs_bullets` (metal) means a bullet is
## consumed with a ping and the block is unharmed. Both are read by on_bullet_hit(), the optional contract bullet.gd calls;
## shatter() reads `brittle` through _shatters_when_crushed().
##
## Walk push: walk_shoved(direction, walk_speed) -> float is the optional contract the player calls while walking into the
## block's side. A block with `walk_push_speed` 0 (ice, metal) returns -1 and refuses, so actors still never move it by walking;
## a block with a speed takes own motion of at most that, and a chain of such blocks moves together, slower per block
## (`chain_push_slowdown`), refusing if anything else (a tile, any other body, a block that refuses) is in front. A walk-pushed block
## coasts only while its floor is slippery (is_slippery()): on any other floor it stops once the push ends.
##
## Jam: jams_crusher() -> bool is the duck-typed contract the Crusher sweeps its stroke for (metal: true, so it stalls the
## piston and latches the crusher jammed; ice and the base class: false).
##
## Shatter: shatter() is the duck-typed contract the Crusher's spike calls on a block it touches. A block whose
## _shatters_when_crushed() is true (`brittle`) goes through _melt() at once, the same path as a full melt (its melt sound,
## its liquid burst, freeing itself), not a separate delete; any other block ignores it.
##
## Surf shove: surf_shoved(direction, surf_speed) -> float is the optional surf contract player.gd's bowl sweep reads
## (the surf as a long-range kick). A fast surfer gives the block own motion of `surf_speed * surf_shove_transfer /
## sqrt(mass)`, never below `shunt_speed` and capped at `surf_shove_max_speed`, and the shove costs the surfer
## `speed * mass / (mass + SURF_SHOVE_PLAYER_WEIGHT)` of that. It returns -1 to refuse (unkickable, or blocked by a wall or
## body on the side the surfer is pushing from), and then the block stays a wall to the surf. The player holds a
## collision exception with a shoved block until it has passed through (a block can't get out of the way in one frame).
##
## Rotation: `allow_rotation` (default true) leaves the body free to rotate; a block that must never turn
## (a fixed-orientation puzzle piece) sets it false and is locked upright. Rotation is hand-integrated in _integrate_forces() like everything else: the
## solver's angular change (a corner landing, a ledge overhang) is accepted, then a soft righting torque toward
## the nearest 90 degrees and angular drag (stronger while in liquid) are applied, so a block topples when its
## support goes but settles flat, upright or on its side. Gravity acts at the centre of mass, which is lowered
## (`com_drop`) so a block resists tipping. While rotation is allowed the grounded vertical-velocity zero is
## skipped: a block perched on an edge needs its downward velocity pressing on the contact for the solver to
## produce the torque that topples it. Band queries (riders, underside push) treat the block as the upright
## rectangle nearest its angle (width and height swap on its side) and follow the residual tilt.
##
## Liquid with rotation (stage 2b): the submerged fraction is the area of the block's rotated rectangle below the
## flat liquid surface of the basin at its centre column (polygon clip), not a bottom-edge depth, so it is exact
## at any angle (and identical to the old depth ratio when upright). The centroid of the submerged area is the
## centre of buoyancy; the upward buoyant acceleration acts there while gravity acts at the centre of mass, and
## the couple between them is applied as angular acceleration (`_buoyancy_alpha`, per unit mass, moment of
## inertia of a uniform rectangle). A tilted block therefore has its low side lifted, and a lowered centre of mass
## adds to that. Slag contact for ice is tested at the rotated corners and bottom midpoint, each against the
## basin in its own column.
##
## Hanging (stage 3): the player hangs from a block's ledge by pinning its hand to a point in world space and
## carrying that point with the block (the player's _follow_hang_platform(), now with the block's full transform,
## so a gentle tilt swings the hang with it). `is_hangable()` is the block's say in it: a rotation-allowed block
## can be grabbed, and stays held, only while within `hang_max_tilt_degrees` of resting flat, no faster than
## `hang_max_speed`, and spinning no faster than `hang_max_spin`; the player is released the moment it isn't.
## A hanging player is not a rider (no weight, no tipping torque, no sinking), see _actors_in_band().
##
## Weight: the engine's `mass` is the block's weight, set per 16px tile in the scene (metal 4, ice 1) and scaled by
## area in _configure_body(). It sets how contacts trade momentum between blocks and is what a rotating body
## (see-saw) reads as a block's load; it plays no part in gravity or buoyancy, which are hand-integrated per unit
## mass.
##
## Contact finish (stage 2d): the collider is an octagon (`chamfer_px`) so sliding doesn't snag on tile seams.
## Static friction is `_is_held()` (see it): `hold_slope_degrees` (ice low, metal high) decides the steepest slope
## an idle block stays on; the old unconditional grounded vertical zero is now this. Carry stays an assist
## (`carry_assist`): the block's friction is 0, so a moving platform or belt moves it by decision, not by grip.
##
## Rider weight (stage 2c): each actor on the top face is a downward force at its feet (only its x matters), so
## standing off-centre applies a torque about the centre of mass, `lever_x * weight / gyration^2`, per unit mass,
## alongside the unchanged vertical carrying-capacity model (`rider_load_tiles`). The weight of one rider is
## `GRAVITY * rider_load_tiles / area / rest_fraction`, the same units as the buoyancy couple, so a floating
## block with a rider settles with its centre of buoyancy under the rider's feet and lists to that side; on land
## the torque presses against the support, which is what lets a rider tip a block off a ledge. The side-contact
## test for actors is made in the block's upright frame, so a rider standing on a tilted top face does not read
## as someone pushing its side. The shove guard's angular half only discards spin that increases the block's
## angular speed beyond what was written, never the solver cancelling it (a floor holding up a loaded block).
##
## Actors can never shove it. Player and enemies are kinematic bodies, and a kinematic body walking into a
## rigid one hands it velocity through the contact solver. The shove guard in _integrate_forces() undoes
## that: when an actor touches a side face and the block has gained horizontal speed away from the actor
## beyond what was written, the excess speed and the displacement it caused are removed (with rotation allowed,
## likewise any angular speed gained while an actor touches it). Walking into a
## block, or a block sliding into an actor, therefore just stops it. It only moves under its own motion: a
## kick, its own friction, buoyancy. `reject_actor_shove = false` turns the guard off (for A/B checks).
##
## Riders (actors standing on it) change buoyancy through the rider count only; their weight is not applied
## as a force yet. A player standing on a block rises with it through the player's ordinary moving-floor
## carry. There is no mask trick for a rising block any more: whether the player's feet stall the block is
## a roadmap check.
##
## Hang/mantle exception: while the player is hanging from the block (ledge grab through the end of the
## mantle), the block and player hold a mutual collision exception, dropped the frame the hang ends. The
## mantle tween carries the player's collider through the block's top corner; without the exception the
## contact between them pushes the block (and the hang follow drags the mantle target with it), so the push
## can feed itself. Any other actor-driven teleport onto a block needs the same treatment.
##
## Expected scene layout:
##   <Block> (RigidBody2D, a subclass script, layer 1|2 / mask 1|2)
##     - CollisionShape2D   (RectangleShape2D; resized from size_tiles, copied per instance at runtime)
##
## Placeholder art is drawn in code by the subclass's _draw_block() until sprites exist
## (draw_placeholder = false hides it).

const TILE := 16.0
const MIRROR_EDGE_FRACTION := 0.25 ## Fraction of a tile's art kept only at the block's outer edges; the middle band between is what gets mirrored (see _draw_art()).
const GRAVITY := 900.0
const MAX_FALL_SPEED := 400.0
const LIT_GRACE_FRAMES := 2 ## A hit stays "current" this many physics frames.
const SPLASH_MIN_SPEED := 60.0 ## px/s downward on first touching a liquid before it splashes.
const SPLASH_RIPPLE_IMPULSE := 0.12 ## Cosmetic: px/s of downward surface kick per px/s of impact speed, per tile of block width.
const MAX_CONTACTS := 8 ## Contacts reported to _integrate_forces().
const FLOOR_NORMAL_Y := 0.7 ## |normal.y| above this (about 45 degrees) is floor/ceiling; below it a side.
const WALL_NORMAL_X := 0.7 ## |normal.x| above this is a wall.
const ACTOR_SIDE_NORMAL_X := 0.1 ## |normal.x| above this on an actor contact counts as touching its side.
const SHOVE_EPSILON := 0.01 ## px/s of unexplained speed gained away from an actor before the guard acts.
const SUPPORT_TOLERANCE := 2.0 ## px: a floor contact this close to the centre of mass's x still counts as supporting it.
const RIDER_SUPPORT_TOLERANCE := 0.5 ## px: slack when deciding the block plus riders balance over the floor contacts (small, so a heavy edge rider still tips it).
const SUPPORT_LATCH_FRAMES := 12 ## physics frames a body floor (plank, block) keeps counting as supporting the centre of mass after the contact report loses its second corner.
const SURF_SHOVE_PLAYER_WEIGHT := 2.0 ## The surfer's weight against the block's mass when working out what a shove costs it (mirrors RotatingBody.player_weight).
const DISSOLVE_TIME := 0.2 ## seconds a dissolving block (see dissolve()) takes to fade out.
const CRUST_LIFT_MARGIN := 0.1 ## px: how far clear of a new crust's collision top a lifted block is set, so it doesn't start in contact.
const HOLD_TILT_MARGIN := 0.08 ## rad: a rotating block may lean this much more than the surface under it and still be held.

@export var size_tiles: Vector2i = Vector2i(1, 1):
	set(value):
		size_tiles = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		_sync_shape()
		queue_redraw()
@export_range(0.0, 4.0, 0.25) var chamfer_px: float = 1.0:  ## Corner bevel on the collider (an octagon), so a sliding block doesn't snag on tile seams. 0 = plain rectangle.
	set(value):
		chamfer_px = value
		_sync_shape()
@export var mirror_tiling: bool = true: ## Art only: blocks bigger than one tile ping-pong the middle of the tile art so the block reads as one piece (see _draw_art()). Off = the same tile repeated per cell.
	set(value):
		mirror_tiling = value
		queue_redraw()
@export var melt_time: float = 2.0 ## Seconds of beam contact to melt fully.
@export var slag_melt_time: float = 0.0 ## Seconds to melt fully while touching molten slag.
@export var cool_rate: float = 0.5 ## Progress lost per second while neither lit nor touching slag.
@export var shunt_speed: float = 100.0 ## px/s a kick sends the block sliding at (0 = can't be kicked).
@export var slide_friction: float = 70.0 ## px/s^2 the slide decays by while on the floor.
@export_group("Material")
@export var brittle: bool = false ## A bullet breaks it and a crusher's spike shatters it (see _break_apart()). Ice and carbon fiber set it in their scenes.
@export var absorbs_bullets: bool = false ## A bullet is consumed on contact with a ping and the block is unharmed (metal sets it in its scene).
@export_group("Walk push")
@export var walk_push_speed: float = 0.0 ## px/s cap on the speed a walking player can push this block at (0 = can't be pushed by walking: the default for ice and metal).
@export_range(0.1, 1.0) var chain_push_slowdown: float = 0.75 ## Speed multiplier for each further walk-pushable block ahead of this one in a pushed chain.
@export_group("Launch")
@export_range(0.0, 2.0, 0.05) var launch_weight_exponent: float = 1.0 ## A jump pad's launch vector is divided by mass^this: 0 = weight ignored, 1 = inversely proportional (a 1x1 metal block, mass 4, gets a quarter of the speed and about a 16th of the height), 2 = steeper still. Mass is per 16px tile times the block's area, so a bigger block lifts less. An unkickable block (shunt_speed <= 0) is launched all the same.
@export_group("Surf")
@export_range(0.0, 1.0, 0.05) var surf_shove_transfer: float = 0.5 ## Fraction of a surfer's speed the block takes as its own motion (divided by sqrt(mass), so a heavy block takes less). 0 still gives it the kick speed.
@export var surf_shove_max_speed: float = 200.0 ## px/s cap on the motion a shove gives (on ice 200 slides about 18 tiles at slide_friction 70).
@export_group("")
@export_range(0.0, 45.0) var hold_slope_degrees: float = 30.0 ## Steepest floor slope an idle block stays put on (its static friction: tan(angle) is the coefficient). Steeper than this it slides down under gravity. Ice sets a low value in its scene.
@export_group("Buoyancy")
@export var buoyant: bool = true
@export_range(0.05, 1.0) var float_depth_fraction: float = 0.8 ## Fraction of the block below the waterline when floating at rest. Also sets the carrying capacity: riders add rider_load_tiles / area to it, and the block sinks once the sum reaches 1.0.
@export var rider_load_tiles: float = 0.15 ## Weight of one actor standing on the block, in tiles of block area (a 1x1 block: +15% submersion; a 2x2: +3.75%). With rotation allowed it also sets how hard an off-centre rider tips the block.
@export_group("Contact")
@export var reject_actor_shove: bool = true ## Undo horizontal speed an actor's contact gives the block (see the header note). Off = A/B comparison only.
@export var carry_assist: bool = true ## Carry the block with the horizontal velocity of the world body under it (platforms, blocks). The block's friction is 0, so without this it would not ride a moving platform.
@export_group("Rotation")
@export var allow_rotation: bool = true ## Let the block rotate (topple, tip, settle on a side). Off = locked upright, for a block that must never turn.
@export_range(0.0, 1.0) var com_drop: float = 0.3 ## Centre of mass below the block's centre, as a fraction of half its height. More = harder to tip.
@export var righting_stiffness: float = 30.0 ## 1/s^2 pull toward the nearest 90 degrees (soft spring). 0 = none.
@export var angular_drag: float = 6.0 ## 1/s angular damping. About 2 * sqrt(righting_stiffness) settles without oscillating.
@export var angular_drag_liquid: float = 12.0 ## Extra 1/s of angular damping at full submersion, so floating blocks don't wobble.
@export_group("Hanging")
@export_range(0.0, 45.0) var hang_max_tilt_degrees: float = 10.0 ## A rotation-allowed block can be grabbed (and stays held) only within this tilt of resting flat (upright or on its side).
@export var hang_max_speed: float = 90.0 ## px/s: faster than this and the block can't be grabbed (a held hang is released).
@export var hang_max_spin: float = 1.2 ## rad/s: likewise for how fast the block is turning.
@export_group("")
@export var draw_placeholder: bool = true
@export var debug_hold: bool = false ## Prints floor/hold state ~6x a second while resting on a floor (for diagnosing a block that slides too early).

var melt_progress: float = 0.0 ## 0..1
var spawner_owned: bool = false ## Set by a BlockDispenser before add_child(): the block then does not join "saveable", because the dispenser saves and re-creates it (see BlockDispenser). Runtime state, never authored.
## Scratch working copy of (own horizontal motion, vertical velocity), valid only inside _physics_process()
## and the subclass hooks it calls. The real velocity is linear_velocity.
var velocity: Vector2 = Vector2.ZERO
var _last_lit_frame: int = -1000
var _melted: bool = false
var _water_manager: WaterManager
var _was_submerged: bool = false
var _rider_query: PhysicsShapeQueryParameters2D
var _player: PhysicsBody2D
var _ignoring_hanger: bool = false ## true while the collision exception with the hanging player is active

var _own_vx: float = 0.0 ## the block's own horizontal motion, without carry
var _written_vx: float = 0.0 ## linear_velocity.x as last written by _physics_process(); the solver's change is measured against it
var _carry_written: float = 0.0 ## carry included in _written_vx
var _vy: float = 0.0 ## vertical velocity as of the last _integrate_forces()
var _on_floor: bool = false ## contact flags from the previous step, set by _scan_contacts()
var _hit_wall: bool = false
var _wall_side: int = 0 ## -1/+1: the wall (tile or solid body) that set _hit_wall is on the block's left/right; 0 none
var _actor_side: int = 0 ## -1/+1: an actor touches the block's left/right face; 0 none
var _floor_av: float = 0.0 ## rad/s: angular velocity of the flattest floor contact's body (a rotating plank, a turning block); 0 for tiles
var _floor_is_body: bool = false ## the flattest floor contact is a body (plank, block), not a tile
var _support_latch: int = 0 ## frames left of the support latch (see SUPPORT_LATCH_FRAMES)
var _floor_tilt: float = 0.0 ## rad: tilt of the flattest floor contact when that floor is a body, not a tile (a plank, another block); 0 for tiles. The righting spring settles toward this, so a block on a tilting plank lies flat on it instead of fighting it.
var _floor_v: Vector2 = Vector2.ZERO ## velocity of the world body under the block at its contact (both axes: a tilting plank moves the surface vertically too)
var _belt_speed: float = 0.0 ## speed of the conveyor under the block
var _rider_count: int = 0
var _written_vy: float = 0.0 ## velocity.y as last written by _physics_process(); a rider's reaction on a rising block is measured against it
var _rider_on_top: bool = false ## an actor touches the block's top face (previous step)
var _roof_hit: bool = false ## a non-actor body touches the block's top face (a ceiling over the block)
var _riders_free_above: bool = true ## every rider has room to be carried up this tick (no ceiling over it)
var _front_query: PhysicsShapeQueryParameters2D ## reused by _bodies_in_front()
var _floor_slippery: bool = false ## the floor under the block answers is_slippery() true (a frozen crust, an ice block), from the last contact scan
var _walk_pushed: bool = false ## a walking player moved the block and the push may not have ended; see _end_walk_push()
var _last_walk_push_frame: int = -1000
var _launch_pending: bool = false ## launch() buffered a vector; applied (once) in _physics_process()
var _launch_vector: Vector2 = Vector2.ZERO ## the buffered launch, already scaled by weight
var _pending_teleport: bool = false ## load_state() asked for a position; applied inside _integrate_forces()
var _pending_pos: Vector2 = Vector2.ZERO
var _pending_angle: float = 0.0
var _pending_av: float = 0.0
var _floor_slope: float = INF ## rad: flattest tile/body floor contact under the block this tick (INF = none)
var _support_min_x: float = INF ## world x range of those floor contacts, to tell whether they hold the centre of mass up
var _support_max_x: float = -INF
var _written_av: float = 0.0 ## angular velocity as last written by _integrate_forces(); the solver's change is measured against it
var _liquid_fraction: float = 0.0 ## 0..1 submerged in any liquid, from the last physics tick (angular drag only)
var _rider_alpha: float = 0.0 ## rad/s^2 from riders' weight off the centre of mass (rotation allowed), set each physics tick, applied in _integrate_rotation()
var _buoyancy_alpha: float = 0.0 ## rad/s^2 from the buoyancy couple, summed by _buoyant_accel() this tick, applied in _integrate_rotation()
var _cob_world: Dictionary = {} ## liquid type -> world centroid (Vector2) of the submerged area, or null when none; set by _submerged_fraction()

func _ready() -> void:
	if not Engine.is_editor_hint():
		_own_shape()
	_sync_shape()
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"water_solid")
	add_to_group(&"ground")  # what makes the top edge hangable — see the header note
	if not spawner_owned:
		add_to_group(&"saveable")
	_configure_body()
	_water_manager = get_tree().get_first_node_in_group(&"water_manager") as WaterManager

## Engine-side setup, in code so every subclass scene gets it from the one place.
func _configure_body() -> void:
	gravity_scale = 0.0  # gravity and buoyancy are integrated by hand in _physics_process()
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	can_sleep = false  # a sleeping body stops running buoyancy and wouldn't notice a basin filling under it
	mass *= size_tiles.x * size_tiles.y  # the scene's `mass` is per 16px tile (metal 4, ice 1), so a bigger block weighs more
	lock_rotation = not allow_rotation
	if allow_rotation:
		center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = Vector2(0.0, size_tiles.y * TILE * 0.5 * com_drop)
	contact_monitor = true
	max_contacts_reported = MAX_CONTACTS
	if physics_material_override == null:
		var material := PhysicsMaterial.new()
		material.friction = 0.0  # sliding decay is slide_friction; the engine adds none
		material.bounce = 0.0
		physics_material_override = material

# --- contracts read by other nodes -----------------------------------------------------------------

## Saveable contract (see game.gd). A melted block frees itself, so it is absent from the snapshot and the fresh
## copy is freed on restore. Vertical velocity is not stored: gravity and buoyancy rebuild it, and restoring a
## fall speed could fire a false splash the frame the block is placed in liquid.
func save_state() -> Dictionary:
	var d := {"position": global_position, "velocity_x": _own_vx, "melt_progress": melt_progress}
	if allow_rotation:
		d["angle"] = rotation
		d["angular_velocity"] = angular_velocity
	return d

func load_state(d: Dictionary) -> void:
	var pos: Vector2 = d.get("position", global_position)
	global_position = pos
	_pending_pos = pos  # the physics server's copy is set inside _integrate_forces()
	_pending_angle = float(d.get("angle", 0.0)) if allow_rotation else 0.0
	_pending_av = float(d.get("angular_velocity", 0.0)) if allow_rotation else 0.0
	rotation = _pending_angle
	_pending_teleport = true
	_own_vx = d.get("velocity_x", 0.0)
	_written_vx = 0.0
	_carry_written = 0.0
	_vy = 0.0
	_written_vy = 0.0
	linear_velocity = Vector2.ZERO
	melt_progress = clampf(d.get("melt_progress", 0.0), 0.0, 1.0)
	_last_lit_frame = -1000
	_launch_pending = false
	_walk_pushed = false
	reset_physics_interpolation()
	queue_redraw()

## Crust contract (called by a WaterBasin the moment a crust forms, see WaterBasin._lift_blocks_onto_crust()): the new slab
## occupies the surface band where a floating block rides, so a block whose centre is in or above that band, and whose
## bounds overlap it over a crust column, is lifted straight up until its lowest point rests on the crust's collision top.
## Anything standing on it (`_actors_in_band()`, the player included) is lifted by the same amount. A block whose centre is
## already below the band, or one clear of it, is untouched. Applied as a teleport inside the next `_integrate_forces()`,
## like a restore, with its own horizontal motion kept. Returns how far it was lifted (0 = untouched).
func lift_clear_of_crust(basin: Node) -> float:
	if _melted or basin == null or not basin.has_method(&"get_crust_collision_top_world_y"):
		return 0.0
	var top: float = basin.get_crust_collision_top_world_y()
	var bottom: float = basin.get_crust_bottom_world_y()
	if global_position.y >= bottom:
		return 0.0
	var low := -INF
	var high := INF
	var left := INF
	var right := -INF
	for corner in _corners_world():
		low = maxf(low, corner.y)
		high = minf(high, corner.y)
		left = minf(left, corner.x)
		right = maxf(right, corner.x)
	if low <= top or high >= bottom:
		return 0.0  # wholly above the slab, or wholly below it
	if not basin.is_rect_over_crust(Rect2(left, high, right - left, low - high)):
		return 0.0
	var lift := low - top + CRUST_LIFT_MARGIN
	for rider in _actors_in_band(-1.0, 4.0):
		rider.global_position.y -= lift
	_pending_pos = global_position + Vector2(0.0, -lift)
	_pending_angle = rotation
	_pending_av = angular_velocity if allow_rotation else 0.0
	global_position = _pending_pos
	_pending_teleport = true
	_vy = 0.0
	_written_vy = 0.0
	linear_velocity.y = 0.0
	return lift

## Beam contract: anything with on_laser_hit(point, direction) is told it's being lit.
func on_laser_hit(_point: Vector2, _direction: Vector2) -> void:
	_last_lit_frame = Engine.get_physics_frames()

## Kick contract read by player.gd's _on_kick_hitbox_body_entered(): direction is -1.0 (left) / 1.0 (right).
func kicked(direction: float) -> void:
	if _melted or shunt_speed <= 0.0:
		return
	_own_vx = signf(direction) * shunt_speed
	_walk_pushed = false
	Audio.play_at(_shunt_sound(), global_position)

## Launch contract (jump_pad.gd calls launch(vector) on anything that has it): buffers the vector, scaled down by weight,
## rather than writing linear_velocity directly. A pad's Area2D signal can fire at any point in the physics step, and a
## direct write could land before _physics_process() rewrites linear_velocity from own motion and gravity, silently
## cancelling it; the buffered vector is applied once, after everything else that edits `velocity` that tick.
## The vector replaces the block's velocity outright, as the player's launch does. A melted block ignores it, and a
## later launch before the first is applied replaces it. Note that the hand-integrated gravity clamps vertical speed
## to +-MAX_FALL_SPEED on the tick after, so a straight-up launch is capped there.
func launch(vector: Vector2) -> void:
	if _melted:
		return
	_launch_vector = vector / pow(maxf(mass, 1.0), launch_weight_exponent)
	_launch_pending = true

## Shatter contract (crusher.gd calls shatter() on anything that has it): bursts the block through the ordinary melt
## path, so it releases the same liquid as melting does. Does nothing for a block that doesn't shatter, or one that has
## already melted (the crusher polls every frame and a melted block can still be listed as overlapping for a tick).
func shatter() -> void:
	if _melted or not _shatters_when_crushed():
		return
	_break_apart()

## Bullet contract (bullet.gd calls on_bullet_hit(point, direction) on any body it overlaps that has it; true = the bullet
## is consumed). `absorbs_bullets` first: consumed with a ping, the block unharmed. Then `brittle`: consumed and the block
## breaks. Anything else lets the bullet fly on, as before.
func on_bullet_hit(point: Vector2, _direction: Vector2) -> bool:
	if _melted:
		return false
	if absorbs_bullets:
		Audio.play_at(&"interactive/metal_ping", point)
		return true
	if brittle:
		_break_apart()
		return true
	return false

## Walk-push contract (player.gd calls walk_shoved(direction, walk_speed) while a standing, walking player presses into the
## block's side): returns the speed the block took (the player is slowed to it) or -1.0 to refuse. Refuses when
## `walk_push_speed` is 0, when melted, and when anything but another walk-pushable block is on the far face (found with
## a shape query, see _bodies_in_front()).
func walk_shoved(direction: float, walk_speed: float) -> float:
	var dir := signf(direction)
	if dir == 0.0:
		return -1.0
	var allowed := _walk_push_limit(dir, 0)
	if allowed <= 0.0:
		return -1.0
	var taken := minf(allowed, absf(walk_speed))
	_walk_push_apply(dir, taken, 0)
	return taken

const WALK_PUSH_MAX_CHAIN := 8 ## blocks: a longer chain refuses (also a guard against a loop of contacts)
const WALK_PUSH_GRACE_FRAMES := 2 ## physics frames without a push before it counts as ended
const WALK_PUSH_PROBE_DEPTH := 4.0 ## px: thickness of the band checked in front of a pushed block (1 px of it overlaps the block's own face)

## The speed this block, and the chain in front of it, can be pushed at, or -1.0 if it refuses.
func _walk_push_limit(dir: float, depth: int) -> float:
	if _melted or walk_push_speed <= 0.0 or depth >= WALK_PUSH_MAX_CHAIN:
		return -1.0
	var limit := walk_push_speed
	for body in _bodies_in_front(dir):
		if not (body is MeltableBlock):
			return -1.0  # a tile, an enemy or any other body in front: a wall
		var ahead: float = (body as MeltableBlock)._walk_push_limit(dir, depth + 1)
		if ahead <= 0.0:
			return -1.0
		limit = minf(limit, ahead * chain_push_slowdown)
	return limit

## Gives this block and every block in front of it the pushed speed.
func _walk_push_apply(dir: float, speed: float, depth: int) -> void:
	if signf(_own_vx) != dir or absf(_own_vx) < speed:
		if Engine.get_physics_frames() - _last_walk_push_frame > WALK_PUSH_GRACE_FRAMES:
			Audio.play_at(_walk_push_sound(), global_position)
		_own_vx = dir * speed
	_walk_pushed = true
	_last_walk_push_frame = Engine.get_physics_frames()
	if depth >= WALK_PUSH_MAX_CHAIN:
		return
	for body in _bodies_in_front(dir):
		if body is MeltableBlock:
			(body as MeltableBlock)._walk_push_apply(dir, speed, depth + 1)

## Bodies (layers 1|2, not this block) within a few px of the block's face on side `dir`, found by a thin shape query
## rather than the contact scan, because a block resting flush against another reports no contact. The band stops short
## of the corners and the bottom, so the floor and the chamfers are never in it.
func _bodies_in_front(dir: float) -> Array[Node]:
	if _front_query == null:
		_front_query = PhysicsShapeQueryParameters2D.new()
		_front_query.collision_mask = 3
		_front_query.shape = RectangleShape2D.new()
		_front_query.exclude = [get_rid()]
	var size := _upright_size()
	var residual := _upright_residual()
	(_front_query.shape as RectangleShape2D).size = Vector2(WALK_PUSH_PROBE_DEPTH, maxf(size.y - 4.0, 1.0))
	_front_query.transform = Transform2D(residual, global_position + Vector2(dir * (size.x * 0.5 + WALK_PUSH_PROBE_DEPTH * 0.5 - 1.0), 0.0).rotated(residual))
	var seen := {}
	var out: Array[Node] = []
	for hit in get_world_2d().direct_space_state.intersect_shape(_front_query, 8):
		var body := hit.collider as Node
		if body != null and not seen.has(body.get_instance_id()):
			seen[body.get_instance_id()] = true
			out.append(body)
	return out

## The push has ended (no walker pressing for WALK_PUSH_GRACE_FRAMES). On a floor that is not slippery the block stops
## with it; on a slippery floor, in the air or in liquid its own motion carries on and decays as usual.
func _end_walk_push() -> void:
	if not _walk_pushed or Engine.get_physics_frames() - _last_walk_push_frame <= WALK_PUSH_GRACE_FRAMES:
		return
	_walk_pushed = false
	if _on_floor and not _floor_slippery:
		velocity.x = 0.0

## Surf contract (optional, read by player.gd's bowl sweep): `direction` is the way the surfer travels (-1/+1). Gives
## the block its own motion that way and returns the surf speed the shove cost, or -1.0 to refuse (the block then
## stays solid and stops the surf like a wall): unkickable, melted, or already pressed against a wall or body on the
## far side. Contacts are the previous step's, so a block that has just reached a wall may be shoved once more.
func surf_shoved(direction: float, surf_speed: float) -> float:
	if _melted or shunt_speed <= 0.0 or direction == 0.0:
		return -1.0
	var dir := signf(direction)
	if _hit_wall and _wall_side == int(dir):
		return -1.0
	var given := surf_speed * surf_shove_transfer / sqrt(maxf(mass, 1.0))
	given = clampf(given, shunt_speed, maxf(surf_shove_max_speed, shunt_speed))
	if signf(_own_vx) == dir:
		given = maxf(given, absf(_own_vx))  # never slows a block that is already sliding the same way
	_own_vx = dir * given
	_walk_pushed = false
	Audio.play_at(_shunt_sound(), global_position)
	return clampf(given * mass / (mass + SURF_SHOVE_PLAYER_WEIGHT), 0.0, surf_speed)

# --- physics ---------------------------------------------------------------------------------------

## Runs at the start of each physics tick, before every _physics_process(). Reads the previous step's contacts,
## then accounts for what the solver did to the horizontal velocity written last tick.
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if Engine.is_editor_hint() or _melted:
		return
	var xf := state.transform
	if _pending_teleport:
		_pending_teleport = false
		xf = Transform2D(_pending_angle, _pending_pos)
		state.transform = xf
		state.linear_velocity = Vector2.ZERO
		state.angular_velocity = _pending_av
		_written_av = _pending_av
		_on_floor = false
		_hit_wall = false
		_wall_side = 0
		_actor_side = 0
		_rider_on_top = false
		_roof_hit = false
		_floor_v = Vector2.ZERO
		_floor_tilt = 0.0
		_floor_is_body = false
		_floor_av = 0.0
		_support_latch = 0
		_belt_speed = 0.0
		_floor_slope = INF
		_support_min_x = INF
		_support_max_x = -INF
		return

	_scan_contacts(state)
	var vel := state.linear_velocity
	if reject_actor_shove and _actor_side != 0:
		# Speed gained away from the actor beyond what was written (and beyond 0 when the block was moving
		# into the actor: the solver stopping it is legitimate, an actor pushing it away is not).
		var away := -float(_actor_side)
		var gained := vel.x * away - maxf(_written_vx * away, 0.0)
		if gained > SHOVE_EPSILON:
			xf.origin.x -= away * gained * state.step  # undo the displacement that speed caused
			state.transform = xf
			vel.x -= away * gained
	if reject_actor_shove and _rider_on_top and not _roof_hit and _riders_free_above and _written_vy < 0.0 and vel.y > _written_vy:
		# A rider can't hold back a rising block. The player follows a moving floor a tick late, so under any sustained
		# upward acceleration the block creeps into its safe margin and the solver cuts the block's rise by about half
		# every few ticks; the block then never catches a level rising faster than that. The rider is pushed up by
		# its own depenetration instead, like a kinematic platform's. Not applied under a ceiling (_riders_free_above),
		# where the contact is what stops the block.
		vel.y = _written_vy
	_own_vx += vel.x - _written_vx  # a wall or body stopping the block lands here
	if _hit_wall and _carry_written != 0.0 and signf(_own_vx) == -signf(_carry_written):
		_own_vx = 0.0  # carried into a wall: don't keep a stored push-back that would creep it away later
	state.linear_velocity = vel
	_integrate_rotation(state)
	_vy = vel.y

## Rotation half of _integrate_forces(). Locked: no angular motion at all. Allowed: accept the solver's angular
## change (landing on a corner, tipping over an edge) unless an actor is touching the block, then apply the
## righting spring toward the nearest 90 degrees and angular drag.
func _integrate_rotation(state: PhysicsDirectBodyState2D) -> void:
	if not allow_rotation:
		state.angular_velocity = 0.0
		return
	var xf := state.transform
	var av := state.angular_velocity
	if reject_actor_shove and _actor_side != 0:
		var gained := av - _written_av
		if absf(gained) > SHOVE_EPSILON and absf(av) > absf(_written_av):  # spin added by the actor, not the solver cancelling ours
			xf = Transform2D(xf.get_rotation() - gained * state.step, xf.origin)  # undo the turn that speed caused
			state.transform = xf
			av = _written_av
	var quarter := PI * 0.5
	var angle := xf.get_rotation()
	var base := _floor_tilt if _floor_slope != INF else 0.0  # lie flat on a tilted plank rather than pulling toward world-upright
	var error := (angle - base) - roundf((angle - base) / quarter) * quarter
	if _floor_is_body and _is_held():
		# Held on a moving body: turn with it. Discarding the solver's angular change here is what stops a
		# reversing plank leaving the block a step behind, balanced on one corner. (Not held = the block is
		# tipping or sliding off, and takes the ordinary path below.)
		av = _floor_av - righting_stiffness * error * state.step
	else:
		av -= righting_stiffness * error * state.step
		av += (_buoyancy_alpha + _rider_alpha) * state.step
		av /= 1.0 + (angular_drag + angular_drag_liquid * _liquid_fraction) * state.step
	if absf(av) < 0.001:
		av = 0.0
	state.angular_velocity = av
	_written_av = av

## Whether the player may grab, or keep hanging from, this block right now. A locked block is always upright, so
## yes (as in stage 1); a rotation-allowed one only while near flat and slow. Called by the player.
func is_hangable() -> bool:
	if not allow_rotation:
		return true
	return absf(_upright_residual()) <= deg_to_rad(hang_max_tilt_degrees) \
			and linear_velocity.length() <= hang_max_speed and absf(angular_velocity) <= hang_max_spin

## Static friction, decided by hand because the engine contact has none (friction 0). An idle block on a floor
## no steeper than `hold_slope_degrees` has gravity cancelled, so it neither creeps nor sinks; steeper, gravity
## acts and it slides. A rotation-allowed block is only held while the floor contacts sit under its centre of
## mass (on both sides of it, give or take SUPPORT_TOLERANCE), so one overhanging a ledge still topples, and
## while it lies no more tilted than the surface under it, so one on its side or knocked askew still tips.
func _is_held() -> bool:
	if not _on_floor or _floor_slope > deg_to_rad(hold_slope_degrees):
		return false
	if not allow_rotation:
		return true
	var x := global_position.x
	if _support_min_x > x + SUPPORT_TOLERANCE or _support_max_x < x - SUPPORT_TOLERANCE:
		# The contact report can drop one corner of a flat contact on a moving body for a frame or two; that is
		# not an overhang, and letting go there starts the block rocking corner to corner. Tiles keep the strict test.
		if not (_floor_is_body and _support_latch > 0):
			return false
	var quarter := PI * 0.5
	var tilt := rotation - roundf(rotation / quarter) * quarter
	return absf(tilt) <= _floor_slope + HOLD_TILT_MARGIN

## Classifies the previous step's contacts. Orientation-independent: a floor contact is a near-vertical normal
## whose contact point is below the block's centre, so the sign convention of the contact normal doesn't matter.
func _scan_contacts(state: PhysicsDirectBodyState2D) -> void:
	_on_floor = false
	_hit_wall = false
	_wall_side = 0
	_actor_side = 0
	_rider_on_top = false
	_roof_hit = false
	_floor_v = Vector2.ZERO
	_floor_tilt = 0.0
	_floor_is_body = false
	_floor_av = 0.0
	_belt_speed = 0.0
	_floor_slope = INF
	_support_min_x = INF
	_support_max_x = -INF
	_floor_slippery = false
	var centre := state.transform.origin
	var tilt := 0.0  # tilt from the nearest 90 degrees: actor contacts are classified in the block's upright frame
	if allow_rotation:
		var angle := state.transform.get_rotation()
		tilt = angle - roundf(angle / (PI * 0.5)) * PI * 0.5
	for i in state.get_contact_count():
		var normal := state.get_contact_local_normal(i)
		var point := state.get_contact_local_position(i)
		var collider := state.get_contact_collider_object(i)
		var body := collider as CollisionObject2D  # null for tiles
		var is_actor := _is_actor_body(body)
		if absf(normal.y) > FLOOR_NORMAL_Y and point.y > centre.y:
			_on_floor = true
			if is_actor:
				continue
			var contact_av := 0.0  # the floor body's angular velocity, if it reports one (RotatingBody, a rigid block)
			if collider != null and collider.has_method("get_angular_velocity"):
				contact_av = collider.get_angular_velocity()
			if collider != null and collider.has_method("is_slippery") and collider.is_slippery():
				_floor_slippery = true
			var slope := atan2(absf(normal.x), absf(normal.y))
			if slope < _floor_slope:
				var up := normal if normal.y < 0.0 else -normal  # the face normal pointing up, whichever way the engine reports it
				_floor_tilt = atan2(up.x, -up.y) if body != null else 0.0
				_floor_is_body = body != null
				_floor_av = contact_av if body != null else 0.0
			_floor_slope = minf(_floor_slope, slope)
			_support_min_x = minf(_support_min_x, point.x)
			_support_max_x = maxf(_support_max_x, point.x)
			# The floor's velocity at the block's centre, not at this corner: on a rotating floor the two corners of
			# a flat contact move at different speeds, and the rigid block can only match one velocity at its centre.
			var lever := centre - point
			var floor_v := state.get_contact_collider_velocity_at_position(i) + contact_av * Vector2(-lever.y, lever.x)
			if floor_v.length_squared() > _floor_v.length_squared():
				_floor_v = floor_v
			if collider != null and collider.has_method("get_conveyor_speed"):
				_belt_speed = collider.get_conveyor_speed()
		elif is_actor:
			if absf(normal.rotated(-tilt).x) > ACTOR_SIDE_NORMAL_X:
				_actor_side = 1 if point.x > centre.x else -1
			elif point.y < centre.y:
				_rider_on_top = true
		elif absf(normal.x) > WALL_NORMAL_X:
			_hit_wall = true
			_wall_side = 1 if point.x > centre.x else -1
		elif absf(normal.y) > FLOOR_NORMAL_Y and point.y < centre.y:
			_roof_hit = true
	var straddles := _support_min_x <= centre.x + SUPPORT_TOLERANCE and _support_max_x >= centre.x - SUPPORT_TOLERANCE
	if straddles:
		_support_latch = SUPPORT_LATCH_FRAMES
	elif _support_latch > 0:
		_support_latch -= 1

func _physics_process(delta: float) -> void:
	if _melted:
		return

	_update_hanger_exception()
	if debug_hold and _on_floor and Engine.get_physics_frames() % 10 == 0:
		print("%s held=%s slope=%.1f tilt=%.1f floor_tilt=%.1f support=[%.1f..%.1f] x=%.1f own_vx=%.1f floor_v=%s vy=%.1f" % [name, _is_held(), rad_to_deg(_floor_slope), rad_to_deg(rotation), rad_to_deg(_floor_tilt), _support_min_x, _support_max_x, global_position.x, _own_vx, _floor_v, _vy])
	if allow_rotation:
		_liquid_fraction = maxf(_submerged_fraction(LiquidConstants.LiquidType.WATER), _submerged_fraction(LiquidConstants.LiquidType.SLAG))
	var riders := _actors_in_band(-1.0, 4.0)
	_rider_count = riders.size()
	_rider_alpha = _rider_torque(riders) if allow_rotation else 0.0
	velocity = Vector2(_own_vx, _vy)
	_buoyancy_alpha = 0.0
	_apply_forces(delta, _rider_count)
	if _on_floor:
		if Engine.get_physics_frames() - _last_walk_push_frame > WALK_PUSH_GRACE_FRAMES:  # a block being walked along isn't braked under the player
			velocity.x = move_toward(velocity.x, 0.0, slide_friction * delta)
		var floor_vy := _floor_v.y if carry_assist else 0.0
		if velocity.y > floor_vy and _is_held():
			# Held by static friction: at rest relative to the floor, not the world. Matching the floor's vertical
			# velocity (a tilting plank, a lift) keeps the contact from pressing into the block each frame; that
			# frictionless, tilted push has a downhill part the solver would add to _own_vx and creep it off.
			velocity.y = floor_vy

	_end_walk_push()

	if _launch_pending:  # after every other edit of `velocity`, so nothing above can cancel it
		_launch_pending = false
		velocity = _launch_vector
		_vy = _launch_vector.y

	_riders_free_above = true
	if reject_actor_shove and velocity.y < 0.0:
		for rider in riders:
			if rider.test_move(rider.global_transform, Vector2(0.0, minf(velocity.y * delta * 2.0, -1.0))):
				_riders_free_above = false  # a ceiling over a rider: the block must stop, not squeeze it
				break

	var carry := _belt_speed
	if carry_assist:
		carry += _floor_v.x
	_own_vx = velocity.x
	_carry_written = carry
	_written_vx = velocity.x + carry
	linear_velocity = Vector2(_written_vx, velocity.y)
	_written_vy = velocity.y
	if not allow_rotation:
		angular_velocity = 0.0

	_update_melt(delta)

## Subclass hook: update `velocity` for this frame — gravity or buoyancy, liquid drag, splash sound. Runs
## before the floor friction and the write. `velocity.x` is the block's own motion (no carry). Helpers:
## _submerged_fraction(), _buoyant_accel(), _integrate_gravity().
func _apply_forces(delta: float, _riders: int) -> void:
	_integrate_gravity(GRAVITY, delta)

## Subclass hook: true while the block is in molten slag (heats it at 1 / slag_melt_time).
func _touching_slag() -> bool:
	return false

func _integrate_gravity(accel_y: float, delta: float) -> void:
	velocity.y = clampf(velocity.y + accel_y * delta, -MAX_FALL_SPEED, MAX_FALL_SPEED)

## Vertical acceleration while `submerged` (0..1) of the block is under the liquid: zero net force at the
## rest fraction (`float_depth_fraction` plus the riders' load), upward when deeper, downward when shallower.
## A rest fraction of 1.0 or more can't carry the load, so the block sinks. The load applies from the first
## frame a rider is detected, so it doesn't depend on the block having settled.
## `liquid_type` selects which centre of buoyancy the couple uses (rotation allowed only; -1 = none).
func _buoyant_accel(submerged: float, riders: int, liquid_type: int = -1) -> float:
	var rest_fraction := _rest_fraction(riders)
	if allow_rotation and _cob_world.get(liquid_type) is Vector2:
		var size := Vector2(size_tiles) * TILE
		var com_world := to_global(Vector2(0.0, size.y * 0.5 * com_drop))
		var lever_x: float = _cob_world[liquid_type].x - com_world.x
		var gyration_sq := (size.x * size.x + size.y * size.y) / 12.0  # moment of inertia per unit mass
		_buoyancy_alpha -= lever_x * (GRAVITY * submerged / rest_fraction) / gyration_sq  # upward force right of the COM turns it counter-clockwise (negative)
	return GRAVITY * (1.0 - submerged / rest_fraction)

## The submerged fraction at which a floating block with `riders` aboard is in equilibrium: `float_depth_fraction`
## plus each rider's `rider_load_tiles` spread over the block's area. 1.0 or more can't carry the load.
func _rest_fraction(riders: int) -> float:
	return float_depth_fraction + riders * rider_load_tiles / float(size_tiles.x * size_tiles.y)

## Vertical liquid drag for a floating block: damps the block's vertical `velocity` toward the velocity of the
## settled `liquid_type` surface at its centre column (`WaterBasin.get_liquid_surface_velocity_y()`) instead of
## toward rest, at `coefficient * submerged` per second. Drag against the world held a loaded block to a fixed
## rise speed (the buoyancy surplus above its rest fraction divided by the drag, about 8 px/s for a 1x1 ice block
## with a rider), so a rising level overtook it. Relative to the liquid, a block at its rest fraction rides the
## surface at any speed, and the drag still settles the bob (still liquid: identical to damping toward 0).
## The liquid's velocity counts only in proportion to how afloat the block is (`submerged` over its rest
## fraction, at most 1), so a block resting on the seabed under a barely wetted base isn't dragged up by the
## current before it has the buoyancy to lift off.
func _damp_vertical_in_liquid(coefficient: float, submerged: float, riders: int, liquid_type: int, delta: float) -> void:
	var basin := _centre_basin()
	var liquid_vy := 0.0
	if basin != null and basin.liquid_type == liquid_type and basin.fill_volume > 0.0:
		liquid_vy = basin.get_liquid_surface_velocity_y() * clampf(submerged / _rest_fraction(riders), 0.0, 1.0)
	velocity.y = liquid_vy + (velocity.y - liquid_vy) / (1.0 + coefficient * submerged * delta)

## The basin (any liquid) at the block's centre column, probed just inside its lowest point, or null. With
## rotation allowed it falls back to the block's centre when the lowest point is already below that column's seabed.
func _centre_basin() -> WaterBasin:
	if _water_manager == null:
		return null
	var lowest := global_position.y + size_tiles.y * TILE * 0.5
	if allow_rotation:
		lowest = -INF
		for corner in _corners_world():
			lowest = maxf(lowest, corner.y)
	var probe := Vector2(global_position.x, lowest - 0.5)  # just inside the block's lowest point
	var basin: WaterBasin = _water_manager.get_basin_for_column(_water_manager.world_to_cell(probe).x, probe.y)
	if basin == null and allow_rotation:
		probe = global_position
		basin = _water_manager.get_basin_for_column(_water_manager.world_to_cell(probe).x, probe.y)
	return basin

## Cosmetic: the block has just hit a liquid surface at `impact_speed` px/s; stirs that basin's surface ripple.
func _splash_ripple(impact_speed: float) -> void:
	var basin := _centre_basin()
	if basin != null:
		basin.disturb(global_position.x, -impact_speed * SPLASH_RIPPLE_IMPULSE * size_tiles.x, size_tiles.x * TILE * 0.5 + 4.0)

## 0..1: how much of the block's area is below the liquid surface of the settled `liquid_type` basin at its
## centre column (the surface is taken as flat across the block). Crust doesn't count
## (get_liquid_surface_world_y() is the liquid's own surface). Also records the submerged area's centroid
## in `_cob_world` for the buoyancy couple.
func _submerged_fraction(liquid_type: int) -> float:
	_cob_world[liquid_type] = null  # no centroid until the clip below finds some submerged area
	var basin := _centre_basin()
	if basin == null or basin.liquid_type != liquid_type or basin.fill_volume <= 0.0:
		return 0.0
	var below := _clip_below(_corners_world(), basin.get_liquid_surface_world_y())
	var total := float(size_tiles.x * size_tiles.y) * TILE * TILE
	var area := 0.0
	var centroid := Vector2.ZERO
	var n := below.size()
	if n >= 3:
		var twice_area := 0.0
		for i in n:
			var p := below[i]
			var q := below[(i + 1) % n]
			var cross := p.x * q.y - q.x * p.y
			twice_area += cross
			centroid += (p + q) * cross
		area = absf(twice_area) * 0.5
		if area > 0.001:
			centroid /= 3.0 * twice_area  # (1 / 6A) * sum, with 2A = twice_area
	if area <= 0.001:
		return 0.0
	_cob_world[liquid_type] = centroid
	return clampf(area / total, 0.0, 1.0)

## The block's four corners in world space (the collision rectangle, centred on the origin).
func _corners_world() -> PackedVector2Array:
	var half := Vector2(size_tiles) * TILE * 0.5
	var xf := global_transform
	return PackedVector2Array([xf * Vector2(-half.x, -half.y), xf * Vector2(half.x, -half.y), xf * Vector2(half.x, half.y), xf * Vector2(-half.x, half.y)])

## Part of a convex polygon at or below world y `surface_y` (greater y), by clipping against that line.
func _clip_below(poly: PackedVector2Array, surface_y: float) -> Array[Vector2]:
	var out: Array[Vector2] = []  # an Array, not a PackedVector2Array: its append() returns nothing to discard
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var a_in := a.y >= surface_y
		var b_in := b.y >= surface_y
		if a_in:
			out.append(a)
		if a_in != b_in:
			out.append(a.lerp(b, (surface_y - a.y) / (b.y - a.y)))
	return out

## True while any part of the block is below the still-liquid surface of a `liquid_type` basin. Tests the four
## (rotated) corners and the bottom midpoint, each against the basin in its own column, since a wide block can
## straddle a basin edge. Crust doesn't count, so a block resting on crust over slag is safe.
func _touching_liquid(liquid_type: int) -> bool:
	if _water_manager == null:
		return false
	var half := Vector2(size_tiles) * TILE * 0.5
	var xf := global_transform
	var locals: Array[Vector2] = [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y), Vector2(0.0, half.y)]
	for local_point in locals:
		var point: Vector2 = xf * local_point
		var probe: Vector2 = point + (xf.origin - point).normalized()  # 1px toward the centre, so an edge on a tile boundary reads the interior column
		var basin: WaterBasin = _water_manager.get_basin_for_column(_water_manager.world_to_cell(probe).x, probe.y)
		if basin != null and basin.liquid_type == liquid_type and basin.fill_volume > 0.0 \
				and point.y > basin.get_liquid_surface_world_y():
			return true
	return false

## Heating: the beam and slag both melt it, the faster one wins; otherwise it cools back down.
func _update_melt(delta: float) -> void:
	var lit := Engine.get_physics_frames() - _last_lit_frame <= LIT_GRACE_FRAMES
	var melt_rate := 0.0  # progress per second
	if lit:
		melt_rate = 1.0 / maxf(melt_time, 0.01)
	if _touching_slag():
		melt_rate = maxf(melt_rate, 1.0 / maxf(slag_melt_time, 0.01))
	var previous := melt_progress
	if melt_rate > 0.0:
		melt_progress = minf(melt_progress + melt_rate * delta, 1.0)
	else:
		melt_progress = maxf(melt_progress - cool_rate * delta, 0.0)
	if melt_progress != previous:
		queue_redraw()
	if melt_progress >= 1.0:
		_melt()

# --- actor contact ---------------------------------------------------------------------------------

## Angular acceleration (per unit mass, clockwise positive) from the riders' weight: each acts straight down at
## its x, so its torque about the centre of mass is its horizontal lever times its weight, over the radius of
## gyration squared. Weight is in the buoyancy model's units (see _buoyant_accel()), so in liquid the couple
## balances the buoyancy couple exactly when the centre of buoyancy sits under the riders' feet.
func _rider_torque(riders: Array[PhysicsBody2D]) -> float:
	if riders.is_empty():
		return 0.0
	var size := Vector2(size_tiles) * TILE
	var area_tiles := float(size_tiles.x * size_tiles.y)
	var rest_fraction := float_depth_fraction + riders.size() * rider_load_tiles / area_tiles
	var weight := GRAVITY * (rider_load_tiles / area_tiles) / rest_fraction
	var com_x := to_global(Vector2(0.0, size.y * 0.5 * com_drop)).x
	var gyration_sq := (size.x * size.x + size.y * size.y) / 12.0
	var alpha := 0.0
	for body in riders:
		alpha += (body.global_position.x - com_x) * weight / gyration_sq
	# Statically stable: the block and its riders together balance over the floor contacts, so the support
	# cancels this torque. Applying it anyway only rocks the block against the floor, and that rocking shoves
	# whatever is stacked on top. It still tips once the combined centre passes the last contact.
	if _on_floor:
		var rider_mass := rider_load_tiles / (area_tiles * float_depth_fraction)  # one rider's weight as a fraction of the block's
		var moment := 0.0
		for body in riders:
			moment += (body.global_position.x - com_x) * rider_mass
		var combined_x := com_x + moment / (1.0 + riders.size() * rider_mass)
		if _support_min_x <= combined_x + RIDER_SUPPORT_TOLERANCE and _support_max_x >= combined_x - RIDER_SUPPORT_TOLERANCE:
			return 0.0
	return alpha

## The block's size as an upright rectangle: width and height swap when it lies on its side (rotation allowed).
func _upright_size() -> Vector2:
	var size := Vector2(size_tiles) * TILE
	if allow_rotation and roundi(global_rotation / (PI * 0.5)) % 2 != 0:
		size = Vector2(size.y, size.x)
	return size

## Tilt away from the nearest 90 degrees (0 when rotation is locked).
func _upright_residual() -> float:
	if not allow_rotation:
		return 0.0
	return global_rotation - roundi(global_rotation / (PI * 0.5)) * PI * 0.5

## Whether `body` is an actor, a walker that is not part of the world: by the layer convention a body on layer 1 and not on
## layer 2 (null, a tile, is not). A basin's crust body is the one world solid on layer 1 alone (`WaterBasin.crust_collision_layer`),
## so it is named here (group "crust") and counts as world: read as an actor, a floor contact is dropped before it reaches the
## floor slope, support extent, hold or `is_slippery()` scan, and the block on a crust is never held or slippery.
func _is_actor_body(body: CollisionObject2D) -> bool:
	return body != null and (body.collision_layer & 2) == 0 and not body.is_in_group(&"crust")

## Actors (layer-1-only bodies) overlapping a thin band as wide as the block, whose centre is
## `center_y_from_top` below the block's top edge (-1 = just above the top face, size.y + 1 = just below the
## bottom face), `band_height` tall. A query rather than anyone's floor contact, because a swimming player's
## floor state is stale/unreliable and the block may be moving under them.
func _actors_in_band(center_y_from_top: float, band_height: float) -> Array[PhysicsBody2D]:
	if _rider_query == null:
		_rider_query = PhysicsShapeQueryParameters2D.new()
		_rider_query.collision_mask = 1
		_rider_query.shape = RectangleShape2D.new()
		_rider_query.exclude = [get_rid()]
	var size := _upright_size()
	var residual := _upright_residual()
	(_rider_query.shape as RectangleShape2D).size = Vector2(maxf(size.x - 2.0, 1.0), band_height)
	_rider_query.transform = Transform2D(residual, global_position + Vector2(0.0, -size.y * 0.5 + center_y_from_top).rotated(residual))
	var seen := {}
	var actors: Array[PhysicsBody2D] = []
	for hit in get_world_2d().direct_space_state.intersect_shape(_rider_query, 8):
		var body := hit.collider as PhysicsBody2D
		if _is_actor_body(body) and not seen.has(body.get_instance_id()) \
				and not (_ignoring_hanger and body == _player):  # a hanging player is on the side wall, not a rider
			seen[body.get_instance_id()] = true
			actors.append(body)
	return actors

## Adds/removes the mutual collision exception with the player for exactly as long as the player's hang is
## attached to this block. See the header note.
func _update_hanger_exception() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&"player") as PhysicsBody2D
		if _player == null:
			return
	var hanging: bool = _player.get("is_hanging") == true and _player.get("hang_platform") == self
	if hanging and not _ignoring_hanger:
		add_collision_exception_with(_player)
		_ignoring_hanger = true
	elif not hanging and _ignoring_hanger:
		remove_collision_exception_with(_player)
		_ignoring_hanger = false

# --- melting ---------------------------------------------------------------------------------------

## Bursts into `_melt_liquid_type()` particles, one WaterManager.spawn_melt_particles() call per 16px cell the
## block covers, then frees itself. Each burst is spawned at the cell's exact world position and spread in the block's
## own rotated frame (passed through), not snapped to the tile grid: a block resting on a see-saw is off the grid and
## tilted, and a snapped, axis-aligned spread put particles inside the plank, so they fell through it.
func _melt() -> void:
	_leave_world()
	Audio.play_at(_melt_sound(), global_position)

	var manager := get_tree().get_first_node_in_group(&"water_manager") as WaterManager
	if manager != null:
		var half := Vector2(size_tiles) * TILE * 0.5
		for cy in size_tiles.y:
			for cx in size_tiles.x:
				var local_center := Vector2(-half.x + (cx + 0.5) * TILE, -half.y + (cy + 0.5) * TILE)
				manager.spawn_melt_particles(manager.world_to_cell(to_global(local_center)), _melt_liquid_type(), to_global(local_center), global_rotation)
	else:
		push_warning("%s: no WaterManager in group 'water_manager' — melted with no liquid" % name)
	queue_free()

## Everything a block that is going away does at once, whichever way it goes (melt, dissolve): marks itself gone
## (`is_intact()` turns false), stops its physics step, leaves the water and ground groups, lets go of a hanging
## player, and stops being solid.
func _leave_world() -> void:
	_melted = true
	set_physics_process(false)
	remove_from_group(&"water_solid")
	remove_from_group(&"ground")
	# a hang is pinned in world space and wouldn't notice the block vanishing (same as drop_platform.gd)
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.get("hang_platform") == self:
		player.is_hanging = false
	if _ignoring_hanger and is_instance_valid(_player):
		remove_collision_exception_with(_player)
		_ignoring_hanger = false
	$CollisionShape2D.set_deferred("disabled", true)  # stop being solid immediately

## True until the block has started melting or dissolving away. A BlockDispenser counts only intact blocks.
func is_intact() -> bool:
	return not _melted

## Quiet retirement (a BlockDispenser calls it on its oldest block): no liquid, no melt sound. The block stops being
## solid at once, holds still, fades out over DISSOLVE_TIME and frees itself. Does nothing to a block that is already
## going away.
func dissolve() -> void:
	if _melted:
		return
	_leave_world()
	set_deferred("freeze", true)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, DISSOLVE_TIME)
	tween.tween_callback(queue_free)

## Jam contract (crusher.gd sweeps its stroke for anything with jams_crusher() true): a block that is solid enough to
## stall a crusher's piston rather than break. False in the base class; MetalBlock overrides it.
func jams_crusher() -> bool:
	return false

## True if a crusher's spike shatters this block (see shatter()): the `brittle` flag.
func _shatters_when_crushed() -> bool:
	return brittle

## How a brittle block breaks (a bullet, a crusher's spike). The base class goes through the ordinary melt path, so it
## plays its melt sound and spawns the same liquid burst (ice); a subclass without liquid overrides it (carbon fiber).
func _break_apart() -> void:
	_melt()

## Subclass hooks for what the block melts into and how it sounds.
func _melt_liquid_type() -> int:
	return LiquidConstants.LiquidType.WATER

func _melt_sound() -> StringName:
	return &"interactive/ice_melt"

func _shunt_sound() -> StringName:
	return &"interactive/ice_shunt"

## Sound of a walking player starting to push the block. Defaults to the kick sound.
func _walk_push_sound() -> StringName:
	return _shunt_sound()

# --- editor / drawing ------------------------------------------------------------------------------

## Gives this instance its own collision shape. Scene instances share one sub-resource, and _sync_shape()
## resizes it, so blocks with different `size_tiles` would otherwise all take the size of the last one loaded.
func _own_shape() -> void:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node != null and shape_node.shape != null:
		shape_node.shape = shape_node.shape.duplicate()

## Sizes the collider to `size_tiles`: a rectangle with its corners bevelled by `chamfer_px` (an octagon), so a
## sliding block doesn't catch on the seam between two tiles. The block scenes carry a ConvexPolygonShape2D
## (local to scene); the fallback only covers a scene that still has a RectangleShape2D.
func _sync_shape() -> void:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var half := Vector2(size_tiles) * TILE * 0.5
	var c := clampf(chamfer_px, 0.0, minf(half.x, half.y) - 1.0)
	var points := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)])
	if c > 0.01:
		points = PackedVector2Array([
			Vector2(-half.x + c, -half.y), Vector2(half.x - c, -half.y), Vector2(half.x, -half.y + c), Vector2(half.x, half.y - c),
			Vector2(half.x - c, half.y), Vector2(-half.x + c, half.y), Vector2(-half.x, half.y - c), Vector2(-half.x, -half.y + c)])
	var poly := shape_node.shape as ConvexPolygonShape2D
	if poly == null:
		poly = ConvexPolygonShape2D.new()
		shape_node.shape = poly
	poly.points = points

func _draw() -> void:
	if not draw_placeholder:
		return
	var size := Vector2(size_tiles) * TILE
	_draw_block(Rect2(-size * 0.5, size))

## Subclass hook: art for the block's local-space rect.
func _draw_block(_rect: Rect2) -> void:
	pass

## Draws one 16px art tile (its top-left in `texture` is `tile_origin`) across `rect`, which is the block's whole
## local-space rect. With `mirror_tiling` a block bigger than one tile along an axis shows only the outer 75% of the
## tile at each end (source 0..0.75 at the start, 0.25..1 at the end) and fills the span between with the middle
## band (source 0.25..0.75) ping-ponged, each copy mirrored against its neighbours, so the join between cells is a
## reflection and never a visible tile edge. A 2-tile axis is: 0..0.75 normal, 0.75..1.25 the mirrored band,
## 1.25..2 normal. Each axis is done independently, so a 3x2 block mirrors in both directions. A 1-tile axis, or
## `mirror_tiling` off, draws the plain tile. Every boundary is a whole pixel (the 0.25 edge is 4px), so nothing is
## resampled. Art for any MeltableBlock subclass goes through here (IceBlock does; MetalBlock will once it has a sprite).
func _draw_art(texture: Texture2D, tile_origin: Vector2, rect: Rect2) -> void:
	var xs := _mirror_segments(size_tiles.x)
	var ys := _mirror_segments(size_tiles.y)
	for sy in ys:
		for sx in xs:
			var src := Rect2(tile_origin + Vector2(sx.src, sy.src), Vector2(sx.len_src, sy.len_src))
			var dst_size := Vector2(sx.len_out, sy.len_out)
			var origin := rect.position + Vector2(sx.out, sy.out)
			# A mirrored segment is drawn through a flipped transform rather than a negative-size rect, which
			# is the unambiguous way to flip a texture region across engine versions.
			var basis_x := Vector2(-1.0 if sx.flip else 1.0, 0.0)
			var basis_y := Vector2(0.0, -1.0 if sy.flip else 1.0)
			var at := origin + Vector2(dst_size.x if sx.flip else 0.0, dst_size.y if sy.flip else 0.0)
			draw_set_transform_matrix(Transform2D(basis_x, basis_y, at))
			draw_texture_rect_region(texture, Rect2(Vector2.ZERO, dst_size), src)
	draw_set_transform_matrix(Transform2D.IDENTITY)

## One axis of _draw_art(): an array of {out, len_out, src, len_src, flip} (px along the axis, source offsets within
## the tile). `tiles` cells long; see _draw_art() for the layout.
func _mirror_segments(tiles: int) -> Array:
	if tiles <= 1 or not mirror_tiling:
		var plain: Array = []
		for i in maxi(tiles, 1):
			plain.append({"out": i * TILE, "len_out": TILE, "src": 0.0, "len_src": TILE, "flip": false})
		return plain
	var edge := TILE * MIRROR_EDGE_FRACTION  # 4px
	var band := TILE - 2.0 * edge  # the ping-ponged middle: source edge..TILE-edge (8px)
	var outer := TILE - edge  # the visible part of an end tile (12px)
	var segs: Array = [{"out": 0.0, "len_out": outer, "src": 0.0, "len_src": outer, "flip": false}]
	var total := tiles * TILE
	var middle := total - 2.0 * outer
	for k in int(round(middle / band)):  # 2*tiles-3 copies: always odd, so the last one lands on source `edge` going into the end piece
		segs.append({"out": outer + k * band, "len_out": band, "src": edge, "len_src": band, "flip": k % 2 == 0})
	segs.append({"out": total - outer, "len_out": outer, "src": edge, "len_src": outer, "flip": false})
	return segs
