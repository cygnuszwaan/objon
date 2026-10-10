@tool
extends EditorScript
## Generates a random open 2D world (floating islands, caves, tunnels) into a TileMapLayer.
##
## HOW TO USE
##   1. Open the level scene and select the ground TileMapLayer in the Scene dock
##      (if nothing is selected, the layer in group "world_tilemap" is used).
##   2. Open the TileMap bottom panel > Terrains tab and click the terrain you want
##      (the script reads that selection; see TERRAIN_SET / TERRAIN to override it).
##   3. Open this script in the Script editor and use File > Run (Ctrl+Shift+X).
##   Ctrl+Z undoes the whole generation (tiles and the player move) in one step.
##
## The world is shaped by layered noise: a stretched noise field makes wide
## floating masses, a horizontal banding term stacks them into layers, a bias
## makes the bottom dense and the top sparse, and "ridged" noise carves winding
## tunnels. Smoothing and cleanup turn that into islands and caves. Nothing is
## guaranteed to be traversable; the feature sizes are tuned around the player's
## jump (about 2 tiles up, 5 across) as a guideline only.
##
## Tuning: edit the constants below. Set SEED to a non-zero number to reproduce a
## world; the seed of every run is printed to the Output panel.

# ---- Terrain -----------------------------------------------------------------
## true = use every terrain in the TileSet's Terrains list, in random patches
## (e.g. both materials of merged.tres). false = use one terrain only.
const USE_ALL_TERRAINS := true
const PATCH_SIZE := 45.0        # typical width of a patch of one terrain (tiles)
const PATCH_WARP := 14.0        # how far patch borders wobble (tiles; 0 = straight cells)
## Single-terrain mode (USE_ALL_TERRAINS = false) only:
## -1 = use the terrain selected in the TileMap editor's Terrains tab.
## Set both to fixed ids (e.g. 0 and 0) to always use that terrain instead.
const TERRAIN_SET := -1
const TERRAIN := -1
## Used when TERRAIN_SET/TERRAIN are -1 and no selection could be read.
const FALLBACK_TERRAIN_SET := 0
const FALLBACK_TERRAIN := 0

# ---- World -------------------------------------------------------------------
const SEED := 0                 # 0 = new random world every run
const ORIGIN := Vector2i(0, 0)  # top-left cell of the world
const WIDTH := 160              # tiles
const HEIGHT := 60              # tiles (the level's kill plane is at row 64)
const BORDER := 2               # thickness of the wall on the sides and the floor
const CLOSED_TOP := false       # also wall off the top edge

# ---- Shape: floating masses --------------------------------------------------
const SIZE_X := 14.0            # typical horizontal size of a mass (tiles)
const SIZE_Y := 6.0             # typical vertical size (smaller = flatter islands)
const THRESHOLD := 0.1          # higher = less solid overall
const LAYER_PERIOD := 13.0      # rows between stacked layers of islands
const LAYER_STRENGTH := 0.4     # 0 = no banding, higher = clearer layers
const TOP_BIAS := -0.05         # density added at the top (negative = sparse sky)
const BOTTOM_BIAS := 0.4        # density added at the bottom (positive = solid ground)

# ---- Shape: tunnels and caves ------------------------------------------------
const TUNNEL_SIZE_X := 22.0
const TUNNEL_SIZE_Y := 14.0
const TUNNEL_WIDTH := 0.10      # 0 = no tunnels; larger = wider and more of them

# ---- Cleanup -----------------------------------------------------------------
const SMOOTH_PASSES := 2        # blob smoothing; 0 keeps the raw noise
const MIN_ISLAND := 14          # loose solid pieces smaller than this are removed
const MIN_POCKET := 8           # sealed-off air pockets smaller than this are filled
const SLOPE_CHANCE := 0.6       # chance a possible ramp is built (0 = no slopes at all)
const MAX_RAMP_RISE := 6        # tallest ramp, in tiles of height (a taller wall keeps its top)
const RAMP_2X1_CHANCE := 0.5    # share of ramps that are gentle 2-wide-per-tile-of-rise slopes
								# (the rest are 45 degree 1x1 slopes)
const MAX_RAMP_CARVE := 2       # rows of existing ground a ramp may shave off to fit

# ---- Slope tiles (the standard scheme shared by all tilesets) ----------------
## Atlas coordinates of the floor slope tiles, in each terrain's own atlas source.
## "r" rises to the right, "l" to the left; "1" is the 45 degree tile, "2" the pair
## making a 2x1 slope (lo = the low half, hi = the high half). A ramp is built from
## these on top of a solid wedge that the generator fills in beneath it.
const SLOPE_TILES := {
	"r1": Vector2i(0, 7), "l1": Vector2i(1, 7),
	"r2_lo": Vector2i(2, 7), "r2_hi": Vector2i(3, 7),
	"l2_hi": Vector2i(4, 7), "l2_lo": Vector2i(5, 7),
}
## Autotiling treats a slope cell, and a cell of another terrain, as empty, so ground
## beside or under one gets trimmed edges. After everything is placed, a sweep picks
## the right tile again for just those cells, counting slopes and other terrains as
## filled. true = every one of the eight neighbours must really be filled to count
## as enclosed; false = a diagonal gap between filled sides is ignored (so the air
## above a previous 2x1 step doesn't leave a notch).
const INTERIOR_NEEDS_CORNERS := false

# ---- Extras ------------------------------------------------------------------
const CLEAR_EXISTING := true    # wipe the layer first (false = merge into it)
const MOVE_PLAYER_TO_START := true  # move the scene's "Player" node to a start spot


func _run() -> void:
	var layer := _find_layer()
	if layer == null:
		push_error("Random level: select a TileMapLayer (the ground layer) first.")
		return
	var tile_set := layer.tile_set
	if tile_set == null or tile_set.get_terrain_sets_count() == 0:
		push_error("Random level: '%s' has no TileSet with terrains." % layer.name)
		return

	var terrains: Array[Dictionary] = []
	if USE_ALL_TERRAINS:
		terrains = _all_terrains(tile_set)
	else:
		var picked := _pick_terrain(tile_set)
		if picked.x >= 0:
			var info := _terrain_info(tile_set, picked.x, picked.y)
			if not info.is_empty():
				terrains.append(info)
	if terrains.is_empty():
		push_error("Random level: no usable terrain (a terrain needs tiles in an atlas source).")
		return
	var slopes_available := true
	for t in terrains:
		slopes_available = slopes_available and t["has_slopes"]

	var seed_used := SEED if SEED != 0 else (randi() % 999999 + 1)
	var cfg := {
		"origin": ORIGIN, "width": WIDTH, "height": HEIGHT, "border": BORDER,
		"closed_top": CLOSED_TOP, "size_x": SIZE_X, "size_y": SIZE_Y,
		"threshold": THRESHOLD, "layer_period": LAYER_PERIOD,
		"layer_strength": LAYER_STRENGTH, "top_bias": TOP_BIAS, "bottom_bias": BOTTOM_BIAS,
		"tunnel_size_x": TUNNEL_SIZE_X, "tunnel_size_y": TUNNEL_SIZE_Y,
		"tunnel_width": TUNNEL_WIDTH, "smooth_passes": SMOOTH_PASSES,
		"min_island": MIN_ISLAND, "min_pocket": MIN_POCKET, "slope_chance": SLOPE_CHANCE,
		"max_ramp_rise": MAX_RAMP_RISE, "max_ramp_carve": MAX_RAMP_CARVE, "ramp_2x1_chance": RAMP_2X1_CHANCE,
		"slopes": slopes_available, "terrain_count": terrains.size(),
		"patch_size": PATCH_SIZE, "patch_warp": PATCH_WARP,
	}
	var result := WorldGen.new().generate(cfg, seed_used)

	var old_data := layer.tile_map_data
	if CLEAR_EXISTING:
		layer.clear()
	var solid_cells: Array[Vector2i] = []
	solid_cells.assign(result["solid"])
	var patch: Dictionary = result["patch"]   # cell -> index into `terrains`
	var groups: Array = []
	for t in terrains:
		groups.append([] as Array[Vector2i])
	for cell in solid_cells:
		groups[patch[cell]].append(cell)
	for i in terrains.size():
		var cells: Array[Vector2i] = groups[i]
		if not cells.is_empty():
			layer.set_cells_terrain_connect(cells, terrains[i]["set"], terrains[i]["terrain"])

	# A slope takes the terrain (and atlas) of the ground it stands on.
	for sl: Dictionary in result["slopes"]:
		var below: Vector2i = sl["cell"] + Vector2i(0, 1)
		patch[sl["cell"]] = patch[below]
		var info: Dictionary = terrains[patch[below]]
		layer.set_cell(sl["cell"], info["source"], SLOPE_TILES[sl["kind"]])
	var fixed := _fix_edge_tiles(layer, terrains, patch, solid_cells, result["slopes"])
	var new_data := layer.tile_map_data
	layer.tile_map_data = old_data  # the undo/redo action below applies the new data

	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Generate random level", UndoRedo.MERGE_DISABLE, layer)
	ur.add_do_property(layer, "tile_map_data", new_data)
	ur.add_undo_property(layer, "tile_map_data", old_data)
	var player := _find_player()
	if MOVE_PLAYER_TO_START and player != null and result["start"] != null:
		var new_pos := layer.to_global(layer.map_to_local(result["start"]))
		ur.add_do_property(player, "global_position", new_pos)
		ur.add_undo_property(player, "global_position", player.global_position)
	ur.commit_action()

	var names: Array[String] = []
	for i in terrains.size():
		names.append("%s: %d" % [terrains[i]["name"], groups[i].size()])
	print("Random level: seed %d, %d tiles (%s), %d slope tiles, %d edge fixes. Layer '%s'." % [
		seed_used, solid_cells.size(), ", ".join(names), result["slopes"].size(), fixed, layer.name])
	if SLOPE_CHANCE > 0.0 and not slopes_available:
		print("Random level: a terrain's atlas lacks the standard slope tiles, so no ramps were built.")
	if result["start"] == null:
		print("Random level: no flat spot found for the player; the player was not moved.")


# ---- Editor lookups ----------------------------------------------------------

func _find_layer() -> TileMapLayer:
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is TileMapLayer:
			return n
	var root := EditorInterface.get_edited_scene_root()
	if root:
		for n in root.find_children("*", "TileMapLayer", true, true):
			if n.is_in_group("world_tilemap"):
				return n
	return null


func _find_player() -> Node2D:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var p := root.find_child("Player", true, true)
	return p as Node2D


## Returns Vector2i(terrain_set, terrain), or (-1, -1) after pushing an error.
func _pick_terrain(tile_set: TileSet) -> Vector2i:
	var ts := TERRAIN_SET
	var t := TERRAIN
	if ts < 0 or t < 0:
		var sel := _read_editor_terrain()
		if sel.x >= 0:
			ts = sel.x
			t = sel.y
		else:
			ts = FALLBACK_TERRAIN_SET
			t = FALLBACK_TERRAIN
			print("Random level: couldn't read a selected terrain (click one in the TileMap > Terrains tab); using set %d terrain %d." % [ts, t])
	if ts >= tile_set.get_terrain_sets_count() or t >= tile_set.get_terrains_count(ts):
		push_error("Random level: terrain set %d / terrain %d doesn't exist in this TileSet." % [ts, t])
		return Vector2i(-1, -1)
	return Vector2i(ts, t)


## The TileMap editor's terrain list is an internal Tree whose items carry
## {terrain_set, terrain_id} metadata; find the selected one.
func _read_editor_terrain() -> Vector2i:
	var base := EditorInterface.get_base_control()
	for node in base.find_children("*", "Tree", true, false):
		var item := (node as Tree).get_selected()
		if item == null:
			continue
		var md: Variant = item.get_metadata(0)
		if md is Dictionary and md.has("terrain_set") and md.has("terrain_id"):
			var ts := int(md["terrain_set"])
			var t := int(md["terrain_id"])
			if ts >= 0 and t >= 0:
				return Vector2i(ts, t)
	return Vector2i(-1, -1)


## Every terrain in the TileSet's list that has tiles in an atlas source.
static func _all_terrains(tile_set: TileSet) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ts in tile_set.get_terrain_sets_count():
		for t in tile_set.get_terrains_count(ts):
			var info := _terrain_info(tile_set, ts, t)
			if not info.is_empty():
				out.append(info)
	return out


const _PEER_BITS := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
]
## Offsets matching _PEER_BITS, in the same order.
const _PEER_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]


## Describes one terrain: its atlas source, whether that atlas has the standard slope
## tiles, and every tile of the terrain with its eight peering bits (for re-picking
## tiles). Empty if the terrain has no tiles.
static func _terrain_info(tile_set: TileSet, terrain_set: int, terrain: int) -> Dictionary:
	for i in tile_set.get_source_count():
		var sid := tile_set.get_source_id(i)
		var src := tile_set.get_source(sid) as TileSetAtlasSource
		if src == null:
			continue
		var tiles: Array[Dictionary] = []
		for ti in src.get_tiles_count():
			var coords := src.get_tile_id(ti)
			var td := src.get_tile_data(coords, 0)
			if td.terrain_set == terrain_set and td.terrain == terrain:
				var bits: Array[int] = []
				for b in _PEER_BITS:
					bits.append(td.get_terrain_peering_bit(b))
				tiles.append({"coords": coords, "bits": bits})
		if tiles.is_empty():
			continue
		var slopes_ok := true
		for co: Vector2i in SLOPE_TILES.values():
			slopes_ok = slopes_ok and src.has_tile(co)
		return {
			"set": terrain_set, "terrain": terrain, "source": sid, "tiles": tiles,
			"has_slopes": slopes_ok,
			"name": tile_set.get_terrain_name(terrain_set, terrain),
		}
	return {}


## Sweep after everything is placed. Autotiling counts slope cells and cells of other
## terrains as empty, so ground touching them gets trimmed edges. For exactly those
## cells, pick the tile again with slopes and every terrain counted as filled, from
## the cell's own terrain, and overwrite it if that tile differs. Returns the count.
static func _fix_edge_tiles(layer: TileMapLayer, terrains: Array[Dictionary], patch: Dictionary,
		solid_cells: Array[Vector2i], slopes: Array) -> int:
	var solid := {}
	for cell in solid_cells:
		solid[cell] = true
	var slope_cells := {}
	for sl: Dictionary in slopes:
		slope_cells[sl["cell"]] = true
	var checked := {}
	var changed := 0
	for cell: Vector2i in solid_cells:
		# Only cells touching a slope or another terrain are re-picked.
		var touches := false
		for d in _PEER_OFFSETS:
			var n: Vector2i = cell + d
			if slope_cells.has(n) or (solid.has(n) and patch[n] != patch[cell]):
				touches = true
				break
		if not touches:
			continue
		var info: Dictionary = terrains[patch[cell]]
		# Desired peering bits: this terrain where filled, -1 (empty) elsewhere.
		var filled: Array[bool] = []
		for d in _PEER_OFFSETS:
			var n: Vector2i = cell + d
			filled.append(solid.has(n) or slope_cells.has(n))
		if not INTERIOR_NEEDS_CORNERS:
			for k in [1, 3, 5, 7]:   # corners: filled if both adjacent sides are
				if filled[(k + 7) % 8] and filled[(k + 1) % 8]:
					filled[k] = true
		var best: Vector2i = layer.get_cell_atlas_coords(cell)
		var best_cost := 1 << 30
		for t: Dictionary in info["tiles"]:
			var cost := 0
			for k in 8:
				var want: int = info["terrain"] if filled[k] else -1
				if t["bits"][k] != want:
					cost += 4 if k % 2 == 0 else 1   # a side matters more than a corner
			if cost < best_cost:
				best_cost = cost
				best = t["coords"]
		if layer.get_cell_atlas_coords(cell) != best or layer.get_cell_source_id(cell) != info["source"]:
			layer.set_cell(cell, info["source"], best)
			changed += 1
	return changed


# ---- Generator (pure logic, no editor access) --------------------------------
# Rows grow downward. Cells are addressed in world coordinates (origin + x, y).

class WorldGen extends RefCounted:
	var rng := RandomNumberGenerator.new()
	var c: Dictionary
	var w := 0
	var h := 0
	var grid := PackedByteArray()   # 1 = solid, local coordinates
	var slopes: Array[Dictionary] = []  # {cell (world), kind}
	var reserved := {}              # local cells holding a slope tile (empty in `grid`)

	func generate(cfg: Dictionary, seed_value: int) -> Dictionary:
		c = cfg
		w = c["width"]
		h = c["height"]
		rng.seed = seed_value
		_fill_from_noise()
		for i in int(c["smooth_passes"]):
			_smooth()
		_apply_border()
		_remove_small_solids()
		_fill_small_pockets()
		_apply_border()
		_build_ramps()
		var origin: Vector2i = c["origin"]
		var solid: Array[Vector2i] = []
		for y in h:
			for x in w:
				if grid[y * w + x] == 1:
					solid.append(origin + Vector2i(x, y))
		var start = _pick_start()
		return {"solid": solid, "slopes": slopes, "start": start, "patch": _patches(solid)}

	# Assigns each solid cell to one of `terrain_count` terrains in random patches:
	# cellular noise gives each cell of the diagram a random value, wobbled by domain
	# warp so the borders aren't straight. Returns {cell: terrain index}.
	func _patches(solid: Array[Vector2i]) -> Dictionary:
		var out := {}
		var n := int(c["terrain_count"])
		if n <= 1:
			for cell in solid:
				out[cell] = 0
			return out
		var noise := FastNoiseLite.new()
		noise.seed = rng.randi()
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
		noise.frequency = 1.0 / float(c["patch_size"])
		if c["patch_warp"] > 0.0:
			noise.domain_warp_enabled = true
			noise.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
			noise.domain_warp_amplitude = c["patch_warp"]
			noise.domain_warp_frequency = 2.0 / float(c["patch_size"])
		for cell in solid:
			var v := noise.get_noise_2d(cell.x, cell.y)
			out[cell] = clampi(int((v * 0.5 + 0.5) * n), 0, n - 1)
		# Absorb stray cells whose neighbours are almost all another terrain.
		for pass_i in 2:
			var snapshot := out.duplicate()
			for cell: Vector2i in solid:
				var counts := PackedInt32Array()
				counts.resize(n)
				var total := 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nb := cell + Vector2i(dx, dy)
						if (dx != 0 or dy != 0) and snapshot.has(nb):
							counts[snapshot[nb]] += 1
							total += 1
				var own: int = snapshot[cell]
				if total >= 3 and counts[own] <= 1:
					var best := own
					for i in n:
						if counts[i] > counts[best]:
							best = i
					out[cell] = best
		return out

	func _solid(x: int, y: int) -> bool:
		if x < 0 or x >= w or y >= h:
			return true
		if y < 0:
			return c["closed_top"]
		return grid[y * w + x] == 1

	func _noise(freq_seed: int, octaves: int) -> FastNoiseLite:
		var n := FastNoiseLite.new()
		n.seed = freq_seed
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
		return n

	func _fill_from_noise() -> void:
		var mass := _noise(rng.randi(), 3)
		var tunnels := _noise(rng.randi(), 2)
		var phase := rng.randf() * TAU
		var ox := rng.randf() * 1000.0
		var oy := rng.randf() * 1000.0
		grid.resize(w * h)
		for y in h:
			var t := smoothstep(0.0, 1.0, float(y) / float(h - 1))
			var base: float = lerpf(c["top_bias"], c["bottom_bias"], t)
			base += c["layer_strength"] * cos(TAU * float(y) / c["layer_period"] + phase)
			for x in w:
				var d: float = mass.get_noise_2d(ox + x / c["size_x"], oy + y / c["size_y"]) + base
				var solid: bool = d > c["threshold"]
				if solid and c["tunnel_width"] > 0.0:
					var tn := tunnels.get_noise_2d(ox + x / c["tunnel_size_x"], oy + y / c["tunnel_size_y"])
					if absf(tn) < c["tunnel_width"]:
						solid = false
				grid[y * w + x] = 1 if solid else 0

	func _neighbors(x: int, y: int) -> int:
		var n := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if (dx != 0 or dy != 0) and _solid(x + dx, y + dy):
					n += 1
		return n

	# Blob smoothing: crowded cells fill in, lonely cells clear.
	func _smooth() -> void:
		var out := grid.duplicate()
		for y in h:
			for x in w:
				var n := _neighbors(x, y)
				if n >= 5:
					out[y * w + x] = 1
				elif n <= 3:
					out[y * w + x] = 0
		grid = out

	func _apply_border() -> void:
		var b: int = c["border"]
		for y in h:
			for x in w:
				if x < b or x >= w - b or y >= h - b or (c["closed_top"] and y < b):
					grid[y * w + x] = 1

	# Connected region (4-neighbour) of cells whose value is `value`, from `start`.
	func _region(start: int, value: int, seen: PackedByteArray) -> PackedInt32Array:
		var out := PackedInt32Array()
		var stack := PackedInt32Array([start])
		seen[start] = 1
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			out.append(i)
			var x := i % w
			var y := i / w
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx < 0 or nx >= w or ny < 0 or ny >= h:
					continue
				var ni := ny * w + nx
				if seen[ni] == 0 and grid[ni] == value:
					seen[ni] = 1
					stack.append(ni)
		return out

	func _remove_small_solids() -> void:
		var seen := PackedByteArray()
		seen.resize(w * h)
		for i in w * h:
			if seen[i] == 0 and grid[i] == 1:
				var region := _region(i, 1, seen)
				if region.size() < c["min_island"]:
					for j in region:
						grid[j] = 0

	# Air regions that touch the top row or are large stay; small sealed ones fill.
	func _fill_small_pockets() -> void:
		var seen := PackedByteArray()
		seen.resize(w * h)
		for i in w * h:
			if seen[i] == 0 and grid[i] == 0:
				var region := _region(i, 0, seen)
				if region.size() < c["min_pocket"]:
					for j in region:
						grid[j] = 1

	# True for an empty cell that no ramp has claimed yet.
	func _free(x: int, y: int) -> bool:
		return x >= 0 and x < w and y >= 0 and y < h \
				and grid[y * w + x] == 0 and not reserved.has(Vector2i(x, y))

	# Builds ramps up from flat floor to higher ground. From each floor cell it looks
	# for the longest ramp (up to max_ramp_rise tiles of height) that ends at higher
	# ground, so a single wall or a whole staircase of steps becomes one slope. 1x1
	# ramps climb one tile per column (45 degrees), 2x1 ramps one tile per two columns.
	# The ramp is a row of slope tiles on a solid wedge: air under the diagonal is
	# filled, and up to max_ramp_carve rows of ground sticking up above it are shaved off.
	func _build_ramps() -> void:
		if not c["slopes"] or c["slope_chance"] <= 0.0:
			return
		var max_rise: int = c["max_ramp_rise"]
		for y in range(max_rise + 2, h - 1):
			for x in range(1, w - 1):
				if not _free(x, y) or not _solid(x, y + 1):
					continue
				for dir in [1, -1]:   # 1: ramp climbs to the right ("/"), -1: to the left
					var prefer_2x1: bool = rng.randf() < c["ramp_2x1_chance"]
					var found := false
					var found_rise := 0
					var found_2x1 := false
					for rise in range(max_rise, 0, -1):
						for two in [prefer_2x1, not prefer_2x1]:
							if _ramp(x, y, dir, rise, two, false):
								found = true
								found_rise = rise
								found_2x1 = two
								break
						if found:
							break
					if found and rng.randf() < c["slope_chance"]:
						_ramp(x, y, dir, found_rise, found_2x1, true)

	# Checks (and with `apply` builds) a ramp that starts beside floor cell (x, y), whose
	# floor row is y + 1, and climbs `rise` tiles in direction `dir`.
	func _ramp(x: int, y: int, dir: int, rise: int, two: bool, apply: bool) -> bool:
		var per_step := 2 if two else 1
		var cols := rise * per_step
		var first := x + 1 if dir == 1 else x - cols
		var top0 := y - rise - 1
		var plateau_x := x + dir * (cols + 1)
		if plateau_x < 0 or plateau_x >= w or not _solid(plateau_x, y - rise + 1) \
				or reserved.has(Vector2i(plateau_x, y - rise + 1)):
			return false
		var plan := []   # per column: [column, slope row, current surface row]
		for i in cols:
			var cx := first + i
			if cx < 1 or cx >= w - 1 or top0 < 0 or not _free(cx, top0):
				return false
			var step := i / per_step
			var row := y - step if dir == 1 else y - (rise - 1) + step
			var surface := top0
			while surface <= y + 1 and _free(cx, surface):
				surface += 1
			if surface > y + 1 or reserved.has(Vector2i(cx, surface)):
				return false
			for k in range(surface, y + 2):
				if not _solid(cx, k):
					return false
			if row + 1 - surface > c["max_ramp_carve"]:
				return false
			plan.append([cx, row, surface])
		if not apply:
			return true
		var origin: Vector2i = c["origin"]
		for i in cols:
			var cx: int = plan[i][0]
			var row: int = plan[i][1]
			var surface: int = plan[i][2]
			for ry in range(surface, row + 1):
				grid[ry * w + cx] = 0
			for fy in range(row + 1, y + 1):
				grid[fy * w + cx] = 1
			var kind: String
			if two:
				var low: bool = (i % 2 == 0) == (dir == 1)
				kind = ("r2_lo" if low else "r2_hi") if dir == 1 else ("l2_lo" if low else "l2_hi")
			else:
				kind = "r1" if dir == 1 else "l1"
			reserved[Vector2i(cx, row)] = true
			slopes.append({"cell": origin + Vector2i(cx, row), "kind": kind})
		return true

	# A standing spot with a flat floor and headroom, preferring the left third.
	func _pick_start() -> Variant:
		var best: Array[Vector2i] = []
		var any: Array[Vector2i] = []
		for y in range(4, h - 1):
			for x in range(3, w - 3):
				var ok := true
				for dx in range(-2, 3):
					if _solid(x + dx, y) or not _solid(x + dx, y + 1) or reserved.has(Vector2i(x + dx, y)):
						ok = false
						break
				for dy in range(1, 5):
					if _solid(x, y - dy):
						ok = false
						break
				if not ok:
					continue
				any.append(Vector2i(x, y))
				if x < w / 3:
					best.append(Vector2i(x, y))
		var pool := best if not best.is_empty() else any
		if pool.is_empty():
			return null
		var p: Vector2i = pool[rng.randi_range(0, pool.size() - 1)]
		return (c["origin"] as Vector2i) + p + Vector2i(0, -1)
