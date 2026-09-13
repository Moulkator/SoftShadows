#########################################################################################################
##
## OVERLAY (INNER) SHADOW FOR PATTERNS (PatternShape polygons)
##
#########################################################################################################
# Version 1.0.0
# A shadow band that starts from the edges facing the sun and fades toward the
# inside of the pattern (the pattern is read as a lowered floor). Rendered by a
# Polygon2D CHILD of the shape holding the same polygon (so it's clipped for
# free) with shaders/OverlayShadowPattern.shader. It sits in the shape's own z
# bucket (z_as_relative, z_index 0) and is placed BEFORE the pattern's Outline
# in child order, so it draws above the pattern fill but below the outline.
#
# Settings mirror OverlayShadowObjects: Sun °, Coverage (band width),
# Diffusion, Curve, Opacity, Color, Link (follow the pattern's soft shadow sun)
# and Lock (sun angle local to the shape, follows its rotation).

var global
var core = null
var logging_level = 0
var shadow_history = null    # set by Core
var dropshadow_patterns = null  # set by Core (for "link sun")

const DATA_KEY = "OverlayShadowPatterns"
const TOOL_DEFAULTS_KEY = "OverlayShadowPatternsToolDefaults"
const NODE_NAME = "OverlayShadowPatternPoly"
const META_KEY = "overlay_shadow_pattern_node"
const COVERAGE_MAX_PX = 256.0   # coverage 1.0 = band of 256 world px
const MAX_POINTS = 512

const DEFAULTS = {
	"enabled": false,
	"opacity": 0.5,
	"sun_angle": 90.0,     # degrees, world space (0 = right, 90 = down); local when lock_sun
	"sun_strength": 0.0,   # "Distance" on the dial: 0 = sun from above (every edge gets the band), 1 = fully directional
	"coverage": 0.25,
	"diffusion": 0.5,
	"curve": 0.0,
	"shadow_color": Color(0, 0, 0, 1),
	"link_sun": true,
	"lock_sun": false,
	# "raised": the pattern is a bump / dome — the edges away from the sun are in shadow.
	# "lowered": the pattern is a hollow — its rim shades the edges facing the sun.
	"relief": "raised"
}
const RELIEFS = ["raised", "lowered"]
const SLIDER_KEYS = ["coverage", "diffusion", "curve", "opacity"]
const DIAL_SIZE = 90
const SNAP_KEYS = ["snap_45", "snap_135", "snap_225", "snap_315"]
const SOFT_OFFSET_MAX = 100.0   # DropShadowPatterns.OFFSET_MAX (dial radius)

var _shader: Shader = null
var ui = {}
var pt_ui = {}
var _syncing = false
var _monitored = null
var _active = {}     # node_id -> {"node": shape, "sig": String}
var _clipboard = {}
var _monitor_timer = null
var _pending_new_nodes = []
var _heal_counter = 0
# Clone / copy-paste follow: signatures of the patterns selected at the last
# Ctrl+C ({sig: cfg}); a new node matching one inherits its config.
var _copy_sources = {}
var _ctrl_c_was = false

var _history_flush_timer = null
var _history_txn_active = false
var _history_txn_before = {}
var _history_txn_label = ""
var _history_suspend = false

const ENABLE_LOGGING = true
func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <OverlayShadowPatterns>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise() -> void:
	_shader = ResourceLoader.load(global.Root + "shaders/OverlayShadowPattern.shader", "Shader", true)
	if _shader == null:
		outputlog("ERROR: Could not load OverlayShadowPattern.shader", 0)
		return
	build_select_tool_ui()
	build_pattern_tool_ui()
	_register_pattern_tool_signals()
	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "on_new_node_added_to_world")

	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.05
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)

	_history_flush_timer = Timer.new()
	_history_flush_timer.wait_time = 0.4
	_history_flush_timer.one_shot = true
	_history_flush_timer.connect("timeout", self, "_history_flush")
	global.Editor.add_child(_history_flush_timer)
	if shadow_history != null and shadow_history.has_method("register_flusher"):
		shadow_history.register_flusher(self, "_history_flush")
	outputlog("Overlay Shadow Patterns initialised. [BUILD: OVERLAY-PATTERNS-1]", 0)

#########################################################################################################
## NODE HELPERS
#########################################################################################################

func is_pattern(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not (node is Polygon2D) or not node.has_meta("node_id"):
		return false
	var layer = node.get_parent()
	if layer == null:
		return false
	var shapes = layer.get_parent()
	if shapes == null:
		return false
	var level = shapes.get_parent()
	if level == null:
		return false
	return level.get("PatternShapes") == shapes

func _node_id(node) -> String:
	return str(node.get_meta("node_id"))

# The meta may be stale after a DD level clone (duplicate() copies the meta
# reference to the SOURCE shape's overlay) — only trust it if it's our child.
func _get_overlay_node(shape):
	if shape.has_meta(META_KEY):
		var n = shape.get_meta(META_KEY)
		if n != null and is_instance_valid(n) and n.get_parent() == shape:
			return n
	return shape.get_node_or_null(NODE_NAME)

# The pattern's textured border (Line2D added by SetOutline). NOT the
# PatternShapeWidget: that one is also a Line2D, always child 0 (DD's
# GetWidget() is GetChild(0) — it must stay there) and uses an absolute z.
func _find_outline(shape):
	for c in shape.get_children():
		if c.get_index() == 0:
			continue
		if c is Line2D and c.name != NODE_NAME and c.z_as_relative:
			return c
	return null

func _shape_signature(shape, cfg) -> String:
	var pts = shape.polygon
	var h = pts.size()
	for p in pts:
		h = (h * 31 + int(p.x * 100)) % 2147483647
		h = (h * 31 + int(p.y * 100)) % 2147483647
	var linked = ""
	if cfg != null and cfg.get("link_sun", false):
		var ls = _linked_sun(_node_id(shape))
		linked = "" if ls == null else "%d|%.2f" % [round(ls[0]), ls[1]]
	var has_outline = _find_outline(shape) != null
	return "%d|%.4f|%.4f|%.4f|%s|%s" % [h, shape.rotation, shape.scale.x, shape.scale.y, linked, str(has_outline)]

# [sun angle deg (0 = right / 90 = down), strength 0..1] mirrored from the
# pattern's soft shadow dial (same handle position on both dials), or null
# when the pattern has no enabled soft shadow.
func _linked_sun(nid: String):
	if not global.ModMapData.has("DropShadowPatterns"):
		return null
	var d = global.ModMapData["DropShadowPatterns"]
	if not d.has(nid) or not (d[nid] is Dictionary):
		return null
	var sc = d[nid]
	if not sc.get("enabled", false):
		return null
	# Paths-dial convention: offset = (-sin a, cos a); sun = -offset.
	var a = deg2rad(float(sc.get("sun_angle", 0.0)))
	var angle = fposmod(rad2deg(atan2(-cos(a), sin(a))), 360.0)
	var strength = clamp(float(sc.get("offset_dist", 0.0)) / SOFT_OFFSET_MAX, 0.0, 1.0)
	return [angle, strength]

#########################################################################################################
## CREATE / REMOVE
#########################################################################################################

func create_shadow(shape, cfg: Dictionary) -> void:
	if not is_pattern(shape) or _shader == null:
		return
	remove_shadow(shape)
	var pts: PoolVector2Array = shape.polygon
	var n = pts.size()
	if n < 3 or n > MAX_POINTS:
		return

	var img = Image.new()
	img.create(n, 1, false, Image.FORMAT_RGBAF)
	img.lock()
	for i in range(n):
		img.set_pixel(i, 0, Color(pts[i].x, pts[i].y, 0.0, 1.0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)

	var area = 0.0
	for i in range(n):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		area += a.x * b.y - b.x * a.y

	var mat = ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_param("poly_data_tex", tex)
	mat.set_shader_param("poly_count", n)
	mat.set_shader_param("winding", 1.0 if area > 0.0 else -1.0)

	var ov = Polygon2D.new()
	ov.name = NODE_NAME
	ov.polygon = pts
	ov.color = Color(1, 1, 1, 1)
	ov.material = mat
	ov.z_as_relative = true
	ov.z_index = 0
	ov.show_behind_parent = false
	ov.set_meta("is_drop_shadow", true)
	shape.add_child(ov)
	# Above the pattern fill (child), below its outline.
	var outline = _find_outline(shape)
	if outline != null:
		shape.move_child(ov, max(outline.get_index(), 1))
	_apply_params(ov, shape, cfg)
	if global.ModMapData.get("DropShadowToggleHidden", false):
		ov.visible = false
	shape.set_meta(META_KEY, ov)
	_active[_node_id(shape)] = {"node": shape, "sig": _shape_signature(shape, cfg)}

func _apply_params(ov, shape, cfg: Dictionary) -> void:
	var mat = ov.material
	if mat == null:
		return
	var col = cfg.get("shadow_color", DEFAULTS["shadow_color"])
	if col is String:
		col = Color(col)
	var s = max(abs(shape.scale.x), abs(shape.scale.y))
	if s < 0.001:
		s = 1.0
	mat.set_shader_param("shadow_color", Color(col.r, col.g, col.b, 1.0))
	mat.set_shader_param("opacity", float(cfg.get("opacity", DEFAULTS["opacity"])))
	mat.set_shader_param("band_width", float(cfg.get("coverage", DEFAULTS["coverage"])) * COVERAGE_MAX_PX / s)
	mat.set_shader_param("diffusion", float(cfg.get("diffusion", DEFAULTS["diffusion"])))
	mat.set_shader_param("curve", float(cfg.get("curve", DEFAULTS["curve"])))

	var sun_deg = float(cfg.get("sun_angle", DEFAULTS["sun_angle"]))
	var strength = clamp(float(cfg.get("sun_strength", 0.0)), 0.0, 1.0)
	if cfg.get("link_sun", false):
		var ls = _linked_sun(_node_id(shape))
		if ls != null:
			sun_deg = ls[0]
			strength = ls[1]
	var sun_vec = Vector2(cos(deg2rad(sun_deg)), sin(deg2rad(sun_deg)))
	var local_sun = sun_vec
	if not cfg.get("lock_sun", false):
		local_sun = shape.transform.affine_inverse().basis_xform(sun_vec)
	mat.set_shader_param("local_sun", local_sun)
	mat.set_shader_param("sun_strength", strength)
	mat.set_shader_param("raised", 1.0 if cfg.get("relief", "raised") == "raised" else 0.0)

# Called by DropShadowPatterns right after its dial / settings change: linked
# overlays (shadow AND dial) follow in the same frame.
func on_soft_shadow_changed(nodes) -> void:
	for node in nodes:
		if not is_pattern(node):
			continue
		var nid = _node_id(node)
		var cfg = _saved_or_default_cfg(nid)
		var linked = cfg.get("link_sun", false)
		if node == _monitored and ui.has("link_sun"):
			linked = ui["link_sun"].pressed
		if not linked:
			continue
		if cfg.get("enabled", false) and _active.has(nid):
			refresh_shadow(node)
		if node == _monitored and ui.has("dial"):
			var ls = _linked_sun(nid)
			if ls != null:
				_set_dial(ui, ls[0], ls[1])

# Pattern Tool: the soft shadow section's dial changed — mirror it on the
# overlay section's dial when its Link is on (same conversion as _linked_sun).
func on_soft_tool_changed(soft_cfg: Dictionary) -> void:
	if not pt_ui.has("dial") or not pt_ui["link_sun"].pressed:
		return
	var a = deg2rad(float(soft_cfg.get("sun_angle", 0.0)))
	var angle = fposmod(rad2deg(atan2(-cos(a), sin(a))), 360.0)
	var strength = clamp(float(soft_cfg.get("offset_dist", 0.0)) / SOFT_OFFSET_MAX, 0.0, 1.0)
	_set_dial(pt_ui, round(angle), strength)
	_save_pattern_tool_defaults()

func remove_shadow(shape) -> void:
	if shape == null or not is_instance_valid(shape):
		return
	var n = _get_overlay_node(shape)
	if n != null and is_instance_valid(n):
		n.get_parent().remove_child(n)
		n.queue_free()
	if shape.has_meta(META_KEY):
		shape.remove_meta(META_KEY)
	if shape.has_meta("node_id"):
		_active.erase(_node_id(shape))

func refresh_shadow(shape) -> void:
	if not is_pattern(shape):
		return
	var cfg = _saved_cfg(_node_id(shape))
	if cfg != null and cfg.get("enabled", false):
		create_shadow(shape, cfg)
	else:
		remove_shadow(shape)
	# Linked + selected: keep the dial mirroring the soft shadow's dial.
	if shape == _monitored and cfg != null and cfg.get("link_sun", false) and ui.has("dial"):
		var ls = _linked_sun(_node_id(shape))
		if ls != null:
			_set_dial(ui, ls[0], ls[1])

#########################################################################################################
## PATTERN TOOL SIGNALS / NEW NODES / MONITOR
#########################################################################################################

func _register_pattern_tool_signals() -> void:
	var ptool = global.Editor.Tools.get("PatternShapeTool")
	if ptool == null:
		return
	for sig in ["OnUpdateEditShape", "OnEndEditShape"]:
		if ptool.has_signal(sig):
			ptool.connect(sig, self, "_on_shape_edited")

func _on_shape_edited(shape) -> void:
	if is_pattern(shape) and _active.has(_node_id(shape)):
		refresh_shadow(shape)

func on_new_node_added_to_world(node) -> void:
	if node != null and is_instance_valid(node):
		_pending_new_nodes.append(node)

func _process_new_node(node) -> void:
	if not is_pattern(node):
		return
	var nid = _node_id(node)
	var cfg = _saved_cfg(nid)
	if cfg != null:
		# Node re-created by DD (undo of a delete, map load): restore.
		if cfg.get("enabled", false):
			create_shadow(node, cfg)
		return
	# Copy/paste or Duplicate: inherit from a matching source (same polygon
	# and texture) — first the patterns copied at the last Ctrl+C, then any
	# pattern that currently carries a shadow.
	var src_cfg = _find_clone_source_cfg(node, nid)
	if src_cfg != null:
		create_shadow(node, src_cfg)
		save_data(node, src_cfg)
		return
	if pt_ui.has("enable") and pt_ui["enable"].pressed \
			and global.Editor.ActiveToolName == "PatternShapeTool":
		var tcfg = get_pattern_tool_config()
		tcfg["enabled"] = true
		create_shadow(node, tcfg)
		save_data(node, tcfg)

# Coarse clone key (point count + texture + color). Points are compared
# separately with a tolerance: DD's copy/paste round-trips the polygon through
# Save()/LoadShape, so non-integer coordinates (circles) come back slightly off.
func _clone_key(shape) -> String:
	var tex = ""
	if shape.material is ShaderMaterial:
		var alb = shape.material.get_shader_param("albedo")
		if alb != null and alb is Texture:
			tex = str(alb.resource_path) if alb.resource_path != "" else str(alb.get_instance_id())
	return "%d|%s|%s" % [shape.polygon.size(), tex, shape.color.to_html(true)]

func _same_polygon(a: PoolVector2Array, b: PoolVector2Array, tol: float = 0.05) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if abs(a[i].x - b[i].x) > tol or abs(a[i].y - b[i].y) > tol:
			return false
	return true

func _find_clone_source_cfg(node, nid: String):
	var key = _clone_key(node)
	if _copy_sources.has(key):
		for src in _copy_sources[key]:
			if _same_polygon(src["points"], node.polygon):
				return src["cfg"].duplicate(true)
	for other_id in _active.keys():
		if other_id == nid:
			continue
		var other = _active[other_id]["node"]
		if other == null or not is_instance_valid(other):
			continue
		if _clone_key(other) == key and _same_polygon(other.polygon, node.polygon):
			var cfg = _saved_cfg(other_id)
			if cfg != null and cfg.get("enabled", false):
				return cfg
	return null

func _track_copy_shortcut() -> void:
	var ctrl = Input.is_key_pressed(KEY_CONTROL) or Input.is_key_pressed(KEY_META)
	var c_now = ctrl and Input.is_key_pressed(KEY_C)
	if c_now and not _ctrl_c_was:
		_copy_sources = {}
		for n in global.Editor.Tools["SelectTool"].Selected:
			if not is_pattern(n):
				continue
			var cfg = _saved_cfg(_node_id(n))
			if cfg != null and cfg.get("enabled", false):
				var key = _clone_key(n)
				if not _copy_sources.has(key):
					_copy_sources[key] = []
				_copy_sources[key].append({"points": PoolVector2Array(n.polygon), "cfg": cfg})
	_ctrl_c_was = c_now

func _on_monitor_tick() -> void:
	_track_copy_shortcut()
	if _pending_new_nodes.size() > 0:
		var batch = _pending_new_nodes
		_pending_new_nodes = []
		for node in batch:
			_process_new_node(node)
	var dead = []
	for nid in _active.keys():
		var e = _active[nid]
		var shape = e["node"]
		if shape == null or not is_instance_valid(shape) or not shape.is_inside_tree():
			dead.append(nid)
			continue
		var sig = _shape_signature(shape, _saved_cfg(nid))
		if sig != e["sig"]:
			refresh_shadow(shape)
	for nid in dead:
		_active.erase(nid)
	_heal_counter += 1
	if _heal_counter >= 10:
		_heal_counter = 0
		_heal_missing_shadows()

func _heal_missing_shadows() -> void:
	if not global.ModMapData.has(DATA_KEY):
		return
	for nid in global.ModMapData[DATA_KEY].keys():
		if _active.has(nid):
			continue
		var iid = int(nid)
		if iid < 0 or not global.World.HasNodeID(iid):
			continue
		var node = global.World.GetNodeByID(iid)
		if not is_pattern(node) or _get_overlay_node(node) != null:
			continue
		var cfg = _saved_cfg(nid)
		if cfg != null and cfg.get("enabled", false):
			create_shadow(node, cfg)

#########################################################################################################
## DATA
#########################################################################################################

func _saved_cfg(nid: String):
	if global.ModMapData.has(DATA_KEY) and global.ModMapData[DATA_KEY].has(nid):
		var cfg = DEFAULTS.duplicate(true)
		for k in global.ModMapData[DATA_KEY][nid].keys():
			cfg[k] = global.ModMapData[DATA_KEY][nid][k]
		if cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		return cfg
	return null

func _saved_or_default_cfg(nid: String) -> Dictionary:
	var cfg = _saved_cfg(nid)
	if cfg == null:
		cfg = DEFAULTS.duplicate(true)
	return cfg

func save_data(shape, cfg: Dictionary) -> void:
	if not shape.has_meta("node_id"):
		return
	if not global.ModMapData.has(DATA_KEY):
		global.ModMapData[DATA_KEY] = {}
	var sc = cfg.duplicate(true)
	if sc["shadow_color"] is Color:
		sc["shadow_color"] = sc["shadow_color"].to_html(true)
	global.ModMapData[DATA_KEY][_node_id(shape)] = sc

func apply_saved_shadows_to_map() -> void:
	if not global.ModMapData.has(DATA_KEY):
		return
	for nid in global.ModMapData[DATA_KEY].keys():
		var iid = int(nid)
		if iid < 0 or not global.World.HasNodeID(iid):
			continue
		var node = global.World.GetNodeByID(iid)
		if is_pattern(node):
			var cfg = _saved_cfg(nid)
			if cfg.get("enabled", false):
				create_shadow(node, cfg)

#########################################################################################################
## UI — SHARED BUILDERS
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
	btn.focus_mode = Control.FOCUS_NONE
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
	if picker != null:
		_hide_screen_picker(picker)

func _hide_screen_picker(node) -> void:
	for child in node.get_children():
		if child is ToolButton:
			child.visible = false
			return
		if child.get_child_count() > 0:
			_hide_screen_picker(child)

func _build_title(container, store: Dictionary, prefix: String, tooltip: String) -> void:
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
	enable.hint_tooltip = tooltip
	enable.focus_mode = Control.FOCUS_NONE
	enable.connect("toggled", self, "_on_enable_toggled", [prefix])
	trow.add_child(enable)
	store["enable"] = enable
	container.add_child(trow)

func _build_settings(parent, store: Dictionary, prefix: String) -> void:
	# Relief buttons (Raised = bump, Lowered = hollow), radio style.
	var rrow = HBoxContainer.new()
	var relief_names = ["Raised", "Lowered"]
	var relief_tips = ["The pattern is a bump / dome: the edges away from the sun are in shadow",
		"The pattern is a hollow: its rim shades the edges facing the sun"]
	for i in range(2):
		var rbtn = Button.new()
		rbtn.text = " " + relief_names[i]
		rbtn.hint_tooltip = relief_tips[i]
		rbtn.toggle_mode = true
		rbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rbtn.align = Button.ALIGN_LEFT
		rbtn.focus_mode = Control.FOCUS_NONE
		rbtn.connect("pressed", self, "_on_relief_pressed", [i, prefix])
		rrow.add_child(rbtn)
		store["relief_btn_" + str(i)] = rbtn
	parent.add_child(rrow)
	_set_relief_buttons(store, 0)

	# Sun dial header: Distance [spin %]  Angle [spin °]  [reset] [link] [lock]
	# Dial: handle = sun direction; distance from the center = directionality
	# (center = sun from above: every edge gets the band; rim = fully
	# directional). Same non-linear radius as the soft shadow dial, so when
	# linked both dials show the same handle position.
	var sun_row = HBoxContainer.new()
	var sl = Label.new()
	sl.text = "Distance"
	sun_row.add_child(sl)
	var strength_spin = SpinBox.new()
	strength_spin.min_value = 0
	strength_spin.max_value = 100
	strength_spin.step = 1
	strength_spin.suffix = "%"
	strength_spin.value = DEFAULTS["sun_strength"] * 100.0
	strength_spin.rect_min_size.x = 80
	strength_spin.connect("value_changed", self, "_on_sun_spin_changed", [prefix])
	sun_row.add_child(strength_spin)
	store["strength_spin"] = strength_spin
	var angle_l = Label.new()
	angle_l.text = "Angle"
	sun_row.add_child(angle_l)
	var angle_spin = SpinBox.new()
	angle_spin.min_value = 0
	angle_spin.max_value = 359
	angle_spin.step = 1
	angle_spin.suffix = "°"
	angle_spin.value = DEFAULTS["sun_angle"]
	angle_spin.rect_min_size.x = 72
	angle_spin.connect("value_changed", self, "_on_sun_spin_changed", [prefix])
	sun_row.add_child(angle_spin)
	store["angle_spin"] = angle_spin
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sun_row.add_child(spacer)
	var sun_rb = _make_icon_button("icons/reset.png", "Reset sun", 0.5)
	sun_rb.connect("pressed", self, "_on_single_reset", ["sun", prefix])
	sun_row.add_child(sun_rb)
	parent.add_child(sun_row)

	# Link / Lock sit beside the dial.
	var side = VBoxContainer.new()
	side.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var link_btn = _make_icon_button("icons/link.png", "Link to the soft shadow's sun angle", 0.5)
	link_btn.toggle_mode = true
	link_btn.pressed = DEFAULTS["link_sun"]
	link_btn.connect("toggled", self, "_on_link_toggled", [prefix])
	side.add_child(link_btn)
	store["link_sun"] = link_btn
	var lock_btn = _make_icon_button("icons/lock.png", "Lock the sun angle to the pattern (follows its rotation)", 0.5)
	lock_btn.toggle_mode = true
	lock_btn.pressed = DEFAULTS["lock_sun"]
	lock_btn.connect("toggled", self, "_on_lock_toggled", [prefix])
	side.add_child(lock_btn)
	store["lock_sun"] = lock_btn

	var cc = CenterContainer.new()
	cc.rect_clip_content = false
	var dial_row = HBoxContainer.new()
	dial_row.add_constant_override("separation", 12)
	var mc = MarginContainer.new()
	mc.rect_clip_content = false
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_constant_override(m, 8)
	mc.add_child(_create_dial(store, prefix))
	dial_row.add_child(mc)
	dial_row.add_child(side)
	cc.add_child(dial_row)
	parent.add_child(cc)
	_update_link_enabled(store)

	_add_slider(parent, store, prefix, "Coverage", "coverage", 0.0, 1.0, 0.01)
	_add_slider(parent, store, prefix, "Blur", "diffusion", 0.0, 1.0, 0.01)
	_add_slider(parent, store, prefix, "Curve", "curve", -2.0, 2.0, 0.01)
	_add_slider(parent, store, prefix, "Opacity", "opacity", 0.05, 1.0, 0.01)

	var crow = HBoxContainer.new()
	var cl = Label.new()
	cl.text = "Color"
	cl.rect_min_size.x = 70
	crow.add_child(cl)
	var cp = ColorPickerButton.new()
	cp.color = DEFAULTS["shadow_color"]
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.connect("color_changed", self, "_on_color", [prefix])
	cp.connect("pressed", self, "_disable_color_pipette", [cp])
	crow.add_child(cp)
	store["color"] = cp
	var cr = _make_icon_button("icons/reset.png", "Reset color", 0.5)
	cr.connect("pressed", self, "_on_single_reset", ["shadow_color", prefix])
	crow.add_child(cr)
	parent.add_child(crow)

	var actions = HBoxContainer.new()
	var al = Label.new()
	al.text = "Shadow"
	al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(al)
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.icon = _load_icon("icons/reset.png", 0.5)
	reset_btn.hint_tooltip = "Reset overlay to defaults"
	reset_btn.connect("pressed", self, "_on_reset", [prefix])
	actions.add_child(reset_btn)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.icon = _load_icon("icons/copy.png", 0.5)
	copy_btn.hint_tooltip = "Copy overlay settings"
	copy_btn.connect("pressed", self, "_on_copy", [prefix])
	actions.add_child(copy_btn)
	var paste_btn = Button.new()
	paste_btn.text = "Paste"
	paste_btn.icon = _load_icon("icons/paste.png", 0.5)
	paste_btn.hint_tooltip = "Paste overlay settings"
	paste_btn.connect("pressed", self, "_on_paste", [prefix])
	actions.add_child(paste_btn)
	parent.add_child(actions)

func _add_slider(parent, store: Dictionary, prefix: String, label: String, key: String, mn, mx, step) -> void:
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
	s.connect("value_changed", self, "_on_slider", [key, prefix])
	row.add_child(s)
	var sb = SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = DEFAULTS[key]
	sb.connect("value_changed", self, "_on_spin", [key, prefix])
	row.add_child(sb)
	var rb = _make_icon_button("icons/reset.png", "Reset " + label, 0.5)
	rb.connect("pressed", self, "_on_single_reset", [key, prefix])
	row.add_child(rb)
	store[key + "_slider"] = s
	store[key + "_spin"] = sb
	parent.add_child(row)

func _store(prefix: String) -> Dictionary:
	return pt_ui if prefix == "pt" else ui

func _update_link_enabled(store: Dictionary) -> void:
	if not store.has("link_sun"):
		return
	store["link_sun"].disabled = store["lock_sun"].pressed
	var en = not store["link_sun"].pressed
	var tint = Color(1, 1, 1, 1.0) if en else Color(1, 1, 1, 0.4)
	store["angle_spin"].editable = en
	store["angle_spin"].modulate = tint
	store["strength_spin"].editable = en
	store["strength_spin"].modulate = tint

func _cfg_from_store(store: Dictionary) -> Dictionary:
	var cfg = DEFAULTS.duplicate(true)
	cfg["enabled"] = store["enable"].pressed
	for key in SLIDER_KEYS:
		cfg[key] = store[key + "_spin"].value
	cfg["shadow_color"] = store["color"].color
	cfg["relief"] = RELIEFS[1 if store["relief_btn_1"].pressed else 0]  # 0 = raised, 1 = lowered
	cfg["sun_angle"] = _world_from_spin(store["angle_spin"].value)
	cfg["sun_strength"] = store["strength_spin"].value / 100.0
	cfg["link_sun"] = store["link_sun"].pressed
	cfg["lock_sun"] = store["lock_sun"].pressed
	return cfg

func _store_from_cfg(store: Dictionary, cfg: Dictionary) -> void:
	_syncing = true
	store["enable"].pressed = cfg.get("enabled", false)
	for key in SLIDER_KEYS:
		store[key + "_slider"].value = cfg[key]
		store[key + "_spin"].value = cfg[key]
	var sc = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if sc is String:
		sc = Color(sc)
	store["color"].color = sc
	store["link_sun"].pressed = cfg.get("link_sun", false)
	store["lock_sun"].pressed = cfg.get("lock_sun", false)
	var relief = cfg.get("relief", "raised")
	if relief == "recess" or relief == "sunken":
		relief = "lowered"
	_set_relief_buttons(store, max(RELIEFS.find(relief), 0))
	_set_dial(store, float(cfg.get("sun_angle", DEFAULTS["sun_angle"])), float(cfg.get("sun_strength", DEFAULTS["sun_strength"])))
	_update_link_enabled(store)
	store["panel"].visible = cfg.get("enabled", false)
	_syncing = false

#########################################################################################################
## UI — SUN DIAL (handle = sun direction, radius = directionality, linear)
#########################################################################################################

# The Angle spin shows the same convention as the Soft Shadow dial (0° = sun at
# noon / top, 90° = right, clockwise). Internally sun_angle stays in world
# degrees (0 = right, 90 = down): displayed = world + 90.
func _spin_from_world(world_deg: float) -> float:
	return fposmod(world_deg + 90.0, 360.0)

func _world_from_spin(spin_deg: float) -> float:
	return fposmod(spin_deg - 90.0, 360.0)

func _make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			img.set_pixel(x, y, color if Vector2(x, y).distance_to(center) <= radius else Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

func _make_ring_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			img.set_pixel(x, y, color if abs(Vector2(x, y).distance_to(center) - radius) < 1.0 else Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

func _create_dial(store: Dictionary, prefix: String) -> Control:
	var size = DIAL_SIZE
	var dial = Control.new()
	dial.name = "SunDial"
	dial.rect_min_size = Vector2(size, size)
	dial.rect_size = Vector2(size, size)
	dial.rect_clip_content = false
	var bg = TextureRect.new()
	bg.texture = _make_circle_texture(size, Color(0.12, 0.12, 0.12, 1.0))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg)
	for ring_frac in [0.25, 0.5, 0.75]:
		var rs = int(size * ring_frac)
		var ring = TextureRect.new()
		ring.texture = _make_ring_texture(rs, Color(0.22, 0.22, 0.22, 1.0))
		ring.rect_position = Vector2((size - rs) / 2.0, (size - rs) / 2.0)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring)
	for diag in [45.0, 135.0, 225.0, 315.0]:
		var dr = deg2rad(diag)
		for d in range(4, int(size / 2.0 - 2.0), 3):
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(size / 2.0 + cos(dr) * d, size / 2.0 + sin(dr) * d)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)
	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(0, size / 2.0 - 0.5)
	h_line.rect_min_size = Vector2(size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(size / 2.0 - 0.5, 0)
	v_line.rect_min_size = Vector2(1, size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)
	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(size / 2.0 - 1.5, size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)
	var snap_pos = {
		"snap_315": Vector2(size - 8, -4),
		"snap_45": Vector2(size - 8, size - 8),
		"snap_135": Vector2(-4, size - 8),
		"snap_225": Vector2(-4, -4)}
	var snap_deg = {"snap_315": 315.0, "snap_45": 45.0, "snap_135": 135.0, "snap_225": 225.0}
	var snap_tip = {"snap_315": "Sun NE", "snap_45": "Sun SE", "snap_135": "Sun SW", "snap_225": "Sun NW"}
	for key in SNAP_KEYS:
		var b = TextureButton.new()
		b.name = key
		b.texture_normal = _make_circle_texture(12, Color(0.3, 0.3, 0.3, 0.8))
		b.texture_pressed = _make_circle_texture(12, Color(0.353, 0.698, 1.0, 1.0))
		b.toggle_mode = true
		b.rect_position = snap_pos[key]
		b.rect_min_size = Vector2(12, 12)
		b.hint_tooltip = snap_tip[key]
		b.connect("toggled", self, "_on_snap_toggled", [key, snap_deg[key], prefix])
		dial.add_child(b)
		store[key] = b
	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.rect_position = Vector2(size / 2.0 - 5, size / 2.0 - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)
	dial.connect("gui_input", self, "_on_dial_input", [dial, prefix])
	store["dial"] = dial
	store["dial_dot"] = handle
	return dial

# Editing the sun by hand breaks the link to the soft shadow's sun.
func _unlink(store: Dictionary) -> void:
	if store.has("link_sun") and store["link_sun"].pressed:
		var prev = _syncing
		_syncing = true
		store["link_sun"].pressed = false
		_syncing = prev
		_update_link_enabled(store)

func _on_dial_input(event: InputEvent, dial: Control, prefix: String) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		dial.set_meta("dragging", event.pressed)
		if event.pressed:
			_update_dial_from_mouse(event.position, dial, prefix)
	elif event is InputEventMouseMotion and dial.get_meta("dragging"):
		_update_dial_from_mouse(event.position, dial, prefix)

func _update_dial_from_mouse(pos: Vector2, dial: Control, prefix: String) -> void:
	var store = _store(prefix)
	var radius = DIAL_SIZE / 2.0
	var delta = pos - Vector2(radius, radius)
	var dist = delta.length()
	if dist > radius:
		delta = delta.normalized() * radius
		dist = radius
	var frac = dist / radius
	var angle = _world_from_spin(store["angle_spin"].value)
	if dist > 0.5:
		angle = fposmod(rad2deg(atan2(delta.y, delta.x)), 360.0)
	var snap_angle = dial.get_meta("snap_angle") as float
	if snap_angle >= 0.0:
		var sd = Vector2(cos(deg2rad(snap_angle)), sin(deg2rad(snap_angle)))
		var proj = delta.dot(sd)
		frac = 0.0 if proj <= 0.0 else min(proj, radius) / radius
		angle = snap_angle
	_unlink(store)
	# Quadratic radius, like the soft shadow dial.
	_set_dial(store, round(angle), frac * frac)
	_after_change(prefix, false, ["sun_angle", "sun_strength", "link_sun"])

func _on_snap_toggled(pressed: bool, key: String, angle: float, prefix: String) -> void:
	var store = _store(prefix)
	var dial = store.get("dial")
	if dial == null:
		return
	if pressed:
		for k in SNAP_KEYS:
			if k != key:
				store[k].pressed = false
		dial.set_meta("snap_angle", angle)
		_unlink(store)
		var strength = store["strength_spin"].value / 100.0
		if strength <= 0.0:
			strength = 1.0
		_set_dial(store, angle, strength)
		_after_change(prefix, false, ["sun_angle", "sun_strength", "link_sun"])
	else:
		dial.set_meta("snap_angle", -1.0)

func _deactivate_snaps(store: Dictionary) -> void:
	for k in SNAP_KEYS:
		if store.has(k):
			store[k].pressed = false
	if store.has("dial"):
		store["dial"].set_meta("snap_angle", -1.0)

func _on_sun_spin_changed(_v, prefix: String) -> void:
	if _syncing:
		return
	var store = _store(prefix)
	var angle = _world_from_spin(store["angle_spin"].value)
	var dial = store.get("dial")
	if dial != null and (dial.get_meta("snap_angle") as float) >= 0.0:
		if abs(angle - (dial.get_meta("snap_angle") as float)) > 0.5:
			_deactivate_snaps(store)
	_set_dial(store, angle, store["strength_spin"].value / 100.0)
	_after_change(prefix, false, ["sun_angle", "sun_strength"])

# Sets spins + handle from (sun angle deg, strength 0..1).
func _set_dial(store: Dictionary, angle: float, strength: float) -> void:
	if not store.has("dial"):
		return
	var was = _syncing
	_syncing = true
	strength = clamp(strength, 0.0, 1.0)
	store["angle_spin"].value = round(_spin_from_world(angle))
	store["strength_spin"].value = round(strength * 100.0)
	var radius = DIAL_SIZE / 2.0
	var direction = Vector2(cos(deg2rad(angle)), sin(deg2rad(angle)))
	# Handle position linear in the value (mouse -> value is quadratic): the
	# handle slows down toward the center, like the other tools' dials.
	var p = Vector2(radius, radius) + direction * strength * radius
	store["dial_dot"].rect_position = Vector2(p.x - 5, p.y - 5)
	_syncing = was

#########################################################################################################
## UI — SELECT TOOL
#########################################################################################################

func build_select_tool_ui() -> void:
	var panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	var parent = null
	for cand in ["patternShapeOptions", "patternOptions", "shapeOptions"]:
		if panel.get(cand) != null:
			parent = panel.get(cand)
			break
	if parent == null:
		outputlog("SelectTool pattern options VBox not found — Select Tool UI disabled", 0)
		return
	ui["_parent"] = parent
	var c = VBoxContainer.new()
	c.name = "OverlayShadowPatternsContainer"
	ui["container"] = c
	c.add_child(HSeparator.new())
	_build_title(c, ui, "sel", "")
	var sp = VBoxContainer.new()
	sp.visible = false
	ui["panel"] = sp
	_build_settings(sp, ui, "sel")
	c.add_child(sp)

func on_selection_changed() -> void:
	_monitored = null
	if not ui.has("container"):
		return
	var sel = global.Editor.Tools["SelectTool"].Selected
	var c = ui["container"]
	if sel.size() > 0 and is_pattern(sel[0]):
		if c.get_parent() != ui["_parent"]:
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			ui["_parent"].add_child(c)
		_position_after_soft_shadow()
		_monitored = sel[0]
		var mcfg = _saved_or_default_cfg(_node_id(sel[0]))
		if mcfg.get("link_sun", false):
			var ls = _linked_sun(_node_id(sel[0]))
			if ls != null:
				mcfg["sun_angle"] = ls[0]
				mcfg["sun_strength"] = ls[1]
		_store_from_cfg(ui, mcfg)
		return
	if c.get_parent() != null:
		c.get_parent().remove_child(c)

# Keep the order Soft Shadow > Overlay Shadow in the Select Tool panel.
func _position_after_soft_shadow() -> void:
	var parent = ui["_parent"]
	var soft = parent.get_node_or_null("DropShadowPatternsContainer")
	var c = ui["container"]
	if soft == null:
		return
	var want = soft.get_index() + 1
	if c.get_index() < soft.get_index():
		want = soft.get_index()
	if c.get_index() != want:
		parent.move_child(c, want)

#########################################################################################################
## UI — PATTERN TOOL
#########################################################################################################

# No overlay section in the Pattern Tool: overlays are set up from the Select
# Tool only. (pt_ui stays empty; every pt_ui path below is guarded.)
func build_pattern_tool_ui() -> void:
	pass

func get_pattern_tool_config() -> Dictionary:
	if not pt_ui.has("enable"):
		return DEFAULTS.duplicate(true)
	return _cfg_from_store(pt_ui)

func _save_pattern_tool_defaults() -> void:
	if not pt_ui.has("enable"):
		return
	var cfg = get_pattern_tool_config()
	cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
	global.ModMapData[TOOL_DEFAULTS_KEY] = cfg

#########################################################################################################
## UI — HANDLERS
#########################################################################################################

func _after_change(prefix: String, force_all: bool, changed_keys: Array) -> void:
	if prefix == "pt":
		_save_pattern_tool_defaults()
	else:
		apply_to_selected(force_all, changed_keys)

func _on_enable_toggled(pressed, prefix: String) -> void:
	if _syncing:
		return
	_store(prefix)["panel"].visible = pressed
	_after_change(prefix, true, [])

func _on_slider(value, key, prefix: String) -> void:
	if _syncing:
		return
	_syncing = true
	_store(prefix)[key + "_spin"].value = value
	_syncing = false
	_after_change(prefix, false, [key])

func _on_spin(value, key, prefix: String) -> void:
	if _syncing:
		return
	_syncing = true
	_store(prefix)[key + "_slider"].value = value
	_syncing = false
	_after_change(prefix, false, [key])

func _set_relief_buttons(store: Dictionary, idx: int) -> void:
	for i in range(2):
		var b = store.get("relief_btn_" + str(i))
		if b == null:
			continue
		b.pressed = (i == idx)
		b.icon = b.get_icon("radio_checked" if i == idx else "radio_unchecked", "CheckBox")

func _on_relief_pressed(idx: int, prefix: String) -> void:
	var store = _store(prefix)
	_set_relief_buttons(store, idx)
	if _syncing:
		return
	_after_change(prefix, false, ["relief"])

func _on_color(_c, prefix: String) -> void:
	if _syncing:
		return
	_after_change(prefix, false, ["shadow_color"])

func _on_link_toggled(pressed, prefix: String) -> void:
	var store = _store(prefix)
	if pressed and not _syncing and store["lock_sun"].pressed:
		_syncing = true
		store["lock_sun"].pressed = false
		_syncing = false
	if pressed and not _syncing and prefix == "sel" and _monitored != null and is_instance_valid(_monitored):
		var ls = _linked_sun(_node_id(_monitored))
		if ls != null:
			_set_dial(store, ls[0], ls[1])
	_update_link_enabled(store)
	if not _syncing:
		_after_change(prefix, false, ["link_sun", "lock_sun"])

func _on_lock_toggled(pressed, prefix: String) -> void:
	var store = _store(prefix)
	if _syncing:
		_update_link_enabled(store)
		return
	_syncing = true
	if pressed and store["link_sun"].pressed:
		store["link_sun"].pressed = false
	# Convert the angle between world and shape-local so nothing jumps on toggle.
	if prefix == "sel" and _monitored != null and is_instance_valid(_monitored):
		var deg = _world_from_spin(store["angle_spin"].value)
		var v = Vector2(cos(deg2rad(deg)), sin(deg2rad(deg)))
		if pressed:
			var ls = _linked_sun(_node_id(_monitored))
			var was_linked = _saved_or_default_cfg(_node_id(_monitored)).get("link_sun", false)
			if was_linked and ls != null:
				v = Vector2(cos(deg2rad(ls[0])), sin(deg2rad(ls[0])))
				_set_dial(store, ls[0], ls[1])
			v = _monitored.transform.affine_inverse().basis_xform(v)
		else:
			v = _monitored.transform.basis_xform(v)
		if v.length_squared() > 0.0:
			var nd = round(fposmod(rad2deg(atan2(v.y, v.x)), 360.0))
			_set_dial(store, nd, store["strength_spin"].value / 100.0)
	_syncing = false
	_update_link_enabled(store)
	_after_change(prefix, false, ["lock_sun", "link_sun", "sun_angle"])

func _on_single_reset(key, prefix: String) -> void:
	var store = _store(prefix)
	_syncing = true
	if key == "shadow_color":
		store["color"].color = DEFAULTS["shadow_color"]
	elif key == "sun":
		_set_dial(store, DEFAULTS["sun_angle"], DEFAULTS["sun_strength"])
		_syncing = false
		_after_change(prefix, false, ["sun_angle", "sun_strength"])
		return
	elif store.has(key + "_slider"):
		store[key + "_slider"].value = DEFAULTS[key]
		store[key + "_spin"].value = DEFAULTS[key]
	_syncing = false
	_after_change(prefix, false, [key])

func _on_reset(prefix: String) -> void:
	var store = _store(prefix)
	var cfg = DEFAULTS.duplicate(true)
	cfg["enabled"] = store["enable"].pressed
	_store_from_cfg(store, cfg)
	_after_change(prefix, false, [])

func _on_copy(prefix: String) -> void:
	_clipboard = _cfg_from_store(_store(prefix))

func _on_paste(prefix: String) -> void:
	if _clipboard.empty():
		return
	var store = _store(prefix)
	var cfg = _clipboard.duplicate(true)
	cfg["enabled"] = store["enable"].pressed or cfg.get("enabled", false)
	_store_from_cfg(store, cfg)
	_after_change(prefix, false, [])

#########################################################################################################
## APPLY TO SELECTION
#########################################################################################################

func apply_to_selected(force_all: bool = false, changed_keys: Array = []) -> void:
	_history_touch("overlay_pattern" if changed_keys.empty() else str(changed_keys[0]))
	var ui_cfg = _cfg_from_store(ui)
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_pattern(node):
			continue
		var nid = _node_id(node)
		var cfg: Dictionary
		if node == _monitored:
			cfg = ui_cfg
		elif force_all:
			cfg = _saved_or_default_cfg(nid)
			cfg["enabled"] = ui_cfg["enabled"]
		elif changed_keys.size() > 0:
			cfg = _saved_or_default_cfg(nid)
			if not cfg.get("enabled", false):
				continue
			for key in changed_keys:
				if ui_cfg.has(key):
					cfg[key] = ui_cfg[key]
		else:
			cfg = ui_cfg
		if cfg["enabled"]:
			create_shadow(node, cfg)
		else:
			remove_shadow(node)
		save_data(node, cfg)

#########################################################################################################
## UNDO/REDO — SETTINGS TRANSACTIONS
#########################################################################################################

func _history_affected() -> Array:
	var out = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_pattern(node) and not out.has(node):
			out.append(node)
	return out

func _history_snapshot(nodes: Array) -> Dictionary:
	var snap = {}
	for node in nodes:
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var nid = _node_id(node)
		var cfg = _saved_or_default_cfg(nid)
		if cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		snap[nid] = cfg
	return snap

func _history_touch(label: String = "") -> void:
	if shadow_history == null or _history_suspend or _syncing:
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
		var cfg = _saved_or_default_cfg(nid)
		if cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		after[nid] = cfg
		if JSON.print(before[nid]) != JSON.print(cfg):
			changed = true
	if changed:
		shadow_history.record(self, "history_apply", before, after, _history_txn_label)

func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true
	var refresh = false
	for nid in payload.keys():
		var cfg = payload[nid].duplicate(true)
		if cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		var iid = int(nid)
		var node = global.World.GetNodeByID(iid) if global.World.HasNodeID(iid) else null
		if is_pattern(node):
			if cfg.get("enabled", false):
				create_shadow(node, cfg)
			else:
				remove_shadow(node)
			save_data(node, cfg)
			if node == _monitored:
				refresh = true
		else:
			if not global.ModMapData.has(DATA_KEY):
				global.ModMapData[DATA_KEY] = {}
			global.ModMapData[DATA_KEY][nid] = payload[nid].duplicate(true)
	if refresh and _monitored != null and is_instance_valid(_monitored):
		_store_from_cfg(ui, _saved_or_default_cfg(_node_id(_monitored)))
	_history_suspend = false
