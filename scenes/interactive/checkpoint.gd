@tool
extends Area2D
## Checkpoint: touching it commits a save (Game.commit_checkpoint) and sets where the player respawns.
##
## Art: sprites/interactive/checkpoint.png, 16x112 = seven 16x16 frames drawn by one Sprite2D (vframes = 7).
## Frame 0 is inactive, frame 6 lit; a light climbs the pole in between. Every checkpoint whose `order` is at
## or below the active one's is lit, so earlier checkpoints stay lit when a later one is touched, and any the
## player skipped light up too. Touching a new one plays 0 -> 6 on it (with interactive/checkpoint); skipped
## ones light silently. A level that reloads to a restored snapshot starts with all of them already lit, no
## animation and no sound.
##
## Ordering: `order` is assigned automatically when an instance is added to a scene in the editor: the lowest
## whole number from 1 up that no other checkpoint in that scene uses, so sequentially added checkpoints get
## 1, 2, 3 and, after deleting number 1, the next one added takes 1 again. It is an ordinary exported value,
## so it can still be edited by hand, and instances already saved in a level are never renumbered (only a
## node added to the edited scene, including a duplicate or paste, is assigned). A touch only counts if its `order` is GREATER
## than the active checkpoint's, so a later checkpoint overrides an earlier one and never the reverse. Two
## checkpoints sharing an `order` in one level get a warning: the second could never override the first.
##
## Respawn point: the node origin is the centre of its 16x16 tile (like Button/Door), and the player's collider
## is 16px tall centred on its origin, so respawning at the origin puts the feet exactly on the tile's bottom
## edge. `respawn_offset` (default 1px up) keeps the capsule from starting inside the floor.
##
## Touch detection: the sensor is polled every physics frame (like Sawwheel/Crusher) instead of using
## body_entered, so a player already standing in it when the level loads still counts. A player who is dead or
## dancing never activates one.
##
## Place it before the Player in the level tree (or give it a lower z_index) so the player draws in front.
##
## Expected scene layout (checkpoint.tscn):
##   Checkpoint (Area2D, this script, collision_layer 0, collision_mask 1)
##     - Sprite2D          (checkpoint.png, vframes 7)
##     - CollisionShape2D  (RectangleShape2D, the pole's tile)
##
## @tool only for the auto-numbering above: in the editor _ready() does that and returns, so nothing that needs
## the Game/Audio autoloads (they don't exist there) ever runs outside a running game.

@export_range(0, 999) var order: int = 0 ## Later checkpoints in the level need a higher number.
@export var respawn_offset: Vector2 = Vector2(0.0, -1.0) ## Added to the node origin for the respawn position.
@export var anim_fps: float = 12.0 ## Frames per second of the light-up (and the dim-down).

const FRAME_DARK := 0
const FRAME_LIT := 6
const PLAYER_GROUP := &"player"
const GROUP := &"checkpoint"

var _frame_pos: float = float(FRAME_DARK)
var _target_frame: int = FRAME_DARK

@onready var _sprite: Sprite2D = $Sprite2D

func _ready() -> void:
	add_to_group(GROUP)
	set_process(false)  # only runs while the frame is travelling
	if Engine.is_editor_hint():
		set_physics_process(false)
		# A node loaded from a saved scene already has its owner when _ready() runs; one just added in the
		# editor (instanced, duplicated or pasted) gets its owner only after being added, so owner is null.
		if owner == null:
			_assign_order.call_deferred()
		return
	Game.checkpoint_committed.connect(_on_checkpoint_committed)
	# has_checkpoint() also drops a snapshot left over from a different scene, so it must come first.
	if Game.has_checkpoint() and order <= Game.checkpoint_index:
		_snap(FRAME_LIT)  # reloaded onto a restored snapshot: already lit, silently
	else:
		_snap(FRAME_DARK)
	_warn_if_order_duplicated.call_deferred()

func _physics_process(_delta: float) -> void:
	if _is_overridden():
		return
	for body in get_overlapping_bodies():
		if _can_activate(body):
			_activate()
			return

## True while the active checkpoint is this one or a later one, so a touch would change nothing.
func _is_overridden() -> bool:
	return Game.has_checkpoint() and order <= Game.checkpoint_index

func _can_activate(body: Node) -> bool:
	if not body.is_in_group(PLAYER_GROUP):
		return false
	return not body.get("is_dead") and not body.get("is_dancing")

func _activate() -> void:
	# commit_checkpoint() takes the snapshot, stores the respawn position and emits checkpoint_committed,
	# which is what animates this node (and dims the others); it returns false if `order` isn't greater.
	if Game.commit_checkpoint(order, global_position + respawn_offset):
		Audio.play_at(&"interactive/checkpoint", global_position)

# Runs on every checkpoint in the level, this one included.
func _on_checkpoint_committed(index: int) -> void:
	_target_frame = FRAME_LIT if order <= index else FRAME_DARK
	set_process(true)

func _process(delta: float) -> void:
	_frame_pos = move_toward(_frame_pos, float(_target_frame), anim_fps * delta)
	_sprite.frame = roundi(_frame_pos)
	if is_equal_approx(_frame_pos, float(_target_frame)):
		set_process(false)

func _snap(frame: int) -> void:
	_target_frame = frame
	_frame_pos = float(frame)
	_sprite.frame = frame

## Editor only. Takes the lowest whole number from 1 up that no other checkpoint in the edited scene uses.
func _assign_order() -> void:
	var edited := get_tree().edited_scene_root
	if edited == null or edited == self or not edited.is_ancestor_of(self):
		return  # e.g. editing checkpoint.tscn itself: its own root must keep its authored value
	var used := {}
	for other in get_tree().get_nodes_in_group(GROUP):
		if other != self and edited.is_ancestor_of(other):
			used[other.get("order")] = true
	var free := 1
	while used.has(free):
		free += 1
	order = free
	notify_property_list_changed()

func _warn_if_order_duplicated() -> void:
	for other in get_tree().get_nodes_in_group(GROUP):
		if other != self and other.order == order and other.get_instance_id() < get_instance_id():
			push_warning("Checkpoint '%s' shares order %d with '%s': the later one can never override the earlier." % [get_path(), order, other.get_path()])
			return
