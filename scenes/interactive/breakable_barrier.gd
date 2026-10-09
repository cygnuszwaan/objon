@tool
extends StaticBody2D
## Breakable barrier: a solid wall that a fast enough surf breaks straight through, and that stops a slower one like
## any other wall. It opts in to the surf's bowl sweep (player.gd `_surf_bowl_sweep()`) through the same duck-typed
## contract the grunt and Drillbot use, `bowled_over(direction, surf_speed) -> bool`: at or above `break_speed` (and,
## optionally, only from the side `break_from` allows) it breaks and returns true, so the player keeps all its speed;
## otherwise it returns false and stays solid, so the surf ends against it.
##
## Layers: 1|2, collision_mask 0. Layer 2 makes it solid to the player like the rest of the world; layer 1 is what
## the bowl sweep queries (and the kick). Group "water_solid" (liquid collides with it), deliberately NOT "ground" or
## "catwalk", so the ledge grab can't latch onto it. Saveable with an empty state: a broken barrier frees itself, so
## it is absent from the snapshot and stays gone after a restore.
##
## The sweep only runs from the player's `surf_bowl_speed` (300 px/s), so a `break_speed` below that behaves as 300;
## the Inspector warns about it. Node origin is the TOP-LEFT corner of the barrier, on a 16 px grid point.

enum BreakFrom { EITHER, LEFT, RIGHT }

const TILE := 16.0
## Mirror player.gd's `surf_bowl_speed` and `surf_top_speed_wet`; only used for the Inspector warning.
const MIN_SWEEP_SPEED := 300.0
const MAX_SURF_SPEED := 800.0
const DEBRIS_GRAVITY := 600.0
const DEBRIS_MAX := 28

## Size in 16 px tiles. The collider is rebuilt from this on every load (a child's shape edits aren't saved in a level).
@export var size_tiles := Vector2i(1, 3):
	set(value):
		size_tiles = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		_apply_size()
## Surf speed (px/s) at or above which it breaks. Reachable range is about 300..600 dry, up to 800 on wet ground.
@export_range(300.0, 800.0, 10.0) var break_speed := 450.0:
	set(value):
		break_speed = value
		update_configuration_warnings()
		queue_redraw()
## Which side the surfer must come from: EITHER, LEFT (travelling right) or RIGHT (travelling left). From the other
## side it is an ordinary wall at any speed.
@export var break_from: BreakFrom = BreakFrom.EITHER:
	set(value):
		break_from = value
		queue_redraw()
@export var wood_color := Color(0.55, 0.38, 0.22):
	set(value):
		wood_color = value
		queue_redraw()
@export var band_color := Color(0.25, 0.25, 0.28):
	set(value):
		band_color = value
		queue_redraw()

var _broken := false

func _ready() -> void:
	_apply_size()
	if Engine.is_editor_hint():
		return
	add_to_group("saveable")  # in _ready(), never deferred: the restore runs before deferred work (see game.gd)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if break_speed < MIN_SWEEP_SPEED:
		warnings.append("break_speed is below the surf's bowl speed (%d); the sweep only runs from there, so it behaves as %d." % [MIN_SWEEP_SPEED, MIN_SWEEP_SPEED])
	if break_speed > MAX_SURF_SPEED:
		warnings.append("break_speed is above the surf's fastest top speed (%d); nothing can break it." % MAX_SURF_SPEED)
	return warnings

func _apply_size() -> void:
	var px := Vector2(size_tiles) * TILE
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node != null:
		var rect := RectangleShape2D.new()  # a new shape per instance, never a shared resource
		rect.size = px
		shape_node.shape = rect
		shape_node.position = px * 0.5
	queue_redraw()

## Surf contract (player.gd): `direction` is the way the surfer travels (-1/+1), `surf_speed` its current speed.
## True = broken, and the player then adds a collision exception at once so this frame's move isn't stopped.
func bowled_over(direction: float, surf_speed: float) -> bool:
	if _broken or surf_speed < break_speed:
		return false
	if break_from == BreakFrom.LEFT and direction <= 0.0:
		return false  # coming from the right
	if break_from == BreakFrom.RIGHT and direction >= 0.0:
		return false  # coming from the left
	_break(signf(direction))
	return true

func save_state() -> Dictionary:
	return {}

func load_state(_d: Dictionary) -> void:
	pass

func _break(direction: float) -> void:
	_broken = true
	# Retire at once: out of the groups (a checkpoint taken this frame must not include it, liquid must stop seeing
	# it) and collision off. The deferred disable is for the physics server; the player's exception covers this frame.
	remove_from_group("saveable")
	remove_from_group("water_solid")
	var shape_node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node != null:
		shape_node.set_deferred("disabled", true)
	Audio.play_at(&"interactive/barrier_break", global_position + Vector2(size_tiles) * TILE * 0.5, 4.0)
	_spawn_debris(direction)
	queue_free()

## Placeholder debris: small coloured shards thrown the way the surfer was travelling, falling and fading. Each shard
## owns its tween, so it dies quietly with its node; they live in the barrier's parent because the barrier is freed.
func _spawn_debris(direction: float) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var px := Vector2(size_tiles) * TILE
	var count := mini(int(px.x * px.y / 64.0) + 4, DEBRIS_MAX)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in count:
		var shard := ColorRect.new()
		var edge := rng.randf_range(2.0, 4.0)
		shard.size = Vector2(edge, edge)
		shard.color = wood_color if rng.randf() < 0.7 else band_color
		shard.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shard.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # moved in idle time
		parent.add_child(shard)
		var start := global_position + Vector2(rng.randf() * px.x, rng.randf() * px.y)
		shard.global_position = start
		var velocity := Vector2(direction * rng.randf_range(50.0, 190.0) + rng.randf_range(-30.0, 30.0), -rng.randf_range(30.0, 170.0))
		var life := rng.randf_range(0.5, 0.9)
		var step := func(t: float) -> void:
			shard.global_position = start + velocity * t + Vector2(0.0, 0.5 * DEBRIS_GRAVITY * t * t)
			shard.modulate.a = clampf((1.0 - t / life) / 0.4, 0.0, 1.0)
		var tween := shard.create_tween()
		tween.tween_method(step, 0.0, life, life)
		tween.tween_callback(shard.queue_free)

func _draw() -> void:
	var px := Vector2(size_tiles) * TILE
	draw_rect(Rect2(Vector2.ZERO, px), wood_color)
	for ty in size_tiles.y:
		for tx in size_tiles.x:
			var o := Vector2(tx, ty) * TILE
			# two plank seams and a nail in each corner
			draw_line(o + Vector2(0, 5.5), o + Vector2(TILE, 5.5), wood_color.darkened(0.3), 1.0)
			draw_line(o + Vector2(0, 10.5), o + Vector2(TILE, 10.5), wood_color.darkened(0.3), 1.0)
			for corner in [Vector2(2, 2), Vector2(13, 2), Vector2(2, 13), Vector2(13, 13)]:
				draw_rect(Rect2(o + corner, Vector2(1, 1)), band_color)
	# iron bands at the top and bottom edges
	draw_rect(Rect2(0, 0, px.x, 2), band_color)
	draw_rect(Rect2(0, px.y - 2, px.x, 2), band_color)
	draw_rect(Rect2(Vector2.ZERO, px), band_color, false, 1.0)
	if Engine.is_editor_hint():
		_draw_editor_hint(px)

## Editor only: arrows for the side it breaks from, and the break speed.
func _draw_editor_hint(px: Vector2) -> void:
	var mid := px * 0.5
	var arrow := Color(1.0, 0.85, 0.2)
	if break_from != BreakFrom.RIGHT:  # from the left: travelling right
		draw_line(Vector2(-14, mid.y), Vector2(-3, mid.y), arrow, 1.0)
		draw_line(Vector2(-6, mid.y - 3), Vector2(-3, mid.y), arrow, 1.0)
		draw_line(Vector2(-6, mid.y + 3), Vector2(-3, mid.y), arrow, 1.0)
	if break_from != BreakFrom.LEFT:  # from the right: travelling left
		draw_line(Vector2(px.x + 14, mid.y), Vector2(px.x + 3, mid.y), arrow, 1.0)
		draw_line(Vector2(px.x + 6, mid.y - 3), Vector2(px.x + 3, mid.y), arrow, 1.0)
		draw_line(Vector2(px.x + 6, mid.y + 3), Vector2(px.x + 3, mid.y), arrow, 1.0)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(0, -3), "%d px/s" % int(break_speed), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, arrow)
