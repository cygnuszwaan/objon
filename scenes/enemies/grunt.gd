@tool
extends CharacterBody2D
## Grunt: a skinny android with a hammer, and the main target for surf bowling.
##
## Behaviour (one `State` enum, decided each physics frame, like the player):
##   PAUSE   standing still, hammer upright, for a random time; then it usually walks on (maybe turned round)
##   WALK    wandering at `wander_speed`; turns at walls and ledges, and after a random time pauses
##   CHASE   the player is inside `aggro_radius` (and within `aggro_height` vertically): walks at `chase_speed`
##           toward them, stopping at a wall or ledge instead of turning; gives up beyond `lose_radius`
##   WINDUP  inside `attack_range`: stops, facing locked, hammer raised. The telegraph; the hammer is inert
##   SWING   the hammer comes down. The ONLY state in which the hammer hurts
##   RECOVER hammer down and inert, the grunt open; then back to CHASE (still aggro) or PAUSE
## There is no speed rule and no immunity: a surfing player bowls the grunt during the telegraph, before a swing
## can land, so bowl/hit ordering is settled by the windup rather than by special cases.
##
## The hammer is a separate Area2D (`HammerPivot/Hammer`, mask 1) that holds the hitbox shape; hits come from a swept
## shape query of that shape every physics frame (see `_sweep_hammer()`), which calls `take_hit()` on whatever has it,
## but only while the state is SWING. It is not mirrored
## by scale (a negative scale on a collider is unreliable): `HammerPivot.rotation` is the shared hammer angle times
## the facing, so the same angle turns the collider and, through `GruntArt.hammer_angle`, the placeholder art.
##
## Contracts other objects rely on (unchanged):
##   take_damage(amount) -> int             the kick / laser contract: `health` points, two kicks by default
##   bowled_over(direction, speed) -> bool  the surf contract: always true, from either side, in every state
##   save_state() / load_state()            the checkpoint contract (group "saveable", see game.gd)
## Layers match Drillbot: collision_layer 1 (the player stands on it, KickHitbox sees it), collision_mask 2.
##
## Runtime state lives in `_health` and `_facing`: `health` and `facing` are authored starting values only.

enum State { PAUSE, WALK, CHASE, WINDUP, SWING, RECOVER }

## Which way the grunt starts facing (the hammer is on this side). Mirrors the placeholder art in the editor.
@export_enum("Left:-1", "Right:1") var facing: int = -1:
	set(value):
		facing = value
		_facing = value
		_apply_facing()
## Kicks to knock it out. Bowling ignores this: it is always instant.
@export_range(1, 5) var health: int = 2

@export_group("Patrol")
## Wander speed, px/s.
@export var wander_speed: float = 24.0
## A walk lasts a random time in this range (seconds)...
@export var walk_time_min: float = 1.0
@export var walk_time_max: float = 3.0
## ...and so does a pause.
@export var pause_time_min: float = 0.6
@export var pause_time_max: float = 2.0
## Chance that a grunt turns round when a pause ends (otherwise it keeps its heading).
@export_range(0.0, 1.0) var turn_chance: float = 0.5

@export_group("Aggro")
## The player this close (px, horizontally) wakes it up.
@export var aggro_radius: float = 96.0
## It lets go of a chase only beyond this (px), so the edge of the radius doesn't flicker it.
@export var lose_radius: float = 144.0
## Vertical reach of the aggro and the attack (px, either way): a player on another floor is ignored.
@export var aggro_height: float = 40.0
## Chase speed, px/s.
@export var chase_speed: float = 44.0
## Horizontal distance (px, centre to centre) at which it stops and starts the windup. The hammer reaches
## about 16 px from the grunt's centre (it first connects around 63-76 degrees into the downswing), a kick about 13 px
## from the player's.
@export var attack_range: float = 14.0

@export_group("Attack")
## The telegraph: hammer rising, harmless (seconds).
@export var windup_time: float = 0.6
## The live part (seconds): the hammer comes down.
@export var swing_time: float = 0.15
## Hammer down and harmless, grunt open to a kick (seconds).
@export var recover_time: float = 0.9
## Damage per swing, passed to `take_hit()`.
@export var damage: int = 1
## Hammer angle at the top of the windup, degrees from upright, positive = forward (the facing side).
@export var windup_angle_degrees: float = -70.0
## Hammer angle at the end of the swing, degrees.
@export var swing_angle_degrees: float = 115.0
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

const LEDGE_PROBE_SHIFT := 7.0  # px the body is shifted forward for the ledge test: its 6 px width plus 1, so the shifted body
	# has floor under it only while the floor reaches more than 1 px past the grunt's front edge (it turns with the centre 4 px from the edge)
const LEDGE_DROP := 12.0  # a floor within this far below the shifted body is not a ledge (a 45 degree slope is 7)
const FLOOR_SNAP := 6.0  # walks down slopes without hopping (the same idea as the player's slope snap)
const FACE_DEADZONE := 2.0  # px: closer than this in x, the grunt keeps its facing instead of flickering
const HAMMER_SWEEP_STEP_DEGREES := 6.0  # arc between two hit tests: about 1.7 px at the hammer's tip
const RECOVER_HOLD := 0.5  # fraction of the recover time the hammer stays down before it is raised again

var _health: int = 2
var _facing: int = -1
var _state: State = State.PAUSE
var _elapsed := 0.0  # seconds in the current state
var _duration := 1.0  # how long this state lasts (random for PAUSE and WALK)
var _swing_hit := false  # the live swing has already hurt someone: one hit per swing
var _edge_turned := false  # the pause it is in began with a wall/ledge turn, so it must not roll the random turn too (runtime only, not saved)
var _prev_hammer_angle := 0.0  # last frame's angle: where this frame's sweep starts
var _hammer_angle := 0.0  # degrees, art-local (facing right); 0 = upright, positive = forward
var _dead := false
var _chill := ChillState.new()  # the shared chill model; runtime only (see apply_chill())
var _player: Node2D
var _hit_flash_tween: Tween

@onready var art: Node2D = $GruntArt
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var hammer_pivot: Node2D = $HammerPivot
@onready var hammer: Area2D = $HammerPivot/Hammer

func _ready() -> void:
	_facing = facing
	_apply_facing()
	if Engine.is_editor_hint():
		return
	_health = health
	floor_snap_length = FLOOR_SNAP
	hammer.monitoring = false  # the Hammer Area2D only holds the shape and mask; hits come from _sweep_hammer()
	add_to_group("enemy")
	add_to_group("saveable")
	_enter_state(State.PAUSE)
	_apply_hammer_pose()

## Mirrors the art to the current facing. In the editor the `facing` export drives it; in play `_facing` does.
func _apply_facing() -> void:
	var node := get_node_or_null("GruntArt") as Node2D
	if node != null:
		node.scale.x = float(_facing)
	_apply_hammer_pose()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _dead:
		return
	_chill.update(delta)
	_chill.apply_tint_to(art)
	_resolve_player()
	if not is_on_floor():
		velocity.y += float(ProjectSettings.get_setting("physics/2d/default_gravity")) * delta
	_elapsed += delta
	var was_swinging := _state == State.SWING
	_update_state()
	velocity.x = _desired_vx()
	move_and_slide()
	_after_move()
	if was_swinging:
		# a frame that ends the swing still tests the arc up to the final pose, which the state no longer shows
		var end_angle := _target_hammer_angle() if _state == State.SWING else swing_angle_degrees
		_sweep_hammer(_prev_hammer_angle, end_angle)
	_apply_hammer_pose()
	_prev_hammer_angle = _hammer_angle

# --- state machine ---------------------------------------------------------------------------

func _enter_state(new_state: State) -> void:
	_state = new_state
	_elapsed = 0.0
	match new_state:
		State.PAUSE:
			_duration = randf_range(pause_time_min, maxf(pause_time_min, pause_time_max))
		State.WALK:
			_duration = randf_range(walk_time_min, maxf(walk_time_min, walk_time_max))
		State.CHASE:
			_duration = 0.0
			_edge_turned = false
		State.WINDUP:
			_duration = maxf(windup_time, 0.01)
			Audio.play_at(&"enemies/grunt_windup", global_position, 0.0)
		State.SWING:
			_duration = maxf(swing_time, 0.01)
			_swing_hit = false
			_prev_hammer_angle = windup_angle_degrees  # the sweep starts from the top of the windup
			Audio.play_at(&"enemies/grunt_swing", global_position, 0.0)
		State.RECOVER:
			_duration = maxf(recover_time, 0.01)

## Transitions, decided from the world each frame. The aggro test is the only thing that pulls it out of a
## wander; once it has committed to an attack the windup/swing/recover run to the end regardless.
func _update_state() -> void:
	match _state:
		State.PAUSE:
			if _player_in_aggro(aggro_radius):
				_enter_state(State.CHASE)
			elif _elapsed >= _duration:
				if not _edge_turned and randf() < turn_chance:
					_set_facing(-_facing)
				_edge_turned = false
				_enter_state(State.WALK)
		State.WALK:
			if _player_in_aggro(aggro_radius):
				_enter_state(State.CHASE)
			elif _elapsed >= _duration:
				_enter_state(State.PAUSE)
		State.CHASE:
			if not _player_in_aggro(lose_radius):
				_enter_state(State.PAUSE)
			else:
				_face_player()
				if _player_in_attack_range():
					_enter_state(State.WINDUP)
		State.WINDUP:
			if _elapsed >= _duration:
				_enter_state(State.SWING)
		State.SWING:
			if _elapsed >= _duration:
				_enter_state(State.RECOVER)
		State.RECOVER:
			if _elapsed >= _duration:
				_enter_state(State.CHASE if _player_in_aggro(aggro_radius) else State.PAUSE)

func _desired_vx() -> float:
	match _state:
		State.WALK:
			return wander_speed * _facing * _chill.speed_scale()
		State.CHASE:
			# stands at a ledge rather than walking off it (a wall stops it through the move itself)
			if _ledge_ahead():
				return 0.0
			return chase_speed * _facing * _chill.speed_scale()
	return 0.0

## After the move: a wall or a ledge turns a wanderer round. A chaser does neither, it just stops (see above).
func _after_move() -> void:
	if _state != State.WALK:
		return
	if (is_on_wall() and get_wall_normal().x * _facing < 0.0) or _ledge_ahead():
		_set_facing(-_facing)
		_enter_state(State.PAUSE)  # a beat at the edge, then it walks the way it now faces
		_edge_turned = true

# --- sensing ---------------------------------------------------------------------------------

func _resolve_player() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D

func _player_alive() -> bool:
	if _player == null:
		return false
	var dead: Variant = _player.get("is_dead")
	var dancing: Variant = _player.get("is_dancing")
	return not (dead == true or dancing == true)

func _player_in_aggro(radius: float) -> bool:
	if not _player_alive():
		return false
	var d := _player.global_position - global_position
	return absf(d.x) <= radius and absf(d.y) <= aggro_height

func _player_in_attack_range() -> bool:
	var d := _player.global_position - global_position
	return absf(d.x) <= attack_range and absf(d.y) <= aggro_height * 0.5

func _face_player() -> void:
	var dx := _player.global_position.x - global_position.x
	if absf(dx) > FACE_DEADZONE:
		_set_facing(1 if dx > 0.0 else -1)

func _set_facing(value: int) -> void:
	if value == _facing:
		return
	_facing = value
	_apply_facing()

## True if there is no floor just ahead. test_move() from the body shifted a step forward, going down: it honours
## one-way catwalks and counts a slope or a wall ahead as floor, so only a real drop reads as a ledge.
func _ledge_ahead() -> bool:
	if not is_on_floor():
		return false
	var shifted := Transform2D(0.0, global_position + Vector2(LEDGE_PROBE_SHIFT * _facing, 0.0))
	return not test_move(shifted, Vector2(0.0, LEDGE_DROP))

# --- hammer ----------------------------------------------------------------------------------

## The hammer angle for the current state and phase (degrees, art-local).
func _target_hammer_angle() -> float:
	var t := clampf(_elapsed / _duration, 0.0, 1.0) if _duration > 0.0 else 0.0
	match _state:
		State.WINDUP:
			return lerpf(0.0, windup_angle_degrees, ease(t, 0.4))  # eases out: a quick lift that settles at the top
		State.SWING:
			return lerpf(windup_angle_degrees, swing_angle_degrees, ease(t, 2.0))  # eases in: it accelerates down
		State.RECOVER:
			if t < RECOVER_HOLD:
				return swing_angle_degrees
			return lerpf(swing_angle_degrees, 0.0, ease((t - RECOVER_HOLD) / (1.0 - RECOVER_HOLD), -2.0))
	return 0.0

func _apply_hammer_pose() -> void:
	if hammer_pivot == null:
		return
	if not Engine.is_editor_hint():
		_hammer_angle = _target_hammer_angle()
	else:
		_hammer_angle = 0.0
	hammer_pivot.rotation = deg_to_rad(_hammer_angle) * float(_facing)
	var art_node := get_node_or_null("GruntArt")
	if art_node != null and art_node.has_method("set_pose"):
		var mode := 0  # 0 inert, 1 telegraph (windup), 2 live (swing): what the placeholder hammer's colour says
		if not Engine.is_editor_hint():
			mode = 2 if _state == State.SWING else (1 if _state == State.WINDUP else 0)
		art_node.set_pose(_hammer_angle, mode)

## The live hit test. An Area2D overlap would be a physics step stale, and the swing eases in so most of its angle is
## covered in its last few frames (a stale poll never saw the hammer below about 40 degrees, so only a player pressed
## against the grunt was hit and a crouching or surfing one ducked it). So this is an immediate shape query of the
## hammer rectangle at every `HAMMER_SWEEP_STEP_DEGREES` along the arc travelled since the last frame, ending on the
## pose it is about to be drawn in. Calls `take_hit()` on any body with it, one hit per swing, counted only when
## `take_hit()` returns true (a hit eaten by i-frames can still land later in the swing).
func _sweep_hammer(from_angle: float, to_angle: float) -> void:
	if _swing_hit:
		return
	var shape_node := hammer.get_node("CollisionShape2D") as CollisionShape2D
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape_node.shape
	query.collision_mask = hammer.collision_mask
	query.exclude = [get_rid()]
	var pivot_pos := hammer_pivot.global_position
	var steps := maxi(1, ceili(absf(to_angle - from_angle) / HAMMER_SWEEP_STEP_DEGREES))
	for i in range(1, steps + 1):
		var a := deg_to_rad(lerpf(from_angle, to_angle, float(i) / float(steps))) * float(_facing)
		query.transform = Transform2D(a, pivot_pos + (hammer.position + shape_node.position).rotated(a))
		for hit in get_world_2d().direct_space_state.intersect_shape(query, 8):
			var body := hit.get("collider") as Node
			if body != null and body.has_method("take_hit") and body.take_hit(damage, global_position):
				_swing_hit = true
				return

# --- checkpoint ------------------------------------------------------------------------------

## Saveable contract (see game.gd): a knocked-out grunt frees itself, so it is absent from the snapshot and the fresh
## copy is freed on restore, as with Drillbot. The attack states aren't resumed: a grunt saved in a WINDUP or a
## SWING comes back in RECOVER (hammer down, harmless), so a restore can never land a surprise hit.
func save_state() -> Dictionary:
	return {
		"position": global_position,
		"facing": _facing,
		"health": _health,
		"state": int(_state),
		"elapsed": _elapsed,
		"duration": _duration,
	}

func load_state(d: Dictionary) -> void:
	global_position = d.get("position", global_position)
	_facing = d.get("facing", _facing)
	_health = d.get("health", _health)
	velocity = Vector2.ZERO
	var saved_state: int = d.get("state", int(State.PAUSE))
	if saved_state == State.WINDUP or saved_state == State.SWING:
		_enter_state(State.RECOVER)
	else:
		_state = saved_state as State
		_elapsed = d.get("elapsed", 0.0)
		_duration = d.get("duration", 1.0)
	_swing_hit = false
	_chill.reset(art)
	_apply_facing()
	reset_physics_interpolation()

# --- damage and death ------------------------------------------------------------------------

## Chill contract (duck-typed, `has_method("apply_chill")`): called every physics frame by a FreezeTurret's beam that ends on
## this body. `_chill` is the shared ChillState model: it slows its walk and chase speed by `ChillState.MIN_SCALE` at full chill and
## turns `art` blue over `ChillState.TINT_RISE_TIME` (`self_modulate`, so the hit flash on `modulate` is untouched).
## Runtime only, never saved: a restore comes back unchilled.
func apply_chill(strength: float) -> void:
	_chill.apply(strength)

func get_chill() -> float:
	return _chill.level

## Kick contract: `amount` is honoured here (Drillbot's ignores it). Returns 0 until there is a scoring system.
func take_damage(amount: int = 1) -> int:
	if _dead:
		return 0
	_health -= maxi(amount, 1)
	Audio.play_at(&"enemies/grunt_hit", global_position, 4.0)
	if _health <= 0:
		_die()
	else:
		_play_hit_feedback()
	return 0

## Surf contract (objon.md, Surf: Bowling): called by the surfing player's bowl sweep above its bowl speed.
## Returns true if the grunt was knocked out. A grunt can be bowled from either side, in every state; only Drillbot
## is directional. `direction` is -1/+1, the way the surfer is travelling, and the grunt is thrown that way.
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

## Retire the grunt now: no more physics, collisions, groups or queries, and a hammer that can't hurt. Shared by
## both ways of dying.
func _retire() -> void:
	_dead = true
	set_physics_process(false)
	remove_from_group("enemy")
	remove_from_group("saveable")  # a checkpoint taken during the knock-out tumble must not include it
	body_shape.set_deferred("disabled", true)
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	art.modulate = Color.WHITE

## Killed by kicks: the standard explosion, like Drillbot.
func _die() -> void:
	_retire()
	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)  # not on self: this node is about to be freed
	queue_free()

## Bowled: the art is thrown away spinning and fades out, then the node frees itself.
func _knock_out(direction: float) -> void:
	_retire()
	Audio.play_at(&"enemies/grunt_bowled", global_position, 6.0)
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
