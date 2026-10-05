shader_type canvas_item;

// Overlay shadow, clipped to the asset's own silhouette via its texture alpha.
// Two modes (overlay_mode):
//   0 = GRADIENT: darkens only the side of the asset facing away from the sun
//       (a terminator sweeps across the asset). No loops — a handful of
//       instructions per fragment.
//   1 = BEVEL: a shadow band follows the silhouette's edges, like the pattern
//       overlay (sun_strength 0 = sun from above, every edge gets the band).
//       The asset has no polygon, so the edge is found by marching the texture
//       alpha in 16 directions (fixed sample count, whatever the band width).

uniform vec4  shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity   : hint_range(0.0, 1.0) = 0.5;
uniform float coverage  : hint_range(0.0, 1.0) = 0.5;   // how far the shadow reaches toward the lit side
uniform float diffusion : hint_range(0.0, 1.0) = 0.5;   // softness of the gradient edge
uniform float curve     : hint_range(-1.0, 1.0) = 0.0;  // bows the shadow terminator (- convex / + concave)
uniform vec2  local_sun = vec2(0.0, 1.0);               // sun direction in the sprite's local space (handles rotation + mirror)
uniform vec2  tex_size = vec2(1.0, 1.0);                // px, to keep the gradient un-skewed by aspect ratio
uniform float ignore_transparency = 0.0;                // 1 = replace-color mode (see fragment)

// --- Bevel mode --------------------------------------------------------------
uniform float overlay_mode = 0.0;                       // 0 = gradient, 1 = bevel
uniform float band_px = 64.0;                           // bevel band width, WORLD px
uniform vec2  px_scale = vec2(1.0, 1.0);                // world px per texel (abs sprite scale)
uniform float sun_strength : hint_range(0.0, 1.0) = 0.0; // 0 = sun from above (all edges), 1 = fully directional
uniform float raised = 1.0;                             // 1 = raised (edges away from the sun), 0 = lowered (edges facing it)

// --- Free Transform (Unofficial Patch) warp support -------------------------
// The overlay sits ON TOP of the asset, clipped to its silhouette — so when FT
// distorts/perspectives the asset (bilinear corner warp in its material), the
// overlay must warp the SAME way or it drifts off the asset. Same approach as
// FT's own distort shader: the vertex moves the quad onto the warped corners,
// the fragment inverse-maps each pixel back to its source texel. The gradient
// then runs in texture space, so the terminator follows the warped form.
// Params are fed by OverlayShadowObjects.gd from FT's published corner data;
// ft_warp_enabled = 0.0 keeps behavior identical to the previous version.
uniform float ft_warp_enabled = 0.0;
uniform vec2 ft_corner_tl = vec2(0.0);  // corners in the sprite's local px
uniform vec2 ft_corner_tr = vec2(0.0);
uniform vec2 ft_corner_br = vec2(0.0);
uniform vec2 ft_corner_bl = vec2(0.0);
varying vec2 ft_v_local;

void vertex() {
    if (ft_warp_enabled > 0.5) {
        VERTEX = mix(mix(ft_corner_tl, ft_corner_tr, UV.x), mix(ft_corner_bl, ft_corner_br, UV.x), UV.y);
    }
    ft_v_local = VERTEX;
}

float ft_cr(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

// Inverse bilinear: local position -> texture uv (clamped; fragments only
// exist inside the warped quad since the vertex stage moved the corners).
vec2 ft_warp_uv(vec2 pos) {
    vec2 a = ft_corner_tl; vec2 b = ft_corner_tr; vec2 c = ft_corner_br; vec2 d = ft_corner_bl;
    vec2 nrm_ctr = (a + b + c + d) * 0.25;
    float nrm_s = max(max(length(b - a), length(d - a)), 1e-3);
    a = (a - nrm_ctr) / nrm_s; b = (b - nrm_ctr) / nrm_s; c = (c - nrm_ctr) / nrm_s; d = (d - nrm_ctr) / nrm_s;
    pos = (pos - nrm_ctr) / nrm_s;
    vec2 e = b - a; vec2 f = d - a; vec2 g = a - b + c - d; vec2 h = pos - a;
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
    return clamp(vec2(u, v), 0.0, 1.0);
}

// Silhouette alpha, transparent outside the texture.
float bevel_alpha(sampler2D tex, vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 0.0;
    return texture(tex, uv).a;
}

// Bevel band strength (0..1) at uv. For each of 16 directions: march outward
// (10 steps across the band) until the silhouette ends, refine that distance
// by bisection (4 steps), then apply the same falloff / sun weighting as the
// pattern overlay. Distances are in WORLD px so the band keeps its width
// whatever the asset's scale.
float bevel_shade(sampler2D tex, vec2 uv, vec2 texel) {
    if (band_px < 0.01) return 0.0;
    // local_sun carries the inverse sprite scale: undo it to get the sun in
    // the un-scaled frame the directions below live in.
    vec2 sun = local_sun * px_scale;
    float sl = length(sun);
    sun = sl > 0.00001 ? sun / sl : vec2(0.0, 1.0);
    if (raised > 0.5) sun = -sun;
    vec2 to_uv = texel / px_scale;                      // world px -> uv
    float band_in = clamp(1.0 - diffusion, 0.0, 0.999);
    float k = pow(2.0, curve);
    float step_len = band_px / 10.0;
    float best = 0.0;
    for (int i = 0; i < 16; i++) {
        float ang = float(i) * 0.39269908;              // 2*PI / 16
        vec2 d = vec2(cos(ang), sin(ang));
        float w = mix(1.0, max(dot(d, sun), 0.0), sun_strength);
        if (w > 0.0) {
            float lo = 0.0;
            float hi = -1.0;
            for (int s = 1; s <= 10; s++) {
                float r = step_len * float(s);
                float a = bevel_alpha(tex, uv + d * r * to_uv);
                if (hi < 0.0) {
                    if (a < 0.2) { hi = r; } else { lo = r; }
                }
            }
            if (hi > 0.0) {
                for (int b = 0; b < 4; b++) {
                    float mid = 0.5 * (lo + hi);
                    if (bevel_alpha(tex, uv + d * mid * to_uv) < 0.2) { hi = mid; } else { lo = mid; }
                }
                float u = 0.5 * (lo + hi) / band_px;
                float f = 1.0 - smoothstep(band_in, 1.0, u);
                f = pow(max(f, 0.0), k);
                best = max(best, w * f);
            }
        }
    }
    return best;
}

void fragment() {
    vec2 suv = UV;
    if (ft_warp_enabled > 0.5) {
        suv = ft_warp_uv(ft_v_local);
    }
    float a_mask = texture(TEXTURE, suv).a;

    // Gradient position in normalized pixel space (long axis spans ~[-0.5, 0.5]).
    // UNWARPED: derived from texture space (identical to local space then).
    // WARPED: derived from the vertex-LOCAL position instead — local_sun lives
    // in that space, so the terminator stays world-anchored while the pixels
    // deform. (Deriving it from suv made the shadow rotate with the warp.)
    vec2 p;
    if (ft_warp_enabled > 0.5) {
        p = ft_v_local / max(tex_size.x, tex_size.y);
    } else {
        p = (suv - vec2(0.5)) * tex_size;
        p /= max(tex_size.x, tex_size.y);
    }

    // Sun direction already expressed in the sprite's local space (computed on
    // the CPU from the inverse transform), so rotation AND mirror are handled —
    // the shadow never flips with a mirrored asset.
    vec2 sun = normalize(local_sun);

    // Axes: proj grows into the shadow side, q runs along the terminator.
    vec2 perp = vec2(-sun.y, sun.x);
    float proj = dot(p, -sun);
    float q = dot(p, perp);

    // Circular arc with a FIXED radius of 0.5. R = H here, so the bow is a true
    // half-circle of radius 0.5 spanning |q| < 0.5; beyond that it holds flat
    // (only visible on fully opaque square corners — masked away elsewhere).
    // curve scales the depth and sign (in-place concave / convex — no side flip).
    float H = 0.5;                   // fixed circle radius
    float qc = clamp(q, -H, H);
    float sagitta = H;               // R = H -> half-circle, sagitta = H
    float arc = sqrt(H * H - qc * qc);
    proj += curve * arc;

    // Coverage sweeps the terminator across exactly the asset's projection
    // range. Because the curve offset (curve * arc) shifts the whole projection
    // one way, the range is ASYMMETRIC — clamping the sweep to [proj_lo, proj_hi]
    // keeps the full slider useful (no dead zone) and always fills at coverage 1.
    float bend = curve * sagitta;
    float proj_hi = 0.75 + max(0.0, bend);
    float proj_lo = -0.75 + min(0.0, bend);
    float threshold = mix(proj_hi, proj_lo, coverage);
    float width = max(diffusion * 0.5, 0.002);
    float t = smoothstep(threshold - width, threshold + width, proj);

    // Bevel mode replaces the terminator by the edge band (fully transparent
    // pixels skip the search: nothing to shade there).
    if (overlay_mode > 0.5) {
        t = a_mask > 0.004 ? bevel_shade(TEXTURE, suv, TEXTURE_PIXEL_SIZE) : 0.0;
    }

    if (ignore_transparency > 0.5) {
        // Replace mode: the source sprite is HIDDEN by the GD side and this
        // overlay re-renders the whole asset in its place. Outside the shaded
        // area (t=0) the pixel is emitted untouched; inside, its color is
        // pushed toward shadow_color by opacity*t while the pixel's ORIGINAL
        // alpha is kept — semi-transparent parts darken without stacking.
        vec4 texc = texture(TEXTURE, suv);
        COLOR = vec4(mix(texc.rgb, shadow_color.rgb, opacity * t), texc.a);
    } else {
        float a = a_mask * t * opacity;
        COLOR = vec4(shadow_color.rgb, a);
    }
}
