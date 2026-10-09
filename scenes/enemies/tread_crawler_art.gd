@tool
extends Node2D

# Placeholder art for tread_crawler.tscn, plain shapes drawn in code until the tank's sprites exist. Drawn FACING
# RIGHT around the body's centre; the parent TreadCrawler mirrors it with this node's scale.x (its facing) and rolls
# it over with scale.y (1 upright, -1 on its back, passing through 0), so everything here is drawn for the upright pose.
#  - the hull is the body collider itself (read from the parent's CollisionShape2D, so it follows shape edits);
#  - the TOP face carries a pale plate: that is the stomp target, and when the crawler is flipped it ends up underneath;
#  - the treads are the dark strip along the bottom, which end up on top when it is flipped;
#  - a small lens marks the facing (+x) side.
# The hull is warning orange while the crawler is dangerous and dull grey while it is stunned (flipped or righting).
# Replace with an AnimatedSprite2D when there is art; TreadCrawler only needs `set_pose(stunned)` to exist, and skips
# it when it doesn't.

const HULL_LIVE := Color(0.95, 0.55, 0.15)
const HULL_STUNNED := Color(0.55, 0.57, 0.6)
const EDGE := Color(0.2, 0.24, 0.3)
const PLATE := Color(0.88, 0.9, 0.93)
const TREAD := Color(0.14, 0.16, 0.2)
const LENS := Color(0.35, 0.9, 0.95)

var stunned := false

func set_pose(is_stunned: bool) -> void:
	if is_stunned == stunned:
		return
	stunned = is_stunned
	queue_redraw()

func _draw() -> void:
	var crawler := get_parent()
	var size := Vector2(14.0, 10.0)
	var pos := Vector2.ZERO
	var shape_node := crawler.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node != null and shape_node.shape is RectangleShape2D:
		size = (shape_node.shape as RectangleShape2D).size
		pos = shape_node.position
	var top_left := pos - size * 0.5
	var hull := Rect2(top_left, size)
	draw_rect(hull, HULL_STUNNED if stunned else HULL_LIVE)
	draw_rect(Rect2(top_left.x + 1.0, top_left.y, size.x - 2.0, 2.0), PLATE)  # the stomp plate on the top face
	draw_rect(Rect2(top_left.x, top_left.y + size.y - 3.0, size.x, 3.0), TREAD)  # treads along the bottom
	draw_rect(Rect2(top_left.x + size.x - 4.0, top_left.y + 3.0, 3.0, 2.0), LENS)  # lens on the facing side
	draw_rect(hull, EDGE, false, 1.0)
