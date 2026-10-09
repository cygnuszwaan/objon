class_name LiquidSkin
extends RefCounted
## Art for the top of a settled liquid or crust: a vertical strip of 16x16 frames that is one tile tall and
## tileable sideways only. WaterBasin draws it as the surface layer and fills everything deeper with the
## colour of the art's own bottom row, so any depth of liquid can be built from one tile of art.
##
## Everything is read from the texture, so swapping the art needs no code change:
##   - `frame_count`   the strip's height / 16.
##   - `headroom`      the fully transparent rows at the top of every frame (the most that all frames share).
##                     The surface line sits at the first opaque row; the headroom is never drawn.
##   - `visible_rows`  16 - headroom: how much of a frame is drawn below the surface line.
##   - `bottom_color(frame)`  the average colour of that frame's last row, used for the body below the skin.
##   - `neutral_color(frame)`  (crust art only, see `cut_fringe`) the average colour of the frame's neutral pixels.
##   - `backed_texture`  (crust art only, see `cut_fringe`) the cut art with its interior fringe filled neutral, for a crust over a void.
## `fps` > 0 animates through the frames (the basin advances the clock); 0 means the basin picks frames itself.

const TILE := 16
const NEUTRAL_ROWS := 4  # the rows from a frame's first opaque row whose colours define that frame's neutral palette (see cut_fringe)

var texture: Texture2D
var backed_texture: Texture2D  # == texture unless built with cut_fringe
var fps: float = 0.0
var frame_count: int = 1
var headroom: int = 0
var visible_rows: int = TILE
var _bottom_colors: Array[Color] = []
var _neutral_colors: Array[Color] = []

## `cut_fringe` is for crust art, whose frames carry the colour of the liquid that solidified at their edges (the whole bottom
## row, and a scatter of hot pixels that creeps up the frame as it cools). Per frame, the colours found in its first
## NEUTRAL_ROWS opaque rows are its neutral palette; every other opaque pixel is fringe and is made transparent, so whatever
## is drawn behind the crust shows through: the liquid's own colour while it still touches the crust, or, over a void, the
## crust's own neutral colour for the fringe inside the crust and nothing at all for the fringe that forms its underside.
## The art file is untouched; `texture` becomes the cut copy (fringe transparent, drawn over liquid) and `backed_texture` the
## cut copy with the interior fringe filled neutral (drawn over a void).
func _init(p_texture: Texture2D, p_fps: float = 0.0, cut_fringe: bool = false) -> void:
	texture = p_texture
	backed_texture = p_texture
	fps = p_fps
	frame_count = maxi(1, floori(float(texture.get_height()) / TILE))
	var image := texture.get_image()
	if image == null:
		push_warning("LiquidSkin: couldn't read pixels from %s (use a lossless import)" % texture.resource_path)
		for _f in frame_count:
			_bottom_colors.append(Color.MAGENTA)
		return
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	headroom = TILE
	var first_opaque_rows: Array[int] = []
	for f in frame_count:
		var first_opaque := TILE
		for y in TILE:
			if _row_has_alpha(image, f * TILE + y):
				first_opaque = y
				break
		first_opaque_rows.append(first_opaque)
		headroom = mini(headroom, first_opaque)
		_bottom_colors.append(_row_average(image, f * TILE + TILE - 1))
	if headroom >= TILE:
		headroom = 0
	visible_rows = TILE - headroom
	if cut_fringe:
		_cut_fringe(image, first_opaque_rows)

func _cut_fringe(image: Image, first_opaque_rows: Array[int]) -> void:
	var cut: Image = image.duplicate()
	var backed: Image = image.duplicate()
	var width := mini(image.get_width(), TILE)
	for f in frame_count:
		var palette := {}  # Color.to_rgba32() -> true
		var first := first_opaque_rows[f]
		for y in range(first, mini(first + NEUTRAL_ROWS, TILE)):
			for x in width:
				var c := image.get_pixel(x, f * TILE + y)
				if c.a > 0.0:
					palette[c.to_rgba32()] = true
		var sum := Color(0, 0, 0, 0)
		var count := 0
		var last_neutral: Array[int] = []  # per column: the lowest row holding a neutral pixel, -1 if none
		last_neutral.resize(width)
		last_neutral.fill(-1)
		for y in TILE:
			for x in width:
				var c := image.get_pixel(x, f * TILE + y)
				if c.a <= 0.0:
					continue
				if palette.has(c.to_rgba32()):
					sum += c
					count += 1
					last_neutral[x] = y
		# The fill is rounded to 8 bits so the pixels baked below and a flat rect drawn in `neutral_color()` match exactly.
		var neutral := Color.MAGENTA
		if count > 0:
			neutral = Color8(roundi(sum.r / count * 255.0), roundi(sum.g / count * 255.0), roundi(sum.b / count * 255.0))
		_neutral_colors.append(neutral)
		for y in TILE:
			for x in width:
				var c := image.get_pixel(x, f * TILE + y)
				if c.a <= 0.0 or palette.has(c.to_rgba32()):
					continue
				cut.set_pixel(x, f * TILE + y, Color(0, 0, 0, 0))
				# Fringe with a neutral pixel somewhere below it in its column is inside the crust: backed neutral. Fringe
				# below a column's last neutral pixel is the molten edge of the underside: it stays transparent, so a crust
				# over a void ends where its neutral pixels end instead of in a flat line one or two rows lower.
				if y >= last_neutral[x]:
					backed.set_pixel(x, f * TILE + y, Color(0, 0, 0, 0))
				else:
					backed.set_pixel(x, f * TILE + y, neutral)
	texture = ImageTexture.create_from_image(cut)
	backed_texture = ImageTexture.create_from_image(backed)

## The average colour of a frame's neutral pixels (crust art only; magenta if the skin was not built with `cut_fringe`).
func neutral_color(frame: int) -> Color:
	if _neutral_colors.is_empty():
		return Color.MAGENTA
	return _neutral_colors[clampi(frame, 0, _neutral_colors.size() - 1)]

func bottom_color(frame: int) -> Color:
	return _bottom_colors[clampi(frame, 0, _bottom_colors.size() - 1)]

static func _row_has_alpha(image: Image, y: int) -> bool:
	for x in mini(image.get_width(), TILE):
		if image.get_pixel(x, y).a > 0.0:
			return true
	return false

static func _row_average(image: Image, y: int) -> Color:
	var sum := Color(0, 0, 0, 0)
	var count := 0
	for x in mini(image.get_width(), TILE):
		var c := image.get_pixel(x, y)
		if c.a > 0.0:
			sum += c
			count += 1
	if count == 0:
		return Color.MAGENTA
	return Color(sum.r / count, sum.g / count, sum.b / count, 1.0)
