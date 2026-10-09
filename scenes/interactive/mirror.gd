@tool
extends StaticBody2D
## Rotating laser mirror. A thin solid plate (blocks the player like any other ground) whose FRONT
## face reflects lasers; the back and edges are opaque (so is a beam running parallel to the plate; see
## scripts/laser_beam.gd). The plate sits at the node's rotation PLUS `base_angle_degrees`, the angle of the
## art when the node is unrotated: -45 matches mirror2.png, a diagonal "/" whose front (the bright face)
## looks up and to the left. With base 0 the plate is horizontal and the front is local -Y (up). Rotate the
## instance in the editor to set its starting angle, which is step index 0; kicks and power turn it from there.
##
## Rotation: each kick turns it one step (`rotation_step_degrees`) in `rotate_direction`. The kick
## reaches it through the existing duck-typed contract — player.gd's KickHitbox calls
## take_damage(amount) on any body it touches — so nothing on the player changed. KickHitbox's mask
## is the default (layer 1 only), so this body sits on layers 1 AND 2: layer 2 keeps it solid/
## world-like for the player and enemies, layer 1 is what lets the kick see it.
##
## Bullets: with `bullet_rotates` on, a cannon bullet that hits the plate turns it one step (the bullet is
## consumed, through Bullet's `on_bullet_hit()` contract). Off by default, so bullets fly through a mirror
## as they always did. Like a kick, a hit that arrives mid-turn is dropped.
##
## Power (see power_target.gd): each RISING EDGE of the power state turns it one step (`rotate_step(1)`);
## falling edges do nothing, the startup state is not an edge, and an edge that arrives mid-turn is
## ignored like a kick. `invert` (read by the PowerTarget child) makes the falling edge of the wire the
## turn. Turn `kick_rotates` off on an instance a switch owns so kicks no longer turn it. It can also be
## driven directly with rotate_step(steps) / rotate_to_step(index).
##
## The beam solver reads this node through get_laser_segment()/get_laser_normal() (see
## scripts/laser_beam.gd) using the LIVE rotation, so a beam visibly sweeps while the mirror turns.
##
## Expected scene layout:
##   Mirror (StaticBody2D, this script, layer 1|2)
##     - CollisionShape2D  (thin RectangleShape2D; resized from plate_length in the editor)
##
## Art: assign `texture` (a single image centred on the node, rotating with it; the current art is the 16x16
## mirror2.png, face through its centre) and it is drawn instead of the vector placeholder. With no texture the
## placeholder is drawn in code (draw_placeholder = false to hide it). `plate_length` is the reflective face's
## length (14 for mirror2.png: 10 px of staircase along each axis); the collision plate is that long and 3 px thick,
## centred on the node, at the same angle as the face, so it is a thin plate on the face, not the whole triangle.

@export var plate_length: float = 14.0: ## Length of the reflective face (and its collider).
	set(value):
		plate_length = value
		_sync_shape()
		queue_redraw()
@export var base_angle_degrees: float = -45.0: ## Angle of the plate relative to the node's rotation; -45 = the diagonal art.
	set(value):
		base_angle_degrees = value
		_sync_shape()
		queue_redraw()
@export var texture: Texture2D:
	set(value):
		texture = value
		queue_redraw()
@export var rotation_step_degrees: float = 45.0
@export_enum("Clockwise:1", "Counter-clockwise:-1") var rotate_direction: int = 1
@export var rotate_time: float = 0.15 ## Seconds one step takes.
@export var kick_rotates: bool = true ## Turn off when a switch owns this mirror.
@export var bullet_rotates: bool = false ## A cannon bullet hitting the plate turns it one step (and is consumed).
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
@export var draw_placeholder: bool = true

const PLATE_THICKNESS := 3.0

var _target_rotation: float = 0.0
var _placed_rotation: float = 0.0  # rotation as placed in the editor = step index 0
var _tween: Tween
var _last_power: bool = false

func _ready() -> void:
	_sync_shape()
	queue_redraw()
	if Engine.is_editor_hint():
		return
	add_to_group(&"laser_mirror")
	add_to_group(&"saveable")
	_target_rotation = rotation
	_placed_rotation = rotation

## Saveable contract (see game.gd). The angle is stored as the accumulated target rotation; the placed angle
## (step index 0) always comes from the scene. A mirror caught mid-turn comes back at the end of that turn.
func save_state() -> Dictionary:
	return {"rotation": _target_rotation, "last_power": _last_power}

func load_state(d: Dictionary) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_target_rotation = d.get("rotation", _target_rotation)
	rotation = _target_rotation
	_last_power = d.get("last_power", _last_power)
	reset_physics_interpolation()

func is_rotating() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()

# --- laser contract (read by LaserBeam) ---------------------------------------------------------

func get_laser_segment() -> PackedVector2Array:
	var half := Vector2.RIGHT.rotated(global_rotation + deg_to_rad(base_angle_degrees)) * (plate_length * 0.5)
	return PackedVector2Array([global_position - half, global_position + half])

func get_laser_normal() -> Vector2:
	return Vector2.UP.rotated(global_rotation + deg_to_rad(base_angle_degrees))

# --- power ---------------------------------------------------------------------------------------

## Startup state: remembered, never an edge.
func set_powered_initial(on: bool) -> void:
	_last_power = on

## One step per rising edge.
func set_powered(on: bool) -> void:
	var rising := on and not _last_power
	_last_power = on
	if rising:
		rotate_step(1)

# --- rotation ------------------------------------------------------------------------------------

## Kick contract (player.gd: `if body.has_method("take_damage"): body.take_damage(KICK_DAMAGE)`).
## Returns 0 — enemies return points from this method; a mirror is worth none.
func take_damage(_amount: int = 1) -> int:
	if kick_rotates:
		rotate_step(1)
	return 0

## Bullet contract (bullet.gd): one step per bullet, and the bullet is consumed. With `bullet_rotates` off it
## returns false and the bullet flies on through, as before. A hit during a turn still consumes the bullet
## but turns nothing (stacked controllers can drop a step; see rotate_step()).
func on_bullet_hit(_point: Vector2, _direction: Vector2) -> bool:
	if not bullet_rotates:
		return false
	rotate_step(1)
	return true

## Turn `steps` steps in rotate_direction (negative steps reverse). Ignored mid-turn so mashing
## kick can't queue up a spin. Returns whether it started turning.
func rotate_step(steps: int = 1) -> bool:
	if is_rotating():
		return false
	_target_rotation += deg_to_rad(rotation_step_degrees) * steps * rotate_direction
	_turn_to(_target_rotation)
	return true

## Absolute version for switches: step index 0 is the angle the mirror was placed at.
func rotate_to_step(index: int) -> bool:
	if is_rotating():
		return false
	_target_rotation = _placed_rotation + deg_to_rad(rotation_step_degrees) * index * rotate_direction
	_turn_to(_target_rotation)
	return true

func _turn_to(target: float) -> void:
	Audio.play_at(&"interactive/mirror_rotate", global_position)
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)  # in step with the beam solve
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "rotation", target, rotate_time)

# --- editor / drawing ----------------------------------------------------------------------------

func _sync_shape() -> void:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var rect := shape_node.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape_node.shape = rect
	rect.size = Vector2(plate_length, PLATE_THICKNESS)
	shape_node.rotation = deg_to_rad(base_angle_degrees)  # the collider follows the plate, not the node

func _draw() -> void:
	if texture != null:
		draw_texture(texture, -texture.get_size() * 0.5)
	elif draw_placeholder:
		# plate frame: rotated by the base angle, front (bright) is local -Y within it
		draw_set_transform(Vector2.ZERO, deg_to_rad(base_angle_degrees))
		var half := plate_length * 0.5
		draw_rect(Rect2(-half, -PLATE_THICKNESS * 0.5, plate_length, PLATE_THICKNESS), Color(0.22, 0.24, 0.3))
		draw_line(Vector2(-half, -PLATE_THICKNESS * 0.5), Vector2(half, -PLATE_THICKNESS * 0.5), Color(0.75, 0.9, 1.0), 1.0)
		draw_circle(Vector2.ZERO, 1.5, Color(0.5, 0.55, 0.65))
		draw_set_transform(Vector2.ZERO, 0.0)
	if Engine.is_editor_hint():
		# front-face marker (editor only), along the plate's real front normal
		draw_line(Vector2.ZERO, Vector2.UP.rotated(deg_to_rad(base_angle_degrees)) * 10.0, Color(0.75, 0.9, 1.0, 0.5), 1.0)
