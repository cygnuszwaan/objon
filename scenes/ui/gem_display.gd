class_name GemDisplay
extends CanvasLayer
## Top-left gem counter under the points counter, a child of the Player scene so every level gets it (like
## HealthBar and PointsDisplay). Shows `collected / total` next to the gem art. It listens to the player's
## `gem_collected` and `gems_counted` signals and syncs its starting values deferred (a child's _ready() runs before
## its parent's). Built in code: a placeholder default-font Label and a `TextureRect` using the first frame of
## `sprites/collectibles/gem1.png` until real UI art exists. The row pops whenever a gem is collected and turns green
## once every gem is. A level with no gems (total 0) hides it.
##
## The total is only known once the player has counted the level's gems (deferred, after this node's own deferred
## sync), so the display redraws on `gems_counted` too; after a checkpoint restore the saved numbers are already in
## place when the sync runs.

const ICON_PATH := "res://sprites/collectibles/gem1.png"
const ICON_FRAME := Rect2(0, 0, 16, 16)
const POP_SCALE := 1.25
const POP_TIME := 0.18
const DONE_COLOR := Color(0.55, 1.0, 0.55)

## Gap between the row and the left edge / top of the screen, in screen pixels.
@export var margin: float = 16.0
## Distance from the top of the screen to this row: below the points counter (its margin plus a 28 px label).
@export var top: float = 56.0
@export var font: Font
@export var font_size: int = 28
## Icon edge in screen pixels (the 16 px art, scaled by a whole number).
@export var icon_size: float = 32.0

var _row: HBoxContainer
var _label: Label
var _tween: Tween

func _ready() -> void:
	layer = 5  # same as HealthBar and PointsDisplay: above the world, below the level-complete overlay (10)
	_row = HBoxContainer.new()
	_row.position = Vector2(margin, top)
	_row.add_theme_constant_override(&"separation", 8)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)
	if ResourceLoader.exists(ICON_PATH):
		var atlas := AtlasTexture.new()
		atlas.atlas = load(ICON_PATH)
		atlas.region = ICON_FRAME
		var icon := TextureRect.new()
		icon.texture = atlas
		icon.custom_minimum_size = Vector2(icon_size, icon_size)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(icon)
	_label = Label.new()
	_label.add_theme_font_size_override(&"font_size", font_size)
	_label.add_theme_color_override(&"font_outline_color", Color(0.05, 0.05, 0.1))
	_label.add_theme_constant_override(&"outline_size", 6)
	if font != null:
		_label.add_theme_font_override(&"font", font)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_label)
	_show(0, 0)
	var player := get_parent()
	if player != null and player.has_signal(&"gem_collected"):
		player.gem_collected.connect(_on_gem_collected)
		if player.has_signal(&"gems_counted"):
			player.gems_counted.connect(_on_gems_counted.bind(player))
		_sync_to.call_deferred(player)

func _sync_to(player: Node) -> void:
	_show(player.gems_collected, player.gems_total)

func _on_gem_collected(count: int, total: int) -> void:
	_show(count, total)
	_pop()

func _on_gems_counted(_total: int, player: Node) -> void:
	_show(player.gems_collected, player.gems_total)

func _show(collected: int, total: int) -> void:
	_row.visible = total > 0
	_label.text = "%d / %d" % [collected, total]
	_label.add_theme_color_override(&"font_color", DONE_COLOR if total > 0 and collected >= total else Color.WHITE)

func _pop() -> void:
	if _tween != null:
		_tween.kill()
	_row.pivot_offset = Vector2(0.0, _row.size.y * 0.5)
	_row.scale = Vector2.ONE * POP_SCALE
	_tween = create_tween()
	_tween.tween_property(_row, "scale", Vector2.ONE, POP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
