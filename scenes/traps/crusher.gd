extends Area2D
# res://scenes/traps/crusher.gd — piston-and-spikes hazard.
# Two hitboxes, both driven from the one shared phase value each physics
# frame: this node's own Area2D + CollisionShape2D is the "danger" hitbox
# (spike, deals damage via take_hit); $ArmBody is a solid AnimatableBody2D
# that blocks the player from jumping through the piston arm itself, and
# resizes to match how much of the arm is currently extended. Put ArmBody
# on whatever physics layer your ground/solid geometry uses so
# move_and_slide() treats it as solid.
#
# The spike also shatters ice, but only when it comes down on it: anything it overlaps that has shatter()
# (MeltableBlock) is told to once the spike's centre line is over it and the spike isn't retracting, and ice
# bursts into water through its own melt path; metal and other blocks ignore it. A block hitting the side of
# the arm is stopped, not shattered.

@export_range(0.0, 1.0) var phase_offset: float = 0.0    # fraction of a cycle to start ahead by — stagger multiple crushers from the Inspector
@export var extend_time: float = 0.8                      # seconds spent traveling from retracted to extended
@export var dwell_extended: float = 0.2                  # seconds held fully extended (the telegraph/punish window) before retracting
@export var retract_time: float = 0.8                     # seconds spent traveling from extended to retracted
@export var dwell_retracted: float = 0.2                 # seconds held fully retracted before extending again
@export var damage: int = 1
@export var invert: bool = false                          # flips the power state (read by the PowerTarget child)
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0
@export var travel_px: float = 20.0                      # total vertical travel; matches the 21-frame sprite (20 gaps × 1px)
@export var arm_height_extended: float = 28.0            # blocking arm's height at full extension; retracted height is this minus travel_px (28-20=8), so the arm's bottom edge always meets the spike's top edge with no gap or overlap

# Power contract (see power_target.gd): powered = cycling. Unpowered, it finishes whatever leg it is in and
# parks fully retracted (the safe rest pose, never frozen mid-stroke); powering it again resumes the cycle
# from there. With nothing wired to the PowerTarget child it cycles forever.
#
# Jam: a metal block (anything whose jams_crusher() is true) stalls the piston. The arm extends as normal and the
# jam latches the moment the spike touches the block from above (the same test as ice's crush, see
# _crushing_from_above()): the arm then reverses at once to the park position at its retract speed and stays there.
# That covers metal already under the arm when the extend leg starts and metal that slides in mid-stroke alike. A
# block pressed against the side of the arm doesn't touch the spike from above and doesn't jam it. The latch holds
# whatever happens to the block afterwards. Only a power cycle clears it (off, then on: set_powered()), so an
# unwired crusher stays jammed until the level reloads. While jammed the cycle clock is frozen at the start of the
# retracted dwell, which is where it resumes after a clear.

const FRAME_COUNT := 21
const TIP_INSET_PX := 1.0  ## How far inside the spike's bottom edge the crush test point sits.

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var extended_position: Vector2 = collision_shape.position  # authored position = fully extended (frame 0), captured once at ready-time
@onready var arm_body: AnimatableBody2D = $ArmBody
@onready var arm_shape_node: CollisionShape2D = $ArmBody/CollisionShape2D
@onready var arm_shape: RectangleShape2D = arm_shape_node.shape.duplicate()  # unique copy — this shape resource is otherwise shared across every Crusher instanced from this scene, so resizing it in place without duplicating would resize every instance in the level at once
@onready var arm_top_y: float = arm_shape_node.position.y - arm_shape_node.shape.size.y * 0.5  # fixed mount point, captured from the authored (extended) shape before we start resizing arm_shape

var _time: float = 0.0
var _segment: int = -1  # which of the four legs the cycle is in (see _physics_process); -1 until the first frame
var _powered: bool = true
var _parked: bool = false  # unpowered and holding at the fully retracted point of the cycle
var _tip_query: PhysicsPointQueryParameters2D  # built on first use by _crushing_from_above()
var _jammed: bool = false  # latched when the spike touches a metal block (see _latch_jam()); cleared only by a power cycle
var _retracted_fraction: float = 1.0  # last frame's arm position, 1 = fully retracted; a jam reverses the arm from here

## Power contract: powered = cycling.
func set_powered(on: bool) -> void:
	if on and not _powered:
		_jammed = false  # a power cycle (off, then on) clears a jam; the sweep re-latches it if the metal is still there
	_powered = on
	if on:
		_parked = false

## Startup/restore apply (see PowerTarget): the same as set_powered() but never an edge, so a restored jam is kept.
func set_powered_initial(on: bool) -> void:
	_powered = on
	if on:
		_parked = false

func _ready() -> void:
	add_to_group("trap")
	add_to_group("saveable")
	arm_body.add_to_group("water_solid")  # water-mechanic.md Phase 9.1: collision only — ArmBody's own
		# root position never moves (only its CollisionShape2D child resizes/repositions locally as the
		# piston extends/retracts), so Phase 9.2's carry mechanism is simply inert for this body.
	sprite.stop()  # frame is driven manually below, never by SpriteFrames' own playback speed
	arm_shape_node.shape = arm_shape  # swap in the duplicated copy before anything mutates it

## Saveable contract (see game.gd). The cycle is one accumulating clock plus the power/park flags; the sprite,
## hitbox and arm are all rebuilt from it on the next physics frame. `_segment` is restored too so the
## restore itself doesn't play a segment-change sound.
func save_state() -> Dictionary:
	return {"time": _time, "segment": _segment, "powered": _powered, "parked": _parked, "jammed": _jammed}

func load_state(d: Dictionary) -> void:
	_time = d.get("time", _time)
	_segment = d.get("segment", _segment)
	_powered = d.get("powered", _powered)
	_parked = d.get("parked", _parked)
	_jammed = d.get("jammed", false)
	_retracted_fraction = 1.0  # a jammed crusher is parked; any other state is rebuilt from the clock next frame

## Advances the cycle clock and returns how retracted the arm is this frame (0 extended .. 1 retracted).
func _cycle_fraction(delta: float) -> float:
	_time += delta

	# Full cycle length is just the four phases back to back: extend,
	# extended dwell, retract, retracted dwell.
	var period: float = extend_time + dwell_extended + retract_time + dwell_retracted

	# Position within the period, wrapped (guards against a negative
	# phase_offset producing a negative fmod result). phase_offset is a 0..1
	# fraction of the period so it stays meaningful if period is retuned.
	var t: float = fmod(_time + phase_offset * period, period)
	if t < 0.0:
		t += period

	# Trapezoidal wave carved out of one period: hold extended, linear
	# retract, hold retracted, linear extend — each leg's duration set
	# directly by its own exported field.
	var seg1_end: float = dwell_extended
	var seg2_end: float = seg1_end + retract_time
	var seg3_end: float = seg2_end + dwell_retracted

	# Unpowered: once the cycle reaches the retracted dwell (or steps straight past the retract leg when
	# there is no dwell), pin the phase at the fully retracted point instead of letting it advance.
	if not _powered and (_parked or (t >= seg2_end and (t < seg3_end or _segment == 1))):
		_parked = true
		_time -= t - seg2_end
		t = seg2_end

	var retracted_fraction: float
	var segment: int  # 0 extended dwell, 1 retracting, 2 retracted dwell, 3 extending
	if t < seg1_end:
		retracted_fraction = 0.0
		segment = 0
	elif t < seg2_end:
		retracted_fraction = 1.0 if retract_time <= 0.0 else (t - seg1_end) / retract_time
		segment = 1
	elif t < seg3_end:
		retracted_fraction = 1.0
		segment = 2
	else:
		retracted_fraction = 0.0 if extend_time <= 0.0 else 1.0 - (t - seg3_end) / extend_time
		segment = 3

	if segment != _segment:
		if _segment != -1:  # the very first frame only records where a phase-offset crusher started; no sound
			_on_segment_changed(_segment, segment)
		_segment = segment
	return retracted_fraction

func _physics_process(delta: float) -> void:
	var retracted_fraction := 1.0
	if not _jammed:
		retracted_fraction = _cycle_fraction(delta)
	if _jammed:  # also true on the frame the jam latches: the arm heads back to the park position at its retract speed
		retracted_fraction = 1.0 if retract_time <= 0.0 else move_toward(_retracted_fraction, 1.0, delta / retract_time)
	_retracted_fraction = retracted_fraction

	sprite.frame = roundi(retracted_fraction * (FRAME_COUNT - 1))
	collision_shape.position = extended_position + Vector2(0.0, -travel_px * retracted_fraction)

	# Blocking arm: same retracted_fraction drives this too, so it can't
	# desync from either the sprite or the danger hitbox. Top edge stays
	# pinned at the mount point; height shrinks toward it, which keeps the
	# bottom edge glued to the spike's top edge throughout the motion.
	var arm_height: float = arm_height_extended - travel_px * retracted_fraction
	arm_shape.size.y = arm_height
	arm_shape_node.position.y = arm_top_y + arm_height * 0.5

	# Same overlap-polling pattern as sawwheel.gd, for the same reason: a hit
	# can be ignored (post-hit grace) without the trap ever
	# "leaving" the player, so body_entered alone could miss a re-hurt. Here
	# it's doubly appropriate — the hitbox itself moves out of range whenever
	# the piston isn't near the ground, so no separate "danger window" state
	# is needed on top of the position check.
	for body in get_overlapping_bodies():
		if body.has_method("take_hit"):
			body.take_hit(damage, global_position)
		# Anything with shatter() (MeltableBlock: ice bursts into water through its own melt path, other blocks
		# ignore the call) is crushed, but only when the spike comes down on it (see _crushing_from_above()):
		# a block kicked into the side of the arm is just stopped by it.
		if body.has_method("shatter") and _crushing_from_above(body):
			body.shatter()
		# A metal block under the spike jams the piston the moment the spike touches it from above: the arm
		# reverses from where it is and the jam latches (see _latch_jam()). Evaluated against this frame's
		# position, so the arm is drawn touching the block before it starts back.
		if not _jammed and body.has_method("jams_crusher") and body.jams_crusher() and _crushing_from_above(body):
			_latch_jam()

## Latches the jam: the spike has touched a metal block. The arm heads back to the park position from wherever it is
## (see _physics_process()), the clock is parked at the start of the retracted dwell, where a clear resumes, and
## the jam sound plays once.
func _latch_jam() -> void:
	_jammed = true
	var period: float = extend_time + dwell_extended + retract_time + dwell_retracted
	var t: float = fposmod(_time + phase_offset * period, period)
	_time -= t - (dwell_extended + retract_time)
	_segment = 2
	_parked = false
	Audio.play_at(&"traps/crusher_jam", collision_shape.global_position)

## True when the spike is pressing down into `body` rather than meeting it from the side or below. Two tests: the
## spike isn't on its retracting leg (a block launched up into a rising spike, or one already inside it when the
## retract starts, isn't being crushed), and the spike's axis is over the block: a point just inside the bottom edge
## of the spike, on its centre line, lies inside the block's own collider. A block pressed against the side of the
## arm has its near edge at the arm's side, so the point is outside it however far the block is pushed.
func _crushing_from_above(body: Node2D) -> bool:
	if _segment == 1:
		return false
	if _tip_query == null:
		_tip_query = PhysicsPointQueryParameters2D.new()
		_tip_query.collision_mask = 1  # blocks sit on layers 1|2 (see objon.md, Physics layers)
		_tip_query.collide_with_areas = false
	var half_h := 0.5 * (collision_shape.shape as RectangleShape2D).size.y
	_tip_query.position = collision_shape.global_position + Vector2(0.0, half_h - TIP_INSET_PX).rotated(global_rotation)
	for hit in get_world_2d().direct_space_state.intersect_point(_tip_query):
		if hit.collider == body:
			return true
	return false

func _on_segment_changed(from_segment: int, to_segment: int) -> void:
	# Leaving the extending leg = the spike just reached full extension (the slam). Tested as "left
	# leg 3" rather than "entered leg 0" so it still fires if dwell_extended is set to 0.
	var at := collision_shape.global_position
	if from_segment == 3:
		Audio.play_at(&"traps/crusher_slam", at)
	if to_segment == 1:
		Audio.play_at(&"traps/crusher_retract", at)
	elif to_segment == 3:
		Audio.play_at(&"traps/crusher_extend", at)
