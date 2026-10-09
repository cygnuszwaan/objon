@tool
extends RotatingBody

# The see-saw: a RotatingBody whose plank length and skin are per-instance exports, so a level can resize and
# reskin it without turning on Editable Children. seesaw.tscn is this script on a plank (a CollisionShape2D, a
# Fulcrum and the placeholder art).
#
# Length: `_apply_plank()` gives the plank's CollisionShape2D its own new RectangleShape2D of `length_tiles` x the
# scene shape's thickness (so instances never share and resize one resource, and no node scale is involved), and
# re-applies it on every load, since the changes to a non-editable child are not saved with the level. The shape's
# own size in the scene is therefore only the thickness; edit the exports, not the shape's width.
#
# Skin: with a `plank_texture`, a `PlankSkin` Sprite2D (made here, never saved) tiles it across the plank's length
# (region_rect with texture repeat, so the texture must be a plain Texture2D, not an AtlasTexture) and hides the
# placeholder art. Its height is the texture's own; `texture_offset` moves it relative to the shape (e.g. +y to
# hang a taller sprite below the top face). Lengths that aren't a whole number of texture widths end in a cut tile.
#
# Mirror surface: with `mirror_surface` the plank's whole top face reflects lasers. The see-saw then joins group
# "laser_mirror" and answers the solver's contract (see scripts/laser_beam.gd) from `get_pose_global()` (built from
# `_angle`, never the node transform, which lags a write under sync_to_physics) and the plank shape's top edge. The
# plank stays a real solid: it opts out of the solver's body exclusion (`laser_body_is_physical()`), so its underside
# and ends still stop the beam, and the analytic segment sits MIRROR_LIFT px in front of the collider so it wins the
# tie on the front face. The turret solves before the see-saw moves (process_physics_priority 100), so the reflected
# beam trails the plank by one frame; a receiver on it needs its hold_time.
#
# Pivot marker: with `show_pivot`, a `PivotMarker` child (made here, never saved, kept as the last child so it
# draws over the placeholder art and the skin) draws a small circle at the Fulcrum, in the editor too.

const TILE := 16.0
const SKIN_NAME := "PlankSkin"
const MARKER_NAME := "PivotMarker"
const MIRROR_LIFT := 1.0  # px the reflective segment sits in front of the plank's top face, so it wins the tie against the collider

@export_group("Plank")
## Length of the plank, centred on the shape (default 2 = one tile either side of the Fulcrum). Lever arms, loads and the editor ghosts all follow.
@export_range(0.5, 32.0, 0.5, "suffix:tiles") var length_tiles: float = 2.0:
	set(value):
		length_tiles = value
		_apply_plank()
## Tiled horizontally across the plank in place of the placeholder art. Leave empty for the placeholder.
@export var plank_texture: Texture2D:
	set(value):
		plank_texture = value
		_apply_plank()
## Moves the skin relative to the plank shape's centre, px.
@export var texture_offset: Vector2 = Vector2.ZERO:
	set(value):
		texture_offset = value
		_apply_plank()
## A small circle at the Fulcrum, drawn over the plank art or skin.
@export var show_pivot: bool = true:
	set(value):
		show_pivot = value
		_apply_plank()
## Radius of the pivot circle, px.
@export_range(0.5, 8.0, 0.5) var pivot_radius: float = 2.0:
	set(value):
		pivot_radius = value
		_apply_plank()
@export var pivot_color: Color = Color(0.72, 0.72, 0.76):
	set(value):
		pivot_color = value
		_apply_plank()
## The plank's whole top face reflects lasers (a thin plate in front of the collider; the underside and the ends still stop the beam). Needs a rectangular plank shape.
@export var mirror_surface: bool = false:
	set(value):
		mirror_surface = value
		_apply_mirror_surface()
@export_group("")

func _ready() -> void:
	_apply_plank()  # before the base class reads the shapes
	super()
	_apply_mirror_surface()

func _apply_plank() -> void:
	if not is_inside_tree():
		return  # the setters run while the scene loads; _ready() calls this again
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null:
		return
	var length := length_tiles * TILE
	var old := cs.shape as RectangleShape2D
	var thickness := old.size.y if old != null else 8.0
	if old == null or not is_equal_approx(old.size.x, length):
		var rect := RectangleShape2D.new()
		rect.size = Vector2(length, thickness)
		cs.shape = rect
	var art := get_node_or_null("PlankArt") as CanvasItem
	if art != null:
		art.visible = plank_texture == null
	_apply_skin(cs, length)
	_apply_pivot_marker()

func _apply_skin(cs: CollisionShape2D, length: float) -> void:
	var skin := get_node_or_null(SKIN_NAME) as Sprite2D
	if plank_texture == null:
		if skin != null:
			remove_child(skin)
			skin.queue_free()
		return
	if skin == null:
		skin = Sprite2D.new()
		skin.name = SKIN_NAME
		skin.region_enabled = true
		skin.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		add_child(skin)  # no owner, so it is never saved into a scene
	skin.texture = plank_texture
	skin.region_rect = Rect2(0.0, 0.0, length, plank_texture.get_height())
	skin.position = cs.position + texture_offset

func _apply_pivot_marker() -> void:
	var marker := get_node_or_null(MARKER_NAME) as PivotMarker
	if not show_pivot:
		if marker != null:
			remove_child(marker)
			marker.queue_free()
		return
	if marker == null:
		marker = PivotMarker.new()
		add_child(marker)  # no owner, so it is never saved into a scene
	marker.radius = pivot_radius
	marker.color = pivot_color
	marker.queue_redraw()
	move_child(marker, get_child_count() - 1)  # last = drawn on top of the art and the skin

# --- mirror surface (laser contract, read by LaserBeam) ---------------------------------------------------------

## Joins or leaves group "laser_mirror" to match `mirror_surface`. Runtime only, and only with a rectangular plank
## shape to take the face from; callable again after a change (the setter does).
func _apply_mirror_surface() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return  # the setter runs while the scene loads; _ready() calls this again
	var wanted := mirror_surface and _plank_shape() != null
	if wanted and not is_in_group(&"laser_mirror"):
		add_to_group(&"laser_mirror")
	elif not wanted and is_in_group(&"laser_mirror"):
		remove_from_group(&"laser_mirror")

## The node named `CollisionShape2D` if it holds a rectangle (the plank `_apply_plank()` builds), else null.
func _plank_shape() -> CollisionShape2D:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or cs.disabled or not (cs.shape is RectangleShape2D):
		return null
	return cs

## `[a, b]` in world space: the plank's top edge (the shape's local -Y side), moved MIRROR_LIFT px along the face
## normal. From the pose at the last `_apply_angle()`, so it matches the physics body.
func get_laser_segment() -> PackedVector2Array:
	var cs := _plank_shape()
	if cs == null:
		var here := global_position
		return PackedVector2Array([here, here])  # zero length: the solver treats it as a miss
	var half := (cs.shape as RectangleShape2D).size * 0.5
	var pose := get_pose_global()
	var normal := get_laser_normal()
	var a := pose * (cs.transform * Vector2(-half.x, -half.y)) + normal * MIRROR_LIFT
	var b := pose * (cs.transform * Vector2(half.x, -half.y)) + normal * MIRROR_LIFT
	return PackedVector2Array([a, b])

## World-space unit normal of the top face (local up through the shape's own rotation and the current pose).
func get_laser_normal() -> Vector2:
	var cs := _plank_shape()
	var local_up := Vector2.UP if cs == null else Vector2.UP.rotated(cs.rotation)
	return get_pose_global().basis_xform(local_up).normalized()

## The plank stays solid to beams on every side but the front (see the header).
func laser_body_is_physical() -> bool:
	return true

## The pivot circle: drawn at the parent's Fulcrum in the parent's space, so it turns with the plank.
class PivotMarker extends Node2D:
	var radius: float = 2.0
	var color: Color = Color(0.72, 0.72, 0.76)

	func _init() -> void:
		name = MARKER_NAME
		set_process(Engine.is_editor_hint())  # follow the Fulcrum as it is dragged; at runtime it never moves in the plank's space

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var fulcrum := get_parent().get_node_or_null("Fulcrum") as Node2D
		var at := fulcrum.position if fulcrum != null else Vector2.ZERO
		draw_circle(at, radius, color)
		draw_arc(at, radius, 0.0, TAU, 16, color.darkened(0.5), 1.0)
