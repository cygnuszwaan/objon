@tool
extends Area2D
## Level finish. Locked (red light) until the unlock rule is met, then unlocked (green light); a player
## reaching it while unlocked plays the open animation, starts the player's victory dance and, after a short
## pause, emits `level_completed` and shows the placeholder level-complete overlay.
##
## The player's exit is `dance_through()` (player.gd): it slides to the finish's centre x over `slide_time`, then
## shrinks toward its own centre over `shrink_time` and disappears, as if dancing down the hallway beyond. The
## level completes once the open animation AND that exit have finished, plus `complete_delay`. The player is
## drawn in front of the finish only if the Player node comes after this one in the tree (or has a higher
## `z_index`); an earlier Player node would be hidden behind the open door.
##
## Art (res://sprites/interactive/), all 32x32 frames, stacked vertically:
##   finish_locked.png    2 frames, loops (red light)
##   finish_unlocked.png  2 frames, loops (green light)
##   finish_open.png      13 frames, plays once on entry and holds its last frame
## The AnimatedSprite2D and its SpriteFrames are built in code (never saved into the scene), so the editor
## shows the locked art for placement without serialising sub-resources.
##
## Origin: bottom-centre of the art, on a 16px grid point, so the node sits on the floor tile's top edge.
## The sensor is the scene's CollisionShape2D (mask layer 1, where the player lives; the node is on no layer).
## It is polled every physics frame like Sawwheel/Crusher rather than tracking body_entered, so a player who
## is already standing in the doorway when it unlocks still enters.
##
## Unlock rule:
##   gems     `required_gem_percent` of the level's gems (total = group "gem" at load, read from the player's
##            `gems_total`; needed = ceil(total * percent / 100)). A level with no gems counts as met.
##   button   optional: give the PowerTarget child `sources` (or let a conductor wire attach to it).
##            Nothing wired = gems only.
##   combine  `require_all` true = gems AND button; false = gems OR button.
## It can relock (a released momentary button) until the player has entered.
##
## Power contract: set_powered(on) records the button state (the first call marks the finish as "wired");
## set_powered_initial(on) does the same silently for the startup state. `invert` is read by the PowerTarget.
##
## Expected scene layout:
##   Finish (Area2D, this script, layer 0 / mask 1)
##     - CollisionShape2D   (sensor)
##     - PowerTarget        (place it in the tile a wire should end at)

signal level_completed
signal unlocked_changed(unlocked: bool)

enum FinishState { LOCKED, UNLOCKED, OPENING, OPEN }

const LOCKED_TEXTURE: Texture2D = preload("res://sprites/interactive/finish_locked.png")
const UNLOCKED_TEXTURE: Texture2D = preload("res://sprites/interactive/finish_unlocked.png")
const OPEN_TEXTURE: Texture2D = preload("res://sprites/interactive/finish_open.png")
const LevelCompleteScene: PackedScene = preload("res://scenes/ui/level_complete.tscn")
const FRAME := 32
const IDLE_FRAMES := 2
const OPEN_FRAMES := 13

@export_range(0.0, 100.0, 1.0) var required_gem_percent: float = 100.0 ## Share of the level's gems needed to unlock.
@export var require_all: bool = false ## With a wired button: true = gems AND button, false = gems OR button.
@export var invert: bool = false ## Flips the button state (read by the PowerTarget child).
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0
@export_file("*.tscn") var next_level: String = "" ## Optional override: the scene the overlay continues to. Empty = the next level in `LevelCatalog` order (none after the last = offer a replay).
@export var idle_fps: float = 4.0 ## Light blink rate of the locked/unlocked art.
@export var open_fps: float = 12.0
@export var slide_time: float = 0.4 ## Seconds for the player to slide to the door's centre.
@export var shrink_time: float = 1.2 ## Seconds for the player to shrink away after sliding.
@export var complete_delay: float = 0.5 ## Seconds after the door has opened and the player has gone before the level completes.

var state: FinishState = FinishState.LOCKED
var _sprite: AnimatedSprite2D
var _player: Node
## Frames _init_from_level() keeps looking for the player before warning (see there).
const PLAYER_LOOKUP_FRAMES := 10
var _initialized: bool = false
var _gems_collected: int = 0
var _gems_total: int = 0
var _button_wired: bool = false
var _button_on: bool = false
var _exit_tween: Tween

func _ready() -> void:
	_build_sprite()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_sprite.animation_finished.connect(_on_animation_finished)
	# Deferred: every gem must have joined its group and the player must have counted them.
	_init_from_level.call_deferred()

func _build_sprite() -> void:
	_sprite = AnimatedSprite2D.new()
	_sprite.name = "Art"
	_sprite.position = Vector2(0.0, -FRAME * 0.5)
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	_add_animation(frames, &"locked", LOCKED_TEXTURE, IDLE_FRAMES, idle_fps, true)
	_add_animation(frames, &"unlocked", UNLOCKED_TEXTURE, IDLE_FRAMES, idle_fps, true)
	_add_animation(frames, &"open", OPEN_TEXTURE, OPEN_FRAMES, open_fps, false)
	_sprite.sprite_frames = frames
	add_child(_sprite)  # no owner: live only, never saved into the scene
	_sprite.play(&"locked")

func _add_animation(frames: SpriteFrames, anim: StringName, texture: Texture2D, count: int, fps: float, loop: bool) -> void:
	frames.add_animation(anim)
	frames.set_animation_speed(anim, fps)
	frames.set_animation_loop(anim, loop)
	for i in count:
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(0, i * FRAME, FRAME, FRAME)
		frames.add_frame(anim, atlas)

func _init_from_level() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	# player.gd joins group "player" in its own _ready(); the deferred call usually clears that, but wait a few frames
	# before giving up in case the Player is built later (or sits further down a slow-loading tree).
	var retries := PLAYER_LOOKUP_FRAMES
	while _player == null and retries > 0 and is_inside_tree():
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group(&"player")
		retries -= 1
	if _player != null:
		_gems_total = _player.gems_total
		_gems_collected = _player.gems_collected
		_player.gem_collected.connect(_on_gem_collected)
	else:
		push_warning("Finish: no node in group 'player' — gems can't count toward unlocking")
	_initialized = true
	_update_lock(true)

# --- unlock rule -----------------------------------------------------------------------------------

func _on_gem_collected(count: int, total: int) -> void:
	_gems_collected = count
	_gems_total = total
	_update_lock(false)

## Power contract (PowerTarget calls these): the button state. Calling either marks the finish as wired.
func set_powered(on: bool) -> void:
	_button_wired = true
	_button_on = on
	_update_lock(false)

func set_powered_initial(on: bool) -> void:
	_button_wired = true
	_button_on = on
	_update_lock(true)

func _unlock_condition() -> bool:
	var needed := ceili(_gems_total * required_gem_percent / 100.0)
	var gems_ok := _gems_collected >= needed
	if not _button_wired:
		return gems_ok
	return (gems_ok and _button_on) if require_all else (gems_ok or _button_on)

## Locked <-> unlocked, until the player enters. `silent` skips the unlock sound (the state at load).
func _update_lock(silent: bool) -> void:
	if not _initialized or state == FinishState.OPENING or state == FinishState.OPEN:
		return
	var want := _unlock_condition()
	var new_state := FinishState.UNLOCKED if want else FinishState.LOCKED
	if new_state == state:
		return
	state = new_state
	_sprite.play(&"unlocked" if want else &"locked")
	if want and not silent:
		Audio.play_at(&"interactive/finish_unlock", global_position)
	unlocked_changed.emit(want)

# --- entry -----------------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if state != FinishState.UNLOCKED:
		return
	for body in get_overlapping_bodies():
		if body.is_in_group(&"player") and body.get(&"is_dead") != true and body.get(&"is_dancing") != true:
			_enter(body)
			return

func _enter(body: Node) -> void:
	state = FinishState.OPENING
	_sprite.play(&"open")
	Audio.play_at(&"interactive/finish_open", global_position)
	if body.has_method(&"dance_through"):
		_exit_tween = body.dance_through(global_position.x, slide_time, shrink_time)
	elif body.has_method(&"start_dance"):
		body.start_dance()

func _on_animation_finished() -> void:
	if state != FinishState.OPENING:
		return
	state = FinishState.OPEN  # holds the last frame
	if _exit_tween != null and _exit_tween.is_valid():
		await _exit_tween.finished  # the player may still be shrinking away
	await get_tree().create_timer(complete_delay, false).timeout
	_complete()

func _complete() -> void:
	level_completed.emit()
	var overlay := LevelCompleteScene.instantiate()
	Game.level_root().add_child(overlay)
	overlay.show_result(_gems_collected, _gems_total, Game.next_level_id(next_level))
