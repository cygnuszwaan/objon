@tool
class_name PoweredSpikeLayer
extends TileMapLayer
## A switchable block of spikes: a `TileMapLayer` of spike tiles (paint them from the ground tileset's spike atlas
## source, exactly as on the `Ground` layer) that is either OUT or RETRACTED as a whole. Powered = out: drawn and
## dangerous. Unpowered = hidden and skipped by the player's hazard poll. The layer has no collision, no
## `surface_type` and no state of its own, so it is never ground-like and a restore needs nothing from it.
##
## POWER: `sources` and `invert` are exported here and forwarded to the `PowerTarget` child (as `CameraCue` does), so
## an instance is wired in its own Inspector without Editable Children; a conductor wire can instead end at the
## `PowerTarget` child (move it to the tile the wire should end at). With no valid source the layer is not driven and
## keeps its authored state, which is OUT, so an unwired layer behaves exactly like spikes painted on the ground.
## `all_required` stays on the `PowerTarget` child. Independent groups of spikes are separate layers.
##
## TRANSITIONS: instant, both ways. Extending into a cell the player stands in hurts at once (the poll's normal
## rules: `take_hit()` and its i-frames); retracting spares the player on the same frame. The startup state goes
## through `set_powered_initial()` (no sound); a checkpoint restore needs no code here: the layer is a pure function
## of its sources, and a source's restore emits `powered_changed` on any change.
##
## POLL: the player asks every layer in group "hazard_layer" through `is_hazard_active()` and, for the active ones,
## the shared `TileHazards.hit_in_rect()` (see Spikes in hazards-traps.md). Enemies and blocks never ask.
##
## SOUND: `traps/spikes_extend` and `traps/spikes_retract` (both in Audio.PLANNED) play at the middle of the painted
## cells when the state actually changes after startup.

## The power sources that drive the layer (any one of them powers it). Forwarded to the `PowerTarget` child when the
## node enters the tree and whenever this list is edited. Left empty, the child's own `sources` (and any conductor
## wire) are used as before.
@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if is_node_ready():
			_forward_sources(true)
			update_configuration_warnings()
## Inverts the power: the spikes are out while the source is off.
@export var invert: bool = false

const SOUND_EXTEND := &"traps/spikes_extend"
const SOUND_RETRACT := &"traps/spikes_retract"

var out: bool = true ## Runtime state: the spikes are out (drawn and dangerous). Authored state is out.

## Runs before the `PowerTarget` child's own `_ready()`, so its first (deferred) recompute already sees the sources.
func _enter_tree() -> void:
	_forward_sources(false)

func _ready() -> void:
	add_to_group(&"hazard_layer")
	collision_enabled = false  # a layer with a ground tileset must never block anything, whatever is painted on it
	if Engine.is_editor_hint():
		return
	_set_out(true)

## True while the spikes are out; what the player's poll asks before it reads this layer's tiles.
func is_hazard_active() -> bool:
	return out

## The startup state: snaps with no sound.
func set_powered_initial(on: bool) -> void:
	_set_out(on)

func set_powered(on: bool) -> void:
	if on == out:
		return
	_set_out(on)
	var at := _sound_position()
	if at != Vector2.INF:
		Audio.play_at(SOUND_EXTEND if on else SOUND_RETRACT, at)

func _set_out(on: bool) -> void:
	out = on
	visible = on

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
		warnings.append("Add a PowerTarget child: without one nothing can switch these spikes.")
	elif sources.is_empty() and target.sources.is_empty():
		warnings.append("No sources: pick the power source(s) in `sources`. (Fine only if a conductor wire ends at the PowerTarget; unwired, the spikes stay out.)")
	if tile_set == null or tile_set.get_custom_data_layer_by_name(TileHazards.DAMAGE_LAYER) == -1:
		warnings.append("The tile set has no `%s` custom data: nothing painted here can hurt. Use the ground tileset." % TileHazards.DAMAGE_LAYER)
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()
