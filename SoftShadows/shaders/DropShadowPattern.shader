shader_type canvas_item;

// Realistic pattern shadow: exact signed distance to the pattern polygon,
// evaluated per fragment, turned into a smooth (gaussian-like) alpha falloff.
// No viewport, no mipmaps — fully synchronous and live.
//
// All distances are in the quad's LOCAL space (= shape-local units).

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity : hint_range(0.0, 2.0) = 0.5;   // > 1 pushes the fade toward full darkness
uniform float blur_radius = 24.0;   // half-width of the fade band (local units)
uniform float spread = 0.0;         // uniform outward growth (local units)
uniform sampler2D poly_data_tex;    // row 0: polygon points (x in R, y in G)
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
    if (poly_count < 3) {
        COLOR = vec4(0.0);
    } else {
        vec2 p = v_local;
        float d2 = 1e20;
        bool inside = false;
        vec2 a = get_point(poly_count - 1);
        for (int i = 0; i < poly_count; i++) {
            vec2 b = get_point(i);
            // distance to segment a-b
            vec2 e = b - a;
            vec2 w = p - a;
            float t = clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
            vec2 q = w - e * t;
            d2 = min(d2, dot(q, q));
            // crossing-number inside test
            if ((a.y > p.y) != (b.y > p.y)) {
                float x = a.x + (p.y - a.y) * e.x / e.y;
                if (p.x < x) {
                    inside = !inside;
                }
            }
            a = b;
        }
        float sd = sqrt(d2);
        if (inside) {
            sd = -sd;
        }
        sd -= spread;
        float alpha;
        if (blur_radius < 0.5) {
            alpha = sd <= 0.0 ? 1.0 : 0.0;
        } else {
            // Wide smooth fade (2*blur) whose centre sits slightly INSIDE the
            // edge: ~84% opacity right at the edge (a fade centred exactly on
            // the edge would halve it where the shadow becomes visible), then a
            // long soft tail outside. EDGE_BIAS 0.5 = centred, 1.0 = fully outside.
            const float EDGE_BIAS = 0.75;
            float t = clamp(EDGE_BIAS - sd / (2.0 * blur_radius), 0.0, 1.0);
            alpha = t * t * (3.0 - 2.0 * t);
        }
        COLOR = vec4(shadow_color.rgb, min(alpha * opacity, 1.0));
    }
}
