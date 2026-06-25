shader_type canvas_item;

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength : hint_range(0.0, 5.0) = 1.0;
uniform vec2 vertex_scale_xy = vec2(2.0, 2.0);
uniform float blur_radius : hint_range(0.0, 120.0, 0.5) = 10.0;
uniform float spread : hint_range(0.0, 1.0) = 0.0;

// --- Projected (cast) shadow ---
uniform float proj_enabled = 0.0;
uniform vec2  proj_dir      = vec2(0.0, 1.0); // direction locale, normalisée
uniform float proj_length   = 0.0;            // intensité de l'allongement
uniform vec2  proj_anchor   = vec2(0.0);      // pivot, en px (centre texture = 0,0)
uniform float proj_taper    = 0.0;            // >0 = pointe affinée, <0 = élargie
uniform vec2  proj_tex_size = vec2(1.0);      // taille texture px (pour px<->uv)
uniform float proj_fade     = 0.0;            // estompe l'ombre vers la pointe (0..1)
uniform float proj_extrude  = 0.0;            // 0 = stretch (étire), 1 = extrude (balaye)
uniform vec2  cut_offset    = vec2(0.0);      // asset-uv shift for the under-asset cut (offset mode; 0 in projected)
uniform int blur_quality : hint_range(2, 16) = 8;
uniform int blur_steps : hint_range(8, 48) = 24;

uniform vec2 sprite_world_pos = vec2(0.0);
uniform float sprite_world_rot = 0.0;
uniform vec2 sprite_world_scale = vec2(1.0);
uniform vec2 obj_world_pos = vec2(0.0);
uniform float shadow_clip_radius = 200.0;
uniform sampler2D poly_data_tex;
uniform int poly_data_size = 0;

uniform int poly_count = 0;

uniform vec4 poly_def0 = vec4(0.0);
uniform vec4 poly_def1 = vec4(0.0);
uniform vec4 poly_def2 = vec4(0.0);
uniform vec4 poly_def3 = vec4(0.0);
uniform vec4 poly_def4 = vec4(0.0);
uniform vec4 poly_def5 = vec4(0.0);
uniform vec4 poly_def6 = vec4(0.0);
uniform vec4 poly_def7 = vec4(0.0);



varying vec2 v_scale;
varying vec2 v_scaled_vertex;

void vertex() {
    v_scale = vertex_scale_xy;
    VERTEX *= mat2(vec2(v_scale.x, 0.0), vec2(0.0, v_scale.y));
    v_scaled_vertex = VERTEX;
}

vec2 vertex_to_world(vec2 sv) {
    vec2 scaled = sv * sprite_world_scale;
    float c = cos(sprite_world_rot);
    float s = sin(sprite_world_rot);
    return vec2(scaled.x*c - scaled.y*s, scaled.x*s + scaled.y*c) + sprite_world_pos;
}

vec2 get_point(int idx) {
    if (poly_data_size <= 0) return vec2(0.0);
    float u = (float(idx) + 0.5) / float(poly_data_size);
    vec4 d = texture(poly_data_tex, vec2(u, 0.25));
    return vec2(d.r, d.g);
}

vec2 get_normal(int idx) {
    if (poly_data_size <= 0) return vec2(0.0);
    float u = (float(idx) + 0.5) / float(poly_data_size);
    vec4 d = texture(poly_data_tex, vec2(u, 0.75));
    return vec2(d.r, d.g);
}

vec4 get_def(int idx) {
    if (idx == 0) return poly_def0;
    if (idx == 1) return poly_def1;
    if (idx == 2) return poly_def2;
    if (idx == 3) return poly_def3;
    if (idx == 4) return poly_def4;
    if (idx == 5) return poly_def5;
    if (idx == 6) return poly_def6;
    if (idx == 7) return poly_def7;
    return vec4(0.0);
}

float check_polyline(vec2 world_pos, vec4 def, int normal_start) {
    // For CLOSED polylines: returns crossing count (for parity test).
    // For OPEN polylines: returns -1.0 if ANY segment is crossed (simple block).
    int start = int(def.x);
    int count = int(def.y);
    bool is_closed = def.z > 1.5;
    if (count < 2) return 0.0;

    vec2 ray_o = obj_world_pos;
    vec2 ray_d = world_pos - obj_world_pos;
    float crossings = 0.0;

    for (int i = 0; i < 255; i++) {
        if (i >= count - 1) break;
        vec2 a = get_point(start + i);
        vec2 b = get_point(start + i + 1);
        vec2 seg_d = b - a;

        float denom = ray_d.x * seg_d.y - ray_d.y * seg_d.x;
        if (abs(denom) < 0.001) continue;

        vec2 d = a - ray_o;
        float t = (d.x * seg_d.y - d.y * seg_d.x) / denom;
        float u = (d.x * ray_d.y - d.y * ray_d.x) / denom;

        if (t > 0.001 && t < 1.0 && u > 0.0 && u < 1.0) {
            if (!is_closed) return -1.0;
            crossings += 1.0;
        }
    }
    return crossings;
}

// Source alpha at a UV. Stretch mode: plain texture lookup (uv is pre-warped by
// the inverse-map in fragment()). Extrude mode: directional sweep — light this
// point if the silhouette covers any point back along -proj_dir within length,
// with a per-distance fade. Side edges of the swept tail are parallel to the
// light direction, which is what a real cast shadow does (clean on boxes).
uniform int extrude_steps = 18;
float src_alpha(sampler2D tex, vec2 p) {
    float m = 0.0;
    if (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
        m = texture(tex, p).a;
    }
    if (proj_enabled > 0.5 && proj_extrude > 0.5 && proj_length > 0.01) {
        float fsteps = float(extrude_steps);
        float total_px = proj_length * max(proj_tex_size.x, proj_tex_size.y);
        float step_px = total_px / fsteps;
        vec2 duv = (proj_dir * step_px) / proj_tex_size;
        for (int s = 1; s <= 64; s++) {
            if (s > extrude_steps) break;
            vec2 q = p - duv * float(s);
            if (q.x >= 0.0 && q.x <= 1.0 && q.y >= 0.0 && q.y <= 1.0) {
                float w = 1.0 - proj_fade * (float(s) / fsteps);
                m = max(m, texture(tex, q).a * w);
            }
        }
    }
    return m;
}

void fragment() {
    if (poly_count > 0) {
        vec2 world_pos = vertex_to_world(v_scaled_vertex);
        int ns = 0;
        float total_crossings = 0.0;
        bool blocked = false;
        for (int i = 0; i < 8; i++) {
            if (i >= poly_count) break;
            vec4 def = get_def(i);
            float result = check_polyline(world_pos, def, ns);
            if (result < -0.5) {
                blocked = true;
            } else {
                total_crossings += result;
            }
            ns += int(def.y) - 1;
        }
        if (blocked) discard;
        int ic = int(total_crossings);
        if (ic == 1 || ic == 3 || ic == 5 || ic == 7) {
            discard;
        }
    }

    vec2 uv = UV * v_scale;
    uv -= (v_scale - vec2(1.0)) * 0.5;

    // Discard the shadow under the asset (it would be hidden anyway, and this keeps
    // it from showing through transparent parts of the asset). The mask is eroded
    // ~2px so the shadow still tucks a couple of pixels under the asset edge for a
    // seamless junction. Runs before the blur loop, so these pixels skip the blur.
    // Offset mode: the shadow sprite is displaced, so the asset alpha that overlaps
    // this fragment lives at uv + cut_offset. Projected: cut_offset is 0 (co-located).
    {
        vec2 cuv = uv + cut_offset;
        float er_a = 0.0;
        if (cuv.x >= 0.0 && cuv.x <= 1.0 && cuv.y >= 0.0 && cuv.y <= 1.0)
            er_a = texture(TEXTURE, cuv).a;
        vec2 er = 2.0 * TEXTURE_PIXEL_SIZE;
        for (int k = 0; k < 6; k++) {
            float ang = 6.28318 * float(k) / 6.0;
            vec2 su = cuv + vec2(cos(ang), sin(ang)) * er;
            float sa = 0.0;
            if (su.x >= 0.0 && su.x <= 1.0 && su.y >= 0.0 && su.y <= 1.0)
                sa = texture(TEXTURE, su).a;
            er_a = min(er_a, sa);
        }
        if (er_a >= 0.5) discard;
    }

    // Projected (cast) shadow: instead of moving geometry, we inverse-map each
    // fragment back into the source texture. The displacement is purely along
    // proj_dir, so the perpendicular component is preserved; the along component
    // is compressed by (1+length) on the projection side (a>0). proj_taper scales
    // the perpendicular width with distance (>0 narrows the tip). This keeps the
    // "part stays under the asset" region (a<0) untouched with no quad twist.
    float proj_fade_mul = 1.0;
    if (proj_enabled > 0.5 && proj_extrude < 0.5) {
        vec2 frag_px = (uv - 0.5) * proj_tex_size;
        vec2 perp = vec2(-proj_dir.y, proj_dir.x);
        vec2 rel = frag_px - proj_anchor;
        float a = dot(rel, proj_dir);
        float b = dot(rel, perp);
        float a_src = a;
        float b_src = b;
        if (a > 0.0) {
            a_src = a / (1.0 + proj_length);
            float half_extent = 0.5 * max(proj_tex_size.x, proj_tex_size.y);
            float wf = 1.0 + proj_taper * clamp(a_src / half_extent, 0.0, 4.0);
            wf = max(wf, 0.05);
            b_src = b * wf;
            // Distance fade: estompe vers la pointe le long de la projection.
            if (proj_fade > 0.001 && proj_length > 0.01) {
                float fade_ref = proj_length * max(proj_tex_size.x, proj_tex_size.y);
                float frac = clamp(a / fade_ref, 0.0, 1.0);
                proj_fade_mul = 1.0 - proj_fade * frac;
            }
        }
        vec2 t = proj_anchor + proj_dir * a_src + perp * b_src;
        uv = t / proj_tex_size + 0.5;
    }

    float pi2 = 6.28318;
    vec2 r = blur_radius * TEXTURE_PIXEL_SIZE;
    float total = 0.0;
    float weight_sum = 0.0;

    total += src_alpha(TEXTURE, uv);
    weight_sum += 1.0;

    for (int d = 0; d < blur_steps; d++) {
        float angle = pi2 * float(d) / float(blur_steps);
        vec2 dir = vec2(cos(angle), sin(angle));
        for (int i = 1; i <= blur_quality; i++) {
            float frac = float(i) / float(blur_quality);
            vec2 sample_uv = uv + dir * r * frac;
            // Softer Gaussian: exp(-1.2 * frac^2) gives more weight to distant samples
            float w = exp(-1.2 * frac * frac);
            total += src_alpha(TEXTURE, sample_uv) * w;
            weight_sum += w;
        }
    }

    float raw_alpha = total / weight_sum;
    float alpha;
    if (spread > 0.001) {
        // Gentle spread: keeps shadow soft even at high blur
        float exponent = mix(1.0, 0.35, spread * spread);
        alpha = pow(clamp(raw_alpha, 0.0, 1.0), exponent);
    } else {
        alpha = raw_alpha;
    }
    alpha = clamp(alpha * shadow_strength * proj_fade_mul, 0.0, 1.0);
    COLOR = vec4(shadow_color.rgb, alpha);
}
