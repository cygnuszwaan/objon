@tool
extends Node2D

# Placeholder art for rail_bot.tscn, plain shapes drawn in code until the bot's sprites exist. Drawn around the bot's
# origin, which is the point on the rail: a trolley wheel there, a short stem, and the body hanging 4 to 12 px below it
# (the body collider is the 12x8 box at (0, 8)), with the spark nozzle underneath. Not mirrored.
#  - the nozzle glows and grows over the TELEGRAPH seconds before each drip (`charge` 0 to 1): that is the warning;
#  - when unpowered the bot greys out and the nozzle is dark.
# Replace with an AnimatedSprite2D when there is art; RailBot only needs `set_pose(charge, powered)` to exist, and
# skips it when it doesn't.

const HULL := Color(0.42, 0.48, 0.58)
const HULL_OFF := Color(0.36, 0.37, 0.4)
const EDGE := Color(0.14, 0.17, 0.22)
const STRIPE := Color(0.95, 0.8, 0.2)
const WHEEL := Color(0.14, 0.16, 0.2)
const NOZZLE_DARK := Color(0.2, 0.2, 0.22)
const GLOW_COLD := Color(1.0, 0.55, 0.15)
const GLOW_HOT := Color(1.0, 0.97, 0.75)

var charge := 0.0
var powered := true

func set_pose(new_charge: float, is_powered: bool) -> void:
	if is_powered == powered and is_equal_approx(new_charge, charge):
		return
	charge = new_charge
	powered = is_powered
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 3.0, WHEEL)  # trolley wheel on the rail
	draw_rect(Rect2(-1.0, 2.0, 2.0, 3.0), EDGE)  # stem
	var body := Rect2(-6.0, 4.0, 12.0, 8.0)
	draw_rect(body, HULL if powered else HULL_OFF)
	draw_rect(Rect2(-6.0, 6.0, 12.0, 2.0), STRIPE if powered else HULL_OFF.darkened(0.2))
	draw_rect(body, EDGE, false, 1.0)
	draw_rect(Rect2(-1.5, 12.0, 3.0, 2.0), NOZZLE_DARK)  # nozzle
	if powered and charge > 0.0:
		draw_circle(Vector2(0.0, 13.5), 1.0 + 2.5 * charge, GLOW_COLD.lerp(GLOW_HOT, charge))
