extends AnimatableBody2D
## Power-driven door. Its PowerTarget child (see door.tscn) takes the sources (buttons, or nothing:
## conductor circuits attach themselves to it by adjacency). `invert` is exported here and read by that
## PowerTarget, so an inverted door is open until powered. This script only implements the device side of
## the power contract: set_powered(on), powered = open, unpowered = closed, and set_powered_initial(on)
## for the startup state (snaps to it, no animation). A door with nothing wired to it stays closed.
##
## Art: sprites/interactive/door1.png, 16x144 = nine 16x16 frames drawn by one Sprite2D (vframes = 9).
## Frame 0 is fully closed (an 8px-wide post filling the tile, bottom-anchored); each later frame drops
## the top edge a further 2px; frame 8 is fully open. Frames 7 and 8 both leave a 2px foot, which is
## drawn but NOT solid: the collider is disabled whenever the visible height is down to FOOT_PX, so an
## open door is recessed into the floor and the player walks straight over it. The node origin is the CENTRE of its 16x16 tile (like Button/JumpPad, and
## the cell ConductorLayer files a device under). Rotate the instance in 90-degree steps for a horizontal
## door or one that closes from the top; the collider and art rotate together.
##
## Collider: layer 2, mask 0, joins "water_solid" and "ground" (water rests on it, and the ledge grab can
## latch onto its top). One RectangleShape2D, per instance, resized every frame change to the visible
## height, so collision is always what the art shows (except the foot, above).
##
## Closing is never a crush: before each step that would GROW the collider, an intersect_shape query over
## the new size looks for any layer-1 body (player, enemies, ice/metal blocks). If one is in the way the
## door holds at its current frame and retries every physics frame, closing the moment the space clears.
## The foot has no collider, so a close that starts from open only asks the question once the door would
## rise above it. Opening shrinks the collider, so it is never blocked; a player hanging from this door is released when
## the top drops away, since a hang is pinned in world space (same as drop_platform.gd).
##
## Sounds: interactive/door_open / interactive/door_close, played when the door actually starts moving
## in that direction (not while a blocked close is waiting).

@export var invert: bool = false ## Open until powered instead of closed until powered (read by the PowerTarget child).
@export var open_fps: float = 16.0 ## Frames per second while opening or closing (8 steps, closed to open).

const FRAME_COUNT := 9
const FRAME_CLOSED := 0
const FRAME_OPEN := 8
const TILE := 16.0
const HALF_TILE := 8.0
const COLLIDER_WIDTH := 8.0  ## The post's width in art pixels.
const STEP_PX := 2.0         ## The top edge drops this much per frame.
const FOOT_PX := 2.0         ## Frames 7 and 8 both keep a 2px foot: drawn, but not solid.
const PLAYER_GROUP := &"player"
const BLOCKING_MASK := 1     ## Physics layer 1 = actors and blocks (see Physics layers in objon.md).
const QUERY_INSET := 0.5     ## The blocked-close query is this much smaller per side, so a body merely touching never blocks.

var _want_open: bool = false
var _frame: int = FRAME_CLOSED
var _frame_pos: float = float(FRAME_CLOSED)  ## Fractional frame; _frame is its rounded value.
var _last_dir: int = 0  ## +1 opening, -1 closing, 0 idle: only used to play each sound once per movement.

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shape_node: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	add_to_group(&"ground")       # ledge-hangable, like moving_platform.gd
	add_to_group(&"water_solid")  # collision only; the door never translates, so water carry is inert
	add_to_group(&"saveable")
	_shape_node.shape = RectangleShape2D.new()  # per instance: the scene's shape resource is shared
	_snap_to_target()  # closed; the PowerTarget's deferred first apply then sets the startup state

## Device side of the power contract (PowerTarget calls this on its parent).
func set_powered(on: bool) -> void:
	if on == _want_open:
		return
	_want_open = on
	if is_node_ready():
		set_physics_process(true)

## Startup state (see power_target.gd): jump straight to it rather than animating.
func set_powered_initial(on: bool) -> void:
	_want_open = on
	if is_node_ready():
		_snap_to_target()

## Saveable contract (see game.gd). Stores the exact frame, so a door caught mid-travel (or holding against a
## blocker) comes back mid-travel and carries on.
func save_state() -> Dictionary:
	return {"want_open": _want_open, "frame_pos": _frame_pos}

## Snaps to the saved frame with no sound; resumes travel if it was mid-way to its target.
func load_state(d: Dictionary) -> void:
	_want_open = d.get("want_open", _want_open)
	_frame_pos = clampf(d.get("frame_pos", _frame_pos), float(FRAME_CLOSED), float(FRAME_OPEN))
	_last_dir = 0
	_set_frame(roundi(_frame_pos))
	var target := float(FRAME_OPEN if _want_open else FRAME_CLOSED)
	set_physics_process(not is_equal_approx(_frame_pos, target))

## True once fully open.
func is_open() -> bool:
	return _frame == FRAME_OPEN

func _physics_process(delta: float) -> void:
	var target := float(FRAME_OPEN if _want_open else FRAME_CLOSED)
	if is_equal_approx(_frame_pos, target):
		_frame_pos = target
		_last_dir = 0
		set_physics_process(false)
		return
	var next_pos := move_toward(_frame_pos, target, open_fps * delta)
	var next_frame := roundi(next_pos)
	if next_frame == _frame:
		_frame_pos = next_pos
		return
	var dir := 1 if next_frame > _frame else -1
	if dir < 0 and _height_for(next_frame) > FOOT_PX and _is_blocked(next_frame):
		_frame_pos = float(_frame)  # hold here; the whole step is retried next physics frame
		return
	if dir != _last_dir:
		_last_dir = dir
		Audio.play_at(&"interactive/door_open" if dir > 0 else &"interactive/door_close", global_position)
	_frame_pos = next_pos
	if dir > 0:
		_release_hanger()
	_set_frame(next_frame)

# --- collider / art ------------------------------------------------------------------------------

## Visible height of the door in `frame`, in pixels.
static func _height_for(frame: int) -> float:
	return maxf(FOOT_PX, TILE - STEP_PX * float(frame))

func _set_frame(frame: int) -> void:
	_frame = frame
	_sprite.frame = frame
	var height := _height_for(frame)
	var rect := _shape_node.shape as RectangleShape2D
	rect.size = Vector2(COLLIDER_WIDTH, height)
	_shape_node.disabled = height <= FOOT_PX  # open: the foot is recessed into the floor
	_shape_node.position = Vector2(0.0, HALF_TILE - height * 0.5)  # bottom-anchored in the tile

func _snap_to_target() -> void:
	_frame_pos = float(FRAME_OPEN if _want_open else FRAME_CLOSED)
	_last_dir = 0
	_set_frame(roundi(_frame_pos))
	set_physics_process(false)

# --- blocked close -------------------------------------------------------------------------------

## Would the collider at `frame` overlap an actor or block? (Only asked when the collider would grow.)
func _is_blocked(frame: int) -> bool:
	var height := _height_for(frame)
	var shape := RectangleShape2D.new()
	shape.size = Vector2(COLLIDER_WIDTH - 2.0 * QUERY_INSET, height - 2.0 * QUERY_INSET)
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = global_transform * Transform2D(0.0, Vector2(0.0, HALF_TILE - height * 0.5))
	params.collision_mask = BLOCKING_MASK
	params.exclude = [get_rid()]
	params.collide_with_bodies = true
	params.collide_with_areas = false
	return not get_world_2d().direct_space_state.intersect_shape(params, 1).is_empty()

# --- hang ----------------------------------------------------------------------------------------

## The top edge is about to drop away: let go of anyone hanging from this door.
func _release_hanger() -> void:
	var player := get_tree().get_first_node_in_group(PLAYER_GROUP)
	if player != null and player.get("hang_platform") == self:
		player.is_hanging = false
