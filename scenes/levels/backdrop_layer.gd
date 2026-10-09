class_name BackdropLayer
extends Node2D
## One parallax backdrop layer: a child Sprite2D named "Art" that scrolls at a fraction of the camera's speed.
##
## `scroll_scale` is how fast the art moves on screen compared with a normal world object, per axis:
## 1 = exactly like the world (no parallax), 0 = pinned to the screen. Distant layers use small values (they
## crawl), nearer ones larger. The two axes are independent, so a layer can pan sideways more than it rises.
##
## Placement: the layer's position is the world point the camera has to be looking at for the art to appear
## exactly where it is drawn in the editor (the art is centred on the node). Everywhere else it is displaced by
## (camera centre - node position) x (1 - scroll_scale). So to line a layer up with the level, put the node
## where you want its art when the camera is centred on the area you're working on. With `repeat_x` the x
## position is invisible (the art is endless sideways); with `repeat_y` the y position is invisible likewise.
##
## The position is a pure function of the camera (no stored state), so a respawn or any camera jump needs no
## handling. It is read from this frame's canvas transform rather than from a node: that is exactly what the
## renderer uses, so it also stays in step with physics interpolation and camera smoothing. `process_priority`
## is high so it runs after the Camera2D has updated for the frame.
##
## Tiling: with `repeat_x` and/or `repeat_y` the Art sprite is duplicated into a grid as large as the visible
## area needs (one tile wide/tall on an axis that doesn't repeat) and the whole grid is wrapped by whole tile
## widths/heights, so the art repeats forever along each repeating axis. The tile must repeat seamlessly along
## every axis it repeats on. The Art sprite must stay `centered`, with its texture the tile. Use `repeat_y`
## for underground levels, where the backdrop has no sky or horizon to run out of.
##
## Drawing order is z_index: keep every layer well below the level's tilemaps (Far < Near < 0).
##
## Expected scene layout (see backdrop_layers.tscn):
##   Far (Node2D, this script, z_index -102)
##     - Art (Sprite2D, centered, the tile's texture)

@export var scroll_scale: Vector2 = Vector2(0.5, 0.5) ## 1 = moves with the world, 0 = pinned to the screen.
@export var repeat_x: bool = true ## Tile the art endlessly sideways.
@export var repeat_y: bool = false ## Tile the art endlessly up and down (underground levels).

var _art: Sprite2D
var _copies: Array[Sprite2D] = []  # row-major grid: index = row * _cols + col
var _tile_size: Vector2 = Vector2.ZERO
var _origin: Vector2 = Vector2.ZERO
var _cols: int = 0
var _rows: int = 0

func _ready() -> void:
	# This node is moved from _process(); interpolating it between physics ticks would fight that.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = 100
	_origin = global_position
	_art = get_node_or_null("Art") as Sprite2D
	if _art == null or _art.texture == null:
		push_warning("BackdropLayer '%s' needs a child Sprite2D named 'Art' with a texture." % get_path())
		set_process(false)
		return
	if not _art.centered:
		push_warning("BackdropLayer '%s': the Art sprite must be centered." % get_path())
	_tile_size = _art.texture.get_size() * _art.scale.abs()
	_copies.append(_art)
	_cols = 1
	_rows = 1

func _process(_delta: float) -> void:
	var canvas := get_canvas_transform()
	var viewport_size := get_viewport_rect().size
	var centre := canvas.affine_inverse() * (viewport_size * 0.5)  # world point at the middle of the screen
	var pos := _origin * scroll_scale + centre * (Vector2.ONE - scroll_scale)
	var view_size := viewport_size / canvas.get_scale().abs()
	var cols := 1
	var rows := 1
	if repeat_x and _tile_size.x > 0.0:
		var view_left := centre.x - view_size.x * 0.5
		var first_left := pos.x + _art.position.x - _tile_size.x * 0.5
		pos.x -= _tile_size.x * ceilf((first_left - view_left) / _tile_size.x)
		cols = ceili(view_size.x / _tile_size.x) + 2
	if repeat_y and _tile_size.y > 0.0:
		var view_top := centre.y - view_size.y * 0.5
		var first_top := pos.y + _art.position.y - _tile_size.y * 0.5
		pos.y -= _tile_size.y * ceilf((first_top - view_top) / _tile_size.y)
		rows = ceili(view_size.y / _tile_size.y) + 2
	_ensure_grid(cols, rows)
	global_position = pos

## Makes the grid of Art duplicates `cols` x `rows` tiles (tile 0,0 is Art itself, the others extend right and
## down from it). Only touches the sprites when the size changes; extras from an earlier, larger grid are hidden.
func _ensure_grid(cols: int, rows: int) -> void:
	if cols == _cols and rows == _rows:
		return
	_cols = cols
	_rows = rows
	while _copies.size() < cols * rows:
		var copy := _art.duplicate() as Sprite2D
		add_child(copy)
		_copies.append(copy)
	for i in _copies.size():
		var copy := _copies[i]
		if i < cols * rows:
			copy.visible = true
			copy.position = _art.position + Vector2(_tile_size.x * (i % cols), _tile_size.y * (i / cols))
		elif copy != _art:
			copy.visible = false
