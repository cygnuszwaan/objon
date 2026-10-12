@tool
class_name PoweredLadderLayer
extends PoweredTileLayer
## A switchable run of ladder tiles: a ladder that appears when powered and is gone when not. Paint ladder tiles on it
## exactly as on the level's `Ladders` layer. A ladder cell is just "a tile is present there" (no collision), and the
## player asks every layer in group "ladder_tilemap".
##
## OUT = visible and in group "ladder_tilemap". RETRACTED = hidden (or a faint ghost with `show_ghost`) and out of the group, so the player no longer sees
## a ladder in those cells. A player climbing it is dropped on the next physics frame by the ordinary "no longer on a
## ladder" rule, with no code here. During the blink the layer is still a ladder.
##
## A bridge of catwalk with a ladder through it takes two layers (one `PoweredCatwalkLayer`, one `PoweredLadderLayer`)
## wired to the same source. Place the layer at the same position as the level's `Ladders` layer so cells line up.
##
## SOUND: `traps/bridge_extend` and `traps/bridge_retract` (in Audio.PLANNED), shared with `PoweredCatwalkLayer`.

const SOUND_EXTEND := &"traps/bridge_extend"
const SOUND_RETRACT := &"traps/bridge_retract"
const GROUP := &"ladder_tilemap"

func _apply_state(on: bool) -> void:
	if Engine.is_editor_hint():
		return
	if on:
		add_to_group(GROUP)
	else:
		remove_from_group(GROUP)

func _sound_id(extended: bool) -> StringName:
	return SOUND_EXTEND if extended else SOUND_RETRACT

func _noun() -> String:
	return "ladders"

func _extra_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if tile_set == null:
		warnings.append("No tile set: use the ladder tile set (res://resources/ladder_tileset.tres).")
	return warnings
