#########################################################################################################
##
## LIGHT SHADOWS - Per-light shadow softness & region clip (build 6)
##
## Two per-light options, usable together:
##
##  - Shadow Softness (0..1): the light's native raycast shadows are replaced
##    by a baked texture — shadow quads projected from the centre, blurred by
##    a double-iteration separable gaussian (uniform width in world px, soft
##    at every angle including on the wall line), dithered against 8-bit
##    banding, multiplied with the light texture.
##
##  - Wrap Corners: the light stops casting rays and instead fills the region
##    enclosing its centre (computed by subtracting occluder barriers from the
##    light bounds with Godot's Geometry API). Light wraps around corners and
##    free-standing walls (both sides lit, cut on the line); block-light
##    objects punch holes on their own footprint; closed doors seal doorways.
##    Softness then blurs the region edges.
##
## Occluders are gathered generically: every LightOccluder2D visible in the
## level (walls always, portals when closed, objects/paths when block-light).
##
##  - The parent light stays 100% native but is neutralised via
##    range_item_cull_mask -> parked layer (NOT saved by DD: a map opened
##    without the mod shows a normal hard-edged light).
##  - The proxy is a plain Light2D child of the parent (never saved, never
##    hit-tested), shadow_enabled = false, carrying the baked texture.
##  - Rebakes are queued and serialized through one shared viewport rig,
##    triggered by a per-light signature checked by the 0.5s monitor.
##
## Persistence : ModMapData["DropShadowLights"][node_id] = {softness, wrap}
##               ("energy" key from build 2 is migrated back into the light)
## Undo/redo   : B2 transactions via ShadowHistory (debounced commits)
##
#########################################################################################################

const BUILD := "LIGHTS-SOFT-104"

# ── Wiring (set by Core.gd) ────────────────────────────────────────────
var global
var core
var logging_level := -1         # -1 = silent (all _log() suppressed); raise to 1 to restore operational logs
var shadow_history = null

# ── Constants ──────────────────────────────────────────────────────────
const DATA_KEY := "DropShadowLights"
const PARKED_MASK := 524288     # 1 << 19 — unused render layer, parks the parent light
const PARKED_ZLAYER := 511      # parent parked on a non-existent Z range layer (belt & braces, not saved by DD)
const ACTIVE_MASK := 2          # DD scene items light layer
const BAKE_RES := 1024          # baked texture resolution
const MAX_BLUR_WORLD := 192.0   # gaussian blur half-width in world px at softness = 1.0
const SOFT_CLIP_AMOUNT := 0.5   # walls & paths softness when Soft Clipping is ON (objects use SOFT_OBJ_AMOUNT)
const SOFT_OBJ_AMOUNT := 0.1    # block-light objects softness when Soft Clipping is ON
const SOFT_WALLS_MAX := 1.0     # walls slider 100% maps to this blur amount (cap)
const SOFT_OBJ_MAX := 0.5       # objects slider 100% maps to this blur amount (cap)
const OBJ_SHRINK := 5.0         # object shadow footprints deflated inward by this many world px
const QUALITY_DELAY_MS := 400   # idle delay before live mode freezes (light considered stationary)
const POOL_MAX := 4             # max lights rendered in parallel during a geometry drag (each ~8 MB of viewport VRAM); extras fall back to fast bakes
const POOL_HOLD_MS := 200       # keep a light pooled this long after it stops being affected (hysteresis: absorbs affected-radius oscillation on fast drags)
const PLIVE_DIAG := false        # diagnostics off
const CONTENT_LAG := 1          # frames between mask preparation and its on-screen consumption (calibrate 1-2)
const REGION_LIVE_MS := 100     # region recompute interval when idle-ish (Ignore Corners)
const REGION_DRAG_MS := 33      # region recompute interval while a wall/path near the light is actively being dragged (30 Hz; was 60 Hz — the cause of multi-light wall stutter)
const REGION_DIAG := false      # diagnostics off
const OCC_CACHE_MS := 1000      # occluder list cache TTL per level
const OCC_DIAG := false         # diagnostics off
const HARD_CLAMP := false       # bound the blur by the hard mask (kills the soft bleed across wall lines)
const BARRIER_W := 8.0          # region mode: barrier stroke width (world px)
const SEG_MARGIN := 64.0        # extra world margin when culling occluders
const DEBUG_TINT_PROXY := false # DIAGNOSTIC: tint everything WE render in blue (reveals a leaking parked parent)
const DEBUG_SHOW_MASK := false  # DIAGNOSTIC: the light displays the raw shadow mask as grayscale
const PREVIEW_NID := "__preview"  # pseudo node_id for the Light tool preview
const EPS := 0.001

# ── State ──────────────────────────────────────────────────────────────
var _tool_soft_clip := false    # Light tool defaults, applied to newly placed lights
var _tool_ignore := false
var _tool_obj := false
var _tool_soft_walls := SOFT_CLIP_AMOUNT   # Light tool default blur AMOUNTS (0.5 = 50%, 0.1 = 10%); slider shows amount*100
var _tool_soft_obj := SOFT_OBJ_AMOUNT
# Raw per-light visual params (shown in their natural units). {min,max,step,default,suffix}.
var _val_specs := {
	"obj_shrink": {"min": 0.0, "max": 50.0, "step": 0.5, "default": OBJ_SHRINK, "suffix": " px"},
}
var _tool_vals := {"obj_shrink": OBJ_SHRINK}
var _lt_blur := {}              # Light tool blur-settings widgets {cog,reset,box,walls_slider,walls_spin,obj_slider,obj_spin,label}
var _st_blur := {}              # Select tool blur-settings widgets (same shape)
var _known_ids := {}            # node_id (String) -> true, gates tool-default stamping
var _copy_src_ids := []         # node_ids of the last clean all-configured light selection (clone source, in order)
var _light_clone_batch := []    # new config-less lights seen this scan, resolved as clones after
var _soft := {}                 # node_id -> {"proxy": Light2D, "sig": String, "bypass": bool}
var _occ_cache := {}            # level instance_id -> {"list": [...], "ms": t}
var _occ_sigs := {}             # level iid -> {occluder iid: {"sig": float, "pos": Vector2}} (localized motion detection)
var _bake_queue := []
var _bake_busy := false
var _bake_started_ms := 0
var _monitor_timer: Timer = null
var _ui_guard := false

# Shared bake rig (built lazily)
var _rig_built := false
var _vp_mask: Viewport = null
var _mask_bg: ColorRect = null
var _blur_vps := []              # 6 statically chained gaussian viewports (H,V x3)
var _live_nid := ""              # light currently rendered in real time (shared rig)
var _live_priority := false      # live holder is user-driven (selected light or preview)
var _diag_transitions := 0
var _diag_last_log := 0
var _live_deferred := false      # one deferred live-frame refresh per frame
var _pool := []                  # persistent pool of parallel-live slots {mvp,mbg,mpolys,fvp,fmat,fsprite,nid,warm}
var _plive := []                 # nids currently borrowing a pool slot (geometry drag)
var _plive_deferred := false     # one deferred parallel-live refresh per frame
var _plive_diag_ms := 0          # throttle for the parallel-pool diagnostic log
var _region_diag_us := 0         # accumulated compute_region() time (µs) for the diagnostic
var _region_diag_n := 0          # compute_region() call count for the diagnostic window
var _region_diag_ms := 0         # throttle for the region timing diagnostic log
var _occ_diag_us := 0            # accumulated full occluder re-collect time (µs)
var _occ_diag_n := 0             # full re-collect count in the diagnostic window
var _occ_inval_n := 0            # cache-invalidation count (freed occluders) in the window
var _occ_diag_ms := 0            # throttle for the occluder diagnostic log
var _blur_mats := []
var _final_shader: Shader = null # final multiply shader (per-light materials)
var _mat_add: CanvasItemMaterial = null  # additive material for shadow fans (channels accumulate)
var _mask_polys := []            # Polygon2D pool inside _vp_mask

# Light tool UI
var _lt_built := false
var _lt_container: VBoxContainer = null
var _lt_soft_clip: CheckButton = null
var _lt_ignore: CheckButton = null
var _lt_obj: CheckButton = null

# Select tool UI
var _st_built := false
var _st_container: VBoxContainer = null
var _st_soft_clip: CheckButton = null
var _st_ignore: CheckButton = null
var _st_obj: CheckButton = null

# Pending undo/redo transaction (debounced)
var _txn = null                 # {"before": {nid: {softness, wrap}}, "after": {...}}
var _txn_timer: Timer = null
var _rg = null                  # region engine (light_region_geometry.gd), lazy-loaded

#########################################################################################################
##
## LOGGING
##
#########################################################################################################

func _log(msg, level = 1):
	if level <= logging_level:
		printraw("(%d) <LightShadows>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
##
## INITIALISE
##
#########################################################################################################

func initialise():
	printraw("(%d) <LightShadows>: " % OS.get_ticks_msec())
	print("[BUILD: %s] initialising" % BUILD)  # kept unconditionally: confirms the running version

	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.25
	_monitor_timer.one_shot = false
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_monitor_tick")
	global.Editor.add_child(_monitor_timer)

	_txn_timer = Timer.new()
	_txn_timer.wait_time = 0.6
	_txn_timer.one_shot = true
	_txn_timer.connect("timeout", self, "_commit_txn")
	global.Editor.add_child(_txn_timer)

	if shadow_history != null:
		shadow_history.register_flusher(self, "flush_pending")

	_build_light_tool_ui()
	_build_select_tool_ui()

#########################################################################################################
##
## BAKE RIG (shared viewports, double-iteration separable gaussian)
##
#########################################################################################################

# 1D gaussian, two passes (H then V), used by BOTH modes: raycast and Wrap
# Corners share the exact same mask-blur-final pipeline and therefore render
# with identical softness.
const BLUR_1D_SHADER := """
shader_type canvas_item;

uniform sampler2D src_tex;
uniform vec2 dir = vec2(1.0, 0.0);
uniform float blur_r = 0.0;
uniform float blur_g = 0.0;

void fragment() {
    // Two shadow channels with independent radii: R = walls & paths
    // (Soft Clipping), G = block-light objects (Softer Object Shadow).
    // 21 taps, and each channel's loop is skipped entirely when its radius
    // is zero (uniform branch): halves the fetch cost when only one of the
    // two softness classes is active.
    float mr = 0.0;
    float mg = 0.0;
    float wsum = 0.0;
    if (blur_r > 0.00005) {
        for (int i = 0; i < 21; i++) {
            float t = (float(i) / 10.0) - 1.0;
            float w = exp(-t * t * 3.0);
            mr += texture(src_tex, SCREEN_UV + dir * (t * blur_r)).r * w;
            wsum += w;
        }
        mr /= wsum;
    } else {
        mr = texture(src_tex, SCREEN_UV).r;
    }
    if (blur_g > 0.00005) {
        float wsum2 = 0.0;
        for (int i = 0; i < 21; i++) {
            float t = (float(i) / 10.0) - 1.0;
            float w = exp(-t * t * 3.0);
            mg += texture(src_tex, SCREEN_UV + dir * (t * blur_g)).g * w;
            wsum2 += w;
        }
        mg /= wsum2;
    } else {
        mg = texture(src_tex, SCREEN_UV).g;
    }
    COLOR = vec4(mr, mg, 0.0, 1.0);
}
"""

# LIVE MODE blur: one single 2D pass (25-tap disc kernel, dual radii) so the
# whole live pipeline is only mask -> blur -> final: minimal stage count =
# minimal possible frame lag after a grid snap, and cheaper per frame.
# Final pass: visibility = 1 - accumulated shadow, times the light texture,
# dithered on the stored value against 8-bit banding.
const FINAL_SHADER := """
shader_type canvas_item;

uniform sampler2D mask_tex;
uniform sampler2D hard_tex;
uniform float hard_clamp = 0.0;
uniform float debug_mask = 0.0;
uniform float live = 0.0;
uniform float blur_r = 0.0;
uniform float blur_g = 0.0;
uniform vec2 world_center = vec2(0.0);
uniform float inv_to_bake = 1.0;
uniform vec2 map_min = vec2(-1000000000.0);
uniform vec2 map_max = vec2(1000000000.0);
uniform float border_band = 0.0;

void fragment() {
    vec2 suv = vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y);
    float s;
    if (live > 0.5) {
        // LIVE MODE: blur the RAW mask inline (rotated gaussian disc, 25
        // taps): the whole pipeline is mask -> final, at most 1 frame of
        // content lag — motion reads as instantaneous.
        vec2 taps[25];
        taps[0] = vec2(0.0, 0.0);
        taps[1] = vec2(0.38, 0.0); taps[2] = vec2(-0.38, 0.0); taps[3] = vec2(0.0, 0.38); taps[4] = vec2(0.0, -0.38);
        taps[5] = vec2(0.27, 0.27); taps[6] = vec2(-0.27, 0.27); taps[7] = vec2(0.27, -0.27); taps[8] = vec2(-0.27, -0.27);
        taps[9] = vec2(0.7, 0.0); taps[10] = vec2(-0.7, 0.0); taps[11] = vec2(0.0, 0.7); taps[12] = vec2(0.0, -0.7);
        taps[13] = vec2(0.5, 0.5); taps[14] = vec2(-0.5, 0.5); taps[15] = vec2(0.5, -0.5); taps[16] = vec2(-0.5, -0.5);
        taps[17] = vec2(1.0, 0.0); taps[18] = vec2(-1.0, 0.0); taps[19] = vec2(0.0, 1.0); taps[20] = vec2(0.0, -1.0);
        taps[21] = vec2(0.71, 0.71); taps[22] = vec2(-0.71, 0.71); taps[23] = vec2(0.71, -0.71); taps[24] = vec2(-0.71, -0.71);
        float ang = fract(sin(dot(suv, vec2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
        float ca = cos(ang);
        float sa = sin(ang);
        float mr = 0.0;
        float mg = 0.0;
        float wsum = 0.0;
        for (int i = 0; i < 25; i++) {
            vec2 t = vec2(taps[i].x * ca - taps[i].y * sa, taps[i].x * sa + taps[i].y * ca);
            float w = exp(-dot(taps[i], taps[i]) * 2.0);
            vec4 c = texture(hard_tex, suv + t * blur_r);
            mr += c.r * w;
            if (blur_g > 0.00005) {
                mg += texture(hard_tex, suv + t * blur_g).g * w;
            } else {
                mg += c.g * w;
            }
            wsum += w;
        }
        s = max(mr / wsum, mg / wsum);
    } else {
        // Union of the two shadow channels (walls/paths in R, objects in G).
        vec4 sm = texture(mask_tex, suv);
        s = max(sm.r, sm.g);
    }
    // Optional native-style bound: kills the soft bleed across wall lines
    // and draws a visible seam through wide gradients — off by default.
    if (hard_clamp > 0.5) {
        vec4 hm = texture(hard_tex, suv);
        s = max(s, max(hm.r, hm.g));
    }
    // MAP BORDER: the map edges must stay HARD. Outside: full shadow.
    // Inside, within one blur width of the border, the blurred shadow is
    // blended back to the HARD mask so no soft falloff ever reaches the
    // edge, whatever combination of options is active.
    // suv is V-flipped for texture sampling; world reconstruction needs the
    // unflipped Y (the mirrored test cut the OPPOSITE side near top/bottom
    // borders and applied the hard band on the wrong side).
    vec2 wpos = (vec2(suv.x, 1.0 - suv.y) * 1024.0 - vec2(512.0)) * inv_to_bake + world_center;
    float border_d = min(min(wpos.x - map_min.x, map_max.x - wpos.x), min(wpos.y - map_min.y, map_max.y - wpos.y));
    if (border_d < 0.0) {
        s = 1.0;
    } else if (border_band > 0.5 && border_d < border_band) {
        vec4 hm2 = texture(hard_tex, suv);
        s = mix(max(hm2.r, hm2.g), s, border_d / border_band);
    }
    float m = 1.0 - clamp(s, 0.0, 1.0);
    vec4 lc = texture(TEXTURE, UV);
    vec4 outc = vec4(lc.rgb * m, lc.a * m);
    if (debug_mask > 0.5) {
        // DIAGNOSTIC: show the raw shadow field (white = lit, black = shadow)
        outc = vec4(m, m, m, 1.0);
    }
    float n = fract(sin(dot(SCREEN_UV, vec2(12.9898, 78.233))) * 43758.5453);
    outc += vec4((n - 0.5) * (2.0 / 255.0));
    COLOR = clamp(outc, vec4(0.0), vec4(1.0));
}
"""

func _make_blur_vp(size: Vector2, dir: Vector2) -> Array:
	var vp = Viewport.new()
	vp.size = size
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.render_target_v_flip = false
	vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	vp.gui_disable_input = true
	var shader = Shader.new()
	shader.code = BLUR_1D_SHADER
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_param("dir", dir)
	var rect = ColorRect.new()
	rect.rect_size = size
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = mat
	vp.add_child(rect)
	global.Editor.add_child(vp)
	return [vp, mat]

func _build_rig():
	if _rig_built:
		return
	var size = Vector2(BAKE_RES, BAKE_RES)

	# Mask viewport (SHADOW channel): background + polygon pool.
	# Raycast: black bg (no shadow) + additive analytic penumbra quads.
	# Wrap: white bg (all shadow) + black region polygon, then blurred.
	_vp_mask = Viewport.new()
	_vp_mask.size = size
	_vp_mask.usage = Viewport.USAGE_2D
	_vp_mask.disable_3d = true
	_vp_mask.render_target_v_flip = false
	_vp_mask.render_target_update_mode = Viewport.UPDATE_DISABLED
	_vp_mask.gui_disable_input = true
	_mask_bg = ColorRect.new()
	_mask_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mask_bg.color = Color(0, 0, 0, 1)
	_mask_bg.rect_size = size
	_vp_mask.add_child(_mask_bg)
	global.Editor.add_child(_vp_mask)
	_vp_mask.get_texture().flags = Texture.FLAG_FILTER

	# Static chain of 6 blur passes (H,V x 3 iterations) with FIXED source
	# bindings, added in tree order after the mask viewport: in live mode all
	# of them render every frame; in bake mode they are stepped sequentially.
	var prev_tex = _vp_mask.get_texture()
	for i in range(6):
		var pair = _make_blur_vp(size, Vector2(1, 0) if i % 2 == 0 else Vector2(0, 1))
		pair[1].set_shader_param("src_tex", prev_tex)
		prev_tex = pair[0].get_texture()
		_blur_vps.append(pair[0])
		_blur_mats.append(pair[1])

	_final_shader = Shader.new()
	_final_shader.code = FINAL_SHADER

	_mat_add = CanvasItemMaterial.new()
	_mat_add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	_rig_built = true
	_log("bake rig built (%dx%d, unified gaussian pipeline)" % [BAKE_RES, BAKE_RES], 0)

# Per-light final viewport: light texture x (1 - shadow mask). The live
# ViewportTexture is the proxy texture; FILTER set explicitly. mask_tex is
# rebound per bake (raycast: raw mask; wrap: blurred mask).
func _make_final_vp() -> Dictionary:
	var size = Vector2(BAKE_RES, BAKE_RES)
	var vp = Viewport.new()
	vp.size = size
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.transparent_bg = true
	vp.render_target_v_flip = false
	vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	vp.gui_disable_input = true
	var mat = ShaderMaterial.new()
	mat.shader = _final_shader
	mat.set_shader_param("mask_tex", _vp_mask.get_texture())
	mat.set_shader_param("hard_tex", _vp_mask.get_texture())
	mat.set_shader_param("hard_clamp", 1.0 if HARD_CLAMP else 0.0)
	mat.set_shader_param("debug_mask", 1.0 if DEBUG_SHOW_MASK else 0.0)
	var sprite = Sprite.new()
	sprite.material = mat
	sprite.position = size * 0.5
	vp.add_child(sprite)
	global.Editor.add_child(vp)
	var tex = vp.get_texture()
	tex.flags = Texture.FLAG_FILTER
	return {"vp": vp, "sprite": sprite, "mat": mat}

# Polygon pool. Region polys draw with plain MIX; shadow fans draw with the
# shared ADD material so the R and G channels accumulate independently of
# paint order. Operates on an explicit (viewport, poly-list) pair so the shared
# mask and the per-light parallel-pool masks share one implementation.
func _set_mask_poly_on(mvp, mpolys: Array, index: int, points: PoolVector2Array, color: Color, material = null):
	while mpolys.size() <= index:
		var poly = Polygon2D.new()
		mvp.add_child(poly)
		mpolys.append(poly)
	var p = mpolys[index]
	p.polygon = points
	p.color = color
	p.material = material
	p.visible = true
	return p

func _hide_mask_polys_on(mpolys: Array, from_index: int):
	for i in range(from_index, mpolys.size()):
		mpolys[i].visible = false

#########################################################################################################
##
## CONFIG STORE
##
#########################################################################################################

func _get_nid(light) -> String:
	if light != null and is_instance_valid(light) and light.has_meta("node_id"):
		return str(light.get_meta("node_id"))
	return ""

func _get_cfg(nid: String):
	if nid == "" or not global.ModMapData.has(DATA_KEY):
		return null
	var store = global.ModMapData[DATA_KEY]
	if store.has(nid) and store[nid] is Dictionary:
		return store[nid]
	return null

# Migrate legacy entries (slider era {softness, wrap}; single-toggle {soft}).
func _migrate_cfg(cfg):
	if cfg == null or not (cfg is Dictionary):
		return
	if cfg.has("softness"):
		cfg["soft"] = float(cfg["softness"]) > EPS
		cfg.erase("softness")
	if cfg.has("wrap"):
		cfg["ignore"] = bool(cfg["wrap"])
		cfg.erase("wrap")
	if cfg.has("soft"):
		cfg["soft_clip"] = bool(cfg["soft"])
		cfg.erase("soft")
	if cfg.has("soft_obj"):
		cfg["soft_clip"] = bool(cfg.get("soft_clip", false)) or bool(cfg["soft_obj"])
		cfg.erase("soft_obj")

func _saved_soft_clip(nid: String) -> bool:
	if nid == PREVIEW_NID:
		return _tool_soft_clip
	var cfg = _get_cfg(nid)
	if cfg == null:
		return false
	_migrate_cfg(cfg)
	return bool(cfg.get("soft_clip", false))

func _saved_ignore(nid: String) -> bool:
	if nid == PREVIEW_NID:
		return _tool_ignore
	var cfg = _get_cfg(nid)
	if cfg == null:
		return false
	_migrate_cfg(cfg)
	return bool(cfg.get("ignore", false))

func _saved_obj(nid: String) -> bool:
	if nid == PREVIEW_NID:
		return _tool_obj
	var cfg = _get_cfg(nid)
	if cfg == null:
		return false
	return bool(cfg.get("obj_shadows", false))

# Soft Clipping blur AMOUNTS (0.5 = 50% for walls, 0.1 = 10% for objects by
# default). The slider shows amount*100 as a percent, range 0..200%.
func _saved_soft_walls(nid: String) -> float:
	if nid == PREVIEW_NID:
		return _tool_soft_walls
	var cfg = _get_cfg(nid)
	if cfg == null:
		return SOFT_CLIP_AMOUNT
	return float(cfg.get("soft_walls_amt", SOFT_CLIP_AMOUNT))

func _saved_soft_obj(nid: String) -> float:
	if nid == PREVIEW_NID:
		return _tool_soft_obj
	var cfg = _get_cfg(nid)
	if cfg == null:
		return SOFT_OBJ_AMOUNT
	return float(cfg.get("soft_obj_amt", SOFT_OBJ_AMOUNT))

func _save_blur(nid: String, walls_amt: float, obj_amt: float):
	if nid == "":
		return
	if not global.ModMapData.has(DATA_KEY):
		global.ModMapData[DATA_KEY] = {}
	var store = global.ModMapData[DATA_KEY]
	var cfg = store.get(nid)
	if not (cfg is Dictionary):
		cfg = {}
		store[nid] = cfg
	cfg["soft_walls_amt"] = clamp(walls_amt, 0.0, SOFT_WALLS_MAX)
	cfg["soft_obj_amt"] = clamp(obj_amt, 0.0, SOFT_OBJ_MAX)

# Raw per-light visual params (currently: obj_shrink).
func _saved_val(nid: String, key: String) -> float:
	var spec = _val_specs[key]
	if nid == PREVIEW_NID:
		return float(_tool_vals.get(key, spec["default"]))
	var cfg = _get_cfg(nid)
	if cfg == null:
		return float(spec["default"])
	return float(cfg.get(key, spec["default"]))

func _save_val(nid: String, key: String, value: float):
	if nid == "":
		return
	var spec = _val_specs[key]
	if not global.ModMapData.has(DATA_KEY):
		global.ModMapData[DATA_KEY] = {}
	var store = global.ModMapData[DATA_KEY]
	var cfg = store.get(nid)
	if not (cfg is Dictionary):
		cfg = {}
		store[nid] = cfg
	cfg[key] = clamp(value, float(spec["min"]), float(spec["max"]))

func _is_active(nid: String) -> bool:
	return _saved_soft_clip(nid) or _saved_ignore(nid)

func _save_cfg(nid: String, soft_clip: bool, ignore: bool, obj_shadows: bool):
	if nid == "":
		return
	if not global.ModMapData.has(DATA_KEY):
		global.ModMapData[DATA_KEY] = {}
	var store = global.ModMapData[DATA_KEY]
	var cfg = store.get(nid)
	if not (cfg is Dictionary):
		cfg = {}
		store[nid] = cfg
	cfg["soft_clip"] = soft_clip
	cfg["ignore"] = ignore
	cfg["obj_shadows"] = obj_shadows

#########################################################################################################
##
## APPLY / TEARDOWN
##
#########################################################################################################

func _apply(light, nid: String):
	if light == null or not is_instance_valid(light):
		return
	var cfg = _get_cfg(nid)
	# Migration from build 2: restore the original (undivided) energy.
	if cfg != null and cfg.has("energy"):
		light.energy = float(cfg["energy"])
		cfg.erase("energy")
		_log("migrated build-2 energy for light %s" % nid)
	if not _is_active(nid):
		_teardown(light, nid)
		return
	var entry = _soft.get(nid)
	if entry == null or not is_instance_valid(entry.get("proxy")):
		_build_rig()
		var proxy = _make_proxy(light)
		var final = _make_final_vp()
		proxy.texture = final["vp"].get_texture()
		entry = {"proxy": proxy, "sig": "", "bypass": false, "vp": final["vp"], "sprite": final["sprite"], "mat": final["mat"]}
		_soft[nid] = entry
	_park(light)
	_sync_proxy(light, entry["proxy"], entry)
	_mark_dirty(nid)

func _park(light):
	light.range_item_cull_mask = PARKED_MASK
	light.range_layer_min = PARKED_ZLAYER
	light.range_layer_max = PARKED_ZLAYER

func _unpark(light):
	light.range_item_cull_mask = ACTIVE_MASK
	light.range_layer_min = 0
	light.range_layer_max = 0

func _teardown(light, nid: String):
	if _live_nid == nid:
		_exit_live()
	var entry = _soft.get(nid)
	if entry != null:
		if entry.get("slot") != null:
			_pool_free(entry["slot"])
			entry.erase("slot")
			entry.erase("slot_release")
		_plive.erase(nid)
		var proxy = entry.get("proxy")
		if proxy != null and is_instance_valid(proxy):
			proxy.free()
		var vp = entry.get("vp")
		if vp != null and is_instance_valid(vp):
			vp.free()
		if entry.get("old_vp") != null and is_instance_valid(entry["old_vp"]):
			entry["old_vp"].free()
		_soft.erase(nid)
	if light != null and is_instance_valid(light):
		_unpark(light)

# The proxy is a child of the LEVEL, not of the light: DD moves the light
# AFTER our per-frame update, and a child proxy would inherit that move and
# override our world-position pin. While LIVE the proxy follows the light's
# current position (instant response, content at most a frame or two behind
# on fast drags); when frozen it stays pinned to the world position the
# displayed mask was computed for (mask_center).
func _make_proxy(light) -> Light2D:
	var proxy = Light2D.new()
	proxy.shadow_enabled = false
	proxy.range_item_cull_mask = ACTIVE_MASK
	proxy.global_position = light.global_position
	var level = _light_level(light)
	if level != null:
		level.add_child(proxy)
	else:
		light.add_child(proxy)
	return proxy

# Mirror the light's live properties onto the proxy, pinned to the world
# position the displayed mask was computed for.
func _sync_proxy(light, proxy, entry = null):
	proxy.energy = light.energy
	proxy.color = light.color * Color(0.5, 0.5, 1.5) if DEBUG_TINT_PROXY else light.color
	proxy.mode = light.mode
	proxy.shadow_enabled = false
	proxy.range_item_cull_mask = ACTIVE_MASK
	if entry != null and entry.has("mask_center"):
		# In live mode mask_center is PREDICTIVE (position + velocity * lead):
		# by the time this content reaches the screen, the light is there.
		proxy.global_position = entry["mask_center"]
	else:
		proxy.global_position = light.global_position

func _mark_dirty(nid: String):
	if not _bake_queue.has(nid):
		_bake_queue.append(nid)
	call_deferred("_bake_next")

#########################################################################################################
##
## MAP LOAD / PERSISTENCE
##
#########################################################################################################

func apply_saved_shadows_to_map():
	if not global.ModMapData.has(DATA_KEY):
		return
	var store = global.ModMapData[DATA_KEY]
	var orphans := []
	for nid in store.keys():
		if not global.World.HasNodeID(int(nid)):
			orphans.append(nid)
			continue
		var node = global.World.GetNodeByID(int(nid))
		if node == null or not is_instance_valid(node) or not (node is Light2D):
			orphans.append(nid)
			continue
		_apply(node, str(nid))
		_known_ids[str(nid)] = true
	for nid in orphans:
		store.erase(nid)
	if orphans.size() > 0:
		_log("cleaned %d orphaned light entries" % orphans.size())
	_log("applied saved config to %d lights" % _known_ids.size())

#########################################################################################################
##
## MONITOR
##
#########################################################################################################

# Per-frame fast path (called by Core.update): near-instant rebake on light
# move/rotate/resize/retexture and per-frame proxy sync — the heavy occluder
# signature stays on the 0.25s monitor tick.
# LOCALIZED geometry change detection: one signature PER OCCLUDER (origin +
# full point sum). The per-frame traversal cost is the same as the old global
# hash, but we now know WHICH occluders changed — only lights whose gather
# radius touches a changed (or removed) occluder react, instead of every
# light on the level rebaking for a torch moved across the map.
func _changed_occluders(level) -> Array:
	var lid = level.get_instance_id()
	var store = _occ_sigs.get(lid)
	if store == null:
		store = {}
		_occ_sigs[lid] = store
	var seen := {}
	var changed := []
	var fresh := []  # brand-new occluders this frame (held: see recreation note below)
	for oc in _cached_occluders(level):
		if not is_instance_valid(oc):
			continue
		var o = oc.global_transform.origin
		var h = o.x * 0.7331 + o.y * 1.297
		var pts = oc.occluder.polygon
		for p in pts:
			h += p.x * 0.611 + p.y * 0.401
		h += float(pts.size()) * 3.17
		var iid = oc.get_instance_id()
		seen[iid] = true
		var prev = store.get(iid)
		if prev == null or prev["sig"] != h:
			if prev != null:
				changed.append({"oc": oc, "pos": o})
			else:
				# A brand-new occluder alone doesn't wake lights: its first frame
				# establishes the baseline (avoids a flash on fresh placement).
				fresh.append({"oc": oc, "pos": o})
			store[iid] = {"sig": h, "pos": o}
		else:
			prev["pos"] = o
	# Removed occluders: react around their LAST known position.
	var had_removal := false
	for iid in store.keys():
		if not seen.has(iid):
			changed.append({"oc": null, "pos": store[iid]["pos"]})
			store.erase(iid)
			had_removal = true
	# A removal together with brand-new occluders in the SAME frame is the
	# signature of wall/path recreation (DD frees & rebuilds the Line2D every
	# frame during a point edit) rather than fresh placement. Surface the new
	# occluders so nearby lights wake and their precise polygon drives the
	# affected test — otherwise the freed occluder's imprecise origin misses the
	# light and the shadow never updates until the drag ends.
	if had_removal:
		for item in fresh:
			changed.append(item)
	return changed

func _light_affected(light, changed: Array) -> bool:
	var radius = _light_radius(light) * 1.5
	var pos = light.global_position
	for item in changed:
		if item["oc"] != null and is_instance_valid(item["oc"]):
			if _occluder_near(item["oc"], pos, radius):
				return true
		elif item["pos"].distance_to(pos) < radius:
			return true
	return false

# TRUE if a NON-object occluder (wall / path / pattern) near the light changed
# or was removed. Only these require the region (Ignore Corners) to recompute:
# block-light OBJECTS are region-excluded (see light_region_geometry
# _build_barrier_solids) and move purely through the object-shadow fans, so an
# object-only drag must NOT trigger the expensive region rebuild every frame.
func _light_wall_changed(light, changed: Array) -> bool:
	var radius = _light_radius(light) * 1.5
	var pos = light.global_position
	for item in changed:
		var near := false
		if item["oc"] != null and is_instance_valid(item["oc"]):
			near = _occluder_near(item["oc"], pos, radius)
		else:
			near = item["pos"].distance_to(pos) < radius
		if not near:
			continue
		# A removed occluder (null) may have been a wall — stay safe, recompute.
		if item["oc"] == null or not _is_object_occluder(item["oc"]):
			return true
	return false

func on_update():
	_detect_light_copy()
	_update_preview()
	if _soft.empty():
		return
	var geo_changed := {}
	var geo_affected := []
	for nid in _soft.keys():
		if nid == PREVIEW_NID:
			continue  # handled by _update_preview
		var entry = _soft[nid]
		var light = _entry_light(nid, entry)
		var proxy = entry.get("proxy")
		if light == null:
			# Level-parented proxies outlive their light briefly: hide at once,
			# the monitor tick performs the full cleanup.
			if proxy != null and is_instance_valid(proxy):
				proxy.visible = false
			continue
		if proxy == null or not is_instance_valid(proxy) or entry["bypass"]:
			continue
		if _live_nid != nid:
			_sync_proxy(light, proxy, entry)
		var level = _light_level(light)
		var changed := false
		var wall_changed := false
		if level != null:
			var lid = level.get_instance_id()
			if not geo_changed.has(lid):
				geo_changed[lid] = _changed_occluders(level)
			if not geo_changed[lid].empty():
				changed = _light_affected(light, geo_changed[lid])
				if changed:
					wall_changed = _light_wall_changed(light, geo_changed[lid])
		# Numeric quick-signature (no per-frame string allocations). Energy is
		# deliberately ABSENT — flickering lights vary it every frame; it is
		# synced straight onto the proxy and never affects the shadow mask.
		var qpos = light.global_position.round()
		var qtex = light.texture.get_rid().get_id() if light.texture != null else 0
		if entry.get("qpos", Vector2.INF) != qpos or abs(entry.get("qrot", -1e9) - light.rotation) > 0.005 or abs(entry.get("qscale", -1e9) - light.texture_scale) > 0.005 or entry.get("qtex", -1) != qtex or changed:
			entry["qpos"] = qpos
			entry["qrot"] = light.rotation
			entry["qscale"] = light.texture_scale
			entry["qtex"] = qtex
			entry["sig"] = ""  # let the next tick recompute the full signature
			entry["moved_ms"] = OS.get_ticks_msec()
			if changed and wall_changed:
				# Wall/path/pattern near this light moved: mark a short active-drag
				# window so the region recomputes at REGION_DRAG_MS (30 Hz) instead
				# of every frame. Object-only moves keep the cached region entirely
				# and rebuild just the fans.
				entry["region_drag_until"] = OS.get_ticks_msec() + 200
			# LIGHT motion: exclusive live rig (viewport recreation, deferred
			# swap). GEOMETRY motion: affected lights refresh through
			# continuous FAST BAKES (mask -> final via the live shader
			# branch, ~3 frames each, sequential) — no shared-rig contention,
			# no cross-light frames, all affected lights follow fluidly.
			if changed:
				geo_affected.append(nid)
			elif not _request_live(nid, entry):
				_mark_dirty(nid)
		if _live_nid == nid:
			# The refresh runs DEFERRED: end of frame, AFTER DD's tools have
			# moved the light in their own _process, BEFORE rendering — the
			# mask and the proxy pin use the frame's final position (no
			# one-frame trail against the cursor).
			if not _live_deferred:
				_live_deferred = true
				call_deferred("_live_frame")
			if OS.get_ticks_msec() - int(entry.get("moved_ms", 0)) >= QUALITY_DELAY_MS:
				_exit_live()  # idle: freeze + queue the full-quality bake
	# GEOMETRY dispatch (object / wall / path motion): affected lights render
	# through the PARALLEL POOL — each borrows a dedicated mask+final viewport
	# pair and renders every frame, so any number up to POOL_MAX refresh at once,
	# instantly and flicker-free (each final samples only its own mask). Beyond
	# POOL_MAX, the extras fall back to sequential fast bakes. The exclusive
	# shared-mask live rig is reserved for LIGHT motion (predictive path) and is
	# never used here, so there is no ping-pong and no cross-light contamination.
	var now = OS.get_ticks_msec()
	if not geo_affected.empty():
		for gnid in geo_affected:
			var gentry = _soft.get(gnid)
			if gentry == null:
				continue
			gentry["moved_ms"] = now
			# Retention window: keep this light in the pool for POOL_HOLD_MS after
			# it last mattered, so a fast drag oscillating across the affected
			# radius doesn't churn acquire/release (each release baked an
			# object-excluded shadow for a few frames — the observed flicker).
			gentry["plive_hold_until"] = now + POOL_HOLD_MS
			if _live_nid == gnid:
				continue  # already rendered by the exclusive live rig this frame
			if not _plive_acquire(gnid, gentry):
				# Pool saturated: this light refreshes through fast bakes instead.
				gentry["fast_until"] = now + QUALITY_DELAY_MS
				_mark_dirty(gnid)
	# Release only lights whose retention window has expired; the rest stay
	# pooled and keep refreshing live (correct even while momentarily unaffected).
	_plive_release_expired(now)
	if not _plive.empty() and not _plive_deferred:
		_plive_deferred = true
		call_deferred("_plive_frame")

func _monitor_tick():
	# Watchdog: a runtime error inside the bake coroutine kills it silently,
	# leaving _bake_busy locked and freezing all future rebakes on the last
	# valid texture. Detect and self-heal.
	if _bake_busy and OS.get_ticks_msec() - _bake_started_ms > 3000:
		_log("WATCHDOG: bake coroutine died (check console for script errors above) — resetting", 0)
		_bake_busy = false
		call_deferred("_bake_next")
	if not _lt_built:
		_build_light_tool_ui()
	if not _st_built:
		_build_select_tool_ui()
	_scan_lights()
	_sync_soft_lights()

# Continuously remember the current selection when it is a clean set of
# CONFIGURED lights: that is the copy source, whether the user then copies via
# Ctrl+C or DD's Copy button. After a paste the selection becomes the clones
# (unconfigured), which fails the all-configured test, so the source is
# preserved for _process_light_clones. Selecting a KNOWN plain light clears the
# source so copying a non-SoftShadows light doesn't wrongly inherit a config.
func _detect_light_copy():
	if global.Editor == null or global.Editor.ActiveToolName != "SelectTool":
		return
	if not global.ModMapData.has(DATA_KEY) or global.ModMapData[DATA_KEY].empty():
		return  # no configured light anywhere: no possible clone source
	var tool = global.Editor.Tools.get("SelectTool")
	if tool == null or tool.Selected.size() == 0:
		return
	var ids := []
	var all_cfg := true
	var has_known_plain := false
	for sel in tool.Selected:
		if is_instance_valid(sel) and sel is Light2D and sel.has_meta("node_id"):
			var sid = str(sel.get_meta("node_id"))
			ids.append(sid)
			if _get_cfg(sid) == null:
				all_cfg = false
				if _known_ids.has(sid):
					has_known_plain = true
		else:
			all_cfg = false
	if all_cfg and ids.size() > 0:
		_copy_src_ids = ids
	elif has_known_plain:
		_copy_src_ids = []

# Resolve the lights collected by _scan_lights that appeared without config:
# copy/paste clones (Ctrl+C/V or DD's Copy/Paste buttons). Match each by index
# to the remembered copy source and clone that source's SoftShadows config.
func _process_light_clones():
	if _light_clone_batch.empty():
		return
	var batch = _light_clone_batch.duplicate()
	_light_clone_batch.clear()
	if _copy_src_ids.empty():
		return
	for i in range(batch.size()):
		var child = batch[i]
		if not is_instance_valid(child) or not child.has_meta("node_id"):
			continue
		var nid = str(child.get_meta("node_id"))
		if _get_cfg(nid) != null or i >= _copy_src_ids.size():
			continue
		var src = _copy_src_ids[i]
		if _get_cfg(src) != null:
			_save_cfg(nid, _saved_soft_clip(src), _saved_ignore(src), _saved_obj(src))
			_save_blur(nid, _saved_soft_walls(src), _saved_soft_obj(src))
			for vkey in _val_specs.keys():
				_save_val(nid, vkey, _saved_val(src, vkey))
			if _is_active(nid):
				_apply(child, nid)
				_finalize_placed(nid, child)
			_log("cloned light config %s <- %s" % [nid, src])

# Detect newly placed lights (stamp the tool defaults) and lights recreated by
# native undo/redo (same node_id, fresh instance, no proxy yet).
func _scan_lights():
	if global.World == null or global.World.Level == null:
		return
	var lights_node = global.World.Level.Lights
	if lights_node == null or not is_instance_valid(lights_node):
		return
	for child in lights_node.get_children():
		if not (child is Light2D):
			continue
		if child.has_meta("preview") and child.get_meta("preview"):
			continue
		var nid = _get_nid(child)
		if nid == "":
			continue
		if not _known_ids.has(nid):
			_known_ids[nid] = true
			if _is_active(nid):
				_apply(child, nid)
			elif (_tool_soft_clip or _tool_ignore) and global.Editor.ActiveToolName == "LightTool":
				if _entry_for_node(child) != "":
					continue  # already served under another nid (id reassigned)
				_save_cfg(nid, _tool_soft_clip, _tool_ignore, _tool_obj)
				_apply(child, nid)
				_finalize_placed(nid, child)
				_log("stamped new light %s clip=%s ignore=%s" % [nid, _tool_soft_clip, _tool_ignore])
			elif global.Editor.ActiveToolName != "LightTool":
				# New light with no config while NOT on the LightTool: a copy/paste
				# clone (Ctrl+C/V or DD's Copy/Paste buttons) — resolved against the
				# remembered copy source after the scan. A LightTool placement with
				# defaults off legitimately stays unconfigured and is skipped here.
				_light_clone_batch.append(child)
		elif _is_active(nid):
			var entry = _soft.get(nid)
			if entry == null or not is_instance_valid(entry.get("proxy")):
				_apply(child, nid)  # recreated by native undo/redo
	_process_light_clones()

# Keep proxies mirrored on their parents, honour the native per-light Shadow
# toggle (shadows off -> temporary native bypass), and queue rebakes whenever
# the per-light signature changes.
func _sync_soft_lights():
	if _soft.empty():
		return
	var stale := []
	for nid in _soft.keys():
		if nid == PREVIEW_NID:
			continue  # handled by _update_preview
		var entry = _soft[nid]
		var light = _entry_light(nid, entry)
		if light == null:
			stale.append(nid)
			continue
		var proxy = entry.get("proxy")
		if proxy == null or not is_instance_valid(proxy):
			stale.append(nid)
			continue
		# Native "Shadow" checkbox off -> nothing to clip: bypass to native.
		# (In wrap mode the region clip IS the shadow, so keep it active.)
		if not light.shadow_enabled:
			if not entry["bypass"]:
				entry["bypass"] = true
				_unpark(light)
				proxy.visible = false
			continue
		if entry["bypass"]:
			entry["bypass"] = false
			proxy.visible = true
			entry["sig"] = ""
		if light.range_item_cull_mask != PARKED_MASK or light.range_layer_min != PARKED_ZLAYER:
			_park(light)
		if _live_nid == nid:
			continue  # live mode renders continuously; the deferred frame owns the sync
		_sync_proxy(light, proxy, entry)
		var level = _light_level(light)
		if level == null:
			continue
		var sig = _signature(light, nid, _cached_occluders(level))
		if sig != entry["sig"]:
			entry["sig"] = sig
			_mark_dirty(nid)
	for nid in stale:
		var entry = _soft[nid]
		var proxy = entry.get("proxy")
		if proxy != null and is_instance_valid(proxy):
			proxy.free()
		var vp = entry.get("vp")
		if vp != null and is_instance_valid(vp):
			vp.free()
		if entry.get("old_vp") != null and is_instance_valid(entry["old_vp"]):
			entry["old_vp"].free()
		_soft.erase(nid)

func _find_light(nid: String):
	if not global.World.HasNodeID(int(nid)):
		return null
	var node = global.World.GetNodeByID(int(nid))
	if node != null and is_instance_valid(node) and node is Light2D:
		return node
	return null

# Cached variant: avoids the per-frame C#-boundary ID lookups (HasNodeID +
# GetNodeByID per light per frame was this codebase's documented FPS killer).
# Reverse lookup: is this node already served by an entry (whatever its key)?
func _entry_for_node(node) -> String:
	for nid in _soft.keys():
		if _soft[nid].get("node") == node:
			return nid
	return ""

func _entry_light(nid: String, entry):
	var node = entry.get("node")
	if node != null and is_instance_valid(node):
		return node
	if nid == PREVIEW_NID:
		return null  # preview node is managed by _update_preview only
	node = _find_light(nid)
	entry["node"] = node
	return node

# Placement finalization, shared by all three detection paths (preview
# promotion handover, node_added, periodic scan): park the light, borrow the
# rig for ONE frame to render it at its REAL grid-snapped position, freeze,
# and queue the quality bake.
func _finalize_placed(nid: String, node):
	var entry = _soft.get(nid)
	if entry == null or not is_instance_valid(entry.get("proxy")) or not is_instance_valid(node):
		return
	entry["node"] = node
	entry["sig"] = ""
	_park(node)
	_enter_live(nid, entry)
	_live_priority = true  # transient one-frame hold, released next tick
	_prepare_mask(nid, entry, node, true)
	entry["moved_ms"] = 0  # already still: next tick exits live and queues quality
	_mark_dirty(nid)
	_log("placed light %s finalized (clip=%s ignore=%s)" % [nid, _tool_soft_clip, _tool_ignore])

# Same-frame stamping of newly placed lights (no 0.25s scan window, no race
# against the live preview). The periodic scan remains as a safety net.
#########################################################################################################
##
## LIGHT TOOL PREVIEW
##
#########################################################################################################

# The Light tool preview light gets the configured options in real time,
# driven by the tool-panel defaults, torn down on placement or tool exit.
func _update_preview():
	var tool = global.Editor.Tools.get("LightTool")
	var native_shadows = tool != null and bool(tool.Shadows)
	var wanted = global.Editor.ActiveToolName == "LightTool" and native_shadows and (_tool_soft_clip or _tool_ignore)
	var entry = _soft.get(PREVIEW_NID)
	# PROMOTION (the real DD flow, LightTool.cs:126-137): on click the
	# preview node itself is placed — meta cleared, node_id assigned
	# synchronously, tool.preview set to null (a new preview appears on the
	# next mouse event). Detect it FIRST and hand the entry over instead of
	# tearing it down: the placed light keeps its proxy, viewport and content
	# (centred on the click position) with zero interruption.
	if entry != null:
		var enode = entry.get("node")
		if enode != null and is_instance_valid(enode) and not (enode.has_meta("preview") and enode.get_meta("preview")):
			var pid = _get_nid(enode)
			if _live_nid == PREVIEW_NID:
				_exit_live()
			_soft.erase(PREVIEW_NID)
			if pid != "" and not _soft.has(pid):
				_soft[pid] = entry
				if not _is_active(pid):
					_save_cfg(pid, _tool_soft_clip, _tool_ignore, _tool_obj)
				_finalize_placed(pid, enode)
			else:
				# id collision or unexpected state: drop our nodes cleanly
				if is_instance_valid(entry.get("proxy")):
					entry["proxy"].free()
				if is_instance_valid(entry.get("vp")):
					entry["vp"].free()
				_unpark(enode)
			entry = null
	if not wanted:
		if entry != null:
			_teardown_preview()
		return
	var pv = _find_preview_light()
	if pv == null:
		if entry != null:
			_teardown_preview()
		return
	if entry == null or entry.get("node") != pv or not is_instance_valid(entry.get("proxy")):
		_teardown_preview()
		_build_rig()
		var proxy = _make_proxy(pv)
		var final = _make_final_vp()
		proxy.texture = final["vp"].get_texture()
		entry = {"proxy": proxy, "sig": "", "bypass": false, "node": pv, "vp": final["vp"], "sprite": final["sprite"], "mat": final["mat"]}
		_soft[PREVIEW_NID] = entry
	_park(pv)
	entry["node"] = pv
	var now = OS.get_ticks_msec()
	if entry.get("pv_pos", Vector2.INF) != pv.global_position:
		entry["pv_pos"] = pv.global_position
		entry["pv_moved_ms"] = now
	if now - int(entry.get("pv_moved_ms", 0)) < QUALITY_DELAY_MS:
		_request_live(PREVIEW_NID, entry)
		if not _live_deferred:
			_live_deferred = true
			call_deferred("_live_frame")
	elif _live_nid == PREVIEW_NID:
		# Mouse idle: freeze the preview (content is static and correct) so
		# queued bakes of freshly placed lights can run instead of starving.
		_exit_live()

func _find_preview_light():
	if global.World == null or global.World.Level == null:
		return null
	var lights_node = global.World.Level.Lights
	if lights_node == null or not is_instance_valid(lights_node):
		return null
	for child in lights_node.get_children():
		if child is Light2D and child.has_meta("preview") and child.get_meta("preview"):
			return child
	return null

func _teardown_preview():
	var entry = _soft.get(PREVIEW_NID)
	if entry == null:
		return
	if _live_nid == PREVIEW_NID:
		_exit_live()
	var proxy = entry.get("proxy")
	if proxy != null and is_instance_valid(proxy):
		proxy.free()
	var vp = entry.get("vp")
	if vp != null and is_instance_valid(vp):
		vp.free()
	var node = entry.get("node")
	if node != null and is_instance_valid(node):
		_unpark(node)
	_soft.erase(PREVIEW_NID)

func _light_level(light):
	# Lights are always children of the level's Lights node.
	var lights_node = light.get_parent()
	if lights_node == null:
		return null
	return lights_node.get_parent()

#########################################################################################################
##
## OCCLUDER GATHERING & SIGNATURE
##
#########################################################################################################

# All LightOccluder2D nodes visible in the level subtree: walls (always),
# closed portals, block-light objects and paths — one generic pass.
func _collect_occluders(level) -> Array:
	var out := []
	_collect_occluders_rec(level, out)
	return out

# TTL cache of the per-level occluder list: the full recursive traversal ran
# 4x/s per tick AND once per bake, which does not scale with map size.
func _cached_occluders(level) -> Array:
	var lid = level.get_instance_id()
	var now = OS.get_ticks_msec()
	var slot = _occ_cache.get(lid)
	if slot != null and now - int(slot["ms"]) < OCC_CACHE_MS:
		var ok = true
		for oc in slot["list"]:
			if not is_instance_valid(oc):
				ok = false  # walls recreate occluders during edits: refresh now
				break
		if ok:
			return slot["list"]
		elif OCC_DIAG:
			_occ_inval_n += 1
	var t0 = OS.get_ticks_usec() if OCC_DIAG else 0
	var list = _collect_occluders(level)
	if OCC_DIAG:
		_occ_diag_us += OS.get_ticks_usec() - t0
		_occ_diag_n += 1
		if now - _occ_diag_ms >= 500:
			_log("OCC recollect=%d/0.5s inval=%d avg=%.2fms occ=%d" % [_occ_diag_n, _occ_inval_n, float(_occ_diag_us) / max(1, _occ_diag_n) / 1000.0, list.size()], 0)
			_occ_diag_ms = now
			_occ_diag_us = 0
			_occ_diag_n = 0
			_occ_inval_n = 0
	_occ_cache[lid] = {"list": list, "ms": now}
	return list

func _collect_occluders_rec(node, out: Array):
	if node is Viewport:
		return
	if node is LightOccluder2D:
		if node.is_visible_in_tree() and node.occluder != null and node.occluder.polygon.size() >= 2:
			out.append(node)
		return
	for child in node.get_children():
		_collect_occluders_rec(child, out)

func _light_radius(light) -> float:
	if light.texture == null:
		return 256.0
	return light.texture_scale * float(light.texture.get_width()) * 0.5

func _occluder_near(occluder, center: Vector2, radius: float) -> bool:
	var xf = occluder.global_transform
	var pts = occluder.occluder.polygon
	var r2 = (radius + SEG_MARGIN) * (radius + SEG_MARGIN)
	for p in pts:
		if xf.xform(p).distance_squared_to(center) <= r2:
			return true
	return false

func _signature(light, nid: String, occluders: Array) -> String:
	var pos = light.global_position
	var tex_path = "" if light.texture == null else light.texture.resource_path
	var sig = "%.0f,%.0f|%.2f|%s|%.4f|%s|%s|%s" % [pos.x, pos.y, light.rotation, tex_path, light.texture_scale, _saved_soft_clip(nid), _saved_ignore(nid), _saved_obj(nid)]
	var radius = _light_radius(light) * 1.5
	var acc := 0
	var count := 0
	for oc in occluders:
		if not is_instance_valid(oc):
			continue
		if not _occluder_near(oc, pos, radius):
			continue
		count += 1
		var o = oc.global_transform.origin
		acc += int(o.x * 8.0) + int(o.y * 8.0) * 31 + oc.occluder.polygon.size() * 977
	return sig + "|%d|%d" % [count, acc]

#########################################################################################################
##
## REGION ENGINE (Wrap Corners mode)
##
#########################################################################################################

# Lazy-loads the light-semantics fork of the region engine (expanding-window
# subtraction, bridged holes). Returns a stub yielding empty regions if the
# file is missing, so bakes fall back to unclipped instead of crashing.
func _region_engine():
	if _rg == null:
		var script = ResourceLoader.load(global.Root + "light_region_geometry.gd", "GDScript", true)
		if script != null:
			_rg = script.new()
			_rg._g = global
			_log("region engine loaded (%s)" % _rg.RG_VERSION, 0)
		else:
			_log("WARNING: light_region_geometry.gd not found, Wrap Corners disabled", 0)
			_rg = _EmptyRegionStub.new()
	return _rg

class _EmptyRegionStub:
	func compute_region(_p, _a, _b, _c) -> Dictionary:
		return {"outer": [], "holes": [], "cancelled": false}

#########################################################################################################
##
## BAKE
##
#########################################################################################################

func _bake_next():
	if _bake_busy or _bake_queue.empty():
		return
	_bake_busy = true
	_bake_started_ms = OS.get_ticks_msec()
	var nid = _bake_queue.pop_front()
	_bake(nid)

# Projected shadow fans. FAR CAP AS A FAN, not a chord: for wide wedges
# (light close to a long wall, angular span approaching 180°) the straight
# chord between the two endpoint projections passes at only cos(span/2) * far
# from the light — INSIDE the viewport — and everything beyond it was
# uncovered (verified numerically on dumped geometry).
# Occluders belonging to block-light OBJECTS (Prop footprints) go to the G
# channel (Softer Object Shadow); walls & paths go to R (Soft Clipping).
func _is_object_occluder(oc) -> bool:
	var parent = oc.get_parent()
	return parent != null and parent.get("Mirror") != null and parent.get_class() != "Line2D"

# objects_only: restrict to object occluders, used by the Keep Object Shadows
# option in Ignore Corners mode.
func _add_shadow_fans_on(mvp, mpolys: Array, occluders: Array, center_world: Vector2, d_world: float, to_bake: float, bake_center: Vector2, poly_index: int, objects_only: bool, obj_shrink: float = OBJ_SHRINK, region_outer = null) -> int:
	var far = d_world * 1.5
	for oc in occluders:
		var is_object = _is_object_occluder(oc)
		if objects_only and not is_object:
			continue
		var channel = Color(0, 1, 0, 1) if is_object else Color(1, 0, 0, 1)
		var xf = oc.global_transform
		var world := PoolVector2Array()
		for p in oc.occluder.polygon:
			world.append(xf.xform(p))
		# Ignore Corners: an object whose footprint centre lies OUTSIDE the lit
		# region (i.e. behind an unlit wall) must not cast a shadow.
		if is_object and region_outer != null and region_outer.size() >= 3 and world.size() > 0:
			var c := Vector2.ZERO
			for wp in world:
				c += wp
			c /= world.size()
			if not Geometry.is_point_in_polygon(c, region_outer):
				continue
		var rings := [world]
		var closed = oc.occluder.closed
		# Object footprints deflated inward by obj_shrink so the shadow hugs the
		# sprite instead of starting at the occluder outline.
		if is_object and closed and world.size() >= 3 and obj_shrink > 0.01:
			var shrunk = Geometry.offset_polygon_2d(world, -obj_shrink)
			if shrunk.size() > 0:
				rings = shrunk
		for ring in rings:
			var n = ring.size()
			var edges = n if closed else n - 1
			for i in range(edges):
				var a = ring[i]
				var b = ring[(i + 1) % n]
				var da = a - center_world
				var db = b - center_world
				if da.length_squared() < 4.0 or db.length_squared() < 4.0:
					continue
				var fan := [
					(a - center_world) * to_bake + bake_center,
					(b - center_world) * to_bake + bake_center
				]
				for s in range(5):
					var t = 1.0 - float(s) / 4.0
					var d = (a + (b - a) * t) - center_world
					fan.append(d.normalized() * far * to_bake + bake_center)
				_set_mask_poly_on(mvp, mpolys, poly_index, PoolVector2Array(fan), channel, _mat_add)
				poly_index += 1
	return poly_index

# Map bounds in world px (DD cells are 256 px). Fallback: unbounded.
func _map_rect() -> Rect2:
	var w = global.World.get("Width")
	var h = global.World.get("Height")
	if w == null or h == null:
		return Rect2(Vector2(-1e9, -1e9), Vector2(2e9, 2e9))
	return Rect2(Vector2.ZERO, Vector2(float(w), float(h)) * 256.0)

# Mask preparation (live mode + bake): rebuilds the mask polygons, blur
# parameters and the light's final sprite. Returns true on success. In live
# mode the (CPU-cheap) fan rebuild runs every frame; the region computation is
# throttled to REGION_LIVE_MS. `target` selects where to render: the shared rig
# (default) or a parallel-pool slot {mvp,mbg,mpolys,mat,sprite}.
func _prepare_mask(nid: String, entry, light, live: bool, center_override = null, target = null) -> bool:
	_build_rig()
	if target == null:
		target = {"mvp": _vp_mask, "mbg": _mask_bg, "mpolys": _mask_polys, "mat": entry["mat"], "sprite": entry["sprite"]}
	var center_world = center_override if center_override != null else light.global_position
	var d_world = _light_radius(light) * 2.0
	if d_world < 1.0:
		return false
	var to_bake = float(BAKE_RES) / d_world
	var bake_center = Vector2(BAKE_RES, BAKE_RES) * 0.5
	var wrap = _saved_ignore(nid)

	var level = _light_level(light)
	var near := []
	if level != null:
		var gather_radius = d_world * 0.75
		for oc in _cached_occluders(level):
			if is_instance_valid(oc) and _occluder_near(oc, center_world, gather_radius):
				near.append(oc)

	var soft_walls = _saved_soft_walls(nid) if _saved_soft_clip(nid) else 0.0
	var soft_objects = _saved_soft_obj(nid) if _saved_soft_clip(nid) else 0.0
	var obj_shadows = _saved_obj(nid)
	var obj_shrink = _saved_val(nid, "obj_shrink")
	var poly_index := 0
	if wrap:
		var now = OS.get_ticks_msec()
		var region = entry.get("region")
		var moved = entry.get("region_center", Vector2.INF).distance_squared_to(center_world) > 0.25
		var interval = REGION_DRAG_MS if int(entry.get("region_drag_until", 0)) > now else REGION_LIVE_MS
		if region == null or not live or moved or now - int(entry.get("region_ms", 0)) >= interval:
			var t0 = OS.get_ticks_usec() if REGION_DIAG else 0
			region = _region_engine().compute_region(center_world, true, true, false)
			if REGION_DIAG and live:
				_region_diag_us += OS.get_ticks_usec() - t0
				_region_diag_n += 1
				if now - _region_diag_ms >= 500:
					_log("REGION compute avg=%.2fms n=%d/0.5s" % [float(_region_diag_us) / max(1, _region_diag_n) / 1000.0, _region_diag_n], 0)
					_region_diag_ms = now
					_region_diag_us = 0
					_region_diag_n = 0
			entry["region"] = region
			entry["region_ms"] = now
			entry["region_center"] = center_world
		target["mbg"].color = Color(1, 0, 0, 1)
		var outer = region.get("outer", [])
		if outer.size() < 3:
			target["mbg"].color = Color(0, 0, 0, 1)
			if not live:
				_log("light %s: wrap fallback to unclipped (empty region)" % nid)
		else:
			_set_mask_poly_on(target["mvp"], target["mpolys"], poly_index, _to_bake_space(outer, center_world, to_bake, bake_center), Color(0, 0, 0, 1))
			poly_index += 1
		if obj_shadows:
			var region_outer = outer if outer.size() >= 3 else null
			poly_index = _add_shadow_fans_on(target["mvp"], target["mpolys"], near, center_world, d_world, to_bake, bake_center, poly_index, true, obj_shrink, region_outer)
	else:
		target["mbg"].color = Color(0, 0, 0, 1)
		poly_index = _add_shadow_fans_on(target["mvp"], target["mpolys"], near, center_world, d_world, to_bake, bake_center, poly_index, false, obj_shrink)
	_hide_mask_polys_on(target["mpolys"], poly_index)

	var sprite = target["sprite"]
	sprite.texture = light.texture
	sprite.rotation = light.global_rotation
	if light.texture != null:
		var s = float(BAKE_RES) / float(light.texture.get_width())
		sprite.scale = Vector2(s, -s)
	sprite.position = Vector2(BAKE_RES, BAKE_RES) * 0.5
	var blur_r = (soft_walls * MAX_BLUR_WORLD * to_bake) / float(BAKE_RES) / sqrt(3.0)
	var blur_g = (soft_objects * MAX_BLUR_WORLD * to_bake) / float(BAKE_RES) / sqrt(3.0)
	if live:
		target["mat"].set_shader_param("blur_r", (soft_walls * MAX_BLUR_WORLD * to_bake) / float(BAKE_RES))
		target["mat"].set_shader_param("blur_g", (soft_objects * MAX_BLUR_WORLD * to_bake) / float(BAKE_RES))
	else:
		for mat in _blur_mats:
			mat.set_shader_param("blur_r", blur_r)
			mat.set_shader_param("blur_g", blur_g)
		target["mat"].set_shader_param("mask_tex", _blur_vps[5].get_texture())
	var mr = _map_rect()
	var target_mat = target["mat"]
	target_mat.set_shader_param("world_center", center_world)
	target_mat.set_shader_param("inv_to_bake", 1.0 / to_bake)
	target_mat.set_shader_param("map_min", mr.position)
	target_mat.set_shader_param("map_max", mr.end)
	target_mat.set_shader_param("border_band", max(soft_walls, soft_objects) * MAX_BLUR_WORLD)
	entry["proxy"].texture_scale = d_world / float(BAKE_RES)
	entry["mask_center"] = center_world
	if not live:
		entry["proxy"].global_position = center_world
	return true

# ── LIVE MODE: the whole rig renders every frame for one moving light ──
# The live rig belongs to the light the USER is driving: the preview or a
# selected light. Changes on other lights (flickering prefabs animate
# position/scale every frame) must never steal it — they get a quality bake
# instead. Without this, placing one flickering light desynced every other
# moving light's shadows (rig thrashing, one frame out of two).
func _is_priority(nid: String, entry) -> bool:
	if nid == PREVIEW_NID:
		return true
	var node = entry.get("node")
	if node == null or not is_instance_valid(node):
		return false
	var tool = global.Editor.Tools.get("SelectTool")
	if tool == null:
		return false
	return tool.Selected.has(node)

func _request_live(nid: String, entry, recreate: bool = true) -> bool:
	if _live_nid == nid:
		return true
	var pri = _is_priority(nid, entry)
	if _live_nid != "" and _live_priority and not pri:
		return false  # a user-driven light holds the rig: don't steal
	_enter_live(nid, entry, recreate)
	_live_priority = pri
	return true

func _diag_transition(kind: String, nid: String):
	_diag_transitions += 1
	var now = OS.get_ticks_msec()
	if now - _diag_last_log >= 200:
		_log("LIVETRACE %s %s (transitions=%d, live=%s, queue=%d, busy=%s)" % [kind, nid, _diag_transitions, _live_nid, _bake_queue.size(), _bake_busy], 0)
		_diag_last_log = now

func _enter_live(nid: String, entry, recreate: bool = true):
	if _live_nid == nid:
		return
	# The exclusive rig supersedes the parallel pool for this light: drop its
	# slot at once (proxy is re-pointed at the exclusive final below).
	if entry.get("slot") != null:
		_pool_free(entry["slot"])
		entry.erase("slot")
		entry.erase("slot_release")
		_plive.erase(nid)
	_diag_transition("enter", nid)
	if _live_nid != "":
		_exit_live()
	_live_nid = nid
	entry["chist"] = []  # fresh pin history for this session
	if not recreate:
		# Rotation across STATIC lights (geometry motion): their centre is
		# fixed, so RID-order content lag can only show as an invisible
		# one-frame shape morph — no recreation needed, cheap switches.
		entry["mat"].set_shader_param("live", 1.0)
		if is_instance_valid(entry.get("proxy")) and is_instance_valid(entry.get("vp")):
			entry["proxy"].texture = entry["vp"].get_texture()
			if is_instance_valid(_vp_mask):
				if _vp_mask.get_parent() != entry["vp"]:
					_vp_mask.get_parent().remove_child(_vp_mask)
					entry["vp"].add_child(_vp_mask)
				_vp_mask.render_target_update_mode = Viewport.UPDATE_ALWAYS
				entry["vp"].render_target_update_mode = Viewport.UPDATE_ALWAYS
		return
	# Recreate this light's final viewport: render targets are processed in
	# CREATION (RID) order, and only the freshest-created viewport reliably
	# samples the same-frame mask on this GPU (empirically established). A
	# few ms once per drag start.
	var old_vp = entry.get("vp")
	if old_vp != null and is_instance_valid(old_vp) and is_instance_valid(_vp_mask) and _vp_mask.get_parent() == old_vp:
		old_vp.remove_child(_vp_mask)
		global.Editor.add_child(_vp_mask)
	var fresh = _make_final_vp()
	entry["vp"] = fresh["vp"]
	entry["sprite"] = fresh["sprite"]
	entry["mat"] = fresh["mat"]
	entry["mat"].set_shader_param("live", 1.0)
	# DEFERRED SWAP: the proxy keeps showing the OLD viewport (frozen but
	# correct) until the fresh one has rendered its first frame — swapping
	# immediately flashed the light black for an instant on every live entry.
	entry["old_vp"] = old_vp
	entry["vp_warm"] = false
	# Nest the mask under this light's final viewport (children render before
	# their parent), then run both every frame.
	_vp_mask.get_parent().remove_child(_vp_mask)
	entry["vp"].add_child(_vp_mask)
	_vp_mask.render_target_update_mode = Viewport.UPDATE_ALWAYS
	entry["vp"].render_target_update_mode = Viewport.UPDATE_ALWAYS

# End-of-frame live refresh: reads the light's FINAL position of the frame.
func _live_frame():
	_live_deferred = false
	if _live_nid == "":
		return
	var entry = _soft.get(_live_nid)
	if entry == null:
		return
	var light = entry.get("node")
	if light == null or not is_instance_valid(light):
		return
	if is_instance_valid(entry.get("proxy")):
		_sync_proxy(light, entry["proxy"], entry)
	# CONTENT-LAG PINNING (build 60): pin the proxy to the centre whose
	# content is currently on screen; shadows stay wall-aligned, the disc
	# trails by one uniform frame.
	_prepare_mask(_live_nid, entry, light, true)
	# Deferred viewport swap: first live frame warms the fresh viewport, the
	# second one switches the proxy over and frees the old target.
	if not entry.get("vp_warm", true):
		entry["vp_warm"] = true
	elif entry.get("old_vp") != null:
		if is_instance_valid(entry.get("proxy")) and is_instance_valid(entry.get("vp")):
			entry["proxy"].texture = entry["vp"].get_texture()
		if is_instance_valid(entry["old_vp"]):
			entry["old_vp"].free()
		entry["old_vp"] = null
	var hist = entry.get("chist", [])
	hist.append(light.global_position)
	while hist.size() > CONTENT_LAG + 1:
		hist.pop_front()
	entry["chist"] = hist
	if is_instance_valid(entry.get("proxy")):
		entry["proxy"].global_position = hist[0]

# Exiting live freezes the display and queues a full-quality sequential bake
# (3-iteration chain) to replace the single-pass live frame.
func _exit_live():
	if _live_nid == "":
		return
	_diag_transition("exit", _live_nid)
	var nid = _live_nid
	var entry = _soft.get(nid)
	_vp_mask.render_target_update_mode = Viewport.UPDATE_DISABLED
	if entry != null:
		if entry.get("mat") != null:
			entry["mat"].set_shader_param("live", 0.0)
		if is_instance_valid(entry.get("vp")):
			entry["vp"].render_target_update_mode = Viewport.UPDATE_DISABLED
	if is_instance_valid(_vp_mask) and _vp_mask.get_parent() != global.Editor:
		_vp_mask.get_parent().remove_child(_vp_mask)
		global.Editor.add_child(_vp_mask)
	_live_nid = ""
	_live_priority = false
	if entry != null and nid != PREVIEW_NID:
		_mark_dirty(nid)
	call_deferred("_bake_next")

#########################################################################################################
##
## PARALLEL LIVE POOL (multi-light geometry drag)
##
## A small pool of dedicated mask+final viewport pairs so several affected
## lights render at once, every frame, instead of serialising through the one
## shared mask. Each pair is self-contained: the mask is nested under a final
## viewport CREATED AFTER it, so the final always samples its own same-frame
## mask (RID order fixed and correct) — no cross-light contamination, no
## flicker. Live-only (single-pass inline blur); the shared blur chain is
## untouched and still serves the full-quality bakes.
##
#########################################################################################################

func _make_pool_slot() -> Dictionary:
	var size = Vector2(BAKE_RES, BAKE_RES)
	# Dedicated mask viewport (created FIRST → lower RID than its final).
	var mvp = Viewport.new()
	mvp.size = size
	mvp.usage = Viewport.USAGE_2D
	mvp.disable_3d = true
	mvp.render_target_v_flip = false
	mvp.render_target_update_mode = Viewport.UPDATE_DISABLED
	mvp.gui_disable_input = true
	var mbg = ColorRect.new()
	mbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mbg.color = Color(0, 0, 0, 1)
	mbg.rect_size = size
	mvp.add_child(mbg)
	# Dedicated final viewport (created AFTER the mask → higher RID; the mask is
	# nested under it so it renders before, consumed same-frame, reliably).
	var fvp = Viewport.new()
	fvp.size = size
	fvp.usage = Viewport.USAGE_2D
	fvp.disable_3d = true
	fvp.transparent_bg = true
	fvp.render_target_v_flip = false
	fvp.render_target_update_mode = Viewport.UPDATE_DISABLED
	fvp.gui_disable_input = true
	var fmat = ShaderMaterial.new()
	fmat.shader = _final_shader
	fmat.set_shader_param("mask_tex", mvp.get_texture())
	fmat.set_shader_param("hard_tex", mvp.get_texture())
	fmat.set_shader_param("hard_clamp", 1.0 if HARD_CLAMP else 0.0)
	fmat.set_shader_param("debug_mask", 1.0 if DEBUG_SHOW_MASK else 0.0)
	fmat.set_shader_param("live", 1.0)
	var fsprite = Sprite.new()
	fsprite.material = fmat
	fsprite.position = size * 0.5
	fvp.add_child(fsprite)
	global.Editor.add_child(fvp)
	fvp.add_child(mvp)  # nest the mask under the final
	mvp.get_texture().flags = Texture.FLAG_FILTER
	fvp.get_texture().flags = Texture.FLAG_FILTER
	return {"mvp": mvp, "mbg": mbg, "mpolys": [], "fvp": fvp, "fmat": fmat, "fsprite": fsprite, "nid": "", "warm": false}

func _slot_target(slot) -> Dictionary:
	return {"mvp": slot["mvp"], "mbg": slot["mbg"], "mpolys": slot["mpolys"], "mat": slot["fmat"], "sprite": slot["fsprite"]}

# Return a free slot (reusing an idle one, else growing the pool up to
# POOL_MAX). Empty dict when the pool is saturated.
func _pool_acquire() -> Dictionary:
	for slot in _pool:
		if slot["nid"] == "":
			return slot
	if _pool.size() < POOL_MAX:
		_build_rig()
		var slot = _make_pool_slot()
		_pool.append(slot)
		if PLIVE_DIAG:
			_log("pool grew to %d slots" % _pool.size(), 0)
		return slot
	return {}

func _pool_free(slot):
	if slot == null:
		return
	slot["mvp"].render_target_update_mode = Viewport.UPDATE_DISABLED
	slot["fvp"].render_target_update_mode = Viewport.UPDATE_DISABLED
	_hide_mask_polys_on(slot["mpolys"], 0)
	slot["nid"] = ""
	slot["warm"] = false

# Put a light into parallel-live (borrowing a pool slot). Returns false only
# when the pool is saturated, so the caller can fall back to fast bakes.
func _plive_acquire(nid: String, entry) -> bool:
	var slot = entry.get("slot")
	if slot != null:
		entry.erase("slot_release")  # re-affected before a pending release completed
		if not _plive.has(nid):
			_plive.append(nid)
		return true
	slot = _pool_acquire()
	if slot.empty():
		return false
	slot["nid"] = nid
	slot["warm"] = false
	slot["mvp"].render_target_update_mode = Viewport.UPDATE_ALWAYS
	slot["fvp"].render_target_update_mode = Viewport.UPDATE_ALWAYS
	entry["slot"] = slot
	entry.erase("slot_release")
	if not _plive.has(nid):
		_plive.append(nid)
	return true

# Stop refreshing a light and, once its full-quality bake has swapped in (in
# _bake), free the slot — no black pop. quality=false frees immediately.
func _plive_release(nid: String, entry, quality := true):
	var slot = entry.get("slot")
	if slot == null:
		_plive.erase(nid)
		return
	_plive.erase(nid)
	if quality:
		entry["slot_release"] = true
		_mark_dirty(nid)
	else:
		_pool_free(slot)
		entry.erase("slot")
		entry.erase("slot_release")

func _plive_release_expired(now: int):
	for nid in _plive.duplicate():
		var entry = _soft.get(nid)
		if entry == null:
			_plive.erase(nid)
			continue
		if int(entry.get("plive_hold_until", 0)) <= now:
			_plive_release(nid, entry, true)

# End-of-frame refresh for every pooled light: each renders into its own slot,
# all in parallel this frame. One warm frame before the proxy is pointed at the
# fresh slot output, so a drag start never shows the slot's stale/blank content.
func _plive_frame():
	_plive_deferred = false
	for nid in _plive.duplicate():
		var entry = _soft.get(nid)
		var slot = entry.get("slot") if entry != null else null
		if entry == null or slot == null:
			_plive.erase(nid)
			continue
		var light = entry.get("node")
		if light == null or not is_instance_valid(light) or not is_instance_valid(entry.get("proxy")):
			continue
		_sync_proxy(light, entry["proxy"], entry)
		_prepare_mask(nid, entry, light, true, null, _slot_target(slot))
		if not slot["warm"]:
			slot["warm"] = true
		else:
			entry["proxy"].texture = slot["fvp"].get_texture()
	if PLIVE_DIAG and not _plive.empty():
		var now = OS.get_ticks_msec()
		if now - _plive_diag_ms >= 250:
			_plive_diag_ms = now
			_log("PLIVE active=%d pool=%d" % [_plive.size(), _pool.size()], 0)

# Coroutine: sequential bake for idle/geometry changes (latency invisible,
# ordering guaranteed by per-pass yields). Live mode handles motion.
func _bake(nid: String):
	# The shared rig belongs to the live light while one is moving: defer.
	if _live_nid != "":
		if not _bake_queue.has(nid):
			_bake_queue.append(nid)
		_bake_busy = false
		return
	var light = _find_light(nid)
	var entry = _soft.get(nid)
	if light == null or entry == null or not is_instance_valid(entry.get("proxy")) or entry["bypass"]:
		_bake_busy = false
		call_deferred("_bake_next")
		return
	var fast = OS.get_ticks_msec() < int(entry.get("fast_until", 0))
	if not _prepare_mask(nid, entry, light, fast):
		_bake_busy = false
		call_deferred("_bake_next")
		return
	if fast:
		# FAST BAKE: mask -> final only, through the final shader's inline
		# live blur (no gaussian chain): ~3 frames per refresh during
		# geometry motion; the quality pass replaces it once settled.
		entry["mat"].set_shader_param("live", 1.0)
		_vp_mask.render_target_update_mode = Viewport.UPDATE_ONCE
		yield(global.Editor.get_tree(), "idle_frame")
		entry = _soft.get(nid)
		if entry != null and is_instance_valid(entry.get("vp")) and _live_nid == "":
			entry["vp"].render_target_update_mode = Viewport.UPDATE_ONCE
			yield(global.Editor.get_tree(), "idle_frame")
		_bake_busy = false
		call_deferred("_bake_next")
		return
	entry["mat"].set_shader_param("live", 0.0)
	# Render the mask TWICE: a Polygon2D geometry change (e.g. Shrink) only
	# re-tessellates on its first draw, so the first render still carries the
	# previous geometry. The second render captures the fresh shape — otherwise
	# a shape-only change needed a second bake (second click) to show up.
	_vp_mask.render_target_update_mode = Viewport.UPDATE_ONCE
	yield(global.Editor.get_tree(), "idle_frame")
	_vp_mask.render_target_update_mode = Viewport.UPDATE_ONCE
	yield(global.Editor.get_tree(), "idle_frame")
	for vp in _blur_vps:
		if _live_nid != "":
			break
		vp.render_target_update_mode = Viewport.UPDATE_ONCE
		yield(global.Editor.get_tree(), "idle_frame")
	entry = _soft.get(nid)
	if entry != null and is_instance_valid(entry.get("vp")) and _live_nid == "":
		entry["vp"].render_target_update_mode = Viewport.UPDATE_ONCE
		yield(global.Editor.get_tree(), "idle_frame")
		entry = _soft.get(nid)
		if entry != null and is_instance_valid(entry.get("proxy")) and is_instance_valid(entry.get("vp")):
			# If the light re-entered the parallel pool during this bake, leave the
			# proxy on its slot output; otherwise swap to the freshly baked final.
			if not _plive.has(nid):
				entry["proxy"].texture = entry["vp"].get_texture()
			if entry.get("old_vp") != null and is_instance_valid(entry["old_vp"]):
				entry["old_vp"].free()
			entry["old_vp"] = null
			entry["proxy"].texture_scale = _light_radius(_find_light(nid)) * 2.0 / float(BAKE_RES) if _find_light(nid) != null else entry["proxy"].texture_scale
			# Parallel-pool teardown: the proxy now shows the freshly baked final,
			# so the borrowed slot can be released with no black pop.
			if not _plive.has(nid) and entry.get("slot_release") and entry.get("slot") != null:
				_pool_free(entry["slot"])
				entry.erase("slot")
				entry.erase("slot_release")
		_log("bake done %s" % nid, 2)
	_bake_busy = false
	call_deferred("_bake_next")

func _to_bake_space(points, center: Vector2, to_bake: float, bake_center: Vector2) -> PoolVector2Array:
	var out := PoolVector2Array()
	for p in points:
		out.append((p - center) * to_bake + bake_center)
	return out

#########################################################################################################
##
## LIGHT TOOL UI
##
#########################################################################################################

# Insert our container right after the row containing the given native
# anchor control (the vanilla Shadow toggle). The anchor may be nested in a
# label row: walk up to the direct child of the vbox. Fallback: appended at
# the end (and logged, so a wrong anchor is visible).
func _insert_after_anchor(vbox, container, anchor):
	vbox.add_child(container)
	if anchor == null or not is_instance_valid(anchor):
		_log("WARNING: shadow anchor not found, section appended at panel end", 0)
		return
	var row = anchor
	while row != null and row.get_parent() != vbox:
		row = row.get_parent()
	if row == null:
		_log("WARNING: shadow anchor not under the panel vbox, section appended at panel end", 0)
		return
	vbox.move_child(container, row.get_index() + 1)

# DD never disables its CheckButtons, so the theme has no styled disabled
# state (default Godot look). Grey out manually instead: dimmed + mouse
# blocked, keeping the vanilla ON/OFF pill rendering.
func _set_toggle_enabled(btn: CheckButton, enabled: bool):
	btn.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	btn.modulate = Color(1, 1, 1, 1.0 if enabled else 0.55)

func _make_toggle(text: String, pressed: bool, target: String, handler: String) -> CheckButton:
	var btn = CheckButton.new()
	btn.text = text
	btn.pressed = pressed
	btn.connect("toggled", self, handler, [target])
	return btn

#########################################################################################################
##
## SOFT CLIPPING BLUR SETTINGS (per-light, revealed by the cog on the Soft Clipping row)
##
#########################################################################################################

func _load_icon(icon_path: String, scale: float = 1.0):
	var image = Image.new()
	if image.load(global.Root + icon_path) != OK:
		return null
	if scale != 1.0:
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _make_icon_button(icon_path: String, tooltip: String, fallback: String, icon_scale: float = 1.0) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	var tex = _load_icon(icon_path, icon_scale)
	if tex != null:
		btn.icon = tex
	else:
		btn.text = fallback  # icon file missing: keep the button usable
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return btn

# One "[Label] [Slider 0-200] [SpinBox %] [Reset]" row, vertically centred.
func _make_slider_row(label_text: String, is_tool: bool, which: String, default_pct: float) -> Dictionary:
	var hb = HBoxContainer.new()
	hb.add_constant_override("separation", 4)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(86, 0)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(lbl)
	var sl = HSlider.new()
	sl.min_value = 0
	sl.max_value = 100
	sl.step = 1
	sl.value = default_pct
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.connect("value_changed", self, "_on_blur_slider", [is_tool, which])
	hb.add_child(sl)
	var sp = SpinBox.new()
	sp.min_value = 0
	sp.max_value = 100
	sp.step = 1
	sp.value = default_pct
	sp.suffix = "%"
	sp.rect_min_size = Vector2(64, 0)
	sp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sp.connect("value_changed", self, "_on_blur_spin", [is_tool, which])
	hb.add_child(sp)
	var rb = _make_icon_button("icons/reset.png", "Reset", "R", 0.5)
	rb.connect("pressed", self, "_on_blur_reset", [is_tool, which])
	hb.add_child(rb)
	return {"row": hb, "slider": sl, "spin": sp}

# One raw-value "[Label] [Slider] [SpinBox unit] [Reset]" row, from _val_specs.
func _make_value_row(key: String, label_text: String, is_tool: bool) -> Dictionary:
	var spec = _val_specs[key]
	var hb = HBoxContainer.new()
	hb.add_constant_override("separation", 4)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(86, 0)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(lbl)
	var sl = HSlider.new()
	sl.min_value = float(spec["min"])
	sl.max_value = float(spec["max"])
	sl.step = float(spec["step"])
	sl.value = float(spec["default"])
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.connect("value_changed", self, "_on_val_slider", [is_tool, key])
	hb.add_child(sl)
	var sp = SpinBox.new()
	sp.min_value = float(spec["min"])
	sp.max_value = float(spec["max"])
	sp.step = float(spec["step"])
	sp.value = float(spec["default"])
	sp.suffix = spec["suffix"]
	sp.rect_min_size = Vector2(64, 0)
	sp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sp.connect("value_changed", self, "_on_val_spin", [is_tool, key])
	hb.add_child(sp)
	var rb = _make_icon_button("icons/reset.png", "Reset", "R", 0.5)
	rb.connect("pressed", self, "_on_val_reset", [is_tool, key])
	hb.add_child(rb)
	return {"row": hb, "slider": sl, "spin": sp}

# Build the Soft Clipping row as [label][cog][reset][ON/OFF switch] plus the
# collapsible two-slider settings box. Populates `blur` with widget refs and
# returns the two nodes to append to the panel container, plus the switch.
func _build_soft_clip_block(is_tool: bool, handler: String, blur: Dictionary) -> Dictionary:
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 4)
	var lbl = Label.new()
	lbl.text = "Soft Clipping (Beta)"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var cog = _make_icon_button("icons/cog.png", "Blur settings", "\u2699", 0.55)
	cog.toggle_mode = true
	cog.connect("toggled", self, "_on_blur_cog", [is_tool])
	row.add_child(cog)
	var reset = _make_icon_button("icons/reset.png", "Reset blur", "R", 0.5)
	reset.connect("pressed", self, "_on_blur_reset_all", [is_tool])
	row.add_child(reset)
	var sw = CheckButton.new()
	sw.pressed = _tool_soft_clip if is_tool else false
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.connect("toggled", self, handler, ["soft_clip"])
	row.add_child(sw)
	var box = VBoxContainer.new()
	box.visible = false
	var walls = _make_slider_row("Walls", is_tool, "walls", _blur_default_pct("walls"))
	var obj = _make_slider_row("Objects", is_tool, "obj", _blur_default_pct("obj"))
	var shrink = _make_value_row("obj_shrink", "Shrink (Objects)", is_tool)
	box.add_child(walls["row"])
	box.add_child(obj["row"])
	box.add_child(shrink["row"])
	blur["label"] = lbl
	blur["cog"] = cog
	blur["reset"] = reset
	blur["box"] = box
	blur["walls_slider"] = walls["slider"]
	blur["walls_spin"] = walls["spin"]
	blur["obj_slider"] = obj["slider"]
	blur["obj_spin"] = obj["spin"]
	blur["obj_shrink_slider"] = shrink["slider"]
	blur["obj_shrink_spin"] = shrink["spin"]
	return {"row": row, "box": box, "switch": sw}

func _blur_widgets(is_tool: bool) -> Dictionary:
	return _lt_blur if is_tool else _st_blur

func _on_blur_cog(pressed: bool, is_tool: bool):
	var b = _blur_widgets(is_tool)
	if b.has("box") and is_instance_valid(b["box"]):
		b["box"].visible = pressed

func _on_blur_slider(value: float, is_tool: bool, which: String):
	if _ui_guard:
		return
	_blur_set(is_tool, which, value, true, false)

func _on_blur_spin(value: float, is_tool: bool, which: String):
	if _ui_guard:
		return
	_blur_set(is_tool, which, value, false, true)

func _blur_max(which: String) -> float:
	return SOFT_WALLS_MAX if which == "walls" else SOFT_OBJ_MAX

func _blur_default_pct(which: String) -> float:
	if which == "walls":
		return SOFT_CLIP_AMOUNT / SOFT_WALLS_MAX * 100.0
	return SOFT_OBJ_AMOUNT / SOFT_OBJ_MAX * 100.0

func _on_blur_reset(is_tool: bool, which: String):
	_blur_set(is_tool, which, _blur_default_pct(which), true, true)

func _on_blur_reset_all(is_tool: bool):
	_blur_set(is_tool, "walls", _blur_default_pct("walls"), true, true)
	_blur_set(is_tool, "obj", _blur_default_pct("obj"), true, true)
	for key in _val_specs.keys():
		_val_set(is_tool, key, float(_val_specs[key]["default"]), true, true)

# Apply a percent value to one channel: sync the paired widgets, then persist
# (tool default or per selected light) and re-render.
func _blur_set(is_tool: bool, which: String, percent: float, sync_spin: bool, sync_slider: bool):
	var b = _blur_widgets(is_tool)
	if sync_slider:
		_set_ctrl(b.get(which + "_slider"), percent)
	if sync_spin:
		_set_ctrl(b.get(which + "_spin"), percent)
	var amt = percent / 100.0 * _blur_max(which)
	if is_tool:
		if which == "walls":
			_tool_soft_walls = amt
		else:
			_tool_soft_obj = amt
		if _soft.has(PREVIEW_NID):
			_mark_dirty(PREVIEW_NID)
	else:
		for light in _selected_lights():
			var nid = _get_nid(light)
			if nid == "":
				continue
			var w = amt if which == "walls" else _saved_soft_walls(nid)
			var o = amt if which == "obj" else _saved_soft_obj(nid)
			_save_blur(nid, w, o)
			_apply(light, nid)

func _on_val_slider(value: float, is_tool: bool, key: String):
	if _ui_guard:
		return
	_val_set(is_tool, key, value, true, false)

func _on_val_spin(value: float, is_tool: bool, key: String):
	if _ui_guard:
		return
	_val_set(is_tool, key, value, false, true)

func _on_val_reset(is_tool: bool, key: String):
	_val_set(is_tool, key, float(_val_specs[key]["default"]), true, true)

# Apply a raw value to one param: sync widgets, persist, re-render.
func _val_set(is_tool: bool, key: String, value: float, sync_spin: bool, sync_slider: bool):
	var b = _blur_widgets(is_tool)
	if sync_slider:
		_set_ctrl(b.get(key + "_slider"), value)
	if sync_spin:
		_set_ctrl(b.get(key + "_spin"), value)
	if is_tool:
		_tool_vals[key] = value
		if _soft.has(PREVIEW_NID):
			_mark_dirty(PREVIEW_NID)
	else:
		for light in _selected_lights():
			var nid = _get_nid(light)
			if nid == "":
				continue
			_save_val(nid, key, value)
			_apply(light, nid)

# Set a control's value WITHOUT emitting value_changed (no handler re-entrancy,
# no stale re-commit that would overwrite the value we just applied).
func _set_ctrl(ctrl, value: float):
	if ctrl != null and is_instance_valid(ctrl):
		ctrl.set_block_signals(true)
		ctrl.value = value
		ctrl.set_block_signals(false)

# Set a param's slider+spin to a display value.
func _set_widget(b: Dictionary, key: String, value: float):
	_set_ctrl(b.get(key + "_slider"), value)
	_set_ctrl(b.get(key + "_spin"), value)

# Load every setting for a light (nid; use PREVIEW_NID for the tool defaults)
# into a panel's widgets. Blur shows as percent-of-cap; the rest are raw.
func _settings_load(b: Dictionary, nid: String):
	_ui_guard = true
	_set_widget(b, "walls", _saved_soft_walls(nid) / SOFT_WALLS_MAX * 100.0)
	_set_widget(b, "obj", _saved_soft_obj(nid) / SOFT_OBJ_MAX * 100.0)
	for key in _val_specs.keys():
		_set_widget(b, key, _saved_val(nid, key))
	_ui_guard = false

func _build_light_tool_ui():
	var panel = global.Editor.Toolset.GetToolPanel("LightTool")
	if panel == null:
		return
	var vbox = core.get_align_vbox(panel)
	if vbox == null:
		return

	var container = VBoxContainer.new()
	container.name = "LightShadowsToolContainer"
	# Our section is tool options, not part of the asset library: tell
	# library_right_panel to leave it in the left tool panel.
	container.set_meta("lrp_keep_left", true)
	_lt_container = container
	var separator = HSeparator.new()
	separator.add_constant_override("separation", 8)
	container.add_child(separator)
	_lt_ignore = _make_toggle("Ignore Corners (Beta)", _tool_ignore, "ignore", "_on_tool_toggled")
	container.add_child(_lt_ignore)
	_lt_obj = _make_toggle("Keep Object Shadows", _tool_obj, "obj", "_on_tool_toggled")
	_set_toggle_enabled(_lt_obj, _tool_ignore)
	container.add_child(_lt_obj)
	var divider = HSeparator.new()
	divider.add_constant_override("separation", 8)
	container.add_child(divider)
	var sc = _build_soft_clip_block(true, "_on_tool_toggled", _lt_blur)
	_lt_soft_clip = sc["switch"]
	container.add_child(sc["row"])
	container.add_child(sc["box"])
	_settings_load(_lt_blur, PREVIEW_NID)
	var closing = HSeparator.new()
	closing.add_constant_override("separation", 8)
	container.add_child(closing)

	var anchor = null
	var tool = global.Editor.Tools.get("LightTool")
	if tool != null and tool.Controls != null and tool.Controls.has("Shadows"):
		anchor = tool.Controls["Shadows"]
		if anchor is BaseButton and not anchor.is_connected("toggled", self, "_on_native_tool_shadows"):
			anchor.connect("toggled", self, "_on_native_tool_shadows")
	_insert_after_anchor(vbox, container, anchor)
	_lt_built = true
	_refresh_tool_enabled()
	_log("Light tool UI injected", 0)

func _on_native_tool_shadows(_pressed: bool):
	_refresh_tool_enabled()

# Our whole section is HIDDEN while the native Shadows toggle is OFF (the mod
# is bypassed in that state) — saves panel space.
func _refresh_tool_enabled():
	if not _lt_built:
		return
	var tool = global.Editor.Tools.get("LightTool")
	var on = tool != null and bool(tool.Shadows)
	if is_instance_valid(_lt_container):
		_lt_container.visible = on
	if on:
		_set_toggle_enabled(_lt_soft_clip, true)
		_set_toggle_enabled(_lt_ignore, true)
		_set_toggle_enabled(_lt_obj, _tool_ignore)

func _on_tool_toggled(pressed: bool, target: String):
	if _ui_guard:
		return
	match target:
		"soft_clip":
			_tool_soft_clip = pressed
		"ignore":
			_tool_ignore = pressed
			_refresh_tool_enabled()
			if pressed:
				# Keep Object Shadows defaults to ON with Ignore Corners.
				_tool_obj = true
				_ui_guard = true
				_lt_obj.pressed = true
				_ui_guard = false
		"obj":
			_tool_obj = pressed

#########################################################################################################
##
## SELECT TOOL UI
##
#########################################################################################################

func _build_select_tool_ui():
	var select_panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	if select_panel == null:
		return
	var light_vbox = select_panel.lightOptions
	if light_vbox == null:
		return

	var container = VBoxContainer.new()
	container.name = "LightShadowsSelectContainer"
	# See _build_light_tool_ui: keep this section in the left tool panel.
	container.set_meta("lrp_keep_left", true)
	_st_container = container
	var separator = HSeparator.new()
	separator.add_constant_override("separation", 8)
	container.add_child(separator)
	_st_ignore = _make_toggle("Ignore Corners (Beta)", false, "ignore", "_on_select_toggled")
	container.add_child(_st_ignore)
	_st_obj = _make_toggle("Keep Object Shadows", false, "obj", "_on_select_toggled")
	_set_toggle_enabled(_st_obj, false)
	container.add_child(_st_obj)
	var divider = HSeparator.new()
	divider.add_constant_override("separation", 8)
	container.add_child(divider)
	var sc = _build_soft_clip_block(false, "_on_select_toggled", _st_blur)
	_st_soft_clip = sc["switch"]
	container.add_child(sc["row"])
	container.add_child(sc["box"])
	var closing = HSeparator.new()
	closing.add_constant_override("separation", 8)
	container.add_child(closing)

	_insert_after_anchor(light_vbox, container, select_panel.lightShadow)
	if select_panel.lightShadow is BaseButton and not select_panel.lightShadow.is_connected("toggled", self, "_on_native_select_shadows"):
		select_panel.lightShadow.connect("toggled", self, "_on_native_select_shadows")
	light_vbox.connect("visibility_changed", self, "_refresh_select_ui")
	_st_built = true
	_log("Select tool UI injected", 0)

func _selected_lights() -> Array:
	var out := []
	var tool = global.Editor.Tools.get("SelectTool")
	if tool == null:
		return out
	for node in tool.Selected:
		if node != null and is_instance_valid(node) and node is Light2D:
			out.append(node)
	return out

func _refresh_select_ui():
	if not _st_built:
		return
	var lights = _selected_lights()
	if lights.empty():
		return
	var nid = _get_nid(lights[0])
	_ui_guard = true
	_st_soft_clip.pressed = _saved_soft_clip(nid)
	_st_ignore.pressed = _saved_ignore(nid)
	_st_obj.pressed = _saved_obj(nid)
	_ui_guard = false
	_settings_load(_st_blur, nid)
	# HIDE the whole section while the native Shadows toggle is OFF (saves space).
	var shadows_on = is_instance_valid(lights[0]) and lights[0].shadow_enabled
	if is_instance_valid(_st_container):
		_st_container.visible = shadows_on
	if shadows_on:
		_set_toggle_enabled(_st_soft_clip, true)
		_set_toggle_enabled(_st_ignore, true)
		_set_toggle_enabled(_st_obj, _saved_ignore(nid))
	_ui_guard = false

func on_selection_changed():
	_refresh_select_ui()

func _on_native_select_shadows(_pressed: bool):
	# Let DD apply shadow_enabled to the selection first, then refresh.
	call_deferred("_refresh_select_ui")

func _on_select_toggled(pressed: bool, target: String):
	if _ui_guard:
		return
	var lights = _selected_lights()
	if lights.empty():
		return
	_txn_touch(lights)
	for light in lights:
		var nid = _get_nid(light)
		if nid == "":
			continue
		var cfg = _get_cfg(nid)
		var had_obj = cfg != null and cfg.has("obj_shadows")
		var soft_clip = pressed if target == "soft_clip" else _saved_soft_clip(nid)
		var ignore = pressed if target == "ignore" else _saved_ignore(nid)
		var obj = pressed if target == "obj" else _saved_obj(nid)
		# Keep Object Shadows defaults to ON the first time Ignore Corners is
		# enabled on a light that was never configured.
		if target == "ignore" and pressed and not had_obj:
			obj = true
		_save_cfg(nid, soft_clip, ignore, obj)
		_apply(light, nid)
		if _txn != null:
			_txn["after"][nid] = {"soft_clip": soft_clip, "ignore": ignore, "obj": obj}
	if target == "ignore":
		_refresh_select_ui()
	_txn_timer.start()

#########################################################################################################
##
## UNDO / REDO (B2 transactions)
##
#########################################################################################################

func _txn_touch(lights: Array):
	if _txn != null:
		return
	var before := {}
	for light in lights:
		var nid = _get_nid(light)
		if nid != "":
			before[nid] = {"soft_clip": _saved_soft_clip(nid), "ignore": _saved_ignore(nid), "obj": _saved_obj(nid)}
	_txn = {"before": before, "after": {}}

func _commit_txn():
	if _txn == null:
		return
	var before = _txn["before"]
	var after = _txn["after"]
	_txn = null
	if after.empty() or shadow_history == null:
		return
	var changed = false
	for nid in after.keys():
		var b = before.get(nid, {"soft_clip": false, "ignore": false, "obj": false})
		for key in ["soft_clip", "ignore", "obj"]:
			if bool(after[nid][key]) != bool(b[key]):
				changed = true
				break
		if changed:
			break
	if not changed:
		return
	shadow_history.record(self, "history_apply", {"values": before}, {"values": after}, "Light shadow settings", "mod")
	_log("txn committed (%d lights)" % after.size())

func flush_pending():
	_txn_timer.stop()
	_commit_txn()

func history_apply(payload):
	if not (payload is Dictionary) or not payload.has("values"):
		return
	for nid in payload["values"].keys():
		var v = payload["values"][nid]
		var soft_clip := false
		var ignore := false
		var obj := false
		if v is Dictionary:
			if v.has("soft_clip"):
				soft_clip = bool(v["soft_clip"]) or bool(v.get("soft_obj", false))
				ignore = bool(v.get("ignore", false))
				obj = bool(v.get("obj", false))
			elif v.has("soft"):
				soft_clip = bool(v["soft"])  # v39 single-toggle payload
				ignore = bool(v.get("ignore", false))
				obj = bool(v.get("obj", false))
			else:
				# Legacy slider-era payload {softness, wrap}
				soft_clip = float(v.get("softness", 0.0)) > EPS
				ignore = bool(v.get("wrap", false))
		else:
			soft_clip = float(v) > EPS  # oldest payloads: bare softness
		var node = _find_light(str(nid))
		if node != null:
			_save_cfg(str(nid), soft_clip, ignore, obj)
			_apply(node, str(nid))
	_refresh_select_ui()
