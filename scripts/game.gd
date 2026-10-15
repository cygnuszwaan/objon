extends Node
## Global input not tied to any one scene, plus the checkpoint snapshot store.
##
## SAVEABLE CONTRACT
## A node opts in by joining group "saveable" (in its own _ready()) and implementing:
##   save_state() -> Dictionary   plain data only (bool/int/float/String/Vector2/Array/Dictionary);
##                                nothing that references nodes or resources.
##   load_state(d: Dictionary)    re-applies that data to a freshly loaded node. Called on the
##                                fresh scene after reload, so it must snap (no animation, no
##                                sound, no emitted "edge" events) and must not depend on any
##                                other saveable having been restored first.
## Snapshot keys are each node's path relative to the level root, so they survive a
## level reload. Renaming or moving a saveable node in the level simply starts it fresh.
##
## FREED NODES: capture() only sees nodes that still exist. A saveable that frees itself
## (gem picked up, block melted, enemy killed) is therefore absent from the snapshot, and
## apply() frees the fresh copy of any saveable that has no entry. Such nodes need only
## save_state()/load_state() for the state they have while alive.
##
## LEVEL LOADING
## Game loads levels itself instead of using SceneTree.change_scene_to_file()/reload_current_scene(), so a level
## need not be a file on disk. load_level(id, source) is the one entry point: `id` is the level's identity (a
## StringName; the checkpoint is scoped to it) and `source` is a res:// path String or a PackedScene (null = look
## the id up in LevelCatalog). The level is instantiated, the old one removed first so two players never exist
## together, and the new root becomes current_scene. Game remembers the id and the source, so restart_level() and
## respawn() reload from those, never from scene_file_path. level_root() is the level's root node (use it instead
## of get_tree().current_scene). A level that was started by the editor (F6 or the main scene) is adopted: its
## id comes from the catalog row with the same path, or is made from the path (LevelCatalog.id_for_path()).
## Order and "next level" come from LevelCatalog, not from the levels.
##
## RESPAWN FLOW
## respawn() reloads the current level and, if a checkpoint exists, re-applies its snapshot and puts the player
## on it at full health; with no checkpoint it is a plain reload (the level's initial state). The restore runs
## from the new level root's `ready` signal, which fires after EVERY node's _ready() (so all saveables have
## joined their group) but before any deferred call queued by those _ready()s. Restored buttons therefore
## reach circuits and PowerTargets before their first recompute, and wired devices snap to their state through
## set_powered_initial(): no sounds, no animation. R and the player's death timer both call respawn().
## restart_level() is the "play again" path: it throws the checkpoint away first.
##
## PAUSE MENU
## Escape (the `menu` action) toggles scenes/ui/pause_menu.tscn, a modal list of LevelCatalog's levels. Opening it
## pauses the tree (physics, tweens, timers, the water manager and every node's _process stop); the menu and this
## autoload run in PROCESS_MODE_ALWAYS, and R does nothing while it is open. A level pick goes to load_level(id):
## it discards the checkpoint first (restart_level() semantics), and a pick of the current level is a restart.
##
## SCOPE: the snapshot belongs to the level id it was taken in. Loading another level id discards it
## (has_checkpoint() is false there), so a level never inherits stale state.
## In-memory only; nothing is written to disk.

signal snapshot_captured
signal snapshot_applied
## Emitted after a checkpoint has been committed (snapshot already taken). Checkpoint nodes use it to light
## the active one and dim the rest.
signal checkpoint_committed(index: int)

const SAVEABLE_GROUP := &"saveable"
const PauseMenuScene := preload("res://scenes/ui/pause_menu.tscn")

## Identity of the level that is loaded (empty until Game has adopted or loaded one). Checkpoints are scoped to it.
var current_level_id: StringName = &""

## Order of the last committed checkpoint (-1 = none). Only a strictly greater index
## replaces it, so touching an earlier checkpoint again does nothing.
var checkpoint_index := -1
## Where the player respawns (global position); meaningful when has_checkpoint().
var checkpoint_position := Vector2.ZERO

var _loading := false            # a load has been requested and the new level root isn't ready yet
var _restore_pending := false    # apply the snapshot once that root is ready
var _level: Node = null          # the loaded level's root (null before adoption)
var _level_source: Variant = null  # what _level was built from: a res:// path String or a PackedScene, so a reload needs no scene_file_path

var _menu: PauseMenu = null           # the open pause menu, null while closed
var _snapshot: Dictionary = {}   # String node path -> Dictionary
var _snapshot_level_id: StringName = &""  # level the snapshot was taken in


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # Escape has to close the menu while the tree is paused
	_ensure_adopted.call_deferred()  # the main scene isn't in the tree yet while autoloads are readied
	add_child(preload("res://scripts/touch_controls.gd").new())  # on-screen controls, shown on touch devices


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu") and not event.is_echo():
		get_viewport().set_input_as_handled()
		toggle_menu()
		return
	if get_tree().paused:
		return  # the menu is open (this node keeps running while paused): R and the rest wait
	if event.is_action_pressed("restart"):
		# After winning, R means "play again" (the level-complete overlay says so): start from scratch
		# rather than dropping the player back at the last checkpoint.
		var player := get_tree().get_first_node_in_group(&"player")
		if player != null and player.get("is_dancing"):
			restart_level()
		else:
			respawn()


## True while the pause menu is open.
func is_menu_open() -> bool:
	return _menu != null and is_instance_valid(_menu)


func toggle_menu() -> void:
	if is_menu_open():
		close_menu()
	else:
		open_menu()


## Pauses the tree and shows the menu over everything (the level-complete overlay included). Ignored while a
## reload is under way or between scenes.
func open_menu() -> void:
	if is_menu_open() or _loading or level_root() == null:
		return
	_menu = PauseMenuScene.instantiate() as PauseMenu
	_menu.resume_requested.connect(close_menu)
	_menu.level_chosen.connect(load_level)
	get_tree().root.add_child(_menu)
	get_tree().paused = true
	Audio.play(&"ui/menu_open")


## Frees the menu and unpauses. Does nothing when it isn't open.
func close_menu() -> void:
	if not is_menu_open():
		return
	_menu.queue_free()
	_menu = null
	get_tree().paused = false
	Audio.play(&"ui/menu_close")


## The loaded level's root node, or null if there is none. Everything that used get_tree().current_scene for "the
## level" asks this instead, so a level hosted under some other node later needs no change at the callers.
func level_root() -> Node:
	_ensure_adopted()
	return _level if _level != null and is_instance_valid(_level) else null


## The single entry point that loads a level from scratch: the menu is closed (unpausing), the checkpoint and its
## snapshot are discarded, the old level is removed and the new one becomes current. `id` is the level's
## identity; `source` is a res:// path String or a PackedScene, or null to look `id` up in LevelCatalog. With no
## source and `id` already loaded this is restart_level(). Safe to call from a signal or physics callback (the
## swap itself is deferred). Ignored while a load is under way.
func load_level(id: StringName, source: Variant = null) -> void:
	close_menu()
	_ensure_adopted()
	if _loading:
		return
	if source == null:
		if id == current_level_id and level_root() != null:
			restart_level()
			return
		source = LevelCatalog.source_of(id)
		if source == null:
			push_warning("Game: no level '%s' in the catalog." % id)
			return
	clear_checkpoint()
	_begin_load(id, source, false)


## The level to continue to after the current one: `override_path` (a `Finish.next_level`) if given, else the
## catalog's next row after the current level. Empty when there is none (the last level).
func next_level_id(override_path: String = "") -> StringName:
	if override_path != "":
		return LevelCatalog.id_for_path(override_path)
	return LevelCatalog.next_after(current_level_id)


## Reloads the level and returns the player to the active checkpoint with its snapshot re-applied (or to the
## level's start, untouched, if there is none). Ignored while a load is already under way.
func respawn() -> void:
	_reload(has_checkpoint())


## Reloads the level from scratch: the checkpoint and its snapshot are discarded first.
func restart_level() -> void:
	if _loading:
		return
	clear_checkpoint()
	_reload(false)


func _reload(restore: bool) -> void:
	_ensure_adopted()
	if _loading or level_root() == null:
		return
	_begin_load(current_level_id, _level_source, restore)


# A level that Godot loaded itself (the main scene, or F6 in the editor) is not known to Game yet: take it over, so
# respawn and checkpoints work for it exactly as for a level Game loaded. Its source is its own file, if it has one.
func _ensure_adopted() -> void:
	if _loading or (_level != null and is_instance_valid(_level)):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := scene.scene_file_path
	_level = scene
	_level_source = path if path != "" else null
	current_level_id = LevelCatalog.id_for_path(path) if path != "" else &"adopted"


func _packed_from(source: Variant) -> PackedScene:
	if source is PackedScene:
		return source
	if source is String and source != "" and ResourceLoader.exists(source):
		return load(source) as PackedScene
	return null


func _begin_load(id: StringName, source: Variant, restore: bool) -> void:
	if _loading:
		return
	var packed := _packed_from(source)
	if packed == null:
		push_warning("Game: could not load level '%s'." % id)
		return
	_loading = true
	_restore_pending = restore
	_swap_level.call_deferred(id, source, packed)


# Instantiates first (a failure leaves the old level alone), then removes the old level at once (not just
# queue_free(), which would leave two players in the tree for the rest of the frame) and adds the new root, which
# becomes current_scene. The restore, if any, waits for the new root's `ready` signal (see RESPAWN FLOW).
func _swap_level(id: StringName, source: Variant, packed: PackedScene) -> void:
	var instance := packed.instantiate()
	if instance == null:
		push_warning("Game: could not instantiate level '%s'." % id)
		_loading = false
		_restore_pending = false
		return
	var root := get_tree().root
	Engine.time_scale = 1.0  # a camera cue's slow motion never carries into the next level (the player restores it on leaving the tree too)
	if _level != null and is_instance_valid(_level):
		if _level.get_parent() != null:
			_level.get_parent().remove_child(_level)
		_level.queue_free()
	instance.ready.connect(_on_level_ready.bind(instance), CONNECT_ONE_SHOT)
	_level = instance
	_level_source = source
	current_level_id = id
	if not _restore_pending:
		clear_checkpoint()  # a fresh start, and keeps the snapshot's level id in step with the new id
	root.add_child(instance)
	get_tree().current_scene = instance


## True when a checkpoint has been committed in the current level.
func has_checkpoint() -> bool:
	_drop_if_level_changed()
	return checkpoint_index >= 0


## Commits a checkpoint: snapshots every saveable and records the respawn position.
## Returns false (and changes nothing) unless `index` is greater than the current one.
func commit_checkpoint(index: int, respawn_position: Vector2) -> bool:
	_drop_if_level_changed()
	if index <= checkpoint_index:
		return false
	capture()
	checkpoint_index = index
	checkpoint_position = respawn_position
	checkpoint_committed.emit(index)
	return true


## Discards the checkpoint and its snapshot.
func clear_checkpoint() -> void:
	_snapshot.clear()
	checkpoint_index = -1
	checkpoint_position = Vector2.ZERO
	_snapshot_level_id = current_level_id


## Replaces the stored snapshot with the current state of every saveable in the scene.
func capture() -> void:
	var scene := level_root()
	if scene == null:
		return
	var snap := {}
	for node in get_tree().get_nodes_in_group(SAVEABLE_GROUP):
		if node.is_queued_for_deletion() or not scene.is_ancestor_of(node):
			continue
		if not node.has_method("save_state"):
			push_warning("Game: '%s' is in group 'saveable' but has no save_state()." % node.get_path())
			continue
		var state = node.save_state()
		if not state is Dictionary:
			push_warning("Game: '%s'.save_state() must return a Dictionary." % node.get_path())
			continue
		snap[_key(scene, node)] = (state as Dictionary).duplicate(true)
	_snapshot = snap
	_snapshot_level_id = current_level_id
	snapshot_captured.emit()


## Re-applies the snapshot to the (freshly loaded) current level: load_state() on every
## saveable that has an entry, queue_free() on every saveable that doesn't (see FREED
## NODES above). Returns false if there is no checkpoint for this level. Call it once the
## level's own startup work has finished; see the respawn flow for when.
func apply(scene_override: Node = null) -> bool:
	_drop_if_level_changed()
	var scene := scene_override if scene_override != null else level_root()
	if scene == null or checkpoint_index < 0:
		return false
	for node in get_tree().get_nodes_in_group(SAVEABLE_GROUP):
		if node.is_queued_for_deletion() or not scene.is_ancestor_of(node):
			continue
		var key := _key(scene, node)
		if _snapshot.has(key):
			if node.has_method("load_state"):
				var state: Dictionary = _snapshot[key]
				node.load_state(state.duplicate(true))
			else:
				push_warning("Game: '%s' is in group 'saveable' but has no load_state()." % node.get_path())
		else:
			node.queue_free()
	snapshot_applied.emit()
	return true


# The new level root's own `ready` signal is the first moment every node in it is ready, so that is where the
# restore happens (see RESPAWN FLOW). Connected in _swap_level() before the root enters the tree.
func _on_level_ready(scene: Node) -> void:
	_loading = false
	if not _restore_pending:
		return
	_restore_pending = false
	if not apply(scene):
		return
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method("respawn_at"):
		player.respawn_at(checkpoint_position)


func _key(scene: Node, node: Node) -> String:
	return str(scene.get_path_to(node))


func _drop_if_level_changed() -> void:
	# No level for a moment while one is being swapped in is not a level change.
	if level_root() == null:
		return
	if current_level_id != _snapshot_level_id:
		clear_checkpoint()
