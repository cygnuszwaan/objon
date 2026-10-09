class_name TouchControls
extends CanvasLayer
## On-screen controls for touch devices (an Android or iOS build, or the web build opened on a phone).
## `Game` adds one as a child in `_ready()`, so every level has it with no level edits.
##
## It drives the game's existing input actions with `Input.parse_input_event(InputEventAction)`, so the
## player, the finish overlay and `Game` read touch exactly as they read the keyboard and nothing else
## needed to change. Every touch is tracked by finger index and the set of held actions is recomputed from
## all fingers after each event, so several fingers can hold different controls at once (crouch + jump,
## crouch + kick) and a finger can slide from one button to another.
##
## Layout (placeholder art drawn in code, translucent so the level shows through):
##   bottom left   8-way D-pad: left, right, up (`climb_up`), down (`crouch`); diagonals press both axes (swimming)
##   bottom right  JUMP and KICK
##   top centre    pause (`menu`) and restart (`restart`, hold to fire so a stray tap can't cost a respawn)
##
## Visibility: shown when the device reports a touchscreen, and the first touch event shows it otherwise
## (covers browsers that don't report one). F8 toggles it in a debug build, and while it is on that way the
## mouse acts as one finger, for checking the layout on a desktop.
##
## While the tree is paused (the pause menu is open) the overlay ignores input and releases everything; the
## menu's own buttons work through the engine's touch-to-mouse emulation.

const LAYER := 8  # above the HUD (5), below the level-complete overlay (10) and the pause menu (20)
const MARGIN := 40.0
const DPAD_RADIUS := 120.0
const DPAD_CAPTURE_SCALE := 1.5     # a touch this many radii from the centre grabs the D-pad
const DPAD_HORIZONTAL_DEADZONE := 0.2  # fractions of the radius a push must exceed
const DPAD_VERTICAL_DEADZONE := 0.35   # larger, so a thumb drifting while running can't crouch
const DPAD_AXIS_SHARE := 0.55       # an axis counts once it is this share of the push (about 33 degrees pure zones)
const JUMP_RADIUS := 84.0
const KICK_RADIUS := 62.0
const SMALL_RADIUS := 30.0
const HIT_SLOP := 10.0              # extra reach around a button, in px
const RESTART_HOLD := 0.6           # seconds the restart button must be held
const MOUSE_FINGER := 1000          # finger index used for the mouse in desktop preview
const PREVIEW_KEY := KEY_F8

const FILL_IDLE := Color(1, 1, 1, 0.10)
const FILL_HELD := Color(1, 1, 1, 0.38)
const RING := Color(1, 1, 1, 0.6)
const RING_SHADOW := Color(0, 0, 0, 0.45)
const GLYPH := Color(1, 1, 1, 0.85)

var _pad: Control
var _shown := false
var _preview := false               # the mouse counts as a finger (desktop preview only)
var _touches: Dictionary = {}       # finger index -> Vector2 position
var _dpad_finger := -1              # the finger that grabbed the D-pad, -1 = none
var _dpad_center := Vector2.ZERO
var _buttons: Array[Dictionary] = []  # {id, action, label, center, radius}
var _active: Dictionary = {}        # action -> true, what has been sent as pressed
var _restart_down := false
var _restart_hold := 0.0
var _restart_fired := false


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS  # releases must still arrive while the tree is paused
	_pad = Control.new()
	_pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.draw.connect(_draw_pad)
	add_child(_pad)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_set_shown(DisplayServer.is_touchscreen_available())


func _process(delta: float) -> void:
	if not _shown or not _restart_down or get_tree().paused:
		return
	_restart_hold = minf(_restart_hold + delta, RESTART_HOLD)
	if _restart_hold >= RESTART_HOLD and not _restart_fired:
		_restart_fired = true
		_refresh()
	else:
		_pad.queue_redraw()  # the progress ring


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.physical_keycode == PREVIEW_KEY and OS.is_debug_build():
			_preview = not _shown
			_set_shown(_preview or DisplayServer.is_touchscreen_available())
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if not _shown:
			_set_shown(true)
		_on_touch(touch.index, touch.position, touch.pressed)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _touches.has(drag.index):
			_touches[drag.index] = drag.position
			_refresh()
	elif _preview and event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		# Mouse events the engine makes from a real touch are skipped: the touch itself is handled above.
		if button.device != InputEvent.DEVICE_ID_EMULATION and button.button_index == MOUSE_BUTTON_LEFT:
			_on_touch(MOUSE_FINGER, button.position, button.pressed)
	elif _preview and event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.device != InputEvent.DEVICE_ID_EMULATION and _touches.has(MOUSE_FINGER):
			_touches[MOUSE_FINGER] = motion.position
			_refresh()


## Positions the controls against the visible area (which grows past 1280x720 on wider screens).
func _layout() -> void:
	var view := get_viewport().get_visible_rect().size
	_dpad_center = Vector2(MARGIN + DPAD_RADIUS, view.y - MARGIN - DPAD_RADIUS)
	var jump_center := Vector2(view.x - MARGIN - JUMP_RADIUS, view.y - MARGIN - JUMP_RADIUS)
	_buttons = [
		{"id": &"jump", "action": &"jump", "label": "JUMP", "center": jump_center, "radius": JUMP_RADIUS},
		{"id": &"kick", "action": &"kick", "label": "KICK", "center": jump_center + Vector2(-160.0, 10.0), "radius": KICK_RADIUS},
		{"id": &"menu", "action": &"menu", "label": "", "center": Vector2(view.x * 0.5 + 55.0, MARGIN + SMALL_RADIUS), "radius": SMALL_RADIUS},
		{"id": &"restart", "action": &"restart", "label": "R", "center": Vector2(view.x * 0.5 - 55.0, MARGIN + SMALL_RADIUS), "radius": SMALL_RADIUS},
	]
	if _pad != null:
		_pad.queue_redraw()


func _set_shown(on: bool) -> void:
	_shown = on
	visible = on
	_touches.clear()
	_dpad_finger = -1
	_refresh()  # releases anything still held


func _on_touch(finger: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		if get_tree().paused:
			return  # a touch that starts over the menu is the menu's
		_touches[finger] = pos
		if _dpad_finger == -1 and pos.distance_to(_dpad_center) <= DPAD_RADIUS * DPAD_CAPTURE_SCALE:
			_dpad_finger = finger
		if finger == _dpad_finger or not _button_at(pos).is_empty():
			get_viewport().set_input_as_handled()
	else:
		_touches.erase(finger)
		if finger == _dpad_finger:
			_dpad_finger = -1
	_refresh()


## Recomputes the wanted actions from every finger and sends only the differences.
func _refresh() -> void:
	var wanted: Dictionary = {}
	if get_tree().paused:
		_restart_down = false
		_restart_hold = 0.0
		_restart_fired = false
	else:
		_collect_wanted(wanted)
	for action in _active.keys():
		if not wanted.has(action):
			_send(action, false)
	for action in wanted:
		if not _active.has(action):
			_send(action, true)
	_active = wanted
	if _pad != null:
		_pad.queue_redraw()


func _collect_wanted(wanted: Dictionary) -> void:
	_restart_down = false
	for finger in _touches:
		var pos: Vector2 = _touches[finger]
		if finger == _dpad_finger:
			_dpad_actions(pos, wanted)
			continue
		var b := _button_at(pos)
		if b.is_empty():
			continue
		if b["id"] == &"restart":
			_restart_down = true
			if _restart_fired:
				wanted[&"restart"] = true
		else:
			wanted[b["action"]] = true
	if not _restart_down:
		_restart_hold = 0.0
		_restart_fired = false


func _dpad_actions(pos: Vector2, wanted: Dictionary) -> void:
	var d := pos - _dpad_center
	var dist := d.length()
	if dist <= 0.001:
		return
	if absf(d.x) > DPAD_RADIUS * DPAD_HORIZONTAL_DEADZONE and absf(d.x) / dist > DPAD_AXIS_SHARE:
		wanted[&"move_right" if d.x > 0.0 else &"move_left"] = true
	if absf(d.y) > DPAD_RADIUS * DPAD_VERTICAL_DEADZONE and absf(d.y) / dist > DPAD_AXIS_SHARE:
		wanted[&"crouch" if d.y > 0.0 else &"climb_up"] = true


func _button_at(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	for b in _buttons:
		var dist := pos.distance_to(b["center"])
		if dist <= float(b["radius"]) + HIT_SLOP and dist < best_dist:
			best = b
			best_dist = dist
	return best


func _send(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(event)


# --- drawing -----------------------------------------------------------------------------------

func _draw_pad() -> void:
	if not _shown:
		return
	var font := _pad.get_theme_default_font()
	for b in _buttons:
		var center: Vector2 = b["center"]
		var radius: float = b["radius"]
		var held := _restart_down if b["id"] == &"restart" else _active.has(b["action"])
		_draw_disc(center, radius, held)
		if b["id"] == &"menu":
			var bar := Vector2(7.0, 20.0)
			_pad.draw_rect(Rect2(center + Vector2(-11.0, -10.0), bar), GLYPH)
			_pad.draw_rect(Rect2(center + Vector2(4.0, -10.0), bar), GLYPH)
		else:
			var size := 28 if b["id"] == &"jump" or b["id"] == &"kick" else 22
			_pad.draw_string(font, center + Vector2(-radius, size * 0.35), b["label"],
					HORIZONTAL_ALIGNMENT_CENTER, radius * 2.0, size, GLYPH)
		if b["id"] == &"restart" and _restart_down:
			_pad.draw_arc(center, radius + 7.0, -PI * 0.5, -PI * 0.5 + TAU * (_restart_hold / RESTART_HOLD),
					32, GLYPH, 4.0, true)
	_draw_dpad()


func _draw_disc(center: Vector2, radius: float, held: bool) -> void:
	_pad.draw_circle(center, radius, FILL_HELD if held else FILL_IDLE)
	_pad.draw_arc(center, radius, 0.0, TAU, 48, RING_SHADOW, 5.0, true)
	_pad.draw_arc(center, radius, 0.0, TAU, 48, RING, 2.0, true)


func _draw_dpad() -> void:
	_draw_disc(_dpad_center, DPAD_RADIUS, _dpad_finger != -1)
	var arrows := {
		&"climb_up": Vector2.UP,
		&"crouch": Vector2.DOWN,
		&"move_left": Vector2.LEFT,
		&"move_right": Vector2.RIGHT,
	}
	for action in arrows:
		var dir: Vector2 = arrows[action]
		var side := dir.orthogonal()
		var tip := _dpad_center + dir * DPAD_RADIUS * 0.72
		var base := _dpad_center + dir * DPAD_RADIUS * 0.42
		var color := GLYPH if _active.has(action) else Color(1, 1, 1, 0.35)
		_pad.draw_colored_polygon(PackedVector2Array([tip, base + side * 16.0, base - side * 16.0]), color)
	var knob := _dpad_center
	if _dpad_finger != -1 and _touches.has(_dpad_finger):
		knob += ((_touches[_dpad_finger] as Vector2) - _dpad_center).limit_length(DPAD_RADIUS * 0.55)
	_pad.draw_circle(knob, 22.0, Color(1, 1, 1, 0.5 if _dpad_finger != -1 else 0.25))
