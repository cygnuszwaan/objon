extends AnimatedSprite2D

# Jump pad — an AnimatedSprite2D root, the same shape as cannon.gd: idle holds frame 0, and the
# animation plays through once per trigger rather than looping. A child Area2D fires the launch on
# overlap ("stepped on/entered" covers landing on top of it as well as walking into it from the side).
#
# Aim is the node's own rotation, not flip_h — rotate the instance in the editor to launch on an
# angle. Vector2.UP.rotated(global_rotation) turns with it, the same way Cannon's Muzzle direction
# turns with Vector2.RIGHT.rotated(global_rotation).
#
# Contract: anything exposing launch(vector: Vector2) gets launched — mirrors the
# take_hit()/collect_gem() duck-typing convention on player.gd rather than a group check, so this
# script doesn't need to know or care that "player" is the group name. Only the player currently
# the player and MeltableBlock (ice and metal blocks, scaled down by weight) implement launch(), so only they
# are affected; drillbot/stingbot walking over one are unaffected with no extra filtering needed here. The
# trigger is body_entered, so a block is launched once per entry, not every frame it overlaps.

# Power contract (see power_target.gd): powered = live, unpowered = inert (it doesn't launch and is drawn
# dimmed). With nothing wired to the PowerTarget child it is always live.

@export var launch_speed: float = 500.0
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).

const DIM_TINT := Color(0.5, 0.5, 0.55)
var _live: bool = true

@onready var trigger: Area2D = $Area2D
var _has_animation: bool = false

func _ready() -> void:
	_has_animation = sprite_frames != null and sprite_frames.has_animation("default")
	if not _has_animation:
		push_warning("No 'default' animation in SpriteFrames — jump pad will not animate")
	elif sprite_frames.get_animation_loop("default"):
		push_warning("JumpPad's 'default' animation has Loop enabled — turn it off in the SpriteFrames panel so it plays through once per trigger instead of looping")
	stop()  # AnimatedSprite2D.stop() resets to frame 0 — idle pose until triggered
	trigger.body_entered.connect(_on_body_entered)
	animation_finished.connect(_on_animation_finished)

func set_powered(on: bool) -> void:
	_live = on
	modulate = Color.WHITE if on else DIM_TINT

func _on_body_entered(body: Node2D) -> void:
	if not _live or not body.has_method("launch"):
		return
	body.launch(Vector2.UP.rotated(global_rotation) * launch_speed)
	Audio.play(&"jump_pad/launch")
	if _has_animation:
		play("default")

func _on_animation_finished() -> void:
	stop()  # back to the idle frame 0 pose, ready for the next trigger
