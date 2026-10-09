@tool
class_name ConductorLayer
extends TileMapLayer
## One colour layer of visual "wiring". Purely cosmetic tiles that also carry the wiring GRAPH: at load
## this layer flood-fills its own painted cells into circuits, attaches buttons and power targets to
## them, and swaps the tiles between lit and dim as buttons change. No physics, no collision.
##
## Atlas (res://sprites/conductors/conductors_atlas.png, 15 columns x 8 rows of 16px): rows 0-3 are lit
## (red, yellow, green, blue), rows 4-7 dim; lit/dim is `atlas_coords.y` +/- 4. The COLUMN is the piece
## and is turned into an edge mask by WIRE_MASK below (no TileSet custom data). Colour is art only: a
## level may hold any number of circuits, several of one colour included, and the four colour layers
## never connect to each other, so differently coloured wires can cross in one cell.
##
## Circuits: within this layer, two neighbouring cells connect when BOTH have an open edge facing each
## other. A circuit is a Circuit node (child of this layer at runtime) that answers the power-source
## contract from power_target.gd: `powered_changed(on)` and `is_powered()`. It is lit while any button
## attached to it is active.
##
## Loose ends are the terminals: any open edge that does not meet a matching open edge in the
## neighbouring cell is a wire END, and a device sitting in the cell beyond that edge is attached to the
## circuit. No dedicated terminal tile exists: a straight, corner or T piece can end a wire next to its
## device. Devices attach through the edge, not the colour:
##   - A Button (group "power_source") in that cell is attached as a source: it lights the circuit.
##   - A PowerTarget (group "power_target") in that cell is attached as a target: the circuit becomes
##     one of its sources through PowerTarget.add_source(), so `invert` / `all_required` still apply.
## A device may be reached from several loose ends (of one circuit or of different ones): a button then
## lights every circuit that touches it, and a target has each of them as a source. A wire passing beside
## a device without an open edge facing it attaches nothing. Atlas columns 0-3 (the old terminal stubs)
## are unused; a painted one is ignored with a warning.
## A device's cell is the cell its node origin is in, so a PowerTarget belongs at the centre of the tile
## it serves (Buttons already sit at their tile's centre). Devices in a different open scene are ignored.
##
## Built once, deferred from _ready() so every button and target has already joined its group: the tiles
## aren't expected to change at runtime.
##
## Editor overlay (`debug_draw`): decodes the painted cells through the SAME tables the runtime uses, so
## it shows what the code thinks the art is: a line from each cell centre to every open edge, coloured
## per circuit, with a label per circuit. Every loose end gets a dot on its open edge (green = a device is attached, red = none,
## so a wire that stops short of its device, or butts against a piece that doesn't open back, shows red).
## Ignored legacy terminal tiles get an orange cross. If the lines don't follow the drawn wire, the column
## table is wrong for the art.
##
## Place the layers immediately after the Ground layer in the tree (same z_index as Ground) so they draw
## above the ground tiles and below every actor that comes later, and give the parent the same position
## as Ground, so cells line up with the ground grid.

@export var debug_draw: bool = true:
	set(value):
		debug_draw = value
		if _overlay != null:
			_overlay.visible = value
			_overlay.queue_redraw()

const N := 1
const E := 2
const S := 4
const W := 8
const DIRS: Array[int] = [N, E, S, W]
const OFFSETS := {N: Vector2i(0, -1), E: Vector2i(1, 0), S: Vector2i(0, 1), W: Vector2i(-1, 0)}
const OPPOSITE := {N: S, E: W, S: N, W: E}

## Open wire edges per atlas column. Columns 0-3 are the retired terminal stubs (mask 0 = not part of any
## circuit). 4 corner W-S, 5 straight N-S, 6 corner E-S, 7 corner N-W, 8 straight E-W, 9 corner N-E,
## 10 T (N,S,W), 11 T (E,S,W), 12 T (N,S,E), 13 T (N,E,W), 14 four-way.
const WIRE_MASK: PackedInt32Array = [
	0, 0, 0, 0,
	W | S, N | S, E | S, N | W, E | W, N | E,
	N | S | W, E | S | W, N | S | E, N | E | W,
	N | E | S | W,
]
const DIM_ROW_OFFSET := 4

var circuits: Array[Circuit] = []

var _masks: Dictionary = {}         # Vector2i cell -> open-edge mask
var _cell_circuit: Dictionary = {}  # Vector2i cell -> Circuit
var _ends: Array[Dictionary] = []   # loose wire ends: {cell, side, attached} (attached = device count)
var _ignored: Array[Vector2i] = []  # painted cells that are not wire pieces (retired terminal tiles)
var _pending_targets: Array = []    # [PowerTarget, Circuit] pairs, attached once every circuit has read its buttons
var _overlay: Node2D
var _signature: int = 0


## A wired-together set of cells. Acts as a power source for the PowerTargets it touches.
class Circuit extends Node:
	signal powered_changed(on: bool)

	var cells: Array[Vector2i] = []
	var sources: Array[Node] = []  # buttons attached at terminals
	var targets: Array[Node] = []  # PowerTargets attached at terminals
	var lit: bool = false

	## Power-source contract (PowerTarget reads this).
	func is_powered() -> bool:
		return lit

	func add_source(source: Node) -> void:
		if sources.has(source):
			return
		sources.append(source)
		if source.has_signal("powered_changed"):
			source.powered_changed.connect(_on_source_changed)

	## Re-read every attached source; emits and returns true if the lit state changed.
	func refresh() -> bool:
		var on := false
		for source in sources:
			if is_instance_valid(source) and source.has_method("is_powered") and source.is_powered():
				on = true
				break
		if on == lit:
			return false
		lit = on
		powered_changed.emit(on)
		return true

	func _on_source_changed(_on: bool) -> void:
		refresh()


func _ready() -> void:
	if Engine.is_editor_hint():
		var stale := get_node_or_null("ConductorOverlay")  # left over from before a script reload
		if stale != null:
			stale.free()
		_overlay = Node2D.new()  # no owner, so it is never saved into the scene
		_overlay.name = "ConductorOverlay"
		_overlay.z_index = 100
		_overlay.visible = debug_draw
		_overlay.draw.connect(_draw_overlay)
		add_child(_overlay)
		set_process(true)
		return
	set_process(false)
	call_deferred("_build_runtime")

# --- runtime -------------------------------------------------------------------------------------

func _build_runtime() -> void:
	_scan(_gather_devices(), true)
	for circuit in circuits:
		circuit.refresh()  # a button already active at load lights its circuit straight away
		circuit.powered_changed.connect(_on_circuit_changed.bind(circuit))
		_paint(circuit)
	# Targets attach last, so their first apply already sees the circuit's true state (a door starts
	# open rather than opening on the first frame).
	for pair in _pending_targets:
		if is_instance_valid(pair[0]):
			pair[0].add_source(pair[1])
	_pending_targets.clear()

func _on_circuit_changed(_on: bool, circuit: Circuit) -> void:
	_paint(circuit)

## Swap every cell of the circuit to its lit or dim row, keeping the colour row and column.
func _paint(circuit: Circuit) -> void:
	for cell in circuit.cells:
		var coords := get_cell_atlas_coords(cell)
		var want := Vector2i(coords.x, (coords.y % DIM_ROW_OFFSET) + (0 if circuit.lit else DIM_ROW_OFFSET))
		if want != coords:
			set_cell(cell, get_cell_source_id(cell), want, get_cell_alternative_tile(cell))

# --- graph ---------------------------------------------------------------------------------------

## cell -> Array of button / power-target nodes whose origin lies in that cell.
func _gather_devices() -> Dictionary:
	var found: Dictionary = {}
	var mine := _scene_top(self)
	for group in [&"power_source", &"power_target"]:
		for node in get_tree().get_nodes_in_group(group):
			var device := node as Node2D
			if device == null or _scene_top(device) != mine:
				continue
			var cell := local_to_map(to_local(device.global_position))
			if not found.has(cell):
				found[cell] = []
			found[cell].append(device)
	return found

## Topmost ancestor below the viewport: identifies which open scene a node belongs to (in the editor
## every open scene shares the tree).
func _scene_top(node: Node) -> Node:
	var top := node
	while top.get_parent() != null and not top.get_parent() is Viewport:
		top = top.get_parent()
	return top

## Decode the painted cells, flood-fill circuits, and (runtime only) attach devices at terminals.
func _scan(devices: Dictionary, runtime: bool) -> void:
	for old in circuits:
		if is_instance_valid(old):
			if old.is_inside_tree():
				old.queue_free()
			else:
				old.free()
	circuits.clear()
	_masks.clear()
	_cell_circuit.clear()
	_ends.clear()
	_ignored.clear()

	for cell in get_used_cells():
		var column := get_cell_atlas_coords(cell).x
		if column < 0 or column >= WIRE_MASK.size():
			continue
		if WIRE_MASK[column] == 0:
			_ignored.append(cell)
			continue
		_masks[cell] = WIRE_MASK[column]

	var seen: Dictionary = {}
	for start in _masks:
		if seen.has(start):
			continue
		var circuit := Circuit.new()
		var queue: Array[Vector2i] = [start]
		seen[start] = true
		while not queue.is_empty():
			var cell: Vector2i = queue.pop_back()
			circuit.cells.append(cell)
			_cell_circuit[cell] = circuit
			var mask: int = _masks[cell]
			for dir in DIRS:
				if (mask & dir) == 0:
					continue
				var neighbour: Vector2i = cell + OFFSETS[dir]
				if seen.has(neighbour) or not _masks.has(neighbour):
					continue
				if (int(_masks[neighbour]) & int(OPPOSITE[dir])) == 0:
					continue  # both cells must open onto the shared edge
				seen[neighbour] = true
				queue.append(neighbour)
		circuits.append(circuit)
		if runtime:
			add_child(circuit)

	for cell in _masks:
		var circuit: Circuit = _cell_circuit[cell]
		var mask: int = _masks[cell]
		for dir in DIRS:
			if (mask & dir) == 0:
				continue
			var device_cell: Vector2i = cell + OFFSETS[dir]
			if _masks.has(device_cell) and (int(_masks[device_cell]) & int(OPPOSITE[dir])) != 0:
				continue  # meets a matching open edge: an ordinary connection, not a loose end
			var here: Array = devices.get(device_cell, [])
			for device in here:
				if device.is_in_group(&"power_source"):
					if runtime:
						circuit.add_source(device)
					elif not circuit.sources.has(device):
						circuit.sources.append(device)
				elif device.is_in_group(&"power_target"):
					if circuit.targets.has(device):
						continue
					circuit.targets.append(device)
					if runtime:
						_pending_targets.append([device, circuit])
			_ends.append({"cell": cell, "side": dir, "attached": here.size()})
	if runtime and not _ignored.is_empty():
		push_warning("%s: %d retired terminal tile(s) (atlas columns 0-3) ignored, e.g. at cell %s. Repaint them as wire pieces ending at the device." % [name, _ignored.size(), _ignored[0]])

# --- editor overlay ------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	# editor only (see _ready): rebuild the overlay's graph only when the tiles or the devices changed
	var devices := _gather_devices()
	var signature := hash([hash(tile_map_data), devices.keys()])
	if signature == _signature:
		return
	_signature = signature
	_scan(devices, false)
	_overlay.queue_redraw()

func _draw_overlay() -> void:
	var half := float(tile_set.tile_size.x) * 0.5 if tile_set != null else 8.0
	for i in circuits.size():
		var circuit := circuits[i]
		var tint := Color.from_hsv(fposmod(i * 0.61803, 1.0), 0.7, 1.0, 0.9)
		for cell in circuit.cells:
			var center := map_to_local(cell)
			var mask: int = _masks[cell]
			for dir in DIRS:
				if (mask & dir) != 0:
					_overlay.draw_line(center, center + Vector2(OFFSETS[dir]) * half, tint, 1.0)
			_overlay.draw_circle(center, 1.5, tint)
		var label := "#%d  %d src  %d tgt" % [i, circuit.sources.size(), circuit.targets.size()]
		_overlay.draw_string(ThemeDB.fallback_font, map_to_local(circuit.cells[0]) + Vector2(-half, -half),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, tint)
	for end in _ends:
		var edge := map_to_local(end["cell"]) + Vector2(OFFSETS[end["side"]]) * half
		var dot := Color(0.3, 1.0, 0.4) if int(end["attached"]) > 0 else Color(1.0, 0.3, 0.3)
		_overlay.draw_circle(edge, 2.5, dot)
	var orange := Color(1.0, 0.6, 0.1)
	for cell in _ignored:
		var c := map_to_local(cell)
		_overlay.draw_line(c - Vector2(half, half) * 0.6, c + Vector2(half, half) * 0.6, orange, 1.5)
		_overlay.draw_line(c + Vector2(half, -half) * 0.6, c + Vector2(-half, half) * 0.6, orange, 1.5)
