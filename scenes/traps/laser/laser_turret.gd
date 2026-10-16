@tool
extends Node2D
## Trap. Fires a continuous laser along its own rotation (direction = Vector2.RIGHT.rotated(
## global_rotation), same facing convention as Cannon — rotate the instance in the editor to aim).
## Each physics frame it solves the beam with LaserBeam.trace(), draws it, and dispatches whatever
## the beam finally hit:
##   - anything with on_laser_hit(point, direction) is told it's being lit (ice melts on this; a laser receiver only when
##     the beam reaches its BeamTarget, see "Beam targets" in laser_beam.gd)
##   - the player (group "player" with take_hit) is hurt, polled every frame like Sawwheel so a
##     player standing in the beam is hit again the moment their grace period ends
##   - an enemy (group "enemy" with take_damage) is hurt by one hit per `enemy_damage_interval`, tracked per
##     enemy (Drillbot ignores the amount and would die in three frames of per-frame polling). The beam still
##     stops at the enemy. The group gate matters: Mirror also has take_damage() (a kick turns it), and a beam
##     ending on a mirror's back or edge must not turn it.
## Everything else the beam touches is simply opaque. With `boils_water` on, the beam also boils the water of boilable
## basins it crosses (liquid has no collider, so the beam passes through it; see WaterManager.boil_along_beam()).
##
## Expected scene layout:
##   LaserTurret (Node2D, this script)
##     - Body (StaticBody2D, layer 2)  + CollisionShape2D   — the solid housing; joins "water_solid"
##     - Muzzle (Marker2D)                                  — beam origin, just outside the housing
##
## Placeholder art: the housing is drawn in code until real sprites exist. Add a Sprite2D/
## AnimatedSprite2D child and set draw_placeholder = false when it does.
##
## Beam art: assign `beam_texture` (and optionally `hit_texture`) and the beam is drawn from sprites instead of
## the vector placeholder. Both are vertical strips of square frames (frame size = the texture's width; the
## current art is 16x16 x 4), animated together at `beam_fps`, with the beam running along the frame's +X
## through its vertical centre. `beam_texture` is a one-tile stretch: every straight segment of the beam
## (turret to mirror, mirror to mirror, ...) is tiled from it, the last tile cropped to fit. `hit_texture`
## replaces the last tile-width of the final segment when the beam ends on something, with its right edge at
## the impact point (a segment shorter than the tile crops the left part off). With no `hit_texture` the
## vector spark is drawn instead; with no `beam_texture` everything is vector. Tiles outside the camera view
## aren't drawn. Damage and what the beam hits don't depend on the art.
##
## Power: powered = beam on (set_powered(on) -> set_enabled(on)); `invert` flips that. With nothing wired to
## its PowerTarget child it keeps its authored `enabled`. set_enabled(false) shuts the beam off and stops
## the hum without freeing anything.

@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_inside_tree() and not Engine.is_editor_hint():
			_apply_enabled()
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0
@export var damage: int = 1 ## Passed to the player's take_hit().
@export_range(0.1, 5.0, 0.05, "suffix:s") var enemy_damage_interval: float = 0.5 ## Seconds between hits on the same enemy (each hit is one point of damage).
## Opt-in laser boiling (roadmap 5.4): the beam boils WATER in any WaterBasin it crosses that has `boilable` on too (both
## flags must be true), making steam where it enters the liquid and draining the pool at the basin's boil_volume_scale.
@export var boils_water: bool = false
@export var draw_placeholder: bool = true
@export var beam_color: Color = Color(1.0, 0.25, 0.2, 1.0) ## Vector placeholder only.
@export_group("Beam art")
@export var beam_texture: Texture2D ## Vertical strip of square frames: one tile of straight beam.
@export var hit_texture: Texture2D ## Vertical strip of square frames: the beam's end where it hits something.
@export var beam_fps: float = 12.0
@export_group("")

@onready var _muzzle: Marker2D = $Muzzle
@onready var _body: StaticBody2D = $Body
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _points: PackedVector2Array = PackedVector2Array()  # world-space, from the last solve
var _end_hit: bool = false   # true when the beam ended on something (draw an impact spark)
var _hum  # Audio.LoopPlayer — left untyped so this @tool script parses in-editor without the autoload
var _time: float = 0.0
var _was_boiling: bool = false  # last frame's beam boiled something: the boil sound plays on the rising edge
var _water_manager: Node  # looked up lazily: only needed when boils_water is on
var _enemy_hit_times: Dictionary = {}  # enemy instance id -> _time of the last hit this turret dealt it

func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_body.add_to_group(&"water_solid")  # collision only — never moves, so carry is inert for it
	add_to_group(&"saveable")
	_hum = Audio.make_loop(&"traps/laser_hum")
	add_child(_hum)
	_apply_enabled()

func set_enabled(value: bool) -> void:
	enabled = value

## Saveable contract (see game.gd). Aim is the instance's own rotation and never changes at runtime, so the
## on/off state is all there is.
func save_state() -> Dictionary:
	return {"enabled": enabled}

func load_state(d: Dictionary) -> void:
	var saved: bool = d.get("enabled", enabled)
	if saved != enabled:  # the setter restarts/stops the hum, so only assign on a real change
		enabled = saved

## Power contract (see power_target.gd): powered = beam on.
func set_powered(on: bool) -> void:
	set_enabled(on)

func _apply_enabled() -> void:
	if not enabled:
		_was_boiling = false
		_points = PackedVector2Array()
		_end_hit = false
		if _hum != null:
			_hum.stop_loop()
		queue_redraw()
	else:
		sprite.play()  # no argument = plays whichever animation is currently selected in the SpriteFrames panel
		if _hum != null:
			_hum.start()

func _physics_process(delta: float) -> void:
	_time += delta
	if not enabled:
		return
	var origin := _muzzle.global_position
	var direction := Vector2.RIGHT.rotated(global_rotation)
	var exclude: Array[RID] = [_body.get_rid()]
	var space := get_world_2d().direct_space_state
	var result := LaserBeam.trace(space, get_tree(), origin, direction, exclude, LaserBeam.DEFAULT_MASK, LaserBeam.TARGET_LASER)

	_points = result.points
	_end_hit = result.end_collider != null
	_dispatch(result)
	if boils_water:
		_boil(result.points, delta)
	elif _was_boiling:
		_was_boiling = false
	queue_redraw()

## Hands the beam polyline to the level's WaterManager, which decides what it boils. The manager is looked up each frame
## until found (and again if it is freed), never once in _ready(), so tree order can't leave it null.
func _boil(points: PackedVector2Array, delta: float) -> void:
	if _water_manager == null or not is_instance_valid(_water_manager):
		_water_manager = get_tree().get_first_node_in_group(&"water_manager")
		if _water_manager == null:
			return
	if not _water_manager.has_method(&"boil_along_beam"):
		return
	var boiling: bool = int(_water_manager.boil_along_beam(points, delta)) > 0
	if boiling and not _was_boiling:
		Audio.play_at(&"traps/laser_boil", global_position)
	_was_boiling = boiling

func _dispatch(result: LaserBeam.Result) -> void:
	var target := result.end_collider
	if target == null:
		return
	if target.has_method(&"on_laser_hit") and LaserBeam.hit_counts(result):  # a receiver is lit only by a hit on its target
		target.on_laser_hit(result.end_point, result.end_direction)
	if target is Node and (target as Node).is_in_group(&"player") and target.has_method(&"take_hit"):
		target.take_hit(damage, global_position)
	if target is Node and (target as Node).is_in_group(&"enemy") and target.has_method(&"take_damage"):
		_burn_enemy(target as Node)

## One point of damage per `enemy_damage_interval` per enemy. The first frame of contact hits at once; the clock is
## kept per enemy, so a beam swept off and back onto the same enemy (a turning mirror) can't skip the interval.
func _burn_enemy(enemy: Node) -> void:
	var id := enemy.get_instance_id()
	if _enemy_hit_times.has(id) and _time - float(_enemy_hit_times[id]) < enemy_damage_interval:
		return
	_prune_enemy_hit_times()
	_enemy_hit_times[id] = _time
	enemy.take_damage(1)

## Drops clocks that have run out, so a long-lived turret doesn't keep an entry for every enemy it ever burned.
func _prune_enemy_hit_times() -> void:
	for id in _enemy_hit_times.keys():
		if _time - float(_enemy_hit_times[id]) >= enemy_damage_interval:
			_enemy_hit_times.erase(id)

# --- drawing -------------------------------------------------------------------------------

func _draw() -> void:
	if draw_placeholder:
		_draw_housing()
	if Engine.is_editor_hint():
		_draw_editor_aim()
		return
	if not enabled or _points.size() < 2:
		return
	var local_points := PackedVector2Array()
	for p in _points:
		local_points.append(to_local(p))
	if beam_texture != null:
		_draw_textured_beam(local_points)
		return
	var pulse := 0.85 + 0.15 * sin(_time * 40.0)
	var glow := beam_color
	glow.a = 0.25 * pulse
	draw_polyline(local_points, glow, 5.0, true)
	var mid := beam_color
	mid.a = 0.7 * pulse
	draw_polyline(local_points, mid, 3.0, true)
	draw_polyline(local_points, Color(1.0, 0.95, 0.9, 1.0), 1.0, true)
	if _end_hit:
		_draw_spark(local_points[local_points.size() - 1])

## Vector impact spark (placeholder, and the fallback when only beam_texture is assigned).
func _draw_spark(end: Vector2) -> void:
	var pulse := 0.85 + 0.15 * sin(_time * 40.0)
	var glow := beam_color
	glow.a = 0.25 * pulse
	var r := 2.5 + 1.5 * sin(_time * 55.0)
	draw_circle(end, r + 2.0, glow)
	draw_circle(end, r, Color(1.0, 0.95, 0.9, 1.0))

## Sprite beam: each segment is laid out in its own rotated frame (origin at the segment's start, +X along it)
## and tiled from beam_texture; the last segment ends in hit_texture when the beam hit something.
func _draw_textured_beam(local_points: PackedVector2Array) -> void:
	var tile := float(beam_texture.get_width())
	var beam_frame := float(int(_time * beam_fps) % maxi(int(beam_texture.get_height() / tile), 1))
	var view := (get_canvas_transform().affine_inverse() * get_viewport_rect()).grow(tile)
	var last := local_points.size() - 2
	for i in range(local_points.size() - 1):
		var a := local_points[i]
		var b := local_points[i + 1]
		var length := a.distance_to(b)
		if length < 0.01:
			continue
		var angle := (b - a).angle()
		var along := Vector2.RIGHT.rotated(angle)
		var has_hit_tile := _end_hit and i == last and hit_texture != null
		var hit_size := float(hit_texture.get_width()) if has_hit_tile else 0.0
		var hit_len := minf(length, hit_size)
		var beam_len := length - hit_len
		draw_set_transform(a, angle)
		var x := 0.0
		while x < beam_len:
			var w := minf(tile, beam_len - x)
			if view.has_point(to_global(a + along * (x + w * 0.5))):
				draw_texture_rect_region(beam_texture, Rect2(x, -tile * 0.5, w, tile), Rect2(0.0, beam_frame * tile, w, tile))
			x += tile
		if has_hit_tile:
			var hit_frame := float(int(_time * beam_fps) % maxi(int(hit_texture.get_height() / hit_size), 1))
			draw_texture_rect_region(hit_texture, Rect2(beam_len, -hit_size * 0.5, hit_len, hit_size), Rect2(hit_size - hit_len, hit_frame * hit_size, hit_len, hit_size))
	draw_set_transform(Vector2.ZERO, 0.0)
	if _end_hit and hit_texture == null:
		_draw_spark(local_points[local_points.size() - 1])

func _draw_housing() -> void:
	draw_rect(Rect2(-8, -8, 16, 16), Color(0.25, 0.27, 0.32))
	draw_rect(Rect2(-8, -8, 16, 16), Color(0.55, 0.58, 0.65), false, 1.0)
	# barrel toward local +X, where the beam leaves
	draw_rect(Rect2(2, -2, 8, 4), Color(0.4, 0.42, 0.48))
	draw_circle(Vector2(-2, 0), 2.5, beam_color if enabled else Color(0.3, 0.1, 0.1))

func _draw_editor_aim() -> void:
	# short dashed preview of the aim line, editor only (straight, ignores reflections)
	var start: Vector2 = Vector2.ZERO
	var muzzle := get_node_or_null("Muzzle") as Marker2D
	if muzzle != null:
		start = muzzle.position
	for i in 12:
		var a: Vector2 = start + Vector2(i * 16.0, 0.0)
		draw_line(a, a + Vector2(8.0, 0.0), Color(beam_color, 0.6), 1.0)
