class_name BeamTarget
extends Area2D
## The spot a receiver's beam has to reach (see "Beam targets" in laser_beam.gd). The shape decides how forgiving the
## aim is: a large shape accepts a beam that lands anywhere on it. The two exports below decide where an accepted beam
## ENDS, so the beam can be drawn into the receiver's focus without shrinking the shape and making the target harder to hit.
## Layer 4, mask 0, in the group of the kind of beam it answers (LaserBeam.TARGET_LASER / _ARC / _FREEZE).
## Authored values only; nothing writes them at run time.

## When on, the beam ends level with this node's origin (the receiver's focus: move the node to move it) instead of at the
## shape's edge: it runs on from where it touches the shape until it is as far along its direction as the origin, so an
## off-centre beam ends at the same depth as a centred one. A beam that touches the shape already past the origin ends where it touches.
@export var stop_at_centre: bool = false
## Extra distance, in px, the beam runs on past where it would otherwise end (the shape's edge, or the origin with
## `stop_at_centre`). It is not clipped to the receiver's body, so keep it small.
@export_range(0.0, 32.0, 0.5, "or_greater", "suffix:px") var extra_depth: float = 0.0
