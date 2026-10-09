@tool
extends Node2D

# Placeholder art for swing.tscn, drawn in code from the parent Swing's Fulcrum and Grip (so it follows edits to
# them): a rod, a bar across its end (perpendicular to the rod, so it turns with the body) and a pivot dot.
# Assumes this node sits at the parent's origin, un-rotated. Replace with sprites when they exist.
#
# In the editor it also draws the swing's arc between `min_angle_degrees` and `max_angle_degrees` and a circle of
# `grab_radius` around the Grip, so the range can be checked against the level before running it.

const ROD_COLOR := Color(0.62, 0.5, 0.34)
const BAR_COLOR := Color(0.85, 0.72, 0.45)
const PIVOT_COLOR := Color(0.72, 0.72, 0.76)
const ARC_COLOR := Color(1.0, 1.0, 1.0, 0.25)
const GRAB_COLOR := Color(0.4, 1.0, 0.5, 0.35)

## Bar length across the rod, px.
@export var bar_length: float = 14.0
## Rod thickness, px.
@export var rod_width: float = 1.0
## Bar thickness, px.
@export var bar_width: float = 2.0

func _ready() -> void:
	set_process(Engine.is_editor_hint())  # only to follow edits in the editor

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var body := get_parent() as Swing
	if body == null:
		return
	var fulcrum := body.get_node_or_null("Fulcrum") as Node2D
	var grip := body.get_node_or_null("Grip") as Node2D
	if fulcrum == null or grip == null:
		return
	var top := fulcrum.position
	var bottom := grip.position
	var along := (bottom - top).normalized()
	var across := along.orthogonal()
	draw_line(top, bottom, ROD_COLOR, rod_width)
	draw_line(bottom - across * bar_length * 0.5, bottom + across * bar_length * 0.5, BAR_COLOR, bar_width)
	draw_circle(top, 1.5, PIVOT_COLOR)
	if Engine.is_editor_hint():
		var radius := top.distance_to(bottom)
		var start := (bottom - top).angle() + deg_to_rad(minf(body.min_angle_degrees, body.max_angle_degrees))
		var end := (bottom - top).angle() + deg_to_rad(maxf(body.min_angle_degrees, body.max_angle_degrees))
		if not body.free_rotation:
			draw_arc(top, radius, start, end, 48, ARC_COLOR, 1.0)
			draw_line(top, top + Vector2.from_angle(start) * radius, ARC_COLOR, 1.0)
			draw_line(top, top + Vector2.from_angle(end) * radius, ARC_COLOR, 1.0)
		else:
			draw_arc(top, radius, 0.0, TAU, 64, ARC_COLOR, 1.0)
		draw_arc(bottom, body.grab_radius, 0.0, TAU, 24, GRAB_COLOR, 1.0)
