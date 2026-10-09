@tool
extends Node2D

# Placeholder see-saw plank art, drawn in code from the parent's CollisionShape2D children so it follows the shape
# (including a node scale on it) when that is edited: a plain rectangle gets wood and a 1px outline, anything else
# the engine's debug fill. (The pivot circle is the Seesaw's own PivotMarker, so it also shows over a skin.) A child of the RotatingBody, so it turns with it. Replace
# with real art by deleting this node and adding a Sprite2D (or draw the whole thing with tilemap sprites).

const WOOD := Color(0.55, 0.38, 0.22)
const OUTLINE := Color(0.32, 0.2, 0.1)
const MIRROR_EDGE := Color(0.75, 0.9, 1.0)  # same bright front-face line as the Mirror placeholder

func _ready() -> void:
	set_process(Engine.is_editor_hint())  # at runtime the plank is static in its own space; only the editor needs redraws

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var body := get_parent() as Node2D
	if body == null:
		return
	for child in body.get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		var rect := cs.shape as RectangleShape2D
		if rect != null:
			# Corners transformed by hand, so the outline stays 1px however the shape node is scaled.
			var half := rect.size * 0.5
			var corners := PackedVector2Array()
			for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
				corners.append(cs.transform * corner)
			draw_colored_polygon(corners, WOOD)
			var top_left := corners[0]
			var top_right := corners[1]
			corners.append(corners[0])
			draw_polyline(corners, OUTLINE, 1.0)
			if body.get(&"mirror_surface"):  # the reflective top face (the Seesaw's `mirror_surface` export)
				draw_line(top_left, top_right, MIRROR_EDGE, 1.0)
		else:
			draw_set_transform_matrix(cs.transform)
			cs.shape.draw(get_canvas_item(), WOOD)
			draw_set_transform_matrix(Transform2D.IDENTITY)
