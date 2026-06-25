extends Reference
#########################################################################################################
##
## SHADOW BAKER
##
#########################################################################################################
# Bakes a shader-driven shadow Sprite into a plain Sprite with an ImageTexture,
# so the expensive blur shader stops running every frame for large objects.
#
# This file exposes two things:
#
#   1. ShadowBaker.bake_shadow(...)         — the viewport render + sprite swap
#   2. ShadowBaker.DebounceManager          — per-prop Timer nodes that fire bake
#                                             requests after a quiet period
#
# Typical integration flow in DropShadowObjects.gd:
#
#   On create_shadow() completion:         debounce.schedule_bake(obj)
#   On _fast_update_shadow() param change: debounce.schedule_bake(obj)  # unbakes first
#   On prop position change (drag end):    debounce.schedule_bake(obj)  # unbakes first
#   On remove_shadow(obj):                 debounce.cancel(obj)
#
# The DebounceManager handles the "revert to shader, wait, then bake" lifecycle —
# callers just say "something changed on this prop" and the manager does the rest.



const DEBOUNCE_MS := 1500
# Verbose bake logging. false = silent (default). Flip to true to trace the bake
# lifecycle (timer fire, viewport build, extract, complete) in the console.
const BAKE_DIAG := false

# Viewports this large still work fine on any modern GPU. Cap exists to prevent
# runaway memory for props with extreme vertex_scale. 8192 = 256MB at RGBA8.
const MAX_BAKE_DIMENSION := 8192

# Params read from the source ShaderMaterial to reconstruct the render pipeline.
const SHADER_PARAMS = [
	"shadow_color",
	"blur_radius",
	"spread",
	"shadow_strength",
	"blur_quality",
	"blur_steps",
	"vertex_scale_xy",
	"extrude_steps",
	"cut_offset",
	# Projected (cast) shadow params — MUST be copied or the bake renders the
	# silhouette with proj_enabled=0 (a centred blob) instead of the cast shadow.
	"proj_enabled",
	"proj_dir",
	"proj_length",
	"proj_anchor",
	"proj_taper",
	"proj_tex_size",
	"proj_fade",
	"proj_extrude",
]

# Meta key set on a shadow Sprite after it's been baked. Used so _fast_update_shadow
# and other live-param mutators can detect a baked sprite and fall back to rebuild.
const META_BAKED := "_drop_shadow_baked"

# Meta key on the Prop that holds the original shader ShaderMaterial, so we can
# restore it when unbaking without reconstructing every param.
const META_SHADER_MAT := "_drop_shadow_shader_mat"


#########################################################################################################
##
## BAKE
##
#########################################################################################################

# Async bake. Returns a new Sprite or null. Call with yield(...).
#
#   shadow_sprite: the shader-driven Sprite built by create_shadow()
#   source_sprite: the original Prop.Sprite (for texture + region)
#   global: mod global (needed for .Editor parenting)
#   mod: (optional) the mod instance, for outputlog diagnostics
static func bake_shadow(shadow_sprite: Sprite, source_sprite: Sprite, global, mod = null) -> Sprite:
	# IMPORTANT: This function must yield at least once on every code path before
	# returning, otherwise `yield(bake_shadow(...), "completed")` in callers gets
	# a plain null instead of a GDScriptFunctionState and crashes hard in Godot 3.4.
	# The first statement is an unconditional yield for exactly this reason.
	yield(global.Editor.get_tree(), "idle_frame")

	if shadow_sprite == null or not is_instance_valid(shadow_sprite):
		_dbg(mod, "bake: shadow_sprite invalid, abort")
		return null
	if source_sprite == null or source_sprite.texture == null:
		_dbg(mod, "bake: source_sprite or texture null, abort")
		return null

	var mat := shadow_sprite.material as ShaderMaterial
	if mat == null:
		_dbg(mod, "bake: shadow_sprite has no ShaderMaterial, abort")
		return null

	# Per-axis quad scale. Falls back to a legacy scalar "vertex_scale" param if a
	# shadow built by an older module version is somehow still around.
	var vsxy: Vector2 = Vector2.ONE
	var vsxy_param = mat.get_shader_param("vertex_scale_xy")
	if vsxy_param is Vector2:
		vsxy = vsxy_param
	else:
		var legacy = mat.get_shader_param("vertex_scale")
		var lf = float(legacy) if legacy != null else 1.0
		vsxy = Vector2(lf, lf)
	if vsxy.x <= 0.0:
		vsxy.x = 1.0
	if vsxy.y <= 0.0:
		vsxy.y = 1.0

	var tex: Texture = source_sprite.texture
	var tex_size: Vector2 = tex.get_size()
	if source_sprite.region_enabled:
		tex_size = source_sprite.region_rect.size
	if tex_size.x < 1.0 or tex_size.y < 1.0:
		_dbg(mod, "bake: tex_size degenerate, abort")
		return null

	var viewport_size := Vector2(
		ceil(tex_size.x * vsxy.x),
		ceil(tex_size.y * vsxy.y)
	)
	if viewport_size.x > MAX_BAKE_DIMENSION or viewport_size.y > MAX_BAKE_DIMENSION:
		_dbg(mod, "bake: viewport too large %s, abort" % viewport_size)
		return null

	_dbg(mod, "bake: begin tex=%s vs=%s vp=%s" % [tex_size, vsxy, viewport_size])
	var tree := global.Editor.get_tree()

	var viewport := _build_viewport(viewport_size)
	var render_sprite := _build_render_sprite(source_sprite, viewport_size, mat)
	viewport.add_child(render_sprite)
	_dbg(mod, "bake: viewport built, adding to Editor")
	global.Editor.add_child(viewport)

	# Two more idle frames to let the viewport render.
	_dbg(mod, "bake: yielding frame 1")
	yield(tree, "idle_frame")
	_dbg(mod, "bake: yielding frame 2")
	yield(tree, "idle_frame")

	_dbg(mod, "bake: extracting sprite")
	var baked := _extract_sprite(viewport, shadow_sprite, mod)

	_dbg(mod, "bake: freeing viewport")
	viewport.queue_free()
	_dbg(mod, "bake: complete, baked=%s" % ("valid" if baked != null else "null"))
	return baked


static func _dbg(mod, msg: String) -> void:
	if not BAKE_DIAG:
		return
	if mod != null and mod.has_method("outputlog"):
		mod.outputlog("ShadowBaker: " + msg, 0)


# Swap shadow_sprite for baked_sprite in the scene tree, preserving index + parent.
# Called by DebounceManager after a successful bake. Safe to call standalone.
static func install_baked(obj, shadow_sprite: Sprite, baked: Sprite, shadow_meta_key: String) -> void:
	if obj == null or not is_instance_valid(obj):
		baked.queue_free()
		return
	if shadow_sprite == null or not is_instance_valid(shadow_sprite):
		baked.queue_free()
		return

	# Preserve the shader material on the prop so unbake can restore it without
	# reconstructing params from the config.
	var shader_mat = shadow_sprite.material
	if shader_mat != null:
		obj.set_meta(META_SHADER_MAT, shader_mat)

	var parent = shadow_sprite.get_parent()
	var idx = shadow_sprite.get_index()
	parent.remove_child(shadow_sprite)
	shadow_sprite.queue_free()

	baked.set_meta(META_BAKED, true)
	parent.add_child(baked)
	parent.move_child(baked, idx)
	obj.set_meta(shadow_meta_key, [baked])


# Revert a baked sprite back to its shader form. Use when params change, the prop
# moves (if clipped), etc. Keeps the same Sprite node — just swaps texture+material
# back. Returns true if an unbake actually happened.
static func unbake(obj, shadow_meta_key: String, source_sprite: Sprite) -> bool:
	if obj == null or not is_instance_valid(obj):
		return false
	if not obj.has_meta(shadow_meta_key):
		return false

	var nodes = obj.get_meta(shadow_meta_key)
	if nodes == null or nodes.size() == 0:
		return false

	var baked: Sprite = nodes[0]
	if baked == null or not is_instance_valid(baked):
		return false
	if not baked.has_meta(META_BAKED):
		return false  # already shader, nothing to do

	var shader_mat = null
	if obj.has_meta(META_SHADER_MAT):
		shader_mat = obj.get_meta(META_SHADER_MAT)

	# Restore the source texture and shader. The Sprite node itself is reused so
	# its position/z_index/show_behind_parent all stay intact.
	baked.texture = source_sprite.texture
	baked.region_enabled = source_sprite.region_enabled
	if source_sprite.region_enabled:
		baked.region_rect = source_sprite.region_rect
	baked.material = shader_mat
	baked.remove_meta(META_BAKED)
	return true


static func is_baked(obj, shadow_meta_key: String) -> bool:
	if obj == null or not is_instance_valid(obj):
		return false
	if not obj.has_meta(shadow_meta_key):
		return false
	var nodes = obj.get_meta(shadow_meta_key)
	if nodes == null or nodes.size() == 0:
		return false
	var s = nodes[0]
	return s != null and is_instance_valid(s) and s.has_meta(META_BAKED)


#########################################################################################################
##
## INTERNALS
##
#########################################################################################################

static func _build_viewport(size: Vector2) -> Viewport:
	var vp := Viewport.new()
	vp.size = size
	vp.transparent_bg = true
	# NOTE: we do NOT set render_target_v_flip here. The flip happens on the CPU
	# in _extract_sprite via img.flip_y(), which is consistent across drivers.
	# Setting both flags causes a double-flip on some systems (GLES2 especially).
	vp.render_target_v_flip = false
	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.own_world = true
	vp.render_target_clear_mode = Viewport.CLEAR_MODE_ONLY_NEXT_FRAME
	return vp


static func _build_render_sprite(source_sprite: Sprite, viewport_size: Vector2,
		source_mat: ShaderMaterial) -> Sprite:
	var s := Sprite.new()
	s.texture = source_sprite.texture
	s.centered = true
	s.position = viewport_size * 0.5
	s.rotation = 0.0
	s.scale = Vector2.ONE

	s.region_enabled = source_sprite.region_enabled
	if source_sprite.region_enabled:
		s.region_rect = source_sprite.region_rect

	var mat := ShaderMaterial.new()
	mat.shader = source_mat.shader
	for p in SHADER_PARAMS:
		var v = source_mat.get_shader_param(p)
		if v != null:
			mat.set_shader_param(p, v)
	# Zero clip params — the baked image is the unclipped shadow. Clipped props
	# rebake on position change via the debounce manager.
	mat.set_shader_param("poly_count", 0)
	s.material = mat
	return s


static func _extract_sprite(viewport: Viewport, shadow_sprite: Sprite, mod = null) -> Sprite:
	_dbg(mod, "extract: get_texture")

	if shadow_sprite == null:
		_dbg(mod, "extract: shadow_sprite is null, abort")
		return null

	var vp_tex := viewport.get_texture()
	if vp_tex == null:
		_dbg(mod, "extract: viewport texture null, abort")
		return null
	_dbg(mod, "extract: get_data")
	var img: Image = vp_tex.get_data()
	if img == null or img.is_empty():
		_dbg(mod, "extract: image null/empty, abort")
		return null
	_dbg(mod, "extract: flip_y")
	img.flip_y()

	_dbg(mod, "extract: create_from_image size=%s fmt=%d" % [img.get_size(), img.get_format()])
	var baked_tex := ImageTexture.new()
	# FLAG_MIPMAPS on viewport-captured images is a known Godot 3.4 segfault vector.
	# Just FLAG_FILTER is enough for shadow visual quality.
	baked_tex.create_from_image(img, Texture.FLAG_FILTER)
	_dbg(mod, "extract: texture created: " + str(baked_tex))

	var out := Sprite.new()
	out.name = shadow_sprite.name
	out.texture = baked_tex
	out.centered = shadow_sprite.centered
	out.position = shadow_sprite.position
	out.rotation = shadow_sprite.rotation
	out.scale = shadow_sprite.scale
	out.z_index = shadow_sprite.z_index
	out.z_as_relative = shadow_sprite.z_as_relative
	out.show_behind_parent = shadow_sprite.show_behind_parent
	out.modulate = shadow_sprite.modulate
	out.self_modulate = shadow_sprite.self_modulate
	# Preserve visibility — otherwise a Hide done via ShadowToggle (or any
	# external code setting visible=false on the shader sprite) gets undone
	# when the debounced bake swaps it for a fresh baked sprite.
	out.visible = shadow_sprite.visible

	for m in shadow_sprite.get_meta_list():
		out.set_meta(m, shadow_sprite.get_meta(m))

	_dbg(mod, "extract: completed")
	return out


#########################################################################################################
##
## DEBOUNCE MANAGER
##
#########################################################################################################
#
# Per-prop Timer that fires a bake after DEBOUNCE_MS of quiet. Any schedule_bake()
# call while a timer is running resets it AND unbakes the prop immediately (so the
# user sees live shader feedback during the quiet period).
#
# Usage:
#   var baker_script = load(global.Root + "scripts/ShadowBaker.gd")
#   var debounce = baker_script.DebounceManager.new(mod, SHADOW_META_KEY, baker_script)
#   debounce.schedule_bake(prop)   # after any change that invalidates the baked form
#   debounce.cancel(prop)          # on remove_shadow

class DebounceManager extends Reference:

	# Mirror of the outer ShadowBaker.BAKE_DIAG (nested classes can't read the outer
	# const). Keep both in sync; false = silent (default).
	const BAKE_DIAG := false

	var _mod                 # the DropShadowObjects instance; needs .global and .get_sprite()
	var _shadow_meta_key: String
	var _baker               # the outer ShadowBaker script (so we can call its statics)

	# Keyed by obj.get_instance_id() so we don't hold direct refs to freed props.
	# Timers are parented under global.Editor (NOT under the Prop — DD serialises
	# Prop children into map saves and a stray Timer crashes that path).
	var _timers := {}        # int instance_id -> Timer
	var _obj_refs := {}      # int instance_id -> WeakRef to obj (for firing)

	# baker_script: pass the result of load("res://.../ShadowBaker.gd") — needed
	# because Godot 3.4 inner classes can't reference the outer script by name.
	func _init(mod, shadow_meta_key: String, baker_script):
		_mod = mod
		_shadow_meta_key = shadow_meta_key
		_baker = baker_script

	# Call whenever something changed on the prop that invalidates the baked form.
	# Unbakes immediately, then waits DEBOUNCE_MS before re-baking.
	func schedule_bake(obj) -> void:
		if obj == null or not is_instance_valid(obj):
			return

		# Revert to shader immediately so live edits stay responsive.
		var source_sprite = _mod.get_sprite(obj)
		if source_sprite != null:
			_baker.unbake(obj, _shadow_meta_key, source_sprite)

		var iid := obj.get_instance_id()
		var timer: Timer = null
		if _timers.has(iid):
			var existing = _timers[iid]
			if is_instance_valid(existing):
				timer = existing
			else:
				_timers.erase(iid)

		if timer == null:
			timer = Timer.new()
			timer.one_shot = true
			timer.wait_time = DEBOUNCE_MS / 1000.0
			timer.connect("timeout", self, "_on_timer_fired", [iid])
			_mod.global.Editor.add_child(timer)
			_timers[iid] = timer

		_obj_refs[iid] = weakref(obj)
		timer.stop()
		timer.start()

	func cancel(obj) -> void:
		if obj == null or not is_instance_valid(obj):
			return
		var iid := obj.get_instance_id()
		_cancel_by_id(iid)

	func _cancel_by_id(iid: int) -> void:
		if _timers.has(iid):
			var timer = _timers[iid]
			if is_instance_valid(timer):
				timer.stop()
				timer.queue_free()
			_timers.erase(iid)
		_obj_refs.erase(iid)

	func _on_timer_fired(iid: int) -> void:
		if BAKE_DIAG and _mod != null and _mod.has_method("outputlog"):
			_mod.outputlog("ShadowBaker: timer fired for iid=%d" % iid, 0)

		# Pull the obj out via weakref BEFORE cleanup — _cancel_by_id erases _obj_refs.
		var obj = null
		if _obj_refs.has(iid):
			obj = _obj_refs[iid].get_ref()
		_cancel_by_id(iid)

		if obj == null or not is_instance_valid(obj):
			if BAKE_DIAG and _mod != null and _mod.has_method("outputlog"):
				_mod.outputlog("ShadowBaker: obj freed before timer fire, skip", 0)
			return
		if not obj.has_meta(_shadow_meta_key):
			return

		var nodes = obj.get_meta(_shadow_meta_key)
		if nodes == null or nodes.size() == 0:
			return
		var shadow_sprite: Sprite = nodes[0]
		if shadow_sprite == null or not is_instance_valid(shadow_sprite):
			return
		if shadow_sprite.has_meta(META_BAKED):
			return

		# Projected shadows stay live (large textures = VRAM cost + fragile viewport
		# capture). DropShadowObjects never queues them, this is defense-in-depth in
		# case a mode switch left a stale timer pending.
		if obj.has_meta("_shadow_config"):
			var cfg = obj.get_meta("_shadow_config")
			if cfg is Dictionary and cfg.get("shadow_mode", "offset") == "projected":
				return

		var source_sprite = _mod.get_sprite(obj)
		if source_sprite == null:
			return

		var baked = yield(_baker.bake_shadow(shadow_sprite, source_sprite, _mod.global, _mod), "completed")
		if baked == null:
			return
		if not is_instance_valid(obj) or not is_instance_valid(shadow_sprite):
			baked.queue_free()
			return
		# If schedule_bake was called again during the bake, a fresh timer will be
		# pending — skip install and let the next fire do it.
		if _timers.has(obj.get_instance_id()):
			baked.queue_free()
			return
		_baker.install_baked(obj, shadow_sprite, baked, _shadow_meta_key)
