@tool
extends Node2D
class_name WaterFaucet

# Authored liquid source that doubles as a DRAIN. Place the node's origin at the TOP-LEFT of the
# tile it occupies (the same tile-aligned convention basin.gd/conveyor_belt.gd use — snap to the
# tile grid in the editor). `spawn_offset` is the point, in pixels from that origin, where particles
# appear; the editor overlay draws the tile and the spawn point.
#
# Two modes, decided once at runtime from where the faucet sits:
#
# DRAIN — the faucet's tile is the floor tile of a WaterBasin's interior column (so the tile directly
# above it is inside that basin). While open it converts the basin's settled liquid back into
# particles at `flow_rate` volume per second, one PARTICLE_VOLUME per particle: volume is debited from the basin and a particle of the
# BASIN's liquid type (not this node's `liquid_type`) is spawned at the spawn point. Only real liquid
# drains — crust is left exactly as it is, and once the liquid is gone (or if only crust/void sits
# over the tile) the faucet emits nothing. The tile must be solid: basins derive their floor from
# tile collision, and the outlet particle simply falls out through it.
#
# SOURCE — anywhere else: no basin is involved, it just spawns `liquid_type` particles from the
# spawn point, exactly as before.
#
# No fixture art is drawn at runtime — the particles themselves ARE the visual. A visible fixture is
# a separate Sprite2D/AnimatedSprite2D child in the scene.

@export var is_open: bool = false
	# Authored starting state, used while nothing is wired to the PowerTarget child. Power drives it:
	# powered = open (set_powered(), below), `invert` flips that. `debug_toggle_key` is a separate,
	# additional way to flip it while testing.

@export var invert: bool = false
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0
	# Flips the power state (read by the PowerTarget child).

@export var liquid_type: LiquidConstants.LiquidType = LiquidConstants.LiquidType.WATER
	# Which liquid a SOURCE faucet drips. Ignored when the faucet is draining a basin (the basin's own
	# liquid comes out). STEAM is a valid enum value but nonsensical here: gas-only, it would drift up
	# and vanish rather than fall and pool.

@export_range(0.0, 50.0, 0.1, "or_greater") var flow_rate: float = 10.0
	# Liquid volume per second, in tile-area units (1.0 = one full tile of basin cross-section) —
	# the same units as WaterBasin.fill_volume, so a drain empties a basin at exactly this rate and a
	# source fills one at exactly this rate, independent of how many particles that takes. The
	# particle count is derived from it: one particle per LiquidConstants.PARTICLE_VOLUME of budget,
	# so changing ACTIVE_PRESET changes how finely the flow is divided, never how much flows.
	# The default (10.0) matches the old fixed 0.01s interval under the TEN preset.

@export var spawn_offset: Vector2 = Vector2.ZERO:
	set(value):
		spawn_offset = value
		queue_redraw()
	# Spawn point in pixels relative to the node origin (the tile's top-left) — keep it inside the
	# 16px tile. The default (0,0) keeps the old behavior for a free-placed source: particles appear at
	# the node's origin. For a floor drain, use something like (8, 16) (bottom-centre of the tile).

@export var debug_draw_tile: bool = true:
	set(value):
		debug_draw_tile = value
		queue_redraw()
	# Editor-only overlay: outlines the tile this node occupies and marks the spawn point.

@export var debug_toggle_key: Key = KEY_F:
	set(value):
		debug_toggle_key = value
		set_process_unhandled_input(not Engine.is_editor_hint() and debug_toggle_key != KEY_NONE)
	# Physical key that flips is_open at runtime — a stand-in for the real trigger this doesn't have
	# yet. KEY_NONE disables it. A raw physical key rather than an InputMap action: a temporary test
	# convenience, not part of the game's real control scheme.

const EDITOR_TILE_SIZE := Vector2(16, 16)
const DRAIN_RIPPLE_PER_VOLUME := 8.0
	# Cosmetic: px/s of downward surface kick per unit of drained volume (tile-area units), applied above the
	# drain so an opening drain dimples the surface and the dimple travels outward (basin.gd, "Surface ripple").
	# Per volume rather than per drip so the effect doesn't depend on ACTIVE_PRESET.

var _water_manager: WaterManager
var _volume_budget: float = 0.0  # flow accrued but not yet emitted as particles, in tile-area units
var _link_resolved: bool = false
var _drain_basin: WaterBasin = null  # null = SOURCE mode
var _drain_column: int = 0

func _ready() -> void:
	set_process_unhandled_input(not Engine.is_editor_hint() and debug_toggle_key != KEY_NONE)
	if Engine.is_editor_hint():
		set_physics_process(false)
		queue_redraw()
		return
	_water_manager = get_tree().get_first_node_in_group("water_manager")
	if _water_manager == null:
		push_warning("WaterFaucet at %s: no WaterManager found in the \"water_manager\" group — this faucet will never spawn anything" % global_position)

## Power contract (see power_target.gd): powered = open.
func set_powered(on: bool) -> void:
	is_open = on

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == debug_toggle_key:
		is_open = not is_open
		get_viewport().set_input_as_handled()
		# Marked handled so a debug key that collides with another unhandled-input consumer doesn't
		# also trigger that — a test convenience shouldn't have side effects beyond this one faucet.

func _physics_process(delta: float) -> void:
	if not is_open or _water_manager == null:
		_volume_budget = 0.0  # closed: nothing accrues, so reopening never dumps a stored burst
		return
	if not _link_resolved:
		_resolve_drain_link()
	_volume_budget += flow_rate * delta
	while _volume_budget >= LiquidConstants.PARTICLE_VOLUME:
		# while, not if: at high flow rates or after a frame-rate hitch several particles are due in
		# one frame, and the budget carries the remainder so the long-run rate is exact.
		_volume_budget -= LiquidConstants.PARTICLE_VOLUME
		if not _spawn_drip():
			_volume_budget = 0.0  # a drain with nothing to drain can't emit, so it shouldn't bank flow either
			return

func _resolve_drain_link() -> void:
	# Resolved lazily on the first open frame rather than in _ready(): basins register with the
	# manager on a deferred call, so at _ready() time the lookup below would find nothing. The
	# basin's structure is frozen once the level starts, so the answer never changes afterwards.
	# The cell is taken from the tile's centre, not its origin, so a node sitting exactly on a tile
	# corner can't round into a neighbouring cell.
	#
	# world_y for the lookup is the node's own origin (the tile's TOP edge), not the tile's centre
	# used for the column: that y is exactly a basin-above's seabed (its floor tile IS this row) and
	# strictly above a basin-below's rim (which starts a full tile lower) — the two are never
	# ambiguous at this exact boundary. Using the tile's centre here instead would sit inside the
	# solid floor tile itself, which belongs to neither basin's owns_world_point() range.
	_link_resolved = true
	var cell := _water_manager.world_to_cell(global_position + _water_manager.get_tile_size() * 0.5)
	var basin := _water_manager.get_basin_for_column(cell.x, global_position.y)
	if basin != null and basin.is_floor_cell(cell):
		_drain_basin = basin
		_drain_column = cell.x

func _spawn_drip() -> bool:
	# Returns false only when a drain has nothing left to drain (see _drip_from_basin()).
	# Horizontal velocity jittered to ±FAUCET_JITTER_SPEED so a stream doesn't read as a perfectly
	# rigid vertical line; vertical velocity always 0 at spawn, gravity does the rest.
	var jitter := randf_range(-LiquidConstants.FAUCET_JITTER_SPEED, LiquidConstants.FAUCET_JITTER_SPEED)
	if _drain_basin == null:
		_water_manager.spawn_particle(global_position + spawn_offset, Vector2(jitter, 0.0), liquid_type)
		return true
	return _drip_from_basin(jitter)

func _drip_from_basin(jitter: float) -> bool:
	if not _drain_basin.has_liquid_at_column(_drain_column):
		return false  # crust, void or dry floor over this tile — nothing to drain, so nothing comes out
	if _water_manager.get_active_count() >= WaterManager.MAX_PARTICLES:
		return true  # pool full: spawn_particle() would silently drop the particle, so don't debit for it
	var leftover := _drain_basin.remove_volume(LiquidConstants.PARTICLE_VOLUME)
	if leftover >= LiquidConstants.PARTICLE_VOLUME:
		return false  # nothing was actually removed
	# The final sliver smaller than PARTICLE_VOLUME still emits one whole particle — negligible next
	# to the alternative of a puddle that can never quite empty.
	# The outlet's y is kept at least one particle-width below the tile's top edge so the particle
	# starts wholly beneath the basin's seabed; see WaterManager._basin_for_particle().
	var spawn := global_position + Vector2(spawn_offset.x, maxf(spawn_offset.y, LiquidConstants.PARTICLE_PIXEL_SIZE))
	_water_manager.spawn_particle(spawn, Vector2(jitter, 0.0), _drain_basin.liquid_type)
	_drain_basin.disturb(global_position.x + spawn_offset.x, -DRAIN_RIPPLE_PER_VOLUME * LiquidConstants.PARTICLE_VOLUME, 8.0)
	return true

func _draw() -> void:
	if not Engine.is_editor_hint() or not debug_draw_tile:
		return
	draw_rect(Rect2(Vector2.ZERO, EDITOR_TILE_SIZE), Color(0.3, 0.8, 1.0, 0.9), false, 1.0)
	draw_circle(spawn_offset, 1.5, Color(1.0, 0.9, 0.2, 1.0))
