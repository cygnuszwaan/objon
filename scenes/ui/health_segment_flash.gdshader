shader_type canvas_item;
// Blends a segment's own pixels toward white by `flash` (0 = untouched, 1 = fully white). It only changes colour,
// never position or size, so the art's dark divider pixels and shaded rows stay exactly where they were drawn
// and merely get lighter along with the rest. Alpha is untouched.
uniform float flash : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(mix(c.rgb, vec3(1.0), flash), c.a);
}
