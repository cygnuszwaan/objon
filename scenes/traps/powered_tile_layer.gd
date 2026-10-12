@tool
class_name PoweredTileLayer
extends TileMapLayer
## The shared base of the switchable tile layers (`PoweredSpikeLayer`, `PoweredCatwalkLayer`, `PoweredLadderLayer`): a
## `TileMapLayer` that is either OUT or RETRACTED as a whole. Powered = out; unpowered = retracted; unwired = out (the
## authored state), so an unwired layer behaves exactly like the same tiles painted on an ordinary layer. The layer
## has no state of its own to save: it is a pure function of its sources, and a source's restore emits `powered_changed`
## on any change, so a checkpoint restore needs no code here.
##
## This class owns the power plumbing and the retract warning; a subclass says what "out" means by overriding
## `_apply_state(on)` (collision, groups, a player hook) and names its sounds and its noun for warnings.
##
## POWER: `sources` and `invert` are exported here and forwarded to the `PowerTarget` child (as `CameraCue` does), so
## an instance is wired in its own Inspector without Editable Children; a conductor wire can instead end at the
## `PowerTarget` child (move it to the tile the wire should end at). `all_required` stays on the `PowerTarget` child.
## Independent groups of tiles are separate layers.
##
## TRANSITIONS: extending is instant. Retracting is instant too unless `warn_time` is above 0 (a subclass opts in
## through `_supports_warning()`): then the layer blinks, still fully OUT and solid, for `warn_time` seconds after the
## power falls and retracts when it ends. Power returning during the blink cancels it (no sound, no change). The
## startup state (`set_powered_initial()`) always snaps, with no blink and no sound.
##
## GHOST: with `show_ghost` on, a retracted layer stays drawn as a faint ghost (`ghost_opacity`) so the player can see
## where it will appear; it is still retracted in every other way (no collision, not in its groups, no hazard).
## During a blink the layer alternates between full and ghost instead of full and hidden.
##
## SOUND: `_sound_id(extended)` names the extend and retract sounds, played at the middle of the painted cells when
## the state really changes after startup (a retract plays when it happens, after any blink).

## The power sources that drive the layer (any one of them powers it). Forwarded to the `PowerTarget` child when the
## node enters the tree and whenever this list is edited. Left empty, the child's own `sources` (and any conductor
## wire) are used as before.
@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if is_node_ready():
			_forward_sources(true)
			update_configuration_warnings()
## Inverts the power: the layer is out while the source is off.
@export var invert: bool = false
## Seconds the layer blinks, still solid, between the power falling and the layer retracting. 0 = retract at once.
## The retract is this much later than the source: a TIMED button's `duration` is the time before the blink starts.
@export_range(0.0, 10.0, 0.05, "or_greater") var warn_time: float = 1.0

## Keep a retracted layer drawn as a faint ghost of where it will be. Purely visual: a ghost is not solid, not a ladder
## and not a hazard.
@export var show_ghost: bool = false:
	set(value):
		show_ghost = value
		notify_property_list_changed()
		if is_node_ready() and not Engine.is_editor_hint():
			_show(out and _warn_left <= 0.0)
## How opaque the ghost is, as a fraction of the layer's own opacity.
@export_range(0.05, 0.8, 0.01) var ghost_opacity: float = 0.25:
	set(value):
		ghost_opacity = value
		if is_node_ready() and not Engine.is_editor_hint():
			_show(out and _warn_left <= 0.0)

const WARN_BLINK_HZ := 5.0 ## The same pulse rate as a TIMED button's last second.

var out: bool = true ## Runtime state: the layer is out. Authored state is out.
var _warn_left: float = 0.0 ## Seconds of blink remaining (0 = not warning).
var _warn_elapsed: float = 0.0
var _base_alpha: float = 1.0 ## The layer's authored `modulate.a`, which a full draw restores and a ghost scales.

## Runs before the `PowerTarget` child's own `_ready()`, so its first (deferred) recompute already sees the sources.
func _enter_tree() -> void:
	_forward_sources(false)

func _ready() -> void:
	set_physics_process(false)
	_base_alpha = modulate.a
	if Engine.is_editor_hint():
		return
	_set_out(true)

func _validate_property(property: Dictionary) -> void:
	if property.name == "warn_time" and not _supports_warning():
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "ghost_opacity" and not show_ghost:
		property.usage = PROPERTY_USAGE_NO_EDITOR

# ---- subclass hooks ---------------------------------------------------------------------------------------------

## Apply the state: runs from every change of `out`, including startup. `visible` is already set.
func _apply_state(_on: bool) -> void:
	pass

## Whether `warn_time` applies to this kind of layer.
func _supports_warning() -> bool:
	return true

## The sound for extending (`true`) or retracting (`false`); `&""` for none.
func _sound_id(_extended: bool) -> StringName:
	return &""

## What the layer holds, for configuration warnings ("spikes", "catwalks", "ladders").
func _noun() -> String:
	return "tiles"

## Extra configuration warnings for the subclass.
func _extra_warnings() -> PackedStringArray:
	return PackedStringArray()

# ---- power device contract ---------------------------------------------------------------------------------------

## The startup state: snaps with no blink and no sound.
func set_powered_initial(on: bool) -> void:
	_cancel_warning()
	_set_out(on)

func set_powered(on: bool) -> void:
	if on:
		if _warn_left > 0.0:
			_cancel_warning()  # power came back during the blink: stays out
			return
		if out:
			return
		_set_out(true)
		_play_change(true)
	else:
		if not out or _warn_left > 0.0:
			return
		if warn_time > 0.0 and _supports_warning():
			_warn_left = warn_time
			_warn_elapsed = 0.0
			set_physics_process(true)
			return
		_set_out(false)
		_play_change(false)

# A plain countdown in _physics_process (pausing freezes it; no create_timer()).
func _physics_process(delta: float) -> void:
	if _warn_left <= 0.0:
		set_physics_process(false)
		return
	_warn_left -= delta
	_warn_elapsed += delta
	if _warn_left <= 0.0:
		_cancel_warning()
		_set_out(false)
		_play_change(false)
		return
	_show(fmod(_warn_elapsed * WARN_BLINK_HZ, 1.0) < 0.5)

func _cancel_warning() -> void:
	_warn_left = 0.0
	_warn_elapsed = 0.0
	set_physics_process(false)
	if out:
		_show(true)

func _set_out(on: bool) -> void:
	out = on
	_show(on)
	_apply_state(on)

## Draws the layer at full strength, or (not `full`) as the ghost with `show_ghost` and not at all without it.
func _show(full: bool) -> void:
	if full:
		visible = true
		modulate.a = _base_alpha
	elif show_ghost:
		visible = true
		modulate.a = _base_alpha * ghost_opacity
	else:
		visible = false
		modulate.a = _base_alpha

func _play_change(extended: bool) -> void:
	var id := _sound_id(extended)
	if id == &"":
		return
	var at := _sound_position()
	if at != Vector2.INF:
		Audio.play_at(id, at)

## The middle of the painted cells in world space, or Vector2.INF with nothing painted.
func _sound_position() -> Vector2:
	var used := get_used_rect()
	if used.size == Vector2i.ZERO:
		return Vector2.INF
	return to_global(map_to_local(used.position + used.size / 2))

## Copies `sources` onto the `PowerTarget` child (a copy, so a conductor's `add_source()` never writes the export).
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
		warnings.append("Add a PowerTarget child: without one nothing can switch these %s." % _noun())
	elif sources.is_empty() and target.sources.is_empty():
		warnings.append("No sources: pick the power source(s) in `sources`. (Fine only if a conductor wire ends at the PowerTarget; unwired, the %s stay out.)" % _noun())
	warnings.append_array(_extra_warnings())
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()
