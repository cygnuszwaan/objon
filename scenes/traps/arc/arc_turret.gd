@tool
extends Node2D
## Trap. The Laser turret's discrete cousin: instead of a continuous beam it fires an electric Arc (arc.gd, a hazardous
## particle) every `fire_interval` seconds along its own rotation (direction = Vector2.RIGHT.rotated(global_rotation),
## same facing convention as Cannon and the Laser turret: rotate the instance in the editor to aim).
##
## The arc flies the path the laser solver gives it, so it bounces off the same mirrors (the kickable Mirror, a
## see-saw plank with `mirror_surface`) and is stopped by everything that stops a laser. It hurts the player on touch
## and electrifies a basin's water as a Rail bot's Spark does. See arc.gd for what it reacts to and ignores.
##
## Timing is fully deterministic: the last `TELEGRAPH` seconds before each shot show as a growing glow at the muzzle (the
## warning), and `phase_offset` staggers several turrets like Crusher's and the Rail bot's. The clock is `_clock`
## (runtime); `start_enabled`, `fire_interval` and the other exports are authored values only, read once.
##
## Power contract (see power_target.gd): powered = firing. Switching on from off fires one arc immediately (deferred,
## like Cannon, because a source may call this inside a physics callback) and then the clock runs, so the next one is a
## full `fire_interval` later; switching off stops the clock and clears the glow. A turret unwired or already powered at
## load keeps its ordinary first shot after `fire_interval` (less `phase_offset`). `invert` is read by the PowerTarget
## child. Arcs already in flight are not recalled by switching off.
##
## Checkpoint: saves only whether it is firing. The clock is NOT restored (it restarts from zero), so a restore can
## never put an arc on the respawning player at once. Arcs in flight are not saved; the level reloads without them.
##
## Expected scene layout (the Laser turret's, minus the beam art):
##   ArcTurret (Node2D, this script)
##     - Body (StaticBody2D, layer 2) + CollisionShape2D   the solid housing; joins "water_solid"
##     - Muzzle (Marker2D)                                 where the arc appears, just outside the housing
##     - PowerTarget
##
## Placeholder art: the housing is drawn in code until real sprites exist; add a Sprite2D/AnimatedSprite2D child and set
## draw_placeholder = false when it does.

const ARC_SCENE: PackedScene = preload("res://scenes/traps/arc/arc.tscn")
const TELEGRAPH := 0.45  # seconds before each shot that the muzzle glows
const CORE := Color(0.9, 1.0, 1.0)
const GLOW := Color(0.35, 0.8, 1.0)

## Seconds between shots.
@export_range(0.2, 10.0, 0.05, "or_greater", "suffix:s") var fire_interval: float = 2.0
## Fraction of an interval to start ahead by, so several turrets can be staggered.
@export_range(0.0, 1.0) var phase_offset: float = 0.0
## Whether it fires from the start. Power (see above) overrides this once something is wired to its PowerTarget.
@export var start_enabled: bool = true
## Flips the power state (read by the PowerTarget child).
@export var invert: bool = false
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0
@export_group("Arc")
## Damage an arc does to the player, passed to `take_hit()`.
@export var damage: int = 1
## Flight speed, px/s.
@export_range(40.0, 800.0, 10.0, "suffix:px/s") var arc_speed: float = 220.0
## Path length an arc travels (mirror bounces included) before it dies out, px.
@export_range(32.0, 4000.0, 16.0, "suffix:px") var arc_range: float = 480.0
@export_group("")
@export var draw_placeholder: bool = true

@onready var _muzzle: Marker2D = $Muzzle
@onready var _body: StaticBody2D = $Body

var _enabled := true
var _clock := 0.0

func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_enabled = start_enabled
	_clock = phase_offset * fire_interval
	_body.add_to_group(&"water_solid")  # collision only: it never moves, so carry is inert for it
	add_to_group(&"saveable")

func _physics_process(delta: float) -> void:
	if not _enabled:
		return
	_clock += delta
	if _clock >= fire_interval:
		_clock -= fire_interval
		_fire()
	if _clock >= fire_interval - TELEGRAPH or _clock < delta:
		queue_redraw()

func _fire() -> void:
	var arc: Node2D = ARC_SCENE.instantiate()
	arc.set("damage", damage)
	arc.set("speed", arc_speed)
	arc.set("max_distance", arc_range)
	arc.set("heading", Vector2.RIGHT.rotated(global_rotation))
	arc.set("exclude_body", _body.get_rid())
	get_parent().add_child(arc)
	arc.global_position = _muzzle.global_position
	arc.reset_physics_interpolation()  # a node added mid-run would otherwise be drawn sliding in from the origin
	Audio.play_at(&"traps/arc_fire", _muzzle.global_position)
	queue_redraw()

## 0..1 growth of the muzzle glow over the telegraph; 0 outside it or while off.
func get_charge() -> float:
	if not _enabled or fire_interval <= TELEGRAPH:
		return 0.0
	return clampf((_clock - (fire_interval - TELEGRAPH)) / TELEGRAPH, 0.0, 1.0)

# --- power -----------------------------------------------------------------------------------

## Power contract: powered = firing. A rising edge fires one arc at once (deferred), then the clock runs from zero.
func set_powered(on: bool) -> void:
	if on == _enabled:
		return
	_enabled = on
	_clock = 0.0
	if on:
		_fire_on_enable.call_deferred()
	queue_redraw()

## The startup and restore apply from PowerTarget: sets the state with no immediate shot.
func set_powered_initial(on: bool) -> void:
	_enabled = on
	_clock = 0.0
	queue_redraw()

## Deferred half of set_powered(true). Skipped if the turret was switched off again before it ran.
func _fire_on_enable() -> void:
	if _enabled and is_inside_tree():
		_fire()

# --- checkpoint ------------------------------------------------------------------------------

## Saveable contract (see game.gd). Aim never changes at runtime, so firing or not is all there is.
func save_state() -> Dictionary:
	return {"enabled": _enabled}

func load_state(d: Dictionary) -> void:
	_enabled = d.get("enabled", _enabled)
	_clock = 0.0
	queue_redraw()

# --- drawing ---------------------------------------------------------------------------------

func _draw() -> void:
	if draw_placeholder:
		_draw_housing()
	if Engine.is_editor_hint():
		_draw_editor_aim()

func _draw_housing() -> void:
	draw_rect(Rect2(-8, -8, 16, 16), Color(0.2, 0.24, 0.32))
	draw_rect(Rect2(-8, -8, 16, 16), Color(0.5, 0.62, 0.78), false, 1.0)
	# barrel toward local +X, where the arc leaves, with two coil rings
	draw_rect(Rect2(2, -2, 8, 4), Color(0.35, 0.42, 0.52))
	draw_line(Vector2(4, -3), Vector2(4, 3), GLOW, 1.0)
	draw_line(Vector2(7, -3), Vector2(7, 3), GLOW, 1.0)
	var charge := 0.0 if Engine.is_editor_hint() else get_charge()
	var lit := _enabled or Engine.is_editor_hint()
	draw_circle(Vector2(-2, 0), 2.5, GLOW if lit else Color(0.12, 0.18, 0.24))
	if charge > 0.0:
		var tip := Vector2(10.0, 0.0)
		draw_circle(tip, 1.0 + 3.0 * charge, Color(GLOW, 0.35 + 0.4 * charge))
		draw_circle(tip, 0.5 + 1.5 * charge, CORE)

func _draw_editor_aim() -> void:
	# short dashed preview of the aim line, editor only (straight, ignores reflections)
	var start := Vector2.ZERO
	var muzzle := get_node_or_null("Muzzle") as Marker2D
	if muzzle != null:
		start = muzzle.position
	for i in 12:
		var a: Vector2 = start + Vector2(i * 16.0, 0.0)
		draw_line(a, a + Vector2(8.0, 0.0), Color(GLOW, 0.6), 1.0)
