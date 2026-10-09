extends Node2D
class_name SurfBoardArt

# Placeholder board for the surf (SurfBoard in player.tscn), drawn in code until there is a sprite. Drawn FACING RIGHT
# with the origin at the middle of the board's top surface, so the player sets this node's position to the feet and its
# scale.x to the facing. `rotation` is the board's tilt (stage 2); the nose is raised a little so it reads as a board.

const DECK := Color(0.95, 0.78, 0.25)
const EDGE := Color(0.55, 0.32, 0.12)

func _draw() -> void:
	var board := PackedVector2Array([
		Vector2(-11.0, 0.5), Vector2(8.0, 0.5), Vector2(11.5, -0.5), Vector2(8.0, 2.5), Vector2(-9.0, 2.5), Vector2(-11.0, 1.5),
	])
	draw_colored_polygon(board, DECK)
	draw_polyline(board + PackedVector2Array([board[0]]), EDGE, 0.75)
	draw_line(Vector2(-6.0, 1.5), Vector2(7.0, 1.5), EDGE, 0.5)
