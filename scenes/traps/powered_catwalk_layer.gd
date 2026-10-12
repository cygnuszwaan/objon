@tool
class_name PoweredCatwalkLayer
extends PoweredTileLayer
## A switchable run of catwalk tiles: a bridge that materialises when powered and is gone when not. Paint catwalk
## tiles (a tile with `surface_type` "catwalk": one-way collision) on it exactly as on the level's `Catwalks` layer.
##
## OUT = collision on, visible and in group "catwalk", so every consumer that finds catwalks through a physics hit
## (the hang probes, the laser, the water and steam rays) or through the group (the ladder-landing scan, which reads
## cells rather than collision) treats it as a catwalk. RETRACTED = collision off, hidden (or a faint non-solid ghost with `show_ghost`) and OUT of the group, so none
## of them see it. Nothing here is in "world_tilemap" or "ground": ground tiles can't be switched (see the Powered tile
## layers note in hazards-traps.md).
##
## RETRACT: the layer blinks for `warn_time` (still solid), then retracts. A player standing on it simply falls (the
## collision is gone). A player hanging from its underside, or mid-mantle onto it, would stay pinned in the air (a tile
## hang has no platform to follow), so the layer calls the player's `release_hang_from_layer(self)` as it retracts.
## Extending is harmless to anyone: the tiles are one-way, so a body inside a cell rises through it.
##
## SOUND: `traps/bridge_extend` and `traps/bridge_retract` (in Audio.PLANNED), shared with `PoweredLadderLayer`.

const SOUND_EXTEND := &"traps/bridge_extend"
const SOUND_RETRACT := &"traps/bridge_retract"
const GROUP := &"catwalk"

func _apply_state(on: bool) -> void:
	if Engine.is_editor_hint():
		return
	collision_enabled = on
	if on:
		add_to_group(GROUP)
		return
	remove_from_group(GROUP)
	_release_hanging_player()

## Asks the player to let go if it hangs from one of this layer's tiles. Duck-typed, like every other player contract.
func _release_hanging_player() -> void:
	if not is_inside_tree():
		return
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method(&"release_hang_from_layer"):
		player.call(&"release_hang_from_layer", self)

func _sound_id(extended: bool) -> StringName:
	return SOUND_EXTEND if extended else SOUND_RETRACT

func _noun() -> String:
	return "catwalks"

func _extra_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if tile_set == null or tile_set.get_custom_data_layer_by_name("surface_type") == -1:
		warnings.append("The tile set has no `surface_type` custom data: nothing painted here counts as a catwalk. Use a tile set whose catwalk tiles carry it.")
		return warnings
	for cell in get_used_cells():
		if not SurfaceTypes.is_catwalk(SurfaceTypes.surface_at_cell(self, cell)):
			warnings.append("Cell %s is not a catwalk tile: this layer joins group \"catwalk\" and only catwalk tiles belong in it. Ground and glass can't be switched." % [cell])
			break
	return warnings
