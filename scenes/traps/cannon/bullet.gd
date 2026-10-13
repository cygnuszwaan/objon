extends Area2D
## Fired by Cannon. Travels in a straight line until it hits the player (hurts them) or a
## body in the "world_tilemap" group, at which point it's replaced with an Explosion and
## plays a sound. Ignores everything else (traps, enemies) unless the body opts in through the
## duck-typed contract below.
##
## Bullet contract (optional, on any body the mask sees): `on_bullet_hit(point: Vector2, direction: Vector2)
## -> bool`. `point` is the bullet's position, `direction` its normalized travel direction. Returning true
## means the body took the bullet: it detonates like any other impact. Returning false lets it fly on,
## so a body can opt out at runtime (Mirror with `bullet_rotates` off). Mirror, the bullet target and MeltableBlock implement it
## (a metal block absorbs the bullet unharmed; an ice or carbon fiber block breaks and consumes it).
##
## `direction` is set by Cannon right after instancing, before add_child — it does not
## need to be normalized. `speed` is an internal tuneable, not exported; the cannon has no
## business knowing or varying it.
##
## This Area2D's collision mask covers both layer 1 (actors, for the player) and layer 2
## (world, for tiles) — unlike this project's other pure-trigger areas (gems, Sawwheel,
## DrillHazard, KickHitbox), which only ever need to see the player and so stay on the
## all-default mask.
##
## Expected scene layout:
##   Bullet (Area2D, this script, collision_layer default / collision_mask = 1|2)
##     - AnimatedSprite2D
##     - CollisionShape2D

const Explosion := preload("res://scenes/effects/explosion.tscn")
const DAMAGE := 1

var speed: float = 240.0 ## px/sec — internal tuneable.
var direction: Vector2 = Vector2.RIGHT

@onready var _sprite: AnimatedSprite2D = $AnimatedSprite2D

func _ready() -> void:
	direction = direction.normalized()
	_sprite.play()
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	global_position += direction * speed * delta

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(&"player") and body.has_method(&"take_hit"):
		body.take_hit(DAMAGE, global_position)
		_detonate()
	elif body.is_in_group(&"world_tilemap"):
		_detonate()
	elif body.has_method(&"on_bullet_hit") and body.on_bullet_hit(global_position, direction):
		_detonate()

func _detonate() -> void:
	Audio.play_at(&"cannon/impact", global_position)

	var explosion: AnimatedSprite2D = Explosion.instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)

	queue_free()
