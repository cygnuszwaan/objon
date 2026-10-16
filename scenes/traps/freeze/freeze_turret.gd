@tool
extends Node2D
## Trap. Fires a continuous freeze beam along its own rotation (direction = Vector2.RIGHT.rotated(global_rotation), the
## same facing convention as the laser turret: rotate the instance in the editor to aim). The third of the beam family:
## the laser is heat (instant), the arc is a charge (one hit), the freeze ray is cold, and its effect is CUMULATIVE: the
## dwell lives on the target (a basin's `freeze_time`, a receiver's `dwell_time`), not here.
##
## Each physics frame it solves the beam with LaserBeam.trace() (so it reflects off mirrors, passes catwalks and glass, and is
## stopped by everything that stops a laser, a crust included), draws it, and dispatches:
##   - whatever the beam finally hit, if it has on_freeze_hit(point, direction): told it is lit (the freeze receiver). The
##     receiver's physical body does not stop the beam at its edge: the beam runs on to the receiver's own target Area
##     (see "Beam targets" in laser_beam.gd) and the receiver is lit only when it gets there.
##   - the player or an enemy (anything with apply_chill): chilled, every frame (chill scales speed and never removes
##     control, and turns the body blue; see Chill in player.md and the shared ChillState). The beam is NON-LETHAL: it
##     deals no damage to anyone.
##   - every `freezable` basin the beam crosses: frost builds on it (WaterManager.freeze_along_beam()) and it freezes
##     once it has had `freeze_time` seconds of beam.
## Everything else the beam touches is opaque.
##
## Expected scene layout (same as the laser turret):
##   FreezeTurret (Node2D, this script)
##     - Body (StaticBody2D, layer 2)  + CollisionShape2D   - the solid housing; joins "water_solid"
##     - Muzzle (Marker2D)                                  - beam origin, just outside the housing
##     - AnimatedSprite2D, PowerTarget
##
## Art: the sprites are hue-shifted copies of the laser's (placeholders). The beam art is the same format as the laser
## turret's: `beam_texture` / `hit_texture` are vertical strips of square frames, tiled along each straight segment.
##
## Power: powered = beam on (set_powered(on) -> set_enabled(on)); `invert` flips that. With nothing wired to its
## PowerTarget child it keeps its authored `start_enabled`. Sound `traps/freeze_hum` (in Audio.PLANNED) loops while it is on.

@export var start_enabled: bool = true ## Whether the beam is on at the start when nothing drives its PowerTarget. Authored only: runtime code reads it into `enabled`.
@export var invert: bool = false ## Flips the power state (read by the PowerTarget child).
@export var draw_placeholder: bool = true
@export var beam_color: Color = Color(0.35, 0.8, 1.0, 1.0) ## Vector placeholder only.
@export_group("Beam art")
@export var beam_texture: Texture2D ## Vertical strip of square frames: one tile of straight beam.
@export var hit_texture: Texture2D ## Vertical strip of square frames: the beam's end where it hits something.
@export var beam_fps: float = 12.0
@export_group("")

var enabled: bool = true:  # runtime state (the authored value is `start_enabled`); the power contract and a restore write it
	set(value):
		enabled = value
		if is_inside_tree() and not Engine.is_editor_hint():
			_apply_enabled()

const CHILL_STRENGTH := 1.0 ## What the beam passes to a body's apply_chill(); ChillState sets how strong chill is.

@onready var _muzzle: Marker2D = $Muzzle
@onready var _body: StaticBody2D = $Body
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _points: PackedVector2Array = PackedVector2Array()  # world-space, from the last solve
var _end_hit: bool = false   # true when the beam ended on something (draw an impact spark)
var _hum  # Audio.LoopPlayer - left untyped so this @tool script parses in-editor without the autoload
var _time: float = 0.0
var _water_manager: Node  # looked up lazily, each frame until found

func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_body.add_to_group(&"water_solid")  # collision only - never moves, so carry is inert for it
	add_to_group(&"saveable")
	_hum = Audio.make_loop(&"traps/freeze_hum")
	add_child(_hum)
	enabled = start_enabled  # the setter applies it (starts the hum and the animation)

func set_enabled(value: bool) -> void:
	enabled = value

## Saveable contract (see game.gd). Aim is the instance's own rotation and never changes at runtime, so the on/off state
## is all there is.
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
	var result := LaserBeam.trace(space, get_tree(), origin, direction, exclude, LaserBeam.DEFAULT_MASK, LaserBeam.TARGET_FREEZE)

	_points = result.points
	_end_hit = result.end_collider != null
	_dispatch(result)
	_freeze_basins(result.points, delta)
	queue_redraw()

## Hands the beam polyline to the level's WaterManager, which builds frost on every freezable basin it crosses. The manager
## is looked up each frame until found (and again if it is freed), never once in _ready(), so tree order can't leave it null.
func _freeze_basins(points: PackedVector2Array, delta: float) -> void:
	if _water_manager == null or not is_instance_valid(_water_manager):
		_water_manager = get_tree().get_first_node_in_group(&"water_manager")
		if _water_manager == null:
			return
	if _water_manager.has_method(&"freeze_along_beam"):
		_water_manager.freeze_along_beam(points, delta)

func _dispatch(result: LaserBeam.Result) -> void:
	var target := result.end_collider
	if target == null:
		return
	if target.has_method(&"on_freeze_hit") and LaserBeam.hit_counts(result):  # a receiver is lit only by a hit on its target
		target.on_freeze_hit(result.end_point, result.end_direction)
	if target.has_method(&"apply_chill"):  # the player and every enemy answer it; the beam is opaque to both
		target.apply_chill(CHILL_STRENGTH)

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
	var pulse := 0.85 + 0.15 * sin(_time * 24.0)
	var glow := beam_color
	glow.a = 0.25 * pulse
	draw_polyline(local_points, glow, 5.0, true)
	var mid := beam_color
	mid.a = 0.7 * pulse
	draw_polyline(local_points, mid, 3.0, true)
	draw_polyline(local_points, Color(0.92, 0.98, 1.0, 1.0), 1.0, true)
	if _end_hit:
		_draw_spark(local_points[local_points.size() - 1])

## Vector impact flash (placeholder, and the fallback when only beam_texture is assigned).
func _draw_spark(end: Vector2) -> void:
	var pulse := 0.85 + 0.15 * sin(_time * 24.0)
	var glow := beam_color
	glow.a = 0.25 * pulse
	var r := 2.5 + 1.0 * sin(_time * 30.0)
	draw_circle(end, r + 2.0, glow)
	draw_circle(end, r, Color(0.92, 0.98, 1.0, 1.0))

## Sprite beam: each segment is laid out in its own rotated frame (origin at the segment's start, +X along it) and tiled
## from beam_texture; the last segment ends in hit_texture when the beam hit something. Same layout as the laser's.
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
	var lit := start_enabled if Engine.is_editor_hint() else enabled
	draw_circle(Vector2(-2, 0), 2.5, beam_color if lit else Color(0.1, 0.18, 0.3))

func _draw_editor_aim() -> void:
	# short dashed preview of the aim line, editor only (straight, ignores reflections)
	var start: Vector2 = Vector2.ZERO
	var muzzle := get_node_or_null("Muzzle") as Marker2D
	if muzzle != null:
		start = muzzle.position
	for i in 12:
		var a: Vector2 = start + Vector2(i * 16.0, 0.0)
		draw_line(a, a + Vector2(8.0, 0.0), Color(beam_color, 0.6), 1.0)
