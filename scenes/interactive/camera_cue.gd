@tool
class_name CameraCue
extends Node2D
## A powered device that shows the player something off-screen: a rising edge of its power pans the camera to this
## node, holds, and eases back to the player. Place it at the point to look at and pick its power sources in
## `sources` on this node: they are forwarded to the `PowerTarget` child, so Editable Children is not needed (a
## conductor wire ending at that child works too). `invert` is exported here as well. `all_required` stays on the
## `PowerTarget` child (the default, any one source powers it).
##
## EDGES: only a rising edge plays the cue; falling edges do nothing. The startup state is not an edge
## (`set_powered_initial()` only records it), so a level that loads with the source already on, or a checkpoint
## restore, never cues. `play()` is the same thing for a script or another device (it goes through `delay`, `once`
## and `cooldown` like an edge).
##
## TIMING: `delay` seconds pass between the edge and the start of the pan (a door's opening can be lined up with the
## camera arriving), then `pan_time`, `hold_time`, `return_time`. `once` plays the cue only the first time (the
## flag is saved, so a restore from a checkpoint after the cue does not replay it). `cooldown` ignores edges for
## that many seconds after a cue ends (finished, replaced or cut short by a hit); an edge during a cue that is
## already playing restarts it from the camera's current offset. The pending delay and the cooldown are plain
## countdowns in `_physics_process()`, so pausing freezes them and nothing here uses `create_timer()`.
##
## The camera work is the player's (`show_cue()`, see Camera under Player); this node only decides when. It reads
## `global_position` every frame, so a cue parented to a moving platform tracks it. The cue never locks input.
##
## SAVE: only `fired` (what `once` needs). The cue itself is runtime only: `load_state()` is silent and cancels a
## pending delay.
##
## AUTHORING: `show_view_rect` draws the 512x288 view rectangle centred on the cue point, while `authoring_overlay`
## is set (the editor sets it; a runtime level editor can too). The sound id `interactive/camera_cue_pan` plays when
## the pan starts and is in Audio.PLANNED.

enum CueEase { LINEAR, SINE, CUBIC }

## Seconds the camera takes to move from where it is to this node.
@export_range(0.0, 5.0, 0.05, "or_greater") var pan_time: float = 0.6
## Seconds the camera stays on this node.
@export_range(0.0, 10.0, 0.05, "or_greater") var hold_time: float = 1.5
## Seconds the camera takes to come back to the player.
@export_range(0.0, 5.0, 0.05, "or_greater") var return_time: float = 0.6
## Seconds from the power edge to the start of the pan.
@export_range(0.0, 10.0, 0.05, "or_greater") var delay: float = 0.0
## Play only the first time.
@export var once: bool = false
## Ignore edges for this many seconds after a cue ends.
@export_range(0.0, 30.0, 0.1, "or_greater") var cooldown: float = 0.0
## The curve of the pan and of the return.
@export var ease_curve: CueEase = CueEase.SINE
## The power sources that drive the cue (any one of them powers it). Forwarded to the `PowerTarget` child when the
## node enters the tree and whenever this list is edited, so the child needs no Editable Children. Left empty, the
## child's own `sources` (and any conductor wire) are used as before.
@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if is_node_ready():
			_forward_sources(true)
			update_configuration_warnings()
## Inverts the power: the cue plays when the source turns off.
@export var invert: bool = false
## Authoring overlay: the view rectangle centred on this node.
@export var show_view_rect: bool = true:
	set(value):
		show_view_rect = value
		queue_redraw()

const VIEW_SIZE := Vector2(512.0, 288.0) ## What the camera sees: the 1280x720 viewport at zoom 2.5.
const SOUND_PAN := &"interactive/camera_cue_pan"
const OVERLAY_COLOR := Color(1.0, 0.85, 0.3, 0.8)

var powered: bool = false ## The last final (post-invert) state the device was given.
var authoring_overlay: bool = false ## Draws the view rectangle. Set in `_ready()` in the editor; a runtime level editor can set it too.
var _fired: bool = false
var _delay_left: float = -1.0 ## Seconds until the pan starts; negative = no cue is waiting.
var _cooldown_left: float = 0.0
var _player: Node

## Runs before the `PowerTarget` child's own `_ready()`, so its first (deferred) recompute already sees the sources.
func _enter_tree() -> void:
	_forward_sources(false)

func _ready() -> void:
	authoring_overlay = Engine.is_editor_hint()
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	set_physics_process(false)
	add_to_group(&"saveable")  # joined here, never deferred (see Checkpoint and save/restore)

## The startup state is recorded, never an edge.
func set_powered_initial(on: bool) -> void:
	powered = on

func set_powered(on: bool) -> void:
	var rising := on and not powered
	powered = on
	if rising:
		play()

## Starts the cue as a rising edge would: ignored while a delay is already pending, after the first play when
## `once` is set, and during a cooldown.
func play() -> void:
	if Engine.is_editor_hint() or _delay_left >= 0.0 or _cooldown_left > 0.0:
		return
	if once and _fired:
		return
	if once:
		_fired = true
	if delay > 0.0:
		_delay_left = delay
		set_physics_process(true)
	else:
		_start_cue()

func _physics_process(delta: float) -> void:
	if _delay_left >= 0.0:
		_delay_left -= delta
		if _delay_left <= 0.0:
			_delay_left = -1.0
			_start_cue()
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	if _delay_left < 0.0 and _cooldown_left <= 0.0:
		set_physics_process(false)

func _start_cue() -> void:
	var player := _find_player()
	if player == null:
		return
	if not player.is_connected(&"cue_ended", _on_cue_ended):
		player.connect(&"cue_ended", _on_cue_ended)
	player.show_cue(self, {
		"pan_time": pan_time,
		"hold_time": hold_time,
		"return_time": return_time,
		"ease": _ease_name(),
		"source": self,
	})
	if player.is_cue_playing():  # a dead or dancing player ignores the cue: no sound then
		Audio.play(SOUND_PAN)

func _on_cue_ended(source: Object) -> void:
	if source != self or cooldown <= 0.0:
		return
	_cooldown_left = cooldown
	set_physics_process(true)

## The player, looked up lazily because it joins group "player" in its own `_ready()`, which can run after ours.
func _find_player() -> Node:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group(&"player")
	if _player != null and _player.has_method("show_cue") and _player.has_signal("cue_ended"):
		return _player
	return null

func _ease_name() -> StringName:
	match ease_curve:
		CueEase.LINEAR:
			return &"linear"
		CueEase.CUBIC:
			return &"cubic"
	return &"sine"

func save_state() -> Dictionary:
	return {"fired": _fired}

func load_state(d: Dictionary) -> void:
	_fired = d.get("fired", _fired)
	_delay_left = -1.0  # a restore never plays a cue
	_cooldown_left = 0.0

## Copies `sources` onto the `PowerTarget` child (a copy, so a conductor's `add_source()` never writes this export).
## `replace` also forwards an empty list, so clearing `sources` in the Inspector clears the child; at load an empty
## list leaves the child's own sources alone.
func _forward_sources(replace: bool) -> void:
	if sources.is_empty() and not replace:
		return
	var target := _power_target()
	if target != null:
		target.sources = sources.duplicate()

func _power_target() -> PowerTarget:
	for child in get_children():
		if child is PowerTarget:
			return child
	return null

## Plain method, so a runtime level validator can reuse it; `_get_configuration_warnings()` calls it.
func get_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var target := _power_target()
	if target == null:
		warnings.append("Add a PowerTarget child: without one nothing can drive this cue.")
	elif sources.is_empty() and target.sources.is_empty():
		warnings.append("No sources: pick the power source(s) in `sources`. (Fine only if a conductor wire ends at the PowerTarget.)")
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()

func _draw() -> void:
	if not authoring_overlay or not show_view_rect:
		return
	draw_rect(Rect2(-VIEW_SIZE * 0.5, VIEW_SIZE), OVERLAY_COLOR, false, 1.0)
	draw_line(Vector2(-6, 0), Vector2(6, 0), OVERLAY_COLOR, 1.0)
	draw_line(Vector2(0, -6), Vector2(0, 6), OVERLAY_COLOR, 1.0)
	draw_arc(Vector2.ZERO, 4.0, 0.0, TAU, 16, OVERLAY_COLOR, 1.0)
