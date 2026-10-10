extends RigidBody2D
## A spark dripped by a Rail bot: a small glowing ball. It falls, rolls down slopes, is carried by conveyor belts, and
## despawns once it has been stationary for a moment (it does not creep off flat floors). It hurts the player on touch.
##
## Deliberately inert towards everything else: it does not hurt or arm enemies and mines and triggers no bullet, laser or
## power contract. The one system it touches is a basin's settled water: reaching the surface electrifies the pool and
## spends the spark (see `_poll_water()`); flowing particles, steam, slag and crusted basins ignore it as before, so
## level designers can still run sparks over anything else without side effects. It sits on physics layer 0 (nothing queries it: kicks, bowling, mine blasts, laser rays, bullets, button
## and plate sensors, the see-saw's load scan all miss it) and masks only layer 2, so it collides with the world (tiles,
## platforms, doors, belts, blocks) and never with actors, the player included.
##
## Motion is hand-integrated like the meltable blocks: gravity is added in _integrate_forces() (gravity_scale 0) so it
## falls at the same slow FALL_ACCEL as before, and the engine only solves contacts. The ball has friction, so on a
## slope it rolls; a rolling resistance slows the spin on any floor (strong on a near-flat one, weak on a slope), so a
## ball on the flat comes to rest within a few tiles and a very shallow slope holds it. A belt (any body with get_conveyor_speed(), the same duck-typed contract the player and blocks read)
## drags the ball's horizontal speed toward the belt's at BELT_GRIP while the ball rests on it, and the ball's spin
## follows so it keeps rolling.
##
## Stationary means: it has stayed within REST_DISTANCE of one spot for REST_TIME. That is judged on position, not
## velocity, because a resting body's velocity is never quite zero (the solver cancels the gravity added each step and
## leaves a few px/s) and a ball carried into a wall by a belt twitches against it; it also despawns a ball creeping
## below about 5 px/s. It then fades out over FADE_TIME, harmless. LIFETIME is a backstop for a ball falling into a
## pit or circling a loop of belts forever.
##
## Contact damage is a child Hitbox Area2D (mask 1) polled every physics frame, like Sawwheel and Crusher; the ball is
## consumed by the player whether or not the hit landed (i-frames), as before.
##
## `damage` is set by the RailBot right after instancing, before add_child. Placeholder art: a glowing ball with a speck
## on the rim so the roll reads, and a short tail behind its motion, drawn in code (`_draw`).
##
## Scene layout: Spark (RigidBody2D, this script, collision_layer 0, collision_mask 2, contact_monitor on)
##   - CollisionShape2D (circle, RADIUS)
##   - Hitbox (Area2D, layer 0, mask 1)
##       - CollisionShape2D (circle, HIT_RADIUS)

const RADIUS := 3.0
const HIT_RADIUS := 4.0  # a little bigger than the ball, so a graze reads as a hit
const FALL_ACCEL := 360.0  # px/s^2, slower than world gravity so the ball reads
const MAX_FALL_SPEED := 170.0  # px/s, vertical
const MAX_SPEED := 220.0  # px/s, total: a long slope can't build up a speed the player can't read
const FLAT_RESISTANCE := 480.0  # spin taken off a rolling ball on a near-flat floor, px/s^2 at the rim (about a quarter of that as linear deceleration): stops 200 px/s in about 12 tiles
const SLOPE_RESISTANCE := 120.0  # the same on a slope, so a slope still rolls the ball but one under about 7 degrees holds it
const FLAT_NORMAL_X := 0.12  # a floor whose normal leans less than this (about 7 degrees) is flat
const BELT_GRIP := 600.0  # px/s^2 toward the belt's speed while resting on it
const FLOOR_MIN_NORMAL_Y := 0.7  # a contact counts as a floor (resting on it, belts read from it) when its normal is within about 45 degrees of vertical
const WALL_MIN_NORMAL_X := 0.7  # a contact this close to horizontal is a wall
const REST_DISTANCE := 2.0  # px: the ball counts as stationary while it stays within this of where it settled
const REST_TIME := 0.4  # seconds stationary before it despawns
const FADE_TIME := 0.2  # seconds; 0 despawns at once
const LIFETIME := 15.0  # seconds
const FLICKER_HZ := 14.0
const CORE := Color(1.0, 0.95, 0.6)
const GLOW := Color(1.0, 0.55, 0.15, 0.55)

var damage: int = 1
var _age := 0.0
var _rest_time := 0.0  # seconds spent within REST_DISTANCE of _rest_anchor
var _rest_anchor := Vector2.ZERO
var _fade := -1.0  # seconds left of the fade-out; negative = not fading
var _hitbox: Area2D
var _manager: Node  # the level's WaterManager, looked up once (null if the level has none)
var _manager_searched := false

func _ready() -> void:
	_hitbox = $Hitbox
	_rest_anchor = global_position
	# Engine-side setup lives in the scene; the two that matter most are restated here because a change to either breaks
	# the despawn or the hand-integrated motion silently.
	gravity_scale = 0.0  # gravity is added by hand in _integrate_forces()
	can_sleep = false  # a sleeping body stops running _integrate_forces(), so it would never despawn

func _physics_process(delta: float) -> void:
	_age += delta
	if _fade >= 0.0:
		_fade -= delta
		modulate.a = clampf(_fade / FADE_TIME, 0.0, 1.0) if FADE_TIME > 0.0 else 0.0
		if _fade <= 0.0:
			queue_free()
		queue_redraw()
		return
	if global_position.distance_to(_rest_anchor) > REST_DISTANCE:
		_rest_anchor = global_position
		_rest_time = 0.0
	else:
		_rest_time += delta
	if _age >= LIFETIME or _rest_time >= REST_TIME:
		_begin_fade()
		return
	modulate.a = 0.75 + 0.25 * sin(_age * TAU * FLICKER_HZ)
	_poll_player()
	if is_queued_for_deletion():
		return  # the player took it this frame
	_poll_water()
	queue_redraw()

## Reaching a basin's settled water surface electrifies the pool (WaterBasin.try_electrify_at(), which decides whether
## this basin conducts) and spends the spark. A basin that refuses (slag, a crust, `conducts_sparks` off) leaves the
## spark falling through as before. Asked each frame with the ball's lowest point; the manager is found once.
func _poll_water() -> void:
	if not _manager_searched:
		_manager_searched = true
		_manager = get_tree().get_first_node_in_group("water_manager")
	if _manager == null:
		return
	var low := global_position + Vector2(0.0, RADIUS)
	var basin: WaterBasin = _manager.find_basin_at_point(low)
	if basin != null and basin.try_electrify_at(low):
		queue_free()

func _begin_fade() -> void:
	_fade = FADE_TIME
	if FADE_TIME <= 0.0:
		queue_free()

func _poll_player() -> void:
	for body in _hitbox.get_overlapping_bodies():
		if body.is_in_group("player"):
			if body.has_method("take_hit"):
				body.take_hit(damage, global_position)
			queue_free()
			return

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	var step := state.step
	var vel := state.linear_velocity
	var spin := state.angular_velocity

	# Contacts from the last step. The normal's sign depends on which side the engine reports it from, so only its
	# vertical size is used, and the contact must be below the ball's centre to be a floor.
	var on_floor := false
	var floor_lean := 1.0  # smallest |normal.x| of the floor contacts: 0 = flat
	var belt := 0.0
	var on_belt := false
	var wall_side := 0  # -1/+1: a wall touches the ball's left/right
	for i in state.get_contact_count():
		var normal := state.get_contact_local_normal(i)
		var point := state.get_contact_local_position(i)
		if absf(normal.x) > WALL_MIN_NORMAL_X:
			wall_side = 1 if point.x > state.transform.origin.x else -1
			continue
		if absf(normal.y) < FLOOR_MIN_NORMAL_Y or point.y <= state.transform.origin.y:
			continue
		on_floor = true
		floor_lean = minf(floor_lean, absf(normal.x))
		var collider := state.get_contact_collider_object(i)
		if collider != null and collider.has_method("get_conveyor_speed"):
			belt = collider.get_conveyor_speed()
			on_belt = true

	vel.y = minf(vel.y + FALL_ACCEL * step, MAX_FALL_SPEED)
	if on_belt:
		if wall_side != 0 and signf(belt) == float(wall_side):
			# Carried into a wall: hold still against it. Pushing on would make the solver bounce the ball off the wall
			# every step, and a jittering ball never reads as at rest.
			vel.x = 0.0 if vel.x * wall_side > 0.0 else vel.x
			spin = 0.0
		else:
			vel.x = move_toward(vel.x, belt, BELT_GRIP * step)
			spin = vel.x / RADIUS  # keep the spin matching the carried speed so the contact friction doesn't fight the belt
	elif on_floor:
		var resistance := FLAT_RESISTANCE if floor_lean < FLAT_NORMAL_X else SLOPE_RESISTANCE
		spin = move_toward(spin, 0.0, resistance / RADIUS * step)
	if vel.length() > MAX_SPEED:
		vel = vel.limit_length(MAX_SPEED)
	state.linear_velocity = vel
	state.angular_velocity = spin

func _draw() -> void:
	# The tail and glow stay upright and trail the motion; only the rim speck turns with the ball.
	draw_set_transform(Vector2.ZERO, -global_rotation)
	var speed := linear_velocity.length()
	if speed > 12.0:
		var back := -linear_velocity / speed
		draw_line(Vector2.ZERO, back * minf(speed * 0.04, 6.0), GLOW, 2.0)
	draw_set_transform(Vector2.ZERO, 0.0)
	draw_circle(Vector2.ZERO, RADIUS, GLOW)
	draw_circle(Vector2.ZERO, RADIUS - 1.2, CORE)
	draw_rect(Rect2(RADIUS - 2.2, -0.5, 1.6, 1.0), Color(1.0, 1.0, 1.0))
