shader_type canvas_item;
// Colour filter for a distant tile layer: washes the tiles out and gives them a cool, hazy cast.
// Reds and greens are pulled toward the pixel's own grey separately (blue is left alone, so what
// remains leans blue), then a haze colour is mixed in and a multiplicative tint is applied.
// Alpha is untouched.

uniform float desaturate_red : hint_range(0.0, 1.0) = 0.3;
uniform float desaturate_green : hint_range(0.0, 1.0) = 0.3;
uniform vec4 haze_color : source_color = vec4(0.55, 0.68, 0.85, 1.0);
uniform float haze_amount : hint_range(0.0, 1.0) = 0.15;
uniform vec4 tint : source_color = vec4(0.9, 0.95, 1.0, 1.0);

void fragment() {
	vec3 rgb = COLOR.rgb; // tile texture x modulate
	float grey = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb.r = mix(rgb.r, grey, desaturate_red);
	rgb.g = mix(rgb.g, grey, desaturate_green);
	rgb = mix(rgb, haze_color.rgb, haze_amount);
	rgb *= tint.rgb;
	COLOR = vec4(rgb, COLOR.a);
}
