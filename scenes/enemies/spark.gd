extends Area2D
## A spark dripped by a Rail bot. Falls straight down (a little slower than the world's gravity so the player can read
## it, and capped), hurts the player on contact, and is gone on touching anything solid or after LIFETIME seconds.
##
## Deliberately inert towards everything else: it does not hurt or arm enemies and mines, it triggers no bullet or
## power contract, and it reacts with no liquid or tile system, so level designers can run sparks over anything without
## side effects. The one exception to "ignores everything" is that it stops on any body that is not the player, not in
## group "enemy" and not its emitter: tiles, doors, blocks, platforms.
##
## `damage` and `emitter` are set by the RailBot right after instancing, before add_child. This is placeholder art: a
## bright core with a short tail drawn in code (`_draw`).
##
## Scene layout: Spark (Area2D, this script, collision_layer 0, collision_mask 3 = actors + world, monitorable off)
##   - CollisionShape2D (circle)

const FALL_ACCEL := 360.0  # px/s^2
const MAX_FALL_SPEED := 170.0  # px/s
const LIFETIME := 3.0  # seconds, a backstop for a spark falling into a pit
const FLICKER_HZ := 14.0
const CORE := Color(1.0, 0.95, 0.6)
const TAIL := Color(1.0, 0.55, 0.15, 0.55)

var damage: int = 1
var emitter: Node
var _fall_speed := 0.0
var _age := 0.0

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	_fall_speed = minf(_fall_speed + FALL_ACCEL * delta, MAX_FALL_SPEED)
	global_position.y += _fall_speed * delta
	modulate.a = 0.75 + 0.25 * sin(_age * TAU * FLICKER_HZ)

func _on_body_entered(body: Node2D) -> void:
	if body == emitter or body.is_in_group("enemy"):
		return
	if body.is_in_group("player") and body.has_method("take_hit"):
		body.take_hit(damage, global_position)
	queue_free()

func _draw() -> void:
	draw_line(Vector2(0.0, -5.0), Vector2.ZERO, TAIL, 2.0)
	draw_rect(Rect2(-1.5, -1.5, 3.0, 3.0), CORE)
