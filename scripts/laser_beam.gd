class_name LaserBeam
extends RefCounted
## Stateless beam solver shared by every laser turret. Call LaserBeam.trace() once per physics
## frame from the emitter; it returns the polyline the beam follows and whatever finally stopped it.
##
## How it works: each step casts a physics ray against the world (layer 2) and actors (layer 1),
## and separately tests the ray analytically against every node in group "laser_mirror". The
## nearer of the two wins. Mirrors are analytic rather than physical so the reflection normal is
## exact at any angle and a rotating mirror never depends on its collider's transform being synced
## this frame. Mirror bodies are excluded from the physics ray for the same reason.
##
## Duck-typed contracts (same convention as take_hit()/launch()):
##   mirror nodes (group "laser_mirror") expose:
##     get_laser_segment() -> PackedVector2Array   # [a, b] in world space, the reflective plate
##     get_laser_normal() -> Vector2               # world-space unit normal of the FRONT face
##     laser_body_is_physical() -> bool            # optional; true keeps the mirror's own body in the physics ray
##   Mirror bodies are normally excluded from the physics ray (the analytic plate stands in for them). A mirror whose
##   body is a real solid that must keep stopping the beam on every side but the front (the see-saw plank) answers
##   true: its analytic segment then has to sit just in front of the collider so it wins the tie on the front face.
##   Front face reflects; back face and plate edges are opaque and stop the beam. So is a beam travelling
##   PARALLEL to a plate: within EDGE_ON_SIN of its direction it never reflects, and one running along the
##   plate's own line (within EDGE_HALF_WIDTH of it) is stopped at the plate's near end instead of slipping past.
##
## Beam targets (opt-in: `target_kind`, one of TARGET_LASER / TARGET_ARC / TARGET_FREEZE; the laser turret, the arc and the
## freeze turret each pass theirs): a solid body (a receiver) may own a child Area2D on layer 4, in the group of its
## kind, that marks the spot a beam of that kind must reach to count. When the beam would end on that body, the solver
## also casts a ray against layer-4 Areas only (never against the gems, hazards and other triggers on layer 1) and
## accepts only an Area of its own kind, so a laser is not drawn into a freeze receiver. If the beam reaches the target,
## it ends there (end_collider is the owning body, end_on_target is true) and is drawn that far INTO the body (a BeamTarget's `stop_at_centre` and `extra_depth` can carry it further in, without shrinking the shape); if it
## misses, it stops on the body's surface as for any solid and end_on_target stays false. A target that sticks out of
## its body can be hit before the body. A beam with no target_kind never sees targets. Emitters tell the body it was hit
## only when `hit_counts(result)` is true (see below).
##
## Catwalks and glass (tiles whose surface_type SurfaceTypes.laser_passes() accepts, or bodies in group "catwalk")
## never stop the beam. Everything else on the mask is opaque, whether or not it can be hurt. A beam therefore reaches
## whatever lies behind glass (and burns the player there); each glass tile it crosses costs one step of MAX_STEPS.

const MAX_REFLECTIONS := 8       # mirror bounces before the beam gives up and just ends
const MAX_STEPS := 32            # total raycasts per solve, including catwalk pass-throughs
const MAX_LENGTH := 1600.0       # px a single unobstructed segment travels
const NUDGE := 0.5               # px stepped past a mirror after bouncing, so it can't re-hit itself
const PASS_NUDGE := 1.0          # px stepped past a catwalk before casting again
const DEFAULT_MASK := 3          # layer 1 (actors) | layer 2 (world)
const TARGET_MASK := 8           # layer 4: beam-target Areas (see "Beam targets" above). Nothing else sits on it.
const TARGET_LASER := &"beam_target_laser"   # group of a BeamTarget Area, per kind of beam it answers
const TARGET_ARC := &"beam_target_arc"
const TARGET_FREEZE := &"beam_target_freeze"
const EDGE_ON_SIN := 0.02        # |beam . plate normal| (the sine of the angle between beam and plate, ~1.1 deg) at or below which the beam counts as parallel to the plate: it never reflects off it, it stops
const EDGE_HALF_WIDTH := 1.5     # px, half a mirror plate's thickness: a parallel beam within this of the plate's line is blocked by it

class Result:
	var points: PackedVector2Array = PackedVector2Array()  # world-space polyline, start to end
	var end_collider: Object = null   # what stopped the beam; null if it simply ran out of length
	var end_point: Vector2 = Vector2.ZERO
	var end_direction: Vector2 = Vector2.RIGHT  # direction of travel on the final segment
	var end_on_target: bool = false   # true when the beam ended on a beam-target Area (end_collider is its owning body)

static func trace(
		space: PhysicsDirectSpaceState2D,
		tree: SceneTree,
		origin: Vector2,
		direction: Vector2,
		exclude: Array[RID] = [],
		mask: int = DEFAULT_MASK,
		target_kind: StringName = &"") -> Result:
	var result := Result.new()
	var pos := origin
	var dir := direction.normalized()
	result.points.append(pos)
	result.end_point = pos
	result.end_direction = dir

	var mirrors: Array[Node] = tree.get_nodes_in_group(&"laser_mirror")
	var excluded: Array[RID] = exclude.duplicate()
	for mirror in mirrors:
		if mirror is CollisionObject2D and not _keeps_physical_body(mirror):
			excluded.append((mirror as CollisionObject2D).get_rid())

	var reflections := 0
	for _step in MAX_STEPS:
		var to := pos + dir * MAX_LENGTH
		var query := PhysicsRayQueryParameters2D.create(pos, to, mask, excluded)
		var hit := space.intersect_ray(query)
		var physics_dist := INF
		if not hit.is_empty():
			physics_dist = pos.distance_to(hit.position)

		# beam target (opt-in): an Area on target_mask that this beam may reach, through its own body
		var target := {}
		if target_kind != &"":
			target = _find_target(space, pos, to, target_kind, hit, excluded)
		var near_dist := physics_dist
		if not target.is_empty():
			near_dist = minf(physics_dist, pos.distance_to(target.position))

		# nearest mirror plate along this ray
		var best_mirror: Node = null
		var best_t := INF
		for mirror in mirrors:
			if not mirror.has_method(&"get_laser_segment"):
				continue
			var segment: PackedVector2Array = mirror.get_laser_segment()
			var t := _ray_segment_t(pos, dir, segment[0], segment[1])
			if t > 0.001 and t < best_t and t <= MAX_LENGTH:
				best_t = t
				best_mirror = mirror

		if best_mirror != null and best_t < near_dist:
			var point := pos + dir * best_t
			result.points.append(point)
			var normal: Vector2 = best_mirror.get_laser_normal()
			if dir.dot(normal) < -EDGE_ON_SIN and reflections < MAX_REFLECTIONS:
				dir = dir.bounce(normal)
				pos = point + dir * NUDGE
				reflections += 1
				result.end_point = point
				result.end_direction = dir
				continue
			# back of a mirror, its edge, a beam parallel to it, or out of bounces: opaque
			result.end_collider = best_mirror
			result.end_point = point
			result.end_direction = dir
			return result

		if not target.is_empty():
			result.points.append(target.position)
			result.end_collider = target.host
			result.end_on_target = true
			result.end_point = target.position
			result.end_direction = dir
			return result

		if not hit.is_empty():
			if _is_passthrough(hit):
				pos = hit.position + dir * PASS_NUDGE
				# The nudge can land inside a solid (a beam clipping a catwalk's corner right under a block).
				# A ray that starts inside a shape ignores it, so the beam would travel straight through:
				# test the new start point and end the beam on whatever already contains it.
				var inside := _solid_at(space, pos, mask, excluded)
				if inside != null:
					result.points.append(pos)
					result.end_collider = inside
					result.end_point = pos
					result.end_direction = dir
					return result
				continue
			result.points.append(hit.position)
			result.end_collider = hit.collider
			result.end_point = hit.position
			result.end_direction = dir
			return result

		# nothing hit: beam runs out of length
		result.points.append(to)
		result.end_point = to
		result.end_direction = dir
		return result

	# ran out of steps (pathological pass-through chain)
	result.points.append(pos)
	result.end_point = pos
	result.end_direction = dir
	return result

## The beam-target Area this segment reaches, as {position, host}, or {} for none. The nearest Area on layer 4
## (of the beam's kind) along pos -> to counts when it comes no later than the physics hit (it sticks out of its body, or nothing solid is
## in the way) or when the physics hit is the target's own host body (the beam passes into the body to reach it).
## hit_from_inside lets a beam that already starts within the target (after a bounce) end at once.
static func _find_target(space: PhysicsDirectSpaceState2D, pos: Vector2, to: Vector2, target_kind: StringName, hit: Dictionary, excluded: Array[RID]) -> Dictionary:
	var query := PhysicsRayQueryParameters2D.create(pos, to, TARGET_MASK, excluded)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.hit_from_inside = true
	var area_hit := space.intersect_ray(query)
	if area_hit.is_empty():
		return {}
	var area := area_hit.collider as Node
	if area == null or not area.is_in_group(target_kind):
		return {}
	var host := area.get_parent()
	if host == null:
		return {}
	var area_dist := pos.distance_to(area_hit.position)
	if hit.is_empty() or area_dist <= pos.distance_to(hit.position) or hit.collider == host:
		return {"position": _target_end(area as BeamTarget, pos, to, area_hit.position), "host": host}
	return {}

## Where a beam that reached `area` at `touch` ends: the touch point, or, for a BeamTarget with `stop_at_centre` and/or
## `extra_depth`, further along the beam (never beyond the end of this segment).
static func _target_end(area: BeamTarget, pos: Vector2, to: Vector2, touch: Vector2) -> Vector2:
	if area == null or (not area.stop_at_centre and area.extra_depth <= 0.0):
		return touch
	var dir := (to - pos).normalized()
	var travel := pos.distance_to(touch)
	if area.stop_at_centre:
		travel = maxf(travel, (area.global_position - pos).dot(dir))
	travel = minf(travel + area.extra_depth, pos.distance_to(to))
	return pos + dir * travel

## Whether the body a solved beam ended on should be told it was hit. A body without a beam target (everything but a
## receiver) always is; one that has a target (it answers `get_beam_target()` with an Area) only when the beam ended on
## that target, so a beam that grazes a receiver's housing and misses its target is just stopped.
static func hit_counts(result: Result) -> bool:
	var body := result.end_collider
	if body == null or result.end_on_target:
		return body != null
	return not (body.has_method(&"get_beam_target") and body.call(&"get_beam_target") != null)

## Whether a mirror's own body stays in the physics ray (see the contract at the top): only on an explicit true.
static func _keeps_physical_body(mirror: Node) -> bool:
	return mirror.has_method(&"laser_body_is_physical") and bool(mirror.call(&"laser_body_is_physical"))

## Whether a physics collider is a world tilemap layer (group "world_tilemap"). A level may have several (ground, one-way
## ground, glass...), each with its own tileset, so the beam asks the layer it actually hit, never "the first one".
static func _is_world_tilemap(collider) -> bool:
	return collider is TileMapLayer and (collider as TileMapLayer).is_in_group(&"world_tilemap")

## Whether the beam steps past this hit: for a world tilemap layer, the tile's surface_type (SurfaceTypes.laser_passes():
## catwalk or glass), for any other body membership of group "catwalk".
static func _is_passthrough(hit: Dictionary) -> bool:
	var collider = hit.collider
	if _is_world_tilemap(collider):
		return SurfaceTypes.laser_passes(SurfaceTypes.surface_at_hit(collider, hit.position, hit.normal))
	if collider is Node:
		return (collider as Node).is_in_group(&"catwalk")
	return false

## The first opaque (non-catwalk) body whose shape contains `point`, or null. Needed because a physics ray that
## starts inside a shape does not hit it (see the pass-through step in trace()).
static func _solid_at(space: PhysicsDirectSpaceState2D, point: Vector2, mask: int, excluded: Array[RID]) -> Object:
	var query := PhysicsPointQueryParameters2D.new()
	query.position = point
	query.collision_mask = mask
	query.exclude = excluded
	for hit in space.intersect_point(query, 8):
		var collider = hit.collider
		if _is_world_tilemap(collider):
			if SurfaceTypes.laser_passes(SurfaceTypes.surface_at_point(collider, point)):
				continue
			return collider
		if collider is Node and (collider as Node).is_in_group(&"catwalk"):
			continue
		return collider
	return null

## Distance t >= 0 along the ray (origin + dir * t) to segment a-b, or -1.0 for a miss. A ray (nearly) parallel
## to the segment is not a miss when it runs along the plate: see _parallel_overlap_t().
static func _ray_segment_t(origin: Vector2, dir: Vector2, a: Vector2, b: Vector2) -> float:
	var v := b - a
	var length := v.length()
	if length < 0.0001:
		return -1.0
	var best := -1.0
	var denom := dir.cross(v)
	if absf(denom) >= 0.000001:
		var ao := a - origin
		var t := ao.cross(v) / denom
		var u := ao.cross(dir) / denom
		if t >= 0.0 and u >= 0.0 and u <= 1.0:
			best = t
	if absf(denom) / length < EDGE_ON_SIN:
		var edge_t := _parallel_overlap_t(origin, dir, a, b)
		if edge_t >= 0.0 and (best < 0.0 or edge_t < best):
			best = edge_t
	return best

## For a ray roughly parallel to segment a-b: where it first meets the plate if the plate comes within
## EDGE_HALF_WIDTH of the ray's line and lies ahead of the origin, else -1.0. The distance is to the plate's
## nearer end along the ray (0.002 if the origin is already within the plate's extent).
static func _parallel_overlap_t(origin: Vector2, dir: Vector2, a: Vector2, b: Vector2) -> float:
	var ta := (a - origin).dot(dir)
	var tb := (b - origin).dot(dir)
	if maxf(ta, tb) <= 0.001:
		return -1.0  # the plate is behind the origin
	var la := dir.cross(a - origin)  # signed sideways offsets of the plate's ends from the ray's line
	var lb := dir.cross(b - origin)
	if minf(la, lb) > EDGE_HALF_WIDTH or maxf(la, lb) < -EDGE_HALF_WIDTH:
		return -1.0  # passes beside the plate, not along it
	return maxf(minf(ta, tb), 0.002)
