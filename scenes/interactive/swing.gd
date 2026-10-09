@tool
class_name Swing
extends RotatingBody

# Trapeze / swing: a rigid rod hanging from the Fulcrum with a bar at the Grip. A RotatingBody whose torque is a
# pendulum's gravity instead of loads: every step `_get_extra_torque()` adds
#     angular acceleration = gravity * r.x / |r|^2       (r = Grip - pivot, so |r| is the rod length)
# which is -(g / L) * sin(angle from straight down) for a bar below the pivot, whatever pose the scene was authored
# in. The bar is not solid (no collision shapes, layer 0): the only thing that interacts with it is the player's grab.
#
# Pose reads: `sync_to_physics` means this node's own transform (and its children's) lags a write by the rest of the
# step, so anything that needs the bar's position inside a physics step (the torque, the rider's pin, the grab test)
# gets it from `get_grip_global()`, which is computed from the angle. Don't read the Grip node's global position there.
#
# The rider: the player grabs the bar through `Player._try_grab_swing()` (airborne, hand within `grab_radius` of the
# Grip) and calls `attach_rider()`. From then on THIS node pins the player's hand to the Grip after it has moved
# itself each step (`_physics_process()` below runs at priority 100, after the player), so the hang is never a frame
# behind the bar. The player feeds back its left/right input through `set_push()` every frame it hangs, and lets go
# through `detach_rider()`, taking `get_velocity_at()` (the tangential velocity at its body) with it.
#
# Length: `length_tiles` sets the rod length; the Grip is placed that far from the Fulcrum on every load (see
# `_apply_length()`). Catching: `catch_momentum()` turns the velocity the player arrives with into angular velocity.
#
# Push: holding left/right accelerates the rider toward that side by `push_accel` rad/s^2 (a constant tangential
# push, not a horizontal force, so it doesn't weaken at wide angles). Pushing along the current motion tapers off to
# nothing as the angular speed approaches `max_pump_speed`, so pumping builds a big swing but stops short of the
# angle limits; pushing against the motion brakes at full strength.
#
# Nothing here knows about collision: a hanging player is pinned (no move_and_slide(), like every hang), so the arc
# between the angle limits must be clear of solid tiles. The editor draws the arc and the grab radius (SwingArt).

const GRIP_NODE := "Grip"
const TILE := 16.0

@export_group("Swing")
## Length of the rod (the string) from the Fulcrum to the Grip, in 16px tiles. The Grip is moved along its authored
## direction from the Fulcrum (straight down if it sits on it) and re-placed on every load, so edit this, not the
## Grip's position. The arc, the pendulum period (2π√(L/g)) and the editor preview all follow.
@export_range(0.5, 32.0, 0.5, "suffix:tiles") var length_tiles: float = 4.0:
	set(value):
		length_tiles = value
		_apply_length()
## How much of the player's velocity along the arc is handed to the swing when it grabs the bar: 1 = the swing takes
## the player's tangential speed outright (as if the rod were weightless), 0 = the swing keeps its own motion.
@export_range(0.0, 1.0, 0.05) var catch_transfer: float = 1.0
## Pendulum gravity, px/s^2. Matches the player's `gravity`; change it only to make one swing feel floaty or heavy.
@export var gravity: float = 900.0
## Angular acceleration (rad/s^2) the rider adds by holding left/right. Torque is `push_accel * inertia`.
@export var push_accel: float = 3.0
## Angular speed (rad/s) at which pushing along the motion has no effect any more. The swing's top speed from
## pumping is about `max_pump_speed * rod length` px/s at the bottom of the arc.
@export var max_pump_speed: float = 4.0
## Distance (px) from the Grip within which the player's hand grabs the bar.
@export var grab_radius: float = 10.0
@export_group("")

var _grip: Node2D
var _rider  # the Player hanging from this swing, or null (untyped: it is reached by duck typing, see the rider contract)
var _push: float = 0.0  # -1..1, the rider's left/right input this frame

func _ready() -> void:
	_grip = get_node_or_null(GRIP_NODE) as Node2D
	_apply_length()  # before the base class reads the Fulcrum and the rest pose
	super()
	if Engine.is_editor_hint():
		return
	add_to_group(&"swing")  # Player._try_grab_swing() looks the swings up by group
	if _grip == null:
		push_warning("%s: no Grip child, the swing can't be grabbed." % name)

## Places the Grip `length_tiles` from the Fulcrum along its current direction. Changes to a non-editable child aren't
## saved with the level, so this runs on every load as well as when the export changes.
func _apply_length() -> void:
	if not is_inside_tree():
		return  # the setter runs while the scene loads; _ready() calls this again
	var grip := get_node_or_null(GRIP_NODE) as Node2D
	var fulcrum := get_node_or_null("Fulcrum") as Node2D
	if grip == null or fulcrum == null:
		return
	var along := grip.position - fulcrum.position
	along = Vector2.DOWN if along.length() < 0.001 else along.normalized()
	grip.position = fulcrum.position + along * length_tiles * TILE

func _joins_water_solid() -> bool:
	return false  # no shapes: nothing for liquid to land on

func _joins_ground() -> bool:
	return false  # no collider and its own grab: never ledge-hangable

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var fulcrum := get_node_or_null("Fulcrum") as Node2D
	var grip := get_node_or_null(GRIP_NODE) as Node2D
	if fulcrum == null:
		warnings.append("Add a Marker2D child named Fulcrum at the pivot (the rod's top end).")
	if grip == null:
		warnings.append("Add a Marker2D child named Grip where the bar is (the rod's bottom end, directly below the Fulcrum at rest).")
	elif fulcrum != null and fulcrum.position.distance_to(grip.position) < 0.001:
		warnings.append("The Grip is exactly on the Fulcrum, so the rod points straight down; move it to choose another direction.")
	return warnings

func _physics_process(delta: float) -> void:
	super(delta)
	if _rider == null:
		return
	if not is_instance_valid(_rider) or not _rider.is_hanging or _rider.hang_swing != self:
		_rider = null  # freed, or let go / knocked off without telling us (another system cleared is_hanging)
		_push = 0.0
		return
	_rider.pin_to_swing(get_grip_global())  # after _apply_angle() above: the hand is on this step's bar

## Pendulum gravity plus the rider's push, as torque (angular acceleration x inertia), clockwise positive.
func _get_extra_torque() -> float:
	if _grip == null:
		return 0.0
	var r := get_grip_global() - get_pivot_global()
	var r_squared := r.length_squared()
	if r_squared < 1.0:
		return 0.0
	var accel := gravity * r.x / r_squared
	if _rider != null and _push != 0.0:
		# Right pushes a hanging rider counter-clockwise (the bar below the pivot swings toward +x as the angle falls),
		# and the other way round if the bar is above the pivot (a free-rotation swing that has gone over the top).
		var push := -_push * push_accel * (1.0 if r.y >= 0.0 else -1.0)
		if push * _omega > 0.0:
			push *= clampf(1.0 - absf(_omega) / maxf(max_pump_speed, 0.001), 0.0, 1.0)
		accel += push
	return accel * inertia

# --- the rider contract (called by player.gd) ---------------------------------------------------------------

## The bar's grab point in world space, for the current `_angle`. Computed from the angle rather than read off the Grip
## node: the body has `sync_to_physics` on, so its node transform only catches up with a write at the end of the physics
## step, and a read inside the step (this swing's own, or the player's) would be one step behind the bar.
func get_grip_global() -> Vector2:
	if _grip == null:
		return global_position
	var rest := _rest_transform * _grip.position  # parent space, at the rest pose
	var in_parent := _pivot_parent + (rest - _pivot_parent).rotated(_angle)
	var parent := get_parent() as Node2D
	return parent.to_global(in_parent) if parent != null else in_parent

## Velocity of a point rigidly attached to the swing, px/s, from the angular velocity of the last step (0 against a
## stop). For a point on the rod this is tangential to the arc; the player takes it with it when it lets go.
func get_velocity_at(world_point: Vector2) -> Vector2:
	var r := world_point - get_pivot_global()
	return Vector2(-r.y, r.x) * _angular_velocity

func attach_rider(rider: Node) -> void:
	_rider = rider
	_push = 0.0

## The player has just grabbed the bar moving at `velocity` (px/s): the part along the arc becomes angular velocity.
## Point mass on a rigid rod: omega = (r x v) / |r|^2 with r from the pivot to the bar (clockwise positive, like the
## angle). The radial part is absorbed by the rod. Blended with the swing's own omega by `catch_transfer`; the angle
## limits still apply on the next step.
func catch_momentum(velocity: Vector2) -> void:
	var r := get_grip_global() - get_pivot_global()
	var r_squared := r.length_squared()
	if r_squared < 1.0:
		return
	var caught := (r.x * velocity.y - r.y * velocity.x) / r_squared
	_omega = lerpf(_omega, caught, catch_transfer)
	_angular_velocity = _omega  # so get_velocity_at() is right the instant the player lets go again

func detach_rider(rider: Node) -> void:
	if _rider == rider:
		_rider = null
		_push = 0.0

## The rider's left/right input, -1..1 (right = +1). Call every physics frame while hanging.
func set_push(direction: float) -> void:
	_push = clampf(direction, -1.0, 1.0)
