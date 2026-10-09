@tool
extends Area2D
## Floor button: a power SOURCE (see power_target.gd for the contract). Emits `powered_changed(on)` and
## answers `is_powered()`; PowerTargets pick it in their `sources` list.
##
## Art: button1_<colour>.png, 16x96 = six 16x16 frames, drawn by one Sprite2D (vframes = 6). Frame 5 is
## the dark resting pad, frame 0 the bright active one. Becoming active steps 5 -> 0, releasing steps
## 0 -> 5, and reversing mid-way just turns around from wherever the frame currently is. `color` only
## swaps the texture. The node origin is the centre of its 16x16 tile, like JumpPad.
##
## Latching:
##   MOMENTARY  active while something is pressing it. The player crouching while standing on it CYCLES it:
##              off, then on again within the same physics frame, so every target sees a falling and a
##              rising edge (a mirror steps, a cannon fires, a door reverses) without the player having
##              to step off and back on. Same edge rule as TOGGLE: one cycle per crouch, and arriving
##              already crouched doesn't count. It only cycles while it is active (the player on it holds
##              it active), and the pad visibly pops back up and presses down again.
##   TOGGLE     flips on each rising edge of "pressed" (standing on it does nothing further), and
##              also when the PLAYER crouches while standing on it. Two independent ways to flip: the
##              step-on edge and the crouch edge. One flip per crouch: the player must stand up and
##              crouch again to flip it back, and walking onto the pad already crouched doesn't count
##              as a crouch (it still counts as the step-on). The crouch is read through the same
##              duck-typed surface player.gd already exposes (`is_crouching`, `is_on_floor()`), so
##              player.gd needed no change. Blocks only ever trigger the step-on flip.
##   TIMED      active for `duration` seconds after a press (stepping on it, or the player starting a crouch on it).
##              Pressing again while it is active restarts the countdown (no powered_changed: the target stays on, the
##              pad presses down again and the press sound replays); standing on it does not extend it, and stepping off
##              and on again is a new press. The remaining time is shown on the pad itself: the frame sweeps from 0
##              (bright, sunk) to 5 (dark, risen) across the duration, so the pedestal rises as the time runs out, and a
##              glow on the pad pulses, faster over the last second. Saves its time left.
## Sounds follow `active`: interactive/button_press when it turns on, interactive/button_release when it
## turns off (in TOGGLE mode both are heard on presses).
##
## Solid pedestal: a child StaticBody2D (layer 2, joins "water_solid" so water rests on it) whose
## top follows the art. The top of the solid surface is the vertical middle of the blue oval in the
## current frame (SURFACE_TOP_PX, measured from the art), and it always extends down to the bottom of
## the tile, so the collider shrinks as the pad sinks and grows as it rises, in step with the frame
## the sprite shows. It is deliberately NOT in "ground"/"catwalk", so the ledge-grab can't latch onto
## it. Enemies masking layer 2 (Drillbot, Stingbot) are blocked by it like any other world body.
##
## Pressers: the player and ice/metal blocks (any MeltableBlock). Not enemies (they share layer 1 with
## the player, so the group/class check below is what filters them), not liquid (particles aren't
## bodies). The sensor is this Area2D's own CollisionShape2D: a strip straddling the top of the
## pedestal, so a body standing on it overlaps (a body beside it does not: the strip is narrower than
## the pedestal). It is polled every physics frame like Sawwheel and Crusher instead of tracking
## body_entered/exited, so a block that melts while on the pad can't leave it stuck pressed. The
## Area2D sits on no layer (nothing needs to detect it) and masks layer 1, which is where both the
## player and the blocks (layers 1|2) live; the pedestal is layer 2 only, so the sensor never sees it.
##
## Expected scene layout:
##   Button (Area2D, this script, collision_layer 0, collision_mask 1)
##     - Sprite2D
##     - CollisionShape2D   (sensor strip)
##     - Solid (StaticBody2D, layer 2)
##         - CollisionShape2D   (RectangleShape2D; resized by this script at runtime)

signal powered_changed(on: bool)

enum LatchMode { MOMENTARY, TOGGLE, TIMED }
enum ButtonColor { BLUE, RED, YELLOW, GREEN }

@export var color: ButtonColor = ButtonColor.BLUE:
	set(value):
		color = value
		if is_node_ready():
			_apply_art()
@export var latch_mode: LatchMode = LatchMode.MOMENTARY:
	set(value):
		latch_mode = value
		notify_property_list_changed()  # shows/hides `duration`
## TIMED only: seconds the button stays active after a press.
@export_range(0.1, 120.0, 0.1, "or_greater") var duration: float = 5.0

const COLOR_NAMES: PackedStringArray = ["blue", "red", "yellow", "green"]
const PLACEHOLDER_COLORS: Array[Color] = [
	Color(0.25, 0.5, 1.0), Color(1.0, 0.3, 0.3), Color(1.0, 0.85, 0.25), Color(0.35, 0.9, 0.4),
]
## Searched in order for button1_<colour>.png. objon.md says only "sprites/", and the other
## interactive art lives in sprites/interactive/, so both are tried; trim to whichever is right.
const ART_DIRS: PackedStringArray = ["res://sprites/interactive/", "res://sprites/"]
const FRAME_DARK := 5
const FRAME_LIT := 0
const ANIM_FPS := 30.0
const FRAME_COUNT := 6
## Top of the solid surface per frame, in art pixels down from the top of the 16px frame: the vertical
## middle of the blue oval (its rows run from the visible top down to row 5). Measured from
## button1_*.png; the four colours share this geometry. Retune here if the art changes.
const SURFACE_TOP_PX: PackedFloat32Array = [3.0, 3.5, 4.0, 4.0, 3.5, 3.0]
const HALF_TILE := 8.0
## After load_state() the pressed flag is trusted for this many physics frames even if the sensor reads empty:
## a restored block only overlaps the strip once the physics server has stepped, and a TOGGLE button would
## otherwise see that as a fresh press and flip.
const RESTORE_GRACE_FRAMES := 3
const SOLID_WIDTH := 14.0 ## The pedestal's width in px (the art's widest rows).
const GLOW_HZ := 1.5 ## TIMED glow pulses per second while plenty of time is left...
const GLOW_HZ_URGENT := 5.0 ## ...and over the last GLOW_URGENT_TIME seconds.
const GLOW_URGENT_TIME := 1.0

var active: bool = false
var _pressed: bool = false ## Physical state; `active` derives from it via latch_mode.
var _player: CharacterBody2D
var _crouch_prev: bool = false ## The player's is_crouching last physics frame, wherever they were.
var _frame_pos: float = float(FRAME_DARK)
var _restore_grace: int = 0
var _time_left: float = 0.0 ## TIMED: seconds of activity remaining (0 when inactive).
var _glow_phase: float = 0.0
var _warned_missing_art: bool = false

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _solid: StaticBody2D = $Solid
@onready var _solid_shape: CollisionShape2D = $Solid/CollisionShape2D

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach buttons to circuits by adjacency
	if not Engine.is_editor_hint():
		add_to_group(&"saveable")
	_apply_art()
	set_process(false)  # only runs while the frame is travelling
	if Engine.is_editor_hint():
		set_physics_process(false)  # the scene file already holds the resting-frame collider
		return
	# The shape resource is shared by every instance of this scene: give this one its own before it
	# gets resized per frame, or every button in the level would follow whichever animated last.
	_solid_shape.shape = RectangleShape2D.new()
	_sync_solid(FRAME_DARK)
	_solid.add_to_group(&"water_solid")  # collision only; water rests on the pedestal
	_player = get_tree().get_first_node_in_group(&"player") as CharacterBody2D  # usually null here: see _poll_crouch

func _validate_property(property: Dictionary) -> void:
	if property.name == "duration" and latch_mode != LatchMode.TIMED:
		property.usage = PROPERTY_USAGE_STORAGE  # kept in the scene, hidden in the Inspector

## Power-source contract (PowerTarget reads this).
func is_powered() -> bool:
	return active

## Saveable contract (see game.gd). Both the logical state and the physical "pressed" flag are stored, so a
## restored TOGGLE button held down by a block doesn't see the block as a new rising edge.
func save_state() -> Dictionary:
	return {"active": active, "pressed": _pressed, "time_left": _time_left}

## Snaps the pad to the saved state: no sound, no animation. Emits powered_changed only if `active` differs
## from the current value, so circuits and targets follow.
func load_state(d: Dictionary) -> void:
	var was_active := active
	active = d.get("active", false)
	_pressed = d.get("pressed", false)
	_restore_grace = RESTORE_GRACE_FRAMES if _pressed else 0
	_time_left = float(d.get("time_left", 0.0)) if latch_mode == LatchMode.TIMED and active else 0.0
	if latch_mode == LatchMode.TIMED and active and _time_left <= 0.0:
		_time_left = duration  # a snapshot without a time (older save): start a fresh countdown
	_frame_pos = _target_frame()
	var frame_index := roundi(_frame_pos)
	_sprite.frame = frame_index
	_sync_solid(frame_index)
	set_process(latch_mode == LatchMode.TIMED and active)  # a timed button keeps sweeping and pulsing
	queue_redraw()
	if active != was_active:
		powered_changed.emit(active)

func _physics_process(delta: float) -> void:
	_poll_crouch()
	_tick_timer(delta)
	var pressed := _is_pressed()
	if _restore_grace > 0:
		_restore_grace -= 1
		if not pressed and _pressed:
			return
	if pressed == _pressed:
		return
	_pressed = pressed
	match latch_mode:
		LatchMode.MOMENTARY:
			_set_active(pressed)
		LatchMode.TOGGLE:
			if pressed:
				_set_active(not active)
		LatchMode.TIMED:
			if pressed:
				_start_timer()

## The frame the player's crouch STARTS while they are standing on the pad: TOGGLE flips, MOMENTARY cycles
## (off then on). _crouch_prev is sampled every frame, on or off the pad, so arriving already crouched
## isn't an edge.
func _poll_crouch() -> void:
	if _player == null or not is_instance_valid(_player):
		# player.gd adds itself to group "player" in its own _ready(), so a button placed above the Player in the level
		# tree finds nothing in its _ready(): look again every frame until it is there (and again after a respawn
		# reload frees the old player), or the crouch never registers.
		_player = get_tree().get_first_node_in_group(&"player") as CharacterBody2D
		_crouch_prev = _player != null and _player.is_crouching  # a player found already crouched isn't an edge
		return
	var crouching: bool = _player.is_crouching
	if crouching and not _crouch_prev and _player.is_on_floor() and overlaps_body(_player):
		match latch_mode:
			LatchMode.TOGGLE:
				_set_active(not active)
			LatchMode.MOMENTARY:
				_cycle()
			LatchMode.TIMED:
				_start_timer()
	_crouch_prev = crouching

## Off then straight back on, all in this frame. Both emissions are synchronous, so every PowerTarget (and
## circuit) sees the falling edge and then the rising edge. The frame is reset to dark so the pad replays its
## press animation instead of staying sunk. Does nothing unless the button is currently active.
func _cycle() -> void:
	if not active:
		return
	_set_active(false)
	_frame_pos = float(FRAME_DARK)
	_set_active(true)

## TIMED: a press. Starts the countdown (turning the button on) or, if it is already running, restarts it from the full
## duration; the pad presses down again and the press sound replays, but targets see no edge.
func _start_timer() -> void:
	_time_left = duration
	if active:
		Audio.play_at(&"interactive/button_press", global_position)
		set_process(true)
	else:
		_set_active(true)

## TIMED: counts the remaining time down and releases the button when it runs out. Runs before this frame's press check,
## so a press landing on the same frame restarts the full duration rather than being ticked.
func _tick_timer(delta: float) -> void:
	if latch_mode != LatchMode.TIMED or not active:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	if _time_left <= 0.0:
		_set_active(false)

func _is_pressed() -> bool:
	for body in get_overlapping_bodies():
		if _can_press(body):
			return true
	return false

func _can_press(body: Node) -> bool:
	return body.is_in_group("player") or body is MeltableBlock

func _set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	if not on:
		_time_left = 0.0
	Audio.play_at(&"interactive/button_press" if on else &"interactive/button_release", global_position)
	set_process(true)
	powered_changed.emit(on)

## The frame the pad is heading for: the resting ends for the plain modes, and for an active TIMED button a point on the
## 0 (bright, sunk) .. 5 (dark, risen) sweep given by the fraction of the time already used.
func _target_frame() -> float:
	if latch_mode == LatchMode.TIMED and active:
		var used := 1.0 - clampf(_time_left / maxf(duration, 0.001), 0.0, 1.0)
		return lerpf(float(FRAME_LIT), float(FRAME_DARK), used)
	return float(FRAME_LIT if active else FRAME_DARK)

func _process(delta: float) -> void:
	var timed_running := latch_mode == LatchMode.TIMED and active
	var target := _target_frame()
	_frame_pos = move_toward(_frame_pos, target, ANIM_FPS * delta)  # sinking on a press is still fast; the sweep itself is slow
	var frame_index := roundi(_frame_pos)
	if frame_index != _sprite.frame:
		_sprite.frame = frame_index
		_sync_solid(frame_index)
	if timed_running:
		var hz := GLOW_HZ_URGENT if _time_left <= GLOW_URGENT_TIME else GLOW_HZ
		_glow_phase = fposmod(_glow_phase + delta * hz * TAU, TAU)
	queue_redraw()
	if is_equal_approx(_frame_pos, target) and not timed_running:
		set_process(false)

# --- solid ---------------------------------------------------------------------------------------

## Resize the pedestal so its top sits at the middle of the oval for `frame_index` and its bottom stays
## on the tile's lower edge.
func _sync_solid(frame_index: int) -> void:
	var top := SURFACE_TOP_PX[clampi(frame_index, 0, FRAME_COUNT - 1)] - HALF_TILE  # local y
	var rect := _solid_shape.shape as RectangleShape2D
	rect.size = Vector2(SOLID_WIDTH, HALF_TILE - top)
	_solid_shape.position = Vector2(0.0, (top + HALF_TILE) * 0.5)

# --- art -----------------------------------------------------------------------------------------

func _apply_art() -> void:
	if _sprite == null:
		return
	var texture: Texture2D = null
	for dir in ART_DIRS:
		var path := "%sbutton1_%s.png" % [dir, COLOR_NAMES[color]]
		if ResourceLoader.exists(path):
			texture = load(path) as Texture2D
			break
	if texture == null and not _warned_missing_art:
		_warned_missing_art = true
		push_warning("Button: no button1_%s.png under %s — drawing a placeholder" % [COLOR_NAMES[color], ", ".join(ART_DIRS)])
	_sprite.texture = texture
	_sprite.hframes = 1
	_sprite.vframes = FRAME_COUNT
	_sprite.frame = roundi(_frame_pos)
	queue_redraw()

## Placeholder pad while the texture is missing, and the TIMED glow on top of whichever art is there.
func _draw() -> void:
	if _sprite == null:
		return
	var base: Color = PLACEHOLDER_COLORS[color]
	var top := SURFACE_TOP_PX[clampi(roundi(_frame_pos), 0, FRAME_COUNT - 1)] - HALF_TILE
	if _sprite.texture == null:
		var lit := 1.0 - (_frame_pos / float(FRAME_DARK))  # 0 dark .. 1 bright
		draw_rect(Rect2(-SOLID_WIDTH * 0.5, top, SOLID_WIDTH, HALF_TILE - top), base.darkened(0.6).lerp(base, lit))
	if latch_mode == LatchMode.TIMED and active:
		# A pulsing strip along the top of the pad. It fades out over the last stretch of the sweep so the pad doesn't
		# end on a bright flash once the button has gone dark.
		var fade := clampf(_time_left / 0.5, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(_glow_phase)
		var glow := base.lightened(0.5)
		glow.a = (0.25 + 0.5 * pulse) * fade
		draw_rect(Rect2(-SOLID_WIDTH * 0.5 + 1.0, top - 1.0, SOLID_WIDTH - 2.0, 2.0), glow)
