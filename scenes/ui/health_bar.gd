class_name HealthBar
extends CanvasLayer
## Top-right health bar, a child of the Player scene so every level gets it. Three layers of art:
##   Back      the empty bar. It is also the MASK: `clip_children` (CLIP_AND_DRAW) draws it and clips its children to
##             its own alpha, so the bar keeps its rounded ends.
##   Segments  the red fill, cut from healthbar1_front.png into one TextureRect per hit point. The cuts follow the
##             art's curved divider lines (see DIVIDER_X / DIVIDER_CUT), not straight verticals, so a remaining
##             segment keeps its rounded right end and a lost one leaves a matching curved gap. Each segment is
##             full bar size (mostly transparent) so it sits exactly where it does in the art. They are children
##             of Back, so they are masked by it.
##   Outline   drawn over both.
## Losing a hit point flashes the rightmost remaining segment white, blinking a few times, then hides it; the
## flat divider lines of Back show where it was. Gaining one plays the same blink in reverse: the segment starts
## hidden, blinks in (normal, white, three times) and settles shown; several gained at once fill in left to right,
## `GAIN_STAGGER` apart. The first sync at load snaps with no animation. The flash is a shader
## (health_segment_flash.gdshader) that only lightens each pixel, so the segment's pixelated rounded divider
## shading stays exactly as drawn.
## Art: sprites/ui/healthbar1_*.png, 128x16 each. It has 4 segments, so this assumes max_health 4.

const FRONT_TEXTURE: Texture2D = preload("res://sprites/ui/healthbar1_front.png")
const FLASH_SHADER: Shader = preload("res://scenes/ui/health_segment_flash.gdshader")
const BAR_SIZE := Vector2(128.0, 16.0)

## The art's three divider lines sit at these x positions (px) in the middle rows, and curve left at the top and
## bottom like a ")": the rounded right end of the segment on their left. Each segment keeps its divider line.
const DIVIDER_X: Array[int] = [32, 64, 96]
## For rows DIVIDER_FIRST_ROW.., the x offset of a divider line's rightmost pixel from DIVIDER_X. A pixel belongs to the
## segment on the left of a divider if x <= DIVIDER_X + offset for its row. Matches healthbar1_front.png.
const DIVIDER_FIRST_ROW := 2
const DIVIDER_CUT: Array[int] = [-2, -1, -1, 0, 0, 0, 0, 0, 0, -1, -1, -2]

const BLINKS := 3
const BLINK_HALF_PERIOD := 0.06  ## seconds on, and the same off, per blink: 3 blinks = 0.36s
const GAIN_STAGGER := 0.2  ## seconds between successive segments when several are gained at once
const FLASH_STRENGTH := 0.6  ## how far toward white a blink goes; under 1 so the pixel shading stays readable

## Screen pixels per art pixel. The player camera is zoomed 2.5x, so 2.5 keeps the bar's pixels the same size as the world's (player.tscn sets it).
@export var pixel_scale: float = 3.0
## Gap between the bar and the top-right corner of the screen, in screen pixels.
@export var margin: float = 16.0

@onready var _root: Control = $Root
@onready var _segments_root: Control = $Root/Back/Segments

var _segments: Array[TextureRect] = []
var _materials: Array[ShaderMaterial] = []
var _tweens: Array[Tween] = []
var _on: Array[bool] = []  ## the state each segment is heading to (shown/hidden), which may be ahead of its visibility mid-animation

func _ready() -> void:
	layer = 5  # above the world, below the level-complete overlay (10)
	_layout()
	_build_segments()
	var player := get_parent()
	if player != null and player.has_signal(&"health_changed"):
		player.health_changed.connect(_on_health_changed)
		# Deferred: a child's _ready() runs before its parent's, and Player sets its starting health there.
		_sync_to.call_deferred(player)

func _layout() -> void:
	# Anchored to the top-right corner. The Control keeps the art's own 128x16 size and is scaled up from its
	# top-left, so its left edge sits (width * scale + margin) in from the right edge of the screen.
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.anchor_top = 0.0
	_root.anchor_bottom = 0.0
	_root.scale = Vector2(pixel_scale, pixel_scale)
	_root.offset_left = -margin - BAR_SIZE.x * pixel_scale
	_root.offset_right = _root.offset_left + BAR_SIZE.x
	_root.offset_top = margin
	_root.offset_bottom = margin + BAR_SIZE.y

## The rightmost x that belongs to the segment on the left of divider `d` in row `y`.
func _divider_cut(d: int, y: int) -> int:
	return DIVIDER_X[d] + DIVIDER_CUT[clampi(y - DIVIDER_FIRST_ROW, 0, DIVIDER_CUT.size() - 1)]

func _build_segments() -> void:
	var art := FRONT_TEXTURE.get_image()
	if art.is_compressed():
		art.decompress()
	art.convert(Image.FORMAT_RGBA8)
	var width := art.get_width()
	var height := art.get_height()
	for i in DIVIDER_X.size() + 1:
		var piece := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
		for y in height:
			var first := 0 if i == 0 else _divider_cut(i - 1, y) + 1
			var last := width - 1 if i == DIVIDER_X.size() else _divider_cut(i, y)
			for x in range(first, last + 1):
				piece.set_pixel(x, y, art.get_pixel(x, y))
		var segment := TextureRect.new()
		segment.name = "Segment%d" % (i + 1)
		segment.texture = ImageTexture.create_from_image(piece)
		segment.mouse_filter = Control.MOUSE_FILTER_IGNORE
		segment.size = BAR_SIZE
		var material := ShaderMaterial.new()
		material.shader = FLASH_SHADER
		segment.material = material
		_segments_root.add_child(segment)
		_segments.append(segment)
		_materials.append(material)
		_tweens.append(null)
		_on.append(true)  # new segments are visible; the first _apply() hides the ones past the player's health

func _sync_to(player: Node) -> void:
	_apply(player.health, false)

func _on_health_changed(current: int, _maximum: int) -> void:
	_apply(current, true)

## Segment i is full while i < current. Segments past that hide, with a flash if `animate`; ones that come
## back blink in (see _flash_in()). A segment already heading to the right state is left alone, so a running
## animation isn't restarted by an unrelated change elsewhere on the bar.
func _apply(current: int, animate: bool) -> void:
	var gained := 0
	for i in _segments.size():
		var want := i < current
		if want == _on[i]:
			continue
		_on[i] = want
		if _tweens[i] != null:
			_tweens[i].kill()
			_tweens[i] = null
		_materials[i].set_shader_parameter(&"flash", 0.0)
		if want:
			if animate:
				_flash_in(i, gained * GAIN_STAGGER)
				gained += 1
			else:
				_segments[i].visible = true
		elif animate and _segments[i].visible:
			_flash_out(i)
		else:
			_segments[i].visible = false

func _flash_out(i: int) -> void:
	var tween := create_tween()
	_tweens[i] = tween
	for _b in BLINKS:
		tween.tween_callback(_materials[i].set_shader_parameter.bind(&"flash", FLASH_STRENGTH))
		tween.tween_interval(BLINK_HALF_PERIOD)
		tween.tween_callback(_materials[i].set_shader_parameter.bind(&"flash", 0.0))
		tween.tween_interval(BLINK_HALF_PERIOD)
	tween.tween_callback(func() -> void: _segments[i].visible = false)

## The reverse of _flash_out(): hidden (through `delay`, for staggering), then (normal, white) x BLINKS, ending shown.
func _flash_in(i: int, delay: float) -> void:
	_segments[i].visible = false
	var tween := create_tween()
	_tweens[i] = tween
	if delay > 0.0:
		tween.tween_interval(delay)
	for _b in BLINKS:
		tween.tween_callback(_show_segment.bind(i, 0.0))
		tween.tween_interval(BLINK_HALF_PERIOD)
		tween.tween_callback(_show_segment.bind(i, FLASH_STRENGTH))
		tween.tween_interval(BLINK_HALF_PERIOD)
	tween.tween_callback(_show_segment.bind(i, 0.0))

func _show_segment(i: int, flash: float) -> void:
	_segments[i].visible = true
	_materials[i].set_shader_parameter(&"flash", flash)
