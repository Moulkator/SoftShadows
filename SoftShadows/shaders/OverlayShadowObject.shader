shader_type canvas_item;

// Overlay (form) shadow: darkens only the side of the asset facing away from
// the sun, clipped to the asset's own silhouette via its texture alpha.
// No blur loops, no raycasting — a handful of instructions per fragment.

uniform vec4  shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity   : hint_range(0.0, 1.0) = 0.5;
uniform float coverage  : hint_range(0.0, 1.0) = 0.5;   // how far the shadow reaches toward the lit side
uniform float diffusion : hint_range(0.0, 1.0) = 0.5;   // softness of the gradient edge
uniform float curve     : hint_range(-1.0, 1.0) = 0.0;  // bows the shadow terminator (- convex / + concave)
uniform vec2  local_sun = vec2(0.0, 1.0);               // sun direction in the sprite's local space (handles rotation + mirror)
uniform vec2  tex_size = vec2(1.0, 1.0);                // px, to keep the gradient un-skewed by aspect ratio
uniform float ignore_transparency = 0.0;                // 1 = replace-color mode (see fragment)

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
