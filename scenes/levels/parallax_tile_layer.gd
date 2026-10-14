@tool
class_name ParallaxTileLayer
extends TileMapLayer
## A purely visual tile layer that sits behind the level and scrolls in parallax: paint distant terrain with
## the level's own ground tileset, drawn smaller than the ground and colour-filtered so it reads as far away.
## No collision, no navigation, no occluders, and it is in none of the tilemap groups ("ground",
## "world_tilemap", "catwalk", "ladder_tilemap"), so the player, water, lasers and basins never see it.
##
## In the editor the layer is drawn 1:1, in the same coordinates as the Ground layer: a cell painted behind a
## point of the ground is behind that point. At run time the layer is drawn at `runtime_zoom` (0.5 = half
## size) and its scroll speed is that same number, which is what a plane that far away would do. Zoom and
## scroll are one setting; there is no separate scroll scale.
##
## Alignment: at run time the layer is scaled about the middle of the screen, so the point of the layer
## that is painted at world position E is drawn at (camera centre + (E - camera centre) x runtime_zoom).
## When the camera is centred on E that is E itself: terrain painted behind a point of the level appears
## directly behind it whenever the player is there. Anywhere else it is pulled toward the screen centre by
## the zoom, which is what makes it look distant. The layer node's own position, scale and rotation are
## the authored placement; keep the scale at 1 (the zoom is `runtime_zoom`).
##
## The transform is a pure function of this frame's camera (canvas transform), with no stored state, so
## respawn teleports and camera smoothing need no handling. `process_priority` is high so it runs after the
## Camera2D has updated.
##
## The colour filter is the ShaderMaterial in parallax_tile_layer.tscn (parallax_tile_layer.gdshader),
## local to each instance: tweak it in the Inspector per level. Keep `z_index` below the level's tilemaps
## and above the BackdropLayers (Far -102, Near -101).

@export_range(0.05, 1.0, 0.01) var runtime_zoom: float = 0.5 ## Size and scroll speed at run time: 1 = like the ground, smaller = further away.

var _origin: Vector2 = Vector2.ZERO

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)  # the editor shows the layer 1:1, exactly as authored
		return
	# Moved and scaled from _process(); interpolating it between physics ticks would fight that.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = 100
	# Belt and braces: the scene already has these off, and a level could override them.
	collision_enabled = false
	navigation_enabled = false
	occlusion_enabled = false
	_origin = global_position
	_apply(Vector2.ZERO)

func _process(_delta: float) -> void:
	var canvas := get_canvas_transform()
	_apply(canvas.affine_inverse() * (get_viewport_rect().size * 0.5))  # world point at the middle of the screen

## Scale about the authored origin by the zoom, then slide so the layer is scaled about the camera centre.
## A cell at local `l` (editor position E = origin + l) lands at centre + (E - centre) x zoom.
func _apply(centre: Vector2) -> void:
	var zoom := clampf(runtime_zoom, 0.05, 1.0)
	scale = Vector2(zoom, zoom)
	global_position = _origin * zoom + centre * (1.0 - zoom)

## Problems with this layer's setup, as plain strings so a runtime level validator can reuse them.
func get_layer_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if tile_set == null:
		warnings.append("Assign the level's ground TileSet so the same tiles can be painted.")
	if collision_enabled:
		warnings.append("Collision is on: turn off Physics > Collision Enabled, this layer is only a picture.")
	if not scale.is_equal_approx(Vector2.ONE):
		warnings.append("Leave Scale at (1, 1): the editor view is 1:1 and the run-time size is Runtime Zoom.")
	for group in [&"ground", &"world_tilemap", &"catwalk", &"ladder_tilemap"]:
		if is_in_group(group):
			warnings.append("Remove this layer from group '%s': the game would treat it as level geometry." % group)
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_layer_warnings()
