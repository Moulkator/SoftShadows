#########################################################################################################
##
## DROP SHADOW FOR PATTERNS (PatternShape polygons)
##
#########################################################################################################
# Version 1.1.0 — Phase 2: "simple" (geometric mesh) + "realistic" (SDF shader) modes.
#
# A PatternShape is a Polygon2D living under Level.PatternShapes / "Layer N".
# The shadow is a MeshInstance2D CHILD of the shape with z_as_relative = true
# and z_index = -1, so it renders one z-unit below the pattern's layer and
# follows the shape for free (move / rotate / scale / layer change / delete /
# undo-redo of DD's PatternShapeRecord). PatternShape.Save() never serializes
# children, so the shadow node is invisible to DD's save pipeline.
#
# Simple    = mesh: filled polygon (solid) + outward "spread" band (solid) +
#             outward "softness" band fading to transparent.
# Realistic = quad + shader computing the exact signed distance to the polygon
#             per fragment (gaussian-like fade both sides of the edge).
# All in shape-local space; the user offset is given in world space and
# converted to local so it stays stable when the shape is rotated / scaled.

var global
var core = null
var logging_level = 0
var shadow_history = null   # set by Core

const DATA_KEY = "DropShadowPatterns"
const TOOL_DEFAULTS_KEY = "DropShadowPatternsToolDefaults"
const SHADOW_NODE_NAME = "DropShadowPatternMesh"
const META_KEY = "drop_shadow_pattern_node"

const DEFAULTS = {
	"enabled": false,
	"opacity": 0.5,
	"sun_angle": 315.0,      # degrees; same convention as the paths dial:
	                         # offset = (-sin a, cos a) * dist (315 = shadow to bottom-right)
	"offset_dist": 0.0,      # px, world space (no offset by default)
	"spread": 0.0,           # px, solid outward growth (classic style)
	"softness": 24.0,        # px, fade-out band width (classic style)
	"simple_blur": 0.15,     # Blur style: 0..1 -> 0..SIMPLE_BLUR_MAX_PX, spread forced to 0
	"slider_style": 0,       # style the shadow was last edited in: 0 classic, 1 blur
	"shadow_color": Color(0, 0, 0, 1),
	"render_mode": "simple",  # "simple" (phase 1) | "realistic" (phase 2)
	# Custom Shadow Layer: raw z (same numbering as DD layers). Clamped per node
	# to the pattern's own layer (never above its asset); == layer means "just
	# under the pattern" (same z bucket, drawn behind parent), lower values go
	# under other patterns / assets. OFF = one z-unit below the pattern's layer.
	"custom_layer": false,
	"shadow_layer": 0,
	# Shadow behind layer: OFF (default) = same z bucket as the pattern, drawn
	# just behind it (so above lower patterns of the same layer); ON = one
	# z-unit below the whole layer. Ignored when Custom Shadow Layer is ON.
	"behind_layer": false
}
const LAYER_MIN = -500
const LAYER_MAX = 1100

const SLIDER_KEYS = ["spread", "softness", "simple_blur", "opacity"]
const SIMPLE_BLUR_MAX_PX = 180.0
const OFFSET_MAX = 100.0
const DIAL_SIZE = 90
const SNAP_KEYS = ["snap_45", "snap_135", "snap_225", "snap_315"]
const RENDER_MODES = ["simple", "realistic"]
const REALISTIC_MAX_POINTS = 512
const SOFT_STRIPS = 6
const MITER_LIMIT = 3.0

# ── State ───────────────────────────────────────────────────────────────
var ui = {}          # Select Tool controls
var pt_ui = {}       # Pattern Tool controls
var _syncing = false
var _monitored = null
var _active = {}     # node_id (String) -> {"node": shape, "sig": String}
var _clipboard = {}
var _monitor_timer = null
var _pattern_tool = null
var _shader: Shader = null

# ── Undo/redo (settings transactions) ───────────────────────────────────
var _history_flush_timer = null
var _history_txn_active = false
var _history_txn_before = {}
var _history_txn_label = ""
var _history_suspend = false

# ── New-node handling ───────────────────────────────────────────────────
var _pending_new_nodes = []
var _heal_counter = 0
# Clone / copy-paste follow: signatures of the patterns selected at the last
# Ctrl+C ({sig: cfg}); a new node matching one inherits its config.
var _copy_sources = {}
var _ctrl_c_was = false
var _layer_reset_pending = false  # Reset: each selected pattern -> its OWN layer

const ENABLE_LOGGING = true
func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <DropShadowPatterns>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise() -> void:
	outputlog("Drop Shadow Patterns initialising...")
	_shader = ResourceLoader.load(global.Root + "shaders/DropShadowPattern.shader", "Shader", true)
	if _shader == null:
		outputlog("WARNING: DropShadowPattern.shader not found — realistic mode falls back to simple", 0)
	build_select_tool_ui()
	build_pattern_tool_ui()
	_register_pattern_tool_signals()

	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "on_new_node_added_to_world")

	# Monitor: processes pending new nodes, and rebuilds shadows whose shape
	# changed (points / transform / outline). Paused by Core during map load.
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

	outputlog("Drop Shadow Patterns initialised. [BUILD: PATTERNS-1]", 0)

#########################################################################################################
## NODE HELPERS
#########################################################################################################

# True if `node` is a PatternShape: a Polygon2D whose grandparent is the
# PatternShapes container of its Level.
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

# The meta may be stale after a DD level clone (duplicate() copies the meta
# reference to the SOURCE shape's shadow) — only trust it if it's our child.
func _get_shadow_node(shape):
	if shape.has_meta(META_KEY):
		var n = shape.get_meta(META_KEY)
		if n != null and is_instance_valid(n) and n.get_parent() == shape:
			return n
	return shape.get_node_or_null(SHADOW_NODE_NAME)

func get_pattern_layer(shape) -> int:
	var p = shape.get_parent()
	return int(p.z_index) if p != null else 0

# Effective raw shadow layer for a node under `cfg` (clamped to its layer).
func effective_shadow_layer(shape, cfg: Dictionary) -> int:
	var layer = get_pattern_layer(shape)
	if not cfg.get("custom_layer", false):
		return layer - 1 if cfg.get("behind_layer", false) else layer
	return int(clamp(int(cfg.get("shadow_layer", layer)), LAYER_MIN, layer))

func _node_id(node) -> String:
	return str(node.get_meta("node_id"))

# Signature used by the monitor to detect geometry / transform changes.
func _shape_signature(shape) -> String:
	var pts = shape.polygon
	var h = pts.size()
	for p in pts:
		h = (h * 31 + int(p.x * 100)) % 2147483647
		h = (h * 31 + int(p.y * 100)) % 2147483647
	return "%d|%.4f|%.4f|%.4f|%d" % [h, shape.rotation, shape.scale.x, shape.scale.y, get_pattern_layer(shape)]

#########################################################################################################
## GEOMETRY
#########################################################################################################

# Outward vertex normals of a closed polygon (miter, clamped).
func _outward_normals(pts: PoolVector2Array) -> Array:
	var n = pts.size()
	var area = 0.0
	for i in range(n):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	var wind = 1.0 if area > 0.0 else -1.0
	var edge_n = []
	for i in range(n):
		var d = pts[(i + 1) % n] - pts[i]
		if d.length_squared() < 0.000001:
			edge_n.append(Vector2.ZERO)
		else:
			d = d.normalized()
			edge_n.append(Vector2(d.y, -d.x) * wind)
	var out = []
	for i in range(n):
		var n_prev = edge_n[(i - 1 + n) % n]
		var n_next = edge_n[i]
		var m = n_prev + n_next
		if m.length_squared() < 0.000001:
			out.append(n_next)
			continue
		m = m.normalized()
		var cos_half = m.dot(n_next)
		var scale = 1.0
		if cos_half > 0.001:
			scale = min(1.0 / cos_half, MITER_LIMIT)
		out.append(m * scale)
	return out

# (spread_px, softness_px) in WORLD px according to the shadow's slider style:
# classic = Spread + Softness; Blur style = spread 0, softness = simple_blur.
func _size_px(cfg: Dictionary) -> Array:
	if int(cfg.get("slider_style", 0)) == 1:
		return [0.0, float(cfg.get("simple_blur", DEFAULTS["simple_blur"])) * SIMPLE_BLUR_MAX_PX]
	return [float(cfg.get("spread", 0.0)), float(cfg.get("softness", 0.0))]

func _build_mesh(shape, cfg: Dictionary) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var pts: PoolVector2Array = shape.polygon
	var n = pts.size()
	if n < 3:
		return mesh

	var raw = cfg.get("shadow_color", DEFAULTS["shadow_color"])
	var color: Color = Color(raw) if raw is String else raw
	var opacity = float(cfg.get("opacity", DEFAULTS["opacity"]))
	var solid = Color(color.r, color.g, color.b, min(opacity, 1.0))

	# px -> shape-local units (compensate the shape's scale)
	var s = max(abs(shape.scale.x), abs(shape.scale.y))
	if s < 0.001:
		s = 1.0
	var size = _size_px(cfg)
	var spread = size[0] / s
	var softness = size[1] / s

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var indices = PoolIntArray()

	# 1) Filled interior
	var tri = Geometry.triangulate_polygon(pts)
	if tri.size() >= 3:
		for p in pts:
			verts.append(p)
			colors.append(solid)
		for idx in tri:
			indices.append(idx)

	# 2) Outward bands (rings). Ring 0 = polygon, ring 1 = +spread (solid),
	#    then SOFT_STRIPS rings fading to transparent over `softness`.
	var normals = _outward_normals(pts)
	var rings = []
	var ring_colors = []
	rings.append(pts)
	ring_colors.append(solid)
	if spread > 0.0:
		var r = PoolVector2Array()
		for i in range(n):
			r.append(pts[i] + normals[i] * spread)
		rings.append(r)
		ring_colors.append(solid)
	if softness > 0.0:
		for k in range(1, SOFT_STRIPS + 1):
			var t = float(k) / float(SOFT_STRIPS)
			var dist = spread + softness * t
			# smooth falloff
			var a = min(opacity * (1.0 - (t * t * (3.0 - 2.0 * t))), 1.0)
			var r = PoolVector2Array()
			for i in range(n):
				r.append(pts[i] + normals[i] * dist)
			rings.append(r)
			ring_colors.append(Color(color.r, color.g, color.b, a))

	if rings.size() > 1:
		var base = verts.size()
		for ri in range(rings.size()):
			for i in range(n):
				verts.append(rings[ri][i])
				colors.append(ring_colors[ri])
		for ri in range(rings.size() - 1):
			var r0 = base + ri * n
			var r1 = base + (ri + 1) * n
			for i in range(n):
				var j = (i + 1) % n
				indices.append(r0 + i)
				indices.append(r0 + j)
				indices.append(r1 + i)
				indices.append(r0 + j)
				indices.append(r1 + j)
				indices.append(r1 + i)

	if indices.size() == 0:
		return mesh
	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	arrays[ArrayMesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _offset_from_angle(sun_deg: float, dist: float) -> Vector2:
	var a = deg2rad(sun_deg)
	return Vector2(-sin(a), cos(a)) * dist

func _local_offset(shape, cfg: Dictionary) -> Vector2:
	var world = _offset_from_angle(float(cfg.get("sun_angle", 0.0)), float(cfg.get("offset_dist", 0.0)))
	# World -> shape-local direction (ignores translation). Layers / Level are
	# not rotated or scaled, so the shape's own transform is enough.
	return shape.transform.basis_xform_inv(world)

#########################################################################################################
## CREATE / REMOVE
#########################################################################################################

func create_shadow(shape, cfg: Dictionary) -> void:
	if not is_pattern(shape):
		return
	remove_shadow(shape)
	var node = null
	if cfg.get("render_mode", "simple") == "realistic" and _shader != null:
		node = _make_realistic_node(shape, cfg)
	if node == null:
		var mesh = _build_mesh(shape, cfg)
		if mesh.get_surface_count() == 0:
			return
		var mi = MeshInstance2D.new()
		mi.mesh = mesh
		node = mi
	node.name = SHADOW_NODE_NAME
	node.position = _local_offset(shape, cfg)
	node.z_as_relative = true
	var rel = effective_shadow_layer(shape, cfg) - get_pattern_layer(shape)
	node.z_index = rel
	# rel == 0: same z bucket as the pattern -> draw behind the parent itself.
	node.show_behind_parent = (rel == 0)
	node.set_meta("is_drop_shadow", true)
	if global.ModMapData.get("DropShadowToggleHidden", false):
		node.visible = false
	shape.add_child(node)
	shape.set_meta(META_KEY, node)
	_active[_node_id(shape)] = {"node": shape, "sig": _shape_signature(shape)}

# Realistic: a rectangular Polygon2D covering the shape's bounds (+ margin)
# whose shader evaluates the polygon's signed distance field.
func _make_realistic_node(shape, cfg: Dictionary):
	var pts: PoolVector2Array = shape.polygon
	var n = pts.size()
	if n < 3 or n > REALISTIC_MAX_POINTS:
		return null
	var raw = cfg.get("shadow_color", DEFAULTS["shadow_color"])
	var color: Color = Color(raw) if raw is String else raw
	var sc = max(abs(shape.scale.x), abs(shape.scale.y))
	if sc < 0.001:
		sc = 1.0
	var size = _size_px(cfg)
	var spread = size[0] / sc
	var blur = size[1] / sc

	# Bounds + margin
	var rect = Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		rect = rect.expand(p)
	# The SDF fade extends up to 2*blur outside the edge: the quad must cover it.
	var margin = spread + 2.0 * blur + 2.0
	rect = rect.grow(margin)

	var img = Image.new()
	img.create(n, 1, false, Image.FORMAT_RGBAF)
	img.lock()
	for i in range(n):
		img.set_pixel(i, 0, Color(pts[i].x, pts[i].y, 0.0, 1.0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)  # no filter, no mipmaps

	var mat = ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_param("shadow_color", Color(color.r, color.g, color.b, 1.0))
	mat.set_shader_param("opacity", float(cfg.get("opacity", DEFAULTS["opacity"])))
	mat.set_shader_param("blur_radius", blur)
	mat.set_shader_param("spread", spread)
	mat.set_shader_param("poly_data_tex", tex)
	mat.set_shader_param("poly_count", n)

	var quad = Polygon2D.new()
	quad.polygon = PoolVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y)])
	quad.color = Color(1, 1, 1, 1)
	quad.material = mat
	return quad

func remove_shadow(shape) -> void:
	if shape == null or not is_instance_valid(shape):
		return
	var n = _get_shadow_node(shape)
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
	if cfg != null and cfg.get("custom_layer", false):
		# Pattern moved below its saved shadow_layer (layer change): persist the
		# clamped value so the UI and the data agree.
		var clamped = effective_shadow_layer(shape, cfg)
		if clamped != int(cfg.get("shadow_layer", 0)):
			cfg["shadow_layer"] = clamped
			save_data(shape, cfg)
		if shape == _monitored and ui.has("shadow_layer_spin"):
			_update_shadow_layer_ui_max()
			_set_layer_ui_value(ui, clamped)
	if cfg != null and cfg.get("enabled", false):
		create_shadow(shape, cfg)
	else:
		remove_shadow(shape)

#########################################################################################################
## PATTERN TOOL SIGNALS / NEW NODES / MONITOR
#########################################################################################################

func _register_pattern_tool_signals() -> void:
	_pattern_tool = global.Editor.Tools.get("PatternShapeTool")
	if _pattern_tool == null:
		outputlog("PatternShapeTool not found", 1)
		return
	for sig in ["OnUpdateEditShape", "OnEndEditShape"]:
		if _pattern_tool.has_signal(sig):
			_pattern_tool.connect(sig, self, "_on_shape_edited")

func _on_shape_edited(shape) -> void:
	if is_pattern(shape) and _active.has(_node_id(shape)):
		refresh_shadow(shape)

# DD signal: never mutate DD collections here — defer to the monitor tick.
func on_new_node_added_to_world(node) -> void:
	if node == null or not is_instance_valid(node):
		return
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
	# Brand-new shape drawn with the Pattern Tool while its toggle is ON.
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
	# Rebuild shadows whose shape changed (points / rotation / scale).
	var dead = []
	for nid in _active.keys():
		var e = _active[nid]
		var shape = e["node"]
		if shape == null or not is_instance_valid(shape) or not shape.is_inside_tree():
			dead.append(nid)
			continue
		var sig = _shape_signature(shape)
		if sig != e["sig"]:
			refresh_shadow(shape)
	for nid in dead:
		_active.erase(nid)
	# Heal: shapes re-created by DD without OnAssignNode (undo of a delete,
	# copy level...) whose saved config is enabled but whose shadow is missing.
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
		if not is_pattern(node) or _get_shadow_node(node) != null:
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
		# Migration (pre-dial): "offset_angle" was the offset direction itself.
		if cfg.has("offset_angle") and not global.ModMapData[DATA_KEY][nid].has("sun_angle"):
			var t = deg2rad(float(cfg["offset_angle"]))
			cfg["sun_angle"] = fposmod(rad2deg(atan2(-cos(t), sin(t))), 360.0)
			cfg.erase("offset_angle")
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
	# Map (re)load: the per-map slider style is seeded by now.
	on_simple_slider_style_changed()
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

func _create_cloud_icon() -> TextureRect:
	var tex = _load_icon("icons/cloud.png", 0.85)
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

# Builds the common settings block into `parent`, storing controls in `store`.
# `prefix` distinguishes handler routing ("sel" = Select Tool, "pt" = Pattern Tool).
func _build_settings(parent, store: Dictionary, prefix: String) -> void:
	# Render mode buttons (Simple = geometric mesh, Realistic = SDF shader),
	# same radio-button style as the paths / walls modules.
	var mrow = HBoxContainer.new()
	var mode_names = ["Simple", "Realistic"]
	for i in range(2):
		var mbtn = Button.new()
		mbtn.text = mode_names[i]
		mbtn.toggle_mode = true
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.align = Button.ALIGN_CENTER
		mbtn.focus_mode = Control.FOCUS_NONE
		mbtn.connect("pressed", self, "_on_mode_pressed", [i, prefix])
		mrow.add_child(mbtn)
		store["mode_btn_" + str(i)] = mbtn
	parent.add_child(mrow)
	_set_mode_buttons(store, 0)

	_build_offset_dial(parent, store, prefix)
	# Size rows: classic (Spread + Softness) or Blur, per the global
	# "Simple Sliders" setting of the Soft Shadows tool.
	_add_slider(parent, store, prefix, "Spread", "spread", 0, 100, 1)
	store["spread_row"] = store["spread_slider"].get_parent()
	_add_slider(parent, store, prefix, "Softness", "softness", 0, 200, 1)
	store["softness_row"] = store["softness_slider"].get_parent()
	_add_slider(parent, store, prefix, "Blur", "simple_blur", 0.0, 1.0, 0.01)
	store["simple_blur_row"] = store["simple_blur_slider"].get_parent()
	_update_size_rows(store)
	# Up to 2: values above 1 push the soft fade band toward full darkness.
	_add_slider(parent, store, prefix, "Opacity", "opacity", 0.05, 2.0, 0.01)

	# Shadow behind layer (hidden when Custom Shadow Layer is ON)
	var brow = HBoxContainer.new()
	var bl = Label.new()
	bl.text = "Shadow behind layer"
	bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bl.hint_tooltip = "OFF: the shadow sits just under its pattern (above lower patterns of the same layer). ON: under the whole layer."
	brow.add_child(bl)
	var bcb = CheckButton.new()
	bcb.pressed = DEFAULTS["behind_layer"]
	bcb.focus_mode = Control.FOCUS_NONE
	bcb.connect("toggled", self, "_on_behind_layer_toggled", [prefix])
	brow.add_child(bcb)
	store["behind_layer"] = bcb
	store["behind_row"] = brow
	brow.visible = (prefix != "pt")

	# Custom Shadow Layer: toggle row + (layer slider/spin/reset, shown when ON)
	var clrow = HBoxContainer.new()
	var cll = Label.new()
	cll.text = "Custom Shadow Layer"
	cll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cll.hint_tooltip = "Draw the shadow on a chosen layer (z_index) instead of just under its pattern"
	clrow.add_child(cll)
	var clb = CheckButton.new()
	clb.pressed = DEFAULTS["custom_layer"]
	clb.focus_mode = Control.FOCUS_NONE
	clb.hint_tooltip = "Draw the shadow on a chosen layer (z_index) instead of just under its pattern"
	clb.connect("toggled", self, "_on_custom_layer_toggled", [prefix])
	clrow.add_child(clb)
	store["custom_layer"] = clb
	clrow.visible = (prefix != "pt")
	parent.add_child(clrow)
	var lrow = HBoxContainer.new()
	lrow.visible = DEFAULTS["custom_layer"] and prefix != "pt"
	var ll = Label.new()
	ll.text = "Layer"
	ll.rect_min_size.x = 60
	ll.hint_tooltip = "Raw z_index. DD layers: Terrain -500, Floor -200, Water 0, User 1-4 = 100-400, Portals 500, Walls 600, Above Walls 700, Roofs 800, Above Roofs 900"
	lrow.add_child(ll)
	var ls = HSlider.new()
	ls.min_value = LAYER_MIN
	ls.max_value = LAYER_MAX
	ls.step = 1
	ls.value = DEFAULTS["shadow_layer"]
	ls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ls.connect("value_changed", self, "_on_slider", ["shadow_layer", prefix])
	lrow.add_child(ls)
	var lsb = SpinBox.new()
	lsb.min_value = LAYER_MIN
	lsb.max_value = LAYER_MAX
	lsb.step = 1
	lsb.value = DEFAULTS["shadow_layer"]
	lsb.connect("value_changed", self, "_on_spin", ["shadow_layer", prefix])
	lrow.add_child(lsb)
	var lrb = _make_icon_button("icons/reset.png", "Reset to the pattern's own layer (just under the pattern)", 0.5)
	lrb.connect("pressed", self, "_on_layer_reset", [prefix])
	lrow.add_child(lrb)
	store["shadow_layer_slider"] = ls
	store["shadow_layer_spin"] = lsb
	store["layer_row"] = lrow
	parent.add_child(lrow)
	parent.add_child(brow)

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
	crow.visible = (prefix != "pt")
	parent.add_child(crow)

	var actions = HBoxContainer.new()
	var al = Label.new()
	al.text = "Shadow"
	al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(al)
	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.icon = _load_icon("icons/reset.png", 0.5)
	reset_btn.hint_tooltip = "Reset shadow to defaults"
	reset_btn.connect("pressed", self, "_on_reset", [prefix])
	actions.add_child(reset_btn)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.icon = _load_icon("icons/copy.png", 0.5)
	copy_btn.hint_tooltip = "Copy shadow settings"
	copy_btn.connect("pressed", self, "_on_copy", [prefix])
	actions.add_child(copy_btn)
	var paste_btn = Button.new()
	paste_btn.text = "Paste"
	paste_btn.icon = _load_icon("icons/paste.png", 0.5)
	paste_btn.hint_tooltip = "Paste shadow settings"
	paste_btn.connect("pressed", self, "_on_paste", [prefix])
	actions.add_child(paste_btn)
	actions.visible = (prefix != "pt")
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

func _cfg_from_store(store: Dictionary) -> Dictionary:
	var cfg = DEFAULTS.duplicate(true)
	cfg["enabled"] = store["enable"].pressed
	for key in SLIDER_KEYS:
		cfg[key] = store[key + "_spin"].value
	cfg["sun_angle"] = store["angle_spin"].value
	cfg["offset_dist"] = store["dist_spin"].value
	cfg["shadow_color"] = store["color"].color
	cfg["render_mode"] = RENDER_MODES[1 if store["mode_btn_1"].pressed else 0]
	cfg["slider_style"] = 1 if _simple_blur_style_enabled() else 0
	cfg["custom_layer"] = store["custom_layer"].pressed
	cfg["shadow_layer"] = int(store["shadow_layer_spin"].value)
	cfg["behind_layer"] = store["behind_layer"].pressed
	return cfg

func _store_from_cfg(store: Dictionary, cfg: Dictionary) -> void:
	_syncing = true
	store["enable"].pressed = cfg.get("enabled", false)
	for key in SLIDER_KEYS:
		store[key + "_slider"].value = cfg[key]
		store[key + "_spin"].value = cfg[key]
	_set_dial(store, float(cfg.get("sun_angle", DEFAULTS["sun_angle"])), float(cfg.get("offset_dist", DEFAULTS["offset_dist"])))
	var sc = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if sc is String:
		sc = Color(sc)
	store["color"].color = sc
	_set_mode_buttons(store, max(RENDER_MODES.find(cfg.get("render_mode", "simple")), 0))
	store["behind_layer"].pressed = cfg.get("behind_layer", false)
	store["behind_row"].visible = (not cfg.get("custom_layer", false)) and store != pt_ui
	store["custom_layer"].pressed = cfg.get("custom_layer", false)
	store["layer_row"].visible = cfg.get("custom_layer", false) and store != pt_ui
	store["shadow_layer_slider"].value = int(cfg.get("shadow_layer", 0))
	store["shadow_layer_spin"].value = int(cfg.get("shadow_layer", 0))
	store["panel"].visible = cfg.get("enabled", false)
	_syncing = false

#########################################################################################################
## UI — OFFSET DIAL (same behaviour as the paths dial: handle = sun direction)
#########################################################################################################

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

func _build_offset_dial(parent, store: Dictionary, prefix: String) -> void:
	# Header: Distance [spin]  Angle [spin]  [reset]
	var header = HBoxContainer.new()
	var dl = Label.new()
	dl.text = "Distance"
	header.add_child(dl)
	var dist_spin = SpinBox.new()
	dist_spin.min_value = 0
	dist_spin.max_value = OFFSET_MAX
	dist_spin.step = 1
	dist_spin.value = DEFAULTS["offset_dist"]
	dist_spin.rect_min_size.x = 85
	dist_spin.connect("value_changed", self, "_on_offset_spin_changed", [prefix])
	header.add_child(dist_spin)
	store["dist_spin"] = dist_spin
	var al = Label.new()
	al.text = "Angle"
	header.add_child(al)
	var angle_spin = SpinBox.new()
	angle_spin.min_value = 0
	angle_spin.max_value = 359
	angle_spin.step = 1
	angle_spin.value = DEFAULTS["sun_angle"]
	angle_spin.suffix = "°"
	angle_spin.rect_min_size.x = 72
	angle_spin.connect("value_changed", self, "_on_offset_spin_changed", [prefix])
	header.add_child(angle_spin)
	store["angle_spin"] = angle_spin
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var rb = _make_icon_button("icons/reset.png", "Reset offset", 0.5)
	rb.connect("pressed", self, "_on_single_reset", ["offset", prefix])
	header.add_child(rb)
	header.visible = (prefix != "pt")
	parent.add_child(header)

	var cc = CenterContainer.new()
	cc.rect_clip_content = false
	var mc = MarginContainer.new()
	mc.rect_clip_content = false
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_constant_override(m, 8)
	mc.add_child(_create_dial(store, prefix))
	if prefix == "sel":
		# Link button beside the dial (shown only when the pattern has an
		# overlay shadow): same state as the overlay section's Link button.
		var dial_row = HBoxContainer.new()
		dial_row.add_constant_override("separation", 12)
		dial_row.add_child(mc)
		var link_btn = _make_icon_button("icons/link.png", "Link the overlay shadow's sun to this dial (moving either dial moves both)", 0.5)
		link_btn.toggle_mode = true
		link_btn.visible = false
		link_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		link_btn.connect("toggled", self, "_on_overlay_link_toggled")
		dial_row.add_child(link_btn)
		store["overlay_link_btn"] = link_btn
		cc.add_child(dial_row)
	else:
		cc.add_child(mc)
	cc.visible = (prefix != "pt")
	parent.add_child(cc)

func _create_dial(store: Dictionary, prefix: String) -> Control:
	var size = DIAL_SIZE
	var dial = Control.new()
	dial.name = "OffsetDial"
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
	var direction = delta.normalized() if dist > 0.5 else Vector2.ZERO
	var snap_angle = dial.get_meta("snap_angle") as float
	if snap_angle >= 0.0:
		var sd = Vector2(cos(deg2rad(snap_angle)), sin(deg2rad(snap_angle)))
		var proj = delta.dot(sd)
		if proj <= 0.0:
			frac = 0.0
		else:
			frac = min(proj, radius) / radius
		direction = sd
	# Handle = sun direction, shadow offset = opposite; quadratic radius.
	var ox = round(-direction.x * frac * frac * OFFSET_MAX)
	var oy = round(-direction.y * frac * frac * OFFSET_MAX)
	_set_dial_from_xy(store, ox, oy)
	_after_change(prefix, false, ["sun_angle", "offset_dist"])

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
		var d = store["dist_spin"].value
		if d > 0:
			var r = deg2rad(angle)
			_set_dial_from_xy(store, round(-d * cos(r)), round(-d * sin(r)))
			_after_change(prefix, false, ["sun_angle", "offset_dist"])
	else:
		dial.set_meta("snap_angle", -1.0)

func _deactivate_snaps(store: Dictionary) -> void:
	for k in SNAP_KEYS:
		if store.has(k):
			store[k].pressed = false
	if store.has("dial"):
		store["dial"].set_meta("snap_angle", -1.0)

func _on_offset_spin_changed(_v, prefix: String) -> void:
	if _syncing:
		return
	var store = _store(prefix)
	var angle = store["angle_spin"].value
	var dist = store["dist_spin"].value
	var dial = store.get("dial")
	if dial != null and (dial.get_meta("snap_angle") as float) >= 0.0:
		var sr = deg2rad(dial.get_meta("snap_angle") as float)
		var expected = fposmod(rad2deg(atan2(cos(sr), -sin(sr))), 360.0)
		if abs(angle - round(expected)) > 0.5:
			_deactivate_snaps(store)
	_set_dial(store, angle, dist)
	_after_change(prefix, false, ["sun_angle", "offset_dist"])

# Sets spins + handle from an (ox, oy) offset (shadow direction).
func _set_dial_from_xy(store: Dictionary, ox: float, oy: float) -> void:
	var dist = sqrt(ox * ox + oy * oy)
	var angle = 0.0
	if dist > 0.5:
		angle = fposmod(rad2deg(atan2(-ox, oy)), 360.0)
	_set_dial(store, round(angle), round(dist))

# Sets spins + handle from (sun angle, distance).
func _set_dial(store: Dictionary, angle: float, dist: float) -> void:
	if not store.has("dial"):
		return
	var was = _syncing
	_syncing = true
	store["angle_spin"].value = angle
	store["dist_spin"].value = dist
	var off = _offset_from_angle(angle, dist)
	var radius = DIAL_SIZE / 2.0
	# Handle position is linear in the VALUE (mouse -> value is quadratic), so
	# the handle slows down toward the center, like the other tools' dials.
	var frac = clamp(dist / OFFSET_MAX, 0.0, 1.0)
	var direction = Vector2(-off.x, -off.y).normalized() if dist > 0.5 else Vector2.ZERO
	var p = Vector2(radius, radius) + direction * frac * radius
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
	c.name = "DropShadowPatternsContainer"
	ui["container"] = c
	c.add_child(HSeparator.new())

	var trow = HBoxContainer.new()
	var icon = _create_cloud_icon()
	if icon != null:
		trow.add_child(icon)
	var title = Label.new()
	title.text = "Soft Shadow"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trow.add_child(title)
	var enable = CheckButton.new()
	enable.pressed = false
	enable.focus_mode = Control.FOCUS_NONE
	enable.connect("toggled", self, "_on_enable_toggled", ["sel"])
	trow.add_child(enable)
	ui["enable"] = enable
	c.add_child(trow)

	var sp = VBoxContainer.new()
	sp.name = "SoftShadowSettings"
	sp.visible = false
	ui["panel"] = sp
	_build_settings(sp, ui, "sel")
	c.add_child(sp)

func on_selection_changed() -> void:
	_monitored = null
	if not ui.has("container"):
		return
	var sel = global.Editor.Tools["SelectTool"].Selected
	if sel.size() > 0 and is_pattern(sel[0]):
		var c = ui["container"]
		if c.get_parent() != ui["_parent"]:
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			ui["_parent"].add_child(c)
		_monitored = sel[0]
		_update_shadow_layer_ui_max()
		_store_from_cfg(ui, _saved_or_default_cfg(_node_id(sel[0])))
		refresh_overlay_link_ui()
		return
	var c = ui["container"]
	if c.get_parent() != null:
		c.get_parent().remove_child(c)

#########################################################################################################
## UI — PATTERN TOOL
#########################################################################################################

func build_pattern_tool_ui() -> void:
	var panel = global.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if panel == null:
		outputlog("PatternShapeTool panel not found", 1)
		return
	var vbox = core.get_align_vbox(panel)
	if vbox == null:
		outputlog("PatternShapeTool Align VBox not found", 1)
		return

	var c = VBoxContainer.new()
	c.name = "DropShadowPatternTool"
	var sep = HSeparator.new()
	sep.add_constant_override("separation", 4)
	c.add_child(sep)

	var trow = HBoxContainer.new()
	var icon = _create_cloud_icon()
	if icon != null:
		trow.add_child(icon)
	var title = Label.new()
	title.text = "Soft Shadow"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trow.add_child(title)
	var enable = CheckButton.new()
	enable.hint_tooltip = "Apply a soft shadow to newly drawn patterns"
	enable.focus_mode = Control.FOCUS_NONE
	enable.connect("toggled", self, "_on_enable_toggled", ["pt"])
	trow.add_child(enable)
	pt_ui["enable"] = enable
	c.add_child(trow)

	var sp = VBoxContainer.new()
	sp.visible = false
	pt_ui["panel"] = sp
	_build_settings(sp, pt_ui, "pt")
	c.add_child(sp)
	vbox.add_child(c)

	# Restore last tool settings for this map
	if global.ModMapData.has(TOOL_DEFAULTS_KEY):
		var cfg = DEFAULTS.duplicate(true)
		for k in global.ModMapData[TOOL_DEFAULTS_KEY].keys():
			cfg[k] = global.ModMapData[TOOL_DEFAULTS_KEY][k]
		_store_from_cfg(pt_ui, cfg)

func get_pattern_tool_config() -> Dictionary:
	return _cfg_from_store(pt_ui)

func _save_pattern_tool_defaults() -> void:
	var cfg = get_pattern_tool_config()
	cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
	global.ModMapData[TOOL_DEFAULTS_KEY] = cfg

#########################################################################################################
## UI — HANDLERS (routed by prefix)
#########################################################################################################

func _after_change(prefix: String, force_all: bool, changed_keys: Array) -> void:
	if prefix == "pt":
		_save_pattern_tool_defaults()
		# The overlay section of the Pattern Tool mirrors this dial when linked.
		if core != null:
			var ov = core.get("overlay_shadow_patterns")
			if ov != null and ov.has_method("on_soft_tool_changed"):
				ov.on_soft_tool_changed(get_pattern_tool_config())
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

# Select Tool slider/spin max = the monitored pattern's own layer (the shadow
# can't go above it). Other selected patterns are clamped individually.
func _update_shadow_layer_ui_max() -> void:
	var mx = LAYER_MAX
	if _monitored != null and is_instance_valid(_monitored):
		mx = int(clamp(get_pattern_layer(_monitored), LAYER_MIN, LAYER_MAX))
	var prev = _syncing
	_syncing = true
	ui["shadow_layer_slider"].max_value = mx
	ui["shadow_layer_spin"].max_value = mx
	_syncing = prev

func _set_layer_ui_value(store: Dictionary, value: int) -> void:
	var prev = _syncing
	_syncing = true
	var v = int(clamp(value, LAYER_MIN, LAYER_MAX))
	store["shadow_layer_slider"].value = v
	store["shadow_layer_spin"].value = v
	_syncing = prev

func _on_behind_layer_toggled(_pressed, prefix: String) -> void:
	if _syncing:
		return
	_after_change(prefix, false, ["behind_layer"])

func _on_custom_layer_toggled(pressed, prefix: String) -> void:
	var store = _store(prefix)
	store["layer_row"].visible = pressed and prefix != "pt"
	store["behind_row"].visible = (not pressed) and prefix != "pt"
	if _syncing:
		return
	# First enable: start from the pattern's own layer so nothing visibly moves.
	if prefix == "sel":
		_update_shadow_layer_ui_max()
		if pressed and _monitored != null and is_instance_valid(_monitored):
			_set_layer_ui_value(store, get_pattern_layer(_monitored))
	_after_change(prefix, false, ["custom_layer", "shadow_layer"])

func _on_layer_reset(prefix: String) -> void:
	var store = _store(prefix)
	if prefix == "sel":
		# Each selected pattern goes back to its OWN layer, not the monitored one's.
		_update_shadow_layer_ui_max()
		if _monitored != null and is_instance_valid(_monitored):
			_set_layer_ui_value(store, get_pattern_layer(_monitored))
		_layer_reset_pending = true
		_after_change(prefix, false, ["shadow_layer"])
		_layer_reset_pending = false
		return
	var layer = 0
	if _pattern_tool != null and _pattern_tool.get("ActiveLayer") != null:
		layer = int(_pattern_tool.get("ActiveLayer"))
	_set_layer_ui_value(store, layer)
	_after_change(prefix, false, ["shadow_layer"])

func _set_mode_buttons(store: Dictionary, idx: int) -> void:
	for i in range(2):
		var b = store.get("mode_btn_" + str(i))
		if b == null:
			continue
		b.pressed = (i == idx)
		b.icon = b.get_icon("radio_checked" if i == idx else "radio_unchecked", "CheckBox")

func _on_mode_pressed(idx: int, prefix: String) -> void:
	var store = _store(prefix)
	_set_mode_buttons(store, idx)
	if _syncing:
		return
	_after_change(prefix, false, ["render_mode"])

# ── Global "Simple Sliders" style (owned by LevelSettingsPatch) ─────────
func _simple_blur_style_enabled() -> bool:
	if core != null:
		var lsp = core.get("level_settings_patch")
		if lsp != null and lsp.has_method("is_simple_blur_style"):
			return lsp.is_simple_blur_style()
	return false

func _update_size_rows(store: Dictionary) -> void:
	if not store.has("spread_row"):
		return
	var blur = _simple_blur_style_enabled()
	store["spread_row"].visible = not blur
	store["softness_row"].visible = not blur
	store["simple_blur_row"].visible = blur

# Called by LevelSettingsPatch when the style changes: swap the rows. No
# rebuild — each shadow keeps its authored style until re-edited.
func on_simple_slider_style_changed() -> void:
	_update_size_rows(ui)
	_update_size_rows(pt_ui)

func _on_color(_c, prefix: String) -> void:
	if _syncing:
		return
	_after_change(prefix, false, ["shadow_color"])

func _on_single_reset(key, prefix: String) -> void:
	var store = _store(prefix)
	_syncing = true
	if key == "shadow_color":
		store["color"].color = DEFAULTS["shadow_color"]
	elif key == "offset":
		_set_dial(store, DEFAULTS["sun_angle"], DEFAULTS["offset_dist"])
		_syncing = false
		_after_change(prefix, false, ["sun_angle", "offset_dist"])
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
	_history_touch("pattern_shadow" if changed_keys.empty() else str(changed_keys[0]))
	var ui_cfg = _cfg_from_store(ui)
	# The slider style only switches when a SIZE slider is touched (or on a
	# full reset / paste); other edits keep the shadow's authored style.
	var size_touched = changed_keys.empty()
	for k in changed_keys:
		if k in ["spread", "softness", "simple_blur"]:
			size_touched = true
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_pattern(node):
			continue
		var nid = _node_id(node)
		var cfg: Dictionary
		if node == _monitored:
			cfg = ui_cfg.duplicate(true)
			if not size_touched:
				var prev = _saved_cfg(nid)
				if prev != null:
					cfg["slider_style"] = int(prev.get("slider_style", 0))
		elif force_all:
			# Enable toggle: keep the node's own settings, only override "enabled".
			cfg = _saved_or_default_cfg(nid)
			cfg["enabled"] = ui_cfg["enabled"]
		elif changed_keys.size() > 0:
			# Per-parameter edit: only nodes that already have a shadow.
			cfg = _saved_or_default_cfg(nid)
			if not cfg.get("enabled", false):
				continue
			for key in changed_keys:
				if ui_cfg.has(key):
					cfg[key] = ui_cfg[key]
			# A size slider also stamps the current Blur Control style,
			# otherwise a shadow authored in the other style ignores it.
			if size_touched and ui_cfg.has("slider_style"):
				cfg["slider_style"] = ui_cfg["slider_style"]
		else:
			cfg = ui_cfg
		if _layer_reset_pending and cfg.get("custom_layer", false):
			cfg["shadow_layer"] = get_pattern_layer(node)
		if cfg.get("custom_layer", false):
			# Never above the pattern: write the clamped value back (per node).
			cfg["shadow_layer"] = effective_shadow_layer(node, cfg)
		if cfg["enabled"]:
			create_shadow(node, cfg)
		else:
			remove_shadow(node)
		save_data(node, cfg)
	# Linked overlay dials / shadows follow immediately (no monitor delay).
	if core != null:
		var ov = core.get("overlay_shadow_patterns")
		if ov != null and ov.has_method("on_soft_shadow_changed"):
			ov.on_soft_shadow_changed(global.Editor.Tools["SelectTool"].Selected)
	# Reflect the clamped value of the primary node in the UI.
	if _monitored != null and is_instance_valid(_monitored) and ui_cfg.get("custom_layer", false):
		var eff = effective_shadow_layer(_monitored, ui_cfg)
		if int(ui["shadow_layer_spin"].value) != eff:
			_syncing = true
			ui["shadow_layer_slider"].value = eff
			ui["shadow_layer_spin"].value = eff
			_syncing = false

#########################################################################################################
## BULK ENABLE API (SelectionShadowToggle) — no dependency on this module's UI state
#########################################################################################################

func has_shadow_enabled(node) -> bool:
	if not is_pattern(node):
		return false
	var cfg = _saved_cfg(_node_id(node))
	return cfg != null and cfg.get("enabled", false)

func set_shadow_enabled(nodes, enabled: bool) -> void:
	var targets = []
	for node in nodes:
		if is_pattern(node) and not targets.has(node):
			targets.append(node)
	if targets.empty():
		return
	_history_touch("enabled")
	for node in targets:
		var nid = _node_id(node)
		var cfg = _saved_cfg(nid)
		if cfg == null:
			cfg = get_pattern_tool_config()
		cfg["enabled"] = enabled
		if cfg.get("custom_layer", false):
			cfg["shadow_layer"] = effective_shadow_layer(node, cfg)
		if enabled:
			create_shadow(node, cfg)
		else:
			remove_shadow(node)
		save_data(node, cfg)

#########################################################################################################
## OFFSET API (GlobalIllumination) — patterns store sun_angle + offset_dist
#########################################################################################################

func get_shadow_offset(node):
	if not has_shadow_enabled(node):
		return null
	var cfg = _saved_cfg(_node_id(node))
	var off = _offset_from_angle(float(cfg.get("sun_angle", 0.0)), float(cfg.get("offset_dist", 0.0)))
	return [round(off.x), round(off.y)]

# Style tag for Global Illumination: a mode switch is not a hand edit.
func get_shadow_style(node):
	if not has_shadow_enabled(node):
		return null
	return _saved_cfg(_node_id(node)).get("render_mode", "simple")

func set_shadow_offset(node, ox: float, oy: float) -> void:
	if not has_shadow_enabled(node):
		return
	var cfg = _saved_cfg(_node_id(node))
	var dist = min(sqrt(ox * ox + oy * oy), OFFSET_MAX)
	if dist > 0.5:
		cfg["sun_angle"] = round(fposmod(rad2deg(atan2(-ox, oy)), 360.0))
	cfg["offset_dist"] = round(dist)
	create_shadow(node, cfg)
	save_data(node, cfg)
	if node == _monitored:
		_store_from_cfg(ui, cfg)
	if core != null:
		var ov = core.get("overlay_shadow_patterns")
		if ov != null and ov.has_method("on_soft_shadow_changed"):
			ov.on_soft_shadow_changed([node])

#########################################################################################################
## OVERLAY LINK (OverlayShadowPatterns) — shared Link button + two-way sun
#########################################################################################################
# When the overlay shadow is linked, both dials show ONE sun: moving this dial
# moves the overlay (on_soft_shadow_changed), and moving the overlay dial moves
# this one (overlay_drive_sun). The link flag lives in the overlay's config;
# the button beside our dial only mirrors it.

var _overlay_link_syncing = false

func _overlay_module():
	return core.get("overlay_shadow_patterns") if core != null else null

# Shows the Link button only when the shown pattern has an overlay shadow, and
# mirrors its link state. Called on selection and by the overlay module.
func refresh_overlay_link_ui() -> void:
	if not ui.has("overlay_link_btn"):
		return
	var state = null
	var ov = _overlay_module()
	if ov != null and ov.has_method("get_link_state") and _monitored != null and is_instance_valid(_monitored):
		state = ov.get_link_state(_monitored)
	_overlay_link_syncing = true
	ui["overlay_link_btn"].visible = state != null
	ui["overlay_link_btn"].pressed = (state == true)
	_overlay_link_syncing = false

func _on_overlay_link_toggled(pressed) -> void:
	if _overlay_link_syncing:
		return
	var ov = _overlay_module()
	if ov != null and ov.has_method("set_link_from_soft"):
		ov.set_link_from_soft(pressed)
	refresh_overlay_link_ui()

# The linked overlay dial moved: set our dial to (world sun angle, strength
# 0..1 = distance / OFFSET_MAX) and apply, exactly as if the user had dragged
# it (history, multi-selection). Returns false when there is nothing to drive.
func overlay_drive_sun(node, sun_world_deg: float, strength: float) -> bool:
	if node == null or node != _monitored or not has_shadow_enabled(node) or not ui.has("dial"):
		return false
	_deactivate_snaps(ui)
	# Dial convention: offset = (-sin a, cos a), sun = -offset -> a = world + 90.
	_set_dial(ui, round(fposmod(sun_world_deg + 90.0, 360.0)), round(clamp(strength, 0.0, 1.0) * OFFSET_MAX))
	_after_change("sel", false, ["sun_angle", "offset_dist"])
	return true

#########################################################################################################
## PRESETS (lib/ShadowPresets.gd) — adapter
#########################################################################################################

var _presets = null

func _init_presets() -> void:
	var script = ResourceLoader.load(global.Root + "lib/ShadowPresets.gd", "GDScript", true)
	if script == null:
		outputlog("lib/ShadowPresets.gd not found — presets disabled", 0)
		return
	_presets = script.new()
	_presets.global = global
	_presets.module = self
	_presets.type_name = "patterns"
	var sel_panel = ui.get("panel")
	if sel_panel != null:
		_presets.build_row(sel_panel, "select")
		sel_panel.move_child(_presets._rows["select"]["row"], 0)
	var tool_panel = pt_ui.get("panel")
	if tool_panel != null:
		_presets.build_row(tool_panel, "tool")
		tool_panel.move_child(_presets._rows["tool"]["row"], 0)


func preset_selected_ids() -> Array:
	var out = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_pattern(node):
			out.append(_node_id(node))
	return out

func preset_exclude_keys() -> Array:
	return ["enabled", "custom_layer", "shadow_layer"]

func preset_offset_keys() -> Array:
	return ["sun_angle", "offset_dist"]

func preset_get_config(scope: String):
	if scope == "select":
		return _cfg_from_store(ui) if ui.has("enable") else null
	return get_pattern_tool_config() if pt_ui.has("enable") else null

func preset_snapshot(scope: String):
	if scope != "select":
		return {"__tool": get_pattern_tool_config()} if pt_ui.has("enable") else null
	var snap = {}
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_pattern(node):
			var nid = _node_id(node)
			var cfg = _saved_cfg(nid)
			snap[nid] = cfg.duplicate(true) if cfg != null else null
	return snap

func preset_restore(scope: String, snap: Dictionary) -> void:
	if scope != "select":
		var t = snap.get("__tool")
		if t is Dictionary and pt_ui.has("enable"):
			var tcfg = get_pattern_tool_config()
			for k in t.keys():
				tcfg[k] = t[k]
			_store_from_cfg(pt_ui, tcfg)
			_save_pattern_tool_defaults()
		return
	_history_touch("preset")
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_pattern(node):
			continue
		var nid = _node_id(node)
		if not snap.has(nid):
			continue
		var cfg = snap[nid]
		if cfg is Dictionary:
			cfg = cfg.duplicate(true)
			if cfg.get("shadow_color") is String:
				cfg["shadow_color"] = Color(cfg["shadow_color"])
		else:
			cfg = get_pattern_tool_config()
		cfg["enabled"] = true
		if cfg.get("custom_layer", false):
			cfg["shadow_layer"] = effective_shadow_layer(node, cfg)
		create_shadow(node, cfg)
		save_data(node, cfg)
	on_selection_changed()

func preset_apply(scope: String, preset: Dictionary) -> void:
	if scope != "select":
		var tcfg = get_pattern_tool_config()
		for k in preset.keys():
			tcfg[k] = preset[k]
		_store_from_cfg(pt_ui, tcfg)
		_save_pattern_tool_defaults()
		return
	var targets = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_pattern(node) and not targets.has(node):
			targets.append(node)
	if targets.empty():
		return
	_history_touch("preset")
	for node in targets:
		var nid = _node_id(node)
		var cfg = _saved_cfg(nid)
		if cfg == null:
			cfg = get_pattern_tool_config()
		for k in preset.keys():
			cfg[k] = preset[k]
		cfg["enabled"] = true
		if cfg.get("custom_layer", false):
			cfg["shadow_layer"] = effective_shadow_layer(node, cfg)
		create_shadow(node, cfg)
		save_data(node, cfg)
	on_selection_changed()

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

# Restores a snapshot {node_id: cfg} (undo AND redo).
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
