extends AnimatedSprite2D
## Trap. Idle holds the animation's first frame. Every `fire_rate` seconds it plays the
## animation once, plays a sound, and spawns a Bullet from the "Muzzle" Marker2D child.
##
## Facing is this node's own rotation (bullet direction = Vector2.RIGHT.rotated(rotation)),
## not flip_h — a rotated turret can point any direction with no separate offset/collider
## mirroring needed, sidestepping the asymmetric-sprite pitfalls flip_h has elsewhere.
##
## Expected scene layout:
##   Cannon (AnimatedSprite2D, this script)
##     - Muzzle (Marker2D)   — barrel tip; bullets spawn here
##     - Timer               — wait_time is overwritten from fire_rate in _ready()
##     - PowerTarget         — powered = firing, unpowered = holds fire (set_powered() stops/starts the Timer);
##                             with nothing wired to it the cannon fires forever. Being enabled fires a shot
##                             straight away and only then starts the Timer, so the first bullet doesn't wait
##                             a full fire_rate.

const Bullet := preload("res://scenes/traps/cannon/bullet.tscn")

@export var fire_rate: float = 1.0 ## Seconds between shots.
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0

@onready var _muzzle: Marker2D = $Muzzle
@onready var _timer: Timer = $Timer
@onready var _solid_body: StaticBody2D = $StaticBody2D

func _ready() -> void:
	frame = 0
	stop()
	animation_finished.connect(_on_animation_finished)

	_timer.wait_time = fire_rate
	_timer.timeout.connect(_fire)
	_timer.start()

	_solid_body.add_to_group("water_solid")  # water-mechanic.md Phase 9.1: collision only — this body
		# never moves, so Phase 9.2's carry mechanism is simply inert for it.

## Power contract (see power_target.gd): powered = firing. Switching on fires one bullet immediately, then
## the Timer runs as usual (so the next one comes a full fire_rate later).
func set_powered(on: bool) -> void:
	if on:
		if _timer.is_stopped():
			_timer.start()
			# Deferred: a source may call this from inside a physics callback, where adding the bullet's
			# Area2D to the tree is not allowed.
			_fire_on_enable.call_deferred()
	else:
		_timer.stop()

## Deferred half of set_powered(true). Skipped if the cannon was switched off again before it ran.
func _fire_on_enable() -> void:
	if not _timer.is_stopped():
		_fire()

func _on_animation_finished() -> void:
	stop()
	frame = 0

func _fire() -> void:
	play()
	Audio.play_at(&"cannon/fire", global_position)

	var bullet: Area2D = Bullet.instantiate()
	bullet.direction = Vector2.RIGHT.rotated(global_rotation)
	bullet.global_position = _muzzle.global_position
	bullet.rotation = global_rotation
	get_parent().add_child(bullet)
