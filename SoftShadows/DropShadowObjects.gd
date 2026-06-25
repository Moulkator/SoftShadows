#########################################################################################################
##
## DROP SHADOW FOR OBJECTS
##
#########################################################################################################
# Version 1.0.0
# class_name DropShadowObjects

var global
var reference_to_script = null
var core = null

# References to paths/walls modules for clipping
var dropshadow_paths = null
var dropshadow_walls = null
var dropshadow_roofs = null

# UI references
var ui_config = {}

# Constants
const SHADOW_META_KEY = "drop_shadow_obj_nodes"
const SHADOW_DATA_KEY = "DropShadow"

# Shape (projected) mode: paintable height-zone grid + mesh subdivision.
const SHAPE_GRID = 12        # editor cells per axis (paint HIGH/LOW)
const SHAPE_MESH_SUBDIV = 24 # mesh quads per axis (silhouette warp resolution)
const PROJ_MAX_LENGTH = 1.5  # max projection length (dial radius -> length)

# Global bake-mode (objects-only). Persisted in ModMapData by LevelSettingsPatch,
# read here to gate the auto-bake debounce. Default AUTO preserves prior behaviour.
#   LIVE   = never auto-bake (shadows stay shader sprites)
#   AUTO   = debounced auto-bake on create/change (the original formula)
#   MANUAL = like LIVE for auto-triggers; baking only via the manual button
const BAKE_MODE_KEY = "DropShadowBakeMode"
const BAKE_MODE_LIVE = 0
const BAKE_MODE_AUTO = 1
const BAKE_MODE_MANUAL = 2
# ModMapData key for the quality-broadcast persistence (toggle state + snapshot
# of pre-broadcast quality values). Survives map save/load and DD restart.
const BROADCAST_DATA_KEY = "DropShadowQualityBroadcast"

# --- Projected-shadow quad sizing & extrude optimisation (tunable) ---
# Max half-extent (px from center) a projected shadow quad is allowed to reach on
# each LOCAL axis. Caps fragment count / bake viewport for very long shadows; the
# tip truncates beyond this. 2048 px ≈ 8 tiles at 256 px/tile.
const MAX_PROJ_HALF_PX = 2048.0
# Extrude sweep: target spacing between sweep samples (px). Smaller = smoother but
# more samples. Steps are derived from sweep length / this, then clamped below.
const EXTRUDE_STEP_TARGET_PX = 8.0
const EXTRUDE_STEPS_MIN = 8
const EXTRUDE_STEPS_MAX = 40
# In extrude mode the directional sweep already fills the body, so the per-fragment
# ring blur (which multiplies the sweep cost) is capped lower than in offset/stretch
# mode. Raise these if extrude edges look too hard.
const EXTRUDE_BLUR_QUALITY_MAX = 4
const EXTRUDE_BLUR_STEPS_MAX = 10

# ModMapData key for the quality lock toggle (true = slider snaps to tier values
# 25/50/75/100, false = free fine-tune 0..100). Default true.
const LOCK_STATE_KEY = "DropShadowQualityLock"
# Container at the Level for "behind layer" shadows (sits before Objects in scene
# tree so it renders below). Same pattern as DropShadowWalls' BELOW_ALL_CONTAINER_NAME.
# This is needed because Dungeondraft's export pipeline ignores absolute z_index
# tricks on Sprites parented to Props — only physical scene-tree position works.
const BELOW_LAYER_CONTAINER_NAME = "DropShadowObjBelowLayer"

const FACTORY_DEFAULTS = {
	"enabled": false,
	"opacity": 0.5,
	"blur": 0.2,
	"offset_x": 0.0,
	"offset_y": 0.0,
	"range": 1.0,
	"behind_layer": false,
	"shadow_color": Color(0, 0, 0, 1),
	"clip_walls": false,
	"clip_paths": false,
	"snap_angle": -1.0,
	# --- Projected (cast) shadow ---
	"shadow_mode": "offset",   # "offset" | "projected"
	"proj_angle": 0.0,         # direction monde, en radians
	"proj_length": 0.0,        # intensité de l'allongement (0 = aucun)
	"proj_anchor_x": 0.0,      # ancre normalisée [-1..1]
	"proj_anchor_y": 0.0,
	"proj_taper": 0.0,         # (inutilisé en mode forme, conservé pour compat)
	"proj_fade": 0.5,          # estompe l'ombre vers la pointe (0 = plein, 1 = disparaît)
	"proj_extrude": 1.0,       # 0 = stretch (étire), 1 = extrude (balaye) — défaut
	# Mode "projected" = silhouette clonée + déformée par un champ de hauteur.
	# shape_mask: liste plate de 0/1 (SHAPE_GRID×SHAPE_GRID). 1 = HAUT (projette),
	# 0 = BAS (contact). Vide => défaut auto (moitié haute = HAUT, moitié basse = BAS).
	"shape_mask": [],
	# GPU-cost trade-off. Stored as int percentage 25/50/75/100 (4 discrete tiers:
	# Low/Medium/High/Ultra). Linearly scales the auto-computed blur_quality +
	# blur_steps shader params (samples per direction × number of directions).
	# 100 = Ultra (current behavior), 25 = Low (faster but visibly grainier).
	"quality": 100
}

var DEFAULT_SHADOW_CONFIG = FACTORY_DEFAULTS.duplicate()

# Shader
var _shadow_shader: Shader = null
var _silhouette_shader: Shader = null

# Monitoring
var _monitor_timer: Timer = null
var _monitored_object = null
var _last_monitored_object = null
var _monitored_type = ""
var _heal_counter = 0  # throttles the missing-shadow self-heal scan
var _syncing_ui = false
var _loading_ui = false  # blocks apply_shadow_to_selected during UI load
var _clipboard = {}
var _all_known_obj_ids = {}
var shadow_history = null  # set by Core; undo/redo of mod params
# ── Transaction d'historique (A2) ──────────────────────────────────────
var _history_flush_timer: Timer = null
var _history_txn_active = false
var _history_txn_before = {}   # {node_id: config complet} capturé au début du geste
var _history_txn_label = ""
var _history_suspend = false   # true pendant une restauration (évite de ré-enregistrer)
var _native_pos_by_id = {}     # node_id -> dernière position connue (détection move natif)
var _native_detect_ready = false  # armé après le chargement (évite les faux marqueurs)
var _native_arm_count = 0
var _copy_source_ids = []  # IDs saved on Ctrl+C
var _paste_pending = false  # set on Ctrl+V, cleared after processing
var _paste_just_processed = false  # skip UI load for 1 tick after paste
var _pending_signal_nodes = []  # nodes from OnAssignNode to check
var _ctrl_v_was_pressed = false  # anti-bounce for key detection
var _ctrl_c_was_pressed = false
var _clone_batch = []  # nodes detected as new in current tick
var _opaque_center_cache = {}  # texture RID -> Vector2 offset (in texture pixels)

# Logging
const ENABLE_LOGGING = true
var logging_level = 0

func outputlog(msg, level=0):
	if ENABLE_LOGGING:
		if level <= logging_level:
			printraw("(%d) <DropShadowObjects>: " % OS.get_ticks_msec())
			print(msg)

# --- CLIP DIAGNOSTIC (temporary) ---
var CLIP_DEBUG := true
var _clip_dbg_last := {}

func _clip_dbg(tag, obj, a, b):
	if not CLIP_DEBUG:
		return
	if obj == null or obj != _monitored_object:
		return
	var line = "%s polylines=%d defs=%d" % [tag, a, b]
	if _clip_dbg_last.get(tag, "") == line:
		return
	_clip_dbg_last[tag] = line
	printraw("(%d) <DSObjects CLIP-DIAG>: " % OS.get_ticks_msec())
	print(line)

func set_property_but_block_signals(obj: Object, property: String, value):
	obj.set_block_signals(true)
	obj.set(property, value)
	obj.set_block_signals(false)

#########################################################################################################
##
## INITIALISATION
##
#########################################################################################################
var _bake_debounce = null
var _baker_script = null

func initialise() -> void:
	outputlog("Drop Shadow Objects initialising...")
	printraw("(%d) " % OS.get_ticks_msec())
	print("[BUILD: DropShadowObjects clip-diag 2026-06-22 #1]")

	# Load the shader
	_shadow_shader = ResourceLoader.load(global.Root + "shaders/DropShadowObject.shader", "Shader", true)
	if _shadow_shader == null:
		outputlog("ERROR: Could not load DropShadowObject.shader", 0)
		return
	
	# ...after _shadow_shader load...
	_baker_script = load(global.Root + "ShadowBaker.gd")  # adjust path
	_bake_debounce = _baker_script.DebounceManager.new(self, SHADOW_META_KEY, _baker_script)

	# Silhouette shader (shape/projected mode). Built in-memory so there's no extra
	# file to ship. Outputs the asset's alpha as a flat shadow colour; a small
	# ring blur (clamped to the sprite's atlas region, so it never samples
	# neighbouring atlas sprites) softens the edge.
	_silhouette_shader = Shader.new()
	_silhouette_shader.code = """
shader_type canvas_item;
uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float opacity = 0.5;
uniform float blur_px = 0.0;
uniform vec2 uv_min = vec2(0.0);
uniform vec2 uv_max = vec2(1.0);
void fragment() {
	vec2 base = clamp(UV, uv_min, uv_max);
	float total = texture(TEXTURE, base).a;
	float wsum = 1.0;
	if (blur_px > 0.01) {
		vec2 r = blur_px * TEXTURE_PIXEL_SIZE;
		for (int i = 0; i < 12; i++) {
			float ang = 6.28318 * float(i) / 12.0;
			vec2 d = vec2(cos(ang), sin(ang)) * r;
			total += texture(TEXTURE, clamp(UV + d, uv_min, uv_max)).a;
			wsum += 1.0;
		}
	}
	float a = (total / wsum) * opacity;
	COLOR = vec4(shadow_color.rgb, clamp(a, 0.0, 1.0));
}
"""

	build_select_tool_ui()
	build_object_tool_ui()

	# Set up monitoring timer
	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.01
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)

	# Timer de debounce pour regrouper un geste en une seule entrée d'historique.
	_history_flush_timer = Timer.new()
	_history_flush_timer.wait_time = 0.4
	_history_flush_timer.one_shot = true
	_history_flush_timer.connect("timeout", self, "_history_flush")
	global.Editor.add_child(_history_flush_timer)
	# S'enregistrer pour un flush forcé juste avant un Ctrl+Z/Ctrl+Y.
	if shadow_history != null and shadow_history.has_method("register_flusher"):
		shadow_history.register_flusher(self, "_history_flush")

	# Sync shadow positions every frame right before rendering (no 1-tick lag)
	VisualServer.connect("frame_pre_draw", self, "_on_frame_pre_draw")

	# Connect to world signal to detect newly placed objects (for ObjectTool toggle)
	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "_on_new_node_added")

	outputlog("Drop Shadow Objects initialised. [BUILD: proj-live-peraxis]", 0)


#########################################################################################################
##
## NODE TYPE DETECTION
##
#########################################################################################################

func is_shadow_node_type(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	# Objects in Dungeondraft are under the Objects container
	if not node.has_meta("node_id"):
		return false
	var parent = node.get_parent()
	if parent == null:
		return false
	# Check if it's an object or roof
	if parent.name == "Objects" or parent.name == "Roofs":
		return true
	return false

func get_node_type(_node) -> String:
	return "objects"

func get_sprite(obj) -> Sprite:
	# Objects in DD have a .Sprite property (Prop nodes)
	if obj.get("Sprite") != null and obj.Sprite is Sprite:
		return obj.Sprite
	if obj is Sprite:
		return obj
	for i in range(obj.get_child_count()):
		var child = obj.get_child(i)
		if child is Sprite and child.texture != null:
			if child.name.begins_with("DropShadow"):
				continue
			return child
	return null

#########################################################################################################
##
## OPAQUE CENTER
##
#########################################################################################################

func _get_opaque_center_offset(sprite) -> Vector2:
	"""Returns offset from texture center to center of opaque pixels, in texture pixel coords."""
	if sprite == null or sprite.texture == null:
		return Vector2.ZERO
	var tex = sprite.texture
	var cache_key = str(tex.get_rid().get_id())
	if _opaque_center_cache.has(cache_key):
		return _opaque_center_cache[cache_key]

	var img = null

	# Try different methods to get image data
	if tex is AtlasTexture:
		var atlas = tex.atlas
		if atlas != null:
			img = atlas.get_data()
	elif tex is LargeTexture:
		_opaque_center_cache[cache_key] = Vector2.ZERO
		return Vector2.ZERO
	else:
		img = tex.get_data()

	if img == null:
		outputlog("_get_opaque_center_offset: get_data() returned null for " + str(tex.resource_path), 0)
		_opaque_center_cache[cache_key] = Vector2.ZERO
		return Vector2.ZERO

	if img.is_empty():
		outputlog("_get_opaque_center_offset: image is empty for " + str(tex.resource_path), 0)
		_opaque_center_cache[cache_key] = Vector2.ZERO
		return Vector2.ZERO

	img.lock()
	var w = img.get_width()
	var h = img.get_height()

	# For AtlasTexture, only scan the region
	var scan_x0 = 0
	var scan_y0 = 0
	var scan_x1 = w
	var scan_y1 = h
	if tex is AtlasTexture:
		var region = tex.region
		scan_x0 = int(region.position.x)
		scan_y0 = int(region.position.y)
		scan_x1 = int(region.position.x + region.size.x)
		scan_y1 = int(region.position.y + region.size.y)
		w = int(region.size.x)
		h = int(region.size.y)

	var min_x = scan_x1
	var min_y = scan_y1
	var max_x = scan_x0
	var max_y = scan_y0
	var stride = 1
	if w * h > 65536:
		stride = 2
	if w * h > 262144:
		stride = 4
	for y in range(scan_y0, scan_y1, stride):
		for x in range(scan_x0, scan_x1, stride):
			if img.get_pixel(x, y).a > 0.1:
				if x < min_x: min_x = x
				if x > max_x: max_x = x
				if y < min_y: min_y = y
				if y > max_y: max_y = y
	img.unlock()

	if max_x < min_x:
		outputlog("_get_opaque_center_offset: fully transparent texture", 0)
		_opaque_center_cache[cache_key] = Vector2.ZERO
		return Vector2.ZERO

	var opaque_center = Vector2((min_x + max_x) / 2.0, (min_y + max_y) / 2.0)
	var tex_center = Vector2(scan_x0 + w / 2.0, scan_y0 + h / 2.0)
	var result = opaque_center - tex_center
	_opaque_center_cache[cache_key] = result
	outputlog("Opaque center offset: " + str(result) + " (tex " + str(w) + "x" + str(h) + ", opaque bounds " + str(min_x - scan_x0) + "," + str(min_y - scan_y0) + " -> " + str(max_x - scan_x0) + "," + str(max_y - scan_y0) + ")", 0)
	return result

#########################################################################################################
##
## SHADOW CREATION / REMOVAL
##
#########################################################################################################

func _compute_world_offset(config: Dictionary) -> Vector2:
	"""Compute the world-space pixel offset from config offset_x/y."""
	return Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))

func _world_to_local_offset(obj, offset: Vector2) -> Vector2:
	"""Convert a world-space offset to obj-local space, accounting for rotation AND mirror (scale)."""
	return obj.global_transform.affine_inverse().basis_xform(offset)

func _apply_projection_params(mat: ShaderMaterial, obj, config: Dictionary, sprite, tex_size: Vector2) -> void:
	"""Push the projected-shadow params to the shader (no-op in offset mode).
	Projection is done per-fragment now, so anchor/dir live in texture px space."""
	if config.get("shadow_mode", "offset") != "projected":
		mat.set_shader_param("proj_enabled", 0.0)
		mat.set_shader_param("proj_extrude", 0.0)
		mat.set_shader_param("proj_length", 0.0)
		return
	# Direction monde -> locale (suit la lumière, pas la rotation/miroir de l'asset)
	var ang = config.get("proj_angle", 0.0)
	var world_dir = Vector2(cos(ang), sin(ang))
	var local_dir = obj.global_transform.affine_inverse().basis_xform(world_dir)
	local_dir = local_dir.normalized() if local_dir.length() > 0.0001 else Vector2(0.0, 1.0)
	# Ancre normalisée [-1..1] -> px relatifs au centre texture (uv 0.5 = centre)
	var anchor_px = Vector2(
		config.get("proj_anchor_x", 0.0) * tex_size.x * 0.5,
		config.get("proj_anchor_y", 0.0) * tex_size.y * 0.5
	)
	mat.set_shader_param("proj_enabled", 1.0)
	mat.set_shader_param("proj_dir", local_dir)
	mat.set_shader_param("proj_length", config.get("proj_length", 0.0))
	mat.set_shader_param("proj_anchor", anchor_px)
	mat.set_shader_param("proj_taper", config.get("proj_taper", 0.0))
	mat.set_shader_param("proj_tex_size", tex_size)
	mat.set_shader_param("proj_fade", config.get("proj_fade", 0.0))
	mat.set_shader_param("proj_extrude", config.get("proj_extrude", 0.0))

#########################################################################################################
##
## SHAPE SHADOW — mode "projected": silhouette clonée + déformée par hauteur
##
#########################################################################################################

func _default_shape_mask() -> Array:
	"""Default height field: top half of the asset = HIGH (projects), bottom
	half = LOW (stays in contact). Flat array, SHAPE_GRID×SHAPE_GRID, row-major
	(row 0 = top of the texture)."""
	var m = []
	for row in range(SHAPE_GRID):
		var hi = 1.0 if row < SHAPE_GRID / 2 else 0.0
		for col in range(SHAPE_GRID):
			m.append(hi)
	return m

func _sample_mask(mask: Array, u: float, v: float) -> float:
	"""Bilinear sample of the SHAPE_GRID mask at UV (u,v) in [0,1]."""
	if mask == null or mask.size() != SHAPE_GRID * SHAPE_GRID:
		return 0.0
	var fx = clamp(u, 0.0, 1.0) * float(SHAPE_GRID - 1)
	var fy = clamp(v, 0.0, 1.0) * float(SHAPE_GRID - 1)
	var x0 = int(floor(fx))
	var y0 = int(floor(fy))
	var x1 = min(x0 + 1, SHAPE_GRID - 1)
	var y1 = min(y0 + 1, SHAPE_GRID - 1)
	var tx = fx - float(x0)
	var ty = fy - float(y0)
	var a = float(mask[y0 * SHAPE_GRID + x0])
	var b = float(mask[y0 * SHAPE_GRID + x1])
	var c = float(mask[y1 * SHAPE_GRID + x0])
	var d = float(mask[y1 * SHAPE_GRID + x1])
	var top = a + (b - a) * tx
	var bot = c + (d - c) * tx
	return top + (bot - top) * ty

func _atlas_uv_info(sprite) -> Dictionary:
	"""Returns the atlas texture to sample + UV origin/scale mapping a [0,1] grid
	onto the sprite's drawn region, plus the displayed pixel size."""
	var tex = sprite.texture
	var atlas = tex
	var uv_origin = Vector2(0, 0)
	var uv_scale = Vector2(1, 1)
	var disp_size = tex.get_size()
	if sprite.region_enabled:
		var full = tex.get_size()
		uv_origin = sprite.region_rect.position / full
		uv_scale = sprite.region_rect.size / full
		disp_size = sprite.region_rect.size
	elif tex is AtlasTexture and tex.atlas != null:
		atlas = tex.atlas
		var full = atlas.get_size()
		uv_origin = tex.region.position / full
		uv_scale = tex.region.size / full
		disp_size = tex.region.size
	return {"atlas": atlas, "uv_origin": uv_origin, "uv_scale": uv_scale, "size": disp_size}

func _create_shape_shadow(obj, config: Dictionary) -> void:
	"""Clone the asset's silhouette (its alpha) onto a subdivided mesh and warp it:
	HIGH zones project along the light by length, LOW zones stay in contact."""
	if _silhouette_shader == null:
		outputlog("shape shadow: silhouette shader missing", 0)
		return
	var sprite = get_sprite(obj)
	if sprite == null or sprite.texture == null:
		return
	var info = _atlas_uv_info(sprite)
	var tex_size = info["size"]
	if tex_size.x < 1.0 or tex_size.y < 1.0:
		return

	var mask = config.get("shape_mask", [])
	if not (mask is Array) or mask.size() != SHAPE_GRID * SHAPE_GRID:
		mask = _default_shape_mask()

	# Projection vector: world direction -> local, scaled by length × texture extent
	var ang = config.get("proj_angle", 0.0)
	var length_px = config.get("proj_length", 0.0) * max(tex_size.x, tex_size.y)
	var world_dir = Vector2(cos(ang), sin(ang))
	var local_dir = obj.global_transform.affine_inverse().basis_xform(world_dir)
	local_dir = local_dir.normalized() if local_dir.length() > 0.0001 else Vector2(0.0, 1.0)
	var offset = local_dir * length_px

	# Build the warped grid mesh (positions displaced by height; original UVs).
	var N = SHAPE_MESH_SUBDIV
	var verts = PoolVector2Array()
	var uvs = PoolVector2Array()
	for j in range(N + 1):
		for i in range(N + 1):
			var u = float(i) / float(N)
			var v = float(j) / float(N)
			var base_pos = Vector2((u - 0.5) * tex_size.x, (v - 0.5) * tex_size.y)
			var h = _sample_mask(mask, u, v)
			verts.append(base_pos + offset * h)
			uvs.append(info["uv_origin"] + Vector2(u, v) * info["uv_scale"])
	var indices = PoolIntArray()
	var stride = N + 1
	for j in range(N):
		for i in range(N):
			var a = j * stride + i
			var b = a + 1
			var c = a + stride
			var d = c + 1
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(b); indices.append(d); indices.append(c)

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
	arrays[ArrayMesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var color = config.get("shadow_color", Color(0, 0, 0, 1))
	if color is String:
		color = Color(color)
	var mat = ShaderMaterial.new()
	mat.shader = _silhouette_shader
	mat.set_shader_param("shadow_color", color)
	mat.set_shader_param("opacity", float(config.get("opacity", 0.5)))
	mat.set_shader_param("blur_px", float(config.get("blur", 0.2)) * 30.0)
	mat.set_shader_param("uv_min", info["uv_origin"])
	mat.set_shader_param("uv_max", info["uv_origin"] + info["uv_scale"])

	var mi = MeshInstance2D.new()
	mi.name = "DropShadowObjShape"
	mi.mesh = mesh
	mi.texture = info["atlas"]
	mi.material = mat
	mi.position = sprite.position
	mi.scale = sprite.scale
	mi.z_as_relative = true
	mi.z_index = -1 if config.get("behind_layer", false) else 0

	obj.add_child(mi)
	obj.move_child(mi, 0)
	obj.set_meta(SHADOW_META_KEY, [mi])
	obj.set_meta("_shadow_offset", Vector2.ZERO)
	obj.set_meta("_shadow_config", config)
	save_shadow_data(obj, config)

func create_shadow(obj, config: Dictionary):
	if obj == null or not is_instance_valid(obj):
		return
	if _shadow_shader == null:
		outputlog("create_shadow: shader is null!", 0)
		return

	var sprite = get_sprite(obj)
	if sprite == null:
		# No sprite — might be a roof (polygon-based)
		if dropshadow_roofs != null and dropshadow_roofs.is_roof(obj):
			dropshadow_roofs.create_roof_shadow(obj, config)
			return
		outputlog("create_shadow: no sprite found for " + str(obj.name), 0)
		return

	remove_shadow(obj)

	var opacity_val = config.get("opacity", 0.15)
	var blur_frac = config.get("blur", 0.1)
	
	var projected = config.get("shadow_mode", "offset") == "projected"
	var offset = Vector2.ZERO if projected else _compute_world_offset(config)
	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)

	# Get texture dimensions
	var tex = sprite.texture
	var tex_size = tex.get_size()
	if sprite.region_enabled:
		tex_size = sprite.region_rect.size
	if tex_size.x < 1.0 or tex_size.y < 1.0:
		return
	

	# Blur slider 0-1 maps to larger range for softer shadows
	var effective_frac = blur_frac * 0.75

	# Spread + blur expansion
	var total_blur = effective_frac * 160.0
	var spread_val = clamp(effective_frac, 0.0, 1.0)

	# Energy compensation — minimal, just prevents shadow from vanishing at high blur
	var BASE_BLUR_PX = 2.0
	var energy_comp = pow(max(total_blur, BASE_BLUR_PX) / BASE_BLUR_PX, 0.2)
	energy_comp = clamp(energy_comp, 1.0, 1.8)

	# Cap shader blur for quality, compensate with larger vertex_scale
	var MAX_SHADER_BLUR = 90.0
	var shader_blur = min(total_blur, MAX_SHADER_BLUR)
	var blur_ratio = total_blur / max(shader_blur, 1.0)  # how much we need to expand

	# Quality - scale with blur for better results at high blur
	# `quality` (0..100, default 70) further scales sample counts to trade
	# visual fidelity for GPU cost. Total fragment samples = blur_quality * blur_steps,
	# so a 0.7 factor cuts cost by ~half. Hard floors prevent fully degenerate output.
	var quality_factor = clamp(float(config.get("quality", 100)) / 100.0, 0.0, 1.0)
	var blur_quality = max(int(clamp(shader_blur / 3.0, 4, 16) * quality_factor), 2)
	var blur_steps = max(int(clamp(shader_blur * 0.9, 16, 48) * quality_factor), 8)

	# Per-axis quad expansion: in projected mode each LOCAL axis is grown only as
	# far as the cast shadow reaches on it (so a thin asset projected across its
	# short axis gets a slim quad, not a huge square). Offset mode stays symmetric.
	var vsxy = _compute_vertex_scale_xy(obj, config, tex_size, shader_blur, blur_ratio)

	# Extrude optimisation: the directional sweep already fills the body, so cap the
	# (multiplicative) ring blur and derive the sweep step count from the length.
	var max_dim = max(tex_size.x, tex_size.y)
	var extrude_steps = 18
	if projected and float(config.get("proj_extrude", 0.0)) > 0.5:
		var sweep_px = float(config.get("proj_length", 0.0)) * max_dim
		extrude_steps = int(clamp(ceil(sweep_px / EXTRUDE_STEP_TARGET_PX), EXTRUDE_STEPS_MIN, EXTRUDE_STEPS_MAX))
		blur_quality = int(clamp(blur_quality, 2, EXTRUDE_BLUR_QUALITY_MAX))
		blur_steps = int(clamp(blur_steps, 6, EXTRUDE_BLUR_STEPS_MAX))

	# Duplicate the sprite — NO scale change ever
	var shadow_sprite = sprite.duplicate(0)
	shadow_sprite.name = "DropShadowObj"

	# Apply shader material
	var mat = ShaderMaterial.new()
	mat.shader = _shadow_shader
	mat.set_shader_param("shadow_color", shadow_color)
	mat.set_shader_param("blur_radius", shader_blur)
	mat.set_shader_param("spread", spread_val)
	mat.set_shader_param("shadow_strength", opacity_val * energy_comp)
	mat.set_shader_param("blur_quality", blur_quality)
	mat.set_shader_param("blur_steps", blur_steps)
	mat.set_shader_param("vertex_scale_xy", vsxy)
	mat.set_shader_param("extrude_steps", extrude_steps)
	_apply_projection_params(mat, obj, config, sprite, tex_size)
	shadow_sprite.material = mat

	# Store meta
	obj.set_meta("_shadow_offset", offset)
	obj.set_meta("_shadow_config", config)
	# Track the source texture so we can detect external swaps (e.g. from the
	# ChangeObjectTexture mod) and rebuild the shadow accordingly. Same RID
	# pattern used for the ObjectTool preview swap detection in _on_monitor_tick.
	if sprite.texture != null:
		obj.set_meta("_shadow_source_tex_rid", sprite.texture.get_rid())

	# Shadow is always a child of obj. behind_layer just changes its relative
	# z-index: 0 = same z bucket as the prop (visible below the prop's sprite
	# but hidden by overlapping props), -1 = one z bucket below the prop (visible
	# under all props). z_as_relative makes the effective z = parent.z + offset,
	# which DD's editor and exporter both honor. Same approach as DropshadowCore
	# and DropShadowPaths — keeping the shadow in the standard scene tree means
	# no transform sync, no orphan cleanup, no special-case for ObjectTool
	# preview, and no export breakage.
	var behind_layer = config.get("behind_layer", false)
	var local_offset = _world_to_local_offset(obj, offset)
	shadow_sprite.position = sprite.position + local_offset
	# Under-asset cut: in offset mode the shadow sprite is displaced, so tell the
	# shader where the asset alpha overlapping each fragment lives (uv + cut_offset).
	mat.set_shader_param("cut_offset", Vector2.ZERO if projected else Vector2(local_offset.x / tex_size.x, local_offset.y / tex_size.y))
	shadow_sprite.show_behind_parent = false
	shadow_sprite.z_as_relative = true
	shadow_sprite.z_index = -1 if behind_layer else 0
	obj.add_child(shadow_sprite)
	obj.move_child(shadow_sprite, 0)

	# Expand the custom rect so the shader-expanded shadow isn't clipped
	_update_custom_rect(obj, sprite, total_blur, max(vsxy.x, vsxy.y))
	# Same expansion on the shadow sprite's OWN canvas item (per-axis), so it isn't
	# culled at chunked export when the source sprite falls outside the current chunk.
	_set_shadow_sprite_custom_rect(shadow_sprite, vsxy)

	obj.set_meta(SHADOW_META_KEY, [shadow_sprite])

	# Reset clip params on the shader (in case clipping was previously enabled)
	mat.set_shader_param("poly_count", 0)

	# Apply wall/path clipping if enabled
	var clip_walls = config.get("clip_walls", false)
	var clip_paths = config.get("clip_paths", false)
	if clip_walls or clip_paths:
		_apply_clip_mask(obj, shadow_sprite, config)
	
	# Last line of create_shadow, after _apply_clip_mask:
	# Skip baking for the ObjectTool/ScatterBrush preview — the asset isn't
	# actually placed yet (user is just scrolling the asset list or moving the
	# cursor). _obj_tool_preview_node is set to `obj` just before this function
	# is called for the preview, in _on_monitor_tick.
	# Projected shadows stay LIVE: after the per-axis + extrude optimisation the
	# live shader is cheap, whereas baking a projected shadow needs a large texture
	# (long cast = big rectangle) → heavy VRAM/bandwidth at rest and fragile viewport
	# capture. Only offset shadows auto-bake.
	if config.get("shadow_mode", "offset") == "projected":
		if _bake_debounce != null:
			_bake_debounce.cancel(obj)
	elif obj != _obj_tool_preview_node and _should_auto_bake():
		_bake_debounce.schedule_bake(obj)

func _compute_vertex_scale_xy(obj, config: Dictionary, tex_size: Vector2, shader_blur: float, blur_ratio: float) -> Vector2:
	# Returns the per-axis quad expansion (local x, y). Offset mode keeps the old
	# symmetric scale. Projected mode grows each LOCAL axis only as far as the cast
	# shadow actually reaches on it, so a thin asset projected ACROSS its short axis
	# gets a slim quad instead of a huge uniform square (which both clipped on the
	# short axis and exploded the fragment count / bake viewport on the long one).
	var max_dim = max(tex_size.x, tex_size.y)
	var min_dim = min(tex_size.x, tex_size.y)
	var effective_dim = max(min_dim, max_dim * 0.25)
	var base_vs = clamp(1.0 + (shader_blur * blur_ratio * 2.5) / effective_dim + 0.5, 1.5, 8.0)
	if config.get("shadow_mode", "offset") != "projected":
		return Vector2(base_vs, base_vs)

	# Cast direction in LOCAL space (follows the light, not the asset rotation).
	var ang = config.get("proj_angle", 0.0)
	var wdir = Vector2(cos(ang), sin(ang))
	var ldir = obj.global_transform.affine_inverse().basis_xform(wdir)
	ldir = ldir.normalized() if ldir.length() > 0.0001 else Vector2(0.0, 1.0)
	var adx = abs(ldir.x)
	var ady = abs(ldir.y)

	var proj_length = float(config.get("proj_length", 0.0))
	var taper = float(config.get("proj_taper", 0.0))
	var hx = tex_size.x * 0.5
	var hy = tex_size.y * 0.5
	# Silhouette half-extents along the cast direction and perpendicular to it
	# (AABB projection of the texture half-size onto dir / perp).
	var sil_along = hx * adx + hy * ady
	var sil_perp = hx * ady + hy * adx
	# Cast geometry from center: body extends sil_along + the projection length;
	# perp width grows when taper widens the tail (taper < 0).
	var h_along = sil_along + proj_length * max_dim
	var h_perp = sil_perp * (1.0 + clamp(-taper, 0.0, 1.0))
	var blur_margin = shader_blur * blur_ratio * 1.5
	# Rotate the (h_along × h_perp) box into local axes, take AABB half-extents,
	# add the isotropic blur margin. perp = (-ldir.y, ldir.x).
	var half_x = h_along * adx + h_perp * ady + blur_margin
	var half_y = h_along * ady + h_perp * adx + blur_margin
	# Cap absolute px reach (fragment count + bake viewport). Floor at the silhouette.
	half_x = clamp(half_x, tex_size.x * 0.75, MAX_PROJ_HALF_PX)
	half_y = clamp(half_y, tex_size.y * 0.75, MAX_PROJ_HALF_PX)
	var vsx = max(2.0 * half_x / max(tex_size.x, 1.0), 1.5)
	var vsy = max(2.0 * half_y / max(tex_size.y, 1.0), 1.5)
	return Vector2(vsx, vsy)

func _update_custom_rect(obj, sprite, blur_px: float, vertex_scale: float):
	if sprite == null or sprite.texture == null:
		return
	var tex_size = sprite.texture.get_size()
	
	# Account for sprite's own scale (flat objects have small scale on one axis)
	var sprite_scale = sprite.scale.abs()
	var scaled_tex = Vector2(tex_size.x * sprite_scale.x, tex_size.y * sprite_scale.y)
	
	# The expand needs to cover the shader's vertex expansion in local space
	# vertex_scale multiplies the mesh, so the overflow beyond the original rect is:
	var expand_x = tex_size.x * sprite_scale.x * (vertex_scale - 1.0) * 0.5
	var expand_y = tex_size.y * sprite_scale.y * (vertex_scale - 1.0) * 0.5
	# Ensure minimum expansion covers the blur radius + offset
	var min_expand = max(tex_size.x, tex_size.y) * vertex_scale * 0.5
	expand_x = max(expand_x, min_expand)
	expand_y = max(expand_y, min_expand)
	
	# Also account for shadow offset
	var config = obj.get_meta("_shadow_config") if obj.has_meta("_shadow_config") else {}
	var offset_x = abs(config.get("offset_x", 0.0))
	var offset_y = abs(config.get("offset_y", 0.0))
	expand_x += offset_x
	expand_y += offset_y

	# Projected mode: shadow stretches far past the rect — expand to fit it.
	if config.get("shadow_mode", "offset") == "projected":
		var proj_extra = config.get("proj_length", 0.0) * max(scaled_tex.x, scaled_tex.y)
		expand_x += proj_extra
		expand_y += proj_extra
	
	var tex_rect = Rect2(Vector2.ZERO, scaled_tex)
	if sprite.centered:
		tex_rect.position = -scaled_tex / 2.0
	else:
		tex_rect.position = sprite.offset * sprite_scale
	var expanded = Rect2()
	expanded.position = tex_rect.position - Vector2(expand_x, expand_y)
	expanded.size = tex_rect.size + Vector2(expand_x * 2.0, expand_y * 2.0)
	VisualServer.canvas_item_set_custom_rect(obj.get_canvas_item(), true, expanded)

func _set_shadow_sprite_custom_rect(shadow_sprite, vertex_scale_xy: Vector2) -> void:
	# Le culling 2D de Godot teste chaque CanvasItem selon SON propre rect : un
	# parent culé n'entraîne pas ses enfants, et un custom_rect posé sur le Prop
	# (obj) ne protège donc pas le sprite enfant qui dessine réellement l'ombre.
	# L'agrandissement (per-axis) est fait dans le vertex() du shader, donc invisible
	# pour le culling CPU. À l'export chunké (Exporter.cs déplace la caméra chunk par
	# chunk), si le centre du sprite source tombe hors du chunk courant, le
	# shadow_sprite est culé entièrement et la pointe de l'ombre disparaît. On force
	# ici un custom_rect couvrant tout le quad scalé, par axe.
	if shadow_sprite == null or not is_instance_valid(shadow_sprite):
		return
	if shadow_sprite.texture == null:
		return
	var ts = shadow_sprite.texture.get_size()
	if shadow_sprite.region_enabled:
		ts = shadow_sprite.region_rect.size
	if ts.x < 1.0 or ts.y < 1.0:
		return
	# Rect du quad en coords LOCALES px (pré-transform), comme VERTEX. Le shader
	# scale VERTEX autour de l'origine locale (0,0), par axe. L'offset/position et
	# le scale du sprite sont appliqués ensuite par sa Transform2D, comme VERTEX.
	var base_pos = shadow_sprite.offset
	if shadow_sprite.centered:
		base_pos = base_pos - ts * 0.5
	var rect = Rect2(
		Vector2(base_pos.x * vertex_scale_xy.x, base_pos.y * vertex_scale_xy.y),
		Vector2(ts.x * vertex_scale_xy.x, ts.y * vertex_scale_xy.y)
	)
	VisualServer.canvas_item_set_custom_rect(shadow_sprite.get_canvas_item(), true, rect)

#########################################################################################################
##
## WALL / PATH CLIPPING
##
#########################################################################################################

func _apply_clip_mask(obj, shadow_sprite, config: Dictionary):
	"""Pass polyline clip data to shader."""
	var clip_walls = config.get("clip_walls", false)
	var clip_paths = config.get("clip_paths", false)
	var obj_pos = obj.global_position
	var offset = _compute_world_offset(config)
	var shadow_center = obj_pos + offset

	var shadow_radius = 200.0
	if shadow_sprite != null and shadow_sprite.texture != null:
		var tex_size = shadow_sprite.texture.get_size()
		var mat = shadow_sprite.material as ShaderMaterial
		if mat != null:
			var vs = mat.get_shader_param("vertex_scale_xy")
			var vsf = max(vs.x, vs.y) if vs is Vector2 else (float(vs) if vs != null else 0.0)
			if vsf > 0:
				shadow_radius = max(tex_size.x, tex_size.y) * vsf * shadow_sprite.global_scale.x * 0.5
	shadow_radius += offset.length()

	var polylines = _collect_clip_polylines(obj, clip_walls, clip_paths, shadow_radius, shadow_center)
	_clip_dbg("TOGGLE-collect", obj, polylines.size(), -1)
	obj.set_meta("_shadow_clip_tex", true)
	if polylines.size() == 0:
		# Clear any existing clip data
		var mat = shadow_sprite.material as ShaderMaterial
		if mat != null:
			mat.set_shader_param("poly_count", 0)
		return

	_send_polylines_to_shader(shadow_sprite, polylines, obj_pos, shadow_radius)
	outputlog("Applied " + str(polylines.size()) + " clip polylines", 2)

func _collect_clip_polylines(obj, clip_walls: bool, clip_paths: bool, max_clip_dist: float = 300.0, search_center = null) -> Array:
	"""Collect polylines (arrays of world-space points) from walls/paths, with closed flag."""
	var polylines = []  # Each entry: [global_pts, is_closed]
	var obj_parent = obj.get_parent()
	if obj_parent == null:
		return polylines
	var level = obj_parent.get_parent()
	if level == null:
		return polylines
	
	# Use shadow center (obj + offset) for proximity checks, fallback to obj position
	var center_pos = search_center if search_center != null else obj.global_position

	if clip_walls:
		var walls_container = null
		for child in level.get_children():
			if child.name == "Walls":
				walls_container = child
				break
		if walls_container != null:
			for wall in walls_container.get_children():
				if not is_instance_valid(wall):
					continue
				var line = null
				if dropshadow_walls != null:
					line = dropshadow_walls.get_line2d(wall)
				else:
					# Find widest Line2D child
					var best_width = 0.0
					for ch in wall.get_children():
						if ch is Line2D and ch.get_point_count() >= 2 and ch.width > best_width:
							best_width = ch.width
							line = ch
				if line == null or not is_instance_valid(line):
					continue
				var points = line.points
				if points.size() < 2:
					continue
				var xform = line.global_transform
				var global_pts = []
				for p in points:
					global_pts.append(xform.xform(p))
				var is_closed = _detect_closed(wall, line)
				if is_closed and global_pts.size() >= 3:
					if global_pts[0].distance_to(global_pts[global_pts.size() - 1]) > 2.0:
						global_pts.append(global_pts[0])
				# Only include if at least one segment is close to the shadow
				var is_nearby = false
				for i in range(global_pts.size() - 1):
					var seg_a = global_pts[i]
					var seg_b = global_pts[i + 1]
					var ab = seg_b - seg_a
					var ab_len = ab.length()
					if ab_len < 0.1:
						continue
					var ab_dir = ab / ab_len
					var t = clamp((center_pos - seg_a).dot(ab_dir), 0.0, ab_len)
					var closest = seg_a + ab_dir * t
					if center_pos.distance_to(closest) < max_clip_dist:
						is_nearby = true
						break
				if is_nearby:
					polylines.append([global_pts, is_closed])

	if clip_paths:
		var paths_container = null
		for child in level.get_children():
			if child.name == "Pathways":
				paths_container = child
				break
		if paths_container != null:
			for path_node in paths_container.get_children():
				if not is_instance_valid(path_node):
					continue
				var points = path_node.get("points")
				if points == null or points.size() < 2:
					continue
				var xform = path_node.global_transform
				var global_pts = []
				for p in points:
					global_pts.append(xform.xform(p))
				var is_loop = _detect_closed(path_node, path_node)
				# If path is a real loop, close the geometry
				if is_loop and global_pts.size() >= 3:
					if global_pts[0].distance_to(global_pts[global_pts.size() - 1]) > 2.0:
						global_pts.append(global_pts[0])
				# Paths always use "any crossing = blocked" clipping (not parity),
				# even if geometrically closed. Parity doesn't work for serpentine paths.
				var is_closed = false
				# Only include if nearby
				var is_nearby = false
				for i in range(global_pts.size() - 1):
					var seg_a = global_pts[i]
					var seg_b = global_pts[i + 1]
					var ab = seg_b - seg_a
					var ab_len = ab.length()
					if ab_len < 0.1:
						continue
					var ab_dir = ab / ab_len
					var t = clamp((center_pos - seg_a).dot(ab_dir), 0.0, ab_len)
					var closest = seg_a + ab_dir * t
					if center_pos.distance_to(closest) < max_clip_dist:
						is_nearby = true
						break
				if is_nearby:
					polylines.append([global_pts, is_closed])

	return polylines

func _sort_by_distance(a, b):
	return a[0] < b[0]

func _point_in_polygon(point: Vector2, polygon: Array) -> bool:
	"""Ray casting algorithm to test if point is inside a polygon."""
	var inside = false
	var n = polygon.size()
	var j = n - 1
	for i in range(n):
		var pi = polygon[i]
		var pj = polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside

func _segments_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	"""Test if segment p1-p2 intersects segment p3-p4 (excluding endpoints)."""
	var d1 = p2 - p1
	var d2 = p4 - p3
	var cross = d1.x * d2.y - d1.y * d2.x
	if abs(cross) < 0.001:
		return false  # Parallel
	var d3 = p3 - p1
	var t = (d3.x * d2.y - d3.y * d2.x) / cross
	var u = (d3.x * d1.y - d3.y * d1.x) / cross
	# Use small epsilon to exclude intersections at endpoints
	return t > 0.01 and t < 0.99 and u > 0.01 and u < 0.99

func _detect_closed(node, line) -> bool:

	"""Detect if a wall/path is closed using its properties."""
	if node == null:
		return false
	# Try direct property access first (Wall node has .Loop property)
	if "Loop" in node:
		if node.Loop:
			return true
	# Try various property names via get()
	for prop_name in ["Loop", "loop", "closed", "Closed", "IsLoop"]:
		var val = node.get(prop_name)
		if val is bool and val:
			return true
		if line != null and line != node:
			val = line.get(prop_name)
			if val is bool and val:
				return true
	# Fallback: check if first and last points are very close AND the shape
	# has few enough points to be a real room/polygon (not a serpentine path).
	# A room typically has 4-20 points; a serpentine path has many more.
	var pts = null
	if "Points" in node:
		pts = node.Points
	elif line != null and line.has_method("get_point_count") and line.get_point_count() >= 3:
		pts = line.points
	if pts != null and pts.size() >= 3 and pts.size() <= 30:
		if pts[0].distance_to(pts[pts.size() - 1]) < 5.0:
			return true
	return false

func _simplify_polyline(points: Array, max_points: int) -> Array:
	"""Simplify a polyline by uniform sampling along its length.
	   This preserves curves much better than Douglas-Peucker."""
	if points.size() <= max_points:
		return points
	
	# Compute cumulative arc length
	var cum_len = [0.0]
	for i in range(1, points.size()):
		cum_len.append(cum_len[i - 1] + points[i - 1].distance_to(points[i]))
	var total_len = cum_len[cum_len.size() - 1]
	if total_len < 0.1:
		return [points[0], points[points.size() - 1]]
	
	# Sample max_points evenly along the arc length
	var result = [points[0]]
	var seg_idx = 0
	for i in range(1, max_points - 1):
		var target_len = total_len * float(i) / float(max_points - 1)
		# Advance seg_idx to find the right segment
		while seg_idx < cum_len.size() - 2 and cum_len[seg_idx + 1] < target_len:
			seg_idx += 1
		# Interpolate within this segment
		var seg_start_len = cum_len[seg_idx]
		var seg_end_len = cum_len[seg_idx + 1]
		var seg_len = seg_end_len - seg_start_len
		if seg_len > 0.001:
			var t = (target_len - seg_start_len) / seg_len
			result.append(points[seg_idx].linear_interpolate(points[seg_idx + 1], t))
		else:
			result.append(points[seg_idx])
	result.append(points[points.size() - 1])
	return result

var _trim_ref_pos = Vector2.ZERO

func _send_polylines_to_shader(shadow_sprite, polylines: Array, obj_pos: Vector2, shadow_radius: float = 250.0):
	"""Pack polylines into a data texture for the shader."""
	var mat = shadow_sprite.material as ShaderMaterial
	if mat == null:
		return

	mat.set_shader_param("sprite_world_pos", shadow_sprite.global_position)
	mat.set_shader_param("sprite_world_rot", shadow_sprite.global_rotation)
	mat.set_shader_param("sprite_world_scale", shadow_sprite.global_scale)
	mat.set_shader_param("obj_world_pos", obj_pos)
	mat.set_shader_param("shadow_clip_radius", shadow_radius)

	# === MERGE CONNECTED POLYLINES ===
	# Fuse polylines that share endpoints (within 5px) into continuous chains.
	# This eliminates corner gaps that break the parity ray-casting test.
	var merge_dist = 8.0
	var merged = []
	var used = []
	for _i in range(polylines.size()):
		used.append(false)

	for i in range(polylines.size()):
		if used[i]:
			continue
		used[i] = true
		var chain = polylines[i][0].duplicate()
		var chain_closed = polylines[i][1]

		# Don't merge already-closed polylines (e.g. rooms) — they need
		# to stay intact for the parity test to work correctly.
		# Keep trying to extend the chain (only for non-closed polylines)
		var changed = true
		while changed and not chain_closed:
			changed = false
			for j in range(polylines.size()):
				if used[j]:
					continue
				var other = polylines[j][0]
				if other.size() < 2:
					continue

				# Try to attach other to the END of chain
				if chain[chain.size() - 1].distance_to(other[0]) < merge_dist:
					# Append other (skip first point, it's the junction)
					for k in range(1, other.size()):
						chain.append(other[k])
					used[j] = true
					changed = true
				elif chain[chain.size() - 1].distance_to(other[other.size() - 1]) < merge_dist:
					# Append reversed other
					for k in range(other.size() - 2, -1, -1):
						chain.append(other[k])
					used[j] = true
					changed = true
				# Try to attach other to the START of chain
				elif chain[0].distance_to(other[other.size() - 1]) < merge_dist:
					# Prepend other (skip last point)
					var new_chain = []
					for k in range(other.size() - 1):
						new_chain.append(other[k])
					new_chain.append_array(chain)
					chain = new_chain
					used[j] = true
					changed = true
				elif chain[0].distance_to(other[0]) < merge_dist:
					# Prepend reversed other
					var new_chain = []
					for k in range(other.size() - 1, 0, -1):
						new_chain.append(other[k])
					new_chain.append_array(chain)
					chain = new_chain
					used[j] = true
					changed = true

			# Check if chain became closed
			if chain.size() >= 3 and chain[0].distance_to(chain[chain.size() - 1]) < merge_dist:
				chain_closed = true

		merged.append([chain, chain_closed])

	# Replace polylines with merged version
	polylines = merged

	# Collect ALL endpoints for connection detection
	var all_endpoints = []
	for poly_data in polylines:
		var pts = poly_data[0]
		if pts.size() >= 2:
			all_endpoints.append(pts[0])
			all_endpoints.append(pts[pts.size() - 1])

	# Sort polylines by distance to obj (closest first)
	var sorted_polys = []
	for poly_data in polylines:
		var polyline = poly_data[0]
		if polyline.size() < 2:
			continue
		var min_dist = INF
		var closest_pt = polyline[0]
		for i in range(polyline.size() - 1):
			var a = polyline[i]
			var b = polyline[i + 1]
			var ab = b - a
			var ab_len = ab.length()
			if ab_len < 0.1:
				continue
			var ab_dir = ab / ab_len
			var t = clamp((obj_pos - a).dot(ab_dir), 0.0, ab_len)
			var cp = a + ab_dir * t
			var d = obj_pos.distance_to(cp)
			if d < min_dist:
				min_dist = d
				closest_pt = cp
		sorted_polys.append([min_dist, poly_data, closest_pt])
	sorted_polys.sort_custom(self, "_sort_by_distance")

	# Occlusion filter: reject polylines that are fully behind already-accepted walls
	# (i.e., all their segments are occluded by closer walls from obj's perspective)
	var accepted_polys = []
	for entry in sorted_polys:
		var poly_data = entry[1]
		var polyline = poly_data[0]

		# Test multiple sample points along this polyline
		var sample_pts = []
		for i in range(polyline.size() - 1):
			sample_pts.append((polyline[i] + polyline[i + 1]) / 2.0)  # segment midpoints
		# Also add the closest point to obj
		sample_pts.append(entry[2])

		var all_occluded = true
		for sample in sample_pts:
			var is_occluded = false
			for accepted in accepted_polys:
				var acc_polyline = accepted[0]
				for i in range(acc_polyline.size() - 1):
					if _segments_intersect(obj_pos, sample, acc_polyline[i], acc_polyline[i + 1]):
						is_occluded = true
						break
				if is_occluded:
					break
			if not is_occluded:
				all_occluded = false
				break

		if not all_occluded:
			accepted_polys.append(poly_data)

	# Build point/normal/def arrays (no simplification needed with texture approach)
	var all_points = []
	var all_normals = []
	var defs = []
	_trim_ref_pos = obj_pos

	# === PHASE 1: Filter all polylines (nearby segments only) ===
	var filtered_polys = []
	for poly_data in accepted_polys:
		if filtered_polys.size() >= 8:
			break
		var polyline = poly_data[0]
		var is_closed = poly_data[1]
		if polyline.size() < 2:
			continue

		var invert_clip = false
		if is_closed and polyline.size() >= 3:
			if not _point_in_polygon(obj_pos, polyline):
				invert_clip = true

		if not is_closed:

			var nearby_groups = [[]]
			for i in range(polyline.size() - 1):
				var a = polyline[i]
				var b = polyline[i + 1]
				var ab = b - a
				var ab_len = ab.length()
				if ab_len < 0.1:
					continue
				var ab_dir = ab / ab_len
				var t = clamp((obj_pos - a).dot(ab_dir), 0.0, ab_len)
				var closest = a + ab_dir * t
				if obj_pos.distance_to(closest) < shadow_radius:
					var group = nearby_groups[nearby_groups.size() - 1]
					if group.size() == 0 or group[group.size() - 1].distance_to(a) < 1.0:
						if group.size() == 0:
							group.append(a)
						group.append(b)
					else:
						nearby_groups.append([a, b])
				else:
					if nearby_groups[nearby_groups.size() - 1].size() > 0:
						nearby_groups.append([])

			for group in nearby_groups:
				if group.size() >= 2:
					filtered_polys.append([group, false])
			continue

		filtered_polys.append([polyline, is_closed])

	# === PHASE 2: Distribute 256-point budget fairly ===
	var total_budget = 256
	var num_polys = filtered_polys.size()
	if num_polys == 0:
		_clip_dbg("SEND-filtered-empty", shadow_sprite.get_parent(), polylines.size(), 0)
		mat.set_shader_param("poly_count", 0)
		return

	# Give each polyline a fair share, respecting their actual size
	var total_requested = 0
	for fp in filtered_polys:
		total_requested += fp[0].size()

	# === PHASE 3: Simplify and build shader data ===
	var budget_used = 0
	for pi in range(num_polys):
		var polyline = filtered_polys[pi][0]
		var is_closed = filtered_polys[pi][1]

		# Budget for this polyline: proportional to its point count
		var remaining_polys = num_polys - pi
		var remaining_budget = total_budget - budget_used
		var my_budget = 0
		if total_requested > 0:
			my_budget = int(float(polyline.size()) / float(total_requested) * total_budget)
		# Ensure minimum budget and don't exceed remaining
		my_budget = max(my_budget, min(2, remaining_budget))
		my_budget = min(my_budget, remaining_budget)
		# Ensure remaining polylines get at least 2 points each
		var reserved_for_others = max(0, (remaining_polys - 1) * 2)
		my_budget = min(my_budget, remaining_budget - reserved_for_others)
		my_budget = max(my_budget, 2)
		if my_budget > remaining_budget:
			break

		if polyline.size() > my_budget:
			polyline = _simplify_polyline(polyline, my_budget)

		var start_connected = is_closed
		var end_connected = is_closed

		if not is_closed:
			var start_pt = polyline[0]
			var end_pt = polyline[polyline.size() - 1]
			for ep in all_endpoints:
				if not start_connected and ep != start_pt and start_pt.distance_to(ep) < 5.0:
					start_connected = true
				if not end_connected and ep != end_pt and end_pt.distance_to(ep) < 5.0:
					end_connected = true
				if start_connected and end_connected:
					break
		
		# With ray-casting, we don't extend endpoints — the ray naturally
		# handles free endpoints correctly (no intersection = no blocking).

		var start_idx = all_points.size()

		var seg_normals = []
		for i in range(polyline.size() - 1):
			var seg_dir = (polyline[i + 1] - polyline[i]).normalized()
			var n = Vector2(-seg_dir.y, seg_dir.x)
			var seg_mid = (polyline[i] + polyline[i + 1]) / 2.0
			# Always orient normal toward the object
			if n.dot(obj_pos - seg_mid) < 0:
				n = -n
			seg_normals.append(n)

		for pt in polyline:
			all_points.append(pt)
		for n in seg_normals:
			all_normals.append(n)
		defs.append([start_idx, polyline.size(), 2.0 if is_closed else (1.0 if start_connected else 0.0), 1.0 if end_connected else 0.0])
		budget_used += polyline.size()

	if defs.size() == 0:
		_clip_dbg("SEND-defs-empty", shadow_sprite.get_parent(), num_polys, 0)
		mat.set_shader_param("poly_count", 0)
		return

	_clip_dbg("SEND-ok", shadow_sprite.get_parent(), num_polys, defs.size())
	mat.set_shader_param("poly_count", defs.size())

	for i in range(8):
		if i < defs.size():
			var d = defs[i]
			mat.set_shader_param("poly_def" + str(i), Plane(d[0], d[1], d[2], d[3]))
		else:
			mat.set_shader_param("poly_def" + str(i), Plane(0, 0, 0, 0))

	# Create data texture: width = max(points, normals+1), height = 2
	# Row 0 (v=0.25): points (x in R, y in G)
	# Row 1 (v=0.75): normals (x in R, y in G)
	var tex_width = max(all_points.size(), all_normals.size() + 1)
	tex_width = max(tex_width, 1)
	var img = Image.new()
	img.create(tex_width, 2, false, Image.FORMAT_RGBAF)
	img.lock()
	# Write points in row 0
	for i in range(all_points.size()):
		img.set_pixel(i, 0, Color(all_points[i].x, all_points[i].y, 0.0, 1.0))
	# Write normals in row 1
	for i in range(all_normals.size()):
		img.set_pixel(i, 1, Color(all_normals[i].x, all_normals[i].y, 0.0, 1.0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)  # No flags (no filtering, no mipmaps)
	mat.set_shader_param("poly_data_tex", tex)
	mat.set_shader_param("poly_data_size", tex_width)

func _collect_clip_segments(obj, clip_walls: bool, clip_paths: bool) -> Array:
	"""Collect line segments from nearby walls/paths on the same level."""
	var segments = []
	var obj_parent = obj.get_parent()
	if obj_parent == null:
		return segments
	var level = obj_parent.get_parent()
	if level == null:
		outputlog("_collect_clip_segments: level is null (parent=" + str(obj_parent.name) + ")", 1)
		return segments

	outputlog("_collect_clip_segments: level=" + str(level.name) + " children=" + str(level.get_child_count()), 2)

	if clip_walls:
		var walls_container = null
		for child in level.get_children():
			if child.name == "Walls":
				walls_container = child
				break
		if walls_container != null:
			for wall in walls_container.get_children():
				if not is_instance_valid(wall):
					continue
				var line = null
				if dropshadow_walls != null:
					line = dropshadow_walls.get_line2d(wall)
				else:
					var best_width = 0.0
					for ch in wall.get_children():
						if ch is Line2D and ch.get_point_count() >= 2 and ch.width > best_width:
							best_width = ch.width
							line = ch
				if line == null or not is_instance_valid(line):
					continue
				var points = line.points
				if points.size() < 2:
					continue
				var xform = line.global_transform
				for i in range(points.size() - 1):
					var p1 = xform.xform(points[i])
					var p2 = xform.xform(points[i + 1])
					segments.append([p1, p2])

	if clip_paths:
		var paths_container = null
		for child in level.get_children():
			if child.name == "Pathways":
				paths_container = child
				break
		if paths_container != null:
			for path_node in paths_container.get_children():
				if not is_instance_valid(path_node):
					continue
				var points = path_node.get("points")
				if points == null or points.size() < 2:
					continue
				var xform = path_node.global_transform
				for i in range(points.size() - 1):
					var p1 = xform.xform(points[i])
					var p2 = xform.xform(points[i + 1])
					segments.append([p1, p2])

	return segments

# Max staleness (ms) for the per-frame clip refresh of PLACED assets. We
# recompute immediately when the asset moves or its offset/sun changes (both
# cheap to detect). The only change we get no signal for is a wall/path moved
# under a placed asset, so we re-collect at most ~2x/s to catch that without
# paying the full polyline collection every frame. (The ObjectTool preview is
# NOT throttled — it must follow the mouse every frame.)
const CLIP_THROTTLE_MS := 2000

func _clip_should_recompute(obj, config: Dictionary) -> bool:
	var pos = obj.global_position
	var offset = _compute_world_offset(config)
	var now = OS.get_ticks_msec()
	if obj.has_meta("_clip_thr"):
		var c = obj.get_meta("_clip_thr")
		if c is Dictionary:
			var moved = pos.distance_to(c.get("pos", pos)) > 0.01
			var off_changed = offset.distance_to(c.get("off", offset)) > 0.01
			if not moved and not off_changed and (now - int(c.get("ms", 0))) < CLIP_THROTTLE_MS:
				return false
	obj.set_meta("_clip_thr", {"pos": pos, "off": offset, "ms": now})
	return true

func _update_clip_planes(obj, shadow_sprite, config: Dictionary):
	"""Lightweight update of clip polyline shader params."""
	# Baked shadows are flat textures (no ShaderMaterial) — the clip is already
	# burned into the texture. Bail BEFORE the (expensive) polyline collection so
	# we don't iterate every wall/path each frame just to throw the result away.
	if shadow_sprite == null or not (shadow_sprite.material is ShaderMaterial):
		return
	var clip_walls = config.get("clip_walls", false)
	var clip_paths = config.get("clip_paths", false)
	var obj_pos = obj.global_position
	var offset = _compute_world_offset(config)
	var shadow_center = obj_pos + offset

	var shadow_radius = 200.0
	if shadow_sprite != null and shadow_sprite.texture != null:
		var tex_size = shadow_sprite.texture.get_size()
		var mat2 = shadow_sprite.material as ShaderMaterial
		if mat2 != null:
			var vs = mat2.get_shader_param("vertex_scale_xy")
			var vsf = max(vs.x, vs.y) if vs is Vector2 else (float(vs) if vs != null else 0.0)
			if vsf > 0:
				shadow_radius = max(tex_size.x, tex_size.y) * vsf * shadow_sprite.global_scale.x * 0.5
	shadow_radius += offset.length()

	var polylines = _collect_clip_polylines(obj, clip_walls, clip_paths, shadow_radius, shadow_center)
	_clip_dbg("TICK-collect", obj, polylines.size(), -1)

	var mat = shadow_sprite.material as ShaderMaterial
	if mat == null:
		return

	if polylines.size() == 0:
		mat.set_shader_param("poly_count", 0)
		return

	_send_polylines_to_shader(shadow_sprite, polylines, obj_pos, shadow_radius)

func remove_shadow(obj):
	if obj == null or not is_instance_valid(obj):
		return

	if _bake_debounce != null:
		_bake_debounce.cancel(obj)

	if obj.has_meta(SHADOW_META_KEY):
		var nodes = obj.get_meta(SHADOW_META_KEY)
		if nodes is Array:
			for node in nodes:
				if is_instance_valid(node):
					node.get_parent().remove_child(node)
					node.free()
		obj.remove_meta(SHADOW_META_KEY)
	if obj.has_meta("_shadow_clip_tex"):
		obj.remove_meta("_shadow_clip_tex")
	if obj.has_meta("_shadow_source_tex_rid"):
		obj.remove_meta("_shadow_source_tex_rid")


#########################################################################################################
## BAKE MODE (objects-only)
#########################################################################################################

# True only when the global mode is AUTO. Live/Manual suppress the debounced
# auto-bake; in those modes shadows stay shader sprites until baked manually.
func _should_auto_bake() -> bool:
	return int(global.ModMapData.get(BAKE_MODE_KEY, BAKE_MODE_AUTO)) == BAKE_MODE_AUTO


func is_object_baked(obj) -> bool:
	if _baker_script == null:
		return false
	return _baker_script.is_baked(obj, SHADOW_META_KEY)


# Bake a single object's live shadow now. Always yields at least once so callers
# can safely `yield(bake_object_now(obj), "completed")`.
func bake_object_now(obj):
	yield(global.Editor.get_tree(), "idle_frame")
	if obj == null or not is_instance_valid(obj):
		return
	if _baker_script == null:
		return
	if not obj.has_meta(SHADOW_META_KEY):
		return
	if _baker_script.is_baked(obj, SHADOW_META_KEY):
		return
	# Projected shadows stay live (baking them is a VRAM/capture problem — see
	# create_shadow). Never bake them, even on an explicit manual bake.
	if obj.has_meta("_shadow_config"):
		var bccfg = obj.get_meta("_shadow_config")
		if bccfg is Dictionary and bccfg.get("shadow_mode", "offset") == "projected":
			return
	# Cancel any pending auto-bake debounce so it can't fight the manual bake.
	if _bake_debounce != null:
		_bake_debounce.cancel(obj)
	var nodes = obj.get_meta(SHADOW_META_KEY)
	if not (nodes is Array) or nodes.size() == 0:
		return
	var shadow_sprite = nodes[0]
	if shadow_sprite == null or not is_instance_valid(shadow_sprite):
		return
	var source_sprite = get_sprite(obj)
	if source_sprite == null:
		return
	var baked = yield(_baker_script.bake_shadow(shadow_sprite, source_sprite, global, self), "completed")
	if baked == null:
		return
	if not is_instance_valid(obj) or not is_instance_valid(shadow_sprite):
		baked.queue_free()
		return
	_baker_script.install_baked(obj, shadow_sprite, baked, SHADOW_META_KEY)


# Single serial bake queue. Overlapping callers (map-load + enable, or several
# enables) merge into one queue, so at most one viewport is ever alive. Pending
# auto-bake debounces for queued objects are cancelled up front so they can't
# fire in parallel with the queue.
var _bake_queue = []        # Array of WeakRef to object owners
var _bake_running = false

func bake_objects_sequential(obj_list):
	if obj_list == null:
		return
	for obj in obj_list:
		if obj == null or not is_instance_valid(obj):
			continue
		# Projected shadows stay live — never queue them for baking.
		if obj.has_meta("_shadow_config"):
			var qccfg = obj.get_meta("_shadow_config")
			if qccfg is Dictionary and qccfg.get("shadow_mode", "offset") == "projected":
				continue
		if _bake_debounce != null:
			_bake_debounce.cancel(obj)
		_bake_queue.append(weakref(obj))
	if not _bake_running:
		_drain_bake_queue()


func _drain_bake_queue():
	if _bake_running:
		return
	_bake_running = true
	yield(global.Editor.get_tree(), "idle_frame")
	var tree = global.Editor.get_tree()
	var done = 0
	while _bake_queue.size() > 0:
		var ref = _bake_queue.pop_front()
		var obj = ref.get_ref() if ref != null else null
		if obj == null or not is_instance_valid(obj):
			continue
		yield(bake_object_now(obj), "completed")
		done += 1
		# Give the freed viewport a frame to release its memory before the next.
		yield(tree, "idle_frame")
	_bake_running = false
	outputlog("Batch bake: processed %d object(s)" % done, 0)


func _fast_update_shadow(obj, config: Dictionary) -> bool:
	if not obj.has_meta(SHADOW_META_KEY):
		return false
	# If baked, unbake first so the shader params we're about to set actually apply.
	if _baker_script.is_baked(obj, SHADOW_META_KEY):
		var src = get_sprite(obj)
		if src != null:
			_baker_script.unbake(obj, SHADOW_META_KEY, src)
	
	var nodes = obj.get_meta(SHADOW_META_KEY)
	if not (nodes is Array) or nodes.size() == 0:
		return false

	var sprite = get_sprite(obj)
	if sprite == null:
		# Roof: fast-update shader params without re-rendering polygon texture
		if dropshadow_roofs != null and dropshadow_roofs.is_roof(obj):
			return dropshadow_roofs.fast_update_roof_shadow(obj, config)
		return false

	var opacity_val = config.get("opacity", 0.15)
	var blur_frac = config.get("blur", 0.1)
	
	var projected = config.get("shadow_mode", "offset") == "projected"
	var offset = Vector2.ZERO if projected else _compute_world_offset(config)
	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)

	var tex_size = sprite.texture.get_size()
	if sprite.region_enabled:
		tex_size = sprite.region_rect.size
	var max_dim = max(tex_size.x, tex_size.y)

	var effective_frac = blur_frac * 0.75

	var total_blur = effective_frac * 160.0
	var spread_val = clamp(effective_frac, 0.0, 1.0)

	var BASE_BLUR_PX = 2.0
	var energy_comp = pow(max(total_blur, BASE_BLUR_PX) / BASE_BLUR_PX, 0.2)
	energy_comp = clamp(energy_comp, 1.0, 1.8)

	var MAX_SHADER_BLUR = 90.0
	var shader_blur = min(total_blur, MAX_SHADER_BLUR)
	var blur_ratio = total_blur / max(shader_blur, 1.0)

	# Quality factor: same scaling as in create_shadow.
	var quality_factor = clamp(float(config.get("quality", 100)) / 100.0, 0.0, 1.0)
	var blur_quality = max(int(clamp(shader_blur / 3.0, 4, 16) * quality_factor), 2)
	var blur_steps = max(int(clamp(shader_blur * 0.9, 16, 48) * quality_factor), 8)

	# Per-axis quad expansion (see _compute_vertex_scale_xy / create_shadow).
	var vsxy = _compute_vertex_scale_xy(obj, config, tex_size, shader_blur, blur_ratio)

	# Extrude optimisation — mirror create_shadow.
	var extrude_steps = 18
	if projected and float(config.get("proj_extrude", 0.0)) > 0.5:
		var sweep_px = float(config.get("proj_length", 0.0)) * max_dim
		extrude_steps = int(clamp(ceil(sweep_px / EXTRUDE_STEP_TARGET_PX), EXTRUDE_STEPS_MIN, EXTRUDE_STEPS_MAX))
		blur_quality = int(clamp(blur_quality, 2, EXTRUDE_BLUR_QUALITY_MAX))
		blur_steps = int(clamp(blur_steps, 6, EXTRUDE_BLUR_STEPS_MAX))

	var local_offset = _world_to_local_offset(obj, offset)
	var behind_layer = config.get("behind_layer", false)

	for node in nodes:
		if not is_instance_valid(node):
			return false
		if node.material is ShaderMaterial:
			var mat = node.material as ShaderMaterial
			mat.set_shader_param("shadow_color", shadow_color)
			mat.set_shader_param("blur_radius", shader_blur)
			mat.set_shader_param("spread", spread_val)
			mat.set_shader_param("shadow_strength", opacity_val * energy_comp)
			mat.set_shader_param("blur_quality", blur_quality)
			mat.set_shader_param("blur_steps", blur_steps)
			mat.set_shader_param("vertex_scale_xy", vsxy)
			mat.set_shader_param("extrude_steps", extrude_steps)
			_apply_projection_params(mat, obj, config, sprite, tex_size)
			mat.set_shader_param("cut_offset", Vector2.ZERO if projected else Vector2(local_offset.x / tex_size.x, local_offset.y / tex_size.y))
			# Shadow stays as a child of obj. behind_layer just toggles relative
			# z-index between 0 (same z bucket as prop) and -1 (one bucket below).
			node.show_behind_parent = false
			node.z_as_relative = true
			node.z_index = -1 if behind_layer else 0
			node.scale = sprite.scale
			node.position = sprite.position + local_offset
			# Keep the shadow sprite's own per-axis cull rect in sync so it isn't
			# culled at chunked export (see _set_shadow_sprite_custom_rect).
			_set_shadow_sprite_custom_rect(node, vsxy)

	obj.set_meta("_shadow_offset", offset)
	obj.set_meta("_shadow_config", config)
	_update_custom_rect(obj, sprite, total_blur, max(vsxy.x, vsxy.y))
	save_shadow_data(obj, config)
	# Projected shadows stay live (see create_shadow). Switching INTO projected
	# cancels any bake still pending from offset; only offset auto-bakes.
	if config.get("shadow_mode", "offset") == "projected":
		if _bake_debounce != null:
			_bake_debounce.cancel(obj)
	elif _should_auto_bake():
		_bake_debounce.schedule_bake(obj)
	return true


#########################################################################################################
##
## MONITORING
##
#########################################################################################################

func _on_monitor_tick():
	# Self-heal: roughly once a second, rebuild any saved+enabled shadow whose
	# live node is missing (map reload didn't re-run the restore pass, or a node
	# finished loading after it). Existing/hidden shadows keep their meta and are
	# skipped, so this is a no-op in steady state.
	_heal_counter += 1
	if _heal_counter >= 100:
		_heal_counter = 0
		_heal_missing_shadows()

	# Détection des moves natifs (timeline undo/redo unifiée).
	_detect_native_moves()
	# Arme la détection native une fois le chargement de map passé (~2 s),
	# pour ne pas marquer les ajouts émis en rafale par OnAssignNode au load.
	if not _native_detect_ready:
		_native_arm_count += 1
		if _native_arm_count >= 200:
			_native_detect_ready = true

	# Defensive cleanup: previous versions of this mod parented "behind layer"
	# shadows in a Level-scoped DropShadowObjBelowLayer container, with transform
	# synced every frame. The new approach keeps shadows as children of their
	# prop with z_index = -1, so any leftover container from an older save is
	# stale and would render duplicate shadows. Free it on first sight.
	var _cur_level = global.World.GetCurrentLevel()
	if _cur_level != null:
		var _bl = _cur_level.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
		if _bl != null:
			_cur_level.remove_child(_bl)
			_bl.queue_free()

	# Detect Ctrl+C: save current selection as copy source
	var ctrl = Input.is_key_pressed(KEY_CONTROL)
	var c_pressed = Input.is_key_pressed(KEY_C)
	var v_pressed = Input.is_key_pressed(KEY_V)
	
	if ctrl and c_pressed and not v_pressed and not _ctrl_c_was_pressed:
		var ids = []
		for sel in global.Editor.Tools["SelectTool"].Selected:
			if is_instance_valid(sel) and sel.has_meta("node_id"):
				ids.append(str(sel.get_meta("node_id")))
		if ids.size() > 0:
			_copy_source_ids = ids
	_ctrl_c_was_pressed = ctrl and c_pressed
	
	if ctrl and v_pressed and not _ctrl_v_was_pressed:
		if _copy_source_ids.size() > 0:
			_paste_pending = true
	_ctrl_v_was_pressed = ctrl and v_pressed
	
	var new_monitored = null

	if global.Editor.Tools["SelectTool"].Selected.size() > 0:
		for node in global.Editor.Tools["SelectTool"].Selected:
			if is_shadow_node_type(node):
				if new_monitored == null:
					new_monitored = node
				_check_clone_shadow(node)
				_check_texture_changed(node)

	# Update ObjectTool preview shadow if toggle is on
	if ui_config.get("obj_tool_shadow_enabled", false):
		# Reset tracking if old preview was freed
		if _obj_tool_preview_node != null and not is_instance_valid(_obj_tool_preview_node):
			_obj_tool_preview_node = null
			_obj_tool_preview_tex = null
		var preview = _get_obj_tool_preview()
		if preview != null:
			# Check if texture changed (asset swap without node change)
			var current_tex = null
			var spr = get_sprite(preview)
			if spr != null and spr.texture != null:
				current_tex = spr.texture.get_rid()
			var changed = preview != _obj_tool_preview_node or current_tex != _obj_tool_preview_tex
			if changed:
				if _obj_tool_preview_node != null and is_instance_valid(_obj_tool_preview_node):
					remove_shadow(_obj_tool_preview_node)
				_obj_tool_preview_node = preview
				_obj_tool_preview_tex = current_tex
				var config = _get_placement_config()
				remove_shadow(preview)
				create_shadow(preview, config)
			# Update clip planes every frame for the preview (position changes as user moves mouse)
			if preview.has_meta("_shadow_clip_tex") and preview.has_meta("_shadow_config"):
				var clip_config = preview.get_meta("_shadow_config")
				var cw = clip_config.get("clip_walls", false)
				var cp = clip_config.get("clip_paths", false)
				if cw or cp:
					var shadow_nodes = preview.get_meta(SHADOW_META_KEY) if preview.has_meta(SHADOW_META_KEY) else null
					if shadow_nodes is Array and shadow_nodes.size() > 0 and is_instance_valid(shadow_nodes[0]):
						_update_clip_planes(preview, shadow_nodes[0], clip_config)
	elif _obj_tool_preview_node != null:
		if is_instance_valid(_obj_tool_preview_node):
			remove_shadow(_obj_tool_preview_node)
		_obj_tool_preview_node = null
		_obj_tool_preview_tex = null

	# Process nodes from OnAssignNode (ObjectTool placement)
	_process_signal_nodes()
	
	# Process clone batch BEFORE UI loading (so clones have their data saved first)
	_process_clone_batch()

	if new_monitored != null and new_monitored != _monitored_object:
		# Track previous selection for clone detection
		if _monitored_object != null and is_instance_valid(_monitored_object):
			_last_monitored_object = _monitored_object
		_reparent_ui_to_node(new_monitored)
		_monitored_object = new_monitored
		if not _paste_just_processed:
			_loading_ui = true
			load_shadow_ui_from_object(new_monitored)
			# Clear _loading_ui after deferred signals have been processed
			global.Editor.get_tree().connect("idle_frame", self, "_clear_loading_ui", [], CONNECT_ONESHOT)
	_paste_just_processed = false

func _on_frame_pre_draw():
	"""Called by VisualServer before every frame render. Syncs shadow positions
	with current object rotation/scale — eliminates 1-frame lag during rotation."""
	_update_all_shadow_rotations()

func _on_new_node_added(node):
	"""Called by DD's OnAssignNode signal. Queue for deferred processing."""
	if node == null or not is_instance_valid(node):
		return
	# Op native d'ajout (placement / paste / redo natif) -> marqueur timeline.
	# Gardé par _native_detect_ready (ignore la rafale du chargement) et par la
	# fenêtre de suppression interne à note_native_op (ajouts dus à un undo/redo).
	# Pas de filtre type/id ici : le nœud n'est pas toujours prêt au signal.
	if _native_detect_ready and shadow_history != null and shadow_history.has_method("note_native_op"):
		shadow_history.note_native_op()
	_pending_signal_nodes.append(node)

func _process_signal_nodes():
	"""Process nodes from OnAssignNode — apply ObjectTool shadow if toggle is ON.
	Always track nodes in _all_known_obj_ids even when toggle is OFF,
	to prevent _check_clone_shadow from treating them as new clones later."""
	if _pending_signal_nodes.size() == 0:
		return
	var nodes = _pending_signal_nodes.duplicate()
	_pending_signal_nodes.clear()
	for node in nodes:
		if not is_instance_valid(node):
			continue
		if not is_shadow_node_type(node):
			continue
		if not node.has_meta("node_id"):
			continue
		var node_id = str(node.get_meta("node_id"))
		if _all_known_obj_ids.has(node_id):
			continue
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
			_all_known_obj_ids[node_id] = node
			# Saved shadow data exists but the live shadow node is missing (map
			# reload, or this node finished loading after apply_saved_shadows_to_map
			# ran). Rebuild it from the saved config instead of silently skipping.
			if not node.has_meta(SHADOW_META_KEY):
				var saved_cfg = global.ModMapData[SHADOW_DATA_KEY][node_id]
				if saved_cfg is Dictionary and saved_cfg.get("enabled", false):
					var rebuild_cfg = saved_cfg.duplicate()
					if rebuild_cfg.has("shadow_color") and rebuild_cfg["shadow_color"] is String:
						rebuild_cfg["shadow_color"] = Color(rebuild_cfg["shadow_color"])
					_deferred_create_shadow(node, rebuild_cfg)
			continue
		# Always track the node
		_all_known_obj_ids[node_id] = node
		# Only create shadow if toggle is ON
		if ui_config.get("obj_tool_shadow_enabled", false):
			var new_config = _get_placement_config()
			save_shadow_data(node, new_config)
			_deferred_create_shadow(node, new_config)

func _check_texture_changed(node):
	"""Detect external texture swaps on a shadowed object (e.g. via the
	ChangeObjectTexture mod) and rebuild the shadow so it tracks the new
	texture, dimensions, custom_rect and clip mask. Same RID-comparison
	pattern used for the ObjectTool preview in _on_monitor_tick."""
	if node == null or not is_instance_valid(node):
		return
	if not node.has_meta(SHADOW_META_KEY):
		return
	if not node.has_meta("_shadow_source_tex_rid"):
		return
	if not node.has_meta("_shadow_config"):
		return
	var sprite = get_sprite(node)
	if sprite == null or sprite.texture == null:
		return
	var current_rid = sprite.texture.get_rid()
	var stored_rid = node.get_meta("_shadow_source_tex_rid")
	if current_rid == stored_rid:
		return
	# Texture swapped — fully rebuild so custom_rect / clip mask / bake all
	# get refreshed from the new texture.
	var config = node.get_meta("_shadow_config")
	remove_shadow(node)
	create_shadow(node, config)

func _check_clone_shadow(node):
	"""When a new node appears, queue it for batch processing at end of tick."""
	if node == null or not is_instance_valid(node):
		return
	if not node.has_meta("node_id"):
		return
	var node_id = str(node.get_meta("node_id"))
	if _all_known_obj_ids.has(node_id):
		return
	if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
		_all_known_obj_ids[node_id] = node
		return
	
	# Queue for batch processing
	_clone_batch.append(node)

func _process_clone_batch():
	"""Process all new nodes detected this tick."""
	if _clone_batch.size() == 0:
		return
	
	var batch = _clone_batch.duplicate()
	_clone_batch.clear()
	
	var is_paste = _paste_pending
	_paste_pending = false
	if is_paste:
		_paste_just_processed = true
	
	for i in range(batch.size()):
		var node = batch[i]
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var node_id = str(node.get_meta("node_id"))
		
		# For Ctrl+V paste: match by index with copy source (preserves order)
		if is_paste and i < _copy_source_ids.size():
			var src_id = _copy_source_ids[i]
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(src_id):
				var src_config = global.ModMapData[SHADOW_DATA_KEY][src_id]
				if src_config is Dictionary:
					var clone_config = src_config.duplicate()
					if clone_config.has("shadow_color") and clone_config["shadow_color"] is String:
						clone_config["shadow_color"] = Color(clone_config["shadow_color"])
					save_shadow_data(node, clone_config)
					if clone_config.get("enabled", false):
						_deferred_create_shadow(node, clone_config)
					_all_known_obj_ids[node_id] = node
					_paste_just_processed = true
					continue
		
		# Fallback: match by sprite texture against ALL existing shadow configs.
		# Covers DD Copy+Paste buttons, duplicate, etc. — any clone scenario
		# where the new node shares the same texture as a shadowed original.
		# Safe because fresh ObjectTool placements are caught by _process_signal_nodes
		# before reaching here.
		if global.ModMapData.has(SHADOW_DATA_KEY):
			var spr = get_sprite(node)
			if spr != null and spr.texture != null:
				var tex_path = spr.texture.resource_path
				if tex_path != "":
					var matched_config = _find_shadow_config_by_texture(tex_path, node_id)
					if matched_config != null:
						var clone_config = matched_config.duplicate()
						if clone_config.has("shadow_color") and clone_config["shadow_color"] is String:
							clone_config["shadow_color"] = Color(clone_config["shadow_color"])
						save_shadow_data(node, clone_config)
						if clone_config.get("enabled", false):
							_deferred_create_shadow(node, clone_config)
						_all_known_obj_ids[node_id] = node
						_paste_just_processed = true
						continue
		
		# Not a paste and no texture match — this is a duplicate/level-clone of an
		# object that had no shadow, or an otherwise-unknown node. Do NOT apply the
		# ObjectTool placement toggle here: a clone is not a placement. Genuine
		# ObjectTool placements are handled by _process_signal_nodes (which honors
		# the toggle). Just register it so it isn't re-processed.
		_all_known_obj_ids[node_id] = node

func _find_shadow_config_by_texture(tex_path: String, exclude_id: String):
	"""Find an existing shadow config for a node that shares the given texture path."""
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return null
	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	for src_id in shadow_data.keys():
		if src_id == exclude_id:
			continue
		var cfg = shadow_data[src_id]
		if not cfg is Dictionary or not cfg.get("enabled", false):
			continue
		if not global.World.HasNodeID(src_id):
			continue
		var src_node = global.World.GetNodeByID(src_id)
		if src_node == null or not is_instance_valid(src_node):
			continue
		var src_spr = get_sprite(src_node)
		if src_spr != null and src_spr.texture != null:
			if src_spr.texture.resource_path == tex_path:
				return cfg
	return null

func _deferred_create_shadow(node, config: Dictionary):
	"""Create shadow after a short delay to let DD finish building the node."""
	var timer = Timer.new()
	timer.wait_time = 0.05
	timer.one_shot = true
	timer.connect("timeout", self, "_on_deferred_shadow_timer", [node, config, timer])
	global.Editor.add_child(timer)
	timer.start()

func _on_deferred_shadow_timer(node, config: Dictionary, timer: Timer):
	timer.queue_free()
	if node != null and is_instance_valid(node):
		var sprite = get_sprite(node)
		if sprite != null and sprite.texture != null:
			remove_shadow(node)
			create_shadow(node, config)

func _update_all_shadow_rotations():
	for obj_id in _all_known_obj_ids.keys():
		var obj = _all_known_obj_ids[obj_id]
		if obj == null or not is_instance_valid(obj):
			continue
		# Skip shadows that aren't drawn this frame (object on a hidden level).
		# Avoids per-frame shader-param work for every off-level shadow.
		if not obj.is_visible_in_tree():
			continue
		if not obj.has_meta(SHADOW_META_KEY) or not obj.has_meta("_shadow_offset"):
			continue
		var nodes = obj.get_meta(SHADOW_META_KEY)
		if not (nodes is Array) or nodes.size() == 0:
			continue

		var sprite = get_sprite(obj)
		if sprite == null:
			# Roof node: shadow container position = just the offset (no sprite offset)
			var offset = obj.get_meta("_shadow_offset") as Vector2
			var local_offset = _world_to_local_offset(obj, offset)
			for node in nodes:
				if is_instance_valid(node):
					if node.position != local_offset:
						node.position = local_offset
			continue

		var offset = obj.get_meta("_shadow_offset") as Vector2
		var local_offset = _world_to_local_offset(obj, offset)

		# Shadow is always a child of obj — parent transform handles rotation,
		# scale, and mirror implicitly. Only position needs an explicit update
		# in case the prop's sprite offset shifted.
		# Recompute the under-asset cut shift too: local_offset rotates with the asset.
		var rt_tex_size = sprite.texture.get_size()
		if sprite.region_enabled:
			rt_tex_size = sprite.region_rect.size
		var rt_projected = false
		if obj.has_meta("_shadow_config"):
			var rcfg = obj.get_meta("_shadow_config")
			if rcfg is Dictionary:
				rt_projected = rcfg.get("shadow_mode", "offset") == "projected"
		var rt_cut = Vector2.ZERO
		if not rt_projected and rt_tex_size.x >= 1.0 and rt_tex_size.y >= 1.0:
			rt_cut = Vector2(local_offset.x / rt_tex_size.x, local_offset.y / rt_tex_size.y)
		for node in nodes:
			if not is_instance_valid(node):
				continue
			var target_pos = sprite.position + local_offset
			if node.position != target_pos:
				node.position = target_pos
			if node.material is ShaderMaterial:
				node.material.set_shader_param("cut_offset", rt_cut)

		# Projected shadows: the cast direction follows the LIGHT, not the asset.
		# The shadow sprite is a child of the (rotating) asset, so re-derive the
		# local proj_dir from the world angle every frame — rotating the asset then
		# leaves the shadow pointing the same way in the world (like offset does).
		# Projected shadows always stay live, so this just updates the shader param.
		if obj.has_meta("_shadow_config"):
			var pcfg = obj.get_meta("_shadow_config")
			if pcfg is Dictionary and pcfg.get("shadow_mode", "offset") == "projected":
				var pang = pcfg.get("proj_angle", 0.0)
				var wdir = Vector2(cos(pang), sin(pang))
				var ldir = obj.global_transform.affine_inverse().basis_xform(wdir)
				ldir = ldir.normalized() if ldir.length() > 0.0001 else Vector2(0.0, 1.0)
				for node in nodes:
					if is_instance_valid(node) and node.material is ShaderMaterial:
						node.material.set_shader_param("proj_dir", ldir)

		# Update clip planes if clipping is active
		if obj.has_meta("_shadow_clip_tex") and obj.has_meta("_shadow_config"):
			var config = obj.get_meta("_shadow_config")
			var clip_walls = config.get("clip_walls", false)
			var clip_paths = config.get("clip_paths", false)
			if clip_walls or clip_paths:
				var shadow_sprite = nodes[0]
				if is_instance_valid(shadow_sprite):
					if _clip_should_recompute(obj, config):
						_update_clip_planes(obj, shadow_sprite, config)

	# Also sync ObjectTool preview shadow (not in _all_known_obj_ids).
	# Same simple logic as placed objects: shadow is a child, position only.
	if _obj_tool_preview_node != null and is_instance_valid(_obj_tool_preview_node):
		var preview = _obj_tool_preview_node
		if preview.has_meta(SHADOW_META_KEY) and preview.has_meta("_shadow_offset"):
			var pnodes = preview.get_meta(SHADOW_META_KEY)
			if pnodes is Array and pnodes.size() > 0:
				var p_sprite = get_sprite(preview)
				if p_sprite != null:
					var p_offset = preview.get_meta("_shadow_offset") as Vector2
					for snode in pnodes:
						if is_instance_valid(snode):
							snode.global_position = p_sprite.global_position + p_offset

func on_selection_changed():
	_monitored_object = null

	if global.Editor.Tools["SelectTool"].Selected.size() > 0:
		var node = global.Editor.Tools["SelectTool"].Selected[0]
		if is_shadow_node_type(node):
			_reparent_ui_to_node(node)
			_monitored_object = node
			load_shadow_ui_from_object(node)
			return

	# No valid object selected — hide UI
	var container = ui_config.get("container")
	if container != null and container.get_parent() != null:
		container.get_parent().remove_child(container)

#########################################################################################################
##
## SELECT TOOL UI
##
#########################################################################################################

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	image.load(global.Root + icon_path)
	if scale != 1.0:
		var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
		image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _make_icon_button(icon_path: String, tooltip: String, icon_scale: float = 1.0) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	btn.icon = _load_icon(icon_path, icon_scale)
	return btn

func _load_uniform_icons(paths: Array, scale = 1.0) -> Array:
	"""Load multiple icons and pad each one to the largest dimensions among them
	so all returned ImageTextures share IDENTICAL pixel sizes. Each original is
	centered on a transparent canvas of (max_w, max_h).

	`scale` may be either a single float (applied to every icon) or an Array of
	floats matching `paths` length (one scale per icon — useful when one icon in
	the row should look slightly larger or smaller than the rest while still
	sharing the row's uniform layout).

	Why this exists: Godot 3.4's Button widget renders Button.icon left-aligned
	(no icon_alignment property — that's Godot 4 only). For an icon-only Button
	row where icons have slightly different source PNG widths, this means the
	icon CENTERS sit at different X-offsets within their button, which propagates
	out: even if every button is centered in an equal-width cell, the icon centers
	end up unequally spaced. Padding the icons to a common size collapses that
	difference at the source — every Button.icon is now visually centered around
	the same point inside its button, and the row reads as evenly distributed."""
	# Normalize `scale` to a per-icon array so the loop below has a single shape.
	var scales = []
	if scale is Array:
		scales = scale
	if scales.size() != paths.size():
		var fallback = 1.0 if scale is Array else float(scale)
		scales = []
		for _i in range(paths.size()):
			scales.append(fallback)

	var images = []
	var max_w = 0
	var max_h = 0
	for idx in range(paths.size()):
		var path = paths[idx]
		var per_icon_scale = float(scales[idx])
		var img = Image.new()
		if img.load(global.Root + path) != OK:
			images.append(null)
			continue
		if per_icon_scale != 1.0:
			img.resize(int(img.get_width() * per_icon_scale), int(img.get_height() * per_icon_scale), Image.INTERPOLATE_LANCZOS)
		# Normalize to RGBA8 so blit_rect always has a compatible target format.
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		images.append(img)
		if img.get_width() > max_w:
			max_w = img.get_width()
		if img.get_height() > max_h:
			max_h = img.get_height()
	var textures = []
	for img in images:
		if img == null:
			textures.append(null)
			continue
		var tex = ImageTexture.new()
		# Already at max size — no padding needed, skip the blit.
		if img.get_width() == max_w and img.get_height() == max_h:
			tex.create_from_image(img)
			textures.append(tex)
			continue
		var padded = Image.new()
		padded.create(max_w, max_h, false, Image.FORMAT_RGBA8)
		padded.fill(Color(0, 0, 0, 0))
		var ofs_x = int((max_w - img.get_width()) / 2)
		var ofs_y = int((max_h - img.get_height()) / 2)
		padded.blit_rect(img,
			Rect2(Vector2(0, 0), Vector2(img.get_width(), img.get_height())),
			Vector2(ofs_x, ofs_y))
		tex.create_from_image(padded)
		textures.append(tex)
	return textures

func build_select_tool_ui():
	var select_panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	var obj_vbox = select_panel.objectOptions
	ui_config["_obj_parent"] = obj_vbox

	var container = VBoxContainer.new()
	container.name = "DropShadowObjectsContainer"
	ui_config["container"] = container

	var separator = HSeparator.new()
	separator.add_constant_override("separation", 8)
	container.add_child(separator)

	# Title row: "Soft Shadow" [reset] [cog] [ON/OFF]
	var title_hbox = HBoxContainer.new()
	var sun_icon = _create_sun_icon()
	if sun_icon != null:
		title_hbox.add_child(sun_icon)
	var title = Label.new()
	title.text = "Soft Shadow"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title)
	var title_reset_btn = _make_icon_button("icons/reset.png", "Reset to defaults", 0.5)
	title_reset_btn.visible = false
	title_reset_btn.connect("pressed", self, "_on_reset_pressed")
	title_hbox.add_child(title_reset_btn)
	ui_config["title_reset_btn"] = title_reset_btn
	var settings_toggle = _make_icon_button("icons/cog.png", "Show/hide settings", 0.55)
	settings_toggle.toggle_mode = true
	settings_toggle.pressed = false
	settings_toggle.visible = false
	settings_toggle.connect("toggled", self, "_on_settings_toggled")
	title_hbox.add_child(settings_toggle)
	ui_config["settings_toggle"] = settings_toggle
	var enable_check = CheckButton.new()
	enable_check.pressed = false
	enable_check.connect("toggled", self, "_on_setting_changed")
	title_hbox.add_child(enable_check)
	container.add_child(title_hbox)
	ui_config["enable_check"] = enable_check

	# ===== Settings panel (hidden by default) =====
	var settings_panel = VBoxContainer.new()
	settings_panel.name = "SettingsPanel"
	settings_panel.visible = false

	# -- Opacity: [Label] [Slider] [SpinBox] [Reset] --
	var opacity_hbox = HBoxContainer.new()
	var opacity_label = Label.new()
	opacity_label.text = "Opacity"
	opacity_label.rect_min_size.x = 60
	opacity_hbox.add_child(opacity_label)
	var opacity_slider = HSlider.new()
	opacity_slider.min_value = 0.05
	opacity_slider.max_value = 1.0
	opacity_slider.step = 0.01
	opacity_slider.value = DEFAULT_SHADOW_CONFIG["opacity"]
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	opacity_slider.connect("value_changed", self, "_on_slider_changed", ["opacity"])
	opacity_hbox.add_child(opacity_slider)
	ui_config["opacity_slider"] = opacity_slider
	var opacity_spin = SpinBox.new()
	opacity_spin.min_value = 0.05
	opacity_spin.max_value = 1.0
	opacity_spin.step = 0.01
	opacity_spin.value = DEFAULT_SHADOW_CONFIG["opacity"]
	opacity_spin.connect("value_changed", self, "_on_spin_changed", ["opacity"])
	opacity_hbox.add_child(opacity_spin)
	ui_config["opacity_spin"] = opacity_spin
	var opacity_reset = _make_icon_button("icons/reset.png", "Reset opacity", 0.5)
	opacity_reset.connect("pressed", self, "_on_single_reset", ["opacity"])
	opacity_hbox.add_child(opacity_reset)
	settings_panel.add_child(opacity_hbox)

	# -- Blur: [Label] [Slider] [SpinBox] [Reset] --
	var size_hbox = HBoxContainer.new()
	var size_label = Label.new()
	size_label.text = "Blur"
	size_label.rect_min_size.x = 60
	size_hbox.add_child(size_label)
	var size_slider = HSlider.new()
	size_slider.min_value = 0.0
	size_slider.max_value = 1.0
	size_slider.step = 0.01
	size_slider.value = DEFAULT_SHADOW_CONFIG["blur"]
	size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	size_slider.connect("value_changed", self, "_on_slider_changed", ["blur"])
	size_hbox.add_child(size_slider)
	ui_config["blur_slider"] = size_slider
	var size_spin = SpinBox.new()
	size_spin.min_value = 0.0
	size_spin.max_value = 1.0
	size_spin.step = 0.01
	size_spin.value = DEFAULT_SHADOW_CONFIG["blur"]
	size_spin.connect("value_changed", self, "_on_spin_changed", ["blur"])
	size_hbox.add_child(size_spin)
	ui_config["blur_spin"] = size_spin
	var size_reset = _make_icon_button("icons/reset.png", "Reset blur", 0.5)
	size_reset.connect("pressed", self, "_on_single_reset", ["blur"])
	size_hbox.add_child(size_reset)
	settings_panel.add_child(size_hbox)

	# -- Quality: [Label] [slider────] [spin %] [lock toggle] [apply_all toggle] --
	# Trades GPU cost for visual fidelity. Stored as int 0..100, scaling the
	# auto-computed blur_quality + blur_steps shader params. The lock toggle
	# constrains the slider to the 4 tier values 25/50/75/100 (default ON,
	# matches the previous tier-button UX); when released, the slider becomes
	# a free-form 0..100 fine-tune.
	var quality_hbox = HBoxContainer.new()
	quality_hbox.add_constant_override("separation", 4)
	var quality_label = Label.new()
	quality_label.text = "Quality"
	quality_label.rect_min_size.x = 60
	quality_label.hint_tooltip = "Lower = faster GPU rendering, slightly grainier soft edges"
	quality_hbox.add_child(quality_label)

	var default_quality = DEFAULT_SHADOW_CONFIG.get("quality", FACTORY_DEFAULTS["quality"])
	var lock_active = _is_quality_lock_active()
	var snap_step = QUALITY_TIER_VALUES[1] - QUALITY_TIER_VALUES[0]  # 25, derived from tier values

	# Lock toggle (left of slider): pressed = locked (snap to tiers), released =
	# unlocked (free). Icon swaps via _update_quality_lock_icon. Persisted in
	# ModMapData so the user preference sticks across map saves.
	var quality_lock = Button.new()
	quality_lock.toggle_mode = true
	quality_lock.pressed = lock_active
	quality_lock.hint_tooltip = "Lock to 4 quality tiers (unlocked = free fine-tune 0..100)"
	quality_lock.connect("toggled", self, "_on_quality_lock_toggled")
	quality_hbox.add_child(quality_lock)
	ui_config["quality_lock_btn"] = quality_lock
	_update_quality_lock_icon(lock_active)

	var quality_slider = HSlider.new()
	quality_slider.min_value = 0
	quality_slider.max_value = 100
	quality_slider.step = snap_step if lock_active else 1
	quality_slider.value = default_quality
	quality_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	quality_slider.connect("value_changed", self, "_on_quality_slider_changed")
	quality_hbox.add_child(quality_slider)
	ui_config["quality_slider"] = quality_slider

	var quality_spin = SpinBox.new()
	quality_spin.min_value = 0
	quality_spin.max_value = 100
	quality_spin.step = snap_step if lock_active else 1
	quality_spin.suffix = "%"
	quality_spin.value = default_quality
	quality_spin.connect("value_changed", self, "_on_quality_spin_changed")
	quality_hbox.add_child(quality_spin)
	ui_config["quality_spin"] = quality_spin

	# Apply-to-all toggle: when pressed, the current quality is broadcast to all
	# objects on the level immediately, and any subsequent slider change
	# auto-propagates until the toggle is released. Stateful so the user sees at
	# a glance whether broadcast mode is active. Snapshot of pre-broadcast values
	# is restored when the toggle is released (and persists across map saves).
	var quality_apply_all = _make_icon_button(
		"icons/apply_all.png",
		"Toggle: when on, quality changes propagate to all objects on this level",
		0.85)
	quality_apply_all.toggle_mode = true
	quality_apply_all.pressed = false
	quality_apply_all.connect("toggled", self, "_on_quality_apply_all_toggled")
	quality_hbox.add_child(quality_apply_all)
	ui_config["quality_apply_all_btn"] = quality_apply_all

	settings_panel.add_child(quality_hbox)

	# -- Offset: Circular Dial --
	var offset_vbox = VBoxContainer.new()
	var offset_header = HBoxContainer.new()
	# Distance label + spin
	var dist_label2 = Label.new()
	dist_label2.text = "Distance"
	offset_header.add_child(dist_label2)
	var dist_offset_spin = SpinBox.new()
	dist_offset_spin.min_value = 0
	dist_offset_spin.max_value = 100
	dist_offset_spin.step = 1
	dist_offset_spin.value = 0
	dist_offset_spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dist_offset_spin.rect_min_size.x = 85
	dist_offset_spin.connect("value_changed", self, "_on_offset_spin_changed")
	offset_header.add_child(dist_offset_spin)
	ui_config["dist_spin"] = dist_offset_spin
	# Angle label + spin
	var angle_label2 = Label.new()
	angle_label2.text = "Angle"
	offset_header.add_child(angle_label2)
	var angle_spin = SpinBox.new()
	angle_spin.min_value = 0
	angle_spin.max_value = 359
	angle_spin.step = 1
	angle_spin.value = 0
	angle_spin.suffix = "°"
	angle_spin.allow_greater = false
	angle_spin.allow_lesser = false
	angle_spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	angle_spin.rect_min_size.x = 72
	angle_spin.connect("value_changed", self, "_on_offset_spin_changed")
	offset_header.add_child(angle_spin)
	ui_config["angle_spin"] = angle_spin
	# Hidden internal spins for offset_x / offset_y (not displayed)
	var offx_spin = SpinBox.new()
	offx_spin.min_value = -100
	offx_spin.max_value = 100
	offx_spin.step = 1
	offx_spin.value = 0
	offx_spin.visible = false
	offset_vbox.add_child(offx_spin)
	ui_config["offset_x_spin"] = offx_spin
	var offy_spin = SpinBox.new()
	offy_spin.min_value = -100
	offy_spin.max_value = 100
	offy_spin.step = 1
	offy_spin.value = 0
	offy_spin.visible = false
	offset_vbox.add_child(offy_spin)
	ui_config["offset_y_spin"] = offy_spin
	var offset_reset = _make_icon_button("icons/reset.png", "Reset offset", 0.5)
	offset_reset.connect("pressed", self, "_on_single_reset", ["offset"])
	offset_header.add_child(offset_reset)
	offset_vbox.add_child(offset_header)

	# The dial
	var dial_container = CenterContainer.new()
	dial_container.rect_clip_content = false
	var dial_margin = MarginContainer.new()
	dial_margin.rect_clip_content = false
	dial_margin.add_constant_override("margin_left", 8)
	dial_margin.add_constant_override("margin_right", 8)
	dial_margin.add_constant_override("margin_top", 8)
	dial_margin.add_constant_override("margin_bottom", 8)
	var dial = _create_dial(90, OFFSET_MAX)
	dial_margin.add_child(dial)
	dial_container.add_child(dial_margin)
	offset_vbox.add_child(dial_container)

	settings_panel.add_child(offset_vbox)

	# -- Range: [Label] [Slider] [SpinBox] [Reset] -- controls dial max offset
	var dist_hbox = HBoxContainer.new()
	var dist_label = Label.new()
	dist_label.text = "Max Distance"
	dist_label.rect_min_size.x = 85
	dist_hbox.add_child(dist_label)
	var dist_slider = HSlider.new()
	dist_slider.min_value = 1.0
	dist_slider.max_value = 20.0
	dist_slider.step = 0.1
	dist_slider.value = DEFAULT_SHADOW_CONFIG["range"]
	dist_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dist_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dist_slider.connect("value_changed", self, "_on_slider_changed", ["range"])
	dist_hbox.add_child(dist_slider)
	ui_config["range_slider"] = dist_slider
	var dist_spin = SpinBox.new()
	dist_spin.min_value = 1.0
	dist_spin.max_value = 20.0
	dist_spin.step = 0.1
	dist_spin.value = DEFAULT_SHADOW_CONFIG["range"]
	dist_spin.connect("value_changed", self, "_on_spin_changed", ["range"])
	dist_hbox.add_child(dist_spin)
	ui_config["range_spin"] = dist_spin
	var dist_reset = _make_icon_button("icons/reset.png", "Reset max distance", 0.5)
	dist_reset.connect("pressed", self, "_on_single_reset", ["range"])
	dist_hbox.add_child(dist_reset)
	settings_panel.add_child(dist_hbox)

	# === Projected (shape) shadow controls ==========================================
	# Hidden unless Style = Projected. The shadow is the asset's silhouette swept
	# (Extrude) or stretched (Stretch) along the light direction — a soft angled
	# smudge that reads well in top-down (where there is no real height to project).
	var proj_vbox = VBoxContainer.new()
	proj_vbox.name = "ProjPanel"

	# --- Direction dial (like offset mode): Distance + Angle header, rings, snaps ---
	var proj_header = HBoxContainer.new()
	var pdist_label = Label.new()
	pdist_label.text = "Distance"
	proj_header.add_child(pdist_label)
	var pdist_spin = SpinBox.new()
	pdist_spin.min_value = 0.0
	pdist_spin.max_value = PROJ_MAX_LENGTH
	pdist_spin.step = 0.05
	pdist_spin.value = 0.0
	pdist_spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pdist_spin.rect_min_size.x = 72
	pdist_spin.connect("value_changed", self, "_on_proj_dist_changed")
	proj_header.add_child(pdist_spin)
	ui_config["proj_dist_spin"] = pdist_spin
	var pdist_reset = _make_icon_button("icons/reset.png", "Reset distance", 0.5)
	pdist_reset.connect("pressed", self, "_on_proj_dist_reset")
	proj_header.add_child(pdist_reset)
	var pang_label = Label.new()
	pang_label.text = "Angle"
	proj_header.add_child(pang_label)
	var psun_spin = SpinBox.new()
	psun_spin.min_value = 0
	psun_spin.max_value = 359
	psun_spin.step = 1
	psun_spin.value = 0
	psun_spin.suffix = "°"
	psun_spin.allow_greater = false
	psun_spin.allow_lesser = false
	psun_spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	psun_spin.rect_min_size.x = 60
	psun_spin.connect("value_changed", self, "_on_proj_angle_changed")
	proj_header.add_child(psun_spin)
	ui_config["proj_sun_angle_spin"] = psun_spin
	var pang_reset = _make_icon_button("icons/reset.png", "Reset angle", 0.5)
	pang_reset.connect("pressed", self, "_on_proj_angle_reset")
	proj_header.add_child(pang_reset)
	proj_vbox.add_child(proj_header)

	var pdial_container = CenterContainer.new()
	pdial_container.rect_clip_content = false
	var pdial_margin = MarginContainer.new()
	pdial_margin.rect_clip_content = false
	pdial_margin.add_constant_override("margin_left", 8)
	pdial_margin.add_constant_override("margin_right", 8)
	pdial_margin.add_constant_override("margin_top", 8)
	pdial_margin.add_constant_override("margin_bottom", 8)
	var pdial = _create_proj_dirlen_dial(90)
	pdial_margin.add_child(pdial)
	pdial_container.add_child(pdial_margin)
	proj_vbox.add_child(pdial_container)

	# Fade slider (estompe vers la pointe)
	var fade_hbox = HBoxContainer.new()
	var fade_label = Label.new()
	fade_label.text = "Fade"
	fade_label.rect_min_size.x = 85
	fade_hbox.add_child(fade_label)
	var fade_slider = HSlider.new()
	fade_slider.min_value = 0.0
	fade_slider.max_value = 1.0
	fade_slider.step = 0.05
	fade_slider.value = 0.5
	fade_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fade_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fade_slider.connect("value_changed", self, "_on_proj_fade_changed")
	fade_hbox.add_child(fade_slider)
	ui_config["proj_fade_slider"] = fade_slider
	var fade_spin = SpinBox.new()
	fade_spin.min_value = 0.0
	fade_spin.max_value = 1.0
	fade_spin.step = 0.05
	fade_spin.value = 0.5
	fade_spin.connect("value_changed", self, "_on_proj_fade_changed")
	fade_hbox.add_child(fade_spin)
	ui_config["proj_fade_spin"] = fade_spin
	var fade_reset = _make_icon_button("icons/reset.png", "Reset fade", 0.5)
	fade_reset.connect("pressed", self, "_on_proj_fade_reset")
	fade_hbox.add_child(fade_reset)
	proj_vbox.add_child(fade_hbox)

	# Cone slider (-0.8 = pointe élargie, +0.8 = pointe affinée) — stretch uniquement
	var tap_hbox = HBoxContainer.new()
	var tap_label = Label.new()
	tap_label.text = "Cone"
	tap_label.rect_min_size.x = 85
	tap_hbox.add_child(tap_label)
	var tap_slider = HSlider.new()
	tap_slider.min_value = -0.8
	tap_slider.max_value = 0.8
	tap_slider.step = 0.05
	tap_slider.value = 0.0
	tap_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tap_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tap_slider.connect("value_changed", self, "_on_proj_taper_changed")
	tap_hbox.add_child(tap_slider)
	ui_config["proj_taper_slider"] = tap_slider
	var tap_spin = SpinBox.new()
	tap_spin.min_value = -0.8
	tap_spin.max_value = 0.8
	tap_spin.step = 0.05
	tap_spin.value = 0.0
	tap_spin.connect("value_changed", self, "_on_proj_taper_changed")
	tap_hbox.add_child(tap_spin)
	ui_config["proj_taper_spin"] = tap_spin
	var tap_reset = _make_icon_button("icons/reset.png", "Reset cone", 0.5)
	tap_reset.connect("pressed", self, "_on_proj_cone_reset")
	tap_hbox.add_child(tap_reset)
	proj_vbox.add_child(tap_hbox)
	_update_proj_taper_enabled(true)  # Cone enabled only in Projected (Stretch)

	proj_vbox.visible = false
	settings_panel.add_child(proj_vbox)
	settings_panel.move_child(proj_vbox, dist_hbox.get_index() + 1)
	ui_config["proj_panel"] = proj_vbox

	# Mode toggle, placed ABOVE the offset controls
	var mode_hbox = HBoxContainer.new()
	var mode_label = Label.new()
	mode_label.text = "Style"
	mode_label.rect_min_size.x = 85
	mode_hbox.add_child(mode_label)
	var mode_opt = OptionButton.new()
	mode_opt.add_item("Offset", 0)
	mode_opt.add_item("Projected (Extrude)", 1)
	mode_opt.add_item("Projected (Stretch)", 2)
	mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_opt.connect("item_selected", self, "_on_shadow_mode_selected")
	mode_hbox.add_child(mode_opt)
	ui_config["mode_opt"] = mode_opt
	settings_panel.add_child(mode_hbox)
	settings_panel.move_child(mode_hbox, offset_vbox.get_index())
	ui_config["offset_mode_nodes"] = [offset_vbox, dist_hbox]
	_update_shadow_mode_visibility(0)
	# === end projected controls =====================================================

	# -- Color picker --
	var color_hbox = HBoxContainer.new()
	var color_label = Label.new()
	color_label.text = "Color"
	color_label.rect_min_size.x = 60
	color_hbox.add_child(color_label)
	var color_picker = ColorPickerButton.new()
	color_picker.color = DEFAULT_SHADOW_CONFIG["shadow_color"]
	color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_picker.connect("color_changed", self, "_on_color_changed")
	color_picker.connect("pressed", self, "_disable_color_pipette", [color_picker])
	color_hbox.add_child(color_picker)
	ui_config["shadow_color_picker"] = color_picker
	var color_reset = _make_icon_button("icons/reset.png", "Reset color", 0.5)
	color_reset.connect("pressed", self, "_on_single_reset", ["shadow_color"])
	color_hbox.add_child(color_reset)
	settings_panel.add_child(color_hbox)

	container.add_child(settings_panel)
	ui_config["settings_panel"] = settings_panel

	# ===== Behind layer toggle =====
	var behind_hbox = HBoxContainer.new()
	var behind_label = Label.new()
	behind_label.text = "Shadow behind layer"
	behind_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	behind_hbox.add_child(behind_label)
	var behind_check = CheckButton.new()
	behind_check.pressed = DEFAULT_SHADOW_CONFIG.get("behind_layer", false)
	behind_check.connect("toggled", self, "_on_behind_layer_toggled")
	behind_hbox.add_child(behind_check)
	ui_config["behind_layer_check"] = behind_check
	settings_panel.add_child(behind_hbox)

	# ===== Clip by walls toggle =====
	var clip_walls_hbox = HBoxContainer.new()
	var clip_walls_label = Label.new()
	clip_walls_label.text = "Stopped by walls"
	clip_walls_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_walls_hbox.add_child(clip_walls_label)
	var clip_walls_check = CheckButton.new()
	clip_walls_check.pressed = DEFAULT_SHADOW_CONFIG.get("clip_walls", false)
	clip_walls_check.connect("toggled", self, "_on_clip_walls_toggled")
	clip_walls_hbox.add_child(clip_walls_check)
	ui_config["clip_walls_check"] = clip_walls_check
	settings_panel.add_child(clip_walls_hbox)

	# ===== Clip by paths toggle =====
	var clip_paths_hbox = HBoxContainer.new()
	var clip_paths_label = Label.new()
	clip_paths_label.text = "Stopped by paths"
	clip_paths_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_paths_hbox.add_child(clip_paths_label)
	var clip_paths_check = CheckButton.new()
	clip_paths_check.pressed = DEFAULT_SHADOW_CONFIG.get("clip_paths", false)
	clip_paths_check.connect("toggled", self, "_on_clip_paths_toggled")
	clip_paths_hbox.add_child(clip_paths_check)
	ui_config["clip_paths_check"] = clip_paths_check
	settings_panel.add_child(clip_paths_hbox)

	# ===== Defaults row: [Use as Default Values] [Reset Defaults] =====
	var defaults_hbox = HBoxContainer.new()
	var use_default_btn = Button.new()
	use_default_btn.text = "Use as Default Values"
	use_default_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	use_default_btn.connect("pressed", self, "_on_use_as_default")
	defaults_hbox.add_child(use_default_btn)
	var reset_defaults_btn = Button.new()
	reset_defaults_btn.text = "Reset Defaults"
	reset_defaults_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_defaults_btn.visible = false
	reset_defaults_btn.connect("pressed", self, "_on_reset_defaults")
	defaults_hbox.add_child(reset_defaults_btn)
	ui_config["reset_defaults_btn"] = reset_defaults_btn
	settings_panel.add_child(defaults_hbox)
	ui_config["defaults_hbox"] = defaults_hbox

	# ===== Actions row: [Shadow label] [Reset] [Copy] [Paste] =====
	var actions_hbox = HBoxContainer.new()
	var shadow_label = Label.new()
	shadow_label.text = "Shadow"
	shadow_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions_hbox.add_child(shadow_label)
	var action_reset_btn = Button.new()
	action_reset_btn.text = "Reset"
	action_reset_btn.icon = _load_icon("icons/reset.png", 0.5)
	action_reset_btn.hint_tooltip = "Reset shadow to defaults"
	action_reset_btn.connect("pressed", self, "_on_reset_pressed")
	actions_hbox.add_child(action_reset_btn)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.icon = _load_icon("icons/copy.png", 0.5)
	copy_btn.hint_tooltip = "Copy shadow settings"
	copy_btn.connect("pressed", self, "_on_copy_shadow")
	actions_hbox.add_child(copy_btn)
	var paste_btn = Button.new()
	paste_btn.text = "Paste"
	paste_btn.icon = _load_icon("icons/paste.png", 0.5)
	paste_btn.hint_tooltip = "Paste shadow settings to selected"
	paste_btn.connect("pressed", self, "_on_paste_shadow")
	actions_hbox.add_child(paste_btn)
	settings_panel.add_child(actions_hbox)
	ui_config["actions_hbox"] = actions_hbox

	# ===== Apply to All button =====
	var apply_all_btn = Button.new()
	apply_all_btn.text = "Apply Shadow to all Objects"
	apply_all_btn.hint_tooltip = "Apply current shadow settings to all objects on this level"
	apply_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_all_btn.connect("pressed", self, "_on_apply_all_pressed")
	settings_panel.add_child(apply_all_btn)
	ui_config["apply_all_btn"] = apply_all_btn

	# Custom apply-all dialog with 4 options
	var apply_dialog = AcceptDialog.new()
	apply_dialog.window_title = "Apply Shadow"
	apply_dialog.get_ok().text = "Every object"
	apply_dialog.get_ok().connect("pressed", self, "_on_apply_all_confirmed", ["all"])
	var no_shadow_btn = apply_dialog.add_button("Every object with no shadow", false, "no_shadow")
	var selected_btn = apply_dialog.add_button("Selected objects", false, "selected")
	apply_dialog.add_cancel("Cancel")
	apply_dialog.connect("custom_action", self, "_on_apply_all_confirmed")

	# Build inner layout: question label + layer scope radios
	var dialog_vbox = VBoxContainer.new()
	dialog_vbox.add_constant_override("separation", 10)
	var question_label = Label.new()
	question_label.text = "Which objects do you want to apply this shadow on?"
	question_label.align = Label.ALIGN_CENTER
	dialog_vbox.add_child(question_label)

	# Layer scope radio row (radio dot icons, same style as Sides)
	var scope_hbox = HBoxContainer.new()
	scope_hbox.add_constant_override("separation", 4)
	var scope_label = Label.new()
	scope_label.text = "Layers:"
	scope_hbox.add_child(scope_label)
	var scope_names = ["All layers", "Current layer", "Filtered layers"]
	var scope_keys = ["all_layers", "current_layer", "filtered_layers"]
	for i in range(scope_names.size()):
		var btn = Button.new()
		btn.text = scope_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == 1)  # "Current layer" default
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_CENTER
		btn.connect("pressed", self, "_on_scope_radio_pressed", [i])
		scope_hbox.add_child(btn)
		ui_config["scope_btn_" + str(i)] = btn
	dialog_vbox.add_child(scope_hbox)
	apply_dialog.add_child(dialog_vbox)
	# Inherit the editor theme by adding to the Windows container (where DD puts its own dialogs)
	var windows_container = global.Editor.get_node("Windows")
	if windows_container != null:
		windows_container.add_child(apply_dialog)
	else:
		global.Editor.add_child(apply_dialog)
	ui_config["apply_all_dialog"] = apply_dialog

	# Deferred styling: center text label and add outline to buttons after dialog is in tree
	var style_timer = Timer.new()
	style_timer.wait_time = 0.1
	style_timer.one_shot = true
	style_timer.connect("timeout", self, "_style_apply_dialog", [style_timer])
	global.Editor.add_child(style_timer)
	style_timer.start()

func _style_apply_dialog(timer: Timer):
	timer.queue_free()
	var dialog = ui_config.get("apply_all_dialog")
	if dialog == null:
		return
	# Hide the default (empty) dialog_text label — we use our own in the VBoxContainer
	for child in dialog.get_children():
		if child is Label and child.text == "":
			child.visible = false
	# Add outline to buttons on top of inherited theme style
	for child in dialog.get_children():
		if child is HBoxContainer:
			for btn in child.get_children():
				if btn is Button:
					var existing = btn.get_stylebox("normal")
					if existing != null and existing is StyleBoxFlat:
						var s = existing.duplicate()
						s.border_color = Color(0.6, 0.6, 0.6, 0.7)
						s.set_border_width_all(1)
						btn.add_stylebox_override("normal", s)
						var h = existing.duplicate()
						h.border_color = Color(0.8, 0.8, 0.8, 0.9)
						h.set_border_width_all(2)
						btn.add_stylebox_override("hover", h)
	# Set scope radio icons (needs theme to be inherited first)
	_update_scope_radio_icons(1)

var _obj_tool_toggle: CheckButton = null
var _scatter_tool_toggle: CheckButton = null
var _obj_tool_lock_btn: Button = null
var _scatter_tool_lock_btn: Button = null
var _obj_tool_use_defaults: bool = true  # true = lock (use defaults), false = unlock (use custom)
var _obj_tool_insert_parent = null
var _obj_tool_insert_idx = -1
var _obj_tool_preview_node = null
var _obj_tool_preview_tex = null  # track texture to detect asset change

func _find_shadow_checkbox(node, path):
	"""Recursively find the native 'Shadow' CheckButton in ObjectTool."""
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is CheckButton:
			var t = child.text
			if t != null and "shadow" in t.to_lower():
				_obj_tool_insert_parent = node
				_obj_tool_insert_idx = i + 1
				return
		if child.get_child_count() > 0:
			_find_shadow_checkbox(child, path)
			if _obj_tool_insert_parent != null:
				return

func build_object_tool_ui():
	# Try common names for the object placement tool
	var tool_names = ["ObjectTool", "ObjectsTool", "PlaceObjectTool", "PlaceTool"]
	var obj_tool_panel = null
	for tn in tool_names:
		obj_tool_panel = global.Editor.Toolset.GetToolPanel(tn)
		if obj_tool_panel != null:
			outputlog("Found object tool panel as: " + tn, 0)
			break
	if obj_tool_panel == null:
		# List all available tools
		var tools_str = ""
		for key in global.Editor.Tools.keys():
			tools_str += key + ", "
		outputlog("ObjectTool panel not found. Available tools: " + tools_str, 0)
		return
	
	# Find the native "Shadow" CheckButton and insert after it
	var target_parent = null
	var insert_idx = -1
	_find_shadow_checkbox(obj_tool_panel, [])
	
	var ot_wrapper = VBoxContainer.new()
	ot_wrapper.name = "SoftShadowObjectToolWrapper"
	
	var ot_sep_top = HSeparator.new()
	ot_sep_top.add_constant_override("separation", 4)
	ot_wrapper.add_child(ot_sep_top)
	
	var ot_container = HBoxContainer.new()
	ot_container.name = "DropShadowObjectTool"
	
	var ot_sun = _create_sun_icon()
	if ot_sun != null:
		ot_container.add_child(ot_sun)
	var label = Label.new()
	label.text = "Soft Shadow"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ot_container.add_child(label)
	
	var ot_lock = Button.new()
	ot_lock.icon = _load_icon("icons/lock.png", 0.75)
	ot_lock.hint_tooltip = "Using default values (click to use custom)"
	# Always visible, but disabled (greyed) when not usable — gives consistent
	# layout instead of the row jumping around as the lock appears/disappears.
	ot_lock.disabled = true
	ot_lock.flat = true
	ot_lock.connect("pressed", self, "_on_lock_btn_pressed")
	ot_container.add_child(ot_lock)
	_obj_tool_lock_btn = ot_lock

	var toggle = CheckButton.new()
	toggle.pressed = false
	toggle.connect("toggled", self, "_on_obj_tool_toggle")
	ot_container.add_child(toggle)
	_obj_tool_toggle = toggle
	
	ot_wrapper.add_child(ot_container)
	
	var ot_sep_bottom = HSeparator.new()
	ot_sep_bottom.add_constant_override("separation", 4)
	ot_wrapper.add_child(ot_sep_bottom)
	
	# Try to insert after native Shadow checkbox
	if _obj_tool_insert_parent != null and _obj_tool_insert_idx >= 0:
		_obj_tool_insert_parent.add_child(ot_wrapper)
		_obj_tool_insert_parent.move_child(ot_wrapper, _obj_tool_insert_idx)
		outputlog("ObjectTool Drop Shadow toggle added after native Shadow.", 0)
	else:
		# Fallback: add at end of Align VBox
		var fallback = core.get_align_vbox(obj_tool_panel)
		if fallback == null:
			fallback = obj_tool_panel
		fallback.add_child(ot_wrapper)
		outputlog("ObjectTool Soft Shadow toggle added (fallback).", 0)
	
	# Also add toggle to ScatterBrush tool if available
	build_scatter_tool_ui()

func build_scatter_tool_ui():
	var scatter_names = ["ScatterBrushTool", "ScatterBrush", "ScatterTool"]
	var scatter_panel = null
	for tn in scatter_names:
		scatter_panel = global.Editor.Toolset.GetToolPanel(tn)
		if scatter_panel != null:
			outputlog("Found scatter tool panel as: " + tn, 0)
			break
	if scatter_panel == null:
		outputlog("ScatterTool panel not found (not installed?)", 0)
		return
	
	# Reset search state for scatter panel
	_obj_tool_insert_parent = null
	_obj_tool_insert_idx = -1
	_find_shadow_checkbox(scatter_panel, [])
	
	var st_wrapper = VBoxContainer.new()
	st_wrapper.name = "SoftShadowScatterWrapper"
	
	var st_sep_top = HSeparator.new()
	st_sep_top.add_constant_override("separation", 4)
	st_wrapper.add_child(st_sep_top)
	
	var st_container = HBoxContainer.new()
	st_container.name = "SoftShadowScatterTool"
	
	var st_cloud = _create_sun_icon()
	if st_cloud != null:
		st_container.add_child(st_cloud)
	var st_label = Label.new()
	st_label.text = "Soft Shadow"
	st_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	st_container.add_child(st_label)
	
	var st_lock = Button.new()
	st_lock.icon = _load_icon("icons/lock.png", 0.75)
	st_lock.hint_tooltip = "Using default values (click to use custom)"
	st_lock.disabled = true
	st_lock.flat = true
	st_lock.connect("pressed", self, "_on_lock_btn_pressed")
	st_container.add_child(st_lock)
	_scatter_tool_lock_btn = st_lock

	var st_toggle = CheckButton.new()
	st_toggle.pressed = false
	st_toggle.connect("toggled", self, "_on_obj_tool_toggle")
	st_container.add_child(st_toggle)
	_scatter_tool_toggle = st_toggle
	
	st_wrapper.add_child(st_container)
	
	var st_sep_bottom = HSeparator.new()
	st_sep_bottom.add_constant_override("separation", 4)
	st_wrapper.add_child(st_sep_bottom)
	
	if _obj_tool_insert_parent != null and _obj_tool_insert_idx >= 0:
		_obj_tool_insert_parent.add_child(st_wrapper)
		_obj_tool_insert_parent.move_child(st_wrapper, _obj_tool_insert_idx)
		outputlog("ScatterTool Soft Shadow toggle added after native Shadow.", 0)
	else:
		var fallback = core.get_align_vbox(scatter_panel)
		if fallback == null:
			fallback = scatter_panel
		fallback.add_child(st_wrapper)
		outputlog("ScatterTool Soft Shadow toggle added (fallback).", 0)

func _on_obj_tool_toggle(pressed: bool):
	ui_config["obj_tool_shadow_enabled"] = pressed
	# ObjectTool and ScatterTool share one logical state — mirror the pressed
	# state onto whichever toggle wasn't the one clicked. Block signals so this
	# assignment doesn't re-enter the handler.
	if _obj_tool_toggle != null and _obj_tool_toggle.pressed != pressed:
		set_property_but_block_signals(_obj_tool_toggle, "pressed", pressed)
	if _scatter_tool_toggle != null and _scatter_tool_toggle.pressed != pressed:
		set_property_but_block_signals(_scatter_tool_toggle, "pressed", pressed)
	if not pressed and _obj_tool_preview_node != null:
		if is_instance_valid(_obj_tool_preview_node):
			remove_shadow(_obj_tool_preview_node)
		_obj_tool_preview_node = null
	_update_lock_btn_visibility()

func _get_placement_config() -> Dictionary:
	"""Get the config to use for new object placement.
	   Lock = factory defaults, Unlock = custom defaults (set via 'Use as Default')."""
	if _obj_tool_use_defaults:
		var config = FACTORY_DEFAULTS.duplicate()
		config["enabled"] = true
		return config
	else:
		var config = DEFAULT_SHADOW_CONFIG.duplicate()
		config["enabled"] = true
		return config

func _on_lock_btn_pressed():
	_obj_tool_use_defaults = !_obj_tool_use_defaults
	_update_lock_btn_icon()
	# Force preview recreation with new config
	if _obj_tool_preview_node != null and is_instance_valid(_obj_tool_preview_node):
		remove_shadow(_obj_tool_preview_node)
	_obj_tool_preview_node = null
	_obj_tool_preview_tex = null

func _update_lock_btn_icon():
	var icon_path = "icons/lock.png" if _obj_tool_use_defaults else "icons/unlock.png"
	var tooltip = "Using default values (click to use custom)" if _obj_tool_use_defaults else "Using custom values (click to use defaults)"
	var icon = _load_icon(icon_path, 0.75)
	if _obj_tool_lock_btn != null:
		_obj_tool_lock_btn.icon = icon
		_obj_tool_lock_btn.hint_tooltip = tooltip
	if _scatter_tool_lock_btn != null:
		_scatter_tool_lock_btn.icon = icon
		_scatter_tool_lock_btn.hint_tooltip = tooltip

func _update_lock_btn_visibility():
	# Misnomer: now toggles `disabled` rather than `visible` so the button stays
	# in the layout (greyed) when not usable — clearer affordance than appearing
	# and disappearing. "Usable" = the corresponding tool's shadow toggle is ON
	# AND the panel currently has custom (non-default) values.
	var has_custom = _are_defaults_custom()
	if _obj_tool_lock_btn != null:
		var obj_on = _obj_tool_toggle != null and _obj_tool_toggle.pressed
		_obj_tool_lock_btn.disabled = not (obj_on and has_custom)
	if _scatter_tool_lock_btn != null:
		var scatter_on = false
		var parent = _scatter_tool_lock_btn.get_parent()
		if parent != null:
			for child in parent.get_children():
				if child is CheckButton:
					scatter_on = child.pressed
					break
		_scatter_tool_lock_btn.disabled = not (scatter_on and has_custom)

func _get_obj_tool_preview():
	# Check ObjectTool and ScatterBrush tool for preview
	for tool_name in ["ObjectTool", "ScatterBrushTool", "ScatterBrush", "ScatterTool"]:
		var tool = global.Editor.Tools.get(tool_name)
		if tool == null:
			continue
		for prop_name in ["Preview", "GhostObject", "Object"]:
			var val = tool.get(prop_name)
			if val != null and is_instance_valid(val):
				var sprite = get_sprite(val)
				if sprite != null:
					return val
	return null

func _create_sun_icon() -> TextureRect:
	"""Create the soft shadow icon from icons/cloud.png."""
	var tex = _load_icon("icons/cloud.png", 0.85)
	if tex == null:
		return null
	var rect = TextureRect.new()
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	rect.rect_min_size = Vector2(18, 18)
	return rect

func _disable_color_pipette(picker_btn: ColorPickerButton):
	var picker = picker_btn.get_picker()
	if picker == null:
		return
	for child in picker.get_children():
		if child is ToolButton:
			child.visible = false
			return
	_hide_screen_picker(picker)

func _hide_screen_picker(node):
	for child in node.get_children():
		if child is ToolButton:
			child.visible = false
			return
		if child.get_child_count() > 0:
			_hide_screen_picker(child)

#########################################################################################################
##
## UI EVENT HANDLERS
##
#########################################################################################################

func _on_setting_changed(pressed):
	if _syncing_ui:
		return
	ui_config["settings_toggle"].visible = pressed
	ui_config["title_reset_btn"].visible = pressed
	ui_config["settings_panel"].visible = pressed and ui_config["settings_toggle"].pressed
	# Auto-open settings on first enable
	if pressed:
		ui_config["settings_toggle"].pressed = true
		ui_config["settings_panel"].visible = true
		call_deferred("_scroll_to_bottom")
	apply_shadow_to_selected(true)  # force_all: toggle applies to entire selection

func _scroll_to_bottom():
	# Find the ScrollContainer ancestor and scroll to bottom
	# Use a short timer to let layout complete first
	var node = ui_config.get("container")
	if node == null:
		return
	var timer = Timer.new()
	timer.wait_time = 0.05
	timer.one_shot = true
	timer.connect("timeout", self, "_do_scroll_to_bottom", [timer])
	global.Editor.add_child(timer)
	timer.start()

func _do_scroll_to_bottom(timer: Timer):
	timer.queue_free()
	var node = ui_config.get("container")
	if node == null:
		return
	var scroll = null
	var parent = node.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			scroll = parent
			break
		parent = parent.get_parent()
	if scroll != null:
		scroll.scroll_vertical = int(scroll.get_v_scrollbar().max_value)

func _on_settings_toggled(pressed):
	ui_config["settings_panel"].visible = pressed
	if pressed:
		# Scroll to bottom of the panel so our section is visible
		call_deferred("_scroll_to_bottom")

func _on_slider_changed(value, which):
	if _syncing_ui:
		return
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_spin"].value = value
		"blur":
			ui_config["blur_spin"].value = value
		"range":
			ui_config["range_spin"].value = value
			_update_offset_range(value)
	_syncing_ui = false
	if which == "range":
		apply_shadow_to_selected(false, ["range"])
	else:
		apply_shadow_to_selected(false, [which])

func _on_spin_changed(value, which):
	if _syncing_ui:
		return
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_slider"].value = value
		"blur":
			ui_config["blur_slider"].value = value
		"range":
			ui_config["range_slider"].value = value
			_update_offset_range(value)
	_syncing_ui = false
	if which == "range":
		apply_shadow_to_selected(false, ["range"])
	else:
		apply_shadow_to_selected(false, [which])

func _update_offset_range(new_range_val: float, scale_offset: bool = true):
	"""Update dial max_offset and spin ranges based on Range slider.
	   If scale_offset is true, scales existing offset values proportionally."""
	var new_max = new_range_val * OFFSET_MAX  # range 1 = 100, range 10 = 1000
	
	var old_ox = ui_config["offset_x_spin"].value
	var old_oy = ui_config["offset_y_spin"].value
	var new_ox = old_ox
	var new_oy = old_oy
	
	if scale_offset:
		# Scale existing offset values proportionally
		var old_max = OFFSET_MAX
		if ui_config.has("dial"):
			old_max = ui_config["dial"].get_meta("max_offset") as float
		var scale_ratio = new_max / max(old_max, 1.0)
		new_ox = clamp(old_ox * scale_ratio, -new_max, new_max)
		new_oy = clamp(old_oy * scale_ratio, -new_max, new_max)
	else:
		new_ox = clamp(old_ox, -new_max, new_max)
		new_oy = clamp(old_oy, -new_max, new_max)
	
	# Update dial metadata
	if ui_config.has("dial"):
		ui_config["dial"].set_meta("max_offset", new_max)
	# Update hidden X/Y spin ranges
	ui_config["offset_x_spin"].min_value = -new_max
	ui_config["offset_x_spin"].max_value = new_max
	ui_config["offset_y_spin"].min_value = -new_max
	ui_config["offset_y_spin"].max_value = new_max
	# Update distance spin max
	if ui_config.has("dist_spin"):
		ui_config["dist_spin"].max_value = new_max
	# Apply values
	ui_config["offset_x_spin"].value = new_ox
	ui_config["offset_y_spin"].value = new_oy
	# Update angle/distance from new X/Y
	_update_angle_distance_from_xy(new_ox, new_oy)
	# Update dial dot position
	_update_dial_dot_position(new_ox, new_oy)

const OFFSET_MAX = 100.0

func _create_dial(dial_size: int, max_offset: float) -> Control:
	var dial = Control.new()
	dial.name = "OffsetDial"
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)

	# We draw the dial via _draw override — use a script-less approach with shapes
	# Background circle (dark)
	var bg = _make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	var bg_sprite = TextureRect.new()
	bg_sprite.texture = bg
	bg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_sprite)

	# Ring guides at 25%, 50%, 75%
	for ring_frac in [0.25, 0.5, 0.75]:
		var ring_size = int(dial_size * ring_frac)
		var ring_tex = _make_ring_texture(ring_size, Color(0.22, 0.22, 0.22, 1.0))
		var ring_rect = TextureRect.new()
		ring_rect.texture = ring_tex
		ring_rect.rect_position = Vector2((dial_size - ring_size) / 2.0, (dial_size - ring_size) / 2.0)
		ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring_rect)

	# Diagonal guide lines (45°, 135°, 225°, 315°)
	# These are thin lines from center to edge at each diagonal
	for diag_angle in [45.0, 135.0, 225.0, 315.0]:
		var diag_rad = deg2rad(diag_angle)
		var dx = cos(diag_rad)
		var dy = sin(diag_rad)
		var line_len = dial_size / 2.0 - 2.0
		# Draw as a series of small dots (1px ColorRects) along the line
		for s in range(4, int(line_len), 3):
			var px = dial_size / 2.0 + dx * s
			var py = dial_size / 2.0 + dy * s
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(px, py)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)

	# Crosshairs
	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(0, dial_size / 2.0 - 0.5)
	h_line.rect_min_size = Vector2(dial_size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(dial_size / 2.0 - 0.5, 0)
	v_line.rect_min_size = Vector2(1, dial_size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)

	# Center dot
	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(dial_size / 2.0 - 1.5, dial_size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)

	# Handle dot (the draggable point)
	var dot = ColorRect.new()
	dot.name = "Handle"
	dot.color = Color(0.95, 0.6, 0.1, 1.0)
	dot.rect_min_size = Vector2(10, 10)
	dot.rect_position = Vector2(dial_size / 2.0 - 5, dial_size / 2.0 - 5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(dot)

	# Diagonal snap buttons at corners
	# 0°=east, 90°=south: 45°=SE, 135°=SW, 225°=NW, 315°=NE
	var snap_btn_size = 12
	var snap_inactive_color = Color(0.3, 0.3, 0.3, 0.8)
	var snap_active_color = Color(0.353, 0.698, 1.0, 1.0)  # #5ab2ff
	var snap_positions = {
		"snap_315": Vector2(dial_size - 8, -4),        # top-right = NE = 315°
		"snap_45":  Vector2(dial_size - 8, dial_size - 8),   # bottom-right = SE = 45°
		"snap_135": Vector2(-4, dial_size - 8),         # bottom-left = SW = 135°
		"snap_225": Vector2(-4, -4)                     # top-left = NW = 225°
	}
	var snap_angles = {"snap_315": 315.0, "snap_45": 45.0, "snap_135": 135.0, "snap_225": 225.0}
	var snap_tooltips = {"snap_315": "Sun NE", "snap_45": "Sun SE", "snap_135": "Sun SW", "snap_225": "Sun NW"}

	for key in snap_positions.keys():
		var snap_btn = TextureButton.new()
		snap_btn.name = key
		snap_btn.texture_normal = _make_circle_texture(snap_btn_size, snap_inactive_color)
		snap_btn.texture_pressed = _make_circle_texture(snap_btn_size, snap_active_color)
		snap_btn.toggle_mode = true
		snap_btn.pressed = false
		snap_btn.rect_position = snap_positions[key]
		snap_btn.rect_min_size = Vector2(snap_btn_size, snap_btn_size)
		snap_btn.hint_tooltip = snap_tooltips[key]
		snap_btn.connect("toggled", self, "_on_snap_toggled", [key, snap_angles[key]])
		dial.add_child(snap_btn)
		ui_config[key] = snap_btn

	dial.set_meta("dial_size", dial_size)
	dial.set_meta("max_offset", max_offset)
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)  # -1 = no snap
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_dial_input", [dial])
	ui_config["dial"] = dial
	ui_config["dial_dot"] = dot
	return dial

func _make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			var dist = Vector2(x, y).distance_to(center)
			if dist <= radius:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
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
			var dist = Vector2(x, y).distance_to(center)
			if abs(dist - radius) < 1.0:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

func _create_proj_dial(dial_size: int, kind: String) -> Control:
	# Lightweight dial, independent from the offset dial. kind = "anchor" (point in
	# [-1,1]) or "dir" (direction only). Value is mirrored into hidden spins by the
	# input handler; the handle is positioned by _set_proj_dial_handle.
	var dial = Control.new()
	dial.name = "ProjDial_" + kind
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)
	var bg = _make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	var bg_rect = TextureRect.new()
	bg_rect.texture = bg
	bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_rect)
	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(0, dial_size / 2.0 - 0.5)
	h_line.rect_min_size = Vector2(dial_size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(dial_size / 2.0 - 0.5, 0)
	v_line.rect_min_size = Vector2(1, dial_size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)
	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(dial_size / 2.0 - 1.5, dial_size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)
	var dot = ColorRect.new()
	dot.name = "Handle"
	dot.color = Color(0.95, 0.6, 0.1, 1.0)
	dot.rect_min_size = Vector2(10, 10)
	dot.rect_position = Vector2(dial_size / 2.0 - 5, dial_size / 2.0 - 5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(dot)
	dial.set_meta("dial_size", dial_size)
	dial.set_meta("kind", kind)
	dial.set_meta("dragging", false)
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_proj_dial_input", [dial])
	return dial

func _create_proj_dirlen_dial(dial_size: int) -> Control:
	# Clone of the offset dial (concentric rings, diagonal guides, corner snap
	# buttons) for the projected mode. Handle points to the SUN; shadow falls
	# opposite. Radius (non-linear) = length. Snap buttons lock the sun angle.
	var dial = Control.new()
	dial.name = "ProjDial"
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)

	var bg = _make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	var bg_sprite = TextureRect.new()
	bg_sprite.texture = bg
	bg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_sprite)

	# Concentric ring guides at 25/50/75%
	for ring_frac in [0.25, 0.5, 0.75]:
		var ring_size = int(dial_size * ring_frac)
		var ring_tex = _make_ring_texture(ring_size, Color(0.22, 0.22, 0.22, 1.0))
		var ring_rect = TextureRect.new()
		ring_rect.texture = ring_tex
		ring_rect.rect_position = Vector2((dial_size - ring_size) / 2.0, (dial_size - ring_size) / 2.0)
		ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring_rect)

	# Diagonal guide dots (45/135/225/315)
	for diag_angle in [45.0, 135.0, 225.0, 315.0]:
		var diag_rad = deg2rad(diag_angle)
		var dx = cos(diag_rad)
		var dy = sin(diag_rad)
		var line_len = dial_size / 2.0 - 2.0
		for s in range(4, int(line_len), 3):
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(dial_size / 2.0 + dx * s, dial_size / 2.0 + dy * s)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)

	# Crosshairs
	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(0, dial_size / 2.0 - 0.5)
	h_line.rect_min_size = Vector2(dial_size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(dial_size / 2.0 - 0.5, 0)
	v_line.rect_min_size = Vector2(1, dial_size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)

	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(dial_size / 2.0 - 1.5, dial_size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)

	var dot = ColorRect.new()
	dot.name = "Handle"
	dot.color = Color(0.95, 0.6, 0.1, 1.0)
	dot.rect_min_size = Vector2(10, 10)
	dot.rect_position = Vector2(dial_size / 2.0 - 5, dial_size / 2.0 - 5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(dot)

	# Corner snap buttons (sun positions); shadow falls opposite.
	var snap_btn_size = 12
	var snap_inactive_color = Color(0.3, 0.3, 0.3, 0.8)
	var snap_active_color = Color(0.353, 0.698, 1.0, 1.0)
	var snap_positions = {
		"proj_snap_315": Vector2(dial_size - 8, -4),
		"proj_snap_45":  Vector2(dial_size - 8, dial_size - 8),
		"proj_snap_135": Vector2(-4, dial_size - 8),
		"proj_snap_225": Vector2(-4, -4)
	}
	var snap_angles = {"proj_snap_315": 315.0, "proj_snap_45": 45.0, "proj_snap_135": 135.0, "proj_snap_225": 225.0}
	var snap_tooltips = {"proj_snap_315": "Sun NE", "proj_snap_45": "Sun SE", "proj_snap_135": "Sun SW", "proj_snap_225": "Sun NW"}
	for key in snap_positions.keys():
		var snap_btn = TextureButton.new()
		snap_btn.name = key
		snap_btn.texture_normal = _make_circle_texture(snap_btn_size, snap_inactive_color)
		snap_btn.texture_pressed = _make_circle_texture(snap_btn_size, snap_active_color)
		snap_btn.toggle_mode = true
		snap_btn.pressed = false
		snap_btn.rect_position = snap_positions[key]
		snap_btn.rect_min_size = Vector2(snap_btn_size, snap_btn_size)
		snap_btn.hint_tooltip = snap_tooltips[key]
		snap_btn.connect("toggled", self, "_on_proj_snap_toggled", [key, snap_angles[key]])
		dial.add_child(snap_btn)
		ui_config[key] = snap_btn

	dial.set_meta("dial_size", dial_size)
	dial.set_meta("kind", "dirlen")
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_proj_dial_input", [dial])
	ui_config["proj_dir_dial"] = dial
	return dial

func _set_proj_dial_handle(dial: Control, v: Vector2) -> void:
	# v in [-1,1] for anchor; unit direction for dir (pinned near the edge).
	if dial == null or not is_instance_valid(dial):
		return
	var dial_size = dial.get_meta("dial_size") as float
	var radius = dial_size / 2.0
	var handle = dial.get_node_or_null("Handle")
	if handle == null:
		return
	var p = v
	if dial.get_meta("kind") == "dir":
		if v.length() < 0.0001:
			p = Vector2(1.0, 0.0)
		p = p.normalized() * 0.9
	handle.rect_position = Vector2(dial_size / 2.0 + p.x * radius - 5, dial_size / 2.0 + p.y * radius - 5)

func _on_proj_dial_input(event: InputEvent, dial: Control):
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dial.set_meta("dragging", event.pressed)
			if event.pressed:
				_update_proj_dial_from_mouse(event.position, dial)
	elif event is InputEventMouseMotion:
		if dial.get_meta("dragging"):
			_update_proj_dial_from_mouse(event.position, dial)

func _update_proj_dial_from_mouse(pos: Vector2, dial: Control):
	var dial_size = dial.get_meta("dial_size") as float
	var radius = dial_size / 2.0
	var center = Vector2(radius, radius)
	var delta = pos - center
	var kind = dial.get_meta("kind")
	if kind == "dirlen":
		# The dial points to the SUN; the shadow falls opposite. Radius (non-linear)
		# = length. Angle snapping is done via the corner snap buttons (like offset).
		if delta.length() > radius:
			delta = delta.normalized() * radius
		var frac = delta.length() / radius
		var length = frac * frac * PROJ_MAX_LENGTH
		var snap = dial.get_meta("snap_angle") as float
		if snap >= 0.0:
			# A snap button is active: the angle is locked, drag changes distance only.
			# The snap stays active until the user clicks it again.
			_syncing_ui = true
			ui_config["proj_dist_spin"].value = length
			_syncing_ui = false
			var f2 = sqrt(length / PROJ_MAX_LENGTH) if PROJ_MAX_LENGTH > 0.0 else 0.0
			var sr = deg2rad(snap)
			_set_proj_dial_handle(dial, Vector2(cos(sr), sin(sr)) * f2)
			apply_shadow_to_selected(false, ["proj_length"])
			return
		var has_dir = delta.length() > 0.5
		var hv = Vector2(delta.x / radius, delta.y / radius)
		_set_proj_dial_handle(dial, hv)
		_syncing_ui = true
		ui_config["proj_dist_spin"].value = length
		if has_dir:
			var sun_ang = rad2deg(atan2(delta.y, delta.x))
			if sun_ang < 0.0:
				sun_ang += 360.0
			ui_config["proj_sun_angle_spin"].value = round(sun_ang)
		_syncing_ui = false
		apply_shadow_to_selected(false, ["proj_angle", "proj_length"])
		return
	if kind == "dir":
		if delta.length() < 0.001:
			return
		var dir = delta.normalized()
		_set_proj_dial_handle(dial, dir)
		var ang_deg = rad2deg(atan2(dir.y, dir.x))
		if ang_deg < 0.0:
			ang_deg += 360.0
		_syncing_ui = true
		ui_config["proj_angle_spin"].value = round(ang_deg)
		_syncing_ui = false
		apply_shadow_to_selected(false, ["proj_angle"])
	else:
		if delta.length() > radius:
			delta = delta.normalized() * radius
		var nx = clamp(delta.x / radius, -1.0, 1.0)
		var ny = clamp(delta.y / radius, -1.0, 1.0)
		_set_proj_dial_handle(dial, Vector2(nx, ny))
		_syncing_ui = true
		ui_config["proj_anchor_x_spin"].value = nx
		ui_config["proj_anchor_y_spin"].value = ny
		_syncing_ui = false
		apply_shadow_to_selected(false, ["proj_anchor_x", "proj_anchor_y"])

func _on_proj_length_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	ui_config["proj_length_slider"].value = value
	ui_config["proj_length_spin"].value = value
	_syncing_ui = false
	apply_shadow_to_selected(false, ["proj_length"])

func _on_proj_fade_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	ui_config["proj_fade_slider"].value = value
	ui_config["proj_fade_spin"].value = value
	_syncing_ui = false
	apply_shadow_to_selected(false, ["proj_fade"])

func _on_proj_fade_reset():
	_syncing_ui = true
	ui_config["proj_fade_slider"].value = 0.5
	ui_config["proj_fade_spin"].value = 0.5
	_syncing_ui = false
	apply_shadow_to_selected(false, ["proj_fade"])

func _apply_proj_from_spins() -> void:
	var length = clamp(ui_config["proj_dist_spin"].value, 0.0, PROJ_MAX_LENGTH)
	var sun_ang = ui_config["proj_sun_angle_spin"].value
	var frac = sqrt(length / PROJ_MAX_LENGTH) if PROJ_MAX_LENGTH > 0.0 else 0.0
	var lr = deg2rad(sun_ang)
	if ui_config.has("proj_dir_dial"):
		_set_proj_dial_handle(ui_config["proj_dir_dial"], Vector2(cos(lr), sin(lr)) * frac)
	apply_shadow_to_selected(false, ["proj_angle", "proj_length"])

func _on_proj_dist_changed(_v = null):
	if _syncing_ui:
		return
	_apply_proj_from_spins()

func _on_proj_angle_changed(_v = null):
	if _syncing_ui:
		return
	var dial = ui_config.get("proj_dir_dial")
	var snap = (dial.get_meta("snap_angle") as float) if dial != null else -1.0
	if snap >= 0.0:
		# Angle is locked by an active snap button: revert manual edits.
		_syncing_ui = true
		ui_config["proj_sun_angle_spin"].value = round(snap)
		_syncing_ui = false
		return
	_apply_proj_from_spins()

func _on_proj_dist_reset():
	_syncing_ui = true
	ui_config["proj_dist_spin"].value = 0.0
	_syncing_ui = false
	_apply_proj_from_spins()

func _on_proj_angle_reset():
	_deactivate_all_proj_snaps()
	_syncing_ui = true
	ui_config["proj_sun_angle_spin"].value = 0
	_syncing_ui = false
	_apply_proj_from_spins()

func _deactivate_all_proj_snaps():
	var prev = _syncing_ui
	_syncing_ui = true
	for k in ["proj_snap_45", "proj_snap_135", "proj_snap_225", "proj_snap_315"]:
		if ui_config.has(k):
			ui_config[k].pressed = false
	_syncing_ui = prev
	if ui_config.has("proj_dir_dial"):
		ui_config["proj_dir_dial"].set_meta("snap_angle", -1.0)

func _on_proj_snap_toggled(pressed, key, sun_screen_angle):
	if _syncing_ui:
		return
	if pressed:
		_syncing_ui = true
		for k in ["proj_snap_45", "proj_snap_135", "proj_snap_225", "proj_snap_315"]:
			if k != key and ui_config.has(k):
				ui_config[k].pressed = false
		ui_config["proj_sun_angle_spin"].value = round(sun_screen_angle)
		_syncing_ui = false
		if ui_config.has("proj_dir_dial"):
			ui_config["proj_dir_dial"].set_meta("snap_angle", sun_screen_angle)
		_apply_proj_from_spins()
	else:
		if ui_config.has("proj_dir_dial"):
			ui_config["proj_dir_dial"].set_meta("snap_angle", -1.0)

func _update_proj_taper_enabled(extrude: bool) -> void:
	# Taper has no effect in Extrude mode — grey it out and lock it.
	var en = not extrude
	var tint = Color(1, 1, 1, 1.0) if en else Color(1, 1, 1, 0.4)
	if ui_config.has("proj_taper_slider"):
		ui_config["proj_taper_slider"].editable = en
		ui_config["proj_taper_slider"].modulate = tint
	if ui_config.has("proj_taper_spin"):
		ui_config["proj_taper_spin"].editable = en
		ui_config["proj_taper_spin"].modulate = tint

func _on_proj_taper_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	ui_config["proj_taper_slider"].value = value
	ui_config["proj_taper_spin"].value = value
	_syncing_ui = false
	apply_shadow_to_selected(false, ["proj_taper"])

func _on_proj_cone_reset():
	_syncing_ui = true
	ui_config["proj_taper_slider"].value = 0.0
	ui_config["proj_taper_spin"].value = 0.0
	_syncing_ui = false
	apply_shadow_to_selected(false, ["proj_taper"])

func _on_shadow_mode_selected(idx):
	_update_shadow_mode_visibility(idx)
	_update_proj_taper_enabled(idx != 2)  # Cone only matters in Projected (Stretch)
	if not _syncing_ui:
		apply_shadow_to_selected(false, ["shadow_mode", "proj_extrude"])

func _update_shadow_mode_visibility(idx):
	var projected = idx == 1 or idx == 2
	if ui_config.has("offset_mode_nodes"):
		for n in ui_config["offset_mode_nodes"]:
			if is_instance_valid(n):
				n.visible = not projected
	if ui_config.has("proj_panel") and is_instance_valid(ui_config["proj_panel"]):
		ui_config["proj_panel"].visible = projected

#########################################################################################################
##
## SHAPE EDITOR (paint HIGH/LOW height zones over the asset thumbnail)
##
#########################################################################################################

func _create_shape_editor(size: int) -> Control:
	var c = Control.new()
	c.name = "ShapeEditor"
	c.rect_min_size = Vector2(size, size)
	c.rect_size = Vector2(size, size)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	c.connect("draw", self, "_draw_shape_editor", [c])
	c.connect("gui_input", self, "_on_shape_editor_input", [c])
	return c

func _editor_dest_rect(editor: Control) -> Rect2:
	var box = editor.rect_size
	var ts = editor.get_meta("tex_size") if editor.has_meta("tex_size") else Vector2(box.x, box.y)
	if ts.x <= 0.0 or ts.y <= 0.0:
		return Rect2(Vector2.ZERO, box)
	var s = min(box.x / ts.x, box.y / ts.y)
	var w = ts.x * s
	var h = ts.y * s
	return Rect2((box.x - w) * 0.5, (box.y - h) * 0.5, w, h)

func _draw_shape_editor(editor: Control) -> void:
	var box = editor.rect_size
	editor.draw_rect(Rect2(Vector2.ZERO, box), Color(0.1, 0.1, 0.1, 1.0))
	var dest = _editor_dest_rect(editor)
	if editor.has_meta("thumb_tex") and editor.get_meta("thumb_tex") != null:
		var tex = editor.get_meta("thumb_tex")
		var src = editor.get_meta("thumb_region")
		editor.draw_texture_rect_region(tex, dest, src, Color(1, 1, 1, 0.7))
	var cw = dest.size.x / float(SHAPE_GRID)
	var ch = dest.size.y / float(SHAPE_GRID)
	var mask = ui_config.get("shape_mask", [])
	if mask is Array and mask.size() == SHAPE_GRID * SHAPE_GRID:
		for row in range(SHAPE_GRID):
			for col in range(SHAPE_GRID):
				if float(mask[row * SHAPE_GRID + col]) > 0.5:
					var r = Rect2(dest.position.x + col * cw, dest.position.y + row * ch, cw, ch)
					editor.draw_rect(r, Color(0.95, 0.6, 0.1, 0.35))
	for k in range(SHAPE_GRID + 1):
		var x = dest.position.x + float(k) * cw
		editor.draw_line(Vector2(x, dest.position.y), Vector2(x, dest.position.y + dest.size.y), Color(1, 1, 1, 0.12))
		var y = dest.position.y + float(k) * ch
		editor.draw_line(Vector2(dest.position.x, y), Vector2(dest.position.x + dest.size.x, y), Color(1, 1, 1, 0.12))

func _paint_editor_cell(editor: Control, pos: Vector2, val: float) -> void:
	var dest = _editor_dest_rect(editor)
	if not dest.has_point(pos):
		return
	var col = int((pos.x - dest.position.x) / dest.size.x * float(SHAPE_GRID))
	var row = int((pos.y - dest.position.y) / dest.size.y * float(SHAPE_GRID))
	col = int(clamp(col, 0, SHAPE_GRID - 1))
	row = int(clamp(row, 0, SHAPE_GRID - 1))
	var mask = ui_config.get("shape_mask", [])
	if not (mask is Array) or mask.size() != SHAPE_GRID * SHAPE_GRID:
		mask = _default_shape_mask()
	if float(mask[row * SHAPE_GRID + col]) == val:
		return  # no change
	mask[row * SHAPE_GRID + col] = val
	ui_config["shape_mask"] = mask
	editor.update()
	if not _syncing_ui:
		apply_shadow_to_selected(false, ["shape_mask"])

func _on_shape_editor_input(event: InputEvent, editor: Control) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == BUTTON_LEFT:
			editor.set_meta("painting", true)
			editor.set_meta("paint_val", 1.0)
			_paint_editor_cell(editor, event.position, 1.0)
		elif event.pressed and event.button_index == BUTTON_RIGHT:
			editor.set_meta("painting", true)
			editor.set_meta("paint_val", 0.0)
			_paint_editor_cell(editor, event.position, 0.0)
		elif not event.pressed:
			editor.set_meta("painting", false)
	elif event is InputEventMouseMotion:
		if editor.has_meta("painting") and editor.get_meta("painting"):
			_paint_editor_cell(editor, event.position, editor.get_meta("paint_val"))

func _set_shape_editor_thumb(sprite) -> void:
	var editor = ui_config.get("shape_editor")
	if editor == null or not is_instance_valid(editor):
		return
	if sprite == null or sprite.texture == null:
		editor.set_meta("thumb_tex", null)
		editor.update()
		return
	var info = _atlas_uv_info(sprite)
	var atlas = info["atlas"]
	var full = atlas.get_size()
	var src = Rect2(info["uv_origin"] * full, info["uv_scale"] * full)
	editor.set_meta("thumb_tex", atlas)
	editor.set_meta("thumb_region", src)
	editor.set_meta("tex_size", info["size"])
	editor.update()

func _on_shape_reset() -> void:
	ui_config["shape_mask"] = _default_shape_mask()
	var editor = ui_config.get("shape_editor")
	if editor != null and is_instance_valid(editor):
		editor.update()
	apply_shadow_to_selected(false, ["shape_mask"])

func _on_dial_input(event: InputEvent, dial: Control):
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dial.set_meta("dragging", event.pressed)
			if event.pressed:
				_update_dial_from_mouse(event.position, dial)
	elif event is InputEventMouseMotion:
		if dial.get_meta("dragging"):
			_update_dial_from_mouse(event.position, dial)

func _update_dial_from_mouse(pos: Vector2, dial: Control):
	var dial_size = dial.get_meta("dial_size") as float
	var max_offset = dial.get_meta("max_offset") as float
	var center = Vector2(dial_size / 2.0, dial_size / 2.0)
	var radius = dial_size / 2.0

	# Vector from center, normalized to -1..1
	var delta = pos - center
	var dist_from_center = delta.length()

	# Clamp to circle
	if dist_from_center > radius:
		delta = delta.normalized() * radius
		dist_from_center = radius

	# Non-linear: fraction = (dist/radius)^2
	# Near center = very precise, edges = large jumps
	var frac = dist_from_center / radius
	var nonlinear_frac = frac * frac  # quadratic curve

	# Direction preserved, magnitude remapped
	var direction = delta.normalized() if dist_from_center > 0.5 else Vector2.ZERO

	# Apply diagonal snap if active
	var snap_angle = dial.get_meta("snap_angle") as float
	if snap_angle >= 0.0:
		var snap_rad = deg2rad(snap_angle)
		var snap_dir = Vector2(cos(snap_rad), sin(snap_rad))
		# Project mouse delta onto the snap direction
		var projection = delta.dot(snap_dir)
		if projection <= 0.0:
			# Mouse is on the opposite side of center — clamp to center
			_set_dial_values(0, 0)
			apply_shadow_to_selected(false, ["offset_x", "offset_y"])
			return
		# Use projection length for distance instead of raw dist_from_center
		var projected_dist = min(projection, radius)
		frac = projected_dist / radius
		nonlinear_frac = frac * frac
		direction = snap_dir

	var ox = round(-direction.x * nonlinear_frac * max_offset)
	var oy = round(-direction.y * nonlinear_frac * max_offset)

	_set_dial_values(ox, oy)
	apply_shadow_to_selected(false, ["offset_x", "offset_y"])

#########################################################################################################
##
## UNDO/REDO — TRANSACTIONS DE RÉGLAGES (slice A2)
##
#########################################################################################################
#
# Tout réglage objet passe par apply_shadow_to_selected() : on y pose _history_touch().
# 1er touch d'un geste -> snapshot du config COMPLET des objets impactés (début de
# transaction). Un timer de debounce regroupe les changements rapprochés. Le flush
# (timer, changement de sélection, ou juste avant un Ctrl+Z) enregistre l'entrée.
# Restauration générique via history_apply_config().

# Objets potentiellement impactés par un réglage : monitoré + tous les sélectionnés
# (sans filtre "enabled" : superset sûr ; restaurer un config identique est un no-op).
func _history_affected_nodes() -> Array:
	var out = []
	if _monitored_object != null and is_instance_valid(_monitored_object) and _monitored_object.has_meta("node_id"):
		out.append(_monitored_object)
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_shadow_node_type(node):
			continue
		if out.has(node):
			continue
		if not node.has_meta("node_id"):
			continue
		out.append(node)
	return out

# Snapshot {node_id: config complet} (shadow_color stocké en html, comme ModMapData).
func _history_full_snapshot(nodes: Array) -> Dictionary:
	var snap = {}
	for node in nodes:
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))
		var cfg
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
			cfg = global.ModMapData[SHADOW_DATA_KEY][nid].duplicate(true)
		elif node.has_meta("_shadow_config"):
			cfg = node.get_meta("_shadow_config").duplicate(true)
		else:
			cfg = DEFAULT_SHADOW_CONFIG.duplicate(true)
		# Normaliser la couleur en html pour une comparaison fiable.
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		snap[nid] = cfg
	return snap

# Appelé en tête d'apply_shadow_to_selected. Ouvre une transaction si besoin.
func _history_touch(label: String = "") -> void:
	if shadow_history == null:
		return
	if _history_suspend or _loading_ui or _syncing_ui:
		return
	if not _history_txn_active:
		_history_txn_before = _history_full_snapshot(_history_affected_nodes())
		_history_txn_active = true
		_history_txn_label = label
	# (Re)démarre le debounce.
	if _history_flush_timer != null:
		_history_flush_timer.start()

# Clôt la transaction en cours : compare avant/après, enregistre si différent.
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
	# "Après" pour les MÊMES ids.
	var after = {}
	var changed = false
	for nid in before.keys():
		var cfg
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
			cfg = global.ModMapData[SHADOW_DATA_KEY][nid].duplicate(true)
		else:
			cfg = before[nid].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		after[nid] = cfg
		if not _configs_equal(before[nid], cfg):
			changed = true
	if changed and shadow_history != null:
		shadow_history.record(self, "history_apply_config", before, after, _history_txn_label)

# Comparaison de deux configs normalisés (couleur html).
func _configs_equal(a, b) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k):
			return false
		if a[k] != b[k]:
			return false
	return true

# Transaction "manuelle" (pour Apply-to-all, qui ne passe pas par apply_shadow_to_selected).
func _history_begin_manual(label: String = "") -> void:
	if shadow_history == null:
		return
	_history_txn_before = {}
	_history_txn_active = true
	_history_txn_label = label

# Capture l'état AVANT d'un nœud juste avant sa modification (idempotent par nid).
func _history_capture_before(node) -> void:
	if not _history_txn_active or shadow_history == null:
		return
	if not is_instance_valid(node) or not node.has_meta("node_id"):
		return
	var nid = str(node.get_meta("node_id"))
	if _history_txn_before.has(nid):
		return
	var single = _history_full_snapshot([node])
	for k in single.keys():
		_history_txn_before[k] = single[k]

# Restaure un snapshot de config complet par objet (utilisé par undo ET redo).
# payload = {node_id: config complet (couleur en html)}
func history_apply_config(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true
	var refresh_monitored = false
	for nid in payload.keys():
		var cfg = payload[nid].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		var node = _all_known_obj_ids.get(nid)
		if node != null and is_instance_valid(node):
			remove_shadow(node)
			if cfg.get("enabled", false):
				create_shadow(node, cfg)
			save_shadow_data(node, cfg)
			if node == _monitored_object:
				refresh_monitored = true
		else:
			# Nœud absent : ne mettre à jour que les données persistées (couleur html).
			var store = payload[nid].duplicate(true)
			global.ModMapData[SHADOW_DATA_KEY][nid] = store
	# Rafraîchir le panneau pour que tous les sliders reflètent l'état restauré.
	if refresh_monitored and _monitored_object != null and is_instance_valid(_monitored_object):
		load_shadow_ui_from_object(_monitored_object)
	_history_suspend = false


# Détecte un déplacement NATIF d'objet (le mod ne déplace jamais les objets, donc
# tout changement de position d'un objet sélectionné est une op native). On ne
# suit que la sélection (peu coûteux ; on ne déplace que ce qui est sélectionné).
# Re-sélectionner un objet ré-établit sa baseline (pas de faux marqueur).
func _detect_native_moves() -> void:
	if shadow_history == null or not shadow_history.has_method("note_native_op"):
		return
	var sel = global.Editor.Tools["SelectTool"].Selected
	var seen = {}
	for node in sel:
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		if not is_shadow_node_type(node):
			continue
		var nid = str(node.get_meta("node_id"))
		var pos = node.global_position
		seen[nid] = true
		if _native_pos_by_id.has(nid):
			if _native_pos_by_id[nid].distance_to(pos) > 0.01:
				shadow_history.note_native_op()
		_native_pos_by_id[nid] = pos
	# Purge les ids qui ne sont plus sélectionnés (re-baseline au re-select).
	# Si un id a quitté la sélection ET que son nœud n'existe plus -> delete natif.
	for nid in _native_pos_by_id.keys():
		if not seen.has(nid):
			if _native_detect_ready and int(nid) >= 0:
				if not global.World.HasNodeID(int(nid)):
					shadow_history.note_native_op()
			_native_pos_by_id.erase(nid)

func _on_snap_toggled(pressed: bool, key: String, angle: float):
	"""Handle diagonal snap button toggle. Only one can be active at a time."""
	var dial = ui_config.get("dial")
	if dial == null:
		return
	if pressed:
		# Deactivate other snap buttons
		for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
			if snap_key != key and ui_config.has(snap_key):
				ui_config[snap_key].pressed = false
		dial.set_meta("snap_angle", angle)
		# Re-apply current distance along the new snap angle (shadow = opposite of sun)
		var current_dist = ui_config["dist_spin"].value
		if current_dist > 0:
			var snap_rad = deg2rad(angle)
			var ox = round(-current_dist * cos(snap_rad))
			var oy = round(-current_dist * sin(snap_rad))
			_set_dial_values(ox, oy)
			apply_shadow_to_selected(false, ["offset_x", "offset_y"])
	else:
		dial.set_meta("snap_angle", -1.0)

func _deactivate_all_snaps():
	"""Deactivate all diagonal snap buttons."""
	for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
		if ui_config.has(snap_key):
			ui_config[snap_key].pressed = false
	var dial = ui_config.get("dial")
	if dial != null:
		dial.set_meta("snap_angle", -1.0)

func _on_offset_spin_changed(_value = null):
	if _syncing_ui:
		return
	var angle_deg = ui_config["angle_spin"].value
	var dist = ui_config["dist_spin"].value

	# If snap is active, check if user changed angle manually → deactivate snap
	var dial = ui_config.get("dial")
	if dial != null:
		var snap_angle = dial.get_meta("snap_angle") as float
		if snap_angle >= 0.0:
			# Convert snap screen angle to sun north-convention angle
			var snap_rad = deg2rad(snap_angle)
			var expected_sun_deg = rad2deg(atan2(cos(snap_rad), -sin(snap_rad)))
			if expected_sun_deg < 0:
				expected_sun_deg += 360.0
			if abs(angle_deg - round(expected_sun_deg)) > 0.5:
				# User changed the angle, deactivate snap
				_deactivate_all_snaps()
			else:
				# Keep snapped: compute shadow offset from snap (shadow = opposite of sun)
				var ox = round(-dist * cos(snap_rad))
				var oy = round(-dist * sin(snap_rad))
				_syncing_ui = true
				ui_config["offset_x_spin"].value = ox
				ui_config["offset_y_spin"].value = oy
				_update_dial_dot_position(ox, oy)
				_syncing_ui = false
				apply_shadow_to_selected(false, ["offset_x", "offset_y"])
				return

	var angle_rad = deg2rad(angle_deg)
	# Angle = sun direction (0° = north, 90° = east), shadow = opposite
	var ox = round(-dist * sin(angle_rad))
	var oy = round(dist * cos(angle_rad))
	_syncing_ui = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_update_dial_dot_position(ox, oy)
	_syncing_ui = false
	apply_shadow_to_selected(false, ["offset_x", "offset_y"])

func _set_dial_values(ox: float, oy: float):
	_syncing_ui = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_update_angle_distance_from_xy(ox, oy)
	_update_dial_dot_position(ox, oy)
	_syncing_ui = false

func _update_angle_distance_from_xy(ox: float, oy: float):
	"""Update angle and distance SpinBoxes from X/Y offset values."""
	var dist = sqrt(ox * ox + oy * oy)
	var angle_deg = 0.0
	if dist > 0.5:
		# Compute sun angle from shadow offset: sun = opposite of shadow
		# 0° = north (up), 90° = east (right), clockwise
		angle_deg = rad2deg(atan2(-ox, oy))
		if angle_deg < 0:
			angle_deg += 360.0
	if ui_config.has("angle_spin"):
		ui_config["angle_spin"].value = round(angle_deg)
	if ui_config.has("dist_spin"):
		ui_config["dist_spin"].value = round(dist)

func _update_dial_dot_position(ox: float, oy: float):
	if not ui_config.has("dial"):
		return
	var dial = ui_config["dial"] as Control
	var dial_size = dial.get_meta("dial_size") as float
	var max_offset = dial.get_meta("max_offset") as float
	var radius = dial_size / 2.0

	# Reverse the nonlinear mapping: nonlinear_frac = offset / max_offset
	# frac = sqrt(nonlinear_frac) since we used frac^2
	var offset_dist = sqrt(ox * ox + oy * oy)
	var nonlinear_frac = clamp(offset_dist / max_offset, 0.0, 1.0)
	var frac = sqrt(nonlinear_frac)  # inverse of the quadratic

	# Show dot at sun position (opposite of shadow offset)
	var direction = Vector2(-ox, -oy).normalized() if offset_dist > 0.5 else Vector2.ZERO
	var dot_pos = Vector2(dial_size / 2.0, dial_size / 2.0) + direction * frac * radius

	var dot = ui_config["dial_dot"] as ColorRect
	dot.rect_position = Vector2(dot_pos.x - 5, dot_pos.y - 5)

func _set_dial_from_offset(ox: float, oy: float):
	_set_dial_values(ox, oy)

func _on_offset_slider_changed(value, which):
	pass

func _on_color_changed(_color):
	if _syncing_ui:
		return
	apply_shadow_to_selected(false, ["shadow_color"])

func _on_reset_pressed():
	_syncing_ui = true
	_deactivate_all_snaps()
	ui_config["opacity_slider"].value = DEFAULT_SHADOW_CONFIG["opacity"]
	ui_config["opacity_spin"].value = DEFAULT_SHADOW_CONFIG["opacity"]
	ui_config["blur_slider"].value = DEFAULT_SHADOW_CONFIG["blur"]
	ui_config["blur_spin"].value = DEFAULT_SHADOW_CONFIG["blur"]
	_set_quality_ui_value(DEFAULT_SHADOW_CONFIG.get("quality", FACTORY_DEFAULTS["quality"]))
	ui_config["range_slider"].value = DEFAULT_SHADOW_CONFIG["range"]
	ui_config["range_spin"].value = DEFAULT_SHADOW_CONFIG["range"]
	_update_offset_range(DEFAULT_SHADOW_CONFIG["range"], false)
	ui_config["shadow_color_picker"].color = DEFAULT_SHADOW_CONFIG["shadow_color"]
	ui_config["behind_layer_check"].pressed = DEFAULT_SHADOW_CONFIG.get("behind_layer", false)
	ui_config["clip_walls_check"].pressed = DEFAULT_SHADOW_CONFIG.get("clip_walls", false)
	ui_config["clip_paths_check"].pressed = DEFAULT_SHADOW_CONFIG.get("clip_paths", false)
	# Style + projected controls back to defaults (Offset, centred, etc.)
	_apply_proj_ui_from_config(DEFAULT_SHADOW_CONFIG)
	_syncing_ui = false
	_set_dial_from_offset(DEFAULT_SHADOW_CONFIG["offset_x"], DEFAULT_SHADOW_CONFIG["offset_y"])
	apply_shadow_to_selected()

func _on_single_reset(which):
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_spin"].value = DEFAULT_SHADOW_CONFIG["opacity"]
			ui_config["opacity_slider"].value = DEFAULT_SHADOW_CONFIG["opacity"]
		"blur":
			ui_config["blur_spin"].value = DEFAULT_SHADOW_CONFIG["blur"]
			ui_config["blur_slider"].value = DEFAULT_SHADOW_CONFIG["blur"]
		"quality":
			_set_quality_ui_value(DEFAULT_SHADOW_CONFIG.get("quality", FACTORY_DEFAULTS["quality"]))
		"range":
			ui_config["range_spin"].value = DEFAULT_SHADOW_CONFIG["range"]
			ui_config["range_slider"].value = DEFAULT_SHADOW_CONFIG["range"]
			_update_offset_range(DEFAULT_SHADOW_CONFIG["range"], false)
		"offset", "offset_x", "offset_y":
			_deactivate_all_snaps()
			_syncing_ui = false
			_set_dial_from_offset(DEFAULT_SHADOW_CONFIG["offset_x"], DEFAULT_SHADOW_CONFIG["offset_y"])
		"shadow_color":
			ui_config["shadow_color_picker"].color = DEFAULT_SHADOW_CONFIG["shadow_color"]
	_syncing_ui = false
	match which:
		"offset", "offset_x", "offset_y":
			apply_shadow_to_selected(false, ["offset_x", "offset_y"])
		_:
			apply_shadow_to_selected(false, [which])

func _are_defaults_custom() -> bool:
	"""Check if DEFAULT_SHADOW_CONFIG differs from FACTORY_DEFAULTS."""
	for key in FACTORY_DEFAULTS.keys():
		var factory_val = FACTORY_DEFAULTS[key]
		var current_val = DEFAULT_SHADOW_CONFIG.get(key, null)
		if factory_val is Color:
			if current_val == null or not current_val is Color:
				return true
			if not factory_val.is_equal_approx(current_val):
				return true
		elif factory_val is float:
			if current_val == null or abs(factory_val - current_val) > 0.001:
				return true
		else:
			if current_val != factory_val:
				return true
	return false

func _update_reset_defaults_visibility():
	if ui_config.has("reset_defaults_btn"):
		ui_config["reset_defaults_btn"].visible = _are_defaults_custom()
	_update_lock_btn_visibility()

func _on_use_as_default():
	var cfg = get_current_shadow_config()
	DEFAULT_SHADOW_CONFIG = {}
	for key in cfg.keys():
		if cfg[key] is Color:
			DEFAULT_SHADOW_CONFIG[key] = Color(cfg[key].r, cfg[key].g, cfg[key].b, cfg[key].a)
		else:
			DEFAULT_SHADOW_CONFIG[key] = cfg[key]
	# Never save enabled state — it's always per-object
	DEFAULT_SHADOW_CONFIG["enabled"] = false
	_save_defaults_to_map()
	_update_reset_defaults_visibility()
	outputlog("Saved current settings as defaults: " + str(DEFAULT_SHADOW_CONFIG), 0)

func _on_shadow_toggle_btn():
	ui_config["enable_check"].pressed = !ui_config["enable_check"].pressed

func _on_behind_layer_toggled(_pressed):
	if _syncing_ui:
		return
	apply_shadow_to_selected(false, ["behind_layer"])

func _on_clip_walls_toggled(_pressed):
	if _syncing_ui:
		return
	apply_shadow_to_selected(false, ["clip_walls"])

func _on_clip_paths_toggled(_pressed):
	if _syncing_ui:
		return
	apply_shadow_to_selected(false, ["clip_paths"])

func _on_apply_all_pressed():
	ui_config["apply_all_dialog"].popup_centered()

var _syncing_scope = false

func _on_scope_radio_pressed(index: int):
	if _syncing_scope:
		return
	_update_scope_radio_icons(index)

func _update_scope_radio_icons(active_index: int):
	_syncing_scope = true
	for i in range(3):
		var key = "scope_btn_" + str(i)
		if not ui_config.has(key):
			continue
		var btn = ui_config[key]
		btn.pressed = (i == active_index)
		if i == active_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
	_syncing_scope = false

func _get_selected_scope() -> int:
	for i in range(3):
		var key = "scope_btn_" + str(i)
		if ui_config.has(key) and ui_config[key].pressed:
			return i
	return 1  # default: current layer

#########################################################################################################
##
## QUALITY TIER (Low / Med / High / Ultra) — radio behavior + apply-to-all
##
#########################################################################################################

# Hard-coded tier definition so other helpers can reuse it without re-deriving.
const QUALITY_TIER_VALUES = [25, 50, 75, 100]
var _syncing_quality_ui = false
# {node_id: int_quality_value} captured the moment the broadcast toggle goes ON,
# so toggling OFF can restore each shadow to its pre-broadcast value. Cleared
# when the toggle is released.
var _quality_broadcast_snapshot = {}

func _is_quality_lock_active() -> bool:
	"""Read the persisted lock state from ModMapData. Default true (locked = snap
	to tiers) so a fresh map opens with the simple 4-tier UX."""
	if not global.ModMapData.has(LOCK_STATE_KEY):
		return true
	return bool(global.ModMapData[LOCK_STATE_KEY])

func _save_quality_lock_state(active: bool) -> void:
	"""Persist the lock state into ModMapData so the slider's snap behavior
	survives map save/load and DD restart."""
	global.ModMapData[LOCK_STATE_KEY] = active

func _update_quality_lock_icon(locked: bool) -> void:
	"""Swap the lock toggle's icon to reflect the current state. Falls back to
	reset.png if lock.png/unlock.png aren't shipped — visible-but-confusing
	rather than a missing-icon crash."""
	var btn = ui_config.get("quality_lock_btn")
	if btn == null or not is_instance_valid(btn):
		return
	var icon_path = "icons/lock.png" if locked else "icons/unlock.png"
	var tex = _load_icon(icon_path, 0.5)
	if tex == null:
		tex = _load_icon("icons/reset.png", 0.5)
	btn.icon = tex

func _quality_broadcast_active() -> bool:
	"""True if the apply-to-all toggle is currently pressed."""
	if not ui_config.has("quality_apply_all_btn"):
		return false
	var btn = ui_config["quality_apply_all_btn"]
	return btn != null and btn.pressed

func _get_current_quality_value() -> int:
	"""Read the slider's current value. Used by the broadcast snapshot/restore
	flow and any apply-to-all action."""
	if not ui_config.has("quality_slider"):
		return int(FACTORY_DEFAULTS.get("quality", 100))
	return int(ui_config["quality_slider"].value)

func _set_quality_ui_value(value) -> void:
	"""Push a numeric quality into both slider and spin without firing handlers
	(used when loading from selection / clipboard / reset)."""
	_syncing_quality_ui = true
	var v = int(value)
	if ui_config.has("quality_slider"):
		ui_config["quality_slider"].value = v
	if ui_config.has("quality_spin"):
		ui_config["quality_spin"].value = v
	_syncing_quality_ui = false

func _on_quality_slider_changed(value: float) -> void:
	if _syncing_quality_ui:
		return
	_syncing_quality_ui = true
	if ui_config.has("quality_spin"):
		ui_config["quality_spin"].value = value
	_syncing_quality_ui = false
	apply_shadow_to_selected(false, ["quality"])
	if _quality_broadcast_active():
		_apply_quality_to_all_objects(int(value))

func _on_quality_spin_changed(value: float) -> void:
	if _syncing_quality_ui:
		return
	_syncing_quality_ui = true
	if ui_config.has("quality_slider"):
		ui_config["quality_slider"].value = value
	_syncing_quality_ui = false
	apply_shadow_to_selected(false, ["quality"])
	if _quality_broadcast_active():
		_apply_quality_to_all_objects(int(value))

func _on_quality_lock_toggled(pressed: bool) -> void:
	"""Lock ON: slider/spin step = 25 (snap to tier values). Lock OFF: step = 1
	(free fine-tune). When re-locking, snap the current value to the nearest
	tier so the slider doesn't sit between two notches visually."""
	var snap_step = QUALITY_TIER_VALUES[1] - QUALITY_TIER_VALUES[0]
	var new_step = snap_step if pressed else 1
	if ui_config.has("quality_slider"):
		ui_config["quality_slider"].step = new_step
	if ui_config.has("quality_spin"):
		ui_config["quality_spin"].step = new_step
	if pressed:
		# Snap current value to nearest tier on relock.
		var current = _get_current_quality_value()
		var snapped = int(round(float(current) / snap_step)) * snap_step
		snapped = clamp(snapped, QUALITY_TIER_VALUES[0], QUALITY_TIER_VALUES[QUALITY_TIER_VALUES.size() - 1])
		if snapped != current:
			# This will fire _on_quality_slider_changed → applies + broadcasts.
			ui_config["quality_slider"].value = snapped
	_update_quality_lock_icon(pressed)
	_save_quality_lock_state(pressed)

func _on_quality_apply_all_toggled(pressed: bool) -> void:
	"""Toggle handler. ON: snapshot every shadow's current quality, then broadcast.
	OFF: restore each shadow to its snapshotted quality, then clear the snapshot."""
	if pressed:
		_snapshot_quality_all_objects()
		_apply_quality_to_all_objects(_get_current_quality_value())
	else:
		_restore_quality_from_snapshot()

func _snapshot_quality_all_objects() -> void:
	"""Record each shadow's current quality keyed by node_id so toggle-OFF can
	put things back as they were."""
	_quality_broadcast_snapshot.clear()
	var level = global.World.GetCurrentLevel()
	if level == null:
		return
	var objects_node = level.get_node_or_null("Objects")
	if objects_node == null:
		return
	for child in objects_node.get_children():
		if not is_shadow_node_type(child) or not child.has_meta("node_id"):
			continue
		var node_id = str(child.get_meta("node_id"))
		# Prefer the live config (active shadow); fall back to saved data
		# (shadow disabled but saved settings exist).
		var q = null
		if child.has_meta("_shadow_config"):
			var cfg = child.get_meta("_shadow_config")
			if cfg != null and cfg.has("quality"):
				q = int(cfg["quality"])
		if q == null and global.ModMapData.has(SHADOW_DATA_KEY) \
				and global.ModMapData[SHADOW_DATA_KEY].has(node_id) \
				and global.ModMapData[SHADOW_DATA_KEY][node_id].has("quality"):
			q = int(global.ModMapData[SHADOW_DATA_KEY][node_id]["quality"])
		if q != null:
			_quality_broadcast_snapshot[node_id] = q
	_save_broadcast_state(true)

func _restore_quality_from_snapshot() -> void:
	"""Apply each snapshotted quality back to its source shadow, then clear."""
	if _quality_broadcast_snapshot.empty():
		return
	var level = global.World.GetCurrentLevel()
	if level == null:
		_quality_broadcast_snapshot.clear()
		return
	var objects_node = level.get_node_or_null("Objects")
	if objects_node == null:
		_quality_broadcast_snapshot.clear()
		return
	var count = 0
	for child in objects_node.get_children():
		if not is_shadow_node_type(child) or not child.has_meta("node_id"):
			continue
		var node_id = str(child.get_meta("node_id"))
		if not _quality_broadcast_snapshot.has(node_id):
			continue
		var prev_q = int(_quality_broadcast_snapshot[node_id])
		# Update saved data even if the shadow isn't active.
		if not child.has_meta(SHADOW_META_KEY):
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
				global.ModMapData[SHADOW_DATA_KEY][node_id]["quality"] = prev_q
			continue
		var existing_cfg = child.get_meta("_shadow_config") if child.has_meta("_shadow_config") else null
		if existing_cfg == null:
			continue
		var new_cfg = existing_cfg.duplicate()
		new_cfg["quality"] = prev_q
		var use_clip = new_cfg.get("clip_walls", false) or new_cfg.get("clip_paths", false)
		var had_clip = child.has_meta("_shadow_clip_tex")
		if not use_clip and not had_clip and _fast_update_shadow(child, new_cfg):
			pass
		else:
			remove_shadow(child)
			create_shadow(child, new_cfg)
		save_shadow_data(child, new_cfg)
		count += 1
	outputlog("quality broadcast OFF: restored %d shadows from snapshot" % count, 0)
	_quality_broadcast_snapshot.clear()
	_save_broadcast_state(false)

func _save_broadcast_state(active: bool) -> void:
	"""Mirror the in-memory broadcast state into ModMapData so it survives map
	save/load and DD restart. Stored as {'active': bool, 'snapshot': {nid: q}}."""
	if active:
		global.ModMapData[BROADCAST_DATA_KEY] = {
			"active": true,
			"snapshot": _quality_broadcast_snapshot.duplicate()
		}
	else:
		# Toggle OFF: drop the persisted record entirely so a future map load
		# starts in the inactive state.
		if global.ModMapData.has(BROADCAST_DATA_KEY):
			global.ModMapData.erase(BROADCAST_DATA_KEY)

func _restore_broadcast_state_from_save() -> void:
	"""Called after apply_saved_shadows_to_map. If the saved map had the broadcast
	toggle ON, repopulate the in-memory snapshot and press the UI toggle so the
	user can release it later to restore the pre-broadcast quality values."""
	if not global.ModMapData.has(BROADCAST_DATA_KEY):
		return
	var data = global.ModMapData[BROADCAST_DATA_KEY]
	if not (data is Dictionary) or not data.get("active", false):
		return
	var snap = data.get("snapshot", {})
	if not (snap is Dictionary):
		return
	_quality_broadcast_snapshot = snap.duplicate()
	# Reflect ON state in the toggle button without firing the toggled signal
	# (we don't want to re-broadcast — shadows are already at the broadcast
	# values from the saved data).
	var btn = ui_config.get("quality_apply_all_btn")
	if btn != null and is_instance_valid(btn):
		btn.set_block_signals(true)
		btn.pressed = true
		btn.set_block_signals(false)
	outputlog("broadcast state restored: %d snapshots loaded" % _quality_broadcast_snapshot.size(), 0)

func _apply_quality_to_all_objects(quality_value: int) -> void:
	"""Propagate a quality value to every shadow on the current level — leaves
	all other settings (color, blur, offset, etc.) untouched. Distinct from
	_on_apply_all_confirmed which pushes the full UI config."""
	var level = global.World.GetCurrentLevel()
	if level == null:
		outputlog("quality apply-to-all: no current level", 0)
		return
	var objects_node = level.get_node_or_null("Objects")
	if objects_node == null:
		outputlog("quality apply-to-all: no Objects container on current level", 0)
		return
	var count = 0
	for child in objects_node.get_children():
		if not is_shadow_node_type(child):
			continue
		if not child.has_meta("node_id"):
			continue
		# Update the saved config even for shadows that aren't currently active,
		# so a future enable picks up the broadcast value.
		if not child.has_meta(SHADOW_META_KEY):
			var node_id_no_shadow = str(child.get_meta("node_id"))
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id_no_shadow):
				global.ModMapData[SHADOW_DATA_KEY][node_id_no_shadow]["quality"] = quality_value
			continue
		var existing_cfg = child.get_meta("_shadow_config") if child.has_meta("_shadow_config") else null
		if existing_cfg == null:
			continue
		var new_cfg = existing_cfg.duplicate()
		new_cfg["quality"] = quality_value
		# Fast-update path handles quality changes without rebuilding the node.
		var use_clip = new_cfg.get("clip_walls", false) or new_cfg.get("clip_paths", false)
		var had_clip = child.has_meta("_shadow_clip_tex")
		if not use_clip and not had_clip and _fast_update_shadow(child, new_cfg):
			pass
		else:
			remove_shadow(child)
			create_shadow(child, new_cfg)
		save_shadow_data(child, new_cfg)
		count += 1
	outputlog("quality apply-to-all: updated %d shadows to %d%%" % [count, quality_value], 0)

func _on_apply_all_confirmed(mode = "all"):
	ui_config["apply_all_dialog"].hide()
	var cfg = get_current_shadow_config()
	cfg["enabled"] = true
	var count = 0
	_history_begin_manual("apply_all")

	# "Selected objects" mode — apply to current selection only
	if mode == "selected":
		for node in global.Editor.Tools["SelectTool"].Selected:
			if not is_shadow_node_type(node):
				continue
			if not node.has_meta("node_id"):
				continue
			_history_capture_before(node)
			var obj_config = cfg.duplicate()
			remove_shadow(node)
			create_shadow(node, obj_config)
			save_shadow_data(node, obj_config)
			count += 1
		outputlog("Applied shadow to " + str(count) + " selected objects", 0)
		_history_flush()
		return

	# Determine layer scope: 0=all, 1=current, 2=filtered
	var scope = _get_selected_scope()
	var scope_names = ["all_layers", "current_layer", "filtered_layers"]
	var scope_name = scope_names[scope]

	var containers = _get_object_containers_for_scope(scope)
	if containers.size() == 0:
		outputlog("apply_all: no object containers found for scope " + scope_name, 0)
		_history_flush()
		return

	var only_without_shadow = (mode == "no_shadow")
	var scope_z_filter = ui_config.get("_scope_z_filter", null)  # set by current_layer scope
	var scope_layer_filter = ui_config.get("_scope_layer_filter", null)  # set by filtered scope
	for container in containers:
		for obj in container.get_children():
			if is_shadow_node_type(obj):
				# Filter by z_index for "current layer" scope
				if scope == 1 and scope_z_filter != null:
					if obj.z_index != scope_z_filter:
						continue
				# Filter by layer filter for "filtered layers" scope
				if scope == 2 and scope_layer_filter != null:
					if scope_layer_filter is Dictionary:
						# LayerFilter = {z_index: true/false} — true means layer is active
						if scope_layer_filter.has(obj.z_index) and not scope_layer_filter[obj.z_index]:
							continue
						# If z_index not in filter at all, skip it
						if not scope_layer_filter.has(obj.z_index):
							continue
					elif scope_layer_filter is Array and not (obj.z_index in scope_layer_filter):
						continue
				if only_without_shadow:
					if obj.has_meta(SHADOW_META_KEY):
						var nodes = obj.get_meta(SHADOW_META_KEY)
						if nodes is Array and nodes.size() > 0:
							continue
				_history_capture_before(obj)
				var obj_config = cfg.duplicate()
				remove_shadow(obj)
				create_shadow(obj, obj_config)
				save_shadow_data(obj, obj_config)
				count += 1
	var z_info = ""
	if scope_z_filter != null:
		z_info = " z_filter=" + str(scope_z_filter)
	outputlog("Applied shadow to " + str(count) + " objects (mode: " + str(mode) + ", scope: " + scope_name + z_info + ")", 0)
	# Clean up temp filter keys
	ui_config.erase("_scope_z_filter")
	ui_config.erase("_scope_layer_filter")
	_history_flush()

func _get_object_containers_for_scope(scope: int) -> Array:
	"""Return Objects containers based on the chosen layer scope.
	0 = all layers, 1 = current layer (same z_index), 2 = filtered layers."""
	var containers = []

	# For all scopes, we iterate objects within containers, so always collect
	# the Objects container from every level (scene tree Level, not DD layer)
	var all_obj_containers = []
	var current_level = global.World.GetCurrentLevel()
	if current_level == null:
		outputlog("scope: GetCurrentLevel() returned null", 0)
		return containers
	var world_root = current_level.get_parent()
	if world_root != null:
		for i in range(world_root.get_child_count()):
			var level = world_root.get_child(i)
			if not is_instance_valid(level):
				continue
			for j in range(level.get_child_count()):
				var child = level.get_child(j)
				if child.name == "Objects":
					all_obj_containers.append(child)
					break

	if all_obj_containers.size() == 0:
		outputlog("scope: no Objects containers found", 0)

	if scope == 0:
		# All layers — return all containers, no filtering
		outputlog("scope=all_layers containers=" + str(all_obj_containers.size()), 0)
		return all_obj_containers

	if scope == 1:
		# Current layer = same DD layer (z_index) as the selected object
		var target_z = 0
		if _monitored_object != null and is_instance_valid(_monitored_object):
			target_z = _monitored_object.z_index
		outputlog("scope=current_layer target_z=" + str(target_z), 0)
		# We still return all containers, but _on_apply_all_confirmed will filter by z_index
		ui_config["_scope_z_filter"] = target_z
		return all_obj_containers

	if scope == 2:
		# Filtered layers — use SelectTool.LayerFilter {z_index: bool}
		var select_tool = global.Editor.Tools["SelectTool"]
		var layer_filter = select_tool.get("LayerFilter")
		if layer_filter != null and layer_filter is Dictionary:
			ui_config["_scope_layer_filter"] = layer_filter
			outputlog("scope=filtered: LayerFilter=" + str(layer_filter), 0)
		else:
			ui_config["_scope_layer_filter"] = null
			outputlog("scope=filtered: no LayerFilter found", 0)
		return all_obj_containers

	return containers

func _on_reset_defaults():
	DEFAULT_SHADOW_CONFIG = FACTORY_DEFAULTS.duplicate()
	_obj_tool_use_defaults = true
	_update_lock_btn_icon()
	_save_defaults_to_map()
	_update_reset_defaults_visibility()
	outputlog("Defaults reset to factory (does not affect current asset)", 0)

func _apply_proj_ui_from_config(cfg: Dictionary) -> void:
	# Set the Style selector + projected controls from a config dict. The caller
	# must already be inside _syncing_ui = true (snaps are reset safely either way).
	var smode = cfg.get("shadow_mode", "offset")
	var is_extrude = cfg.get("proj_extrude", 0.0) >= 0.5
	if ui_config.has("mode_opt"):
		if smode == "projected":
			ui_config["mode_opt"].selected = 1 if is_extrude else 2
		else:
			ui_config["mode_opt"].selected = 0
		_update_shadow_mode_visibility(ui_config["mode_opt"].selected)
		_update_proj_taper_enabled(ui_config["mode_opt"].selected != 2)
	var plen = clamp(cfg.get("proj_length", 0.0), 0.0, PROJ_MAX_LENGTH)
	if ui_config.has("proj_dist_spin"):
		ui_config["proj_dist_spin"].value = plen
	var ptap = cfg.get("proj_taper", 0.0)
	if ui_config.has("proj_taper_slider"):
		ui_config["proj_taper_slider"].value = ptap
	if ui_config.has("proj_taper_spin"):
		ui_config["proj_taper_spin"].value = ptap
	var pfade = cfg.get("proj_fade", 0.5)
	if ui_config.has("proj_fade_slider"):
		ui_config["proj_fade_slider"].value = pfade
	if ui_config.has("proj_fade_spin"):
		ui_config["proj_fade_spin"].value = pfade
	var sun_deg = fmod(rad2deg(cfg.get("proj_angle", 0.0)) + 180.0, 360.0)
	if sun_deg < 0.0:
		sun_deg += 360.0
	if ui_config.has("proj_sun_angle_spin"):
		ui_config["proj_sun_angle_spin"].value = round(sun_deg)
	_deactivate_all_proj_snaps()
	if ui_config.has("proj_dir_dial"):
		var frac2 = sqrt(plen / PROJ_MAX_LENGTH) if PROJ_MAX_LENGTH > 0.0 else 0.0
		var lr = deg2rad(sun_deg)
		_set_proj_dial_handle(ui_config["proj_dir_dial"], Vector2(cos(lr), sin(lr)) * frac2)

func _on_copy_shadow():
	_clipboard = get_current_shadow_config()
	outputlog("Shadow settings copied", 0)

func _on_paste_shadow():
	if _clipboard.empty():
		return
	_syncing_ui = true
	if _clipboard.has("opacity"):
		ui_config["opacity_slider"].value = _clipboard["opacity"]
		ui_config["opacity_spin"].value = _clipboard["opacity"]
	if _clipboard.has("blur"):
		ui_config["blur_slider"].value = _clipboard["blur"]
		ui_config["blur_spin"].value = _clipboard["blur"]
	if _clipboard.has("quality"):
		_set_quality_ui_value(_clipboard["quality"])
	if _clipboard.has("range"):
		ui_config["range_slider"].value = _clipboard["range"]
		ui_config["range_spin"].value = _clipboard["range"]
	if _clipboard.has("offset_x") or _clipboard.has("offset_y"):
		_set_dial_from_offset(
			_clipboard.get("offset_x", 0.0),
			_clipboard.get("offset_y", 0.0)
		)
	if _clipboard.has("shadow_color"):
		var sc = _clipboard["shadow_color"]
		if sc is String:
			sc = Color(sc)
		ui_config["shadow_color_picker"].color = sc
	if _clipboard.has("enabled") and _clipboard["enabled"]:
		ui_config["enable_check"].pressed = true
	if _clipboard.has("behind_layer"):
		ui_config["behind_layer_check"].pressed = _clipboard["behind_layer"]
	# Restore snap state from clipboard
	var pasted_snap = _clipboard.get("snap_angle", -1.0)
	for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
		if ui_config.has(snap_key):
			set_property_but_block_signals(ui_config[snap_key], "pressed", false)
	var paste_dial = ui_config.get("dial")
	if paste_dial != null:
		paste_dial.set_meta("snap_angle", -1.0)
	if pasted_snap >= 0.0:
		if paste_dial != null:
			paste_dial.set_meta("snap_angle", pasted_snap)
		var snap_map = {45.0: "snap_45", 135.0: "snap_135", 225.0: "snap_225", 315.0: "snap_315"}
		for angle_val in snap_map.keys():
			if abs(pasted_snap - angle_val) < 0.5 and ui_config.has(snap_map[angle_val]):
				set_property_but_block_signals(ui_config[snap_map[angle_val]], "pressed", true)
	# Style + projected controls (mode, distance, angle, fade, cone, dial).
	_apply_proj_ui_from_config(_clipboard)
	_syncing_ui = false
	apply_shadow_to_selected()
#########################################################################################################

func get_current_shadow_config() -> Dictionary:
	var snap = -1.0
	var dial = ui_config.get("dial")
	if dial != null:
		snap = dial.get_meta("snap_angle") as float
	return {
		"enabled": ui_config["enable_check"].pressed,
		"opacity": ui_config["opacity_spin"].value,
		"blur": ui_config["blur_spin"].value,
		"quality": int(ui_config["quality_spin"].value),
		"offset_x": ui_config["offset_x_spin"].value,
		"offset_y": ui_config["offset_y_spin"].value,
		"range": ui_config["range_spin"].value,
		"behind_layer": ui_config["behind_layer_check"].pressed,
		"shadow_color": ui_config["shadow_color_picker"].color,
		"clip_walls": ui_config["clip_walls_check"].pressed,
		"clip_paths": ui_config["clip_paths_check"].pressed,
		"snap_angle": snap,
		"shadow_mode": ("projected" if (ui_config.has("mode_opt") and ui_config["mode_opt"].selected >= 1) else "offset"),
		"proj_angle": (deg2rad(fmod(ui_config["proj_sun_angle_spin"].value + 180.0, 360.0)) if ui_config.has("proj_sun_angle_spin") else 0.0),
		"proj_length": (ui_config["proj_dist_spin"].value if ui_config.has("proj_dist_spin") else 0.0),
		"proj_anchor_x": (ui_config["proj_anchor_x_spin"].value if ui_config.has("proj_anchor_x_spin") else 0.0),
		"proj_anchor_y": (ui_config["proj_anchor_y_spin"].value if ui_config.has("proj_anchor_y_spin") else 0.0),
		"proj_taper": (ui_config["proj_taper_spin"].value if ui_config.has("proj_taper_spin") else 0.0),
		"proj_fade": (ui_config["proj_fade_spin"].value if ui_config.has("proj_fade_spin") else 0.5),
		"proj_extrude": (1.0 if (ui_config.has("mode_opt") and ui_config["mode_opt"].selected == 1) else 0.0)
	}

func _clear_loading_ui():
	_loading_ui = false

func apply_shadow_to_selected(force_all: bool = false, changed_keys: Array = []):
	if _loading_ui:
		return
	# Ouvre/prolonge une transaction d'historique (snapshot avant mutation).
	_history_touch("offset" if changed_keys.empty() else str(changed_keys[0]))
	var ui_cfg = get_current_shadow_config()

	var objects_to_process = []
	
	# Always include the monitored object
	if _monitored_object != null and is_instance_valid(_monitored_object):
		if _monitored_object.has_meta("node_id"):
			objects_to_process.append(_monitored_object)
	
	# Also include other selected nodes
	for node in global.Editor.Tools["SelectTool"].Selected:
		if not is_shadow_node_type(node):
			continue
		if objects_to_process.has(node):
			continue
		if not node.has_meta("node_id"):
			continue
		if force_all:
			# Toggle ON/OFF: include ALL selected nodes
			objects_to_process.append(node)
		else:
			# Slider change: only include nodes already with shadow enabled
			var nid = str(node.get_meta("node_id"))
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
				var saved = global.ModMapData[SHADOW_DATA_KEY][nid]
				if saved.get("enabled", false):
					objects_to_process.append(node)
	
	for node in objects_to_process:
		var node_id = str(node.get_meta("node_id"))
		
		var cfg: Dictionary
		if node == _monitored_object:
			# The primary selected object always gets the full UI config
			cfg = ui_cfg
		elif force_all:
			# Toggle ON/OFF: use node's own saved config, only override "enabled"
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
				cfg = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
				if cfg.has("shadow_color") and cfg["shadow_color"] is String:
					cfg["shadow_color"] = Color(cfg["shadow_color"])
			else:
				cfg = DEFAULT_SHADOW_CONFIG.duplicate()
			cfg["enabled"] = ui_cfg["enabled"]
		elif changed_keys.size() > 0:
			# Per-parameter edit: start from node's saved config, merge only changed keys
			if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
				cfg = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
				if cfg.has("shadow_color") and cfg["shadow_color"] is String:
					cfg["shadow_color"] = Color(cfg["shadow_color"])
			else:
				cfg = DEFAULT_SHADOW_CONFIG.duplicate()
			# When range changes, scale this object's offsets proportionally
			if "range" in changed_keys:
				var old_range = cfg.get("range", 1.0)
				var new_range = ui_cfg.get("range", 1.0)
				if old_range > 0.001 and abs(new_range - old_range) > 0.001:
					var scale_f = new_range / old_range
					cfg["offset_x"] = round(cfg.get("offset_x", 0.0) * scale_f)
					cfg["offset_y"] = round(cfg.get("offset_y", 0.0) * scale_f)
			for key in changed_keys:
				if ui_cfg.has(key):
					cfg[key] = ui_cfg[key]
		else:
			# Fallback: full UI config (single selection or no specific key)
			cfg = ui_cfg
		
		if cfg["enabled"]:
			var use_clip = cfg.get("clip_walls", false) or cfg.get("clip_paths", false)
			var had_clip = node.has_meta("_shadow_clip_tex")
			if not use_clip and not had_clip and _fast_update_shadow(node, cfg):
				pass
			else:
				remove_shadow(node)
				create_shadow(node, cfg)
			save_shadow_data(node, cfg)
		else:
			remove_shadow(node)
			save_shadow_data(node, cfg)


#########################################################################################################
##
## UI REPARENTING & LOADING
##
#########################################################################################################

func _reparent_ui_to_node(node):
	var container = ui_config.get("container")
	if container == null:
		return
	var target_parent = ui_config.get("_obj_parent")
	if target_parent == null:
		return
	if container.get_parent() == target_parent:
		return
	if container.get_parent() != null:
		container.get_parent().remove_child(container)
	target_parent.add_child(container)

func load_shadow_ui_from_object(obj):
	if obj == null or not is_instance_valid(obj):
		return
	if not obj.has_meta("node_id"):
		return

	var node_id = str(obj.get_meta("node_id"))
	var config = DEFAULT_SHADOW_CONFIG.duplicate()
	# Track whether the raw save predates the quality field — older shadows were
	# rendered at the legacy auto-computed quality (= 100% in our new scaling),
	# so we want to display 100 for them rather than the new default of 70.
	var legacy_pre_quality = false

	# Load saved config if it exists
	if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
		var saved = global.ModMapData[SHADOW_DATA_KEY][node_id]
		legacy_pre_quality = not saved.has("quality") and saved.has("enabled")
		for key in saved.keys():
			config[key] = saved[key]
		# Backward compat: migrate old "size"/"softness" to "blur"
		if saved.has("size") and not saved.has("blur"):
			config["blur"] = clamp(saved["size"] / 0.75, 0.0, 1.0)
		config.erase("size")
		config.erase("softness")
	if legacy_pre_quality:
		config["quality"] = 100

	# Sync UI
	_syncing_ui = true
	ui_config["enable_check"].pressed = config.get("enabled", false)
	ui_config["opacity_slider"].value = config.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"])
	ui_config["opacity_spin"].value = config.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"])
	ui_config["blur_slider"].value = config.get("blur", DEFAULT_SHADOW_CONFIG["blur"])
	ui_config["blur_spin"].value = config.get("blur", DEFAULT_SHADOW_CONFIG["blur"])
	# Quality: snap to closest tier so legacy free-form percentages (e.g. a save
	# from the slider implementation that wrote 70) still produce a valid radio
	# selection. The pre-quality-key migration above already promoted unmodded
	# old saves to 100 (Ultra) for visual continuity.
	var quality_val = config.get("quality", DEFAULT_SHADOW_CONFIG.get("quality", FACTORY_DEFAULTS["quality"]))
	_set_quality_ui_value(quality_val)
	ui_config["range_slider"].value = config.get("range", DEFAULT_SHADOW_CONFIG["range"])
	ui_config["range_spin"].value = config.get("range", DEFAULT_SHADOW_CONFIG["range"])
	_update_offset_range(config.get("range", DEFAULT_SHADOW_CONFIG["range"]), false)
	_set_dial_from_offset(
		config.get("offset_x", DEFAULT_SHADOW_CONFIG["offset_x"]),
		config.get("offset_y", DEFAULT_SHADOW_CONFIG["offset_y"])
	)
	var sc = config.get("shadow_color", DEFAULT_SHADOW_CONFIG["shadow_color"])
	if sc is String:
		sc = Color(sc)
	ui_config["shadow_color_picker"].color = sc
	ui_config["behind_layer_check"].pressed = config.get("behind_layer", DEFAULT_SHADOW_CONFIG.get("behind_layer", false))
	ui_config["clip_walls_check"].pressed = config.get("clip_walls", DEFAULT_SHADOW_CONFIG.get("clip_walls", false))
	ui_config["clip_paths_check"].pressed = config.get("clip_paths", DEFAULT_SHADOW_CONFIG.get("clip_paths", false))
	# Restore snap state
	var saved_snap = config.get("snap_angle", -1.0)
	# Deactivate all snaps without triggering signals
	for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
		if ui_config.has(snap_key):
			set_property_but_block_signals(ui_config[snap_key], "pressed", false)
	var dial = ui_config.get("dial")
	if dial != null:
		dial.set_meta("snap_angle", -1.0)
	if saved_snap >= 0.0:
		if dial != null:
			dial.set_meta("snap_angle", saved_snap)
		var snap_map = {45.0: "snap_45", 135.0: "snap_135", 225.0: "snap_225", 315.0: "snap_315"}
		for angle_val in snap_map.keys():
			if abs(saved_snap - angle_val) < 0.5 and ui_config.has(snap_map[angle_val]):
				set_property_but_block_signals(ui_config[snap_map[angle_val]], "pressed", true)
	# Restore projected-mode controls
	var smode = config.get("shadow_mode", "offset")
	var is_extrude = config.get("proj_extrude", 0.0) >= 0.5
	if ui_config.has("mode_opt"):
		if smode == "projected":
			ui_config["mode_opt"].selected = 1 if is_extrude else 2
		else:
			ui_config["mode_opt"].selected = 0
		_update_proj_taper_enabled(ui_config["mode_opt"].selected != 2)
	var plen = clamp(config.get("proj_length", 0.0), 0.0, PROJ_MAX_LENGTH)
	if ui_config.has("proj_dist_spin"):
		ui_config["proj_dist_spin"].value = plen
	var ptap = config.get("proj_taper", 0.0)
	if ui_config.has("proj_taper_slider"):
		ui_config["proj_taper_slider"].value = ptap
	if ui_config.has("proj_taper_spin"):
		ui_config["proj_taper_spin"].value = ptap
	# Fade (soft directional shadow)
	var pfade = config.get("proj_fade", 0.5)
	if ui_config.has("proj_fade_slider"):
		ui_config["proj_fade_slider"].value = pfade
	if ui_config.has("proj_fade_spin"):
		ui_config["proj_fade_spin"].value = pfade
	# Sun angle = opposite of the stored shadow angle. Snap buttons reset on load.
	var shadow_deg = rad2deg(config.get("proj_angle", 0.0))
	var sun_deg = fmod(shadow_deg + 180.0, 360.0)
	if sun_deg < 0.0:
		sun_deg += 360.0
	if ui_config.has("proj_sun_angle_spin"):
		ui_config["proj_sun_angle_spin"].value = round(sun_deg)
	_deactivate_all_proj_snaps()
	if ui_config.has("proj_dir_dial"):
		# Handle points to the SUN (opposite the shadow). Radius encodes length.
		var frac2 = sqrt(plen / PROJ_MAX_LENGTH)
		var lr = deg2rad(sun_deg)
		_set_proj_dial_handle(ui_config["proj_dir_dial"], Vector2(cos(lr), sin(lr)) * frac2)
	_syncing_ui = false
	if ui_config.has("mode_opt"):
		_update_shadow_mode_visibility(ui_config["mode_opt"].selected)

	# Update visibility
	var enabled = config.get("enabled", false)
	ui_config["settings_toggle"].visible = enabled
	ui_config["title_reset_btn"].visible = enabled
	if enabled and ui_config["settings_toggle"].pressed:
		ui_config["settings_panel"].visible = true
	else:
		ui_config["settings_panel"].visible = false

#########################################################################################################
##
## SAVE / LOAD
##
#########################################################################################################

func save_shadow_data(obj, config: Dictionary):
	if obj == null or not is_instance_valid(obj):
		return
	if not obj.has_meta("node_id"):
		return

	var node_id = str(obj.get_meta("node_id"))

	if not global.ModMapData.has(SHADOW_DATA_KEY):
		global.ModMapData[SHADOW_DATA_KEY] = {}

	var save_config = config.duplicate()
	if save_config.has("shadow_color") and save_config["shadow_color"] is Color:
		save_config["shadow_color"] = save_config["shadow_color"].to_html(true)

	global.ModMapData[SHADOW_DATA_KEY][node_id] = save_config
	_all_known_obj_ids[node_id] = obj
	obj.set_meta("_shadow_config", config)

func _save_defaults_to_map():
	"""Persist DEFAULT_SHADOW_CONFIG to ModMapData so it survives save/load."""
	var save_cfg = DEFAULT_SHADOW_CONFIG.duplicate()
	if save_cfg.has("shadow_color") and save_cfg["shadow_color"] is Color:
		save_cfg["shadow_color"] = save_cfg["shadow_color"].to_html(true)
	global.ModMapData["DropShadowDefaults"] = save_cfg

func _load_defaults_from_map():
	"""Restore DEFAULT_SHADOW_CONFIG from ModMapData after map load."""
	if not global.ModMapData.has("DropShadowDefaults"):
		return
	var saved = global.ModMapData["DropShadowDefaults"]
	if not (saved is Dictionary):
		return
	DEFAULT_SHADOW_CONFIG = saved.duplicate()
	DEFAULT_SHADOW_CONFIG["enabled"] = false
	if DEFAULT_SHADOW_CONFIG.has("shadow_color") and DEFAULT_SHADOW_CONFIG["shadow_color"] is String:
		DEFAULT_SHADOW_CONFIG["shadow_color"] = Color(DEFAULT_SHADOW_CONFIG["shadow_color"])
	_update_reset_defaults_visibility()

# Walk every Level's "Objects" and "Roofs" containers and register each node id
# in _all_known_obj_ids. Multi-level safe; called once at load. Prevents objects
# saved without a shadow from being treated as new clones on first click.
func _seed_known_object_ids() -> void:
	if global == null:
		return
	var current_level = global.World.GetCurrentLevel()
	if current_level == null:
		return
	var world_root = current_level.get_parent()
	if world_root == null:
		return
	var count = 0
	for i in range(world_root.get_child_count()):
		var level = world_root.get_child(i)
		if not is_instance_valid(level):
			continue
		for container_name in ["Objects", "Roofs"]:
			var cont = level.get_node_or_null(container_name)
			if cont == null:
				continue
			for child in cont.get_children():
				if is_instance_valid(child) and child.has_meta("node_id"):
					var nid = str(child.get_meta("node_id"))
					if not _all_known_obj_ids.has(nid):
						_all_known_obj_ids[nid] = child
						count += 1
	outputlog("Seeded " + str(count) + " known object ids at load", 0)

func _heal_missing_shadows():
	# Recreate shadows that should exist (saved config, enabled) but whose live
	# node is gone. Covers map reload when apply_saved_shadows_to_map didn't run,
	# and nodes that loaded after it. Skips nodes that already have a shadow
	# (including hidden ones — ShadowToggle only flips .visible, keeping the meta).
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return
	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	var hidden = bool(global.ModMapData.get("DropShadowToggleHidden", false))
	for node_id in shadow_data.keys():
		var cfg = shadow_data[node_id]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		if int(node_id) < 0:
			continue
		var int_id = int(node_id)
		if not global.World.HasNodeID(int_id):
			continue
		var node = global.World.GetNodeByID(int_id)
		if node == null or not is_instance_valid(node):
			continue
		if not is_shadow_node_type(node):
			continue
		if node.has_meta(SHADOW_META_KEY):
			continue
		var sprite = get_sprite(node)
		if sprite == null or sprite.texture == null:
			continue  # not ready yet — try again next scan
		var rebuild_cfg = cfg.duplicate()
		if rebuild_cfg.has("shadow_color") and rebuild_cfg["shadow_color"] is String:
			rebuild_cfg["shadow_color"] = Color(rebuild_cfg["shadow_color"])
		remove_shadow(node)
		create_shadow(node, rebuild_cfg)
		_all_known_obj_ids[str(int_id)] = node
		if hidden and node.has_meta(SHADOW_META_KEY):
			for n in node.get_meta(SHADOW_META_KEY):
				if is_instance_valid(n):
					n.visible = false

func apply_saved_shadows_to_map():
	outputlog("apply_saved_shadows_to_map (objects)", 0)
	outputlog("  shader loaded: " + str(_shadow_shader != null), 0)

	_load_defaults_from_map()
	_update_reset_defaults_visibility()

	# Register every pre-existing object/roof so a first selection after reload
	# is never mistaken for a freshly-placed clone (which would auto-apply the
	# ObjectTool placement shadow). Runs while monitors are paused → safe.
	_seed_known_object_ids()

	if not global.ModMapData.has(SHADOW_DATA_KEY):
		outputlog("  no shadow data found", 0)
		return

	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	var count = 0

	for node_id in shadow_data.keys():
		if int(node_id) < 0:
			continue
		var int_id = int(node_id)
		if global.World.HasNodeID(int_id):
			var node = global.World.GetNodeByID(int_id)
			if is_shadow_node_type(node):
				var config = shadow_data[node_id]
				_all_known_obj_ids[str(int_id)] = node
				if config.get("enabled", false):
					outputlog("  creating shadow for object " + str(node_id) + " name=" + str(node.name), 0)
					remove_shadow(node)
					create_shadow(node, config)
					count += 1

	outputlog("Applied shadows to " + str(count) + " objects", 0)
	# After all shadows are recreated, restore the broadcast toggle state and
	# its snapshot if the map was saved with the broadcast active.
	_restore_broadcast_state_from_save()
