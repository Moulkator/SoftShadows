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
// Quad centre in LOCAL px (before scaling). For a centred sprite this is its
// `offset`; for a non-centred one, offset + tex_size/2. The vertex expansion is
// anchored here instead of the local origin: the fragment UV remap assumes the
// expansion is symmetric about the TEXTURE centre, which only holds when the
// quad centre is the anchor. Scaling about the origin displaced the whole
// shadow (body AND under-asset cut) by (v_scale-1)*offset for sprites with a
// non-zero offset — the cut hole peeked out from one side of the asset, growing
// with the projected distance (v_scale grows with proj_length).
uniform vec2 quad_center_px = vec2(0.0);
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
    VERTEX = quad_center_px + (VERTEX - quad_center_px) * vec2(v_scale.x, v_scale.y);
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

// --- Free Transform (Unofficial Patch) warp support -------------------------
// When FT distorts/perspectives the parent asset (a bilinear corner warp done
// in the asset's own material), the shadow must show the WARPED silhouette.
// The blur / projection / extrude geometry stays in the un-warped quad space;
// only the silhouette lookups are inverse-mapped through the warp, per sample.
// Params are fed by DropShadowObjects.gd from FT's published corner data
// (ModMapData["_ft_distort"], corners in the sprite's local px, +/-real_size/2
// space). ft_warp_enabled = 0.0 keeps behavior identical to the previous
// version of this shader.
uniform float ft_warp_enabled = 0.0;
uniform vec2 ft_corner_tl = vec2(0.0);
uniform vec2 ft_corner_tr = vec2(0.0);
uniform vec2 ft_corner_br = vec2(0.0);
uniform vec2 ft_corner_bl = vec2(0.0);
uniform vec2 ft_tex_size = vec2(1.0);   // real texture px (region size if any)
uniform vec2 ft_center_px = vec2(0.0);  // drawn-rect centre in local px

float ft_cr(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

// p_uv: un-warped texture uv of this sample. Returns the uv of the source
// texel visible at that spatial position under the corner warp (inverse
// bilinear, same math as FT's distort shader), or vec2(-10.0) when the
// position falls outside the warped quad (transparent).
vec2 ft_warp_sample(vec2 p_uv) {
    vec2 p = ft_center_px + (p_uv - vec2(0.5)) * ft_tex_size;
    vec2 a = ft_corner_tl; vec2 b = ft_corner_tr; vec2 c = ft_corner_br; vec2 d = ft_corner_bl;
    vec2 nrm_ctr = (a + b + c + d) * 0.25;
    float nrm_s = max(max(length(b - a), length(d - a)), 1e-3);
    a = (a - nrm_ctr) / nrm_s; b = (b - nrm_ctr) / nrm_s; c = (c - nrm_ctr) / nrm_s; d = (d - nrm_ctr) / nrm_s;
    p = (p - nrm_ctr) / nrm_s;
    vec2 e = b - a; vec2 f = d - a; vec2 g = a - b + c - d; vec2 h = p - a;
    float k2 = ft_cr(g, f); float k1 = ft_cr(e, f) + ft_cr(h, g); float k0 = ft_cr(h, e);
    float v;
    if (abs(k2) < 1e-5) { v = -k0 / k1; }
    else {
        float sq = sqrt(max(k1 * k1 - 4.0 * k0 * k2, 0.0));
        float qq = -0.5 * (k1 + (k1 >= 0.0 ? sq : -sq));
        float v1 = qq / k2;
        float v2 = abs(qq) > 1e-12 ? k0 / qq : v1;
        v = (v1 >= -0.001 && v1 <= 1.001) ? v1 : v2;
    }
    vec2 den = e + g * v;
    float u = abs(den.x) > abs(den.y) ? (h.x - f.x * v) / den.x : (h.y - f.y * v) / den.y;
    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) return vec2(-10.0);
    return vec2(u, v);
}

// Guarded silhouette alpha lookup. Replaces the previous inline
// "in [0,1] -> texture(...).a, else 0" pattern (identical when warp is off).
// When the warp is on, the [0,1] pre-check is dropped on purpose: the warped
// image can legitimately extend outside the original texture rect, and
// ft_warp_sample already returns transparent outside the warped quad.
float ft_alpha(sampler2D tex, vec2 p) {
    if (ft_warp_enabled < 0.5) {
        if (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) return texture(tex, p).a;
        return 0.0;
    }
    vec2 w = ft_warp_sample(p);
    if (w.x < -5.0) return 0.0;
    return texture(tex, w).a;
}

// Source alpha at a UV. Stretch mode: plain texture lookup (uv is pre-warped by
// the inverse-map in fragment()). Extrude mode: directional sweep — light this
// point if the silhouette covers any point back along -proj_dir within length,
// with a per-distance fade. Side edges of the swept tail are parallel to the
// light direction, which is what a real cast shadow does (clean on boxes).
uniform int extrude_steps = 18;
float src_alpha(sampler2D tex, vec2 p) {
    float m = ft_alpha(tex, p);
    if (proj_enabled > 0.5 && proj_extrude > 0.5 && proj_length > 0.01) {
        float fsteps = float(extrude_steps);
        float total_px = proj_length * max(proj_tex_size.x, proj_tex_size.y);
        float step_px = total_px / fsteps;
        vec2 duv = (proj_dir * step_px) / proj_tex_size;
        // Fine near-field pass: 4 sub-samples inside the FIRST coarse step. At
        // long distances a coarse step (up to ~50 texpx) overshoots the shallow
        // grazing chords of the silhouette near its rim, detaching the shadow
        // from the asset edge by up to one step (a gap that grows with distance).
        for (int s = 1; s <= 4; s++) {
            float f = 0.2 * float(s);
            vec2 q = p - duv * f;
            float w = 1.0 - proj_fade * (f / fsteps);
            m = max(m, ft_alpha(tex, q) * w);
        }
        for (int s = 1; s <= 64; s++) {
            if (s > extrude_steps) break;
            vec2 q = p - duv * float(s);
            float w = 1.0 - proj_fade * (float(s) / fsteps);
            m = max(m, ft_alpha(tex, q) * w);
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

    // Under-asset cut. The mask is eroded ~2px so the shadow still tucks a couple
    // of pixels under the asset edge for a seamless junction.
    // Offset mode: the shadow sprite is displaced, so the asset alpha that overlaps
    // this fragment lives at uv + cut_offset. Projected: cut_offset is 0 (co-located).
    // NOTE: this used to be a binary `if (er_a >= 0.5) discard`. Many DD asset PNGs
    // carry a baked-in semi-transparent halo/shading (often stronger on one side):
    // every halo pixel with alpha >= 0.5 killed the shadow while being nearly
    // invisible on screen, leaving a pale band between the visible asset edge and
    // the shadow body (rotating with the asset, in both projected sub-modes).
    // A continuous attenuation by the asset coverage has no threshold step: the
    // asset already composites over the shadow with its own alpha, so scaling the
    // shadow by (1 - alpha) keeps the junction seamless for ANY alpha profile.
    // Fully opaque interiors still discard early to skip the blur loop (perf).
    float cut_mul = 1.0;
    {
        vec2 cuv = uv + cut_offset;
        // ft_alpha keeps the cut hole under the WARPED asset (identical to the
        // previous guarded lookups when the warp is off).
        float er_a = ft_alpha(TEXTURE, cuv);
        vec2 er = 2.0 * TEXTURE_PIXEL_SIZE;
        for (int k = 0; k < 6; k++) {
            float ang = 6.28318 * float(k) / 6.0;
            vec2 su = cuv + vec2(cos(ang), sin(ang)) * er;
            er_a = min(er_a, ft_alpha(TEXTURE, su));
        }
        if (er_a >= 0.999) discard;
        cut_mul = 1.0 - clamp(er_a, 0.0, 1.0);
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
    alpha = clamp(alpha * shadow_strength * proj_fade_mul, 0.0, 1.0) * cut_mul;
    COLOR = vec4(shadow_color.rgb, alpha);
}
