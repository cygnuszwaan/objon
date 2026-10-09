class_name PointsDisplay
extends CanvasLayer
## Top-left points counter, a child of the Player scene so every level gets it (like HealthBar). It listens to the
## player's `points_changed` signal and syncs its starting value deferred (a child's _ready() runs before its
## parent's). Built in code: a placeholder Label in the default font until real UI art exists. The number pops
## (scales up and settles) whenever it goes up.

const POP_SCALE := 1.25
const POP_TIME := 0.18

## Gap between the label and the top-left corner of the screen, in screen pixels.
@export var margin: float = 16.0
@export var font: Font
@export var font_size: int = 28

var _label: Label
var _tween: Tween

func _ready() -> void:
	layer = 5  # same as HealthBar: above the world, below the level-complete overlay (10)
	_label = Label.new()
	_label.position = Vector2(margin, margin)
	_label.add_theme_font_size_override(&"font_size", font_size)
	_label.add_theme_color_override(&"font_color", Color.WHITE)
	_label.add_theme_color_override(&"font_outline_color", Color(0.05, 0.05, 0.1))
	_label.add_theme_constant_override(&"outline_size", 6)
	if font != null:
		_label.add_theme_font_override(&"font", font)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	_show_total(0)
	var player := get_parent()
	if player != null and player.has_signal(&"points_changed"):
		player.points_changed.connect(_on_points_changed)
		_sync_to.call_deferred(player)

func _sync_to(player: Node) -> void:
	_show_total(player.points)

func _on_points_changed(total: int, delta: int) -> void:
	_show_total(total)
	if delta > 0:
		_pop()

func _show_total(total: int) -> void:
	_label.text = "POINTS  %d" % total

func _pop() -> void:
	if _tween != null:
		_tween.kill()
	_label.pivot_offset = Vector2(0.0, _label.size.y * 0.5)
	_label.scale = Vector2.ONE * POP_SCALE
	_tween = create_tween()
	_tween.tween_property(_label, "scale", Vector2.ONE, POP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
