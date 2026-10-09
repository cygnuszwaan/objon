class_name TileHazards
extends RefCounted
## Static helpers for hazard tiles (spikes): what a tile's `hazard_damage` and `hazard_direction` custom data mean.
## A hazard tile has no collision at all, so nothing is blocked, pushed or ridden; an actor that wants to be hurt
## by one asks `hit_in_rect()` once per physics frame, the polling pattern of Sawwheel and Crusher, so i-frame
## expiry re-hurts it. The player does (`_poll_tile_hazards()`); enemies and blocks never ask, so they ignore it.
##
## TileSet custom data (both layers are in `ground_tileset.tres`; a TileSet without them has no hazards):
##   `hazard_damage`     int, 0 or unset = harmless; the argument of `take_hit()`.
##   `hazard_direction`  Vector2, the way the points face (zero or unset = up). Only its dominant axis counts.
## The spike art is the half of the tile on the side opposite the direction, so that half is the dangerous zone,
## trimmed by SPIKE_SIDE_INSET on the two sides and short of the tips by SPIKE_TIP_MARGIN. Orientation is part of
## the tile (one atlas tile per direction, pre-rotated art), never a flip/transpose flag, so the zone can't
## disagree with what is drawn.

const DAMAGE_LAYER := "hazard_damage"
const DIRECTION_LAYER := "hazard_direction"
const SPIKE_ART_DEPTH := 8.0      ## px of the tile the spike art fills, measured from its base edge
const SPIKE_TIP_MARGIN := 1.0     ## px short of the tips: an actor must reach this far into the art to be hurt
const SPIKE_SIDE_INSET := 1.0     ## px trimmed from each side of the zone

## The most damaging hazard tile overlapping `rect` (world space), or an empty Dictionary:
## {"damage": int, "position": Vector2 (the tile's centre, world)}.
static func hit_in_rect(layer: TileMapLayer, rect: Rect2) -> Dictionary:
	if layer == null or layer.tile_set == null:
		return {}
	var tile_set := layer.tile_set
	if tile_set.get_custom_data_layer_by_name(DAMAGE_LAYER) == -1:
		return {}
	var has_direction := tile_set.get_custom_data_layer_by_name(DIRECTION_LAYER) != -1
	var tile := Vector2(tile_set.tile_size)
	var from := layer.local_to_map(layer.to_local(rect.position))
	var to := layer.local_to_map(layer.to_local(rect.end))
	var best := {}
	for x in range(mini(from.x, to.x), maxi(from.x, to.x) + 1):
		for y in range(mini(from.y, to.y), maxi(from.y, to.y) + 1):
			var cell := Vector2i(x, y)
			var data := layer.get_cell_tile_data(cell)
			if data == null:
				continue
			var damage := int(data.get_custom_data(DAMAGE_LAYER))
			if damage <= 0 or (not best.is_empty() and damage <= int(best["damage"])):
				continue
			var direction := Vector2.UP
			if has_direction:
				var authored: Vector2 = data.get_custom_data(DIRECTION_LAYER)
				if authored != Vector2.ZERO:
					direction = authored
			var centre := layer.to_global(layer.map_to_local(cell))
			if danger_zone(centre, direction, tile).intersects(rect):
				best = {"damage": damage, "position": centre}
	return best

## The dangerous part of a spike tile centred at `centre` (world), points facing `direction`, as a rect.
static func danger_zone(centre: Vector2, direction: Vector2, tile: Vector2) -> Rect2:
	var facing := Vector2(signf(direction.x), 0.0) if absf(direction.x) > absf(direction.y) else Vector2(0.0, signf(direction.y))
	if facing == Vector2.ZERO:
		facing = Vector2.UP
	var depth := SPIKE_ART_DEPTH - SPIKE_TIP_MARGIN
	var half := tile.x * 0.5
	var along := Vector2(absf(facing.x), absf(facing.y))  # (1, 0) for left/right, (0, 1) for up/down
	var size := along * depth + (Vector2.ONE - along) * (tile.x - 2.0 * SPIKE_SIDE_INSET)
	var middle := centre - facing * (half - depth * 0.5)  # the base edge is opposite the points
	return Rect2(middle - size * 0.5, size)
