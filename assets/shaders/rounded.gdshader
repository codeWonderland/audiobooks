shader_type canvas_item;
// Rounds the corners of a (roughly square) TextureRect by discarding pixels
// outside the rounded rectangle. Used for the large cover on the player screen.

uniform float radius : hint_range(0.0, 0.5) = 0.06;

void fragment() {
	vec2 p = min(UV, vec2(1.0) - UV);       // distance to nearest edges (0..0.5)
	vec2 c = max(vec2(radius) - p, vec2(0.0));
	if (length(c) > radius) {
		discard;
	}
	COLOR = texture(TEXTURE, UV);
}
