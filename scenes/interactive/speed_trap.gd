@tool
extends Area2D
## Speed trap: a roadside speed camera as a power SOURCE (see power_target.gd for the contract). Emits
## `powered_changed(on)` and answers `is_powered()`; PowerTargets pick it in their `sources` list and conductor wires
## attach to it by adjacency, exactly like a Button.
##
## What it is: a thin sensor strip across the path (a vertical line `strip_height` px tall, standing on the floor) with a
## camera on a post beside it and a little three-digit screen. When the player CROSSES the strip's centre line (the sign
## of the player's x relative to it changes between two physics frames, in either direction; standing in the strip does
## nothing) the trap reads the player's speed: the lens flashes, the screen shows the reading (speed * `display_scale`,
## whole units), and if the speed is at or above `threshold_speed` the trap powers for `hold_time` seconds (a pass while
## already powered restarts the countdown; 0 = latched on until the level is reset). A failed pass still shows its
## reading, in red, so the player can calibrate how much faster to go; a pass shows it in green.
##
## `require_surfing` (default on) reads a surfing player only (get_surf_speed(): the board's ground speed, or the
## horizontal speed it carries in the air), so a jump-pad launch or a swing release can't trigger it; a crossing by a
## non-surfing player is ignored entirely (no flash, no reading). With it off the reading is the player's |velocity.x|.
## Choose `threshold_speed` so that threshold * display_scale is a whole number: the pass test uses the true speed and the
## screen shows it rounded down, so a whole-number threshold never shows a passing speed below the limit.
##
## The crossing is geometric, not an Area2D overlap, because a 600 px/s surf covers 10 px a frame and would step over a
## thin strip; the Area2D (no layers, monitoring off) only carries the CollisionShape2D that shows the strip in the
## editor. A step of more than MAX_CROSS_STEP px in one frame (a teleport, a respawn) is not a crossing. The node must
## not be rotated: the strip is always vertical.
##
## Origin: the centre of a 16x16 tile (the cell a ConductorLayer files it under, like Button), the strip's line is the
## origin's x and runs from the bottom edge of that tile (the floor) up `strip_height`. The post stands on `post_side`.
## Art is drawn in code (seven-segment digits, lens, halo) until sprites exist. Place it before the Player in the tree so
## the player draws in front. Sounds `interactive/speed_trap_flash` (every read), `interactive/speed_trap_pass` and
## `interactive/speed_trap_fail` are in Audio.PLANNED.
##
## Saveable: powered, time left, the reading shown and whether it passed; a restore snaps silently.

signal powered_changed(on: bool)

enum PostSide { LEFT = -1, RIGHT = 1 }

## Speed in px/s at or above which a crossing powers the trap.
@export_range(0.0, 2000.0, 10.0, "or_greater") var threshold_speed: float = 450.0
## The screen shows speed * display_scale (a friendlier unit than px/s), rounded down. 0.1 turns a 450 px/s limit into 45.
@export var display_scale: float = 0.1
## Seconds the trap stays powered after a passing crossing; 0 = latched on.
@export_range(0.0, 120.0, 0.1, "or_greater") var hold_time: float = 5.0
## Read a surfing player only (see above).
@export var require_surfing: bool = true
## Height of the sensor strip in px, up from the floor line.
@export_range(8.0, 160.0, 4.0, "or_greater") var strip_height: float = 32.0:
	set(value):
		strip_height = maxf(value, 8.0)
		_apply_strip()
		queue_redraw()
@export var post_side: PostSide = PostSide.RIGHT:
	set(value):
		post_side = value
		queue_redraw()

const TILE_HALF := 8.0
const STRIP_WIDTH := 4.0 ## Only the editor shape's width; detection uses the centre line.
const MAX_CROSS_STEP := 48.0
const PLAYER_HALF_HEIGHT := 8.0 ## The standing capsule is 16px tall and centred on the player's origin.
const FLASH_TIME := 0.18
const MAX_READING := 999

const COLOR_PASS := Color(0.35, 0.95, 0.45)
const COLOR_FAIL := Color(1.0, 0.3, 0.25)
const COLOR_IDLE := Color(0.9, 0.75, 0.3)
const COLOR_METAL := Color(0.32, 0.35, 0.4)
const COLOR_METAL_DARK := Color(0.16, 0.18, 0.22)
const COLOR_SCREEN := Color(0.05, 0.07, 0.07)

## Seven-segment table, bits a b c d e f g = 1 2 4 8 16 32 64, digits 0..9.
const SEGMENTS: PackedInt32Array = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111]
const SEG_DASH := 64

var powered: bool = false
var _time_left: float = 0.0
var _reading: int = -1 ## Shown on the screen; -1 = nothing read yet.
var _passed: bool = false
var _flash_t: float = 0.0
var _prev_side: int = 0 ## Sign of the player's x relative to the line last frame (0 = unknown).
var _prev_dx: float = 0.0
var _player: Node2D

@onready var _strip_shape: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	_apply_strip()
	if Engine.is_editor_hint():
		set_physics_process(false)
		set_process(false)
		queue_redraw()
		return
	add_to_group(&"saveable")
	set_process(false)  # only runs while the flash or the countdown needs redrawing
	_player = get_tree().get_first_node_in_group(&"player") as Node2D
	queue_redraw()

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left, "reading": _reading, "passed": _passed}

## Snaps to the saved state with no sound or flash. Emits powered_changed only if `powered` differs from the current
## value, so circuits and targets follow. The crossing memory is reset: the player has just been teleported.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered and hold_time > 0.0 else 0.0
	if powered and hold_time > 0.0 and _time_left <= 0.0:
		_time_left = hold_time
	_reading = int(d.get("reading", -1))
	_passed = d.get("passed", false)
	_flash_t = 0.0
	_prev_side = 0
	set_process(powered and hold_time > 0.0)
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	if powered and hold_time > 0.0:
		_time_left = maxf(_time_left - delta, 0.0)
		if _time_left <= 0.0:
			_set_powered(false)
	_poll_crossing()

## Samples the player's side of the line every frame and reads the speed on a change of side inside the strip.
func _poll_crossing() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&"player") as Node2D
		if _player == null:
			return
	var dx := _player.global_position.x - global_position.x
	var side := int(signf(dx))
	if side == 0:
		return  # exactly on the line: wait for the next frame to see which side it went to
	var crossed := _prev_side != 0 and side != _prev_side and absf(dx - _prev_dx) <= MAX_CROSS_STEP
	_prev_side = side
	_prev_dx = dx
	if crossed and _player_in_strip_height():
		_read_player()

func _player_in_strip_height() -> bool:
	var bottom := global_position.y + TILE_HALF
	var top := bottom - strip_height
	var py := _player.global_position.y
	return py + PLAYER_HALF_HEIGHT >= top and py - PLAYER_HALF_HEIGHT <= bottom

func _read_player() -> void:
	if _player.get("is_dead") == true or _player.get("is_dancing") == true:
		return
	var speed := 0.0
	if _player.get("is_surfing") == true and _player.has_method("get_surf_speed"):
		speed = _player.get_surf_speed()
	elif require_surfing:
		return
	else:
		speed = absf((_player as CharacterBody2D).velocity.x) if _player is CharacterBody2D else 0.0
	_reading = clampi(floori(speed * display_scale), 0, MAX_READING)
	_passed = speed >= threshold_speed
	_flash_t = FLASH_TIME
	Audio.play_at(&"interactive/speed_trap_flash", global_position)
	if _passed:
		Audio.play_at(&"interactive/speed_trap_pass", global_position)
		_time_left = hold_time  # a pass while powered restarts the countdown (no edge for the targets)
		_set_powered(true)
	else:
		Audio.play_at(&"interactive/speed_trap_fail", global_position)
	set_process(true)
	queue_redraw()

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if not on:
		_time_left = 0.0
	queue_redraw()
	powered_changed.emit(on)

func _process(delta: float) -> void:
	_flash_t = maxf(_flash_t - delta, 0.0)
	queue_redraw()
	if _flash_t <= 0.0 and not (powered and hold_time > 0.0):
		set_process(false)

# --- editor shape ---------------------------------------------------------------------------------------------------

## Sizes the editor strip shape to `strip_height`, on this instance's own copy of the resource.
func _apply_strip() -> void:
	if _strip_shape == null:
		return
	var rect := _strip_shape.shape as RectangleShape2D
	if rect == null:
		return
	if not rect.resource_local_to_scene:
		rect = rect.duplicate() as RectangleShape2D
		_strip_shape.shape = rect
	rect.size = Vector2(STRIP_WIDTH, strip_height)
	_strip_shape.position = Vector2(0.0, TILE_HALF - strip_height * 0.5)

# --- art (placeholder, drawn in code) ---------------------------------------------------------------------------------

## A rect given in post-relative coordinates (post on the right, +x away from the beam), mirrored for a left post.
func _r(x: float, y: float, w: float, h: float) -> Rect2:
	var s := float(post_side)
	return Rect2(x if s > 0.0 else -x - w, y, w, h)

func _reading_color() -> Color:
	if _reading < 0:
		return COLOR_IDLE
	return COLOR_PASS if _passed else COLOR_FAIL

func _draw() -> void:
	var top := TILE_HALF - strip_height  # local y of the strip's top
	var lit := powered
	var beam_color := COLOR_PASS if lit else (COLOR_FAIL if _reading >= 0 and not _passed and _flash_t > 0.0 else COLOR_IDLE)
	# The sensor line: a dashed vertical beam from the floor up, with a small floor plate.
	var y := TILE_HALF
	while y > top:
		var y2 := maxf(y - 3.0, top)
		draw_line(Vector2(0.0, y), Vector2(0.0, y2), Color(beam_color, 0.9 if _flash_t > 0.0 or lit else 0.45), 1.0)
		y -= 5.0
	draw_rect(Rect2(-4.0, TILE_HALF - 1.0, 8.0, 1.0), COLOR_METAL)
	# Post, camera housing, lens.
	draw_rect(_r(10.0, top - 2.0, 2.0, strip_height + 2.0), COLOR_METAL_DARK)
	draw_rect(_r(6.0, top - 9.0, 12.0, 7.0), COLOR_METAL)
	draw_rect(_r(6.0, top - 9.0, 12.0, 1.0), COLOR_METAL.lightened(0.25))
	var lens := Vector2(_r(6.0, 0.0, 0.0, 0.0).position.x, top - 5.5)
	draw_circle(lens, 2.5, COLOR_METAL_DARK)
	draw_circle(lens, 1.5, Color(0.25, 0.55, 0.85) if _flash_t <= 0.0 else Color.WHITE)
	# The status LED on the housing: green while powered, red for a failed read.
	var led := COLOR_PASS if lit else (COLOR_FAIL if _reading >= 0 and not _passed else COLOR_METAL_DARK)
	draw_rect(_r(14.0, top - 8.0, 2.0, 2.0), led)
	_draw_screen(top)
	# The lens halo: a brief expanding ring and glow, not a full-screen flash.
	if _flash_t > 0.0:
		var k := 1.0 - _flash_t / FLASH_TIME  # 0 at the flash, 1 when it has faded
		draw_circle(lens, lerpf(3.0, 12.0, k), Color(1.0, 1.0, 1.0, 0.55 * (1.0 - k)))
		draw_arc(lens, lerpf(3.0, 14.0, k), 0.0, TAU, 20, Color(1.0, 1.0, 1.0, 0.8 * (1.0 - k)), 1.0)

func _draw_screen(top: float) -> void:
	var rect := _r(4.0, top - 1.0, 15.0, 11.0)
	var color := _reading_color()
	draw_rect(rect, COLOR_METAL_DARK)
	draw_rect(Rect2(rect.position + Vector2.ONE, rect.size - Vector2(2.0, 2.0)), COLOR_SCREEN)
	if powered:
		draw_rect(rect, Color(COLOR_PASS, 0.7), false, 1.0)  # a green edge while the trap is on
	# Digits: three of them, 3x5 px with 1px gaps, drawn left to right whichever side the post is on.
	var shown := _reading
	if Engine.is_editor_hint() and _reading < 0:
		shown = clampi(floori(threshold_speed * display_scale), 0, MAX_READING)  # an editor preview of the limit
		color = COLOR_PASS
	var digits: Array[int] = []
	if shown < 0:
		digits = [SEG_DASH, SEG_DASH, SEG_DASH]
	else:
		var hundreds := shown / 100
		var tens := (shown / 10) % 10
		var ones := shown % 10
		digits = [
			SEGMENTS[hundreds] if shown >= 100 else 0,
			SEGMENTS[tens] if shown >= 10 else 0,
			SEGMENTS[ones],
		]
	for i in 3:
		var origin := rect.position + Vector2(2.0 + i * 4.0, 2.0)
		_draw_digit(origin, digits[i], color)
	# Countdown: a one-pixel bar under the digits, draining while a timed hold runs.
	if powered and hold_time > 0.0:
		var frac := clampf(_time_left / hold_time, 0.0, 1.0)
		draw_rect(Rect2(rect.position + Vector2(2.0, 8.0), Vector2(11.0 * frac, 1.0)), COLOR_PASS)

## One seven-segment digit with its top-left at `origin`: unlit segments faintly, lit ones in `color`.
func _draw_digit(origin: Vector2, mask: int, color: Color) -> void:
	var segs: Array[Rect2] = [
		Rect2(0, 0, 3, 1), Rect2(2, 0, 1, 3), Rect2(2, 2, 1, 3), Rect2(0, 4, 3, 1),  # a b c d
		Rect2(0, 2, 1, 3), Rect2(0, 0, 1, 3), Rect2(0, 2, 3, 1),                     # e f g
	]
	for i in 7:
		var seg := Rect2(origin + segs[i].position, segs[i].size)
		draw_rect(seg, color if (mask >> i) & 1 else Color(color, 0.1))
