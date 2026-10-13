@tool
class_name RotatingBody
extends AnimatableBody2D

# Rotating platform base (see-saw, water wheel). Roadmap: objon.md, "Roadmap: rotating bodies".
#
# STEP 1.1: rotation about the Fulcrum. No torque in this step; riders are carried by move_and_slide()'s ordinary
# moving-floor inheritance, plus the idle-rider grip below.
#
# How the rotation works: the body's transform at _ready() is the "rest pose". Each physics frame the pose is
# rest_transform rotated by `_angle` about the pivot (the Fulcrum's position at rest, in parent space).
# Motion is written inside _physics_process() with sync_to_physics on, same contract as moving_platform.gd,
# so the physics server derives the body's linear + angular velocity from the transform change.
#
# Idle-rider grip: move_and_slide()'s carry alone left riders creeping toward the descending end on every
# swing (each frame's leftover error — a straight-line step from the previous step's velocity, then
# depenetration and floor snap — has a downhill component on a tilt, and nothing ever restores it). So a
# rider that is standing still on this body is pinned at a fixed point in the body's local space: each frame,
# after the body has moved, its global position is set from that anchor. A rider that is moving under its own
# power (|velocity.x| above IDLE_SPEED: walking, a kicked block) is released and left to the engine;
# it is re-anchored where it stands the moment it is idle again. The anchor is the rider's FOOT point (the
# lowest point of its upright collider), not its collider centre: riders never rotate, so as the face tilts the
# point where an upright capsule/box actually touches it moves sideways relative to the centre, and a
# centre anchor reads as the rider sliding along the surface. After the foot is placed the rider is snapped
# onto the face along the face normal (move_and_collide: depenetrates if sunk, closes the gap if hovering),
# which fixes only the perpendicular distance. `grip_idle_riders = false` turns this off
# for A/B comparison. This body runs AFTER every other physics process (process_physics_priority) so riders
# have already done their own move_and_slide() for the frame when it pins them.
#
# STEP 1.2 (weights and load): every physics frame, after the body has moved, it finds
# what is standing on it and reports the torque each load would apply about the pivot. Loads are the player
# (`player_weight`, same units as a block's `mass`: metal 4 and ice 1 per 16px tile) and MeltableBlocks (their
# `mass`) and, when `enemy_weight_scale` is above 0 (default 0: enemies are ignored), enemies by their
# `get_load_weight()`. Detection is a thin band over the top face of each collision shape, following the rotation (like the grip's), but on layer 1 it also returns rigid blocks, which the grip
# deliberately skips. A candidate counts only if it is resting on its support: a short probe (2px, along
# the face normal for this body) must reach the support (a `test_move()` that hits it first for actors, an overlap
# query for rigid blocks, whose mask includes the player's layer), which excludes a block beside the plank or a player
# in mid-air. Loads stack: whatever rests on a block that rests on this body (a player on a block, a block on a
# block, up to MAX_STACK_DEPTH levels) is counted too, at its own x (a block or an enemy can carry a stack).
# Torque = weight x (load x - pivot x), positive = clockwise on screen (the same sign as the angle): standing right of the pivot pushes the right side down.
# `get_net_torque()` (loads + resting liquid + steam push; `get_load_torque()`, `get_liquid_torque()` and `get_steam_torque()` are its parts) and
# `get_loads()` are what the dynamics read. `debug_draw` (or `debug_toggle_key`
# at runtime) draws the pivot, every load's lever arm, weight and torque, and the net torque as an arc, in world
# space; in the editor it draws just the pivot so the Fulcrum can be placed.
#
# STEP 1.3 (dynamics): the angle is now integrated from the torques, not spun at a test rate. Each physics frame,
# before the body moves: torque = the loads' net torque (`_net_torque`, from the previous frame's scan, so one
# frame old) + the motor (`get_motor_torque()`, step 3.3) - `restoring_torque` x angle (a spring back to level; ignored
# with `free_rotation` and while the motor runs).
# Angular velocity gains torque / `inertia` x delta, loses `damping` (fraction per second), then `friction_torque`
# is taken off its magnitude and never past zero, so friction only opposes motion: a body at rest with a net torque
# below `friction_torque` stays put. Without `free_rotation` the angle is clamped to [`min_angle_degrees`,
# `max_angle_degrees`] and angular velocity into a stop is zeroed (no bounce); with it the angle wraps to +/-PI.
# Inertia is a fixed export: the loads do not add to it (their weights are in torque units, where gravity is 1, so
# adding weight x r^2 would swamp any sensible inertia). `get_angle()`, `get_angular_velocity()` (the real step's
# change of angle, so it is 0 against a stop) and `get_net_torque()` are the readouts; blocks resting on it read
# the angular velocity as before.
#
# STEP 3.3 (power): `set_powered(on)` (the PowerTarget contract, with an `invert` export) switches `motor_torque`: on = motorized,
# off = a free see-saw. With an angle limit the motor reverses at each stop so the body oscillates between them (the
# spring back to level is suspended while it runs); with `free_rotation` it is a steady drive.
#
# STEP 3.2 (audio): a looping creak at the pivot (`creak_sound`, volume and pitch follow the angular speed, faded so
# it doesn't click) and a positional thud when the angle limit is hit (`stop_sound`, louder the faster it arrives).
# Both are Audio ids that are in Audio.PLANNED until their files exist.
#
# STEP 3.1 (checkpoints): joins "saveable"; save_state() holds the angle and angular velocity, load_state() snaps to
# them silently and clears the grip anchors and load state (see below).
#
# STEP 1.5 (editor authoring): in the editor the body draws translucent ghosts of its collision shapes at the minimum
# and maximum angle (`show_limits_in_editor`; skipped with `free_rotation`), so the swing range is visible while the
# shape and the Fulcrum are edited, and it shows a configuration warning for a missing Fulcrum or collision shape.
# `seesaw.gd` extends this for `seesaw.tscn`: a 2 tile plank (32x8) with a per-instance length export, an optional
# tiling skin texture and one placeholder-art child (`seesaw_plank_art.gd`, drawn from the collision shapes).
#
# Joins "water_solid" at runtime (step 2.1): WaterManager lets particles rest on it and carries them by its full
# transform change, so liquid on a tilting plank is swung round the pivot.
#
# STEP 8.5 (ledge grab): joins "ground" at runtime (unless `hangable` is off or a subclass's `_joins_ground()` says
# no, as Swing's does) so the player's ledge grab accepts its end, and answers the player's duck-typed
# `is_hangable()`: only while tilted no more than `hang_max_tilt_degrees` from rest and turning no faster than
# `hang_max_angular_speed`. The player asks at the grab and every frame of the hang (and mantle), carries the hang
# through the body's full transform change (`_follow_hang_platform()`), and lets go the frame the answer is no.

## Pin riders that are standing still to the body (see header). Off = engine carry only.
@export var grip_idle_riders: bool = true
@export_group("Dynamics")
## Resistance to angular acceleration (angular acceleration = torque / inertia, rad/s^2). Torque is weight x px, so
## the player (weight 2) at 40px from the pivot is 80.
@export var inertia: float = 120.0
## Fraction of angular velocity lost per second (like Godot's angular damp).
@export var damping: float = 1.5
## Torque that always opposes motion and never reverses it: the body stays put while the net torque is below it.
@export var friction_torque: float = 8.0
## Spring back toward level, in torque per radian of tilt. 0 = no spring. Ignored with `free_rotation`.
@export var restoring_torque: float = 60.0
## Motor torque, positive = clockwise on screen. With an angle limit the motor alternates: its direction reverses each
## time the body reaches a stop, so it oscillates between the two limits (the sign of this sets the first direction, the
## spring back to level is suspended while the motor runs, and the motor has to beat any load that opposes it). With
## `free_rotation` it is a steady drive instead. Power switches it on and off (see "Power"); 0 = a free see-saw.
@export var motor_torque: float = 0.0
## Rotate all the way round (a wheel) instead of stopping at the angle limits.
@export var free_rotation: bool = false
## Lower angle limit (counter-clockwise, negative), degrees. Ignored with `free_rotation`. Keep the limits at about 25 or less so riders hold (step 1.4).
@export_range(-180.0, 0.0, 0.5) var min_angle_degrees: float = -25.0
## Upper angle limit (clockwise, positive), degrees. Ignored with `free_rotation`.
@export_range(0.0, 180.0, 0.5) var max_angle_degrees: float = 25.0
@export_group("Load")
## Scales the torque of liquid resting on the body (WaterManager works out the liquid's own weight from its profile). 0 = liquid doesn't tip it.
@export var liquid_weight_scale: float = 1.0
## Weight of the player standing on the body, in the same units as a block's `mass` (metal 4 per tile, ice 1). Tune with the dynamics in step 1.3.
@export var player_weight: float = 2.0
## Multiplies every enemy's `get_load_weight()` (a landed enemy standing on the body). 0 = enemies are ignored, so an
## existing see-saw is unchanged; 1 = they weigh what they are authored to.
@export_range(0.0, 10.0, 0.1, "or_greater") var enemy_weight_scale: float = 0.0
## Scales the upward push of steam dying on the body's underside (WaterManager sums and smooths it; roadmap N3.5). 0 = steam
## does not tip it, so an existing see-saw is unchanged; 1 = a full boil column under the tip of a 2-tile plank lifts it
## with a torque of about 45 (more than the player's weight at the tip, less than a metal block's).
@export_range(0.0, 10.0, 0.1, "or_greater") var steam_torque_scale: float = 0.0
@export_group("Hang")
## Whether the player can ledge-grab this body's ends. Off = never joins "ground", so it is a plain solid.
@export var hangable: bool = true
## Tilt from the rest pose (degrees, either way) beyond which the body can't be grabbed and a held hang is let go.
@export_range(0.0, 45.0, 0.5) var hang_max_tilt_degrees: float = 15.0
## Angular speed (rad/s) beyond which the body can't be grabbed and a held hang is let go.
@export_range(0.0, 3.0, 0.05) var hang_max_angular_speed: float = 0.8
@export_group("Power")
## Flips the power input: wired power ON = free see-saw, OFF = motorized. Read by the PowerTarget child. Unwired, the motor is just on (and with motor_torque 0, there is nothing to switch).
@export var invert: bool = false
@export_group("Audio")
## Looping creak while the body turns (Audio id; empty = none). Volume and pitch follow the angular speed.
@export var creak_sound: StringName = &"interactive/seesaw_creak"
## One-shot thud when the body hits an angle limit (Audio id; empty = none). Louder the faster it arrives.
@export var stop_sound: StringName = &"interactive/seesaw_thud"
## Angular speed (rad/s) at which the creak is at full volume and top pitch.
@export var creak_full_speed: float = 0.6
## Angular speed (rad/s) below which the creak is silent.
@export var creak_min_speed: float = 0.03
## Angular speed (rad/s) at which the stop thud is at full volume.
@export var stop_full_speed: float = 1.0
## Angular speed (rad/s) into a limit below which there is no thud (so resting against it, or touching it gently, is silent).
@export var stop_min_speed: float = 0.2
@export_group("Editor")
## Draws translucent ghosts of the collision shapes at the minimum (blue) and maximum (orange) angle in the editor. Editor only; skipped with `free_rotation`.
@export var show_limits_in_editor: bool = true
@export_group("Debug")
## Draws the pivot, each load's lever arm, weight and torque, and the net torque (see the header). Works in the editor (pivot only) and at runtime.
@export var debug_draw: bool = false:
	set(value):
		debug_draw = value
		_update_debug_overlay()
## Flips `debug_draw` at runtime (physical key). KEY_NONE = no key.
@export var debug_toggle_key: Key = KEY_NONE
## Prints a line whenever a load in the band fails the resting test (and what the test hit instead), to diagnose flicker.
@export var debug_loads: bool = false
## Net torque at which the debug arc has swept half a turn.
@export var debug_full_arc_torque: float = 400.0
@export_group("")

const CREAK_PITCH_LOW := 0.85  # the creak's pitch scale at the quietest, rising to HIGH at creak_full_speed
const CREAK_PITCH_HIGH := 1.15
const CREAK_FADE := 0.15  # seconds for the creak to fade in or out, so it doesn't click on and off as the speed crosses the threshold
const STOP_QUIET_DB := -18.0  # the thud's volume at stop_min_speed, rising to 0 dB at stop_full_speed
const LIMIT_MIN_COLOR := Color(0.4, 0.75, 1.0, 0.25)
const LIMIT_MAX_COLOR := Color(1.0, 0.6, 0.2, 0.25)
const RIDER_MASK := 1  # layer 1: the player and enemies (CharacterBody2D). Meltable blocks are also on it but are RigidBody2D, so _find_riders() skips them: they ride by engine contact plus their own carry assist, and load the body through their `mass` (step 1.2), not through this grip
const RIDER_BAND := 3.0  # px above the top face (local -Y) that counts as "on it" for the candidate query
const IDLE_SPEED := 6.0  # px/s of the rider's own horizontal velocity below which it counts as standing still
const MAX_STACK_DEPTH := 3  # levels of blocks (and what stands on them) counted above the body
const LOAD_LATCH_FRAMES := 8  # physics frames a load that is still in the band over the face keeps counting after the resting test starts failing (see _consider_load)
const SNAP_TO_FACE := 8.0  # px a pinned rider may be moved along the face normal to settle onto the face

var _angle: float = 0.0  # radians, relative to the rest pose
var _motor_on: bool = true  # power: the motor runs only while this is true (unwired = always)
var _motor_dir: float = 1.0  # +1 / -1: which way the motor is pushing now; flips at each stop (see _integrate_dynamics)
var _omega: float = 0.0  # rad/s, the integrated state (can differ from _angular_velocity on the frame a stop clamps the angle)
var _angular_velocity: float = 0.0  # rad/s, from the last physics step's change of _angle; blocks read it through get_angular_velocity()
var _drive_torque: float = 0.0  # last frame's torque on the body: loads + motor - spring (for the overlay)
var _rest_transform: Transform2D
var _pivot_parent: Vector2  # pivot in the parent's space, fixed for the life of the body
var _loads: Array[Dictionary] = []  # this frame's loads: {body, id (its instance id, still readable after the body is freed), weight, offset, torque, position}
var _net_torque: float = 0.0  # sum of the loads' torques about the pivot, positive = clockwise
var _liquid_torque: float = 0.0  # torque of the liquid resting on the body this frame, from WaterManager (already scaled by `liquid_weight_scale`)
var _steam_torque: float = 0.0  # torque of the steam pushing the body's underside this frame, from WaterManager (already scaled by `steam_torque_scale`; negative = lifts the right end)
var _water_manager: Node  # found lazily through the "water_manager" group; null in a level without one
var _creak  # Audio.LoopPlayer (untyped: this is a @tool script and the Audio autoload isn't), or null with no creak sound
var _creak_base_db: float = 0.0  # the loop's volume at full level, including Audio's per-id tuning
var _creak_level: float = 0.0  # 0..1, smoothed
var _overlay: TorqueOverlay  # the debug drawing (top level, so it draws in world space), or null
var _load_ids: Dictionary = {}  # instance ids of the loads reported last frame
var _load_misses: Dictionary = {}  # instance id -> consecutive frames its resting test has failed while latched
var _launched_frame: Dictionary = {}  # instance id -> physics frame a subclass launched it (see `_launched_recently()`); not saved
var _gripped: Dictionary = {}  # rider (CharacterBody2D: the player, enemies; never a rigid block) -> anchor in this body's local space

func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)  # the dynamics, the grip and the load scan are runtime-only; the editor just shows the pivot and the limits
		child_order_changed.connect(update_configuration_warnings)
		_update_debug_overlay()
		return
	set_process(false)  # _process() only redraws the editor preview
	if _joins_water_solid():
		add_to_group("water_solid")  # WaterManager collects the group in a deferred call, so tree order doesn't matter
	if hangable and _joins_ground():
		add_to_group("ground")  # what makes the ends ledge-hangable: Player._is_hangable_surface() reads the group, then asks is_hangable()
	add_to_group("saveable")  # checkpoints: save_state() / load_state() below (see Game's SAVEABLE CONTRACT)
	sync_to_physics = true  # the whole "riders are carried for free" design depends on it
	process_physics_priority = 100  # after riders' own move_and_slide() each frame
	_rest_transform = transform
	_motor_dir = -1.0 if motor_torque < 0.0 else 1.0
	var fulcrum := get_node_or_null("Fulcrum") as Node2D
	if fulcrum == null:
		push_warning("%s: no Fulcrum child, rotating about the body origin." % name)
		_pivot_parent = _rest_transform.origin
	else:
		_pivot_parent = _rest_transform * fulcrum.position
	_update_debug_overlay()
	_make_creak(fulcrum)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		queue_redraw()  # follow shape, Fulcrum and limit edits

## Editor only: ghosts of the collision shapes at the angle limits, each rotated about the Fulcrum exactly as
## _apply_angle() will rotate the body.
func _draw() -> void:
	if not Engine.is_editor_hint() or not show_limits_in_editor or free_rotation:
		return
	var fulcrum := get_node_or_null("Fulcrum") as Node2D
	var pivot := fulcrum.position if fulcrum != null else Vector2.ZERO
	for limit in [[min_angle_degrees, LIMIT_MIN_COLOR], [max_angle_degrees, LIMIT_MAX_COLOR]]:
		var angle := deg_to_rad(limit[0])
		var about_pivot := Transform2D(angle, pivot - pivot.rotated(angle))
		for child in get_children():
			var cs := child as CollisionShape2D
			if cs == null or cs.disabled or cs.shape == null:
				continue
			draw_set_transform_matrix(about_pivot * cs.transform)
			cs.shape.draw(get_canvas_item(), limit[1])
	draw_set_transform_matrix(Transform2D.IDENTITY)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_node_or_null("Fulcrum") == null:
		warnings.append("Add a Marker2D child named Fulcrum at the pivot; without it the body rotates about its own origin.")
	var has_shape := false
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			has_shape = true
	if not has_shape:
		warnings.append("Needs at least one CollisionShape2D (or CollisionPolygon2D) child.")
	if min_angle_degrees > max_angle_degrees:
		warnings.append("min_angle_degrees is above max_angle_degrees; the two are swapped at runtime.")
	return warnings

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var previous_angle := _angle
	_integrate_dynamics(delta)
	_angular_velocity = (_angle - previous_angle) / delta
	if free_rotation:
		_angle = wrapf(_angle, -PI, PI)  # after the velocity is taken, so the wrap isn't read as a jump
	_apply_angle()
	_update_creak(delta)
	_update_loads()
	if grip_idle_riders:
		_grip_riders()
	elif not _gripped.is_empty():
		_gripped.clear()
	if _overlay != null:
		_overlay.queue_redraw()

## Asks WaterManager for the torque of the liquid resting on this body this frame (it runs earlier in the frame, so
## this frame's value, not last frame's), and, with `steam_torque_scale` above 0, the smoothed push of steam dying on its
## underside. No manager in the level, or nothing on the body, is 0.
func _read_liquid_torque() -> void:
	if _water_manager == null or not is_instance_valid(_water_manager):
		_water_manager = get_tree().get_first_node_in_group("water_manager")
	_liquid_torque = 0.0
	_steam_torque = 0.0
	if _water_manager != null and _water_manager.has_method("get_resting_torque"):
		_liquid_torque = float(_water_manager.call("get_resting_torque", self)) * liquid_weight_scale
	if steam_torque_scale > 0.0 and _water_manager != null and _water_manager.has_method("get_steam_torque"):
		_steam_torque = float(_water_manager.call("get_steam_torque", self)) * steam_torque_scale

# --- audio (step 3.2) -------------------------------------------------------------------------------------

## The creak: a looping positional sound at the pivot (it doesn't move as the plank turns), silent until its file exists.
func _make_creak(fulcrum: Node2D) -> void:
	if creak_sound == &"":
		return
	_creak = Audio.make_loop(creak_sound)
	_creak.position = fulcrum.position if fulcrum != null else Vector2.ZERO
	add_child(_creak)
	_creak_base_db = _creak.volume_db

## Volume and pitch follow the angular speed. The level fades rather than switching, and the loop is stopped once
## it has faded out, so a still see-saw costs nothing. Against a stop the speed is 0, so it falls silent there.
func _update_creak(delta: float) -> void:
	if _creak == null or _creak.stream == null:
		return
	var speed := absf(_angular_velocity)
	var target := 0.0
	if speed > creak_min_speed:
		target = clampf(speed / maxf(creak_full_speed, 0.001), 0.0, 1.0)
	_creak_level = move_toward(_creak_level, target, delta / CREAK_FADE)
	if _creak_level <= 0.001:
		_creak_level = 0.0
		if _creak.playing:
			_creak.stop_loop()
		return
	_creak.start()
	_creak.volume_db = _creak_base_db + linear_to_db(_creak_level)
	_creak.pitch_scale = lerpf(CREAK_PITCH_LOW, CREAK_PITCH_HIGH, clampf(speed / maxf(creak_full_speed, 0.001), 0.0, 1.0))

## `speed`: rad/s the body was turning into the limit when it arrived (0 if it only pressed against it). A positional
## thud at the pivot, quiet at stop_min_speed and full at stop_full_speed; nothing below stop_min_speed.
func _hit_stop(speed: float) -> void:
	if stop_sound == &"" or speed < stop_min_speed:
		return
	var t := clampf(inverse_lerp(stop_min_speed, maxf(stop_full_speed, stop_min_speed + 0.001), speed), 0.0, 1.0)
	Audio.play_at(stop_sound, get_pivot_global(), lerpf(STOP_QUIET_DB, 0.0, t))

## Checkpoint snapshot: the dynamic state only (the pivot and rest pose come from the scene, the settings from the
## exports). Riders, loads and liquid are not saved: the player and blocks restore themselves, and liquid in flight
## isn't saved anywhere.
func save_state() -> Dictionary:
	return {"angle": _angle, "angular_velocity": _omega, "motor_dir": _motor_dir}

## Snaps to the saved angle with no animation or sound, and forgets everything derived from the old pose (grip
## anchors, load latches, the frame's loads and liquid torque) so nothing is dragged or latched across the jump. Runs
## from the scene root's `ready` signal, after every _ready() but before the deferred calls, so WaterManager may not
## have registered this body yet; if it has, its stored previous transform is reset so liquid isn't carried by the jump.
func load_state(d: Dictionary) -> void:
	_angle = float(d.get("angle", 0.0))
	_omega = float(d.get("angular_velocity", 0.0))
	_motor_dir = float(d.get("motor_dir", _motor_dir))
	if not free_rotation:
		var low := deg_to_rad(minf(min_angle_degrees, max_angle_degrees))
		var high := deg_to_rad(maxf(min_angle_degrees, max_angle_degrees))
		_angle = clampf(_angle, low, high)
	_angular_velocity = _omega
	_gripped.clear()
	_loads.clear()
	_load_ids.clear()
	_load_misses.clear()
	_launched_frame.clear()
	_net_torque = 0.0
	_liquid_torque = 0.0
	_steam_torque = 0.0
	_apply_angle()
	_teleport_physics_body()
	_reset_interpolation_tree(self)
	if _water_manager == null or not is_instance_valid(_water_manager):
		_water_manager = get_tree().get_first_node_in_group("water_manager")
	if _water_manager != null and _water_manager.has_method("forget_motion"):
		_water_manager.call("forget_motion", self)

## Puts the physics server's copy of the body at the node's current transform without the server seeing it as
## movement. A kinematic body's velocity is derived from how far its transform moved in a step, so a plain jump to the
## saved angle is a one-frame spike that flings whatever rests on the plank (the restored block slid off). Switching the
## body to static and straight back to kinematic makes the server take the next transform it is given directly
## (its "first kinematic transform" path), with no velocity. The node's own sync_to_physics push of the same transform
## then moves nothing.
func _teleport_physics_body() -> void:
	var rid := get_rid()
	PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_STATIC)
	PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_KINEMATIC)
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform)

## reset_physics_interpolation() only clears the node it is called on, and the art, skin, pivot marker and overlay
## are children, so each needs it or they blend from the old pose across the jump (the plank showed flat for a frame).
func _reset_interpolation_tree(node: Node) -> void:
	node.reset_physics_interpolation()
	for child in node.get_children():
		_reset_interpolation_tree(child)

# --- power (step 3.3) -------------------------------------------------------------------------------------

## Power contract (see power_target.gd): powered = the motor runs, unpowered = a free see-saw. With nothing wired
## to the PowerTarget child the motor just stays on, so `motor_torque` is the whole story.
func set_powered(on: bool) -> void:
	_motor_on = on

## The motor torque acting now, positive = clockwise: 0 when unpowered or `motor_torque` is 0, a steady
## `motor_torque` with `free_rotation`, otherwise its magnitude in the current direction (`_motor_dir`).
func get_motor_torque() -> float:
	if not _motor_on or motor_torque == 0.0:
		return 0.0
	if free_rotation:
		return motor_torque
	return absf(motor_torque) * _motor_dir

## Subclass hook: torque added to the loads, liquid and motor each step (same units as `inertia`: angular
## acceleration = torque / inertia), positive = clockwise. Called from _integrate_dynamics() before the body moves,
## so it sees last step's pose. Swing uses it for the pendulum's gravity and the rider's push.
func _get_extra_torque() -> float:
	return 0.0

## Subclass hook: false for a body with no shapes that nothing should rest on (Swing), so WaterManager never
## registers it as a solid.
func _joins_water_solid() -> bool:
	return true

## Subclass hook: false for a body the player must not ledge-grab (Swing has its own grab and no collider).
func _joins_ground() -> bool:
	return true

## Subclass hook: the angle just clamped at a stop. `speed` is the angular speed (rad/s, always >= 0) the body was
## turning into it with, 0 if it only pressed against it; `side` is +1 at the clockwise (max) stop and -1 at the
## counter-clockwise (min) one. Runs inside the dynamics step, after `_angle` is clamped and before the transform is
## applied (read the pose from `get_pose_global()`), and with `_loads` still last frame's scan. The see-saw's launch
## uses it. Never called with `free_rotation`, which has no stops.
func _stop_reached(_speed: float, _side: float) -> void:
	pass

## Whether the player may grab, or keep hanging from, this body right now (duck-typed, read by player.gd at the grab
## and every frame of the hang). Within `hang_max_tilt_degrees` of the rest pose and no faster than
## `hang_max_angular_speed`; `get_angular_velocity()` is the real step's change of angle, so a body resting against a
## stop reads 0. A free-rotation body's angle wraps, so its tilt is the wrapped distance from rest.
func is_hangable() -> bool:
	if not hangable or not _joins_ground():
		return false
	return absf(wrapf(_angle, -PI, PI)) <= deg_to_rad(hang_max_tilt_degrees) \
			and absf(_angular_velocity) <= hang_max_angular_speed

## One step of the rotation: torque -> angular velocity (damping, then friction) -> angle (then the stops).
func _integrate_dynamics(delta: float) -> void:
	_read_liquid_torque()
	var motor := get_motor_torque()
	var torque := _net_torque + _liquid_torque + _steam_torque + motor + _get_extra_torque()
	if not free_rotation and motor == 0.0:
		torque -= restoring_torque * _angle  # suspended while the motor runs: it would stop the swing short of the stops
	_drive_torque = torque
	var inv_inertia := 1.0 / maxf(inertia, 0.001)
	_omega += torque * inv_inertia * delta
	_omega -= _omega * minf(damping * delta, 1.0)
	_omega = move_toward(_omega, 0.0, friction_torque * inv_inertia * delta)  # opposes motion, stops at zero
	_angle += _omega * delta
	if not free_rotation:
		var low := deg_to_rad(minf(min_angle_degrees, max_angle_degrees))
		var high := deg_to_rad(maxf(min_angle_degrees, max_angle_degrees))
		if _angle >= high:
			_angle = high
			var arrival := maxf(_omega, 0.0)
			_hit_stop(arrival)
			_stop_reached(arrival, 1.0)
			_omega = minf(_omega, 0.0)  # into the stop: velocity dies, no bounce
			_motor_dir = -1.0  # the motor turns round at a stop
		elif _angle <= low:
			_angle = low
			var arrival := maxf(-_omega, 0.0)
			_hit_stop(arrival)
			_stop_reached(arrival, -1.0)
			_omega = maxf(_omega, 0.0)
			_motor_dir = 1.0

## Angular velocity in rad/s (positive = clockwise on screen), as of the last physics step. Same name as
## RigidBody2D's getter on purpose: MeltableBlock asks whatever floor it rests on for it, so a plank and a
## turning block are read the same way.
func get_angular_velocity() -> float:
	return _angular_velocity

## Rotation in radians relative to the rest pose (positive = clockwise on screen).
func get_angle() -> float:
	return _angle

## The pivot in world space (fixed; does not move as the body rotates).
func get_pivot_global() -> Vector2:
	var parent := get_parent() as Node2D
	return parent.to_global(_pivot_parent) if parent != null else _pivot_parent

## Net torque of everything on the body about the pivot, positive = clockwise on screen: the riders' loads plus the
## liquid resting on it and the steam pushing its underside (the dynamics add the motor and the spring).
func get_net_torque() -> float:
	return _net_torque + _liquid_torque + _steam_torque

## The riders' (player, blocks) share of get_net_torque().
func get_load_torque() -> float:
	return _net_torque

## The resting liquid's share of get_net_torque().
func get_liquid_torque() -> float:
	return _liquid_torque

## The steam's share of get_net_torque(): the smoothed upward push on the underside, already scaled by
## `steam_torque_scale` (negative lifts the right end, positive the left).
func get_steam_torque() -> float:
	return _steam_torque

## This frame's loads, one Dictionary each: `body` (the player or a MeltableBlock), `weight`, `offset` (its x minus the
## pivot's x, px), `torque` (weight x offset) and `position` (its world position). Includes loads stacked on blocks.
func get_loads() -> Array[Dictionary]:
	return _loads

## The body's global transform computed from `_angle`, never read from the node: `sync_to_physics` makes the node's
## transform catch up with a write only at the end of the physics step, so a read inside the step (the laser solver's,
## a rider's) would be one step behind. Same maths as `_apply_angle()`, composed with the parent's global transform.
func get_pose_global() -> Transform2D:
	var about_pivot := Transform2D(_angle, _pivot_parent - _pivot_parent.rotated(_angle))
	var in_parent := about_pivot * _rest_transform
	var parent := get_parent() as Node2D
	return parent.global_transform * in_parent if parent != null else in_parent

func _apply_angle() -> void:
	# Rotate the rest pose about the pivot: R(angle) around P, then the rest transform.
	var about_pivot := Transform2D(_angle, _pivot_parent - _pivot_parent.rotated(_angle))
	transform = about_pivot * _rest_transform

## Whether the body with this instance id was launched off the plank within the last `LOAD_LATCH_FRAMES` frames. Such a
## body is neither re-anchored by the grip nor kept as a load by the latch, so a launch is never undone or repeated.
func _launched_recently(id: int) -> bool:
	if not _launched_frame.has(id):
		return false
	if Engine.get_physics_frames() - int(_launched_frame[id]) > LOAD_LATCH_FRAMES:
		_launched_frame.erase(id)
		return false
	return true

## Pins standing-still riders to their anchors; must run after _apply_angle() so to_global() uses the new pose.
func _grip_riders() -> void:
	var riders := _find_riders()
	for r in _gripped.keys():
		if not is_instance_valid(r) or not riders.has(r):
			_gripped.erase(r)
	for rider in riders:
		if _launched_recently(rider.get_instance_id()):
			_gripped.erase(rider)  # just thrown: never pin it back onto the face
		elif absf(rider.velocity.x) > IDLE_SPEED:
			_gripped.erase(rider)  # moving under its own power: engine carry only, re-anchor when idle again
		elif _gripped.has(rider):
			var foot := Vector2(0.0, _foot_offset(rider))
			rider.global_position = to_global(_gripped[rider]) - foot
			# Settle onto the face along its normal (local +Y = into the face): keeps the foot's position along
			# the face, fixes only the gap/sink that the tilt changed.
			rider.move_and_collide(global_transform.basis_xform(Vector2(0.0, SNAP_TO_FACE)))
		else:
			_gripped[rider] = to_local(rider.global_position + Vector2(0.0, _foot_offset(rider)))

## Actors standing on this body: a thin band above each collision shape finds candidates, then each is checked
## to be on the floor with this body as the thing directly beneath it. Only `CharacterBody2D`s count: a
## `MeltableBlock` is a `RigidBody2D`, so the `as CharacterBody2D` cast below leaves it out on purpose (the engine
## carries it by contact, and a gripped body would fight the solver).
func _find_riders() -> Array[CharacterBody2D]:
	var found: Array[CharacterBody2D] = []
	var space := get_world_2d().direct_space_state
	var band_up := global_transform.basis_xform(Vector2(0.0, -RIDER_BAND))
	var params := PhysicsShapeQueryParameters2D.new()
	params.collision_mask = RIDER_MASK
	params.exclude = [get_rid()]
	for child in get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		params.shape = cs.shape
		params.transform = cs.global_transform.translated(band_up)
		for hit in space.intersect_shape(params, 16):
			var body := hit["collider"] as CharacterBody2D
			if body != null and not found.has(body) and _is_riding(body):
				found.append(body)
	return found

func _is_riding(body: PhysicsBody2D) -> bool:
	# Probe 2px into the face (local +Y): what a resting rider would hit first must be this body.
	return _is_resting_on(body, self, global_transform.basis_xform(Vector2(0.0, 2.0)))

## True if `body` is resting on `support`: for an actor on the floor and not hanging (a hang skips move_and_slide(),
## so is_on_floor() is stale), and in every case a short probe of `body` along `into` (a few px toward the support)
## reaches `support`: a test_move() that must hit it first for actors, an overlap query for rigid blocks.
func _is_resting_on(body: PhysicsBody2D, support: PhysicsBody2D, into: Vector2) -> bool:
	var character := body as CharacterBody2D
	if character != null and not character.is_on_floor():
		return false
	if "is_hanging" in body and body.is_hanging:
		return false
	if body is RigidBody2D:
		return _rigid_overlaps_support(body, support, into)
	var col := KinematicCollision2D.new()
	return body.test_move(body.global_transform, into, col) and col.get_collider() == support

## Resting test for a rigid block: its own shapes, nudged `into` (a few px toward the support), must overlap the
## support. An overlap query rather than test_move() because a block's mask includes layer 1: with a player
## standing on it, test_move()'s probe can report the player (overlapping its top face) as what it hit, failing the
## test for as long as the player stays there. Here only whether the support is among the overlaps matters.
func _rigid_overlaps_support(body: PhysicsBody2D, support: PhysicsBody2D, into: Vector2) -> bool:
	var params := PhysicsShapeQueryParameters2D.new()
	params.collision_mask = support.collision_layer
	params.exclude = [body.get_rid()]
	var space := get_world_2d().direct_space_state
	for child in body.get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		params.shape = cs.shape
		params.transform = cs.global_transform.translated(into)
		for hit in space.intersect_shape(params, 8):
			if hit["collider"] == support:
				return true
	return false

## How far below the rider's origin the lowest point of its (upright) collider is, in world pixels. Reads the
## rider's enabled CollisionShape2D children (rectangle, capsule, circle); a rotated collider or an unknown
## shape type is ignored, and with none usable the result is 0 (anchor = origin).
func _foot_offset(body: CharacterBody2D) -> float:
	var lowest := 0.0
	var found := false
	for child in body.get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		if absf(sin(cs.global_rotation)) > 0.01:
			continue
		var half := 0.0
		if cs.shape is RectangleShape2D:
			half = (cs.shape as RectangleShape2D).size.y * 0.5
		elif cs.shape is CapsuleShape2D:
			half = (cs.shape as CapsuleShape2D).height * 0.5
		elif cs.shape is CircleShape2D:
			half = (cs.shape as CircleShape2D).radius
		else:
			continue
		var bottom := cs.global_position.y - body.global_position.y + half * absf(cs.global_scale.y)
		if not found or bottom > lowest:
			lowest = bottom
			found = true
	return lowest

# --- load scan (step 1.2) ---------------------------------------------------------------------------------

## Rebuilds `_loads` and `_net_torque` from what stands on the body now. Runs after _apply_angle(), so the band
## follows this frame's pose.
func _update_loads() -> void:
	_load_ids.clear()
	for entry in _loads:
		_load_ids[entry["id"]] = true  # the stored id, not entry["body"]: last frame's load may have been freed since (a melted block)
	_loads.clear()
	var seen := {}
	var params := PhysicsShapeQueryParameters2D.new()
	params.collision_mask = RIDER_MASK
	params.exclude = [get_rid()]
	var band_up := global_transform.basis_xform(Vector2(0.0, -RIDER_BAND))
	var into := global_transform.basis_xform(Vector2(0.0, 2.0))
	var space := get_world_2d().direct_space_state
	for child in get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		params.shape = cs.shape
		params.transform = cs.global_transform.translated(band_up)
		for hit in space.intersect_shape(params, 16):
			_consider_load(hit["collider"], self, into, seen, 0)
	_net_torque = 0.0
	for entry in _loads:
		_net_torque += entry["torque"]
	for id in _load_misses.keys():
		if not seen.has(id):
			_load_misses.erase(id)

## Adds `candidate` to the loads if it has weight and is resting on `support`, then looks for what rests on it
## if it is a block (a player standing on a block on the plank loads the plank too).
func _consider_load(candidate: Object, support: PhysicsBody2D, into: Vector2, seen: Dictionary, depth: int) -> void:
	var body := candidate as PhysicsBody2D
	if body == null or seen.has(body.get_instance_id()):
		return
	var weight := _weight_of(body)
	if weight <= 0.0:
		return
	var id := body.get_instance_id()
	if not _is_resting_on(body, support, into):
		# The test is a single test_move() and is fragile for a body that is also touching something else (a player
		# standing on a block on the plank: the probe can report the player, or a block pressed in and out of the
		# face by the solver misses the 2px reach for a frame). A load that counted last frame and is still in the
		# band over the face keeps counting for a few frames, so the torque doesn't drop to zero and back.
		if _launched_recently(id):
			return  # it left because it was launched, not because of a contact glitch: no latch
		var misses: int = _load_misses.get(id, 0)
		if debug_loads:
			print("%s: %s failed the resting test on %s (miss %d, was load: %s)" % [name, body.name, support.name, misses, _load_ids.has(id)])
		if not _load_ids.has(id) or misses >= LOAD_LATCH_FRAMES:
			return
		_load_misses[id] = misses + 1
	else:
		_load_misses.erase(id)
	seen[id] = true
	var offset := body.global_position.x - get_pivot_global().x
	_loads.append({"body": body, "id": id, "weight": weight, "offset": offset, "torque": weight * offset, "position": body.global_position})
	if depth < MAX_STACK_DEPTH and _carries_stack(body):
		_collect_on_top_of(body, seen, depth + 1)

## Things standing on a block that is itself a load: a band above each of its shapes, straight up in world space.
func _collect_on_top_of(block: PhysicsBody2D, seen: Dictionary, depth: int) -> void:
	var params := PhysicsShapeQueryParameters2D.new()
	params.collision_mask = RIDER_MASK
	params.exclude = [get_rid(), block.get_rid()]
	var space := get_world_2d().direct_space_state
	for child in block.get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		params.shape = cs.shape
		params.transform = cs.global_transform.translated(Vector2(0.0, -RIDER_BAND))
		for hit in space.intersect_shape(params, 16):
			_consider_load(hit["collider"], block, Vector2(0.0, 2.0), seen, depth)

## Weight in block-mass units: a MeltableBlock's `mass`, the player's `player_weight`, an enemy's
## `get_load_weight()` times `enemy_weight_scale`, nothing else.
func _weight_of(body: PhysicsBody2D) -> float:
	if body is MeltableBlock:
		return (body as MeltableBlock).mass
	if body.is_in_group(&"player"):
		return player_weight
	if enemy_weight_scale > 0.0 and body.is_in_group(&"enemy") and body.has_method(&"get_load_weight"):
		return float(body.call(&"get_load_weight")) * enemy_weight_scale
	return 0.0

## Whether what rests on `body` is counted too: a rigid block, or an enemy that has weight here.
func _carries_stack(body: PhysicsBody2D) -> bool:
	return body is RigidBody2D or (enemy_weight_scale > 0.0 and body.is_in_group(&"enemy") and body.has_method(&"get_load_weight"))

# --- debug drawing ----------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or debug_toggle_key == KEY_NONE:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == debug_toggle_key:
		debug_draw = not debug_draw

## The pivot for drawing: in the editor the physics state isn't set up, so read the Fulcrum node directly.
func _pivot_for_drawing() -> Vector2:
	var fulcrum := get_node_or_null("Fulcrum") as Node2D
	if Engine.is_editor_hint():
		return fulcrum.global_position if fulcrum != null else global_position
	return get_pivot_global()

func _update_debug_overlay() -> void:
	if not is_inside_tree():
		return  # the setter runs while the scene loads; _ready() calls this again
	if debug_draw and _overlay == null:
		_overlay = TorqueOverlay.new()
		_overlay.body = self
		add_child(_overlay)  # no owner, so it is never saved into a scene
	elif not debug_draw and _overlay != null:
		_overlay.queue_free()
		_overlay = null

## World-space drawing of the pivot, the loads and the net torque. A top-level child, so the body's own rotation
## doesn't carry the drawing round with it.
class TorqueOverlay extends Node2D:
	const CLOCKWISE := Color(1.0, 0.6, 0.2)
	const COUNTER := Color(0.4, 0.75, 1.0)
	const FONT_SIZE := 6

	var body: RotatingBody

	func _init() -> void:
		name = "TorqueOverlay"
		top_level = true
		z_index = 200
		z_as_relative = false

	func _process(_delta: float) -> void:
		if Engine.is_editor_hint():
			queue_redraw()  # follow the Fulcrum as it is dragged; at runtime the body redraws us each physics frame

	func _draw() -> void:
		if body == null:
			return
		var font := ThemeDB.fallback_font
		var pivot := body._pivot_for_drawing()
		draw_circle(pivot, 2.0, Color(1, 1, 1, 0.9))
		draw_line(pivot + Vector2(-5, 0), pivot + Vector2(5, 0), Color(1, 1, 1, 0.9), 1.0)
		draw_line(pivot + Vector2(0, -5), pivot + Vector2(0, 5), Color(1, 1, 1, 0.9), 1.0)
		if Engine.is_editor_hint():
			draw_string(font, pivot + Vector2(6, -4), "pivot", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(1, 1, 1, 0.9))
			return
		var loads := body.get_loads()
		for i in loads.size():
			var entry: Dictionary = loads[i]
			var at: Vector2 = entry["position"]
			var torque: float = entry["torque"]
			var color := CLOCKWISE if torque >= 0.0 else COUNTER
			var lever_y := pivot.y - 20.0 - 7.0 * (i % 4)  # staggered so neighbouring labels don't overlap
			draw_line(Vector2(pivot.x, lever_y), Vector2(at.x, lever_y), color, 1.0)  # the lever arm
			draw_line(Vector2(at.x, lever_y), at, Color(color, 0.5), 1.0)
			draw_circle(at, 1.5, color)
			draw_string(font, Vector2(at.x + 2.0, lever_y - 1.0), "w%.1f  T%+.0f" % [entry["weight"], torque], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
		var net := body.get_net_torque()
		var net_color := CLOCKWISE if net >= 0.0 else COUNTER
		var radius := 14.0
		var sweep := clampf(net / maxf(body.debug_full_arc_torque, 0.001), -1.0, 1.0) * PI
		if absf(sweep) > 0.02:
			var start := -PI * 0.5
			var end := start + sweep
			draw_arc(pivot, radius, start, end, 24, net_color, 1.5)
			var tip := pivot + Vector2.from_angle(end) * radius
			var forward := Vector2.from_angle(end + signf(sweep) * PI * 0.5)  # the way the arc is travelling at its tip
			var outward := Vector2.from_angle(end)
			draw_line(tip, tip - forward * 3.5 + outward * 2.5, net_color, 1.5)
			draw_line(tip, tip - forward * 3.5 - outward * 2.5, net_color, 1.5)
		draw_string(font, pivot + Vector2(-18.0, radius + 9.0), "net T%+.0f  %+.1f deg" % [net, rad_to_deg(body.get_angle())], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, net_color)
		var liquid := body.get_liquid_torque()
		if absf(liquid) > 0.05:  # the resting liquid's share of the net, on its own line
			var liquid_color := CLOCKWISE if liquid >= 0.0 else COUNTER
			draw_string(font, pivot + Vector2(-18.0, radius + 16.0), "liquid T%+.0f  (loads T%+.0f)" % [liquid, body.get_load_torque()], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, liquid_color)
		var steam := body.get_steam_torque()
		if absf(steam) > 0.05:  # the steam's share of the net, on its own line
			draw_string(font, pivot + Vector2(-18.0, radius + 30.0), "steam T%+.0f" % steam, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, CLOCKWISE if steam >= 0.0 else COUNTER)
		var motor := body.get_motor_torque()
		if motor != 0.0:
			draw_string(font, pivot + Vector2(-18.0, radius + 23.0), "motor T%+.0f" % motor, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, CLOCKWISE if motor >= 0.0 else COUNTER)
