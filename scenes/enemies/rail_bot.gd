@tool
extends AnimatableBody2D
## Rail bot: a trolley that rides a Path2D rail (a ceiling, a wall, any curve you draw) with a spark nozzle hanging
## from it, dripping a spark on a steady timer. The sparks fall and the bot itself is a solid
## obstacle on its rail that only a mine's blast, a laser or a kick can remove.
##
## Placing one: either make it a CHILD of the Path2D (it finds the rail itself), or put it anywhere and set `rail` to the
## Path2D. Draw the rail with the Path2D's own point tool. The bot's origin is the point on the rail; the body hangs 4 to
## 12 px below it and the nozzle is at the bottom, so the rail should run just under a ceiling. Walls work too: the bot
## stays upright and the sparks still fall straight down. The rail itself is drawn as a plain line by the first bot to find
## it (an unowned Line2D under the Path2D, rebuilt each load, never saved; tune it with RAIL_* below).
##
## Motion: `speed` px/s along the rail. `mode` PING_PONG turns at each end after `end_pause`; LOOP wraps from the end back
## to the start, so close the curve (repeat its first point as its last) or it will jump. `start_fraction` is where on the
## rail it starts, and the editor snaps it there so you can see.
##
## Sparks: a `drip_interval` timer, with the last `TELEGRAPH` seconds before each drip shown as a growing glow at the
## nozzle (the warning). Fully deterministic, no randomness; `phase_offset` staggers several bots, like Crusher's.
## A spark is a small physical ball. It drops from the nozzle (it does NOT inherit the bot's sideways speed: that keeps its
## path readable), rolls down slopes, rides conveyor belts, hurts the player on touch and despawns once it comes to rest.
## It collides with the world only and is invisible to everything else: no liquid, no enemy, mine, laser, bullet or sensor
## reacts to it, deliberately (see spark.gd). They are added next to the bot (or beside the Path2D if it is a child
## of one), are not saved, and vanish with the level on a respawn.
##
## Power contract (see power_target.gd): powered = running. Unpowered, the bot stops where it is and stops dripping,
## the glow goes out; powered again, it carries on. A PowerTarget child is in the scene: with nothing wired to it the bot
## runs forever. `invert` is read by that child.
##
## Contact: touching the body hurts the player and knocks them off a rail hang (see _poll_contact()).
##
## Contracts other objects rely on:
##   take_damage(amount) -> int   the kick / laser / mine-blast contract (group "enemy"): costs `health` points, and at 0 it
##                                explodes. The default is 1, so one hit does it
##   save_state() / load_state()  the checkpoint contract (group "saveable", see game.gd)
## Layers match the other enemies: collision_layer 1 (so the KickHitbox and a mine's blast see it), collision_mask 0
## (it is moved by script, `sync_to_physics`, and never pushed).
##
## Exports are authored values only, read once: runtime state is `_health`, `_powered`, `_offset`, `_dir` and the timers.

enum Mode { PING_PONG, LOOP }

## The Path2D to ride. Leave it empty if the bot is a child of the Path2D.
@export var rail: Path2D:
	set(value):
		rail = value
		if is_node_ready():
			_rebuild_rail()
			_snap_to_start()
			update_configuration_warnings()
@export var mode: Mode = Mode.PING_PONG
## Lets the player hang from this bot's rail (brachiate along it, or slide down it if it slopes). The rail joins group
## "grab_rail" at run time; a rail with no bot can be made grabbable by putting its Path2D in that group by hand.
@export var rail_grabbable: bool = true
## Hits it takes to destroy (a kick, a laser pulse, a mine's blast).
@export_range(1, 5) var health: int = 1
## Damage the bot does to the player on contact (`take_hit()`, which also knocks the player off a rail or out of any held state).
@export var contact_damage: int = 1
## Flips the power state (read by the PowerTarget child).
@export var invert: bool = false
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0

@export_group("Movement")
## Speed along the rail, px/s.
@export var speed: float = 40.0
## Standing still at each end of the rail before turning round (PING_PONG only), seconds.
@export var end_pause: float = 0.6
## Where on the rail it starts, 0 = the first point, 1 = the last.
@export_range(0.0, 1.0) var start_fraction: float = 0.0:
	set(value):
		start_fraction = value
		if is_node_ready():
			_snap_to_start()

@export_group("Sparks")
## Seconds between drips.
@export var drip_interval: float = 1.6
## Fraction of an interval to start ahead by, so several bots can be staggered.
@export_range(0.0, 1.0) var phase_offset: float = 0.0
## Damage a spark does to the player, passed to `take_hit()`.
@export var spark_damage: int = 1

const SPARK_SCENE: PackedScene = preload("res://scenes/enemies/spark.tscn")
const EXPLOSION_SCENE: PackedScene = preload("res://scenes/effects/explosion.tscn")
const NOZZLE := Vector2(0.0, 13.5)  # where a spark appears, relative to the bot's origin
const EXPLOSION_OFFSET := Vector2(0.0, 8.0)  # the middle of the body
const TELEGRAPH := 0.45  # seconds before each drip that the nozzle glows
const HIT_FLASH_COLOR := Color(1.6, 0.5, 0.5)
const HIT_FLASH_DURATION := 0.2
const RAIL_NODE_NAME := "RailLine"
const RAIL_COLOR := Color(0.3, 0.33, 0.4)
const RAIL_WIDTH := 2.0

var _health: int = 1
var _powered := true
var _dead := false
var _chill := ChillState.new()  # the shared chill model; runtime only (see apply_chill())
var _offset := 0.0  # distance along the rail, px
var _dir := 1.0
var _pause_left := 0.0
var _drip_clock := 0.0
var _hit_flash_tween: Tween

@onready var art: Node2D = $RailBotArt
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var hitbox: Area2D = $Hitbox

func _ready() -> void:
	_health = health
	_rebuild_rail.call_deferred()  # deferred: a parent Path2D is still busy setting up its children
	_snap_to_start()
	if Engine.is_editor_hint():
		return
	add_to_group("enemy")
	add_to_group("saveable")
	add_to_group("rail_bot")  # the player's rail hang treats it as an obstacle
	_drip_clock = phase_offset * drip_interval
	_apply_pose()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED and Engine.is_editor_hint():
		update_configuration_warnings()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var path := _rail_path()
	if path == null:
		warnings.append("No rail: make this a child of a Path2D, or set `rail`.")
	elif path.curve == null or path.curve.point_count < 2:
		warnings.append("The rail's curve needs at least two points.")
	return warnings

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _dead:
		return
	_chill.update(delta)  # before the powered check: an unpowered bot's hue still fades
	_chill.apply_tint_to(art)
	_poll_contact()  # before the powered check: a stopped bot still hurts
	if not _powered:
		return
	_advance(delta)
	_drip_clock += delta
	if _drip_clock >= drip_interval:
		_drip_clock -= drip_interval
		_drip()
	_apply_pose()

## Contact damage: the Hitbox (Area2D, layer 0, mask 1, a little bigger than the body) is polled every physics frame, not
## signalled once, so a player whose i-frames ran out while touching is hit again (same as Sawwheel and Crusher).
func _poll_contact() -> void:
	for body in hitbox.get_overlapping_bodies():
		if body != self and body.has_method("take_hit"):
			body.take_hit(contact_damage, global_position + Vector2(0.0, EXPLOSION_OFFSET.y))

# --- the rail --------------------------------------------------------------------------------

func _rail_path() -> Path2D:
	if rail != null:
		return rail
	return get_parent() as Path2D

func _rail_length() -> float:
	var path := _rail_path()
	if path == null or path.curve == null or path.curve.point_count < 2:
		return 0.0
	return path.curve.get_baked_length()

func _snap_to_start() -> void:
	_offset = start_fraction * _rail_length()
	_place()

## Puts the bot at `_offset` along the rail (global position, so the Path2D may sit anywhere).
func _place() -> void:
	var path := _rail_path()
	if _rail_length() <= 0.0:
		return
	global_position = path.to_global(path.curve.sample_baked(_offset))

func _advance(delta: float) -> void:
	var length := _rail_length()
	if length <= 0.0:
		return
	if _pause_left > 0.0:
		_pause_left -= delta
		return
	_offset += _dir * speed * _chill.speed_scale() * delta
	if mode == Mode.LOOP:
		_offset = fposmod(_offset, length)
	elif _offset >= length:
		_offset = length
		_dir = -1.0
		_pause_left = end_pause
	elif _offset <= 0.0:
		_offset = 0.0
		_dir = 1.0
		_pause_left = end_pause
	_place()

## Draws the rail as a line under the Path2D, once however many bots share it. Also rebuilt when the curve is edited.
func _rebuild_rail() -> void:
	var path := _rail_path()
	if path == null or path.curve == null:
		return
	if not path.curve.changed.is_connected(_on_rail_curve_changed):
		path.curve.changed.connect(_on_rail_curve_changed)
	if rail_grabbable and not Engine.is_editor_hint():
		path.add_to_group(&"grab_rail")  # see player.gd's rail hang
	if path.has_method(&"draws_own_line"):
		return  # a Rail node draws itself
	var line := path.get_node_or_null(RAIL_NODE_NAME) as Line2D
	if line == null:
		line = Line2D.new()
		line.name = RAIL_NODE_NAME
		line.width = RAIL_WIDTH
		line.default_color = RAIL_COLOR
		path.add_child(line)  # unowned on purpose: rebuilt here every load and never saved
	line.points = path.curve.get_baked_points()

## The rail's curve was edited (in the editor a dragged Rail marker or Path2D point): redraw it and put the bot back
## on its start.
func _on_rail_curve_changed() -> void:
	_rebuild_rail()
	if Engine.is_editor_hint():
		_snap_to_start()

# --- sparks ----------------------------------------------------------------------------------

func _drip() -> void:
	var host: Node = get_parent()
	if host is Path2D:
		host = host.get_parent()
	if host == null:
		return
	var spark := SPARK_SCENE.instantiate()
	spark.set("damage", spark_damage)
	host.add_child(spark)
	spark.global_position = global_position + NOZZLE
	spark.reset_physics_interpolation()  # a body added mid-run would otherwise be drawn sliding in from the origin
	Audio.play_at(&"enemies/railbot_drip", spark.global_position, 2.0)

func _apply_pose() -> void:
	if art == null or not art.has_method("set_pose"):
		return
	var charge := 0.0
	if _powered and drip_interval > TELEGRAPH:
		charge = clampf((_drip_clock - (drip_interval - TELEGRAPH)) / TELEGRAPH, 0.0, 1.0)
	art.set_pose(charge, _powered)

# --- power -----------------------------------------------------------------------------------

## Power contract: powered = running.
func set_powered(on: bool) -> void:
	_powered = on
	_apply_pose()

# --- checkpoint ------------------------------------------------------------------------------

## Saveable contract (see game.gd): a destroyed bot frees itself, so it is absent from the snapshot and the fresh copy is
## freed on restore, as with the other enemies. The drip timer is NOT restored: it restarts from zero, so a restore can
## never put a spark on the respawning player at once. Sparks already falling are not saved: the level reloads without them.
func save_state() -> Dictionary:
	return {
		"offset": _offset,
		"dir": _dir,
		"pause": _pause_left,
		"health": _health,
		"powered": _powered,
	}

func load_state(d: Dictionary) -> void:
	_offset = d.get("offset", _offset)
	_dir = d.get("dir", _dir)
	_pause_left = d.get("pause", 0.0)
	_health = d.get("health", _health)
	_powered = d.get("powered", _powered)
	_drip_clock = 0.0
	_chill.reset(art)
	_place()
	_apply_pose()
	reset_physics_interpolation()

# --- damage and death ------------------------------------------------------------------------

## Chill contract (duck-typed, `has_method("apply_chill")`): called every physics frame by a FreezeTurret's beam that ends on
## this body. `_chill` is the shared ChillState model: it slows its speed along the rail (the drip timer and the end pause are not scaled) by `ChillState.MIN_SCALE` at full chill and
## turns `art` blue over `ChillState.TINT_RISE_TIME` (`self_modulate`, so the hit flash on `modulate` is untouched).
## Runtime only, never saved: a restore comes back unchilled.
func apply_chill(strength: float) -> void:
	_chill.apply(strength)

func get_chill() -> float:
	return _chill.level

## Kick / laser / mine-blast contract. Returns 0 until there is a scoring system.
func take_damage(amount: int = 1) -> int:
	if _dead:
		return 0
	_health -= maxi(amount, 1)
	Audio.play_at(&"enemies/railbot_hit", global_position, 4.0)
	if _health <= 0:
		_die()
	else:
		_play_hit_feedback()
	return 0

func _play_hit_feedback() -> void:
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	art.modulate = Color.WHITE
	_hit_flash_tween = create_tween()
	_hit_flash_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_hit_flash_tween.tween_property(art, "modulate", HIT_FLASH_COLOR, 0.0)
	_hit_flash_tween.tween_property(art, "modulate", Color.WHITE, HIT_FLASH_DURATION)

## Destroyed: out of both groups and collision off so nothing it triggers can find it, then the standard explosion.
func _die() -> void:
	_dead = true
	set_physics_process(false)
	remove_from_group("enemy")
	remove_from_group("saveable")
	remove_from_group("rail_bot")
	body_shape.set_deferred("disabled", true)
	hitbox.set_deferred("monitoring", false)
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position + EXPLOSION_OFFSET
	get_parent().add_child(explosion)  # not on self: this node is about to be freed
	queue_free()
