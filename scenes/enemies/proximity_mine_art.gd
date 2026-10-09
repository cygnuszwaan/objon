@tool
extends Node2D

# Placeholder art for proximity_mine.tscn, plain shapes drawn in code until the mine's sprites exist, around the body's
# centre. Not mirrored: the mine is symmetric.
#  - a squat hull (the body collider itself, read from the parent's CollisionShape2D) with three short prongs on top;
#  - a light on top: dim while dormant; once armed it blinks bright red, faster as the fuse runs down;
#  - once armed, a ring and a faint fill showing the blast radius, so the danger zone is readable (and on a phone,
#    where the player can't judge distance by eye as well);
#  - in the editor only, the trigger box (cyan) and the blast circle (red) so a level designer can see the reach.
# Replace with an AnimatedSprite2D when there is art; ProximityMine only needs `set_pose(armed, blink_on, fuse)` to
# exist, and skips it when it doesn't.

const HULL := Color(0.36, 0.4, 0.46)
const EDGE := Color(0.14, 0.17, 0.22)
const PRONG := Color(0.62, 0.64, 0.68)
const LIGHT_DORMANT := Color(0.45, 0.1, 0.1)
const LIGHT_ON := Color(1.0, 0.25, 0.2)
const LIGHT_OFF := Color(0.3, 0.06, 0.06)
const BLAST_RING := Color(1.0, 0.3, 0.2, 0.55)
const BLAST_FILL := Color(1.0, 0.3, 0.2, 0.08)
const EDITOR_TRIGGER := Color(0.3, 0.9, 0.95, 0.5)
const EDITOR_BLAST := Color(1.0, 0.3, 0.2, 0.4)

var armed := false
var blink_on := false
var fuse := 0.0

func set_pose(is_armed: bool, is_blink_on: bool, fuse_fraction: float) -> void:
	if is_armed == armed and is_blink_on == blink_on and is_equal_approx(fuse_fraction, fuse):
		return
	armed = is_armed
	blink_on = is_blink_on
	fuse = fuse_fraction
	queue_redraw()

func _draw() -> void:
	var mine := get_parent()
	var size := Vector2(10.0, 8.0)
	var pos := Vector2.ZERO
	var shape_node := mine.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node != null and shape_node.shape is RectangleShape2D:
		size = (shape_node.shape as RectangleShape2D).size
		pos = shape_node.position
	var blast_radius: float = mine.get("blast_radius") if mine.get("blast_radius") != null else 40.0
	var top_left := pos - size * 0.5

	if Engine.is_editor_hint():
		var trigger_radius: float = mine.get("trigger_radius") if mine.get("trigger_radius") != null else 32.0
		var trigger_height: float = mine.get("trigger_height") if mine.get("trigger_height") != null else 28.0
		draw_rect(Rect2(pos - Vector2(trigger_radius, trigger_height), Vector2(trigger_radius, trigger_height) * 2.0), EDITOR_TRIGGER, false, 1.0)
		draw_arc(pos, blast_radius, 0.0, TAU, 48, EDITOR_BLAST, 1.0, true)
	elif armed:
		draw_circle(pos, blast_radius, BLAST_FILL)
		draw_arc(pos, blast_radius, 0.0, TAU, 48, BLAST_RING, 1.0, true)

	for x in [-3.0, 0.0, 3.0]:  # prongs, then the hull over their feet
		draw_rect(Rect2(pos.x + x - 0.5, top_left.y - 2.0, 1.0, 3.0), PRONG)
	draw_rect(Rect2(top_left, size), HULL)
	draw_rect(Rect2(top_left, size), EDGE, false, 1.0)
	var light := LIGHT_DORMANT
	if armed:
		light = LIGHT_ON if blink_on else LIGHT_OFF
	draw_rect(Rect2(pos.x - 1.5, top_left.y + 1.0, 3.0, 3.0), light)
	if armed and blink_on:
		draw_circle(Vector2(pos.x, top_left.y + 2.5), 3.0 + 3.0 * fuse, Color(1.0, 0.3, 0.2, 0.3))
