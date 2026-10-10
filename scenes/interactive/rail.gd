@tool
class_name Rail
extends Path2D
## A rail the player can hang from and a rail bot can ride, authored by dragging Marker2D children instead of editing
## a Curve2D. Put two or more Marker2D children under it; the curve runs through them in child order (straight, or
## rounded with `smoothing`). A rail bot placed as a child of this node rides it. Because the curve is generated from the
## markers (never authored, never saved), duplicating the node or instancing a scene that contains it keeps every
## copy's own points: marker positions are ordinary node properties, which an instance saves.
##
## With fewer than two Marker2D children it leaves `curve` alone, so a Rail also works as a plain Path2D.
##
## Drawn here as a plain line (so a bot-less rail is visible too); rail bots skip drawing their own when the rail
## answers `draws_own_line()`. Joins group "grab_rail" at run time when `grabbable` (see Rail hang in docs/player.md).
##
## Exports are authored values only; the generated curve and `_last_points` are runtime state.

## Straight segments at 0; 1 rounds the corners through the markers (Catmull-Rom).
@export_range(0.0, 1.0, 0.05) var smoothing: float = 0.0:
	set(value):
		smoothing = value
		if is_node_ready():
			_rebuild_curve()
## Repeats the first marker as the last point so a rail bot in LOOP mode wraps without a jump.
@export var closed: bool = false:
	set(value):
		closed = value
		if is_node_ready():
			_rebuild_curve()
## Lets the player hang from this rail.
@export var grabbable: bool = true
@export_group("Look")
@export var line_color: Color = Color(0.3, 0.33, 0.4)
@export var line_width: float = 2.0

var _last_points := PackedVector2Array()
var _curve_owned := false  # this node created the current curve, so it may be mutated

func _enter_tree() -> void:
	# Children exist with their saved positions by now, and a rail bot child's own _ready() runs before this node's,
	# so the curve is built here to be there when the bot snaps to its start.
	_rebuild_curve()
	if not child_order_changed.is_connected(_rebuild_curve):
		child_order_changed.connect(_rebuild_curve)

func _ready() -> void:
	if not Engine.is_editor_hint() and grabbable:
		add_to_group(&"grab_rail")
	queue_redraw()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint() and _marker_points() != _last_points:
		_rebuild_curve()  # a marker was dragged

func _get_configuration_warnings() -> PackedStringArray:
	return rail_warnings()

func rail_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _marker_points().size() < 2 and (curve == null or curve.point_count < 2):
		warnings.append("Add at least two Marker2D children: the rail runs through them in order.")
	return warnings

func _validate_property(property: Dictionary) -> void:
	# The curve is generated from the markers, so it is not saved with the scene.
	if property.name == "curve" and _marker_points().size() >= 2:
		property.usage &= ~PROPERTY_USAGE_STORAGE

func draws_own_line() -> bool:
	return true

func _marker_points() -> PackedVector2Array:
	var points := PackedVector2Array()
	for child in get_children():
		if child is Marker2D:
			points.append((child as Marker2D).position)
	return points

## Rebuilds the curve from the Marker2D children (a named method so a runtime editor can re-run it).
func _rebuild_curve() -> void:
	var points := _marker_points()
	_last_points = points
	if points.size() < 2:
		queue_redraw()
		update_configuration_warnings()
		return
	if not _curve_owned:
		curve = Curve2D.new()  # never mutate a curve that came out of a saved scene: it may be shared
		_curve_owned = true
	curve.clear_points()
	var count := points.size()
	for i in count:
		var prev := points[maxi(i - 1, 0)]
		var next := points[mini(i + 1, count - 1)]
		var handle := Vector2.ZERO
		if smoothing > 0.0:
			handle = (next - prev) * (1.0 / 6.0) * smoothing
		curve.add_point(points[i], -handle, handle)
	if closed:
		curve.add_point(points[0], Vector2.ZERO, Vector2.ZERO)
	queue_redraw()
	update_configuration_warnings()

func _draw() -> void:
	if curve == null or curve.point_count < 2:
		return
	draw_polyline(curve.get_baked_points(), line_color, line_width)
