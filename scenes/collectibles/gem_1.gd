extends Area2D
# Collectible gem, kept beside its scene per the placement convention in objon.md — suggested
# home res://scenes/collectibles/. `Area2D` root + `AnimatedSprite2D` (idle/spin animation, Loop
# ON) + `CollisionShape2D`. Joins group "gem": the player counts the level's total from it at load and the
# Finish's unlock percentage is measured against that total. Collecting is the contract below.
#
# Mirrors the take_hit contract in player.gd rather than checking is_in_group("player"): whatever
# touches this just needs a collect_gem() method, so the gem doesn't need to know or care what the
# group is called.

## Points awarded on pickup (shown by the player's floating feedback and the points counter).
@export var points: int = 5

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

func _ready() -> void:
	add_to_group(&"gem")
	add_to_group(&"saveable")
	sprite.play()  # no argument = plays whichever animation is currently selected in the SpriteFrames panel
	body_entered.connect(_on_body_entered)

# Saveable contract (see game.gd). A gem has no state beyond "still here": collecting frees it, so a
# collected gem is absent from the snapshot and Game.apply() frees the fresh copy on restore.
func save_state() -> Dictionary:
	return {}

func load_state(_d: Dictionary) -> void:
	pass

func _on_body_entered(body: Node2D) -> void:
	if not body.has_method("collect_gem"):
		return
	body.collect_gem()
	if body.has_method("add_points"):
		body.add_points(points)
	# stop monitoring immediately — queue_free() doesn't remove the node until the end of the
	# frame, and a second overlapping body (or a second body_entered already queued this same
	# frame) could otherwise double-collect this same gem before it's actually gone.
	set_deferred("monitoring", false)
	hide()
	queue_free()
