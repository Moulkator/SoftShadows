#########################################################################################################
##
## DROP SHADOW FOR PATHS
##
#########################################################################################################
# Version 4.0.0 - WALLS ONLY
# class_name DropShadowWalls

var global
var reference_to_script = null
var core = null

# UI references
var ui_config = {}

# Constants
const SHADOW_META_KEY = "drop_shadow_nodes"
const SHADOW_DATA_KEY = "DropShadow"
const PORTAL_OVERRIDES_KEY = "DropShadowPortalOverrides"
const USER_DEFAULTS_KEY = "DropShadowUserDefaults"
const USER_DEFAULTS_WALL_KEY = "DropShadowUserDefaultsWall"

const FACTORY_DEFAULTS = {
	"enabled": false,
	"opacity": 0.6,
	"opacity_realistic": 1.2,
	"softness": 2.75,
	"direction": 2,
	"spread": 0.25,
	"offset_x": 0.0,
	"offset_y": 0.0,
	"radial_offset": 0.0,
	"crop_blur": false,
	"crop_ends": false,
	"side_balance": 0.0,
	"range": 1.0,
	"snap_angle": -1.0,
	"fade_in_enabled": false,
	"fade_out_enabled": false,
	"fade_in_strength": 5.0,
	"fade_out_strength": 5.0,
	"grow_enabled": false,
	"shrink_enabled": false,
	"grow_length": 0.5,
	"shrink_length": 0.5,
	"extend_enabled": false,
	"fade_extend": 0.0,
	"extend_which": 2,
	"swap_ends": false,
	"skip_portals": false,
	"below_all_walls": false,
	"render_mode": "simple",   # "simple" = mesh géométrique | "realistic" = silhouette texturée floutée
	"realistic_blur": 0.2,     # flou du mode realistic (0 = net) ; 0..1 -> 0..REALISTIC_BLUR_MAX_PX
	"shadow_color": Color(0, 0, 0, 1)
}

var DEFAULT_SHADOW_CONFIG = FACTORY_DEFAULTS.duplicate()

# Stashed extend settings per wall node_id, saved when skip_portals is toggled OFF
# on a closed loop so they can be restored when skip_portals is toggled back ON.
var _stashed_extend = {}  # { node_id: { extend_enabled, fade_in_enabled, fade_out_enabled, fade_extend, extend_which } }


enum ShadowDirection { OUTER = 0, INNER = 1, BOTH = 2 }

# --- Mode "Realistic" (walls) : silhouette texturée du mur, capturée en viewport,
# décalée, floutée (noyau polaire + mips), rendue dessous. Portage du pipeline paths.
const REALISTIC_BLUR_MAX_PX = 180.0    # plafond du rayon de flou (world px)
const REALISTIC_MIN_BLUR_PX = 0.5      # en deçà : copie nette (pas de bake polaire)
const REALISTIC_BLUR_FLOOR_PX = 6.0    # palier bas : tout flou > 0 vaut au moins ça
const REALISTIC_VP_MAX_DIM = 2048.0    # résolution max de la capture (downscale au-delà)
const REALISTIC_VP_DOWNSAMPLE = 1.0    # pleine résolution
const REALISTIC_BLUR_STEPS = 24        # nb d'angles du noyau polaire
const REALISTIC_BLUR_QUALITY = 8       # nb d'anneaux radiaux
const REALISTIC_FOLD_SAFETY = 1.5     # offset concave max = SAFETY * rayon de courbure (anti-repli)
const REALISTIC_OUTER_GAIN = 1.5      # le côté extérieur ressort plus que l'intérieur (bridé aux coins) -> léger retrait quand il est poussé
var _silhouette_bake_shader = null     # shader silhouette pour le ruban-mesh (radial)
var _realistic_gen = {}                # instance_id -> génération (annule les captures obsolètes)
var _wall_r_capturing = {}             # instance_id -> génération en cours de capture (le monitor saute ce nœud tant qu'une capture est en vol)
var _wall_loop_nat = {}                # instance_id -> {tex, origin, content, sig} : bitmap naturel de boucle caché (phase DD, indépendant du radial)
var _wall_r_live = {}                  # instance_id -> {sprite, vp_size, scale_f, base_pos, parent, line, line_xform} : MAJ en place des réglages
var _wall_r_session = {}               # instance_id -> {vp, container, sprite, scale_f, base_pos, tsize, parent, line, line_xform} : session live (viewport persistant)
var _wall_r_last_req = {}              # instance_id -> ms du dernier update live (déclenche le settle)
const WALL_R_LIVE_HEADROOM = 1.3       # marge sur la taille du viewport live (évite les resize)
const WALL_R_LIVE_SETTLE_MS = 180      # calme après édition -> bake statique mipmappé
var _wall_last_changed = ""            # dernier réglage modifié (pour décider MAJ live vs recapture)
const WALL_R_LIVE_PARAMS = ["offset_x", "offset_y", "opacity", "shadow_color", "realistic_blur", "range", "radial_offset", "side_balance", "direction"]
var _wall_r_settle = {}                # instance_id -> cfg en attente de recapture (silhouette changée)
var _wall_r_settle_time = {}           # instance_id -> ticks du dernier changement
const WALL_R_SETTLE_MS = 160           # calme après édition -> recapture (radial/side/géométrie)
var _realistic_vp_shader = null
var _wall_silhouette_shader = null

# Logging Functions
const ENABLE_LOGGING = true
var logging_level = 0

#########################################################################################################
##
## UTILITY FUNCTIONS
##
#########################################################################################################

func outputlog(msg, level=0):
	if ENABLE_LOGGING:
		if level <= logging_level:
			printraw("(%d) <DropShadow>: " % OS.get_ticks_msec())
			print(msg)
	else:
		pass

# Disable the eyedropper/screen pick button inside a ColorPickerButton's popup.
# This prevents a Godot engine crash when the scene tree is large (3+ mods loaded).
func _disable_screen_picker(picker_button) -> void:
	if picker_button == null or not is_instance_valid(picker_button):
		return
	var picker = picker_button.get_picker()
	if picker == null:
		return
	for child in picker.get_children():
		if child is ToolButton:
			child.visible = false
			child.disabled = true
			break
	_hide_screen_pick_recursive(picker)

func _hide_screen_pick_recursive(node) -> void:
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is ToolButton:
			child.visible = false
			child.disabled = true
		elif child.get_child_count() > 0:
			_hide_screen_pick_recursive(child)

func get_node_type(node):
	if node == null or not is_instance_valid(node):
		return null
	if node.get("WallID") != null:
		return null
	if node.get("FadeIn") != null:
		return "paths"
	if node.get("Joint") != null:
		return "walls"
	return null

func is_portal_node(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.get("WallID") != null

func get_wall_for_portal(portal_node):
	if portal_node == null or not is_instance_valid(portal_node):
		return null
	var wall_id = portal_node.get("WallID")
	if wall_id == null:
		return null
	if global.World.HasNodeID(wall_id):
		return global.World.GetNodeByID(wall_id)
	return null

func get_portal_id(portal_node) -> String:
	if portal_node == null or not is_instance_valid(portal_node):
		return ""
	if portal_node.has_meta("node_id"):
		return str(portal_node.get_meta("node_id"))
	return ""

func is_portal_skip_overridden(portal_id: String) -> bool:
	if portal_id == "":
		return false
	if not global.ModMapData.has(PORTAL_OVERRIDES_KEY):
		return false
	return global.ModMapData[PORTAL_OVERRIDES_KEY].has(portal_id)

func set_portal_skip_override(portal_id: String, override: bool):
	if portal_id == "":
		return
	if not global.ModMapData.has(PORTAL_OVERRIDES_KEY):
		global.ModMapData[PORTAL_OVERRIDES_KEY] = {}
	if override:
		global.ModMapData[PORTAL_OVERRIDES_KEY][portal_id] = true
	else:
		global.ModMapData[PORTAL_OVERRIDES_KEY].erase(portal_id)
		if global.ModMapData[PORTAL_OVERRIDES_KEY].size() == 0:
			global.ModMapData.erase(PORTAL_OVERRIDES_KEY)

func _should_skip_portal(portal_node, skip_portals_global: bool) -> bool:
	var should_skip = false
	if portal_node.get_child_count() > 0:
		var sp = portal_node.get_child(0)
		if sp is Sprite and sp.texture != null:
			if sp.texture.resource_path == "" or sp.texture.resource_path.ends_with("null.png"):
				should_skip = true
	if not should_skip:
		should_skip = skip_portals_global
	var p_id = get_portal_id(portal_node)
	if is_portal_skip_overridden(p_id):
		should_skip = not should_skip
	return should_skip

# Project a point onto a polyline and return the distance along it.
# Returns -1.0 if the point is not close to the line.
func _project_point_on_line(point: Vector2, pts: PoolVector2Array) -> float:
	var best_dist = INF
	var best_along = 0.0
	var cumulative = 0.0
	for i in range(pts.size() - 1):
		var a = pts[i]
		var b = pts[i + 1]
		var ab = b - a
		var seg_len = ab.length()
		if seg_len < 0.01:
			cumulative += seg_len
			continue
		var t = clamp((point - a).dot(ab) / (seg_len * seg_len), 0.0, 1.0)
		var proj = a + ab * t
		var d = point.distance_to(proj)
		if d < best_dist:
			best_dist = d
			best_along = cumulative + t * seg_len
		cumulative += seg_len
	return best_along

# Split a polyline at two distances along it, returning [before, between, after].
# 'before' = points from start to cut_start
# 'between' = points from cut_start to cut_end (the portal region)
# 'after' = points from cut_end to end
func _split_line_at(pts: PoolVector2Array, cut_start: float, cut_end: float) -> Array:
	var before = PoolVector2Array()
	var after = PoolVector2Array()
	var cumulative = 0.0

	# Walk through the polyline and distribute points
	for i in range(pts.size()):
		var pt = pts[i]
		var dist_here = cumulative

		if i > 0:
			dist_here = cumulative

		if dist_here <= cut_start + 0.5:
			before.append(pt)
		if dist_here >= cut_end - 0.5:
			after.append(pt)

		if i < pts.size() - 1:
			var seg_len = pts[i].distance_to(pts[i + 1])
			var next_cum = cumulative + seg_len

			# If cut_start falls within this segment, insert interpolated point
			if cumulative < cut_start and next_cum > cut_start:
				var t = (cut_start - cumulative) / seg_len
				var interp = lerp(pts[i], pts[i + 1], t)
				before.append(interp)

			# If cut_end falls within this segment, insert interpolated point
			if cumulative < cut_end and next_cum > cut_end:
				var t = (cut_end - cumulative) / seg_len
				var interp = lerp(pts[i], pts[i + 1], t)
				after.insert(0, interp)

			cumulative = next_cum

	return [before, after]

func _cmp_cuts(a, b) -> bool:
	return a["start"] < b["start"]

# Extract points from a polyline between two distances along it.
func _extract_line_region(pts: PoolVector2Array, from_dist: float, to_dist: float) -> PoolVector2Array:
	var result = PoolVector2Array()
	var cumulative = 0.0

	for i in range(pts.size()):
		var dist_here = cumulative

		# Add interpolated start point if region starts mid-segment
		if i < pts.size() - 1:
			var seg_len = pts[i].distance_to(pts[i + 1])
			var next_cum = cumulative + seg_len

			if cumulative < from_dist and next_cum > from_dist and from_dist > cumulative + 0.5:
				var t = (from_dist - cumulative) / seg_len
				result.append(lerp(pts[i], pts[i + 1], t))

		# Add point if within region
		if dist_here >= from_dist - 0.5 and dist_here <= to_dist + 0.5:
			result.append(pts[i])

		# Add interpolated end point and stop
		if i < pts.size() - 1:
			var seg_len2 = pts[i].distance_to(pts[i + 1])
			var next_cum2 = cumulative + seg_len2

			if cumulative < to_dist and next_cum2 > to_dist and to_dist < next_cum2 - 0.5:
				var t2 = (to_dist - cumulative) / seg_len2
				result.append(lerp(pts[i], pts[i + 1], t2))

			cumulative = next_cum2

	return result

func is_shadow_node_type(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var t = get_node_type(node)
	return t == "walls"

# For walls, the Line2D with points is a child of the wall node
# Walls have multiple Line2D children - use the widest one (visual texture)
# For paths, the node itself is the Line2D
func get_line2d(node):
	if node == null or not is_instance_valid(node):
		return null
	if get_node_type(node) == "walls":
		var best = null
		var best_width = 0.0
		for i in range(node.get_child_count()):
			var child = node.get_child(i)
			if child is Line2D and child.get_point_count() >= 2:
				if child.width > best_width:
					best_width = child.width
					best = child
		return best
	return node  # paths are Line2D themselves

func is_path_closed(path) -> bool:
	if path == null or not is_instance_valid(path):
		return false
	var line = get_line2d(path)
	if line == null or line.points.size() < 3:
		return false
	for prop_name in ["loop", "Loop", "closed", "Closed", "IsLoop"]:
		var val = path.get(prop_name)
		if val is bool and val:
			return true
		if line != path:
			val = line.get(prop_name)
			if val is bool and val:
				return true
	return false

func _wall_has_skipped_portals(wall, skip_portals_override = null) -> bool:
	if wall == null or not is_instance_valid(wall):
		return false
	var wall_id = str(wall.get_meta("node_id")) if wall.has_meta("node_id") else ""
	var skip_global = false
	if skip_portals_override != null:
		skip_global = skip_portals_override
	elif wall_id != "" and global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
		skip_global = global.ModMapData[SHADOW_DATA_KEY][wall_id].get("skip_portals", false)
	var found_any_portal = false
	for ci in range(wall.get_child_count()):
		var ch = wall.get_child(ci)
		if not (ch.name.begins_with("Portal") or ch.name.begins_with("@Portal")):
			continue
		found_any_portal = true
		if _should_skip_portal(ch, skip_global):
			return true
	# If skip_portals is ON but no portal children exist yet (cold start timing),
	# assume portals will be skipped once they load. Prevents wiping extend
	# on first load. Once portals actually load, hash changes → re-evaluated.
	if skip_global and not found_any_portal:
		return true
	return false

func set_property_but_block_signals(obj: Object, property: String, value):
	obj.set_block_signals(true)
	obj.set(property, value)
	obj.set_block_signals(false)

#########################################################################################################
##
## GEOMETRY UTILS
##
#########################################################################################################

# Calculate smooth normals for each point (averaged from adjacent segments)
# If is_closed, the first and last points are connected
func calculate_point_normals(points: PoolVector2Array, is_closed: bool = false) -> Array:
	var normals = []
	var count = points.size()
	if count < 2:
		return normals

	var miter_limit = 2.0

	for i in range(count):
		var normal = Vector2.ZERO
		var seg_prev = Vector2.ZERO
		var seg_next = Vector2.ZERO
		var len_prev = 0.0
		var len_next = 0.0
		var dir_prev = Vector2.ZERO
		var dir_next = Vector2.ZERO
		var n_prev = Vector2.ZERO
		var n_next = Vector2.ZERO
		var ratio = 0.0
		var dot = 0.0

		if is_closed:
			var prev_idx = (i - 1 + count) % count
			var next_idx = (i + 1) % count
			seg_prev = points[i] - points[prev_idx]
			seg_next = points[next_idx] - points[i]
			len_prev = seg_prev.length()
			len_next = seg_next.length()
			dir_prev = (seg_prev / len_prev) if len_prev > 0.01 else Vector2.ZERO
			dir_next = (seg_next / len_next) if len_next > 0.01 else Vector2.ZERO
			n_prev = Vector2(-dir_prev.y, dir_prev.x)
			n_next = Vector2(-dir_next.y, dir_next.x)

			# If one segment is much shorter, weight toward the longer one
			if len_prev > 0.01 and len_next > 0.01:
				ratio = min(len_prev, len_next) / max(len_prev, len_next)
				if ratio < 0.3:
					normal = n_prev if len_prev > len_next else n_next
				else:
					normal = ((n_prev + n_next) / 2.0).normalized()
					dot = n_prev.dot(normal)
					if dot > 0.01:
						normal = normal / dot
						if normal.length() > miter_limit:
							normal = normal.normalized() * miter_limit
					else:
						normal = n_prev
			elif len_prev > 0.01:
				normal = n_prev
			elif len_next > 0.01:
				normal = n_next
		else:
			if i == 0:
				dir_next = (points[1] - points[0]).normalized()
				normal = Vector2(-dir_next.y, dir_next.x)
			elif i == count - 1:
				dir_prev = (points[i] - points[i - 1]).normalized()
				normal = Vector2(-dir_prev.y, dir_prev.x)
			else:
				seg_prev = points[i] - points[i - 1]
				seg_next = points[i + 1] - points[i]
				len_prev = seg_prev.length()
				len_next = seg_next.length()
				dir_prev = (seg_prev / len_prev) if len_prev > 0.01 else Vector2.ZERO
				dir_next = (seg_next / len_next) if len_next > 0.01 else Vector2.ZERO
				n_prev = Vector2(-dir_prev.y, dir_prev.x)
				n_next = Vector2(-dir_next.y, dir_next.x)

				if len_prev > 0.01 and len_next > 0.01:
					ratio = min(len_prev, len_next) / max(len_prev, len_next)
					if ratio < 0.3:
						normal = n_prev if len_prev > len_next else n_next
					else:
						normal = ((n_prev + n_next) / 2.0).normalized()
						dot = n_prev.dot(normal)
						if dot > 0.01:
							normal = normal / dot
							if normal.length() > miter_limit:
								normal = normal.normalized() * miter_limit
						else:
							normal = n_prev
				elif len_prev > 0.01:
					normal = n_prev
				elif len_next > 0.01:
					normal = n_next

		normals.append(normal)

	return normals

func smoothstep_val(t: float) -> float:
	t = clamp(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _build_opacity_factors(num_points: int, original_count: int, fade_in: bool, fade_out: bool, fade_in_strength: float, fade_out_strength: float, start_ext_count: int):
	if not fade_in and not fade_out:
		return null
	var factors = []
	# Calculate fade range: extension points + fraction of original path
	var fade_in_pts = (int(original_count * fade_in_strength / 20.0) + start_ext_count) if fade_in else 0
	var end_ext_count = num_points - original_count - start_ext_count
	var fade_out_pts = (int(original_count * fade_out_strength / 20.0) + end_ext_count) if fade_out else 0
	# Clamp so fade_in + fade_out don't exceed total points
	if fade_in and fade_out and (fade_in_pts + fade_out_pts) > num_points:
		var total = float(fade_in_pts + fade_out_pts)
		fade_in_pts = int(fade_in_pts / total * num_points)
		fade_out_pts = int(fade_out_pts / total * num_points)
	if fade_in_pts < 2 and fade_in:
		fade_in_pts = 2
	if fade_out_pts < 2 and fade_out:
		fade_out_pts = 2
	for i in range(num_points):
		var factor = 1.0
		var t_fade = 0.0
		if fade_in and fade_in_pts > 0 and i < fade_in_pts:
			t_fade = float(i) / float(fade_in_pts)
			factor = min(factor, smoothstep_val(t_fade))
		if fade_out and fade_out_pts > 0:
			var from_end = num_points - 1 - i
			if from_end < fade_out_pts:
				t_fade = float(from_end) / float(fade_out_pts)
				factor = min(factor, smoothstep_val(t_fade))
		factors.append(factor)
	return factors

func _build_width_factors(num_points: int, original_count: int, grow: bool, shrink: bool, grow_val: float, shrink_val: float, start_ext_count: int):
	if not grow and not shrink:
		return null
	# Clamp grow+shrink so they don't exceed the path length
	if grow and shrink and grow_val + shrink_val > 1.0:
		var total = grow_val + shrink_val
		grow_val = grow_val / total
		shrink_val = shrink_val / total
	var factors = []
	var grow_pts = int(original_count * grow_val) if grow else 0
	var shrink_pts = int(original_count * shrink_val) if shrink else 0
	if grow_pts < 2 and grow:
		grow_pts = 2
	if shrink_pts < 2 and shrink:
		shrink_pts = 2
	for i in range(num_points):
		var factor = 1.0
		if grow and grow_pts > 0 and i < grow_pts:
			factor = min(factor, float(i) / float(grow_pts))
		if shrink and shrink_pts > 0:
			var from_end = num_points - 1 - i
			if from_end < shrink_pts:
				factor = min(factor, float(from_end) / float(shrink_pts))
		factor = smoothstep_val(factor)
		factors.append(factor)
	return factors

# Get or create a container node for "below all walls" shadows.
# Placed as a sibling of the Walls node in the Level, at the index just
# before Walls so it renders behind all walls but above lower layers.
# Must NOT be a child of Walls — that breaks DD's wall selection system.
const BELOW_ALL_CONTAINER_NAME = "DropShadowBelowAll"

func _get_below_all_container(wall_node: Node2D):
	# Derive the level from the wall's parent chain, NOT GetCurrentLevel().
	# This ensures below_all shadows go into the correct level when
	# apply_saved_shadows_to_map processes walls from multiple levels.
	var level = null
	var walker = wall_node.get_parent()
	while walker != null:
		if walker.name == "Walls":
			level = walker.get_parent()
			break
		walker = walker.get_parent()
	if level == null:
		return null
	var walls_node = level.get_node_or_null("Walls")
	if walls_node == null:
		return null
	var container = level.get_node_or_null(BELOW_ALL_CONTAINER_NAME)
	if container != null:
		container.z_as_relative = true
		container.z_index = walls_node.z_index - 1
		var walls_idx = walls_node.get_index()
		if container.get_index() >= walls_idx:
			level.move_child(container, walls_idx)
		return container
	container = Node2D.new()
	container.name = BELOW_ALL_CONTAINER_NAME
	container.z_as_relative = true
	container.z_index = walls_node.z_index - 1
	level.add_child(container)
	level.move_child(container, walls_node.get_index())
	return container

func _cleanup_below_all_orphans():
	# Remove below_all meshes that are no longer referenced by any wall's SHADOW_META_KEY.
	var level = global.World.GetCurrentLevel()
	if level == null:
		return
	var ba = level.get_node_or_null(BELOW_ALL_CONTAINER_NAME)
	if ba == null or ba.get_child_count() == 0:
		return
	# Collect instance IDs of all meshes still referenced by a wall
	var referenced = {}
	if global.ModMapData.has(SHADOW_DATA_KEY):
		for nid in global.ModMapData[SHADOW_DATA_KEY].keys():
			if not global.World.HasNodeID(nid):
				continue
			var wall = global.World.GetNodeByID(nid)
			if wall == null or not is_instance_valid(wall):
				continue
			if wall.has_meta(SHADOW_META_KEY):
				var snodes = wall.get_meta(SHADOW_META_KEY)
				if snodes is Array:
					for sn in snodes:
						if is_instance_valid(sn):
							referenced[sn.get_instance_id()] = true
	# Remove any mesh not referenced
	for ci in range(ba.get_child_count() - 1, -1, -1):
		var child = ba.get_child(ci)
		if not referenced.has(child.get_instance_id()):
			ba.remove_child(child)
			child.queue_free()



#########################################################################################################
##
## MESH GENERATION
##
#########################################################################################################

# Build shadow mesh for one side
# start_offset: distance from path center where shadow starts (at texture visible edge)
# spread: solid shadow distance from start
# softness: gradient fade distance after spread
# point_opacity_factors: per-point opacity multiplier (for fade in/out), null = all 1.0
# point_width_factors: per-point width multiplier (for grow/shrink), null = all 1.0
func build_shadow_mesh_side(points: PoolVector2Array, normals: Array,
	start_offset: float, spread: float, softness: float, opacity: float,
	sign_dir: float, num_strips: int, is_closed: bool = false,
	point_opacity_factors = null, point_width_factors = null,
	base_color: Color = Color(0, 0, 0, 1), corner_factors = null,
	radial_offset: float = 0.0) -> ArrayMesh:

	var mesh = ArrayMesh.new()
	var num_points = points.size()
	if num_points < 2:
		return mesh

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var indices = PoolIntArray()

	var strip_count = num_strips + 1
	var total_dist = spread + softness

	for i in range(num_points):
		# Radial offset shifts the base point along the path's outward normal.
		# +radial_offset = away from path interior; -radial_offset = toward interior.
		var p = points[i] + normals[i] * radial_offset
		var n = normals[i] * sign_dir

		var opacity_factor = 1.0
		if point_opacity_factors != null and i < point_opacity_factors.size():
			opacity_factor = point_opacity_factors[i]

		var width_factor = 1.0
		if point_width_factors != null and i < point_width_factors.size():
			width_factor = point_width_factors[i]

		# Corner factor: clamps normal length at concave corners to reduce overlap
		var corner_f = 1.0
		if corner_factors != null and i < corner_factors.size():
			corner_f = corner_factors[i]

		var local_total_dist = total_dist * width_factor
		var local_spread = spread * width_factor
		var local_softness = softness * width_factor
		var local_opacity = opacity * opacity_factor

		# At concave corners, shrink the normal to reduce triangle overlap
		var effective_n = n * corner_f

		for s in range(strip_count):
			var t = (float(s) / float(strip_count - 1)) if strip_count > 1 else 0.0
			# Start at the visible texture edge, extend outward
			var dist = start_offset + t * local_total_dist
			var vert = p + effective_n * dist
			verts.append(vert)

			# Alpha: full opacity in spread zone, then fade
			var edge_dist = t * local_total_dist
			var alpha = 0.0
			if edge_dist <= local_spread:
				alpha = local_opacity
			elif local_softness > 0.01:
				var fade_t = (edge_dist - local_spread) / local_softness
				alpha = local_opacity * (1.0 - smoothstep_val(fade_t))
			colors.append(Color(base_color.r, base_color.g, base_color.b, alpha))

	# Build triangle indices between consecutive points
	var segment_count = num_points - 1
	if is_closed:
		segment_count = num_points  # include closing segment

	for i in range(segment_count):
		var curr_idx = i
		var next_idx = (i + 1) % num_points

		var base_curr = curr_idx * strip_count
		var base_next = next_idx * strip_count

		for s in range(strip_count - 1):
			var a = base_curr + s
			var b = base_curr + s + 1
			var c = base_next + s
			var d = base_next + s + 1

			indices.append(a)
			indices.append(c)
			indices.append(b)

			indices.append(b)
			indices.append(c)
			indices.append(d)

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	arrays[ArrayMesh.ARRAY_INDEX] = indices

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func build_shadow_mesh_both(points: PoolVector2Array, normals: Array,
	spread: float, softness: float, opacity: float,
	num_strips_per_side: int, is_closed: bool = false,
	point_opacity_factors = null, point_width_factors = null,
	base_color: Color = Color(0, 0, 0, 1), radial_offset: float = 0.0) -> ArrayMesh:

	var mesh = ArrayMesh.new()
	var num_points = points.size()
	if num_points < 2:
		return mesh
	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var indices = PoolIntArray()
	var total_strips = num_strips_per_side * 2 + 1
	var total_dist = spread + softness

	for i in range(num_points):
		# Radial offset shifts the base point along the path's outward normal.
		var p = points[i] + normals[i] * radial_offset
		var n_outer = normals[i]
		var n_inner = -normals[i]
		var opacity_factor = 1.0
		if point_opacity_factors != null and i < point_opacity_factors.size():
			opacity_factor = point_opacity_factors[i]
		var width_factor = 1.0
		if point_width_factors != null and i < point_width_factors.size():
			width_factor = point_width_factors[i]
		var local_total_dist = total_dist * width_factor
		var local_spread = spread * width_factor
		var local_softness = softness * width_factor
		var local_opacity = opacity * opacity_factor

		for s in range(total_strips):
			var vert: Vector2
			var alpha: float
			if s < num_strips_per_side:
				var t = 1.0 - float(s) / float(num_strips_per_side)
				var dist = t * local_total_dist
				vert = p + n_inner * dist
				var edge_dist = t * local_total_dist
				if edge_dist <= local_spread:
					alpha = local_opacity
				elif local_softness > 0.01:
					var fade_t = (edge_dist - local_spread) / local_softness
					alpha = local_opacity * (1.0 - smoothstep_val(fade_t))
				else:
					alpha = 0.0
			elif s == num_strips_per_side:
				vert = p
				alpha = local_opacity
			else:
				var outer_idx = s - num_strips_per_side - 1
				var t = float(outer_idx + 1) / float(num_strips_per_side)
				var dist = t * local_total_dist
				vert = p + n_outer * dist
				var edge_dist = t * local_total_dist
				if edge_dist <= local_spread:
					alpha = local_opacity
				elif local_softness > 0.01:
					var fade_t = (edge_dist - local_spread) / local_softness
					alpha = local_opacity * (1.0 - smoothstep_val(fade_t))
				else:
					alpha = 0.0
			verts.append(vert)
			colors.append(Color(base_color.r, base_color.g, base_color.b, alpha))

	var segment_count = num_points - 1
	if is_closed:
		segment_count = num_points
	for i in range(segment_count):
		var curr_idx = i
		var next_idx = (i + 1) % num_points
		var base_curr = curr_idx * total_strips
		var base_next = next_idx * total_strips
		for s in range(total_strips - 1):
			var a = base_curr + s
			var b = base_curr + s + 1
			var c = base_next + s
			var d = base_next + s + 1
			indices.append(a)
			indices.append(c)
			indices.append(b)
			indices.append(b)
			indices.append(c)
			indices.append(d)

	var arr = []
	arr.resize(ArrayMesh.ARRAY_MAX)
	arr[ArrayMesh.ARRAY_VERTEX] = verts
	arr[ArrayMesh.ARRAY_COLOR] = colors
	arr[ArrayMesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

# Build a rounded line-cap mesh as a half-ellipse (or quarter-ellipse for
# Outer/Inner) centered at `center`. The semi-axis along `normal` is fixed at
# `spread + softness` so the cap always lines up with the strip cross-section
# at the wall endpoint. The semi-axis along `outward` is scaled by
# `outward_scale`:
#    outward_scale = 1.0  -> perfect half-circle (default)
#    outward_scale < 1.0  -> compressed (cap is squashed toward the strip)
#    outward_scale > 1.0  -> elongated (cap extends further past the endpoint)
#    outward_scale = 0.0  -> degenerate (no cap)
#
# Each "ray" of the cap reproduces the cross-section of the strip: full
# opacity inside `spread`, smoothstep fade through `softness`. Alpha is
# driven by the radial parameter `t` (not Euclidean distance) so contours
# of equal opacity follow ellipse contours and the strip / cap junction
# stays seamless regardless of `outward_scale`.
#
# half_only_sign:
#    0  -> full half-disc/ellipse (BOTH direction)
#   +1  -> quarter on +normal side only (OUTER direction)
#   -1  -> quarter on -normal side only (INNER direction)
#
# `outward` and `normal` must be unit vectors and perpendicular to each other.
# For the start of a wall, pass -tangent_in; for the end, pass +tangent_out.
func _build_cap_mesh(center: Vector2, outward: Vector2, normal: Vector2,
	spread: float, softness: float, opacity: float,
	base_color: Color, angular_steps: int, radial_strips: int,
	half_only_sign: float, outward_scale: float = 1.0) -> ArrayMesh:

	var mesh = ArrayMesh.new()
	var total_dist = spread + softness
	if total_dist <= 0.01 or angular_steps < 2 or radial_strips < 1:
		return mesh
	if outward_scale <= 0.001:
		return mesh

	var phi_start: float
	var phi_end: float
	if half_only_sign > 0.5:
		phi_start = 0.0
		phi_end = PI * 0.5
	elif half_only_sign < -0.5:
		phi_start = -PI * 0.5
		phi_end = 0.0
	else:
		phi_start = -PI * 0.5
		phi_end = PI * 0.5

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var indices = PoolIntArray()

	var radial_count = radial_strips + 1

	for a in range(angular_steps + 1):
		var phi = phi_start + (phi_end - phi_start) * (float(a) / float(angular_steps))
		var dir_phi = outward * (cos(phi) * outward_scale) + normal * sin(phi)
		for r in range(radial_count):
			var t = float(r) / float(radial_count - 1)
			var rad = t * total_dist
			verts.append(center + dir_phi * rad)

			var alpha = 0.0
			if rad <= spread:
				alpha = opacity
			elif softness > 0.01:
				var fade_t = (rad - spread) / softness
				alpha = opacity * (1.0 - smoothstep_val(fade_t))
			colors.append(Color(base_color.r, base_color.g, base_color.b, alpha))

	for a in range(angular_steps):
		var base_a = a * radial_count
		var base_b = (a + 1) * radial_count
		for r in range(radial_count - 1):
			var i00 = base_a + r
			var i01 = base_a + r + 1
			var i10 = base_b + r
			var i11 = base_b + r + 1
			indices.append(i00)
			indices.append(i10)
			indices.append(i01)
			indices.append(i01)
			indices.append(i10)
			indices.append(i11)

	if verts.size() == 0 or indices.size() == 0:
		return mesh

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	arrays[ArrayMesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Helper: add a cap mesh at a wall segment endpoint. Handles direction
# (BOTH/OUTER/INNER → full half-disc / quarter-disc), Shape slider mapping
# (-1..+1 → outward_scale 0..2), and integration into _add_shadow_mesh.
func _add_cap_for_endpoint(seg_pts: PoolVector2Array, at_start: bool,
	direction: int, spread_px: float, softness_px: float, opacity: float,
	num_strips: int, shape_v: float, shadow_color: Color,
	shadow_parent: Node2D, offset: Vector2, below_all: bool,
	line_global_xform: Transform2D, wall_nid: String, mesh_name: String,
	shadow_nodes: Array, radial_offset: float = 0.0):

	if seg_pts.size() < 2:
		return
	var cap_half_sign = 0.0  # BOTH = full half-disc
	if direction == ShadowDirection.OUTER:
		cap_half_sign = 1.0
	elif direction == ShadowDirection.INNER:
		cap_half_sign = -1.0

	var cap_outward_scale = 1.0 + clamp(shape_v, -1.0, 1.0)  # 0..2

	var center: Vector2
	var outward: Vector2
	var tangent: Vector2  # forward direction of the segment at the endpoint
	if at_start:
		center = seg_pts[0]
		tangent = (seg_pts[1] - seg_pts[0]).normalized()
		outward = -tangent
	else:
		var last_idx = seg_pts.size() - 1
		center = seg_pts[last_idx]
		tangent = (seg_pts[last_idx] - seg_pts[last_idx - 1]).normalized()
		outward = tangent
	# Use the SAME normal convention as `calculate_point_normals` / the
	# strip mesh — perpendicular CCW of the forward tangent. This is what
	# `+normal` means for the strip, so cap_half_sign +1 (OUTER) covers the
	# same side as the OUTER strip, and -1 (INNER) covers the INNER side.
	# Computing normal from `outward` instead would flip the side at the
	# start of a segment (where outward = -tangent).
	var normal = Vector2(-tangent.y, tangent.x)

	# Match the radial shift applied in build_shadow_mesh_side so the cap
	# stays seamlessly aligned with the strip endpoint.
	center += normal * radial_offset

	var cap_mesh = _build_cap_mesh(center, outward, normal,
		spread_px, softness_px, opacity, shadow_color,
		18, num_strips, cap_half_sign, cap_outward_scale)
	if cap_mesh.get_surface_count() == 0:
		return
	var cap_inst = MeshInstance2D.new()
	cap_inst.mesh = cap_mesh
	cap_inst.name = mesh_name
	_add_shadow_mesh(cap_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
	shadow_nodes.append(cap_inst)

#########################################################################################################
##
## INITIALISE
##
#########################################################################################################

func initialise() -> void:
	outputlog("Drop Shadow Walls initialising...")

	build_select_tool_ui()
	_build_wall_tool_ui()
	_build_building_tool_ui()
	call_deferred("_build_portal_tool_ui")
	_register_wall_tool_signals()

	# Connect to node creation signal for split detection
	global.World.connect("OnAssignNode", self, "on_new_node_added_to_world")

	# Set up monitoring timer for path changes
	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.01
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)

	# Timer de debounce pour l'historique undo/redo (un geste = une entrée).
	_history_flush_timer = Timer.new()
	_history_flush_timer.wait_time = 0.4
	_history_flush_timer.one_shot = true
	_history_flush_timer.connect("timeout", self, "_history_flush")
	global.Editor.add_child(_history_flush_timer)
	if shadow_history != null and shadow_history.has_method("register_flusher"):
		shadow_history.register_flusher(self, "_history_flush")
	if shadow_history != null and shadow_history.has_method("register_resync"):
		shadow_history.register_resync(self, "_history_force_resync")

	outputlog("Drop Shadow Walls initialised. (ba-cleanup-v3)", 0)
	outputlog("[BUILD: WALLS-APPLYALL-NOLAYERS-2]", 0)

#########################################################################################################
##
## WALL TOOL SIGNALS & SPLIT DETECTION
##
#########################################################################################################

func _register_wall_tool_signals():
	var tool_name = "WallTool"
	# OnStartEditWall, OnUpdateEditWall, OnEndEditWall, OnEndWall pass (node)
	for signal_name in ["OnEndWall", "OnStartEditWall", "OnUpdateEditWall", "OnEndEditWall"]:
		global.Editor.Tools[tool_name].connect(signal_name, self, "_on_wall_tool_signal", [signal_name])
	# OnStartWall passes no node arg
	global.Editor.Tools[tool_name].connect("OnStartWall", self, "_on_wall_tool_signal_no_node", ["OnStartWall"])

func _on_wall_tool_signal_no_node(signal_name: String):
	pass

func _on_wall_tool_signal(node, signal_name: String):
	match signal_name:
		"OnEndWall":
			# Wall drawing completed — apply shadow if wall tool toggle is ON
			if (_wall_tool_toggle != null and _wall_tool_toggle.pressed) or (_building_tool_toggle != null and _building_tool_toggle.pressed):
				if node != null and is_instance_valid(node) and is_shadow_node_type(node):
					# Delay slightly to let DD finish building the wall node
					call_deferred("_apply_wall_tool_shadow", node)
		"OnUpdateEditWall", "OnEndEditWall":
			# Refresh shadow on wall point edits
			if node != null and is_instance_valid(node) and is_shadow_node_type(node):
				_refresh_wall_shadow(node)

func _apply_wall_tool_shadow(wall):
	if wall == null or not is_instance_valid(wall):
		return
	if not wall.has_meta("node_id"):
		# Wall might not be ready yet, retry after a short delay
		yield(global.Editor.get_tree().create_timer(0.1), "timeout")
		if wall == null or not is_instance_valid(wall):
			return
		if not wall.has_meta("node_id"):
			return
	var node_id = str(wall.get_meta("node_id"))
	# Don't overwrite if wall already has shadow data
	if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
		return
	var cfg = _get_wall_tool_config()
	# Closed walls (loops) can't have extend - force it off
	if is_path_closed(wall):
		cfg["extend_enabled"] = false
		cfg["fade_in_enabled"] = false
		cfg["fade_out_enabled"] = false
	remove_shadow(wall)
	create_shadow(wall, cfg)
	save_shadow_data(wall, cfg)
	_all_known_path_ids[node_id] = true
	_all_points_hashes[node_id] = _get_points_hash(wall)
	outputlog("Applied wall tool shadow to wall " + node_id, 1)

func _refresh_wall_shadow(wall):
	if not wall.has_meta("node_id"):
		return
	var node_id = str(wall.get_meta("node_id"))
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return
	if not global.ModMapData[SHADOW_DATA_KEY].has(node_id):
		return
	var config = global.ModMapData[SHADOW_DATA_KEY][node_id]
	if config.get("enabled", false):
		remove_shadow(wall)
		create_shadow(wall, config)
		_all_points_hashes[node_id] = _get_points_hash(wall)

# Called by DD when a new node is added to the world (used for split detection)
# We MUST NOT modify any collections here as DD is iterating its mod list
var _pending_new_nodes = []

func on_new_node_added_to_world(node):
	if node == null or not is_instance_valid(node):
		return
	if _native_detect_ready and shadow_history != null and shadow_history.has_method("note_native_op"):
		shadow_history.note_native_op()
	# Just queue the node - processing happens in _on_monitor_tick
	_pending_new_nodes.append(node)

func _deferred_on_new_node_added(node):
	if node == null or not is_instance_valid(node):
		return
	if is_portal_node(node):
		_on_new_portal_placed(node)
		return
	var node_type = get_node_type(node)
	if node_type == null:
		return
	if not node.has_meta("node_id"):
		return
	var new_id = str(node.get_meta("node_id"))

	# Skip if already has shadow config
	if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(new_id):
		return

	# Find source node: the one being split
	var source_id = _find_split_source(node, node_type)
	# Pas un split : peut-être un COPY (clipboard_fix recrée le wall avec la même
	# forme que la source). On cherche un wall existant de même forme possédant
	# déjà un config, pour en hériter au lieu de retomber sur le défaut.
	if source_id == "":
		source_id = _find_clone_source(node, node_type, new_id)
	if source_id == "":
		# No split source — could be a Building Tool or Wall Tool placement
		var bt_on = _building_tool_toggle != null and _building_tool_toggle.pressed
		var wt_on = _wall_tool_toggle != null and _wall_tool_toggle.pressed
		if (bt_on or wt_on) and node_type == "walls":
			outputlog("Tool shadow: wall " + new_id + " bt=" + str(bt_on) + " wt=" + str(wt_on), 0)
			var cfg = _get_wall_tool_config()
			# Closed walls (loops) can't have extend - force it off
			if is_path_closed(node):
				cfg["extend_enabled"] = false
				cfg["fade_in_enabled"] = false
				cfg["fade_out_enabled"] = false
			save_shadow_data(node, cfg)
			yield(global.Editor.get_tree().create_timer(0.05), "timeout")
			if is_instance_valid(node):
				remove_shadow(node)
				create_shadow(node, cfg)
				_all_known_path_ids[new_id] = true
				_all_points_hashes[new_id] = _get_points_hash(node)
		return

	# Copy shadow config from source
	if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(source_id):
		var src_config = global.ModMapData[SHADOW_DATA_KEY][source_id]
		var new_config = src_config.duplicate()
		save_shadow_data(node, new_config)
		outputlog("[COPY-DIAG] heritage " + new_id + " <- " + source_id + " mode=" + str(new_config.get("render_mode", "simple")) + " enabled=" + str(new_config.get("enabled", false)), 0)
		if new_config.get("enabled", false):
			# Delay shadow creation slightly to let DD finish building the node
			yield(global.Editor.get_tree().create_timer(0.05), "timeout")
			# Realistic : la capture exige les Line2D enfants (segments) du mur, que DD
			# construit de façon ASYNCHRONE après la copie. Le délai fixe suffisait au
			# mode simple (points) mais pas au realistic -> sortie silencieuse sans
			# ombre. On attend que le Line2D existe (jusqu'à ~2s).
			if new_config.get("render_mode", "simple") == "realistic":
				var _tries = 0
				while _tries < 20 and is_instance_valid(node) and get_line2d(node) == null:
					yield(global.Editor.get_tree().create_timer(0.1), "timeout")
					_tries += 1
				outputlog("[COPY-DIAG] realistic ready apres " + str(_tries) + " essais, line=" + str(get_line2d(node) != null if is_instance_valid(node) else "node freed"), 0)
			if is_instance_valid(node):
				remove_shadow(node)
				create_shadow(node, new_config)
				_all_points_hashes[new_id] = _get_points_hash(node)

# Hash de FORME invariant par translation (points relatifs au 1er point). Permet
# de matcher une copie même si ses points locaux sont décalés vs la source
# (clipboard_fix recrée le wall via AddWall, possiblement en coords monde).
func _get_wall_shape_hash(path) -> int:
	if path == null or not is_instance_valid(path):
		return 0
	var line = get_line2d(path)
	if line == null or get_node_type(path) != "walls":
		return 0
	var h = 0
	var tex_width = line.width
	var has_origin = false
	var origin = Vector2.ZERO
	var count = 0
	for ci in range(path.get_child_count()):
		var ch = path.get_child(ci)
		if ch is Line2D and ch.width == tex_width and ch.get_point_count() >= 2:
			for p in ch.points:
				if not has_origin:
					origin = p
					has_origin = true
				var rp = p - origin
				h = h * 31 + int(round(rp.x * 10)) + int(round(rp.y * 10)) * 7
				count += 1
	h = h * 31 + count
	h = h * 31 + int(round(tex_width * 10))
	return h

# Cherche un wall EXISTANT de même type et même FORME que `node`, possédant déjà
# un config de shadow, pour qu'une COPIE en hérite (cas clipboard_fix).
func _find_clone_source(node, node_type: String, new_id: String) -> String:
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return ""
	if node_type != "walls":
		return ""
	var new_shape = _get_wall_shape_hash(node)
	if new_shape == 0:
		return ""
	var matches = []
	for src_id in global.ModMapData[SHADOW_DATA_KEY].keys():
		if str(src_id) == new_id:
			continue
		if not global.World.HasNodeID(src_id):
			continue
		var src = global.World.GetNodeByID(src_id)
		if src == null or not is_instance_valid(src) or src == node:
			continue
		if get_node_type(src) != node_type:
			continue
		if _get_wall_shape_hash(src) == new_shape:
			matches.append(str(src_id))
	if matches.size() == 0:
		return ""
	if matches.size() == 1:
		return matches[0]
	# Plusieurs candidats de MÊME forme (copie de copie : l'original et ses copies ont
	# un hash identique) : préfère le plus RÉCEMMENT SÉLECTIONNÉ — pour copier un mur,
	# on l'a forcément sélectionné juste avant le Ctrl+C. Sans ça, le premier trouvé
	# (souvent l'original) imposait sa config aux copies de copies.
	for rnid in _select_recency:
		if matches.has(rnid):
			return rnid
	return matches[0]

func _find_split_source(node, node_type: String) -> String:
	# Method 1: Check current selection
	var selected = global.Editor.Tools["SelectTool"].Selected
	if selected.size() > 0:
		var sel = selected[0]
		if is_instance_valid(sel) and sel.has_meta("node_id"):
			var sel_id = str(sel.get_meta("node_id"))
			if sel_id != str(node.get_meta("node_id")):
				if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(sel_id):
					return sel_id

	# Method 2: For walls, find wall whose point count decreased (split detection via snapshot)
	if node_type == "walls":
		var new_id_str = str(node.get_meta("node_id"))
		var level = global.World.GetCurrentLevel()
		if level != null:
			var walls_node = level.get_node_or_null("Walls")
			if walls_node != null:
				for i in range(walls_node.get_child_count()):
					var wall_child = walls_node.get_child(i)
					if not is_instance_valid(wall_child) or not wall_child.has_meta("node_id"):
						continue
					var cid = str(wall_child.get_meta("node_id"))
					if cid == new_id_str:
						continue
					# Check if this wall's point count decreased AND has shadow data
					if _wall_point_snapshot.has(cid):
						var old_count = _wall_point_snapshot[cid]
						var new_count = _get_wall_line2d_point_count(wall_child)
						if new_count < old_count:
							if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(cid):
								return cid

	# Method 3: For paths, check if a selected path was split (point count decreased)
	if node_type == "paths":
		if global.ModMapData.has(SHADOW_DATA_KEY):
			for src_id in global.ModMapData[SHADOW_DATA_KEY].keys():
				if not global.World.HasNodeID(src_id):
					continue
				var src_node = global.World.GetNodeByID(src_id)
				if get_node_type(src_node) != "paths":
					continue
				# Check if points hash changed (fewer points = was split)
				var old_hash = _all_points_hashes.get(src_id, 0)
				var new_hash = _get_points_hash(src_node)
				if old_hash != 0 and new_hash != old_hash:
					return src_id

	return ""

# Get the point count of the widest Line2D child of a wall (the texture line)
func _get_wall_line2d_point_count(wall: Node2D) -> int:
	var best_width = 0.0
	var best_count = 0
	for i in range(wall.get_child_count()):
		var ch = wall.get_child(i)
		if ch is Line2D and ch.get_point_count() >= 2 and ch.width > best_width:
			best_width = ch.width
			best_count = ch.get_point_count()
	return best_count

# Update the wall point snapshot (called from monitor tick)
func _update_wall_point_snapshot():
	var level = global.World.GetCurrentLevel()
	if level == null:
		return
	var walls_node = level.get_node_or_null("Walls")
	if walls_node == null:
		return
	var new_snap = {}
	for i in range(walls_node.get_child_count()):
		var wch = walls_node.get_child(i)
		if is_instance_valid(wch) and wch.has_meta("node_id"):
			new_snap[str(wch.get_meta("node_id"))] = _get_wall_line2d_point_count(wch)
	_wall_point_snapshot = new_snap

# Monitoring: track selected path state to detect changes (edit points, transitions)
var _monitored_path = null
var _select_recency = []   # node_ids sélectionnés, du plus récent au plus ancien (cap 8)
var _monitored_points_hash = 0
var _monitored_transitions_hash = 0
var _monitored_type = ""  # "paths" or "walls"
var _wall_point_snapshot = {}  # {node_id_str: point_count} for wall split detection
var _monitor_timer = null

# ── Undo/redo (transactions de réglages) ───────────────────────────────
var shadow_history = null   # set by Core
var _history_flush_timer = null
var _history_txn_active = false
var _history_txn_before = {}   # {node_id: {node, cfg}}
var _history_txn_label = ""
var _history_suspend = false

# ── Détection des ops natives (timeline undo/redo) ─────────────────────
var _native_state_by_id = {}   # node_id -> {pos, hash} (move ET reshape natifs)
var _native_detect_ready = false
var _native_arm_count = 0
var _native_heal_count = 0

# Tool panel references
var _path_tool_toggle = null  # CheckButton in PathTool
var _pt_editing_path = null   # Currently tracked editing path in PathTool
var _pt_editing_hash = 0      # Points hash of tracked editing path
var _pt_finalized_path = null  # Path that was just finalized, needs transition rebuild
var _pt_finalized_ticks = 0    # Ticks since finalization (rebuild a few times to catch transitions)

# ── Détection des ops natives + heal (timeline undo/redo) ──────────────
func _detect_native_wall_ops() -> void:
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
		var h = _get_points_hash(node)
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

func _has_valid_shadow(node, meta_key: String) -> bool:
	if not node.has_meta(meta_key):
		return false
	var nodes = node.get_meta(meta_key)
	if not (nodes is Array):
		return false
	for n in nodes:
		if is_instance_valid(n):
			return true
	return false

# Resync/heal : reconstruit les shadows manquantes des nœuds présents+activés
# (nœud réapparu via redo natif à géométrie identique). Ne purge jamais.
func _history_force_resync() -> void:
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return
	var hidden = bool(global.ModMapData.get("DropShadowToggleHidden", false))
	var sd = global.ModMapData[SHADOW_DATA_KEY]
	for node_id in sd.keys():
		var cfg = sd[node_id]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		if not global.World.HasNodeID(node_id):
			continue
		var node = global.World.GetNodeByID(node_id)
		if node == null or not is_instance_valid(node) or not is_shadow_node_type(node):
			continue
		if _has_valid_shadow(node, SHADOW_META_KEY):
			continue
		remove_shadow(node)
		create_shadow(node, cfg)
		_all_points_hashes[node_id] = _get_points_hash(node)
		if hidden and node.has_meta(SHADOW_META_KEY):
			for n in node.get_meta(SHADOW_META_KEY):
				if is_instance_valid(n):
					n.visible = false

func _get_points_hash(path) -> int:
	if path == null or not is_instance_valid(path):
		return 0
	var line = get_line2d(path)
	if line == null:
		return 0

	var node_type = get_node_type(path)
	var h = 0

	# For walls: hash ALL Line2D segments of matching width
	if node_type == "walls":
		var tex_width = line.width
		for ci in range(path.get_child_count()):
			var ch = path.get_child(ci)
			if ch is Line2D and ch.width == tex_width and ch.get_point_count() >= 2:
				for p in ch.points:
					h = h * 31 + int(p.x * 10) + int(p.y * 10) * 7
		h = h * 31 + path.get_child_count()
		# Include portal texture state so shadow rebuilds when textures load
		for ci2 in range(path.get_child_count()):
			var ch2 = path.get_child(ci2)
			if (ch2.name.begins_with("Portal") or ch2.name.begins_with("@Portal")) and ch2.get_child_count() > 0:
				var spr = ch2.get_child(0)
				if spr is Sprite and spr.texture != null:
					h = h * 31 + spr.texture.resource_path.hash()
				else:
					h = h * 31 + 1  # texture not loaded yet
	else:
		for p in line.points:
			h = h * 31 + int(p.x * 10) + int(p.y * 10) * 7

	h = h * 31 + int(line.width * 10)
	h = h * 31 + int(line.rotation * 1000)
	# Include wall Line2D textures so hash changes when wall texture is swapped
	if node_type == "walls":
		for ci3 in range(path.get_child_count()):
			var ch3 = path.get_child(ci3)
			if ch3 is Line2D and ch3.texture != null:
				h = h * 31 + ch3.texture.get_rid().get_id()
	elif line.texture != null:
		h = h * 31 + line.texture.get_rid().get_id()
	return h

func _get_transitions_hash(path) -> int:
	if path == null or not is_instance_valid(path):
		return 0
	var h = 0
	for prop in ["FadeIn", "FadeOut", "Grow", "Shrink"]:
		var val = path.get(prop)
		if val is bool and val:
			h += hash(prop)
	return h

# Cache of points hashes for all shadow paths: { node_id: hash }
var _all_points_hashes = {}

# Known portal IDs per wall: { wall_node_id: { portal_id: true } }
var _known_wall_portals = {}

func _apply_override_to_new_portals(wall_node):
	if wall_node == null or not is_instance_valid(wall_node) or not wall_node.has_meta("node_id"):
		return
	var wall_id = str(wall_node.get_meta("node_id"))
	if not _known_wall_portals.has(wall_id):
		_known_wall_portals[wall_id] = {}
	var known = _known_wall_portals[wall_id]
	for ci in range(wall_node.get_child_count()):
		var ch = wall_node.get_child(ci)
		if not (ch.name.begins_with("Portal") or ch.name.begins_with("@Portal")):
			continue
		var p_id = get_portal_id(ch)
		if p_id == "":
			continue
		if known.has(p_id):
			continue
		# New portal detected
		known[p_id] = true
		# "Switch Shadow Setting" toggle: ON = invert default, OFF = use default
		if _portal_tool_keep_shadow:
			set_portal_skip_override(p_id, true)

var pt_ui = {}  # PathTool UI controls (separate from SelectTool ui_config)

func _build_path_tool_ui():
	var path_tool_panel = global.Editor.Toolset.GetToolPanel("PathTool")
	if path_tool_panel == null:
		outputlog("PathTool panel not found", 1)
		return
	var align_vbox = core.get_align_vbox(path_tool_panel)
	if align_vbox == null:
		outputlog("PathTool Align VBox not found", 1)
		return

	# Find BLOCK_LIGHT CheckButton and insert after it + its empty HBox separator
	var insert_after = -1
	for i in range(align_vbox.get_child_count()):
		var align_child = align_vbox.get_child(i)
		if align_child is CheckButton:
			var t = align_child.text
			if t != null and "LOCK" in t.to_upper():
				insert_after = i + 1
				# Skip the empty HBox separator if present
				if insert_after < align_vbox.get_child_count():
					var next_child = align_vbox.get_child(insert_after)
					if next_child is HBoxContainer and next_child.get_child_count() == 0:
						insert_after = i + 2
				break

	# Main container
	var pt_container = VBoxContainer.new()
	pt_container.name = "DropShadowPathTool"

	var sep1 = HSeparator.new()
	sep1.add_constant_override("separation", 4)
	pt_container.add_child(sep1)

	# Title row: "Soft Shadow" [reset] [cog] [ON/OFF]
	var title_hbox = HBoxContainer.new()
	var pt_cloud = _create_cloud_icon()
	if pt_cloud != null:
		title_hbox.add_child(pt_cloud)
	var title_label = Label.new()
	title_label.text = "Soft Shadow"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_label)
	var pt_reset_btn = _make_icon_button("icons/reset.png", "Reset to defaults", 0.5)
	pt_reset_btn.visible = false
	pt_reset_btn.connect("pressed", self, "_on_pt_reset_pressed")
	title_hbox.add_child(pt_reset_btn)
	pt_ui["reset_btn"] = pt_reset_btn
	var pt_cog = _make_icon_button("icons/cog.png", "Show/hide settings", 0.55)
	pt_cog.toggle_mode = true
	pt_cog.pressed = false
	pt_cog.visible = false
	pt_cog.connect("toggled", self, "_on_pt_cog_toggled")
	title_hbox.add_child(pt_cog)
	pt_ui["cog_btn"] = pt_cog
	var pt_enable = CheckButton.new()
	pt_enable.pressed = false
	title_hbox.add_child(pt_enable)
	_path_tool_toggle = pt_enable
	pt_ui["enable_check"] = pt_enable
	pt_container.add_child(title_hbox)

	# Direction buttons (visible when ON, outside settings panel)
	var dir_wrapper = VBoxContainer.new()
	dir_wrapper.visible = false
	pt_ui["dir_wrapper"] = dir_wrapper
	var dir_hbox = HBoxContainer.new()
	var dir_names = ["Side A", "Side B", "Both"]
	for i in range(3):
		var btn = Button.new()
		btn.text = " " + dir_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == int(DEFAULT_SHADOW_CONFIG["direction"]))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_LEFT
		if i == int(DEFAULT_SHADOW_CONFIG["direction"]):
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
		btn.connect("pressed", self, "_on_pt_direction_pressed", [i])
		dir_hbox.add_child(btn)
		pt_ui["dir_btn_" + str(i)] = btn
	dir_wrapper.add_child(dir_hbox)
	pt_container.add_child(dir_wrapper)

	# Settings panel (visible via cog toggle)
	var pt_settings = VBoxContainer.new()
	pt_settings.visible = false
	pt_ui["settings"] = pt_settings

	# Opacity
	pt_settings.add_child(_make_pt_slider_row("Opacity", "opacity", 0.05, 1.0, 0.05, DEFAULT_SHADOW_CONFIG["opacity"]))
	# Spread
	pt_settings.add_child(_make_pt_slider_row("Spread", "spread", 0.0, 3.0, 0.05, DEFAULT_SHADOW_CONFIG["spread"]))
	# Softness
	pt_settings.add_child(_make_pt_slider_row("Softness", "softness", 0.1, 10.0, 0.25, DEFAULT_SHADOW_CONFIG["softness"]))

	# Extend Ends with Fade
	var pt_ext_sep = HSeparator.new()
	pt_ext_sep.add_constant_override("separation", 2)
	pt_settings.add_child(pt_ext_sep)
	var pt_ext_hbox = HBoxContainer.new()
	var pt_ext_label = Label.new()
	pt_ext_label.text = "Extend Ends with Fade"
	pt_ext_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pt_ext_hbox.add_child(pt_ext_label)
	var pt_ext_check = CheckButton.new()
	pt_ext_check.pressed = false
	pt_ext_check.connect("toggled", self, "_on_pt_extend_toggled")
	pt_ext_hbox.add_child(pt_ext_check)
	pt_ui["extend_check"] = pt_ext_check
	pt_ui["pt_ext_hbox"] = pt_ext_hbox
	# Initially in dir_wrapper (cog closed)
	dir_wrapper.add_child(pt_ext_hbox)

	# Shape slider (-1..+1, 0 = semicircle cap; inside settings, shown when extend ON)
	var pt_fd_container = VBoxContainer.new()
	pt_fd_container.visible = false
	var pt_fd_hbox = HBoxContainer.new()
	var pt_fd_label = Label.new()
	pt_fd_label.text = "Shape"
	pt_fd_label.rect_min_size.x = 60
	pt_fd_hbox.add_child(pt_fd_label)
	var pt_fd_slider = HSlider.new()
	pt_fd_slider.min_value = -1.0
	pt_fd_slider.max_value = 1.0
	pt_fd_slider.step = 0.05
	pt_fd_slider.value = DEFAULT_SHADOW_CONFIG["fade_extend"]
	pt_fd_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pt_fd_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pt_fd_slider.connect("value_changed", self, "_on_pt_slider_changed", ["fade_extend"])
	pt_fd_hbox.add_child(pt_fd_slider)
	pt_ui["fade_extend_slider"] = pt_fd_slider
	var pt_fd_spin = SpinBox.new()
	pt_fd_spin.min_value = -1.0
	pt_fd_spin.max_value = 1.0
	pt_fd_spin.step = 0.05
	pt_fd_spin.value = DEFAULT_SHADOW_CONFIG["fade_extend"]
	pt_fd_spin.connect("value_changed", self, "_on_pt_spin_changed", ["fade_extend"])
	pt_fd_hbox.add_child(pt_fd_spin)
	pt_ui["fade_extend_spin"] = pt_fd_spin
	var pt_fd_reset = _make_icon_button("icons/reset.png", "Reset shape", 0.5)
	pt_fd_reset.connect("pressed", self, "_on_pt_single_reset", ["fade_extend"])
	pt_fd_hbox.add_child(pt_fd_reset)
	pt_fd_container.add_child(pt_fd_hbox)
	pt_settings.add_child(pt_fd_container)
	pt_ui["fade_extend_container"] = pt_fd_container

	pt_container.add_child(pt_settings)

	var sep2 = HSeparator.new()
	sep2.add_constant_override("separation", 4)
	pt_container.add_child(sep2)

	align_vbox.add_child(pt_container)
	if insert_after >= 0 and insert_after < align_vbox.get_child_count():
		align_vbox.move_child(pt_container, insert_after)

	# Connect AFTER everything is built to avoid issues during construction
	pt_enable.connect("toggled", self, "_on_path_tool_shadow_toggled")

	outputlog("PathTool UI built successfully", 1)

func _make_pt_slider_row(label_text: String, key: String, min_val: float, max_val: float, step_val: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.rect_min_size.x = 60
	hbox.add_child(label)
	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_pt_slider_changed", [key])
	hbox.add_child(slider)
	pt_ui[key + "_slider"] = slider
	var spin = SpinBox.new()
	spin.min_value = min_val
	spin.max_value = max_val
	spin.step = step_val
	spin.value = default_val
	spin.connect("value_changed", self, "_on_pt_spin_changed", [key])
	hbox.add_child(spin)
	pt_ui[key + "_spin"] = spin
	var reset = _make_icon_button("icons/reset.png", "Reset " + label_text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_pt_single_reset", [key])
	hbox.add_child(reset)
	return hbox

# Build config from PathTool UI merged with defaults
func _get_path_tool_config(path = null) -> Dictionary:
	var cfg = FACTORY_DEFAULTS.duplicate()
	# Apply user defaults if they exist
	if global.ModMapData.has(USER_DEFAULTS_KEY):
		var user_def = global.ModMapData[USER_DEFAULTS_KEY]
		for key in user_def.keys():
			cfg[key] = user_def[key]
	cfg["enabled"] = true
	cfg["opacity"] = pt_ui["opacity_spin"].value
	cfg["spread"] = pt_ui["spread_spin"].value
	cfg["softness"] = pt_ui["softness_spin"].value
	cfg["direction"] = _get_pt_direction()
	# Extend toggle from path tool UI
	if pt_ui.has("extend_check"):
		cfg["extend_enabled"] = pt_ui["extend_check"].pressed
		if pt_ui["extend_check"].pressed:
			cfg["fade_extend"] = pt_ui["fade_extend_spin"].value if pt_ui.has("fade_extend_spin") else FACTORY_DEFAULTS["fade_extend"]
	# Apply path transitions if no user defaults
	if path != null and is_instance_valid(path) and not global.ModMapData.has(USER_DEFAULTS_KEY):
		_apply_path_transitions(cfg, path)
	return cfg

func _get_pt_direction() -> int:
	for i in range(3):
		if pt_ui["dir_btn_" + str(i)].pressed:
			return i
	return 2

func _on_pt_direction_pressed(dir_index):
	for i in range(3):
		var btn = pt_ui["dir_btn_" + str(i)]
		btn.pressed = (i == dir_index)
		if i == dir_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")

func _on_pt_slider_changed(value, which):
	pt_ui[which + "_spin"].value = value

func _on_pt_spin_changed(value, which):
	pt_ui[which + "_slider"].value = value

func _on_pt_single_reset(which):
	var def_val = _get_effective_default_for_tool(which, USER_DEFAULTS_KEY)
	pt_ui[which + "_slider"].value = def_val
	pt_ui[which + "_spin"].value = def_val

func _on_pt_reset_pressed():
	_sync_pt_ui_from_defaults()

# Track all known path node_ids to detect newly created paths
var _all_known_path_ids = {}

func _on_path_tool_shadow_toggled(pressed):
	if pt_ui.has("dir_wrapper"):
		pt_ui["dir_wrapper"].visible = pressed
	if pt_ui.has("cog_btn"):
		pt_ui["cog_btn"].visible = pressed
	if pt_ui.has("reset_btn"):
		pt_ui["reset_btn"].visible = pressed
	if pressed:
		_sync_pt_ui_from_defaults()
	else:
		if pt_ui.has("settings"):
			pt_ui["settings"].visible = false
		if pt_ui.has("cog_btn"):
			pt_ui["cog_btn"].pressed = false
		_reparent_pt_extend_toggle(false)

func _sync_pt_ui_from_defaults():
	if not pt_ui.has("opacity_slider"):
		return
	# Load user path defaults if they exist, otherwise factory
	var cfg = FACTORY_DEFAULTS.duplicate()
	if global.ModMapData.has(USER_DEFAULTS_KEY):
		var user_def = global.ModMapData[USER_DEFAULTS_KEY]
		for key in user_def.keys():
			cfg[key] = user_def[key]
	pt_ui["opacity_slider"].value = cfg.get("opacity", FACTORY_DEFAULTS["opacity"])
	pt_ui["opacity_spin"].value = cfg.get("opacity", FACTORY_DEFAULTS["opacity"])
	pt_ui["spread_slider"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	pt_ui["spread_spin"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	pt_ui["softness_slider"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
	pt_ui["softness_spin"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
	_on_pt_direction_pressed(int(cfg.get("direction", FACTORY_DEFAULTS["direction"])))
	if pt_ui.has("extend_check"):
		pt_ui["extend_check"].pressed = cfg.get("extend_enabled", false)
	if pt_ui.has("fade_extend_slider"):
		pt_ui["fade_extend_slider"].value = cfg.get("fade_extend", FACTORY_DEFAULTS["fade_extend"])
	if pt_ui.has("fade_extend_spin"):
		pt_ui["fade_extend_spin"].value = cfg.get("fade_extend", FACTORY_DEFAULTS["fade_extend"])
	if pt_ui.has("fade_extend_container"):
		pt_ui["fade_extend_container"].visible = cfg.get("extend_enabled", false)

func _on_pt_cog_toggled(pressed):
	if pt_ui.has("settings"):
		pt_ui["settings"].visible = pressed
	_reparent_pt_extend_toggle(pressed)

func _on_pt_extend_toggled(pressed):
	if pt_ui.has("fade_extend_container"):
		pt_ui["fade_extend_container"].visible = pressed

func _reparent_pt_extend_toggle(cog_open: bool):
	var ext_hbox = pt_ui.get("pt_ext_hbox")
	if ext_hbox == null:
		return
	var settings = pt_ui.get("settings")
	var dir_wrapper = pt_ui.get("dir_wrapper")
	if cog_open:
		if ext_hbox.get_parent() == settings:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		# Insert after the separator that's before the fd_container
		var fd_container = pt_ui.get("fade_extend_container")
		if fd_container != null and settings != null:
			var fd_idx = fd_container.get_index()
			settings.add_child(ext_hbox)
			settings.move_child(ext_hbox, fd_idx)
		elif settings != null:
			settings.add_child(ext_hbox)
	else:
		if ext_hbox.get_parent() == dir_wrapper:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		dir_wrapper.add_child(ext_hbox)

#########################################################################################################
##
## WALL TOOL UI
##
#########################################################################################################

var wt_ui = {}  # WallTool UI controls
var _wall_tool_toggle = null  # Reference to wall tool enable checkbox
var _building_tool_toggle = null  # Reference to building tool enable checkbox

func _build_building_tool_ui():
	var building_names = ["FloorShapeTool", "BuildingTool", "FloorTool"]
	var building_panel = null
	for tn in building_names:
		building_panel = global.Editor.Toolset.GetToolPanel(tn)
		if building_panel != null:
			outputlog("Found building tool panel as: " + tn, 0)
			break
	if building_panel == null:
		outputlog("BuildingTool panel not found", 0)
		return
	
	var align_vbox = core.get_align_vbox(building_panel)
	if align_vbox == null:
		align_vbox = building_panel
	
	var bt_wrapper = VBoxContainer.new()
	bt_wrapper.name = "SoftShadowBuildingTool"
	
	var bt_sep_top = HSeparator.new()
	bt_sep_top.add_constant_override("separation", 4)
	bt_wrapper.add_child(bt_sep_top)
	
	var bt_hbox = HBoxContainer.new()
	var bt_cloud = _create_cloud_icon()
	if bt_cloud != null:
		bt_hbox.add_child(bt_cloud)
	var bt_label = Label.new()
	bt_label.text = "Soft Shadow"
	bt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bt_hbox.add_child(bt_label)
	var bt_note = Label.new()
	bt_note.text = "(Wall Tool Settings)"
	var small_font = DynamicFont.new()
	small_font.font_data = bt_note.get_font("font").font_data if bt_note.get_font("font") is DynamicFont else null
	if small_font.font_data != null:
		small_font.size = bt_note.get_font("font").size - 2
		bt_note.add_font_override("font", small_font)
	bt_note.add_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
	bt_hbox.add_child(bt_note)
	
	var bt_toggle = CheckButton.new()
	bt_toggle.pressed = false
	bt_toggle.connect("toggled", self, "_on_building_tool_shadow_toggled")
	bt_hbox.add_child(bt_toggle)
	_building_tool_toggle = bt_toggle
	
	bt_wrapper.add_child(bt_hbox)
	
	var bt_sep_bottom = HSeparator.new()
	bt_sep_bottom.add_constant_override("separation", 4)
	bt_wrapper.add_child(bt_sep_bottom)
	
	align_vbox.add_child(bt_wrapper)
	outputlog("BuildingTool Soft Shadow toggle added.", 0)

func _build_wall_tool_ui():
	var wall_tool_panel = global.Editor.Toolset.GetToolPanel("WallTool")
	if wall_tool_panel == null:
		outputlog("WallTool panel not found", 1)
		return
	var align_vbox = core.get_align_vbox(wall_tool_panel)
	if align_vbox == null:
		outputlog("WallTool Align VBox not found", 1)
		return

	# Find the native "Shadow" checkbox to insert just after it
	var shadow_idx = -1
	for i in range(align_vbox.get_child_count()):
		var child = align_vbox.get_child(i)
		var ctext = str(child.get("text")) if child.get("text") != null else ""
		if ctext.to_lower() == "shadow":
			shadow_idx = i
			break
		for j in range(child.get_child_count()):
			var sub = child.get_child(j)
			var stext = str(sub.get("text")) if sub.get("text") != null else ""
			if stext.to_lower() == "shadow":
				shadow_idx = i
				break
		if shadow_idx >= 0:
			break

	# Main container
	var wt_container = VBoxContainer.new()
	wt_container.name = "DropShadowWallTool"

	var sep1 = HSeparator.new()
	sep1.add_constant_override("separation", 4)
	wt_container.add_child(sep1)

	# Title row: "Soft Shadow" [reset] [cog] [ON/OFF]
	var title_hbox = HBoxContainer.new()
	var wt_cloud = _create_cloud_icon()
	if wt_cloud != null:
		title_hbox.add_child(wt_cloud)
	var title_label = Label.new()
	title_label.text = "Soft Shadow"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_label)
	var wt_reset_btn = _make_icon_button("icons/reset.png", "Reset to defaults", 0.5)
	wt_reset_btn.visible = false
	wt_reset_btn.connect("pressed", self, "_on_wt_reset_pressed")
	title_hbox.add_child(wt_reset_btn)
	wt_ui["reset_btn"] = wt_reset_btn
	var wt_cog = _make_icon_button("icons/cog.png", "Show/hide settings", 0.55)
	wt_cog.toggle_mode = true
	wt_cog.pressed = false
	wt_cog.visible = false
	wt_cog.connect("toggled", self, "_on_wt_cog_toggled")
	title_hbox.add_child(wt_cog)
	wt_ui["cog_btn"] = wt_cog
	var wt_enable = CheckButton.new()
	wt_enable.pressed = false
	title_hbox.add_child(wt_enable)
	_wall_tool_toggle = wt_enable
	wt_ui["enable_check"] = wt_enable
	wt_container.add_child(title_hbox)

	# Render mode: Simple | Realistic (radio) — comme dans le Select tool / Path Tool.
	var wt_mode_wrapper = VBoxContainer.new()
	wt_mode_wrapper.visible = false
	wt_ui["mode_wrapper"] = wt_mode_wrapper
	var wt_mode_hbox = HBoxContainer.new()
	var wt_mode_names = ["Simple", "Realistic"]
	for mi in range(2):
		var mbtn = Button.new()
		mbtn.text = " " + wt_mode_names[mi]
		mbtn.toggle_mode = true
		mbtn.pressed = (mi == _render_mode_to_index(DEFAULT_SHADOW_CONFIG.get("render_mode", "simple")))
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.align = Button.ALIGN_LEFT
		if mbtn.pressed:
			mbtn.icon = mbtn.get_icon("radio_checked", "CheckBox")
		else:
			mbtn.icon = mbtn.get_icon("radio_unchecked", "CheckBox")
		mbtn.connect("pressed", self, "_on_wt_render_mode_pressed", [mi])
		wt_mode_hbox.add_child(mbtn)
		wt_ui["mode_btn_" + str(mi)] = mbtn
	wt_mode_wrapper.add_child(wt_mode_hbox)
	wt_container.add_child(wt_mode_wrapper)

	# Direction buttons (visible when ON, outside settings panel)
	var dir_wrapper = VBoxContainer.new()
	dir_wrapper.visible = false
	wt_ui["dir_wrapper"] = dir_wrapper
	var dir_hbox = HBoxContainer.new()
	var dir_names = ["Side A", "Side B", "Both"]
	for i in range(3):
		var btn = Button.new()
		btn.text = " " + dir_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == int(DEFAULT_SHADOW_CONFIG["direction"]))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_LEFT
		if i == int(DEFAULT_SHADOW_CONFIG["direction"]):
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
		btn.connect("pressed", self, "_on_wt_direction_pressed", [i])
		dir_hbox.add_child(btn)
		wt_ui["dir_btn_" + str(i)] = btn
	dir_wrapper.add_child(dir_hbox)
	wt_container.add_child(dir_wrapper)

	# Settings panel (visible via cog toggle)
	var wt_settings = VBoxContainer.new()
	wt_settings.visible = false
	wt_ui["settings"] = wt_settings

	# Opacity
	wt_settings.add_child(_make_wt_slider_row("Opacity", "opacity", 0.05, 1.0, 0.05, DEFAULT_SHADOW_CONFIG["opacity"]))
	# Spread (Simple mode only)
	var wt_spread_row = _make_wt_slider_row("Spread", "spread", 0.0, 3.0, 0.05, DEFAULT_SHADOW_CONFIG["spread"])
	wt_ui["spread_hbox"] = wt_spread_row
	wt_settings.add_child(wt_spread_row)
	# Softness (Simple mode only)
	var wt_soft_row = _make_wt_slider_row("Softness", "softness", 0.1, 10.0, 0.25, DEFAULT_SHADOW_CONFIG["softness"])
	wt_ui["softness_hbox"] = wt_soft_row
	wt_settings.add_child(wt_soft_row)
	# Blur (Realistic mode only)
	var wt_blur_row = _make_wt_slider_row("Blur", "realistic_blur", 0.0, 1.0, 0.01, DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2))
	wt_blur_row.visible = false
	wt_ui["realistic_blur_hbox"] = wt_blur_row
	wt_settings.add_child(wt_blur_row)

	# Extend Ends with Fade
	var wt_ext_sep = HSeparator.new()
	wt_ext_sep.add_constant_override("separation", 2)
	wt_settings.add_child(wt_ext_sep)
	var wt_ext_hbox = HBoxContainer.new()
	var wt_ext_label = Label.new()
	wt_ext_label.text = "Extend Ends with Fade"
	wt_ext_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wt_ext_hbox.add_child(wt_ext_label)
	var wt_ext_check = CheckButton.new()
	wt_ext_check.pressed = false
	wt_ext_check.connect("toggled", self, "_on_wt_extend_toggled")
	wt_ext_hbox.add_child(wt_ext_check)
	wt_ui["extend_check"] = wt_ext_check
	wt_ui["wt_ext_hbox"] = wt_ext_hbox
	# Initially in dir_wrapper (cog closed)
	dir_wrapper.add_child(wt_ext_hbox)

	wt_container.add_child(wt_settings)

	var sep2 = HSeparator.new()
	sep2.add_constant_override("separation", 4)
	wt_container.add_child(sep2)

	align_vbox.add_child(wt_container)
	if shadow_idx >= 0:
		align_vbox.move_child(wt_container, shadow_idx + 1)
		outputlog("WallTool: Soft Shadow inserted after native Shadow at idx " + str(shadow_idx + 1), 0)
	else:
		outputlog("WallTool: native Shadow not found, Soft Shadow added at end", 0)

	# Connect AFTER everything is built
	wt_enable.connect("toggled", self, "_on_wall_tool_shadow_toggled")

	outputlog("WallTool UI built successfully", 1)

func _make_wt_slider_row(label_text: String, key: String, min_val: float, max_val: float, step_val: float, default_val: float) -> HBoxContainer:
	var hbox = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.rect_min_size.x = 60
	hbox.add_child(label)
	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.connect("value_changed", self, "_on_wt_slider_changed", [key])
	hbox.add_child(slider)
	wt_ui[key + "_slider"] = slider
	var spin = SpinBox.new()
	spin.min_value = min_val
	spin.max_value = max_val
	spin.step = step_val
	spin.value = default_val
	spin.connect("value_changed", self, "_on_wt_spin_changed", [key])
	hbox.add_child(spin)
	wt_ui[key + "_spin"] = spin
	var reset = _make_icon_button("icons/reset.png", "Reset " + label_text.to_lower(), 0.5)
	reset.connect("pressed", self, "_on_wt_single_reset", [key])
	hbox.add_child(reset)
	return hbox

func _get_wall_tool_config() -> Dictionary:
	var cfg = FACTORY_DEFAULTS.duplicate()
	# Apply user wall defaults if they exist
	if global.ModMapData.has(USER_DEFAULTS_WALL_KEY):
		var user_def = global.ModMapData[USER_DEFAULTS_WALL_KEY]
		for key in user_def.keys():
			cfg[key] = user_def[key]
	cfg["enabled"] = true
	if not wt_ui.has("opacity_spin"):
		return cfg
	# Mode-independent opacity: the slider holds the active mode's value, the other
	# mode's value is kept in wt_ui["opacity_inactive"] (same pattern as SelectTool).
	var _wt_realistic = (_get_wt_render_mode() == 1)
	var _wt_op_active = wt_ui["opacity_spin"].value
	var _wt_op_other = wt_ui.get("opacity_inactive", FACTORY_DEFAULTS["opacity"] if _wt_realistic else FACTORY_DEFAULTS["opacity_realistic"])
	if _wt_realistic:
		cfg["opacity_realistic"] = _wt_op_active
		cfg["opacity"] = _wt_op_other
	else:
		cfg["opacity"] = _wt_op_active
		cfg["opacity_realistic"] = _wt_op_other
	cfg["spread"] = wt_ui["spread_spin"].value
	cfg["softness"] = wt_ui["softness_spin"].value
	cfg["direction"] = _get_wt_direction()
	cfg["render_mode"] = _render_mode_from_index(_get_wt_render_mode())
	if wt_ui.has("realistic_blur_spin"):
		cfg["realistic_blur"] = wt_ui["realistic_blur_spin"].value
	# Extend (now means: draw rounded caps at ends — no longer forces fade_in/out)
	# Not available in Realistic mode (the toggle is hidden there).
	if wt_ui.has("extend_check"):
		cfg["extend_enabled"] = wt_ui["extend_check"].pressed and not _wt_realistic
	return cfg

func _get_wt_direction() -> int:
	for i in range(3):
		if wt_ui.has("dir_btn_" + str(i)) and wt_ui["dir_btn_" + str(i)].pressed:
			return i
	return 0

func _on_wt_direction_pressed(dir_index):
	for i in range(3):
		var btn = wt_ui["dir_btn_" + str(i)]
		btn.pressed = (i == dir_index)
		if i == dir_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")

func _on_wt_render_mode_pressed(mode_index):
	# Mode-independent opacity: swap the slider with the inactive mode's value.
	# Max is raised to 2.0 in Realistic (set max first so a value >1 is not clamped).
	var _prev = int(wt_ui.get("mode_current", 0))
	if mode_index != _prev and wt_ui.has("opacity_slider"):
		var _cur = wt_ui["opacity_slider"].value
		var _oth = wt_ui.get("opacity_inactive", FACTORY_DEFAULTS["opacity_realistic"] if mode_index == 1 else FACTORY_DEFAULTS["opacity"])
		wt_ui["opacity_inactive"] = _cur
		var _mx = 2.0 if mode_index == 1 else 1.0
		wt_ui["opacity_slider"].max_value = _mx
		wt_ui["opacity_spin"].max_value = _mx
		wt_ui["opacity_slider"].value = _oth
		wt_ui["opacity_spin"].value = _oth
	wt_ui["mode_current"] = mode_index
	for i in range(2):
		if not wt_ui.has("mode_btn_" + str(i)):
			continue
		var b = wt_ui["mode_btn_" + str(i)]
		b.pressed = (i == mode_index)
		if i == mode_index:
			b.icon = b.get_icon("radio_checked", "CheckBox")
		else:
			b.icon = b.get_icon("radio_unchecked", "CheckBox")
	_update_wt_mode_visibility()

# Realistic mode: show Blur, hide Spread/Softness/Extend. Simple mode: the opposite.
func _update_wt_mode_visibility():
	var _realistic = (int(wt_ui.get("mode_current", 0)) == 1)
	if wt_ui.has("spread_hbox"):
		wt_ui["spread_hbox"].visible = not _realistic
	if wt_ui.has("softness_hbox"):
		wt_ui["softness_hbox"].visible = not _realistic
	if wt_ui.has("realistic_blur_hbox"):
		wt_ui["realistic_blur_hbox"].visible = _realistic
	if wt_ui.has("wt_ext_hbox"):
		wt_ui["wt_ext_hbox"].visible = not _realistic

func _get_wt_render_mode() -> int:
	for i in range(2):
		if wt_ui.has("mode_btn_" + str(i)) and wt_ui["mode_btn_" + str(i)].pressed:
			return i
	return 0

func _on_wt_slider_changed(value, which):
	wt_ui[which + "_spin"].value = value

func _on_wt_spin_changed(value, which):
	wt_ui[which + "_slider"].value = value

func _on_wt_single_reset(which):
	# Opacity default depends on the active render mode (simple vs realistic).
	if which == "opacity" and int(wt_ui.get("mode_current", 0)) == 1:
		which = "opacity_realistic"
		var def_val_r = _get_effective_default_for_tool(which, USER_DEFAULTS_WALL_KEY)
		wt_ui["opacity_slider"].value = def_val_r
		wt_ui["opacity_spin"].value = def_val_r
		return
	var def_val = _get_effective_default_for_tool(which, USER_DEFAULTS_WALL_KEY)
	wt_ui[which + "_slider"].value = def_val
	wt_ui[which + "_spin"].value = def_val

# Returns the effective default value for a tool panel slider reset,
# checking user defaults for the given key, then falling back to FACTORY_DEFAULTS.
func _get_effective_default_for_tool(which: String, defaults_key: String):
	if global.ModMapData.has(defaults_key):
		var user_def = global.ModMapData[defaults_key]
		if user_def.has(which):
			return user_def[which]
	return FACTORY_DEFAULTS[which]

func _on_wt_reset_pressed():
	_sync_wt_ui_from_defaults()

func _on_wall_tool_shadow_toggled(pressed):
	if wt_ui.has("dir_wrapper"):
		wt_ui["dir_wrapper"].visible = pressed
		if wt_ui.has("mode_wrapper"):
			wt_ui["mode_wrapper"].visible = pressed
	if wt_ui.has("cog_btn"):
		wt_ui["cog_btn"].visible = pressed
	if wt_ui.has("reset_btn"):
		wt_ui["reset_btn"].visible = pressed
	if not pressed:
		if wt_ui.has("settings"):
			wt_ui["settings"].visible = false
		if wt_ui.has("cog_btn"):
			wt_ui["cog_btn"].pressed = false
	# Sync building tool toggle
	if _building_tool_toggle != null and _building_tool_toggle.pressed != pressed:
		_building_tool_toggle.pressed = pressed

func _on_building_tool_shadow_toggled(pressed):
	# Sync wall tool toggle
	if _wall_tool_toggle != null and _wall_tool_toggle.pressed != pressed:
		_wall_tool_toggle.pressed = pressed

func _on_wt_cog_toggled(pressed):
	if wt_ui.has("settings"):
		wt_ui["settings"].visible = pressed
	_reparent_wt_extend_toggle(pressed)

func _on_wt_extend_toggled(_pressed):
	pass

func _reparent_wt_extend_toggle(cog_open: bool):
	var ext_hbox = wt_ui.get("wt_ext_hbox")
	if ext_hbox == null:
		return
	var settings = wt_ui.get("settings")
	var dir_wrapper = wt_ui.get("dir_wrapper")
	if cog_open:
		if ext_hbox.get_parent() == settings:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		if settings != null:
			settings.add_child(ext_hbox)
	else:
		if ext_hbox.get_parent() == dir_wrapper:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		dir_wrapper.add_child(ext_hbox)

func _sync_wt_ui_from_defaults():
	if not wt_ui.has("opacity_slider"):
		return
	var cfg = FACTORY_DEFAULTS.duplicate()
	if global.ModMapData.has(USER_DEFAULTS_WALL_KEY):
		var user_def = global.ModMapData[USER_DEFAULTS_WALL_KEY]
		for key in user_def.keys():
			cfg[key] = user_def[key]
	# Mode first: set mode_current before calling the handler so no swap occurs,
	# then set the max (2.0 in Realistic) before the value to avoid clamping.
	var _midx = _render_mode_to_index(cfg.get("render_mode", "simple"))
	wt_ui["mode_current"] = _midx
	_on_wt_render_mode_pressed(_midx)
	var _mx = 2.0 if _midx == 1 else 1.0
	wt_ui["opacity_slider"].max_value = _mx
	wt_ui["opacity_spin"].max_value = _mx
	var _op_s = cfg.get("opacity", FACTORY_DEFAULTS["opacity"])
	var _op_r = cfg.get("opacity_realistic", FACTORY_DEFAULTS["opacity_realistic"])
	wt_ui["opacity_slider"].value = _op_r if _midx == 1 else _op_s
	wt_ui["opacity_spin"].value = _op_r if _midx == 1 else _op_s
	wt_ui["opacity_inactive"] = _op_s if _midx == 1 else _op_r
	wt_ui["spread_slider"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	wt_ui["spread_spin"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	wt_ui["softness_slider"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
	wt_ui["softness_spin"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
	if wt_ui.has("realistic_blur_slider"):
		wt_ui["realistic_blur_slider"].value = cfg.get("realistic_blur", FACTORY_DEFAULTS.get("realistic_blur", 0.2))
		wt_ui["realistic_blur_spin"].value = cfg.get("realistic_blur", FACTORY_DEFAULTS.get("realistic_blur", 0.2))
	_on_wt_direction_pressed(int(cfg.get("direction", FACTORY_DEFAULTS["direction"])))
	if wt_ui.has("extend_check"):
		wt_ui["extend_check"].pressed = cfg.get("extend_enabled", false)

func _update_path_tool_live_shadow():
	if _path_tool_toggle == null or not _path_tool_toggle.pressed:
		# Toggle is OFF — clean up any live shadow
		if _pt_editing_path != null and is_instance_valid(_pt_editing_path):
			remove_shadow(_pt_editing_path)
		_pt_editing_path = null
		_pt_editing_hash = 0
		return

	# Find the currently editing path in PathTool
	var editing = null
	var path_tool = global.Editor.Tools.get("PathTool")
	if path_tool != null:
		# Try direct properties
		for prop in ["EditingPath", "editingPath", "SelectedPath", "CurrentPath", "currentPath", "path", "Path", "ActivePath"]:
			var ed = path_tool.get(prop)
			if ed != null and is_instance_valid(ed):
				editing = ed
				break
		# If no direct property, try to find a Line2D child
		if editing == null and path_tool is Node:
			for i in range(path_tool.get_child_count()):
				var child = path_tool.get_child(i)
				if child is Line2D and child.points.size() >= 1:
					editing = child
					break

	if editing == null:
		# No editing path — finalize previous if it exists
		if _pt_editing_path != null and is_instance_valid(_pt_editing_path):
			if _pt_editing_path.has_meta("node_id") and _pt_editing_path.points.size() >= 2:
				var nid = str(_pt_editing_path.get_meta("node_id"))
				var cfg = _get_path_tool_config(_pt_editing_path)
				remove_shadow(_pt_editing_path)
				create_shadow(_pt_editing_path, cfg)
				save_shadow_data(_pt_editing_path, cfg)
				_all_known_path_ids[nid] = true
				_all_points_hashes[nid] = _get_points_hash(_pt_editing_path)
				# Schedule delayed rebuilds to catch transitions being set
				_pt_finalized_path = _pt_editing_path
				_pt_finalized_ticks = 0
				outputlog("Finalized shadow for path " + nid, 1)
		_pt_editing_path = null
		_pt_editing_hash = 0
		return

	if editing.points.size() < 2:
		return

	var new_hash = _get_points_hash(editing)

	# New path or points changed — update shadow
	if editing != _pt_editing_path or new_hash != _pt_editing_hash:
		# Finalize previous editing path if it changed
		if _pt_editing_path != null and _pt_editing_path != editing and is_instance_valid(_pt_editing_path):
			if _pt_editing_path.has_meta("node_id") and _pt_editing_path.points.size() >= 2:
				var prev_nid = str(_pt_editing_path.get_meta("node_id"))
				if not (global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(prev_nid)):
					var save_cfg = _get_path_tool_config(_pt_editing_path)
					save_shadow_data(_pt_editing_path, save_cfg)
					_all_known_path_ids[prev_nid] = true
			else:
				remove_shadow(_pt_editing_path)
		_pt_editing_path = editing
		_pt_editing_hash = new_hash
		remove_shadow(editing)
		var live_cfg = _get_path_tool_config(editing)
		create_shadow(editing, live_cfg)

var _scan_skip_ids := {}

func _on_monitor_tick():
	# Recapture realistic différée (radial/side/géométrie) au repos.
	_process_wall_r_session_settle()
	_process_wall_r_settle()
	# Détection des ops natives (move/reshape/delete) pour la timeline undo/redo.
	_detect_native_wall_ops()
	if not _native_detect_ready:
		_native_arm_count += 1
		if _native_arm_count >= 200:
			_native_detect_ready = true
	# Heal périodique : reconstruit les shadows manquantes (nœud réapparu via un
	# redo natif à géométrie identique, que le scan par hash ne détecte pas).
	_native_heal_count += 1
	if _native_heal_count >= 30:
		_native_heal_count = 0
		_history_force_resync()
	# Sync BelowAll container visibility with Walls node (for HideLayers compatibility)
	# and clean up orphan meshes from deleted walls
	var _cur_level = global.World.GetCurrentLevel()
	if _cur_level != null:
		var _ba = _cur_level.get_node_or_null(BELOW_ALL_CONTAINER_NAME)
		if _ba != null:
			var _walls = _cur_level.get_node_or_null("Walls")
			if _walls != null and _ba.visible != _walls.visible:
				_ba.visible = _walls.visible
			if _ba.get_child_count() > 0:
				_cleanup_below_all_orphans()

	# Process pending new nodes from OnAssignNode signal (split detection)
	if _pending_new_nodes.size() > 0:
		var nodes_to_process = _pending_new_nodes.duplicate()
		_pending_new_nodes.clear()
		for pending_node in nodes_to_process:
			if is_instance_valid(pending_node):
				_deferred_on_new_node_added(pending_node)

	# Real-time shadow drawing while using PathTool
	_update_path_tool_live_shadow()

	# Delayed rebuild for finalized paths (to pick up transitions set after finalization)
	if _pt_finalized_path != null and is_instance_valid(_pt_finalized_path):
		_pt_finalized_ticks += 1
		# Rebuild at tick 10, 30, 50 (0.1s, 0.3s, 0.5s) to catch transitions
		if _pt_finalized_ticks in [10, 30, 50]:
			var cfg = _get_path_tool_config(_pt_finalized_path)
			remove_shadow(_pt_finalized_path)
			create_shadow(_pt_finalized_path, cfg)
			if _pt_finalized_path.has_meta("node_id"):
				save_shadow_data(_pt_finalized_path, cfg)
		if _pt_finalized_ticks >= 50:
			_pt_finalized_path = null
			_pt_finalized_ticks = 0

	# Keep monitored path in sync with selection/editing for UI purposes
	var new_monitored = null
	_update_portal_ui()
	_update_portal_tool_freestanding_visibility()
	# Check SelectTool selection
	if global.Editor.Tools["SelectTool"].Selected.size() > 0:
		var node = global.Editor.Tools["SelectTool"].Selected[0]
		if is_shadow_node_type(node):
			new_monitored = node

	# Fallback: check PathTool editing path
	if new_monitored == null:
		var path_tool = global.Editor.Tools.get("PathTool")
		if path_tool != null:
			for prop in ["EditingPath", "editingPath", "SelectedPath"]:
				var edited = path_tool.get(prop)
				if edited != null and is_instance_valid(edited) and is_shadow_node_type(edited):
					new_monitored = edited
					break

	if new_monitored != null and new_monitored != _monitored_path:
		_reparent_ui_to_node(new_monitored)
		_monitored_path = new_monitored
		if new_monitored.has_meta("node_id"):
			var _rnid = str(new_monitored.get_meta("node_id"))
			_select_recency.erase(_rnid)
			_select_recency.push_front(_rnid)
			if _select_recency.size() > 8:
				_select_recency.pop_back()
		_monitored_type = get_node_type(new_monitored)
		_monitored_points_hash = _get_points_hash(new_monitored)
		_monitored_transitions_hash = _get_transitions_hash(new_monitored)
		load_shadow_ui_from_path(new_monitored)

	# Check monitored path for transition changes (UI update)
	if _monitored_path != null and is_instance_valid(_monitored_path):
		var new_th = _get_transitions_hash(_monitored_path)
		if new_th != _monitored_transitions_hash:
			_monitored_transitions_hash = new_th
			load_shadow_ui_from_path(_monitored_path)

	# Scan ALL paths with saved shadow data for point changes
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return

	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	for node_id in shadow_data.keys():
		# Perf: objects/roofs/paths share this "DropShadow" key but are never
		# walls. Cache ids known to be non-wall and skip them before the
		# HasNodeID/GetNodeByID/get_node_type cross-boundary C# calls, so a map
		# full of object shadows doesn't cost this scan every tick.
		if _scan_skip_ids.has(node_id):
			continue
		var config = shadow_data[node_id]
		if not config.get("enabled", false):
			continue
		if not global.World.HasNodeID(node_id):
			continue
		var scan_node = global.World.GetNodeByID(node_id)
		if not is_shadow_node_type(scan_node):
			_scan_skip_ids[node_id] = true
			continue

		# Capture realistic async en cours : ne pas reconstruire (le meta est
		# temporairement vide -> sinon rebuild en boucle qui annule la capture).
		if _wall_r_capturing.has(scan_node.get_instance_id()):
			continue

		var new_hash = _get_points_hash(scan_node)
		var old_hash = _all_points_hashes.get(node_id, 0)
		
		# Also check if shadow nodes were orphaned (e.g. parent Line2D was recreated)
		var shadow_orphaned = false
		if scan_node.has_meta(SHADOW_META_KEY):
			var snodes = scan_node.get_meta(SHADOW_META_KEY)
			if snodes is Array and snodes.size() > 0:
				for sn in snodes:
					if not is_instance_valid(sn):
						shadow_orphaned = true
						break
			elif snodes is Array and snodes.size() == 0:
				shadow_orphaned = true
		else:
			# Has saved data but no meta on node → shadow was never created or was lost
			shadow_orphaned = true
		
		if new_hash != old_hash or shadow_orphaned:
			_all_points_hashes[node_id] = new_hash
			# Detect newly added portals and apply keep_shadow override
			if get_node_type(scan_node) == "walls":
				_apply_override_to_new_portals(scan_node)
			# Clean extend for closed loops without skipped portals
			if is_path_closed(scan_node) and not _wall_has_skipped_portals(scan_node, config.get("skip_portals", false)):
				if config.get("extend_enabled", false) or config.get("fade_in_enabled", false) or config.get("fade_out_enabled", false):
					config["extend_enabled"] = false
					config["fade_in_enabled"] = false
					config["fade_out_enabled"] = false
					save_shadow_data(scan_node, config)
			if config.get("render_mode", "simple") == "realistic" and scan_node.has_meta(SHADOW_META_KEY) and not shadow_orphaned:
				# Déplacement/reshape d'un mur realistic : on REPOSITIONNE le sprite en
				# direct (suit le mur, texture actuelle) + re-bake la silhouette au repos.
				# Jamais de remove -> aucun flicker.
				_wall_r_follow_and_settle(scan_node, config)
			else:
				remove_shadow(scan_node)
				create_shadow(scan_node, config)
			# Also update monitored hash if it's the same path
			if scan_node == _monitored_path:
				_monitored_points_hash = new_hash

	# Detect copied paths: new paths with same points as existing shadow paths
	_detect_copied_shadow_paths()

	# Update wall point snapshot for split detection
	_update_wall_point_snapshot()

# Track which node_ids we've already checked for copies to avoid re-processing
var _known_node_ids = {}

func _detect_copied_shadow_paths():
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return

	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]

	# Check currently selected paths for ones without shadow config
	var selected = global.Editor.Tools["SelectTool"].Selected
	if selected.size() == 0:
		return

	for sel_node in selected:
		if not is_shadow_node_type(sel_node):
			continue
		# DD can't copy walls, skip them
		if get_node_type(sel_node) == "walls":
			continue
		var sel_id = str(sel_node.get_meta("node_id"))
		# Skip if already has shadow config
		if shadow_data.has(sel_id):
			continue
		# Skip if already checked
		if _known_node_ids.has(sel_id):
			continue
		_known_node_ids[sel_id] = true

		# Compute points hash and look for a match in existing shadow paths
		var sel_hash = _get_points_hash(sel_node)
		for src_id in shadow_data.keys():
			var src_config = shadow_data[src_id]
			if not src_config.get("enabled", false):
				continue
			if not global.World.HasNodeID(src_id):
				continue
			var src_node = global.World.GetNodeByID(src_id)
			if not is_shadow_node_type(src_node):
				continue
			var src_hash = _get_points_hash(src_node)
			if sel_hash == src_hash:
				# Match found - copy the config
				var new_config = src_config.duplicate()
				save_shadow_data(sel_node, new_config)
				remove_shadow(sel_node)
				create_shadow(sel_node, new_config)
				outputlog("Copied shadow config to pasted path " + sel_id, 1)
				break

#########################################################################################################
##
## UI BUILDING
##
#########################################################################################################

# Clipboard for copy/paste
var clipboard_config = null

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

func _make_section_header(parent: Control, section_title: String, section_key: String) -> VBoxContainer:
	# Creates a section with "Title [cog]" header and a hidden VBoxContainer for content
	var header = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = section_title
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)
	var toggle = _make_icon_button("icons/cog.png", "Show/hide " + section_title.to_lower(), 0.45)
	toggle.toggle_mode = true
	toggle.pressed = false
	toggle.connect("toggled", self, "_on_section_toggled", [section_key])
	header.add_child(toggle)
	parent.add_child(header)
	ui_config[section_key + "_header"] = header
	ui_config[section_key + "_toggle"] = toggle
	var content = VBoxContainer.new()
	content.visible = false
	parent.add_child(content)
	ui_config[section_key + "_content"] = content
	return content

func build_select_tool_ui():

	var select_panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	var wall_vbox = select_panel.wallOptions
	ui_config["_wall_parent"] = wall_vbox

	var container = VBoxContainer.new()
	container.name = "DropShadowWallsContainer"
	ui_config["container"] = container

	var separator = HSeparator.new()
	separator.add_constant_override("separation", 8)
	container.add_child(separator)

	# Title row: "Soft Shadow" [reset] [cog] [ON/OFF]
	var title_hbox = HBoxContainer.new()
	var sel_cloud = _create_cloud_icon()
	if sel_cloud != null:
		title_hbox.add_child(sel_cloud)
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

	# Render mode: Simple (mesh géométrique) | Realistic (silhouette texturée floutée)
	# Au-dessus du sélecteur de direction, comme dans le path tool. Masqué quand l'ombre est OFF.
	var mode_wrapper = VBoxContainer.new()
	mode_wrapper.visible = false
	var mode_btn_container = HBoxContainer.new()
	var mode_names = ["Simple", "Realistic"]
	for mi in range(2):
		var mbtn = Button.new()
		mbtn.text = " " + mode_names[mi]
		mbtn.toggle_mode = true
		mbtn.pressed = (mi == _render_mode_to_index(DEFAULT_SHADOW_CONFIG.get("render_mode", "simple")))
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.align = Button.ALIGN_LEFT
		if mbtn.pressed:
			mbtn.icon = mbtn.get_icon("radio_checked", "CheckBox")
		else:
			mbtn.icon = mbtn.get_icon("radio_unchecked", "CheckBox")
		mbtn.connect("pressed", self, "_on_wall_render_mode_pressed", [mi])
		mode_btn_container.add_child(mbtn)
		ui_config["mode_btn_" + str(mi)] = mbtn
	mode_wrapper.add_child(mode_btn_container)
	container.add_child(mode_wrapper)
	ui_config["mode_wrapper"] = mode_wrapper

	# Direction buttons - hidden when shadow is OFF
	var dir_wrapper = VBoxContainer.new()
	dir_wrapper.visible = false
	var dir_btn_container = HBoxContainer.new()
	var dir_names = ["Side A", "Side B", "Both"]
	for i in range(3):
		var btn = Button.new()
		btn.text = " " + dir_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == DEFAULT_SHADOW_CONFIG["direction"])
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_LEFT
		btn.connect("pressed", self, "_on_direction_pressed", [i])
		dir_btn_container.add_child(btn)
		ui_config["dir_btn_" + str(i)] = btn
	dir_wrapper.add_child(dir_btn_container)
	container.add_child(dir_wrapper)
	ui_config["dir_wrapper"] = dir_wrapper

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
	opacity_slider.step = 0.05
	opacity_slider.value = DEFAULT_SHADOW_CONFIG["opacity"]
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	opacity_slider.connect("value_changed", self, "_on_slider_changed", ["opacity"])
	opacity_hbox.add_child(opacity_slider)
	ui_config["opacity_slider"] = opacity_slider
	var opacity_spin = SpinBox.new()
	opacity_spin.min_value = 0.05
	opacity_spin.max_value = 1.0
	opacity_spin.step = 0.05
	opacity_spin.value = DEFAULT_SHADOW_CONFIG["opacity"]
	opacity_spin.connect("value_changed", self, "_on_spin_changed", ["opacity"])
	opacity_hbox.add_child(opacity_spin)
	ui_config["opacity_spin"] = opacity_spin
	var opacity_reset = _make_icon_button("icons/reset.png", "Reset opacity", 0.5)
	opacity_reset.connect("pressed", self, "_on_single_reset", ["opacity"])
	opacity_hbox.add_child(opacity_reset)
	settings_panel.add_child(opacity_hbox)

	# -- Spread: [Label] [Slider] [SpinBox] [Reset] --
	var spread_hbox = HBoxContainer.new()
	var spread_label = Label.new()
	spread_label.text = "Spread"
	spread_label.rect_min_size.x = 60
	spread_hbox.add_child(spread_label)
	var spread_slider = HSlider.new()
	spread_slider.min_value = 0.0
	spread_slider.max_value = 3.0
	spread_slider.step = 0.05
	spread_slider.value = DEFAULT_SHADOW_CONFIG["spread"]
	spread_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spread_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spread_slider.connect("value_changed", self, "_on_slider_changed", ["spread"])
	spread_hbox.add_child(spread_slider)
	ui_config["spread_slider"] = spread_slider
	var spread_spin = SpinBox.new()
	spread_spin.min_value = 0.0
	spread_spin.max_value = 3.0
	spread_spin.step = 0.05
	spread_spin.value = DEFAULT_SHADOW_CONFIG["spread"]
	spread_spin.connect("value_changed", self, "_on_spin_changed", ["spread"])
	spread_hbox.add_child(spread_spin)
	ui_config["spread_spin"] = spread_spin
	var spread_reset = _make_icon_button("icons/reset.png", "Reset spread", 0.5)
	spread_reset.connect("pressed", self, "_on_single_reset", ["spread"])
	spread_hbox.add_child(spread_reset)
	ui_config["spread_hbox"] = spread_hbox
	settings_panel.add_child(spread_hbox)

	# -- Softness: [Label] [Slider] [SpinBox] [Reset] --
	var soft_hbox = HBoxContainer.new()
	var soft_label = Label.new()
	soft_label.text = "Softness"
	soft_label.rect_min_size.x = 60
	soft_hbox.add_child(soft_label)
	var soft_slider = HSlider.new()
	soft_slider.min_value = 0.1
	soft_slider.max_value = 5.0
	soft_slider.step = 0.05
	soft_slider.value = DEFAULT_SHADOW_CONFIG["softness"]
	soft_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	soft_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	soft_slider.connect("value_changed", self, "_on_slider_changed", ["softness"])
	soft_hbox.add_child(soft_slider)
	ui_config["softness_slider"] = soft_slider
	var soft_spin = SpinBox.new()
	soft_spin.min_value = 0.1
	soft_spin.max_value = 5.0
	soft_spin.step = 0.05
	soft_spin.value = DEFAULT_SHADOW_CONFIG["softness"]
	soft_spin.connect("value_changed", self, "_on_spin_changed", ["softness"])
	soft_hbox.add_child(soft_spin)
	ui_config["softness_spin"] = soft_spin
	var soft_reset = _make_icon_button("icons/reset.png", "Reset softness", 0.5)
	soft_reset.connect("pressed", self, "_on_single_reset", ["softness"])
	soft_hbox.add_child(soft_reset)
	ui_config["softness_hbox"] = soft_hbox
	settings_panel.add_child(soft_hbox)

	# -- Blur (mode Realistic uniquement) : [Label] [Slider] --
	var blur_hbox = HBoxContainer.new()
	blur_hbox.visible = false
	var blur_label = Label.new()
	blur_label.text = "Blur"
	blur_label.rect_min_size.x = 60
	blur_hbox.add_child(blur_label)
	var blur_slider = HSlider.new()
	blur_slider.min_value = 0.0
	blur_slider.max_value = 1.0
	blur_slider.step = 0.01
	blur_slider.value = DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2)
	blur_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blur_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blur_slider.connect("value_changed", self, "_on_slider_changed", ["realistic_blur"])
	blur_hbox.add_child(blur_slider)
	ui_config["realistic_blur_slider"] = blur_slider
	ui_config["realistic_blur_hbox"] = blur_hbox
	settings_panel.add_child(blur_hbox)
	# Crop Blur : visible en Side A/B, restreint le flou au côté choisi.
	var crop_hbox = HBoxContainer.new()
	crop_hbox.visible = false
	var crop_label = Label.new()
	crop_label.text = "Crop at Center"
	crop_label.rect_min_size.x = 60
	crop_hbox.add_child(crop_label)
	var crop_spacer = Control.new()
	crop_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crop_hbox.add_child(crop_spacer)
	var crop_check = CheckButton.new()
	crop_check.pressed = DEFAULT_SHADOW_CONFIG.get("crop_blur", false)
	crop_check.connect("toggled", self, "_on_crop_blur_toggled")
	crop_hbox.add_child(crop_check)
	ui_config["crop_blur_check"] = crop_check
	ui_config["crop_blur_hbox"] = crop_hbox
	settings_panel.add_child(crop_hbox)
	# Crop Ends : visible en Realistic (toute direction), coupe le flou au dernier
	# pixel de l'endcap à chaque extrémité du mur. Indépendant de Crop Blur.
	var cends_hbox = HBoxContainer.new()
	cends_hbox.visible = false
	var cends_label = Label.new()
	cends_label.text = "Crop Ends"
	cends_label.rect_min_size.x = 60
	cends_hbox.add_child(cends_label)
	var cends_spacer = Control.new()
	cends_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cends_hbox.add_child(cends_spacer)
	var cends_check = CheckButton.new()
	cends_check.pressed = DEFAULT_SHADOW_CONFIG.get("crop_ends", false)
	cends_check.connect("toggled", self, "_on_crop_ends_toggled")
	cends_hbox.add_child(cends_check)
	ui_config["crop_ends_check"] = cends_check
	ui_config["crop_ends_hbox"] = cends_hbox
	settings_panel.add_child(cends_hbox)

	# -- Extend Ends with Fade: toggle row + distance slider --
	# The toggle row (ext_hbox) starts in dir_wrapper (main area)
	# and moves to extend_section (settings_panel) when cog is open
	var ext_hbox = HBoxContainer.new()
	var ext_label = Label.new()
	ext_label.text = "Extend Ends with Fade"
	ext_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ext_hbox.add_child(ext_label)
	var ext_check = CheckButton.new()
	ext_check.pressed = false
	ext_check.connect("toggled", self, "_on_extend_toggled")
	ext_hbox.add_child(ext_check)
	ui_config["extend_check"] = ext_check
	ui_config["ext_hbox"] = ext_hbox

	# Add toggle to dir_wrapper initially (visible when shadow ON, cog closed)
	dir_wrapper.add_child(ext_hbox)

	# Distance slider lives in extend_section inside settings_panel
	var extend_section = VBoxContainer.new()
	extend_section.name = "ExtendFadeSection"
	var ext_sep = HSeparator.new()
	ext_sep.add_constant_override("separation", 2)
	extend_section.add_child(ext_sep)

	# Extend Which: Start / End / Both buttons
	var ext_which_container = HBoxContainer.new()
	ext_which_container.visible = false
	var ext_which_names = ["Start", "End", "Both"]
	for i in range(3):
		var btn = Button.new()
		btn.text = " " + ext_which_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == DEFAULT_SHADOW_CONFIG["extend_which"])
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_LEFT
		btn.connect("pressed", self, "_on_extend_which_pressed", [i])
		ext_which_container.add_child(btn)
		ui_config["ext_which_btn_" + str(i)] = btn
	extend_section.add_child(ext_which_container)
	ui_config["ext_which_container"] = ext_which_container

	# Shape: [Label] [Slider] [SpinBox] [Reset] — controls cap shape (-1..+1, 0=semicircle)
	var fd_container = VBoxContainer.new()
	fd_container.visible = false
	var fd_hbox = HBoxContainer.new()
	var fd_label = Label.new()
	fd_label.text = "Shape"
	fd_label.rect_min_size.x = 60
	fd_hbox.add_child(fd_label)
	var fd_slider = HSlider.new()
	fd_slider.min_value = -1.0
	fd_slider.max_value = 1.0
	fd_slider.step = 0.05
	fd_slider.value = DEFAULT_SHADOW_CONFIG["fade_extend"]
	fd_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fd_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fd_slider.connect("value_changed", self, "_on_slider_changed", ["fade_extend"])
	fd_hbox.add_child(fd_slider)
	ui_config["fade_extend_slider"] = fd_slider
	var fd_spin = SpinBox.new()
	fd_spin.min_value = -1.0
	fd_spin.max_value = 1.0
	fd_spin.step = 0.05
	fd_spin.value = DEFAULT_SHADOW_CONFIG["fade_extend"]
	fd_spin.connect("value_changed", self, "_on_spin_changed", ["fade_extend"])
	fd_hbox.add_child(fd_spin)
	ui_config["fade_extend_spin"] = fd_spin
	var fd_reset = _make_icon_button("icons/reset.png", "Reset", 0.5)
	fd_reset.connect("pressed", self, "_on_single_reset", ["fade_extend"])
	fd_hbox.add_child(fd_reset)
	fd_container.add_child(fd_hbox)
	extend_section.add_child(fd_container)
	ui_config["fade_extend_container"] = fd_container

	ui_config["extend_section"] = extend_section

	# -- Skip Portals: walls only toggle, outside extend_section so it stays visible for loops --
	var skip_portals_hbox = HBoxContainer.new()
	var skip_portals_label = Label.new()
	skip_portals_label.text = "Skip Portals"
	skip_portals_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skip_portals_hbox.add_child(skip_portals_label)
	var skip_portals_check = CheckButton.new()
	skip_portals_check.pressed = false
	skip_portals_check.connect("toggled", self, "_on_skip_portals_toggled")
	skip_portals_hbox.add_child(skip_portals_check)
	ui_config["skip_portals_check"] = skip_portals_check
	ui_config["skip_portals_hbox"] = skip_portals_hbox
	settings_panel.add_child(skip_portals_hbox)

	# -- Below All Walls: toggle to render shadow below every wall, not just its own --
	var below_all_hbox = HBoxContainer.new()
	var below_all_label = Label.new()
	below_all_label.text = "Below All Walls"
	below_all_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	below_all_hbox.add_child(below_all_label)
	var below_all_check = CheckButton.new()
	below_all_check.pressed = false
	below_all_check.hint_tooltip = "Render this shadow behind every wall, not just its own"
	below_all_check.connect("toggled", self, "_on_below_all_walls_toggled")
	below_all_hbox.add_child(below_all_check)
	ui_config["below_all_walls_check"] = below_all_check
	ui_config["below_all_walls_hbox"] = below_all_hbox
	settings_panel.add_child(below_all_hbox)

	# Extend section placed after Below All Walls
	settings_panel.add_child(extend_section)

	# === Transitions section (collapsible) ===
	var trans_sep = HSeparator.new()
	trans_sep.add_constant_override("separation", 4)
	settings_panel.add_child(trans_sep)
	ui_config["sec_transitions_sep"] = trans_sep
	var trans_content = _make_section_header(settings_panel, "Transitions", "sec_transitions")
	ui_config["trans_content"] = trans_content

	# -- Fade In: [Label] [Slider] [SpinBox] [Reset] [Check] --
	var fi_hbox = HBoxContainer.new()
	var fi_label = Label.new()
	fi_label.text = "Fade In"
	fi_label.rect_min_size.x = 60
	fi_hbox.add_child(fi_label)
	fi_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fi_s_slider = HSlider.new()
	fi_s_slider.min_value = 1.0
	fi_s_slider.max_value = 20.0
	fi_s_slider.step = 0.5
	fi_s_slider.value = DEFAULT_SHADOW_CONFIG["fade_in_strength"]
	fi_s_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fi_s_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fi_s_slider.connect("value_changed", self, "_on_slider_changed", ["fade_in_strength"])
	fi_hbox.add_child(fi_s_slider)
	ui_config["fade_in_strength_slider"] = fi_s_slider
	var fi_s_spin = SpinBox.new()
	fi_s_spin.min_value = 1.0
	fi_s_spin.max_value = 20.0
	fi_s_spin.step = 0.5
	fi_s_spin.value = DEFAULT_SHADOW_CONFIG["fade_in_strength"]
	fi_s_spin.connect("value_changed", self, "_on_spin_changed", ["fade_in_strength"])
	fi_hbox.add_child(fi_s_spin)
	ui_config["fade_in_strength_spin"] = fi_s_spin
	var fi_s_reset = _make_icon_button("icons/reset.png", "Reset", 0.5)
	fi_s_reset.connect("pressed", self, "_on_single_reset", ["fade_in_strength"])
	fi_hbox.add_child(fi_s_reset)
	ui_config["fade_in_strength_reset"] = fi_s_reset
	var fi_check = CheckButton.new()
	fi_check.pressed = false
	fi_check.size_flags_horizontal = Control.SIZE_SHRINK_END
	fi_check.connect("toggled", self, "_on_transition_toggled", ["fade_in"])
	fi_hbox.add_child(fi_check)
	ui_config["fade_in_check"] = fi_check
	trans_content.add_child(fi_hbox)
	ui_config["fade_in_hbox"] = fi_hbox

	# -- Fade Out: [Label] [Slider] [SpinBox] [Reset] [Check] --
	var fo_hbox = HBoxContainer.new()
	var fo_label = Label.new()
	fo_label.text = "Fade Out"
	fo_label.rect_min_size.x = 60
	fo_hbox.add_child(fo_label)
	fo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fo_s_slider = HSlider.new()
	fo_s_slider.min_value = 1.0
	fo_s_slider.max_value = 20.0
	fo_s_slider.step = 0.5
	fo_s_slider.value = DEFAULT_SHADOW_CONFIG["fade_out_strength"]
	fo_s_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fo_s_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fo_s_slider.connect("value_changed", self, "_on_slider_changed", ["fade_out_strength"])
	fo_hbox.add_child(fo_s_slider)
	ui_config["fade_out_strength_slider"] = fo_s_slider
	var fo_s_spin = SpinBox.new()
	fo_s_spin.min_value = 1.0
	fo_s_spin.max_value = 20.0
	fo_s_spin.step = 0.5
	fo_s_spin.value = DEFAULT_SHADOW_CONFIG["fade_out_strength"]
	fo_s_spin.connect("value_changed", self, "_on_spin_changed", ["fade_out_strength"])
	fo_hbox.add_child(fo_s_spin)
	ui_config["fade_out_strength_spin"] = fo_s_spin
	var fo_s_reset = _make_icon_button("icons/reset.png", "Reset", 0.5)
	fo_s_reset.connect("pressed", self, "_on_single_reset", ["fade_out_strength"])
	fo_hbox.add_child(fo_s_reset)
	ui_config["fade_out_strength_reset"] = fo_s_reset
	var fo_check = CheckButton.new()
	fo_check.pressed = false
	fo_check.size_flags_horizontal = Control.SIZE_SHRINK_END
	fo_check.connect("toggled", self, "_on_transition_toggled", ["fade_out"])
	fo_hbox.add_child(fo_check)
	ui_config["fade_out_check"] = fo_check
	trans_content.add_child(fo_hbox)
	ui_config["fade_out_hbox"] = fo_hbox

	# -- Grow: [Label] [Slider] [SpinBox] [Reset] [Check] --
	var gr_hbox = HBoxContainer.new()
	var gr_label = Label.new()
	gr_label.text = "Grow"
	gr_label.rect_min_size.x = 60
	gr_hbox.add_child(gr_label)
	gr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var gr_s_slider = HSlider.new()
	gr_s_slider.min_value = 0.05
	gr_s_slider.max_value = 1.0
	gr_s_slider.step = 0.05
	gr_s_slider.value = DEFAULT_SHADOW_CONFIG["grow_length"]
	gr_s_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gr_s_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gr_s_slider.connect("value_changed", self, "_on_slider_changed", ["grow_length"])
	gr_hbox.add_child(gr_s_slider)
	ui_config["grow_length_slider"] = gr_s_slider
	var gr_s_spin = SpinBox.new()
	gr_s_spin.min_value = 0.05
	gr_s_spin.max_value = 1.0
	gr_s_spin.step = 0.05
	gr_s_spin.value = DEFAULT_SHADOW_CONFIG["grow_length"]
	gr_s_spin.connect("value_changed", self, "_on_spin_changed", ["grow_length"])
	gr_hbox.add_child(gr_s_spin)
	ui_config["grow_length_spin"] = gr_s_spin
	var gr_s_reset = _make_icon_button("icons/reset.png", "Reset", 0.5)
	gr_s_reset.connect("pressed", self, "_on_single_reset", ["grow_length"])
	gr_hbox.add_child(gr_s_reset)
	ui_config["grow_length_reset"] = gr_s_reset
	var gr_check = CheckButton.new()
	gr_check.pressed = false
	gr_check.size_flags_horizontal = Control.SIZE_SHRINK_END
	gr_check.connect("toggled", self, "_on_transition_toggled", ["grow"])
	gr_hbox.add_child(gr_check)
	ui_config["grow_check"] = gr_check
	trans_content.add_child(gr_hbox)
	ui_config["grow_hbox"] = gr_hbox

	# -- Shrink: [Label] [Slider] [SpinBox] [Reset] [Check] --
	var sh_hbox = HBoxContainer.new()
	var sh_label = Label.new()
	sh_label.text = "Shrink"
	sh_label.rect_min_size.x = 60
	sh_hbox.add_child(sh_label)
	sh_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sh_s_slider = HSlider.new()
	sh_s_slider.min_value = 0.05
	sh_s_slider.max_value = 1.0
	sh_s_slider.step = 0.05
	sh_s_slider.value = DEFAULT_SHADOW_CONFIG["shrink_length"]
	sh_s_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh_s_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sh_s_slider.connect("value_changed", self, "_on_slider_changed", ["shrink_length"])
	sh_hbox.add_child(sh_s_slider)
	ui_config["shrink_length_slider"] = sh_s_slider
	var sh_s_spin = SpinBox.new()
	sh_s_spin.min_value = 0.05
	sh_s_spin.max_value = 1.0
	sh_s_spin.step = 0.05
	sh_s_spin.value = DEFAULT_SHADOW_CONFIG["shrink_length"]
	sh_s_spin.connect("value_changed", self, "_on_spin_changed", ["shrink_length"])
	sh_hbox.add_child(sh_s_spin)
	ui_config["shrink_length_spin"] = sh_s_spin
	var sh_s_reset = _make_icon_button("icons/reset.png", "Reset", 0.5)
	sh_s_reset.connect("pressed", self, "_on_single_reset", ["shrink_length"])
	sh_hbox.add_child(sh_s_reset)
	ui_config["shrink_length_reset"] = sh_s_reset
	var sh_check = CheckButton.new()
	sh_check.pressed = false
	sh_check.size_flags_horizontal = Control.SIZE_SHRINK_END
	sh_check.connect("toggled", self, "_on_transition_toggled", ["shrink"])
	sh_hbox.add_child(sh_check)
	ui_config["shrink_check"] = sh_check
	trans_content.add_child(sh_hbox)
	ui_config["shrink_hbox"] = sh_hbox

	# -- Swap Ends toggle (paths only, inside transitions) --
	var swap_sep = HSeparator.new()
	swap_sep.add_constant_override("separation", 2)
	trans_content.add_child(swap_sep)
	ui_config["swap_sep"] = swap_sep
	var swap_hbox = HBoxContainer.new()
	var swap_label = Label.new()
	swap_label.text = "Swap Ends"
	swap_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	swap_hbox.add_child(swap_label)
	var swap_check = CheckButton.new()
	swap_check.pressed = false
	swap_check.connect("toggled", self, "_on_swap_ends_toggled")
	swap_hbox.add_child(swap_check)
	trans_content.add_child(swap_hbox)
	ui_config["swap_ends_check"] = swap_check
	ui_config["swap_hbox"] = swap_hbox

	# === Offset section (collapsible) ===
	var off_sep = HSeparator.new()
	off_sep.add_constant_override("separation", 4)
	settings_panel.add_child(off_sep)
	var off_content = _make_section_header(settings_panel, "Offset", "sec_offset")

	# -- Offset: Circular Dial (Distance + Angle) --
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
	# Hidden internal spins for offset_x / offset_y (not displayed, used by config)
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
	off_content.add_child(offset_vbox)

	# -- Max Distance: [Label] [Slider] [SpinBox] [Reset] --
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
	off_content.add_child(dist_hbox)

	# === Radial Offset section ===
	var radial_hbox = HBoxContainer.new()
	var radial_label = Label.new()
	radial_label.text = "Radial Offset"
	radial_label.rect_min_size.x = 85
	radial_hbox.add_child(radial_label)
	var radial_slider = HSlider.new()
	radial_slider.min_value = -100.0
	radial_slider.max_value = 100.0
	radial_slider.step = 1.0
	radial_slider.value = DEFAULT_SHADOW_CONFIG["radial_offset"]
	radial_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	radial_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	radial_slider.connect("value_changed", self, "_on_slider_changed", ["radial_offset"])
	radial_hbox.add_child(radial_slider)
	ui_config["radial_offset_slider"] = radial_slider
	var radial_spin = SpinBox.new()
	radial_spin.min_value = -100.0
	radial_spin.max_value = 100.0
	radial_spin.step = 1.0
	radial_spin.value = DEFAULT_SHADOW_CONFIG["radial_offset"]
	radial_spin.connect("value_changed", self, "_on_spin_changed", ["radial_offset"])
	radial_hbox.add_child(radial_spin)
	ui_config["radial_offset_spin"] = radial_spin
	var radial_reset = _make_icon_button("icons/reset.png", "Reset radial offset", 0.5)
	radial_reset.connect("pressed", self, "_on_single_reset", ["radial_offset"])
	radial_hbox.add_child(radial_reset)
	off_content.add_child(radial_hbox)

	# === Side Balance section (asymmetric BOTH-only feature) ===
	# Hidden unless direction == BOTH. At 0 the shadow is symmetric.
	# Positive values shrink Side A (OUTER); negative shrink Side B (INNER).
	var sb_hbox = HBoxContainer.new()
	var sb_label = Label.new()
	sb_label.text = "Side Balance"
	sb_label.rect_min_size.x = 85
	sb_label.hint_tooltip = "0 = symmetric. +N shrinks OUTER side, −N shrinks INNER side (only affects spread + softness; only visible when direction is BOTH)."
	sb_hbox.add_child(sb_label)
	var sb_slider = HSlider.new()
	sb_slider.min_value = -100.0
	sb_slider.max_value = 100.0
	sb_slider.step = 1.0
	sb_slider.value = DEFAULT_SHADOW_CONFIG["side_balance"]
	sb_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sb_slider.connect("value_changed", self, "_on_slider_changed", ["side_balance"])
	sb_hbox.add_child(sb_slider)
	ui_config["side_balance_slider"] = sb_slider
	var sb_spin = SpinBox.new()
	sb_spin.min_value = -100.0
	sb_spin.max_value = 100.0
	sb_spin.step = 1.0
	sb_spin.value = DEFAULT_SHADOW_CONFIG["side_balance"]
	sb_spin.connect("value_changed", self, "_on_spin_changed", ["side_balance"])
	sb_hbox.add_child(sb_spin)
	ui_config["side_balance_spin"] = sb_spin
	var sb_reset = _make_icon_button("icons/reset.png", "Reset side balance", 0.5)
	sb_reset.connect("pressed", self, "_on_single_reset", ["side_balance"])
	sb_hbox.add_child(sb_reset)
	sb_hbox.visible = false  # only shown in BOTH direction (set by _set_direction_buttons)
	ui_config["side_balance_hbox"] = sb_hbox
	off_content.add_child(sb_hbox)

	# === Color section ===
	var color_sep = HSeparator.new()
	color_sep.add_constant_override("separation", 4)
	settings_panel.add_child(color_sep)
	var color_hbox = HBoxContainer.new()
	var color_label = Label.new()
	color_label.text = "Shadow Color"
	color_label.rect_min_size.x = 60
	color_hbox.add_child(color_label)
	var color_picker = ColorPickerButton.new()
	color_picker.color = DEFAULT_SHADOW_CONFIG["shadow_color"]
	color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_picker.rect_min_size.y = 24
	color_picker.connect("color_changed", self, "_on_color_changed")
	color_hbox.add_child(color_picker)
	ui_config["shadow_color_picker"] = color_picker
	# Disable the screen pick (eyedropper) button to prevent a Godot engine crash
	# that occurs when the scene tree is large (3+ mods loaded)
	call_deferred("_disable_screen_picker", color_picker)
	var color_reset = _make_icon_button("icons/reset.png", "Reset color", 0.5)
	color_reset.connect("pressed", self, "_on_single_reset", ["shadow_color"])
	color_hbox.add_child(color_reset)
	settings_panel.add_child(color_hbox)

	# === Defaults section ===
	var defaults_sep = HSeparator.new()
	defaults_sep.add_constant_override("separation", 4)
	settings_panel.add_child(defaults_sep)
	var def_hbox = HBoxContainer.new()
	var save_default_btn = Button.new()
	save_default_btn.text = "Use as Default Values"
	save_default_btn.hint_tooltip = "Save current settings as default for new shadows"
	save_default_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_default_btn.connect("pressed", self, "_on_save_default_pressed")
	def_hbox.add_child(save_default_btn)
	var reset_default_btn = Button.new()
	reset_default_btn.text = "Factory Reset"
	reset_default_btn.hint_tooltip = "Restore factory default settings"
	reset_default_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_default_btn.visible = false
	reset_default_btn.connect("pressed", self, "_on_reset_default_pressed")
	def_hbox.add_child(reset_default_btn)
	ui_config["reset_default_btn"] = reset_default_btn
	settings_panel.add_child(def_hbox)

	# === Action buttons: Shadow Reset / Copy / Paste ===
	var actions_sep = HSeparator.new()
	actions_sep.add_constant_override("separation", 4)
	settings_panel.add_child(actions_sep)
	var actions_hbox = HBoxContainer.new()
	var actions_label = Label.new()
	actions_label.text = "Shadow"
	actions_hbox.add_child(actions_label)
	var reset_btn = _make_icon_button("icons/reset.png", "Reset to defaults", 0.65)
	reset_btn.text = " Reset"
	reset_btn.connect("pressed", self, "_on_reset_pressed")
	actions_hbox.add_child(reset_btn)
	ui_config["reset_button"] = reset_btn
	var copy_btn = _make_icon_button("icons/copy.png", "Copy shadow settings", 0.65)
	copy_btn.text = " Copy"
	copy_btn.connect("pressed", self, "_on_copy_pressed")
	actions_hbox.add_child(copy_btn)
	ui_config["copy_button"] = copy_btn
	var paste_btn = _make_icon_button("icons/paste.png", "Paste shadow settings", 0.65)
	paste_btn.text = " Paste"
	paste_btn.connect("pressed", self, "_on_paste_pressed")
	actions_hbox.add_child(paste_btn)
	ui_config["paste_button"] = paste_btn
	settings_panel.add_child(actions_hbox)

	# === Apply to All button ===
	var apply_all_btn = Button.new()
	apply_all_btn.text = "Apply Shadow to all Walls"
	apply_all_btn.hint_tooltip = "Apply current shadow settings to all walls on this level"
	apply_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_all_btn.connect("pressed", self, "_on_apply_all_pressed")
	settings_panel.add_child(apply_all_btn)
	ui_config["apply_all_btn"] = apply_all_btn
	# Apply-all dialog
	var apply_dialog = AcceptDialog.new()
	apply_dialog.window_title = "Apply Shadow"
	apply_dialog.get_ok().text = "Every wall"
	apply_dialog.get_ok().connect("pressed", self, "_on_apply_all_confirmed", ["all"])
	apply_dialog.add_button("Every wall with no shadow", false, "no_shadow")
	var selected_btn = apply_dialog.add_button("Selected walls", false, "selected")
	apply_dialog.add_cancel("Cancel")
	apply_dialog.connect("custom_action", self, "_on_apply_all_confirmed")

	# Build inner layout: question label (walls have a single layer, no layer scope needed)
	var dialog_vbox = VBoxContainer.new()
	dialog_vbox.add_constant_override("separation", 10)
	var question_label = Label.new()
	question_label.text = "Which walls do you want to apply this shadow on?"
	question_label.align = Label.ALIGN_CENTER
	dialog_vbox.add_child(question_label)
	apply_dialog.add_child(dialog_vbox)

	var windows_container = global.Editor.get_node("Windows")
	if windows_container != null:
		windows_container.add_child(apply_dialog)
	else:
		global.Editor.add_child(apply_dialog)
	ui_config["apply_all_dialog"] = apply_dialog

	# Deferred styling: hide the empty built-in AcceptDialog label
	var dialog_style_timer = Timer.new()
	dialog_style_timer.wait_time = 0.1
	dialog_style_timer.one_shot = true
	dialog_style_timer.connect("timeout", self, "_style_apply_dialog", [dialog_style_timer])
	global.Editor.add_child(dialog_style_timer)
	dialog_style_timer.start()

	container.add_child(settings_panel)
	ui_config["settings_panel"] = settings_panel

	var end_sep = HSeparator.new()
	end_sep.add_constant_override("separation", 8)
	container.add_child(end_sep)

	# Insert at top so shadow section appears above other mods
	wall_vbox.add_child(container)
	wall_vbox.move_child(container, 0)
	ui_config["container"] = container

	# Set initial radio icons
	_set_direction_buttons(DEFAULT_SHADOW_CONFIG["direction"])
	_build_portal_ui(select_panel)

#########################################################################################################
##
## UI CALLBACKS
##
#########################################################################################################

var _syncing_ui = false
# Tracks which config properties the user has manually changed since the UI was
# last loaded from a path. Used for multi-selection: only these properties are
# propagated to non-monitored paths that already have saved configs.
var _dirty_properties = {}

func _on_slider_changed(value, which):
	if _syncing_ui:
		return
	_dirty_properties[which] = true
	_wall_last_changed = which
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_spin"].value = value
		"spread":
			ui_config["spread_spin"].value = value
		"softness":
			ui_config["softness_spin"].value = value
		"range":
			ui_config["range_spin"].value = value
			_update_offset_range(value)
		"fade_in_strength":
			ui_config["fade_in_strength_spin"].value = value
		"fade_out_strength":
			ui_config["fade_out_strength_spin"].value = value
		"grow_length":
			ui_config["grow_length_spin"].value = value
		"shrink_length":
			ui_config["shrink_length_spin"].value = value
		"fade_extend":
			ui_config["fade_extend_spin"].value = value
		"radial_offset":
			ui_config["radial_offset_spin"].value = value
		"side_balance":
			ui_config["side_balance_spin"].value = value
	_syncing_ui = false
	apply_shadow_to_selected_paths()

func _on_spin_changed(value, which):
	if _syncing_ui:
		return
	_dirty_properties[which] = true
	_wall_last_changed = which
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_slider"].value = value
		"spread":
			ui_config["spread_slider"].value = value
		"softness":
			ui_config["softness_slider"].value = value
		"range":
			ui_config["range_slider"].value = value
			_update_offset_range(value)
		"fade_in_strength":
			ui_config["fade_in_strength_slider"].value = value
		"fade_out_strength":
			ui_config["fade_out_strength_slider"].value = value
		"grow_length":
			ui_config["grow_length_slider"].value = value
		"shrink_length":
			ui_config["shrink_length_slider"].value = value
		"fade_extend":
			ui_config["fade_extend_slider"].value = value
		"radial_offset":
			ui_config["radial_offset_slider"].value = value
		"side_balance":
			ui_config["side_balance_slider"].value = value
	_syncing_ui = false
	apply_shadow_to_selected_paths()

# Non-linear offset dial: distance maps via quadratic for fine control near center
const OFFSET_MAX = 100.0

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

func _create_dial(dial_size: int, max_offset: float) -> Control:
	var dial = Control.new()
	dial.name = "OffsetDial"
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)
	var bg = _make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	var bg_sprite = TextureRect.new()
	bg_sprite.texture = bg
	bg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_sprite)
	for ring_frac in [0.25, 0.5, 0.75]:
		var ring_size = int(dial_size * ring_frac)
		var ring_tex = _make_ring_texture(ring_size, Color(0.22, 0.22, 0.22, 1.0))
		var ring_rect = TextureRect.new()
		ring_rect.texture = ring_tex
		ring_rect.rect_position = Vector2((dial_size - ring_size) / 2.0, (dial_size - ring_size) / 2.0)
		ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring_rect)
	for diag_angle in [45.0, 135.0, 225.0, 315.0]:
		var diag_rad = deg2rad(diag_angle)
		var dx = cos(diag_rad)
		var dy = sin(diag_rad)
		var line_len = dial_size / 2.0 - 2.0
		for s in range(4, int(line_len), 3):
			var px = dial_size / 2.0 + dx * s
			var py = dial_size / 2.0 + dy * s
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(px, py)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)
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
	var snap_btn_size = 12
	var snap_inactive_color = Color(0.3, 0.3, 0.3, 0.8)
	var snap_active_color = Color(0.353, 0.698, 1.0, 1.0)
	var snap_positions = {
		"snap_315": Vector2(dial_size - 8, -4),
		"snap_45":  Vector2(dial_size - 8, dial_size - 8),
		"snap_135": Vector2(-4, dial_size - 8),
		"snap_225": Vector2(-4, -4)
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
	dial.set_meta("snap_angle", -1.0)
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_dial_input", [dial])
	ui_config["dial"] = dial
	ui_config["dial_dot"] = dot
	return dial

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
	var delta = pos - center
	var dist_from_center = delta.length()
	if dist_from_center > radius:
		delta = delta.normalized() * radius
		dist_from_center = radius
	var frac = dist_from_center / radius
	var nonlinear_frac = frac * frac
	var direction = delta.normalized() if dist_from_center > 0.5 else Vector2.ZERO
	var snap_angle = dial.get_meta("snap_angle") as float
	if snap_angle >= 0.0:
		var snap_rad = deg2rad(snap_angle)
		var snap_dir = Vector2(cos(snap_rad), sin(snap_rad))
		var projection = delta.dot(snap_dir)
		if projection <= 0.0:
			_set_dial_values(0, 0)
			apply_shadow_to_selected_paths()
			return
		var projected_dist = min(projection, radius)
		frac = projected_dist / radius
		nonlinear_frac = frac * frac
		direction = snap_dir
	var ox = round(-direction.x * nonlinear_frac * max_offset)
	var oy = round(-direction.y * nonlinear_frac * max_offset)
	_set_dial_values(ox, oy)
	apply_shadow_to_selected_paths()

func _on_snap_toggled(pressed: bool, key: String, angle: float):
	var dial = ui_config.get("dial")
	if dial == null:
		return
	if pressed:
		for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
			if snap_key != key and ui_config.has(snap_key):
				ui_config[snap_key].pressed = false
		dial.set_meta("snap_angle", angle)
		var current_dist = ui_config["dist_spin"].value
		if current_dist > 0:
			var snap_rad = deg2rad(angle)
			var ox = round(-current_dist * cos(snap_rad))
			var oy = round(-current_dist * sin(snap_rad))
			_set_dial_values(ox, oy)
			apply_shadow_to_selected_paths()
	else:
		dial.set_meta("snap_angle", -1.0)

func _deactivate_all_snaps():
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
	var dial = ui_config.get("dial")
	if dial != null:
		var snap_angle = dial.get_meta("snap_angle") as float
		if snap_angle >= 0.0:
			var snap_rad = deg2rad(snap_angle)
			var expected_sun_deg = rad2deg(atan2(cos(snap_rad), -sin(snap_rad)))
			if expected_sun_deg < 0:
				expected_sun_deg += 360.0
			if abs(angle_deg - round(expected_sun_deg)) > 0.5:
				_deactivate_all_snaps()
			else:
				var ox = round(-dist * cos(snap_rad))
				var oy = round(-dist * sin(snap_rad))
				_syncing_ui = true
				ui_config["offset_x_spin"].value = ox
				ui_config["offset_y_spin"].value = oy
				_update_dial_dot_position(ox, oy)
				_syncing_ui = false
				_dirty_properties["offset_x"] = true
				_dirty_properties["offset_y"] = true
				_wall_last_changed = "offset_x"
				apply_shadow_to_selected_paths()
				return
	var angle_rad = deg2rad(angle_deg)
	var ox = round(-dist * sin(angle_rad))
	var oy = round(dist * cos(angle_rad))
	_syncing_ui = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_update_dial_dot_position(ox, oy)
	_syncing_ui = false
	_dirty_properties["offset_x"] = true
	_dirty_properties["offset_y"] = true
	_wall_last_changed = "offset_x"
	apply_shadow_to_selected_paths()

func _set_dial_values(ox: float, oy: float):
	_syncing_ui = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_update_angle_distance_from_xy(ox, oy)
	_update_dial_dot_position(ox, oy)
	_syncing_ui = false
	_dirty_properties["offset_x"] = true
	_dirty_properties["offset_y"] = true
	_wall_last_changed = "offset_x"

func _update_angle_distance_from_xy(ox: float, oy: float):
	var dist = sqrt(ox * ox + oy * oy)
	var angle_deg = 0.0
	if dist > 0.5:
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
	var offset_dist = sqrt(ox * ox + oy * oy)
	var nonlinear_frac = clamp(offset_dist / max_offset, 0.0, 1.0)
	var frac = sqrt(nonlinear_frac)
	var direction = Vector2(-ox, -oy).normalized() if offset_dist > 0.5 else Vector2.ZERO
	var dot_pos = Vector2(dial_size / 2.0, dial_size / 2.0) + direction * frac * radius
	var dot = ui_config["dial_dot"] as ColorRect
	dot.rect_position = Vector2(dot_pos.x - 5, dot_pos.y - 5)

func _set_dial_from_offset(ox: float, oy: float):
	_set_dial_values(ox, oy)

func _update_offset_range(new_range_val: float, scale_offset: bool = true):
	var new_max = new_range_val * OFFSET_MAX
	var old_ox = ui_config["offset_x_spin"].value
	var old_oy = ui_config["offset_y_spin"].value
	var new_ox = old_ox
	var new_oy = old_oy
	if scale_offset:
		var old_max = OFFSET_MAX
		if ui_config.has("dial"):
			old_max = ui_config["dial"].get_meta("max_offset") as float
		var scale_ratio = new_max / max(old_max, 1.0)
		new_ox = clamp(old_ox * scale_ratio, -new_max, new_max)
		new_oy = clamp(old_oy * scale_ratio, -new_max, new_max)
	else:
		new_ox = clamp(old_ox, -new_max, new_max)
		new_oy = clamp(old_oy, -new_max, new_max)
	if ui_config.has("dial"):
		ui_config["dial"].set_meta("max_offset", new_max)
	ui_config["offset_x_spin"].min_value = -new_max
	ui_config["offset_x_spin"].max_value = new_max
	ui_config["offset_y_spin"].min_value = -new_max
	ui_config["offset_y_spin"].max_value = new_max
	if ui_config.has("dist_spin"):
		ui_config["dist_spin"].max_value = new_max
	ui_config["offset_x_spin"].value = new_ox
	ui_config["offset_y_spin"].value = new_oy
	_update_angle_distance_from_xy(new_ox, new_oy)
	_update_dial_dot_position(new_ox, new_oy)

func _on_direction_pressed(dir_index):
	if _syncing_ui:
		return
	_dirty_properties["direction"] = true
	_wall_last_changed = "direction"
	_syncing_ui = true
	_set_direction_buttons(dir_index)
	_syncing_ui = false
	_update_crop_blur_visibility()
	apply_shadow_to_selected_paths()

func _set_direction_buttons(active_index: int):
	for i in range(3):
		var btn = ui_config["dir_btn_" + str(i)]
		btn.pressed = (i == active_index)
		if i == active_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
	# Side Balance row is only relevant in BOTH direction.
	if ui_config.has("side_balance_hbox"):
		ui_config["side_balance_hbox"].visible = (active_index == ShadowDirection.BOTH)

func _get_selected_direction() -> int:
	for i in range(3):
		if ui_config["dir_btn_" + str(i)].pressed:
			return i
	return 2  # default Both

func _on_reset_pressed():
	var defaults_key = USER_DEFAULTS_WALL_KEY if _monitored_type == "walls" else USER_DEFAULTS_KEY
	var reset_config = FACTORY_DEFAULTS.duplicate()
	if global.ModMapData.has(defaults_key):
		var user_def = global.ModMapData[defaults_key]
		for key in user_def.keys():
			reset_config[key] = user_def[key]
	reset_config["enabled"] = ui_config["enable_check"].pressed
	# Preserve current UI display state (cog, section toggles)
	reset_config["settings_open"] = ui_config["settings_toggle"].pressed

	# For paths with no user defaults: read transitions from DD path properties
	if _monitored_type == "paths" and not global.ModMapData.has(defaults_key):
		if _monitored_path != null and is_instance_valid(_monitored_path):
			_apply_path_transitions(reset_config, _monitored_path)

	# For walls with no user defaults: disable all transitions
	if _monitored_type == "walls" and not global.ModMapData.has(defaults_key):
		_disable_wall_only_transitions(reset_config)

	set_ui_without_signals(reset_config)
	_apply_reset_to_all_selected()

func _apply_path_transitions(config: Dictionary, path) -> void:
	var fi = path.get("FadeIn")
	var fo = path.get("FadeOut")
	var gr = path.get("Grow")
	var sh = path.get("Shrink")
	if fi is bool:
		config["fade_in_enabled"] = fi
	if fo is bool:
		config["fade_out_enabled"] = fo
	if gr is bool:
		config["grow_enabled"] = gr
	if sh is bool:
		config["shrink_enabled"] = sh

func _disable_transitions(config: Dictionary) -> void:
	config["fade_in_enabled"] = false
	config["fade_out_enabled"] = false
	config["grow_enabled"] = false
	config["shrink_enabled"] = false
	config["extend_enabled"] = false
	config["swap_ends"] = false

# For walls: disable all transitions by default (user can enable fade/extend/swap manually)
func _disable_wall_only_transitions(config: Dictionary) -> void:
	config["grow_enabled"] = false
	config["shrink_enabled"] = false
	config["fade_in_enabled"] = false
	config["fade_out_enabled"] = false
	config["extend_enabled"] = false
	config["swap_ends"] = false

func _apply_reset_to_all_selected():
	var base_config = get_current_shadow_config()

	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_shadow_node_type(node):
			var cfg = base_config.duplicate()
			var node_type = get_node_type(node)
			if node_type == "paths" and not global.ModMapData.has(USER_DEFAULTS_KEY):
				_apply_path_transitions(cfg, node)
			if node_type == "walls":
				cfg["grow_enabled"] = false
				cfg["shrink_enabled"] = false
			remove_shadow(node)
			if cfg["enabled"]:
				create_shadow(node, cfg)
			save_shadow_data(node, cfg)

func _on_copy_pressed():
	clipboard_config = get_current_shadow_config()
	outputlog("Config copied to clipboard", 1)

func _on_paste_pressed():
	if clipboard_config != null:
		# Paste applies everything — mark all properties dirty
		for key in clipboard_config.keys():
			if key != "enabled" and key != "settings_open":
				_dirty_properties[key] = true
		set_ui_without_signals(clipboard_config)
		apply_shadow_to_selected_paths()
		outputlog("Config pasted from clipboard", 1)

func _on_single_reset(which):
	_dirty_properties[which] = true
	_syncing_ui = true
	var def_val = _get_effective_default(which)
	match which:
		"opacity":
			ui_config["opacity_spin"].value = def_val
			ui_config["opacity_slider"].value = def_val
		"spread":
			ui_config["spread_spin"].value = def_val
			ui_config["spread_slider"].value = def_val
		"softness":
			ui_config["softness_spin"].value = def_val
			ui_config["softness_slider"].value = def_val
		"offset_x", "offset_y", "offset":
			_deactivate_all_snaps()
			_syncing_ui = false
			_set_dial_from_offset(DEFAULT_SHADOW_CONFIG["offset_x"], DEFAULT_SHADOW_CONFIG["offset_y"])
		"range":
			ui_config["range_spin"].value = def_val
			ui_config["range_slider"].value = def_val
			_update_offset_range(def_val, false)
		"fade_in_strength":
			ui_config["fade_in_strength_spin"].value = def_val
			ui_config["fade_in_strength_slider"].value = def_val
		"fade_out_strength":
			ui_config["fade_out_strength_spin"].value = def_val
			ui_config["fade_out_strength_slider"].value = def_val
		"grow_length":
			ui_config["grow_length_spin"].value = def_val
			ui_config["grow_length_slider"].value = def_val
		"shrink_length":
			ui_config["shrink_length_spin"].value = def_val
			ui_config["shrink_length_slider"].value = def_val
		"fade_extend":
			ui_config["fade_extend_spin"].value = def_val
			ui_config["fade_extend_slider"].value = def_val
		"radial_offset":
			ui_config["radial_offset_spin"].value = def_val
			ui_config["radial_offset_slider"].value = def_val
		"side_balance":
			ui_config["side_balance_spin"].value = def_val
			ui_config["side_balance_slider"].value = def_val
		"shadow_color":
			if def_val is String:
				def_val = Color(def_val)
			ui_config["shadow_color_picker"].color = def_val
	_syncing_ui = false
	apply_shadow_to_selected_paths()

# Returns the effective default value for a given config key,
# checking user defaults first, then falling back to FACTORY_DEFAULTS.
func _get_effective_default(which: String):
	var defaults_key = USER_DEFAULTS_WALL_KEY if _monitored_type == "walls" else USER_DEFAULTS_KEY
	if global.ModMapData.has(defaults_key):
		var user_def = global.ModMapData[defaults_key]
		if user_def.has(which):
			return user_def[which]
	return FACTORY_DEFAULTS[which]

func _scroll_to_show(target_control: Control):
	# Scroll the parent ScrollContainer just enough to show the bottom of target_control
	var node = ui_config.get("container")
	if node == null:
		return
	var scroll_container = null
	var walker = node
	while walker != null:
		if walker is ScrollContainer:
			scroll_container = walker
			break
		walker = walker.get_parent()
	if scroll_container == null:
		return
	# Wait for layout to update
	yield(scroll_container.get_tree(), "idle_frame")
	yield(scroll_container.get_tree(), "idle_frame")
	# Calculate target bottom position relative to scroll container's internal content
	var target_bottom = target_control.rect_global_position.y + target_control.rect_size.y
	var scroll_top = scroll_container.rect_global_position.y
	var scroll_height = scroll_container.rect_size.y
	var scroll_bottom = scroll_top + scroll_height
	# Only scroll if target bottom is below visible area
	if target_bottom > scroll_bottom:
		var needed = target_bottom - scroll_bottom
		scroll_container.scroll_vertical += int(needed) + 8  # small padding

func _on_settings_toggled(pressed):
	ui_config["settings_panel"].visible = pressed
	# Move extend toggle between dir_wrapper (cog closed) and extend_section (cog open)
	_reparent_extend_toggle(pressed)
	# Save cog state for monitored path
	if _monitored_path != null and is_instance_valid(_monitored_path):
		var node_id = str(_monitored_path.get_meta("node_id"))
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
			global.ModMapData[SHADOW_DATA_KEY][node_id]["settings_open"] = pressed
	if pressed and not _syncing_ui:
		_scroll_to_show(ui_config["settings_panel"])

func _reparent_extend_toggle(cog_open: bool):
	var ext_hbox = ui_config.get("ext_hbox")
	if ext_hbox == null:
		return
	var extend_section = ui_config.get("extend_section")
	var dir_wrapper = ui_config.get("dir_wrapper")
	if cog_open:
		# Move to extend_section in settings_panel (before distance slider)
		if ext_hbox.get_parent() == extend_section:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		extend_section.add_child(ext_hbox)
		extend_section.move_child(ext_hbox, 1)  # After separator, before fd_container
	else:
		# Move back to dir_wrapper (main area)
		if ext_hbox.get_parent() == dir_wrapper:
			return
		if ext_hbox.get_parent() != null:
			ext_hbox.get_parent().remove_child(ext_hbox)
		dir_wrapper.add_child(ext_hbox)

func _on_section_toggled(pressed, section_key):
	ui_config[section_key + "_content"].visible = pressed
	if pressed and not _syncing_ui:
		_scroll_to_show(ui_config[section_key + "_content"])

func _on_setting_changed(_value = null):
	var is_on = ui_config["enable_check"].pressed
	ui_config["dir_wrapper"].visible = is_on
	if ui_config.has("mode_wrapper"):
		ui_config["mode_wrapper"].visible = is_on
	ui_config["settings_toggle"].visible = is_on
	ui_config["title_reset_btn"].visible = is_on
	if not is_on:
		ui_config["settings_toggle"].pressed = false
		ui_config["settings_panel"].visible = false
		_reparent_extend_toggle(false)
	apply_shadow_to_selected_paths()

func _on_save_default_pressed():
	var config = get_current_shadow_config()
	config["enabled"] = false  # Never save enabled state as default
	config.erase("settings_open")  # Don't save UI display state
	var save_config = config.duplicate()
	if save_config.has("shadow_color") and save_config["shadow_color"] is Color:
		save_config["shadow_color"] = save_config["shadow_color"].to_html(true)
	var key = USER_DEFAULTS_WALL_KEY if _monitored_type == "walls" else USER_DEFAULTS_KEY
	global.ModMapData[key] = save_config
	_sync_pt_ui_from_defaults()
	_sync_wt_ui_from_defaults()
	_update_reset_defaults_visibility()
	outputlog("Current settings saved as " + _monitored_type + " defaults", 1)

func _on_reset_default_pressed():
	var key = USER_DEFAULTS_WALL_KEY if _monitored_type == "walls" else USER_DEFAULTS_KEY
	if global.ModMapData.has(key):
		global.ModMapData.erase(key)
	_sync_pt_ui_from_defaults()
	_sync_wt_ui_from_defaults()
	_update_reset_defaults_visibility()
	outputlog(_monitored_type + " defaults restored to factory settings", 1)

func _update_transition_controls_visibility():
	var transitions = [
		["fade_in", "fade_in_strength_spin", "fade_in_strength_reset", "fade_in_strength_slider"],
		["fade_out", "fade_out_strength_spin", "fade_out_strength_reset", "fade_out_strength_slider"],
		["grow", "grow_length_spin", "grow_length_reset", "grow_length_slider"],
		["shrink", "shrink_length_spin", "shrink_length_reset", "shrink_length_slider"]
	]
	for t in transitions:
		var is_on = ui_config[t[0] + "_check"].pressed
		ui_config[t[1]].visible = is_on
		ui_config[t[2]].visible = is_on
		ui_config[t[3]].visible = is_on

func _on_transition_toggled(_pressed, _which):
	if not _syncing_ui:
		_dirty_properties[_which + "_enabled"] = true
		_update_transition_controls_visibility()
	if _pressed and not _syncing_ui:
		# Scroll to show the row that was just toggled on
		var check_key = _which + "_check"
		if ui_config.has(check_key):
			_scroll_to_show(ui_config[check_key])
	apply_shadow_to_selected_paths()

func _on_extend_toggled(pressed):
	if not _syncing_ui:
		_dirty_properties["extend_enabled"] = true
	ui_config["fade_extend_container"].visible = pressed
	ui_config["ext_which_container"].visible = pressed
	if _monitored_type == "paths":
		if pressed:
			_update_fade_visibility_for_extend_which()
		else:
			if ui_config.has("fade_in_hbox"):
				ui_config["fade_in_hbox"].visible = true
			if ui_config.has("fade_out_hbox"):
				ui_config["fade_out_hbox"].visible = true
	# Walls now use the same model as paths: extend just draws rounded caps
	# at the enabled ends. No more forced fade_in/out coupling — the cap
	# mesh provides its own visual termination via its radial alpha gradient.
	if pressed and not _syncing_ui:
		_scroll_to_show(ui_config["fade_extend_container"])
	apply_shadow_to_selected_paths()

func _on_swap_ends_toggled(_pressed):
	if not _syncing_ui:
		_dirty_properties["swap_ends"] = true
	apply_shadow_to_selected_paths()

func _on_extend_which_pressed(which_index):
	if _syncing_ui:
		return
	_dirty_properties["extend_which"] = true
	_syncing_ui = true
	_set_extend_which_buttons(which_index)
	_syncing_ui = false
	_update_fade_visibility_for_extend_which()
	apply_shadow_to_selected_paths()

func _update_fade_visibility_for_extend_which():
	if not ui_config["extend_check"].pressed:
		return
	var which = _get_selected_extend_which()
	# Walls have no fade_in/fade_out UI exposed, so nothing to do for them.
	# Paths: hide the fade row that's covered by the cap on that end.
	if _monitored_type == "paths":
		if which == 0:  # Start only
			if ui_config.has("fade_out_hbox"):
				ui_config["fade_out_hbox"].visible = true
			if ui_config.has("fade_in_hbox"):
				ui_config["fade_in_hbox"].visible = false
		elif which == 1:  # End only
			if ui_config.has("fade_in_hbox"):
				ui_config["fade_in_hbox"].visible = true
			if ui_config.has("fade_out_hbox"):
				ui_config["fade_out_hbox"].visible = false
		else:  # Both
			if ui_config.has("fade_in_hbox"):
				ui_config["fade_in_hbox"].visible = false
			if ui_config.has("fade_out_hbox"):
				ui_config["fade_out_hbox"].visible = false

func _set_extend_which_buttons(active_index: int):
	for i in range(3):
		var btn = ui_config["ext_which_btn_" + str(i)]
		btn.pressed = (i == active_index)
		if i == active_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")

func _get_selected_extend_which() -> int:
	for i in range(3):
		if ui_config["ext_which_btn_" + str(i)].pressed:
			return i
	return 2

func _on_skip_portals_toggled(_pressed):
	if _syncing_ui:
		return
	_dirty_properties["skip_portals"] = true
	
	# Stash/restore extend settings for closed loop walls
	if _monitored_path != null and is_instance_valid(_monitored_path):
		var nid = str(_monitored_path.get_meta("node_id")) if _monitored_path.has_meta("node_id") else ""
		if nid != "" and get_node_type(_monitored_path) == "walls" and is_path_closed(_monitored_path):
			if not _pressed:
				# Toggling OFF: stash current extend settings before they get wiped
				_stashed_extend[nid] = {
					"extend_enabled": ui_config["extend_check"].pressed,
					"fade_in_enabled": ui_config["fade_in_check"].pressed,
					"fade_out_enabled": ui_config["fade_out_check"].pressed,
					"fade_extend": ui_config["fade_extend_spin"].value,
					"extend_which": _get_selected_extend_which()
				}
			else:
				# Toggling ON: restore stashed extend settings to UI
				if _stashed_extend.has(nid):
					var stash = _stashed_extend[nid]
					_syncing_ui = true
					ui_config["extend_check"].pressed = stash.get("extend_enabled", false)
					ui_config["fade_in_check"].pressed = stash.get("fade_in_enabled", false)
					ui_config["fade_out_check"].pressed = stash.get("fade_out_enabled", false)
					ui_config["fade_extend_spin"].value = stash.get("fade_extend", 0.0)
					ui_config["fade_extend_slider"].value = stash.get("fade_extend", 0.0)
					_set_extend_which_buttons(int(stash.get("extend_which", 2)))
					_syncing_ui = false
					_stashed_extend.erase(nid)
					# Mark these as dirty so they propagate
					_dirty_properties["extend_enabled"] = true
					_dirty_properties["fade_in_enabled"] = true
					_dirty_properties["fade_out_enabled"] = true
					_dirty_properties["fade_extend"] = true
					_dirty_properties["extend_which"] = true
	
	apply_shadow_to_selected_paths()
	_update_transition_visibility(_monitored_type)

func _on_below_all_walls_toggled(_pressed):
	if _syncing_ui:
		return
	_dirty_properties["below_all_walls"] = true
	apply_shadow_to_selected_paths()

func _render_mode_to_index(mode) -> int:
	return 1 if str(mode) == "realistic" else 0

func _render_mode_from_index(idx: int) -> String:
	return "realistic" if int(idx) == 1 else "simple"

# Opacité indépendante par mode : le slider tient le mode actif, la valeur de l'autre mode
# est stockée dans ui_config["opacity_inactive"]. Renvoie [opacity_simple, opacity_realistic].
func _get_ui_opacities() -> Array:
	var def_s = DEFAULT_SHADOW_CONFIG["opacity"]
	var def_r = DEFAULT_SHADOW_CONFIG.get("opacity_realistic", def_s)
	if not ui_config.has("opacity_slider"):
		return [def_s, def_r]
	var active = ui_config["opacity_slider"].value
	var other = ui_config.get("opacity_inactive", def_r)
	var realistic = ui_config.has("mode_btn_1") and ui_config["mode_btn_1"].pressed
	if realistic:
		return [other, active]
	return [active, other]

func _on_crop_blur_toggled(_pressed):
	if _syncing_ui:
		return
	_dirty_properties["crop_blur"] = true
	# Pas un param "live" -> force le chemin settle/re-bake (le masque doit être (re)capturé).
	_wall_last_changed = "crop_blur"
	apply_shadow_to_selected_paths()

func _on_crop_ends_toggled(_pressed):
	if _syncing_ui:
		return
	_dirty_properties["crop_ends"] = true
	# Pas un param "live" -> force le chemin settle/re-bake (le masque doit être (re)capturé).
	_wall_last_changed = "crop_ends"
	apply_shadow_to_selected_paths()

func _update_crop_blur_visibility():
	if not ui_config.has("crop_blur_hbox"):
		return
	var realistic = ui_config.has("mode_btn_1") and ui_config["mode_btn_1"].pressed
	var dir = _get_selected_direction()
	ui_config["crop_blur_hbox"].visible = realistic and dir != ShadowDirection.BOTH
	# Crop Ends : Realistic, toute direction (y compris Both).
	if ui_config.has("crop_ends_hbox"):
		ui_config["crop_ends_hbox"].visible = realistic

func _set_render_mode_buttons(active_index: int):
	for i in range(2):
		if not ui_config.has("mode_btn_" + str(i)):
			continue
		ui_config["mode_btn_" + str(i)].pressed = (i == active_index)
		if i == active_index:
			ui_config["mode_btn_" + str(i)].icon = ui_config["mode_btn_" + str(i)].get_icon("radio_checked", "CheckBox")
		else:
			ui_config["mode_btn_" + str(i)].icon = ui_config["mode_btn_" + str(i)].get_icon("radio_unchecked", "CheckBox")
	var _realistic = (active_index == 1)
	# Blur : mode Realistic uniquement. Spread/Softness : mode Simple uniquement.
	if ui_config.has("realistic_blur_hbox"):
		ui_config["realistic_blur_hbox"].visible = _realistic
	if ui_config.has("spread_hbox"):
		ui_config["spread_hbox"].visible = not _realistic
	if ui_config.has("softness_hbox"):
		ui_config["softness_hbox"].visible = not _realistic
	# Opacité max doublée en Realistic (le flou atténue l'ombre -> on peut vouloir la
	# renforcer au-delà de 1.0 ; le shader n'est pas bridé).
	if ui_config.has("opacity_slider"):
		var omax = 2.0 if _realistic else 1.0
		ui_config["opacity_slider"].max_value = omax
		if ui_config.has("opacity_spin"):
			ui_config["opacity_spin"].max_value = omax
	_update_crop_blur_visibility()

func _on_wall_render_mode_pressed(mode_index):
	if _syncing_ui:
		return
	_syncing_ui = true
	# Opacité indépendante : échange le slider avec la valeur du mode inactif (max d'abord
	# pour ne pas clamper une valeur realistic >1 en passant par un max simple).
	if ui_config.has("opacity_slider"):
		var _cur = ui_config["opacity_slider"].value
		var _oth = ui_config.get("opacity_inactive", DEFAULT_SHADOW_CONFIG.get("opacity_realistic", DEFAULT_SHADOW_CONFIG["opacity"]))
		ui_config["opacity_inactive"] = _cur
		var _mx = 2.0 if mode_index == 1 else 1.0
		ui_config["opacity_slider"].max_value = _mx
		ui_config["opacity_spin"].max_value = _mx
		ui_config["opacity_slider"].value = _oth
		ui_config["opacity_spin"].value = _oth
	_set_render_mode_buttons(mode_index)
	_update_transition_visibility(_monitored_type)
	_syncing_ui = false
	_dirty_properties["render_mode"] = true
	apply_shadow_to_selected_paths()

func _on_color_changed(_color):
	if _syncing_ui:
		return
	_dirty_properties["shadow_color"] = true
	_wall_last_changed = "shadow_color"
	apply_shadow_to_selected_paths()

# === Portal "Keep Wall Shadow" toggle ===
var _portal_ui = {}
var _portal_insert_idx = -1

func _find_rotate_button(node, path):
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is Button or child is CheckButton or child is CheckBox:
			var t = ""
			if child.get("text") != null:
				t = child.text.to_lower()
			if "rotate" in t or "180" in t or "flip" in t:
				_portal_insert_idx = i + 1
				return
		if child.get_child_count() > 0:
			_find_rotate_button(child, path)
			if _portal_insert_idx >= 0:
				return
var _portal_tool_ui = {}
var _portal_selection_hash = 0
var _syncing_portal_toggle = false
var _portal_tool_keep_shadow = false

func _build_portal_ui(select_panel):
	var portal_container = VBoxContainer.new()
	portal_container.name = "DropShadowPortalContainer"
	portal_container.visible = false
	var sep = HSeparator.new()
	sep.add_constant_override("separation", 8)
	portal_container.add_child(sep)
	var hbox = HBoxContainer.new()
	var sel_portal_cloud = _create_cloud_icon()
	if sel_portal_cloud != null:
		hbox.add_child(sel_portal_cloud)
	var label = Label.new()
	label.text = "Switch Shadow Setting"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var toggle = CheckButton.new()
	toggle.pressed = false
	toggle.connect("toggled", self, "_on_portal_keep_shadow_toggled")
	hbox.add_child(toggle)
	portal_container.add_child(hbox)
	_portal_ui["container"] = portal_container
	_portal_ui["toggle"] = toggle
	# Try to find portal/door options panel; fallback to wallOptions
	var target_parent = null
	for prop_name in ["portalOptions", "doorOptions", "PortalOptions", "DoorOptions"]:
		var panel = select_panel.get(prop_name)
		if panel != null and panel is Control:
			target_parent = panel
			outputlog("Portal panel found via: " + prop_name, 0)
			break
	if target_parent != null:
		# Try to insert just after the "BLOCK_LIGHT" button
		var block_light_idx = -1
		for i in range(target_parent.get_child_count()):
			var child = target_parent.get_child(i)
			var t = ""
			if child.get("text") != null:
				t = child.text.to_lower()
			if "block_light" in t or "block light" in t:
				block_light_idx = i
				break
			if child is Container:
				for j in range(child.get_child_count()):
					var sub = child.get_child(j)
					var st = ""
					if sub.get("text") != null:
						st = sub.text.to_lower()
					if "block_light" in st or "block light" in st:
						block_light_idx = i
						break
				if block_light_idx >= 0:
					break
		if block_light_idx >= 0:
			target_parent.add_child(portal_container)
			target_parent.move_child(portal_container, block_light_idx + 1)
			outputlog("Portal: Keep Wall Shadow inserted after BLOCK_LIGHT at idx " + str(block_light_idx + 1), 0)
		else:
			target_parent.add_child(portal_container)
			outputlog("Portal: Keep Wall Shadow added at end (BLOCK_LIGHT not found)", 0)
	else:
		outputlog("Portal panel NOT found, trying wallOptions fallback", 0)
		var wall_opts = select_panel.get("wallOptions")
		if wall_opts != null and wall_opts is Control:
			wall_opts.add_child(portal_container)
		else:
			outputlog("Could not find parent for portal UI", 0)

func _build_portal_tool_ui():
	if not is_instance_valid(global.Editor) or global.Editor.Toolset == null:
		return
	var tool_panel = null
	for tool_name in ["PortalTool", "DoorTool", "PortalPlaceTool"]:
		if global.Editor.Toolset.has_method("GetToolPanel"):
			tool_panel = global.Editor.Toolset.GetToolPanel(tool_name)
		if tool_panel != null:
			break
	if tool_panel == null:
		return
	var parent_vbox = core.get_align_vbox(tool_panel)
	if parent_vbox == null:
		parent_vbox = tool_panel
	var pt_container = VBoxContainer.new()
	pt_container.name = "DropShadowPortalTool"
	var sep = HSeparator.new()
	sep.add_constant_override("separation", 4)
	pt_container.add_child(sep)
	var hbox = HBoxContainer.new()
	var pt_cloud = _create_cloud_icon()
	if pt_cloud != null:
		hbox.add_child(pt_cloud)
	var label = Label.new()
	label.text = "Switch Shadow Setting"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var toggle = CheckButton.new()
	toggle.pressed = false
	toggle.connect("toggled", self, "_on_portal_tool_keep_shadow_toggled")
	hbox.add_child(toggle)
	pt_container.add_child(hbox)
	var pt_sep_bottom = HSeparator.new()
	pt_sep_bottom.add_constant_override("separation", 4)
	pt_container.add_child(pt_sep_bottom)
	
	# Try to insert just after the "Anchored" button so the order is:
	# ... Anchored / Keep Wall Shadow ...
	var inserted = false
	var freestanding_idx = _find_freestanding_index(parent_vbox)
	if freestanding_idx >= 0:
		parent_vbox.add_child(pt_container)
		parent_vbox.move_child(pt_container, freestanding_idx + 1)
		outputlog("PortalTool: Keep Wall Shadow inserted after Freestanding at idx " + str(freestanding_idx + 1), 0)
		inserted = true
	if not inserted:
		# Fallback: insert between "Rotate 180" and "Style"
		_portal_insert_idx = -1
		_find_rotate_button(parent_vbox, [])
		if _portal_insert_idx >= 0:
			parent_vbox.add_child(pt_container)
			parent_vbox.move_child(pt_container, _portal_insert_idx)
			outputlog("PortalTool: Keep Wall Shadow inserted at rotate idx " + str(_portal_insert_idx), 0)
		else:
			parent_vbox.add_child(pt_container)
			outputlog("PortalTool: Keep Wall Shadow added at end (fallback)", 0)
	_portal_tool_ui["container"] = pt_container
	_portal_tool_ui["toggle"] = toggle
	# Update visibility based on PortalTool.Freestanding state
	_update_portal_tool_freestanding_visibility()

func _on_portal_tool_keep_shadow_toggled(pressed):
	_portal_tool_keep_shadow = pressed

func _find_freestanding_index(parent: Node) -> int:
	# Find the child index of the "ANCHORED" button (DD's freestanding toggle)
	for i in range(parent.get_child_count()):
		var child = parent.get_child(i)
		var t = ""
		if child.get("text") != null:
			t = child.text.to_lower()
		if "anchor" in t or "freestand" in t:
			return i
		if child is Container:
			for j in range(child.get_child_count()):
				var sub = child.get_child(j)
				var st = ""
				if sub.get("text") != null:
					st = sub.text.to_lower()
				if "anchor" in st or "freestand" in st:
					return i
	return -1

func _update_portal_tool_freestanding_visibility():
	# Hide "Keep Wall Shadow" when portal tool is in freestanding mode
	if not _portal_tool_ui.has("container"):
		return
	var portal_tool = global.Editor.Tools.get("PortalTool")
	if portal_tool == null:
		return
	var is_freestanding = portal_tool.get("Freestanding")
	if is_freestanding is bool:
		_portal_tool_ui["container"].visible = not is_freestanding

func _sync_portal_toggles(pressed):
	_syncing_portal_toggle = true
	if _portal_ui.has("toggle"):
		_portal_ui["toggle"].pressed = pressed
	_syncing_portal_toggle = false

func _on_portal_keep_shadow_toggled(pressed):
	if _syncing_portal_toggle:
		return
	var portals = _get_selected_portals()
	if portals.size() == 0:
		return
	var walls_to_rebuild = {}
	for portal in portals:
		var portal_id = get_portal_id(portal)
		if portal_id == "":
			continue
		var current_has_shadow = _get_portal_has_shadow(portal)
		if pressed == current_has_shadow:
			continue
		var currently_overridden = is_portal_skip_overridden(portal_id)
		set_portal_skip_override(portal_id, not currently_overridden)
		var wall = get_wall_for_portal(portal)
		if wall != null and is_instance_valid(wall):
			var wall_id = str(wall.get_meta("node_id"))
			walls_to_rebuild[wall_id] = wall
	for wall_id in walls_to_rebuild:
		var wall = walls_to_rebuild[wall_id]
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
			var config = global.ModMapData[SHADOW_DATA_KEY][wall_id]
			# If this is a closed loop that no longer has skipped portals,
			# force extend/fade off (loop has no open ends anymore)
			if is_path_closed(wall) and not _wall_has_skipped_portals(wall, config.get("skip_portals", false)):
				config["extend_enabled"] = false
				config["fade_in_enabled"] = false
				config["fade_out_enabled"] = false
				save_shadow_data(wall, config)
			if config.get("enabled", false):
				remove_shadow(wall)
				create_shadow(wall, config)
	# Refresh extend visibility in case loop gained/lost skipped portals
	if _monitored_path != null and is_instance_valid(_monitored_path):
		_update_transition_visibility(_monitored_type)

func _get_selected_portals() -> Array:
	var portals = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_portal_node(node):
			portals.append(node)
	return portals

func _get_portal_has_shadow(portal_node) -> bool:
	var wall = get_wall_for_portal(portal_node)
	var wall_skip = false
	if wall != null and is_instance_valid(wall):
		var wall_id = str(wall.get_meta("node_id"))
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
			wall_skip = global.ModMapData[SHADOW_DATA_KEY][wall_id].get("skip_portals", false)
	if portal_node.get_child_count() > 0:
		var sp = portal_node.get_child(0)
		if sp is Sprite and sp.texture != null:
			if sp.texture.resource_path == "" or sp.texture.resource_path.ends_with("null.png"):
				return is_portal_skip_overridden(get_portal_id(portal_node))
	var should_skip = wall_skip
	if is_portal_skip_overridden(get_portal_id(portal_node)):
		should_skip = not should_skip
	return not should_skip

func _update_portal_ui():
	if not _portal_ui.has("container"):
		return
	var portals = _get_selected_portals()
	# Filter out freestanding portals (not attached to a wall) — "Keep Wall Shadow" is irrelevant for them
	var attached_portals = []
	for p in portals:
		var is_free = p.get("IsFreestanding")
		if is_free is bool and is_free:
			continue
		attached_portals.append(p)
	# Hide if no attached portals, or if the parent wall has no shadow enabled
	var should_show = attached_portals.size() > 0
	if should_show:
		# Check if at least one portal's parent wall has shadow enabled
		var any_wall_has_shadow = false
		for p in attached_portals:
			var wall = get_wall_for_portal(p)
			if wall != null and is_instance_valid(wall) and wall.has_meta("node_id"):
				var wall_id = str(wall.get_meta("node_id"))
				if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
					if global.ModMapData[SHADOW_DATA_KEY][wall_id].get("enabled", false):
						any_wall_has_shadow = true
						break
		should_show = any_wall_has_shadow
	_portal_ui["container"].visible = should_show
	if should_show:
		var sel_hash = 0
		for p in attached_portals:
			sel_hash = sel_hash * 31 + p.get_instance_id()
		if sel_hash != _portal_selection_hash:
			_portal_selection_hash = sel_hash
			_sync_portal_toggles(_get_portal_has_shadow(attached_portals[0]))
	else:
		_portal_selection_hash = 0

func _on_new_portal_placed(portal_node):
	var portal_id = get_portal_id(portal_node)
	if portal_id == "":
		return
	var wall = get_wall_for_portal(portal_node)
	if wall == null or not is_instance_valid(wall):
		return
	var wall_id = str(wall.get_meta("node_id")) if wall.has_meta("node_id") else ""
	# "Switch Shadow Setting" toggle: ON = invert default, OFF = use default
	if _portal_tool_keep_shadow:
		set_portal_skip_override(portal_id, true)
	# Register this portal as known so _apply_override_to_new_portals won't re-process it
	if wall_id != "":
		if not _known_wall_portals.has(wall_id):
			_known_wall_portals[wall_id] = {}
		_known_wall_portals[wall_id][portal_id] = true
	# Schedule a delayed rebuild of the wall shadow so the override is visible.
	if wall_id != "" and global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
		call_deferred("_deferred_rebuild_wall_for_portal", wall, wall_id)

func _deferred_rebuild_wall_for_portal(wall, wall_id: String):
	# Wait for DD to finalize the portal (set Begin/End, load texture, split Line2Ds).
	# We rebuild multiple times with increasing delays because DD may take
	# variable time to fully initialize the portal properties.
	for delay in [0.05, 0.15, 0.35]:
		yield(global.Editor.get_tree().create_timer(delay), "timeout")
		if wall == null or not is_instance_valid(wall):
			return
		if not global.ModMapData.has(SHADOW_DATA_KEY) or not global.ModMapData[SHADOW_DATA_KEY].has(wall_id):
			return
		var config = global.ModMapData[SHADOW_DATA_KEY][wall_id]
		if is_path_closed(wall) and not _wall_has_skipped_portals(wall, config.get("skip_portals", false)):
			config["extend_enabled"] = false
			config["fade_in_enabled"] = false
			config["fade_out_enabled"] = false
			save_shadow_data(wall, config)
		if config.get("enabled", false):
			remove_shadow(wall)
			create_shadow(wall, config)
			_all_points_hashes[wall_id] = _get_points_hash(wall)

#########################################################################################################
##
## SHADOW CREATION
##
#########################################################################################################

func get_current_shadow_config() -> Dictionary:
	return {
		"enabled": ui_config["enable_check"].pressed,
		"settings_open": ui_config["settings_toggle"].pressed,
		"opacity": _get_ui_opacities()[0],
		"opacity_realistic": _get_ui_opacities()[1],
		"softness": ui_config["softness_slider"].value,
		"direction": _get_selected_direction(),
		"spread": ui_config["spread_slider"].value,
		"offset_x": ui_config["offset_x_spin"].value,
		"offset_y": ui_config["offset_y_spin"].value,
		"crop_blur": (ui_config["crop_blur_check"].pressed if ui_config.has("crop_blur_check") else false),
		"crop_ends": (ui_config["crop_ends_check"].pressed if ui_config.has("crop_ends_check") else false),
		"radial_offset": ui_config["radial_offset_spin"].value if ui_config.has("radial_offset_spin") else DEFAULT_SHADOW_CONFIG["radial_offset"],
		"side_balance": ui_config["side_balance_spin"].value if ui_config.has("side_balance_spin") else DEFAULT_SHADOW_CONFIG["side_balance"],
		"range": ui_config["range_spin"].value if ui_config.has("range_spin") else DEFAULT_SHADOW_CONFIG["range"],
		"snap_angle": ui_config["dial"].get_meta("snap_angle") if ui_config.has("dial") else -1.0,
		"fade_in_enabled": ui_config["fade_in_check"].pressed,
		"fade_out_enabled": ui_config["fade_out_check"].pressed,
		"fade_in_strength": ui_config["fade_in_strength_spin"].value,
		"fade_out_strength": ui_config["fade_out_strength_spin"].value,
		"grow_enabled": ui_config["grow_check"].pressed,
		"shrink_enabled": ui_config["shrink_check"].pressed,
		"grow_length": ui_config["grow_length_spin"].value,
		"shrink_length": ui_config["shrink_length_spin"].value,
		"extend_enabled": ui_config["extend_check"].pressed,
		"fade_extend": ui_config["fade_extend_spin"].value,
		"extend_which": _get_selected_extend_which(),
		"swap_ends": ui_config["swap_ends_check"].pressed,
		"skip_portals": ui_config["skip_portals_check"].pressed,
		"below_all_walls": ui_config["below_all_walls_check"].pressed,
		"render_mode": _render_mode_from_index(1 if (ui_config.has("mode_btn_1") and ui_config["mode_btn_1"].pressed) else 0),
		"realistic_blur": (ui_config["realistic_blur_slider"].value if ui_config.has("realistic_blur_slider") else DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2)),
		"shadow_color": ui_config["shadow_color_picker"].color
	}

#########################################################################################################
##
## UNDO/REDO — TRANSACTIONS DE RÉGLAGES (walls)
##
#########################################################################################################

func _history_affected_paths() -> Array:
	var out = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_shadow_node_type(node) and not out.has(node):
			out.append(node)
	var path_tool = global.Editor.Tools.get("PathTool")
	if path_tool != null:
		for prop in ["EditingPath", "editingPath", "SelectedPath"]:
			var edited = path_tool.get(prop)
			if edited != null and is_instance_valid(edited) and is_shadow_node_type(edited):
				if not out.has(edited):
					out.append(edited)
				break
	if _monitored_path != null and is_instance_valid(_monitored_path):
		if is_shadow_node_type(_monitored_path) and not out.has(_monitored_path):
			out.append(_monitored_path)
	return out

# Snapshot {node_id: {node, cfg}} — référence nœud embarquée (pas de map id->nœud).
func _history_snapshot(nodes: Array) -> Dictionary:
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
			cfg = get_current_shadow_config()
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		snap[nid] = {"node": node, "cfg": cfg}
	return snap

func _history_touch(label: String = "") -> void:
	if shadow_history == null:
		return
	if _history_suspend or _syncing_ui:
		return
	if not _history_txn_active:
		_history_txn_before = _history_snapshot(_history_affected_paths())
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
		var node = before[nid]["node"]
		var cfg
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
			cfg = global.ModMapData[SHADOW_DATA_KEY][nid].duplicate(true)
		else:
			cfg = before[nid]["cfg"].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is Color:
			cfg["shadow_color"] = cfg["shadow_color"].to_html(true)
		after[nid] = {"node": node, "cfg": cfg}
		if JSON.print(before[nid]["cfg"]) != JSON.print(cfg):
			changed = true
	if changed and shadow_history != null:
		shadow_history.record(self, "history_apply", before, after, _history_txn_label)

# Transaction "manuelle" (Apply-to-all, qui ne passe pas par apply_shadow_to_selected_paths).
func _history_begin_manual(label: String = "") -> void:
	if shadow_history == null:
		return
	_history_txn_before = {}
	_history_txn_active = true
	_history_txn_label = label

func _history_capture_before(node) -> void:
	if not _history_txn_active or shadow_history == null:
		return
	if not is_instance_valid(node) or not node.has_meta("node_id"):
		return
	var nid = str(node.get_meta("node_id"))
	if _history_txn_before.has(nid):
		return
	var single = _history_snapshot([node])
	for k in single.keys():
		_history_txn_before[k] = single[k]

# Restaure un snapshot {node_id: {node, cfg}} (undo ET redo).
func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true
	var refresh = false
	for nid in payload.keys():
		var node = payload[nid]["node"]
		var cfg = payload[nid]["cfg"].duplicate(true)
		if cfg.has("shadow_color") and cfg["shadow_color"] is String:
			cfg["shadow_color"] = Color(cfg["shadow_color"])
		if node != null and is_instance_valid(node):
			remove_shadow(node)
			if cfg.get("enabled", false):
				create_shadow(node, cfg)
			save_shadow_data(node, cfg)
			if node == _monitored_path:
				refresh = true
		else:
			if not global.ModMapData.has(SHADOW_DATA_KEY):
				global.ModMapData[SHADOW_DATA_KEY] = {}
			global.ModMapData[SHADOW_DATA_KEY][nid] = payload[nid]["cfg"].duplicate(true)
	if refresh and _monitored_path != null and is_instance_valid(_monitored_path):
		load_shadow_ui_from_path(_monitored_path)
	_history_suspend = false


func apply_shadow_to_selected_paths():

	_history_touch("wall")

	var ui_cfg = get_current_shadow_config()

	# Gather paths from SelectTool and PathTool
	var paths_to_process = []
	for node in global.Editor.Tools["SelectTool"].Selected:
		if is_shadow_node_type(node):
			paths_to_process.append(node)

	# Also include PathTool editing path if not already in list
	var path_tool = global.Editor.Tools.get("PathTool")
	if path_tool != null:
		for prop in ["EditingPath", "editingPath", "SelectedPath"]:
			var edited = path_tool.get(prop)
			if edited != null and is_instance_valid(edited) and is_shadow_node_type(edited):
				if not paths_to_process.has(edited):
					paths_to_process.append(edited)
				break

	# Also include monitored path (may be set from PathTool)
	if _monitored_path != null and is_instance_valid(_monitored_path):
		if is_shadow_node_type(_monitored_path) and not paths_to_process.has(_monitored_path):
			paths_to_process.append(_monitored_path)

	for node in paths_to_process:
		var node_id = str(node.get_meta("node_id"))
		var node_type = get_node_type(node)

		# Check if this path already has a saved shadow config
		var has_saved = false
		if global.ModMapData.has(SHADOW_DATA_KEY):
			has_saved = global.ModMapData[SHADOW_DATA_KEY].has(node_id)

		if node == _monitored_path or not has_saved:
			# Monitored path or new path: apply UI config
			var cfg = ui_cfg.duplicate()
			# For new paths (not monitored): apply type-specific defaults
			if node != _monitored_path and not has_saved:
				var def_key = USER_DEFAULTS_WALL_KEY if node_type == "walls" else USER_DEFAULTS_KEY
				cfg = FACTORY_DEFAULTS.duplicate()
				if global.ModMapData.has(def_key):
					var user_def = global.ModMapData[def_key]
					for dkey in user_def.keys():
						cfg[dkey] = user_def[dkey]
				cfg["enabled"] = ui_cfg["enabled"]
				if node_type == "paths" and not global.ModMapData.has(USER_DEFAULTS_KEY):
					_apply_path_transitions(cfg, node)
			# Walls don't have grow/shrink transitions
			if node_type == "walls":
				cfg["grow_enabled"] = false
				cfg["shrink_enabled"] = false
				# Closed loops without skipped portals can't have extend
				if is_path_closed(node) and not _wall_has_skipped_portals(node, cfg.get("skip_portals", false)):
					cfg["extend_enabled"] = false
					cfg["fade_in_enabled"] = false
					cfg["fade_out_enabled"] = false
			if cfg["enabled"] and node.has_meta(SHADOW_META_KEY) and _can_live_update_realistic_wall(cfg) and _live_update_realistic_wall(node, cfg):
				save_shadow_data(node, cfg)
			elif cfg["enabled"] and cfg.get("render_mode", "simple") == "realistic" and node.has_meta(SHADOW_META_KEY):
				_wall_r_settle[node.get_instance_id()] = cfg.duplicate()
				_wall_r_settle_time[node.get_instance_id()] = OS.get_ticks_msec()
				save_shadow_data(node, cfg)
			else:
				remove_shadow(node)
				if cfg["enabled"]:
					create_shadow(node, cfg)
				save_shadow_data(node, cfg)
		else:
			# Existing path (not monitored): apply only enabled, skip_portals,
			# and any properties the user has explicitly changed (dirty)
			var saved = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
			saved["enabled"] = ui_cfg["enabled"]
			# Always sync skip_portals from UI (it's a wall-level toggle)
			saved["skip_portals"] = ui_cfg.get("skip_portals", false)
			# Apply any properties the user has manually changed
			for dirty_key in _dirty_properties:
				var eff_key = dirty_key
				# En mode Realistic, le slider Opacity pilote opacity_realistic : c'est
				# cette clé qu'il faut propager à la sélection (sinon seuls le monitored
				# et les nouveaux murs changeaient d'opacité).
				if dirty_key == "opacity" and ui_cfg.get("render_mode", "simple") == "realistic":
					eff_key = "opacity_realistic"
				if ui_cfg.has(eff_key):
					saved[eff_key] = ui_cfg[eff_key]
			# Closed loops without skipped portals can't have extend
			if is_path_closed(node) and not _wall_has_skipped_portals(node, saved.get("skip_portals", false)):
				saved["extend_enabled"] = false
				saved["fade_in_enabled"] = false
				saved["fade_out_enabled"] = false
			if saved["enabled"] and node.has_meta(SHADOW_META_KEY) and _can_live_update_realistic_wall(saved) and _live_update_realistic_wall(node, saved):
				save_shadow_data(node, saved)
			elif saved["enabled"] and saved.get("render_mode", "simple") == "realistic" and node.has_meta(SHADOW_META_KEY):
				_wall_r_settle[node.get_instance_id()] = saved.duplicate()
				_wall_r_settle_time[node.get_instance_id()] = OS.get_ticks_msec()
				save_shadow_data(node, saved)
			else:
				remove_shadow(node)
				if saved["enabled"]:
					create_shadow(node, saved)
				save_shadow_data(node, saved)
	# Réglage traité : réinitialise pour qu'un prochain apply non-réglage force une recapture.
	_wall_last_changed = ""

# Bevel sharp corners for a specific shadow side.
# sign_dir: 1.0 for outer, -1.0 for inner
# For each corner, uses cross product to determine if the shadow side faces
# the convex (outside) or concave (inside) of the turn:
# - Convex side: arc of points for smooth shadow
# - Concave side: bevel with shadow fading to zero at corner
# Returns [PoolVector2Array points, Array corner_factors]
# Suit un mur realistic en direct pendant un déplacement/reshape : repositionne le sprite
# existant (base_pos recalculé sur la géométrie courante) sans le retirer -> pas de flicker,
# et planifie un re-bake de la silhouette au repos (au cas où la forme a changé).
func _wall_r_follow_and_settle(node, cfg):
	var nid = node.get_instance_id()
	var line = get_line2d(node)
	if line == null or not is_instance_valid(line):
		remove_shadow(node)
		create_shadow(node, cfg)
		return
	var shadow_color = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	var opacity = cfg.get("opacity_realistic", cfg.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"]))
	var blur_px = _realistic_blur_px_from_frac(cfg.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2)))
	var radial = _make_radial(cfg)
	var offset = Vector2(cfg.get("offset_x", 0.0), cfg.get("offset_y", 0.0))
	if line.rotation != 0.0:
		offset = offset.rotated(-line.rotation)
	# Session live : re-peuple la silhouette (nouvelle forme/orientation) + repositionne, en
	# direct via le viewport persistant. Suit move/rotate/reshape sans flicker.
	if _wall_r_session.has(nid):
		if not _update_wall_r_session(nid, node, line, radial, offset, shadow_color, opacity, blur_px):
			remove_shadow(node)
			create_shadow(node, cfg)
		return
	var below_all = cfg.get("below_all_walls", false)
	var shadow_parent = _get_wall_r_wrapper(line)
	var wall_nid = str(node.get_meta("node_id")) if node.has_meta("node_id") else ""
	if below_all:
		var ba = _get_below_all_container(line)
		if ba != null:
			shadow_parent = ba
	_start_wall_r_session(node, line, shadow_parent, line.global_transform, wall_nid, radial, offset, shadow_color, opacity, blur_px)

func _bevel_points_for_side(source_points: PoolVector2Array, sign_dir: float, is_closed: bool) -> Array:
	if source_points.size() < 3:
		var early_factors = []
		for _j in range(source_points.size()):
			early_factors.append(1.0)
		return [source_points, early_factors]

	# Adaptive bevel parameters based on angle sharpness
	# dot=1.0 means straight (no turn), dot=-1.0 means full U-turn
	# threshold: only bevel corners sharper than ~66° turn (dot < 0.40)
	var bevel_angle_threshold = 0.99

	# bevel_dist and arc_steps scale with sharpness:
	#   sharpness = 0.0 at threshold (gentle corner) → small dist, few steps
	#   sharpness = 1.0 at U-turn (dot = -1.0) → large dist, many steps
	var bevel_dist_min = 40.0
	var bevel_dist_max = 60.0
	var arc_steps_min = 3
	var arc_steps_max = 8

	var result = PoolVector2Array()
	var factors = []
	var pt_count = source_points.size()

	for i in range(pt_count):
		var has_prev = false
		var has_next = false
		var dir_in = Vector2.ZERO
		var dir_out = Vector2.ZERO

		if is_closed:
			has_prev = true
			has_next = true
			dir_in = (source_points[i] - source_points[(i - 1 + pt_count) % pt_count]).normalized()
			dir_out = (source_points[(i + 1) % pt_count] - source_points[i]).normalized()
		else:
			if i > 0:
				has_prev = true
				dir_in = (source_points[i] - source_points[i - 1]).normalized()
			if i < pt_count - 1:
				has_next = true
				dir_out = (source_points[i + 1] - source_points[i]).normalized()

		if has_prev and has_next:
			var dot = dir_in.dot(dir_out)
			if dot < bevel_angle_threshold:
				# sharpness: 0.0 at threshold, 1.0 at dot=-1.0
				var sharpness = clamp((bevel_angle_threshold - dot) / (bevel_angle_threshold + 1.0), 0.0, 1.0)
				var bevel_dist = bevel_dist_min + (bevel_dist_max - bevel_dist_min) * sharpness
				var arc_steps = arc_steps_min + int((arc_steps_max - arc_steps_min) * sharpness)

				var prev_pt = source_points[(i - 1 + pt_count) % pt_count] if is_closed else source_points[i - 1]
				var next_pt = source_points[(i + 1) % pt_count] if is_closed else source_points[i + 1]
				var seg_in_len = source_points[i].distance_to(prev_pt)
				var seg_out_len = source_points[i].distance_to(next_pt)
				var d = min(bevel_dist, seg_in_len * 0.4, seg_out_len * 0.4)

				var p_before = source_points[i] - dir_in * d
				var p_after = source_points[i] + dir_out * d

				var cross = dir_in.x * dir_out.y - dir_in.y * dir_out.x
				var is_convex = (cross * sign_dir) < 0.0

				if is_convex:
					result.append(p_before)
					factors.append(1.0)
					var corner = source_points[i]
					for s in range(1, arc_steps + 1):
						var t = float(s) / float(arc_steps + 1)
						var from_corner = p_before.linear_interpolate(corner, t)
						var to_corner = corner.linear_interpolate(p_after, t)
						var arc_pt = from_corner.linear_interpolate(to_corner, t)
						result.append(arc_pt)
						factors.append(1.0)
					result.append(p_after)
					factors.append(1.0)
				else:
					# Concave: bevel cut with reduced distance for sharp angles
					var concave_d = d * (1.0 - sharpness * 0.85)
					var cp_before = source_points[i] - dir_in * concave_d
					var cp_after = source_points[i] + dir_out * concave_d
					result.append(cp_before)
					factors.append(1.0)
					result.append(cp_after)
					factors.append(1.0)
				continue

		result.append(source_points[i])
		factors.append(1.0)

	return [result, factors]


# Returns [factor_A, factor_B] in [0, 1] from a side_balance value in [-100, +100].
# 0 = symmetric (both 1.0). Positive shrinks Side A (OUTER); negative shrinks Side B (INNER).
func _side_balance_factors(side_balance: float) -> Array:
	var bal = clamp(side_balance / 100.0, -1.0, 1.0)
	var factor_a = 1.0 - max(0.0, bal)
	var factor_b = 1.0 - max(0.0, -bal)
	return [factor_a, factor_b]

# Unified bevel for BOTH direction. Adds arc points at sharp corners so the
# OUTER and INNER sides of a single combined mesh share the same centerline
# (no visible seam where they meet). Copied from DropShadowPaths.
func _bevel_points_for_both(pts: PoolVector2Array, closed: bool) -> PoolVector2Array:
	if pts.size() < 3:
		return pts

	var bevel_dist = 35.0
	var bevel_angle_threshold = 0.40
	var result = PoolVector2Array()
	var pt_count = pts.size()

	for i in range(pt_count):
		var has_prev = false
		var has_next = false
		var dir_in = Vector2.ZERO
		var dir_out = Vector2.ZERO

		if closed:
			has_prev = true
			has_next = true
			dir_in = (pts[i] - pts[(i - 1 + pt_count) % pt_count]).normalized()
			dir_out = (pts[(i + 1) % pt_count] - pts[i]).normalized()
		else:
			if i > 0:
				has_prev = true
				dir_in = (pts[i] - pts[i - 1]).normalized()
			if i < pt_count - 1:
				has_next = true
				dir_out = (pts[i + 1] - pts[i]).normalized()

		if has_prev and has_next:
			var dot = dir_in.dot(dir_out)
			if dot < bevel_angle_threshold:
				var prev_pt = pts[(i - 1 + pt_count) % pt_count] if closed else pts[i - 1]
				var next_pt = pts[(i + 1) % pt_count] if closed else pts[i + 1]
				var seg_in_len = pts[i].distance_to(prev_pt)
				var seg_out_len = pts[i].distance_to(next_pt)
				var d = min(bevel_dist, seg_in_len * 0.4, seg_out_len * 0.4)

				var p_before = pts[i] - dir_in * d
				var p_after = pts[i] + dir_out * d

				var arc_steps = 4
				result.append(p_before)
				var corner = pts[i]
				for s in range(1, arc_steps + 1):
					var t = float(s) / float(arc_steps + 1)
					var from_corner = p_before.linear_interpolate(corner, t)
					var to_corner = corner.linear_interpolate(p_after, t)
					var arc_pt = from_corner.linear_interpolate(to_corner, t)
					result.append(arc_pt)
				result.append(p_after)
				continue

		result.append(pts[i])

	return result


func _add_shadow_mesh(mesh_inst: MeshInstance2D, parent: Node2D, offset: Vector2,
		is_below_all: bool, line_global_xform: Transform2D, wall_node_id: String = ""):
	if is_below_all:
		# Place in the level-wide container; replicate the line's global transform
		# so that the mesh vertices (in line-local space) end up in the correct world position.
		# The offset is already in line-local space (pre-rotated by create_shadow).
		var container_inv = parent.global_transform.affine_inverse()
		var target_xform = container_inv * line_global_xform
		# Apply the line-local offset by translating within the line's coordinate frame
		target_xform.origin += target_xform.basis_xform(offset)
		mesh_inst.transform = target_xform
		mesh_inst.show_behind_parent = false
		mesh_inst.z_index = 0
		# Tag with wall node_id for orphan cleanup
		if wall_node_id != "":
			mesh_inst.set_meta("_ba_wall_id", wall_node_id)
	else:
		# Default: behind own wall only
		mesh_inst.show_behind_parent = true
		mesh_inst.z_index = 0
		mesh_inst.position = offset
	parent.add_child(mesh_inst)


#########################################################################################################
##  MODE REALISTIC (walls) — statique
#########################################################################################################

func _realistic_blur_px_from_frac(frac) -> float:
	frac = clamp(frac, 0.0, 1.0)
	if frac <= 0.0005:
		return 0.0
	return REALISTIC_BLUR_FLOOR_PX + frac * (REALISTIC_BLUR_MAX_PX - REALISTIC_BLUR_FLOOR_PX)

func _realistic_blur_kernel(blur_px, scale_f) -> Array:
	# [rayon en texels, mip_lod]. Le mip comble les trous radiaux du noyau au flou fort.
	var blur_vp = blur_px * scale_f
	var mip_lod = 0.0
	var spacing = blur_vp / float(REALISTIC_BLUR_QUALITY)
	if spacing > 1.0:
		mip_lod = log(spacing) / log(2.0)
	return [blur_vp, mip_lod]

func _apply_realistic_blur_params(mat, tsize, blur_px, scale_f, shadow_color, opacity, has_mips = true):
	var blur_vp = blur_px * scale_f
	var mip_lod = 0.0
	var quality = REALISTIC_BLUR_QUALITY
	if has_mips:
		var spacing = blur_vp / float(REALISTIC_BLUR_QUALITY)
		if spacing > 1.0:
			mip_lod = log(spacing) / log(2.0)
	else:
		# Session live (ViewportTexture sans mips) : on ne peut pas s'appuyer sur le mip
		# pour combler les trous du noyau -> on met assez d'anneaux (spacing<=1) pour ne
		# pas sous-échantillonner (sinon alpha trop faible = ombre terne). Plafonné (perf).
		quality = int(clamp(ceil(blur_vp), REALISTIC_BLUR_QUALITY, 40))
	mat.set_shader_param("shadow_color", shadow_color)
	mat.set_shader_param("shadow_strength", opacity)
	mat.set_shader_param("texel", Vector2(1.0 / tsize.x, 1.0 / tsize.y))
	mat.set_shader_param("blur_px", blur_vp)
	mat.set_shader_param("mip_lod", mip_lod)
	mat.set_shader_param("vertex_scale", Vector2((tsize.x + 2.0 * blur_vp) / tsize.x, (tsize.y + 2.0 * blur_vp) / tsize.y))
	mat.set_shader_param("blur_steps", REALISTIC_BLUR_STEPS)
	mat.set_shader_param("blur_quality", quality)

# Shader silhouette pour la copie Line2D du mur : blanc + alpha de la texture -> on
# capture la SILHOUETTE (forme), pas les couleurs du mur. Modulée (net) ou floutée.





func _get_wall_silhouette_shader() -> Shader:
	if _wall_silhouette_shader != null:
		return _wall_silhouette_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_mix;
uniform float clip_side = 0.0;   // 0 = pas de clip ; +1/-1 = ne garder qu'une moitié (UV.y</>0.5) pour Side A/B
// Étirement RADIAL par moitié, ancré au MILIEU de la texture (= ligne centrale du mur) :
// suit la déformation du ruban (f_out/f_in). quad_scale agrandit le quad (vertex) pour
// faire de la place, le fragment ré-échantillonne chaque moitié avec son facteur.
uniform float stretch_a = 1.0;   // facteur du côté UV.y < anchor_v
uniform float stretch_b = 1.0;   // facteur du côté UV.y > anchor_v
uniform float quad_scale = 1.0;  // = max(1, stretch_a, stretch_b)
uniform float tex_center_y = 0.0;   // y LOCAL de l'ancre = ligne centrale du MUR (scale vertex)
uniform float anchor_v = 0.5;       // ancre en UV.y = ligne centrale du MUR dans la texture
void vertex() {
	VERTEX.y = tex_center_y + (VERTEX.y - tex_center_y) * quad_scale;
}
void fragment() {
	// Même transformation MONDE que le ruban : d -> d*f, ancrée à la ligne centrale du
	// mur (anchor_v), PAS au milieu de la texture du sprite -> pas de dérive quand le
	// sprite est décentré/offset ou le mur asymétrique, proportions préservées.
	float v = (UV.y - anchor_v) * quad_scale;
	float f = v < 0.0 ? stretch_a : stretch_b;
	float uy = anchor_v + v / max(f, 0.001);
	if (uy < 0.0 || uy > 1.0) { discard; }
	vec2 uv2 = vec2(UV.x, uy);
	if (clip_side != 0.0 && (uv2.y - anchor_v) * clip_side < 0.0) { discard; }
	COLOR = vec4(1.0, 1.0, 1.0, texture(TEXTURE, uv2).a);
}
"""
	_wall_silhouette_shader = sh
	return _wall_silhouette_shader

# Flou polaire (identique au pipeline paths). Le mip pré-moyenne chaque échantillon.
func _get_realistic_vp_blur_shader() -> Shader:
	if _realistic_vp_shader != null:
		return _realistic_vp_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.6;
uniform vec2 texel = vec2(1.0);
uniform float blur_px = 0.0;
uniform float mip_lod = 0.0;
uniform vec2 vertex_scale = vec2(1.0);
uniform int blur_steps = 24;
uniform int blur_quality = 8;
uniform float crop_enabled = 0.0;   // Crop Blur (Side A/B) : discard là où crop_mask est opaque
uniform sampler2D crop_mask;
uniform float alpha_gain = 1.0;     // compensation Side sans crop (demi-silhouette) ; clampé à 1

varying vec2 v_scale;

void vertex() {
	v_scale = vertex_scale;
	VERTEX *= mat2(vec2(v_scale.x, 0.0), vec2(0.0, v_scale.y));
}

float samp(sampler2D tex, vec2 p) {
	if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) { return 0.0; }
	return textureLod(tex, p, mip_lod).a;
}

void fragment() {
	vec2 uv = UV * v_scale - (v_scale - vec2(1.0)) * 0.5;
	float crop_fade = 1.0;
	if (crop_enabled > 0.5) {
		// clamp = extension des pixels de bord : le masque atteint le bord du rect sur le
		// côté interdit -> les fragments au-delà (vertex_scale) restent croppés.
		// R = région interdite, G = région gardée (protection) : on ne coupe que là où
		// l'ombre gardée d'AUCUNE branche n'a le droit d'exister (R sans G) -> pas de
		// morsure quand une branche non adjacente (hairpin, courbe) passe à portée.
		vec2 cuv = clamp(uv, vec2(0.0), vec2(1.0));
		vec4 cm = texture(crop_mask, cuv);
		// R sans G = crop latéral (Side, binaire). B = Crop Ends, ATTÉNUATION continue :
		// 1 = coupe dure (dans l'axe du mur), dégradé latéral = fondu dans l'ombre voisine.
		if (cm.r > 0.5 && cm.g < 0.5) { discard; }
		crop_fade = 1.0 - min(cm.b, 1.0);
		if (crop_fade <= 0.003) { discard; }
	}
	float total = samp(TEXTURE, uv);
	float wsum = 1.0;
	float pi2 = 6.28318;
	for (int d = 0; d < 48; d++) {
		if (d >= blur_steps) { break; }
		float ang = pi2 * float(d) / float(blur_steps);
		vec2 dir = vec2(cos(ang), sin(ang));
		for (int i = 1; i <= 16; i++) {
			if (i > blur_quality) { break; }
			float frac = float(i) / float(blur_quality);
			vec2 sp = uv + dir * (blur_px * frac) * texel;
			float w = exp(-1.2 * frac * frac);
			total += samp(TEXTURE, sp) * w;
			wsum += w;
		}
	}
	float a = total / max(wsum, 0.0001);
	a = min(a * alpha_gain, 1.0) * crop_fade;
	if (a < 0.003) { discard; }
	COLOR = vec4(shadow_color.rgb, a * shadow_strength);
}
"""
	_realistic_vp_shader = sh
	return _realistic_vp_shader

# Libère une liste de nœuds d'ombre (swap atomique realistic).
# Radial offset / side balance (comme les paths) : rendent la silhouette asymétrique.
# r (radial) : bascule l'épaisseur d'un côté à l'autre (f_out=1-r, f_in=1+r, largeur totale
# constante -> décalage perpendiculaire). b (balance) : grossit UN seul côté.
func _make_radial(config: Dictionary):
	# Realistic : +/- inversés (vs simple) et portée du radial ×3.
	var r = -clamp(float(config.get("radial_offset", 0.0)) / 100.0, -1.0, 1.0) * 3.0
	var b = -clamp(float(config.get("side_balance", 0.0)) / 100.0, -1.0, 1.0)
	var dir = int(config.get("direction", ShadowDirection.BOTH))
	# Non-null dès que radial/side OU la direction (Side A/B) demande une silhouette
	# asymétrique/clippée. En Both sans radial/side -> null -> clone plein rapide.
	if abs(r) < 0.01 and abs(b) < 0.01 and dir == ShadowDirection.BOTH:
		return null
	# Le flag crop est GATÉ par le flou : en net il n'y a pas de débordement, le crop est
	# inactif et la silhouette Side reste réduite de moitié.
	var crop = config.get("crop_blur", false)
	if _realistic_blur_px_from_frac(config.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2))) < REALISTIC_MIN_BLUR_PX:
		crop = false
	return {"r": r, "b": b, "dir": dir, "crop": crop}

# Côté à garder (UV.y</>0.5) pour un sprite (endcap/portail) en Side A/B, selon l'orientation
# de son UV.y vs la normale du mur. 0 = pas de clip (Both).
func _sprite_clip_side(clone, wall_normal, dir) -> float:
	if dir == ShadowDirection.BOTH:
		return 0.0
	var s = _sprite_uvy_sign(clone, wall_normal)
	if s == 0.0:
		return 0.0
	return s if dir == ShadowDirection.OUTER else -s

var _tex_vband_cache = {}
# Étendue verticale OPAQUE d'une texture (fractions 0..1 de sa hauteur, [v_min, v_max)).
# Échantillonnage par pas en X (<=64 colonnes) -> scan unique ~10-30ms, mis en CACHE par
# RID (+ région). Texture nulle ou illisible = pleine hauteur (comportement "plein" de
# la silhouette). Sert à mesurer la bande VISIBLE du mur et du sprite pour normaliser.
func _texture_vband(tex, region_enabled = false, region_rect = Rect2()) -> Array:
	if tex == null:
		return [0.0, 1.0]
	var key = str(tex.get_rid().get_id())
	if region_enabled:
		key += "_" + str(region_rect)
	if _tex_vband_cache.has(key):
		return _tex_vband_cache[key]
	var res = [0.0, 1.0]
	var img = tex.get_data()
	if img != null:
		if img.is_compressed():
			img.decompress()
	if img != null and not img.is_compressed():
		var x0 = 0
		var y0 = 0
		var w = img.get_width()
		var h = img.get_height()
		if region_enabled and region_rect.size.x >= 1.0 and region_rect.size.y >= 1.0:
			x0 = int(region_rect.position.x)
			y0 = int(region_rect.position.y)
			w = int(min(region_rect.size.x, img.get_width() - x0))
			h = int(min(region_rect.size.y, img.get_height() - y0))
		if w >= 1 and h >= 1:
			img.lock()
			var step_x = int(max(1, w / 64))
			var vmin = -1
			var vmax = -1
			for yy in range(h):
				var xx = 0
				while xx < w:
					if img.get_pixel(x0 + xx, y0 + yy).a > 0.1:
						if vmin < 0:
							vmin = yy
						vmax = yy
						break
					xx += step_x
			img.unlock()
			if vmin >= 0:
				res = [float(vmin) / float(h), float(vmax + 1) / float(h)]
	_tex_vband_cache[key] = res
	return res

# Direction de clip effective pour la silhouette : BOTH quand le crop est actif (la
# silhouette reste complète, le masque de sortie fait la sélection -> opacité de Both).
func _silhouette_clip_dir(radial) -> int:
	if radial == null:
		return ShadowDirection.BOTH
	if radial.get("crop", false):
		return ShadowDirection.BOTH
	return int(radial.get("dir", ShadowDirection.BOTH))

# Signe de l'orientation UV.y du sprite vs la +normale du mur (+1 : la moitié UV.y>0.5
# est du côté +normale). 0 si dégénéré (sprite parallèle au mur).
func _sprite_uvy_sign(clone, wall_normal) -> float:
	var uvy_dir = clone.transform.basis_xform(Vector2(0.0, -1.0 if clone.flip_v else 1.0))
	var d = uvy_dir.dot(wall_normal)
	if abs(d) < 0.0001:
		return 0.0
	return sign(d)

# Étirement d'un sprite silhouette (endcap/portail), NORMALISÉ PAR CONTENU : l'étendue
# OPAQUE du sprite (scan alpha, cache) est calée, de part et d'autre de la LIGNE
# CENTRALE DU MUR (`wall_point` projeté dans le repère du sprite), sur la bande VISIBLE
# du mur (étendue opaque de SA texture x facteurs radiaux f_out/f_in). L'ombre du
# portail remplit donc exactement la bande d'ombre du mur, quel que soit le padding
# transparent des textures (palissade, porte fine...). Le clip Side A/B est ancré à la
# ligne du mur (anchor_v). Convention Line2D (cf. strip) : UV.y=1 au bord +normale.
func _apply_sprite_radial_stretch(mat, clone, wall_normal, radial, wall_point, wall_tex, wall_width):
	if radial == null:
		return
	var s = _sprite_uvy_sign(clone, wall_normal)
	if s == 0.0:
		return
	var rect = clone.get_rect()
	if rect.size.y < 0.001 or wall_width < 1.0:
		return
	# Ancre : ligne centrale du mur dans le repère local du sprite, puis en UV.
	var anchor_y = clone.transform.affine_inverse().xform(wall_point).y
	anchor_y = clamp(anchor_y, rect.position.y, rect.position.y + rect.size.y)
	var anchor_v = (anchor_y - rect.position.y) / rect.size.y
	if clone.flip_v:
		anchor_v = 1.0 - anchor_v
	mat.set_shader_param("tex_center_y", anchor_y)
	mat.set_shader_param("anchor_v", anchor_v)
	# Bande visible du mur, par côté de sa ligne centrale (texture nulle = pleine largeur).
	var wb = _texture_vband(wall_tex)
	var d_out = max(wb[1] - 0.5, 0.02) * wall_width   # côté +normale (UV.y=1)
	var d_in = max(0.5 - wb[0], 0.02) * wall_width    # côté -normale (UV.y=0)
	# Étendue opaque du sprite par côté de l'ancre, en unités locales (UV flip-aware).
	var sb = _texture_vband(clone.texture, clone.region_enabled, clone.region_rect)
	var sv0 = sb[0]
	var sv1 = sb[1]
	if clone.flip_v:
		var tmp = sv0
		sv0 = 1.0 - sv1
		sv1 = 1.0 - tmp
	var ext_b = max(sv1 - anchor_v, 0.01) * rect.size.y
	var ext_a = max(anchor_v - sv0, 0.01) * rect.size.y
	# Échelle locale -> monde le long de la normale (le clone peut être scalé).
	var yscale = clone.transform.basis_xform(Vector2(0, 1)).length()
	if yscale < 0.0001:
		return
	var fac = _radial_side_factors(radial)
	var t_out = d_out * fac[0]
	var t_in = d_in * fac[1]
	var stretch_b = (t_out if s > 0.0 else t_in) / (ext_b * yscale)
	var stretch_a = (t_in if s > 0.0 else t_out) / (ext_a * yscale)
	stretch_a = clamp(stretch_a, 0.02, 50.0)
	stretch_b = clamp(stretch_b, 0.02, 50.0)
	mat.set_shader_param("stretch_a", stretch_a)
	mat.set_shader_param("stretch_b", stretch_b)
	mat.set_shader_param("quad_scale", max(1.0, max(stretch_a, stretch_b)))

func _radial_side_factors(radial) -> Array:
	var r = radial.get("r", 0.0) if radial != null else 0.0
	var b = radial.get("b", 0.0) if radial != null else 0.0
	var f_out = max(0.0, (1.0 - r) * (1.0 + max(0.0, b)))
	var f_in = max(0.0, (1.0 + r) * (1.0 + max(0.0, -b)))
	# L'extérieur ressort plus que l'intérieur (bridé aux coins par l'anti-repli). On retire
	# légèrement son excédent (>1) pour rééquilibrer les deux sens.
	if f_out > 1.0:
		f_out = 1.0 + (f_out - 1.0) * REALISTIC_OUTER_GAIN
	return [f_out, f_in]

func _radial_extent_factor(radial) -> float:
	if radial == null:
		return 1.0
	var f = _radial_side_factors(radial)
	return max(1.0, max(f[0], f[1]))

func _free_realistic_nodes(nodes):
	if nodes is Array:
		for n in nodes:
			if is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.free()

# Anti-doublons : supprime tout sprite realistic résiduel de CE mur (sauf `keep`). Couvre
# le cas own-wall (enfants du Line2D) et below-all (enfants du conteneur, filtrés par id mur).
# Pour chaque point beveled, sa longueur d'arc le long du tracé BRUT (projection sur le
# segment brut le plus proche) -> l'UV suit la longueur du mur (à travers les sommets),
# pas celle raccourcie du contour arrondi -> motif calé, pas de déphasage aux coins.
func _raw_arclen_map(bpts, rpts, closed) -> Array:
	var rn = rpts.size()
	var out = []
	if rn < 2:
		for _b in bpts:
			out.append(0.0)
		return out
	var rcum = [0.0]
	var acc = 0.0
	for i in range(1, rn):
		acc += rpts[i].distance_to(rpts[i - 1])
		rcum.append(acc)
	var seg_count = rn if closed else rn - 1
	for bp in bpts:
		var best_d = 1e20
		var best_u = 0.0
		for i in range(seg_count):
			var a = rpts[i]
			var b = rpts[(i + 1) % rn]
			var ab = b - a
			var abl2 = ab.length_squared()
			var t = 0.0
			if abl2 > 0.000001:
				t = clamp((bp - a).dot(ab) / abl2, 0.0, 1.0)
			var proj = a + ab * t
			var d = bp.distance_squared_to(proj)
			if d < best_d:
				best_d = d
				best_u = rcum[i] + t * ab.length()
		out.append(best_u)
	return out

func _build_silhouette_strip(line, bulge, radial, closed, bitmap_map = null) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var raw_pts = line.points
	if bulge != null:
		raw_pts = _bulge_disp_from(raw_pts, bulge)
	# Arrondit les coins secs (comme la densité de points d'un path) : sinon la normale
	# au sommet unique pince (unit) ou cisaille (miter) la texture. Le bevel répartit.
	var pts = _bevel_points_for_both(raw_pts, closed)
	var n = pts.size()
	if n < 2:
		return mesh
	# UV en U basé sur la longueur d'arc des points BRUTS (à travers le sommet, comme DD),
	# projetée sur les points beveled -> forme arrondie mais motif calé sur le mur (pas de
	# déphasage cumulé aux coins).
	var u_map = _raw_arclen_map(pts, raw_pts, closed)
	var normals = calculate_point_normals(pts, closed)
	if normals.size() != n:
		return mesh
	var base_half = line.width * 0.5
	var fac = _radial_side_factors(radial)
	var f_out = fac[0]   # côté extérieur (+normale)
	var f_in = fac[1]    # côté intérieur (-normale)
	# Grow/Shrink (ModifyPaths) : DD expose les largeurs PAR-POINT dans "widths". Si
	# présentes (et alignées sur les points) ET Grow/Shrink actif, la demi-largeur suit
	# le tapering ; sinon largeur uniforme. Le double contrôle évite d'appliquer un
	# "widths" périmé laissé par DD après désactivation. bh_arr[i] = demi-largeur locale.
	var gs_grow = line.get("Grow")
	var gs_shrink = line.get("Shrink")
	var gs_on = (gs_grow is bool and gs_grow) or (gs_shrink is bool and gs_shrink)
	var pw = line.get("widths")
	var has_pw = gs_on and pw != null and pw.size() == n
	var u_period = base_half * 2.0
	if line.texture != null and line.texture.get_width() > 0:
		u_period = float(line.texture.get_width())
	if u_period <= 0.0:
		u_period = 1.0
	# Boucle : DD ajuste le tiling pour un nombre ENTIER de tuiles sur le périmètre
	# (normalizeUV) -> la couture tombe juste. On fait pareil pour éviter le décalage.
	if closed and raw_pts.size() >= 2:
		var _rt = 0.0
		for _i in range(1, raw_pts.size()):
			_rt += raw_pts[_i].distance_to(raw_pts[_i - 1])
		_rt += raw_pts[raw_pts.size() - 1].distance_to(raw_pts[0])
		if _rt > 0.0:
			u_period = _rt / max(1.0, round(_rt / u_period))

	# Plafonnement au rayon de courbure : SEUL le côté CONCAVE (intérieur du virage)
	# peut se replier. Le côté convexe (extérieur) ne se replie jamais et ne doit PAS
	# être écrasé -> on ne clampe que le côté tourné vers le centre de courbure.
	var half_out = []
	var half_in = []
	var bh_arr = []
	for i in range(n):
		var bh = (float(pw[i]) * 0.5) if has_pw else base_half
		bh_arr.append(bh)
		var raw_out = bh * f_out
		var raw_in = bh * f_in
		var cap_out = raw_out + bh + 1.0   # plafond large = pas de clamp
		var cap_in = raw_in + bh + 1.0
		var has_prev = closed or i > 0
		var has_next = closed or i < n - 1
		if has_prev and has_next:
			var ip = ((i - 1 + n) % n) if closed else (i - 1)
			var inx = ((i + 1) % n) if closed else (i + 1)
			var pa = pts[ip]
			var pb = pts[i]
			var pc = pts[inx]
			var area2 = abs((pb - pa).cross(pc - pa))
			var ab = (pb - pa).length()
			var bc = (pc - pb).length()
			var ca = (pa - pc).length()
			if area2 > 0.001 and ab > 0.001 and bc > 0.001 and ca > 0.001:
				var safe = REALISTIC_FOLD_SAFETY * (ab * bc * ca) / (2.0 * area2)
				var d_in = (pb - pa).normalized()
				var d_out = (pc - pb).normalized()
				var curv = d_out - d_in
				if curv.length() > 0.0001:
					var to_center = curv.normalized()
					var nrmi = normals[i]
					if nrmi.length() > 0.0001:
						nrmi = nrmi.normalized()
					if to_center.dot(nrmi) > 0.0:
						cap_out = safe
					else:
						cap_in = safe
		half_out.append(min(raw_out, cap_out))
		half_in.append(min(raw_in, cap_in))

	for _pass in range(2):
		half_out = _smooth_half_array(half_out, n, closed)
		half_in = _smooth_half_array(half_in, n, closed)

	var verts = PoolVector2Array()
	var uvs = PoolVector2Array()
	# Mode bitmap (boucle) : la texture vient d'un rendu hors-écran du Line2D NATUREL
	# (tiling exact de DD). On échantillonne ce bitmap PAR POSITION : chaque bord du
	# ruban lit la position du bord NATUREL (+-base_half) -> la géométrie s'étire mais le
	# tiling reste celui de DD. bm_o/bm_c = région monde couverte par le bitmap.
	var use_bitmap = bitmap_map != null
	var bm_o = bitmap_map.get("origin", Vector2.ZERO) if use_bitmap else Vector2.ZERO
	var bm_c = bitmap_map.get("content", Vector2.ONE) if use_bitmap else Vector2.ONE
	if bm_c.x <= 0.0:
		bm_c.x = 1.0
	if bm_c.y <= 0.0:
		bm_c.y = 1.0
	# Direction (clip d'un côté) : OUTER (Side A) ne garde que la moitié +normale, INNER
	# (Side B) la moitié -normale, BOTH garde tout. Le bord rabattu vient au centre du
	# trait (position = pts[i], V = 0.5 -> milieu de la texture).
	var dir_clip = int(radial.get("dir", ShadowDirection.BOTH)) if radial != null else ShadowDirection.BOTH
	# Crop actif : silhouette COMPLÈTE (la sélection du côté se fait au masque de sortie)
	# -> le flou a autant de matière qu'en Both, l'opacité près du mur est identique.
	if radial != null and radial.get("crop", false):
		dir_clip = ShadowDirection.BOTH
	var keep_out = dir_clip != ShadowDirection.INNER
	var keep_in = dir_clip != ShadowDirection.OUTER
	var cum = 0.0
	for i in range(n):
		if i > 0:
			cum += pts[i].distance_to(pts[i - 1])
		var nrm = normals[i]
		if nrm.length() > 0.0001:
			nrm = nrm.normalized()
		var ho = half_out[i] if keep_out else 0.0
		var hi = half_in[i] if keep_in else 0.0
		verts.append(pts[i] + nrm * ho)
		verts.append(pts[i] - nrm * hi)
		if use_bitmap:
			var so = bh_arr[i] if keep_out else 0.0
			var si = bh_arr[i] if keep_in else 0.0
			uvs.append((pts[i] + nrm * so - bm_o) / bm_c)
			uvs.append((pts[i] - nrm * si - bm_o) / bm_c)
		else:
			var u = u_map[i] / u_period if i < u_map.size() else cum / u_period
			# V : bord extérieur (+normale) -> 1, intérieur -> 0 (miroir sinon). Bord
			# rabattu par la direction -> 0.5 (centre de la texture).
			var vo = 1.0 if keep_out else 0.5
			var vi = 0.0 if keep_in else 0.5
			uvs.append(Vector2(u, vo))
			uvs.append(Vector2(u, vi))

	var sections = n
	if closed:
		cum += pts[n - 1].distance_to(pts[0])
		var nrm0 = normals[0]
		if nrm0.length() > 0.0001:
			nrm0 = nrm0.normalized()
		var ho0 = half_out[0] if keep_out else 0.0
		var hi0 = half_in[0] if keep_in else 0.0
		verts.append(pts[0] + nrm0 * ho0)
		verts.append(pts[0] - nrm0 * hi0)
		if use_bitmap:
			var so0 = bh_arr[0] if keep_out else 0.0
			var si0 = bh_arr[0] if keep_in else 0.0
			uvs.append((pts[0] + nrm0 * so0 - bm_o) / bm_c)
			uvs.append((pts[0] - nrm0 * si0 - bm_o) / bm_c)
		else:
			var raw_total = 0.0
			for _ri in range(1, raw_pts.size()):
				raw_total += raw_pts[_ri].distance_to(raw_pts[_ri - 1])
			if raw_pts.size() >= 2:
				raw_total += raw_pts[raw_pts.size() - 1].distance_to(raw_pts[0])
			var u0 = raw_total / u_period
			var vo0 = 1.0 if keep_out else 0.5
			var vi0 = 0.0 if keep_in else 0.5
			uvs.append(Vector2(u0, vo0))
			uvs.append(Vector2(u0, vi0))
		sections = n + 1

	var indices = PoolIntArray()
	for s in range(sections - 1):
		var a_out = s * 2
		var a_in = s * 2 + 1
		var b_out = (s + 1) * 2
		var b_in = (s + 1) * 2 + 1
		indices.append(a_out)
		indices.append(a_in)
		indices.append(b_out)
		indices.append(b_out)
		indices.append(a_in)
		indices.append(b_in)

	if verts.size() < 3 or indices.size() < 3:
		return mesh
	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
	arrays[ArrayMesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Lissage 5-tap d'un tableau de demi-largeurs (boucle ou bornes).

func _smooth_half_array(arr: Array, n: int, closed: bool) -> Array:
	var out = []
	for i in range(n):
		var acc = 0.0
		var cnt = 0
		for k in range(-2, 3):
			var j = i + k
			if closed:
				j = (j + n) % n
			else:
				j = int(clamp(j, 0, n - 1))
			acc += arr[j]
			cnt += 1
		out.append(acc / float(cnt))
	return out

# Nœud silhouette : Line2D (cas normal) ou MeshInstance2D ruban texturé (radial/side
# balance actif, pour découpler épaisseur et tiling). bake = true -> shader silhouette
# blanche (alpha) pour la capture viewport ; bake = false -> shader teinté (ombre nette).

func _get_silhouette_bake_shader() -> Shader:
	if _silhouette_bake_shader != null:
		return _silhouette_bake_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_mix;
uniform sampler2D tex;
uniform bool tiled = true;
// Compatibilité ModifyPaths (n'agit qu'en mode tiled / path ouvert ; en mode bitmap
// de boucle, ces effets sont déjà cuits dans la texture capturée).
uniform float start_point = 0.0;
uniform bool path_flip_vertical = false;
uniform bool FadeIn = false;
uniform bool FadeOut = false;
uniform float path_length_in_uv = 0.0;
uniform float fade_distance = 10.0;
void fragment() {
	float a;
	if (tiled) {
		float orig_x = UV.x;
		float vy = path_flip_vertical ? clamp(1.0 - UV.y, 0.0, 1.0) : clamp(UV.y, 0.0, 1.0);
		a = texture(tex, vec2(fract(orig_x + start_point), vy)).a;
		if (path_length_in_uv > 0.0) {
			float f_dist = 0.01 * fade_distance * path_length_in_uv;
			if (FadeIn && orig_x < f_dist) { a *= clamp(orig_x / f_dist, 0.0, 1.0); }
			if (FadeOut && orig_x > path_length_in_uv - f_dist) { a *= 1.0 - clamp((orig_x - (path_length_in_uv - f_dist)) / f_dist, 0.0, 1.0); }
		}
	} else {
		a = texture(tex, clamp(UV, vec2(0.0), vec2(1.0))).a;
	}
	COLOR = vec4(1.0, 1.0, 1.0, a);
}
"""
	_silhouette_bake_shader = sh
	return sh

# Shader silhouette teintée (ombre nette directe).
var _silhouette_tint_shader = null


# Entrée du mode realistic (statique). Silhouette = clones des Line2D du mur (rendu
# exact de DD, trous de portails inclus) capturés dans un viewport, puis Sprite
# décalé + (net : modulé | flou : shader polaire), rendu sous le mur.
func create_realistic_shadow_wall(path, config: Dictionary, line):
	if line == null:
		line = get_line2d(path)
	if line == null or not is_instance_valid(line):
		return

	# Segments visuels du mur (Line2D, déjà coupés autour des portails par DD). On ne
	# filtre PAS sur .texture : DD texture souvent via un material -> .texture = null. La
	# silhouette = la FORME du Line2D (largeur), alpha via la texture si présente sinon plein.
	var tex_width = 0.0
	for ci in range(path.get_child_count()):
		var ch = path.get_child(ci)
		if ch is Line2D and ch.get_point_count() >= 2 and ch.width > tex_width:
			tex_width = ch.width
	var segments = []
	for ci2 in range(path.get_child_count()):
		var ch2 = path.get_child(ci2)
		if ch2 is Line2D and ch2.get_point_count() >= 2 and abs(ch2.width - tex_width) < 0.01:
			segments.append(ch2)
	if segments.size() == 0 or tex_width < 1.0:
		return

	var opacity = config.get("opacity_realistic", config.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"]))
	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	var below_all = config.get("below_all_walls", false)
	# Le rayon de flou est piloté par le slider Blur dédié (0..1 -> 0..REALISTIC_BLUR_MAX_PX).
	var blur_px = _realistic_blur_px_from_frac(config.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2)))
	var do_blur = blur_px >= REALISTIC_MIN_BLUR_PX
	var radial = _make_radial(config)

	# Parenting (même modèle que l'ombre simple : sous son mur, ou conteneur below-all).
	var shadow_parent = _get_wall_r_wrapper(line)
	var line_global_xform = line.global_transform
	var wall_nid = str(path.get_meta("node_id")) if path.has_meta("node_id") else ""
	if below_all:
		var ba = _get_below_all_container(line)
		if ba != null:
			shadow_parent = ba
	var offset = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	if line.rotation != 0.0:
		offset = offset.rotated(-line.rotation)

	var nid = path.get_instance_id()
	var gen = _realistic_gen.get(nid, 0) + 1
	_realistic_gen[nid] = gen
	_wall_r_capturing[nid] = gen   # le monitor saute ce mur tant que cette capture est en vol

	# bbox de tous les points des segments, en espace LINE-local.
	var line_inv = line.global_transform.affine_inverse()
	var seg_xf = []
	var have = false
	var minp = Vector2.ZERO
	var maxp = Vector2.ZERO
	for seg in segments:
		var xf = line_inv * seg.global_transform
		seg_xf.append(xf)
		for p in seg.points:
			var lp = xf.xform(p)
			if not have:
				minp = lp
				maxp = lp
				have = true
			else:
				minp.x = min(minp.x, lp.x)
				minp.y = min(minp.y, lp.y)
				maxp.x = max(maxp.x, lp.x)
				maxp.y = max(maxp.y, lp.y)
	if not have:
		return
	var margin = tex_width * _radial_extent_factor(radial)
	var origin = minp - Vector2(margin, margin)
	var content = (maxp - minp) + Vector2(2.0 * margin, 2.0 * margin)
	if content.x < 1.0 or content.y < 1.0:
		return
	var scale_f = REALISTIC_VP_DOWNSAMPLE
	var big = max(content.x, content.y)
	if big * scale_f > REALISTIC_VP_MAX_DIM:
		scale_f = REALISTIC_VP_MAX_DIM / big
	var vp_size = Vector2(max(ceil(content.x * scale_f), 1.0), max(ceil(content.y * scale_f), 1.0))
	var base_pos = origin + content * 0.5

	# Viewport : clone chaque segment (shader silhouette) dans un conteneur mis à l'échelle.
	var vp = Viewport.new()
	vp.size = vp_size
	vp.transparent_bg = true
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.render_target_v_flip = false
	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	var container = Node2D.new()
	container.scale = Vector2(scale_f, scale_f)
	container.position = -origin * scale_f
	vp.add_child(container)
	# Boucle + radial : bitmap de la texture NATURELLE (phase DD exacte). CACHÉ par hash de
	# points -> une seule capture tant que la géométrie ne change pas (radial/offset/couleur
	# ne l'invalident pas) -> pas de re-render à chaque réglage.
	var loop_bitmap = null
	if radial != null and is_path_closed(path) and segments.size() == 1:
		var lsig = _get_points_hash(path)
		if _wall_loop_nat.has(nid) and _wall_loop_nat[nid].get("sig") == lsig and _wall_loop_nat[nid].get("tex") != null:
			loop_bitmap = _wall_loop_nat[nid]
		else:
			var gn = _wall_r_geom(path, line, 1.0)   # région fixe (non-radiale) -> cachable
			if gn != null:
				var nvps = Vector2(max(ceil(gn["content"].x * gn["scale_f"]), 1.0), max(ceil(gn["content"].y * gn["scale_f"]), 1.0))
				var pvp = Viewport.new()
				pvp.size = nvps
				pvp.transparent_bg = true
				pvp.usage = Viewport.USAGE_2D
				pvp.disable_3d = true
				pvp.hdr = false
				pvp.render_target_v_flip = false
				pvp.render_target_update_mode = Viewport.UPDATE_ONCE
				var pcont = Node2D.new()
				pcont.scale = Vector2(gn["scale_f"], gn["scale_f"])
				pcont.position = -gn["origin"] * gn["scale_f"]
				pvp.add_child(pcont)
				var nat = segments[0].duplicate(0)
				for nc in nat.get_children():
					nc.free()
				nat.set("Loop", true)
				nat.transform = seg_xf[0]
				nat.default_color = Color(1, 1, 1, 1)
				var nmat = ShaderMaterial.new()
				nmat.shader = _get_wall_silhouette_shader()
				nat.material = nmat
				pcont.add_child(nat)
				line.add_child(pvp)
				yield(global.Editor.get_tree(), "idle_frame")
				yield(global.Editor.get_tree(), "idle_frame")
				if _realistic_gen.get(nid, -1) != gen or not is_instance_valid(path) or not is_instance_valid(line) or not is_instance_valid(pvp):
					if is_instance_valid(pvp):
						pvp.queue_free()
					if _wall_r_capturing.get(nid, -1) == gen:
						_wall_r_capturing.erase(nid)
					return
				var pimg = pvp.get_texture().get_data()
				pvp.queue_free()
				if pimg != null:
					pimg.flip_y()
					var ptex = ImageTexture.new()
					ptex.create_from_image(pimg, Texture.FLAG_FILTER)
					loop_bitmap = {"tex": ptex, "origin": gn["origin"], "content": gn["content"], "sig": lsig}
					_wall_loop_nat[nid] = loop_bitmap
	_populate_wall_r_container(container, path, segments, seg_xf, line_inv, radial, loop_bitmap)
	# Crop Blur (Side A/B) et/ou Crop Ends : viewport masque aligné, capturé dans les
	# MÊMES idle frames.
	var _side_crop = _wall_crop_active(config) and do_blur
	var _ends_crop = config.get("crop_ends", false) and do_blur
	var mvp = null
	if _side_crop or _ends_crop:
		var mres = _make_wall_crop_viewport(vp, container, path, segments, seg_xf, line_inv,
			int(config.get("direction", ShadowDirection.BOTH)),
			_wall_crop_reach(blur_px, tex_width), false, Viewport.UPDATE_ONCE, _side_crop, _ends_crop)
		mvp = mres[0]
	line.add_child(vp)

	yield(global.Editor.get_tree(), "idle_frame")
	yield(global.Editor.get_tree(), "idle_frame")

	if _realistic_gen.get(nid, -1) != gen or not is_instance_valid(path) or not is_instance_valid(line) or not is_instance_valid(vp):
		if _wall_r_capturing.get(nid, -1) == gen:
			_wall_r_capturing.erase(nid)
		if is_instance_valid(vp):
			vp.queue_free()
		return
	var img = vp.get_texture().get_data()
	# Readback du masque AVANT le queue_free du viewport principal (mvp en est l'enfant).
	var mask_tex = null
	if mvp != null and is_instance_valid(mvp):
		var mimg = mvp.get_texture().get_data()
		if mimg != null:
			mimg.flip_y()
			mask_tex = ImageTexture.new()
			mask_tex.create_from_image(mimg, Texture.FLAG_FILTER)
	vp.queue_free()
	if img == null:
		if _wall_r_capturing.get(nid, -1) == gen:
			_wall_r_capturing.erase(nid)
		return
	img.flip_y()
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER)


	# Réutilise le sprite existant s'il y en a un (jamais deux -> pas de duplication). On
	# libère d'abord tout autre nœud d'ombre de ce mur (mesh simple, sprites traînards).
	var spr = null
	var old_nodes = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	if old_nodes is Array:
		for n in old_nodes:
			if is_instance_valid(n) and (n is Sprite) and spr == null:
				spr = n   # on garde le premier sprite pour le réutiliser
			elif is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.free()
	if spr == null:
		spr = Sprite.new()
	spr.name = "DropShadowRealistic"
	spr.texture = tex
	spr.centered = true
	spr.z_as_relative = true
	spr.set_meta("_wall_r_owner", nid)   # tag propriétaire -> purge exhaustive fiable
	var mat = spr.material if spr.material is ShaderMaterial else ShaderMaterial.new()
	mat.shader = _get_realistic_vp_blur_shader()
	spr.material = mat
	_apply_wall_r_params(mat, vp_size, blur_px, scale_f, shadow_color, opacity)
	_apply_wall_crop_params(mat, mask_tex)
	mat.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	if spr.get_parent() == null:
		shadow_parent.add_child(spr)
	elif spr.get_parent() != shadow_parent:
		spr.get_parent().remove_child(spr)
		shadow_parent.add_child(spr)
	_place_wall_r_sprite(spr, shadow_parent, line, line_global_xform, base_pos, offset, scale_f)
	if shadow_parent != line and wall_nid != "":
		spr.set_meta("_ba_wall_id", wall_nid)
	path.set_meta(SHADOW_META_KEY, [spr])
	_purge_wall_r_sprites(path, line, nid, spr)
	# Le bake statique vient de donner au sprite une texture mipmappée : si une session
	# live existait, on libère son viewport persistant (le sprite ne le lit plus).
	if _wall_r_session.has(nid):
		var _sess = _wall_r_session[nid]
		_wall_r_session.erase(nid)
		_wall_r_last_req.erase(nid)
		if is_instance_valid(_sess["vp"]):
			_sess["vp"].queue_free()
	_wall_r_live[nid] = {"sprite": spr, "vp_size": vp_size, "scale_f": scale_f, "base_pos": base_pos, "parent": shadow_parent, "line": line, "line_xform": line_global_xform}
	if _wall_r_capturing.get(nid, -1) == gen:
		_wall_r_capturing.erase(nid)


# Géométrie realistic du mur : segments, transforms, bbox, échelle. margin_factor fixe
# (2.0 pour la session live -> couvre tout radial sans resize).
func _wall_r_geom(path, line, margin_factor):
	var tex_width = 0.0
	for ci in range(path.get_child_count()):
		var ch = path.get_child(ci)
		if ch is Line2D and ch.get_point_count() >= 2 and ch.width > tex_width:
			tex_width = ch.width
	var segments = []
	for ci2 in range(path.get_child_count()):
		var ch2 = path.get_child(ci2)
		if ch2 is Line2D and ch2.get_point_count() >= 2 and abs(ch2.width - tex_width) < 0.01:
			segments.append(ch2)
	if segments.size() == 0 or tex_width < 1.0:
		return null
	var line_inv = line.global_transform.affine_inverse()
	var seg_xf = []
	var have = false
	var minp = Vector2.ZERO
	var maxp = Vector2.ZERO
	for seg in segments:
		var xf = line_inv * seg.global_transform
		seg_xf.append(xf)
		for p in seg.points:
			var lp = xf.xform(p)
			if not have:
				minp = lp
				maxp = lp
				have = true
			else:
				minp.x = min(minp.x, lp.x)
				minp.y = min(minp.y, lp.y)
				maxp.x = max(maxp.x, lp.x)
				maxp.y = max(maxp.y, lp.y)
	if not have:
		return null
	var margin = tex_width * margin_factor
	var origin = minp - Vector2(margin, margin)
	var content = (maxp - minp) + Vector2(2.0 * margin, 2.0 * margin)
	if content.x < 1.0 or content.y < 1.0:
		return null
	var scale_f = REALISTIC_VP_DOWNSAMPLE
	var big = max(content.x, content.y)
	if big * scale_f > REALISTIC_VP_MAX_DIM:
		scale_f = REALISTIC_VP_MAX_DIM / big
	return {"tex_width": tex_width, "segments": segments, "seg_xf": seg_xf, "line_inv": line_inv, "origin": origin, "content": content, "scale_f": scale_f, "base_pos": origin + content * 0.5}

# Démarre une session LIVE : viewport persistant (UPDATE_ALWAYS) dont le sprite lit
# directement la ViewportTexture -> radial/side se voient en direct, sans readback.
func _start_wall_r_session(path, line, shadow_parent, line_global_xform, wall_nid, radial, offset, shadow_color, opacity, blur_px):
	var nid = path.get_instance_id()
	var g = _wall_r_geom(path, line, 2.0)
	# Session sans mips : plafonne l'échelle pour que le rayon de flou tienne dans les
	# anneaux (pas de sous-échantillonnage -> couleur non ternie). Le flou masque la basse déf.
	if blur_px > 0.5 and g != null:
		g["scale_f"] = min(g["scale_f"], float(REALISTIC_BLUR_QUALITY) / blur_px)
	if g == null:
		return
	# Viewport CARRÉ (dimension max) : la bbox axis-aligned grossit à la rotation, un carré
	# couvre n'importe quel angle sans clip. Plafonné à la résolution max.
	var _big = max(g["content"].x, g["content"].y) * g["scale_f"] * WALL_R_LIVE_HEADROOM
	_big = min(_big, REALISTIC_VP_MAX_DIM)
	var tsize = Vector2(max(ceil(_big), 1.0), max(ceil(_big), 1.0))
	var vp = Viewport.new()
	vp.size = tsize
	vp.transparent_bg = true
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.render_target_v_flip = true
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	var container = Node2D.new()
	container.scale = Vector2(g["scale_f"], g["scale_f"])
	container.position = tsize * 0.5 - g["base_pos"] * g["scale_f"]
	vp.add_child(container)
	_populate_wall_r_container(container, path, g["segments"], g["seg_xf"], g["line_inv"], radial, _wall_loop_nat.get(path.get_instance_id()))
	# Crop Blur et/ou Crop Ends : masque persistant (UPDATE_ALWAYS) aligné sur le viewport de session.
	var crop_on = radial != null and radial.get("crop", false) and int(radial.get("dir", ShadowDirection.BOTH)) != ShadowDirection.BOTH and blur_px >= REALISTIC_MIN_BLUR_PX
	var ends_on = _wall_cfg_crop_ends(path) and blur_px >= REALISTIC_MIN_BLUR_PX
	var mvp = null
	var mcont = null
	var mtex = null
	if crop_on or ends_on:
		var mres = _make_wall_crop_viewport(vp, container, path, g["segments"], g["seg_xf"], g["line_inv"],
			int(radial.get("dir")) if radial != null else ShadowDirection.BOTH, _wall_crop_reach(blur_px, g["tex_width"]), true, Viewport.UPDATE_ALWAYS, crop_on, ends_on)
		mvp = mres[0]
		mcont = mres[1]
		mtex = mvp.get_texture()
		mtex.flags = Texture.FLAG_FILTER
	line.add_child(vp)
	var vtex = vp.get_texture()
	vtex.flags = Texture.FLAG_FILTER
	var spr = null
	var old_nodes = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	if old_nodes is Array:
		for n in old_nodes:
			if is_instance_valid(n) and (n is Sprite) and spr == null:
				spr = n
			elif is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.free()
	if spr == null:
		spr = Sprite.new()
	spr.name = "DropShadowRealistic"
	spr.texture = vtex
	spr.centered = true
	spr.z_as_relative = true
	spr.set_meta("_wall_r_owner", nid)
	var mat = spr.material if spr.material is ShaderMaterial else ShaderMaterial.new()
	mat.shader = _get_realistic_vp_blur_shader()
	spr.material = mat
	_apply_realistic_blur_params(mat, tsize, blur_px, g["scale_f"], shadow_color, opacity, false)
	_apply_wall_crop_params(mat, mtex)
	mat.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	if spr.get_parent() == null:
		shadow_parent.add_child(spr)
	elif spr.get_parent() != shadow_parent:
		spr.get_parent().remove_child(spr)
		shadow_parent.add_child(spr)
	_place_wall_r_sprite(spr, shadow_parent, line, line_global_xform, g["base_pos"], offset, g["scale_f"])
	if shadow_parent != line and wall_nid != "":
		spr.set_meta("_ba_wall_id", wall_nid)
	path.set_meta(SHADOW_META_KEY, [spr])
	_purge_wall_r_sprites(path, line, nid, spr)
	_wall_r_session[nid] = {"vp": vp, "container": container, "sprite": spr, "scale_f": g["scale_f"], "base_pos": g["base_pos"], "tsize": tsize, "parent": shadow_parent, "line": line, "line_xform": line_global_xform, "mvp": mvp, "mcont": mcont}
	_wall_r_last_req[nid] = OS.get_ticks_msec()
	_wall_r_live.erase(nid)

# Met à jour une session live existante : repopule la silhouette (radial) + params sprite.
func _update_wall_r_session(nid, path, line, radial, offset, shadow_color, opacity, blur_px):
	var s = _wall_r_session[nid]
	if not is_instance_valid(s["sprite"]) or not is_instance_valid(s["vp"]) or not is_instance_valid(s["container"]):
		_wall_r_session.erase(nid)
		return false
	var g = _wall_r_geom(path, line, 2.0)
	# Session sans mips : plafonne l'échelle pour que le rayon de flou tienne dans les
	# anneaux (pas de sous-échantillonnage -> couleur non ternie). Le flou masque la basse déf.
	if blur_px > 0.5 and g != null:
		g["scale_f"] = min(g["scale_f"], float(REALISTIC_BLUR_QUALITY) / blur_px)
	if g == null:
		return true
	for c in s["container"].get_children():
		s["container"].remove_child(c)
		c.free()
	s["container"].scale = Vector2(g["scale_f"], g["scale_f"])
	s["container"].position = s["tsize"] * 0.5 - g["base_pos"] * g["scale_f"]
	_populate_wall_r_container(s["container"], path, g["segments"], g["seg_xf"], g["line_inv"], radial, _wall_loop_nat.get(path.get_instance_id()))
	# Crop Blur / Crop Ends : synchronise le masque avec l'état courant.
	var crop_on = radial != null and radial.get("crop", false) and int(radial.get("dir", ShadowDirection.BOTH)) != ShadowDirection.BOTH and blur_px >= REALISTIC_MIN_BLUR_PX
	var ends_on = _wall_cfg_crop_ends(path) and blur_px >= REALISTIC_MIN_BLUR_PX
	var need_mask = crop_on or ends_on
	var mvp = s.get("mvp")
	var mcont = s.get("mcont")
	if need_mask and (mvp == null or not is_instance_valid(mvp) or mcont == null or not is_instance_valid(mcont)):
		# Masque absent de cette session (ex. Both -> Side en cours de session) : on ne peut
		# pas l'ajouter à chaud -> false, le chemin settle re-bake reconstruit tout (l'ancien
		# sprite reste affiché entre-temps, pas de flicker).
		return false
	if need_mask:
		for mc in mcont.get_children():
			mcont.remove_child(mc)
			mc.free()
		mcont.scale = s["container"].scale
		mcont.position = s["container"].position
		if crop_on:
			_populate_wall_crop_mask(mcont, path, g["segments"], g["seg_xf"], g["line_inv"], int(radial.get("dir")), _wall_crop_reach(blur_px, g["tex_width"]))
		if ends_on:
			_populate_wall_end_crop(mcont, path, g["segments"], g["seg_xf"], g["line_inv"], _wall_crop_reach(blur_px, g["tex_width"]))
	if s["sprite"].material is ShaderMaterial:
		_apply_realistic_blur_params(s["sprite"].material, s["tsize"], blur_px, g["scale_f"], shadow_color, opacity, false)
		if need_mask:
			_apply_wall_crop_params(s["sprite"].material, mvp.get_texture())
		else:
			s["sprite"].material.set_shader_param("crop_enabled", 0.0)
		s["sprite"].material.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	s["scale_f"] = g["scale_f"]
	s["base_pos"] = g["base_pos"]
	_place_wall_r_sprite(s["sprite"], s["parent"], line, s["line_xform"], g["base_pos"], offset, g["scale_f"])
	_wall_r_last_req[nid] = OS.get_ticks_msec()
	return true

func _populate_wall_r_container(container, path, segments, seg_xf, line_inv, radial, loop_bitmap = null):
	var seg_closed = is_path_closed(path) and segments.size() == 1
	var sil = _get_wall_silhouette_shader()
	for si in range(segments.size()):
		var seg2 = segments[si]
		if seg_closed and radial != null and loop_bitmap != null:
			# Boucle + radial : strip-mesh échantillonnant le BITMAP naturel (phase DD cuite)
			# par position monde -> le radial déforme la géométrie, la texture reste calée.
			var strip_b = _build_silhouette_strip(seg2, null, radial, seg_closed, loop_bitmap)
			if strip_b.get_surface_count() > 0:
				var mi_b = MeshInstance2D.new()
				mi_b.mesh = strip_b
				mi_b.transform = seg_xf[si]
				var bmat_b = ShaderMaterial.new()
				bmat_b.shader = _get_silhouette_bake_shader()
				bmat_b.set_shader_param("tex", loop_bitmap["tex"])
				bmat_b.set_shader_param("tiled", false)   # échantillonnage direct du bitmap
				mi_b.material = bmat_b
				container.add_child(mi_b)
			continue
		if seg_closed:
			# Boucle (sans radial, ou session) : on DUPLIQUE le Line2D du mur (avec Loop)
			# -> tiling EXACT comme DD.
			var lclone = seg2.duplicate(0)
			for lc in lclone.get_children():
				lc.free()
			lclone.set("Loop", true)
			lclone.transform = seg_xf[si]
			lclone.default_color = Color(1, 1, 1, 1)
			var lmat = ShaderMaterial.new()
			lmat.shader = sil
			lclone.material = lmat
			container.add_child(lclone)
			continue
		if radial != null:
			# Radial/side (murs ouverts) : ruban-mesh texturé (asymétrie + coins miter).
			var strip = _build_silhouette_strip(seg2, null, radial, seg_closed)
			if strip.get_surface_count() > 0:
				var mi = MeshInstance2D.new()
				mi.mesh = strip
				mi.transform = seg_xf[si]
				var bmat = ShaderMaterial.new()
				bmat.shader = _get_silhouette_bake_shader()
				bmat.set_shader_param("tex", seg2.texture)
				bmat.set_shader_param("tiled", true)
				mi.material = bmat
				container.add_child(mi)
			continue
		var clone = Line2D.new()
		clone.points = seg2.points
		clone.width = seg2.width
		clone.texture = seg2.texture          # texture du mur -> la silhouette suit sa forme (alpha)
		clone.texture_mode = seg2.texture_mode
		clone.joint_mode = seg2.joint_mode
		clone.begin_cap_mode = seg2.begin_cap_mode
		clone.end_cap_mode = seg2.end_cap_mode
		clone.transform = seg_xf[si]
		clone.default_color = Color(1, 1, 1, 1)
		var cmat = ShaderMaterial.new()
		cmat.shader = sil                     # blanc + alpha : sans texture -> plein ; avec -> forme réelle
		clone.material = cmat
		container.add_child(clone)
	# Endcaps : Sprites enfants de CHAQUE segment Line2D (CreateWallEnd, murs ouverts).
	# On les clone pour que leur forme (EndTexture) apparaisse dans l'ombre. En radial, on
	# les ÉTIRE depuis le milieu comme le ruban (normale de l'extrémité proche).
	for si2 in range(segments.size()):
		var seg3 = segments[si2]
		var xf3 = seg_xf[si2]
		var n_first = Vector2(0, 1)
		var n_last = Vector2(0, 1)
		var p_first = Vector2.ZERO
		var p_last = Vector2.ZERO
		if radial != null and seg3.points.size() >= 2:
			var nrm3 = calculate_point_normals(seg3.points, seg_closed)
			p_first = xf3.xform(seg3.points[0])
			p_last = xf3.xform(seg3.points[seg3.points.size() - 1])
			if nrm3.size() > 0:
				n_first = xf3.basis_xform(nrm3[0]).normalized()
				n_last = xf3.basis_xform(nrm3[nrm3.size() - 1]).normalized()
		for ei in range(seg3.get_child_count()):
			var ech = seg3.get_child(ei)
			if not (ech is Sprite) or ech.texture == null:
				continue
			# NE PAS re-capturer notre propre ombre (sprite enfant de la line/segment) :
			# sinon on la bake dans la nouvelle capture -> bande supplémentaire à chaque passage.
			if str(ech.name).begins_with("DropShadowRealistic") or ech.has_meta("_wall_r_owner"):
				continue
			var ecl = Sprite.new()
			ecl.texture = ech.texture
			ecl.centered = ech.centered
			ecl.offset = ech.offset
			ecl.flip_h = ech.flip_h
			ecl.flip_v = ech.flip_v
			ecl.region_enabled = ech.region_enabled
			ecl.region_rect = ech.region_rect
			ecl.transform = line_inv * ech.global_transform
			var nn_e = Vector2(0, 1)
			var wp_e = Vector2.ZERO
			if radial != null:
				var pos = ecl.transform.origin
				if pos.distance_to(p_first) <= pos.distance_to(p_last):
					nn_e = n_first
					wp_e = p_first
				else:
					nn_e = n_last
					wp_e = p_last
			ecl.self_modulate = Color(1, 1, 1, 1)
			var emat = ShaderMaterial.new()
			emat.shader = sil
			emat.set_shader_param("clip_side", _sprite_clip_side(ecl, nn_e, _silhouette_clip_dir(radial)))
			_apply_sprite_radial_stretch(emat, ecl, nn_e, radial, wp_e, seg3.texture, seg3.width)
			ecl.material = emat
			container.add_child(ecl)
	# Portails : ajoute leur forme (sprite) à la silhouette pour les portails NON skippés
	# (ceux avec une vraie texture porte/fenêtre). Les portails skippés (ouverture nue)
	# laissent le trou. Comble ainsi le gap du mur avec la forme réelle du portail.
	var _skip_portals = false
	var _pnode_id = str(path.get_meta("node_id")) if path.has_meta("node_id") else ""
	if _pnode_id != "" and global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(_pnode_id):
		_skip_portals = global.ModMapData[SHADOW_DATA_KEY][_pnode_id].get("skip_portals", false)
	# Radial/side : normales du mur (en line-local) pour orienter clip et étirement des
	# portails (étirés depuis le milieu comme le ruban, pas translatés).
	var _wall_norms = []   # [{p, n}] tous les points du mur en line-local
	if radial != null and segments.size() > 0:
		for _si in range(segments.size()):
			var _sn = calculate_point_normals(segments[_si].points, seg_closed)
			for _pi in range(segments[_si].points.size()):
				var _pll = seg_xf[_si].xform(segments[_si].points[_pi])
				var _nll = seg_xf[_si].basis_xform(_sn[_pi]).normalized() if _pi < _sn.size() else Vector2(0, 1)
				_wall_norms.append({"p": _pll, "n": _nll})
	for pci in range(path.get_child_count()):
		var pc = path.get_child(pci)
		if not (str(pc.name).begins_with("Portal") or str(pc.name).begins_with("@Portal")):
			continue
		if _should_skip_portal(pc, _skip_portals):
			continue
		if pc.get_child_count() == 0:
			continue
		var psp = pc.get_child(0)
		if not (psp is Sprite) or psp.texture == null:
			continue
		var pcl = Sprite.new()
		pcl.texture = psp.texture
		pcl.centered = psp.centered
		pcl.offset = psp.offset
		pcl.flip_h = psp.flip_h
		pcl.flip_v = psp.flip_v
		pcl.region_enabled = psp.region_enabled
		pcl.region_rect = psp.region_rect
		pcl.transform = line_inv * psp.global_transform
		# Suit le radial : normale + point du mur les plus proches (clip + ancre d'étirement).
		var nn_p = Vector2(0, 1)
		var wp_p = Vector2.ZERO
		if _wall_norms.size() > 0:
			var ppos = pcl.transform.origin
			var _best = _wall_norms[0]
			var _bestd = 1.0e20
			for wn in _wall_norms:
				var dd = ppos.distance_squared_to(wn["p"])
				if dd < _bestd:
					_bestd = dd
					_best = wn
			nn_p = _best["n"]
			wp_p = _best["p"]
		pcl.self_modulate = Color(1, 1, 1, 1)
		var pmat = ShaderMaterial.new()
		pmat.shader = sil
		pmat.set_shader_param("clip_side", _sprite_clip_side(pcl, nn_p, _silhouette_clip_dir(radial)))
		_apply_sprite_radial_stretch(pmat, pcl, nn_p, radial, wp_p, segments[0].texture, segments[0].width)
		pcl.material = pmat
		container.add_child(pcl)

# --- Crop Blur (Side A/B, realistic) ---------------------------------------------------
# Le flou polaire étale la silhouette (pourtant clippée au centre) au-delà de la ligne
# centrale du mur. Le masque = bande SOLIDE du côté interdit (centre -> reach), capturée
# dans un 2e viewport aligné sur la capture principale, passée au shader de flou qui
# discard là où le masque est opaque. Le crop SUIT l'offset X/Y du sprite (même espace
# texture que la silhouette). Le masque suit la polyligne (coins/courbes), pas un simple
# demi-plan, est prolongé aux extrémités (endcaps) et ponté aux portails.
var _crop_tint_shader = null
# Teinte additive du masque : R = côté interdit, G = côté gardé (protection). blend_add
# -> les recouvrements saturent, les deux canaux coexistent sur un même pixel.
func _get_crop_tint_shader() -> Shader:
	if _crop_tint_shader != null:
		return _crop_tint_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_add;
uniform vec4 tint = vec4(1.0, 0.0, 0.0, 1.0);
void fragment() {
	COLOR = tint * COLOR;   // COLOR de vertex = rampe des dégradés (blanc par défaut)
}
"""
	_crop_tint_shader = sh
	return sh

func _crop_opposite_dir(dir) -> int:
	return ShadowDirection.INNER if dir == ShadowDirection.OUTER else ShadowDirection.OUTER

func _crop_tint_mat(is_keep) -> ShaderMaterial:
	var m = ShaderMaterial.new()
	m.shader = _get_crop_tint_shader()
	m.set_shader_param("tint", Color(0, 1, 0, 1) if is_keep else Color(1, 0, 0, 1))
	return m

# Mesh de coupe d'extrémité en DÉGRADÉ : bande centrale = coupe DURE dans l'axe du mur
# (bleu=1, la "ligne rose"), ailes latérales en rampe 1->0 sur `fade` : la coupe
# s'estompe là où elle rencontre l'ombre voisine (coin intérieur d'un U...) au lieu
# d'y tailler un rectangle net.
func _end_crop_gradient_mesh(c, t, nrm, hard_half, fade, out_len) -> ArrayMesh:
	var verts = PoolVector2Array()
	var cols = PoolColorArray()
	var white = Color(1, 1, 1, 1)
	var black = Color(0, 0, 0, 1)
	var bands = [
		[-hard_half - fade, -hard_half, black, white],
		[-hard_half, hard_half, white, white],
		[hard_half, hard_half + fade, white, black],
	]
	for b in bands:
		var v00 = c + nrm * b[0]
		var v10 = c + nrm * b[1]
		var v01 = v00 + t * out_len
		var v11 = v10 + t * out_len
		verts.append(v00)
		cols.append(b[2])
		verts.append(v10)
		cols.append(b[3])
		verts.append(v01)
		cols.append(b[2])
		verts.append(v10)
		cols.append(b[3])
		verts.append(v11)
		cols.append(b[3])
		verts.append(v01)
		cols.append(b[2])
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var m = ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

func _crop_tint_mat_ends() -> ShaderMaterial:
	var m = ShaderMaterial.new()
	m.shader = _get_crop_tint_shader()
	m.set_shader_param("tint", Color(0, 0, 1, 1))   # BLEU = crop absolu (Crop Ends)
	return m

# crop_ends depuis la config SAUVÉE du mur (les sessions live n'ont pas la config).
func _wall_cfg_crop_ends(path) -> bool:
	if path == null or not is_instance_valid(path) or not path.has_meta("node_id"):
		return false
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return false
	var d = global.ModMapData[SHADOW_DATA_KEY].get(str(path.get_meta("node_id")))
	return d != null and d.get("crop_ends", false)

# Crop Ends : quads BLEUS (crop absolu, prioritaire sur la protection verte) au-delà du
# DERNIER PIXEL de l'endcap, perpendiculaires au mur, à chaque VRAIE extrémité (les
# coupes de portails sont exclues en consommant les 2 extrémités les plus proches de
# chaque portail). Sans endcap, le crop se fait à l'extrémité du mur. Indépendant du
# crop latéral, actif aussi en Both.
func _populate_wall_end_crop(container, path, segments, seg_xf, line_inv, reach):
	if is_path_closed(path) and segments.size() == 1:
		return
	var tex_width = segments[0].width if segments.size() > 0 else 20.0
	# Extrémités ouvertes (pos + tangente SORTANTE, line-local).
	var ends = []
	for si in range(segments.size()):
		var p = segments[si].points
		if p.size() < 2:
			continue
		var ta = p[1] - p[0]
		var tb = p[p.size() - 1] - p[p.size() - 2]
		if ta.length() > 0.001:
			ends.append({"p": seg_xf[si].xform(p[0]), "t": seg_xf[si].basis_xform(-ta.normalized()).normalized(), "used": false})
		if tb.length() > 0.001:
			ends.append({"p": seg_xf[si].xform(p[p.size() - 1]), "t": seg_xf[si].basis_xform(tb.normalized()).normalized(), "used": false})
	# Les coupes de PORTAILS ne sont pas des extrémités : chaque portail consomme ses
	# deux extrémités les plus proches.
	for pci in range(path.get_child_count()):
		var pc = path.get_child(pci)
		if not (str(pc.name).begins_with("Portal") or str(pc.name).begins_with("@Portal")):
			continue
		if not (pc is Node2D):
			continue
		var ppos = (line_inv * pc.get_global_transform()).origin
		for _k in range(2):
			var best = -1
			var bestd = 1.0e20
			for ei in range(ends.size()):
				if ends[ei]["used"]:
					continue
				var dd = ppos.distance_squared_to(ends[ei]["p"])
				if dd < bestd:
					bestd = dd
					best = ei
			if best >= 0:
				ends[best]["used"] = true
	for e in ends:
		if e["used"]:
			continue
		var end_p = e["p"]
		var t = e["t"]
		# Bord extérieur de l'endcap : projection max des coins du rect des Sprites
		# proches de l'extrémité sur la tangente sortante. 0 si pas d'endcap.
		var d_end = 0.0
		for si2 in range(segments.size()):
			for che in segments[si2].get_children():
				if not (che is Sprite) or che.texture == null:
					continue
				var sxf = seg_xf[si2] * che.transform
				if sxf.origin.distance_to(end_p) > tex_width * 4.0 + 64.0:
					continue
				var r = che.get_rect()
				for cx in [r.position.x, r.position.x + r.size.x]:
					for cy in [r.position.y, r.position.y + r.size.y]:
						var proj = (sxf.xform(Vector2(cx, cy)) - end_p).dot(t)
						if proj > d_end:
							d_end = proj
		var c = end_p + t * d_end
		var nrm = Vector2(-t.y, t.x)
		var mi = MeshInstance2D.new()
		mi.mesh = _end_crop_gradient_mesh(c, t, nrm, tex_width * 0.5 + 4.0, reach, reach + 8.0)
		mi.material = _crop_tint_mat_ends()
		container.add_child(mi)

# Gain d'alpha du flou : compense la silhouette DEMI-largeur du mode Side SANS crop
# (deux fois moins de matière à portée du noyau -> alpha ~/2 à flou fort). Le clamp à 1
# dans le shader le rend sans effet à flou faible (alpha déjà saturé près du mur).
func _crop_alpha_gain(radial) -> float:
	if radial == null:
		return 1.0
	if int(radial.get("dir", ShadowDirection.BOTH)) == ShadowDirection.BOTH:
		return 1.0
	if radial.get("crop", false):
		return 1.0   # crop actif : silhouette complète, pas de compensation
	# 2.0 = compensation théorique exacte à flou fort, mais le clamp élargit le halo
	# perçu -> trop vif. 1.5 = entre-deux validé visuellement.
	return 1.5

func _wall_crop_active(config) -> bool:
	return config.get("crop_blur", false) and int(config.get("direction", ShadowDirection.BOTH)) != ShadowDirection.BOTH

func _wall_crop_reach(blur_px, tex_width) -> float:
	# Couvre tout débordement possible : rayon de flou + demi-largeur gardée (+ marge).
	return blur_px + tex_width + 8.0

# Masque du côté interdit, en TRIANGLES : un QUAD par ARÊTE (normale d'arête, borné par
# le mur -> ne mord jamais le côté gardé, quel que soit l'angle) + un ÉVENTAIL d'arc aux
# coins CONVEXES côté interdit (comble le secteur entre deux quads sans dépasser leurs
# normales d'arête -> pas de triangle d'ombre résiduel, pas de morsure). Remplace le strip
# à normales miter : le clamp du miter (2.0) laissait un coin de masque ouvert aux angles
# aigus (triangles d'ombre côté interdit), et le bevel mordait le côté gardé.
# Les extrémités OUVERTES sont prolongées longitudinalement de `reach` (arête colinéaire
# supplémentaire) : couvre le flou des ENDCAPS et le débordement des ouvertures.
func _build_wall_crop_mesh(seg, dir, closed, reach) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var src = seg.points
	if not closed and src.size() >= 2:
		var t0 = src[1] - src[0]
		var t1 = src[src.size() - 1] - src[src.size() - 2]
		if t0.length() > 0.001 and t1.length() > 0.001:
			var ext = PoolVector2Array()
			ext.append(src[0] - t0.normalized() * reach)
			ext.append_array(src)
			ext.append(src[src.size() - 1] + t1.normalized() * reach)
			src = ext
	var pts = src
	var n = pts.size()
	if n < 2:
		return mesh
	var side = -1.0 if dir == ShadowDirection.OUTER else 1.0
	var verts = PoolVector2Array()
	var edge_count = n if closed else n - 1
	var edge_n = []
	for i in range(edge_count):
		var a = pts[i]
		var b = pts[(i + 1) % n]
		var d = b - a
		if d.length() < 0.001:
			edge_n.append(Vector2.ZERO)
			continue
		d = d.normalized()
		edge_n.append(Vector2(-d.y, d.x) * side)
	# Coins CONCAVES côté interdit : point MITER (intersection des deux lignes d'offset,
	# sur la bissectrice) -> chaque quad est rabattu à la bissectrice et ne peut JAMAIS
	# traverser l'autre branche (fini les morsures aux angles aigus), et les deux quads
	# se rejoignent sans trou. Non clampé (le miter reste DANS le coin, entre les deux
	# arêtes) ; denom borné pour les demi-tours quasi parfaits.
	var c_start = 0 if closed else 1
	var c_end = edge_count if closed else n - 1
	var miter_at = {}
	for ci in range(c_start, c_end):
		var e_prev = (ci - 1 + edge_count) % edge_count
		var vA = edge_n[e_prev]
		var vB = edge_n[ci % edge_count]
		if vA.length() < 0.5 or vB.length() < 0.5:
			continue
		if vA.cross(vB) * side < 0.0001:
			continue   # convexe (éventail) ou colinéaire (quads carrés jointifs)
		var mraw = vA + vB
		if mraw.length() < 0.001:
			continue   # demi-tour parfait : dégénéré, quads carrés
		var mn = mraw.normalized()
		var denom = max(mn.dot(vA), 0.05)
		# Borne le miter à la plus courte des deux arêtes : au-delà, il ressortirait du
		# coin SUIVANT (nouvelle morsure). Contrepartie : au fond d'un coin très aigu et
		# profond, le masque n'atteint pas tout à fait le reach latéral (fuite d'ombre
		# infime dans la crevasse entre les deux branches).
		var vtx = pts[ci % n]
		var lcap = max(reach, min((vtx - pts[(ci - 1 + n) % n]).length(), (pts[(ci + 1) % n] - vtx).length()))
		miter_at[ci % n] = vtx + mn * min(reach / denom, lcap)
	# QUADS par arête, extrémités rabattues au miter aux coins concaves.
	for i in range(edge_count):
		var nrm = edge_n[i]
		if nrm.length() < 0.5:
			continue
		var a = pts[i]
		var b = pts[(i + 1) % n]
		var a2 = miter_at.get(i, a + nrm * reach)
		var b2 = miter_at.get((i + 1) % n, b + nrm * reach)
		verts.append(a)
		verts.append(a2)
		verts.append(b)
		verts.append(b)
		verts.append(a2)
		verts.append(b2)
	# Éventails aux coins : uniquement quand le côté interdit est CONVEXE au virage
	# (cross(vA, vB) * side < 0). Côté concave, le miter ci-dessus fait la jointure.
	for ci in range(c_start, c_end):
		var e_prev = (ci - 1 + edge_count) % edge_count
		var vA = edge_n[e_prev]
		var vB = edge_n[ci % edge_count]
		if vA.length() < 0.5 or vB.length() < 0.5:
			continue
		var crossz = vA.cross(vB)
		if crossz * side >= -0.0001:
			continue
		var ang = atan2(crossz, vA.dot(vB))
		var steps = int(max(1, ceil(abs(ang) / 0.4)))
		var corner = pts[ci % n]
		var u_prev = vA
		for k in range(1, steps + 1):
			var u_k = vA.rotated(ang * float(k) / float(steps))
			verts.append(corner)
			verts.append(corner + u_prev * reach)
			verts.append(corner + u_k * reach)
			u_prev = u_k
	if verts.size() < 3:
		return mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Deux passes : côté INTERDIT (rouge) + côté GARDÉ (vert, même géométrie côté opposé).
# Le vert PROTÈGE : une branche non adjacente (hairpin, courbe dense) dont le quad
# interdit traverse le path/mur ne coupe plus l'ombre gardée qui vit là (R sans G).
func _populate_wall_crop_mask(container, path, segments, seg_xf, line_inv, dir, reach):
	_populate_wall_crop_side(container, path, segments, seg_xf, line_inv, dir, reach, false)
	_populate_wall_crop_side(container, path, segments, seg_xf, line_inv, _crop_opposite_dir(dir), reach, true)

func _populate_wall_crop_side(container, path, segments, seg_xf, line_inv, dir, reach, is_keep):
	var closed = is_path_closed(path) and segments.size() == 1
	var side = -1.0 if dir == ShadowDirection.OUTER else 1.0
	for si in range(segments.size()):
		var strip = _build_wall_crop_mesh(segments[si], dir, closed, reach)
		if strip.get_surface_count() == 0:
			continue
		var mi = MeshInstance2D.new()
		mi.mesh = strip
		mi.transform = seg_xf[si]
		mi.material = _crop_tint_mat(is_keep)
		container.add_child(mi)
	if closed:
		return
	# Ponts aux PORTAILS : les segments Line2D sont coupés autour des portails -> la bande
	# per-segment laisse un trou dans le masque, et la silhouette du portail (porte/fenêtre)
	# y déborde en flou. Pour chaque portail avec sprite, on ponte les deux extrémités de
	# segment les plus proches par un quad centre->côté interdit (en espace LINE-local).
	# Extrémités ouvertes : position + normale (+90° du tangent, même convention que
	# calculate_point_normals) en line-local.
	var ends = []
	for si2 in range(segments.size()):
		var p = segments[si2].points
		if p.size() < 2:
			continue
		var ta = (p[1] - p[0])
		var tb = (p[p.size() - 1] - p[p.size() - 2])
		if ta.length() > 0.001:
			var na = Vector2(-ta.y, ta.x).normalized()
			ends.append({"p": seg_xf[si2].xform(p[0]), "n": seg_xf[si2].basis_xform(na).normalized()})
		if tb.length() > 0.001:
			var nb = Vector2(-tb.y, tb.x).normalized()
			ends.append({"p": seg_xf[si2].xform(p[p.size() - 1]), "n": seg_xf[si2].basis_xform(nb).normalized()})
	if ends.size() < 2:
		return
	for pci in range(path.get_child_count()):
		var pc = path.get_child(pci)
		if not (str(pc.name).begins_with("Portal") or str(pc.name).begins_with("@Portal")):
			continue
		if pc.get_child_count() == 0:
			continue
		var psp = pc.get_child(0)
		if not (psp is Sprite) or psp.texture == null:
			continue
		var ppos = (line_inv * psp.global_transform).origin
		# Deux extrémités les plus proches du portail.
		var i0 = -1
		var i1 = -1
		var d0 = 1.0e20
		var d1 = 1.0e20
		for ei in range(ends.size()):
			var dd = ppos.distance_squared_to(ends[ei]["p"])
			if dd < d0:
				d1 = d0
				i1 = i0
				d0 = dd
				i0 = ei
			elif dd < d1:
				d1 = dd
				i1 = ei
		if i0 < 0 or i1 < 0:
			continue
		var e0 = ends[i0]["p"]
		var e1 = ends[i1]["p"]
		var db = e1 - e0
		if db.length() < 0.001:
			continue
		db = db.normalized()
		# Léger chevauchement longitudinal avec les bandes adjacentes (pas de couture).
		var v0 = e0 - db * 4.0
		var v1 = e1 + db * 4.0
		var n_b = Vector2(-db.y, db.x)
		# Oriente la normale du pont comme celle de l'extrémité adjacente (indépendant de
		# l'ordre des points des segments).
		if n_b.dot(ends[i0]["n"]) < 0.0:
			n_b = -n_b
		var verts = PoolVector2Array()
		verts.append(v0)
		verts.append(v0 + n_b * side * reach)
		verts.append(v1)
		verts.append(v1 + n_b * side * reach)
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		var bmesh = ArrayMesh.new()
		bmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
		var bmi = MeshInstance2D.new()
		bmi.mesh = bmesh   # espace line-local -> transform identité (le container mappe line-local)
		bmi.material = _crop_tint_mat(is_keep)
		container.add_child(bmi)

# Viewport de capture du masque, aligné (taille/transform) sur la capture principale.
# Enfant du viewport principal -> libéré automatiquement avec lui (tous les teardowns).
func _make_wall_crop_viewport(vp, container, path, segments, seg_xf, line_inv, dir, reach, v_flip, update_mode, side_on = true, ends_on = false):
	var mvp = Viewport.new()
	mvp.size = vp.size
	mvp.transparent_bg = true
	mvp.usage = Viewport.USAGE_2D
	mvp.disable_3d = true
	mvp.hdr = false
	mvp.render_target_v_flip = v_flip
	mvp.render_target_update_mode = update_mode
	var mcont = Node2D.new()
	mcont.scale = container.scale
	mcont.position = container.position
	mvp.add_child(mcont)
	if side_on:
		_populate_wall_crop_mask(mcont, path, segments, seg_xf, line_inv, dir, reach)
	if ends_on:
		_populate_wall_end_crop(mcont, path, segments, seg_xf, line_inv, reach)
	vp.add_child(mvp)   # un Viewport n'est pas un CanvasItem -> ne pollue pas la capture principale
	return [mvp, mcont]

func _apply_wall_crop_params(mat, mask_tex):
	if mask_tex == null:
		mat.set_shader_param("crop_enabled", 0.0)
		return
	mat.set_shader_param("crop_enabled", 1.0)
	mat.set_shader_param("crop_mask", mask_tex)

# Purge EXHAUSTIVE : libère tout sprite realistic appartenant à ce mur (tag _wall_r_owner)
# où qu'il soit dans l'arbre (line courante, ancienne line, conteneur below-all), sauf `keep`.
func _purge_wall_r_sprites(path, line, nid, keep):
	var roots = []
	if is_instance_valid(path):
		roots.append(path.get_parent())   # nœud Walls -> couvre toutes les lines (own-wall)
	var ba = _get_below_all_container(line) if is_instance_valid(line) else null
	if ba != null:
		roots.append(ba)
	var found = []
	for r in roots:
		if r != null and is_instance_valid(r):
			_purge_wall_r_recursive(r, nid, keep, found)
	# Libère APRÈS la collecte (ne jamais modifier l'arbre pendant l'itération).
	for s in found:
		if is_instance_valid(s):
			if s.get_parent() != null:
				s.get_parent().remove_child(s)
			s.free()

func _purge_wall_r_recursive(node, nid, keep, found):
	for c in node.get_children():
		if c != keep and (c is Sprite) and c.has_meta("_wall_r_owner") and int(c.get_meta("_wall_r_owner")) == nid:
			found.append(c)
		elif c.get_child_count() > 0:
			_purge_wall_r_recursive(c, nid, keep, found)


# Applique couleur/opacité/flou sur le matériau du sprite realistic (shader de flou).
func _apply_wall_r_params(mat, vp_size, blur_px, scale_f, shadow_color, opacity):
	_apply_realistic_blur_params(mat, vp_size, blur_px, scale_f, shadow_color, opacity)

# Place le sprite : centré sur base_pos+offset (line-local), échelle 1/scale_f, mappé dans
# le repère du parent (mur, ou conteneur below-all).
# Wrapper Node2D (enfant du Line2D, derrière lui) qui contient le sprite d'ombre. Comme
# "Colour and Modify Things" itère line.get_children() et n'écrase le matériau que des
# Sprite, notre ombre logée dans ce Node2D est protégée.
func _get_wall_r_wrapper(line):
	for c in line.get_children():
		if (c is Node2D) and not (c is Sprite) and str(c.name) == "DropShadowRealisticWrap":
			return c
	var w = Node2D.new()
	w.name = "DropShadowRealisticWrap"
	w.show_behind_parent = true
	line.add_child(w)
	return w

func _place_wall_r_sprite(spr, shadow_parent, line, line_global_xform, base_pos, offset, scale_f):
	var local_place = Transform2D()
	local_place.x = Vector2(1.0 / scale_f, 0.0)
	local_place.y = Vector2(0.0, 1.0 / scale_f)
	local_place.origin = base_pos + offset
	if shadow_parent == line:
		spr.transform = local_place
		spr.show_behind_parent = true
	else:
		spr.transform = shadow_parent.global_transform.affine_inverse() * line_global_xform * local_place
		spr.show_behind_parent = false
	spr.z_index = 0


# Vrai si le seul réglage modifié est un paramètre "live" (n'affecte pas la silhouette).
func _can_live_update_realistic_wall(cfg) -> bool:
	if cfg.get("render_mode", "simple") != "realistic":
		return false
	return _wall_last_changed in WALL_R_LIVE_PARAMS

# MAJ en place du sprite realistic (réglages) sans recapture ni flicker. False -> recapture.
func _live_update_realistic_wall(node, cfg) -> bool:
	var nid = node.get_instance_id()
	var line = get_line2d(node)
	if line == null or not is_instance_valid(line):
		return false
	var shadow_color = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	var opacity = cfg.get("opacity_realistic", cfg.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"]))
	var blur_px = _realistic_blur_px_from_frac(cfg.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2)))
	var radial = _make_radial(cfg)
	var offset = Vector2(cfg.get("offset_x", 0.0), cfg.get("offset_y", 0.0))
	if line.rotation != 0.0:
		offset = offset.rotated(-line.rotation)

	# Session live active -> mise à jour en direct (radial inclus).
	if _wall_r_session.has(nid):
		return _update_wall_r_session(nid, node, line, radial, offset, shadow_color, opacity, blur_px)

	# Changement de silhouette (radial/side, même vers 0) -> session live (reconstruit la
	# silhouette ; sinon un retour à 0 laisserait le sprite statique déformé).
	if _wall_last_changed in ["radial_offset", "side_balance", "direction"] and node.has_meta(SHADOW_META_KEY):
		var below_all = cfg.get("below_all_walls", false)
		var shadow_parent = _get_wall_r_wrapper(line)
		var line_global_xform = line.global_transform
		var wall_nid = str(node.get_meta("node_id")) if node.has_meta("node_id") else ""
		if below_all:
			var ba = _get_below_all_container(line)
			if ba != null:
				shadow_parent = ba
		_start_wall_r_session(node, line, shadow_parent, line_global_xform, wall_nid, radial, offset, shadow_color, opacity, blur_px)
		return true

	# Sinon (offset/blur/couleur sur un sprite statique) -> MAJ en place.
	if not _wall_r_live.has(nid):
		return false
	var s = _wall_r_live[nid]
	var spr = s["sprite"]
	if not is_instance_valid(spr):
		_wall_r_live.erase(nid)
		return false
	if spr.material is ShaderMaterial:
		_apply_wall_r_params(spr.material, s["vp_size"], blur_px, s["scale_f"], shadow_color, opacity)
		spr.material.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	_place_wall_r_sprite(spr, s["parent"], line, s["line_xform"], s["base_pos"], offset, s["scale_f"])
	return true

# Recapture différée (debounce) des changements de silhouette realistic (radial/side/géométrie).
# Pendant l'édition, l'ancien sprite reste affiché ; au repos (WALL_R_SETTLE_MS), on recapture
# une seule fois (swap atomique -> pas de flicker, pas de readback par frame -> pas de lag).
# Au repos (souris relâchée, calme), reconvertit une session live en texture statique
# mipmappée (qualité pleine) via un bake statique qui réutilise le sprite et libère le
# viewport persistant. Pendant le drag (bouton tenu), on garde le live.
func _process_wall_r_session_settle():
	if _wall_r_session.empty():
		return
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		return
	var now = OS.get_ticks_msec()
	var ready = []
	for nid in _wall_r_session:
		if now - _wall_r_last_req.get(nid, 0) >= WALL_R_LIVE_SETTLE_MS:
			ready.append(nid)
	for nid in ready:
		if _wall_r_capturing.has(nid):
			continue
		var node = instance_from_id(nid)
		var s = _wall_r_session[nid]
		if node == null or not is_instance_valid(node):
			_wall_r_session.erase(nid)
			_wall_r_last_req.erase(nid)
			if is_instance_valid(s["vp"]):
				s["vp"].queue_free()
			continue
		var node_id = str(node.get_meta("node_id")) if node.has_meta("node_id") else ""
		var cfg = null
		if node_id != "" and global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(node_id):
			cfg = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
			if cfg.has("shadow_color") and cfg["shadow_color"] is String:
				cfg["shadow_color"] = Color(cfg["shadow_color"])
		if cfg != null and cfg.get("enabled", false) and cfg.get("render_mode", "simple") == "realistic":
			create_shadow(node, cfg)   # bake statique -> réutilise le sprite + libère la session
		else:
			_wall_r_session.erase(nid)
			_wall_r_last_req.erase(nid)
			if is_instance_valid(s["vp"]):
				s["vp"].queue_free()

func _process_wall_r_settle():
	if _wall_r_settle.empty():
		return
	# Tant que le bouton gauche est tenu (drag d'un slider), on ne recapture PAS :
	# l'ancien sprite reste affiché, la capture se fait une seule fois au relâchement.
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		return
	var now = OS.get_ticks_msec()
	var ready = []
	for nid in _wall_r_settle:
		if _wall_r_capturing.has(nid):
			continue  # capture déjà en vol pour ce mur
		if now - _wall_r_settle_time.get(nid, 0) >= WALL_R_SETTLE_MS:
			ready.append(nid)
	for nid in ready:
		var cfg = _wall_r_settle[nid]
		_wall_r_settle.erase(nid)
		_wall_r_settle_time.erase(nid)
		var node = instance_from_id(nid)
		if node != null and is_instance_valid(node) and cfg.get("enabled", false):
			create_shadow(node, cfg)


func create_shadow(path, config: Dictionary):
	if path == null or not is_instance_valid(path):
		return

	var line = get_line2d(path)
	if line == null:
		return

	# Mode "Realistic" : silhouette texturée du mur, décalée + floutée, rendue dessous.
	if config.get("render_mode", "simple") == "realistic":
		create_realistic_shadow_wall(path, config, line)
		return


	var source_points = PoolVector2Array()
	var _wall_extra_segments = []
	var _wall_had_cuts = false

	# Collect portals
	var portal_nodes = []
	for ci_p in range(path.get_child_count()):
		var ch_p = path.get_child(ci_p)
		if ch_p.name.begins_with("Portal") or ch_p.name.begins_with("@Portal"):
			portal_nodes.append(ch_p)

	# Find wall texture width
	var tex_width = 0.0
	for ci in range(path.get_child_count()):
		var ch = path.get_child(ci)
		if ch is Line2D and ch.get_point_count() >= 2 and ch.width > tex_width:
			tex_width = ch.width
	# Collect segments
	var segments = []
	for ci2 in range(path.get_child_count()):
		var ch2 = path.get_child(ci2)
		if ch2 is Line2D and ch2.width == tex_width and ch2.get_point_count() >= 2:
			segments.append(ch2.points)

	var skip_portals_global = config.get("skip_portals", false)

	# Step 1: Build the full wall trace (continuous polyline covering the entire wall)
	# Use the wall's Points property for the complete geometry (not split by portals).
	# Line2D children are split around portals by Dungeondraft, so merging them
	# misses extremities when a portal sits at the start or end of the wall.
	var full_line = PoolVector2Array()
	var wall_points = path.get("Points")
	if wall_points != null and wall_points.size() >= 2:
		for wp in wall_points:
			full_line.append(wp)
	else:
		# Fallback: merge Line2D segments (non-wall paths or missing Points)
		for si in range(segments.size()):
			var seg = segments[si]
			for pi in range(seg.size()):
				if full_line.size() > 0 and pi == 0 and si > 0:
					if full_line[full_line.size() - 1].distance_to(seg[0]) < 1.0:
						continue
				full_line.append(seg[pi])
	if full_line.size() < 2:
		full_line = line.points

	# For closed loops, append the first point to close the polyline
	# so portal projections and cuts cover the closing segment
	var is_loop = is_path_closed(path)
	if is_loop and full_line.size() > 2:
		if full_line[0].distance_to(full_line[full_line.size() - 1]) > 1.0:
			full_line.append(full_line[0])

	# Step 2: Collect cut regions for skipped portals
	# Each skipped portal defines a [Begin, End] region to remove from the line
	var cuts = []  # Array of {start_dist, end_dist} along the polyline
	for p_node in portal_nodes:
		if not _should_skip_portal(p_node, skip_portals_global):
			continue
		var p_begin = p_node.get("Begin")
		var p_end = p_node.get("End")
		if p_begin == null or p_end == null:
			continue
		var d_begin = _project_point_on_line(p_begin, full_line)
		var d_end = _project_point_on_line(p_end, full_line)
		if d_begin > d_end:
			var tmp = d_begin
			d_begin = d_end
			d_end = tmp
		cuts.append({"start": d_begin, "end": d_end})

	if cuts.size() == 0:
		# No portals to skip — use the full merged line
		source_points = full_line
	else:
		# Sort cuts by start distance
		cuts.sort_custom(self, "_cmp_cuts")

		# Merge overlapping cuts
		var merged_cuts = [cuts[0]]
		for ci3 in range(1, cuts.size()):
			var prev = merged_cuts[merged_cuts.size() - 1]
			var curr = cuts[ci3]
			if curr["start"] <= prev["end"] + 1.0:
				prev["end"] = max(prev["end"], curr["end"])
			else:
				merged_cuts.append(curr)

		# Step 3: Extract line segments between cuts
		# Compute total line length
		var total_len = 0.0
		for tli in range(full_line.size() - 1):
			total_len += full_line[tli].distance_to(full_line[tli + 1])

		# Generate kept regions: [0, cut0.start], [cut0.end, cut1.start], ..., [cutN.end, total_len]
		var kept_regions = []
		var prev_end = 0.0
		for mc in merged_cuts:
			if mc["start"] > prev_end + 0.5:
				kept_regions.append({"start": prev_end, "end": mc["start"]})
			prev_end = mc["end"]
		if prev_end < total_len - 0.5:
			kept_regions.append({"start": prev_end, "end": total_len})

		# Extract points for each kept region
		var result_segments = []
		for kr in kept_regions:
			var seg_pts = _extract_line_region(full_line, kr["start"], kr["end"])
			if seg_pts.size() >= 2:
				result_segments.append(seg_pts)

		if result_segments.size() == 0:
			source_points = full_line
		elif result_segments.size() == 1:
			source_points = result_segments[0]
			# A single kept segment from a loop means the cut didn't split the loop
			# into multiple visible parts, but the loop IS still broken open
			_wall_had_cuts = true
		else:
			# For loops: the last segment ends at the loop closure point and the first
			# segment starts there. Merge them to avoid a shadow gap at the junction.
			if is_loop and result_segments.size() >= 2:
				var last_seg = result_segments[result_segments.size() - 1]
				var first_seg = result_segments[0]
				if last_seg.size() >= 2 and first_seg.size() >= 2:
					if last_seg[last_seg.size() - 1].distance_to(first_seg[0]) < 5.0:
						# Append first_seg points to last_seg (skip duplicate junction point)
						var merged = PoolVector2Array()
						for mp in last_seg:
							merged.append(mp)
						for mpi in range(1, first_seg.size()):
							merged.append(first_seg[mpi])
						# Replace: merged becomes first, remove last
						result_segments[0] = merged
						result_segments.remove(result_segments.size() - 1)
			source_points = result_segments[0]
			# Even if loop segments were merged back into one, the loop was cut open
			_wall_had_cuts = true
			for rsi in range(1, result_segments.size()):
				_wall_extra_segments.append(result_segments[rsi])

	if source_points.size() < 2:
		return

	# Remove duplicate consecutive points (e.g. two points stacked for sharp 90° corners)
	# This prevents zero-length segments that produce degenerate normals
	var deduped = PoolVector2Array()
	deduped.append(source_points[0])
	for di in range(1, source_points.size()):
		if source_points[di].distance_to(source_points[di - 1]) > 0.5:
			deduped.append(source_points[di])
	source_points = deduped

	if source_points.size() < 2:
		return

	# Read transition settings early to determine auto-extension
	var cfg_fade_in = config.get("fade_in_enabled", false)
	var cfg_fade_out = config.get("fade_out_enabled", false)
	var cfg_grow = config.get("grow_enabled", false)
	var cfg_shrink = config.get("shrink_enabled", false)
	var fade_in_strength = config.get("fade_in_strength", 5.0)
	var fade_out_strength = config.get("fade_out_strength", 5.0)
	var grow_length_val = config.get("grow_length", 0.5)
	var shrink_length_val = config.get("shrink_length", 0.5)

	# Swap ends: visually reverse which end gets which transition
	var swap = config.get("swap_ends", false)
	if swap:
		var tmp_fe = cfg_fade_in
		cfg_fade_in = cfg_fade_out
		cfg_fade_out = tmp_fe
		var tmp_fs = fade_in_strength
		fade_in_strength = fade_out_strength
		fade_out_strength = tmp_fs
		var tmp_ge = cfg_grow
		cfg_grow = cfg_shrink
		cfg_shrink = tmp_ge
		var tmp_gs = grow_length_val
		grow_length_val = shrink_length_val
		shrink_length_val = tmp_gs

	# Extension is now a Shape value (-1..+1) controlling rounded cap shape.
	# It only matters when extend_enabled is on; otherwise no caps are drawn.
	var extend_enabled = config.get("extend_enabled", false)
	var shape_v = clamp(config.get("fade_extend", 0.0), -1.0, 1.0)
	var extend_which = int(config.get("extend_which", 2))
	# Swap extend_which when swap_ends is active: Start(0) <-> End(1), Both(2) unchanged
	if swap and extend_which == 0:
		extend_which = 1
	elif swap and extend_which == 1:
		extend_which = 0

	# Cap flags for the main segment (and reused per extra segment)
	var draw_start_cap = false
	var draw_end_cap = false
	if extend_enabled:
		if extend_which == 0 or extend_which == 2:
			draw_start_cap = true
		if extend_which == 1 or extend_which == 2:
			draw_end_cap = true

	# Walls no longer force fade_in/out when extend is on — the cap mesh
	# provides its own visual termination via its radial alpha gradient,
	# matching how paths now work.

	var orig_cfg_fade_in = cfg_fade_in
	var orig_cfg_fade_out = cfg_fade_out
	var orig_cfg_grow = cfg_grow
	var orig_cfg_shrink = cfg_shrink

	# Centerline extension is removed — caps are rendered as separate meshes
	# AFTER the main strip(s). These counters stay zero so opacity/width
	# factors are computed against the un-extended source_points.
	var start_ext_count = 0
	var end_ext_count = 0

	var opacity = config["opacity"]
	var direction = int(config["direction"])
	var use_separate_extends = false  # legacy flag; no longer extends centerline

	var original_count = source_points.size()

	var half_width = line.width / 2.0
	var num_strips = 10

	# Convert fraction-based settings to pixel values relative to path width
	var spread_px = config["spread"] * half_width
	var softness_px = config["softness"] * half_width

	var start_outer = 0.0
	var start_inner = 0.0

	# Detect if path is closed
	# A loop with portal cuts is no longer closed (broken into open segments)
	var has_cuts = _wall_extra_segments.size() > 0 or _wall_had_cuts
	var is_closed = is_loop and not has_cuts and source_points.size() > 2
	
	# For closed loops without cuts, remove the appended closing point
	# (the mesh builder handles closure internally)
	if is_closed and source_points.size() > 2:
		if source_points[0].distance_to(source_points[source_points.size() - 1]) < 2.0:
			source_points.remove(source_points.size() - 1)

	var shadow_nodes = []

	# Determine shadow parent: either the line (default) or a level-wide container
	var below_all = config.get("below_all_walls", false)
	var shadow_parent = _get_wall_r_wrapper(line)
	var line_global_xform = line.global_transform
	var wall_nid = str(path.get_meta("node_id")) if path.has_meta("node_id") else ""
	if below_all:
		var ba_container = _get_below_all_container(line)
		if ba_container != null:
			shadow_parent = ba_container

	var offset = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	var path_rotation = line.rotation
	if path_rotation != 0.0:
		offset = offset.rotated(-path_rotation)

	# Slider value is in -100..+100; multiply by 2 so the effective
	# pixel shift covers ~twice the distance while keeping the cap small.
	var radial_offset = float(config.get("radial_offset", 0.0)) * 2.0
	var side_balance = float(config.get("side_balance", 0.0))

	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)

	# === MAIN BODY ===
	var main_fade_in = cfg_fade_in if (not use_separate_extends or start_ext_count == 0) else false
	var main_fade_out = cfg_fade_out if (not use_separate_extends or end_ext_count == 0) else false
	var main_grow = cfg_grow if (not use_separate_extends or start_ext_count == 0) else false
	var main_shrink = cfg_shrink if (not use_separate_extends or end_ext_count == 0) else false
	var main_start_ext = start_ext_count if not use_separate_extends else 0

	# BOTH direction is rendered as a SINGLE combined mesh (using a unified
	# bevel for both sides) so the OUTER and INNER halves share the same
	# centerline points — avoiding a visible seam where they meet when
	# radial_offset shifts the meeting line out from under the wall texture.
	if direction == ShadowDirection.BOTH:
		var both_pts = _bevel_points_for_both(source_points, is_closed)
		var both_nrm = calculate_point_normals(both_pts, is_closed)
		var both_opc = _build_opacity_factors(both_pts.size(), original_count, main_fade_in, main_fade_out, fade_in_strength, fade_out_strength, main_start_ext)
		var both_wfc = _build_width_factors(both_pts.size(), original_count, main_grow, main_shrink, grow_length_val, shrink_length_val, main_start_ext)

		var sb_factors = _side_balance_factors(side_balance)
		var factor_a = sb_factors[0]
		var factor_b = sb_factors[1]

		if abs(side_balance) < 0.5:
			# Symmetric: unified mesh, no seam.
			var both_mesh = build_shadow_mesh_both(both_pts, both_nrm,
				spread_px, softness_px, opacity, num_strips, is_closed,
				both_opc, both_wfc, shadow_color, radial_offset)
			if both_mesh.get_surface_count() > 0:
				var mesh_inst_both = MeshInstance2D.new()
				mesh_inst_both.mesh = both_mesh
				mesh_inst_both.name = "DropShadowBoth"
				_add_shadow_mesh(mesh_inst_both, shadow_parent, offset, below_all, line_global_xform, wall_nid)
				shadow_nodes.append(mesh_inst_both)
		else:
			# Asymmetric: two meshes reusing the unified centerline points so
			# the meeting line stays aligned. Each side scales spread+softness
			# by its factor (other params remain identical between the two).
			if factor_a > 0.001:
				var a_mesh = build_shadow_mesh_side(both_pts, both_nrm, start_outer,
					spread_px * factor_a, softness_px * factor_a, opacity, 1.0, num_strips, is_closed,
					both_opc, both_wfc, shadow_color, null, radial_offset)
				if a_mesh.get_surface_count() > 0:
					var a_inst = MeshInstance2D.new()
					a_inst.mesh = a_mesh
					a_inst.name = "DropShadowOuter"
					_add_shadow_mesh(a_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
					shadow_nodes.append(a_inst)
			if factor_b > 0.001:
				var b_mesh = build_shadow_mesh_side(both_pts, both_nrm, start_inner,
					spread_px * factor_b, softness_px * factor_b, opacity, -1.0, num_strips, is_closed,
					both_opc, both_wfc, shadow_color, null, radial_offset)
				if b_mesh.get_surface_count() > 0:
					var b_inst = MeshInstance2D.new()
					b_inst.mesh = b_mesh
					b_inst.name = "DropShadowInner"
					_add_shadow_mesh(b_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
					shadow_nodes.append(b_inst)

	elif direction == ShadowDirection.OUTER:
		var outer_bevel = _bevel_points_for_side(source_points, 1.0, is_closed)
		var outer_pts = outer_bevel[0]
		var outer_cfactors = outer_bevel[1]
		var outer_nrm = calculate_point_normals(outer_pts, is_closed)
		var outer_opc = _build_opacity_factors(outer_pts.size(), original_count, main_fade_in, main_fade_out, fade_in_strength, fade_out_strength, main_start_ext)
		var outer_wfc = _build_width_factors(outer_pts.size(), original_count, main_grow, main_shrink, grow_length_val, shrink_length_val, main_start_ext)
		var outer_mesh = build_shadow_mesh_side(outer_pts, outer_nrm, start_outer,
			spread_px, softness_px, opacity, 1.0, num_strips, is_closed,
			outer_opc, outer_wfc, shadow_color, outer_cfactors, radial_offset)
		if outer_mesh.get_surface_count() > 0:
			var mesh_inst = MeshInstance2D.new()
			mesh_inst.mesh = outer_mesh
			mesh_inst.name = "DropShadowOuter"
			_add_shadow_mesh(mesh_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
			shadow_nodes.append(mesh_inst)

	elif direction == ShadowDirection.INNER:
		var inner_bevel = _bevel_points_for_side(source_points, -1.0, is_closed)
		var inner_pts = inner_bevel[0]
		var inner_cfactors = inner_bevel[1]
		var inner_nrm = calculate_point_normals(inner_pts, is_closed)
		var inner_opc = _build_opacity_factors(inner_pts.size(), original_count, main_fade_in, main_fade_out, fade_in_strength, fade_out_strength, main_start_ext)
		var inner_wfc = _build_width_factors(inner_pts.size(), original_count, main_grow, main_shrink, grow_length_val, shrink_length_val, main_start_ext)
		var inner_mesh = build_shadow_mesh_side(inner_pts, inner_nrm, start_inner,
			spread_px, softness_px, opacity, -1.0, num_strips, is_closed,
			inner_opc, inner_wfc, shadow_color, inner_cfactors, radial_offset)
		if inner_mesh.get_surface_count() > 0:
			var mesh_inst2 = MeshInstance2D.new()
			mesh_inst2.mesh = inner_mesh
			mesh_inst2.name = "DropShadowInner"
			_add_shadow_mesh(mesh_inst2, shadow_parent, offset, below_all, line_global_xform, wall_nid)
			shadow_nodes.append(mesh_inst2)

	# === ROUNDED CAPS at enabled ends of the main segment ===
	# Skipped for closed loops (no real ends to cap).
	if (draw_start_cap or draw_end_cap) and not is_closed and source_points.size() >= 2:
		var cap_asymmetric = (direction == ShadowDirection.BOTH and abs(side_balance) >= 0.5)
		var cap_sb = _side_balance_factors(side_balance)
		var cap_fa = cap_sb[0]
		var cap_fb = cap_sb[1]
		if draw_start_cap:
			if cap_asymmetric:
				if cap_fa > 0.001:
					_add_cap_for_endpoint(source_points, true, ShadowDirection.OUTER,
						spread_px * cap_fa, softness_px * cap_fa, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowStartCapOuter", shadow_nodes, radial_offset)
				if cap_fb > 0.001:
					_add_cap_for_endpoint(source_points, true, ShadowDirection.INNER,
						spread_px * cap_fb, softness_px * cap_fb, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowStartCapInner", shadow_nodes, radial_offset)
			else:
				_add_cap_for_endpoint(source_points, true, direction,
					spread_px, softness_px, opacity, num_strips, shape_v, shadow_color,
					shadow_parent, offset, below_all, line_global_xform, wall_nid,
					"DropShadowStartCap", shadow_nodes, radial_offset)
		if draw_end_cap:
			if cap_asymmetric:
				if cap_fa > 0.001:
					_add_cap_for_endpoint(source_points, false, ShadowDirection.OUTER,
						spread_px * cap_fa, softness_px * cap_fa, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowEndCapOuter", shadow_nodes, radial_offset)
				if cap_fb > 0.001:
					_add_cap_for_endpoint(source_points, false, ShadowDirection.INNER,
						spread_px * cap_fb, softness_px * cap_fb, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowEndCapInner", shadow_nodes, radial_offset)
			else:
				_add_cap_for_endpoint(source_points, false, direction,
					spread_px, softness_px, opacity, num_strips, shape_v, shadow_color,
					shadow_parent, offset, below_all, line_global_xform, wall_nid,
					"DropShadowEndCap", shadow_nodes, radial_offset)

	path.set_meta(SHADOW_META_KEY, shadow_nodes)

	# For walls with X portals or skip_portals: create additional shadow meshes for extra segments
	if _wall_extra_segments.size() > 0:
		var extra_idx = 0
		for extra_seg in _wall_extra_segments:
			if extra_seg.size() < 2:
				continue
			extra_idx += 1
			var ex_pts = extra_seg

			# Deduplicate consecutive points for extra segments too
			var ex_deduped = PoolVector2Array()
			ex_deduped.append(ex_pts[0])
			for edi in range(1, ex_pts.size()):
				if ex_pts[edi].distance_to(ex_pts[edi - 1]) > 0.5:
					ex_deduped.append(ex_pts[edi])
			ex_pts = ex_deduped
			if ex_pts.size() < 2:
				continue

			# Centerline extension is removed for extra segments — caps are
			# rendered as separate meshes at each enabled end below.
			var ex_original_count = ex_pts.size()
			var ex_main_fade_in = orig_cfg_fade_in
			var ex_main_fade_out = orig_cfg_fade_out
			var ex_main_grow = orig_cfg_grow
			var ex_main_shrink = orig_cfg_shrink
			var ex_main_start_ext = 0

			# Main body: unified mesh for BOTH (avoids OUTER/INNER seam), per-side mesh otherwise.
			if direction == ShadowDirection.BOTH:
				var ex_both_pts = _bevel_points_for_both(ex_pts, false)
				var ex_both_nrm = calculate_point_normals(ex_both_pts, false)
				var ex_both_opc = _build_opacity_factors(ex_both_pts.size(), ex_original_count, ex_main_fade_in, ex_main_fade_out, fade_in_strength, fade_out_strength, ex_main_start_ext)
				var ex_both_wfc = _build_width_factors(ex_both_pts.size(), ex_original_count, ex_main_grow, ex_main_shrink, grow_length_val, shrink_length_val, ex_main_start_ext)

				var ex_sb_factors = _side_balance_factors(side_balance)
				var ex_factor_a = ex_sb_factors[0]
				var ex_factor_b = ex_sb_factors[1]

				if abs(side_balance) < 0.5:
					var ex_both_mesh = build_shadow_mesh_both(ex_both_pts, ex_both_nrm,
						spread_px, softness_px, opacity, num_strips, false,
						ex_both_opc, ex_both_wfc, shadow_color, radial_offset)
					if ex_both_mesh.get_surface_count() > 0:
						var ex_inst_both = MeshInstance2D.new()
						ex_inst_both.mesh = ex_both_mesh
						ex_inst_both.name = "DropShadowBothX" + str(extra_idx)
						_add_shadow_mesh(ex_inst_both, shadow_parent, offset, below_all, line_global_xform, wall_nid)
						shadow_nodes.append(ex_inst_both)
				else:
					if ex_factor_a > 0.001:
						var ex_a_mesh = build_shadow_mesh_side(ex_both_pts, ex_both_nrm, start_outer,
							spread_px * ex_factor_a, softness_px * ex_factor_a, opacity, 1.0, num_strips, false,
							ex_both_opc, ex_both_wfc, shadow_color, null, radial_offset)
						if ex_a_mesh.get_surface_count() > 0:
							var ex_a_inst = MeshInstance2D.new()
							ex_a_inst.mesh = ex_a_mesh
							ex_a_inst.name = "DropShadowOuterX" + str(extra_idx)
							_add_shadow_mesh(ex_a_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
							shadow_nodes.append(ex_a_inst)
					if ex_factor_b > 0.001:
						var ex_b_mesh = build_shadow_mesh_side(ex_both_pts, ex_both_nrm, start_inner,
							spread_px * ex_factor_b, softness_px * ex_factor_b, opacity, -1.0, num_strips, false,
							ex_both_opc, ex_both_wfc, shadow_color, null, radial_offset)
						if ex_b_mesh.get_surface_count() > 0:
							var ex_b_inst = MeshInstance2D.new()
							ex_b_inst.mesh = ex_b_mesh
							ex_b_inst.name = "DropShadowInnerX" + str(extra_idx)
							_add_shadow_mesh(ex_b_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
							shadow_nodes.append(ex_b_inst)
			elif direction == ShadowDirection.OUTER:
				var ex_bevel = _bevel_points_for_side(ex_pts, 1.0, false)
				var ex_bpts = ex_bevel[0]
				var ex_cfac = ex_bevel[1]
				var ex_nrm = calculate_point_normals(ex_bpts, false)
				var ex_opc = _build_opacity_factors(ex_bpts.size(), ex_original_count, ex_main_fade_in, ex_main_fade_out, fade_in_strength, fade_out_strength, ex_main_start_ext)
				var ex_wfc = _build_width_factors(ex_bpts.size(), ex_original_count, ex_main_grow, ex_main_shrink, grow_length_val, shrink_length_val, ex_main_start_ext)
				var ex_mesh = build_shadow_mesh_side(ex_bpts, ex_nrm, start_outer,
					spread_px, softness_px, opacity, 1.0, num_strips, false,
					ex_opc, ex_wfc, shadow_color, ex_cfac, radial_offset)
				if ex_mesh.get_surface_count() > 0:
					var ex_inst = MeshInstance2D.new()
					ex_inst.mesh = ex_mesh
					ex_inst.name = "DropShadowOuterX" + str(extra_idx)
					_add_shadow_mesh(ex_inst, shadow_parent, offset, below_all, line_global_xform, wall_nid)
					shadow_nodes.append(ex_inst)
			elif direction == ShadowDirection.INNER:
				var ex_bevel2 = _bevel_points_for_side(ex_pts, -1.0, false)
				var ex_bpts2 = ex_bevel2[0]
				var ex_cfac2 = ex_bevel2[1]
				var ex_nrm2 = calculate_point_normals(ex_bpts2, false)
				var ex_opc2 = _build_opacity_factors(ex_bpts2.size(), ex_original_count, ex_main_fade_in, ex_main_fade_out, fade_in_strength, fade_out_strength, ex_main_start_ext)
				var ex_wfc2 = _build_width_factors(ex_bpts2.size(), ex_original_count, ex_main_grow, ex_main_shrink, grow_length_val, shrink_length_val, ex_main_start_ext)
				var ex_mesh2 = build_shadow_mesh_side(ex_bpts2, ex_nrm2, start_inner,
					spread_px, softness_px, opacity, -1.0, num_strips, false,
					ex_opc2, ex_wfc2, shadow_color, ex_cfac2, radial_offset)
				if ex_mesh2.get_surface_count() > 0:
					var ex_inst2 = MeshInstance2D.new()
					ex_inst2.mesh = ex_mesh2
					ex_inst2.name = "DropShadowInnerX" + str(extra_idx)
					_add_shadow_mesh(ex_inst2, shadow_parent, offset, below_all, line_global_xform, wall_nid)
					shadow_nodes.append(ex_inst2)

			# Caps at each enabled end of this extra segment
			var ex_cap_asym = (direction == ShadowDirection.BOTH and abs(side_balance) >= 0.5)
			var ex_cap_sb = _side_balance_factors(side_balance)
			var ex_cap_fa = ex_cap_sb[0]
			var ex_cap_fb = ex_cap_sb[1]
			if draw_start_cap:
				if ex_cap_asym:
					if ex_cap_fa > 0.001:
						_add_cap_for_endpoint(ex_pts, true, ShadowDirection.OUTER,
							spread_px * ex_cap_fa, softness_px * ex_cap_fa, opacity, num_strips, shape_v, shadow_color,
							shadow_parent, offset, below_all, line_global_xform, wall_nid,
							"DropShadowStartCapOuterX" + str(extra_idx), shadow_nodes, radial_offset)
					if ex_cap_fb > 0.001:
						_add_cap_for_endpoint(ex_pts, true, ShadowDirection.INNER,
							spread_px * ex_cap_fb, softness_px * ex_cap_fb, opacity, num_strips, shape_v, shadow_color,
							shadow_parent, offset, below_all, line_global_xform, wall_nid,
							"DropShadowStartCapInnerX" + str(extra_idx), shadow_nodes, radial_offset)
				else:
					_add_cap_for_endpoint(ex_pts, true, direction,
						spread_px, softness_px, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowStartCapX" + str(extra_idx), shadow_nodes, radial_offset)
			if draw_end_cap:
				if ex_cap_asym:
					if ex_cap_fa > 0.001:
						_add_cap_for_endpoint(ex_pts, false, ShadowDirection.OUTER,
							spread_px * ex_cap_fa, softness_px * ex_cap_fa, opacity, num_strips, shape_v, shadow_color,
							shadow_parent, offset, below_all, line_global_xform, wall_nid,
							"DropShadowEndCapOuterX" + str(extra_idx), shadow_nodes, radial_offset)
					if ex_cap_fb > 0.001:
						_add_cap_for_endpoint(ex_pts, false, ShadowDirection.INNER,
							spread_px * ex_cap_fb, softness_px * ex_cap_fb, opacity, num_strips, shape_v, shadow_color,
							shadow_parent, offset, below_all, line_global_xform, wall_nid,
							"DropShadowEndCapInnerX" + str(extra_idx), shadow_nodes, radial_offset)
				else:
					_add_cap_for_endpoint(ex_pts, false, direction,
						spread_px, softness_px, opacity, num_strips, shape_v, shadow_color,
						shadow_parent, offset, below_all, line_global_xform, wall_nid,
						"DropShadowEndCapX" + str(extra_idx), shadow_nodes, radial_offset)

		# Update the meta with all shadow nodes including extras
		path.set_meta(SHADOW_META_KEY, shadow_nodes)

	outputlog("Shadow created with " + str(shadow_nodes.size()) + " mesh(es)", 1)

func remove_shadow(path):
	if path == null or not is_instance_valid(path):
		return
	# Invalide toute capture realistic asynchrone encore en attente sur ce mur.
	var _rnid = path.get_instance_id()
	if _realistic_gen.has(_rnid):
		_realistic_gen[_rnid] = _realistic_gen[_rnid] + 1
	_wall_r_live.erase(_rnid)
	_wall_loop_nat.erase(_rnid)
	if _wall_r_session.has(_rnid):
		var _rs = _wall_r_session[_rnid]
		_wall_r_session.erase(_rnid)
		_wall_r_last_req.erase(_rnid)
		if is_instance_valid(_rs["vp"]):
			_rs["vp"].queue_free()
	_wall_r_settle.erase(_rnid)
	_wall_r_settle_time.erase(_rnid)
	if path.has_meta(SHADOW_META_KEY):
		var nodes = path.get_meta(SHADOW_META_KEY)
		if nodes is Array:
			for node in nodes:
				if is_instance_valid(node):
					node.get_parent().remove_child(node)
					node.free()
		path.remove_meta(SHADOW_META_KEY)

#########################################################################################################
##
## SELECTION CHANGE HANDLING
##
#########################################################################################################

func on_selection_changed():

	_monitored_path = null
	_monitored_type = ""

	if global.Editor.Tools["SelectTool"].Selected.size() > 0:
		var node = global.Editor.Tools["SelectTool"].Selected[0]
		if is_shadow_node_type(node):
			_reparent_ui_to_node(node)
			_monitored_path = node
			_monitored_type = get_node_type(node)
			_monitored_points_hash = _get_points_hash(node)
			_monitored_transitions_hash = _get_transitions_hash(node)
			load_shadow_ui_from_path(node)
			return

	reset_ui_to_defaults()

func _reparent_ui_to_node(node):
	var container = ui_config.get("container")
	if container == null:
		return
	var target_parent = ui_config.get("_wall_parent")
	if target_parent == null:
		return
	if container.get_parent() == target_parent:
		_update_transition_visibility("walls")
		return
	if container.get_parent() != null:
		container.get_parent().remove_child(container)
	target_parent.add_child(container)
	target_parent.move_child(container, 0)
	_update_transition_visibility("walls")

func _update_transition_visibility(node_type: String):
	var is_wall = (node_type == "walls")
	# Detect if the current path/wall is closed (loop)
	var closed = false
	if _monitored_path != null and is_instance_valid(_monitored_path):
		closed = is_path_closed(_monitored_path)
	# Hide grow/shrink and individual fade rows for walls
	if ui_config.has("grow_hbox"):
		ui_config["grow_hbox"].visible = not is_wall
	if ui_config.has("shrink_hbox"):
		ui_config["shrink_hbox"].visible = not is_wall
	if ui_config.has("fade_in_hbox"):
		ui_config["fade_in_hbox"].visible = not is_wall
	if ui_config.has("fade_out_hbox"):
		ui_config["fade_out_hbox"].visible = not is_wall
	# Hide swap ends for walls
	if ui_config.has("swap_hbox"):
		ui_config["swap_hbox"].visible = not is_wall
	if ui_config.has("swap_sep"):
		ui_config["swap_sep"].visible = not is_wall
	# Show skip portals only for walls
	if ui_config.has("skip_portals_hbox"):
		ui_config["skip_portals_hbox"].visible = is_wall
	# Show below all walls only for walls
	if ui_config.has("below_all_walls_hbox"):
		ui_config["below_all_walls_hbox"].visible = is_wall
	# Hide entire transitions section for walls, respect cog state for paths
	if ui_config.has("sec_transitions_sep"):
		ui_config["sec_transitions_sep"].visible = not is_wall
	if ui_config.has("sec_transitions_header"):
		ui_config["sec_transitions_header"].visible = not is_wall
	if ui_config.has("sec_transitions_content"):
		if is_wall:
			ui_config["sec_transitions_content"].visible = false
		# For paths: don't force visible, let the cog toggle control it
	# Hide extend for closed paths/walls (loops have no ends to extend)
	# UNLESS the loop has skipped portals (which break it into open segments)
	var loop_has_skips = false
	if closed and _monitored_path != null and is_instance_valid(_monitored_path):
		loop_has_skips = _wall_has_skipped_portals(_monitored_path)
	var hide_extend = closed and not loop_has_skips
	# En mode Realistic, "extend with fade" ne s'applique pas -> masqué.
	if ui_config.has("mode_btn_1") and ui_config["mode_btn_1"].pressed:
		hide_extend = true
	if hide_extend:
		if ui_config.has("ext_hbox"):
			ui_config["ext_hbox"].visible = false
		if ui_config.has("extend_section"):
			ui_config["extend_section"].visible = false
		if ui_config.has("fade_extend_container"):
			ui_config["fade_extend_container"].visible = false
		if ui_config.has("ext_which_container"):
			ui_config["ext_which_container"].visible = false
		if ui_config.has("extend_check"):
			ui_config["extend_check"].pressed = false
	else:
		if ui_config.has("ext_hbox"):
			ui_config["ext_hbox"].visible = true
		if ui_config.has("extend_section"):
			ui_config["extend_section"].visible = true
	# Update fade row visibility based on extend state and extend_which
	var ext_on = ui_config["extend_check"].pressed
	if ext_on:
		_update_fade_visibility_for_extend_which()
	elif not is_wall:
		if ui_config.has("fade_in_hbox"):
			ui_config["fade_in_hbox"].visible = true
		if ui_config.has("fade_out_hbox"):
			ui_config["fade_out_hbox"].visible = true

func load_shadow_ui_from_path(path):
	_dirty_properties = {}
	if path == null or not is_instance_valid(path):
		return
	if not path.has_meta("node_id"):
		return

	var node_type = get_node_type(path)
	var defaults_key = USER_DEFAULTS_WALL_KEY if node_type == "walls" else USER_DEFAULTS_KEY
	var has_user_defaults = global.ModMapData.has(defaults_key)
	var config = FACTORY_DEFAULTS.duplicate()

	# Apply user defaults if they exist
	if has_user_defaults:
		var user_def = global.ModMapData[defaults_key]
		for key in user_def.keys():
			config[key] = user_def[key]

	# Load saved per-path config if it exists
	var node_id = str(path.get_meta("node_id"))
	var has_saved = false
	if global.ModMapData.has(SHADOW_DATA_KEY):
		var all_data = global.ModMapData[SHADOW_DATA_KEY]
		if all_data.has(node_id):
			var saved = all_data[node_id]
			for key in saved.keys():
				config[key] = saved[key]
			has_saved = true

	# If no saved config and no user defaults: follow path transition properties
	# If user defaults exist: they already contain the user's preferred transitions
	# Walls never have transitions
	if not has_saved and not has_user_defaults and get_node_type(path) == "paths":
		var path_fade_in = path.get("FadeIn")
		var path_fade_out = path.get("FadeOut")
		var path_grow = path.get("Grow")
		var path_shrink = path.get("Shrink")
		if path_fade_in is bool:
			config["fade_in_enabled"] = path_fade_in
		if path_fade_out is bool:
			config["fade_out_enabled"] = path_fade_out
		if path_grow is bool:
			config["grow_enabled"] = path_grow
		if path_shrink is bool:
			config["shrink_enabled"] = path_shrink
	elif not has_saved and not has_user_defaults and get_node_type(path) == "walls":
		_disable_wall_only_transitions(config)

	set_ui_without_signals(config)

func set_ui_without_signals(config: Dictionary):

	_syncing_ui = true

	var controls = ["enable_check", "opacity_slider", "softness_slider", "spread_slider",
		"opacity_spin", "spread_spin", "softness_spin",
		"offset_x_spin", "offset_y_spin",
		"radial_offset_slider", "radial_offset_spin",
		"side_balance_slider", "side_balance_spin",
		"range_slider", "range_spin", "dist_spin", "angle_spin",
		"dir_btn_0", "dir_btn_1", "dir_btn_2",
		"fade_in_check", "fade_out_check", "grow_check", "shrink_check",
		"fade_in_strength_slider", "fade_in_strength_spin",
		"fade_out_strength_slider", "fade_out_strength_spin",
		"grow_length_slider", "grow_length_spin",
		"shrink_length_slider", "shrink_length_spin",
		"extend_check", "fade_extend_slider", "fade_extend_spin",
		"swap_ends_check", "skip_portals_check", "below_all_walls_check", "shadow_color_picker"]
	for c in controls:
		ui_config[c].set_block_signals(true)

	ui_config["enable_check"].pressed = config.get("enabled", false)
	var _rm_real = config.get("render_mode", "simple") == "realistic"
	var _op_s = config.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"])
	var _op_r = config.get("opacity_realistic", _op_s)
	ui_config["opacity_inactive"] = _op_s if _rm_real else _op_r
	var _op_mx = 2.0 if _rm_real else 1.0
	ui_config["opacity_slider"].max_value = _op_mx
	ui_config["opacity_spin"].max_value = _op_mx
	ui_config["opacity_slider"].value = _op_r if _rm_real else _op_s
	ui_config["opacity_spin"].value = _op_r if _rm_real else _op_s
	if ui_config.has("crop_blur_check"):
		ui_config["crop_blur_check"].pressed = config.get("crop_blur", false)
	if ui_config.has("crop_ends_check"):
		ui_config["crop_ends_check"].pressed = config.get("crop_ends", false)
	_update_crop_blur_visibility()
	ui_config["softness_slider"].value = config.get("softness", DEFAULT_SHADOW_CONFIG["softness"])
	ui_config["softness_spin"].value = config.get("softness", DEFAULT_SHADOW_CONFIG["softness"])
	ui_config["spread_slider"].value = config.get("spread", DEFAULT_SHADOW_CONFIG["spread"])
	ui_config["spread_spin"].value = config.get("spread", DEFAULT_SHADOW_CONFIG["spread"])
	ui_config["offset_x_spin"].value = config.get("offset_x", DEFAULT_SHADOW_CONFIG["offset_x"])
	ui_config["offset_y_spin"].value = config.get("offset_y", DEFAULT_SHADOW_CONFIG["offset_y"])
	var cfg_radial_offset = config.get("radial_offset", DEFAULT_SHADOW_CONFIG["radial_offset"])
	if ui_config.has("radial_offset_slider"):
		ui_config["radial_offset_slider"].value = cfg_radial_offset
	if ui_config.has("radial_offset_spin"):
		ui_config["radial_offset_spin"].value = cfg_radial_offset
	var cfg_side_balance = config.get("side_balance", DEFAULT_SHADOW_CONFIG["side_balance"])
	if ui_config.has("side_balance_slider"):
		ui_config["side_balance_slider"].value = cfg_side_balance
	if ui_config.has("side_balance_spin"):
		ui_config["side_balance_spin"].value = cfg_side_balance
	var cfg_range = config.get("range", DEFAULT_SHADOW_CONFIG["range"])
	ui_config["range_slider"].value = cfg_range
	ui_config["range_spin"].value = cfg_range
	_update_offset_range(cfg_range, false)
	var ox = config.get("offset_x", DEFAULT_SHADOW_CONFIG["offset_x"])
	var oy = config.get("offset_y", DEFAULT_SHADOW_CONFIG["offset_y"])
	_update_angle_distance_from_xy(ox, oy)
	_update_dial_dot_position(ox, oy)
	# Restore snap angle
	var cfg_snap = config.get("snap_angle", DEFAULT_SHADOW_CONFIG["snap_angle"])
	if ui_config.has("dial"):
		ui_config["dial"].set_meta("snap_angle", cfg_snap)
	_deactivate_all_snaps()
	if cfg_snap >= 0.0:
		for snap_key in ["snap_45", "snap_135", "snap_225", "snap_315"]:
			if ui_config.has(snap_key):
				var snap_angles = {"snap_45": 45.0, "snap_135": 135.0, "snap_225": 225.0, "snap_315": 315.0}
				if abs(snap_angles[snap_key] - cfg_snap) < 0.5:
					ui_config[snap_key].pressed = true
	var dir = int(config.get("direction", DEFAULT_SHADOW_CONFIG["direction"]))
	_set_direction_buttons(dir)

	# Transition settings
	ui_config["fade_in_check"].pressed = config.get("fade_in_enabled", DEFAULT_SHADOW_CONFIG["fade_in_enabled"])
	ui_config["fade_out_check"].pressed = config.get("fade_out_enabled", DEFAULT_SHADOW_CONFIG["fade_out_enabled"])
	ui_config["fade_in_strength_slider"].value = config.get("fade_in_strength", DEFAULT_SHADOW_CONFIG["fade_in_strength"])
	ui_config["fade_in_strength_spin"].value = config.get("fade_in_strength", DEFAULT_SHADOW_CONFIG["fade_in_strength"])
	ui_config["fade_out_strength_slider"].value = config.get("fade_out_strength", DEFAULT_SHADOW_CONFIG["fade_out_strength"])
	ui_config["fade_out_strength_spin"].value = config.get("fade_out_strength", DEFAULT_SHADOW_CONFIG["fade_out_strength"])
	ui_config["grow_check"].pressed = config.get("grow_enabled", DEFAULT_SHADOW_CONFIG["grow_enabled"])
	ui_config["shrink_check"].pressed = config.get("shrink_enabled", DEFAULT_SHADOW_CONFIG["shrink_enabled"])
	ui_config["grow_length_slider"].value = config.get("grow_length", DEFAULT_SHADOW_CONFIG["grow_length"])
	ui_config["grow_length_spin"].value = config.get("grow_length", DEFAULT_SHADOW_CONFIG["grow_length"])
	ui_config["shrink_length_slider"].value = config.get("shrink_length", DEFAULT_SHADOW_CONFIG["shrink_length"])
	ui_config["shrink_length_spin"].value = config.get("shrink_length", DEFAULT_SHADOW_CONFIG["shrink_length"])
	ui_config["fade_extend_slider"].value = config.get("fade_extend", DEFAULT_SHADOW_CONFIG["fade_extend"])
	ui_config["fade_extend_spin"].value = config.get("fade_extend", DEFAULT_SHADOW_CONFIG["fade_extend"])
	ui_config["extend_check"].pressed = config.get("extend_enabled", DEFAULT_SHADOW_CONFIG["extend_enabled"])
	ui_config["fade_extend_container"].visible = ui_config["extend_check"].pressed
	var ext_which = int(config.get("extend_which", DEFAULT_SHADOW_CONFIG["extend_which"]))
	_set_extend_which_buttons(ext_which)
	ui_config["ext_which_container"].visible = ui_config["extend_check"].pressed
	ui_config["swap_ends_check"].pressed = config.get("swap_ends", DEFAULT_SHADOW_CONFIG["swap_ends"])
	ui_config["skip_portals_check"].pressed = config.get("skip_portals", DEFAULT_SHADOW_CONFIG["skip_portals"])
	ui_config["below_all_walls_check"].pressed = config.get("below_all_walls", DEFAULT_SHADOW_CONFIG["below_all_walls"])
	if ui_config.has("realistic_blur_slider"):
		ui_config["realistic_blur_slider"].value = config.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.2))
	if ui_config.has("mode_btn_0"):
		_set_render_mode_buttons(_render_mode_to_index(config.get("render_mode", "simple")))
	var sc = config.get("shadow_color", DEFAULT_SHADOW_CONFIG["shadow_color"])
	if sc is String:
		sc = Color(sc)
	ui_config["shadow_color_picker"].color = sc

	# Update transition controls visibility (spin, reset, slider)
	_update_transition_controls_visibility()
	ui_config["dir_wrapper"].visible = ui_config["enable_check"].pressed
	if ui_config.has("mode_wrapper"):
		ui_config["mode_wrapper"].visible = ui_config["enable_check"].pressed
	ui_config["settings_toggle"].visible = ui_config["enable_check"].pressed
	ui_config["title_reset_btn"].visible = ui_config["enable_check"].pressed
	if ui_config["enable_check"].pressed:
		var so = config.get("settings_open", false)
		ui_config["settings_toggle"].pressed = so
		ui_config["settings_panel"].visible = so
		_reparent_extend_toggle(so)
	else:
		ui_config["settings_toggle"].pressed = false
		ui_config["settings_panel"].visible = false
		_reparent_extend_toggle(false)

	for c in controls:
		ui_config[c].set_block_signals(false)

	# Hide transitions section and copy/paste for walls
	_update_wall_ui_visibility()

	_syncing_ui = false

func _update_wall_ui_visibility():
	_update_transition_visibility(_monitored_type)

func reset_ui_to_defaults():
	set_ui_without_signals(DEFAULT_SHADOW_CONFIG)

#########################################################################################################
##
## DATA PERSISTENCE (ModMapData)
##
#########################################################################################################

func save_shadow_data(path, config: Dictionary):
	if path == null or not is_instance_valid(path):
		return
	if not path.has_meta("node_id"):
		return

	var node_id = str(path.get_meta("node_id"))

	if not global.ModMapData.has(SHADOW_DATA_KEY):
		global.ModMapData[SHADOW_DATA_KEY] = {}

	# Convert Color to hex string for JSON serialization
	var save_config = config.duplicate()
	if save_config.has("shadow_color") and save_config["shadow_color"] is Color:
		save_config["shadow_color"] = save_config["shadow_color"].to_html(true)

	global.ModMapData[SHADOW_DATA_KEY][node_id] = save_config
	_all_points_hashes[node_id] = _get_points_hash(path)
	_known_node_ids[node_id] = true
	_all_known_path_ids[node_id] = true


func _are_defaults_custom() -> bool:
	var key = USER_DEFAULTS_WALL_KEY if _monitored_type == "walls" else USER_DEFAULTS_KEY
	return global.ModMapData.has(key)

func _update_reset_defaults_visibility():
	if ui_config.has("reset_default_btn"):
		ui_config["reset_default_btn"].visible = _are_defaults_custom()

func _on_apply_all_pressed():
	ui_config["apply_all_dialog"].popup_centered()

func _style_apply_dialog(timer: Timer):
	timer.queue_free()
	var dialog = ui_config.get("apply_all_dialog")
	if dialog == null:
		return
	for child in dialog.get_children():
		if child is Label and child.text == "":
			child.visible = false
		if child is HBoxContainer:
			# Buttons row of the AcceptDialog: add a 1px white border on each button
			for btn in child.get_children():
				if btn is Button:
					_add_white_border(btn)

func _add_white_border(btn: Button):
	for state in ["normal", "hover", "pressed"]:
		var sb = btn.get_stylebox(state, "Button")
		if sb == null:
			continue
		var styled = sb.duplicate()
		if styled is StyleBoxFlat:
			styled.border_width_left = 1
			styled.border_width_right = 1
			styled.border_width_top = 1
			styled.border_width_bottom = 1
			styled.border_color = Color(1, 1, 1, 1)
			btn.add_stylebox_override(state, styled)

func _on_apply_all_confirmed(mode = "all"):
	ui_config["apply_all_dialog"].hide()
	var cfg = get_current_shadow_config()
	cfg["enabled"] = true
	var count = 0
	_history_begin_manual("apply_all")

	# "Selected walls" mode — apply to current selection only
	if mode == "selected":
		for node in global.Editor.Tools["SelectTool"].Selected:
			if not is_shadow_node_type(node):
				continue
			_history_capture_before(node)
			var obj_config = cfg.duplicate()
			remove_shadow(node)
			create_shadow(node, obj_config)
			save_shadow_data(node, obj_config)
			count += 1
		outputlog("Applied shadow to " + str(count) + " selected walls", 0)
		_history_flush()
		return

	# Walls have a single layer: apply to all walls of the current level only
	var container = _get_current_level_walls_container()
	if container == null:
		outputlog("apply_all: no Walls container found on current level", 0)
		_history_flush()
		return

	var only_without_shadow = (mode == "no_shadow")
	for obj in container.get_children():
		if is_shadow_node_type(obj):
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
	outputlog("Applied shadow to " + str(count) + " walls (mode: " + str(mode) + ")", 0)
	_history_flush()

func _get_current_level_walls_container():
	var current_level = global.World.GetCurrentLevel()
	if current_level == null:
		return null
	for j in range(current_level.get_child_count()):
		var child = current_level.get_child(j)
		if child.name == "Walls":
			return child
	return null

func apply_saved_shadows_to_map():

	outputlog("apply_saved_shadows_to_map", 1)

	if not global.ModMapData.has(SHADOW_DATA_KEY):
		return

	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	var count = 0

	for node_id in shadow_data.keys():
		if global.World.HasNodeID(node_id):
			var node = global.World.GetNodeByID(node_id)
			if is_shadow_node_type(node):
				var config = shadow_data[node_id]
				_known_node_ids[node_id] = true
				_all_known_path_ids[node_id] = true
				if config.get("enabled", false):
					remove_shadow(node)
					create_shadow(node, config)
					_all_points_hashes[node_id] = _get_points_hash(node)
					count += 1
		else:
			shadow_data.erase(node_id)

	outputlog("Applied shadows to " + str(count) + " paths", 0)
