@tool
extends CharacterBody2D
## Tread crawler: a low, armoured tank that trundles back and forth along a ledge. Its sides are dangerous; its
## top is the way to beat it. Landing on top flips it onto its back, where it is harmless, still solid and still
## standable, so a flipped crawler is also a safe stepping stone over spikes or slag.
##
## One `State` enum, decided each physics frame:
##   WALK     trundling at `speed`; a wall or a ledge ahead turns it round (into TURN)
##   TURN     a beat standing still at a wall or ledge (`turn_pause`), then WALK the other way. Still dangerous
##   FLIPPED  on its back for `flipped_time`: harmless, solid, motionless. Its last `WOBBLE_TIME` seconds the art
##            struggles (the telegraph). A player standing on it pins it: it only rights itself once nobody is on top
##   RIGHTING `righting_time`: turning back over, still harmless, then WALK
##
## Two Area2Ds, both mask 1 (actors), both polled in `_poll_player()` while it is upright:
##   StompZone  a strip over the top face, overlapping it by a couple of px so a player standing on it counts. A
##              player in it while falling or at rest (`velocity.y >= 0`) flips it, and is bounced by `stomp_bounce`.
##              Jumping up through it from the side does nothing.
##   Hazard     the body's footprint grown a couple of px at the sides, and stopping short of the top face. Calls
##              `take_hit()` on whatever has it, like Drillbot's drill. Stomp is tested first, so a player landing on a
##              corner is stomped, not hurt.
##
## Contracts other objects rely on:
##   take_damage(amount) -> int             the kick / laser contract: a kick flips an upright crawler (no damage); on
##                                          a flipped one it costs `health` points (one kick by default)
##   bowled_over(direction, speed) -> bool  the surf contract: always true, from either side, in every state
##   save_state() / load_state()            the checkpoint contract (group "saveable", see game.gd)
## Layers match Drillbot and Grunt: collision_layer 1 (the player stands on it, KickHitbox sees it), collision_mask 2.
##
## Runtime state lives in `_health` and `_facing`: `health` and `facing` are authored starting values only.

enum State { WALK, TURN, FLIPPED, RIGHTING }

## Which way the crawler starts facing. Mirrors the placeholder art in the editor.
@export_enum("Left:-1", "Right:1") var facing: int = -1:
	set(value):
		facing = value
		_facing = value
		_apply_facing()
## Kicks to destroy it once it is flipped. An upright crawler is only flipped by a kick, never damaged.
@export_range(1, 5) var health: int = 1

@export_group("Movement")
## Trundle speed, px/s.
@export var speed: float = 28.0
## Standing still at a wall or ledge before walking the other way (seconds).
@export var turn_pause: float = 0.4

@export_group("Flip")
## Time on its back before it starts to right itself (seconds). The last second of it is the struggle telegraph.
@export var flipped_time: float = 4.0
## Time spent turning back over (seconds), harmless.
@export var righting_time: float = 0.35
## Upward speed given to a player who stomps it, px/s. 0 turns the bounce off. The player's horizontal speed is kept.
@export var stomp_bounce: float = 140.0

@export_group("Attack")
## Damage per contact, passed to `take_hit()`.
@export var damage: int = 1
## Weight on a weight plate or see-saw, in block-mass units (metal 4, ice 1 per tile, the player 2). Counts only while
## it is alive and on the floor (`get_load_weight()`); 0 = it never presses anything. An authored value only.
@export_group("Load")
@export_range(0.0, 40.0, 0.5, "or_greater") var load_weight: float = 2.0
@export_group("")

const EXPLOSION_SCENE: PackedScene = preload("res://scenes/effects/explosion.tscn")
const HIT_FLASH_COLOR := Color(1.6, 0.5, 0.5)
const HIT_FLASH_DURATION := 0.2
const KNOCKOUT_DURATION := 0.7
const KNOCKOUT_THROW := Vector2(90.0, -45.0)  # px the art flies, x mirrored by the bowl direction
const KNOCKOUT_SPINS := 1.5  # turns while it flies

const FLOOR_SNAP := 6.0  # walks down slopes without hopping
const LEDGE_DROP := 12.0  # a floor within this far below the shifted body is not a ledge (a 45 degree slope is 7)
const DEFAULT_WIDTH := 14.0  # the body width the ledge probe falls back to if the shape isn't a rectangle
const FLIP_SECONDS := 0.2  # how long the art takes to roll over (it tracks `_flip_t`, 0 upright to 1 on its back)
const WOBBLE_TIME := 1.0  # the struggle at the end of FLIPPED
const WOBBLE_ANGLE := 0.14  # radians, peak
const WOBBLE_RATE := 38.0  # radians/s of the wobble's sine

var _health: int = 1
var _facing: int = -1
var _state: State = State.WALK
var _elapsed := 0.0  # seconds in the current state
var _duration := 0.0  # how long this state lasts (0 = WALK, which ends on a wall or ledge instead)
var _flip_t := 0.0  # 0 upright .. 1 on its back: drives the art's roll
var _dead := false
var _ledge_shift := DEFAULT_WIDTH + 1.0  # px the body is shifted forward for the ledge test: its width plus 1
var _hit_flash_tween: Tween

@onready var art: Node2D = $TreadCrawlerArt
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var stomp_zone: Area2D = $StompZone
@onready var hazard: Area2D = $Hazard

func _ready() -> void:
	_facing = facing
	_apply_facing()
	if Engine.is_editor_hint():
		return
	_health = health
	floor_snap_length = FLOOR_SNAP
	if body_shape.shape is RectangleShape2D:
		_ledge_shift = (body_shape.shape as RectangleShape2D).size.x + 1.0
	add_to_group("enemy")
	add_to_group("saveable")
	_enter_state(State.WALK)
	_apply_pose()

## Mirrors the art to the current facing. In the editor the `facing` export drives it; in play `_facing` does.
func _apply_facing() -> void:
	var node := get_node_or_null("TreadCrawlerArt") as Node2D
	if node != null:
		node.scale.x = float(_facing)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _dead:
		return
	if not is_on_floor():
		velocity.y += float(ProjectSettings.get_setting("physics/2d/default_gravity")) * delta
	_elapsed += delta
	_update_state()
	velocity.x = speed * _facing if _state == State.WALK else 0.0
	move_and_slide()
	_after_move()
	_poll_player()
	_flip_t = move_toward(_flip_t, 1.0 if _is_flipped() else 0.0, delta / FLIP_SECONDS)
	_apply_pose()

# --- state machine ---------------------------------------------------------------------------

func _enter_state(new_state: State) -> void:
	_state = new_state
	_elapsed = 0.0
	match new_state:
		State.WALK:
			_duration = 0.0
		State.TURN:
			_duration = maxf(turn_pause, 0.01)
		State.FLIPPED:
			_duration = maxf(flipped_time, 0.01)
		State.RIGHTING:
			_duration = maxf(righting_time, 0.01)

func _update_state() -> void:
	match _state:
		State.TURN:
			if _elapsed >= _duration:
				_enter_state(State.WALK)
		State.FLIPPED:
			# a player standing on it pins it: it rights itself only once the top is clear
			if _elapsed >= _duration and not _player_on_top():
				_enter_state(State.RIGHTING)
		State.RIGHTING:
			if _elapsed >= _duration:
				_enter_state(State.WALK)

## After the move: a wall or a ledge turns a walker round, after a beat standing still.
func _after_move() -> void:
	if _state != State.WALK:
		return
	if (is_on_wall() and get_wall_normal().x * _facing < 0.0) or _ledge_ahead():
		_facing = -_facing
		_apply_facing()
		_enter_state(State.TURN)

func _is_upright() -> bool:
	return _state == State.WALK or _state == State.TURN

func _is_flipped() -> bool:
	return _state == State.FLIPPED

## True if there is no floor just ahead. test_move() from the body shifted a step forward, going down: it honours
## one-way catwalks and counts a slope or a wall ahead as floor, so only a real drop reads as a ledge.
func _ledge_ahead() -> bool:
	if not is_on_floor():
		return false
	var shifted := Transform2D(0.0, global_position + Vector2(_ledge_shift * _facing, 0.0))
	return not test_move(shifted, Vector2(0.0, LEDGE_DROP))

# --- the player ------------------------------------------------------------------------------

## The player standing on, or landing on, the top face.
func _stomper(only_falling: bool) -> CharacterBody2D:
	for body in stomp_zone.get_overlapping_bodies():
		if not body.is_in_group("player"):
			continue
		if body.get("is_dead") == true or body.get("is_dancing") == true:
			continue
		var player := body as CharacterBody2D
		if player != null and (not only_falling or player.velocity.y >= 0.0):
			return player
	return null

func _player_on_top() -> bool:
	return _stomper(false) != null

## While upright: a falling or resting player on the top flips it (and is bounced); otherwise whatever is in the
## Hazard is hit. Stomp first, so a corner landing is a stomp. Polled each frame, like Drillbot's drill: take_hit()'s
## own invincibility window stops repeat hits from stacking.
func _poll_player() -> void:
	if not _is_upright():
		return
	var player := _stomper(true)
	if player != null:
		if stomp_bounce > 0.0 and player.has_method("launch"):
			player.launch(Vector2(player.velocity.x, -stomp_bounce))
		_flip()
		return
	for body in hazard.get_overlapping_bodies():
		if body != self and body.has_method("take_hit"):
			body.take_hit(damage, global_position)

func _flip() -> void:
	_enter_state(State.FLIPPED)
	velocity.x = 0.0
	Audio.play_at(&"enemies/crawler_flip", global_position, 2.0)
	_play_hit_feedback()

# --- art -------------------------------------------------------------------------------------

func _apply_pose() -> void:
	var wobble := 0.0
	if _state == State.FLIPPED and _elapsed >= _duration - WOBBLE_TIME:
		wobble = sin(_elapsed * WOBBLE_RATE) * WOBBLE_ANGLE
	art.scale.y = lerpf(1.0, -1.0, ease(_flip_t, -2.0) if _flip_t > 0.0 else 0.0)  # through 0: it rolls over
	art.rotation = wobble * float(_facing)
	if art.has_method("set_pose"):
		art.set_pose(not _is_upright())

# --- checkpoint ------------------------------------------------------------------------------

## Saveable contract (see game.gd): a destroyed crawler frees itself, so it is absent from the snapshot and the fresh
## copy is freed on restore, as with Drillbot and Grunt. Every state resumes as saved, a flipped one included.
func save_state() -> Dictionary:
	return {
		"position": global_position,
		"facing": _facing,
		"health": _health,
		"state": int(_state),
		"elapsed": _elapsed,
		"duration": _duration,
		"flip": _flip_t,
	}

func load_state(d: Dictionary) -> void:
	global_position = d.get("position", global_position)
	_facing = d.get("facing", _facing)
	_health = d.get("health", _health)
	_state = (d.get("state", int(State.WALK)) as int) as State
	_elapsed = d.get("elapsed", 0.0)
	_duration = d.get("duration", 0.0)
	_flip_t = d.get("flip", 1.0 if _is_flipped() else 0.0)
	velocity = Vector2.ZERO
	_apply_facing()
	_apply_pose()
	reset_physics_interpolation()

# --- damage and death ------------------------------------------------------------------------

## Kick contract. Upright: the kick flips it, no damage. On its back (or righting): costs `health` points. Returns 0
## until there is a scoring system.
func take_damage(amount: int = 1) -> int:
	if _dead:
		return 0
	if _is_upright():
		_flip()
		return 0
	_health -= maxi(amount, 1)
	Audio.play_at(&"enemies/crawler_hit", global_position, 4.0)
	if _health <= 0:
		_die()
	else:
		_play_hit_feedback()
	return 0

## Surf contract (objon.md, Surf: Bowling): bowled from either side, in every state, and thrown the way the surfer
## is travelling.
func bowled_over(direction: float, _surf_speed: float) -> bool:
	if _dead:
		return false
	_knock_out(signf(direction) if direction != 0.0 else float(-_facing))
	return true

func _play_hit_feedback() -> void:
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	art.modulate = Color.WHITE
	_hit_flash_tween = create_tween()
	_hit_flash_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_hit_flash_tween.tween_property(art, "modulate", HIT_FLASH_COLOR, 0.0)
	_hit_flash_tween.tween_property(art, "modulate", Color.WHITE, HIT_FLASH_DURATION)

## Retire the crawler now: no more physics, collisions, groups or queries, and nothing that can hurt. Shared by both
## ways of dying.
func _retire() -> void:
	_dead = true
	set_physics_process(false)
	remove_from_group("enemy")
	remove_from_group("saveable")  # a checkpoint taken during the knock-out tumble must not include it
	body_shape.set_deferred("disabled", true)
	stomp_zone.set_deferred("monitoring", false)
	hazard.set_deferred("monitoring", false)
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	art.modulate = Color.WHITE

## Killed by a kick while flipped: the standard explosion, like Drillbot and Grunt.
func _die() -> void:
	_retire()
	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)  # not on self: this node is about to be freed
	queue_free()

## Bowled: the art is thrown away spinning and fades out, then the node frees itself.
func _knock_out(direction: float) -> void:
	_retire()
	Audio.play_at(&"enemies/crawler_bowled", global_position, 6.0)
	var tween := create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.set_parallel(true)
	tween.tween_property(art, "position", art.position + Vector2(KNOCKOUT_THROW.x * direction, KNOCKOUT_THROW.y), KNOCKOUT_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(art, "rotation", TAU * KNOCKOUT_SPINS * direction, KNOCKOUT_DURATION)
	tween.tween_property(art, "modulate:a", 0.0, KNOCKOUT_DURATION * 0.4).set_delay(KNOCKOUT_DURATION * 0.6)
	tween.chain().tween_callback(queue_free)

## Weight contract, read by the weight plate and the see-saw (duck-typed, found through group "enemy"): `load_weight`
## while this body is alive and standing on something, else 0 (a body in the air presses nothing).
func get_load_weight() -> float:
	if _dead or not is_on_floor():
		return 0.0
	return load_weight
