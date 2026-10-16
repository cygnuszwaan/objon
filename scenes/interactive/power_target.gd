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
## per target, so two PowerTargets on one button can act oppositely. `invert_sources` is a checkbox per source
## (same size as `sources`, kept in step by the `sources` setter): a ticked source is read as NOT before the sources
## are combined, so "door opens while A is on and B is off" is `all_required` with B ticked. A source with no entry
## (one a conductor adds at run time, or an array that fell out of step) is not inverted. The target's `invert`
## still flips the combined result afterwards. `all_required` (default off = OR)
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
## DELAY: the parent device's `delay` export (seconds, default 0) holds every change of the final state back by that
## long before the device is told, so triggers and their effects can be sequenced. It is a pure time shift, not a
## filter: each change is queued with its own countdown and applied in order, so a pulse shorter than `delay` still
## arrives as a pulse (a rising-edge device such as a mirror, a cannon or a dispenser never loses one). Both edges
## wait the same time. The startup state is never delayed (a restore snaps at once, with nothing pending), and a
## parent without a `delay` export is not delayed. A device that already has its own timing answers
## `has_own_power_delay()` with true and is left alone (the camera cue: its `delay` is the wait before the pan, and
## its pass-through shifts what it drives). The countdowns are plain game-time countdowns in `_physics_process()`
## (never `create_timer()`), so pausing freezes them and a camera cue's slow motion stretches them.
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
## Editor overlay: a line from this node to each of its sources, orange when `invert` is on or that source is ticked in `invert_sources`. Redrawn
## continuously in the editor only; costs nothing at runtime.

## Emitted after `_apply_power()`, once per change of the final (post-invert) state.
signal power_changed(on: bool)

@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if fit_flags(invert_sources, sources.size()):
			notify_property_list_changed()
		if is_node_ready():
			_reconnect_sources()
			queue_redraw()
			update_configuration_warnings()
## One checkbox per entry of `sources`, in the same order: tick it to read that source as NOT.
@export var invert_sources: Array[bool] = []:
	set(value):
		invert_sources = value
		if is_node_ready() and not _setting_pair:
			recompute()
			queue_redraw()
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
const DELAY_PROPERTY := &"delay" ## The export a device declares on its root to delay its power.
const LINK_COLOR := Color(0.4, 0.85, 1.0, 0.8)
const LINK_COLOR_INVERTED := Color(1.0, 0.6, 0.2, 0.8)

var powered: bool = false ## The state the device was last told: the final state after `invert`, `delay` seconds late.
var _desired: bool = false ## The latest final state (after `invert`), whether or not the device has been told yet.
var _desired_known: bool = false ## False until the first recompute(), so the startup state is always applied.
var _pending: Array = [] ## Changes waiting out `delay`, oldest first: [seconds_left: float, on: bool].
var _connected: Array[Node] = []
var _setting_pair: bool = false ## True inside `set_sources()`, so the flags alone do not trigger a recompute.
var is_initial_apply: bool = false ## True only inside the _apply_power() call that sets the startup state.
var _ready_frame: int = 0
var _debug_flip: bool = false

func _ready() -> void:
	add_to_group(&"power_target")  # what ConductorLayer scans to wire circuits to targets by adjacency
	set_physics_process(false)  # only while a delayed change is pending
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
## read (a valid source, or a debug flip), so an unlinked device keeps its authored state. The startup state and a
## change with no `delay` are applied at once; any other change joins the queue and is applied `delay` seconds later.
func recompute() -> void:
	if Engine.is_editor_hint():
		return
	if not _has_valid_source() and not _debug_flip and not _desired_known:
		return
	var on := ((_sources_powered() != _is_inverted()) != _debug_flip)
	if _desired_known and on == _desired:
		return
	var initial := not _desired_known and Engine.get_physics_frames() - _ready_frame <= STARTUP_FRAMES
	_desired_known = true
	_desired = on
	var wait := get_delay()
	if initial or (wait <= 0.0 and _pending.is_empty()):
		_commit(on, initial)
		return
	_pending.append([wait, on])  # a zero wait behind a pending change still queues, so order is kept
	set_physics_process(true)

## Tells the device (and then `power_changed` listeners) the state it should now have.
func _commit(on: bool, initial: bool = false) -> void:
	is_initial_apply = initial
	powered = on
	_apply_power(on)
	is_initial_apply = false
	power_changed.emit(on)

func _physics_process(delta: float) -> void:
	for entry in _pending:
		entry[0] -= delta
	while not _pending.is_empty() and _pending[0][0] <= 0.0:
		var due: Array = _pending.pop_front()
		_commit(due[1])
	if _pending.is_empty():
		set_physics_process(false)

## Seconds a change waits before the device is told: the parent's `delay` export, 0 when the parent has none or has
## its own timing (`has_own_power_delay()`).
func get_delay() -> float:
	var device := get_parent()
	if device == null or (device.has_method(&"has_own_power_delay") and device.has_own_power_delay()):
		return 0.0
	var wait: Variant = device.get(DELAY_PROPERTY)
	if wait is float or wait is int:
		return maxf(float(wait), 0.0)
	return 0.0

## The final (post-invert, undelayed) state a recompute would reach right now; false while nothing is wired. Read-only: lets a
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
	for i in sources.size():
		var source := sources[i]
		if not _is_valid_source(source):
			continue
		seen_any = true
		var lit: bool = source.is_powered() != flag_at(invert_sources, i)
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

## Replaces the source list and its per-source inversions together, so a device that forwards both (the camera cue,
## the powered tile layers) causes one recompute that sees both, never a half-updated pair. `inverts` shorter than
## `list` leaves the rest not inverted.
func set_sources(list: Array[Node], inverts: Array[bool] = []) -> void:
	var flags: Array[bool] = inverts.duplicate()
	fit_flags(flags, list.size())
	_setting_pair = true
	invert_sources = flags
	_setting_pair = false
	sources = list  # reconnects and recomputes once, with both in place

## Pads or trims `flags` in place to `count` entries (new ones false). Returns true if the size changed. Shared by every
## device that keeps a checkbox array beside a source list.
static func fit_flags(flags: Array[bool], count: int) -> bool:
	if flags.size() == count:
		return false
	flags.resize(count)
	return true

## True if entry `index` of `flags` is ticked; false past the end.
static func flag_at(flags: Array[bool], index: int) -> bool:
	return index >= 0 and index < flags.size() and flags[index]

## Runtime only: attach one more source without touching the Inspector list's setter. It gets no checkbox, so it is
## not inverted. ConductorLayer
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
	var target_inverted := _is_inverted()
	for i in sources.size():
		var source := sources[i]
		if source == null or not is_instance_valid(source) or not source is Node2D:
			continue
		var color := LINK_COLOR_INVERTED if target_inverted or flag_at(invert_sources, i) else LINK_COLOR
		var end := to_local((source as Node2D).global_position)
		draw_line(Vector2.ZERO, end, color, 1.0)
		draw_circle(end, 2.5, color)
