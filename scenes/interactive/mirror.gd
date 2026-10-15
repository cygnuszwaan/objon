@tool
extends StaticBody2D
## Rotating laser mirror on a cradle. The node's own transform orients the CRADLE (the static mount, drawn by this
## node: rotate or flip the instance to put the mount on a floor, wall or ceiling, or let a moving platform carry
## it). The mirror itself is the child `Plate`, which turns on its own: `plate_angle`, in radians, is its angle
## relative to the cradle, so turning the instance never changes what the mirror does, and every angle below
## (`initial_angle_degrees`, the aims) is relative to the cradle. A thin solid plate (blocks the player like any
## other ground) whose FRONT face reflects lasers; the back and edges are opaque (so is a beam running parallel to
## the plate; see scripts/laser_beam.gd). The plate sits at the node's rotation PLUS `plate_angle` PLUS
## `base_angle_degrees`, the angle of the art at plate angle 0: -45 matches mirror2.png, a diagonal "/" whose
## front (the bright face) looks up and to the left. With base 0 and plate angle 0 the plate is horizontal and the
## front is local -Y (up). `initial_angle_degrees` sets the starting angle in step mode, which is step index 0;
## kicks and power turn it from there.
##
## Control mode (`toggle_between_aims`, one checkbox per instance; the Inspector shows only the fields of
## the mode that is selected, and a hidden field keeps its value):
##   Off (default), STEP mode: each kick turns it one step (`rotation_step_degrees`) in `rotate_direction`,
##     and so does each RISING EDGE of power. `initial_angle_degrees` is step index 0.
##   On, TOGGLE mode: the mirror has two authored aims, `aim_0_degrees` (unpowered) and `aim_1_degrees`
##     (powered), written as plate angles in degrees relative to the cradle. Power
##     follows the LEVEL, not the edge: it swings to aim 1 when powered and back to aim 0 when not. It
##     sweeps the numeric way from one aim to the other (aim 0 = 0, aim 1 = 270 sweeps 270 degrees; use
##     -90 for the short way). A kick or a bullet flips it to the other aim.
##
## Kicks reach it through the existing duck-typed contract — player.gd's KickHitbox calls
## take_damage(amount) on any body it touches — so nothing on the player changed. KickHitbox's mask
## is the default (layer 1 only), so this body sits on layers 1 AND 2: layer 2 keeps it solid/
## world-like for the player and enemies, layer 1 is what lets the kick see it.
##
## Bullets: with `bullet_rotates` on, a cannon bullet that hits the plate turns it one step, or flips
## it in toggle mode (the bullet is consumed, through Bullet's `on_bullet_hit()` contract). Off by default,
## so bullets fly through a mirror as they always did. Like a kick, a hit that arrives mid-turn is dropped.
##
## Power (see power_target.gd): the startup state is never an edge and, in toggle mode, snaps to its aim
## with no turn and no sound. In step mode a rising edge turns one step and an edge that arrives mid-turn is
## ignored like a kick. In toggle mode a power change that arrives mid-turn is NOT dropped: the mirror
## turns back from where it is, so it always ends on the aim the power state names. `invert` (read by the
## PowerTarget child) flips the state the mirror sees. Turn `kick_rotates` off on an instance a switch owns
## so kicks no longer turn it. It can also be driven directly with rotate_step(steps) / rotate_to_step(index),
## and in toggle mode with toggle_aim() / rotate_to_aim(index).
##
## The beam solver reads this node through get_laser_segment()/get_laser_normal() (see
## scripts/laser_beam.gd) using the LIVE rotation, so a beam visibly sweeps while the mirror turns.
##
## Expected scene layout:
##   Mirror (StaticBody2D, this script, layer 1|2; the cradle is drawn by this node)
##     - CollisionShape2D  (thin RectangleShape2D; resized from plate_length, turned with the plate)
##     - Plate             (Node2D; turned with the plate; the mirror art, aim preview and pivot pin are drawn on it)
##     - PowerTarget
##
## Art: assign `texture` (a single image centred on the pivot, turning with the plate; the current art is the 16x16
## mirror2.png, face through its centre) and it is drawn instead of the vector placeholder. With no texture the
## placeholder is drawn in code (draw_placeholder = false to hide it). The cradle is a placeholder drawn in code
## too (a U-shaped yoke around the pivot on a foot pointing local +Y); assign `cradle_texture` (centred on the
## pivot, foot down at rotation 0) to replace it, or turn `show_cradle` off to hide it. The cradle draws behind the
## plate; `cradle_in_front` draws it over the plate instead (the plate child gets `show_behind_parent`). `plate_length` is the reflective face's
## length (14 for mirror2.png: 10 px of staircase along each axis); the collision plate is that long and 3 px thick,
## centred on the node, at the same angle as the face, so it is a thin plate on the face, not the whole triangle.

@export var plate_length: float = 14.0: ## Length of the reflective face (and its collider).
	set(value):
		plate_length = value
		_sync_shape()
		queue_redraw()
@export var base_angle_degrees: float = -45.0: ## Angle of the art's plate at plate angle 0; -45 = the diagonal art.
	set(value):
		base_angle_degrees = value
		_sync_shape()
		_redraw_all()
@export var initial_angle_degrees: float = 0.0: ## Step mode: the plate's angle on its cradle at step index 0 and at startup. Relative to the cradle, so rotating the instance doesn't change it. Toggle mode starts at aim 0 instead.
	set(value):
		initial_angle_degrees = value
		_refresh_authored_pose()
@export var texture: Texture2D: ## The mirror art, centred on the pivot and turning with the plate.
	set(value):
		texture = value
		_redraw_all()
@export var cradle_texture: Texture2D: ## Cradle art, centred on the pivot with its foot down (local +Y) at rotation 0; drawn instead of the placeholder cradle.
	set(value):
		cradle_texture = value
		queue_redraw()
@export var cradle_in_front: bool = false: ## Draw the cradle over the plate instead of behind it (the pivot pin is then left out).
	set(value):
		cradle_in_front = value
		_sync_draw_order()
		_redraw_all()
@export var show_cradle: bool = true: ## Draw the cradle (the placeholder, or `cradle_texture`).
	set(value):
		show_cradle = value
		_redraw_all()
@export var toggle_between_aims: bool = false: ## Off: kicks and power rising edges turn it one step. On: power swings it between aim 0 and aim 1.
	set(value):
		toggle_between_aims = value
		notify_property_list_changed()  # re-runs _validate_property(): shows the fields of the selected mode
		_refresh_authored_pose()
		if is_node_ready():
			update_configuration_warnings()
@export var aim_0_degrees: float = 0.0: ## Toggle mode: the plate's angle while unpowered (and at startup), in degrees relative to the cradle.
	set(value):
		aim_0_degrees = value
		_refresh_authored_pose()
		if is_node_ready():
			update_configuration_warnings()
@export var aim_1_degrees: float = 90.0: ## Toggle mode: the plate's angle while powered, in degrees relative to the cradle.
	set(value):
		aim_1_degrees = value
		_refresh_authored_pose()
		if is_node_ready():
			update_configuration_warnings()
@export var rotation_step_degrees: float = 45.0 ## Step mode: degrees per kick or rising edge.
@export_enum("Clockwise:1", "Counter-clockwise:-1") var rotate_direction: int = 1 ## Step mode: which way each step turns.
@export var rotate_time: float = 0.15 ## Seconds one step takes (toggle mode: the whole sweep from one aim to the other).
@export var kick_rotates: bool = true ## Turn off when a switch owns this mirror.
@export var bullet_rotates: bool = false ## A cannon bullet hitting the plate turns it one step (and is consumed).
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
@export var draw_placeholder: bool = true

const PLATE_THICKNESS := 3.0
const CRADLE_YOKE_RADIUS := 8.0  # px, the placeholder cradle's yoke around the pivot

## The plate's angle relative to the cradle, in radians: what the turn tweens. Turns the `Plate` child and the
## collider (the node's own transform is the cradle and never changes at run time).
var plate_angle: float = 0.0:
	set(value):
		plate_angle = value
		_sync_plate()
var _target_angle: float = 0.0  # where the plate is turning to (or resting at), relative to the cradle
var _initial_angle: float = 0.0  # step index 0, from `initial_angle_degrees`
var _tween: Tween
var _last_power: bool = false
var _aim_index: int = 0  # toggle mode: 0 or 1, the aim the mirror is at or turning to
var _state_restored: bool = false  # load_state() has run: the startup apply must not undo it
var _plate: Node2D  # the `Plate` child, found in _ready()
var _shape_node: CollisionShape2D  # the `CollisionShape2D` child, found in _ready()
## Authoring overlay flag (not an export): draws both aims in toggle mode. On in the editor, off in a game.
var show_aim_preview: bool = Engine.is_editor_hint()

func _ready() -> void:
	_plate = get_node_or_null("Plate") as Node2D
	_shape_node = get_node_or_null("CollisionShape2D") as CollisionShape2D
	if _plate != null and not _plate.draw.is_connected(_draw_plate):
		_plate.draw.connect(_draw_plate)
	_initial_angle = deg_to_rad(initial_angle_degrees)
	_sync_draw_order()
	plate_angle = _authored_angle()  # in the editor too: the plate shows its authored angle
	_sync_shape()
	_redraw_all()
	if Engine.is_editor_hint():
		return
	add_to_group(&"laser_mirror")
	add_to_group(&"saveable")
	_target_angle = plate_angle
	if toggle_between_aims:
		_snap_to_aim(0)

## Saveable contract (see game.gd). The angle is stored as the accumulated target plate angle (relative to the
## cradle); the initial angle (step index 0) and the cradle's orientation always come from the scene. A mirror caught
## mid-turn comes back at the end of that turn.
func save_state() -> Dictionary:
	return {"angle": _target_angle, "last_power": _last_power, "aim": _aim_index}

func load_state(d: Dictionary) -> void:
	_kill_tween()
	_target_angle = d.get("angle", _target_angle)
	plate_angle = _target_angle
	_last_power = d.get("last_power", _last_power)
	_aim_index = d.get("aim", _aim_index)
	_state_restored = true  # a restore runs before the PowerTarget's startup apply; the saved aim wins over it
	_reset_plate_interpolation()

func is_rotating() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()

# --- laser contract (read by LaserBeam) ---------------------------------------------------------

func get_laser_segment() -> PackedVector2Array:
	var half := Vector2.RIGHT.rotated(_plate_global_rotation()) * (plate_length * 0.5)
	return PackedVector2Array([global_position - half, global_position + half])

func get_laser_normal() -> Vector2:
	return Vector2.UP.rotated(_plate_global_rotation())

## The plate's face direction in world space: the cradle's rotation, the plate's turn on it and the art's base angle.
func _plate_global_rotation() -> float:
	return global_rotation + plate_angle + deg_to_rad(base_angle_degrees)

# --- power ---------------------------------------------------------------------------------------

## Startup state: remembered, never an edge. In toggle mode it snaps to the aim the state names (no turn,
## no sound), unless a checkpoint restore already placed the mirror.
func set_powered_initial(on: bool) -> void:
	_last_power = on
	if toggle_between_aims and not _state_restored:
		_snap_to_aim(1 if on else 0)

## Step mode: one step per rising edge, falling edges do nothing. Toggle mode: powered = aim 1, unpowered =
## aim 0, on both edges.
func set_powered(on: bool) -> void:
	var rising := on and not _last_power
	_last_power = on
	if toggle_between_aims:
		_go_to_aim(1 if on else 0)
	elif rising:
		rotate_step(1)

# --- rotation ------------------------------------------------------------------------------------

## Kick contract (player.gd: `if body.has_method("take_damage"): body.take_damage(KICK_DAMAGE)`).
## Returns 0 — enemies return points from this method; a mirror is worth none.
func take_damage(_amount: int = 1) -> int:
	if kick_rotates:
		_advance()
	return 0

## Bullet contract (bullet.gd): one step per bullet (a flip to the other aim in toggle mode), and the bullet is
## consumed. With `bullet_rotates` off it returns false and the bullet flies on through, as before. A hit
## during a turn still consumes the bullet but turns nothing (stacked controllers can drop a step; see
## rotate_step()).
func on_bullet_hit(_point: Vector2, _direction: Vector2) -> bool:
	if not bullet_rotates:
		return false
	_advance()
	return true

## What one kick or one bullet does: a step in step mode, a flip to the other aim in toggle mode.
func _advance() -> bool:
	return toggle_aim() if toggle_between_aims else rotate_step(1)

## Step mode: turn `steps` steps in rotate_direction (negative steps reverse). Ignored mid-turn so mashing
## kick can't queue up a spin. Returns whether it started turning. In toggle mode an odd count flips to the
## other aim and an even count does nothing.
func rotate_step(steps: int = 1) -> bool:
	if toggle_between_aims:
		return toggle_aim() if steps % 2 != 0 else false
	if is_rotating():
		return false
	_target_angle += deg_to_rad(rotation_step_degrees) * steps * rotate_direction
	_turn_to(_target_angle, rotate_time)
	return true

## Absolute version for switches: step index 0 is `initial_angle_degrees`. In toggle mode index 0
## is aim 0 and any other index is aim 1.
func rotate_to_step(index: int) -> bool:
	if toggle_between_aims:
		return rotate_to_aim(0 if index == 0 else 1)
	if is_rotating():
		return false
	_target_angle = _initial_angle + deg_to_rad(rotation_step_degrees) * index * rotate_direction
	_turn_to(_target_angle, rotate_time)
	return true

## Toggle mode: flip to the other aim. Ignored mid-turn, like a kick. Does nothing in step mode.
func toggle_aim() -> bool:
	if not toggle_between_aims or is_rotating():
		return false
	return _go_to_aim(1 - _aim_index)

## Toggle mode: turn to aim 0 or aim 1. Ignored mid-turn. Does nothing in step mode.
func rotate_to_aim(index: int) -> bool:
	if not toggle_between_aims or is_rotating():
		return false
	return _go_to_aim(1 if index != 0 else 0)

## The aim as a plate angle relative to the cradle, in radians.
func _aim_rotation(index: int) -> float:
	return deg_to_rad(aim_1_degrees if index == 1 else aim_0_degrees)

## Turn to an aim from wherever the mirror is, replacing any turn in progress (power changes are never dropped,
## so the mirror always ends on the aim the power state names). The sweep takes `rotate_time` for the full
## distance between the two aims and proportionally less for a part of it, so a reversal mid-turn is quick.
## Returns whether a turn started.
func _go_to_aim(index: int) -> bool:
	_aim_index = index
	_target_angle = _aim_rotation(index)
	var distance := absf(_target_angle - plate_angle)
	if distance < 0.0001:
		_kill_tween()
		plate_angle = _target_angle
		return false
	var span := absf(_aim_rotation(1) - _aim_rotation(0))
	var fraction := clampf(distance / span, 0.0, 1.0) if span > 0.0001 else 1.0
	_turn_to(_target_angle, rotate_time * fraction)
	return true

## Place the mirror on an aim at once: no turn, no sound.
func _snap_to_aim(index: int) -> void:
	_kill_tween()
	_aim_index = index
	_target_angle = _aim_rotation(index)
	plate_angle = _target_angle
	_reset_plate_interpolation()

func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

func _turn_to(target: float, duration: float) -> void:
	_kill_tween()
	Audio.play_at(&"interactive/mirror_rotate", global_position)
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)  # in step with the beam solve
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "plate_angle", target, duration)

# --- editor / drawing ----------------------------------------------------------------------------

## Shows the fields of the selected control mode. A hidden field is still stored, so switching mode back
## and forth keeps what was authored.
func _validate_property(property: Dictionary) -> void:
	var prop_name: StringName = property.name
	if toggle_between_aims:
		if prop_name == &"rotation_step_degrees" or prop_name == &"rotate_direction":
			property.usage = PROPERTY_USAGE_NO_EDITOR
	elif prop_name == &"aim_0_degrees" or prop_name == &"aim_1_degrees":
		property.usage = PROPERTY_USAGE_NO_EDITOR

## Plain method, so a runtime level validator can reuse it; `_get_configuration_warnings()` calls it.
func get_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if toggle_between_aims and is_equal_approx(aim_0_degrees, aim_1_degrees):
		warnings.append("Aim 0 and aim 1 are the same angle, so this mirror never turns.")
	if get_node_or_null("Plate") == null:
		warnings.append("No 'Plate' child node (see mirror.tscn): the mirror art and its turn are drawn on it.")
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()

## The plate angle the mirror starts at: aim 0 in toggle mode, else the initial angle. Radians, relative to the cradle.
func _authored_angle() -> float:
	return _aim_rotation(0) if toggle_between_aims else deg_to_rad(initial_angle_degrees)

## Editor only: an authored angle changed, so the plate shows it. At run time the exports are read once, in _ready().
func _refresh_authored_pose() -> void:
	if Engine.is_editor_hint():
		plate_angle = _authored_angle()
	_redraw_all()

## Collider size and angle (the size from `plate_length`, the angle from the plate's turn and the art's base angle).
func _sync_shape() -> void:
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var rect := shape_node.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape_node.shape = rect
	rect.size = Vector2(plate_length, PLATE_THICKNESS)
	shape_node.rotation = plate_angle + deg_to_rad(base_angle_degrees)  # the collider follows the plate, not the node

## Turns the `Plate` child and the collider to `plate_angle` (called on every change of it, so on every tween step).
func _sync_plate() -> void:
	if _plate != null:
		_plate.rotation = plate_angle
		if show_aim_preview and toggle_between_aims:
			_plate.queue_redraw()  # the aim preview is drawn relative to the plate's own turn
	if _shape_node != null:
		_shape_node.rotation = plate_angle + deg_to_rad(base_angle_degrees)

## The cradle is this node's own drawing and the plate is a child, so the plate is on top unless it is told to draw
## behind its parent.
func _sync_draw_order() -> void:
	if _plate != null:
		_plate.show_behind_parent = cradle_in_front

func _reset_plate_interpolation() -> void:
	if _plate != null:
		_plate.reset_physics_interpolation()

func _redraw_all() -> void:
	queue_redraw()
	if _plate != null:
		_plate.queue_redraw()

## The cradle, in the node's own frame (static; turning the instance reorients it).
func _draw() -> void:
	if not show_cradle:
		return
	if cradle_texture != null:
		draw_texture(cradle_texture, -cradle_texture.get_size() * 0.5)
		return
	# Placeholder: a U-shaped yoke around the pivot, on a short stem and a foot pointing local +Y.
	var steel := Color(0.22, 0.24, 0.3)
	var edge := Color(0.5, 0.55, 0.65)
	draw_arc(Vector2.ZERO, CRADLE_YOKE_RADIUS, 0.0, PI, 16, steel, 2.0)
	draw_circle(Vector2(-CRADLE_YOKE_RADIUS, 0.0), 1.5, edge)
	draw_circle(Vector2(CRADLE_YOKE_RADIUS, 0.0), 1.5, edge)
	draw_rect(Rect2(-1.5, CRADLE_YOKE_RADIUS, 3.0, 2.0), steel)
	draw_rect(Rect2(-6.0, CRADLE_YOKE_RADIUS + 2.0, 12.0, 2.0), steel)
	draw_line(Vector2(-6.0, CRADLE_YOKE_RADIUS + 2.0), Vector2(6.0, CRADLE_YOKE_RADIUS + 2.0), edge, 1.0)

## The plate, drawn on the `Plate` child (connected to its `draw` signal in _ready()), so it turns with `plate_angle`
## and, like any node, is interpolated between physics steps.
func _draw_plate() -> void:
	if _plate == null:
		return
	if texture != null:
		_plate.draw_texture(texture, -texture.get_size() * 0.5)
	elif draw_placeholder:
		# plate frame: rotated by the base angle, front (bright) is local -Y within it
		_plate.draw_set_transform(Vector2.ZERO, deg_to_rad(base_angle_degrees))
		var half := plate_length * 0.5
		_plate.draw_rect(Rect2(-half, -PLATE_THICKNESS * 0.5, plate_length, PLATE_THICKNESS), Color(0.22, 0.24, 0.3))
		_plate.draw_line(Vector2(-half, -PLATE_THICKNESS * 0.5), Vector2(half, -PLATE_THICKNESS * 0.5), Color(0.75, 0.9, 1.0), 1.0)
		_plate.draw_set_transform(Vector2.ZERO, 0.0)
	if show_cradle and not cradle_in_front:
		_plate.draw_circle(Vector2.ZERO, 1.5, Color(0.5, 0.55, 0.65))  # the pivot pin, in front of the art
	if Engine.is_editor_hint():
		# front-face marker (editor only), along the plate's real front normal
		_plate.draw_line(Vector2.ZERO, Vector2.UP.rotated(deg_to_rad(base_angle_degrees)) * 10.0, Color(0.75, 0.9, 1.0, 0.5), 1.0)
	if show_aim_preview and toggle_between_aims:
		_draw_aim_preview()

## Both aims as a plate outline with its front-face tick: aim 0 (unpowered) cool blue, aim 1 (powered) orange,
## the same colours as the wire links. Drawn on the plate node, whose own turn is `plate_angle`, so each outline is
## offset by the difference between its aim and where the plate is now.
func _draw_aim_preview() -> void:
	var half := plate_length * 0.5
	for index in 2:
		var color := Color(0.4, 0.85, 1.0, 0.8) if index == 0 else Color(1.0, 0.6, 0.2, 0.8)
		_plate.draw_set_transform(Vector2.ZERO, _aim_rotation(index) - plate_angle + deg_to_rad(base_angle_degrees))
		_plate.draw_line(Vector2(-half, 0.0), Vector2(half, 0.0), color, 1.0)
		_plate.draw_line(Vector2.ZERO, Vector2(0.0, -6.0), color, 1.0)
	_plate.draw_set_transform(Vector2.ZERO, 0.0)
