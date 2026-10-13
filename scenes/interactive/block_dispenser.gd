@tool
class_name BlockDispenser
extends Node2D
## Powered device that makes ice or metal blocks: a rising edge of power spawns one block at its `SpawnPoint` marker,
## so a block is a renewable resource (a replaceable shield, a second weight). Powered devices follow the power
## contract (see power.md): `set_powered(on)`, a `PowerTarget` child, `invert` exported here.
##
## Spawning. A rising edge (the final power state going off to on, after `invert`) spawns one `block_scene` instance,
## `size_tiles` big, centred on `SpawnPoint`, upright and at rest, fading in over FADE_IN_TIME but solid from the first
## frame. The startup state is never an edge, so a level never loads with a block waiting. An edge that arrives while
## `cooldown` is still running is dropped silently; the cooldown starts only after a block was actually spawned. If
## the spawn area is occupied (an `intersect_shape` over the block's footprint on layers 1|2, as the door does before
## closing) the edge is dropped and `interactive/dispenser_blocked` plays; that does not start the cooldown.
##
## max_alive. At most `max_alive` of this dispenser's blocks exist (0 = unlimited). A block that melted, shattered or
## was removed some other way no longer counts. When a new block would exceed the limit, the oldest are retired
## through `MeltableBlock.dissolve()` (a quiet fade, no liquid), and the blocks about to be retired are ignored by the
## occupancy check, since a block sitting on the spawn point is exactly what is being replaced. The new block is only
## made, and the old one only retired, if the area is free.
##
## Ownership (checkpoints). A spawned block is `spawner_owned`: it does not join group "saveable" itself, because
## `Game.apply()` frees every saveable with no snapshot entry and snapshot keys are node paths. The dispenser is the
## saveable: `save_state()` carries each live block's own state under an explicit, unique name
## (`<dispenser name>_block_<serial>`, serial saved), and `load_state()` re-creates them silently (no sound, no fade,
## no edge). Blocks are added as siblings of the dispenser, so the dispenser's transform never moves them.

const TILE := 16.0
const FADE_IN_TIME := 0.2 ## seconds a new block takes to fade in (it is solid throughout).
const AREA_INSET := 0.5 ## px: the occupancy query is this much smaller than the block on every side, so a block resting flush against a wall doesn't count the wall.
const BLOCK_MASK := 3 ## layers 1|2: actors (player, enemies, blocks) and the world.
const SOUND_SPAWN := &"interactive/dispenser_spawn"
const SOUND_BLOCKED := &"interactive/dispenser_blocked"
const SOUND_DISSOLVE := &"interactive/dispenser_dissolve"
const DISSOLVE_VOLUME_DB := -8.0 ## the retirement is meant to be quiet.
const DEFAULT_SPAWN_OFFSET := Vector2(0.0, TILE) ## local spawn point when the scene has no SpawnPoint marker.

@export var block_scene: PackedScene: ## Root must be a MeltableBlock (ice_block.tscn, metal_block.tscn or carbon_fiber_block.tscn).
	set(value):
		block_scene = value
		update_configuration_warnings()
@export var size_tiles: Vector2i = Vector2i(1, 1): ## Size of each spawned block in 16px tiles.
	set(value):
		size_tiles = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		queue_redraw()
@export_range(0, 16) var max_alive: int = 1 ## Most blocks of this dispenser alive at once; the oldest is dissolved to make room. 0 = unlimited.
@export_range(0.0, 10.0, 0.05, "or_greater") var cooldown: float = 0.5 ## Seconds after a spawn during which further rising edges are ignored. 0 = none.
@export var invert: bool = false ## Read by the PowerTarget child: spawns on the falling edge of the wired source instead.
@export var show_spawn_area: bool = true: ## Editor-only overlay: the block's footprint at the spawn point.
	set(value):
		show_spawn_area = value
		queue_redraw()

var _blocks: Array = [] ## this dispenser's blocks, oldest first (pruned lazily by _live_blocks())
var _serial: int = 0 ## next block name number; never reused, so a restored name can't collide
var _cooldown_left: float = 0.0
var _spawn_queued: bool = false

func _ready() -> void:
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"saveable")

func _physics_process(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
		if _cooldown_left == 0.0:
			queue_redraw()

# --- power device contract ---------------------------------------------------------------------------

## Rising edge = one spawn attempt. A falling edge does nothing.
func set_powered(on: bool) -> void:
	if not on or _spawn_queued or _cooldown_left > 0.0:
		return
	_spawn_queued = true
	call_deferred("_try_spawn")  # a source can change inside a physics callback, where adding a body is not allowed

## The startup state is not an edge: nothing spawns.
func set_powered_initial(_on: bool) -> void:
	pass

# --- spawning ----------------------------------------------------------------------------------------

func _try_spawn() -> void:
	_spawn_queued = false
	var block := _make_block()
	if block == null:
		return
	var retiring := _blocks_to_retire()
	if not _spawn_area_free(retiring):
		block.free()
		Audio.play_at(SOUND_BLOCKED, _spawn_global())
		return
	for old in retiring:
		old.dissolve()
		_blocks.erase(old)
	if not retiring.is_empty():
		Audio.play_at(SOUND_DISSOLVE, _spawn_global(), DISSOLVE_VOLUME_DB)
	block.name = "%s_block_%d" % [name, _serial]
	_serial += 1
	block.modulate.a = 0.0
	_add_block(block, _spawn_global())
	block.create_tween().tween_property(block, "modulate:a", 1.0, FADE_IN_TIME)
	_blocks.append(block)
	_cooldown_left = cooldown
	queue_redraw()
	Audio.play_at(SOUND_SPAWN, _spawn_global())

## A fresh, unparented block of the configured scene and size, or null if `block_scene` is unusable.
func _make_block() -> MeltableBlock:
	if block_scene == null:
		push_warning("%s: block_scene is not set" % name)
		return null
	var block := block_scene.instantiate() as MeltableBlock
	if block == null:
		push_warning("%s: block_scene's root is not a MeltableBlock" % name)
		return null
	block.size_tiles = size_tiles
	block.spawner_owned = true  # before add_child(): _ready() reads it
	return block

## Adds the block next to the dispenser, with its centre at `world_pos`.
func _add_block(block: MeltableBlock, world_pos: Vector2) -> void:
	var parent := get_parent()
	var parent_2d := parent as Node2D
	block.position = parent_2d.to_local(world_pos) if parent_2d != null else world_pos
	parent.add_child(block)

## This dispenser's blocks that are still around and intact, oldest first.
func _live_blocks() -> Array:
	var live: Array = []
	for b in _blocks:
		if is_instance_valid(b) and not b.is_queued_for_deletion() and b.is_intact():
			live.append(b)
	_blocks = live
	return live

## The oldest blocks that must go for one more to fit under `max_alive`.
func _blocks_to_retire() -> Array:
	var live := _live_blocks()
	if max_alive <= 0 or live.size() < max_alive:
		return []
	return live.slice(0, live.size() - max_alive + 1)

## True if nothing but `ignored` blocks overlaps the block-sized area at the spawn point.
func _spawn_area_free(ignored: Array) -> bool:
	var shape := RectangleShape2D.new()
	shape.size = Vector2(size_tiles) * TILE - Vector2.ONE * (AREA_INSET * 2.0)
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, _spawn_global())
	query.collision_mask = BLOCK_MASK
	var exclude: Array[RID] = []
	for b in ignored:
		exclude.append(b.get_rid())
	query.exclude = exclude
	return get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()

func _spawn_global() -> Vector2:
	var marker := get_node_or_null("SpawnPoint") as Node2D
	return marker.global_position if marker != null else to_global(DEFAULT_SPAWN_OFFSET)

# --- saveable contract -------------------------------------------------------------------------------

func save_state() -> Dictionary:
	var entries: Array = []
	for b in _live_blocks():
		entries.append({"name": String(b.name), "state": b.save_state()})
	return {"blocks": entries, "serial": _serial, "cooldown_left": _cooldown_left}

## Silent: re-creates the saved blocks (no sound, no fade, no edge) and drops any this fresh copy already has. Nothing
## else needs to have been restored first.
func load_state(d: Dictionary) -> void:
	for b in _live_blocks():
		b.free()
	_blocks = []
	_serial = int(d.get("serial", 0))
	_cooldown_left = maxf(0.0, float(d.get("cooldown_left", 0.0)))
	_spawn_queued = false
	for entry in d.get("blocks", []):
		var block := _make_block()
		if block == null:
			break
		block.name = String(entry.get("name", "%s_block_%d" % [name, _serial]))
		_add_block(block, _spawn_global())
		block.load_state(entry.get("state", {}))
		_blocks.append(block)
	queue_redraw()

# --- editor / drawing --------------------------------------------------------------------------------

## Plain method so a runtime level validator can reuse it; _get_configuration_warnings() forwards here.
func get_config_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if block_scene == null:
		out.append("block_scene is not set: nothing will spawn.")
	else:
		var probe := block_scene.instantiate()
		if not probe is MeltableBlock:
			out.append("block_scene's root must be a MeltableBlock (ice_block.tscn, metal_block.tscn or carbon_fiber_block.tscn).")
		if probe != null:
			probe.free()
	if get_node_or_null("PowerTarget") == null:
		out.append("A PowerTarget child is needed to drive this dispenser.")
	return out

func _get_configuration_warnings() -> PackedStringArray:
	return get_config_warnings()

## Placeholder art drawn in code: a steel housing on the dispenser's own tile with a mouth on its underside and a
## light (green = ready, amber = cooling down), plus the editor-only spawn-area outline.
func _draw() -> void:
	var half := TILE * 0.5
	draw_rect(Rect2(-half, -half, TILE, TILE), Color(0.30, 0.32, 0.37))
	draw_rect(Rect2(-half + 1.0, -half + 1.0, TILE - 2.0, TILE - 2.0), Color(0.42, 0.45, 0.52), false, 1.0)
	draw_rect(Rect2(-half + 3.0, half - 5.0, TILE - 6.0, 3.0), Color(0.08, 0.09, 0.11))
	var ready_light := Color(0.35, 0.85, 0.45) if _cooldown_left <= 0.0 else Color(0.95, 0.70, 0.25)
	draw_rect(Rect2(-half + 3.0, -half + 3.0, 3.0, 3.0), ready_light)
	if show_spawn_area and Engine.is_editor_hint():
		var marker := get_node_or_null("SpawnPoint") as Node2D
		var centre := marker.position if marker != null else DEFAULT_SPAWN_OFFSET
		var size := Vector2(size_tiles) * TILE
		draw_rect(Rect2(centre - size * 0.5, size), Color(0.35, 0.85, 0.45, 0.9), false, 1.0)
