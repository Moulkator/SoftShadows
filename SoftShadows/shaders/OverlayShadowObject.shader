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

void fragment() {
    float a_mask = texture(TEXTURE, UV).a;

    // Centered position in normalized pixel space (long axis spans ~[-0.5, 0.5]).
    vec2 p = (UV - vec2(0.5)) * tex_size;
    p /= max(tex_size.x, tex_size.y);

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

    float a = a_mask * t * opacity;
    COLOR = vec4(shadow_color.rgb, a);
}
