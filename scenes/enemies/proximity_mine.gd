@tool
extends CharacterBody2D
## Proximity mine: sits on the floor until the player comes near, then arms (a blinking fuse that speeds up) and goes
## off, hurting everything inside `blast_radius`. The fix is to leave, or to kick it away: a kicked mine slides along the
## floor with its fuse still running, and goes off at once if it hits a wall or an enemy, so it is also a weapon.
##
## Two states: DORMANT (waiting) and ARMED (fuse running; `fuse_time`, or less when a neighbour's blast chains it).
## Arming is by the player within `trigger_radius` horizontally and `trigger_height` vertically (a dead or dancing
## player never counts), by a kick, or by anything that calls `take_damage()` on it (a laser beam, say). It never
## disarms: once armed it goes off, so a player who runs away is safe only by being outside the blast when it does.
##
## The blast is an immediate circle query on the actor layer (mask 1) when the fuse ends or the mine impacts:
##   the player          take_hit(damage, mine position), so the knockback is away from the mine
##   group "enemy"       take_damage(enemy_damage): a Grunt dies to the default 2, a Tread crawler is flipped
##   another mine        armed with a short `CHAIN_FUSE`, so mines chain a beat apart instead of recursing
## It does not check line of sight: a blast reaches through a thin floor or wall within the radius.
##
## Contracts other objects rely on:
##   take_damage(amount) -> int   the kick / laser contract: arms it, never damages it
##   kicked(direction)            the kick-direction contract: slides it `kick_speed` px/s, friction `slide_friction`
##   save_state() / load_state()  the checkpoint contract (group "saveable", see game.gd)
## Layers match the other enemies: collision_layer 1 (the player stands on it, KickHitbox sees it), collision_mask 2.
## It has no `bowled_over()`, so a surfer simply stops against it, and it will already have armed.
##
## All its exports are tuning values the script only reads; its runtime state is `_state`, `_elapsed` and `_duration`.

enum State { DORMANT, ARMED }

@export_group("Trigger")
## The player this close (px, horizontally) arms it.
@export var trigger_radius: float = 32.0:
	set(value):
		trigger_radius = value
		_refresh_art()
## Vertical reach of the trigger (px, either way): a player on another floor doesn't arm it.
@export var trigger_height: float = 28.0:
	set(value):
		trigger_height = value
		_refresh_art()
## Seconds from arming to the blast.
@export var fuse_time: float = 0.8

@export_group("Blast")
## Everything within this many px of the mine is hurt.
@export var blast_radius: float = 40.0:
	set(value):
		blast_radius = value
		_refresh_art()
## Damage to the player, passed to `take_hit()`.
@export var damage: int = 1
## Damage to enemies, passed to `take_damage()`. Two kills a Grunt.
@export var enemy_damage: int = 2

@export_group("Kick")
## Speed a kick sends it sliding at, px/s (0 = a kick only arms it).
@export var kick_speed: float = 160.0
## Slowing of a slide, px/s^2.
@export var slide_friction: float = 120.0
## Weight on a weight plate or see-saw, in block-mass units (metal 4, ice 1 per tile, the player 2). Counts only while
## it is alive and on the floor (`get_load_weight()`); 0 = it never presses anything. An authored value only.
@export_group("Load")
@export_range(0.0, 40.0, 0.5, "or_greater") var load_weight: float = 1.0
@export_group("")

const EXPLOSION_SCENE: PackedScene = preload("res://scenes/effects/explosion.tscn")
const EXPLOSION_SCALE := 1.5  # the standard explosion drawn larger: this is a bigger bang than a bot dying
const BLAST_MASK := 1  # actors: the player, enemies, other mines
const MAX_BLAST_HITS := 16
const CHAIN_FUSE := 0.15  # seconds a mine caught in another's blast waits before going off
const IMPACT_SPEED := 40.0  # px/s: a slide faster than this goes off on hitting a wall or an enemy
const BLINK_SLOW_HZ := 3.0  # blink rate when just armed...
const BLINK_FAST_HZ := 12.0  # ...and just before it goes off

var _state: State = State.DORMANT
var _elapsed := 0.0  # seconds since it armed
var _duration := 0.0  # the fuse it is running (fuse_time, or the shorter chain fuse)
var _blink_phase := 0.0
var _exploded := false
var _player: Node2D

@onready var art: Node2D = $ProximityMineArt
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var contact: Area2D = $Contact

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("enemy")
	add_to_group("saveable")
	_apply_pose()

## The art draws the trigger and blast rings in the editor, so a change to either number has to redraw it.
func _refresh_art() -> void:
	var node := get_node_or_null("ProximityMineArt") as Node2D
	if node != null:
		node.queue_redraw()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _exploded:
		return
	if not is_on_floor():
		velocity.y += float(ProjectSettings.get_setting("physics/2d/default_gravity")) * delta
	var speed_before := velocity.x
	velocity.x = move_toward(velocity.x, 0.0, slide_friction * delta)
	move_and_slide()

	# A kicked mine goes off on a wall or an enemy. The wall test uses the speed from before the move, which the
	# collision has just zeroed, and needs the wall to oppose the slide so a slope isn't an impact.
	if absf(speed_before) > IMPACT_SPEED and is_on_wall() and get_wall_normal().x * speed_before < 0.0:
		_detonate()
		return
	if absf(velocity.x) > IMPACT_SPEED and _touching_enemy():
		_detonate()
		return

	match _state:
		State.DORMANT:
			if _player_near():
				arm()
		State.ARMED:
			_elapsed += delta
			_blink_phase += delta * lerpf(BLINK_SLOW_HZ, BLINK_FAST_HZ, _fuse_fraction())
			if _elapsed >= _duration:
				_detonate()
				return
	_apply_pose()

# --- arming ----------------------------------------------------------------------------------

## Starts the fuse (`seconds` <= 0 means `fuse_time`). An armed mine's fuse can only be shortened, never restarted.
func arm(seconds: float = -1.0) -> void:
	if _exploded:
		return
	var fuse := seconds if seconds > 0.0 else fuse_time
	if _state == State.ARMED:
		if fuse < _duration - _elapsed:
			_duration = _elapsed + fuse
		return
	_state = State.ARMED
	_elapsed = 0.0
	_duration = maxf(fuse, 0.01)
	_blink_phase = 0.0
	Audio.play_at(&"enemies/mine_arm", global_position, 2.0)
	_apply_pose()

func _fuse_fraction() -> float:
	return clampf(_elapsed / _duration, 0.0, 1.0) if _duration > 0.0 else 0.0

func _player_near() -> bool:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D
	if _player == null or _player.get("is_dead") == true or _player.get("is_dancing") == true:
		return false
	var d := _player.global_position - global_position
	return absf(d.x) <= trigger_radius and absf(d.y) <= trigger_height

func _touching_enemy() -> bool:
	for body in contact.get_overlapping_bodies():
		if body != self and body.is_in_group("enemy"):
			return true
	return false

# --- the blast -------------------------------------------------------------------------------

## Goes off now: hurts everything in the radius, then removes itself. Retires first (out of its groups, collision off)
## so nothing it calls can find it, and a checkpoint taken this frame leaves it out.
func _detonate() -> void:
	if _exploded:
		return
	_exploded = true
	set_physics_process(false)
	remove_from_group("enemy")
	remove_from_group("saveable")
	body_shape.set_deferred("disabled", true)
	Audio.play_at(&"enemies/mine_explode", global_position, 6.0)

	var circle := CircleShape2D.new()
	circle.radius = blast_radius
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = BLAST_MASK
	query.exclude = [get_rid()]
	var seen := {}
	for hit in get_world_2d().direct_space_state.intersect_shape(query, MAX_BLAST_HITS):
		var body := hit.get("collider") as Node
		if body == null or seen.has(body.get_instance_id()):
			continue
		seen[body.get_instance_id()] = true
		if body.has_method("arm"):
			body.arm(CHAIN_FUSE)
		elif body.is_in_group("player") and body.has_method("take_hit"):
			body.take_hit(damage, global_position)
		elif body.is_in_group("enemy") and body.has_method("take_damage"):
			body.take_damage(enemy_damage)

	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position
	explosion.scale = Vector2.ONE * EXPLOSION_SCALE
	get_parent().add_child(explosion)  # not on self: this node is about to be freed
	queue_free()

# --- art -------------------------------------------------------------------------------------

func _apply_pose() -> void:
	if art != null and art.has_method("set_pose"):
		art.set_pose(_state == State.ARMED, fmod(_blink_phase, 1.0) < 0.5, _fuse_fraction())

# --- kick and laser contracts ----------------------------------------------------------------

## Kick / laser contract: arms it, never damages it (a kick calls this and then `kicked()`).
func take_damage(_amount: int = 1) -> int:
	arm()
	return 0

## Kick-direction contract: sends it sliding the way the player kicked.
func kicked(direction: float) -> void:
	if _exploded or kick_speed <= 0.0:
		return
	velocity.x = signf(direction) * kick_speed
	Audio.play_at(&"enemies/mine_kick", global_position, 2.0)

# --- checkpoint ------------------------------------------------------------------------------

## Saveable contract (see game.gd): a mine that has gone off frees itself, so it is absent from the snapshot and the
## fresh copy is freed on restore, as with the other enemies. A mine saved armed or mid-slide comes back DORMANT and
## still, so a restore can never land a surprise blast: it simply arms again, with its whole fuse, if the player is near.
func save_state() -> Dictionary:
	return {"position": global_position}

func load_state(d: Dictionary) -> void:
	global_position = d.get("position", global_position)
	_state = State.DORMANT
	_elapsed = 0.0
	_duration = 0.0
	_blink_phase = 0.0
	velocity = Vector2.ZERO
	_apply_pose()
	reset_physics_interpolation()

## Weight contract, read by the weight plate and the see-saw (duck-typed, found through group "enemy"): `load_weight`
## while this body is alive and standing on something, else 0 (a body in the air presses nothing).
func get_load_weight() -> float:
	if _exploded or not is_on_floor():
		return 0.0
	return load_weight
