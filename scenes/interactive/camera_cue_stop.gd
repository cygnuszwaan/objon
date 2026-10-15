@tool
class_name CameraCueStop
extends Node2D
## One stop of a multi-stop `CameraCue`: a point the camera pans to, holds on and leaves for the next stop. Make it a
## direct child of the cue; the cue plays its stops in tree order, then the camera returns to the player. The node
## origin is the point to look at (the cue's own origin is not a stop once it has any). It has no collision and no art
## at run time.
##
## Each stop carries its own timing, zoom and speed of time, so a cue can say "slow the game, close on the cause,
## then on the effect": `pan_time` is the camera's move from wherever it is to this point, `hold_time` the wait on
## it, `zoom` the camera zoom multiplier while it is there (1 leaves it alone, above 1 closes in, below 1 shows more),
## and `time_scale` how fast the world runs from the start of the pan until the next stop starts (see TIME in
## `camera_cue.gd`). The cue's own `pan_time`, `hold_time`, `zoom` and `frame_player` are not used once it has stops;
## its `return_time`, `ease_curve`, `delay`, `once` and `cooldown` still are.
##
## `releases_pass_through` makes the cue's pass-through (what a door or a spike layer wired to the cue waits on) rise
## the moment the camera arrives at this stop and holds, so the thing it drives happens while the camera is on it.
## With no stop marked, the first stop releases it. More than one marked: the first of them does.
##
## AUTHORING: draws the view rectangle at this stop's zoom, numbered in play order, while `authoring_overlay` is set
## (a plain variable the editor sets in `_ready()`, not an `Engine.is_editor_hint()` test).

## Seconds the camera takes to move here from where it is.
@export_range(0.0, 5.0, 0.05, "or_greater") var pan_time: float = 0.6
## Seconds the camera stays here.
@export_range(0.0, 10.0, 0.05, "or_greater") var hold_time: float = 1.0
## Camera zoom multiplier while here: 1 leaves it alone, 2 shows half as much of the level, 0.5 twice as much.
@export_range(0.1, 4.0, 0.05) var zoom: float = 1.0:
	set(value):
		zoom = value
		queue_redraw()
## How fast the world runs from the start of the pan to this stop until the next stop starts (1 = normal, 0.1 = a tenth
## speed). The last stop's value eases back to 1 over the cue's `return_time`. Cue time itself always runs in real time.
@export_range(0.05, 1.0, 0.05) var time_scale: float = 1.0
## The cue's pass-through rises when the camera arrives here.
@export var releases_pass_through: bool = false:
	set(value):
		releases_pass_through = value
		queue_redraw()

const VIEW_SIZE := Vector2(512.0, 288.0)  ## What the camera sees at zoom 1: the 1280x720 viewport at the base zoom 2.5.
const OVERLAY_COLOR := Color(0.45, 0.9, 1.0, 0.85)
const RELEASE_COLOR := Color(1.0, 0.55, 0.3, 0.9)

var authoring_overlay: bool = false  ## Draws the view rectangle. Set in `_ready()` in the editor; a runtime level editor can set it too.

func _ready() -> void:
	authoring_overlay = Engine.is_editor_hint()
	set_notify_local_transform(authoring_overlay)
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED or what == NOTIFICATION_PARENTED or what == NOTIFICATION_MOVED_IN_PARENT:
		var parent := get_parent()
		if parent != null and authoring_overlay:
			parent.queue_redraw()  # the cue draws the path through its stops
		queue_redraw()

## The position of this stop among its cue's stops (0 = first), the order it plays in.
func get_stop_index() -> int:
	var index := 0
	var parent := get_parent()
	if parent == null:
		return 0
	for child in parent.get_children():
		if child == self:
			return index
		if child is CameraCueStop:
			index += 1
	return index

func _draw() -> void:
	if not authoring_overlay:
		return
	var color := RELEASE_COLOR if releases_pass_through else OVERLAY_COLOR
	var view := VIEW_SIZE / maxf(zoom, 0.05)
	draw_rect(Rect2(-view * 0.5, view), color, false, 1.0)
	draw_line(Vector2(-4, 0), Vector2(4, 0), color, 1.0)
	draw_line(Vector2(0, -4), Vector2(0, 4), color, 1.0)
	var label := str(get_stop_index() + 1) + ("  release" if releases_pass_through else "")
	draw_string(ThemeDB.fallback_font, -view * 0.5 + Vector2(3, 11), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
