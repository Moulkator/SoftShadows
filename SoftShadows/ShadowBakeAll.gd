extends Reference
#########################################################################################################
##
## SHADOW BAKE ALL  -  global per-level shadow flattening (objects slice)
##
#########################################################################################################
# Replaces many live shader object-shadows with ONE static overlay sprite per
# level, placed ON TOP of everything, then turns the per-object toggles OFF (perf).
# Reversible (unbake).
#
# Method (variant B, "darkening overlay"): render the level twice in real paint
# order, toggling ONLY the object-shadow sprites:
#   R0 = object shadows OFF      R1 = object shadows ON
# The difference isolates the object-shadow contribution with correct z-order
# (R1 is the true render), so shadows that fall ONTO objects are kept and shadows
# hidden BEHIND objects are dropped. Everything unaffected by object shadows is
# identical in R0/R1 and cancels.
#
# Overlay per pixel (on the premultiplied data the viewport returns):
#   R1 transparent          -> transparent
#   R0 transparent (void)   -> the shadow itself (keeps colour)
#   else (shadow on content)-> black, alpha = how much darker R1 is than R0
# Placed on top with normal alpha blend over the live (shadow-off) scene it
# reproduces the shadowed look; objects stay crisp.
#
# Capture mirrors DD's Exporter: pan global.Camera in viewport-sized chunks and
# stitch global.Camera.get_viewport().get_texture().get_data().

var global
var core = null
var dropshadow_objects = null
var logging_level = 0

const ENABLE_LOGGING = true

# Bake resolution in pixels per tile. 256 == TileSize == 1:1 pixel-perfect overlay.
# Lower it on very large maps (memory + CPU combine cost).
var px_per_tile := 256
# Fractional dilation of the baked overlay (0 = off, 1 = full 1px ring). Kept at
# 1 to close the radial sub-pixel sliver left by the capture at 256 px/tile.
var overlay_grow := 1.0

const OVERLAY_NAME := "DropShadowBakeOverlay"
const OVERLAY_Z := 4096                       # Godot Node2D z_index max -> on top of all
const ALPHA_EPS_BYTE := 1                      # ~0.004 * 255
const BAKE_RECORD_KEY := "DropShadowBakeAll"   # ModMapData: save/reload safety record
const OBJECTS_CONTAINER := "Objects"
const TOGGLE_STATE_KEY := "DropShadowToggleHidden"  # shared with ShadowToggle floatbar button

# GPU overlay compute. The per-pixel build/grow run as shader passes instead of
# slow GDScript loops. Tiled at a size safe for both GLES2 and GLES3; falls back
# to the CPU path automatically if a pass can't be set up / read back.
const GPU_MAX_TILE := 4096
var _use_gpu := true
var _build_shader_res = null
var _grow_shader_res = null

# Output-resolution cap for huge maps. At px_per_tile = 256 a very large map
# produces multi-gigabyte images (RAM blows up, the machine swaps, the bake
# stalls). When the full-res output would exceed this on its largest side, the
# effective px/tile is lowered so the image stays bounded — softer shadows on
# enormous maps, but the bake actually finishes. Normal maps stay at 256.
var max_output_dim := 12288

# Fallbacks if the objects module can't be queried for its key constants.
const FALLBACK_META_KEY := "drop_shadow_obj_nodes"  # kept for reference
const FALLBACK_DATA_KEY := "DropShadow"             # kept for reference

# level.get_instance_id() -> { level, overlay: Sprite, off: [{id, kind}], ppt: int }
var _bake_records := {}
var _busy := false

# Which asset categories to include when baking (checkboxes). Unbake ignores this
# and always restores whatever was actually baked.
var _cat_enabled := {"objects": true, "paths": true, "walls": true, "roofs": true}
var _cat_checkboxes := []   # CheckBox refs, greyed out while a bake exists

# Seconds to keep the loading popup up after the sweep, covering DD's post-bake
# recompute freeze. A SceneTreeTimer spans the freeze (no process time elapses
# during it), so the popup stays visible throughout.
const FINALIZE_HOLD_SEC := 1.5

# Mirrors the floatbar Shadows toggle so baked overlays hide/show with it.
# null forces a first sync in on_update.
var _last_hidden = null

# Loading popup
var _progress_panel = null
var _progress_bar = null
var _progress_label = null
# Smooth bar easing: _progress_set moves the target; on_update eases the shown
# value toward it each frame so the bar glides instead of stepping.
var _prog_target := 0.0
var _prog_shown := 0.0
var _prog_last_ms := 0

# UI refs (bake/unbake buttons)
var _bake_btn = null
var _unbake_btn = null
var _last_level_iid := 0
var _scope_all := false   # false = current level, true = all levels


func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <ShadowBakeAll>: " % OS.get_ticks_msec())
		print(msg)


func initialise():
	if dropshadow_objects == null:
		if global != null and global.ModMapData.has("_dropshadow_refs"):
			dropshadow_objects = global.ModMapData["_dropshadow_refs"].get("objects")
	outputlog("ShadowBakeAll initialised (objects=%s)" % str(dropshadow_objects != null), 0)
	var drv = OS.get_video_driver_name(OS.get_current_video_driver())
	outputlog("Video driver: %s | GPU: %s" % [str(drv), str(VisualServer.get_video_adapter_name())], 0)


#########################################################################################################
## SHADOW-KIND TABLE
#########################################################################################################
# Every shadow type shares the same pattern: a host container + a meta key on
# each host holding its shadow-node array (for R0/R1 visibility toggling) + a
# ModMapData bucket holding each host's config (with an "enabled" flag) + a
# module exposing create/remove methods (host, cfg)/(host). One table row per
# type makes the bake generic; adding a type = adding a row.
#
# "create"/"remove" name the module methods; they default to the standard pair
# except for path overlays, which expose a distinct pair.
func _kinds() -> Array:
	return [
		{"kind": "obj",          "cat": "objects", "ref": "objects",         "container": "Objects",  "meta": "drop_shadow_obj_nodes",    "data": "DropShadow",         "create": "create_shadow",         "remove": "remove_shadow",         "meta_cfg": ""},
		{"kind": "obj_overlay",  "cat": "objects", "ref": "overlay_objects", "container": "Objects",  "meta": "overlay_shadow_obj_nodes", "data": "OverlayShadow",      "create": "create_shadow",         "remove": "remove_shadow",         "meta_cfg": ""},
		{"kind": "path",         "cat": "paths",   "ref": "paths",           "container": "Pathways", "meta": "drop_shadow_nodes",        "data": "DropShadow",         "create": "create_shadow",         "remove": "remove_shadow",         "meta_cfg": ""},
		{"kind": "path_overlay", "cat": "paths",   "ref": "paths",           "container": "Pathways", "meta": "overlay_shadow_nodes",     "data": "DropShadowOverlay",  "create": "create_overlay_shadow", "remove": "remove_overlay_shadow", "meta_cfg": ""},
		{"kind": "wall",         "cat": "walls",   "ref": "walls",           "container": "Walls",    "meta": "drop_shadow_nodes",        "data": "DropShadow",         "create": "create_shadow",         "remove": "remove_shadow",         "meta_cfg": ""},
		{"kind": "roof",         "cat": "roofs",   "ref": "roofs",           "container": "Roofs",    "meta": "drop_shadow_nodes",        "data": "DropShadowRoof",     "create": "create_shadow",         "remove": "remove_shadow",         "meta_cfg": "_drop_shadow_roof_config"},
	]


# Kinds whose category checkbox is currently enabled (bake-time filter only).
func _active_kinds() -> Array:
	var out := []
	for k in _kinds():
		if _cat_enabled.get(k["cat"], true):
			out.append(k)
	return out


func _kind_by_id(kid: String):
	for k in _kinds():
		if k["kind"] == kid:
			return k
	return null


func _refs() -> Dictionary:
	if global != null and global.ModMapData.has("_dropshadow_refs"):
		var r = global.ModMapData["_dropshadow_refs"]
		if r is Dictionary:
			return r
	return {}


# Resolve the module exposing create_shadow/remove_shadow for a kind's ref key.
func _module_for(ref_key: String):
	var refs = _refs()
	if refs.has(ref_key) and refs[ref_key] != null:
		return refs[ref_key]
	if ref_key == "objects":
		return dropshadow_objects   # always present, used before refs are published
	return null


# Normalise a persisted record's off-list to [{id, kind}], accepting the legacy
# "off_ids" (objects-only) format from earlier saves.
func _record_off_list(entry: Dictionary) -> Array:
	if entry.has("off") and entry["off"] is Array:
		return entry["off"]
	var out := []
	for id in entry.get("off_ids", []):
		out.append({"id": str(id), "kind": "obj"})
	return out


func _get_config_dk(id: String, dk: String):
	if global.ModMapData.has(dk) and global.ModMapData[dk].has(id):
		return global.ModMapData[dk][id]
	return null


func _set_enabled_dk(id: String, value: bool, dk: String) -> void:
	if global.ModMapData.has(dk) and global.ModMapData[dk].has(id):
		var cfg = global.ModMapData[dk][id]
		if cfg is Dictionary:
			cfg["enabled"] = value


# Some modules (roofs) keep an in-memory/meta config cache that their periodic
# "heal" prefers over ModMapData; that cache's dict is the same object as the
# host's meta_cfg meta. Setting enabled there too stops the heal from rebuilding
# a shadow on top of the baked overlay.
func _set_host_cfg_enabled(host, meta_cfg_key: String, value: bool) -> void:
	if meta_cfg_key == "" or host == null or not is_instance_valid(host):
		return
	if host.has_meta(meta_cfg_key):
		var cfg = host.get_meta(meta_cfg_key)
		if cfg is Dictionary:
			cfg["enabled"] = value


#########################################################################################################
## FLOATBAR TOGGLE  (baked overlays follow the global Shadows show/hide)
#########################################################################################################

func _shadows_hidden() -> bool:
	return bool(global.ModMapData.get(TOGGLE_STATE_KEY, false))


func set_overlays_visible(visible: bool) -> void:
	for lid in _bake_records:
		var spr = _bake_records[lid].get("overlay")
		if spr != null and is_instance_valid(spr):
			spr.visible = visible


#########################################################################################################
## LOADING POPUP
#########################################################################################################

func _progress_open(title_text: String) -> void:
	_progress_close()
	if global.Editor == null:
		return
	var panel := Panel.new()
	panel.rect_size = Vector2(340, 96)
	# Opaque dark background so the map doesn't show through the popup.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.11, 0.12, 0.98)
	sb.border_color = Color(0, 0, 0, 0.9)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	panel.add_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	vb.margin_left = 16; vb.margin_top = 16
	vb.margin_right = -16; vb.margin_bottom = -16
	var lbl := Label.new()
	lbl.text = title_text
	vb.add_child(lbl)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 0
	vb.add_child(bar)
	panel.add_child(vb)
	global.Editor.add_child(panel)
	var vp = global.Editor.get_viewport().get_visible_rect().size
	panel.rect_position = ((vp - panel.rect_size) / 2.0).floor()
	_progress_panel = panel
	_progress_bar = bar
	_progress_label = lbl
	_prog_target = 0.0
	_prog_shown = 0.0
	_prog_last_ms = OS.get_ticks_msec()


# Sets the TARGET fraction (0..1); the bar eases toward it in _progress_tick.
func _progress_set(frac: float, msg: String) -> void:
	_prog_target = clamp(frac, 0.0, 1.0)
	if msg != "" and _progress_label != null and is_instance_valid(_progress_label):
		_progress_label.text = msg


# Called every frame from on_update: glide the shown value toward the target.
func _progress_tick() -> void:
	if _progress_bar == null or not is_instance_valid(_progress_bar):
		return
	var now = OS.get_ticks_msec()
	var dt = float(now - _prog_last_ms) / 1000.0
	_prog_last_ms = now
	if dt < 0.0:
		dt = 0.0
	# Exponential approach; reaches ~the target within ~0.25 s of steady frames.
	var k = clamp(dt / 0.25, 0.0, 1.0)
	_prog_shown += (_prog_target - _prog_shown) * k
	_progress_bar.value = _prog_shown * 100.0


func _progress_close() -> void:
	if _progress_panel != null and is_instance_valid(_progress_panel):
		if _progress_panel.get_parent() != null:
			_progress_panel.get_parent().remove_child(_progress_panel)
		_progress_panel.queue_free()
	_progress_panel = null
	_progress_bar = null
	_progress_label = null


# Holds the popup up through DD's post-sweep recompute freeze, then closes.
func _progress_finalize_and_close() -> void:
	_progress_set(1.0, "Finalizing…")
	var tree = global.Editor.get_tree()
	yield(tree, "idle_frame")
	yield(tree.create_timer(FINALIZE_HOLD_SEC), "timeout")
	_progress_close()


#########################################################################################################
## UI
#########################################################################################################

func build_controls(container):
	if container == null:
		return
	container.add_child(HSeparator.new())

	var title = Label.new()
	title.text = "Bake All Shadows"
	container.add_child(title)

	var scope_hb = HBoxContainer.new()
	var scope_lbl = Label.new()
	scope_lbl.text = "Scope"
	scope_hb.add_child(scope_lbl)
	var scope_opt = OptionButton.new()
	scope_opt.add_item("This level", 0)
	scope_opt.add_item("All levels", 1)
	scope_opt.selected = (1 if _scope_all else 0)
	scope_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scope_opt.connect("item_selected", self, "_on_scope_changed")
	scope_hb.add_child(scope_opt)
	container.add_child(scope_hb)

	# Asset-type checkboxes (which categories to include when baking).
	var types_lbl = Label.new()
	types_lbl.text = "Asset types"
	container.add_child(types_lbl)
	var grid = GridContainer.new()
	grid.columns = 2
	_cat_checkboxes = []
	for cat in ["objects", "paths", "walls", "roofs"]:
		var cb = CheckBox.new()
		cb.text = cat.capitalize()
		cb.pressed = _cat_enabled.get(cat, true)
		cb.connect("toggled", self, "_on_cat_toggled", [cat])
		grid.add_child(cb)
		_cat_checkboxes.append(cb)
	container.add_child(grid)

	var bake_btn = Button.new()
	bake_btn.text = "Render shadows"
	bake_btn.connect("pressed", self, "_on_bake_pressed")
	container.add_child(bake_btn)
	_bake_btn = bake_btn

	var unbake_btn = Button.new()
	unbake_btn.text = "Unbake"
	unbake_btn.connect("pressed", self, "_on_unbake_pressed")
	container.add_child(unbake_btn)
	_unbake_btn = unbake_btn

	var help = Label.new()
	help.autowrap = true
	help.text = "Merges the chosen shadow types into one image per level — more FPS, less lag — and Unbake restores them. This differs from the per-asset Render bake, where each asset's shadow is baked individually and stays on the asset."
	help.modulate = Color(1, 1, 1, 0.6)
	container.add_child(help)

	_refresh_buttons()


func _on_cat_toggled(pressed: bool, cat: String) -> void:
	_cat_enabled[cat] = pressed


func _on_scope_changed(index: int) -> void:
	_scope_all = (index == 1)
	_refresh_buttons()


# Enable/disable the two buttons based on bake state and the chosen scope.
func _refresh_buttons() -> void:
	if _bake_btn == null or not is_instance_valid(_bake_btn):
		return
	if _busy:
		_bake_btn.disabled = true
		_unbake_btn.disabled = true
		_set_cats_disabled(true)
		_set_button_border(_bake_btn, false)
		_set_button_border(_unbake_btn, false)
		return
	var world = global.get("World")
	if _scope_all:
		# If ANY level is baked, the only coherent all-levels action is Unbake
		# (Render would silently skip the already-baked levels).
		var any_baked = _bake_records.size() > 0
		_bake_btn.disabled = any_baked
		_unbake_btn.disabled = not any_baked
	else:
		var baked = false
		if world != null:
			var level = _current_level(world)
			if level != null:
				baked = _bake_records.has(level.get_instance_id())
		_bake_btn.disabled = baked
		_unbake_btn.disabled = not baked
	# Category checkboxes are pointless once something is baked (Unbake restores
	# everything regardless), so grey them whenever Unbake is available.
	_set_cats_disabled(not _unbake_btn.disabled)
	# 1px white border on a button only while it is available.
	_set_button_border(_bake_btn, not _bake_btn.disabled)
	_set_button_border(_unbake_btn, not _unbake_btn.disabled)


# Adds (on) or removes (off) a 1px white border on a button across its visible
# states, preserving the theme's background where possible.
func _set_button_border(btn, on: bool) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	for state in ["normal", "hover", "pressed"]:
		if on:
			var base = btn.get_stylebox(state)
			var sb
			if base != null and base is StyleBoxFlat:
				sb = base.duplicate()
			else:
				sb = StyleBoxFlat.new()
				sb.bg_color = Color(0.18, 0.18, 0.20, 1.0)
			sb.border_color = Color(1, 1, 1, 1)
			sb.border_width_left = 1
			sb.border_width_top = 1
			sb.border_width_right = 1
			sb.border_width_bottom = 1
			btn.add_stylebox_override(state, sb)
		else:
			btn.add_stylebox_override(state, null)


func _set_cats_disabled(disabled: bool) -> void:
	for cb in _cat_checkboxes:
		if cb != null and is_instance_valid(cb):
			cb.disabled = disabled


# Called every frame from Core.update — only refreshes when the level changed.
func on_update() -> void:
	_progress_tick()
	# Keep baked overlays in sync with the floatbar Shadows toggle.
	var hidden = _shadows_hidden()
	if _last_hidden == null or hidden != _last_hidden:
		_last_hidden = hidden
		set_overlays_visible(not hidden)
	if _bake_btn == null or not is_instance_valid(_bake_btn):
		return
	var world = global.get("World")
	if world == null:
		return
	var level = _current_level(world)
	var iid = (level.get_instance_id() if level != null else 0)
	if iid != _last_level_iid:
		_last_level_iid = iid
		_refresh_buttons()


func _on_bake_pressed():
	if _scope_all:
		bake_all_levels()
	else:
		bake_current_level()


func _on_unbake_pressed():
	if _scope_all:
		unbake_all_levels()
	else:
		unbake_current_level()


#########################################################################################################
## BAKE / UNBAKE
#########################################################################################################

func bake_current_level():
	if _busy:
		outputlog("bake: busy, ignored", 0)
		return
	var world = global.get("World")
	var camera = global.get("Camera")
	var ui = global.get("WorldUI")
	if world == null or camera == null:
		outputlog("bake: world/camera missing, abort", 0)
		return
	var viewport = camera.get_viewport()
	var level = _current_level(world)
	if level == null or viewport == null:
		outputlog("bake: no current level / viewport, abort", 0)
		return
	_busy = true
	_refresh_buttons()
	_progress_open("Rendering shadows…")
	yield(_bake_level(world, camera, ui, viewport, level, 0.0, 1.0), "completed")
	yield(_progress_finalize_and_close(), "completed")
	_busy = false
	_refresh_buttons()


func bake_all_levels():
	if _busy:
		outputlog("bake_all: busy, ignored", 0)
		return
	var world = global.get("World")
	var camera = global.get("Camera")
	var ui = global.get("WorldUI")
	if world == null or camera == null:
		outputlog("bake_all: world/camera missing, abort", 0)
		return
	var viewport = camera.get_viewport()
	if viewport == null:
		outputlog("bake_all: viewport missing, abort", 0)
		return
	var levels = world.call("get_AllLevels")
	if levels == null or levels.size() == 0:
		outputlog("bake_all: no levels, abort", 0)
		return

	_busy = true
	_refresh_buttons()
	_progress_open("Rendering shadows…")
	var n = levels.size()
	var original = world.call("get_CurrentLevelId")
	var tree = global.Editor.get_tree()
	outputlog("bake_all: %d levels" % n, 0)
	for i in range(n):
		world.call("SetLevel", i, false)
		yield(tree, "idle_frame")
		yield(tree, "idle_frame")
		var lvl = _current_level(world)
		outputlog("bake_all: index %d -> level %s" % [i, str(lvl.name) if lvl != null else "null"], 0)
		if lvl != null and not _bake_records.has(lvl.get_instance_id()):
			yield(_bake_level(world, camera, ui, viewport, lvl, float(i) / float(n), float(i + 1) / float(n)), "completed")
	# Restore the level the user was on.
	world.call("SetLevel", original, false)
	yield(tree, "idle_frame")
	yield(_progress_finalize_and_close(), "completed")
	outputlog("bake_all: done", 0)
	_busy = false
	_refresh_buttons()


# Bakes ONE level which must already be the current/visible level (so the main
# viewport renders it). Yields; returns true if an overlay was produced.
func _bake_level(world, camera, ui, viewport, level, prog_lo := 0.0, prog_hi := 0.0) -> bool:
	yield(global.Editor.get_tree(), "idle_frame")  # ensure a FunctionState before any return

	var lid = level.get_instance_id()
	if _bake_records.has(lid):
		return false

	var entries := []        # [ {host, id, kind} ]
	var shadow_nodes := []
	for kdef in _active_kinds():
		var container = level.get(kdef["container"])
		if container == null:
			continue
		var mk = kdef["meta"]
		for host in container.get_children():
			if not host.has_meta(mk):
				continue
			var nid = _node_id(host)
			if nid == "":
				continue
			entries.append({"host": host, "id": nid, "kind": kdef["kind"]})
			var nodes = host.get_meta(mk)
			if nodes is Array:
				for n in nodes:
					if is_instance_valid(n):
						shadow_nodes.append(n)
	if entries.size() == 0:
		outputlog("bake: no shadows on level %s" % str(level.name), 0)
		return false

	var ppt = _effective_ppt(world)
	var w_tiles = int(world.get("Width"))
	var h_tiles = int(world.get("Height"))
	var t_start = OS.get_ticks_msec()
	if ppt < px_per_tile:
		outputlog("bake: level %s — %d shadows, map %dx%d tiles, ppt LOWERED %d->%d (out %dx%d) to fit %d cap" % [str(level.name), entries.size(), w_tiles, h_tiles, px_per_tile, ppt, w_tiles * ppt, h_tiles * ppt, max_output_dim], 0)
	else:
		outputlog("bake: level %s — %d shadows, map %dx%d tiles @ %d px/tile (out %dx%d)" % [str(level.name), entries.size(), w_tiles, h_tiles, ppt, w_tiles * ppt, h_tiles * ppt], 0)

	# --- capture R0 (off) / R1 (on) ---
	var prev_ui_vis = (ui.visible if ui != null else true)
	var prev_tbg = viewport.get("transparent_bg")
	if ui != null:
		ui.visible = false
	viewport.set("transparent_bg", true)

	var span = prog_hi - prog_lo
	var p_r0 = prog_lo + 0.35 * span
	var p_r1 = prog_lo + 0.70 * span
	for n in shadow_nodes:
		n.visible = false
	_progress_set(prog_lo, "Baking %s — pass 1/2" % str(level.name))
	var r0 = yield(_capture(world, camera, viewport, ppt, prog_lo, p_r0), "completed")
	for n in shadow_nodes:
		n.visible = true
	_progress_set(p_r0, "Baking %s — pass 2/2" % str(level.name))
	var r1 = yield(_capture(world, camera, viewport, ppt, p_r0, p_r1), "completed")
	var t_capture = OS.get_ticks_msec()

	if is_instance_valid(viewport):
		viewport.set("transparent_bg", prev_tbg)

	if r0 == null or r1 == null:
		if ui != null and is_instance_valid(ui):
			ui.visible = prev_ui_vis
		outputlog("bake: capture failed on level %s" % str(level.name), 0)
		return false

	# Paint a frame WITH the popup visible while the world UI is still hidden, so
	# the upcoming UI re-render shows this frame during its freeze rather than the
	# last (hidden) capture frame.
	var tree2 = global.Editor.get_tree()
	if _progress_panel != null and is_instance_valid(_progress_panel):
		_progress_panel.visible = true
	_progress_set(p_r1, "Building overlay…")
	yield(tree2, "idle_frame")
	if ui != null and is_instance_valid(ui):
		ui.visible = prev_ui_vis
	yield(tree2, "idle_frame")

	# Cooperative passes (GPU with CPU fallback) so the bar keeps moving.
	var p_build = prog_lo + 0.80 * span
	var p_grow = prog_lo + 0.85 * span
	var overlay_img = yield(_compute_overlay(r0, r1, p_r1, p_build), "completed")
	if overlay_grow > 0.0:
		overlay_img = yield(_compute_grow(overlay_img, overlay_grow, p_build, p_grow), "completed")
	var t_compute = OS.get_ticks_msec()
	var spr = _make_overlay_sprite(level, overlay_img, world, ppt)
	var img_b64 = _encode_png(overlay_img)
	var t_encode = OS.get_ticks_msec()

	# --- turn every collected shadow OFF (enabled=false + remove live node) ---
	_progress_set(p_grow, "Removing live shadows…")
	var off := []   # [ {id, kind} ]
	var ecount = entries.size()
	# Yield more often for huge maps so the bar visibly advances during removal.
	var yield_every = max(1, int(ceil(float(ecount) / 60.0)))
	var idx = 0
	for e in entries:
		var kdef = _kind_by_id(e["kind"])
		if kdef == null:
			idx += 1
			continue
		_set_enabled_dk(e["id"], false, kdef["data"])
		_set_host_cfg_enabled(e["host"], kdef.get("meta_cfg", ""), false)
		var mod = _module_for(kdef["ref"])
		if mod != null and mod.has_method(kdef["remove"]):
			mod.call(kdef["remove"], e["host"])
		off.append({"id": e["id"], "kind": e["kind"]})
		idx += 1
		if idx % yield_every == 0:
			_progress_set(p_grow + (prog_hi - p_grow) * float(idx) / float(ecount), "")
			yield(tree2, "idle_frame")
	var t_remove = OS.get_ticks_msec()

	_bake_records[lid] = {"level": level, "overlay": spr, "off": off, "ppt": ppt}
	_write_bake_record(level, off, ppt, img_b64)
	outputlog("bake: level %s done, %d off | timings ms: capture=%d compute=%d encode=%d remove=%d total=%d" % [str(level.name), off.size(), t_capture - t_start, t_compute - t_capture, t_encode - t_compute, t_remove - t_encode, t_remove - t_start], 0)
	return true


func unbake_current_level():
	if _busy:
		outputlog("unbake: busy, ignored", 0)
		return
	var world = global.get("World")
	var level = _current_level(world)
	if level == null:
		outputlog("unbake: no current level, abort", 0)
		return
	var lid = level.get_instance_id()
	if not _bake_records.has(lid):
		outputlog("unbake: this level is not baked", 0)
		return
	_unbake_record(world, lid)
	outputlog("unbake: done. shadows restored.", 0)
	_refresh_buttons()


func unbake_all_levels():
	if _busy:
		outputlog("unbake_all: busy, ignored", 0)
		return
	var world = global.get("World")
	var lids = _bake_records.keys()
	if lids.size() == 0:
		outputlog("unbake_all: nothing baked", 0)
		return
	# Duplicate keys: _unbake_record mutates _bake_records during iteration.
	for lid in lids.duplicate():
		_unbake_record(world, lid)
	outputlog("unbake_all: done", 0)
	_refresh_buttons()


# Reverses one bake record. Does NOT require the level to be current/visible.
func _unbake_record(world, lid) -> void:
	if not _bake_records.has(lid):
		return
	var rec = _bake_records[lid]
	var spr = rec.get("overlay")
	if spr != null and is_instance_valid(spr):
		if spr.get_parent() != null:
			spr.get_parent().remove_child(spr)
		spr.queue_free()
	for item in _record_off_list(rec):
		var kid = str(item.get("kind", "obj"))
		var kdef = _kind_by_id(kid)
		if kdef == null:
			continue
		var id = str(item["id"])
		_set_enabled_dk(id, true, kdef["data"])
		var node = _get_node_by_id(world, id)
		if node == null:
			continue
		_set_host_cfg_enabled(node, kdef.get("meta_cfg", ""), true)
		var cfg = _get_config_dk(id, kdef["data"])
		var mod = _module_for(kdef["ref"])
		if cfg != null and mod != null and mod.has_method(kdef["create"]):
			if mod.has_method(kdef["remove"]):
				mod.call(kdef["remove"], node)
			mod.call(kdef["create"], node, cfg)
	var lvl = rec.get("level")
	if lvl != null and is_instance_valid(lvl):
		_clear_bake_record(lvl)
	_bake_records.erase(lid)


# Save/reload persistence (called from Core on map load, BEFORE
# apply_saved_shadows_to_map). For each persisted level record, the baked overlay
# image is decoded and its sprite recreated, and the object shadows are kept OFF
# (enabled already false in the saved data). If an overlay can't be rebuilt, the
# shadows for that level are re-enabled as a fallback so the map is never blank.
func on_map_load():
	if global == null or not global.ModMapData.has(BAKE_RECORD_KEY):
		return
	var recs = global.ModMapData[BAKE_RECORD_KEY]
	if not (recs is Dictionary):
		return
	var world = global.get("World")
	var restored := 0
	var failed := 0
	for lvl_key in recs.keys():
		var entry = recs[lvl_key]
		if not (entry is Dictionary):
			continue
		var off = _record_off_list(entry)
		var ppt = int(entry.get("ppt", 256))
		var level = _find_level_by_record_key(world, lvl_key)
		var img = _decode_png(entry.get("img", ""))
		if level == null or img == null:
			# Can't rebuild the overlay -> re-enable the shadows so the map isn't
			# left blank (apply_saved_shadows_to_map will then recreate them) and
			# drop the unusable record.
			for item in off:
				var kdef = _kind_by_id(str(item.get("kind", "obj")))
				if kdef != null:
					_set_enabled_dk(str(item["id"]), true, kdef["data"])
			recs.erase(lvl_key)
			failed += 1
			continue
		# Shadows stay OFF (enabled is already false in the saved data, so the
		# upcoming apply_saved_shadows_to_map skips them) and we recreate the overlay.
		var spr = _make_overlay_sprite(level, img, world, ppt)
		_bake_records[level.get_instance_id()] = {
			"level": level,
			"overlay": spr,
			"off": off,
			"ppt": ppt,
		}
		restored += 1
	_refresh_buttons()
	outputlog("on_map_load: bake restored on %d level(s), %d fallback" % [restored, failed], 0)


#########################################################################################################
## OVERLAY BUILD  (variant B - darkening)
#########################################################################################################

func _build_overlay(r0: Image, r1: Image, prog_lo := 0.0, prog_hi := 0.0) -> Image:
	var w = int(r1.get_width())
	var h = int(r1.get_height())
	var d0 = r0.get_data()
	var d1 = r1.get_data()
	var out_data := PoolByteArray()
	out_data.resize(w * h * 4)

	var tree = global.Editor.get_tree()
	var band_h = max(1, int(ceil(float(h) / 24.0)))
	var y0 = 0
	while y0 < h:
		var y1 = min(h, y0 + band_h)
		for y in range(y0, y1):
			for x in range(w):
				var b = (y * w + x) * 4
				var a1 = d1[b + 3]
				if a1 <= ALPHA_EPS_BYTE:
					out_data[b] = 0; out_data[b + 1] = 0; out_data[b + 2] = 0; out_data[b + 3] = 0
					continue
				var a0 = d0[b + 3]
				if a0 <= ALPHA_EPS_BYTE:
					# Shadow on the void: keep the shadow itself (un-premultiply rgb).
					var af = float(a1) / 255.0
					out_data[b]     = int(min(255.0, float(d1[b]) / af))
					out_data[b + 1] = int(min(255.0, float(d1[b + 1]) / af))
					out_data[b + 2] = int(min(255.0, float(d1[b + 2]) / af))
					out_data[b + 3] = a1
					continue
				# Shadow on content -> darkening fraction via straight luminance.
				var a0f = float(a0) / 255.0
				var a1f = float(a1) / 255.0
				var l0 = (0.299 * d0[b] + 0.587 * d0[b + 1] + 0.114 * d0[b + 2]) / a0f
				var l1 = (0.299 * d1[b] + 0.587 * d1[b + 1] + 0.114 * d1[b + 2]) / a1f
				if l0 < 1.0:
					out_data[b] = 0; out_data[b + 1] = 0; out_data[b + 2] = 0; out_data[b + 3] = 0
					continue
				var t = 1.0 - (l1 / l0)
				if t <= 0.004:
					out_data[b] = 0; out_data[b + 1] = 0; out_data[b + 2] = 0; out_data[b + 3] = 0
					continue
				if t > 1.0:
					t = 1.0
				out_data[b] = 0; out_data[b + 1] = 0; out_data[b + 2] = 0
				out_data[b + 3] = int(t * 255.0)
		if prog_hi > prog_lo:
			_progress_set(prog_lo + (prog_hi - prog_lo) * float(y1) / float(h), "")
		yield(tree, "idle_frame")
		y0 = y1

	var out := Image.new()
	out.create_from_data(w, h, false, Image.FORMAT_RGBA8, out_data)
	return out


# Fractional 1px dilation. For each shadow pixel, write a partial-strength copy
# into its still-transparent 8-neighbours (taking the max). `amount` scales the
# ring strength (0.4 = 40%). Only iterates shadow pixels' neighbourhoods, so it
# stays cheap even on large transparent overlays.
func _grow_overlay(img: Image, amount: float, prog_lo := 0.0, prog_hi := 0.0) -> Image:
	var w = int(img.get_width())
	var h = int(img.get_height())
	var src = img.get_data()
	var dst = src   # copy-on-write: diverges from src on first write
	var neigh = [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]]
	var tree = global.Editor.get_tree()
	var band_h = max(1, int(ceil(float(h) / 16.0)))
	var y0 = 0
	while y0 < h:
		var y1 = min(h, y0 + band_h)
		for y in range(y0, y1):
			for x in range(w):
				var b = (y * w + x) * 4
				var sa = src[b + 3]
				if sa == 0:
					continue
				var val = int(sa * amount)
				if val <= 0:
					continue
				for o in neigh:
					var nx = x + o[0]
					var ny = y + o[1]
					if nx < 0 or nx >= w or ny < 0 or ny >= h:
						continue
					var nb = (ny * w + nx) * 4
					if src[nb + 3] != 0:
						continue   # neighbour already covered by real shadow
					if val > dst[nb + 3]:
						dst[nb] = src[b]
						dst[nb + 1] = src[b + 1]
						dst[nb + 2] = src[b + 2]
						dst[nb + 3] = val
		if prog_hi > prog_lo:
			_progress_set(prog_lo + (prog_hi - prog_lo) * float(y1) / float(h), "")
		yield(tree, "idle_frame")
		y0 = y1
	var out := Image.new()
	out.create_from_data(w, h, false, Image.FORMAT_RGBA8, dst)
	return out


#########################################################################################################
## GPU OVERLAY COMPUTE  (shader passes; CPU functions above are the fallback)
#########################################################################################################

const BUILD_SHADER_CODE := """shader_type canvas_item;
uniform sampler2D r0_tex;
uniform sampler2D r1_tex;
uniform float alpha_eps = 0.004;
void fragment() {
vec4 c1 = texture(r1_tex, UV);
float a1 = c1.a;
if (a1 <= alpha_eps) {
COLOR = vec4(0.0);
} else {
vec4 c0 = texture(r0_tex, UV);
float a0 = c0.a;
if (a0 <= alpha_eps) {
COLOR = vec4(0.0, 0.0, 0.0, a1);
} else {
float l0 = (0.299 * c0.r + 0.587 * c0.g + 0.114 * c0.b) / a0;
float l1 = (0.299 * c1.r + 0.587 * c1.g + 0.114 * c1.b) / a1;
if (l0 < (1.0 / 255.0)) {
COLOR = vec4(0.0);
} else {
float t = 1.0 - (l1 / l0);
if (t <= 0.004) {
COLOR = vec4(0.0);
} else {
COLOR = vec4(0.0, 0.0, 0.0, min(t, 1.0));
}
}
}
}
}
"""

const GROW_SHADER_CODE := """shader_type canvas_item;
uniform sampler2D src_tex;
uniform vec2 texel;
uniform float amount = 1.0;
uniform float alpha_eps = 0.004;
void fragment() {
vec4 c = texture(src_tex, UV);
if (c.a > alpha_eps) {
COLOR = c;
} else {
float best = 0.0;
for (int dy = -1; dy <= 1; dy++) {
for (int dx = -1; dx <= 1; dx++) {
if (dx == 0 && dy == 0) { continue; }
float na = texture(src_tex, UV + vec2(float(dx), float(dy)) * texel).a;
best = max(best, na * amount);
}
}
COLOR = vec4(0.0, 0.0, 0.0, best);
}
}
"""


func _get_build_shader() -> Shader:
	if _build_shader_res == null:
		_build_shader_res = Shader.new()
		_build_shader_res.code = BUILD_SHADER_CODE
	return _build_shader_res


func _get_grow_shader() -> Shader:
	if _grow_shader_res == null:
		_grow_shader_res = Shader.new()
		_grow_shader_res.code = GROW_SHADER_CODE
	return _grow_shader_res


# px/tile to actually use for this map: the requested native value, lowered if
# the resulting image would exceed max_output_dim on its largest side.
func _effective_ppt(world) -> int:
	var w_tiles = int(world.get("Width"))
	var h_tiles = int(world.get("Height"))
	var big = max(w_tiles, h_tiles)
	if big <= 0:
		return px_per_tile
	var ppt = px_per_tile
	if big * ppt > max_output_dim:
		ppt = int(max_output_dim / big)
		ppt = max(32, ppt)
	return ppt


# Runs one shader pass on a (w x h) off-screen viewport and returns the readback
# Image (upright, RGBA8), or null on any failure. sampler_imgs maps uniform name
# -> Image; scalars maps uniform name -> value.
func _gpu_render(shader: Shader, sampler_imgs: Dictionary, scalars: Dictionary, w: int, h: int):
	if global.Editor == null or w <= 0 or h <= 0:
		return null
	var vp := Viewport.new()
	vp.size = Vector2(w, h)
	vp.transparent_bg = true
	vp.hdr = false
	vp.usage = Viewport.USAGE_2D
	vp.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	var rect := ColorRect.new()
	rect.rect_min_size = Vector2(w, h)
	rect.rect_size = Vector2(w, h)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	for nm in sampler_imgs:
		var tex := ImageTexture.new()
		tex.create_from_image(sampler_imgs[nm], 0)   # 0 = nearest, clamp, no mipmaps
		mat.set_shader_param(nm, tex)
	for k in scalars:
		mat.set_shader_param(k, scalars[k])
	rect.material = mat
	vp.add_child(rect)
	global.Editor.add_child(vp)
	var tree = global.Editor.get_tree()
	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var img = null
	var tex_out = vp.get_texture()
	if tex_out != null:
		img = tex_out.get_data()
	vp.queue_free()
	if img == null or img.is_empty():
		return null
	img.flip_y()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


# GPU equivalent of _build_overlay. Tiles the work; returns null on any failure
# so the caller can fall back to the CPU path.
func _build_overlay_gpu(r0: Image, r1: Image, prog_lo := 0.0, prog_hi := 0.0):
	var w = int(r1.get_width())
	var h = int(r1.get_height())
	if r0.get_format() != Image.FORMAT_RGBA8:
		r0.convert(Image.FORMAT_RGBA8)
	if r1.get_format() != Image.FORMAT_RGBA8:
		r1.convert(Image.FORMAT_RGBA8)
	var out := Image.new()
	out.create(w, h, false, Image.FORMAT_RGBA8)
	var nx = int(ceil(float(w) / float(GPU_MAX_TILE)))
	var ny = int(ceil(float(h) / float(GPU_MAX_TILE)))
	var total = max(1, nx * ny)
	var done = 0
	var shader = _get_build_shader()
	var oy = 0
	while oy < h:
		var ch = min(GPU_MAX_TILE, h - oy)
		var ox = 0
		while ox < w:
			var cw = min(GPU_MAX_TILE, w - ox)
			var sub0 = r0.get_rect(Rect2(ox, oy, cw, ch))
			var sub1 = r1.get_rect(Rect2(ox, oy, cw, ch))
			var res = yield(_gpu_render(shader, {"r0_tex": sub0, "r1_tex": sub1}, {"alpha_eps": float(ALPHA_EPS_BYTE) / 255.0}, cw, ch), "completed")
			if res == null:
				return null
			out.blit_rect(res, Rect2(0, 0, cw, ch), Vector2(ox, oy))
			done += 1
			if prog_hi > prog_lo:
				_progress_set(prog_lo + (prog_hi - prog_lo) * float(done) / float(total), "")
			ox += GPU_MAX_TILE
		oy += GPU_MAX_TILE
	return out


# GPU equivalent of _grow_overlay (1px dilation). Tiles with a 1px apron so edge
# pixels see their neighbours from adjacent tiles. Returns null on failure.
func _grow_overlay_gpu(img: Image, amount: float, prog_lo := 0.0, prog_hi := 0.0):
	var w = int(img.get_width())
	var h = int(img.get_height())
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var out := Image.new()
	out.create(w, h, false, Image.FORMAT_RGBA8)
	var nx = int(ceil(float(w) / float(GPU_MAX_TILE)))
	var ny = int(ceil(float(h) / float(GPU_MAX_TILE)))
	var total = max(1, nx * ny)
	var done = 0
	var shader = _get_grow_shader()
	var oy = 0
	while oy < h:
		var ch = min(GPU_MAX_TILE, h - oy)
		var ox = 0
		while ox < w:
			var cw = min(GPU_MAX_TILE, w - ox)
			var pw = cw + 2
			var ph = ch + 2
			var padded := Image.new()
			padded.create(pw, ph, false, Image.FORMAT_RGBA8)   # zero-filled apron
			var sx = max(0, ox - 1)
			var sy = max(0, oy - 1)
			var ex = min(w, ox + cw + 1)
			var ey = min(h, oy + ch + 1)
			var piece = img.get_rect(Rect2(sx, sy, ex - sx, ey - sy))
			padded.blit_rect(piece, Rect2(0, 0, ex - sx, ey - sy), Vector2(sx - (ox - 1), sy - (oy - 1)))
			var res = yield(_gpu_render(shader, {"src_tex": padded}, {"texel": Vector2(1.0 / float(pw), 1.0 / float(ph)), "amount": amount, "alpha_eps": float(ALPHA_EPS_BYTE) / 255.0}, pw, ph), "completed")
			if res == null:
				return null
			var center = res.get_rect(Rect2(1, 1, cw, ch))
			out.blit_rect(center, Rect2(0, 0, cw, ch), Vector2(ox, oy))
			done += 1
			if prog_hi > prog_lo:
				_progress_set(prog_lo + (prog_hi - prog_lo) * float(done) / float(total), "")
			ox += GPU_MAX_TILE
		oy += GPU_MAX_TILE
	return out


# Try GPU; fall back to the CPU pixel loop on failure. Both yield.
func _compute_overlay(r0: Image, r1: Image, prog_lo: float, prog_hi: float):
	if _use_gpu:
		var g = yield(_build_overlay_gpu(r0, r1, prog_lo, prog_hi), "completed")
		if g != null:
			return g
		_use_gpu = false
		outputlog("GPU overlay build unavailable -> CPU fallback (GPU disabled this session)", 0)
	return yield(_build_overlay(r0, r1, prog_lo, prog_hi), "completed")


func _compute_grow(img: Image, amount: float, prog_lo: float, prog_hi: float):
	if _use_gpu:
		var g = yield(_grow_overlay_gpu(img, amount, prog_lo, prog_hi), "completed")
		if g != null:
			return g
		_use_gpu = false
		outputlog("GPU grow unavailable -> CPU fallback (GPU disabled this session)", 0)
	return yield(_grow_overlay(img, amount, prog_lo, prog_hi), "completed")


func _make_overlay_sprite(level, overlay_img: Image, world, ppt: int) -> Sprite:
	# Remove any stale overlay first.
	for child in level.get_children():
		if String(child.name) == OVERLAY_NAME:
			level.remove_child(child)
			child.queue_free()

	var tex := ImageTexture.new()
	# Bilinear filter (no mipmaps — Godot 3.4 viewport-image mipmaps can segfault).
	# Filtering softens the ~half-pixel viewport-capture offset; supersampling
	# (px_per_tile > TileSize) is the real lever for crisper, better-aligned edges.
	tex.create_from_image(overlay_img, Texture.FLAG_FILTER)

	var tile_size = float(world.get("TileSize"))
	var s = tile_size / float(ppt)

	var spr := Sprite.new()
	spr.name = OVERLAY_NAME
	spr.texture = tex
	spr.centered = false
	spr.position = Vector2.ZERO
	spr.scale = Vector2(s, s)
	spr.z_as_relative = false
	spr.z_index = OVERLAY_Z
	spr.show_behind_parent = false
	spr.visible = not _shadows_hidden()
	level.add_child(spr)
	return spr


#########################################################################################################
## CAPTURE ENGINE
#########################################################################################################

func _capture(world, camera, viewport, ppt: int, prog_lo := 0.0, prog_hi := 0.0) -> Image:
	yield(global.Editor.get_tree(), "idle_frame")  # guarantee a FunctionState

	var tile_size = int(world.get("TileSize"))
	var w_tiles = int(world.get("Width"))
	var h_tiles = int(world.get("Height"))
	var out_w = w_tiles * ppt
	var out_h = h_tiles * ppt
	var zoom = float(tile_size) / float(ppt)

	var output := Image.new()
	output.create(out_w, out_h, false, Image.FORMAT_RGBA8)

	var cam_anchor = camera.get("anchor_mode")
	var cam_zoom = camera.get("zoom")
	var cam_pos = camera.get("position")
	_cam_set_anchor_topleft(camera)
	_cam_set_zoom(camera, zoom)

	var chunk = viewport.get("size")
	var cw = int(chunk.x)
	var ch = int(chunk.y)
	var tree = global.Editor.get_tree()

	var total_chunks = max(1, int(ceil(float(out_w) / float(cw))) * int(ceil(float(out_h) / float(ch))))
	var done = 0
	var y = 0
	while y < out_h:
		var x = 0
		while x < out_w:
			_cam_pan(camera, Vector2(x, y) * float(tile_size) / float(ppt))
			yield(tree, "idle_frame")
			yield(tree, "idle_frame")
			var vtex = viewport.get_texture()
			if vtex != null:
				var img = vtex.get_data()
				if img != null and not img.is_empty():
					img.flip_y()
					output.blit_rect(img, Rect2(Vector2.ZERO, img.get_size()), Vector2(x, y))
			done += 1
			if prog_hi > prog_lo:
				_progress_set(prog_lo + (prog_hi - prog_lo) * float(done) / float(total_chunks), "")
			x += cw
		y += ch

	_cam_restore(camera, cam_anchor, cam_zoom, cam_pos)
	return output


#########################################################################################################
## SHADOW-CONFIG / NODE HELPERS
#########################################################################################################

func _node_id(prop) -> String:
	if prop.has_meta("node_id"):
		return str(prop.get_meta("node_id"))
	return ""


func _get_node_by_id(world, id: String):
	var int_id = int(id)
	if world.has_method("HasNodeID") and world.has_method("GetNodeByID"):
		if world.call("HasNodeID", int_id):
			return world.call("GetNodeByID", int_id)
	return null


func _write_bake_record(level, off: Array, ppt: int, img_b64: String) -> void:
	if not global.ModMapData.has(BAKE_RECORD_KEY):
		global.ModMapData[BAKE_RECORD_KEY] = {}
	var lvl_id = _level_record_key(level)
	global.ModMapData[BAKE_RECORD_KEY][lvl_id] = {
		"off": off,
		"ppt": ppt,
		"img": img_b64,
	}


func _clear_bake_record(level) -> void:
	if not global.ModMapData.has(BAKE_RECORD_KEY):
		return
	var lvl_id = _level_record_key(level)
	if global.ModMapData[BAKE_RECORD_KEY].has(lvl_id):
		global.ModMapData[BAKE_RECORD_KEY].erase(lvl_id)
	if global.ModMapData[BAKE_RECORD_KEY].empty():
		global.ModMapData.erase(BAKE_RECORD_KEY)


func _level_record_key(level) -> String:
	# Prefer a stable level ID if exposed; fall back to label/name.
	if level.get("ID") != null:
		return str(level.get("ID"))
	return String(level.name)


# Image -> base64 PNG string (compresses transparent areas very well).
func _encode_png(img: Image) -> String:
	var buf = img.save_png_to_buffer()
	if buf == null or buf.size() == 0:
		return ""
	return Marshalls.raw_to_base64(buf)


# base64 PNG string -> Image (returns null on any failure).
func _decode_png(b64: String):
	if b64 == null or b64 == "":
		return null
	var buf = Marshalls.base64_to_raw(b64)
	if buf == null or buf.size() == 0:
		return null
	var img = Image.new()
	if img.load_png_from_buffer(buf) != OK:
		return null
	return img


# Find the live Level node matching a persisted record key.
func _find_level_by_record_key(world, key: String):
	if world == null:
		return null
	var levels = world.call("get_AllLevels")
	if levels == null:
		return null
	for lvl in levels:
		if lvl != null and _level_record_key(lvl) == key:
			return lvl
	return null


func _current_level(world):
	if world.has_method("get_Level"):
		var lv = world.call("get_Level")
		if lv != null:
			return lv
	for child in world.get_children():
		if String(child.name).find("Level") != -1 and child.get("visible") == true:
			return child
	return null


#########################################################################################################
## CAMERA HELPERS
#########################################################################################################

func _cam_set_anchor_topleft(camera) -> void:
	if camera.has_method("SetAnchorMode"):
		camera.call("SetAnchorMode", 0)
	else:
		camera.set("anchor_mode", Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT)


func _cam_set_zoom(camera, z: float) -> void:
	if camera.has_method("SetRawZoom"):
		camera.call("SetRawZoom", z)
	else:
		camera.set("zoom", Vector2(z, z))


func _cam_pan(camera, pos: Vector2) -> void:
	if camera.has_method("Pan"):
		camera.call("Pan", pos)
	else:
		camera.set("position", pos)


func _cam_restore(camera, anchor, zoom, pos) -> void:
	if camera.has_method("SetAnchorMode"):
		camera.call("SetAnchorMode", anchor)
	else:
		camera.set("anchor_mode", anchor)
	if camera.has_method("SetRawZoom"):
		camera.call("SetRawZoom", zoom.x)
	else:
		camera.set("zoom", zoom)
	if camera.has_method("Pan"):
		camera.call("Pan", pos)
	else:
		camera.set("position", pos)
