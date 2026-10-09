@tool
extends Node2D

# Placeholder art for grunt.tscn, plain rectangles drawn in code until the android's sprites exist. Drawn FACING
# RIGHT around the body's centre; the parent Grunt mirrors it by setting this node's scale.x to its facing.
#  - the body is the 6x16 collider itself (read from the parent's CollisionShape2D, so it follows shape edits), with a
#    small visor on the facing side so the heading reads;
#  - the hammer is the hitbox itself (read from HammerPivot/Hammer/CollisionShape2D), drawn turned about the pivot by
#    `hammer_angle` (degrees from upright, positive = forward). Its colour is the state: grey = harmless, amber =
#    windup (the telegraph), red = the live swing.
# Replace with an AnimatedSprite2D (and a hammer sprite on HammerPivot) when there is art; Grunt only needs
# `set_pose(angle, mode)` to exist, and skips it when it doesn't.

const BODY := Color(0.45, 0.52, 0.6)
const BODY_EDGE := Color(0.2, 0.24, 0.3)
const VISOR := Color(0.35, 0.9, 0.95)
const HAMMER_INERT := Color(0.62, 0.64, 0.68)
const HAMMER_WINDUP := Color(1.0, 0.75, 0.2)
const HAMMER_LIVE := Color(1.0, 0.2, 0.15)

var hammer_angle := 0.0
var hammer_mode := 0  # 0 inert, 1 telegraph, 2 live

func set_pose(angle: float, mode: int) -> void:
	if is_equal_approx(angle, hammer_angle) and mode == hammer_mode:
		return
	hammer_angle = angle
	hammer_mode = mode
	queue_redraw()

func _draw() -> void:
	var grunt := get_parent()
	var body_size := Vector2(6.0, 16.0)
	var body_pos := Vector2.ZERO
	var body_shape_node := grunt.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if body_shape_node != null and body_shape_node.shape is RectangleShape2D:
		body_size = (body_shape_node.shape as RectangleShape2D).size
		body_pos = body_shape_node.position
	# body, then a visor on the facing (+x) side near the top
	draw_rect(Rect2(body_pos - body_size * 0.5, body_size), BODY)
	draw_rect(Rect2(body_pos - body_size * 0.5, body_size), BODY_EDGE, false, 1.0)
	draw_rect(Rect2(body_pos.x + body_size.x * 0.5 - 3.0, body_pos.y - body_size.y * 0.5 + 2.0, 3.0, 2.0), VISOR)

	# hammer: the hitbox rectangle, turned about the pivot
	var pivot := Vector2(0.0, -4.0)
	var hammer_pos := Vector2(0.0, -8.0)
	var hammer_size := Vector2(4.0, 16.0)
	var pivot_node := grunt.get_node_or_null("HammerPivot") as Node2D
	if pivot_node != null:
		pivot = pivot_node.position
	var shape_node := grunt.get_node_or_null("HammerPivot/Hammer/CollisionShape2D") as CollisionShape2D
	if shape_node != null and shape_node.shape is RectangleShape2D:
		hammer_size = (shape_node.shape as RectangleShape2D).size
		hammer_pos = shape_node.position
	var colour := HAMMER_INERT
	if hammer_mode == 1:
		colour = HAMMER_WINDUP
	elif hammer_mode == 2:
		colour = HAMMER_LIVE
	draw_set_transform(pivot, deg_to_rad(hammer_angle), Vector2.ONE)
	draw_rect(Rect2(hammer_pos - hammer_size * 0.5, hammer_size), colour)
	draw_rect(Rect2(hammer_pos - hammer_size * 0.5, hammer_size), BODY_EDGE, false, 1.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
