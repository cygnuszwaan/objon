@tool
extends StaticBody2D
## Conveyor belt. A static platform (physics layer 2, same as any other solid ground) that adds
## to the x-component of an actor's velocity while it's standing on top — see player.gd's
## _conveyor_push_speed(), which reads get_conveyor_speed() off whatever it's resting on each
## physics frame. Duck-typed the same way take_hit()/collect_gem() are: this node doesn't know
## or care that the rider is specifically the player.
##
## Deliberately NOT added to the "ground"/"catwalk" groups and not part of world_tilemap.
## _surface_type_at() only recognizes those, so _is_hangable_surface() and _catwalk_ahead() both
## return "" for this body — the player can never ledge-grab a conveyor, end caps included. This
## isn't a special case anywhere; it falls out of the existing surface-type check for free.
##
## @tool so `segments` rebuilds the belt live in the editor. Assign left_cap_frames/mid_frames/
## right_cap_frames once per belt (its three pieces of source art); segments then controls both
## length and which side of the node's origin the belt extends to — see the segments export
## comment below. It rebuilds Pieces (Node2D) with whatever mix of LeftCap/Mid.../RightCap
## AnimatedSprite2D children that calls for, and resizes/repositions CollisionShape2D's
## RectangleShape2D (disabling it entirely at segments == 0) to match. Each SpriteFrames resource
## needs "left" and "right" animations (the two travel directions), Loop on. Rebuilding replaces
## whatever is currently under Pieces — don't hand-edit its children, they won't survive the next
## segments/frames change.

enum Direction { LEFT, RIGHT }

const TILE_SIZE: float = 16.0

@export var left_cap_frames: SpriteFrames:
	set(value):
		left_cap_frames = value
		if is_inside_tree():
			_rebuild()

@export var mid_frames: SpriteFrames:
	set(value):
		mid_frames = value
		if is_inside_tree():
			_rebuild()

@export var right_cap_frames: SpriteFrames:
	set(value):
		right_cap_frames = value
		if is_inside_tree():
			_rebuild()

@export var segments: int = 3:
	# How many tiles wide the belt is, and which side of the node's origin it extends to:
	#   0        -> no belt at all (Pieces cleared, collision disabled)
	#   1        -> a single mid tile only, no end caps
	#   |n| >= 2 -> end caps at both ends with (|n| - 2) mid tiles between
	# Positive builds rightward from x=0 (origin at the belt's left edge); negative builds the same
	# layout leftward instead (origin at the belt's right edge) — see _segment_layout().
	set(value):
		segments = value
		if is_inside_tree():
			_rebuild()

@export var direction: Direction = Direction.RIGHT:
	set(value):
		direction = value
		if is_inside_tree():
			_update_visuals()
			queue_redraw()

@export var belt_speed: float = 80.0:  # px/s added to a rider's velocity.x; sign comes from direction
	set(value):
		belt_speed = value
		if is_inside_tree():
			_update_visuals()

@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_inside_tree():
			_update_visuals()

const REFERENCE_SPEED: float = 10.0
	# px/s that the art's authored FPS looks like a correct 1:1 scroll at (measured against the
	# actual sprites). speed_scale is derived from belt_speed / REFERENCE_SPEED so the animation's
	# apparent pace always tracks belt_speed — one knob instead of two that could drift apart.

@export var debug_draw_bounds: bool = true:
	# outlines the belt's total width, ticks each tile boundary, and shows a small direction arrow
	# in the editor viewport (see _draw()) — visible whether or not sprite art is assigned yet, and
	# harmless layered over real sprites once it is. Flip off once you don't need it.
	set(value):
		debug_draw_bounds = value
		queue_redraw()

@onready var pieces: Node2D = $Pieces
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	collision_layer = 2
	collision_mask = 0  # static; nothing needs to push this around
	_rebuild()
	# A one-shot queue_redraw() (called at the end of _rebuild(), and from the property setters
	# below) can silently miss its window for a NESTED scene instance in the editor — its canvas
	# item isn't always fully attached to the editor's live tree the instant _ready() runs, unlike
	# opening this scene standalone, where the node IS the tree root. Redrawing every editor frame
	# sidesteps the timing question entirely rather than chasing the "right" moment to call it once.
	# Zero runtime cost: set_process(false) below whenever this isn't running in the editor.
	set_process(Engine.is_editor_hint())

func _process(_delta: float) -> void:
	queue_redraw()

## Tile count and build direction shared by _rebuild() and _draw(), so the editor outline can
## never disagree with what actually gets built: [count, dir] where count = abs(segments) and
## dir is +1 (build rightward from x=0) or -1 (build leftward, ending flush at x=0).
func _segment_layout() -> Array:
	return [absi(segments), 1 if segments >= 0 else -1]

func _tile_position_index(i: int, count: int, dir: int) -> int:
	return i if dir > 0 else i - count

## Tears down and reinstances Pieces from left_cap_frames/mid_frames/right_cap_frames per
## _segment_layout(), then resizes CollisionShape2D's RectangleShape2D to match (assumes it
## already holds one — set its shape to a RectangleShape2D once by hand; this only ever touches
## size/position/disabled on it).
func _rebuild() -> void:
	if pieces == null:
		return
	for child in pieces.get_children():
		pieces.remove_child(child)  # out of the tree now, so the rebuilt pieces can take the same names
		child.queue_free()

	var layout := _segment_layout()
	var count: int = layout[0]
	var dir: int = layout[1]

	if collision_shape:
		collision_shape.disabled = count == 0

	if count == 1:
		_add_piece(mid_frames, "Mid1", _tile_position_index(0, count, dir))
	elif count >= 2:
		_add_piece(left_cap_frames, "LeftCap", _tile_position_index(0, count, dir))
		for i in count - 2:
			_add_piece(mid_frames, "Mid%d" % (i + 1), _tile_position_index(i + 1, count, dir))
		_add_piece(right_cap_frames, "RightCap", _tile_position_index(count - 1, count, dir))
	# count == 0: nothing to place — Pieces stays empty, collision stays disabled above

	if count > 0 and collision_shape and collision_shape.shape is RectangleShape2D:
		var rect := collision_shape.shape as RectangleShape2D
		rect.size.x = count * TILE_SIZE
		collision_shape.position.x = float(dir) * count * TILE_SIZE * 0.5

	_update_visuals()
	queue_redraw()

func _add_piece(frames: SpriteFrames, piece_name: String, tile_index: int) -> void:
	var sprite := AnimatedSprite2D.new()
	sprite.name = piece_name
	sprite.sprite_frames = frames
	sprite.position = Vector2((tile_index + 0.5) * TILE_SIZE, 0.0)
	pieces.add_child(sprite)  # no owner on purpose: the pieces are rebuilt on every load, so they are never saved with a scene (and a belt still being dragged into a level isn't under the edited root yet, so setting one raises "Invalid owner")

## Polled by player.gd every physics frame it's grounded on this body. 0.0 while disabled, so a
## switched-off belt is inert rather than needing a separate "is this belt on" check at the call site.
func get_conveyor_speed() -> float:
	if not enabled:
		return 0.0
	return belt_speed if direction == Direction.RIGHT else -belt_speed

# --- public API for level buttons etc. (not yet built) to toggle or retune a belt at runtime ---
func set_enabled(value: bool) -> void:
	enabled = value

## Power contract (see power_target.gd): powered = running. `invert` flips it; with nothing wired to the
## PowerTarget child the belt keeps its authored `enabled`. The PowerTarget's tile is where a conductor
## wire attaches: move it along the belt to the tile the wire should end at.
func set_powered(on: bool) -> void:
	set_enabled(on)

func set_belt_speed(value: float) -> void:
	belt_speed = value

func _update_visuals() -> void:
	if pieces == null:
		return
	var anim := &"right" if direction == Direction.RIGHT else &"left"
	var scale := absf(belt_speed) / REFERENCE_SPEED
	for piece in pieces.get_children():
		if not piece is AnimatedSprite2D:
			continue
		var sprite: AnimatedSprite2D = piece
		if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(anim):
			push_warning("%s has no '%s' animation in its SpriteFrames" % [sprite.name, anim])
			continue
		sprite.speed_scale = scale
		if sprite.animation != anim or not sprite.is_playing():
			sprite.play(anim)
		if not enabled:
			sprite.pause()  # freeze mid-frame rather than hide, so a disabled belt still reads as "there"

func _draw() -> void:
	if not Engine.is_editor_hint() or not debug_draw_bounds:
		return
	var layout := _segment_layout()
	var count: int = layout[0]
	var dir: int = layout[1]
	if count == 0:
		return  # nothing built — nothing to outline

	var width := count * TILE_SIZE
	var origin_x := 0.0 if dir > 0 else -width
	var half_height := TILE_SIZE * 0.5

	draw_rect(Rect2(origin_x, -half_height, width, TILE_SIZE), Color.YELLOW, false, 1.0)
	for i in range(1, count):
		var x := origin_x + i * TILE_SIZE
		draw_line(Vector2(x, -half_height), Vector2(x, half_height), Color.YELLOW, 1.0)

	# small arrow at belt center pointing in the travel direction
	var arrow_dir := 1.0 if direction == Direction.RIGHT else -1.0
	var center := Vector2(origin_x + width * 0.5, 0.0)
	draw_line(center - Vector2(4.0 * arrow_dir, 0.0), center + Vector2(4.0 * arrow_dir, 0.0), Color.CYAN, 1.5)
	draw_line(center + Vector2(4.0 * arrow_dir, 0.0), center + Vector2(1.0 * arrow_dir, -2.0), Color.CYAN, 1.5)
	draw_line(center + Vector2(4.0 * arrow_dir, 0.0), center + Vector2(1.0 * arrow_dir, 2.0), Color.CYAN, 1.5)
