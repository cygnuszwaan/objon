extends AnimatableBody2D
# res://scenes/interactive/drop_platform.gd — a platform that gives way after being stood
# on (or hung from) for a bit, falls out of the level, then quietly reappears in its
# original spot once that spot is off screen. Built fresh, not a port of DropPlatform.cs
# (see objon.md): the original ran a DOTween punch-rotation and a separate coroutine timer
# off the same dropDelay value — two clocks for one conceptual sequence. Here it's one
# countdown float, same discipline as crusher.gd/sawwheel.gd.
#
# Node setup:
#   - root AnimatableBody2D (this script) + $Sprite2D (or rename the @onready below to match —
#     any CanvasItem works, since only `modulate` is touched) + $CollisionShape2D, the solid slab.
#     Unlike moving_platform.gd, the sprite IS touched by this script now, to flash a warning
#     during the hold time (see below).
#   - $LandingSensor: an Area2D + its own CollisionShape2D, sized GENEROUSLY by hand in the
#     editor — wide/tall enough to overlap the player both standing on top AND hanging from
#     the edge (the hang grip sits above/beside the ledge corner per player.gd's
#     hang_grip_inset/hang_grip_lift/hang_hand_local_offset tuning, not exactly at the
#     surface), since detection here is geometric overlap, not a reference into player
#     internals. A little oversized is fine; it only needs to rule out "nowhere near this
#     platform", the is_on_floor()/hang_platform check below does the precise part.
#   - $RespawnNotifier: a VisibleOnScreenNotifier2D. Size its `rect` to the platform's
#     footprint in the editor. Script makes it top_level so it stays pinned to the ORIGINAL
#     spot even after this body has fallen away — that's what lets the "reappear only once
#     off screen" rule work without a second body/scene involved.
#
# Ledge-hanging: like the moving platform, this joins group "ground" so player.gd's
# _is_hangable_surface() accepts it — no special-casing needed there.
#
# Sequence: armed (waiting) -> landed on/hung from (hold_time countdown starts, one-shot —
# leaving early does NOT cancel it, same "you touched it, it's committed" feel as a real
# trapdoor; sprite flashes FLASH_COUNT times over the countdown as the "this is about to
# give way" tell) -> drop (collision disables immediately, so a standing player falls through
# the gap instead of riding it down; a player hanging from THIS platform is forced to let go,
# since a hang is pinned in world space and wouldn't otherwise notice the collision is gone)
# -> falls until the ORIGINAL slot is off screen -> reset there, re-armed.
#
# Known simplification: reappearing is gated only on the original slot being off screen, not
# on the falling copy also being off screen. In a normal side-scroller this holds anyway (by
# the time you've scrolled away from the hole, the copy — further off in the same direction —
# is long gone too), but a level where the camera can see both the hole and the fall path at
# once could show a brief "vanish" when it resets. Flagging rather than adding a second
# notifier for a case that hasn't come up yet.

@export var hold_time: float = 1.0  # seconds the platform holds after landing/hanging before it drops

const FALL_GRAVITY: float = 900.0  # matches player.gd's gravity, so the drop reads as a normal fall
const FALL_MAX_SPEED: float = 600.0
const FLASH_COUNT: int = 3       # not exported — a fixed "unstable" tell, not a per-instance tunable
const FLASH_MIN_ALPHA: float = 0.25

@onready var solid_shape: CollisionShape2D = $CollisionShape2D
@onready var landing_sensor: Area2D = $LandingSensor
@onready var respawn_notifier: VisibleOnScreenNotifier2D = $RespawnNotifier
@onready var sprite: CanvasItem = $Sprite2D  # any CanvasItem works — only `modulate` is touched

var _start_position: Vector2
var _armed: bool = true
var _hold_timer: float = 0.0
var _dropping: bool = false
var _fall_velocity: float = 0.0
var _rider: Node = null  # whoever tripped the countdown; only used to release a hang at drop time
var _flash_tween: Tween  # kept so a drop mid-flash can kill it instead of leaving modulate stuck dim

func _ready() -> void:
	add_to_group("ground")  # what makes the edge hangable — same mechanism as moving_platform.gd
	add_to_group("water_solid")  # water-mechanic.md Phase 9.1/9.3: particles can rest on this; once
		# solid_shape disables mid-drop, WaterManager's raycast simply stops finding it and a resting
		# particle starts falling on its own next frame — no explicit release call needed here.
	_start_position = position

	# Freeze RespawnNotifier at the authored spot, decoupled from wherever this body ends up.
	# Read global_position BEFORE flipping top_level (still resolved through the normal parent
	# transform at this point), then re-apply it after — once top_level is true, position/
	# global_position stop following the parent, so this "locks in" the original world spot.
	var origin := respawn_notifier.global_position
	respawn_notifier.top_level = true
	respawn_notifier.global_position = origin

func _physics_process(delta: float) -> void:
	if _dropping:
		_process_fall(delta)
		return

	if _armed:
		_check_for_landing()
	elif _hold_timer > 0.0:
		_hold_timer -= delta
		if _hold_timer <= 0.0:
			_start_drop()

func _check_for_landing() -> void:
	for body in landing_sensor.get_overlapping_bodies():
		if not body.is_in_group("player"):
			continue
		# is_on_floor() is a built-in CharacterBody2D check, not specific to this platform, but
		# combined with "currently overlapping this platform's own sensor" it's precise enough
		# without reaching into player internals for which body is the current floor. Hanging is
		# the one case with no floor contact at all, so it's checked via player.gd's own
		# hang_platform reference instead — exactly the state that mechanism exists for.
		var standing_on_us: bool = body.is_on_floor()
		var hanging_on_us: bool = body.get("hang_platform") == self
		if standing_on_us or hanging_on_us:
			_rider = body
			_armed = false
			_hold_timer = hold_time
			_start_flash_warning()
			return

func _start_flash_warning() -> void:
	# FLASH_COUNT dim/bright cycles spread evenly across the countdown, so the flashing finishes
	# right as the platform drops regardless of what hold_time is set to.
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate.a = 1.0
	var half_cycle: float = (hold_time / FLASH_COUNT) * 0.5
	_flash_tween = create_tween()
	_flash_tween.set_loops(FLASH_COUNT)
	# one warning sound per flash, in step with the visual (the callback runs at the start of each loop).
	# If the warning asset is instead a single long creak, call this once from here rather than per loop.
	_flash_tween.tween_callback(Audio.play_at.bind(&"interactive/drop_platform_warning", global_position))
	_flash_tween.tween_property(sprite, "modulate:a", FLASH_MIN_ALPHA, half_cycle)
	_flash_tween.tween_property(sprite, "modulate:a", 1.0, half_cycle)

func _start_drop() -> void:
	_dropping = true
	Audio.play_at(&"interactive/drop_platform_fall", global_position)
	solid_shape.set_deferred("disabled", true)  # let a standing player fall through the gap immediately

	# Timed to finish exactly as hold_time runs out, but kill it defensively anyway (e.g. if
	# hold_time is ever changed at runtime) so modulate.a can't get stuck mid-fade.
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate.a = 1.0

	# A hang is pinned in world space (see player.gd's hang_anchor/_follow_hang_platform) and
	# never touches our collision shape at all, so disabling it above does nothing for a player
	# currently hanging from THIS platform — without this they'd be left dangling in mid-air
	# where the ledge used to be. Force the hang off so gravity takes over, same as letting go.
	if is_instance_valid(_rider) and _rider.get("hang_platform") == self:
		_rider.is_hanging = false

	_rider = null

func _process_fall(delta: float) -> void:
	_fall_velocity = minf(_fall_velocity + FALL_GRAVITY * delta, FALL_MAX_SPEED)
	position.y += _fall_velocity * delta

	if not respawn_notifier.is_on_screen():
		_reset()

func _reset() -> void:
	position = _start_position
	_fall_velocity = 0.0
	_dropping = false
	_armed = true
	solid_shape.set_deferred("disabled", false)
