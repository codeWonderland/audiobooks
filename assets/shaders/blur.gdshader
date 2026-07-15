shader_type canvas_item;
// Cheap separable-ish box blur used for the frosted cover backdrop on the
// player screen. Samples the control's own texture around each pixel.

uniform float radius : hint_range(0.0, 0.03) = 0.008;

void fragment() {
	vec4 sum = vec4(0.0);
	float total = 0.0;
	for (int x = -3; x <= 3; x++) {
		for (int y = -3; y <= 3; y++) {
			vec2 off = vec2(float(x), float(y)) * radius;
			sum += texture(TEXTURE, UV + off);
			total += 1.0;
		}
	}
	COLOR = sum / total;
}
