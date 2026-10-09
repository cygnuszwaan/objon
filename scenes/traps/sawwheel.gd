extends Area2D
# Stationary spinning circular saw (2x2 tiles). Purely an environmental hazard: it never moves,
# it just hurts whatever is overlapping it.
#
# Scene setup (res://scenes/interactive/sawwheel.tscn):
#   Sawwheel        (Area2D, this script)
#   |- AnimatedSprite2D   (SpriteFrames with the spin animation, Loop ON)
#   |- CollisionShape2D   (CircleShape2D, radius ~14-16 for a 32x32 saw — tune to the visible blade)
#
# Damages anything that has take_hit(damage: int, from_position: Vector2) — today that's only the
# Player, but bullets/enemies can gain the same method later without this script changing.

# Power contract (see power_target.gd): powered = spinning and dangerous, unpowered = the blade stops, the
# hum stops and it no longer hurts. With nothing wired to the PowerTarget child it spins forever.

@export var damage: int = 1
@export var invert: bool = false # Flips the power state (read by the PowerTarget child).

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _hum
var _active: bool = true

func _ready() -> void:
	add_to_group("trap")  # replaces the original's "Trap" tag; nothing reads it yet
	sprite.play()  # no argument = plays whichever animation is currently selected in the SpriteFrames panel

	# Blade hum: a looping positional sound owned by this saw, so it fades with distance and stops when
	# the saw is freed. Silent (and harmless) until res://audio/traps/sawwheel_hum.* exists.
	_hum = Audio.make_loop(&"traps/sawwheel_hum")
	add_child(_hum)
	_hum.start()

func set_powered(on: bool) -> void:
	_active = on
	if on:
		sprite.play()
		_hum.start()
	else:
		sprite.pause()
		_hum.stop_loop()

func _physics_process(_delta: float) -> void:
	if not _active:
		return
	# Poll every physics frame instead of connecting body_entered. body_entered fires ONCE, on the
	# frame the player first overlaps — but a hit can be ignored (post-hit grace
	# period), and a saw is stationary, so a player standing in it when immunity ends would never
	# be hurt again. Polling means "still overlapping when immunity runs out" gets hit, which is
	# what a hazard should do.
	for body in get_overlapping_bodies():
		if body.has_method("take_hit"):
			body.take_hit(damage, global_position)
