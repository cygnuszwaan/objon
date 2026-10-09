@tool
extends Node2D
## Basin sensor: a power SOURCE (see power_target.gd for the contract) that reads a WaterBasin. Emits
## `powered_changed(on)` and answers `is_powered()`; PowerTargets pick it in their `sources` list and conductor
## wires attach to it by adjacency, like a Button. A faucet filling a basin can open a door, a drain emptying it can
## close one, and a crusted basin is a switch.
##
## Not a physical object: it has no collision, so it can sit anywhere (on a wall, inside a machine) and is wired like
## any source. Set `basin` to the WaterBasin it reads. Origin: the centre of a 16x16 tile (the cell a ConductorLayer
## files it under, like Button). Art is drawn in code (a housing with a level gauge and a lamp) until sprites exist.
##
## Modes (`mode`), each one reading of the basin:
##   FILL    powered at or above `fill_fraction` (0..1) of the basin's capacity, `WaterBasin.get_fill_fraction()`:
##           settled liquid plus crust over the volume the basin holds at its spill point. Releases only below
##           `fill_fraction - fill_hysteresis`.
##   CRUST   powered while the basin has a crust (`has_crust`). A crust never thins or melts, so this only ends with
##           a reload or a restore from before it formed.
##   COLUMN  powered while still liquid lies over one interior column (`column`, counted from the left wall: 0 is the
##           column just inside it), at least `column_depth_tiles` deep. Crust and a void over the column read as
##           no liquid. Releases only below `column_depth_tiles - depth_hysteresis_tiles`.
## `liquid_filter` (ANY, WATER, SLAG) adds a condition to every mode: the basin's liquid must be of that type. It
## reads the basin's RUNTIME `liquid_type` (an empty basin is claimed by whichever liquid arrives first), never the
## authored one. A basin crusted over slag still reads SLAG.
##
## Power: rises the physics frame the reading is met; falls once it has stayed unmet for `hold_time` seconds
## (default 0.15). Hysteresis (FILL, COLUMN) plus that hold is the shared rule for a source read from an analogue
## quantity: a surface rippling around the threshold or particles arriving and leaving can't chatter it. A sensor on
## a basin that its own power drains (a drain faucet it opens) swings between the two thresholds, as slowly as the
## liquid moves, rather than flickering at one level.
##
## Derived from the basin (which restores its own `fill_volume`, liquid type and crust): the sensor reads the basin
## directly with no overlap to wait for, so a restore needs no grace period. It still saves `powered` and
## `time_left`: a fresh sensor starts unpowered and would rise on the first physics frame after a restore, and a
## rising edge turns a wired mirror a step. `load_state()` snaps silently and emits `powered_changed` only on a
## change; the live reading takes over from the next physics frame, and a reading inside the hysteresis band keeps
## whichever state was restored. A basin authored pre-filled past the threshold powers on the first physics frame,
## which the PowerTarget's startup apply absorbs like any source's.
##
## The editor warnings (unset or wrong `basin`, no interior, `column` out of range) refresh when the sensor's own
## exports change; if you change the basin's width, reselect this node or reopen the scene.
## Sounds `interactive/basin_sensor_on` and `interactive/basin_sensor_off` (on a change of `powered`, not within
## QUIET_FRAMES of load) are in Audio.PLANNED.

signal powered_changed(on: bool)

enum Mode { FILL, CRUST, COLUMN }
enum LiquidFilter { ANY, WATER, SLAG }

## The WaterBasin to read.
@export var basin: NodePath:
	set(value):
		basin = value
		update_configuration_warnings()
		queue_redraw()
## What to read: the fill fraction, a crust, or liquid over one column.
@export var mode: Mode = Mode.FILL:
	set(value):
		mode = value
		notify_property_list_changed()  # shows/hides the mode's own fields
		update_configuration_warnings()
		queue_redraw()
## Only read a basin holding this liquid (its runtime type). ANY = no condition.
@export var liquid_filter: LiquidFilter = LiquidFilter.ANY
## FILL: the fill fraction (0 empty, 1 full to the spill point) at which the sensor powers.
@export_range(0.05, 1.0, 0.05) var fill_fraction: float = 0.5:
	set(value):
		fill_fraction = value
		queue_redraw()
## FILL: how far below `fill_fraction` the basin must fall before the sensor releases.
@export_range(0.0, 0.5, 0.01, "or_greater") var fill_hysteresis: float = 0.05
## COLUMN: which interior column to watch, counted from the left wall (0 = just inside it).
@export_range(0, 64, 1, "or_greater") var column: int = 0:
	set(value):
		column = value
		update_configuration_warnings()
## COLUMN: depth of liquid over that column, in tiles, at which the sensor powers.
@export_range(0.05, 8.0, 0.05, "or_greater") var column_depth_tiles: float = 0.25:
	set(value):
		column_depth_tiles = value
		queue_redraw()
## COLUMN: how far below `column_depth_tiles` the liquid must fall before the sensor releases.
@export_range(0.0, 2.0, 0.01, "or_greater") var depth_hysteresis_tiles: float = 0.15
## Seconds the reading must stay unmet before the sensor releases. 0 = releases the same frame.
@export_range(0.0, 5.0, 0.05, "or_greater") var hold_time: float = 0.15
@export var draw_placeholder: bool = true

const QUIET_FRAMES := 3 ## No sound for a change this soon after load.
const EPSILON := 0.0005 ## Float slack on a fraction compared with its threshold (a full basin reads 0.9999...).
const TILE_HALF := 8.0
const GAUGE_RECT := Rect2(-3.0, -5.5, 6.0, 11.0) ## The level tube, local to the origin.
const COLOR_BODY := Color(0.25, 0.27, 0.32)
const COLOR_EDGE := Color(0.55, 0.58, 0.65)
const COLOR_TUBE := Color(0.1, 0.11, 0.14)
const COLOR_TICK := Color(1.0, 0.75, 0.25)
const COLOR_CRUST := Color(0.5, 0.46, 0.42)
const COLOR_LAMP_OFF := Color(0.3, 0.1, 0.1)
const COLOR_LAMP_ON := Color(0.35, 0.9, 0.45)

var powered: bool = false
var reading: float = 0.0 ## The last physics frame's reading: a fraction (FILL), 0/1 (CRUST) or tiles (COLUMN).
var _basin: WaterBasin
var _time_left: float = 0.0 ## Hold remaining while the reading is unmet and the sensor is powered.
var _drawn_reading: float = -1.0
var _ready_frame: int = 0

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()
	_resolve_basin()
	if _basin == null:
		push_warning("BasinSensor '%s': `basin` doesn't point at a WaterBasin; it will stay unpowered." % name)

func _validate_property(property: Dictionary) -> void:
	var shown := true
	match property.name:
		"fill_fraction", "fill_hysteresis":
			shown = mode == Mode.FILL
		"column", "column_depth_tiles", "depth_hysteresis_tiles":
			shown = mode == Mode.COLUMN
	if not shown:
		property.usage = PROPERTY_USAGE_STORAGE  # kept in the scene, hidden in the Inspector

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var target := get_node_or_null(basin) as WaterBasin
	if target == null:
		warnings.append("Set `basin` to a WaterBasin.")
	elif target.get_interior_column_count() <= 0:
		warnings.append("The basin has no interior (its width isn't derived yet, or it is only wall columns), so this sensor can never read it.")
	elif mode == Mode.COLUMN and column >= target.get_interior_column_count():
		warnings.append("`column` (%d) is beyond the basin's %d interior columns, so it can never power." % [column, target.get_interior_column_count()])
	return warnings

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound. Emits powered_changed only if `powered` differs from the current value.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered else 0.0
	if powered and _time_left <= 0.0:
		_time_left = hold_time
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	if _basin == null or not is_instance_valid(_basin):
		_resolve_basin()
		if _basin == null:
			return
	reading = _read_basin()
	if _is_met():
		_time_left = hold_time
		_set_powered(true)
	elif powered:
		_time_left = maxf(_time_left - delta, 0.0)
		if _time_left <= 0.0:
			_set_powered(false)
	if not is_equal_approx(reading, _drawn_reading):
		_drawn_reading = reading
		queue_redraw()

## (Re)finds the basin from the `basin` path. Named so an editor can re-run it after a change.
func _resolve_basin() -> void:
	_basin = get_node_or_null(basin) as WaterBasin

## The current reading for the chosen mode, straight from the basin (never its authored exports).
func _read_basin() -> float:
	match mode:
		Mode.FILL:
			return _basin.get_fill_fraction()
		Mode.CRUST:
			return 1.0 if _basin.has_crust else 0.0
		_:
			return _basin.get_liquid_depth_at_interior_column(column)

## Whether the reading counts now: the liquid-type condition, then the mode's threshold, with the release threshold
## (threshold minus hysteresis) once powered.
func _is_met() -> bool:
	if liquid_filter != LiquidFilter.ANY and int(_basin.liquid_type) != _filter_type():
		return false
	match mode:
		Mode.FILL:
			var release := fill_fraction - minf(fill_hysteresis, fill_fraction)
			return reading >= (release if powered else fill_fraction) - EPSILON
		Mode.CRUST:
			return reading > 0.5
		_:
			var release := column_depth_tiles - minf(depth_hysteresis_tiles, column_depth_tiles)
			return reading >= (release if powered else column_depth_tiles) - EPSILON

func _filter_type() -> int:
	return int(LiquidConstants.LiquidType.WATER) if liquid_filter == LiquidFilter.WATER else int(LiquidConstants.LiquidType.SLAG)

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if not on:
		_time_left = 0.0
	if Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/basin_sensor_on" if on else &"interactive/basin_sensor_off", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not draw_placeholder:
		return
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_BODY)
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_EDGE, false, 1.0)
	draw_rect(GAUGE_RECT, COLOR_TUBE)
	# How much of the tube is lit: the fill fraction, the crust (all or nothing) or the column depth against the
	# power threshold's own scale (the tube is full at twice the threshold). Nothing in the editor.
	var level := 0.0
	if not Engine.is_editor_hint():
		match mode:
			Mode.FILL:
				level = reading
			Mode.CRUST:
				level = reading
			_:
				level = reading / maxf(column_depth_tiles * 2.0, 0.001)
	level = clampf(level, 0.0, 1.0)
	var liquid_colour := COLOR_CRUST if mode == Mode.CRUST else _liquid_colour()
	if level > 0.0:
		var h := GAUGE_RECT.size.y * level
		draw_rect(Rect2(GAUGE_RECT.position.x, GAUGE_RECT.end.y - h, GAUGE_RECT.size.x, h), liquid_colour)
	# Tick at the power threshold (FILL and COLUMN).
	var tick_level := -1.0
	if mode == Mode.FILL:
		tick_level = fill_fraction
	elif mode == Mode.COLUMN:
		tick_level = 0.5
	if tick_level >= 0.0:
		var y := GAUGE_RECT.end.y - GAUGE_RECT.size.y * clampf(tick_level, 0.0, 1.0)
		draw_line(Vector2(GAUGE_RECT.position.x - 1.5, y), Vector2(GAUGE_RECT.end.x + 1.5, y), COLOR_TICK, 1.0)
	draw_rect(GAUGE_RECT, COLOR_EDGE, false, 1.0)
	draw_circle(Vector2(5.5, -5.5), 1.5, COLOR_LAMP_ON if powered else COLOR_LAMP_OFF)

## Gauge colour: the filter's liquid if one is set, else the basin's current one (water blue until a basin is read).
func _liquid_colour() -> Color:
	var type := LiquidConstants.LiquidType.WATER
	if liquid_filter == LiquidFilter.SLAG:
		type = LiquidConstants.LiquidType.SLAG
	elif liquid_filter == LiquidFilter.ANY and _basin != null and is_instance_valid(_basin):
		type = _basin.liquid_type
	return LiquidConstants.profile(type).color_base
