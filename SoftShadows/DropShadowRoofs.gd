#########################################################################################################
##
## DROP SHADOW FOR ROOFS
##
#########################################################################################################
# Soft drop shadow for the Roof tool. Renders a faded silhouette mesh that
# extrudes the roof outline toward the offset direction, suggesting that the
# roof has volume above the ground.
#
# This first revision focuses on rendering only — no UI, no persistence.
# Defaults are hardcoded; new roofs get a shadow automatically, and existing
# roofs on the loaded map get one applied via apply_saved_state().

var global
var dropshadow_objects = null
var core = null
var logging_level = 0

# Match the meta key used by the other DropShadow scripts so future cleanup
# / select-tool integration can reuse the same plumbing.
const SHADOW_META_KEY = "drop_shadow_nodes"
const ENABLE_LOGGING = true

# Persistent storage in global.ModMapData. Keyed by node_id (the persistent
# DD identifier, distinct from instance_id which is RAM-only). Color is
# stored as hex string for JSON serialisation.
const SHADOW_DATA_KEY = "DropShadowRoof"
const GLOBAL_DATA_KEY = "DropShadowRoofGlobal"  # opacity / softness / sun

# Hardcoded for now. UI will write into the same shape later.
const DEFAULT_CONFIG = {
	"enabled": true,
	"opacity": 0.5,
	"softness": 10.0,
	"offset_x": 100.0,
	"offset_y": 100.0,
	"ridge_height": 2.0,
	"shadow_color": Color(0, 0, 0, 1)
}

# Rotation monitor: roofs with an active shadow are tracked here so we can
# rebuild the shadow when the user rotates them (otherwise the offset would
# rotate along with the roof and drift away from world-space).
# instance_id -> { roof: WeakRef, last_rotation: float, config: Dictionary }
var _monitored_roofs := {}
var _monitor_timer: Timer = null
const _ROTATION_EPSILON := 0.0005  # ~0.03°

# Opacity is treated as a global parameter (like the sun direction): one slider
# value applies to every roof. When the UI changes it, we propagate to all
# tracked roofs; when a new roof is created, it picks up this value instead of
# the hardcoded default.
var _last_opacity: float = DEFAULT_CONFIG["opacity"]
var _last_softness: float = DEFAULT_CONFIG["softness"]
# Defaults applied to NEW roofs. These are configured from the RoofTool
# UI; existing roofs keep their per-roof config.
var _default_offset_x: float = DEFAULT_CONFIG["offset_x"]
var _default_offset_y: float = DEFAULT_CONFIG["offset_y"]
var _default_ridge_height: float = DEFAULT_CONFIG["ridge_height"]
var _default_enabled: bool = true

# === UI state ===
# The SelectTool UI lets the user edit the shadow config of the selected roof.
# Per-roof configs are remembered in _configs_by_id (keyed by instance id) and
# also mirrored on the roof as meta — same belt-and-suspenders pattern as the
# other DropShadow scripts.
var ui_config := {}
var rt_ui_config := {}
var _configs_by_id := {}
var _suppress_ui_signals := false
var _suppress_sun_signal := false
var _ui_built := false

# ── Undo/redo (transactions de réglages) ───────────────────────────────
var shadow_history = null   # set by Core
var _history_flush_timer = null
var _history_txn_active := false
var _history_txn_before := {}
var _history_txn_label := ""
var _history_suspend := false

# ── Détection des ops natives (timeline undo/redo) ─────────────────────
var _native_state_by_id := {}   # node_id -> {pos, hash} (move ET reshape natifs)
var _native_detect_ready := false
var _native_arm_count := 0
var _native_heal_count := 0
var _rt_ui_built := false

const DIAL_SIZE := 100
const MAX_DIAL_OFFSET := 1000.0
const META_CONFIG_KEY := "_drop_shadow_roof_config"

#########################################################################################################
##
## UTILITY
##
#########################################################################################################

func outputlog(msg, level = 0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <DropShadowRoofs>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
##
## INIT
##
#########################################################################################################

func initialise():
	outputlog("Drop Shadow Roofs initialising...", 0)
	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "_on_new_node_added")

	# Tick at 100ms — fast enough to feel live during drag-rotate, cheap
	# because we just compare a float per tracked roof.
	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.1
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)

	# Timer de debounce pour l'historique undo/redo.
	_history_flush_timer = Timer.new()
	_history_flush_timer.wait_time = 0.4
	_history_flush_timer.one_shot = true
	_history_flush_timer.connect("timeout", self, "_history_flush")
	global.Editor.add_child(_history_flush_timer)
	if shadow_history != null and shadow_history.has_method("register_flusher"):
		shadow_history.register_flusher(self, "_history_flush")
	if shadow_history != null and shadow_history.has_method("register_resync"):
		shadow_history.register_resync(self, "_history_force_resync")

	# Build SelectTool UI on next idle so DD's panels are ready
	call_deferred("_build_select_tool_ui")
	# Same for the RoofTool sidebar (defaults for new roofs + global params)
	call_deferred("_build_roof_tool_ui")
	# Hook the global RoofTool sun direction so changes there ripple to all
	# tracked roofs (and vice-versa). Same deferred call so RoofTool is up.
	call_deferred("_connect_sun_direction")

	outputlog("Drop Shadow Roofs initialised.", 0)

func apply_saved_state():
	# Phase 0 : pull global state (opacity, softness) from ModMapData if any.
	# This must happen BEFORE we start tracking roofs so newly created entries
	# pick up the correct globals.
	_load_globals()

	# Phase 1 : scan every roof on every level so the toggle / global sliders
	# can affect them all, even those the user never selected. Each tracked
	# roof gets a default-disabled config unless a persisted one exists.
	var all_roofs = _scan_all_roofs()
	var tracked = 0
	for roof in all_roofs:
		var iid = roof.get_instance_id()
		if _configs_by_id.has(iid):
			continue
		var persisted = _load_persisted_config(roof)
		var cfg
		if persisted != null:
			cfg = persisted
		else:
			cfg = DEFAULT_CONFIG.duplicate()
			cfg["enabled"] = false  # don't auto-enable for never-saved roofs
			cfg["opacity"] = _last_opacity
			cfg["softness"] = _last_softness
		_configs_by_id[iid] = cfg
		roof.set_meta(META_CONFIG_KEY, cfg)
		tracked += 1

	# Phase 2 : create shadows for every roof whose saved config has it on.
	var enabled_count = 0
	for iid in _configs_by_id.keys():
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			continue
		var cfg = _configs_by_id[iid]
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)
			enabled_count += 1

	outputlog("Drop Shadow Roofs: tracked %d roof(s), %d enabled" % [tracked, enabled_count], 0)

# Walk every Level under the World root and collect every Roof child of each
# "Roofs" container. Multi-level safe.
func _scan_all_roofs() -> Array:
	var out = []
	if global == null:
		return out
	var current_level = global.World.GetCurrentLevel()
	if current_level == null:
		return out
	var world_root = current_level.get_parent()
	if world_root == null:
		return out
	for i in range(world_root.get_child_count()):
		var level = world_root.get_child(i)
		if not is_instance_valid(level):
			continue
		var roofs_node = level.get_node_or_null("Roofs")
		if roofs_node == null:
			continue
		for child in roofs_node.get_children():
			if is_roof(child):
				out.append(child)
	return out

func on_selection_changed():
	if not _ui_built:
		outputlog("on_selection_changed: UI not built yet", 0)
		return
	var roof = _get_selected_roof()
	var c = ui_config.get("container")
	if c == null:
		outputlog("on_selection_changed: container missing", 0)
		return
	if roof == null:
		c.visible = false
		return
	c.visible = true
	_set_ui_from_config(_get_config_for_roof(roof))

#########################################################################################################
##
## TYPE DETECTION
##
#########################################################################################################

func is_roof(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not (node is Node2D):
		return false
	# A Roof exposes these unique properties (see modding API)
	return (node.get("ridge") != null
		and node.get("edge") != null
		and node.get("sides") != null
		and node.get("points") != null
		and node.get("type") != null)

func is_shadow_node_type(node) -> bool:
	return is_roof(node)

#########################################################################################################
##
## EVENTS
##
#########################################################################################################

func _on_new_node_added(node):
	if not is_roof(node):
		return
	# Op native d'ajout (placement/paste/redo) -> marqueur timeline.
	if _native_detect_ready and shadow_history != null and shadow_history.has_method("note_native_op"):
		shadow_history.note_native_op()
	# Defer one frame so DD finishes building the roof's edge/sides children
	call_deferred("_deferred_apply_default", node)

func _deferred_apply_default(node):
	if not is_instance_valid(node) or not is_roof(node):
		return
	# Detect whether this roof already has a config (in memory, on the node
	# itself, or in ModMapData). If yes, use it. If no, it's a brand new
	# roof — build the config from the LIVE RoofTool UI defaults
	# (_default_* / _last_*), not from DEFAULT_CONFIG.
	var iid = node.get_instance_id()
	var existing = null
	if _configs_by_id.has(iid):
		existing = _configs_by_id[iid]
	elif node.has_meta(META_CONFIG_KEY):
		var meta_cfg = node.get_meta(META_CONFIG_KEY)
		if meta_cfg is Dictionary:
			existing = meta_cfg
	else:
		var loaded = _load_persisted_config(node)
		if loaded != null:
			existing = loaded

	var cfg
	if existing != null:
		cfg = existing
	else:
		cfg = DEFAULT_CONFIG.duplicate()
		cfg["enabled"] = _default_enabled
		cfg["opacity"] = _last_opacity
		cfg["softness"] = _last_softness
		cfg["offset_x"] = _default_offset_x
		cfg["offset_y"] = _default_offset_y
		cfg["ridge_height"] = _default_ridge_height
	create_shadow(node, cfg)

func _on_monitor_tick():
	# Détection des ops natives (move/reshape/delete) pour la timeline undo/redo.
	_detect_native_roof_ops()
	if not _native_detect_ready:
		_native_arm_count += 1
		if _native_arm_count >= 20:
			_native_detect_ready = true
	# Heal périodique (~1 s) : reconstruit les shadows manquantes d'un roof
	# réapparu via un redo natif (nouvel instance_id, config persistée par node_id).
	_native_heal_count += 1
	if _native_heal_count >= 10:
		_native_heal_count = 0
		_history_force_resync()

	# Rebuild shadows for any tracked roof whose rotation drifted past epsilon.
	# Stale entries (freed roofs) are pruned in the same pass.
	if _monitored_roofs.empty():
		return
	var to_remove = []
	for iid in _monitored_roofs.keys():
		var entry = _monitored_roofs[iid]
		var roof = entry["roof"].get_ref()
		if roof == null or not is_instance_valid(roof):
			to_remove.append(iid)
			continue
		var current_rot = roof.global_rotation
		if abs(current_rot - entry["last_rotation"]) > _ROTATION_EPSILON:
			# create_shadow re-registers this roof with the fresh rotation.
			create_shadow(roof, entry["config"])
	for iid in to_remove:
		_monitored_roofs.erase(iid)

#########################################################################################################
##
## GEOMETRY HELPERS
##
#########################################################################################################

# ── Détection des ops natives + heal (timeline undo/redo) ──────────────
# Hash de FORME du roof (contour local, invariant par translation ; non pollué
# par les réglages de shadow qui ne touchent pas le contour).
func _get_roof_geom_hash(roof) -> int:
	var contour = _get_roof_contour(roof)
	var h = 0
	for p in contour:
		h = h * 31 + int(round(p.x * 10)) + int(round(p.y * 10)) * 7
	h = h * 31 + contour.size()
	return h

func _detect_native_roof_ops() -> void:
	if shadow_history == null or not shadow_history.has_method("note_native_op"):
		return
	var sel = global.Editor.Tools["SelectTool"].Selected
	var seen = {}
	for node in sel:
		if not is_instance_valid(node) or not is_roof(node):
			continue
		if not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))
		var pos = node.global_position
		var h = _get_roof_geom_hash(node)
		seen[nid] = true
		if _native_state_by_id.has(nid):
			var prev = _native_state_by_id[nid]
			if prev["pos"].distance_to(pos) > 0.01 or prev["hash"] != h:
				shadow_history.note_native_op()
		_native_state_by_id[nid] = {"pos": pos, "hash": h}
	for nid in _native_state_by_id.keys():
		if not seen.has(nid):
			if _native_detect_ready and int(nid) >= 0:
				if not global.World.HasNodeID(int(nid)):
					shadow_history.note_native_op()
			_native_state_by_id.erase(nid)

func _has_valid_shadow(roof, meta_key: String) -> bool:
	if not roof.has_meta(meta_key):
		return false
	var nodes = roof.get_meta(meta_key)
	if not (nodes is Array):
		return false
	for n in nodes:
		if is_instance_valid(n):
			return true
	return false

# Resync/heal : reconstruit les shadows manquantes des roofs présents+activés.
# Re-scanne les roofs vivants (un roof réapparu via redo a un NOUVEL instance_id ;
# son config est récupéré depuis la persistance par node_id). Ne purge jamais.
func _history_force_resync() -> void:
	var hidden = bool(global.ModMapData.get("DropShadowToggleHidden", false))
	for roof in _scan_all_roofs():
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			continue
		var iid = roof.get_instance_id()
		var cfg = null
		if _configs_by_id.has(iid):
			cfg = _configs_by_id[iid]
		else:
			var persisted = _load_persisted_config(roof)
			if persisted != null:
				cfg = persisted
				_configs_by_id[iid] = cfg
				roof.set_meta(META_CONFIG_KEY, cfg)
		if cfg == null or not cfg.get("enabled", false):
			continue
		if _has_valid_shadow(roof, SHADOW_META_KEY):
			continue
		create_shadow(roof, cfg)
		if hidden and roof.has_meta(SHADOW_META_KEY):
			for n in roof.get_meta(SHADOW_META_KEY):
				if is_instance_valid(n):
					n.visible = false

# Returns the roof's outer contour expressed in the roof's local coord system,
# closed implicitly (last vertex != first).
func _get_roof_contour(roof) -> PoolVector2Array:
	var edge = roof.get("edge")
	if edge == null:
		return PoolVector2Array()
	var pts = edge.points
	if pts == null or pts.size() < 3:
		return PoolVector2Array()

	# Edge is a Line2D child of the roof — convert to roof-local space
	var xform = edge.transform
	var out = PoolVector2Array()
	for p in pts:
		out.append(xform.xform(p))

	# Strip a closing duplicate vertex if present
	if out.size() >= 2 and out[0].distance_to(out[out.size() - 1]) < 0.5:
		out.remove(out.size() - 1)

	return out

# For each contour vertex, returns the height multiplier to use when
# projecting it: ridge_height if the vertex coincides with a ridge endpoint
# (the back-triangle tip in a dormer, for instance), 1.0 otherwise. This
# ensures the silhouette's projected pointed corners line up with the tips
# produced by _build_projected_roof_faces — no gap.
# For each contour vertex, returns the height multiplier to use when
# projecting it: ridge_height if the vertex coincides with a ridge endpoint
# (the back-triangle tip in a dormer, for instance), 1.0 otherwise. This
# ensures the silhouette's projected pointed corners line up with the tips
# produced by _build_projected_roof_faces — no gap.
# For dormers: identifies the visible apex (= off-contour ridge endpoint),
# the on-contour "back" ridge endpoint (where the dormer meets the main
# wall), and the two contour vertices flanking the contour vertex nearest
# to the apex (= the corners of the visible pignon's base).
func _compute_dormer_apex_data(roof, contour: PoolVector2Array) -> Dictionary:
	var result = {"apex_pos": null, "ridge_back_pos": null, "v1_idx": -1, "v2_idx": -1}
	var ridge = roof.get("ridge")
	if ridge == null:
		return result
	var rpts = ridge.points
	if rpts == null or rpts.size() < 1:
		return result
	var rxform = ridge.transform
	var ridge_local = []
	for p in rpts:
		ridge_local.append(rxform.xform(p))

	# Classify each ridge endpoint: apex (off-contour) vs back (on-contour)
	var apex_pos = null
	var back_pos = null
	for r in ridge_local:
		var inside = Geometry.is_point_in_polygon(r, contour)
		var on_contour = false
		for v in contour:
			if v.distance_squared_to(r) < 100.0:
				on_contour = true
				break
		if not inside and not on_contour:
			apex_pos = r
		elif on_contour:
			back_pos = r
	if apex_pos == null:
		return result
	result.apex_pos = apex_pos
	result.ridge_back_pos = back_pos

	# Find the contour vertex nearest to apex (= the base corner of the
	# visible pignon, typically = ridge_back_pos when it's on the contour).
	# v1, v2 are the prev/next neighbours in the contour.
	var n = contour.size()
	var min_d = INF
	var nearest = -1
	for i in range(n):
		var d = contour[i].distance_squared_to(apex_pos)
		if d < min_d:
			min_d = d
			nearest = i
	if nearest < 0:
		return result
	result.v1_idx = (nearest - 1 + n) % n
	result.v2_idx = (nearest + 1) % n
	return result

func _compute_vertex_heights(roof, contour: PoolVector2Array, ridge_height: float) -> Array:
	var n = contour.size()
	var heights = []
	heights.resize(n)
	for i in range(n):
		heights[i] = 1.0
	var ridge = roof.get("ridge")
	if ridge == null:
		return heights
	var rpts = ridge.points
	if rpts == null or rpts.size() < 1:
		return heights
	var rxform = ridge.transform
	var ridge_local = []
	for p in rpts:
		ridge_local.append(rxform.xform(p))

	# Only a vertex that is BOTH on a ridge endpoint AND a real corner of the
	# contour is a true apex. If the contour goes flat through the vertex
	# (the two adjacent edges are colinear), the vertex is just the BASE of
	# a pignon — like a dormer's ridge[0] sitting on the rectangle's edge —
	# and must stay at eaves height.
	for i in range(n):
		var v = contour[i]
		var on_ridge = false
		for r in ridge_local:
			if v.distance_squared_to(r) < 100.0:
				on_ridge = true
				break
		if not on_ridge:
			continue
		var prev_v = contour[(i - 1 + n) % n]
		var next_v = contour[(i + 1) % n]
		var d1 = (v - prev_v)
		var d2 = (next_v - v)
		if d1.length_squared() < 0.01 or d2.length_squared() < 0.01:
			continue
		d1 = d1.normalized()
		d2 = d2.normalized()
		if d1.dot(d2) > 0.99:
			continue  # colinear — base, not apex
		heights[i] = ridge_height
	return heights

# Builds the projected 3D faces of the roof. For each edge segment we look
# at which ridge endpoint each of its two endpoints is closest to:
#   • Same ridge endpoint for both → segment is a pignon (short end of the
#     gable). Project as a TRIANGLE: (v1+offset, v2+offset, ridge_end+offset×h).
#   • Different ridge endpoints      → segment is a long side. Project as a
#     QUAD: (v1+offset, v2+offset, ridge_b+offset×h, ridge_a+offset×h).
# Returns a list of PoolVector2Array — caller is responsible for merging
# them into the silhouette via _consolidate. Vertices are in roof-local
# space, ready to feed back into the silhouette pipeline.
func _build_projected_roof_faces(roof, offset: Vector2, height_factor: float) -> Array:
	var ridge = roof.get("ridge")
	var edge = roof.get("edge")
	if ridge == null or edge == null:
		return []
	var rpts = ridge.points
	var epts = edge.points
	if rpts == null or rpts.size() < 2 or epts == null or epts.size() < 3:
		return []

	var rxform = ridge.transform
	var exform = edge.transform
	var ridge_local = []
	for p in rpts:
		ridge_local.append(rxform.xform(p))
	var edge_local = []
	for p in epts:
		edge_local.append(exform.xform(p))
	if edge_local.size() >= 2 and edge_local[0].distance_to(edge_local[edge_local.size() - 1]) < 0.5:
		edge_local.pop_back()
	if edge_local.size() < 3:
		return []

	var ridge_a = ridge_local[0]
	var ridge_b = ridge_local[ridge_local.size() - 1]
	if ridge_a.distance_to(ridge_b) < 0.5:
		return []

	# For each edge vertex, decide which ridge endpoint it "belongs to".
	# Closest-point assignment works for typical Gable footprints.
	var ne = edge_local.size()
	var assign = []
	for v in edge_local:
		var d_a = (v - ridge_a).length_squared()
		var d_b = (v - ridge_b).length_squared()
		assign.append(0 if d_a <= d_b else 1)

	var ext = offset * height_factor
	var ridge_proj = [ridge_a + ext, ridge_b + ext]

	var faces = []
	for i in range(ne):
		var i_next = (i + 1) % ne
		var v1 = edge_local[i]
		var v2 = edge_local[i_next]
		var r1 = assign[i]
		var r2 = assign[i_next]
		var poly = PoolVector2Array()
		if r1 == r2:
			# Pignon: triangle from edge segment to one ridge endpoint
			poly.append(v1 + offset)
			poly.append(v2 + offset)
			poly.append(ridge_proj[r1])
		else:
			# Long side: quad from edge segment to the projected ridge line
			poly.append(v1 + offset)
			poly.append(v2 + offset)
			poly.append(ridge_proj[r2])
			poly.append(ridge_proj[r1])
		faces.append(poly)
	return faces

# For dormers, the ridge has one endpoint INSIDE the contour (the base of
# the pignon) and one OUTSIDE (the visible pignon tip drawn by DD via its
# sides polygons). The shadow silhouette needs that off-contour tip as a
# real contour vertex, otherwise the shadow stops at the rectangle and the
# projected ridge tip floats free.
#
# This returns the contour with the off-contour ridge endpoint inserted
# between its two nearest consecutive contour vertices. For a Gable (both
# ridge endpoints inside the contour), it returns the contour unchanged.
func _extend_contour_with_apex(roof, contour: PoolVector2Array) -> PoolVector2Array:
	var ridge = roof.get("ridge")
	if ridge == null:
		outputlog("EXTEND: no ridge node", 0)
		return contour
	var rpts = ridge.points
	if rpts == null or rpts.size() < 2:
		outputlog("EXTEND: ridge has %d points, need >=2" % (0 if rpts == null else rpts.size()), 0)
		return contour
	var rxform = ridge.transform
	var ridge_local = []
	for p in rpts:
		ridge_local.append(rxform.xform(p))

	# Find an off-contour ridge endpoint (= candidate apex). Off-contour
	# means: not on the contour AND not inside the contour. For Gables, both
	# ridge endpoints are INSIDE → no apex to insert.
	var apex = null
	outputlog("EXTEND: testing %d ridge points against contour:" % ridge_local.size(), 0)
	for r in ridge_local:
		var inside = Geometry.is_point_in_polygon(r, contour)
		var on_contour = false
		var nearest_d2 = INF
		for v in contour:
			var d2 = v.distance_squared_to(r)
			if d2 < nearest_d2:
				nearest_d2 = d2
			if d2 < 100.0:
				on_contour = true
		outputlog("  ridge=%s inside=%s on_contour=%s nearest_d²=%.1f" % [str(r), str(inside), str(on_contour), nearest_d2], 0)
		if inside:
			continue  # inside — Gable case, skip
		if not on_contour:
			apex = r
			break

	if apex == null:
		outputlog("EXTEND: no apex found, returning contour unchanged", 0)
		return contour
	outputlog("EXTEND: apex = %s" % str(apex), 0)

	# Simplify the contour by dropping colinear midpoints — those vertices
	# that are exactly between two "real" corners of the contour (like a
	# dormer's ridge[0] which sits in the middle of one edge). They're
	# structural markers but not part of the visible polygon shape, and
	# leaving them in causes the apex insertion to produce a zigzag instead
	# of a clean pentagon. Result: only the true corners remain.
	var n = contour.size()
	var simplified = PoolVector2Array()
	for i in range(n):
		var prev_v = contour[(i - 1 + n) % n]
		var v = contour[i]
		var next_v = contour[(i + 1) % n]
		var d1 = v - prev_v
		var d2 = next_v - v
		if d1.length_squared() < 0.01 or d2.length_squared() < 0.01:
			simplified.append(v)
			continue
		d1 = d1.normalized()
		d2 = d2.normalized()
		if d1.dot(d2) > 0.99:
			continue  # colinear midpoint — drop it
		simplified.append(v)

	if simplified.size() < 3:
		return contour  # too aggressive, fall back

	# Find the simplified-contour edge whose two endpoints are closest to
	# the apex — that's the edge the apex should split.
	var ns = simplified.size()
	var best_i = -1
	var best_score = INF
	for i in range(ns):
		var a = simplified[i]
		var b = simplified[(i + 1) % ns]
		var score = a.distance_to(apex) + b.distance_to(apex)
		if score < best_score:
			best_score = score
			best_i = i

	if best_i == -1:
		return contour

	var extended = PoolVector2Array()
	for i in range(ns):
		extended.append(simplified[i])
		if i == best_i:
			extended.append(apex)
	return extended

func _is_ccw(poly: PoolVector2Array) -> bool:
	# Shoelace. In Godot's Y-down screen space, signed area > 0 means CW visually,
	# < 0 means CCW visually. We use the visual convention: CCW means outward
	# normal of edge (p1->p2) is (dy, -dx).
	var n = poly.size()
	if n < 3:
		return true
	var sum = 0.0
	for i in range(n):
		var p1 = poly[i]
		var p2 = poly[(i + 1) % n]
		sum += (p2.x - p1.x) * (p2.y + p1.y)
	return sum < 0.0

# Builds the silhouette of (P) ∪ (P + offset) ∪ (skirt quads connecting them).
# Returns an array of PoolVector2Array sub-polygons. With non-zero offset and
# a simple convex roof, this is typically a single polygon.
func _build_silhouette(contour: PoolVector2Array, offset: Vector2, vertex_heights: Array = []) -> Array:
	if contour.size() < 3:
		return []

	# No offset → just the roof footprint
	if offset.length_squared() < 0.01:
		return [_clean_polygon(contour)]

	var n = contour.size()
	# vertex_heights[i] = the offset multiplier to use when projecting vertex i.
	# Default 1.0 means "project to v + offset" (eaves level). Vertices that
	# coincide with a ridge endpoint should use ridge_height so the silhouette's
	# pointed corners line up with the projected ridge — this is what fixes the
	# dormer's back-triangle gap.
	var has_heights = vertex_heights.size() == n
	var projected_pts = PoolVector2Array()
	for i in range(n):
		var h = 1.0
		if has_heights:
			h = float(vertex_heights[i])
		projected_pts.append(contour[i] + offset * h)

	# Start with the union of the two end caps (footprint + projected footprint).
	var current = Geometry.merge_polygons_2d(contour, projected_pts)
	if current == null or current.size() == 0:
		current = [contour]

	# Add skirt quads — but ONLY for edges whose outward normal points in
	# the offset direction (front-facing edges). Back-facing edges, when
	# extruded by the offset, produce "twisted" quads that fold back into the
	# polygon and corrupt the merge result with self-intersections.
	# Geometrically this is correct: back-facing edges are covered by the
	# overlap between P and P+offset and don't need an explicit skirt.
	var ccw = _is_ccw(contour)
	for i in range(n):
		var i_next = (i + 1) % n
		var a = contour[i]
		var b = contour[i_next]
		var edge = b - a
		if edge.length_squared() < 0.0001:
			continue
		edge = edge.normalized()
		var outward: Vector2
		if ccw:
			outward = Vector2(edge.y, -edge.x)
		else:
			outward = Vector2(-edge.y, edge.x)
		if outward.dot(offset) <= 0.0:
			continue  # back-facing — skip

		# Use per-vertex projection: this matters when one endpoint of the
		# edge is at ridge level (height = ridge_height) and the other is at
		# eaves level (height = 1) — without this the dormer's back-triangle
		# gets disconnected from the projected ridge tip.
		var ha = 1.0
		var hb = 1.0
		if has_heights:
			ha = float(vertex_heights[i])
			hb = float(vertex_heights[i_next])
		var quad = PoolVector2Array([a, b, b + offset * hb, a + offset * ha])
		var new_current = []
		for poly in current:
			var m = Geometry.merge_polygons_2d(poly, quad)
			if m == null or m.size() == 0:
				new_current.append(poly)
			else:
				for sub in m:
					new_current.append(sub)
		current = _consolidate(new_current)

	# Final cleanup: round-trip through Clipper to normalize any sliver
	# self-intersections introduced by the iterative quad merges.
	var cleaned = []
	for p in current:
		cleaned.append(_clean_polygon(p))
	return cleaned

# Strips zero-length edges (adjacent duplicate vertices). Optionally runs a
# Clipper round-trip to repair tiny self-intersections.
func _clean_polygon(p: PoolVector2Array) -> PoolVector2Array:
	if p.size() < 3:
		return p
	var dedup = PoolVector2Array()
	for v in p:
		if dedup.size() == 0 or dedup[dedup.size() - 1].distance_to(v) > 0.5:
			dedup.append(v)
	if dedup.size() >= 3 and dedup[0].distance_to(dedup[dedup.size() - 1]) < 0.5:
		dedup.remove(dedup.size() - 1)
	if dedup.size() < 3:
		return p
	# Clipper round-trip: tiny outward then inward offset cleans up self-
	# intersections without changing the visible shape.
	var grown = Geometry.offset_polygon_2d(dedup, 0.5, Geometry.JOIN_MITER)
	if grown != null and grown.size() == 1:
		var back = Geometry.offset_polygon_2d(grown[0], -0.5, Geometry.JOIN_MITER)
		if back != null and back.size() == 1 and back[0].size() >= 3:
			return back[0]
	return dedup

# Greedy pairwise merge — handles cases where successive quad merges produced
# polygons that should now be combined. Uses inflate / merge / deflate with a
# small tolerance to absorb polygons that touch only along a shared edge but
# fail strict merge_polygons_2d due to float precision (the pignon / sides /
# main silhouette case). Falls back to plain merge if the inflated version
# can't be deflated cleanly.
const _MERGE_TOLERANCE := 1.5

func _consolidate(polys: Array) -> Array:
	if polys.size() <= 1:
		return polys
	var result = []
	for p in polys:
		if p.size() < 3:
			continue
		var absorbed = false
		for j in range(result.size()):
			var m = _merge_with_tolerance(result[j], p)
			if m.size() == 1:
				result[j] = m[0]
				absorbed = true
				break
		if not absorbed:
			result.append(p)
	# Second pass: now that everything's been seen once, try to absorb any
	# remaining pairs that didn't merge on the first pass (order-dependent).
	var changed = true
	while changed and result.size() > 1:
		changed = false
		for i in range(result.size()):
			var found_pair = false
			for j in range(i + 1, result.size()):
				var m = _merge_with_tolerance(result[i], result[j])
				if m.size() == 1:
					result[i] = m[0]
					result.remove(j)
					changed = true
					found_pair = true
					break
			if found_pair:
				break
	return result

# Merge two polygons with an inflate / merge / deflate tolerance. Returns
# Array of polygons (size 1 = single merged shape, size >= 2 = disjoint).
func _merge_with_tolerance(a: PoolVector2Array, b: PoolVector2Array) -> Array:
	# First try the cheap exact merge
	var direct = Geometry.merge_polygons_2d(a, b)
	if direct.size() == 1:
		return direct
	# Inflate both, merge, deflate the union — covers near-touching polygons
	var ia = Geometry.offset_polygon_2d(a, _MERGE_TOLERANCE, Geometry.JOIN_MITER)
	var ib = Geometry.offset_polygon_2d(b, _MERGE_TOLERANCE, Geometry.JOIN_MITER)
	if ia.size() == 0 or ib.size() == 0:
		return direct
	var inflated_merge = Geometry.merge_polygons_2d(ia[0], ib[0])
	if inflated_merge.size() != 1:
		return direct  # genuinely disjoint
	var deflated = Geometry.offset_polygon_2d(inflated_merge[0], -_MERGE_TOLERANCE, Geometry.JOIN_MITER)
	if deflated.size() == 1 and deflated[0].size() >= 3:
		return [deflated[0]]
	# Deflate produced multiple parts or nothing — fall back to direct
	return direct

#########################################################################################################
##
## MESH BUILDING
##
#########################################################################################################

# Vertex normals averaged from adjacent edge normals. Miter-scaled so a
# softness-distance offset stays uniform around corners. Capped to avoid
# spike artifacts at acute angles.
func _vertex_normals(poly: PoolVector2Array, ccw: bool) -> Array:
	var n = poly.size()
	var edge_normals = []
	for i in range(n):
		var p1 = poly[i]
		var p2 = poly[(i + 1) % n]
		var dir = p2 - p1
		if dir.length_squared() < 0.0001:
			edge_normals.append(Vector2.ZERO)
			continue
		dir = dir.normalized()
		var norm
		if ccw:
			norm = Vector2(dir.y, -dir.x)
		else:
			norm = Vector2(-dir.y, dir.x)
		edge_normals.append(norm)

	var verts = []
	for i in range(n):
		var n_prev = edge_normals[(i - 1 + n) % n]
		var n_curr = edge_normals[i]
		var avg = n_prev + n_curr
		if avg.length_squared() < 0.0001:
			verts.append(Vector2.ZERO)
			continue
		avg = avg.normalized()
		var miter_dot = avg.dot(n_curr)
		var scale = 1.0
		if abs(miter_dot) > 0.001:
			scale = 1.0 / miter_dot
		scale = clamp(scale, 1.0, 4.0)
		verts.append(avg * scale)
	return verts

# Bevel sharp corners of a polygon by inflating then deflating with
# JOIN_ROUND. Straight edges stay straight; only corners get rounded.
# Returns the original polygon on failure or when radius is too small.
func _round_corners(poly: PoolVector2Array, radius: float) -> PoolVector2Array:
	if radius <= 0.5 or poly.size() < 3:
		return poly
	var inflated = Geometry.offset_polygon_2d(poly, radius, Geometry.JOIN_ROUND)
	if inflated.size() == 0:
		return poly
	# Pick the largest piece in case the polygon got split
	var biggest_in = inflated[0]
	for p in inflated:
		if p.size() > biggest_in.size():
			biggest_in = p
	if biggest_in.size() < 3:
		return poly
	var deflated = Geometry.offset_polygon_2d(biggest_in, -radius, Geometry.JOIN_ROUND)
	if deflated.size() == 0:
		return poly
	var biggest_out = deflated[0]
	for p in deflated:
		if p.size() > biggest_out.size():
			biggest_out = p
	if biggest_out.size() < 3:
		return poly
	return biggest_out

func _build_fade_mesh(poly: PoolVector2Array, softness: float, opacity: float, color: Color) -> MeshInstance2D:
	var n = poly.size()
	if n < 3:
		return null

	var inner_color = Color(color.r, color.g, color.b, opacity)
	var outer_color = Color(color.r, color.g, color.b, 0.0)

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var indices = PoolIntArray()

	# We use TWO independent insets:
	#   - rim_inner   : manual (always n vertices, 1:1 with the boundary so the
	#                   rim quads have clean alpha gradient)
	#   - fill_inner  : Clipper-based (may have a different vertex count, but
	#                   stays a clean simple polygon — triangulable).
	# The rim and fill don't need to share geometry; each is allowed to be
	# slightly different. The rim is what the user sees fading; the fill is
	# what keeps the interior opaque so we never get the "donut" hole.
	var rim_inner = _manual_inset(poly, softness) if softness >= 0.5 else PoolVector2Array()
	var fill_inner = _clipper_inset(poly, softness) if softness >= 0.5 else poly

	# === Outer ring (always n vertices, alpha 0) ===
	for i in range(n):
		verts.append(poly[i])
		colors.append(outer_color)

	# === Rim inner ring (alpha = opacity) ===
	# Only emitted when we have a usable manual inset; otherwise no fade.
	var rim_emitted = (rim_inner.size() == n)
	if rim_emitted:
		for i in range(n):
			verts.append(rim_inner[i])
			colors.append(inner_color)

		# Rim quads between outer (indices 0..n-1) and rim_inner (n..2n-1)
		var ccw = _is_ccw(poly)
		for i in range(n):
			var i_next = (i + 1) % n
			var outer_curr = i
			var outer_next = i_next
			var inner_curr = n + i
			var inner_next = n + i_next
			if ccw:
				indices.append(outer_curr)
				indices.append(outer_next)
				indices.append(inner_curr)
				indices.append(outer_next)
				indices.append(inner_next)
				indices.append(inner_curr)
			else:
				indices.append(outer_curr)
				indices.append(inner_curr)
				indices.append(outer_next)
				indices.append(outer_next)
				indices.append(inner_curr)
				indices.append(inner_next)

	# === Core fill (alpha = opacity) ===
	# Independent vertex set so we don't depend on the rim's geometry being
	# triangulable. Try fill_inner first; if it triangulates, great. Otherwise
	# fall back to the silhouette itself with full opacity (overlapping the
	# rim slightly, but visible & acceptable).
	var fill_pts = fill_inner if fill_inner.size() >= 3 else poly
	var fill_tri = Geometry.triangulate_polygon(fill_pts)
	if fill_tri == null or fill_tri.size() < 3:
		# Even fill_inner failed — try the silhouette polygon directly
		fill_pts = poly
		fill_tri = Geometry.triangulate_polygon(poly)

	if fill_tri != null and fill_tri.size() >= 3:
		var fill_base = verts.size()
		for v in fill_pts:
			verts.append(v)
			colors.append(inner_color)
		for idx in fill_tri:
			indices.append(fill_base + idx)

	if verts.size() == 0 or indices.size() == 0:
		return null

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	arrays[ArrayMesh.ARRAY_INDEX] = indices

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi = MeshInstance2D.new()
	mi.mesh = mesh
	return mi

# Manual per-vertex inward inset — always returns same vertex count as input.
# May self-intersect on tight concave corners with large softness, but that's
# OK because we only use it for the rim gradient, not the fill triangulation.
func _manual_inset(poly: PoolVector2Array, softness: float) -> PoolVector2Array:
	var n = poly.size()
	if n < 3 or softness < 0.5:
		return PoolVector2Array()
	var ccw = _is_ccw(poly)
	var v_normals = _vertex_normals(poly, ccw)
	var result = PoolVector2Array()
	for i in range(n):
		result.append(poly[i] - v_normals[i] * softness)
	return result

# Clipper-based inset — may return different vertex count or even no
# polygon for very small inputs, but the result (when present) is always
# a clean simple polygon, suitable for triangulation.
func _clipper_inset(poly: PoolVector2Array, softness: float) -> PoolVector2Array:
	if poly.size() < 3 or softness < 0.5:
		return PoolVector2Array()
	var insets = Geometry.offset_polygon_2d(poly, -softness, Geometry.JOIN_MITER)
	if insets != null and insets.size() >= 1 and insets[0].size() >= 3:
		return insets[0]
	return PoolVector2Array()

#########################################################################################################
##
## CREATE / REMOVE
##
#########################################################################################################

func create_shadow(roof, config: Dictionary):
	if roof == null or not is_instance_valid(roof):
		return
	if not is_roof(roof):
		return
	if not config.get("enabled", false):
		return

	# Dormers (type=2) are not supported — their geometry is too irregular
	# to project a clean shadow with the current approach. Bail out early.
	if roof.get("type") == 2:
		return

	remove_shadow(roof)

	var contour = _get_roof_contour(roof)
	if contour.size() < 3:
		outputlog("create_shadow: contour too small for roof %s" % roof.name, 0)
		return

	var offset_world = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	# Compensate for the roof's rotation/scale so the shadow points in a fixed
	# WORLD direction regardless of the roof's orientation. The shadow mesh is
	# parented to the roof and inherits its transform, so we feed it an offset
	# already expressed in the roof's local frame.
	var inv_basis = roof.global_transform.affine_inverse()
	var offset = inv_basis.basis_xform(offset_world)

	var softness = float(config.get("softness", 8.0))
	var opacity = float(config.get("opacity", 0.5))
	var color = config.get("shadow_color", Color(0, 0, 0, 1))
	if color is String:
		color = Color(color)

	var roof_type = roof.get("type")
	var ridge_height = float(config.get("ridge_height", 1.5))
	var dormer_data = null
	if roof_type == 2 and ridge_height > 1.001:
		# For dormers: compute apex/back ridge data. We don't extend the
		# contour or modify heights — all vertices project naturally. The
		# pignon-related polygons are added below as separate triangles
		# that get merged into the silhouette.
		dormer_data = _compute_dormer_apex_data(roof, contour)

	var silhouette = _build_silhouette(contour, offset)
	if silhouette.size() == 0:
		return

	# For dormers: add (a) the visible pignon's "kite" shadow extending
	# from the apex through v1/v2 to apex+offset, and (b) the back pignon
	# triangle toward ridge_back + offset×ridge_height (analogous to what
	# _build_projected_roof_faces does for Gables).
	if dormer_data != null and dormer_data.apex_pos != null and offset.length_squared() >= 1.0:
		var v1 = contour[dormer_data.v1_idx]
		var v2 = contour[dormer_data.v2_idx]
		var apex_proj = dormer_data.apex_pos + offset

		var to_merge = []
		for sp in silhouette:
			to_merge.append(sp)

		# Visible pignon shadow: 2 triangles forming a kite (apex, v1, apex+offset, v2)
		to_merge.append(PoolVector2Array([dormer_data.apex_pos, v1, apex_proj]))
		to_merge.append(PoolVector2Array([dormer_data.apex_pos, apex_proj, v2]))

		# Back pignon triangle (toward ridge_back projected at ridge_height)
		if dormer_data.ridge_back_pos != null:
			var back_proj = dormer_data.ridge_back_pos + offset * ridge_height
			to_merge.append(PoolVector2Array([v1 + offset, v2 + offset, back_proj]))

		var combined = _consolidate(to_merge)
		var cleaned = []
		for p in combined:
			cleaned.append(_clean_polygon(p))
		silhouette = cleaned

	# Augment with the 3D-projected roof faces (long-side quads + pignon
	# triangles toward each ridge endpoint at ridge_height). Only for Gables:
	# they have two real pignons (walls) that need volumetric shadow.
	if roof_type == 0:
		if ridge_height > 1.001 and offset.length_squared() >= 1.0:
			var to_merge = []
			for sp in silhouette:
				to_merge.append(sp)
			var faces = _build_projected_roof_faces(roof, offset, ridge_height)
			for face in faces:
				if face.size() >= 3:
					to_merge.append(face)
			var combined = _consolidate(to_merge)
			var cleaned = []
			for p in combined:
				cleaned.append(_clean_polygon(p))
			silhouette = cleaned

	var container = Node2D.new()
	container.name = "DropShadowRoof"

	for poly_pts in silhouette:
		if poly_pts.size() < 3:
			continue
		var mesh_inst = _build_fade_mesh(poly_pts, softness, opacity, color)
		if mesh_inst != null:
			container.add_child(mesh_inst)

	roof.add_child(container)
	# Place at index 0 so it draws beneath all the roof's other children
	# (edge, ridge, sides). Same trick as DropShadowWalls for in-tree ordering.
	roof.move_child(container, 0)
	roof.set_meta(SHADOW_META_KEY, [container])

	# Register for rotation monitoring (so we rebuild on rotate)
	_monitored_roofs[roof.get_instance_id()] = {
		"roof": weakref(roof),
		"last_rotation": roof.global_rotation,
		"config": config
	}

	# Persist config in our in-memory store + as a meta on the roof (mirror).
	# Storing both ways: the dict survives roof re-references, the meta survives
	# script reloads.
	_save_config_for_roof(roof, config)

	outputlog("Created roof shadow (%d sub-polys)" % silhouette.size(), 1)

func remove_shadow(roof):
	if roof == null or not is_instance_valid(roof):
		return
	_monitored_roofs.erase(roof.get_instance_id())
	if not roof.has_meta(SHADOW_META_KEY):
		return
	var nodes = roof.get_meta(SHADOW_META_KEY)
	if nodes is Array:
		for node in nodes:
			if is_instance_valid(node):
				node.get_parent().remove_child(node)
				node.free()
	roof.remove_meta(SHADOW_META_KEY)

#########################################################################################################
##
## CONFIG STORAGE / SELECTION
##
#########################################################################################################

func _save_config_for_roof(roof, config: Dictionary):
	if roof == null or not is_instance_valid(roof):
		return
	# Stored as a duplicate so later UI tweaks don't mutate previous configs
	# in unexpected ways (the same dict reference would otherwise leak).
	var cfg_copy = config.duplicate(true)
	_configs_by_id[roof.get_instance_id()] = cfg_copy
	roof.set_meta(META_CONFIG_KEY, cfg_copy)
	# Persist into ModMapData so the config survives map save/load. Walls /
	# Paths / Objects use the same pattern with their own SHADOW_DATA_KEY.
	_persist_config(roof, cfg_copy)

# Write the config to global.ModMapData under SHADOW_DATA_KEY[node_id].
# Color is converted to hex for JSON friendliness. No-op if the roof has no
# node_id meta (e.g. a transient roof during tool placement).
func _persist_config(roof, config: Dictionary):
	if roof == null or not is_instance_valid(roof):
		return
	if not roof.has_meta("node_id"):
		return
	if global == null:
		return
	var node_id = str(roof.get_meta("node_id"))
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		global.ModMapData[SHADOW_DATA_KEY] = {}
	var save_cfg = config.duplicate()
	if save_cfg.has("shadow_color") and save_cfg["shadow_color"] is Color:
		save_cfg["shadow_color"] = save_cfg["shadow_color"].to_html(true)
	global.ModMapData[SHADOW_DATA_KEY][node_id] = save_cfg

# Mirror of _persist_config: pull saved config back into a usable form.
# Returns null if no saved config exists for this roof.
func _load_persisted_config(roof):
	if roof == null or not is_instance_valid(roof):
		return null
	if not roof.has_meta("node_id"):
		return null
	if global == null or not global.ModMapData.has(SHADOW_DATA_KEY):
		return null
	var node_id = str(roof.get_meta("node_id"))
	var bucket = global.ModMapData[SHADOW_DATA_KEY]
	if not bucket.has(node_id):
		return null
	var cfg = bucket[node_id].duplicate()
	if cfg.has("shadow_color") and cfg["shadow_color"] is String:
		cfg["shadow_color"] = Color(cfg["shadow_color"])
	return cfg

# Globals (opacity, softness, last sun direction) are saved together so the
# atmosphere survives map reload. Sun direction is read from RoofTool when
# loading rather than re-stored, but opacity / softness are mod-only state.
func _persist_globals():
	if global == null:
		return
	global.ModMapData[GLOBAL_DATA_KEY] = {
		"opacity": _last_opacity,
		"softness": _last_softness,
		"default_offset_x": _default_offset_x,
		"default_offset_y": _default_offset_y,
		"default_ridge_height": _default_ridge_height,
		"default_enabled": _default_enabled,
	}

func _load_globals():
	if global == null or not global.ModMapData.has(GLOBAL_DATA_KEY):
		return
	var g = global.ModMapData[GLOBAL_DATA_KEY]
	if g.has("opacity"):
		_last_opacity = float(g["opacity"])
	if g.has("softness"):
		_last_softness = float(g["softness"])
	if g.has("default_offset_x"):
		_default_offset_x = float(g["default_offset_x"])
	if g.has("default_offset_y"):
		_default_offset_y = float(g["default_offset_y"])
	if g.has("default_ridge_height"):
		_default_ridge_height = float(g["default_ridge_height"])
	if g.has("default_enabled"):
		_default_enabled = bool(g["default_enabled"])

func _get_config_for_roof(roof) -> Dictionary:
	if roof == null or not is_instance_valid(roof):
		return DEFAULT_CONFIG.duplicate()
	var iid = roof.get_instance_id()
	if _configs_by_id.has(iid):
		return _configs_by_id[iid]
	if roof.has_meta(META_CONFIG_KEY):
		var cfg = roof.get_meta(META_CONFIG_KEY)
		if cfg is Dictionary:
			_configs_by_id[iid] = cfg
			return cfg
	# Fall back to persisted ModMapData (e.g. roof was loaded from disk)
	var persisted = _load_persisted_config(roof)
	if persisted != null:
		_configs_by_id[iid] = persisted
		roof.set_meta(META_CONFIG_KEY, persisted)
		return persisted
	return DEFAULT_CONFIG.duplicate()

func _get_selected_roof():
	# Only meaningful while the SelectTool is active
	if global.Editor.ActiveToolName != "SelectTool":
		return null
	var sel = global.Editor.Tools["SelectTool"].Selected
	if sel == null or sel.size() == 0:
		return null
	var first = sel[0]
	if not is_roof(first):
		return null
	return first

# Returns ALL selected roofs (used when applying settings to a multi-selection).
# Empty array if none / no SelectTool.
func _get_selected_roofs() -> Array:
	var out = []
	if global.Editor.ActiveToolName != "SelectTool":
		return out
	var sel = global.Editor.Tools["SelectTool"].Selected
	if sel == null or sel.size() == 0:
		return out
	for s in sel:
		if is_roof(s):
			out.append(s)
	return out

#########################################################################################################
##
## UI BUILDING
##
#########################################################################################################

func _build_select_tool_ui():
	if _ui_built:
		return
	var select_panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	if select_panel == null:
		outputlog("SelectTool panel not found, retrying", 0)
		# Defer one more time in case panel is still being built
		yield(global.Editor.get_tree(), "idle_frame")
		select_panel = global.Editor.Toolset.GetToolPanel("SelectTool")
		if select_panel == null:
			outputlog("SelectTool panel still missing, giving up on UI", 0)
			return

	# The SelectTool panel is a ScrollContainer; its real flow lives in a
	# child VBoxContainer named "Align" which holds the FILTER/LAYERS/DELETE
	# buttons + per-type sections (walls, paths, objects, …). DD does NOT
	# expose a roof-specific section, so we append our container at the end
	# of Align — that way it sits inside the normal scrollable flow instead
	# of being a stray child of the ScrollContainer.
	var align = core.get_align_vbox(select_panel)
	if align == null:
		outputlog("No Align VBox found, falling back to panel root", 0)
		align = select_panel
	else:
		outputlog("UI parent: SelectTool/%s" % align.name, 0)

	ui_config["_parent"] = align

	var container = VBoxContainer.new()
	container.name = "DropShadowRoofsContainer"
	container.visible = false
	ui_config["container"] = container
	align.add_child(container)

	container.add_child(HSeparator.new())

	# --- Title row : [Cloud] [Label] [Toggle] ---------------------------
	var title_hbox = HBoxContainer.new()
	var cloud = _create_cloud_icon()
	if cloud != null:
		title_hbox.add_child(cloud)
	var title_label = Label.new()
	title_label.text = "Soft Shadow (Beta)"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_label)
	var enable_check = CheckButton.new()
	enable_check.pressed = false
	enable_check.connect("toggled", self, "_on_enable_toggled")
	title_hbox.add_child(enable_check)
	ui_config["enable_check"] = enable_check
	container.add_child(title_hbox)

	# --- Settings panel (revealed when enabled) -------------------------
	var settings = VBoxContainer.new()
	settings.visible = false
	ui_config["settings"] = settings
	container.add_child(settings)

	# Dial in a centered wrapper so it doesn't expand horizontally
	var dial_wrapper = CenterContainer.new()
	var dial = _create_dial(DIAL_SIZE, MAX_DIAL_OFFSET)
	dial_wrapper.add_child(dial)
	settings.add_child(dial_wrapper)

	# Offset X / Y (spinbox-only — the dial covers the visual case)
	settings.add_child(_make_spin_row("Offset X", "offset_x",
		-MAX_DIAL_OFFSET, MAX_DIAL_OFFSET, 1.0, DEFAULT_CONFIG["offset_x"]))
	settings.add_child(_make_spin_row("Offset Y", "offset_y",
		-MAX_DIAL_OFFSET, MAX_DIAL_OFFSET, 1.0, DEFAULT_CONFIG["offset_y"]))
	# Softness / Opacity (slider + spin)
	settings.add_child(_make_slider_row("Softness", "softness",
		0.0, 100.0, 1.0, DEFAULT_CONFIG["softness"]))
	settings.add_child(_make_slider_row("Opacity", "opacity",
		0.0, 1.0, 0.05, DEFAULT_CONFIG["opacity"]))
	# Ridge Height — only meaningful for Gable / Dormer, but always visible.
	# 1.0 means the ridge pointer doesn't extend past the main silhouette
	# (so it's invisible). 1.5–2.0 gives a nice protruding tail.
	settings.add_child(_make_slider_row("Ridge Height", "ridge_height",
		1.0, 5.0, 0.1, DEFAULT_CONFIG["ridge_height"]))

	container.add_child(HSeparator.new())

	_ui_built = true
	outputlog("SelectTool UI built", 0)

func _make_slider_row(text: String, key: String, min_v: float, max_v: float, step: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = text
	label.rect_min_size.x = 70
	hbox.add_child(label)

	var slider = HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_slider_changed", [key])
	hbox.add_child(slider)
	ui_config[key + "_slider"] = slider

	var spin = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = default_val
	spin.connect("value_changed", self, "_on_spin_changed", [key])
	hbox.add_child(spin)
	ui_config[key + "_spin"] = spin

	var reset = _make_icon_button("icons/reset.png", "Reset " + text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_select_single_reset", [key])
	hbox.add_child(reset)

	return hbox

func _make_spin_row(text: String, key: String, min_v: float, max_v: float, step: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = text
	label.rect_min_size.x = 70
	hbox.add_child(label)

	var spin = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = default_val
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.connect("value_changed", self, "_on_spin_changed", [key])
	hbox.add_child(spin)
	ui_config[key + "_spin"] = spin

	var reset = _make_icon_button("icons/reset.png", "Reset " + text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_select_single_reset", [key])
	hbox.add_child(reset)

	return hbox

func _on_select_single_reset(key: String):
	var def_val = DEFAULT_CONFIG.get(key, 0.0)
	if ui_config.has(key + "_slider"):
		ui_config[key + "_slider"].value = def_val
	if ui_config.has(key + "_spin"):
		ui_config[key + "_spin"].value = def_val
	# value_changed will fire, which calls _on_slider_changed/_on_spin_changed
	# → _apply_ui_to_selection. So the change propagates properly.

#########################################################################################################
##
## DIAL
##
#########################################################################################################

func _create_dial(size: int, max_off: float) -> Control:
	var dial = Control.new()
	dial.name = "OffsetDial"
	dial.rect_min_size = Vector2(size, size)
	dial.rect_size = Vector2(size, size)

	# Background disc
	var bg = TextureRect.new()
	bg.texture = _make_circle_texture(size, Color(0.12, 0.12, 0.12, 1.0))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg)

	# Crosshair
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

	# Center dot
	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(size / 2.0 - 1.5, size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)

	# Draggable handle
	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.rect_position = Vector2(size / 2.0 - 5, size / 2.0 - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)

	dial.set_meta("size", size)
	dial.set_meta("max_off", max_off)
	dial.set_meta("dragging", false)
	dial.connect("gui_input", self, "_on_dial_input", [dial])

	ui_config["dial"] = dial
	ui_config["dial_handle"] = handle
	return dial

# DEBUG: small filled circle Sprite at a given position, used to visually
# inspect candidate "visible apex" positions for dormers.
func _make_debug_marker(pos: Vector2, color: Color, size: int = 12) -> Sprite:
	var s = Sprite.new()
	s.texture = _make_circle_texture(size, color)
	s.position = pos
	s.z_index = 100
	return s

func _color_name(c: Color) -> String:
	if c == Color(1,0,0,1): return "RED"
	if c == Color(1,0.5,0,1): return "ORANGE"
	if c == Color(1,1,0,1): return "YELLOW"
	if c == Color(0,1,0,1): return "GREEN"
	if c == Color(0,0.6,1,1): return "LIGHTBLUE"
	if c == Color(0.5,0,1,1): return "PURPLE"
	if c == Color(1,0,1,1): return "MAGENTA"
	if c == Color(0,1,1,1): return "CYAN"
	if c == Color(1,1,1,1): return "WHITE"
	if c == Color(0.4,0.2,0,1): return "BROWN"
	if c == Color(0.5,0.5,0.5,1): return "GREY"
	if c == Color(0,0.5,0,1): return "DARKGREEN"
	if c == Color(0.5,0,0,1): return "DARKRED"
	if c == Color(0,0,0.5,1): return "DARKBLUE"
	if c == Color(0.7,0.7,0,1): return "OLIVE"
	if c == Color(0.2,0,0.5,1): return "INDIGO"
	if c == Color(0,0.3,0.3,1): return "TEAL"
	return str(c)

func _make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = size / 2.0
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			var dx = x - center
			var dy = y - center
			if dx * dx + dy * dy <= radius * radius:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

# Cloud icon for the title row. Mirrors the helpers from DropShadowWalls so
# the visual identity matches across all soft-shadow modes.
func _create_cloud_icon() -> TextureRect:
	var tex = _load_icon("icons/cloud.png", 0.85)
	if tex == null:
		return null
	var rect = TextureRect.new()
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	rect.rect_min_size = Vector2(18, 18)
	return rect

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
	var button = Button.new()
	button.hint_tooltip = tooltip
	button.icon = _load_icon(icon_path, icon_scale)
	return button

func _on_dial_input(event, dial: Control):
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dial.set_meta("dragging", event.pressed)
			if event.pressed:
				_update_dial_from_mouse(event.position, dial)
	elif event is InputEventMouseMotion:
		if dial.get_meta("dragging"):
			_update_dial_from_mouse(event.position, dial)

func _update_dial_from_mouse(pos: Vector2, dial: Control):
	var size = dial.get_meta("size") as float
	var max_off = dial.get_meta("max_off") as float
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	var delta = pos - center
	var dist = delta.length()
	if dist > radius:
		delta = delta.normalized() * radius
		dist = radius
	var frac = dist / radius
	# Squared mapping gives finer control near center, like in walls/objects
	var nonlin = frac * frac
	var dir = delta.normalized() if dist > 0.5 else Vector2.ZERO
	# Convention: the handle represents the SUN, so dragging it in a direction
	# means the sun is in that direction — and the shadow falls the opposite
	# way. We negate so the actual shadow offset is opposite to handle motion.
	var ox = round(-dir.x * nonlin * max_off)
	var oy = round(-dir.y * nonlin * max_off)

	_suppress_ui_signals = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_suppress_ui_signals = false
	_update_dial_handle(ox, oy)
	_apply_ui_to_selection()

# Place the handle at the position that corresponds to the given offset
func _update_dial_handle(ox: float, oy: float):
	var dial = ui_config.get("dial")
	var handle = ui_config.get("dial_handle")
	if dial == null or handle == null:
		return
	var size = dial.get_meta("size") as float
	var max_off = dial.get_meta("max_off") as float
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0

	# Handle position = SUN position = opposite of shadow offset.
	var v = Vector2(-ox, -oy)
	var vlen = v.length()
	if vlen < 0.0001:
		handle.rect_position = center - Vector2(5, 5)
		return
	# Inverse of the squared mapping used in _update_dial_from_mouse
	var nonlin = clamp(vlen / max_off, 0.0, 1.0)
	var frac = sqrt(nonlin)
	var p = center + v.normalized() * frac * radius
	handle.rect_position = p - Vector2(5, 5)

#########################################################################################################
##
## EVENT HANDLERS
##
#########################################################################################################

func _on_enable_toggled(pressed: bool):
	if _suppress_ui_signals:
		return
	var settings = ui_config.get("settings")
	if settings != null:
		settings.visible = pressed
	_apply_ui_to_selection()

func _on_slider_changed(value: float, key: String):
	if _suppress_ui_signals:
		return
	# Mirror to the matching spinbox
	_suppress_ui_signals = true
	var spin = ui_config.get(key + "_spin")
	if spin != null:
		spin.value = value
	_suppress_ui_signals = false
	_apply_ui_to_selection()

func _on_spin_changed(value: float, key: String):
	if _suppress_ui_signals:
		return
	# Mirror to the matching slider (if any)
	_suppress_ui_signals = true
	var slider = ui_config.get(key + "_slider")
	if slider != null:
		slider.value = value
	_suppress_ui_signals = false

	# Offset spinboxes also drive the dial handle
	if key == "offset_x" or key == "offset_y":
		var ox = ui_config["offset_x_spin"].value
		var oy = ui_config["offset_y_spin"].value
		_update_dial_handle(ox, oy)

	_apply_ui_to_selection()

#########################################################################################################
##
## UNDO/REDO — TRANSACTIONS DE RÉGLAGES (roofs)
##
#########################################################################################################
# Les réglages roof se propagent globalement (opacité/softness/sun touchent TOUS
# les roofs). On snapshotte donc l'état complet : _configs_by_id (par-roof, inclut
# offsets/sun) + les globals. Couleur normalisée en html (Color non JSON-able).

func _roof_state_snapshot() -> Dictionary:
	var configs = {}
	for iid in _configs_by_id.keys():
		var c = _configs_by_id[iid].duplicate(true)
		if c.has("shadow_color") and c["shadow_color"] is Color:
			c["shadow_color"] = c["shadow_color"].to_html(true)
		configs[iid] = c
	var globals = {
		"opacity": _last_opacity,
		"softness": _last_softness,
		"default_offset_x": _default_offset_x,
		"default_offset_y": _default_offset_y,
		"default_ridge_height": _default_ridge_height,
		"default_enabled": _default_enabled,
	}
	return {"configs": configs, "globals": globals}

func _history_touch(label: String = "") -> void:
	if shadow_history == null:
		return
	if _history_suspend or _suppress_ui_signals:
		return
	if not _history_txn_active:
		_history_txn_before = _roof_state_snapshot()
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
	var after = _roof_state_snapshot()
	if JSON.print(before) != JSON.print(after) and shadow_history != null:
		shadow_history.record(self, "history_apply", before, after, _history_txn_label)

# Restaure un état roof complet {configs, globals} (undo ET redo).
func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true

	# Globals
	var g = payload.get("globals", {})
	if g.has("opacity"): _last_opacity = float(g["opacity"])
	if g.has("softness"): _last_softness = float(g["softness"])
	if g.has("default_offset_x"): _default_offset_x = float(g["default_offset_x"])
	if g.has("default_offset_y"): _default_offset_y = float(g["default_offset_y"])
	if g.has("default_ridge_height"): _default_ridge_height = float(g["default_ridge_height"])
	if g.has("default_enabled"): _default_enabled = bool(g["default_enabled"])
	_persist_globals()

	# Per-roof configs
	var configs = payload.get("configs", {})
	_configs_by_id = {}
	for iid in configs.keys():
		var cfg = configs[iid].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		_configs_by_id[iid] = cfg
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			continue
		roof.set_meta(META_CONFIG_KEY, cfg)
		_persist_config(roof, cfg)
		remove_shadow(roof)
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)

	# Rafraîchir les UIs (SelectTool + RoofTool)
	on_selection_changed()
	_mirror_to_rt_ui("opacity", _last_opacity)
	_mirror_to_rt_ui("softness", _last_softness)
	_history_suspend = false


func _apply_ui_to_selection():
	_history_touch("roof")
	var roofs = _get_selected_roofs()
	if roofs.size() == 0:
		return
	var ui_cfg = _get_config_from_ui()

	# Apply the full UI config to EVERY selected roof. Per-roof settings
	# (offset_x, offset_y, ridge_height) thus all get the new value; global
	# settings (opacity, softness, enabled) are written here too and the
	# propagation calls below handle the non-selected roofs.
	for roof in roofs:
		var cfg = ui_cfg.duplicate()
		_save_config_for_roof(roof, cfg)
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)
		else:
			remove_shadow(roof)

	# Use the first selected roof as the "primary" reference for global
	# propagation. The propagation functions are idempotent — they skip any
	# roof that is already at the target value — so the other selected roofs
	# (already updated by the loop above) won't be redundantly rebuilt.
	var primary = roofs[0]
	_push_direction_to_sun(ui_cfg.get("offset_x", 0.0), ui_cfg.get("offset_y", 0.0), primary)
	_last_opacity = ui_cfg.get("opacity", _last_opacity)
	_last_softness = ui_cfg.get("softness", _last_softness)
	_propagate_opacity_to_roofs(_last_opacity, primary)
	_propagate_softness_to_roofs(_last_softness, primary)
	_persist_globals()
	_propagate_enabled_to_roofs(ui_cfg.get("enabled", false), primary)

	# Mirror global state to the RoofTool UI
	_mirror_to_rt_ui("opacity", _last_opacity)
	_mirror_to_rt_ui("softness", _last_softness)
	# Sync RoofTool's dial direction to match the new sun direction
	var d = Vector2(ui_cfg.get("offset_x", 0.0), ui_cfg.get("offset_y", 0.0))
	if d.length_squared() > 0.25:
		_sync_rt_dial_direction(d.normalized())

func _get_config_from_ui() -> Dictionary:
	var c = DEFAULT_CONFIG.duplicate()
	c["enabled"] = ui_config["enable_check"].pressed
	c["offset_x"] = ui_config["offset_x_spin"].value
	c["offset_y"] = ui_config["offset_y_spin"].value
	c["softness"] = ui_config["softness_spin"].value
	c["opacity"] = ui_config["opacity_spin"].value
	c["ridge_height"] = ui_config["ridge_height_spin"].value
	return c

func _set_ui_from_config(config: Dictionary):
	_suppress_ui_signals = true
	ui_config["enable_check"].pressed = config.get("enabled", false)
	var settings = ui_config.get("settings")
	if settings != null:
		settings.visible = config.get("enabled", false)
	ui_config["offset_x_spin"].value = config.get("offset_x", 0.0)
	ui_config["offset_y_spin"].value = config.get("offset_y", 0.0)
	ui_config["softness_slider"].value = config.get("softness", 8.0)
	ui_config["softness_spin"].value = config.get("softness", 8.0)
	ui_config["opacity_slider"].value = config.get("opacity", 0.5)
	ui_config["opacity_spin"].value = config.get("opacity", 0.5)
	ui_config["ridge_height_slider"].value = config.get("ridge_height", 1.5)
	ui_config["ridge_height_spin"].value = config.get("ridge_height", 1.5)
	_suppress_ui_signals = false
	_update_dial_handle(config.get("offset_x", 0.0), config.get("offset_y", 0.0))

#########################################################################################################
##
## SUN DIRECTION (GLOBAL ANGLE)
##
#########################################################################################################
# Hooks `RoofTool.SunDirection` (a Range control). The angle is shared across
# all roofs while each roof keeps its own magnitude (distance). Convention
# tested first: shadow points in the SAME direction as SunDirection in
# degrees (atan2(y,x) → degrees). If the user reports it inverted, just add
# 180° in both directions.

func _get_sun_range():
	var roof_tool = global.Editor.Tools.get("RoofTool")
	if roof_tool == null:
		return null
	return roof_tool.get("SunDirection")

func _connect_sun_direction():
	var sun_range = _get_sun_range()
	if sun_range == null:
		outputlog("RoofTool.SunDirection missing, sun-link disabled", 0)
		return
	if not sun_range.has_signal("value_changed"):
		outputlog("SunDirection has no value_changed signal", 0)
		return
	if sun_range.is_connected("value_changed", self, "_on_sun_direction_changed"):
		return
	sun_range.connect("value_changed", self, "_on_sun_direction_changed")
	outputlog("Hooked RoofTool.SunDirection.value_changed", 0)

# Called when the user moves the SunDirection slider in the RoofTool panel.
# We re-orient all tracked roofs to match, preserving each roof's magnitude.
# Convention: shadow points OPPOSITE to the sun (sun in the north → shadow
# cast to the south), so we add 180° before converting to a direction vector.
func _on_sun_direction_changed(value: float):
	if _suppress_sun_signal:
		return
	_history_touch("roof")
	var dir = _angle_deg_to_dir(value + 180.0)
	_propagate_direction_to_roofs(dir, null)
	# Keep the default offset direction in sync too (preserving magnitude),
	# so new roofs cast their shadow in the current sun direction.
	var cur = Vector2(_default_offset_x, _default_offset_y)
	var mag = cur.length()
	if mag < 0.5:
		mag = 100.0
	_default_offset_x = round(dir.x * mag)
	_default_offset_y = round(dir.y * mag)
	_persist_globals()
	# If a roof is currently selected, refresh its UI to show the new offset.
	var sel = _get_selected_roof()
	if sel != null:
		_set_ui_from_config(_get_config_for_roof(sel))
	# Sync the RoofTool UI dial direction too
	_sync_rt_dial_direction(dir)

# Re-orients all tracked roofs' shadows to the given world direction, keeping
# their per-roof magnitude. Skips `except_roof` (typically the one the user
# is currently editing — already up to date).
func _propagate_direction_to_roofs(dir: Vector2, except_roof):
	var to_remove = []
	var except_iid = -1
	if except_roof != null and is_instance_valid(except_roof):
		except_iid = except_roof.get_instance_id()
	for iid in _configs_by_id.keys():
		if iid == except_iid:
			continue
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			to_remove.append(iid)
			continue
		var cfg = _configs_by_id[iid]
		var current = Vector2(cfg.get("offset_x", 0.0), cfg.get("offset_y", 0.0))
		var mag = current.length()
		if mag < 0.5:
			# Roof has no offset set — leave it alone (don't pick a magnitude
			# out of thin air).
			continue
		cfg["offset_x"] = round(dir.x * mag)
		cfg["offset_y"] = round(dir.y * mag)
		_save_config_for_roof(roof, cfg)
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)
	for iid in to_remove:
		_configs_by_id.erase(iid)

# Same idea for opacity: propagate the new opacity value to every tracked
# roof except the one currently being edited (already up to date). Roofs
# whose opacity is already at the target value are skipped to avoid
# pointless rebuilds.
func _propagate_opacity_to_roofs(opacity: float, except_roof):
	var to_remove = []
	var except_iid = -1
	if except_roof != null and is_instance_valid(except_roof):
		except_iid = except_roof.get_instance_id()
	for iid in _configs_by_id.keys():
		if iid == except_iid:
			continue
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			to_remove.append(iid)
			continue
		var cfg = _configs_by_id[iid]
		if abs(float(cfg.get("opacity", 0.5)) - opacity) < 0.005:
			continue
		cfg["opacity"] = opacity
		_save_config_for_roof(roof, cfg)
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)
	for iid in to_remove:
		_configs_by_id.erase(iid)

# Same idea for softness.
func _propagate_softness_to_roofs(softness: float, except_roof):
	var to_remove = []
	var except_iid = -1
	if except_roof != null and is_instance_valid(except_roof):
		except_iid = except_roof.get_instance_id()
	for iid in _configs_by_id.keys():
		if iid == except_iid:
			continue
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			to_remove.append(iid)
			continue
		var cfg = _configs_by_id[iid]
		if abs(float(cfg.get("softness", 12.0)) - softness) < 0.05:
			continue
		cfg["softness"] = softness
		_save_config_for_roof(roof, cfg)
		if cfg.get("enabled", false):
			create_shadow(roof, cfg)
	for iid in to_remove:
		_configs_by_id.erase(iid)

# Toggle enabled on every tracked roof. enabled=true creates shadows, false
# removes them. Skips the currently-edited roof (already up to date).
func _propagate_enabled_to_roofs(enabled: bool, except_roof):
	var to_remove = []
	var except_iid = -1
	if except_roof != null and is_instance_valid(except_roof):
		except_iid = except_roof.get_instance_id()
	for iid in _configs_by_id.keys():
		if iid == except_iid:
			continue
		var roof = instance_from_id(iid)
		if roof == null or not is_instance_valid(roof) or not is_roof(roof):
			to_remove.append(iid)
			continue
		var cfg = _configs_by_id[iid]
		if cfg.get("enabled", false) == enabled:
			continue
		cfg["enabled"] = enabled
		_save_config_for_roof(roof, cfg)
		if enabled:
			create_shadow(roof, cfg)
		else:
			remove_shadow(roof)
	for iid in to_remove:
		_configs_by_id.erase(iid)

# Push the current roof's offset direction back into the global SunDirection.
# Sun = shadow + 180° (opposite). Normalised to [-180, 180] because that's
# the SunDirection Range's domain — using [0, 360) clipped to the 0-180 half.
func _push_direction_to_sun(ox: float, oy: float, current_roof):
	var v = Vector2(ox, oy)
	if v.length_squared() < 0.5:
		return  # no usable direction
	# Shadow→sun is + 180° (opposite). Normalise to [-180, 180].
	var ang_deg = rad2deg(atan2(v.y, v.x)) + 180.0
	while ang_deg > 180.0:
		ang_deg -= 360.0
	while ang_deg < -180.0:
		ang_deg += 360.0
	var sun_range = _get_sun_range()
	if sun_range == null:
		return
	# Only update if it would actually change something — avoid signal spam
	# and unnecessary rebuilds when the user is just tweaking magnitude.
	var current_sun = float(sun_range.value)
	if abs(current_sun - ang_deg) < 0.5:
		return
	_suppress_sun_signal = true
	sun_range.value = ang_deg
	_suppress_sun_signal = false
	# Propagate the new direction to other roofs (current_roof is already done)
	_propagate_direction_to_roofs(v.normalized(), current_roof)

func _angle_deg_to_dir(angle_deg: float) -> Vector2:
	var ang_rad = deg2rad(angle_deg)
	return Vector2(cos(ang_rad), sin(ang_rad))

#########################################################################################################
##
## ROOF TOOL UI — duplicates the SelectTool UI in the RoofTool sidebar.
## Settings here:
##   - Toggle / Opacity / Softness / Sun direction = GLOBAL state, mirrored
##     between both UIs and propagated to all existing roofs.
##   - Offset X/Y / Ridge Height = DEFAULTS for newly created roofs only;
##     existing roofs keep their per-roof values. The dial's position
##     reflects (offset_x, offset_y) so it shows the user where new roofs
##     will project their shadow.
##
#########################################################################################################

func _build_roof_tool_ui():
	if _rt_ui_built:
		return
	var roof_panel = global.Editor.Toolset.GetToolPanel("RoofTool")
	if roof_panel == null:
		outputlog("RoofTool panel not found, retrying", 0)
		yield(global.Editor.get_tree(), "idle_frame")
		roof_panel = global.Editor.Toolset.GetToolPanel("RoofTool")
		if roof_panel == null:
			outputlog("RoofTool panel still missing, giving up on RT UI", 0)
			return

	var align = core.get_align_vbox(roof_panel)
	if align == null:
		outputlog("No Align VBox in RoofTool, falling back to panel root", 0)
		align = roof_panel
	else:
		outputlog("RT UI parent: RoofTool/%s" % align.name, 0)

	rt_ui_config["_parent"] = align

	var container = VBoxContainer.new()
	container.name = "DropShadowRoofsContainer"
	rt_ui_config["container"] = container
	align.add_child(container)

	container.add_child(HSeparator.new())

	# --- Title row : [Cloud] [Label] [Toggle] ---------------------------
	var title_hbox = HBoxContainer.new()
	var cloud = _create_cloud_icon()
	if cloud != null:
		title_hbox.add_child(cloud)
	var title_label = Label.new()
	title_label.text = "Soft Shadow (Beta)"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_label)
	var enable_check = CheckButton.new()
	enable_check.pressed = _default_enabled
	enable_check.connect("toggled", self, "_on_rt_enable_toggled")
	title_hbox.add_child(enable_check)
	rt_ui_config["enable_check"] = enable_check
	container.add_child(title_hbox)

	# --- Settings panel (revealed when enabled) -------------------------
	var settings = VBoxContainer.new()
	settings.visible = _default_enabled
	rt_ui_config["settings"] = settings
	container.add_child(settings)

	settings.add_child(_make_slider_row_rt("Softness", "softness",
		0.0, 100.0, 1.0, _last_softness))
	settings.add_child(_make_slider_row_rt("Opacity", "opacity",
		0.0, 1.0, 0.05, _last_opacity))

	container.add_child(HSeparator.new())

	_rt_ui_built = true
	outputlog("RoofTool UI built", 0)

	# Inject reset buttons next to DD's native sliders (Sun Direction, Shade
	# Contrast, Width, ...). Done deferred so the DD widgets are guaranteed
	# to be in the tree.
	call_deferred("_inject_native_resets")

# Adds a reset button next to each named DD-native widget on the RoofTool
# panel. The reset value is captured the first time the button is clicked
# (so it matches DD's current default at mod load time).
func _inject_native_resets():
	var roof_tool = global.Editor.Tools.get("RoofTool")
	if roof_tool == null:
		return
	var natives = [
		["SunDirection", "Reset sun direction"],
		["ShadeContrast", "Reset shade contrast"],
	]
	for entry in natives:
		var prop_name = entry[0]
		var tooltip = entry[1]
		var widget = roof_tool.get(prop_name)
		# Skip if missing OR not a Node (e.g. a plain float property)
		if widget == null or not (widget is Node):
			continue
		var parent = widget.get_parent()
		if parent == null:
			continue
		var tag = "_dsr_reset_" + prop_name
		if parent.has_meta(tag):
			continue
		var initial_value = 0.0
		if widget is Range:
			initial_value = widget.value
		var reset = _make_icon_button("icons/reset.png", tooltip, 0.5)
		reset.connect("pressed", self, "_on_native_reset", [prop_name, initial_value])
		parent.add_child(reset)
		parent.set_meta(tag, true)
		outputlog("Injected reset button next to RoofTool.%s" % prop_name, 0)

func _on_native_reset(prop_name: String, default_val: float):
	var roof_tool = global.Editor.Tools.get("RoofTool")
	if roof_tool == null:
		return
	var widget = roof_tool.get(prop_name)
	if widget == null or not (widget is Range):
		return
	widget.value = default_val

func _make_slider_row_rt(text: String, key: String, min_v: float, max_v: float, step: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = text
	label.rect_min_size.x = 70
	hbox.add_child(label)

	var slider = HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_rt_slider_changed", [key])
	hbox.add_child(slider)
	rt_ui_config[key + "_slider"] = slider

	var spin = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = default_val
	spin.connect("value_changed", self, "_on_rt_spin_changed", [key])
	hbox.add_child(spin)
	rt_ui_config[key + "_spin"] = spin

	var reset = _make_icon_button("icons/reset.png", "Reset " + text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_rt_single_reset", [key])
	hbox.add_child(reset)

	return hbox

func _make_spin_row_rt(text: String, key: String, min_v: float, max_v: float, step: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = text
	label.rect_min_size.x = 70
	hbox.add_child(label)

	var spin = SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = default_val
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.connect("value_changed", self, "_on_rt_spin_changed", [key])
	hbox.add_child(spin)
	rt_ui_config[key + "_spin"] = spin

	var reset = _make_icon_button("icons/reset.png", "Reset " + text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_rt_single_reset", [key])
	hbox.add_child(reset)

	return hbox

func _on_rt_single_reset(key: String):
	var def_val = DEFAULT_CONFIG.get(key, 0.0)
	if rt_ui_config.has(key + "_slider"):
		rt_ui_config[key + "_slider"].value = def_val
	if rt_ui_config.has(key + "_spin"):
		rt_ui_config[key + "_spin"].value = def_val

func _create_dial_rt(size: int, max_off: float) -> Control:
	var dial = Control.new()
	dial.name = "OffsetDialRT"
	dial.rect_min_size = Vector2(size, size)
	dial.rect_size = Vector2(size, size)

	var bg = TextureRect.new()
	bg.texture = _make_circle_texture(size, Color(0.12, 0.12, 0.12, 1.0))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg)

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

	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.rect_position = Vector2(size / 2.0 - 5, size / 2.0 - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)

	dial.set_meta("size", size)
	dial.set_meta("max_off", max_off)
	dial.set_meta("dragging", false)
	dial.connect("gui_input", self, "_on_rt_dial_input", [dial])

	rt_ui_config["dial"] = dial
	rt_ui_config["dial_handle"] = handle
	return dial

func _on_rt_dial_input(event, dial: Control):
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			dial.set_meta("dragging", event.pressed)
			if event.pressed:
				_update_rt_dial_from_mouse(event.position, dial)
	elif event is InputEventMouseMotion:
		if dial.get_meta("dragging"):
			_update_rt_dial_from_mouse(event.position, dial)

func _update_rt_dial_from_mouse(pos: Vector2, dial: Control):
	var size = dial.get_meta("size") as float
	var max_off = dial.get_meta("max_off") as float
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	var delta = pos - center
	var dist = delta.length()
	if dist > radius:
		delta = delta.normalized() * radius
		dist = radius
	var frac = dist / radius
	var nonlin = frac * frac
	var dir = delta.normalized() if dist > 0.5 else Vector2.ZERO
	var ox = round(-dir.x * nonlin * max_off)
	var oy = round(-dir.y * nonlin * max_off)

	_suppress_ui_signals = true
	rt_ui_config["offset_x_spin"].value = ox
	rt_ui_config["offset_y_spin"].value = oy
	_suppress_ui_signals = false
	_update_rt_dial_handle(ox, oy)
	_apply_rt_offset_change(ox, oy)

func _update_rt_dial_handle(ox: float, oy: float):
	var dial = rt_ui_config.get("dial")
	var handle = rt_ui_config.get("dial_handle")
	if dial == null or handle == null:
		return
	var size = dial.get_meta("size") as float
	var max_off = dial.get_meta("max_off") as float
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0

	var v = Vector2(-ox, -oy)
	var vlen = v.length()
	if vlen < 0.0001:
		handle.rect_position = center - Vector2(5, 5)
		return
	var nonlin = clamp(vlen / max_off, 0.0, 1.0)
	var frac = sqrt(nonlin)
	var p = center + v.normalized() * frac * radius
	handle.rect_position = p - Vector2(5, 5)

# Called when the RoofTool dial / offset spinboxes change. Updates the
# stored defaults, propagates the new direction to all existing roofs,
# pushes it to DD's SunDirection, and syncs the SelectTool dial.
func _apply_rt_offset_change(ox: float, oy: float):
	_history_touch("roof")
	_default_offset_x = ox
	_default_offset_y = oy
	_persist_globals()
	# Push direction to DD's SunDirection AND to all roofs
	_push_direction_to_sun(ox, oy, null)
	# Sync the SelectTool dial's direction (preserving its magnitude)
	_sync_select_dial_direction(Vector2(ox, oy).normalized() if Vector2(ox, oy).length() > 0.5 else Vector2.ZERO)

# Adjusts the SelectTool dial's offset so its direction matches the given
# direction while keeping its current magnitude. Useful for keeping both
# UIs visually in sync.
func _sync_select_dial_direction(new_dir: Vector2):
	if not _ui_built or new_dir.length_squared() < 0.0001:
		return
	var sx_spin = ui_config.get("offset_x_spin")
	var sy_spin = ui_config.get("offset_y_spin")
	if sx_spin == null or sy_spin == null:
		return
	var current = Vector2(sx_spin.value, sy_spin.value)
	var mag = current.length()
	if mag < 0.5:
		return
	var nx = round(new_dir.x * mag)
	var ny = round(new_dir.y * mag)
	_suppress_ui_signals = true
	sx_spin.value = nx
	sy_spin.value = ny
	_suppress_ui_signals = false
	_update_dial_handle(nx, ny)

# Conversely, sync the RoofTool dial direction from another source (e.g.
# DD's SunDirection slider).
func _sync_rt_dial_direction(new_dir: Vector2):
	if not _rt_ui_built or new_dir.length_squared() < 0.0001:
		return
	var rx_spin = rt_ui_config.get("offset_x_spin")
	var ry_spin = rt_ui_config.get("offset_y_spin")
	if rx_spin == null or ry_spin == null:
		return
	var current = Vector2(_default_offset_x, _default_offset_y)
	var mag = current.length()
	if mag < 0.5:
		return
	var nx = round(new_dir.x * mag)
	var ny = round(new_dir.y * mag)
	_default_offset_x = nx
	_default_offset_y = ny
	_suppress_ui_signals = true
	rx_spin.value = nx
	ry_spin.value = ny
	_suppress_ui_signals = false
	_update_rt_dial_handle(nx, ny)

func _on_rt_enable_toggled(pressed: bool):
	if _suppress_ui_signals:
		return
	_default_enabled = pressed
	var settings = rt_ui_config.get("settings")
	if settings != null:
		settings.visible = pressed
	_persist_globals()
	# Mirror the SelectTool toggle (visual only — its enabled state would be
	# overridden anyway by per-roof config when a roof is selected)
	if _ui_built:
		var sel_check = ui_config.get("enable_check")
		if sel_check != null and sel_check.pressed != pressed:
			_suppress_ui_signals = true
			sel_check.pressed = pressed
			var sel_settings = ui_config.get("settings")
			if sel_settings != null:
				sel_settings.visible = pressed
			_suppress_ui_signals = false
	# Propagate to ALL existing roofs (idempotent — skips roofs already at target)
	_propagate_enabled_to_roofs(pressed, null)

func _on_rt_slider_changed(value: float, key: String):
	if _suppress_ui_signals:
		return
	_suppress_ui_signals = true
	var spin = rt_ui_config.get(key + "_spin")
	if spin != null:
		spin.value = value
	_suppress_ui_signals = false
	_apply_rt_value_change(key, value)

func _on_rt_spin_changed(value: float, key: String):
	if _suppress_ui_signals:
		return
	_suppress_ui_signals = true
	var slider = rt_ui_config.get(key + "_slider")
	if slider != null:
		slider.value = value
	_suppress_ui_signals = false

	if key == "offset_x" or key == "offset_y":
		var ox = rt_ui_config["offset_x_spin"].value
		var oy = rt_ui_config["offset_y_spin"].value
		_update_rt_dial_handle(ox, oy)
		_apply_rt_offset_change(ox, oy)
	else:
		_apply_rt_value_change(key, value)

# Apply a non-offset value change from the RoofTool UI: updates either the
# default for new roofs (ridge_height) or the global state (opacity, softness)
# and syncs the SelectTool UI + propagates to all roofs as appropriate.
func _apply_rt_value_change(key: String, value: float):
	_history_touch("roof")
	match key:
		"opacity":
			_last_opacity = value
			_persist_globals()
			_propagate_opacity_to_roofs(value, null)
			_mirror_to_select_ui(key, value)
		"softness":
			_last_softness = value
			_persist_globals()
			_propagate_softness_to_roofs(value, null)
			_mirror_to_select_ui(key, value)
		"ridge_height":
			_default_ridge_height = value
			_persist_globals()
			# Ridge height is per-roof, so we DON'T propagate to existing
			# roofs. Just update the default for new ones.
			# Don't sync SelectTool either — that one is per-roof.

func _mirror_to_select_ui(key: String, value: float):
	if not _ui_built:
		return
	_suppress_ui_signals = true
	var slider = ui_config.get(key + "_slider")
	if slider != null:
		slider.value = value
	var spin = ui_config.get(key + "_spin")
	if spin != null:
		spin.value = value
	_suppress_ui_signals = false

func _mirror_to_rt_ui(key: String, value: float):
	if not _rt_ui_built:
		return
	_suppress_ui_signals = true
	var slider = rt_ui_config.get(key + "_slider")
	if slider != null:
		slider.value = value
	var spin = rt_ui_config.get(key + "_spin")
	if spin != null:
		spin.value = value
	_suppress_ui_signals = false
