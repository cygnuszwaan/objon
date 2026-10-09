class_name SurfaceTypes
extends RefCounted
## The one place that says what a tile's `surface_type` custom data means. Every script that asks "is this ground?",
## "can this be grabbed?", "does water or steam step past this?" or "does the laser pass this?" about a world-tilemap tile
## goes through here instead of comparing the string itself, so a new surface type is added in one place. Stateless, never instantiated.
##
## Tile types: "ground" (solid), "glass" (solid and unbreakable like ground, but see-through: ground-like for everything
## except light, which passes it), "catwalk" (one-way platform: liquid, steam and beams step past it, the player hangs from its underside).
## Anything else, or an untagged tile, is none of the above. Non-tile bodies don't carry a surface_type:
## they opt in through the groups "ground" and "catwalk", which callers still test themselves.

const GROUND := "ground"
const GLASS := "glass"
const CATWALK := "catwalk"

## Solid floor and wall for everything that cares about terrain: a basin's floors and walls, and (with the catwalk, see
## is_hangable()) the ledge grab. Glass counts; it differs from ground only for light (laser_passes()).
static func is_ground_like(surface: String) -> bool:
	return surface == GROUND or surface == GLASS

## A one-way tile that liquid and steam fall or rise through, and that the player hangs from by its underside.
static func is_catwalk(surface: String) -> bool:
	return surface == CATWALK

## Whether the ledge grab may latch onto a tile of this type.
static func is_hangable(surface: String) -> bool:
	return is_ground_like(surface) or is_catwalk(surface)

## Whether a laser beam passes through a tile of this type without stopping or reacting: catwalks and glass.
static func laser_passes(surface: String) -> bool:
	return is_catwalk(surface) or surface == GLASS

## The surface_type of the tile at `cell`, or "" for an empty cell.
static func surface_at_cell(tilemap: TileMapLayer, cell: Vector2i) -> String:
	if tilemap == null:
		return ""
	var tile_data := tilemap.get_cell_tile_data(cell)
	if tile_data == null:
		return ""
	var surface: String = tile_data.get_custom_data("surface_type")
	return surface

## The surface_type of the tile containing the world-space `point`, or "".
static func surface_at_point(tilemap: TileMapLayer, point: Vector2) -> String:
	if tilemap == null:
		return ""
	return surface_at_cell(tilemap, tilemap.local_to_map(tilemap.to_local(point)))

## The surface_type of the tile a physics hit landed on. A hit on a tile's right or bottom face lies on the boundary it
## shares with the empty neighbour, and local_to_map()'s floor() would round it into that wrong cell, so the point is
## nudged half a pixel into the tile along the inward normal first.
static func surface_at_hit(tilemap: TileMapLayer, hit_position: Vector2, hit_normal: Vector2) -> String:
	return surface_at_point(tilemap, hit_position - hit_normal * 0.5)
