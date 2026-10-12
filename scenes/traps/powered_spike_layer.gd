@tool
class_name PoweredSpikeLayer
extends PoweredTileLayer
## A switchable block of spikes: a `TileMapLayer` of spike tiles (paint them from the ground tileset's spike atlas
## source, exactly as on the `Ground` layer) that is either OUT or RETRACTED as a whole. Powered = out: drawn and
## dangerous. Unpowered = hidden and skipped by the player's hazard poll. The layer has no collision, no
## `surface_type` and no state of its own, so it is never ground-like and a restore needs nothing from it.
##
## The power plumbing (`sources`, `invert`, `set_powered_initial()`, warnings, sound) is in `PoweredTileLayer`. Spikes
## have NO warning phase: extending under a standing player hurts at once (the poll's normal rules: `take_hit()` and
## its i-frames) and retracting spares the player on the same frame, so `warn_time` is hidden here.
##
## POLL: the player asks every layer in group "hazard_layer" through `is_hazard_active()` and, for the active ones,
## the shared `TileHazards.hit_in_rect()` (see Spikes in hazards-traps.md). Enemies and blocks never ask.
##
## SOUND: `traps/spikes_extend` and `traps/spikes_retract` (both in Audio.PLANNED).

const SOUND_EXTEND := &"traps/spikes_extend"
const SOUND_RETRACT := &"traps/spikes_retract"

func _ready() -> void:
	add_to_group(&"hazard_layer")
	collision_enabled = false  # a layer with a ground tileset must never block anything, whatever is painted on it
	super()

## True while the spikes are out; what the player's poll asks before it reads this layer's tiles.
func is_hazard_active() -> bool:
	return out

func _supports_warning() -> bool:
	return false

func _sound_id(extended: bool) -> StringName:
	return SOUND_EXTEND if extended else SOUND_RETRACT

func _noun() -> String:
	return "spikes"

func _extra_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if tile_set == null or tile_set.get_custom_data_layer_by_name(TileHazards.DAMAGE_LAYER) == -1:
		warnings.append("The tile set has no `%s` custom data: nothing painted here can hurt. Use the ground tileset." % TileHazards.DAMAGE_LAYER)
	return warnings
