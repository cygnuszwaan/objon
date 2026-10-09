@tool
extends Node2D

# Placeholder see-saw trestle: a fixed triangle with its apex at the Fulcrum, drawn in code. It is a child of the
# rotating plank, so each frame it draws itself in world space (undoing the plank's rotation) instead of being
# top-level, which would make the editor save position changes into the scene whenever the Fulcrum is dragged.
# Must come before the plank art in the scene tree so it is drawn underneath. The plank pivots about the apex, so
# the trestle's half angle (atan(half_width / height), about 32 degrees by default) must stay under 90 degrees minus
# the plank's maximum tilt; it is fine for the default 25 degree swing.

@export var height: float = 22.0
@export var half_width: float = 14.0
@export var color: Color = Color(0.3, 0.3, 0.34)

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var body := get_parent() as Node2D
	if body == null:
		return
	var fulcrum := body.get_node_or_null("Fulcrum") as Node2D
	var pivot := fulcrum.global_position if fulcrum != null else body.global_position
	draw_set_transform_matrix(get_global_transform().affine_inverse() * Transform2D(0.0, pivot))
	draw_colored_polygon(PackedVector2Array([Vector2.ZERO, Vector2(-half_width, height), Vector2(half_width, height)]), color)
	draw_rect(Rect2(-half_width - 3.0, height, half_width * 2.0 + 6.0, 3.0), color.darkened(0.25))
	draw_set_transform_matrix(Transform2D.IDENTITY)
