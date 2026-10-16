extends Node2D
## An electric arc fired by an ArcTurret: one discrete, hazardous particle that flies along the laser solver's path.
## It hurts the player on touch, bounces off mirrors exactly as a laser beam does, and electrifies a basin's settled
## water the way a Rail bot's Spark does. It is a Node2D with no physics body and no collision layer, so nothing
## queries it (kicks, bowling, mine blasts, laser rays, bullets, sensors, the see-saw's load scan all miss it), by
## design: the player and a basin's water are the only things it reacts to.
##
## Motion: each physics frame the arc asks `LaserBeam.trace()` for the beam it would be if it were a laser, starting
## at its own position along its heading, and walks `speed * delta` along that polyline. A mirror turning mid-flight,
## a mirror on a moving platform or a tipping see-saw plank is therefore read live, and a reflection inside one
## frame needs no special case. Anything the solver stops at ends the arc: world tiles, doors, blocks, the back or
## edge of a mirror, the turret's own housing once the arc is `OWN_BODY_GRACE` px clear of it (it is excluded until then
## so the muzzle does not hit it). The trace mask is the world (layer 2) only, so an arc flies through enemies and
## actors unharmed and is not stopped by them; catwalks and glass pass it as they pass a laser. It also ends at
## `max_distance` of travel.
##
## Contract: a body that ends the arc and has `on_arc_hit(point, direction)` is told once (`ArcReceiver`).
##
## Hazard: the player is tested with an immediate circle `intersect_shape()` (mask 1, group "player") at every
## `SAMPLE_STEP` px of the frame's travel, so a fast arc cannot step over a thin collider. A hit calls
## `take_hit(damage, position)` and spends the arc whether or not the hit landed (i-frames), as a Spark does.
##
## Water: at the same sample points the arc offers its lowest point to the basin under it
## (`WaterManager.find_basin_at_point()` then `WaterBasin.try_electrify_at()`, the Spark's own calls and refusals:
## `conducts_sparks` off, slag, a crust, no liquid over the column, a point still above the surface). A basin that
## accepts spends the arc; one that refuses lets it fly on.
##
## `damage`, `speed`, `max_distance`, `heading` and `exclude_body` are set by the ArcTurret right after instancing,
## before `add_child()`. Arcs are not saved and vanish with the level on a respawn. Placeholder art: a bright ball
## with a jagged tail, drawn in code (`_draw`).
##
## Scene layout: Arc (Node2D, this script), nothing else.

const RADIUS := 3.0
const HIT_RADIUS := 4.0  # a little bigger than the ball, so a graze reads as a hit
const SAMPLE_STEP := 4.0  # px between hit and water samples along a frame's travel (HIT_RADIUS: no gap between circles)
const OWN_BODY_GRACE := 12.0  # px of travel before the firing turret's own body can stop the arc
const MIN_VERTEX_CLEARANCE := 0.75  # px: after crossing a mirror the arc is at least this far past it, so the next solve cannot start on the plate
const MAX_SAMPLES_PER_FRAME := 64
const FADE_TIME := 0.18  # seconds of the harmless impact flash
const TRAIL_POINTS := 7
const FLICKER_HZ := 30.0
const WORLD_MASK := 2  # layer 2: world solids; layer 1 (actors, enemies) is not seen by the trace
const PLAYER_MASK := 1
const CORE := Color(0.9, 1.0, 1.0)
const GLOW := Color(0.35, 0.8, 1.0)

var damage: int = 1
var speed: float = 220.0  # px/s
var max_distance: float = 480.0  # px of travel before it dies out
var heading: Vector2 = Vector2.RIGHT
var exclude_body: RID  # the firing turret's body: not collidable for the first OWN_BODY_GRACE px

var _traveled := 0.0
var _age := 0.0
var _fade := -1.0  # seconds left of the impact flash; negative = still flying
var _trail: PackedVector2Array = PackedVector2Array()  # world-space recent positions, newest last
var _manager: Node  # the level's WaterManager, looked up lazily (null if the level has none)
var _manager_searched := false
var _hit_shape: CircleShape2D

func _ready() -> void:
	heading = heading.normalized()
	_hit_shape = CircleShape2D.new()
	_hit_shape.radius = HIT_RADIUS
	# The trail is seeded on the first physics frame, not here: the turret sets `global_position` after `add_child()`,
	# so at `_ready()` the arc is still at the world origin and a trail started there draws a line from the origin.

func _physics_process(delta: float) -> void:
	_age += delta
	if _trail.is_empty():
		_trail.append(global_position)
	if _fade >= 0.0:
		_fade -= delta
		if _fade <= 0.0:
			queue_free()
		queue_redraw()
		return
	var budget := minf(speed * delta, max_distance - _traveled)
	if budget <= 0.0:
		_end(false)
		return
	var space := get_world_2d().direct_space_state
	var exclude: Array[RID] = []
	if _traveled < OWN_BODY_GRACE and exclude_body.is_valid():
		exclude.append(exclude_body)
	var result := LaserBeam.trace(space, get_tree(), global_position, heading, exclude, WORLD_MASK, LaserBeam.TARGET_ARC)
	var walked := _walk(result, budget)  # the path covered this frame, start to end
	var reached_end: bool = walked["reached_end"]
	var path: PackedVector2Array = walked["path"]
	var reflected: bool = walked["reflected"]

	if _sweep(space, path):
		return  # spent on the player or on a pool
	_traveled += float(walked["length"])
	global_position = path[path.size() - 1]
	heading = walked["heading"]
	_trail.append(global_position)
	if _trail.size() > TRAIL_POINTS:
		_trail.remove_at(0)
	if reflected:
		Audio.play_at(&"traps/arc_reflect", global_position, -4.0)
	if reached_end:
		_dispatch_hit(result)
		_end(true)
	elif _traveled >= max_distance:
		_end(false)
	queue_redraw()

## Walks `budget` px along the solver's polyline from its start. Returns the path covered (start, every mirror vertex
## crossed, end), its length, the heading at the end, whether the polyline ran out first (the arc reached whatever
## stopped the beam) and whether a mirror was crossed. After a vertex the arc is placed at least MIN_VERTEX_CLEARANCE
## px along the new segment (when it is that long), so the next frame's solve never starts on the mirror's plate.
func _walk(result: LaserBeam.Result, budget: float) -> Dictionary:
	var pts := result.points.duplicate()  # edited below: a crossed vertex is replaced by the point just past it
	var path := PackedVector2Array([pts[0]])
	var remaining := budget
	var length := 0.0
	var dir := heading
	var reflected := false
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		dir = (b - a) / seg
		if remaining < seg:
			path.append(a + dir * remaining)
			length += remaining
			return {"path": path, "length": length, "heading": dir, "reached_end": false, "reflected": reflected}
		# the segment is covered in full: this is the end of the beam, or a mirror vertex
		path.append(b)
		length += seg
		remaining -= seg
		if i == pts.size() - 2:
			return {"path": path, "length": length, "heading": dir, "reached_end": true, "reflected": reflected}
		reflected = true
		var next_dir := (pts[i + 2] - b).normalized()
		var advance := minf(maxf(remaining, MIN_VERTEX_CLEARANCE), b.distance_to(pts[i + 2]))
		var placed := b + next_dir * advance
		path.append(placed)
		length += advance
		remaining = maxf(remaining - advance, 0.0)
		if remaining <= 0.0:
			return {"path": path, "length": length, "heading": next_dir, "reached_end": false, "reflected": reflected}
		pts[i + 1] = placed  # the next segment now starts where the arc is
		dir = next_dir
	return {"path": path, "length": length, "heading": dir, "reached_end": true, "reflected": reflected}

## Tells whatever stopped the arc that it was struck: the optional duck-typed contract
## `on_arc_hit(point, direction)` (the Laser turret's `on_laser_hit()` for a discrete shot; `ArcReceiver` implements
## it). Called once, on the frame the arc ends on the body. A body without the method (a wall, a door, a mirror's
## back or edge) is simply an obstacle.
func _dispatch_hit(result: LaserBeam.Result) -> void:
	var target := result.end_collider
	if target != null and is_instance_valid(target) and target.has_method(&"on_arc_hit") and LaserBeam.hit_counts(result):
		target.call(&"on_arc_hit", result.end_point, result.end_direction)

## Player and water at the sample points along `path`. True when the arc was spent (it frees itself or fades).
func _sweep(space: PhysicsDirectSpaceState2D, path: PackedVector2Array) -> bool:
	var samples := 0
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var seg := a.distance_to(b)
		var steps := maxi(ceili(seg / SAMPLE_STEP), 1)
		for s in range(1, steps + 1):
			samples += 1
			if samples > MAX_SAMPLES_PER_FRAME:
				return false
			var p := a.lerp(b, float(s) / float(steps))
			if _hits_player(space, p):
				return true
			if _hits_water(p):
				return true
	return false

func _hits_player(space: PhysicsDirectSpaceState2D, point: Vector2) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = _hit_shape
	query.transform = Transform2D(0.0, point)
	query.collision_mask = PLAYER_MASK
	for hit in space.intersect_shape(query, 8):
		var body := hit.collider as Node
		if body != null and body.is_in_group(&"player"):
			if body.has_method(&"take_hit"):
				body.take_hit(damage, point)
			global_position = point
			_end(true)
			return true
	return false

## The arc's lowest point against the basin under it, as a Spark does each frame. A basin that accepts spends the arc
## (its own zap sound and ripple play); one that refuses lets the arc fly on.
func _hits_water(point: Vector2) -> bool:
	if not _manager_searched or (_manager != null and not is_instance_valid(_manager)):
		_manager_searched = true
		_manager = get_tree().get_first_node_in_group(&"water_manager")
	if _manager == null:
		return false
	var low := point + Vector2(0.0, RADIUS)
	var basin: WaterBasin = _manager.find_basin_at_point(low)
	if basin != null and basin.try_electrify_at(low):
		global_position = point
		_end(false)
		return true
	return false

## The arc is spent: a short harmless flash where it stopped. `impact` plays the fizzle sound (a wall or a hit; a
## pool has its own zap and a timed-out arc is silent).
func _end(impact: bool) -> void:
	if _fade >= 0.0:
		return
	_fade = FADE_TIME
	if impact:
		Audio.play_at(&"traps/arc_fizzle", global_position, -2.0)
	queue_redraw()

func _draw() -> void:
	var flicker := 0.8 + 0.2 * sin(_age * TAU * FLICKER_HZ)
	var life := 1.0
	if _fade >= 0.0:
		life = clampf(_fade / FADE_TIME, 0.0, 1.0)
		var r := RADIUS + (1.0 - life) * 6.0
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 16, Color(GLOW, 0.8 * life), 1.5)
		draw_circle(Vector2.ZERO, RADIUS * life, Color(CORE, life))
		return
	# jagged tail through the recent positions, kinked a little each physics frame so it crackles
	var frame := Engine.get_physics_frames()
	var previous := Vector2.ZERO
	for i in range(_trail.size() - 1, -1, -1):
		var local := to_local(_trail[i])
		var age_fraction := float(_trail.size() - 1 - i) / float(TRAIL_POINTS)
		var kink := Vector2.ZERO
		if i != _trail.size() - 1:
			var angle := float(((frame + i * 7) * 2654435761) % 1000) / 1000.0 * TAU
			kink = Vector2.from_angle(angle) * 1.6
		var q := local + kink
		if i != _trail.size() - 1:
			draw_line(previous, q, Color(GLOW, 0.7 * (1.0 - age_fraction)), 2.0)
		previous = q
	draw_circle(Vector2.ZERO, RADIUS + 1.5, Color(GLOW, 0.45 * flicker))
	draw_circle(Vector2.ZERO, RADIUS - 0.6, CORE)
