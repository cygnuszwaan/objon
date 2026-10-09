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
## Catwalks and glass (tiles whose surface_type SurfaceTypes.laser_passes() accepts, or bodies in group "catwalk")
## never stop the beam. Everything else on the mask is opaque, whether or not it can be hurt. A beam therefore reaches
## whatever lies behind glass (and burns the player there); each glass tile it crosses costs one step of MAX_STEPS.

const MAX_REFLECTIONS := 8       # mirror bounces before the beam gives up and just ends
const MAX_STEPS := 32            # total raycasts per solve, including catwalk pass-throughs
const MAX_LENGTH := 1600.0       # px a single unobstructed segment travels
const NUDGE := 0.5               # px stepped past a mirror after bouncing, so it can't re-hit itself
const PASS_NUDGE := 1.0          # px stepped past a catwalk before casting again
const DEFAULT_MASK := 3          # layer 1 (actors) | layer 2 (world)
const EDGE_ON_SIN := 0.02        # |beam . plate normal| (the sine of the angle between beam and plate, ~1.1 deg) at or below which the beam counts as parallel to the plate: it never reflects off it, it stops
const EDGE_HALF_WIDTH := 1.5     # px, half a mirror plate's thickness: a parallel beam within this of the plate's line is blocked by it

class Result:
	var points: PackedVector2Array = PackedVector2Array()  # world-space polyline, start to end
	var end_collider: Object = null   # what stopped the beam; null if it simply ran out of length
	var end_point: Vector2 = Vector2.ZERO
	var end_direction: Vector2 = Vector2.RIGHT  # direction of travel on the final segment

static func trace(
		space: PhysicsDirectSpaceState2D,
		tree: SceneTree,
		origin: Vector2,
		direction: Vector2,
		exclude: Array[RID] = [],
		mask: int = DEFAULT_MASK) -> Result:
	var result := Result.new()
	var pos := origin
	var dir := direction.normalized()
	result.points.append(pos)
	result.end_point = pos
	result.end_direction = dir

	var world_tilemap := tree.get_first_node_in_group(&"world_tilemap") as TileMapLayer
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

		if best_mirror != null and best_t < physics_dist:
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

		if not hit.is_empty():
			if _is_passthrough(hit, world_tilemap):
				pos = hit.position + dir * PASS_NUDGE
				# The nudge can land inside a solid (a beam clipping a catwalk's corner right under a block).
				# A ray that starts inside a shape ignores it, so the beam would travel straight through:
				# test the new start point and end the beam on whatever already contains it.
				var inside := _solid_at(space, pos, mask, excluded, world_tilemap)
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

## Whether a mirror's own body stays in the physics ray (see the contract at the top): only on an explicit true.
static func _keeps_physical_body(mirror: Node) -> bool:
	return mirror.has_method(&"laser_body_is_physical") and bool(mirror.call(&"laser_body_is_physical"))

## Whether the beam steps past this hit: for the world tilemap, the tile's surface_type (SurfaceTypes.laser_passes():
## catwalk or glass), for any other body membership of group "catwalk".
static func _is_passthrough(hit: Dictionary, world_tilemap: TileMapLayer) -> bool:
	var collider = hit.collider
	if world_tilemap != null and collider == world_tilemap:
		return SurfaceTypes.laser_passes(SurfaceTypes.surface_at_hit(world_tilemap, hit.position, hit.normal))
	if collider is Node:
		return (collider as Node).is_in_group(&"catwalk")
	return false

## The first opaque (non-catwalk) body whose shape contains `point`, or null. Needed because a physics ray that
## starts inside a shape does not hit it (see the pass-through step in trace()).
static func _solid_at(space: PhysicsDirectSpaceState2D, point: Vector2, mask: int, excluded: Array[RID], world_tilemap: TileMapLayer) -> Object:
	var query := PhysicsPointQueryParameters2D.new()
	query.position = point
	query.collision_mask = mask
	query.exclude = excluded
	for hit in space.intersect_point(query, 8):
		var collider = hit.collider
		if world_tilemap != null and collider == world_tilemap:
			if SurfaceTypes.laser_passes(SurfaceTypes.surface_at_point(world_tilemap, point)):
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
