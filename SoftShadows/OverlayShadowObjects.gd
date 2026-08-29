#########################################################################################################
##
## OVERLAY (FORM) SHADOW FOR OBJECTS
##
#########################################################################################################
# Version 1.0.0
# A self-shadow that sits ON TOP of an asset, clipped to its silhouette, darkening
# only the side facing away from the sun. Reuses the same per-object child-sprite
# pattern as DropShadowObjects but with a trivial shader (no blur, no raycast).

var global
var core = null
var logging_level = 0
var _monitor_timer = null  # kept null for Core's _pause/_resume_monitor compatibility

const DATA_KEY = "OverlayShadow"
const META_KEY = "overlay_shadow_obj_nodes"

const DEFAULTS = {
	"enabled": false,
	"opacity": 0.5,
	"sun_angle": 90.0,   # degrees, WORLD space
	"coverage": 0.5,
	"diffusion": 0.5,
	"curve": 0.0,
	"shadow_color": Color(0, 0, 0, 1),
	"link_sun": true,   # follow the soft (drop) shadow's sun angle (on by default)
	"ignore_transparency": false  # replace-color mode for semi-transparent pixels
}

var _shader: Shader = null
var ui = {}
var _syncing = false
var _monitored = null
var _active = {}  # node_id (String) -> overlay Sprite

# Clone / copy-paste tracking (mirrors DropShadowObjects)
var _all_known_ids = {}      # node_id -> node, so existing objects aren't seen as clones

# ── Undo/redo (transactions de réglages) ───────────────────────────────
var shadow_history = null   # set by Core
var _history_flush_timer = null
var _history_txn_active = false
var _history_txn_before = {}
var _history_txn_label = ""
var _history_suspend = false

var _copy_source_ids = []    # ids saved on Ctrl+C
var _paste_pending = false   # set on Ctrl+V
var _clone_batch = []        # new nodes detected this tick
var _pending_signal_nodes = []
var _ctrl_c_was = false
var _ctrl_v_was = false
var _clipboard = {}
var _heal_counter = 0

const ENABLE_LOGGING = true
func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <OverlayShadowObjects>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise() -> void:
	_shader = ResourceLoader.load(global.Root + "shaders/OverlayShadowObject.shader", "Shader", true)
	if _shader == null:
		outputlog("ERROR: Could not load OverlayShadowObject.shader", 0)
		return
	build_ui()
	# Per-frame: keep each overlay's sun direction locked to world while the
	# asset rotates. One uniform write per active overlay — negligible cost.
	VisualServer.connect("frame_pre_draw", self, "_on_frame_pre_draw")

	# Monitor timer: detects Ctrl+C / Ctrl+V and object clones so the overlay
	# follows copied/duplicated objects. Paused by Core during map load.
	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.01
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)
	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "_on_new_node_added")

	# Timer de debounce pour l'historique undo/redo.
	_history_flush_timer = Timer.new()
	_history_flush_timer.wait_time = 0.4
	_history_flush_timer.one_shot = true
	_history_flush_timer.connect("timeout", self, "_history_flush")
	global.Editor.add_child(_history_flush_timer)
	if shadow_history != null and shadow_history.has_method("register_flusher"):
		shadow_history.register_flusher(self, "_history_flush")

	outputlog("Overlay Shadow Objects initialised. [BUILD: OVERLAY-CMTMERGE-4]", 0)

#########################################################################################################
## NODE HELPERS
#########################################################################################################

func is_obj(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not node.has_meta("node_id"):
		return false
	var p = node.get_parent()
	if p == null:
		return false
	return p.name == "Objects" or p.name == "Roofs"

func get_sprite(obj) -> Sprite:
	if obj.get("Sprite") != null and obj.Sprite is Sprite:
		return obj.Sprite
	if obj is Sprite:
		return obj
	for i in range(obj.get_child_count()):
		var c = obj.get_child(i)
		if c is Sprite and c.texture != null:
			if c.name.begins_with("DropShadow") or c.name.begins_with("OverlayShadow"):
				continue
			return c
	return null

#########################################################################################################
## CREATE / UPDATE / REMOVE
#########################################################################################################

# ── Free Transform (Unofficial Patch) warp compat ─────────────────────────
# FT's distort/perspective/skew warps the asset via a bilinear corner warp and
# publishes the corners (sprite-local px) in ModMapData["_ft_distort"], keyed
# "node-id-<id>". The overlay shader carries the matching warp (ft_* uniforms)
# so the overlay stays glued to the warped asset. No-op when FT is absent.

func _ft_warp_signature(obj):
	# Returns the FT distort corner array [8 floats] for obj, or null.
	var store = global.ModMapData.get("_ft_distort", null)
	if store == null or not (store is Dictionary) or store.empty():
		return null
	if obj == null or not is_instance_valid(obj) or not obj.has_meta("node_id"):
		return null
	var raw = store.get("node-id-" + str(obj.get_meta("node_id")), null)
	if raw is Array and raw.size() == 8:
		return raw
	return null


func _apply_ft_warp_params(ov, obj) -> void:
	# Push (or clear) the FT warp corners on an overlay's material.
	if ov == null or not is_instance_valid(ov) or ov.material == null:
		return
	var raw = _ft_warp_signature(obj)
	ov.set_meta("_ov_ft_sig", raw)
	if raw == null:
		ov.material.set_shader_param("ft_warp_enabled", 0.0)
		return
	ov.material.set_shader_param("ft_warp_enabled", 1.0)
	ov.material.set_shader_param("ft_corner_tl", Vector2(raw[0], raw[1]))
	ov.material.set_shader_param("ft_corner_tr", Vector2(raw[2], raw[3]))
	ov.material.set_shader_param("ft_corner_br", Vector2(raw[4], raw[5]))
	ov.material.set_shader_param("ft_corner_bl", Vector2(raw[6], raw[7]))


func create_shadow(obj, cfg: Dictionary) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	if _shader == null:
		return
	var sprite = get_sprite(obj)
	if sprite == null:
		return

	remove_shadow(obj)

	var ov = sprite.duplicate(0)
	# duplicate() ALWAYS copies children, whatever the flags — so any node other
	# mods attached to the sprite (e.g. Unofficial Patch's hover overlay) gets a
	# frozen clone inside our overlay, drawn after (= on top of) the real one.
	# The overlay must be the bare sprite only: strip everything.
	for dc in ov.get_children():
		ov.remove_child(dc)
		dc.free()
	ov.name = "OverlayShadowObj"

	var mat = ShaderMaterial.new()
	mat.shader = _shader
	ov.material = mat

	ov.position = sprite.position
	ov.show_behind_parent = false
	ov.z_as_relative = true
	# z_index 0 keeps the overlay in the SAME z bucket as its parent prop, so it
	# never jumps above neighbouring props. It still renders above its own asset
	# because it's the last child of obj (drawn after the prop's own sprite).
	ov.z_index = 0

	obj.add_child(ov)
	# Drawn last among siblings -> renders on top of this prop's own sprite only.
	obj.move_child(ov, obj.get_child_count() - 1)

	# Remember the source sprite so the overlay can mirror its texture/region
	# every frame. Free Transform's crop / soft crop / edge crop bake a new
	# texture onto the source sprite (region disabled); mirroring keeps the
	# overlay clipped to the same (cropped) silhouette. See _sync_overlay_texture.
	ov.set_meta("_src_sprite", sprite)

	_apply_params(ov, cfg, obj.global_rotation)

	# Respect the floatbar global Show/Hide state so a freshly created overlay
	# doesn't pop back into view while shadows are globally hidden.
	if global.ModMapData.get("DropShadowToggleHidden", false):
		ov.visible = false

	# Replace mode (Ignore Transparency Colors): the overlay re-renders the whole
	# asset (shadow mixed in, original alpha kept), so the source sprite must not
	# draw itself. We zero self_modulate.a instead of flipping .visible: the
	# sprite stays "alive" for everything else (children added by other mods,
	# visibility checks, DD copy...), it just stops painting its own pixels.
	# The original alpha is saved in a meta so it can be restored exactly.
	var replace_mode = cfg.get("ignore_transparency", false)
	ov.set_meta("_replace_mode", replace_mode)
	if replace_mode:
		if not sprite.has_meta("_ovr_saved_sma"):
			sprite.set_meta("_ovr_saved_sma", sprite.self_modulate.a)
		# The overlay must keep the asset's REAL alpha (duplicate may have copied
		# an already-zeroed value on a heal rebuild).
		ov.self_modulate.a = sprite.get_meta("_ovr_saved_sma")
		# Snapshot the source sprite's material: replace mode only renders while
		# the sprite still wears THIS material. Any other material means another
		# mod swapped it in (e.g. Unofficial Patch's hover tint) — the tint
		# paints on the source sprite, so replace must step aside or the tint
		# lands on an invisible sprite. See the per-frame sync.
		ov.set_meta("_src_material", sprite.material)
		var hidden_global = global.ModMapData.get("DropShadowToggleHidden", false)
		sprite.self_modulate.a = sprite.get_meta("_ovr_saved_sma") if hidden_global else 0.0

	obj.set_meta(META_KEY, [ov])
	obj.set_meta("_overlay_config", cfg)
	if obj.has_meta("node_id"):
		_active[str(obj.get_meta("node_id"))] = ov

func _apply_params(ov, cfg: Dictionary, rot: float) -> void:
	var mat = ov.material
	if mat == null:
		return
	var col = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if col is String:
		col = Color(col)
	var size = Vector2(1, 1)
	if ov.texture != null:
		size = ov.texture.get_size()
		if ov.region_enabled:
			size = ov.region_rect.size
	mat.set_shader_param("shadow_color", col)
	mat.set_shader_param("opacity", cfg.get("opacity", DEFAULTS["opacity"]))
	mat.set_shader_param("coverage", cfg.get("coverage", DEFAULTS["coverage"]))
	mat.set_shader_param("diffusion", cfg.get("diffusion", DEFAULTS["diffusion"]))
	mat.set_shader_param("curve", cfg.get("curve", DEFAULTS["curve"]))
	mat.set_shader_param("ignore_transparency", 1.0 if cfg.get("ignore_transparency", false) else 0.0)
	# Express the world sun direction in the sprite's local space so rotation and
	# mirror (negative scale) are both handled. Stored as meta for the per-frame sync.
	var sun_deg = cfg.get("sun_angle", DEFAULTS["sun_angle"])
	if cfg.get("link_sun", false):
		var lobj = ov.get_parent()
		if lobj != null and lobj.has_meta("node_id"):
			var lsun = _linked_sun_angle(str(lobj.get_meta("node_id")))
			if lsun != null:
				sun_deg = lsun
	var world_rad = deg2rad(sun_deg)
	var world_sun = Vector2(cos(world_rad), sin(world_rad))
	ov.set_meta("_world_sun", world_sun)
	var local_sun = ov.global_transform.affine_inverse().basis_xform(world_sun)
	mat.set_shader_param("local_sun", local_sun)
	mat.set_shader_param("tex_size", size)
	# Mirror our params under the ovr_ prefix too: MERGED materials (source
	# shader + our injected shadow block, see _ovr_apply_merged) expose them
	# prefixed to avoid uniform name collisions. Harmless on the plain shader.
	mat.set_shader_param("ovr_shadow_color", cfg.get("shadow_color", DEFAULTS["shadow_color"]))
	mat.set_shader_param("ovr_opacity", cfg.get("opacity", DEFAULTS["opacity"]))
	mat.set_shader_param("ovr_coverage", cfg.get("coverage", DEFAULTS["coverage"]))
	mat.set_shader_param("ovr_diffusion", cfg.get("diffusion", DEFAULTS["diffusion"]))
	mat.set_shader_param("ovr_curve", cfg.get("curve", DEFAULTS["curve"]))
	mat.set_shader_param("ovr_local_sun", local_sun)
	mat.set_shader_param("ovr_tex_size", size)
	# Free Transform warp (no-op when the parent asset isn't distorted).
	_apply_ft_warp_params(ov, ov.get_parent())

func remove_shadow(obj) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	if obj.has_meta(META_KEY):
		for ov in obj.get_meta(META_KEY):
			if is_instance_valid(ov):
				_restore_source_sprite(ov)
				ov.queue_free()
		obj.remove_meta(META_KEY)
	# Sweep any stray duplicates.
	for c in obj.get_children():
		if is_instance_valid(c) and c.name.begins_with("OverlayShadowObj"):
			_restore_source_sprite(c)
			c.queue_free()
	if obj.has_meta("node_id"):
		var nid = str(obj.get_meta("node_id"))
		if _active.has(nid):
			_active.erase(nid)

#########################################################################################################
## MERGED MATERIALS (replace mode x Colour and Modify Things)
#########################################################################################################
# CMT recolors assets by swapping a ShaderMaterial onto the sprite. In replace
# mode OUR overlay repaints the asset, so it must reproduce that recoloring or
# the tint would visually vanish. Rather than porting CMT's shader (version
# coupling), we INJECT our shadow block into a COPY of whatever shader code the
# source material carries, and copy its param values over. Strictly read-only
# for CMT: the merged shader + material live on our overlay only.

var _ovr_shader_cache = {}  # source code hash -> merged Shader (compiled once)

# Injected before fragment(). ovr_ prefix avoids uniform name collisions.
const OVR_UNIFORM_BLOCK = """
// ---- Overlay Shadow injection (SoftShadows): uniforms ----
uniform vec4 ovr_shadow_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float ovr_opacity = 0.5;
uniform float ovr_coverage = 0.5;
uniform float ovr_diffusion = 0.5;
uniform float ovr_curve = 0.0;
uniform vec2 ovr_local_sun = vec2(0.0, 1.0);
uniform vec2 ovr_tex_size = vec2(1.0, 1.0);
"""

# Injected right before fragment()'s closing brace: same terminator math as
# OverlayShadowObject.shader (replace branch), applied to whatever COLOR the
# source shader produced. Braces scope the locals away from the host code.
const OVR_FRAGMENT_TAIL = """
	{ // ---- Overlay Shadow injection (SoftShadows): darken toward the sun ----
__OVR_POS__
	vec2 ovr_sun = normalize(ovr_local_sun);
	vec2 ovr_perp = vec2(-ovr_sun.y, ovr_sun.x);
	float ovr_proj = dot(ovr_pp, -ovr_sun);
	float ovr_q = dot(ovr_pp, ovr_perp);
	float ovr_H = 0.5;
	float ovr_qc = clamp(ovr_q, -ovr_H, ovr_H);
	float ovr_arc = sqrt(ovr_H * ovr_H - ovr_qc * ovr_qc);
	ovr_proj += ovr_curve * ovr_arc;
	float ovr_bend = ovr_curve * ovr_H;
	float ovr_hi = 0.75 + max(0.0, ovr_bend);
	float ovr_lo = -0.75 + min(0.0, ovr_bend);
	float ovr_thr = mix(ovr_hi, ovr_lo, ovr_coverage);
	float ovr_w = max(ovr_diffusion * 0.5, 0.002);
	float ovr_t = smoothstep(ovr_thr - ovr_w, ovr_thr + ovr_w, ovr_proj);
	COLOR.rgb = mix(COLOR.rgb, ovr_shadow_color.rgb, ovr_opacity * ovr_t);
	}
"""

func _is_cmt_material(mat) -> bool:
	# CMT materials carry no meta marker; identify them by their signature
	# uniforms instead (set on every material CMT builds). FT-marked materials
	# are handled by the FT adoption path, not here.
	if not (mat is ShaderMaterial) or mat.shader == null:
		return false
	if mat.has_meta("_ft_warp") or mat.has_meta("_ft_merged"):
		return false
	return mat.get_shader_param("apply_grayscale") != null or mat.get_shader_param("apply_hsl") != null

func _ovr_is_mergeable(mat) -> bool:
	# Materials whose rendering our overlay must reproduce: CMT recoloring, and
	# the FT+CMT fused material (_ft_merged) which carries both the warp and
	# the recoloring in one shader. FT ALONE (_ft_warp) stays on the plain
	# path: pure geometry, already replicated by our ft_ params.
	if _is_cmt_material(mat):
		return true
	return mat is ShaderMaterial and mat.shader != null and mat.has_meta("_ft_merged")

func _ovr_find_fn_block(code, fname):
	# Locates "void <fname>" and its matching braces by depth counting.
	# Returns [fn_start, open_idx, close_idx] on the ORIGINAL code, or null.
	var fi = code.find("void " + fname)
	if fi < 0:
		return null
	var open = code.find("{", fi)
	if open < 0:
		return null
	var depth = 0
	for i in range(open, code.length()):
		var ch = code[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return [fi, open, i]
	return null

func _ovr_sort_ins(a, b) -> bool:
	return a[0] < b[0]

func _ovr_build_merged_shader(code):
	# Inject into a COPY of the source shader code:
	# - our declarations right after shader_type (global scope, BEFORE both
	#   functions — vertex() may precede fragment() and uses our varying)
	# - "ovr_v_local = VERTEX;" at the end of vertex() when one exists (after
	#   FT's warp moved VERTEX), so the gradient can run in the warped local
	#   space and stay world-anchored — same fix as the plain shader
	# - our shadow block right before fragment()'s closing brace
	# Returns null when the code shape isn't recognized.
	var frag = _ovr_find_fn_block(code, "fragment")
	if frag == null:
		return null
	var vert = _ovr_find_fn_block(code, "vertex")
	var st = code.find("shader_type")
	if st < 0:
		return null
	var decl_at = code.find(";", st)
	if decl_at < 0:
		return null
	decl_at += 1
	var decl = OVR_UNIFORM_BLOCK
	var pos_line = "	vec2 ovr_pp = (UV - vec2(0.5)) * ovr_tex_size / max(ovr_tex_size.x, ovr_tex_size.y);"
	if vert != null:
		decl += "varying vec2 ovr_v_local;\n"
		pos_line = "	vec2 ovr_pp = ovr_v_local / max(ovr_tex_size.x, ovr_tex_size.y);"
	var inserts = [[decl_at, decl], [frag[2], OVR_FRAGMENT_TAIL.replace("__OVR_POS__", pos_line)]]
	if vert != null:
		inserts.append([vert[2], "	ovr_v_local = VERTEX;\n"])
	inserts.sort_custom(self, "_ovr_sort_ins")
	# Assemble by slicing the ORIGINAL code at ascending insertion points, so
	# the indices computed above never shift.
	var out = ""
	var prev = 0
	for ins in inserts:
		out += code.substr(prev, ins[0] - prev) + ins[1]
		prev = ins[0]
	out += code.substr(prev, code.length() - prev)
	var sh = Shader.new()
	sh.code = out
	return sh

func _ovr_apply_merged(ov, src_mat) -> bool:
	# Build (or reuse from cache) the merged material and put it on our overlay.
	var code = src_mat.shader.code
	var key = code.hash()
	var sh = _ovr_shader_cache.get(key, null)
	if sh == null:
		sh = _ovr_build_merged_shader(code)
		if sh == null:
			outputlog("Overlay replace: unrecognized source shader shape, replace suspended", 0)
			return false
		_ovr_shader_cache[key] = sh
	if not ov.has_meta("_ovr_plain_mat"):
		ov.set_meta("_ovr_plain_mat", ov.material)
	var plain = ov.get_meta("_ovr_plain_mat")
	var merged = ShaderMaterial.new()
	merged.shader = sh
	# Copy the source material's param VALUES (uniform names parsed from its
	# own code) so the recoloring matches exactly. Rebuilt on every source
	# material swap (CMT creates a fresh material per tweak), shader cache
	# makes that cheap.
	var rx = RegEx.new()
	rx.compile("uniform\\s+(?:\\w+\\s+)+?(\\w+)\\s*[:=;]")
	for m in rx.search_all(code):
		var pname = m.get_string(1)
		var v = src_mat.get_shader_param(pname)
		if v != null:
			merged.set_shader_param(pname, v)
	# Copy OUR shadow params from the plain overlay material, prefixed.
	for p in ["shadow_color", "opacity", "coverage", "diffusion", "curve", "local_sun", "tex_size"]:
		var pv = plain.get_shader_param(p)
		if pv != null:
			merged.set_shader_param("ovr_" + p, pv)
	ov.material = merged
	ov.set_meta("_ovr_merged_from", src_mat)
	return true

func _ovr_restore_plain(ov) -> void:
	# Back to our plain shadow material (source material no longer needs merging).
	if not ov.has_meta("_ovr_merged_from"):
		return
	ov.remove_meta("_ovr_merged_from")
	if ov.has_meta("_ovr_plain_mat"):
		ov.material = ov.get_meta("_ovr_plain_mat")
		# The plain material received NO live updates while the merged one was
		# active (per-frame writes target ov.material) -> refresh what can have
		# gone stale in the meantime: FT warp corners (asset transformed while
		# tinted -> the shadow snapped back to the fusion-time deformation) and
		# tex_size (texture baked/cropped while tinted). local_sun refreshes
		# itself on the next frame tick.
		_apply_ft_warp_params(ov, ov.get_parent())
		var rs = Vector2(1, 1)
		if ov.texture != null:
			rs = ov.texture.get_size()
			if ov.region_enabled:
				rs = ov.region_rect.size
		ov.material.set_shader_param("tex_size", rs)
		ov.material.set_shader_param("ovr_tex_size", rs)

func _restore_source_sprite(ov) -> void:
	# Undo the replace-mode hide before the overlay goes away, or the asset
	# would stay invisible (remove, toggle off, undo, heal rebuild...).
	if not (ov.has_meta("_replace_mode") and ov.get_meta("_replace_mode")):
		return
	if not ov.has_meta("_src_sprite"):
		return
	var src = ov.get_meta("_src_sprite")
	if src != null and is_instance_valid(src) and src.has_meta("_ovr_saved_sma"):
		src.self_modulate.a = src.get_meta("_ovr_saved_sma")
		src.remove_meta("_ovr_saved_sma")

func _on_frame_pre_draw() -> void:
	if _active.empty():
		return
	var dead = []
	for nid in _active.keys():
		var ov = _active[nid]
		if ov == null or not is_instance_valid(ov):
			dead.append(nid)
			continue
		if ov.material != null:
			# Keep the overlay clipped to the asset's current silhouette: Free
			# Transform crop / soft crop / edge crop replace the source sprite's
			# texture, so mirror it here before computing the sun direction.
			_sync_overlay_texture(ov)
			# Replace mode: the source sprite's own drawing is slaved to the
			# overlay's state — self_modulate.a zeroed while the overlay shows
			# (it re-renders the asset), restored when the overlay is hidden
			# (global Show/Hide toggle flips ov.visible without knowing about
			# replace mode). .visible is never touched so other mods / DD copy
			# keep seeing a normal sprite.
			# SUSPENSION: if the source sprite wears a material other than the
			# one snapshotted at creation, another mod swapped it in (hover
			# tint...). Its effect paints on the SOURCE sprite, so replace steps
			# aside: source shown normally, our overlay muted. It resumes the
			# moment the original material is restored.
			if ov.has_meta("_replace_mode") and ov.get_meta("_replace_mode") and ov.has_meta("_src_sprite"):
				var rsrc = ov.get_meta("_src_sprite")
				if rsrc != null and is_instance_valid(rsrc) and rsrc.has_meta("_ovr_saved_sma"):
					var suspended = false
					var cur_mat = rsrc.material
					if _ovr_is_mergeable(cur_mat):
						# CMT recoloring (tinted, or tinted + FT-warped via the
						# fused _ft_merged shader): render through a MERGED
						# material (its shader + our shadow block). Rebuilt
						# whenever a fresh material is swapped in.
						var merged_from = ov.get_meta("_ovr_merged_from") if ov.has_meta("_ovr_merged_from") else null
						if merged_from != cur_mat:
							if not _ovr_apply_merged(ov, cur_mat):
								suspended = true
					elif cur_mat == null or cur_mat == ov.get_meta("_src_material") or (cur_mat is ShaderMaterial and cur_mat.has_meta("_ft_warp")):
						# Known-good baselines -> plain shadow material:
						# - null: bare sprite (a mod removed its material, e.g.
						#   CMT tint deleted or CMT disabled)
						# - the material snapshotted at creation (never
						#   overwritten, so returning to it always works)
						# - FT ALONE (_ft_warp): pure warp, already replicated
						#   by our plain shader via the ft_ params
						_ovr_restore_plain(ov)
					else:
						# Unknown material = temporary tint (hover...) ->
						# suspend until a known state returns.
						suspended = true
					var want_a = rsrc.get_meta("_ovr_saved_sma") if (suspended or not ov.visible) else 0.0
					if rsrc.self_modulate.a != want_a:
						rsrc.self_modulate.a = want_a
					# Mute the overlay itself while suspended (its own channel,
					# so the global toggle's ov.visible is left alone). Restored
					# to the asset's original alpha, kept in the sprite's meta.
					var want_ov_a = 0.0 if suspended else rsrc.get_meta("_ovr_saved_sma")
					if ov.self_modulate.a != want_ov_a:
						ov.self_modulate.a = want_ov_a
			var ws = ov.get_meta("_world_sun") if ov.has_meta("_world_sun") else Vector2(0, 1)
			# If linked, follow the soft shadow's sun angle live.
			var obj = ov.get_parent()
			# Free Transform warp: keep the overlay's corners in sync with the
			# asset's live distort (drag, undo, removal). Arrays compare by
			# value; near-free when FT publishes no distort data at all.
			var ft_sig = _ft_warp_signature(obj)
			var ft_prev = ov.get_meta("_ov_ft_sig") if ov.has_meta("_ov_ft_sig") else null
			if not (ft_sig == null and ft_prev == null) and ft_sig != ft_prev:
				_apply_ft_warp_params(ov, obj)
			if obj != null and obj.has_meta("_overlay_config"):
				var ocfg = obj.get_meta("_overlay_config")
				if ocfg is Dictionary and ocfg.get("link_sun", false):
					var lsun = _linked_sun_angle(nid)
					if lsun != null:
						var lr = deg2rad(lsun)
						ws = Vector2(cos(lr), sin(lr))
						ov.set_meta("_world_sun", ws)
						# Reflect the live linked angle in the UI of the selected object.
						if _monitored != null and is_instance_valid(_monitored) and _monitored == obj and ui.has("sun_angle_slider"):
							_syncing = true
							ui["sun_angle_slider"].value = round(lsun)
							ui["sun_angle_spin"].value = round(lsun)
							_syncing = false
			var live_ls = ov.global_transform.affine_inverse().basis_xform(ws)
			ov.material.set_shader_param("local_sun", live_ls)
			ov.material.set_shader_param("ovr_local_sun", live_ls)
	for nid in dead:
		_active.erase(nid)

func _sync_overlay_texture(ov) -> void:
	# Mirror the source sprite's texture + region onto the overlay so that any
	# texture-baking transform (FT crop / soft crop / edge crop, which swap the
	# sprite's texture and disable region) is reflected in the overlay shadow.
	# Cheap: identity comparisons, writes only on change.
	if not ov.has_meta("_src_sprite"):
		return
	var src = ov.get_meta("_src_sprite")
	if src == null or not is_instance_valid(src):
		return
	var region_changed = src.region_enabled and ov.region_rect != src.region_rect
	if ov.texture == src.texture and ov.region_enabled == src.region_enabled and not region_changed:
		return
	ov.texture = src.texture
	ov.region_enabled = src.region_enabled
	if src.region_enabled:
		ov.region_rect = src.region_rect
	# Refresh the silhouette size used by the shadow shader.
	if ov.material != null:
		var size = Vector2(1, 1)
		if ov.texture != null:
			size = ov.texture.get_size()
			if ov.region_enabled:
				size = ov.region_rect.size
		ov.material.set_shader_param("tex_size", size)
		ov.material.set_shader_param("ovr_tex_size", size)

#########################################################################################################
## CLONE / COPY-PASTE DETECTION
#########################################################################################################

func _on_new_node_added(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	_pending_signal_nodes.append(node)

func _on_monitor_tick() -> void:
	# Self-heal: roughly once a second, rebuild any saved+enabled overlay whose
	# live sprite is missing (native delete + undo restores the object node but
	# not our injected overlay child). No-op in steady state.
	_heal_counter += 1
	if _heal_counter >= 100:
		_heal_counter = 0
		_heal_missing_shadows()

	var ctrl = Input.is_key_pressed(KEY_CONTROL)
	var c_pressed = Input.is_key_pressed(KEY_C)
	var v_pressed = Input.is_key_pressed(KEY_V)

	if ctrl and c_pressed and not v_pressed and not _ctrl_c_was:
		var ids = []
		for sel in global.Editor.Tools["SelectTool"].Selected:
			if is_instance_valid(sel) and sel.has_meta("node_id"):
				ids.append(str(sel.get_meta("node_id")))
		if ids.size() > 0:
			_copy_source_ids = ids
	_ctrl_c_was = ctrl and c_pressed

	if ctrl and v_pressed and not _ctrl_v_was:
		if _copy_source_ids.size() > 0:
			_paste_pending = true
	_ctrl_v_was = ctrl and v_pressed

	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_obj(node):
			_check_clone(node)

	_process_signal_nodes()
	_process_clone_batch()

func _heal_missing_shadows() -> void:
	if not global.ModMapData.has(DATA_KEY):
		return
	for nid in global.ModMapData[DATA_KEY].keys():
		var cfg = global.ModMapData[DATA_KEY][nid]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		if int(nid) < 0:
			continue
		if not global.World.HasNodeID(int(nid)):
			continue
		var node = global.World.GetNodeByID(int(nid))
		if node == null or not is_instance_valid(node) or not is_obj(node):
			continue
		# Skip if a live overlay already exists on this node.
		if node.has_meta(META_KEY):
			var alive = false
			for ov in node.get_meta(META_KEY):
				if is_instance_valid(ov):
					alive = true
					break
			if alive:
				continue
		var sprite = get_sprite(node)
		if sprite == null or sprite.texture == null:
			continue  # not ready yet — try again next scan
		var rcfg = cfg.duplicate()
		if rcfg.has("shadow_color") and rcfg["shadow_color"] is String:
			rcfg["shadow_color"] = Color(rcfg["shadow_color"])
		create_shadow(node, rcfg)
		_all_known_ids[str(nid)] = node

func _process_signal_nodes() -> void:
	# Register freshly placed objects so they aren't later mistaken for clones.
	# (Overlay has no ObjectTool placement toggle, so we only register.)
	if _pending_signal_nodes.size() == 0:
		return
	var nodes = _pending_signal_nodes.duplicate()
	_pending_signal_nodes.clear()
	for node in nodes:
		if not is_instance_valid(node) or not is_obj(node) or not node.has_meta("node_id"):
			continue
		_all_known_ids[str(node.get_meta("node_id"))] = node

func _check_clone(node) -> void:
	if node == null or not is_instance_valid(node) or not node.has_meta("node_id"):
		return
	var nid = str(node.get_meta("node_id"))
	if _all_known_ids.has(nid):
		return
	if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
		_all_known_ids[nid] = node
		return
	_clone_batch.append(node)

func _process_clone_batch() -> void:
	if _clone_batch.size() == 0:
		return
	var batch = _clone_batch.duplicate()
	_clone_batch.clear()
	var is_paste = _paste_pending
	_paste_pending = false

	for i in range(batch.size()):
		var node = batch[i]
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))

		# Ctrl+V: match by index against the copy source (preserves order).
		# A tracked paste source is authoritative — even when it has NO config
		# recorded (i.e. the copied original never had a shadow), that absence
		# must be respected instead of falling through to the texture fallback
		# below, which would wrongly borrow some OTHER object's shadow.
		if is_paste and i < _copy_source_ids.size():
			var src_id = _copy_source_ids[i]
			if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(src_id):
				var src = global.ModMapData[DATA_KEY][src_id]
				if src is Dictionary:
					_apply_clone_config(node, src)
					_all_known_ids[nid] = node
					continue
			# Tracked source exists but has no data at all -> definitively "no shadow".
			_all_known_ids[nid] = node
			continue

		# Fallback by texture match DISABLED: it borrowed shadow config from any
		# OTHER object sharing the same texture, regardless of whether the actual
		# copied source had a shadow. Covers DD's own Copy/Paste toolbar buttons
		# (no reliable way to track their true source) — pasting via those buttons
		# now never inherits a shadow; re-apply manually if needed. Ctrl+C/V above
		# remains fully accurate since it tracks the real source.

		_all_known_ids[nid] = node

func _apply_clone_config(node, src_cfg: Dictionary) -> void:
	# Strip stale meta from the clone (points at the source's overlay sprite).
	if node.has_meta(META_KEY):
		node.remove_meta(META_KEY)
	var cfg = src_cfg.duplicate()
	if cfg.has("shadow_color") and cfg["shadow_color"] is String:
		cfg["shadow_color"] = Color(cfg["shadow_color"])
	save_data(node, cfg)
	if cfg.get("enabled", false):
		create_shadow(node, cfg)

func _find_config_by_texture(node, exclude_id: String):
	if not global.ModMapData.has(DATA_KEY):
		return null
	var spr = get_sprite(node)
	if spr == null or spr.texture == null:
		return null
	var tpath = spr.texture.resource_path
	if tpath == "":
		return null
	for src_id in global.ModMapData[DATA_KEY].keys():
		if src_id == exclude_id:
			continue
		var cfg = global.ModMapData[DATA_KEY][src_id]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		if not global.World.HasNodeID(int(src_id)):
			continue
		var src_node = global.World.GetNodeByID(int(src_id))
		if src_node == null or not is_instance_valid(src_node):
			continue
		var src_spr = get_sprite(src_node)
		if src_spr != null and src_spr.texture != null and src_spr.texture.resource_path == tpath:
			return cfg
	return null

func _seed_known_ids() -> void:
	var lvl = global.World.GetCurrentLevel()
	if lvl == null:
		return
	var root = lvl.get_parent()
	if root == null:
		return
	for i in range(root.get_child_count()):
		var level = root.get_child(i)
		if not is_instance_valid(level):
			continue
		for cn in ["Objects", "Roofs"]:
			var cont = level.get_node_or_null(cn)
			if cont == null:
				continue
			for child in cont.get_children():
				if is_instance_valid(child) and child.has_meta("node_id"):
					_all_known_ids[str(child.get_meta("node_id"))] = child

#########################################################################################################
## UI
#########################################################################################################

func build_ui() -> void:
	var panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	var parent = panel.objectOptions
	ui["_obj_parent"] = parent

	var c = VBoxContainer.new()
	c.name = "OverlayShadowObjectsContainer"
	ui["container"] = c

	c.add_child(HSeparator.new())

	# Title row: [stairs icon] label + enable toggle
	var trow = HBoxContainer.new()
	var icon = _create_stairs_icon()
	if icon != null:
		trow.add_child(icon)
	var title = Label.new()
	title.text = "Overlay Shadow"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trow.add_child(title)
	var enable = CheckButton.new()
	enable.pressed = false
	enable.connect("toggled", self, "_on_enable_toggled")
	trow.add_child(enable)
	ui["enable"] = enable
	c.add_child(trow)

	# Settings panel
	var sp = VBoxContainer.new()
	sp.name = "OverlaySettings"
	sp.visible = false
	ui["panel"] = sp

	# Sun ° row with a "link to soft shadow sun angle" toggle.
	var sun_row = HBoxContainer.new()
	var sun_l = Label.new()
	sun_l.text = "Sun °"
	sun_l.rect_min_size.x = 70
	sun_row.add_child(sun_l)
	var sun_s = HSlider.new()
	sun_s.min_value = 0
	sun_s.max_value = 359
	sun_s.step = 1
	sun_s.value = DEFAULTS["sun_angle"]
	sun_s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sun_s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sun_s.connect("value_changed", self, "_on_slider", ["sun_angle"])
	sun_row.add_child(sun_s)
	ui["sun_angle_slider"] = sun_s
	var sun_sb = SpinBox.new()
	sun_sb.min_value = 0
	sun_sb.max_value = 359
	sun_sb.step = 1
	sun_sb.value = DEFAULTS["sun_angle"]
	sun_sb.connect("value_changed", self, "_on_spin", ["sun_angle"])
	sun_row.add_child(sun_sb)
	ui["sun_angle_spin"] = sun_sb
	var sun_rb = _make_icon_button("icons/reset.png", "Reset Sun °", 0.5)
	sun_rb.connect("pressed", self, "_on_single_reset", ["sun_angle"])
	sun_row.add_child(sun_rb)
	var link_btn = _make_icon_button("icons/link.png", "Link to the soft shadow's sun angle", 0.5)
	link_btn.toggle_mode = true
	link_btn.pressed = DEFAULTS["link_sun"]
	link_btn.connect("toggled", self, "_on_link_toggled")
	sun_row.add_child(link_btn)
	ui["link_sun"] = link_btn
	sp.add_child(sun_row)
	_update_link_enabled(DEFAULTS["link_sun"])

	_add_slider(sp, "Coverage", "coverage", 0.0, 1.0, 0.01)
	_add_slider(sp, "Diffusion", "diffusion", 0.0, 1.0, 0.01)
	_add_slider(sp, "Curve", "curve", -2.0, 2.0, 0.01)
	_add_slider(sp, "Opacity", "opacity", 0.05, 1.0, 0.01)

	# Ignore Transparency: replace-color mode — semi-transparent pixels take the
	# shadow tint while keeping their original alpha, instead of stacking a
	# translucent shadow that lets the pixels below show through.
	var it_row = HBoxContainer.new()
	var it_l = Label.new()
	it_l.text = "Ignore Transparency Colors"
	it_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	it_row.add_child(it_l)
	var it_btn = CheckButton.new()
	it_btn.pressed = DEFAULTS["ignore_transparency"]
	it_btn.hint_tooltip = "Tint semi-transparent pixels with the shadow color, keeping their alpha"
	it_btn.connect("toggled", self, "_on_ignore_transparency_toggled")
	it_row.add_child(it_btn)
	ui["ignore_transparency"] = it_btn
	sp.add_child(it_row)

	var crow = HBoxContainer.new()
	var cl = Label.new()
	cl.text = "Color"
	cl.rect_min_size.x = 70
	crow.add_child(cl)
	var cp = ColorPickerButton.new()
	cp.color = DEFAULTS["shadow_color"]
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.connect("color_changed", self, "_on_color")
	# Hide the screen-picker eyedropper (it crashes DD).
	cp.connect("pressed", self, "_disable_color_pipette", [cp])
	crow.add_child(cp)
	ui["color"] = cp
	var color_reset = _make_icon_button("icons/reset.png", "Reset color", 0.5)
	color_reset.connect("pressed", self, "_on_single_reset", ["shadow_color"])
	crow.add_child(color_reset)
	sp.add_child(crow)

	# Actions row: [label] [Reset] [Copy] [Paste]
	var actions = HBoxContainer.new()
	var alabel = Label.new()
	alabel.text = "Shadow"
	alabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(alabel)
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.icon = _load_icon("icons/reset.png", 0.5)
	reset_btn.hint_tooltip = "Reset overlay to defaults"
	reset_btn.connect("pressed", self, "_on_reset")
	actions.add_child(reset_btn)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.icon = _load_icon("icons/copy.png", 0.5)
	copy_btn.hint_tooltip = "Copy overlay settings"
	copy_btn.connect("pressed", self, "_on_copy")
	actions.add_child(copy_btn)
	var paste_btn = Button.new()
	paste_btn.text = "Paste"
	paste_btn.icon = _load_icon("icons/paste.png", 0.5)
	paste_btn.hint_tooltip = "Paste overlay settings to selected"
	paste_btn.connect("pressed", self, "_on_paste")
	actions.add_child(paste_btn)
	sp.add_child(actions)

	c.add_child(sp)

func _add_slider(parent, label: String, key: String, mn, mx, step) -> void:
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = label
	l.rect_min_size.x = 70
	row.add_child(l)
	var s = HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = DEFAULTS[key]
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.connect("value_changed", self, "_on_slider", [key])
	row.add_child(s)
	var sb = SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = DEFAULTS[key]
	sb.connect("value_changed", self, "_on_spin", [key])
	row.add_child(sb)
	var rb = _make_icon_button("icons/reset.png", "Reset " + label, 0.5)
	rb.connect("pressed", self, "_on_single_reset", [key])
	row.add_child(rb)
	ui[key + "_slider"] = s
	ui[key + "_spin"] = sb
	parent.add_child(row)

#########################################################################################################
## UI HELPERS
#########################################################################################################

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	if image.load(global.Root + icon_path) != OK:
		return null
	if scale != 1.0:
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _make_icon_button(icon_path: String, tooltip: String, icon_scale: float = 1.0) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	btn.icon = _load_icon(icon_path, icon_scale)
	return btn

func _create_stairs_icon() -> TextureRect:
	var tex = _load_icon("icons/stairs.png", 0.85)
	if tex == null:
		return null
	var rect = TextureRect.new()
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	rect.rect_min_size = Vector2(18, 18)
	return rect

func _disable_color_pipette(picker_btn: ColorPickerButton) -> void:
	var picker = picker_btn.get_picker()
	if picker == null:
		return
	_hide_screen_picker(picker)

func _hide_screen_picker(node) -> void:
	for child in node.get_children():
		if child is ToolButton:
			child.visible = false
			return
		if child.get_child_count() > 0:
			_hide_screen_picker(child)

func _on_single_reset(key) -> void:
	_syncing = true
	if key == "shadow_color":
		ui["color"].color = DEFAULTS["shadow_color"]
	elif ui.has(key + "_slider"):
		ui[key + "_slider"].value = DEFAULTS[key]
		ui[key + "_spin"].value = DEFAULTS[key]
	_syncing = false
	apply_to_selected(false, [key])

func _on_reset() -> void:
	_syncing = true
	for key in ["sun_angle", "coverage", "diffusion", "curve", "opacity"]:
		ui[key + "_slider"].value = DEFAULTS[key]
		ui[key + "_spin"].value = DEFAULTS[key]
	ui["color"].color = DEFAULTS["shadow_color"]
	ui["link_sun"].pressed = DEFAULTS["link_sun"]
	_update_link_enabled(DEFAULTS["link_sun"])
	ui["ignore_transparency"].pressed = DEFAULTS["ignore_transparency"]
	_syncing = false
	apply_to_selected()

func _on_copy() -> void:
	_clipboard = get_config_from_ui()

func _on_paste() -> void:
	if _clipboard.empty():
		return
	_syncing = true
	for key in ["sun_angle", "coverage", "diffusion", "curve", "opacity"]:
		if _clipboard.has(key):
			ui[key + "_slider"].value = _clipboard[key]
			ui[key + "_spin"].value = _clipboard[key]
	if _clipboard.has("shadow_color"):
		var sc = _clipboard["shadow_color"]
		if sc is String:
			sc = Color(sc)
		ui["color"].color = sc
	if _clipboard.get("enabled", false):
		ui["enable"].pressed = true
		ui["panel"].visible = true
	ui["link_sun"].pressed = _clipboard.get("link_sun", false)
	_update_link_enabled(ui["link_sun"].pressed)
	ui["ignore_transparency"].pressed = _clipboard.get("ignore_transparency", false)
	_syncing = false
	apply_to_selected()

func _on_enable_toggled(pressed) -> void:
	if _syncing:
		return
	ui["panel"].visible = pressed
	apply_to_selected(true)

func _on_slider(value, key) -> void:
	if _syncing:
		return
	_syncing = true
	ui[key + "_spin"].value = value
	_syncing = false
	apply_to_selected(false, [key])

func _on_spin(value, key) -> void:
	if _syncing:
		return
	_syncing = true
	ui[key + "_slider"].value = value
	_syncing = false
	apply_to_selected(false, [key])

func _on_color(_c) -> void:
	if _syncing:
		return
	apply_to_selected(false, ["shadow_color"])

func _on_ignore_transparency_toggled(_pressed) -> void:
	if not _syncing:
		apply_to_selected(false, ["ignore_transparency"])

func _on_link_toggled(pressed) -> void:
	_update_link_enabled(pressed)
	if not _syncing:
		apply_to_selected(false, ["link_sun"])

func _update_link_enabled(linked) -> void:
	# When linked, the Sun ° controls are driven by the soft shadow -> grey + lock.
	var en = not linked
	var tint = Color(1, 1, 1, 1.0) if en else Color(1, 1, 1, 0.4)
	if ui.has("sun_angle_slider"):
		ui["sun_angle_slider"].editable = en
		ui["sun_angle_slider"].modulate = tint
	if ui.has("sun_angle_spin"):
		ui["sun_angle_spin"].editable = en
		ui["sun_angle_spin"].modulate = tint

func _linked_sun_angle(node_id):
	# World sun angle (deg) of the object's soft (drop) shadow, or null if none.
	# Projected: sun is opposite the stored shadow direction. Offset: sun is
	# opposite the offset vector.
	if not global.ModMapData.has("DropShadow"):
		return null
	var d = global.ModMapData["DropShadow"]
	if not d.has(node_id):
		return null
	var sc = d[node_id]
	if not (sc is Dictionary):
		return null
	var sun
	if sc.get("shadow_mode", "offset") == "projected":
		sun = fmod(rad2deg(sc.get("proj_angle", 0.0)) + 180.0, 360.0)
	else:
		var ox = sc.get("offset_x", 0.0)
		var oy = sc.get("offset_y", 0.0)
		if abs(ox) < 0.0001 and abs(oy) < 0.0001:
			return null
		sun = rad2deg(atan2(-oy, -ox))
	if sun < 0.0:
		sun += 360.0
	return sun

#########################################################################################################
## CONFIG <-> UI
#########################################################################################################

func get_config_from_ui() -> Dictionary:
	return {
		"enabled": ui["enable"].pressed,
		"sun_angle": ui["sun_angle_spin"].value,
		"coverage": ui["coverage_spin"].value,
		"diffusion": ui["diffusion_spin"].value,
		"curve": ui["curve_spin"].value,
		"opacity": ui["opacity_spin"].value,
		"shadow_color": ui["color"].color,
		"link_sun": ui["link_sun"].pressed,
		"ignore_transparency": ui["ignore_transparency"].pressed
	}

func load_ui_from_object(obj) -> void:
	if obj == null or not obj.has_meta("node_id"):
		return
	var cfg = DEFAULTS.duplicate()
	var nid = str(obj.get_meta("node_id"))
	if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
		for k in global.ModMapData[DATA_KEY][nid].keys():
			cfg[k] = global.ModMapData[DATA_KEY][nid][k]
	_syncing = true
	ui["enable"].pressed = cfg.get("enabled", false)
	for key in ["sun_angle", "coverage", "diffusion", "curve", "opacity"]:
		ui[key + "_slider"].value = cfg[key]
		ui[key + "_spin"].value = cfg[key]
	var sc = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if sc is String:
		sc = Color(sc)
	ui["color"].color = sc
	ui["link_sun"].pressed = cfg.get("link_sun", false)
	_update_link_enabled(ui["link_sun"].pressed)
	ui["ignore_transparency"].pressed = cfg.get("ignore_transparency", false)
	_syncing = false
	ui["panel"].visible = cfg.get("enabled", false)

#########################################################################################################
## APPLY / SAVE / SELECTION
#########################################################################################################

#########################################################################################################
## UNDO/REDO — TRANSACTIONS DE RÉGLAGES (overlay objets)
#########################################################################################################

func _history_affected() -> Array:
	var out = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_obj(node) and node.has_meta("node_id") and not out.has(node):
			out.append(node)
	return out

func _history_snapshot(nodes: Array) -> Dictionary:
	var snap = {}
	for node in nodes:
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))
		var cfg
		if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
			cfg = global.ModMapData[DATA_KEY][nid].duplicate(true)
		else:
			cfg = DEFAULTS.duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		snap[nid] = cfg
	return snap

func _history_touch(label: String = "") -> void:
	if shadow_history == null:
		return
	if _history_suspend or _syncing:
		return
	if not _history_txn_active:
		_history_txn_before = _history_snapshot(_history_affected())
		_history_txn_active = true
		_history_txn_label = label
	if _history_flush_timer != null:
		_history_flush_timer.start()

func _history_flush() -> void:
	if not _history_txn_active:
		return
	_history_txn_active = false
	if _history_flush_timer != null:
		_history_flush_timer.stop()
	var before = _history_txn_before
	_history_txn_before = {}
	if before.empty():
		return
	var after = {}
	var changed = false
	for nid in before.keys():
		var cfg
		if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
			cfg = global.ModMapData[DATA_KEY][nid].duplicate(true)
		else:
			cfg = before[nid].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		after[nid] = cfg
		if JSON.print(before[nid]) != JSON.print(cfg):
			changed = true
	if changed and shadow_history != null:
		shadow_history.record(self, "history_apply", before, after, _history_txn_label)

# Restaure un snapshot {node_id: cfg} (undo ET redo).
func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true
	var refresh = false
	for nid in payload.keys():
		var cfg = payload[nid].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		var node = _all_known_ids.get(nid)
		if node != null and is_instance_valid(node):
			remove_shadow(node)
			if cfg.get("enabled", false):
				create_shadow(node, cfg)
			save_data(node, cfg)
			if node == _monitored:
				refresh = true
		else:
			if not global.ModMapData.has(DATA_KEY):
				global.ModMapData[DATA_KEY] = {}
			global.ModMapData[DATA_KEY][nid] = payload[nid].duplicate(true)
	if refresh and _monitored != null and is_instance_valid(_monitored):
		load_ui_from_object(_monitored)
	_history_suspend = false


func apply_to_selected(force_all: bool = false, changed_keys: Array = []) -> void:
	_history_touch("overlay_obj" if changed_keys.empty() else str(changed_keys[0]))
	var ui_cfg = get_config_from_ui()
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_obj(node) or not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))
		var cfg: Dictionary
		if node == _monitored:
			# The primary selected object always gets the full UI config.
			cfg = ui_cfg
		elif force_all:
			# Enable toggle: keep the node's own settings, only override "enabled".
			cfg = _saved_or_default_cfg(nid)
			cfg["enabled"] = ui_cfg["enabled"]
		elif changed_keys.size() > 0:
			# Per-parameter edit: only touch nodes that already have an overlay,
			# and merge only the changed keys into their own config.
			cfg = _saved_or_default_cfg(nid)
			if not cfg.get("enabled", false):
				continue
			for key in changed_keys:
				if ui_cfg.has(key):
					cfg[key] = ui_cfg[key]
		else:
			# Fallback (reset all / paste): full UI config.
			cfg = ui_cfg
		if cfg["enabled"]:
			create_shadow(node, cfg)
		else:
			remove_shadow(node)
		save_data(node, cfg)

func _saved_or_default_cfg(nid: String) -> Dictionary:
	var cfg: Dictionary
	if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
		cfg = global.ModMapData[DATA_KEY][nid].duplicate(true)
	else:
		cfg = DEFAULTS.duplicate(true)
	if cfg.has("shadow_color") and cfg["shadow_color"] is String:
		cfg["shadow_color"] = Color(cfg["shadow_color"])
	return cfg

func save_data(obj, cfg: Dictionary) -> void:
	if not obj.has_meta("node_id"):
		return
	var nid = str(obj.get_meta("node_id"))
	if not global.ModMapData.has(DATA_KEY):
		global.ModMapData[DATA_KEY] = {}
	var sc = cfg.duplicate()
	if sc.has("shadow_color") and sc["shadow_color"] is Color:
		sc["shadow_color"] = sc["shadow_color"].to_html(true)
	global.ModMapData[DATA_KEY][nid] = sc

func on_selection_changed() -> void:
	_monitored = null
	var sel = global.Editor.Tools["SelectTool"].Selected
	if sel.size() > 0 and is_obj(sel[0]):
		_reparent_ui_to_node(sel[0])
		_monitored = sel[0]
		load_ui_from_object(sel[0])
		return
	var c = ui.get("container")
	if c != null and c.get_parent() != null:
		c.get_parent().remove_child(c)

func _position_container_above_cmt(vbox, container) -> void:
	# Place the Overlay Shadow section right ABOVE the "Colour and Modify
	# Things" block in the Select Tool options. CMT has no named container: it
	# inserts loose rows at the index of DD's own COLOR/STYLE label, and the
	# TOPMOST of those rows is the HBox whose first child is the "Tint Color"
	# Label — so that row is our anchor. (The Soft Shadow section anchors
	# itself on THIS container in turn, so the final order is Soft Shadow >
	# Overlay Shadow > CMT.) When CMT isn't installed (or hasn't built its UI
	# yet), do nothing; this runs on every selection, so the position heals as
	# soon as the row exists.
	if vbox == null or container == null or container.get_parent() != vbox:
		return
	var target_idx = -1
	for child in vbox.get_children():
		if child is HBoxContainer and child.get_child_count() > 0:
			var first = child.get_child(0)
			if first is Label and first.text == "Tint Color":
				target_idx = child.get_index()
				break
	if target_idx < 0:
		return
	# move_child semantics: moving DOWN shifts the anchor up by one after the
	# removal, so the "just above the anchor" slot differs by direction.
	var cur = container.get_index()
	var want = target_idx if cur > target_idx else target_idx - 1
	if cur == want or want < 0:
		return
	vbox.move_child(container, want)

func _reparent_ui_to_node(_node) -> void:
	var c = ui.get("container")
	var target = ui.get("_obj_parent")
	if c == null or target == null:
		return
	if c.get_parent() == target:
		_position_container_above_cmt(target, c)
		return
	if c.get_parent() != null:
		c.get_parent().remove_child(c)
	target.add_child(c)
	_position_container_above_cmt(target, c)

func apply_saved_shadows_to_map() -> void:
	_seed_known_ids()
	if not global.ModMapData.has(DATA_KEY):
		return
	for nid in global.ModMapData[DATA_KEY].keys():
		if int(nid) < 0:
			continue
		var iid = int(nid)
		if global.World.HasNodeID(iid):
			var node = global.World.GetNodeByID(iid)
			if is_obj(node):
				var cfg = global.ModMapData[DATA_KEY][nid]
				if cfg.get("enabled", false):
					remove_shadow(node)
					create_shadow(node, cfg)
