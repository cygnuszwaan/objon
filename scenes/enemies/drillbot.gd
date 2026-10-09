extends CharacterBody2D
## Ground-patrol enemy. Walks back and forth across `patrol_distance` (each
## way from its spawn point), pausing to dwell at each end. With `patrol_distance`
## at 0 it has no set range and patrols freely instead, like the Tread crawler:
## it walks until a wall or a ledge is ahead, dwells there, and turns round.
##
## The drillbot's own body (this CharacterBody2D + its CollisionShape2D) is
## solid, harmless, and kickable — the player can stand on it like any other
## platform, or land a kick on it to deal damage. The drill is a separate,
## front-only DrillHazard Area2D that hurts the player on contact. Since the
## drill covers the front, "vulnerable from the back" falls out of the
## geometry rather than needing its own dedicated hitbox: walk up from the
## front and you hit the drill before you can land a kick; from the back
## there's nothing in the way.

# Collision setup (authored on the Drillbot node in drillbot.tscn, not here — noted for anyone
# reading only this script): collision_layer stays at the project default (1), so the player and
# KickHitbox still detect this body as solid/standable/kickable exactly as before. collision_mask
# is narrowed to 2 (ground only), dropping the player's layer (1) — without that, the drillbot's
# own move_and_slide() treated the player's weight as an obstacle, which on a slope bled off enough
# of its horizontal velocity to visibly slow it down whenever the player stood on top. The player
# still collides with (stands on, is blocked by) the drillbot as normal, since that's governed by
# the PLAYER's own mask, not the drillbot's — this is a one-directional exclusion, not mutual
# pass-through. Requires the ground tilemap to live on layer 2 rather than the old shared default
# (see test_level.tscn) — any other level's ground layer needs the same move, or the drillbot will
# fall through its own floor.
## Px each way from the spawn point. 0 = patrol freely: walk until a wall or a ledge, dwell, turn round.
@export_range(0.0, 512.0, 1.0, "or_greater") var patrol_distance: float = 96.0

var _speed: float = 40.0
var _dwell_time: float = 1.0
var _health: int = 3
const LEDGE_DROP := 12.0  # free patrol: a floor within this far below the shifted body is not a ledge (a 45 degree slope is 7)
const WALL_PROBE_MARGIN := 1.0  # free patrol: px beyond the drill's tip that the wall probe reaches
const FALLBACK_BODY_WIDTH := 24.0  # free patrol: the width the ledge probe assumes if the body shape isn't a polygon, rectangle or capsule
const DRILL_DAMAGE: int = 1  # dealt to the player on contact with DrillHazard; matches KICK_DAMAGE's placeholder-ness — tune once real hazard damage values exist

const EXPLOSION_SCENE: PackedScene = preload("res://scenes/effects/explosion.tscn")

# Hit feedback (shake + flash) — plays on any non-lethal hit; the killing hit skips straight to
# the death explosion instead (see take_damage/_die), so the two effects never overlap.
const HIT_FLASH_COLOR: Color = Color(1.6, 0.5, 0.5)  # reddish overbright; Compatibility renderer has
	# no bloom, so this just reads as a warm flash rather than a true HDR blow-out — tune to taste
const HIT_FLASH_DURATION: float = 0.2
const HIT_SHAKE_STRENGTH: float = 2.0  # px, random jitter radius
const HIT_SHAKE_STEPS: int = 5
const HIT_SHAKE_DURATION: float = 0.2  # total, across all steps

var _hit_flash_tween: Tween
var _hit_shake_tween: Tween

# Rename these to whatever's actually authored on the AnimatedSprite2D — guessed placeholders,
# not confirmed against a real SpriteFrames resource.
const TRAVEL_ANIM: StringName = &"move"
const DWELL_ANIM: StringName = &"idle"

var _facing: int = 1          # 1 = right (default), -1 = left
var _origin_x: float
var _dwelling: bool = false
var _dead: bool = false
var _ledge_shift: float = FALLBACK_BODY_WIDTH + 1.0  # free patrol: how far the body is shifted forward for the ledge test (its width plus 1)
var _drill_overhang: float = 0.0  # free patrol: how far the drill's tip sticks out past the body collider's front edge, so the wall probe reaches the tip

var _drill_loop: Audio.LoopPlayer
var _travel_loop: Audio.LoopPlayer

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var drill_hazard: Area2D = $DrillHazard
@onready var drill_hazard_shape: CollisionShape2D = $DrillHazard/CollisionShape2D

# Canonical (unflipped, i.e. _facing == -1 / flip_h == false) values, captured once in _ready()
# before anything gets mirrored. Everything in the scene was authored centered on local x = 0, so
# every one of these is just negated wholesale on flip rather than handled as a one-off case.
var _base_sprite_offset_x: float
var _base_sprite_position: Vector2
var _base_body_points: PackedVector2Array   # empty if body_shape isn't a ConvexPolygonShape2D
var _base_drill_points: PackedVector2Array  # empty if drill_hazard_shape isn't a ConvexPolygonShape2D


func _ready() -> void:
	add_to_group("enemy")
	add_to_group("saveable")
	_origin_x = global_position.x

	_base_sprite_offset_x = sprite.offset.x
	_base_sprite_position = sprite.position

	# .duplicate() so each Drillbot instance mirrors its own collider rather than all sharing
	# (and fighting over) the same underlying Resource if this scene is ever placed more than once.
	if body_shape.shape is ConvexPolygonShape2D:
		body_shape.shape = body_shape.shape.duplicate()
		_base_body_points = body_shape.shape.points
	if drill_hazard_shape.shape is ConvexPolygonShape2D:
		drill_hazard_shape.shape = drill_hazard_shape.shape.duplicate()
		_base_drill_points = drill_hazard_shape.shape.points

	_ledge_shift = _body_width() + 1.0
	_drill_overhang = maxf(_front_edge_x(body_shape, null) - _front_edge_x(drill_hazard_shape, drill_hazard), 0.0)
	_update_facing()
	sprite.play(TRAVEL_ANIM)

	_drill_loop = Audio.make_loop(&"enemies/drillbot_drill", -12.0)
	add_child(_drill_loop)
	_drill_loop.start()

	_travel_loop = Audio.make_loop(&"enemies/drillbot_travel", 6.0)
	add_child(_travel_loop)
	_travel_loop.start()


## Saveable contract (see game.gd). A killed bot frees itself, so it is absent from the snapshot and the fresh
## copy is freed on restore. `_origin_x` (the patrol centre) always comes from the scene. A bot saved mid-dwell
## restores walking: it is still at its patrol end, so it simply starts the dwell again (the dwell is an
## `await` and can't be resumed) and then turns round as usual.
func save_state() -> Dictionary:
	return {"position": global_position, "facing": _facing, "health": _health}

func load_state(d: Dictionary) -> void:
	global_position = d.get("position", global_position)
	_facing = d.get("facing", _facing)
	_health = d.get("health", _health)
	_dwelling = false
	velocity = Vector2.ZERO
	_update_facing()
	reset_physics_interpolation()


# Mirrors everything around this Drillbot's local x = 0, matching how the scene was authored,
# rather than the item 53/54 approach of nudging individual node positions and hoping it lined
# up. Handles three distinct kinds of asymmetry:
#  - flip_h + offset.x on the sprite (offset.x alone would leave the body visibly jumping on
#    flip — flip_h mirrors the texture in place around the sprite's *unflipped* rect, it does not
#    re-mirror offset for you)
#  - position.x on plain nodes (DrillHazard, its CollisionShape2D, body_shape) — covers a simple
#    positional offset, a no-op if that node is actually at local x = 0
#  - ConvexPolygonShape2D.points, negated per-point — a position mirror does nothing for an
#    asymmetric polygon; the points themselves have to flip
# The un-flipped AnimatedSprite2D frames face LEFT by default (per in-editor testing), so
# _facing == 1 (right) needs flip_h = true — the reverse of the more usual "frames default to
# facing right" assumption. Flip that boolean (and the mirror conditions below) if the art gets
# re-exported facing the other way.
func _update_facing() -> void:
	sprite.flip_h = _facing == 1
	sprite.offset.x = -_base_sprite_offset_x if sprite.flip_h else _base_sprite_offset_x

	drill_hazard.position.x = absf(drill_hazard.position.x) * _facing
	drill_hazard_shape.position.x = absf(drill_hazard_shape.position.x) * _facing
	body_shape.position.x = absf(body_shape.position.x) * _facing

	if not _base_body_points.is_empty():
		body_shape.shape.points = _mirrored_points(_base_body_points)
	if not _base_drill_points.is_empty():
		drill_hazard_shape.shape.points = _mirrored_points(_base_drill_points)


func _mirrored_points(base_points: PackedVector2Array) -> PackedVector2Array:
	if _facing == -1:
		return base_points  # matches the shape's authored (unflipped) orientation already
	var mirrored := PackedVector2Array()
	mirrored.resize(base_points.size())
	for i in base_points.size():
		mirrored[i] = Vector2(-base_points[i].x, base_points[i].y)
	return mirrored


func _physics_process(delta: float) -> void:
	if _dead:
		return

	if not is_on_floor():
		velocity.y += float(ProjectSettings.get_setting("physics/2d/default_gravity")) * delta

	if _dwelling:
		velocity.x = 0.0
	else:
		velocity.x = _speed * _facing
		if patrol_distance > 0.0:
			var traveled: float = global_position.x - _origin_x
			if (_facing == 1 and traveled >= patrol_distance) or (_facing == -1 and traveled <= -patrol_distance):
				_start_dwell()

	move_and_slide()

	# Free patrol (patrol_distance 0): after the move, a wall or a ledge ahead starts the dwell, then it turns round.
	if patrol_distance <= 0.0 and not _dwelling and (_wall_ahead() or _ledge_ahead()):
		_start_dwell()

	# Polling rather than a one-shot body_entered signal, same idiom flagged for future traps
	# (the saw's "take_hit polling pattern") — the drill is a standing hazard the player can dwell
	# against, not a one-shot event, and take_hit's own invincibility window is what keeps repeat
	# calls here from spamming damage every frame.
	for body in drill_hazard.get_overlapping_bodies():
		if body.has_method("take_hit"):
			body.take_hit(DRILL_DAMAGE, global_position)


## Horizontal extent of the body collider, for the ledge probe. The polygon's points are canonical (unmirrored), and the
## width is the same either way round.
func _body_width() -> float:
	var shape := body_shape.shape
	if shape is ConvexPolygonShape2D and not (shape as ConvexPolygonShape2D).points.is_empty():
		var low := INF
		var high := -INF
		for point in (shape as ConvexPolygonShape2D).points:
			low = minf(low, point.x)
			high = maxf(high, point.x)
		return high - low
	if shape is RectangleShape2D:
		return (shape as RectangleShape2D).size.x
	if shape is CapsuleShape2D:
		return (shape as CapsuleShape2D).radius * 2.0
	return FALLBACK_BODY_WIDTH


## Local x of a collider's front edge, in the canonical (unmirrored, facing left) frame, where the front is the most
## negative x. `holder` is the node the shape's node hangs from, or null if the shape's node is the body's own child.
## Positions go through absf() because `_update_facing()` normalises them that way.
func _front_edge_x(shape_node: CollisionShape2D, holder: Node2D) -> float:
	var x := -absf(shape_node.position.x)
	if holder != null:
		x -= absf(holder.position.x)
	var shape := shape_node.shape
	if shape is ConvexPolygonShape2D and not (shape as ConvexPolygonShape2D).points.is_empty():
		var low := INF
		for point in (shape as ConvexPolygonShape2D).points:
			low = minf(low, point.x)
		# the points were captured before any mirroring, and are canonical already
		return x + low
	if shape is RectangleShape2D:
		return x - (shape as RectangleShape2D).size.x * 0.5
	if shape is CapsuleShape2D:
		return x - (shape as CapsuleShape2D).radius
	if shape is CircleShape2D:
		return x - (shape as CircleShape2D).radius
	return x


## True if a wall is ahead of the DRILL'S TIP, not just of the body. The body collider is shorter than the drill (the
## drill is a separate Area2D out in front), so waiting for the body to touch the wall (`is_on_wall()`) turns it round
## only once the drill is already buried in it. This is a `test_move()` of the body forward by the drill's overhang plus
## a pixel; a hit counts only if it opposes the facing and is steeper than `floor_max_angle`, so a slope it can walk up is
## not a wall. `is_on_wall()` is kept as a backstop. (No raycast: test_move() sweeps the whole collider.)
func _wall_ahead() -> bool:
	if is_on_wall() and get_wall_normal().x * _facing < 0.0:
		return true
	if _drill_overhang <= 0.0:
		return false
	var probe := KinematicCollision2D.new()
	if not test_move(global_transform, Vector2((_drill_overhang + WALL_PROBE_MARGIN) * _facing, 0.0), probe):
		return false
	var normal := probe.get_normal()
	return normal.x * _facing < 0.0 and absf(normal.angle_to(up_direction)) > floor_max_angle + 0.01


## True if there is no floor just ahead. test_move() from the body shifted a step forward, going down: it honours
## one-way catwalks and counts a slope or a wall ahead as floor, so only a real drop reads as a ledge. The same
## probe as the Grunt and the Tread crawler.
func _ledge_ahead() -> bool:
	if not is_on_floor():
		return false
	var shifted := Transform2D(0.0, global_position + Vector2(_ledge_shift * _facing, 0.0))
	return not test_move(shifted, Vector2(0.0, LEDGE_DROP))


func _start_dwell() -> void:
	_dwelling = true
	velocity.x = 0.0
	_travel_loop.stop_loop()
	sprite.play(DWELL_ANIM)

	await get_tree().create_timer(_dwell_time, false).timeout
	if _dead:
		return

	_facing *= -1
	_update_facing()
	_dwelling = false
	_travel_loop.start()
	sprite.play(TRAVEL_ANIM)


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


## Surf contract (see objon.md, Planned: surfboard): bowlable only from behind, its vulnerable side. `direction` is the way
## the surfer is travelling, so a surfer travelling the way the drillbot faces is coming up behind it. From the drill side
## this returns false, the surfer is left to meet the drill hazard (and its take_hit() ends the surf), and the drill wins.
func bowled_over(direction: float, _surf_speed: float) -> bool:
	if _dead or signf(direction) != float(_facing):
		return false
	_die()
	return true

func _die() -> void:
	_dead = true
	set_physics_process(false)
	_drill_loop.stop_loop()
	_travel_loop.stop_loop()
	if _hit_flash_tween and _hit_flash_tween.is_valid():
		_hit_flash_tween.kill()
	if _hit_shake_tween and _hit_shake_tween.is_valid():
		_hit_shake_tween.kill()

	var explosion: AnimatedSprite2D = EXPLOSION_SCENE.instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)  # not add_child(explosion) on self — this node is about to
		# queue_free() and would take a child down with it before the animation finishes

	queue_free()
