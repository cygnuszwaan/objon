extends CharacterBody2D
## Flying enemy that homes toward the player, trying to hold an aerial-diagonal hover spot
## (above and to one side) from which it jabs — its two Stinger `Area2D`s, bottom-left and
## bottom-right, cover both approach sides. It has a limited `flight_time` airborne before
## it must land and `recharge_time`, then launches again.
##
## Physics: default collision_layer (1, actor — same as Drillbot, so KickHitbox and
## take_damage work normally), collision_mask narrowed to 2 (world only). Same reasoning as
## Drillbot: excluding the player's own layer keeps the player's weight/position from
## disturbing this body's move_and_slide() results, which matters here too since seek/jab/
## recoil all drive velocity directly every frame.
##
## No obstacle avoidance yet — it seeks the hover position in a straight line and can get
## stuck against a wall between it and that spot. Fine for an open flight-lane test level;
## worth revisiting once a level actually boxes it in.
##
## Expected scene layout:
##   Stingbot (CharacterBody2D, this script, collision_layer=1 [default], collision_mask=2)
##     - AnimatedSprite2D   — FLY_ANIM / RECHARGE_ANIM below
##     - CollisionShape2D   — body: solid, standable, kickable, same as Drillbot
##     - StingerLeft (Area2D)  -> CollisionShape2D, near the sprite's bottom-left
##     - StingerRight (Area2D) -> CollisionShape2D, near the sprite's bottom-right

# Rename these to whatever's actually authored on the AnimatedSprite2D — guessed
# placeholders, not confirmed against real SpriteFrames resources (same caveat as Drillbot).
const FLY_ANIM: StringName = &"fly"
const RECHARGE_ANIM: StringName = &"recharge"

enum Phase { AIRBORNE, LANDING, RECHARGING, LAUNCHING }

@export var flight_time: float = 6.0    ## Seconds airborne before it must land and recharge.
@export var recharge_time: float = 2.0  ## Seconds spent landed before launching again.
## Weight on a weight plate or see-saw, in block-mass units (metal 4, ice 1 per tile, the player 2). Counts only while
## it is alive and on the floor (`get_load_weight()`); 0 = it never presses anything. An authored value only.
@export_group("Load")
@export_range(0.0, 40.0, 0.5, "or_greater") var load_weight: float = 1.0
@export_group("")

# Internal tuneables — not exported, same idiom as Bullet's `speed` / Drillbot's `_speed`.
var _fly_speed: float = 30.0
var _hover_offset: Vector2 = Vector2(24.0, -40.0)  # x = horizontal spread from player, y = height above
var _hover_arrival_tolerance: float = 4.0
var _attack_lunge_speed: float = 100.0
var _attack_duration: float = 0.4
var _recoil_speed: float = 120.0
var _recoil_duration: float = 0.6  # the "grace" window after a landed jab
var _landing_descend_speed: float = 30.0
var _launch_ascend_speed: float = 30.0
var _launch_duration: float = 0.5

var _health: int = 3
const STING_DAMAGE: int = 1  # placeholder-tune, matches DRILL_DAMAGE's status in drillbot.gd

const EXPLOSION_SCENE: PackedScene = preload("res://scenes/effects/explosion.tscn")

# Hit feedback (flash + shake) — identical to Drillbot's; if one changes, consider the other.
const HIT_FLASH_COLOR: Color = Color(1.6, 0.5, 0.5)
const HIT_FLASH_DURATION: float = 0.2
const HIT_SHAKE_STRENGTH: float = 2.0
const HIT_SHAKE_STEPS: int = 5
const HIT_SHAKE_DURATION: float = 0.2

var _hit_flash_tween: Tween
var _hit_shake_tween: Tween

var _phase: Phase = Phase.AIRBORNE
var _flight_timer: float = 0.0
var _recharge_timer: float = 0.0
var _launch_timer: float = 0.0
var _attack_timer: float = 0.0   # counts down through the jab lunge
var _recoil_timer: float = 0.0   # counts down through the post-jab grace window
var _dead: bool = false
var _chill := ChillState.new()  # the shared chill model; runtime only (see apply_chill())

var _player: Node2D

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var stinger_left: Area2D = $StingerLeft
@onready var stinger_right: Area2D = $StingerRight

var _base_sprite_position: Vector2


func _ready() -> void:
	add_to_group(&"enemy")
	add_to_group(&"saveable")
	_player = get_tree().get_first_node_in_group(&"player")
	_base_sprite_position = sprite.position
	_flight_timer = flight_time
	sprite.play(FLY_ANIM)


## Saveable contract (see game.gd). A killed bot frees itself, so it is absent from the snapshot and the fresh
## copy is freed on restore. Velocity isn't stored: every phase sets it each frame before moving.
func save_state() -> Dictionary:
	return {
		"position": global_position, "health": _health, "phase": int(_phase),
		"flight_timer": _flight_timer, "recharge_timer": _recharge_timer, "launch_timer": _launch_timer,
		"attack_timer": _attack_timer, "recoil_timer": _recoil_timer, "flip_h": sprite.flip_h,
	}

func load_state(d: Dictionary) -> void:
	global_position = d.get("position", global_position)
	_health = d.get("health", _health)
	_phase = d.get("phase", int(_phase))
	_flight_timer = d.get("flight_timer", _flight_timer)
	_recharge_timer = d.get("recharge_timer", _recharge_timer)
	_launch_timer = d.get("launch_timer", _launch_timer)
	_attack_timer = d.get("attack_timer", _attack_timer)
	_recoil_timer = d.get("recoil_timer", _recoil_timer)
	sprite.flip_h = d.get("flip_h", sprite.flip_h)
	sprite.play(RECHARGE_ANIM if _phase == Phase.RECHARGING else FLY_ANIM)
	velocity = Vector2.ZERO
	_chill.reset(sprite)
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_chill.update(delta)
	_chill.apply_tint_to(sprite)
	if _player == null or not is_instance_valid(_player):
		# player.gd joins group "player" in its own _ready(), so a Stingbot above the Player in the level tree finds
		# nothing in its _ready(): look again each frame until it is there (and after a respawn frees the old one).
		_player = get_tree().get_first_node_in_group(&"player")
		if _player == null:
			return

	match _phase:
		Phase.AIRBORNE:
			_process_airborne(delta)
		Phase.LANDING:
			_process_landing()
		Phase.RECHARGING:
			_process_recharging(delta)
		Phase.LAUNCHING:
			_process_launching(delta)

	move_and_slide()

	# Polling, same idiom as Drillbot's DrillHazard — a fixed hitbox that only actually
	# overlaps the player during a jab, no separate "am I attacking" gate needed for it.
	for stinger in [stinger_left, stinger_right]:
		for body in stinger.get_overlapping_bodies():
			if body.has_method(&"take_hit"):
				body.take_hit(STING_DAMAGE, global_position)


func _process_airborne(delta: float) -> void:
	_flight_timer -= delta
	if _flight_timer <= 0.0:
		_start_landing()
		return

	if _attack_timer > 0.0:
		_attack_timer -= delta
		velocity = (_player.global_position - global_position).normalized() * _attack_lunge_speed * _chill.speed_scale()
		if _attack_timer <= 0.0:
			_recoil_timer = _recoil_duration
		return

	if _recoil_timer > 0.0:
		_recoil_timer -= delta
		velocity = (global_position - _player.global_position).normalized() * _recoil_speed * _chill.speed_scale()
		return

	# Hover on whichever diagonal side of the player it's currently on, recomputed every
	# frame from actual position rather than latched — same "derive from reality, don't
	# track a flag" preference as the player's own state machine.
	var attack_side: int = -1 if global_position.x < _player.global_position.x else 1
	var target: Vector2 = _player.global_position + Vector2(_hover_offset.x * attack_side, _hover_offset.y)
	var to_target: Vector2 = target - global_position

	if to_target.length() <= _hover_arrival_tolerance:
		velocity = Vector2.ZERO
		_attack_timer = _attack_duration
	else:
		velocity = to_target.normalized() * _fly_speed * _chill.speed_scale()
		if absf(velocity.x) > 0.5:
			sprite.flip_h = velocity.x < 0.0


func _start_landing() -> void:
	_phase = Phase.LANDING
	velocity = Vector2(0.0, _landing_descend_speed * _chill.speed_scale())


func _process_landing() -> void:
	if is_on_floor():
		_phase = Phase.RECHARGING
		_recharge_timer = recharge_time
		velocity = Vector2.ZERO
		sprite.play(RECHARGE_ANIM)
	else:
		velocity = Vector2(0.0, _landing_descend_speed * _chill.speed_scale())


func _process_recharging(delta: float) -> void:
	velocity = Vector2.ZERO
	_recharge_timer -= delta
	if _recharge_timer <= 0.0:
		_phase = Phase.LAUNCHING
		_launch_timer = _launch_duration
		sprite.play(FLY_ANIM)


func _process_launching(delta: float) -> void:
	_launch_timer -= delta
	velocity = Vector2(0.0, -_launch_ascend_speed * _chill.speed_scale())
	if _launch_timer <= 0.0:
		_phase = Phase.AIRBORNE
		_flight_timer = flight_time


## Chill contract (duck-typed, `has_method("apply_chill")`): called every physics frame by a FreezeTurret's beam that ends on
## this body. `_chill` is the shared ChillState model: it slows the speeds below by `ChillState.MIN_SCALE` at full chill and
## turns the sprite blue over `ChillState.TINT_RISE_TIME` (`self_modulate`, so the hit flash on `modulate` is untouched).
## Runtime only, never saved: a restore comes back unchilled.
func apply_chill(strength: float) -> void:
	_chill.apply(strength)


func get_chill() -> float:
	return _chill.level


func _play_hit_feedback() -> void:
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	if _hit_shake_tween and _hit_shake_tween.is_valid():
		_hit_shake_tween.kill()
	sprite.modulate = Color.WHITE
	sprite.position = _base_sprite_position

	_hit_flash_tween = create_tween()
	_hit_flash_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_hit_flash_tween.tween_property(sprite, "modulate", HIT_FLASH_COLOR, 0.0)
	_hit_flash_tween.tween_property(sprite, "modulate", Color.WHITE, HIT_FLASH_DURATION)

	_hit_shake_tween = create_tween()
	_hit_shake_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	var step_duration := HIT_SHAKE_DURATION / HIT_SHAKE_STEPS
	for i in HIT_SHAKE_STEPS:
		var jitter := Vector2(randf_range(-HIT_SHAKE_STRENGTH, HIT_SHAKE_STRENGTH), randf_range(-HIT_SHAKE_STRENGTH, HIT_SHAKE_STRENGTH))
		_hit_shake_tween.tween_property(sprite, "position", _base_sprite_position + jitter, step_duration)
	_hit_shake_tween.tween_property(sprite, "position", _base_sprite_position, step_duration)


func take_damage(amount: int = 1) -> int:
	if _dead:
		return 0

	_health -= 1
	Audio.play_at(&"enemies/bot_takedamage", global_position, 6.0)

	if _health <= 0:
		_die()
	else:
		_play_hit_feedback()

	return 0  # TODO: real point value once a scoring system exists


func _die() -> void:
	_dead = true
	set_physics_process(false)
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	if _hit_shake_tween and _hit_shake_tween.is_valid():
		_hit_shake_tween.kill()

	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)  # not add_child on self — see Drillbot's _die for why

	queue_free()

## Weight contract, read by the weight plate and the see-saw (duck-typed, found through group "enemy"): `load_weight`
## while this body is alive and standing on something, else 0 (a body in the air presses nothing).
func get_load_weight() -> float:
	if _dead or not is_on_floor():
		return 0.0
	return load_weight
