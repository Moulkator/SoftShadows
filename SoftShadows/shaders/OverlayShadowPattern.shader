shader_type canvas_item;

// Overlay (inner) shadow for patterns: a shadow band starts from the edges
// that face the sun and fades toward the inside of the polygon (the pattern
// is read as a lowered floor: its rim casts a shadow onto the floor below).
// Drawn on a Polygon2D holding the pattern's own polygon, so it is already
// clipped to the pattern — the shader only needs the distance to each edge.
//
// Distances are in the polygon's LOCAL space.

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.5;
uniform float band_width = 64.0;                        // local units
uniform float diffusion : hint_range(0.0, 1.0) = 0.5;   // softness of the inner edge of the band
uniform float curve : hint_range(-2.0, 2.0) = 0.0;      // falloff shape (- hollow / + bulged)
uniform vec2 local_sun = vec2(0.0, 1.0);                // sun direction in polygon-local space
uniform float sun_strength : hint_range(0.0, 1.0) = 1.0; // 0 = sun from above (all edges), 1 = fully directional
uniform float raised = 0.0;                             // 0 = lowered (band on sun-facing edges), 1 = raised (band on edges away from the sun)
uniform float winding = 1.0;                            // +1 / -1: sign making (dy, -dx) the outward normal
uniform sampler2D poly_data_tex;                        // row 0: polygon points (x in R, y in G)
uniform int poly_count = 0;

varying vec2 v_local;

vec2 get_point(int idx) {
    float u = (float(idx) + 0.5) / float(poly_count);
    vec4 d = texture(poly_data_tex, vec2(u, 0.5));
    return vec2(d.r, d.g);
}

void vertex() {
    v_local = VERTEX;
}

void fragment() {
    float best = 0.0;
    if (poly_count >= 3 && band_width > 0.001) {
        vec2 sun = normalize(local_sun) * (raised > 0.5 ? -1.0 : 1.0);
        vec2 p = v_local;
        vec2 a = get_point(poly_count - 1);
        float band_in = clamp(1.0 - diffusion, 0.0, 0.999);
        float k = pow(2.0, curve);
        for (int i = 0; i < poly_count; i++) {
            vec2 b = get_point(i);
            vec2 e = b - a;
            float el = length(e);
            if (el > 0.0001) {
                vec2 n_out = vec2(e.y, -e.x) / el * winding;
                float w = mix(1.0, max(dot(n_out, sun), 0.0), sun_strength);
                if (w > 0.0) {
                    vec2 wv = p - a;
                    float t = clamp(dot(wv, e) / (el * el), 0.0, 1.0);
                    float dist = length(wv - e * t);
                    float u = dist / band_width;
                    float f = 1.0 - smoothstep(band_in, 1.0, u);
                    f = pow(max(f, 0.0), k);
                    best = max(best, w * f);
                }
            }
            a = b;
        }
    }
    COLOR = vec4(shadow_color.rgb, best * opacity);
}
