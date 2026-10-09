extends Area2D
# Collectible medkit, beside its scene per the placement convention in objon.md. `Area2D` root +
# `AnimatedSprite2D` (2-frame idle at 2 fps, built in the scene) + `CollisionShape2D`.
#
# Duck-typed like gem_1.gd: whatever touches it just needs collect_medkit(heal, points) -> bool, which returns true
# if the medkit was taken. It is taken on touch even at full health (the heal is simply wasted, the points still
# count, so nobody gains by getting hurt first); only a dead or dancing player leaves it in place. The overlap is
# still polled every physics frame, which covers a player already standing in it when they become able to take it.

## Hit points restored (clamped to the player's max_health).
@export var heal_amount: int = 2
## Points awarded on pickup, whether or not the heal was needed.
@export var points: int = 10

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _collected := false

func _ready() -> void:
	add_to_group(&"saveable")
	sprite.play(&"idle")

# Saveable contract (see game.gd): like a gem, a medkit has no state beyond "still here". A collected
# one frees itself, so it is absent from the snapshot and Game.apply() frees the fresh copy on restore.
func save_state() -> Dictionary:
	return {}

func load_state(_d: Dictionary) -> void:
	pass

func _physics_process(_delta: float) -> void:
	if _collected:
		return
	for body in get_overlapping_bodies():
		if body.has_method("collect_medkit") and body.collect_medkit(heal_amount, points):
			_collected = true
			set_deferred("monitoring", false)  # same double-collect guard as the gem
			hide()
			queue_free()
			return
