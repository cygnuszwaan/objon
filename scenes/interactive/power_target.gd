@tool
class_name PowerTarget
extends Node2D
## Shared "receiving end" of the power contract. Add one as a child of anything that should be driven by
## buttons (door, laser turret, conveyor...), or extend it for a device that has no scene of its own
## (see debug_power_target.gd).
##
## The contract, duck-typed like take_hit() / get_conveyor_speed():
##   SOURCE  emits `powered_changed(on: bool)` and answers `is_powered() -> bool`   (Button today,
##           conductor circuits in Phase 2)
##   DEVICE  implements `set_powered(on: bool)`
## PowerTarget sits between them: it listens to its `sources`, combines their states, applies `invert`,
## and calls `_apply_power(on)` once per actual change (and once at startup, so an inverted target with
## nothing pressed starts on). The default `_apply_power()` forwards to `set_powered()` on the PARENT
## node; a subclass overrides `_apply_power()` instead.
##
## Sources are a typed node-picker list, so wiring is done by picking nodes in the Inspector. `invert` is
## per target, so two PowerTargets on one button can act oppositely. `all_required` (default off = OR)
## makes the target need EVERY source powered rather than any one.
##
## No valid sources = not driven at all: the device keeps its authored state (a turret stays on, a door
## stays closed), so a device scene can carry a PowerTarget child and behave exactly as before until
## something is wired to it. The first valid source (Inspector or conductor circuit) drives it.
##
## `invert` can also be declared on the PARENT device (`@export var invert: bool` on its root script), which
## puts the toggle in the device's own Inspector instead of behind Editable Children. Either one inverts;
## both set = inverted, not cancelled. `sources` and `all_required` stay on this node.
##
## Startup: the first recompute is deferred until every node's _ready() (and the conductor layers' own
## deferred build) has run, so a device is never driven before it is ready. That first apply, when it
## happens within STARTUP_FRAMES of load, goes to the parent device's `set_powered_initial(on)` if it has
## one (a door snaps to its state, a mirror doesn't count it as an edge) and to `set_powered(on)` otherwise.
##
## The cell a conductor wire attaches to is the cell THIS node sits in, not the device root's: move the
## PowerTarget child inside a multi-tile device to the tile the wire should end at.
##
## `debug_toggle_key` (default none) flips the final state from the keyboard, so any device can be triggered
## remotely while testing. It XORs with the computed state; an unlinked device starts from "unpowered".
##
## Editor overlay: a line from this node to each of its sources, orange when `invert` is on. Redrawn
## continuously in the editor only; costs nothing at runtime.

## Emitted after `_apply_power()`, once per change of the final (post-invert) state.
signal power_changed(on: bool)

@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if is_node_ready():
			_reconnect_sources()
			queue_redraw()
			update_configuration_warnings()
@export var invert: bool = false:
	set(value):
		invert = value
		if is_node_ready():
			recompute()
			queue_redraw()
@export var all_required: bool = false:
	set(value):
		all_required = value
		if is_node_ready():
			recompute()
@export var draw_links: bool = true ## Editor-only overlay.
@export var debug_toggle_key: Key = KEY_NONE ## Test convenience: physical key that flips this target's state. KEY_NONE = off.

const STARTUP_FRAMES := 3 ## A first apply this soon after load counts as the initial state.
const LINK_COLOR := Color(0.4, 0.85, 1.0, 0.8)
const LINK_COLOR_INVERTED := Color(1.0, 0.6, 0.2, 0.8)

var powered: bool = false ## Final state, after `invert`.
var _applied: bool = false ## False until the first recompute(), so the startup state is always applied.
var _connected: Array[Node] = []
var is_initial_apply: bool = false ## True only inside the _apply_power() call that sets the startup state.
var _ready_frame: int = 0
var _debug_flip: bool = false

func _ready() -> void:
	add_to_group(&"power_target")  # what ConductorLayer scans to wire circuits to targets by adjacency
	if Engine.is_editor_hint():
		set_process(true)
		return
	set_process(false)
	set_process_unhandled_input(debug_toggle_key != KEY_NONE)
	_ready_frame = Engine.get_physics_frames()
	_reconnect_sources(false)
	call_deferred("recompute")  # after every _ready(), so the device is ready to be driven

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == debug_toggle_key:
		_debug_flip = not _debug_flip
		recompute()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	queue_redraw()  # editor only (see _ready)

## Re-read every source and apply the result if it changed. Does nothing until there is something to
## read (a valid source, or a debug flip), so an unlinked device keeps its authored state.
func recompute() -> void:
	if Engine.is_editor_hint():
		return
	if not _has_valid_source() and not _debug_flip and not _applied:
		return
	var on := ((_sources_powered() != _is_inverted()) != _debug_flip)
	if _applied and on == powered:
		return
	is_initial_apply = not _applied and Engine.get_physics_frames() - _ready_frame <= STARTUP_FRAMES
	_applied = true
	powered = on
	_apply_power(on)
	is_initial_apply = false
	power_changed.emit(on)

## The final (post-invert) state a recompute would apply right now; false while nothing is wired. Read-only: lets a
## device that is itself a source (the camera cue's pass-through) answer `is_powered()` before its own first apply.
func evaluate() -> bool:
	if Engine.is_editor_hint() or (not _has_valid_source() and not _debug_flip):
		return false
	return (_sources_powered() != _is_inverted()) != _debug_flip

## Own `invert`, or a boolean `invert` declared on the parent device.
func _is_inverted() -> bool:
	if invert:
		return true
	var device := get_parent()
	return device != null and device.get(&"invert") == true

func _has_valid_source() -> bool:
	for source in sources:
		if _is_valid_source(source):
			return true
	return false

## Override in a subclass. The default forwards to the parent's set_powered() (or, for the startup
## state, its set_powered_initial() if it has one).
func _apply_power(on: bool) -> void:
	var device := get_parent()
	if device == null:
		return
	if is_initial_apply and device.has_method("set_powered_initial"):
		device.set_powered_initial(on)
	elif device.has_method("set_powered"):
		device.set_powered(on)

func _sources_powered() -> bool:
	var seen_any := false
	for source in sources:
		if not _is_valid_source(source):
			continue
		seen_any = true
		var lit: bool = source.is_powered()
		if all_required and not lit:
			return false
		if not all_required and lit:
			return true
	return seen_any and all_required

func _is_valid_source(source: Node) -> bool:
	return source != null and is_instance_valid(source) and source.has_method("is_powered")

func _reconnect_sources(apply_now: bool = true) -> void:
	if Engine.is_editor_hint():
		return
	for old in _connected:
		if is_instance_valid(old) and old.powered_changed.is_connected(_on_source_changed):
			old.powered_changed.disconnect(_on_source_changed)
	_connected.clear()
	for source in sources:
		_connect_source(source)
	if apply_now:
		recompute()

func _connect_source(source: Node) -> void:
	if source == null or not source.has_signal("powered_changed"):
		return
	if source.powered_changed.is_connected(_on_source_changed):
		return
	source.powered_changed.connect(_on_source_changed)
	_connected.append(source)

## Runtime only: attach one more source without touching the Inspector list's setter. ConductorLayer
## uses this to wire a circuit to the targets its terminals touch. Duplicates are ignored.
func add_source(source: Node) -> void:
	if Engine.is_editor_hint() or source == null or sources.has(source):
		return
	sources.append(source)
	_connect_source(source)
	recompute()

func _on_source_changed(_on: bool) -> void:
	recompute()  # re-reads every source, so OR / AND stay correct whichever one fired

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	for source in sources:
		if source != null and not source.has_method("is_powered"):
			warnings.append("%s has no is_powered(): it isn't a power source." % source.name)
	return warnings

func _draw() -> void:
	if not Engine.is_editor_hint() or not draw_links:
		return
	var color := LINK_COLOR_INVERTED if _is_inverted() else LINK_COLOR
	for source in sources:
		if source == null or not is_instance_valid(source) or not source is Node2D:
			continue
		var end := to_local((source as Node2D).global_position)
		draw_line(Vector2.ZERO, end, color, 1.0)
		draw_circle(end, 2.5, color)
