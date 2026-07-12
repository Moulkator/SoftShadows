#########################################################################################################
##
## DROP SHADOW FOR PATHS
##
#########################################################################################################
# Version 4.0.0 - PATHS ONLY
# class_name DropShadowPaths

var global
var reference_to_script = null
var core = null

# UI references
var ui_config = {}

# Constants
const SHADOW_META_KEY = "drop_shadow_nodes"
const SHADOW_DATA_KEY = "DropShadow"
const USER_DEFAULTS_KEY = "DropShadowUserDefaults"
const USER_DEFAULTS_WALL_KEY = "DropShadowUserDefaultsWall"

const FACTORY_DEFAULTS = {
	"enabled": false,
	"opacity": 1.0,
	"opacity_realistic": 0.9,
	"softness": 2.75,
	"direction": 2,
	"spread": 0.25,
	"offset_x": 0.0,
	"offset_y": 0.0,
	"offset_angle": 0.0,          # angle du dial d'offset (deg) ; sert au bombage lié si offset nul
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
	"extend_which": 2,
	"fade_extend": 0.0,
	"swap_ends": false,
	"skip_portals": false,
	"behind_layer": false,
	"render_mode": "simple",  # "simple" = mesh géométrique | "realistic" = silhouette texturée (mode B)
	"realistic_blur": 0.2,  # flou du mode realistic (0 = net), 0..1 -> 0..REALISTIC_BLUR_MAX_PX
	# Bulge : renflement local de l'ombre par-dessus l'offset de base rigide. La zone
	# [entry, exit] (fractions de la longueur du path) bombe d'un vecteur (bulge dial),
	# lié par défaut à l'offset principal (délier = direction indépendante via le dial).
	# Renflement local additionné à l'offset de base. Points Entry/Exit (positions +
	# ON/OFF) ; longueurs de rampe linkables ; easing smooth(arc)/plateau per-côté linkable.
	"bulge_enabled": false,
	"bulge_distance": 200.0,        # ampleur du bombage (px), indépendante du dial
	"bulge_link": true,           # lier la direction du bombage à l'offset principal
	"bulge_angle": 0.0,           # direction du bombage en degrés (si délié)
	"bulge_entry": 0.0,           # position du point d'entrée (0..1)
	"bulge_exit": 1.0,            # position du point de sortie (0..1)
	"bulge_entry_active": true,   # point d'entrée actif (sinon décollé jusqu'au début)
	"bulge_exit_active": true,    # point de sortie actif (sinon décollé jusqu'à la fin)
	"bulge_entry_len": 0.5,       # longueur de rampe entrée (0.02..1.0)
	"bulge_exit_len": 0.5,        # longueur de rampe sortie (0.02..1.0)
	"bulge_ramp_link": true,      # lier les longueurs de rampe entrée/sortie
	"bulge_entry_smooth": true,   # entrée : true = arc doux (sin), false = plateau (smoothstep)
	"bulge_exit_smooth": true,    # sortie : true = arc doux, false = plateau
	"bulge_smooth_link": true,    # lier le profil smooth entrée/sortie
	"shadow_color": Color(0, 0, 0, 1)
}

var DEFAULT_SHADOW_CONFIG = FACTORY_DEFAULTS.duplicate()

# --- Flou du mode "Realistic" (tunables) ---
# Le rayon de flou réutilise le slider Softness : blur_px = softness * half_width,
# plafonné ici. Le strip est élargi de ~1.25x ce rayon pour donner de la place au
# halo (un Line2D est borné par la largeur de sa texture), puis le shader étale
# l'alpha par un noyau gaussien (2*K+1)^2.
const REALISTIC_BLUR_MAX_PX = 180.0   # plafond du rayon de flou (world px)
const REALISTIC_MIN_BLUR_PX = 0.5     # en deçà : copie nette vectorielle (sous-pixel) ; au-dessus : bake polaire
const REALISTIC_BLUR_FLOOR_PX = 6.0   # palier bas : tout flou > 0 vaut au moins ça (les valeurs minuscules crénelaient)
const REALISTIC_BLUR_MARGIN_MULT = 1.4  # marge de strip / rayon de flou
const REALISTIC_BLUR_MAX_K = 6       # demi-taille max du noyau (doit = MAXK du shader)
const REALISTIC_BLUR_STRIDE_PX = 10.0  # pas cible entre taps -> kn = ceil(rayon / pas)
const REALISTIC_FOLD_SAFETY = 0.85   # offset concave max = SAFETY * rayon de courbure
const REALISTIC_VP_MAX_DIM = 2048.0  # résolution max de la capture (downscale au-delà)
const REALISTIC_LIVE_THRESHOLD_MS = 120  # 2 (re)builds flous rapprochés -> édition interactive -> mode live (viewport persistant)
const REALISTIC_LIVE_SETTLE_MS = 170     # calme après édition -> conversion en texture statique mipmappée (qualité pleine)
const REALISTIC_LIVE_HEADROOM = 1.6      # marge sur la taille du viewport live -> on ne le resize qu'à la croissance, pas chaque frame
const REALISTIC_VP_DOWNSAMPLE = 1.0  # pleine résolution : source nette -> pas de crénelage
const REALISTIC_BLUR_STEPS = 24      # nb d'angles du noyau polaire (cf. shader des objets)
const REALISTIC_BLUR_QUALITY = 8     # nb d'anneaux radiaux du noyau polaire


const OVERLAY_META_KEY = "overlay_shadow_nodes"
const OVERLAY_DATA_KEY = "DropShadowOverlay"

const OVERLAY_DEFAULTS = {
	"enabled": false,
	"opacity": 0.90,
	"direction": 0,  # 0=Side A, 1=Side B, 2=Both
	"axis": 0,  # 0=Horizontal (longueur du path), 1=Vertical (hauteur du trait)
	"fade_length": 0.5,  # 0-1, fraction of path covered by fade
	"shadow_color": Color(0, 0, 0, 1)
}

var overlay_ui = {}

enum ShadowDirection { OUTER = 0, INNER = 1, BOTH = 2 }

# Container at the Level for "behind layer" path shadows (sits before the
# Pathways node so it renders below all paths, regardless of overlap order).
# Same pattern as DropShadowWalls' BELOW_ALL_CONTAINER_NAME.
const BELOW_LAYER_CONTAINER_NAME = "DropShadowPathsBelowLayer"

func _get_below_layer_container(line_node: Node2D):
	"""Get/create the Level-scoped container that holds detached "behind
	layer" path shadow meshes. Parented to the Level (NOT inside Pathways
	— that breaks DD's internal Pathways iteration), placed before Pathways
	in scene-tree order."""
	if line_node == null or not is_instance_valid(line_node):
		return null
	var pathways = null
	var walker = line_node.get_parent()
	while walker != null:
		if walker.name == "Pathways":
			pathways = walker
			break
		walker = walker.get_parent()
	if pathways == null:
		return null
	var level = pathways.get_parent()
	if level == null:
		return null
	var container = level.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
	if container == null:
		container = Node2D.new()
		container.name = BELOW_LAYER_CONTAINER_NAME
		container.z_as_relative = false
		container.z_index = 0
		level.add_child(container)
	# Always sit BEFORE Pathways in tree order.
	var pathways_idx = pathways.get_index()
	if container.get_index() >= pathways_idx:
		level.move_child(container, pathways_idx)
	return container

func _cleanup_below_layer_orphans():
	"""Remove detached shadow meshes from the BELOW_LAYER container that are
	no longer referenced by any path's SHADOW_META_KEY meta."""
	if global == null or global.World == null:
		return
	var current_level = global.World.GetCurrentLevel()
	if current_level == null:
		return
	var container = current_level.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
	if container == null or container.get_child_count() == 0:
		return
	var referenced = {}
	if global.ModMapData.has(SHADOW_DATA_KEY):
		for nid in global.ModMapData[SHADOW_DATA_KEY].keys():
			if not global.World.HasNodeID(nid):
				continue
			var path = global.World.GetNodeByID(nid)
			if path == null or not is_instance_valid(path):
				continue
			if path.has_meta(SHADOW_META_KEY):
				var snodes = path.get_meta(SHADOW_META_KEY)
				if snodes is Array:
					for sn in snodes:
						if is_instance_valid(sn):
							referenced[sn.get_instance_id()] = true
	for ci in range(container.get_child_count() - 1, -1, -1):
		var child = container.get_child(ci)
		if not referenced.has(child.get_instance_id()):
			container.remove_child(child)
			child.queue_free()

#########################################################################################################
##
## EXPORT DIALOG HOOK
## DD's export pipeline only renders content inside its recognized level
## nodes (Terrain, FloorShapes, WaterMesh, Walls, Roofs, ...). Anything in a
## custom Level-scoped container — including our DropShadowPathsBelowLayer —
## is rendered as an overlay ABOVE the map, breaking the "behind layer"
## semantics. Workaround inspired by the grid_fix mod's approach: while the
## export window is open, copy each behind_layer shadow mesh into a DD-known
## container that renders before Pathways (we use FloorShapes), then delete
## the copies when the window closes. We can't move the originals because
## putting our Node2Ds into Walls/etc. would crash DD's SelectTool.
##
#########################################################################################################

const EXPORT_COPY_SUFFIX = "_DropShadowExportCopy"
var _export_dialog_ref = null
var _export_shadow_copies := []  # Array of [original_mesh, copy_mesh]

func _hook_export_dialog():
	if _export_dialog_ref != null and is_instance_valid(_export_dialog_ref):
		return
	if global == null or global.Editor == null:
		return
	if not ("Windows" in global.Editor):
		return
	var dialog = global.Editor.Windows.get("Export") if global.Editor.Windows is Dictionary else null
	if dialog == null:
		return
	_export_dialog_ref = dialog
	if not dialog.is_connected("about_to_show", self, "_on_export_about_to_show"):
		dialog.connect("about_to_show", self, "_on_export_about_to_show")
	if not dialog.is_connected("popup_hide", self, "_on_export_popup_hide"):
		dialog.connect("popup_hide", self, "_on_export_popup_hide")

func _on_export_about_to_show():
	"""Copy each behind_layer shadow mesh into a DD-recognized level node
	(FloorShapes, fallback WaterMesh) so the export pipeline renders it in
	the right order, and hide the originals to prevent double rendering."""
	_delete_export_shadow_copies()
	if global == null or global.World == null:
		return
	var level = global.World.GetCurrentLevel()
	if level == null:
		return
	var container = level.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
	if container == null or container.get_child_count() == 0:
		return
	# Pick a DD-known parent that renders before Pathways. FloorShapes is the
	# most natural fit (paths sit visually on top of floor textures); fall back
	# to WaterMesh / Terrain if needed.
	var export_parent = level.find_node("FloorShapes", false, false)
	if export_parent == null:
		export_parent = level.find_node("WaterMesh", false, false)
	if export_parent == null:
		export_parent = level.find_node("Terrain", false, false)
	if export_parent == null:
		return
	for child in container.get_children():
		if not (child is MeshInstance2D):
			continue
		if child.mesh == null:
			continue
		var copy = MeshInstance2D.new()
		copy.name = child.name + EXPORT_COPY_SUFFIX
		copy.mesh = child.mesh
		copy.material = child.material
		copy.modulate = child.modulate
		copy.self_modulate = child.self_modulate
		# Preserve absolute z (= source path's z) so render order respects the
		# path's visual layer; tree position (FloorShapes is before Pathways)
		# breaks ties so the shadow draws below its path.
		copy.z_as_relative = false
		copy.z_index = child.z_index
		var orig_global = child.global_transform
		export_parent.add_child(copy)
		copy.global_transform = orig_global
		_export_shadow_copies.append([child, copy])
		# Hide original during export so we don't render it twice (the
		# overlay rendering of our level container would still happen).
		child.visible = false

func _on_export_popup_hide():
	_delete_export_shadow_copies()

func _delete_export_shadow_copies():
	for pair in _export_shadow_copies:
		var original = pair[0]
		var copy = pair[1]
		if is_instance_valid(original):
			original.visible = true
		if is_instance_valid(copy):
			if copy.get_parent() != null:
				copy.get_parent().remove_child(copy)
			copy.queue_free()
	_export_shadow_copies.clear()

# Render shadow mesh as a direct MeshInstance2D child of `line`.
# Opacity and color are baked into vertex colors by the mesh builder.
# When `behind_layer` is true, we use the same trick as the Dropshadow mod
# for objects: keep the mesh as a child of the line (so DD's standard scene
# hierarchy treats it normally — including during export), and just set
# `z_as_relative = true` with `z_index = -1`. Effective z = line.z - 1, so
# the shadow renders below its path's visual layer regardless of whether
# we're in the editor or in the export pipeline.
func _create_shadow_mesh_node(line: Node2D, mesh: ArrayMesh,
	user_offset: Vector2, node_name: String, behind_layer: bool = false) -> Array:
	if mesh.get_surface_count() == 0:
		return []
	var mesh_inst = MeshInstance2D.new()
	mesh_inst.mesh = mesh
	mesh_inst.name = node_name
	mesh_inst.position = user_offset
	if behind_layer:
		# Sit one z-unit below the line's z bucket. Stays in the standard
		# scene tree (child of line), so DD's editor and export pipelines
		# render it consistently.
		mesh_inst.z_as_relative = true
		mesh_inst.z_index = -1
		mesh_inst.show_behind_parent = false
	else:
		mesh_inst.show_behind_parent = true
	line.add_child(mesh_inst)
	return [mesh_inst]

# Fast-path: update only offset on existing shadow nodes without rebuilding mesh.
# Opacity and color are baked into vertex colors, so changing them requires a full rebuild.
# Only offset can be updated in-place.
const FAST_UPDATE_PARAMS = ["offset_x", "offset_y"]

func _can_fast_update(changed_params: Array, cfg: Dictionary) -> bool:
	if changed_params.size() == 0:
		return false
	# Bulge lié : l'offset pilote aussi le vecteur de bombage -> sa modif change la
	# géométrie -> rebuild (pas de simple repositionnement). Délié = pure translation -> OK.
	if _bulge_enabled(cfg) and cfg.get("bulge_link", true):
		return false
	for p in changed_params:
		if not (p in FAST_UPDATE_PARAMS):
			return false
	return true

func _fast_update_shadow(path, config: Dictionary) -> bool:
	if not path.has_meta(SHADOW_META_KEY):
		return false
	var nodes = path.get_meta(SHADOW_META_KEY)
	if not (nodes is Array) or nodes.size() == 0:
		return false
	var offset = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	var line = get_line2d(path)
	if line == null:
		return false
	# Convert world offset to line-local space, accounting for rotation AND mirror (scale)
	var local_offset = line.global_transform.affine_inverse().basis_xform(offset)
	for node in nodes:
		if not is_instance_valid(node):
			return false
		# Ombre floutée (Viewport + Sprite) : la position du sprite est calculée,
		# pas un simple offset -> on force un rebuild complet pour l'offset.
		if node is Viewport or node is Sprite:
			return false
		if not (node is MeshInstance2D or node is Line2D):
			continue
		node.position = local_offset
	return true

# Paramètres qui, en mode Realistic, ne touchent QUE le shader du Sprite (ou la
# teinte de la copie nette) : mise à jour en direct, sans recréer le viewport.
const REALISTIC_LIVE_PARAMS = ["opacity", "shadow_color", "realistic_blur", "offset_x", "offset_y"]
# Params de FORME du bombage : modifiables en live (uniformes vertex shader) tant que
# l'ombre est NETTE (Line2D rendu chaque frame). En FLOU, le bombage est cuit dans la
# texture -> re-bake requis, donc on ne les autorise pas en live dans ce cas.
const BULGE_LIVE_PARAMS = ["bulge_distance", "bulge_angle", "bulge_entry", "bulge_exit",
	"bulge_entry_len", "bulge_exit_len", "bulge_entry_active", "bulge_exit_active",
	"bulge_entry_smooth", "bulge_exit_smooth"]

# Décalage perpendiculaire (radial offset / side balance) : géométrie de la silhouette,
# gérée en live (net : refresh des points ; flou : session live, re-render GPU).
const REALISTIC_RADIAL_PARAMS = ["radial_offset", "side_balance"]

func _can_live_update_realistic(changed_params: Array, cfg: Dictionary) -> bool:
	if cfg.get("render_mode", "simple") != "realistic":
		return false
	if changed_params.size() == 0:
		return false
	for p in changed_params:
		if p in REALISTIC_LIVE_PARAMS:
			continue
		# Forme du bombage : live en net (uniformes) ou en flou (session live, re-render GPU).
		if (p in BULGE_LIVE_PARAMS) and _bulge_enabled(cfg):
			continue
		if p in REALISTIC_RADIAL_PARAMS:
			continue
		return false
	return true

# Met à jour une ombre Realistic existante sans rebuild. Renvoie false si la forme
# doit changer (net <-> flou) -> l'appelant fait alors un rebuild complet.
func _live_update_realistic(path, cfg: Dictionary, changed = []) -> bool:
	if not path.has_meta(SHADOW_META_KEY):
		return false
	var nodes = path.get_meta(SHADOW_META_KEY)
	if not (nodes is Array) or nodes.size() == 0:
		return false
	var first = nodes[0]
	if not is_instance_valid(first):
		return false
	var line = get_line2d(path)
	if line == null:
		return false
	# Boucle fermée + radial/side balance : la silhouette vient d'un ruban qui échantillonne
	# le bitmap du Line2D naturel. En FLOU avec ce bitmap déjà en cache, on laisse passer
	# vers la session live (mise à jour GPU, pas de lag). Sinon (net, ou bitmap pas encore
	# capturé), on force le rebuild via la coroutine _create_realistic_loop (qui le capture).
	if _is_line_closed(line) and not _bulge_enabled(cfg) and _make_radial(cfg, line) != null:
		var blur_px0 = _realistic_blur_px_from_frac(cfg.get("realistic_blur", 0.0))
		var loop_live_ok = blur_px0 >= REALISTIC_MIN_BLUR_PX and _loop_nat_valid(path.get_instance_id(), line)
		if not loop_live_ok:
			return false

	# Un changement de direction (Side A/B/Both) change la silhouette (clip d'un côté) et
	# peut basculer Line2D <-> ruban -> rebuild complet (rare, pas de souci de lag).
	if "direction" in changed:
		return false

	var opacity = cfg.get("opacity_realistic", cfg.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"]))
	var shadow_color = cfg.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	var blur_px = _realistic_blur_px_from_frac(cfg.get("realistic_blur", 0.0))
	var want_blur = blur_px >= REALISTIC_MIN_BLUR_PX
	var offset = Vector2(cfg.get("offset_x", 0.0), cfg.get("offset_y", 0.0))
	offset = line.global_transform.affine_inverse().basis_xform(offset)

	# Un changement de FORME (bombage, ou décalage radial / side balance, ou l'offset
	# quand le bombage est lié car il pilote la direction) en flou : on pilote la session
	# live (re-render GPU du viewport, pas de re-bake CPU) au lieu de rebuild -> pas de lag.
	var bulge_shape_changed = false
	for p in changed:
		if p in BULGE_LIVE_PARAMS:
			bulge_shape_changed = true
			break
	var radial_shape_changed = ("radial_offset" in changed) or ("side_balance" in changed)
	var offset_changed = ("offset_x" in changed) or ("offset_y" in changed)
	var bulge_linked = cfg.get("bulge_link", true)
	var bulge_drive = _bulge_enabled(cfg) and (bulge_shape_changed or (offset_changed and bulge_linked))
	if want_blur and (bulge_drive or radial_shape_changed):
		var behind = cfg.get("behind_layer", false)
		var bulge = _make_bulge(cfg, line)
		var radial = _make_radial(cfg, line)
		var lnid2 = path.get_instance_id()
		_realistic_last_req[lnid2] = OS.get_ticks_msec()
		if _realistic_live.has(lnid2):
			_update_realistic_live(path, line, offset, shadow_color, opacity, behind, blur_px, bulge, radial)
		else:
			_start_realistic_live(path, line, offset, shadow_color, opacity, behind, blur_px, bulge, radial)
		return true

	var mat = first.material
	if mat == null:
		return false
	if first is Sprite:
		# Forme floutée. Si on repasse net -> rebuild.
		if not want_blur:
			return false
		var ds = first.get_meta("ds_scale") if first.has_meta("ds_scale") else 1.0
		var base_pos = first.get_meta("base_pos") if first.has_meta("base_pos") else first.position
		var tsize = first.get_meta("tsize") if first.has_meta("tsize") else Vector2(1.0, 1.0)
		var k = _realistic_blur_kernel(blur_px, ds)
		var blur_vp = k[0]
		var vsx = (tsize.x + 2.0 * blur_vp) / tsize.x
		var vsy = (tsize.y + 2.0 * blur_vp) / tsize.y
		mat.set_shader_param("shadow_color", shadow_color)
		mat.set_shader_param("shadow_strength", opacity)
		mat.set_shader_param("blur_px", blur_vp)
		mat.set_shader_param("mip_lod", k[1])
		mat.set_shader_param("vertex_scale", Vector2(vsx, vsy))
		first.position = base_pos + offset
		# Si une session live est active, garder ses params à jour pour que la
		# conversion en texture statique reprenne couleur/opacité/flou/offset corrects.
		var lnid = path.get_instance_id()
		if _realistic_live.has(lnid):
			var sess = _realistic_live[lnid]
			sess["color"] = shadow_color
			sess["opacity"] = opacity
			sess["blur_px"] = blur_px
			sess["offset"] = offset
		return true
	elif first is Line2D:
		# Forme nette. Si on passe au flou -> rebuild (besoin du viewport).
		if want_blur:
			return false
		# Radial/side balance vient d'être activé -> passage au ruban Mesh : rebuild.
		if radial_shape_changed and _make_radial(cfg, line) != null:
			return false
		mat.set_shader_param("shadow_color", shadow_color)
		mat.set_shader_param("shadow_strength", opacity)
		first.position = offset
		# Bombage : maj des uniformes de déplacement (vertex shader) sans rebuild.
		if _bulge_enabled(cfg):
			_apply_bulge_uniforms(mat, _make_bulge(cfg, line))
		return true
	elif first is MeshInstance2D:
		# Ruban net (radial/side balance actif). Si on passe au flou -> rebuild.
		if want_blur:
			return false
		# Radial désactivé -> retour au Line2D : rebuild.
		if radial_shape_changed and _make_radial(cfg, line) == null:
			return false
		first.position = offset
		if radial_shape_changed or bulge_shape_changed:
			first.mesh = _build_silhouette_strip(line, _make_bulge(cfg, line), _make_radial(cfg, line))
		if mat is ShaderMaterial:
			mat.set_shader_param("shadow_color", shadow_color)
			mat.set_shader_param("shadow_strength", opacity)
		return true
	return false

# Logging Functions
const ENABLE_LOGGING = true
var logging_level = 0

# Cache for visible texture height ratios (texture resource path → ratio)
var _visible_height_cache = {}

func _get_visible_height_ratio(line) -> float:
	if line.texture == null:
		return 1.0
	var tex = line.texture
	var cache_key = tex.resource_path if tex.resource_path != "" else str(tex.get_rid().get_id())
	if _visible_height_cache.has(cache_key):
		return _visible_height_cache[cache_key]
	var img = tex.get_data()
	if img == null:
		_visible_height_cache[cache_key] = 1.0
		return 1.0
	img.lock()
	var w = img.get_width()
	var h = img.get_height()
	if h == 0 or w == 0:
		img.unlock()
		_visible_height_cache[cache_key] = 1.0
		return 1.0
	var first_visible = h
	for y in range(h):
		var found = false
		for x in range(0, w, max(1, w / 16)):
			if img.get_pixel(x, y).a > 0.01:
				found = true
				break
		if found:
			first_visible = y
			break
	var last_visible = -1
	for y in range(h - 1, -1, -1):
		var found = false
		for x in range(0, w, max(1, w / 16)):
			if img.get_pixel(x, y).a > 0.01:
				found = true
				break
		if found:
			last_visible = y
			break
	img.unlock()
	if first_visible >= h or last_visible < 0:
		_visible_height_cache[cache_key] = 1.0
		return 1.0
	var visible_rows = last_visible - first_visible + 1
	var ratio = float(visible_rows) / float(h)
	_visible_height_cache[cache_key] = ratio
	return ratio

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
	# Find all ToolButtons inside the ColorPicker (the eyedropper is a ToolButton)
	for child in picker.get_children():
		if child is ToolButton:
			child.visible = false
			child.disabled = true
			break
	# Also search deeper (Godot 3.x may nest the button)
	_hide_screen_pick_recursive(picker)

func _hide_screen_pick_recursive(node) -> void:
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		if child is ToolButton:
			# The screen pick button typically has no text and a small size
			child.visible = false
			child.disabled = true
		elif child.get_child_count() > 0:
			_hide_screen_pick_recursive(child)

func get_node_type(node):
	if node == null or not is_instance_valid(node):
		return null
	# Portals have WallID
	if node.get("WallID") != null:
		return null  # We don't handle portals
	# Paths have FadeIn
	if node.get("FadeIn") != null:
		return "paths"
	# Walls have Joint
	if node.get("Joint") != null:
		return "walls"
	return null

func is_shadow_node_type(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var t = get_node_type(node)
	return t == "paths"

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

# Variante prenant directement le Line2D (utilisée pour fermer la copie realistic).
func _is_line_closed(line) -> bool:
	if line == null or not is_instance_valid(line) or line.points.size() < 3:
		return false
	for prop_name in ["loop", "Loop", "closed", "Closed", "IsLoop"]:
		var val = line.get(prop_name)
		if val is bool and val:
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
	base_color: Color = Color(0, 0, 0, 1), corner_factors_outer = null,
	corner_factors_inner = null, radial_offset: float = 0.0) -> ArrayMesh:

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
		var corner_f_outer = 1.0
		if corner_factors_outer != null and i < corner_factors_outer.size():
			corner_f_outer = corner_factors_outer[i]
		var corner_f_inner = 1.0
		if corner_factors_inner != null and i < corner_factors_inner.size():
			corner_f_inner = corner_factors_inner[i]
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
				vert = p + n_inner * (corner_f_inner * dist)
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
				vert = p + n_outer * (corner_f_outer * dist)
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
# at the path endpoint. The semi-axis along `outward` is scaled by
# `outward_scale`:
#    outward_scale = 1.0  -> perfect half-circle (default)
#    outward_scale < 1.0  -> compressed (cap is squashed toward the strip)
#    outward_scale > 1.0  -> elongated (cap extends further past the endpoint)
#    outward_scale = 0.0  -> degenerate (no cap)
#
# Each "ray" of the cap (from center outward to the rim) reproduces the
# cross-section of the strip: full opacity inside `spread`, smoothstep fade
# through `softness`. The alpha is driven by the radial parameter `t` (not
# Euclidean distance), so contours of equal opacity follow ellipse contours
# and the strip / cap junction stays seamless regardless of `outward_scale`.
#
# half_only_sign:
#    0  -> full half-disc/ellipse (BOTH direction)
#   +1  -> quarter on +normal side only (OUTER direction)
#   -1  -> quarter on -normal side only (INNER direction)
#
# `outward` and `normal` must be unit vectors and perpendicular to each other.
# `outward` is the direction the path is heading at the endpoint (so for the
# start of the path, pass -tangent_in; for the end, pass +tangent_out).
func _build_cap_mesh(center: Vector2, outward: Vector2, normal: Vector2,
	spread: float, softness: float, opacity: float,
	base_color: Color, angular_steps: int, radial_strips: int,
	half_only_sign: float, outward_scale: float = 1.0) -> ArrayMesh:

	var mesh = ArrayMesh.new()
	var total_dist = spread + softness
	if total_dist <= 0.01 or angular_steps < 2 or radial_strips < 1:
		return mesh
	# Degenerate (or near-degenerate) cap: skip rendering entirely.
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

	var radial_count = radial_strips + 1  # number of radial samples (incl. r=0 at center)

	for a in range(angular_steps + 1):
		var phi = phi_start + (phi_end - phi_start) * (float(a) / float(angular_steps))
		# Half-ellipse: outward axis scaled by outward_scale, normal axis at full length
		var dir_phi = outward * (cos(phi) * outward_scale) + normal * sin(phi)
		for r in range(radial_count):
			var t = float(r) / float(radial_count - 1)
			var rad = t * total_dist
			verts.append(center + dir_phi * rad)

			# Alpha driven by the parameter `rad` (matches strip cross-section gradient).
			# Note: this is intentional — using the actual Euclidean distance from
			# center would shift the spread/softness boundary as outward_scale varies
			# and break the strip-cap junction at phi = ±PI/2.
			var alpha = 0.0
			if rad <= spread:
				alpha = opacity
			elif softness > 0.01:
				var fade_t = (rad - spread) / softness
				alpha = opacity * (1.0 - smoothstep_val(fade_t))
			colors.append(Color(base_color.r, base_color.g, base_color.b, alpha))

	# Triangulate as a grid of quads (angular x radial).
	# Quads at r=0 are degenerate (zero-area, all share `center`) and emit no pixels.
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

#########################################################################################################
##
## INITIALISE
##
#########################################################################################################

func initialise() -> void:
	outputlog("Drop Shadow Paths initialising...")

	build_select_tool_ui()
	_build_path_tool_ui()

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

	# Hook DD's export dialog so behind_layer shadows render correctly during
	# export (DD's export pipeline renders content outside its recognized
	# level containers — like our Level-scoped DropShadowPathsBelowLayer — as
	# an overlay above everything else; we work around this by temporarily
	# copying our shadows into a recognized container while export is open).
	_hook_export_dialog()

	outputlog("Drop Shadow Paths initialised.", 0)
	outputlog("[BUILD: PATHS-FRAMELOCK-2]", 0)

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
			if _wall_tool_toggle != null and _wall_tool_toggle.pressed:
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

# Called by DD when a new node is added to the world (used for split/copy detection)
# We MUST NOT modify any collections here as DD is iterating its mod list
var _pending_new_nodes = []
var _current_batch_ids = {}
# Tracks which IDs were selected last tick — used to prefer correct sources during paste
var _last_selection_ids = {}

func on_new_node_added_to_world(node):
	if node == null or not is_instance_valid(node):
		return
	# Op native d'ajout (placement/paste/redo) -> marqueur timeline (gardé par
	# l'armement et la fenêtre de suppression interne à note_native_op).
	if _native_detect_ready and shadow_history != null and shadow_history.has_method("note_native_op"):
		shadow_history.note_native_op()
	_pending_new_nodes.append(node)

func _deferred_on_new_node_added(node):
	if node == null or not is_instance_valid(node):
		return
	var node_type = get_node_type(node)
	if node_type == null:
		return
	if not node.has_meta("node_id"):
		return
	var new_id = str(node.get_meta("node_id"))

	# Skip if already has shadow config AND overlay config
	var has_shadow = global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(new_id)
	var has_overlay = global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(new_id)
	if has_shadow and has_overlay:
		return

	# --- Try split detection (wall/path geometry changed) ---
	var source_id = _find_split_source(node, node_type)

	# --- Try copy detection: match hash against ALL paths with shadow data ---
	if source_id == "":
		source_id = _find_copy_source_by_hash(new_id, node)

	if source_id == "":
		return

	# --- Copy config from source ---
	_copy_config_from_source(node, new_id, source_id, has_shadow, has_overlay)

func _find_copy_source_by_hash(new_id: String, node) -> String:
	"""Match a new node's geometry against existing paths with shadow/overlay data.

	Uses the geometry-only hash (no rotation/scale) so a freshly pasted or
	duplicated node still matches its source even if DD hasn't fully applied
	the source's transform yet at the time this runs.
	The full-hash cache `_all_points_hashes` is bypassed here because it
	stores the *full* hash; we always recompute the geom hash live for the
	source node. This is O(n_points) per source — fine in practice.
	Prefers sources from `_last_selection_ids` (what was selected before the
	paste). If the original in the selection had no shadow data, returns
	empty (no false copy)."""
	var new_hash = _get_points_hash(node, true)
	if new_hash == 0:
		return ""
	# Collect all source IDs that have shadow or overlay data
	var all_src_ids = {}
	if global.ModMapData.has(SHADOW_DATA_KEY):
		for sid in global.ModMapData[SHADOW_DATA_KEY].keys():
			all_src_ids[sid] = true
	if global.ModMapData.has(OVERLAY_DATA_KEY):
		for sid in global.ModMapData[OVERLAY_DATA_KEY].keys():
			all_src_ids[sid] = true
	# First pass: check _last_selection_ids for matching geom hash
	var found_hash_in_selection = false
	for src_id in _last_selection_ids.keys():
		if src_id == new_id or _current_batch_ids.has(src_id):
			continue
		if not global.World.HasNodeID(src_id):
			continue
		var src_node = global.World.GetNodeByID(src_id)
		if not is_instance_valid(src_node):
			continue
		var src_hash = _get_points_hash(src_node, true)
		if src_hash == new_hash:
			found_hash_in_selection = true
			# Hash matches a selected source — only copy if it has shadow data
			if all_src_ids.has(src_id):
				return src_id
			# Original was selected but has no shadow data → don't copy from elsewhere
			return ""
	# Second pass: only if no hash match was found in selection at all
	# (handles cases where selection tracking failed, e.g. split)
	if not found_hash_in_selection:
		for src_id in all_src_ids.keys():
			if src_id == new_id or _current_batch_ids.has(src_id):
				continue
			if not global.World.HasNodeID(src_id):
				continue
			var src_node = global.World.GetNodeByID(src_id)
			if not is_instance_valid(src_node):
				continue
			if _get_points_hash(src_node, true) == new_hash:
				return src_id
	return ""

func _copy_config_from_source(node, new_id: String, source_id: String, has_shadow: bool, has_overlay: bool):
	# Copy shadow config from source
	if not has_shadow and global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(source_id):
		var src_config = global.ModMapData[SHADOW_DATA_KEY][source_id]
		var new_config = src_config.duplicate()
		save_shadow_data(node, new_config)
		if new_config.get("enabled", false):
			yield(global.Editor.get_tree().create_timer(0.05), "timeout")
			if is_instance_valid(node):
				remove_shadow(node)
				create_shadow(node, new_config)
				_all_points_hashes[new_id] = _get_points_hash(node)
		outputlog("Copied shadow config from " + source_id + " to " + new_id, 0)

	# Copy overlay config from source
	if not has_overlay and global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(source_id):
		var src_overlay = global.ModMapData[OVERLAY_DATA_KEY][source_id]
		var new_overlay = src_overlay.duplicate()
		save_overlay_data(node, new_overlay)
		if new_overlay.get("enabled", false):
			yield(global.Editor.get_tree().create_timer(0.06), "timeout")
			if is_instance_valid(node):
				remove_overlay_shadow(node)
				create_overlay_shadow(node, new_overlay)
		outputlog("Copied overlay config from " + source_id + " to " + new_id, 0)

func _find_split_source(node, node_type: String) -> String:
	# Method 1: For walls, find wall whose point count decreased (split detection via snapshot)
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
					if _wall_point_snapshot.has(cid):
						var old_count = _wall_point_snapshot[cid]
						var new_count = _get_wall_line2d_point_count(wall_child)
						if new_count < old_count:
							if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(cid):
								return cid

	# Method 2: For paths, check if a selected path was split (hash changed)
	if node_type == "paths":
		# Check both shadow and overlay sources
		var all_src_ids = {}
		if global.ModMapData.has(SHADOW_DATA_KEY):
			for sid in global.ModMapData[SHADOW_DATA_KEY].keys():
				all_src_ids[sid] = true
		if global.ModMapData.has(OVERLAY_DATA_KEY):
			for sid in global.ModMapData[OVERLAY_DATA_KEY].keys():
				all_src_ids[sid] = true
		for src_id in all_src_ids.keys():
			if not global.World.HasNodeID(src_id):
				continue
			var src_node = global.World.GetNodeByID(src_id)
			if get_node_type(src_node) != "paths":
				continue
			# Check if points hash changed (fewer points = was split, same = was copied)
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
var _native_state_by_id = {}   # node_id -> {pos, hash} (détection move ET reshape natifs)
var _native_detect_ready = false
var _native_arm_count = 0
var _native_heal_count = 0

# Tool panel references
var _path_tool_toggle = null  # CheckButton in PathTool
var _pt_editing_path = null   # Currently tracked editing path in PathTool
var _pt_editing_hash = 0      # Points hash of tracked editing path
var _pt_finalized_path = null  # Path that was just finalized, needs transition rebuild
var _pt_finalized_ticks = 0    # Ticks since finalization (rebuild a few times to catch transitions)

func _get_points_hash(path, geom_only: bool = false) -> int:
	# When `geom_only` is true, rotation and global scale are excluded.
	# That mode is used by copy detection only — DD doesn't always apply the
	# transform on a freshly pasted/duplicated node at the same tick as the
	# node-added signal, so a full hash that includes rotation can desync
	# between source and copy. The geometry-only hash is invariant to that.
	# Change detection still uses the full hash so a rotation triggers a
	# rebuild (the world→local offset conversion depends on the transform).
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
	# Texture du path : un changement de texture doit reconstruire l'ombre (la
	# silhouette/alpha bakée en dépend). Incluse dans le hash géométrique.
	if line.texture != null:
		h = h * 31 + int(line.texture.get_width())
		h = h * 31 + int(line.texture.get_height())
		var tp = line.texture.resource_path
		if tp == "":
			tp = str(line.texture.get_rid().get_id())
		h = h * 31 + tp.hash()
	# Effets shader (start_point, flip, fondu) posés par ModifyPaths + transitions
	# Grow/Shrink (largeurs par point) : tous changent la silhouette/alpha bakée ->
	# doivent reconstruire l'ombre.
	var sp = _get_path_shader_params(line)
	h = h * 31 + int(sp["sp"] * 10000)
	h = h * 31 + (1 if sp["flip"] else 0)
	h = h * 31 + (1 if sp["fade_in"] else 0)
	h = h * 31 + (1 if sp["fade_out"] else 0)
	h = h * 31 + int(sp["fdist"] * 100)
	h = h * 31 + int(sp["plu"] * 1000)
	h = h * 31 + (1 if (path.get("Grow") == true) else 0)
	h = h * 31 + (1 if (path.get("Shrink") == true) else 0)
	if not geom_only:
		h = h * 31 + int(line.rotation * 1000)
		# Include scale so mirror (scale.x = -1) triggers rebuild
		h = h * 31 + int(line.global_scale.x * 1000)
		h = h * 31 + int(line.global_scale.y * 1000)
		# Include z_index so changing the path's layer rebuilds the (detached)
		# shadow mesh with a matching z.
		h = h * 31 + int(line.z_index)
	return h

# Repositionne l'ombre EXISTANTE pour le transform courant (rotation/scale) sans
# rebuild : l'ombre est enfant du Line2D, donc elle suit déjà rotation et scale ;
# seul le décalage monde->local doit être recalculé (l'ombre portée pointe dans
# une direction MONDE fixe). Évite de rebaker pendant un rotate/resize -> l'ombre
# ne disparaît plus.
func _reposition_shadow_offset(node, config):
	if node == null or not is_instance_valid(node):
		return
	if not node.has_meta(SHADOW_META_KEY):
		return
	# Bulge actif : le vecteur de bombage est en espace local ; un changement de
	# transform (rotation/scale) change sa direction monde -> rebuild complet.
	if _bulge_enabled(config):
		create_shadow(node, config)
		return
	var line = get_line2d(node)
	if line == null:
		return
	var world_off = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	var local_off = line.global_transform.affine_inverse().basis_xform(world_off)
	var nodes = node.get_meta(SHADOW_META_KEY)
	if not (nodes is Array):
		return
	for n in nodes:
		if not is_instance_valid(n):
			continue
		if n is Sprite:
			var bp = n.get_meta("base_pos") if n.has_meta("base_pos") else Vector2(0.0, 0.0)
			n.position = bp + local_off
		elif n is MeshInstance2D or n is Line2D:
			n.position = local_off

func _get_transitions_hash(path) -> int:
	if path == null or not is_instance_valid(path):
		return 0
	var h = 0
	for prop in ["FadeIn", "FadeOut", "Grow", "Shrink"]:
		var val = path.get(prop)
		if val is bool and val:
			h += hash(prop)
	# Offset (start_point) et distance de transition : posés par ModifyPaths sur le
	# matériau du path. Leurs VALEURS doivent aussi déclencher une resync (l'ombre
	# realistic et l'overlay répliquent ces paramètres dans leurs masques).
	var ln = get_line2d(path)
	if ln != null and ln.material is ShaderMaterial:
		var spv = ln.material.get_shader_param("start_point")
		if spv != null:
			h += hash(stepify(float(spv), 0.001))
		var fdv = ln.material.get_shader_param("fade_distance")
		if fdv != null:
			h += hash(stepify(float(fdv), 0.001))
	return h

# Cache of points hashes for all shadow paths: { node_id: hash }
var _all_points_hashes = {}
var _all_geom_hashes = {}  # node_id -> hash géométrique seul (sans transform), pour distinguer rotate/resize d'un vrai changement

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

	# Render mode buttons (Simple = mesh géométrique, Realistic = silhouette texturée)
	var pt_mode_wrapper = VBoxContainer.new()
	pt_mode_wrapper.visible = false
	pt_ui["mode_wrapper"] = pt_mode_wrapper
	var pt_mode_hbox = HBoxContainer.new()
	var pt_mode_names = ["Simple", "Realistic"]
	for i in range(2):
		var mbtn = Button.new()
		mbtn.text = " " + pt_mode_names[i]
		mbtn.toggle_mode = true
		mbtn.pressed = (i == _render_mode_to_index(DEFAULT_SHADOW_CONFIG.get("render_mode", "simple")))
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.align = Button.ALIGN_LEFT
		if i == _render_mode_to_index(DEFAULT_SHADOW_CONFIG.get("render_mode", "simple")):
			mbtn.icon = mbtn.get_icon("radio_checked", "CheckBox")
		else:
			mbtn.icon = mbtn.get_icon("radio_unchecked", "CheckBox")
		mbtn.connect("pressed", self, "_on_pt_render_mode_pressed", [i])
		pt_mode_hbox.add_child(mbtn)
		pt_ui["mode_btn_" + str(i)] = mbtn
	pt_mode_wrapper.add_child(pt_mode_hbox)
	pt_container.add_child(pt_mode_wrapper)

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

	# Cap shape slider (inside settings, shown when extend ON).
	# Range -1..+1 controls the cap's outward stretch:
	#   -1 = flat (no cap), 0 = perfect semicircle, +1 = elongated (~2x reach)
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
	var pt_fd_reset = _make_icon_button("icons/reset.png", "Reset cap shape", 0.5)
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
	cfg["render_mode"] = _get_pt_render_mode()
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

func _get_pt_render_mode() -> String:
	for i in range(2):
		if pt_ui.has("mode_btn_" + str(i)) and pt_ui["mode_btn_" + str(i)].pressed:
			return _render_mode_from_index(i)
	return "simple"

func _on_pt_render_mode_pressed(mode_index):
	for i in range(2):
		if not pt_ui.has("mode_btn_" + str(i)):
			continue
		var btn = pt_ui["mode_btn_" + str(i)]
		btn.pressed = (i == mode_index)
		if i == mode_index:
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
	if pt_ui.has("mode_wrapper"):
		pt_ui["mode_wrapper"].visible = pressed
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
	_on_pt_render_mode_pressed(_render_mode_to_index(cfg.get("render_mode", "simple")))
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

func _build_wall_tool_ui():
	var wall_tool_panel = global.Editor.Toolset.GetToolPanel("WallTool")
	if wall_tool_panel == null:
		outputlog("WallTool panel not found", 1)
		return
	var align_vbox = core.get_align_vbox(wall_tool_panel)
	if align_vbox == null:
		outputlog("WallTool Align VBox not found", 1)
		return

	# Insert at the end of the panel
	var insert_after = align_vbox.get_child_count()

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
	# Spread
	wt_settings.add_child(_make_wt_slider_row("Spread", "spread", 0.0, 3.0, 0.05, DEFAULT_SHADOW_CONFIG["spread"]))
	# Softness
	wt_settings.add_child(_make_wt_slider_row("Softness", "softness", 0.1, 10.0, 0.25, DEFAULT_SHADOW_CONFIG["softness"]))

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
	cfg["opacity"] = wt_ui["opacity_spin"].value
	cfg["spread"] = wt_ui["spread_spin"].value
	cfg["softness"] = wt_ui["softness_spin"].value
	cfg["direction"] = _get_wt_direction()
	# Extend
	if wt_ui.has("extend_check"):
		cfg["extend_enabled"] = wt_ui["extend_check"].pressed
		if wt_ui["extend_check"].pressed:
			cfg["fade_in_enabled"] = true
			cfg["fade_out_enabled"] = true
		else:
			cfg["fade_in_enabled"] = false
			cfg["fade_out_enabled"] = false
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

func _on_wt_slider_changed(value, which):
	wt_ui[which + "_spin"].value = value

func _on_wt_spin_changed(value, which):
	wt_ui[which + "_slider"].value = value

func _on_wt_single_reset(which):
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
	if wt_ui.has("cog_btn"):
		wt_ui["cog_btn"].visible = pressed
	if wt_ui.has("reset_btn"):
		wt_ui["reset_btn"].visible = pressed
	if not pressed:
		if wt_ui.has("settings"):
			wt_ui["settings"].visible = false
		if wt_ui.has("cog_btn"):
			wt_ui["cog_btn"].pressed = false

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
	wt_ui["opacity_slider"].value = cfg.get("opacity", FACTORY_DEFAULTS["opacity"])
	wt_ui["opacity_spin"].value = cfg.get("opacity", FACTORY_DEFAULTS["opacity"])
	wt_ui["spread_slider"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	wt_ui["spread_spin"].value = cfg.get("spread", FACTORY_DEFAULTS["spread"])
	wt_ui["softness_slider"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
	wt_ui["softness_spin"].value = cfg.get("softness", FACTORY_DEFAULTS["softness"])
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
		var live_cfg = _get_path_tool_config(editing)
		# Realistic : swap atomique + session live gèrent le remplacement -> NE PAS
		# pré-retirer (sinon le viewport live est détruit/recréé à chaque frame).
		# Simple : retrait explicite avant reconstruction du mesh.
		if live_cfg.get("render_mode", "simple") == "realistic":
			create_shadow(editing, live_cfg)
		else:
			remove_shadow(editing)
			create_shadow(editing, live_cfg)

var _scan_skip_ids := {}

func _on_monitor_tick():
	# Détection des ops natives (move/reshape/delete) pour la timeline undo/redo.
	_detect_native_path_ops()
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

	# Sync BelowLayer container visibility with Pathways node (HideLayers compat)
	# and clean up orphan meshes from deleted paths.
	var _cur_level = global.World.GetCurrentLevel()
	if _cur_level != null:
		# Defensive: previous versions of this mod stored "behind layer" shadow
		# meshes in a Level-scoped container (or briefly in Pathways), neither
		# of which is needed anymore — shadows now live as direct children of
		# their path with z_index = -1. Free any leftover container so it
		# doesn't render stale meshes during export or save bloat into the map.
		var _pw = _cur_level.get_node_or_null("Pathways")
		if _pw != null:
			var _stray = _pw.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
			if _stray != null:
				_pw.remove_child(_stray)
				_stray.queue_free()
		var _bl = _cur_level.get_node_or_null(BELOW_LAYER_CONTAINER_NAME)
		if _bl != null:
			_cur_level.remove_child(_bl)
			_bl.queue_free()

	# Process pending new nodes from OnAssignNode signal (split detection)
	if _pending_new_nodes.size() > 0:
		var nodes_to_process = _pending_new_nodes.duplicate()
		_pending_new_nodes.clear()
		# Collect all new IDs in this batch so they don't match each other
		var batch_ids = {}
		for pending_node in nodes_to_process:
			if is_instance_valid(pending_node) and pending_node.has_meta("node_id"):
				batch_ids[str(pending_node.get_meta("node_id"))] = true
		_current_batch_ids = batch_ids
		for pending_node in nodes_to_process:
			if is_instance_valid(pending_node):
				_deferred_on_new_node_added(pending_node)
		_current_batch_ids = {}

	# Real-time shadow drawing while using PathTool
	_update_path_tool_live_shadow()

	# Convertit les ombres floutées live stabilisées en texture statique mipmappée.
	_process_realistic_live_settle()

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
			# ModifyPaths a changé offset / fade distance / transition -> l'overlay
			# réplique ces paramètres dans son masque : on le reconstruit pour resync.
			if _monitored_path.has_meta("node_id"):
				var mon_id = str(_monitored_path.get_meta("node_id"))
				if global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(mon_id):
					var mon_ov = global.ModMapData[OVERLAY_DATA_KEY][mon_id]
					if mon_ov.get("enabled", false):
						remove_overlay_shadow(_monitored_path)
						create_overlay_shadow(_monitored_path, mon_ov)

	# Scan ALL paths with saved shadow data for point changes
	if not global.ModMapData.has(SHADOW_DATA_KEY):
		# Still update wall point snapshot even without shadow data
		_update_wall_point_snapshot()
		_update_last_selection()
		return

	var shadow_data = global.ModMapData[SHADOW_DATA_KEY]
	for node_id in shadow_data.keys():
		# Perf: objects/roofs share this "DropShadow" key but are never paths.
		# Cache ids already known to be non-path and skip them at the top of the
		# tick, before the HasNodeID/GetNodeByID/get_node_type cross-boundary C#
		# calls. Otherwise a map full of object shadows costs this scan every tick.
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

		var new_hash = _get_points_hash(scan_node)
		var old_hash = _all_points_hashes.get(node_id, 0)
		var new_geom = _get_points_hash(scan_node, true)
		var old_geom = _all_geom_hashes.get(node_id, 0)
		if new_geom != old_geom:
			# Vraie modif (points / largeur / texture) -> reconstruction. Pour le
			# realistic on NE pré-supprime PAS : les builders font un swap atomique
			# (l'ancienne ombre reste visible pendant le bake) -> pas de disparition.
			_all_points_hashes[node_id] = new_hash
			_all_geom_hashes[node_id] = new_geom
			if config.get("render_mode", "simple") == "realistic":
				create_shadow(scan_node, config)
			else:
				remove_shadow(scan_node)
				create_shadow(scan_node, config)
			# Also rebuild overlay if present
			if global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(node_id):
				var ov_cfg = global.ModMapData[OVERLAY_DATA_KEY][node_id]
				if ov_cfg.get("enabled", false):
					remove_overlay_shadow(scan_node)
					create_overlay_shadow(scan_node, ov_cfg)
			# Also update monitored hash if it's the same path
			if scan_node == _monitored_path:
				_monitored_points_hash = new_hash
		elif new_hash != old_hash:
			# Transform seul (rotation / scale / z).
			_all_points_hashes[node_id] = new_hash
			if config.get("render_mode", "simple") == "realistic":
				# On repositionne l'ombre existante (elle suit déjà le path en tant
				# qu'enfant), sans rebuild ni rebake -> pas de disparition.
				_reposition_shadow_offset(scan_node, config)
			else:
				# Mode simple : rebuild synchrone comme avant (pas de disparition,
				# et gère correctement le miroir).
				remove_shadow(scan_node)
				create_shadow(scan_node, config)
			if scan_node == _monitored_path:
				_monitored_points_hash = new_hash

	# Update wall point snapshot for split detection
	_update_wall_point_snapshot()

	# Update last selection IDs for next tick's paste detection
	_update_last_selection()

func _update_last_selection():
	var sel_now = global.Editor.Tools["SelectTool"].Selected
	if sel_now.size() > 0:
		var new_sel_ids = {}
		for s in sel_now:
			if is_instance_valid(s) and s.has_meta("node_id"):
				var sid = str(s.get_meta("node_id"))
				new_sel_ids[sid] = true
				# Cache hash for ALL selected paths (even without shadow data)
				# so paste detection can match originals that had no shadow
				if is_shadow_node_type(s) and not _all_points_hashes.has(sid):
					_all_points_hashes[sid] = _get_points_hash(s)
		if new_sel_ids.size() > 0:
			_last_selection_ids = new_sel_ids

# Track which node_ids we've already processed (for save_shadow_data dedup)
var _known_node_ids = {}

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

func _create_stairs_icon() -> TextureRect:
	var tex = _load_icon("icons/stairs.png", 0.65)
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
	button.focus_mode = Control.FOCUS_NONE
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
	var path_vbox = select_panel.pathOptions
	ui_config["_path_parent"] = path_vbox

	var container = VBoxContainer.new()
	container.name = "DropShadowPathsContainer"
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
	settings_toggle.focus_mode = Control.FOCUS_NONE
	settings_toggle.connect("toggled", self, "_on_settings_toggled")
	title_hbox.add_child(settings_toggle)
	ui_config["settings_toggle"] = settings_toggle
	var enable_check = CheckButton.new()
	enable_check.pressed = false
	enable_check.focus_mode = Control.FOCUS_NONE
	enable_check.connect("toggled", self, "_on_setting_changed")
	title_hbox.add_child(enable_check)
	container.add_child(title_hbox)
	ui_config["enable_check"] = enable_check

	# Render mode buttons (Simple = mesh géométrique, Realistic = silhouette texturée)
	# Masqué quand l'ombre est OFF, comme le radio direction.
	var mode_wrapper = VBoxContainer.new()
	mode_wrapper.visible = false
	var mode_btn_container = HBoxContainer.new()
	var mode_names = ["Simple", "Realistic"]
	for i in range(2):
		var mbtn = Button.new()
		mbtn.text = " " + mode_names[i]
		mbtn.toggle_mode = true
		mbtn.pressed = (i == _render_mode_to_index(DEFAULT_SHADOW_CONFIG.get("render_mode", "simple")))
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.align = Button.ALIGN_LEFT
		mbtn.connect("pressed", self, "_on_render_mode_pressed", [i])
		mode_btn_container.add_child(mbtn)
		ui_config["mode_btn_" + str(i)] = mbtn
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
	settings_panel.add_child(spread_hbox)
	ui_config["spread_hbox"] = spread_hbox

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
	settings_panel.add_child(soft_hbox)
	ui_config["softness_hbox"] = soft_hbox

	# -- Blur (mode Realistic uniquement): [Label] [Slider] [SpinBox] [Reset] --
	# Découplé de Softness. 0 = silhouette nette, 1 = flou max (REALISTIC_BLUR_MAX_PX).
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
	blur_slider.value = DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.0)
	blur_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blur_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blur_slider.connect("value_changed", self, "_on_slider_changed", ["realistic_blur"])
	blur_hbox.add_child(blur_slider)
	ui_config["realistic_blur_slider"] = blur_slider
	var blur_spin = SpinBox.new()
	blur_spin.min_value = 0.0
	blur_spin.max_value = 1.0
	blur_spin.step = 0.01
	blur_spin.value = DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.0)
	blur_spin.connect("value_changed", self, "_on_spin_changed", ["realistic_blur"])
	blur_hbox.add_child(blur_spin)
	ui_config["realistic_blur_spin"] = blur_spin
	var blur_reset = _make_icon_button("icons/reset.png", "Reset blur", 0.5)
	blur_reset.connect("pressed", self, "_on_single_reset", ["realistic_blur"])
	blur_hbox.add_child(blur_reset)
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
	# Crop Ends : visible en Realistic (toute direction), coupe le flou au bord du cap
	# à chaque extrémité du path. Indépendant de Crop at Center.
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

	# -- Behind Layer: toggle to render the shadow below ALL paths on the
	# level (not just behind its own path texture). Detaches the mesh from
	# the line and parents it to a Level-scoped container placed before
	# the Pathways node in scene-tree order. Same semantic as "Shadow
	# behind layer" on objects and "Below All Walls" on walls.
	var behind_layer_hbox = HBoxContainer.new()
	var behind_layer_label = Label.new()
	behind_layer_label.text = "Shadow behind layer"
	behind_layer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	behind_layer_hbox.add_child(behind_layer_label)
	var behind_layer_check = CheckButton.new()
	behind_layer_check.pressed = DEFAULT_SHADOW_CONFIG.get("behind_layer", false)
	behind_layer_check.hint_tooltip = "Render this shadow behind every path on this level, not just its own"
	behind_layer_check.connect("toggled", self, "_on_behind_layer_toggled")
	behind_layer_hbox.add_child(behind_layer_check)
	ui_config["behind_layer_check"] = behind_layer_check
	ui_config["behind_layer_hbox"] = behind_layer_hbox
	settings_panel.add_child(behind_layer_hbox)

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

	# Extend Which: End A / End B / Both buttons
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

	# Cap shape: [Label] [Slider] [SpinBox] [Reset]
	# Range -1..+1, default 0. Controls the cap's outward stretch (see comment
	# above the cap mesh builder for details).
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

	# -- Skip Portals: walls only toggle, inside extend section --
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
	extend_section.add_child(skip_portals_hbox)

	ui_config["extend_section"] = extend_section
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
	# Bouton reset à gauche du cog : header [titre, reset, cog].
	var off_header = ui_config["sec_offset_header"]
	var off_reset_btn = _make_icon_button("icons/reset.png", "Reset Offset settings", 0.45)
	off_reset_btn.connect("pressed", self, "_on_offset_section_reset")
	off_header.add_child(off_reset_btn)
	off_header.move_child(off_reset_btn, 1)

	# -- Offset: Circular Dial (Distance + Angle) --
	var offset_vbox = VBoxContainer.new()
	var offset_header = HBoxContainer.new()
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

	# === Bulge (section dédiée) ===
	# Renflement local additionné à l'offset de base rigide. Profil montée x descente :
	# chaque côté (entry/exit) se rattache (rampe) ou reste décollé jusqu'au bout du path.
	# Divider entre Offset et Bulge.
	var bulge_divider = HSeparator.new()
	bulge_divider.add_constant_override("separation", 8)
	settings_panel.add_child(bulge_divider)

	var bulge_root = _make_section_header(settings_panel, "Bend", "sec_bulge")
	# Pas de cog : la section se déploie selon l'état ON/OFF. Header : [titre, reset, ON/OFF].
	var bulge_header = ui_config["sec_bulge_header"]
	if ui_config.has("sec_bulge_toggle"):
		var bulge_cog = ui_config["sec_bulge_toggle"]
		bulge_header.remove_child(bulge_cog)
		bulge_cog.queue_free()
		ui_config.erase("sec_bulge_toggle")
	var bulge_reset_btn = _make_icon_button("icons/reset.png", "Reset Bend settings", 0.45)
	bulge_reset_btn.connect("pressed", self, "_on_bulge_section_reset")
	bulge_header.add_child(bulge_reset_btn)
	var bulge_en_check = CheckButton.new()
	bulge_en_check.pressed = DEFAULT_SHADOW_CONFIG.get("bulge_enabled", false)
	bulge_en_check.connect("toggled", self, "_on_bulge_toggled", ["bulge_enabled"])
	bulge_header.add_child(bulge_en_check)
	ui_config["bulge_enabled_check"] = bulge_en_check

	# Contenu révélé quand Bulge est actif.
	var bulge_content = VBoxContainer.new()
	bulge_root.add_child(bulge_content)
	ui_config["bulge_content"] = bulge_content

	# Angle (direction) : slider + link + reset. Grisé si lié à l'offset principal.
	var bang_hbox = HBoxContainer.new()
	var bang_label = Label.new()
	bang_label.text = "Angle"
	bang_label.rect_min_size.x = 85
	bang_hbox.add_child(bang_label)
	var bang_slider = HSlider.new()
	bang_slider.min_value = 0.0
	bang_slider.max_value = 360.0
	bang_slider.step = 1
	bang_slider.value = DEFAULT_SHADOW_CONFIG.get("bulge_angle", 0.0)
	bang_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bang_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bang_slider.connect("value_changed", self, "_on_bulge_angle_changed")
	bang_hbox.add_child(bang_slider)
	ui_config["bulge_angle_slider"] = bang_slider
	var bang_spin = SpinBox.new()
	bang_spin.min_value = 0.0
	bang_spin.max_value = 360.0
	bang_spin.step = 1
	bang_spin.value = DEFAULT_SHADOW_CONFIG.get("bulge_angle", 0.0)
	bang_spin.connect("value_changed", self, "_on_bulge_angle_changed")
	bang_hbox.add_child(bang_spin)
	ui_config["bulge_angle_spin"] = bang_spin
	var blink_btn = _make_icon_button("icons/link.png", "Link bend angle to the main offset", 0.5)
	blink_btn.toggle_mode = true
	blink_btn.pressed = DEFAULT_SHADOW_CONFIG.get("bulge_link", true)
	blink_btn.connect("toggled", self, "_on_bulge_link_toggled")
	bang_hbox.add_child(blink_btn)
	ui_config["bulge_link_btn"] = blink_btn
	var bang_reset = _make_icon_button("icons/reset.png", "Reset Angle", 0.5)
	bang_reset.connect("pressed", self, "_on_reset_bulge_angle")
	bang_hbox.add_child(bang_reset)
	bulge_content.add_child(bang_hbox)

	# Distance (ampleur), indépendante de l'état du link.
	var bdist_hbox = HBoxContainer.new()
	var bdist_label = Label.new()
	bdist_label.text = "Distance"
	bdist_label.rect_min_size.x = 85
	bdist_hbox.add_child(bdist_label)
	var bdist_slider = HSlider.new()
	bdist_slider.min_value = 0.0
	bdist_slider.max_value = BULGE_DIST_MAX
	bdist_slider.step = 1
	bdist_slider.value = DEFAULT_SHADOW_CONFIG.get("bulge_distance", 0.0)
	bdist_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bdist_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bdist_slider.connect("value_changed", self, "_on_bulge_distance_changed")
	bdist_hbox.add_child(bdist_slider)
	ui_config["bulge_distance_slider"] = bdist_slider
	var bdist_spin = SpinBox.new()
	bdist_spin.min_value = 0.0
	bdist_spin.max_value = BULGE_DIST_MAX
	bdist_spin.step = 1
	bdist_spin.value = DEFAULT_SHADOW_CONFIG.get("bulge_distance", 0.0)
	bdist_spin.connect("value_changed", self, "_on_bulge_distance_changed")
	bdist_hbox.add_child(bdist_spin)
	ui_config["bulge_distance_spin"] = bdist_spin
	var bdist_reset = _make_icon_button("icons/reset.png", "Reset Distance", 0.5)
	bdist_reset.connect("pressed", self, "_on_reset_bulge_distance")
	bdist_hbox.add_child(bdist_reset)
	bulge_content.add_child(bdist_hbox)

	# Longueur de rampe : unifiée (Ramp + link) ou par côté (si délié / un point OFF).
	var ramp_hbox = HBoxContainer.new()
	var ramp_label = Label.new()
	ramp_label.text = "Ramp"
	ramp_label.rect_min_size.x = 85
	ramp_hbox.add_child(ramp_label)
	var ramp_slider = HSlider.new()
	ramp_slider.min_value = 0.02
	ramp_slider.max_value = 1.0
	ramp_slider.step = 0.01
	ramp_slider.value = DEFAULT_SHADOW_CONFIG.get("bulge_entry_len", 0.3)
	ramp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ramp_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ramp_slider.connect("value_changed", self, "_on_bulge_ramp_unified_changed")
	ramp_hbox.add_child(ramp_slider)
	ui_config["bulge_ramp_slider"] = ramp_slider
	var ramp_spin = SpinBox.new()
	ramp_spin.min_value = 0.02
	ramp_spin.max_value = 1.0
	ramp_spin.step = 0.01
	ramp_spin.value = DEFAULT_SHADOW_CONFIG.get("bulge_entry_len", 0.3)
	ramp_spin.connect("value_changed", self, "_on_bulge_ramp_unified_changed")
	ramp_hbox.add_child(ramp_spin)
	ui_config["bulge_ramp_spin"] = ramp_spin
	var ramp_link = _make_icon_button("icons/link.png", "Link entry/exit ramp lengths", 0.5)
	ramp_link.toggle_mode = true
	ramp_link.pressed = DEFAULT_SHADOW_CONFIG.get("bulge_ramp_link", true)
	ramp_link.connect("toggled", self, "_on_bulge_ramp_link_toggled")
	ramp_hbox.add_child(ramp_link)
	ui_config["bulge_ramp_link_btn"] = ramp_link
	var ramp_reset = _make_icon_button("icons/reset.png", "Reset ramp length", 0.5)
	ramp_reset.connect("pressed", self, "_on_bulge_ramp_reset")
	ramp_hbox.add_child(ramp_reset)
	bulge_content.add_child(ramp_hbox)
	ui_config["bulge_ramp_hbox"] = ramp_hbox

	# Longueurs par côté (révélées en délié / point OFF).
	for spec in [["bulge_entry_len", "Entry Ramp"], ["bulge_exit_len", "Exit Ramp"]]:
		var ln_hbox = HBoxContainer.new()
		var ln_label = Label.new()
		ln_label.text = spec[1]
		ln_label.rect_min_size.x = 85
		ln_hbox.add_child(ln_label)
		var ln_slider = HSlider.new()
		ln_slider.min_value = 0.02
		ln_slider.max_value = 1.0
		ln_slider.step = 0.01
		ln_slider.value = DEFAULT_SHADOW_CONFIG.get(spec[0], 0.3)
		ln_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ln_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ln_slider.connect("value_changed", self, "_on_slider_changed", [spec[0]])
		ln_hbox.add_child(ln_slider)
		ui_config[spec[0] + "_slider"] = ln_slider
		var ln_spin = SpinBox.new()
		ln_spin.min_value = 0.02
		ln_spin.max_value = 1.0
		ln_spin.step = 0.01
		ln_spin.value = DEFAULT_SHADOW_CONFIG.get(spec[0], 0.3)
		ln_spin.connect("value_changed", self, "_on_spin_changed", [spec[0]])
		ln_hbox.add_child(ln_spin)
		ui_config[spec[0] + "_spin"] = ln_spin
		var ln_reset = _make_icon_button("icons/reset.png", "Reset " + spec[1], 0.5)
		ln_reset.connect("pressed", self, "_on_single_reset", [spec[0]])
		ln_hbox.add_child(ln_reset)
		bulge_content.add_child(ln_hbox)
		ui_config[spec[0] + "_hbox"] = ln_hbox

	# Points Entry/Exit : position (slider) + reset + ON/OFF (côté actif).
	for spec in [["bulge_entry", "Entry Point", "bulge_entry_active"], ["bulge_exit", "Exit Point", "bulge_exit_active"]]:
		var b_hbox = HBoxContainer.new()
		var b_label = Label.new()
		b_label.text = spec[1]
		b_label.rect_min_size.x = 85
		b_hbox.add_child(b_label)
		var b_slider = HSlider.new()
		b_slider.min_value = 0.0
		b_slider.max_value = 1.0
		b_slider.step = 0.01
		b_slider.value = DEFAULT_SHADOW_CONFIG.get(spec[0], 0.0)
		b_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b_slider.connect("value_changed", self, "_on_slider_changed", [spec[0]])
		b_hbox.add_child(b_slider)
		ui_config[spec[0] + "_slider"] = b_slider
		var b_spin = SpinBox.new()
		b_spin.min_value = 0.0
		b_spin.max_value = 1.0
		b_spin.step = 0.01
		b_spin.value = DEFAULT_SHADOW_CONFIG.get(spec[0], 0.0)
		b_spin.connect("value_changed", self, "_on_spin_changed", [spec[0]])
		b_hbox.add_child(b_spin)
		ui_config[spec[0] + "_spin"] = b_spin
		var b_reset = _make_icon_button("icons/reset.png", "Reset " + spec[1], 0.5)
		b_reset.connect("pressed", self, "_on_single_reset", [spec[0]])
		b_hbox.add_child(b_reset)
		var b_active = CheckButton.new()
		b_active.pressed = DEFAULT_SHADOW_CONFIG.get(spec[2], true)
		b_active.connect("toggled", self, "_on_bulge_toggled", [spec[2]])
		b_hbox.add_child(b_active)
		ui_config[spec[2] + "_check"] = b_active
		bulge_content.add_child(b_hbox)

	# Profil smooth(arc)/plateau : unifié (Smooth Ramp + link) ou par côté.
	var smooth_hbox = HBoxContainer.new()
	var smooth_label = Label.new()
	smooth_label.text = "Smooth Ramp"
	smooth_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	smooth_hbox.add_child(smooth_label)
	var smooth_link = _make_icon_button("icons/link.png", "Link entry/exit smooth profile", 0.5)
	smooth_link.toggle_mode = true
	smooth_link.pressed = DEFAULT_SHADOW_CONFIG.get("bulge_smooth_link", true)
	smooth_link.connect("toggled", self, "_on_bulge_smooth_link_toggled")
	smooth_hbox.add_child(smooth_link)
	ui_config["bulge_smooth_link_btn"] = smooth_link
	var smooth_check = CheckButton.new()
	smooth_check.pressed = DEFAULT_SHADOW_CONFIG.get("bulge_entry_smooth", true)
	smooth_check.connect("toggled", self, "_on_bulge_smooth_unified_toggled")
	smooth_hbox.add_child(smooth_check)
	ui_config["bulge_smooth_check"] = smooth_check
	bulge_content.add_child(smooth_hbox)
	ui_config["bulge_smooth_hbox"] = smooth_hbox

	# Smooth par côté (révélés en délié).
	for spec in [["bulge_entry_smooth", "Smooth Entry Ramp"], ["bulge_exit_smooth", "Smooth Exit Ramp"]]:
		var sm_hbox = HBoxContainer.new()
		var sm_label = Label.new()
		sm_label.text = spec[1]
		sm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sm_hbox.add_child(sm_label)
		var sm_check = CheckButton.new()
		sm_check.pressed = DEFAULT_SHADOW_CONFIG.get(spec[0], true)
		sm_check.connect("toggled", self, "_on_bulge_toggled", [spec[0]])
		sm_hbox.add_child(sm_check)
		ui_config[spec[0] + "_check"] = sm_check
		bulge_content.add_child(sm_hbox)
		ui_config[spec[0] + "_hbox"] = sm_hbox

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
	apply_all_btn.text = "Apply Shadow to all Paths"
	apply_all_btn.hint_tooltip = "Apply current shadow settings to all paths on this level"
	apply_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_all_btn.connect("pressed", self, "_on_apply_all_pressed")
	settings_panel.add_child(apply_all_btn)
	ui_config["apply_all_btn"] = apply_all_btn
	# Apply-all dialog
	var apply_dialog = AcceptDialog.new()
	apply_dialog.window_title = "Apply Shadow"
	apply_dialog.get_ok().text = "Every path"
	apply_dialog.get_ok().connect("pressed", self, "_on_apply_all_confirmed", ["all"])
	apply_dialog.add_button("Every path with no shadow", false, "no_shadow")
	var selected_btn = apply_dialog.add_button("Selected paths", false, "selected")
	apply_dialog.add_cancel("Cancel")
	apply_dialog.connect("custom_action", self, "_on_apply_all_confirmed")

	# Build inner layout: question label + layer scope radios
	var dialog_vbox = VBoxContainer.new()
	dialog_vbox.add_constant_override("separation", 10)
	var question_label = Label.new()
	question_label.text = "Which paths do you want to apply this shadow on?"
	question_label.align = Label.ALIGN_CENTER
	dialog_vbox.add_child(question_label)

	# Layer scope radio row (radio dot icons, same style as Sides)
	var scope_hbox = HBoxContainer.new()
	scope_hbox.add_constant_override("separation", 4)
	var scope_label = Label.new()
	scope_label.text = "Layers:"
	scope_hbox.add_child(scope_label)
	var scope_names = ["All layers", "Current layer", "Filtered layers"]
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

	var windows_container = global.Editor.get_node("Windows")
	if windows_container != null:
		windows_container.add_child(apply_dialog)
	else:
		global.Editor.add_child(apply_dialog)
	ui_config["apply_all_dialog"] = apply_dialog

	# Deferred styling: set scope radio icons + hide empty label after theme is inherited
	var scope_style_timer = Timer.new()
	scope_style_timer.wait_time = 0.1
	scope_style_timer.one_shot = true
	scope_style_timer.connect("timeout", self, "_style_apply_dialog", [scope_style_timer])
	global.Editor.add_child(scope_style_timer)
	scope_style_timer.start()

	container.add_child(settings_panel)
	ui_config["settings_panel"] = settings_panel

	var end_sep = HSeparator.new()
	end_sep.add_constant_override("separation", 8)
	container.add_child(end_sep)

	# ===== SHADOW OVERLAY SECTION =====
	_build_overlay_ui(container)

	# Insert at top so shadow section appears above other mods
	path_vbox.add_child(container)
	path_vbox.move_child(container, 0)
	ui_config["container"] = container

	# Set initial radio icons
	_set_direction_buttons(DEFAULT_SHADOW_CONFIG["direction"])

	# Prevent all UI controls from stealing focus (would deselect the path)
	_disable_focus_recursive(container)

static func _disable_focus_recursive(node: Control):
	if node is Control:
		node.focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		if child is Control:
			_disable_focus_recursive(child)

#########################################################################################################
##
## UI CALLBACKS
##
#########################################################################################################

var _syncing_ui = false
var _last_changed_params = []

func _on_slider_changed(value, which):
	if _syncing_ui:
		return
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_spin"].value = value
		"spread":
			ui_config["spread_spin"].value = value
		"softness":
			ui_config["softness_spin"].value = value
		"realistic_blur":
			ui_config["realistic_blur_spin"].value = value
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
		"bulge_entry_len":
			ui_config["bulge_entry_len_spin"].value = value
		"bulge_exit_len":
			ui_config["bulge_exit_len_spin"].value = value
		"bulge_entry":
			ui_config["bulge_entry_spin"].value = value
		"bulge_exit":
			ui_config["bulge_exit_spin"].value = value
	_syncing_ui = false
	_last_changed_params = [which]
	# Range change also scales offset values — propagate both to multi-select
	if which == "range":
		_last_changed_params = ["range", "offset_x", "offset_y"]
	apply_shadow_to_selected_paths()

func _on_spin_changed(value, which):
	if _syncing_ui:
		return
	_syncing_ui = true
	match which:
		"opacity":
			ui_config["opacity_slider"].value = value
		"spread":
			ui_config["spread_slider"].value = value
		"softness":
			ui_config["softness_slider"].value = value
		"realistic_blur":
			ui_config["realistic_blur_slider"].value = value
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
		"bulge_entry_len":
			ui_config["bulge_entry_len_slider"].value = value
		"bulge_exit_len":
			ui_config["bulge_exit_len_slider"].value = value
		"bulge_entry":
			ui_config["bulge_entry_slider"].value = value
		"bulge_exit":
			ui_config["bulge_exit_slider"].value = value
	_syncing_ui = false
	_last_changed_params = [which]
	# Range change also scales offset values — propagate both to multi-select
	if which == "range":
		_last_changed_params = ["range", "offset_x", "offset_y"]
	apply_shadow_to_selected_paths()

# Non-linear offset dial
const OFFSET_MAX = 100.0
# Distance max du bombage : 10x l'offset (le renflement peut décoller bien plus loin).
const BULGE_DIST_MAX = 1000.0

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
			_last_changed_params = ["offset_x", "offset_y"]
			apply_shadow_to_selected_paths()
			return
		var projected_dist = min(projection, radius)
		frac = projected_dist / radius
		nonlinear_frac = frac * frac
		direction = snap_dir
	var ox = round(-direction.x * nonlinear_frac * max_offset)
	var oy = round(-direction.y * nonlinear_frac * max_offset)
	_set_dial_values(ox, oy)
	_last_changed_params = ["offset_x", "offset_y"]
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
			_last_changed_params = ["offset_x", "offset_y"]
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
				_last_changed_params = ["offset_x", "offset_y"]
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
	_last_changed_params = ["offset_x", "offset_y"]
	apply_shadow_to_selected_paths()

func _set_dial_values(ox: float, oy: float):
	_syncing_ui = true
	ui_config["offset_x_spin"].value = ox
	ui_config["offset_y_spin"].value = oy
	_update_angle_distance_from_xy(ox, oy)
	_update_dial_dot_position(ox, oy)
	_syncing_ui = false

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
	_syncing_ui = true
	_set_direction_buttons(dir_index)
	_syncing_ui = false
	_update_crop_blur_visibility()
	_last_changed_params = ["direction"]
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

func _render_mode_to_index(mode) -> int:
	return 1 if str(mode) == "realistic" else 0

func _render_mode_from_index(idx: int) -> String:
	return "realistic" if int(idx) == 1 else "simple"

func _on_render_mode_pressed(mode_index):
	if _syncing_ui:
		return
	_syncing_ui = true
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
	_syncing_ui = false
	_last_changed_params = ["render_mode"]
	apply_shadow_to_selected_paths()

# Opacité indépendante par mode (slider = mode actif, autre mode dans ui_config["opacity_inactive"]).
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
	# Pas un param "live" -> force le rebuild complet (le masque doit être (re)capturé).
	_last_changed_params = ["crop_blur"]
	apply_shadow_to_selected_paths()

func _on_crop_ends_toggled(_pressed):
	if _syncing_ui:
		return
	# Pas un param "live" -> force le rebuild complet (le masque doit être (re)capturé).
	_last_changed_params = ["crop_ends"]
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
		var btn = ui_config["mode_btn_" + str(i)]
		btn.pressed = (i == active_index)
		if i == active_index:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
	# Le row Blur n'a de sens qu'en mode realistic.
	if ui_config.has("realistic_blur_hbox"):
		ui_config["realistic_blur_hbox"].visible = (active_index == 1)
	# Spread / Softness ne concernent que le mode Simple (mesh) : masqués en Realistic.
	var _simple = (active_index == 0)
	if ui_config.has("spread_hbox"):
		ui_config["spread_hbox"].visible = _simple
	if ui_config.has("softness_hbox"):
		ui_config["softness_hbox"].visible = _simple
	# Opacité max doublée en Realistic (le flou atténue l'ombre -> on peut la renforcer >1).
	if ui_config.has("opacity_slider"):
		var omax = 1.0 if _simple else 2.0
		ui_config["opacity_slider"].max_value = omax
		if ui_config.has("opacity_spin"):
			ui_config["opacity_spin"].max_value = omax
	_update_crop_blur_visibility()
	# Extend Ends with Fade + Transitions dépendent AUSSI de l'état mur/fermé : on laisse
	# _update_transition_visibility() croiser mode + mur/boucle (source unique de vérité).
	_update_transition_visibility(_monitored_type)

func _get_selected_render_mode() -> String:
	for i in range(2):
		if ui_config.has("mode_btn_" + str(i)) and ui_config["mode_btn_" + str(i)].pressed:
			return _render_mode_from_index(i)
	return "simple"

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
		set_ui_without_signals(clipboard_config)
		_last_changed_params = []
		apply_shadow_to_selected_paths()
		outputlog("Config pasted from clipboard", 1)

func _on_single_reset(which):
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
		"realistic_blur":
			ui_config["realistic_blur_spin"].value = def_val
			ui_config["realistic_blur_slider"].value = def_val
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
		"bulge_entry_len":
			ui_config["bulge_entry_len_spin"].value = def_val
			ui_config["bulge_entry_len_slider"].value = def_val
		"bulge_exit_len":
			ui_config["bulge_exit_len_spin"].value = def_val
			ui_config["bulge_exit_len_slider"].value = def_val
		"bulge_entry":
			ui_config["bulge_entry_spin"].value = def_val
			ui_config["bulge_entry_slider"].value = def_val
		"bulge_exit":
			ui_config["bulge_exit_spin"].value = def_val
			ui_config["bulge_exit_slider"].value = def_val
		"shadow_color":
			if def_val is String:
				def_val = Color(def_val)
			ui_config["shadow_color_picker"].color = def_val
	_syncing_ui = false
	_last_changed_params = [which]
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
	if _syncing_ui:
		return
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
	_last_changed_params = ["enabled"]
	# Defer shadow changes to avoid modifying scene tree during UI event processing
	# (which can cause DD's SelectTool to deselect the path)
	call_deferred("apply_shadow_to_selected_paths")

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

# Switch-with-memory between Extend Ends (with cap) and the transitions
# group (fade-in, fade-out, grow, shrink). Both groups can't be active at
# the same time, but the buttons stay clickable: enabling one group
# automatically deactivates the other and remembers its state, and coming
# back restores it.
#
# Note: `swap_ends` is intentionally NOT part of this group. It coexists
# with extend (when extend_which is Start it flips to End and vice versa,
# Both is unchanged — the rendering code already applies this) and also
# coexists with transitions (it swaps fade_in↔fade_out, grow↔shrink).
const _TRANSITION_KEYS = ["fade_in", "fade_out", "grow", "shrink"]
var _saved_transitions_state: Dictionary = {}

func _save_and_clear_transitions():
	# Snapshot which transition checks are currently on, then turn them all
	# off. Strength/length values stay as configured. Signals are blocked
	# per-toggle so the apply step doesn't fire once per cleared toggle.
	_saved_transitions_state.clear()
	for k in _TRANSITION_KEYS:
		var check = ui_config.get(k + "_check")
		if check == null:
			continue
		_saved_transitions_state[k] = check.pressed
		if check.pressed:
			check.set_block_signals(true)
			check.pressed = false
			check.set_block_signals(false)
	_update_transition_controls_visibility()

func _restore_transitions(except_key: String = ""):
	# Restore previously saved transition toggle states. No-op if nothing
	# was saved. `except_key` (e.g. "fade_in") is skipped — used when the
	# user just clicked that toggle ON, so its just-clicked state must win
	# over the snapshot value. Strength/length sub-sliders re-show via the
	# visibility helper at the end.
	if _saved_transitions_state.empty():
		return
	for k in _TRANSITION_KEYS:
		if k == except_key:
			continue
		var check = ui_config.get(k + "_check")
		if check == null:
			continue
		var saved_val = _saved_transitions_state.get(k, false)
		if check.pressed != saved_val:
			check.set_block_signals(true)
			check.pressed = saved_val
			check.set_block_signals(false)
	_saved_transitions_state.clear()
	_update_transition_controls_visibility()

func _ensure_extend_off_for_transition(except_key: String = ""):
	# Called when the user just turned ON a transition while extend is
	# currently ON — flip the switch: turn extend off (silently), hide its
	# sub-UI, and restore the previously saved transition snapshot. The
	# `except_key` is the transition the user just clicked: it's skipped
	# in the restore so the click takes precedence over any stale snapshot
	# value (which would otherwise force it back to OFF when the snapshot
	# was taken while no transitions were active).
	if _monitored_type == "walls":
		return
	var ext_check = ui_config.get("extend_check")
	if ext_check == null or not ext_check.pressed:
		return
	ext_check.set_block_signals(true)
	ext_check.pressed = false
	ext_check.set_block_signals(false)
	if ui_config.has("fade_extend_container"):
		ui_config["fade_extend_container"].visible = false
	if ui_config.has("ext_which_container"):
		ui_config["ext_which_container"].visible = false
	_restore_transitions(except_key)

func _legacy_extend_transitions_cleanup():
	# Called once after loading saved data into the UI. If both groups
	# happen to be active simultaneously (legacy data saved before the
	# switch behaviour), prefer extend and snapshot the transitions so
	# the user can restore them by toggling extend off.
	if _monitored_type == "walls":
		return
	var ext_check = ui_config.get("extend_check")
	if ext_check == null or not ext_check.pressed:
		return
	var any_on = false
	for k in _TRANSITION_KEYS:
		var c = ui_config.get(k + "_check")
		if c != null and c.pressed:
			any_on = true
			break
	if not any_on:
		return
	# Snapshot then clear (signals already blocked by the load process,
	# but using set_block_signals here is harmless and defensive).
	_saved_transitions_state.clear()
	for k in _TRANSITION_KEYS:
		var c = ui_config.get(k + "_check")
		if c == null:
			continue
		_saved_transitions_state[k] = c.pressed
		if c.pressed:
			c.set_block_signals(true)
			c.pressed = false
			c.set_block_signals(false)
	_update_transition_controls_visibility()

func _on_transition_toggled(_pressed, _which):
	# When user enables a transition while extend is on, flip to
	# transitions mode (turn off extend, restore saved transitions
	# except the one the user just turned on).
	if _pressed and not _syncing_ui:
		_ensure_extend_off_for_transition(_which)
	if not _syncing_ui:
		_update_transition_controls_visibility()
	if _pressed and not _syncing_ui:
		var check_key = _which + "_check"
		if ui_config.has(check_key):
			_scroll_to_show(ui_config[check_key])
	_last_changed_params = [_which + "_enabled"]
	apply_shadow_to_selected_paths()

func _on_extend_toggled(pressed):
	ui_config["fade_extend_container"].visible = pressed
	ui_config["ext_which_container"].visible = pressed
	# Walls keep their special coupling: enabling extend on a wall also
	# enables fade in/out so the wall gets its cross-section fade.
	if _monitored_type == "walls" and not _syncing_ui:
		_syncing_ui = true
		ui_config["fade_in_check"].pressed = pressed
		ui_config["fade_out_check"].pressed = pressed
		_syncing_ui = false
	# Paths: switch between modes, snapshotting the inactive group so it
	# can be restored on the next switch.
	if _monitored_type != "walls" and not _syncing_ui:
		if pressed:
			_save_and_clear_transitions()
		else:
			_restore_transitions()
	if pressed and not _syncing_ui:
		_scroll_to_show(ui_config["fade_extend_container"])
	_last_changed_params = ["extend_enabled"]
	apply_shadow_to_selected_paths()

func _on_swap_ends_toggled(_pressed):
	# swap_ends coexists with extend AND with transitions, so it never
	# triggers a group switch. When extend_which is Start or End, the
	# rendering code flips it via the swap; when transitions are on, the
	# rendering code swaps fade_in↔fade_out and grow↔shrink. Both behave
	# transparently from the UI side here.
	_last_changed_params = ["swap_ends"]
	apply_shadow_to_selected_paths()

func _on_extend_which_pressed(which_index):
	if _syncing_ui:
		return
	_syncing_ui = true
	_set_extend_which_buttons(which_index)
	_syncing_ui = false
	_update_fade_visibility_for_extend_which()
	_last_changed_params = ["extend_which"]
	apply_shadow_to_selected_paths()

# NOTE: kept as a no-op for backward compatibility with existing call sites.
# Previously this hid individual fade rows when extend was active; with the
# new switch-with-memory behaviour between extend and transitions, the two
# groups can never be active at the same time anyway, so there is nothing
# to hide here.
func _update_fade_visibility_for_extend_which():
	pass

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
	_last_changed_params = ["skip_portals"]
	apply_shadow_to_selected_paths()

func _on_behind_layer_toggled(_pressed):
	if _syncing_ui:
		return
	_last_changed_params = ["behind_layer"]
	apply_shadow_to_selected_paths()

# Bulge : enable/plateau -> visibilité + rebuild (la géométrie change).
func _on_bulge_toggled(_pressed, which):
	if _syncing_ui:
		return
	_update_bulge_visibility()
	_last_changed_params = [which]
	apply_shadow_to_selected_paths()

# Lier/délier la direction du bombage. En déliant, on amorce la direction propre depuis
# l'offset principal courant (pour repartir de là), puis on cache/montre le dial + X/Y.
func _on_bulge_link_toggled(_pressed):
	if _syncing_ui:
		return
	var linked = ui_config["bulge_link_btn"].pressed
	if not linked:
		# Passage délié : amorcer l'angle depuis la direction de l'offset principal.
		var ox = ui_config["offset_x_spin"].value if ui_config.has("offset_x_spin") else 0.0
		var oy = ui_config["offset_y_spin"].value if ui_config.has("offset_y_spin") else 0.0
		var a = 0.0
		if Vector2(ox, oy).length() > 0.5:
			a = rad2deg(atan2(oy, ox))
			if a < 0.0:
				a += 360.0
		_syncing_ui = true
		if ui_config.has("bulge_angle_slider"):
			ui_config["bulge_angle_slider"].value = a
		if ui_config.has("bulge_angle_spin"):
			ui_config["bulge_angle_spin"].value = a
		_syncing_ui = false
	_update_bulge_visibility()
	_last_changed_params = ["bulge_link"]
	apply_shadow_to_selected_paths()

# Angle (direction) : slider + spin partagés.
func _on_bulge_angle_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	if ui_config.has("bulge_angle_slider"):
		ui_config["bulge_angle_slider"].value = value
	if ui_config.has("bulge_angle_spin"):
		ui_config["bulge_angle_spin"].value = value
	_syncing_ui = false
	_last_changed_params = ["bulge_angle"]
	apply_shadow_to_selected_paths()

func _on_reset_bulge_angle():
	_on_bulge_angle_changed(FACTORY_DEFAULTS.get("bulge_angle", 0.0))

# Visibilité + état (grisage) de la section bulge.
func _update_bulge_visibility():
	if not ui_config.has("bulge_content"):
		return
	var en = ui_config.has("bulge_enabled_check") and ui_config["bulge_enabled_check"].pressed
	# La section entière se déploie selon l'état ON/OFF (plus de cog).
	if ui_config.has("sec_bulge_content"):
		ui_config["sec_bulge_content"].visible = en
	ui_config["bulge_content"].visible = en
	# Direction : slider Angle grisé si lié à l'offset.
	var dir_linked = ui_config.has("bulge_link_btn") and ui_config["bulge_link_btn"].pressed
	_bulge_set_enabled(ui_config.get("bulge_angle_slider"), not dir_linked)
	_bulge_set_enabled(ui_config.get("bulge_angle_spin"), not dir_linked)
	var e_act = ui_config.has("bulge_entry_active_check") and ui_config["bulge_entry_active_check"].pressed
	var x_act = ui_config.has("bulge_exit_active_check") and ui_config["bulge_exit_active_check"].pressed
	var both = e_act and x_act
	# --- Longueur de rampe : unifiée (linkée + 2 points) ou par côté ---
	var ramp_linked = ui_config.has("bulge_ramp_link_btn") and ui_config["bulge_ramp_link_btn"].pressed
	var ramp_unified = ramp_linked and both
	_bulge_set_enabled(ui_config.get("bulge_ramp_link_btn"), both)
	_bulge_set_enabled(ui_config.get("bulge_ramp_slider"), ramp_unified)
	_bulge_set_enabled(ui_config.get("bulge_ramp_spin"), ramp_unified)
	if ui_config.has("bulge_entry_len_hbox"):
		ui_config["bulge_entry_len_hbox"].visible = (not ramp_unified) and e_act
	if ui_config.has("bulge_exit_len_hbox"):
		ui_config["bulge_exit_len_hbox"].visible = (not ramp_unified) and x_act
	# --- Profil smooth : unifié ou par côté ---
	var smooth_linked = ui_config.has("bulge_smooth_link_btn") and ui_config["bulge_smooth_link_btn"].pressed
	var smooth_unified = smooth_linked and both
	_bulge_set_enabled(ui_config.get("bulge_smooth_link_btn"), both)
	# Le ON/OFF unifié n'a de sens qu'en mode unifié ; caché sinon (lignes par côté visibles).
	if ui_config.has("bulge_smooth_check"):
		ui_config["bulge_smooth_check"].visible = smooth_unified
	if ui_config.has("bulge_entry_smooth_hbox"):
		ui_config["bulge_entry_smooth_hbox"].visible = (not smooth_unified) and e_act
	if ui_config.has("bulge_exit_smooth_hbox"):
		ui_config["bulge_exit_smooth_hbox"].visible = (not smooth_unified) and x_act

# Active/grise un contrôle (Button -> disabled ; Slider/SpinBox -> editable).
func _bulge_set_enabled(node, en: bool):
	if node == null:
		return
	node.modulate = Color(1, 1, 1, 1.0) if en else Color(1, 1, 1, 0.4)
	if node is Button:
		node.disabled = not en
	else:
		node.editable = en

# Ramp unifié (linké) : pilote les deux longueurs entrée/sortie.
func _on_bulge_ramp_unified_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	if ui_config.has("bulge_ramp_slider"):
		ui_config["bulge_ramp_slider"].value = value
	if ui_config.has("bulge_ramp_spin"):
		ui_config["bulge_ramp_spin"].value = value
	for k in ["bulge_entry_len_slider", "bulge_entry_len_spin", "bulge_exit_len_slider", "bulge_exit_len_spin"]:
		if ui_config.has(k):
			ui_config[k].value = value
	_syncing_ui = false
	_last_changed_params = ["bulge_entry_len", "bulge_exit_len"]
	apply_shadow_to_selected_paths()

# Lier les longueurs de rampe : en liant, on aligne sortie sur entrée.
func _on_bulge_ramp_link_toggled(_pressed):
	if _syncing_ui:
		return
	if ui_config["bulge_ramp_link_btn"].pressed:
		var v = ui_config["bulge_entry_len_spin"].value if ui_config.has("bulge_entry_len_spin") else 0.3
		_on_bulge_ramp_unified_changed(v)
	_update_bulge_visibility()
	_last_changed_params = ["bulge_ramp_link"]
	apply_shadow_to_selected_paths()

func _on_bulge_ramp_reset():
	_on_bulge_ramp_unified_changed(FACTORY_DEFAULTS.get("bulge_entry_len", 0.3))

# Smooth unifié (linké) : pilote les deux côtés.
func _on_bulge_smooth_unified_toggled(pressed):
	if _syncing_ui:
		return
	_syncing_ui = true
	for k in ["bulge_entry_smooth_check", "bulge_exit_smooth_check"]:
		if ui_config.has(k):
			ui_config[k].pressed = pressed
	_syncing_ui = false
	_last_changed_params = ["bulge_entry_smooth", "bulge_exit_smooth"]
	apply_shadow_to_selected_paths()

func _on_bulge_smooth_link_toggled(_pressed):
	if _syncing_ui:
		return
	if ui_config["bulge_smooth_link_btn"].pressed:
		var v = ui_config["bulge_entry_smooth_check"].pressed if ui_config.has("bulge_entry_smooth_check") else true
		_on_bulge_smooth_unified_toggled(v)
	_update_bulge_visibility()
	_last_changed_params = ["bulge_smooth_link"]
	apply_shadow_to_selected_paths()

# Distance (ampleur) : slider + spin partagés, indépendants du dial/de la direction.
func _on_bulge_distance_changed(value):
	if _syncing_ui:
		return
	_syncing_ui = true
	if ui_config.has("bulge_distance_slider"):
		ui_config["bulge_distance_slider"].value = value
	if ui_config.has("bulge_distance_spin"):
		ui_config["bulge_distance_spin"].value = value
	_syncing_ui = false
	_last_changed_params = ["bulge_distance"]
	apply_shadow_to_selected_paths()

func _on_reset_bulge_distance():
	_on_bulge_distance_changed(FACTORY_DEFAULTS.get("bulge_distance", 0.0))

# Reset de la section Offset : remet offset/range/radial/side balance aux valeurs d'usine.
func _on_offset_section_reset():
	var cfg = get_current_shadow_config()
	var keys = ["offset_x", "offset_y", "range", "radial_offset", "side_balance"]
	for k in keys:
		cfg[k] = FACTORY_DEFAULTS[k]
	set_ui_without_signals(cfg)
	_last_changed_params = keys
	apply_shadow_to_selected_paths()

# Reset de la section Bulge : remet tous les réglages (sauf l'activation) aux valeurs d'usine.
func _on_bulge_section_reset():
	var cfg = get_current_shadow_config()
	var keys = ["bulge_distance", "bulge_angle", "bulge_link", "bulge_entry", "bulge_exit",
		"bulge_entry_active", "bulge_exit_active", "bulge_entry_len", "bulge_exit_len",
		"bulge_ramp_link", "bulge_entry_smooth", "bulge_exit_smooth", "bulge_smooth_link"]
	for k in keys:
		cfg[k] = FACTORY_DEFAULTS[k]
	set_ui_without_signals(cfg)
	_last_changed_params = keys
	apply_shadow_to_selected_paths()

func _on_color_changed(_color):
	if _syncing_ui:
		return
	_last_changed_params = ["shadow_color"]
	apply_shadow_to_selected_paths()

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
		"offset_angle": ui_config["angle_spin"].value if ui_config.has("angle_spin") else 0.0,
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
		"extend_which": _get_selected_extend_which(),
		"fade_extend": ui_config["fade_extend_spin"].value,
		"swap_ends": ui_config["swap_ends_check"].pressed,
		"skip_portals": ui_config["skip_portals_check"].pressed,
		"behind_layer": ui_config["behind_layer_check"].pressed,
		"render_mode": _get_selected_render_mode(),
		"realistic_blur": ui_config["realistic_blur_slider"].value if ui_config.has("realistic_blur_slider") else DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.0),
		"bulge_enabled": ui_config["bulge_enabled_check"].pressed if ui_config.has("bulge_enabled_check") else false,
		"bulge_distance": ui_config["bulge_distance_spin"].value if ui_config.has("bulge_distance_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_distance", 0.0),
		"bulge_entry": ui_config["bulge_entry_spin"].value if ui_config.has("bulge_entry_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_entry", 0.0),
		"bulge_exit": ui_config["bulge_exit_spin"].value if ui_config.has("bulge_exit_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_exit", 1.0),
		"bulge_entry_active": ui_config["bulge_entry_active_check"].pressed if ui_config.has("bulge_entry_active_check") else true,
		"bulge_exit_active": ui_config["bulge_exit_active_check"].pressed if ui_config.has("bulge_exit_active_check") else true,
		"bulge_entry_len": ui_config["bulge_entry_len_spin"].value if ui_config.has("bulge_entry_len_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_entry_len", 0.3),
		"bulge_exit_len": ui_config["bulge_exit_len_spin"].value if ui_config.has("bulge_exit_len_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_exit_len", 0.3),
		"bulge_ramp_link": ui_config["bulge_ramp_link_btn"].pressed if ui_config.has("bulge_ramp_link_btn") else true,
		"bulge_entry_smooth": ui_config["bulge_entry_smooth_check"].pressed if ui_config.has("bulge_entry_smooth_check") else true,
		"bulge_exit_smooth": ui_config["bulge_exit_smooth_check"].pressed if ui_config.has("bulge_exit_smooth_check") else true,
		"bulge_smooth_link": ui_config["bulge_smooth_link_btn"].pressed if ui_config.has("bulge_smooth_link_btn") else true,
		"bulge_link": ui_config["bulge_link_btn"].pressed if ui_config.has("bulge_link_btn") else true,
		"bulge_angle": ui_config["bulge_angle_spin"].value if ui_config.has("bulge_angle_spin") else DEFAULT_SHADOW_CONFIG.get("bulge_angle", 0.0),
		"shadow_color": ui_config["shadow_color_picker"].color
	}

#########################################################################################################
##
## UNDO/REDO — TRANSACTIONS DE RÉGLAGES (paths)
##
#########################################################################################################

# Paths impactés par un réglage : sélection + path en édition (PathTool) + monitoré.
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

# Snapshot {node_id: {node, main, ov}} — couleurs normalisées en html (formats
# distincts : main = "rrggbbaa", overlay = "#rrggbb"). Référence nœud embarquée.
func _history_snapshot(nodes: Array) -> Dictionary:
	var snap = {}
	for node in nodes:
		if not is_instance_valid(node) or not node.has_meta("node_id"):
			continue
		var nid = str(node.get_meta("node_id"))
		# --- config principal ---
		var main
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
			main = global.ModMapData[SHADOW_DATA_KEY][nid].duplicate(true)
		elif node.has_meta("_shadow_config"):
			main = node.get_meta("_shadow_config").duplicate(true)
		else:
			main = FACTORY_DEFAULTS.duplicate(true)
		if main.has("shadow_color") and main["shadow_color"] is Color:
			main["shadow_color"] = main["shadow_color"].to_html(true)
		# --- config overlay ---
		var ov
		if global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(nid):
			ov = global.ModMapData[OVERLAY_DATA_KEY][nid].duplicate(true)
		else:
			ov = OVERLAY_DEFAULTS.duplicate(true)
		if ov.has("shadow_color") and ov["shadow_color"] is Color:
			ov["shadow_color"] = "#" + ov["shadow_color"].to_html(false)
		snap[nid] = {"node": node, "main": main, "ov": ov}
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
	var after = _history_snapshot_ids(before)
	var changed = false
	for nid in before.keys():
		if not after.has(nid):
			continue
		if JSON.print(before[nid]["main"]) != JSON.print(after[nid]["main"]):
			changed = true
		if JSON.print(before[nid]["ov"]) != JSON.print(after[nid]["ov"]):
			changed = true
	if changed and shadow_history != null:
		shadow_history.record(self, "history_apply", before, after, _history_txn_label)

# Re-snapshot (état "après") pour les nœuds d'un snapshot "avant" donné.
func _history_snapshot_ids(before: Dictionary) -> Dictionary:
	var nodes = []
	for nid in before.keys():
		var n = before[nid]["node"]
		if n != null and is_instance_valid(n):
			nodes.append(n)
	return _history_snapshot(nodes)

# Vérifie qu'un nœud a au moins une shadow vivante (sinon il faut la reconstruire).
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

# Resync après un undo/redo natif : reconstruit les shadows manquantes/invalides
# des nœuds présents (cas d'un nœud réapparu à géométrie identique, que le scan
# par hash ne détecte pas). Ne purge JAMAIS de données.
func _history_force_resync() -> void:
	var hidden = bool(global.ModMapData.get("DropShadowToggleHidden", false))
	if global.ModMapData.has(SHADOW_DATA_KEY):
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
	if global.ModMapData.has(OVERLAY_DATA_KEY):
		var od = global.ModMapData[OVERLAY_DATA_KEY]
		for node_id in od.keys():
			var ocfg = od[node_id]
			if not (ocfg is Dictionary) or not ocfg.get("enabled", false):
				continue
			if not global.World.HasNodeID(node_id):
				continue
			var node = global.World.GetNodeByID(node_id)
			if node == null or not is_instance_valid(node) or not is_shadow_node_type(node):
				continue
			if _has_valid_shadow(node, OVERLAY_META_KEY):
				continue
			remove_overlay_shadow(node)
			create_overlay_shadow(node, ocfg)
			if hidden and node.has_meta(OVERLAY_META_KEY):
				for n in node.get_meta(OVERLAY_META_KEY):
					if is_instance_valid(n):
						n.visible = false

# Détecte une op native sur un path : déplacement (position du nœud) OU reshape
# (hash géométrie ; le mod n'édite jamais les points/position), ou delete (id
# quitte la sélection et nœud disparu).
func _detect_native_path_ops() -> void:
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
		var h = _get_points_hash(node, true)
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

# Restaure un snapshot {node_id: {node, main, ov}} (undo ET redo). N'applique
# que ce qui diffère réellement de l'état courant (évite les re-render inutiles).
func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	_history_suspend = true
	var refresh = false
	for nid in payload.keys():
		var node = payload[nid]["node"]
		var main = payload[nid]["main"]
		var ov = payload[nid]["ov"]

		# État courant pour décider quoi ré-appliquer.
		var cur_main = {}
		if global.ModMapData.has(SHADOW_DATA_KEY) and global.ModMapData[SHADOW_DATA_KEY].has(nid):
			cur_main = global.ModMapData[SHADOW_DATA_KEY][nid]
		var cur_ov = {}
		if global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(nid):
			cur_ov = global.ModMapData[OVERLAY_DATA_KEY][nid]
		var main_diff = JSON.print(main) != JSON.print(cur_main)
		var ov_diff = JSON.print(ov) != JSON.print(cur_ov)

		if node != null and is_instance_valid(node):
			if main_diff:
				var m = main.duplicate(true)
				if m.has("shadow_color") and m["shadow_color"] is String:
					m["shadow_color"] = Color(m["shadow_color"])
				remove_shadow(node)
				if m.get("enabled", false):
					create_shadow(node, m)
				save_shadow_data(node, m)
			if ov_diff:
				var o = ov.duplicate(true)
				if o.has("shadow_color") and o["shadow_color"] is String:
					o["shadow_color"] = Color(o["shadow_color"])
				remove_overlay_shadow(node)
				if o.get("enabled", false):
					create_overlay_shadow(node, o)
				save_overlay_data(node, o)
			if node == _monitored_path and (main_diff or ov_diff):
				refresh = true
		else:
			if main_diff:
				if not global.ModMapData.has(SHADOW_DATA_KEY):
					global.ModMapData[SHADOW_DATA_KEY] = {}
				global.ModMapData[SHADOW_DATA_KEY][nid] = main.duplicate(true)
			if ov_diff:
				if not global.ModMapData.has(OVERLAY_DATA_KEY):
					global.ModMapData[OVERLAY_DATA_KEY] = {}
				global.ModMapData[OVERLAY_DATA_KEY][nid] = ov.duplicate(true)

	if refresh and _monitored_path != null and is_instance_valid(_monitored_path):
		load_shadow_ui_from_path(_monitored_path)
		load_overlay_ui_from_path(_monitored_path)
	_history_suspend = false


func apply_shadow_to_selected_paths():

	_history_touch("path" if _last_changed_params.empty() else str(_last_changed_params[0]))

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

		var has_saved = false
		if global.ModMapData.has(SHADOW_DATA_KEY):
			has_saved = global.ModMapData[SHADOW_DATA_KEY].has(node_id)

		var is_selected = false
		for sel_node in global.Editor.Tools["SelectTool"].Selected:
			if sel_node == node:
				is_selected = true
				break

		if node == _monitored_path or not has_saved:
			var cfg = ui_cfg.duplicate()
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
			if node_type == "walls":
				cfg["grow_enabled"] = false
				cfg["shrink_enabled"] = false
			# Mise à jour live (Realistic) : maj des params shader sans rebuild.
			if cfg["enabled"] and node.has_meta(SHADOW_META_KEY) and _can_live_update_realistic(_last_changed_params, cfg):
				if not _live_update_realistic(node, cfg, _last_changed_params):
					# Changement de forme (net <-> flou) : on NE pré-supprime PAS ;
					# les builders realistic font un swap atomique -> pas de flicker.
					create_shadow(node, cfg)
				save_shadow_data(node, cfg)
			# Fast path: skip viewport rebuild for opacity/color/offset changes
			elif cfg["enabled"] and _can_fast_update(_last_changed_params, cfg) and node.has_meta(SHADOW_META_KEY):
				if not _fast_update_shadow(node, cfg):
					remove_shadow(node)
					create_shadow(node, cfg)
				save_shadow_data(node, cfg)
			else:
				remove_shadow(node)
				if cfg["enabled"]:
					create_shadow(node, cfg)
				save_shadow_data(node, cfg)
		elif is_selected and has_saved:
			var saved = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
			if _last_changed_params.size() > 0:
				for param_key in _last_changed_params:
					var eff_key = param_key
					# En mode Realistic, le slider Opacity pilote opacity_realistic :
					# c'est cette clé qu'il faut propager à la sélection.
					if param_key == "opacity" and ui_cfg.get("render_mode", "simple") == "realistic":
						eff_key = "opacity_realistic"
					if ui_cfg.has(eff_key):
						saved[eff_key] = ui_cfg[eff_key]
			else:
				saved = ui_cfg.duplicate()
			if node_type == "walls":
				saved["grow_enabled"] = false
				saved["shrink_enabled"] = false
			if saved["enabled"] and node.has_meta(SHADOW_META_KEY) and _can_live_update_realistic(_last_changed_params, saved):
				if not _live_update_realistic(node, saved):
					create_shadow(node, saved)
				save_shadow_data(node, saved)
			elif saved["enabled"] and _can_fast_update(_last_changed_params, saved) and node.has_meta(SHADOW_META_KEY):
				if not _fast_update_shadow(node, saved):
					remove_shadow(node)
					create_shadow(node, saved)
				save_shadow_data(node, saved)
			else:
				remove_shadow(node)
				if saved["enabled"]:
					create_shadow(node, saved)
				save_shadow_data(node, saved)
		else:
			var saved = global.ModMapData[SHADOW_DATA_KEY][node_id].duplicate()
			saved["enabled"] = ui_cfg["enabled"]
			remove_shadow(node)
			if saved["enabled"]:
				create_shadow(node, saved)
			save_shadow_data(node, saved)

	_last_changed_params = []

# Bevel sharp corners for a specific shadow side.
# sign_dir: 1.0 for outer, -1.0 for inner
# For each corner, uses cross product to determine if the shadow side faces
# the convex (outside) or concave (inside) of the turn:
# - Convex side: arc of points for smooth shadow
# - Concave side: bevel with shadow fading to zero at corner
# Returns [PoolVector2Array points, Array corner_factors]
func _bevel_points_for_side(source_points: PoolVector2Array, sign_dir: float, is_closed: bool) -> Array:
	if source_points.size() < 3:
		var early_factors = []
		for _j in range(source_points.size()):
			early_factors.append(1.0)
		return [source_points, early_factors]

	var bevel_dist = 35.0
	var bevel_angle_threshold = 0.40
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
					var arc_steps = 4
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
					# Concave corner: triangles from adjacent segments overlap here.
					# Halve the corner_factor so overlapping alpha sums to ~1.0
					var sharpness = clamp((0.85 - dot) / 1.85, 0.0, 1.0)
					var concave_d = d * (1.0 - sharpness * 0.85)
					var cp_before = source_points[i] - dir_in * concave_d
					var cp_after = source_points[i] + dir_out * concave_d
					result.append(cp_before)
					factors.append(0.5)
					result.append(source_points[i])
					factors.append(0.5)
					result.append(cp_after)
					factors.append(0.5)
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

# Bevel sharp corners for BOTH-side shadow.
# Every sharp corner gets an arc (since it's convex on one side).
# Returns [PoolVector2Array points] (no corner_factors needed for BOTH).
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

# === Bulge (renflement local) ============================================
# Quand activée, l'offset de base reste une translation rigide ; en plus, chaque point
# est déplacé de bulge_vec * m(t), où t est sa position en longueur d'arc (0->1). m est
# un profil montée x descente : chaque côté (entry/exit) se rattache (rampe vers 0) ou
# reste décollé (1) jusqu'au bout du path. Baké dans la géométrie (Simple et Realistic).

func _bulge_enabled(cfg: Dictionary) -> bool:
	return cfg.get("bulge_enabled", false)

# Vecteur de bombage en espace MONDE : direction (offset principal si lié, sinon propre)
# normalisée puis mise à l'ampleur bulge_distance (indépendante de l'état du link).
func _bulge_vec_world(cfg: Dictionary) -> Vector2:
	var dist = cfg.get("bulge_distance", 0.0)
	if dist <= 0.5:
		return Vector2.ZERO
	if cfg.get("bulge_link", true):
		var dir = Vector2(cfg.get("offset_x", 0.0), cfg.get("offset_y", 0.0))
		if dir.length() >= 0.5:
			return dir.normalized() * dist
		# Offset de distance nulle : on suit l'angle du dial d'offset (distance traitée
		# comme 1). Même convention que le dial : dir = (-sin a, cos a).
		var oa = deg2rad(cfg.get("offset_angle", 0.0))
		return Vector2(-sin(oa), cos(oa)) * dist
	# Délié : direction donnée par l'angle du bombage (degrés).
	var a = deg2rad(cfg.get("bulge_angle", 0.0))
	return Vector2(cos(a), sin(a)) * dist

# Poids du bombage en t (0..1) : montée x descente. Côté entrée : si actif, rampe 0->1
# depuis `entry` sur e_len ; sinon décollé (1) dès le début. Côté sortie : si actif, rampe
# 1->0 finissant à `exit` sur x_len ; sinon décollé jusqu'à la fin. e_smooth/x_smooth :
# true = arc doux (smootherstep, très lisse aux deux bouts), false = plateau (rampe linéaire).
func _bulge_weight(t: float, entry: float, exit: float, e_active: bool, e_len: float, e_smooth: bool, x_active: bool, x_len: float, x_smooth: bool) -> float:
	var rise = 1.0
	if e_active:
		var xr = clamp((t - entry) / max(e_len, 0.0001), 0.0, 1.0)
		rise = (xr * xr * xr * (xr * (xr * 6.0 - 15.0) + 10.0)) if e_smooth else xr
	var fall = 1.0
	if x_active:
		var xf = clamp((exit - t) / max(x_len, 0.0001), 0.0, 1.0)
		fall = (xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0)) if x_smooth else xf
	return rise * fall

# Renvoie les points déplacés par le bombage (vec * profil). vec en espace ligne (local).
func _bulge_displaced_points(points: PoolVector2Array, vec: Vector2, entry: float, exit: float, e_active: bool, e_len: float, e_smooth: bool, x_active: bool, x_len: float, x_smooth: bool) -> PoolVector2Array:
	var n = points.size()
	if n < 2:
		return points
	# Longueurs d'arc cumulées -> t normalisé.
	var cum = []
	cum.resize(n)
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + points[i].distance_to(points[i - 1])
	var total = cum[n - 1]
	var out = PoolVector2Array()
	out.resize(n)
	if total < 0.0001:
		for i in range(n):
			out[i] = points[i]
		return out
	for i in range(n):
		var t = cum[i] / total
		out[i] = points[i] + vec * _bulge_weight(t, entry, exit, e_active, e_len, e_smooth, x_active, x_len, x_smooth)
	return out

# Construit le descripteur de bombage depuis la config + la transform du path. null si
# inactif. vec converti en espace LOCAL (rotation/miroir du path), comme l'offset.
func _make_bulge(config: Dictionary, line):
	if not _bulge_enabled(config):
		return null
	var vec_world = _bulge_vec_world(config)
	var vec_local = line.global_transform.affine_inverse().basis_xform(vec_world)
	return {
		"vec": vec_local,
		"entry": config.get("bulge_entry", 0.0),
		"exit": config.get("bulge_exit", 1.0),
		"e_active": config.get("bulge_entry_active", true),
		"e_len": config.get("bulge_entry_len", 0.3),
		"e_smooth": config.get("bulge_entry_smooth", true),
		"x_active": config.get("bulge_exit_active", true),
		"x_len": config.get("bulge_exit_len", 0.3),
		"x_smooth": config.get("bulge_exit_smooth", true)
	}

# Points déplacés à partir d'un descripteur de bombage (pour cadrer la bbox de capture).
func _bulge_disp_from(points: PoolVector2Array, bulge) -> PoolVector2Array:
	return _bulge_displaced_points(points, bulge["vec"], bulge["entry"], bulge["exit"], bulge["e_active"], bulge["e_len"], bulge["e_smooth"], bulge["x_active"], bulge["x_len"], bulge["x_smooth"])

# Descripteur d'épaisseur (mode realistic) pour le RUBAN texturé :
# - scale : épaisseur globale (radial offset). 1 = largeur du path, >1 plus épais.
# - bal   : asymétrie (side balance) dans [-1,1]. +bal rétrécit le côté EXTÉRIEUR
#   (cohérent avec le mode mesh) et épaissit l'intérieur. Renvoie null si négligeable.
func _make_radial(config: Dictionary, line):
	# Realistic : +/- inversés (vs simple) et portée du radial ×3.
	var r = -clamp(float(config.get("radial_offset", 0.0)) / 100.0, -1.0, 1.0) * 3.0
	var b = -clamp(float(config.get("side_balance", 0.0)) / 100.0, -1.0, 1.0)
	# Direction (Side A = OUTER / Side B = INNER / Both) : clip la silhouette à un côté du
	# centre du trait. Réalisé par le ruban mesh -> un clip non-BOTH doit produire un
	# radial non nul (ruban neutre si pas d'offset/balance). "dir" voyage dans le dict.
	var direction = int(config.get("direction", ShadowDirection.BOTH))
	if abs(r) < 0.01 and abs(b) < 0.01 and direction == ShadowDirection.BOTH:
		return null
	# Le flag crop est GATÉ par le flou : en net il n'y a pas de débordement, le crop est
	# inactif et la silhouette Side reste réduite de moitié.
	var crop = config.get("crop_blur", false)
	if _realistic_blur_px_from_frac(config.get("realistic_blur", 0.0)) < REALISTIC_MIN_BLUR_PX:
		crop = false
	return {"r": r, "b": b, "dir": direction, "crop": crop}

# Facteurs d'épaisseur par côté (extérieur +normale / intérieur -normale) :
# - radial offset (r) : bascule l'épaisseur d'un côté à l'autre (un côté grossit,
#   l'autre rétrécit) -> f_out = 1-r, f_in = 1+r.
# - side balance (b) : grossit UN SEUL côté à la fois (0 = bascule entre les deux) ->
#   b>0 épaissit l'extérieur, b<0 l'intérieur ; l'autre côté reste à la base.
func _radial_side_factors(radial) -> Array:
	var r = radial.get("r", 0.0) if radial != null else 0.0
	var b = radial.get("b", 0.0) if radial != null else 0.0
	var f_out = max(0.0, (1.0 - r) * (1.0 + max(0.0, b)))
	var f_in = max(0.0, (1.0 + r) * (1.0 + max(0.0, -b)))
	return [f_out, f_in]

# Facteur d'extension max (pour dimensionner la marge de capture).
func _radial_extent_factor(radial) -> float:
	if radial == null:
		return 1.0
	var f = _radial_side_factors(radial)
	return max(1.0, max(f[0], f[1]))

# Construit le RUBAN de triangles texturé de la silhouette : UV.x = distance cumulée /
# période (tiling indépendant de l'épaisseur -> nombre de maillons FIXE, pas de
# rallongement), UV.y = 0 au bord extérieur (+normale) -> 1 au bord intérieur
# (-normale). Demi-largeurs PAR CÔTÉ -> épaisseur symétrique/asymétrique sans toucher au
# tiling. Le bombage est cuit dans la centerline en amont.
func _build_silhouette_strip(line, bulge, radial, bitmap_map = null) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var pts = line.points
	if bulge != null:
		pts = _bulge_disp_from(pts, bulge)
	var n = pts.size()
	if n < 2:
		return mesh
	var closed = _is_line_closed(line)
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
	# -> le flou a autant de matière qu'en Both, l'opacité près du trait est identique.
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
			var u = cum / u_period
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
			var u0 = cum / u_period
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
func _new_realistic_copy(line, radial, bake: bool, loop_nat = null):
	if radial == null:
		return Line2D.new()
	var mi = MeshInstance2D.new()
	var mat = ShaderMaterial.new()
	mat.shader = _get_silhouette_bake_shader() if bake else _get_silhouette_tint_shader()
	if loop_nat != null:
		# Boucle : on échantillonne le bitmap naturel (rendu exact de DD), pas tuilé.
		mat.set_shader_param("tex", loop_nat["tex"])
		mat.set_shader_param("tiled", false)
	else:
		mat.set_shader_param("tex", line.texture)
	mi.material = mat
	return mi

# Shader silhouette pour la capture (blanc + alpha de la texture, tiling u par fract).
var _silhouette_bake_shader = null
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
func _get_silhouette_tint_shader() -> Shader:
	if _silhouette_tint_shader != null:
		return _silhouette_tint_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_mix;
uniform sampler2D tex;
uniform bool tiled = true;
uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength = 1.0;
// Compatibilité ModifyPaths (n'agit qu'en mode tiled / path ouvert).
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
	COLOR = vec4(shadow_color.rgb, a * shadow_strength);
}
"""
	_silhouette_tint_shader = sh
	return sh

# Pose les uniformes ModifyPaths (offset, flip, transitions) sur un matériau silhouette
# de ruban (mode tiled / path ouvert). Neutres si le mod n'est pas actif.
func _apply_silhouette_path_params(mat, line):
	if mat == null or not (mat is ShaderMaterial):
		return
	var sp = _get_path_shader_params(line)
	var plu = sp["plu"]
	if plu <= 0.0:
		# Repli : longueur totale / largeur de texture (mêmes unités que le u du ruban).
		var tl = 0.0
		var lp = line.points
		for i in range(1, lp.size()):
			tl += lp[i].distance_to(lp[i - 1])
		var tw = float(line.texture.get_width()) if line.texture != null else 1.0
		plu = (tl / tw) if tw > 0.0 else 0.0
	mat.set_shader_param("start_point", sp["sp"])
	mat.set_shader_param("path_flip_vertical", sp["flip"])
	mat.set_shader_param("FadeIn", sp["fade_in"])
	mat.set_shader_param("FadeOut", sp["fade_out"])
	mat.set_shader_param("path_length_in_uv", plu)
	mat.set_shader_param("fade_distance", sp["fdist"])

# Gradient 2 stops encodant t (0->1) dans le canal ROUGE, lu par le vertex shader pour
# déplacer chaque sommet. Le Line2D échantillonne le gradient par longueur d'arc (=t).
# Alpha = 1 (le fondu éventuel passe par le calcul UV du fragment, pas par ce gradient).
func _make_anchor_t_gradient() -> Gradient:
	var g = Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(0.0, 0.0, 0.0, 1.0))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1.0, 0.0, 0.0, 1.0))
	return g

# Pose les uniformes de bombage (déplacement de sommets) sur un matériau de copie.
func _apply_bulge_uniforms(mat, bulge):
	if bulge == null:
		mat.set_shader_param("bulge_active", false)
		return
	mat.set_shader_param("bulge_active", true)
	mat.set_shader_param("bulge_offset", bulge["vec"])
	mat.set_shader_param("bulge_entry", bulge["entry"])
	mat.set_shader_param("bulge_exit", bulge["exit"])
	mat.set_shader_param("bulge_entry_active", bulge["e_active"])
	mat.set_shader_param("bulge_entry_len", bulge["e_len"])
	mat.set_shader_param("bulge_entry_smooth", bulge["e_smooth"])
	mat.set_shader_param("bulge_exit_active", bulge["x_active"])
	mat.set_shader_param("bulge_exit_len", bulge["x_len"])
	mat.set_shader_param("bulge_exit_smooth", bulge["x_smooth"])

func create_shadow(path, config: Dictionary):
	if path == null or not is_instance_valid(path):
		return

	var line = get_line2d(path)
	if line == null:
		return

	# Stash crop_ends : les builders realistic (bake/live) n'ont pas la config et la
	# lisaient dans ModMapData, sauvegardé APRÈS create_shadow -> toggle décalé d'un
	# cran. Le stash porte la valeur FRAÎCHE.
	_path_crop_ends_cfg[path.get_instance_id()] = config.get("crop_ends", false)

	# Mode "Realistic" (B) : silhouette texturée décalée, rendue sous le path.
	if config.get("render_mode", "simple") == "realistic":
		create_realistic_shadow(path, config, line)
		return

	# Paths: get points directly from Line2D
	var source_points = line.points

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

	# Extension distance from config (only when extend is enabled)
	var extend_enabled = config.get("extend_enabled", false)
	var fade_extend = config.get("fade_extend", 256.0) if extend_enabled else 0.0
	var extend_which = int(config.get("extend_which", 2))
	# Swap extend_which when swap_ends is active: Start(0) <-> End(1), Both(2) unchanged
	if swap and extend_which == 0:
		extend_which = 1
	elif swap and extend_which == 1:
		extend_which = 0

	# WRAP-AROUND mode: instead of extending the centerline past the endpoint
	# and forcing a fade on top, we render an additional half-disc mesh
	# (rounded line cap) at each enabled end. The cap radius is the natural
	# shadow thickness (spread + softness), so the wrap stays confined to the
	# shadow's actual width. No extra fade is forced — the radial alpha
	# gradient of the cap provides the visual termination on its own.
	var draw_start_cap = false
	var draw_end_cap = false
	if extend_enabled:
		if extend_which == 0 or extend_which == 2:  # Start or Both
			draw_start_cap = true
		if extend_which == 1 or extend_which == 2:  # End or Both
			draw_end_cap = true

	var ext_steps = 45  # kept for compatibility; unused in wrap mode
	var start_ext_count = 0
	var end_ext_count = 0

	var original_count = source_points.size() - start_ext_count - end_ext_count

	var opacity = config["opacity"]
	var direction = int(config["direction"])
	var visible_ratio = _get_visible_height_ratio(line)
	var half_width = (line.width * visible_ratio) / 2.0
	var num_strips = 10

	# Convert fraction-based settings to pixel values relative to path width
	# This ensures the shadow scales with the path size
	var spread_px = config["spread"] * half_width
	var softness_px = config["softness"] * half_width

	# Start shadow from the center of the path (offset = 0)
	# The path texture is drawn ON TOP (show_behind_parent), so it covers
	# the inner portion of the shadow. Only the part extending beyond the
	# visible texture will be seen.
	var start_outer = 0.0
	var start_inner = 0.0

	# Detect if path is closed via DD internal properties
	# Disable closing when extensions are active to avoid wrap-around artifacts
	var is_closed = false
	if start_ext_count == 0 and end_ext_count == 0 and source_points.size() > 2:
		for prop_name in ["loop", "Loop", "closed", "Closed", "IsLoop"]:
			var val = path.get(prop_name)
			if val is bool and val:
				is_closed = true
				break
			if line != path:
				val = line.get(prop_name)
				if val is bool and val:
					is_closed = true
					break

	var shadow_nodes = []

	var offset = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	# Convert world offset to line-local space, accounting for rotation AND mirror (scale)
	offset = line.global_transform.affine_inverse().basis_xform(offset)

	# Accroche des extrémités : on bake le décalage pondéré dans la polyligne centrale
	# (bouts épinglés) et on annule la translation rigide du nœud mesh.
	# Bulge : l'offset de base reste une translation rigide du nœud ; le renflement
	# local (zone [entry, exit]) s'ajoute par-dessus, baké dans la polyligne centrale.
	var mesh_offset = offset
	if _bulge_enabled(config):
		var bvec = line.global_transform.affine_inverse().basis_xform(_bulge_vec_world(config))
		source_points = _bulge_displaced_points(source_points, bvec, config.get("bulge_entry", 0.0), config.get("bulge_exit", 1.0), config.get("bulge_entry_active", true), config.get("bulge_entry_len", 0.3), config.get("bulge_entry_smooth", true), config.get("bulge_exit_active", true), config.get("bulge_exit_len", 0.3), config.get("bulge_exit_smooth", true))

	# Slider value is in -100..+100; multiply by 2 so the effective
	# pixel shift covers ~twice the distance while keeping the cap small.
	var radial_offset = float(config.get("radial_offset", 0.0)) * 2.0
	var side_balance = float(config.get("side_balance", 0.0))

	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)

	# When `behind_layer` is on, every mesh node (main strips + caps) is
	# parented to a Level-scoped container placed before the Pathways node
	# so the shadow renders below ALL paths on the level, not just behind
	# its own path. See _get_below_layer_container / _create_shadow_mesh_node.
	var behind_layer = config.get("behind_layer", false)

	# Build mesh with opacity baked into vertex colors, render as direct MeshInstance2D.

	if direction == ShadowDirection.BOTH:
		var both_pts = _bevel_points_for_both(source_points, is_closed)
		var both_nrm = calculate_point_normals(both_pts, is_closed)
		var both_opc = _build_opacity_factors(both_pts.size(), original_count, cfg_fade_in, cfg_fade_out, fade_in_strength, fade_out_strength, start_ext_count)
		var both_wfc = _build_width_factors(both_pts.size(), original_count, cfg_grow, cfg_shrink, grow_length_val, shrink_length_val, start_ext_count)

		var sb_factors = _side_balance_factors(side_balance)
		var factor_a = sb_factors[0]
		var factor_b = sb_factors[1]

		if abs(side_balance) < 0.5:
			# Symmetric (slider near 0): single unified mesh, no seam.
			var both_mesh = build_shadow_mesh_both(both_pts, both_nrm,
				spread_px, softness_px, opacity, num_strips, is_closed,
				both_opc, both_wfc, shadow_color, null, null, radial_offset)
			if both_mesh.get_surface_count() > 0:
				var nodes = _create_shadow_mesh_node(line, both_mesh,
					mesh_offset, "DropShadowBoth", behind_layer)
				for n in nodes:
					shadow_nodes.append(n)
		else:
			# Asymmetric: render the two sides as separate meshes, but reusing
			# the unified centerline points so the meeting line still aligns.
			if factor_a > 0.001:
				var a_mesh = build_shadow_mesh_side(both_pts, both_nrm, start_outer,
					spread_px * factor_a, softness_px * factor_a, opacity, 1.0, num_strips, is_closed,
					both_opc, both_wfc, shadow_color, null, radial_offset)
				if a_mesh.get_surface_count() > 0:
					var nodes_a = _create_shadow_mesh_node(line, a_mesh,
						mesh_offset, "DropShadowOuter", behind_layer)
					for n in nodes_a:
						shadow_nodes.append(n)
			if factor_b > 0.001:
				var b_mesh = build_shadow_mesh_side(both_pts, both_nrm, start_inner,
					spread_px * factor_b, softness_px * factor_b, opacity, -1.0, num_strips, is_closed,
					both_opc, both_wfc, shadow_color, null, radial_offset)
				if b_mesh.get_surface_count() > 0:
					var nodes_b = _create_shadow_mesh_node(line, b_mesh,
						mesh_offset, "DropShadowInner", behind_layer)
					for n in nodes_b:
						shadow_nodes.append(n)

	elif direction == ShadowDirection.OUTER:
		var outer_bevel = _bevel_points_for_side(source_points, 1.0, is_closed)
		var outer_pts = outer_bevel[0]
		var outer_cfactors = outer_bevel[1]
		var outer_nrm = calculate_point_normals(outer_pts, is_closed)
		var outer_opc = _build_opacity_factors(outer_pts.size(), original_count, cfg_fade_in, cfg_fade_out, fade_in_strength, fade_out_strength, start_ext_count)
		var outer_wfc = _build_width_factors(outer_pts.size(), original_count, cfg_grow, cfg_shrink, grow_length_val, shrink_length_val, start_ext_count)
		var outer_mesh = build_shadow_mesh_side(outer_pts, outer_nrm, start_outer,
			spread_px, softness_px, opacity, 1.0, num_strips, is_closed,
			outer_opc, outer_wfc, shadow_color, outer_cfactors, radial_offset)
		if outer_mesh.get_surface_count() > 0:
			var nodes = _create_shadow_mesh_node(line, outer_mesh,
				mesh_offset, "DropShadowOuter", behind_layer)
			for n in nodes:
				shadow_nodes.append(n)

	elif direction == ShadowDirection.INNER:
		var inner_bevel = _bevel_points_for_side(source_points, -1.0, is_closed)
		var inner_pts = inner_bevel[0]
		var inner_cfactors = inner_bevel[1]
		var inner_nrm = calculate_point_normals(inner_pts, is_closed)
		var inner_opc = _build_opacity_factors(inner_pts.size(), original_count, cfg_fade_in, cfg_fade_out, fade_in_strength, fade_out_strength, start_ext_count)
		var inner_wfc = _build_width_factors(inner_pts.size(), original_count, cfg_grow, cfg_shrink, grow_length_val, shrink_length_val, start_ext_count)
		var inner_mesh = build_shadow_mesh_side(inner_pts, inner_nrm, start_inner,
			spread_px, softness_px, opacity, -1.0, num_strips, is_closed,
			inner_opc, inner_wfc, shadow_color, inner_cfactors, radial_offset)
		if inner_mesh.get_surface_count() > 0:
			var nodes = _create_shadow_mesh_node(line, inner_mesh,
				mesh_offset, "DropShadowInner", behind_layer)
			for n in nodes:
				shadow_nodes.append(n)

	# WRAP-AROUND caps (rounded line caps): a half-ellipse (or quarter for
	# Outer/Inner) is rendered at each enabled end. The ellipse's normal-axis
	# stays at spread+softness so the cap meets the strip seamlessly; its
	# outward-axis is scaled by the "Shape" slider (-1..+1, default 0):
	#    -1  -> outward_scale = 0 (no cap, just a flat termination)
	#     0  -> outward_scale = 1 (perfect semicircle)
	#    +1  -> outward_scale = 2 (cap stretched ~2x past the endpoint)
	# Skipped for closed paths (no real ends).
	if (draw_start_cap or draw_end_cap) and not is_closed and source_points.size() >= 2:
		var cap_half_sign = 0.0  # 0 = both sides (full half-disc)
		if direction == ShadowDirection.OUTER:
			cap_half_sign = 1.0  # +normal side only (quarter-disc)
		elif direction == ShadowDirection.INNER:
			cap_half_sign = -1.0  # -normal side only

		# Map slider value to outward axis scaling (clamped for legacy data
		# saved when the slider was a 1..512 pixel distance).
		var shape_v = clamp(config.get("fade_extend", 0.0), -1.0, 1.0)
		var cap_outward_scale = 1.0 + shape_v  # in [0, 2]

		# Asymmetric BOTH: render two quarter caps so each side matches its
		# corresponding strip thickness. Symmetric / single-direction keeps the
		# original single half-disc (or quarter-disc) cap.
		var cap_asymmetric = (direction == ShadowDirection.BOTH and abs(side_balance) >= 0.5)
		var cap_factors_a = _side_balance_factors(side_balance)
		var cap_factor_a = cap_factors_a[0]
		var cap_factor_b = cap_factors_a[1]

		if draw_start_cap:
			var p0 = source_points[0]
			var t_in = (source_points[1] - p0).normalized()
			var outward_s = -t_in
			var normal_s = Vector2(-t_in.y, t_in.x)
			if cap_asymmetric:
				if cap_factor_a > 0.001:
					var cap_a = _build_cap_mesh(p0, outward_s, normal_s,
						spread_px * cap_factor_a, softness_px * cap_factor_a, opacity, shadow_color,
						18, num_strips, 1.0, cap_outward_scale)
					if cap_a.get_surface_count() > 0:
						for n in _create_shadow_mesh_node(line, cap_a, mesh_offset, "DropShadowStartCapOuter", behind_layer):
							shadow_nodes.append(n)
				if cap_factor_b > 0.001:
					var cap_b = _build_cap_mesh(p0, outward_s, normal_s,
						spread_px * cap_factor_b, softness_px * cap_factor_b, opacity, shadow_color,
						18, num_strips, -1.0, cap_outward_scale)
					if cap_b.get_surface_count() > 0:
						for n in _create_shadow_mesh_node(line, cap_b, mesh_offset, "DropShadowStartCapInner", behind_layer):
							shadow_nodes.append(n)
			else:
				var cap_mesh_s = _build_cap_mesh(p0, outward_s, normal_s,
					spread_px, softness_px, opacity, shadow_color,
					18, num_strips, cap_half_sign, cap_outward_scale)
				if cap_mesh_s.get_surface_count() > 0:
					var nodes_s = _create_shadow_mesh_node(line, cap_mesh_s,
						mesh_offset, "DropShadowStartCap", behind_layer)
					for n in nodes_s:
						shadow_nodes.append(n)

		if draw_end_cap:
			var last_idx = source_points.size() - 1
			var pN = source_points[last_idx]
			var t_out = (pN - source_points[last_idx - 1]).normalized()
			var outward_e = t_out
			var normal_e = Vector2(-t_out.y, t_out.x)
			if cap_asymmetric:
				if cap_factor_a > 0.001:
					var cap_a = _build_cap_mesh(pN, outward_e, normal_e,
						spread_px * cap_factor_a, softness_px * cap_factor_a, opacity, shadow_color,
						18, num_strips, 1.0, cap_outward_scale)
					if cap_a.get_surface_count() > 0:
						for n in _create_shadow_mesh_node(line, cap_a, mesh_offset, "DropShadowEndCapOuter", behind_layer):
							shadow_nodes.append(n)
				if cap_factor_b > 0.001:
					var cap_b = _build_cap_mesh(pN, outward_e, normal_e,
						spread_px * cap_factor_b, softness_px * cap_factor_b, opacity, shadow_color,
						18, num_strips, -1.0, cap_outward_scale)
					if cap_b.get_surface_count() > 0:
						for n in _create_shadow_mesh_node(line, cap_b, mesh_offset, "DropShadowEndCapInner", behind_layer):
							shadow_nodes.append(n)
			else:
				var cap_mesh_e = _build_cap_mesh(pN, outward_e, normal_e,
					spread_px, softness_px, opacity, shadow_color,
					18, num_strips, cap_half_sign, cap_outward_scale)
				if cap_mesh_e.get_surface_count() > 0:
					var nodes_e = _create_shadow_mesh_node(line, cap_mesh_e,
						mesh_offset, "DropShadowEndCap", behind_layer)
					for n in nodes_e:
						shadow_nodes.append(n)

	path.set_meta(SHADOW_META_KEY, shadow_nodes)

	outputlog("Shadow created with " + str(shadow_nodes.size()) + " mesh(es)", 1)

func _get_mipmapped_texture(src):
	# Renvoie une copie mipmappée + filtrée + REPEAT de la texture source, en cache.
	# Le pré-flou des mips est ce qui permet un blur lisse à grand rayon.
	if src == null:
		return src
	var rid = src.get_rid().get_id()
	if _mip_tex_cache.has(rid):
		var cached = _mip_tex_cache[rid]
		if is_instance_valid(cached):
			return cached
	var img = src.get_data()
	if img == null:
		return src
	img = img.duplicate()
	if img.is_compressed():
		if img.decompress() != OK:
			return src
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER | Texture.FLAG_REPEAT)
	_mip_tex_cache[rid] = t
	return t

func _get_realistic_shader() -> Shader:
	if _realistic_shader != null:
		return _realistic_shader
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.6;
uniform float margin_v = 0.0;   // fraction d'UNE bande de marge sur le strip elargi
uniform float v_blur = 0.0;     // rayon de flou en V (unites sv = bande de texture d'origine)
uniform float u_blur = 0.0;     // rayon de flou en U (unites UV.x du Line2D)
uniform float u_scale = 1.0;    // compense le rescale d'aspect du TILE quand le strip est elargi
uniform float mip_lod = 0.0;    // niveau de mip echantillonne (pre-flou de la source)
uniform int kn = 3;             // demi-taille du noyau gaussien (taps actifs = 2*kn+1 par axe)
uniform int do_blur = 0;

// MAXK doit rester synchronise avec REALISTIC_BLUR_MAX_K cote GDScript.
const int MAXK = 6;

void fragment() {
	// Remap V : la texture d'origine occupe la bande centrale [margin_v, 1-margin_v]
	// du strip elargi ; les bandes exterieures sont la place laissee au halo.
	float inner = 1.0 - 2.0 * margin_v;
	float sv = (UV.y - margin_v) / max(inner, 0.0001);
	// En mode TILE, Godot conserve l'aspect : elargir le strip rescale AUSSI la
	// texture en longueur. u_scale remet la frequence de tuilage d'origine.
	float su = UV.x * u_scale;

	float a = 0.0;
	if (do_blur == 0) {
		if (sv >= 0.0 && sv <= 1.0) {
			a = texture(TEXTURE, vec2(su, sv)).a;
		}
	} else {
		// Vrai noyau gaussien : kn taps de chaque cote, espaces d'un pas, chacun
		// pre-floute par le mip a la largeur d'UN pas (mip_lod calcule cote CPU).
		// Les empreintes se recouvrent juste -> enveloppe lisse, pas de boite ni
		// de stries. kn (et donc le cout) s'adapte au rayon.
		float fkn = max(float(kn), 1.0);
		float stride_v = v_blur / fkn;
		float stride_u = u_blur / fkn;
		float sigma = max(fkn * 0.5, 0.5);
		float two_s2 = 2.0 * sigma * sigma;
		float acc = 0.0;
		float wsum = 0.0;
		for (int i = -MAXK; i <= MAXK; i++) {
			if (i < -kn || i > kn) { continue; }
			for (int j = -MAXK; j <= MAXK; j++) {
				if (j < -kn || j > kn) { continue; }
				float fi = float(i);
				float fj = float(j);
				float w = exp(-(fi * fi + fj * fj) / two_s2);
				float svo = sv + fi * stride_v;
				float suo = su + fj * stride_u;
				// Hors bande d'origine -> alpha 0 : c'est ce qui cree le degrade
				// du halo en moyennant des echantillons pleins et vides.
				float av = 0.0;
				if (svo >= 0.0 && svo <= 1.0) {
					av = textureLod(TEXTURE, vec2(suo, svo), mip_lod).a;
				}
				acc += av * w;
				wsum += w;
			}
		}
		a = acc / max(wsum, 0.0001);
	}

	if (a < 0.003) {
		discard;
	}
	COLOR = vec4(shadow_color.rgb, a * shadow_strength);
}
"""
	_realistic_shader = shader
	return shader

# Construit un ruban de triangles texturé le long de la centerline. Chaque point
# émet deux sommets (center ± normal * base_half) ; UV.x = distance cumulée /
# u_period (tiling correct, indépendant de la largeur), UV.y = 0 (bord +n) -> 1
# (bord -n). Pas de joints Line2D donc aucun spike. `normals` sont mitrées et
# plafonnées (calculate_point_normals), ce qui borne la largeur aux angles.
func _build_realistic_strip_mesh(pts: PoolVector2Array, normals: Array, base_half: float, u_period: float, is_closed: bool) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var n = pts.size()
	if n < 2 or normals.size() != n or u_period <= 0.0:
		return mesh

	# (1) Clamp par triplet : plafonne la demi-largeur au rayon de courbure LOCAL
	# (cercle circonscrit aux 3 points adjacents). Attrape le point le plus serré
	# -> jamais de sous-clamp -> pas de repli/rayons. Mais bruité/abrupt.
	var raw_half = []
	for i in range(n):
		var half_i = base_half
		var has_prev = is_closed or i > 0
		var has_next = is_closed or i < n - 1
		if has_prev and has_next:
			var ip = ((i - 1 + n) % n) if is_closed else (i - 1)
			var inx = ((i + 1) % n) if is_closed else (i + 1)
			var pa = pts[ip]
			var pb = pts[i]
			var pc = pts[inx]
			var ab = (pb - pa).length()
			var bc = (pc - pb).length()
			var ca = (pa - pc).length()
			var area2 = abs((pb - pa).cross(pc - pa))  # 2 * aire
			if area2 > 0.001 and ab > 0.001 and bc > 0.001 and ca > 0.001:
				var radius = (ab * bc * ca) / (2.0 * area2)
				var max_off = REALISTIC_FOLD_SAFETY * radius
				if max_off < half_i:
					half_i = max_off
		raw_half.append(half_i)

	# (2) Min sur une fenêtre de DISTANCE (~base_half d'arc de chaque côté) :
	# étale le rétrécissement sur toute la zone du virage -> transition progressive
	# (pas de dents) tout en restant conservatif (le creux n'est jamais remonté
	# au-dessus du rayon sûr -> pas de repli).
	var win_dist = base_half
	var minned = []
	for i in range(n):
		var m = raw_half[i]
		var jp = i
		var d = 0.0
		var g = 0
		while g < n:
			g += 1
			var jprev = ((jp - 1 + n) % n) if is_closed else (jp - 1)
			if not is_closed and jprev < 0:
				break
			d += pts[jp].distance_to(pts[jprev])
			jp = jprev
			if raw_half[jp] < m:
				m = raw_half[jp]
			if d >= win_dist or jp == i:
				break
		var jn = i
		d = 0.0
		g = 0
		while g < n:
			g += 1
			var jnext = ((jn + 1) % n) if is_closed else (jn + 1)
			if not is_closed and jnext > n - 1:
				break
			d += pts[jn].distance_to(pts[jnext])
			jn = jnext
			if raw_half[jn] < m:
				m = raw_half[jn]
			if d >= win_dist or jn == i:
				break
		minned.append(m)

	# (3) Moyenne légère pour effacer les marches résiduelles du min.
	var half_len = minned
	for _pass in range(2):
		var smooth = []
		for i in range(n):
			var acc = 0.0
			var cnt = 0
			for k in range(-2, 3):
				var j = i + k
				if is_closed:
					j = (j + n) % n
				else:
					j = int(clamp(j, 0, n - 1))
				acc += half_len[j]
				cnt += 1
			smooth.append(acc / float(cnt))
		half_len = smooth

	var verts = PoolVector2Array()
	var uvs = PoolVector2Array()
	var cum = 0.0
	for i in range(n):
		if i > 0:
			cum += pts[i].distance_to(pts[i - 1])
		var nrm = normals[i]
		if nrm.length() > 0.0001:
			nrm = nrm.normalized()
		var off = nrm * half_len[i]
		var u = cum / u_period
		verts.append(pts[i] + off)   # bord "out" -> UV.y = 0
		uvs.append(Vector2(u, 0.0))
		verts.append(pts[i] - off)   # bord "in"  -> UV.y = 1
		uvs.append(Vector2(u, 1.0))

	# Section de fermeture pour les boucles (UV qui continue).
	var sections = n
	if is_closed:
		cum += pts[n - 1].distance_to(pts[0])
		var nrm0 = normals[0]
		if nrm0.length() > 0.0001:
			nrm0 = nrm0.normalized()
		var off0 = nrm0 * half_len[0]
		var u0 = cum / u_period
		verts.append(pts[0] + off0)
		uvs.append(Vector2(u0, 0.0))
		verts.append(pts[0] - off0)
		uvs.append(Vector2(u0, 1.0))
		sections = n + 1

	# 2 triangles par segment entre sections consécutives.
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

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
	arrays[ArrayMesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# Mode B : on copie le path TEL QU'IL EST RENDU dans une texture hors-écran
# (Viewport), puis on floute ce bitmap plat. Un flou d'image ne peut produire ni
# repli, ni rayon, ni dent -- par construction ; le halo déborde dans la marge
# transparente. Réglages : opacity, shadow_color, offset_x/y, behind_layer,
# realistic_blur. Net (blur 0) = simple copie Line2D teintée (pas de viewport).
func create_realistic_shadow(path, config: Dictionary, line = null):
	if path == null or not is_instance_valid(path):
		return
	if line == null:
		line = get_line2d(path)
	if line == null:
		return
	if line.points.size() < 2:
		return
	if line.texture == null:
		outputlog("create_realistic_shadow: path sans texture, ignoré", 0)
		return

	var opacity = config.get("opacity_realistic", config.get("opacity", DEFAULT_SHADOW_CONFIG["opacity"]))
	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	var behind_layer = config.get("behind_layer", false)

	var blur_px = _realistic_blur_px_from_frac(config.get("realistic_blur", 0.0))
	var do_blur = blur_px >= REALISTIC_MIN_BLUR_PX

	# Décalage monde -> local (rotation ET miroir/scale du path)
	var offset = Vector2(config.get("offset_x", 0.0), config.get("offset_y", 0.0))
	offset = line.global_transform.affine_inverse().basis_xform(offset)

	# Bulge : le décalage de BASE reste la translation rigide du nœud. Le renflement
	# local devient un déplacement par-sommet (vertex shader) sur une copie aux POINTS
	# D'ORIGINE (texture inchangée, étirement par l'angle). La bbox de capture intègre
	# le bombage ; le nœud reste positionné à l'offset de base.
	var bulge = _make_bulge(config, line)
	# Décalage perpendiculaire (radial offset / side balance) + direction (clip d'un côté).
	var radial = _make_radial(config, line)

	# Tout (re)build realistic incrémente le jeton de génération : invalide une
	# capture floutée asynchrone encore en vol (évite qu'elle écrase une ombre
	# plus récente, nette ou floutée).
	var nid = path.get_instance_id()
	var gen = _realistic_gen.get(nid, 0) + 1
	_realistic_gen[nid] = gen

	# Boucle fermée + radial/side balance (sans bombage) : le tiling de boucle ne peut
	# pas être recalculé à la main -> le ruban échantillonne le bitmap du Line2D NATUREL
	# (tiling exact de DD), mis en cache. En FLOU on passe par la MÊME session live que
	# les paths ouverts (viewport persistant échantillonné en direct, sans readback) ->
	# pas de lag pendant le drag. Le bake statique de boucle (1er build / settle) capture
	# ou met à jour le cache du bitmap.
	if radial != null and bulge == null and _is_line_closed(line):
		if not do_blur:
			# Net : ruban direct (instantané si le bitmap est déjà en cache).
			_teardown_realistic_live(nid)
			_realistic_last_req[nid] = OS.get_ticks_msec()
			_create_realistic_loop(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, radial)
			return
		var now_l = OS.get_ticks_msec()
		var last_l = _realistic_last_req.get(nid, -1000000)
		_realistic_last_req[nid] = now_l
		if _realistic_live.has(nid) and _loop_nat_valid(nid, line):
			_update_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		elif now_l - last_l < REALISTIC_LIVE_THRESHOLD_MS and _loop_nat_valid(nid, line):
			_start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		else:
			# Pas (encore) de bitmap en cache, ou build isolé : coroutine (capture + bake).
			_teardown_realistic_live(nid)
			_create_realistic_loop(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, radial)
		return

	if not do_blur:
		# Net : copie quasi-gratuite. Une éventuelle session live n'a plus lieu d'être.
		_teardown_realistic_live(nid)
		_realistic_last_req[nid] = OS.get_ticks_msec()
		_create_realistic_sharp(path, line, offset, shadow_color, opacity, behind_layer, bulge, radial)
	else:
		# Flou. Pendant une édition interactive (appels rapprochés), on bascule en
		# mode LIVE : viewport persistant échantillonné en direct -> le flou suit
		# l'édition sans readback ni lag. Au repos, _process_realistic_live_settle()
		# reconvertit en texture statique mipmappée. Un build isolé (chargement de
		# carte, etc.) reste un bake statique direct.
		var now = OS.get_ticks_msec()
		var last = _realistic_last_req.get(nid, -1000000)
		_realistic_last_req[nid] = now
		if _realistic_live.has(nid):
			_update_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		elif now - last < REALISTIC_LIVE_THRESHOLD_MS:
			_start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		else:
			_create_realistic_blurred(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, bulge, radial)

# Applique les propriétés visuelles du path à une copie Line2D (rendu identique).
# Avec accroche : géométrie INCHANGÉE (points d'origine) -> le déplacement se fait au
# vertex shader, et le gradient est remplacé par une rampe t (rouge) lue par ce shader.
func _copy_line_props(dst, src, bulge = null, radial = null):
	# NB : quand radial/side balance est actif, la silhouette passe par un ruban texturé
	# (MeshInstance2D), pas par ce Line2D -> on n'élargit PAS le trait (l'élargir
	# changerait le tiling "Super" et rallongerait la chaîne). Ici radial reste nul côté
	# Line2D.
	dst.points = src.points
	dst.width = src.width
	dst.width_curve = src.width_curve
	dst.default_color = Color(1, 1, 1, 1)
	dst.texture = src.texture
	dst.texture_mode = src.texture_mode
	dst.joint_mode = src.joint_mode
	dst.begin_cap_mode = src.begin_cap_mode
	dst.end_cap_mode = src.end_cap_mode
	dst.sharp_limit = src.sharp_limit
	dst.round_precision = src.round_precision
	dst.antialiased = src.antialiased
	# Boucle fermée : DD dessine ses paths avec un Line2D patché (build custom) qui gère
	# la fermeture nativement (joint propre à la couture). On réplique la propriété loop
	# sur la copie (même classe que le path, comme pour "Super"). Si la copie ne la
	# supporte pas, repli : on rajoute le premier point (segment de fermeture, mais sans
	# joint -> léger chevauchement possible).
	var closed = _is_line_closed(src)
	var appended_close = false
	if closed:
		var native_closed = false
		for prop_name in ["loop", "Loop", "closed", "Closed", "IsLoop"]:
			var v = src.get(prop_name)
			if v is bool and v:
				dst.set(prop_name, true)
				if dst.get(prop_name) == true:
					native_closed = true
				break
		if not native_closed:
			var cpts = src.points
			cpts.append(cpts[0])
			dst.points = cpts
			dst.begin_cap_mode = Line2D.LINE_CAP_NONE
			dst.end_cap_mode = Line2D.LINE_CAP_NONE
			appended_close = true
	if src.gradient != null:
		dst.gradient = src.gradient.duplicate()
	# Quand le path porte un effet shader (universalshader actif), il IGNORE son
	# gradient (fragment: COLOR = color, sans * COLOR) -> le fondu vient du shader
	# seul. On neutralise donc le gradient sur la copie pour ne pas fonder DEUX fois.
	if _path_has_shader_effect(_get_path_shader_params(src)):
		dst.gradient = null
	# DD dessine ses paths avec un Line2D patché (flag "Super" du build Godot custom) :
	# tiling de la texture par longueur d'arc réelle. Une copie Line2D standard a ce
	# flag à false -> tiling d'origine qui distord la texture entre des points à
	# espacement non-uniforme (sortie Chaikin, même sur une droite) -> ombre
	# compressée/étirée. On réplique la valeur du path pour un rendu identique.
	for _sname in ["super", "Super"]:
		var _sval = src.get(_sname)
		if _sval != null:
			dst.set(_sname, _sval)
	# Grow/Shrink : DD stocke les largeurs par point (cônus aux extrémités) dans le
	# champ "widths" du Pathway et les pose via set_point_width (Line2D patché). On les
	# réplique pour que l'ombre se rétrécisse comme le path.
	var widths = src.get("widths")
	if widths != null and dst.has_method("set_point_width"):
		var wn = widths.size()
		# Copie fermée par ajout de point : aligner les largeurs (première répétée).
		if appended_close and wn == dst.get_point_count() - 1:
			var w2 = []
			for i in range(wn):
				w2.append(widths[i])
			w2.append(widths[0])
			widths = w2
			wn = widths.size()
		if wn > 0 and wn == dst.get_point_count():
			for i in range(wn):
				dst.call("set_point_width", i, widths[i])
	# Accroche : rampe t (rouge) dans le gradient -> lue par le vertex shader.
	if bulge != null:
		dst.gradient = _make_anchor_t_gradient()

# Libère une liste de nœuds d'ombre (détache puis free).
func _free_shadow_nodes(nodes):
	if nodes is Array:
		for n in nodes:
			if is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.free()

# Net : copie fidèle du Line2D (se rend exactement comme le path), teintée.
# --- Crop Blur (Side A/B, realistic) ---------------------------------------------------
# Le flou polaire étale la silhouette (clippée au centre par le ruban) au-delà de la
# ligne centrale du path. Le masque = région SOLIDE du côté interdit, capturée dans un
# 2e viewport aligné sur la capture principale, passée au shader de flou qui discard là
# où le masque est opaque. Le crop SUIT l'offset X/Y du sprite (même espace texture).
# Géométrie identique aux walls : QUADS par arête + MITER aux coins concaves (jamais de
# morsure sur le côté gardé) + ÉVENTAILS aux coins convexes (pas de fuite triangulaire).
# Pas de portails/endcaps sur les paths ; le bulge est appliqué à la centerline en amont.
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

# Ajoute au container les DEUX passes du masque : côté interdit (rouge) + côté gardé
# (vert, même géométrie côté opposé). Le vert PROTÈGE l'ombre gardée des branches non
# adjacentes (hairpin, courbe dense) traversées par les quads interdits.
func _populate_path_crop(mcont, pts, dir, closed, reach):
	var sides = [[dir, false], [_crop_opposite_dir(dir), true]]
	for sd in sides:
		var strip = _build_path_crop_mesh(pts, sd[0], closed, reach)
		if strip.get_surface_count() == 0:
			continue
		var mi = MeshInstance2D.new()
		mi.mesh = strip
		mi.material = _crop_tint_mat(sd[1])
		mcont.add_child(mi)

# Gain d'alpha du flou : compense la silhouette DEMI-largeur du mode Side SANS crop
# (deux fois moins de matière à portée du noyau -> alpha ~/2 à flou fort). Le clamp à 1
# dans le shader le rend sans effet à flou faible (alpha déjà saturé près du trait).
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

# crop_ends pour les builders realistic : stash (valeur fraîche posée par create_shadow)
# en priorité, config SAUVÉE en repli (ModMapData est sauvegardé APRÈS create_shadow
# dans apply_shadow_to_selected_paths -> lu seul, il retarde le toggle d'un cran).
var _path_crop_ends_cfg = {}
func _path_cfg_crop_ends(path) -> bool:
	if path == null or not is_instance_valid(path):
		return false
	var iid = path.get_instance_id()
	if _path_crop_ends_cfg.has(iid):
		return _path_crop_ends_cfg[iid]
	if not path.has_meta("node_id") or not global.ModMapData.has(SHADOW_DATA_KEY):
		return false
	var d = global.ModMapData[SHADOW_DATA_KEY].get(str(path.get_meta("node_id")))
	return d != null and d.get("crop_ends", false)

func _path_ends_on(path, blur_px, closed) -> bool:
	if closed:
		return false
	return _path_cfg_crop_ends(path) and blur_px >= REALISTIC_MIN_BLUR_PX

# Crop Ends : quads BLEUS (crop absolu, prioritaire sur la protection verte) au-delà du
# bord extérieur du CAP à chaque extrémité du path (les caps rond/carré d'un Line2D
# dépassent de width/2 ; CAP_NONE = affleurant). Indépendant du crop latéral, actif
# aussi en Both. `pts` = centerline (bulge déjà appliqué), en espace line-local.
func _populate_path_end_crop(mcont, pts, reach, line):
	if pts.size() < 2:
		return
	var w2 = line.width * 0.5
	var ends = []
	var t0 = pts[1] - pts[0]
	var t1 = pts[pts.size() - 1] - pts[pts.size() - 2]
	if t0.length() > 0.001:
		ends.append({"p": pts[0], "t": -t0.normalized(), "cap": line.begin_cap_mode != Line2D.LINE_CAP_NONE})
	if t1.length() > 0.001:
		ends.append({"p": pts[pts.size() - 1], "t": t1.normalized(), "cap": line.end_cap_mode != Line2D.LINE_CAP_NONE})
	for e in ends:
		var c = e["p"] + e["t"] * (w2 if e["cap"] else 0.0)
		var t = e["t"]
		var nrm = Vector2(-t.y, t.x)
		var mi = MeshInstance2D.new()
		mi.mesh = _end_crop_gradient_mesh(c, t, nrm, w2 + 4.0, reach, reach + 8.0)
		mi.material = _crop_tint_mat_ends()
		mcont.add_child(mi)

func _path_crop_on(radial, blur_px) -> bool:
	if radial == null or not radial.get("crop", false):
		return false
	if int(radial.get("dir", ShadowDirection.BOTH)) == ShadowDirection.BOTH:
		return false
	return blur_px >= REALISTIC_MIN_BLUR_PX

func _path_crop_reach(blur_px, line_width) -> float:
	# Couvre tout débordement possible : rayon de flou + demi-largeur gardée (+ marge).
	return blur_px + line_width + 8.0

func _build_path_crop_mesh(src: PoolVector2Array, dir, closed, reach) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	if not closed and src.size() >= 2:
		# Extrémités ouvertes prolongées de `reach` (arête colinéaire) : couvre le flou
		# des caps du trait.
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
	# sur la bissectrice) -> chaque quad reste confiné entre son arête et la bissectrice,
	# borné à la plus courte arête adjacente (ne ressort pas du coin suivant).
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
	# Éventails aux coins CONVEXES côté interdit.
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

# Viewport de capture du masque, aligné (taille + transform du contenu) sur la capture
# principale. Enfant du viewport principal -> libéré automatiquement avec lui.
func _make_path_crop_viewport(vp, cont_scale, cont_pos, pts, dir, reach, closed, v_flip, update_mode, side_on = true, ends_on = false, line = null):
	var mvp = Viewport.new()
	mvp.size = vp.size
	mvp.transparent_bg = true
	mvp.usage = Viewport.USAGE_2D
	mvp.disable_3d = true
	mvp.hdr = false
	mvp.render_target_v_flip = v_flip
	mvp.render_target_update_mode = update_mode
	var mcont = Node2D.new()
	mcont.scale = Vector2(cont_scale, cont_scale)
	mcont.position = cont_pos
	mvp.add_child(mcont)
	if side_on:
		_populate_path_crop(mcont, pts, dir, closed, reach)
	if ends_on and line != null:
		_populate_path_end_crop(mcont, pts, reach, line)
	vp.add_child(mvp)   # un Viewport n'est pas un CanvasItem -> ne pollue pas la capture principale
	return [mvp, mcont]

func _apply_path_crop_params(mat, mask_tex):
	if mask_tex == null:
		mat.set_shader_param("crop_enabled", 0.0)
		return
	mat.set_shader_param("crop_enabled", 1.0)
	mat.set_shader_param("crop_mask", mask_tex)

func _create_realistic_sharp(path, line, offset, shadow_color, opacity, behind_layer, bulge = null, radial = null):
	var copy
	if radial != null:
		# Ruban texturé teinté (épaisseur radiale / asymétrie side balance) -> découple
		# l'épaisseur du tiling (pas de rallongement de la chaîne).
		copy = MeshInstance2D.new()
		copy.name = "DropShadowRealistic"
		copy.mesh = _build_silhouette_strip(line, bulge, radial)
		var smat = ShaderMaterial.new()
		smat.shader = _get_silhouette_tint_shader()
		smat.set_shader_param("tex", line.texture)
		smat.set_shader_param("shadow_color", shadow_color)
		smat.set_shader_param("shadow_strength", opacity)
		_apply_silhouette_path_params(smat, line)
		copy.material = smat
	else:
		copy = Line2D.new()
		copy.name = "DropShadowRealistic"
		_copy_line_props(copy, line, bulge, radial)
		var mat = ShaderMaterial.new()
		mat.shader = _get_realistic_tint_shader()
		mat.set_shader_param("shadow_color", shadow_color)
		mat.set_shader_param("shadow_strength", opacity)
		var sp = _get_path_shader_params(line)
		mat.set_shader_param("start_point", sp["sp"])
		mat.set_shader_param("path_flip_vertical", sp["flip"])
		mat.set_shader_param("FadeIn", sp["fade_in"])
		mat.set_shader_param("FadeOut", sp["fade_out"])
		mat.set_shader_param("path_length_in_uv", sp["plu"])
		mat.set_shader_param("fade_distance", sp["fdist"])
		_apply_bulge_uniforms(mat, bulge)
		copy.material = mat
	copy.position = offset
	copy.z_as_relative = true
	if behind_layer:
		copy.z_index = -1
		copy.show_behind_parent = false
	else:
		copy.show_behind_parent = true
	# Swap atomique : on n'enlève l'ancienne ombre qu'une fois la nouvelle posée.
	var old_nodes = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	line.add_child(copy)
	path.set_meta(SHADOW_META_KEY, [copy])
	_free_shadow_nodes(old_nodes)

# Flou : rasterise une copie du path dans un Viewport, affiche un Sprite flouté.
# Calcule le noyau de flou (demi-taille, rayon en texels, LOD mip) à partir du
# rayon monde et de l'échelle de rendu. Source unique pour build ET mise à jour
# live, afin qu'ils restent rigoureusement synchrones.
func _realistic_blur_px_from_frac(frac) -> float:
	# Mappe le slider (0..1) vers un rayon en px. 0 = net (copie vectorielle). Au-
	# dessus, on démarre au palier FLOOR (les valeurs minuscules crénelaient) puis
	# on interpole jusqu'au max -> tout le bas du slider est "propre".
	frac = clamp(frac, 0.0, 1.0)
	if frac <= 0.0005:
		return 0.0
	return REALISTIC_BLUR_FLOOR_PX + frac * (REALISTIC_BLUR_MAX_PX - REALISTIC_BLUR_FLOOR_PX)

func _realistic_blur_kernel(blur_px, scale_f) -> Array:
	# Renvoie [rayon en texels, mip_lod]. Le mip comble les trous radiaux du noyau
	# polaire au flou fort : chaque échantillon couvre ~l'espacement entre anneaux.
	var blur_vp = blur_px * scale_f
	var mip_lod = 0.0
	var spacing = blur_vp / float(REALISTIC_BLUR_QUALITY)
	if spacing > 1.0:
		mip_lod = log(spacing) / log(2.0)
	return [blur_vp, mip_lod]

# Flou : rasterise une copie du path dans un Viewport, capture le rendu en
# ImageTexture MIPMAPPÉE, jette le viewport, puis affiche un Sprite qui floute la
# texture en textureLod. Le mip pré-moyenne chaque échantillon -> comble les trous
# entre échantillons -> plus de carrés sur les bords droits/45°. Asynchrone (le
# viewport rend en une frame) ; un jeton de génération annule les captures rendues
# obsolètes par une destruction/reconstruction pendant l'attente.
func _create_realistic_blurred(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, bulge = null, radial = null):
	var g = _compute_realistic_geom(line, bulge, radial)
	if g == null:
		return
	var origin = g["origin"]
	var content = g["content"]
	var scale_f = g["scale_f"]
	var vp_size = g["vp_size"]
	var nid = path.get_instance_id()

	# Viewport hors-écran : rend une copie du Line2D sur fond transparent, UNE fois.
	var vp = Viewport.new()
	vp.size = vp_size
	vp.transparent_bg = true
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.render_target_v_flip = false
	vp.render_target_update_mode = Viewport.UPDATE_ONCE

	var copy = _new_realistic_copy(line, radial, true)
	_setup_bake_copy(copy, line, scale_f, origin, bulge, radial)
	vp.add_child(copy)
	# Crop at Center (Side A/B) et/ou Crop Ends : viewport masque aligné, capturé dans
	# les MÊMES idle frames.
	var _side_crop = _path_crop_on(radial, blur_px)
	var _ends_crop = _path_ends_on(path, blur_px, _is_line_closed(line))
	var mvp = null
	if _side_crop or _ends_crop:
		var mpts = line.points
		if bulge != null:
			mpts = _bulge_disp_from(mpts, bulge)
		var mres = _make_path_crop_viewport(vp, scale_f, -origin * scale_f, mpts,
			int(radial.get("dir")) if radial != null else ShadowDirection.BOTH,
			_path_crop_reach(blur_px, line.width),
			_is_line_closed(line), false, Viewport.UPDATE_ONCE, _side_crop, _ends_crop, line)
		mvp = mres[0]
	line.add_child(vp)

	# Laisse le viewport effectuer son rendu (UPDATE_ONCE -> prêt après ~1-2 frames).
	yield(global.Editor.get_tree(), "idle_frame")
	yield(global.Editor.get_tree(), "idle_frame")

	# Capture annulée (ombre refaite/détruite, ou path/line libéré) ?
	if _realistic_gen.get(nid, -1) != gen or not is_instance_valid(path) or not is_instance_valid(line) or not is_instance_valid(vp):
		if is_instance_valid(vp):
			vp.queue_free()
		return

	# Rendu -> image -> ImageTexture mipmappée. Le rendu de viewport est retourné
	# verticalement -> flip_y. NOTE: si le flou apparaît miroir vertical vs le net,
	# retirer ce flip_y.
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
		return
	img.flip_y()
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER)


	var tsize = vp_size  # taille texture en px
	var base_pos = g["base_pos"]
	var spr = Sprite.new()
	spr.name = "DropShadowRealistic"
	spr.texture = tex
	spr.centered = true
	spr.scale = Vector2(1.0 / scale_f, 1.0 / scale_f)
	spr.position = base_pos + offset
	spr.z_as_relative = true
	# Mémorisé pour la mise à jour live (flou/offset/couleur/opacité sans rebuild).
	spr.set_meta("ds_scale", scale_f)
	spr.set_meta("base_pos", base_pos)
	spr.set_meta("tsize", tsize)

	var mat = ShaderMaterial.new()
	mat.shader = _get_realistic_vp_blur_shader()
	_apply_realistic_blur_params(mat, tsize, blur_px, scale_f, shadow_color, opacity)
	_apply_path_crop_params(mat, mask_tex)
	mat.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	spr.material = mat

	if behind_layer:
		spr.z_index = -1
		spr.show_behind_parent = false
	else:
		spr.show_behind_parent = true

	line.add_child(spr)
	# Swap atomique : ancienne ombre libérée seulement une fois la nouvelle posée.
	var old_nodes = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	path.set_meta(SHADOW_META_KEY, [spr])
	_free_shadow_nodes(old_nodes)

# Cas BOUCLE FERMÉE + radial/side balance : le tiling de boucle est fait par l'engine
# (Line2D "Super"), impossible à reproduire en calculant les UV à la main. On rend donc
# le Line2D NATUREL (tiling exact de DD) hors-écran -> bitmap, puis le ruban asymétrique
# échantillonne ce bitmap PAR POSITION (étirement géométrique, texture = rendu de DD).
# Résultat : tiling parfait sur boucle, épaisseur radiale/asymétrique conservée. Net =
# ruban direct ; flou = 2e viewport + Sprite flouté (machinerie identique au bake).
func _create_realistic_loop(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, radial):
	var nid = path.get_instance_id()
	# Étape 1 : bitmap du Line2D NATUREL (tiling exact de DD). Réutilisé du cache tant que
	# le path n'a pas changé (radial/offset/couleur ne l'invalident pas) -> pas de rendu
	# viewport ni d'attente quand on ne fait que régler l'épaisseur.
	var tex1
	var nat_origin
	var nat_content
	if _loop_nat_valid(nid, line):
		var c = _loop_nat_tex[nid]
		tex1 = c["tex"]
		nat_origin = c["origin"]
		nat_content = c["content"]
	else:
		# Capture asynchrone (un seul render+readback, ~2 frames). Gardée : une seule
		# capture en vol par path. Elle NE s'annule PAS sur changement de génération
		# (le bitmap ne dépend pas du radial) -> elle se met en cache même pendant un
		# drag continu, après quoi la session live prend le relais (fluide).
		if _loop_capturing.get(nid, false):
			return
		var gn = _compute_realistic_geom(line, null, null)
		if gn == null:
			return
		nat_origin = gn["origin"]
		nat_content = gn["content"]
		_loop_capturing[nid] = true
		var vp1 = Viewport.new()
		vp1.size = gn["vp_size"]
		vp1.transparent_bg = true
		vp1.usage = Viewport.USAGE_2D
		vp1.disable_3d = true
		vp1.hdr = false
		vp1.render_target_v_flip = false
		vp1.render_target_update_mode = Viewport.UPDATE_ONCE
		var nat = Line2D.new()
		_setup_bake_copy(nat, line, gn["scale_f"], nat_origin, null, null)
		vp1.add_child(nat)
		line.add_child(vp1)
		yield(global.Editor.get_tree(), "idle_frame")
		yield(global.Editor.get_tree(), "idle_frame")
		if not is_instance_valid(path) or not is_instance_valid(line) or not is_instance_valid(vp1):
			if is_instance_valid(vp1):
				vp1.queue_free()
			_loop_capturing.erase(nid)
			return
		var img1 = vp1.get_texture().get_data()
		vp1.queue_free()
		if img1 == null:
			_loop_capturing.erase(nid)
			return
		img1.flip_y()
		tex1 = ImageTexture.new()
		tex1.create_from_image(img1, Texture.FLAG_FILTER)
		_loop_nat_tex[nid] = {"tex": tex1, "sig": _loop_sig(line), "origin": nat_origin, "content": nat_content}
		_loop_capturing.erase(nid)

	# Capture/cache prêt. Si une édition plus récente est survenue pendant la capture, la
	# session live (déclenchée par ces éditions) prend le relais -> on abandonne ce build
	# statique pour ne pas écraser la sprite live (course sur SHADOW_META_KEY).
	if _realistic_gen.get(nid, -1) != gen:
		return

	# Étape 2 : ruban asymétrique qui échantillonne le bitmap par position.
	var bm = {"origin": nat_origin, "content": nat_content}
	var mesh = _build_silhouette_strip(line, null, radial, bm)

	var do_blur = blur_px >= REALISTIC_MIN_BLUR_PX
	if not do_blur:
		# Net : le ruban teinté est l'ombre finale.
		var mi = MeshInstance2D.new()
		mi.name = "DropShadowRealistic"
		mi.mesh = mesh
		var smat = ShaderMaterial.new()
		smat.shader = _get_silhouette_tint_shader()
		smat.set_shader_param("tex", tex1)
		smat.set_shader_param("tiled", false)
		smat.set_shader_param("shadow_color", shadow_color)
		smat.set_shader_param("shadow_strength", opacity)
		mi.material = smat
		mi.position = offset
		mi.z_as_relative = true
		if behind_layer:
			mi.z_index = -1
			mi.show_behind_parent = false
		else:
			mi.show_behind_parent = true
		var old_sharp = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
		line.add_child(mi)
		path.set_meta(SHADOW_META_KEY, [mi])
		_free_shadow_nodes(old_sharp)
		return

	# Flou : on rend le ruban (silhouette blanche+alpha) dans un 2e viewport (géométrie
	# ÉTENDUE pour contenir l'épaisseur), puis Sprite flouté (machinerie du bake).
	var ge = _compute_realistic_geom(line, null, radial)
	if ge == null:
		return
	var ext_origin = ge["origin"]
	var scale_f = ge["scale_f"]
	var vp2 = Viewport.new()
	vp2.size = ge["vp_size"]
	vp2.transparent_bg = true
	vp2.usage = Viewport.USAGE_2D
	vp2.disable_3d = true
	vp2.hdr = false
	vp2.render_target_v_flip = false
	vp2.render_target_update_mode = Viewport.UPDATE_ONCE
	var mi2 = MeshInstance2D.new()
	mi2.mesh = mesh
	var bmat = ShaderMaterial.new()
	bmat.shader = _get_silhouette_bake_shader()
	bmat.set_shader_param("tex", tex1)
	bmat.set_shader_param("tiled", false)
	mi2.material = bmat
	mi2.scale = Vector2(scale_f, scale_f)
	mi2.position = -ext_origin * scale_f
	vp2.add_child(mi2)
	# Crop Blur (Side A/B) : viewport masque aligné (boucle -> mesh fermé, pas d'extension).
	var mvp2 = null
	if _path_crop_on(radial, blur_px):
		var mres2 = _make_path_crop_viewport(vp2, scale_f, -ext_origin * scale_f, line.points,
			int(radial.get("dir")), _path_crop_reach(blur_px, line.width),
			true, false, Viewport.UPDATE_ONCE)
		mvp2 = mres2[0]
	line.add_child(vp2)
	yield(global.Editor.get_tree(), "idle_frame")
	yield(global.Editor.get_tree(), "idle_frame")
	if _realistic_gen.get(nid, -1) != gen or not is_instance_valid(path) or not is_instance_valid(line) or not is_instance_valid(vp2):
		if is_instance_valid(vp2):
			vp2.queue_free()
		return
	var img2 = vp2.get_texture().get_data()
	# Readback du masque AVANT le queue_free du viewport principal (mvp2 en est l'enfant).
	var mask_tex2 = null
	if mvp2 != null and is_instance_valid(mvp2):
		var mimg2 = mvp2.get_texture().get_data()
		if mimg2 != null:
			mimg2.flip_y()
			mask_tex2 = ImageTexture.new()
			mask_tex2.create_from_image(mimg2, Texture.FLAG_FILTER)
	vp2.queue_free()
	if img2 == null:
		return
	img2.flip_y()
	var tex2 = ImageTexture.new()
	tex2.create_from_image(img2, Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER)

	var tsize = ge["vp_size"]
	var base_pos = ge["base_pos"]
	var spr = Sprite.new()
	spr.name = "DropShadowRealistic"
	spr.texture = tex2
	spr.centered = true
	spr.scale = Vector2(1.0 / scale_f, 1.0 / scale_f)
	spr.position = base_pos + offset
	spr.z_as_relative = true
	spr.set_meta("ds_scale", scale_f)
	spr.set_meta("base_pos", base_pos)
	spr.set_meta("tsize", tsize)
	var mat = ShaderMaterial.new()
	mat.shader = _get_realistic_vp_blur_shader()
	_apply_realistic_blur_params(mat, tsize, blur_px, scale_f, shadow_color, opacity)
	_apply_path_crop_params(mat, mask_tex2)
	mat.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	spr.material = mat
	if behind_layer:
		spr.z_index = -1
		spr.show_behind_parent = false
	else:
		spr.show_behind_parent = true
	line.add_child(spr)
	var old_blur = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	path.set_meta(SHADOW_META_KEY, [spr])
	_free_shadow_nodes(old_blur)

# --- Helpers partagés bake statique / live (source unique géométrie + params) ---

# Géométrie de capture à partir des points : bbox + marge, échelle (downscale si
# énorme), taille viewport, centre. Renvoie un Dictionary ou null si dégénéré.
func _compute_realistic_geom(line, bulge = null, radial = null):
	var pts = line.points
	if bulge != null:
		pts = _bulge_disp_from(pts, bulge)
	if pts.size() < 2:
		return null
	var minp = pts[0]
	var maxp = pts[0]
	for p in pts:
		minp.x = min(minp.x, p.x)
		minp.y = min(minp.y, p.y)
		maxp.x = max(maxp.x, p.x)
		maxp.y = max(maxp.y, p.y)
	# Marge = largeur du trait, élargie si le ruban est épaissi/asymétrique (radial).
	var margin = line.width * _radial_extent_factor(radial)
	var origin = minp - Vector2(margin, margin)
	var content = (maxp - minp) + Vector2(2.0 * margin, 2.0 * margin)
	if content.x < 1.0 or content.y < 1.0:
		return null
	var scale_f = REALISTIC_VP_DOWNSAMPLE
	var big = max(content.x, content.y)
	if big * scale_f > REALISTIC_VP_MAX_DIM:
		scale_f = REALISTIC_VP_MAX_DIM / big
	var vp_size = Vector2(max(ceil(content.x * scale_f), 1.0), max(ceil(content.y * scale_f), 1.0))
	return {"origin": origin, "content": content, "scale_f": scale_f, "vp_size": vp_size, "base_pos": origin + content * 0.5}

# Configure la copie Line2D à rasteriser (points/props + échelle + position +
# décalage de texture éventuel). Réutilisé par le bake statique ET le live.
func _apply_bake_copy_props(copy, line, scale_f, bulge = null, radial = null, loop_nat = null):
	copy.scale = Vector2(scale_f, scale_f)
	if copy is Line2D:
		_copy_line_props(copy, line, bulge, radial)
		var sp = _get_path_shader_params(line)
		# On assigne le shader de bake si le path a un effet (start_point/fondu) OU si
		# l'accroche est active (le déplacement par-sommet a besoin d'un vertex shader).
		# Sans effet, les paramètres restent neutres -> rendu identique à un matériau nul.
		if _path_has_shader_effect(sp) or bulge != null:
			var omat = ShaderMaterial.new()
			omat.shader = _get_realistic_bake_offset_shader()
			omat.set_shader_param("start_point", sp["sp"])
			omat.set_shader_param("path_flip_vertical", sp["flip"])
			omat.set_shader_param("FadeIn", sp["fade_in"])
			omat.set_shader_param("FadeOut", sp["fade_out"])
			omat.set_shader_param("path_length_in_uv", sp["plu"])
			omat.set_shader_param("fade_distance", sp["fdist"])
			_apply_bulge_uniforms(omat, bulge)
			copy.material = omat
		else:
			copy.material = null
	elif loop_nat != null:
		# Ruban BOUCLE : échantillonne le bitmap naturel (tiling exact de DD) par position.
		copy.mesh = _build_silhouette_strip(line, null, radial, {"origin": loop_nat["origin"], "content": loop_nat["content"]})
		if copy.material is ShaderMaterial:
			copy.material.set_shader_param("tex", loop_nat["tex"])
			copy.material.set_shader_param("tiled", false)
	else:
		# Ruban path ouvert : le bombage est cuit dans les sommets, matériau silhouette
		# (shader + tex) déjà posé à la création -> on rebuild juste le maillage.
		copy.mesh = _build_silhouette_strip(line, bulge, radial)
		if copy.material is ShaderMaterial and line.texture != null:
			copy.material.set_shader_param("tex", line.texture)
			copy.material.set_shader_param("tiled", true)
			_apply_silhouette_path_params(copy.material, line)

func _setup_bake_copy(copy, line, scale_f, origin, bulge = null, radial = null, loop_nat = null):
	_apply_bake_copy_props(copy, line, scale_f, bulge, radial, loop_nat)
	copy.position = -origin * scale_f

# Pose tous les uniformes du shader de flou polaire sur un matériau donné.
func _apply_realistic_blur_params(mat, tsize, blur_px, scale_f, shadow_color, opacity):
	var k = _realistic_blur_kernel(blur_px, scale_f)
	var blur_vp = k[0]
	var mip_lod = k[1]
	mat.set_shader_param("shadow_color", shadow_color)
	mat.set_shader_param("shadow_strength", opacity)
	mat.set_shader_param("texel", Vector2(1.0 / tsize.x, 1.0 / tsize.y))
	mat.set_shader_param("blur_px", blur_vp)
	mat.set_shader_param("mip_lod", mip_lod)
	mat.set_shader_param("vertex_scale", Vector2((tsize.x + 2.0 * blur_vp) / tsize.x, (tsize.y + 2.0 * blur_vp) / tsize.y))
	mat.set_shader_param("blur_steps", REALISTIC_BLUR_STEPS)
	mat.set_shader_param("blur_quality", REALISTIC_BLUR_QUALITY)

# === Mode LIVE : viewport persistant échantillonné DIRECTEMENT (pas de readback) ===
# Pendant l'édition interactive d'un path, le flou se recalcule en direct sur GPU à
# chaque frame (viewport UPDATE_ALWAYS, sa ViewportTexture est la texture du Sprite).
# Au repos (stabilisé), _process_realistic_live_settle() convertit en texture
# statique MIPMAPPÉE (qualité pleine) et libère le viewport. Compromis : une
# ViewportTexture n'a pas de mips -> trous radiaux possibles à très fort flou en
# DIRECT seulement (le bake statique de stabilisation les supprime).

# Taille de texture fixe pour le live : besoin courant + marge, bornée au plafond.
# Évite de resizer le viewport à chaque frame (source de décalages de rendu).
func _live_tsize_for(needed: Vector2) -> Vector2:
	return Vector2(min(ceil(needed.x * REALISTIC_LIVE_HEADROOM), REALISTIC_VP_MAX_DIM), min(ceil(needed.y * REALISTIC_LIVE_HEADROOM), REALISTIC_VP_MAX_DIM))

func _start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge = null, radial = null):
	var g = _compute_realistic_geom(line, bulge, radial)
	if g == null:
		return
	var nid = path.get_instance_id()
	var scale_f = g["scale_f"]
	var center = g["base_pos"]
	var needed = g["content"] * scale_f
	var tsize = _live_tsize_for(needed)
	var vp = Viewport.new()
	vp.size = tsize
	vp.transparent_bg = true
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.render_target_v_flip = true   # échantillonnage shader direct droit (comme le flip_y du bake statique)
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS

	# Contenu CENTRÉ dans la texture fixe : la copie est positionnée pour que le
	# centre de la bbox tombe au centre de la texture (T/2). La taille restant fixe,
	# pas de resize par frame -> rendu stable.
	# Boucle+radial : la copie échantillonne le bitmap naturel (tiling exact de DD)
	# mis en cache, au lieu de la texture du path en arc-longueur.
	var loop_nat = _loop_nat_tex.get(nid) if (radial != null and _is_line_closed(line) and _loop_nat_valid(nid, line)) else null
	var copy = _new_realistic_copy(line, radial, true, loop_nat)
	_apply_bake_copy_props(copy, line, scale_f, bulge, radial, loop_nat)
	copy.position = tsize * 0.5 - center * scale_f
	vp.add_child(copy)
	# Crop at Center et/ou Crop Ends : masque persistant (UPDATE_ALWAYS) aligné sur le
	# viewport de session.
	var _side_crop = _path_crop_on(radial, blur_px)
	var _ends_crop = _path_ends_on(path, blur_px, _is_line_closed(line))
	var mvp = null
	var mcont = null
	var mtex = null
	if _side_crop or _ends_crop:
		var mpts = line.points
		if bulge != null:
			mpts = _bulge_disp_from(mpts, bulge)
		var mres = _make_path_crop_viewport(vp, scale_f, tsize * 0.5 - center * scale_f, mpts,
			int(radial.get("dir")) if radial != null else ShadowDirection.BOTH,
			_path_crop_reach(blur_px, line.width),
			_is_line_closed(line), true, Viewport.UPDATE_ALWAYS, _side_crop, _ends_crop, line)
		mvp = mres[0]
		mcont = mres[1]
		mtex = mvp.get_texture()
		mtex.flags = Texture.FLAG_FILTER
	line.add_child(vp)

	var vtex = vp.get_texture()
	vtex.flags = Texture.FLAG_FILTER   # filtrage lisse (pas de mips sur un ViewportTexture)

	var spr = Sprite.new()
	spr.name = "DropShadowRealistic"
	spr.texture = vtex
	spr.centered = true
	spr.scale = Vector2(1.0 / scale_f, 1.0 / scale_f)
	spr.position = center + offset
	spr.z_as_relative = true
	spr.set_meta("ds_scale", scale_f)
	spr.set_meta("base_pos", center)
	spr.set_meta("tsize", tsize)
	var mat = ShaderMaterial.new()
	mat.shader = _get_realistic_vp_blur_shader()
	_apply_realistic_blur_params(mat, tsize, blur_px, scale_f, shadow_color, opacity)
	_apply_path_crop_params(mat, mtex)
	mat.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	spr.material = mat
	if behind_layer:
		spr.z_index = -1
		spr.show_behind_parent = false
	else:
		spr.show_behind_parent = true

	line.add_child(spr)
	var old_nodes = path.get_meta(SHADOW_META_KEY) if path.has_meta(SHADOW_META_KEY) else null
	path.set_meta(SHADOW_META_KEY, [spr])
	_free_shadow_nodes(old_nodes)
	_realistic_live[nid] = {"vp": vp, "copy": copy, "sprite": spr, "converting": false, "color": shadow_color, "opacity": opacity, "blur_px": blur_px, "offset": offset, "behind": behind_layer, "scale_f": scale_f, "tsize": tsize, "center": center, "bulge": bulge, "radial": radial, "loop": loop_nat != null, "mvp": mvp, "mcont": mcont}

func _update_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge = null, radial = null):
	var nid = path.get_instance_id()
	var sess = _realistic_live.get(nid)
	if sess == null or not is_instance_valid(sess["vp"]) or not is_instance_valid(sess["copy"]) or not is_instance_valid(sess["sprite"]):
		_teardown_realistic_live(nid)
		_start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		return
	sess["converting"] = false   # une nouvelle édition annule toute conversion en cours
	# Le type de copie (Line2D vs ruban Mesh) dépend de l'activation du radial/side
	# balance. S'il change, on recrée la session avec le bon type.
	var needs_mesh = radial != null
	var has_mesh = not (sess["copy"] is Line2D)
	if needs_mesh != has_mesh:
		_teardown_realistic_live(nid)
		_start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		return
	# Boucle : si le bitmap naturel n'est plus valide (path remodelé), on recapture via
	# la coroutine plutôt que d'échantillonner un cache périmé.
	var is_loop = sess.get("loop", false)
	if is_loop and not _loop_nat_valid(nid, line):
		_teardown_realistic_live(nid)
		var gen2 = _realistic_gen.get(nid, 0) + 1
		_realistic_gen[nid] = gen2
		_create_realistic_loop(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen2, radial)
		return
	var loop_nat = _loop_nat_tex.get(nid) if is_loop else null
	sess["color"] = shadow_color
	sess["opacity"] = opacity
	sess["blur_px"] = blur_px
	sess["offset"] = offset
	sess["behind"] = behind_layer
	sess["bulge"] = bulge
	sess["radial"] = radial
	var g = _compute_realistic_geom(line, bulge, radial)
	if g == null:
		return
	# FRAME-LOCK : le cadre du viewport (centre + taille) ne bouge que quand la
	# géométrie en SORT. Recadrer à chaque édition déplaçait le sprite immédiatement
	# alors que la texture affichée a une frame de retard -> ombre décalée/coupée
	# pendant les tracés rapides, qui "revenait en place" au repos.
	var center = sess.get("center", g["base_pos"])
	var scale_f = sess["scale_f"]
	# Ré-échantillonne uniquement si le contenu dépasse le plafond à l'échelle courante.
	var big = max(g["content"].x, g["content"].y)
	if big * scale_f > REALISTIC_VP_MAX_DIM:
		scale_f = REALISTIC_VP_MAX_DIM / big
		sess["scale_f"] = scale_f
	var needed = g["content"] * scale_f
	var vp = sess["vp"]
	var tsize = sess["tsize"]
	# Le contenu tient-il dans le cadre verrouillé (marge de sécurité 1px monde) ?
	var half_frame = tsize / (2.0 * scale_f)
	var drift = g["base_pos"] - center
	var fits = abs(drift.x) + g["content"].x * 0.5 <= half_frame.x - 1.0
	fits = fits and abs(drift.y) + g["content"].y * 0.5 <= half_frame.y - 1.0
	if not fits:
		# Re-cadrage : centre sur la bbox courante, taille avec marge d'avance, jamais
		# rétrécie en cours de session. Le viewport ne rendra le NOUVEAU cadrage qu'à la
		# frame suivante, alors que sprite/copie sont reconfigurés tout de suite -> on
		# CACHE le sprite pendant cette frame de latence (micro-blink au lieu d'une
		# frame d'ombre décalée/coupée à chaque refit pendant un tracé rapide).
		center = g["base_pos"]
		sess["center"] = center
		var nts = _live_tsize_for(needed)
		tsize = Vector2(max(tsize.x, nts.x), max(tsize.y, nts.y))
		sess["tsize"] = tsize
		vp.size = tsize
		sess["sprite"].visible = false
		sess["refit_frame"] = Engine.get_frames_drawn()
	var copy = sess["copy"]
	_apply_bake_copy_props(copy, line, scale_f, bulge, radial, loop_nat)
	copy.position = tsize * 0.5 - center * scale_f
	# Crop at Center / Crop Ends : synchronise le masque avec l'état courant.
	var crop_on = _path_crop_on(radial, blur_px)
	var ends_on = _path_ends_on(path, blur_px, _is_line_closed(line))
	var need_mask = crop_on or ends_on
	var mvp = sess.get("mvp")
	var mcont = sess.get("mcont")
	if need_mask and (mvp == null or not is_instance_valid(mvp) or mcont == null or not is_instance_valid(mcont)):
		# Masque absent de cette session (ex. Both -> Side, ou crop coché en cours de
		# session) : redémarre la session avec le masque.
		_teardown_realistic_live(nid)
		_start_realistic_live(path, line, offset, shadow_color, opacity, behind_layer, blur_px, bulge, radial)
		return
	if not need_mask and mvp != null and is_instance_valid(mvp):
		mvp.queue_free()
		sess["mvp"] = null
		sess["mcont"] = null
		if sess["sprite"].material is ShaderMaterial:
			sess["sprite"].material.set_shader_param("crop_enabled", 0.0)
	elif need_mask:
		mvp.size = tsize
		for mc in mcont.get_children():
			mcont.remove_child(mc)
			mc.free()
		mcont.scale = Vector2(scale_f, scale_f)
		mcont.position = tsize * 0.5 - center * scale_f
		var mpts = line.points
		if bulge != null:
			mpts = _bulge_disp_from(mpts, bulge)
		if crop_on:
			_populate_path_crop(mcont, mpts, int(radial.get("dir")), _is_line_closed(line), _path_crop_reach(blur_px, line.width))
		if ends_on:
			_populate_path_end_crop(mcont, mpts, _path_crop_reach(blur_px, line.width), line)
	var spr = sess["sprite"]
	var vtex = vp.get_texture()
	vtex.flags = Texture.FLAG_FILTER
	spr.texture = vtex
	spr.scale = Vector2(1.0 / scale_f, 1.0 / scale_f)
	spr.position = center + offset
	spr.set_meta("ds_scale", scale_f)
	spr.set_meta("base_pos", center)
	spr.set_meta("tsize", tsize)
	_apply_realistic_blur_params(spr.material, tsize, blur_px, scale_f, shadow_color, opacity)
	spr.material.set_shader_param("alpha_gain", _crop_alpha_gain(radial))
	if behind_layer:
		spr.z_index = -1
		spr.show_behind_parent = false
	else:
		spr.z_index = 0
		spr.show_behind_parent = true

func _teardown_realistic_live(nid):
	var sess = _realistic_live.get(nid)
	if sess == null:
		return
	if is_instance_valid(sess["vp"]):
		sess["vp"].queue_free()
	_realistic_live.erase(nid)

# Convertit les sessions live stabilisées (plus d'édition depuis SETTLE_MS) en
# texture statique mipmappée. Appelé à chaque tick monitor.
func _process_realistic_live_settle():
	if _realistic_live.empty():
		return
	var now = OS.get_ticks_msec()
	for nid in _realistic_live.keys():
		var sess = _realistic_live[nid]
		# Fin de refit : le viewport a re-rendu au nouveau cadrage -> réaffiche le sprite.
		if sess.has("refit_frame"):
			if Engine.get_frames_drawn() > sess["refit_frame"]:
				if is_instance_valid(sess["sprite"]):
					sess["sprite"].visible = true
				sess.erase("refit_frame")
		if sess["converting"]:
			continue
		if now - _realistic_last_req.get(nid, 0) < REALISTIC_LIVE_SETTLE_MS:
			continue
		var path = instance_from_id(nid)
		if path == null or not is_instance_valid(path):
			_teardown_realistic_live(nid)
			continue
		var line = get_line2d(path)
		if line == null:
			_teardown_realistic_live(nid)
			continue
		sess["converting"] = true
		var gen = _realistic_gen.get(nid, 0) + 1
		_realistic_gen[nid] = gen
		_convert_realistic_live_to_static(nid, path, line, sess["offset"], sess["color"], sess["opacity"], sess["behind"], sess["blur_px"], gen, sess.get("bulge"), sess.get("radial"))

# Bake statique (swap atomique) puis libération du viewport live, une fois le static
# prêt. Si une nouvelle édition survient (gen changé), la conversion est annulée et
# la session live conservée.
func _convert_realistic_live_to_static(nid, path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, bulge = null, radial = null):
	# Boucle+radial : le static doit refaire l'ombre via la coroutine boucle (mesh qui
	# échantillonne le bitmap naturel), pas le bake arc-longueur des paths ouverts.
	if radial != null and bulge == null and _is_line_closed(line):
		_create_realistic_loop(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, radial)
	else:
		_create_realistic_blurred(path, line, offset, shadow_color, opacity, behind_layer, blur_px, gen, bulge, radial)
	yield(global.Editor.get_tree(), "idle_frame")
	yield(global.Editor.get_tree(), "idle_frame")
	yield(global.Editor.get_tree(), "idle_frame")
	if _realistic_gen.get(nid, -1) != gen:
		# Conversion annulée par une nouvelle édition : on garde le live.
		if _realistic_live.has(nid):
			_realistic_live[nid]["converting"] = false
		return
	# Static en place (sa sprite a remplacé la live via le swap) -> libère le viewport.
	_teardown_realistic_live(nid)

# Lit le décalage de texture (start_point) et le flip vertical éventuellement
# posés sur le matériau du path par un mod tiers (ModifyPaths/universalshader).
# Renvoie [start_point, path_flip_vertical]. On lit le matériau -> indépendant du
# mod : si la propriété n'existe pas, valeurs neutres (0, false).
# Lit les paramètres de rendu posés sur le matériau du path par un mod tiers
# (ModifyPaths/universalshader) : décalage de texture (start_point), flip vertical,
# et fondu d'extrémités (FadeIn/FadeOut + path_length_in_uv + fade_distance). On lit
# le matériau -> indépendant du mod : propriété absente = valeur neutre.
func _get_path_shader_params(line) -> Dictionary:
	var p = {"sp": 0.0, "flip": false, "fade_in": false, "fade_out": false, "plu": 0.0, "fdist": 10.0}
	if line != null and line.material is ShaderMaterial:
		var m = line.material
		var v = m.get_shader_param("start_point")
		if v != null:
			p["sp"] = float(v)
		var f = m.get_shader_param("path_flip_vertical")
		if f != null:
			p["flip"] = bool(f)
		var fi = m.get_shader_param("FadeIn")
		if fi != null:
			p["fade_in"] = bool(fi)
		var fo = m.get_shader_param("FadeOut")
		if fo != null:
			p["fade_out"] = bool(fo)
		var pl = m.get_shader_param("path_length_in_uv")
		if pl != null:
			p["plu"] = float(pl)
		var fd = m.get_shader_param("fade_distance")
		if fd != null:
			p["fdist"] = float(fd)
	return p

# Vrai si un effet shader d'extrémité/texture est actif (déclenche l'usage du shader
# passthrough au bake et le hash de détection).
func _path_has_shader_effect(p: Dictionary) -> bool:
	return p["sp"] > 0.0005 or p["flip"] or p["fade_in"] or p["fade_out"]

# Shader passthrough pour le bake flou : applique le même décalage de phase, flip et
# fondu d'extrémités (FadeIn/FadeOut + fade_distance) que le path AVANT la
# rasterisation -> la silhouette bakée colle au rendu. Préserve gradient via * COLOR.
func _get_realistic_bake_offset_shader() -> Shader:
	if _realistic_bake_offset_shader != null:
		return _realistic_bake_offset_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float start_point = 0.0;
uniform bool path_flip_vertical = false;
uniform bool FadeIn = false;
uniform bool FadeOut = false;
uniform float path_length_in_uv = 0.0;
uniform float fade_distance = 10.0;
uniform bool bulge_active = false;
uniform vec2 bulge_offset = vec2(0.0);
uniform float bulge_entry = 0.0;
uniform float bulge_exit = 1.0;
uniform bool bulge_entry_active = true;
uniform float bulge_entry_len = 0.3;
uniform bool bulge_entry_smooth = true;
uniform bool bulge_exit_active = true;
uniform float bulge_exit_len = 0.3;
uniform bool bulge_exit_smooth = true;
float bulge_m(float t) {
	float rise = 1.0;
	if (bulge_entry_active) {
		float xr = clamp((t - bulge_entry) / max(bulge_entry_len, 0.0001), 0.0, 1.0);
		rise = bulge_entry_smooth ? (xr * xr * xr * (xr * (xr * 6.0 - 15.0) + 10.0)) : xr;
	}
	float fall = 1.0;
	if (bulge_exit_active) {
		float xf = clamp((bulge_exit - t) / max(bulge_exit_len, 0.0001), 0.0, 1.0);
		fall = bulge_exit_smooth ? (xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0)) : xf;
	}
	return rise * fall;
}
void vertex() {
	// Déplacement par-sommet : t (longueur d'arc 0..1) est encodé dans COLOR.r (gradient).
	if (bulge_active) { VERTEX += bulge_offset * bulge_m(COLOR.r); }
}
void fragment() {
	float orig_x = UV.x;
	vec2 uv = UV;
	if (path_flip_vertical) { uv.y = clamp(1.0 - uv.y, 0.0, 1.0); }
	uv.x = mod(uv.x + start_point, 1.0);
	// Seul l'alpha sert au bake (la teinte vient du shader de flou du Sprite) ; la
	// pollution de COLOR.rgb par la rampe t (accroche) est donc sans effet.
	vec4 c = texture(TEXTURE, uv) * COLOR;
	if (path_length_in_uv > 0.0) {
		float f_dist = 0.01 * fade_distance * path_length_in_uv;
		if (FadeIn && orig_x < f_dist) { c.a *= clamp(orig_x / f_dist, 0.0, 1.0); }
		if (FadeOut && orig_x > path_length_in_uv - f_dist) { c.a *= 1.0 - clamp((orig_x - (path_length_in_uv - f_dist)) / f_dist, 0.0, 1.0); }
	}
	COLOR = c;
}
"""
	_realistic_bake_offset_shader = sh
	return sh

func _get_realistic_tint_shader() -> Shader:
	if _realistic_tint_shader != null:
		return _realistic_tint_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.6;
uniform float start_point = 0.0;          // décalage de phase texture le long du path (cf. universalshader)
uniform bool path_flip_vertical = false;  // flip vertical de la texture du path
uniform bool FadeIn = false;
uniform bool FadeOut = false;
uniform float path_length_in_uv = 0.0;
uniform float fade_distance = 10.0;
uniform bool bulge_active = false;
uniform vec2 bulge_offset = vec2(0.0);
uniform float bulge_entry = 0.0;
uniform float bulge_exit = 1.0;
uniform bool bulge_entry_active = true;
uniform float bulge_entry_len = 0.3;
uniform bool bulge_entry_smooth = true;
uniform bool bulge_exit_active = true;
uniform float bulge_exit_len = 0.3;
uniform bool bulge_exit_smooth = true;
float bulge_m(float t) {
	float rise = 1.0;
	if (bulge_entry_active) {
		float xr = clamp((t - bulge_entry) / max(bulge_entry_len, 0.0001), 0.0, 1.0);
		rise = bulge_entry_smooth ? (xr * xr * xr * (xr * (xr * 6.0 - 15.0) + 10.0)) : xr;
	}
	float fall = 1.0;
	if (bulge_exit_active) {
		float xf = clamp((bulge_exit - t) / max(bulge_exit_len, 0.0001), 0.0, 1.0);
		fall = bulge_exit_smooth ? (xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0)) : xf;
	}
	return rise * fall;
}
void vertex() {
	// Déplacement par-sommet : t encodé dans COLOR.r (gradient). Avec accroche, le
	// gradient vanilla (et donc le fondu COLOR.a) est remplacé par la rampe t.
	if (bulge_active) { VERTEX += bulge_offset * bulge_m(COLOR.r); }
}
void fragment() {
	float vcol_a = COLOR.a;   // alpha du gradient vanilla (1 si neutralisé / universalshader actif / accroche)
	float orig_x = UV.x;
	vec2 uv = UV;
	if (path_flip_vertical) { uv.y = clamp(1.0 - uv.y, 0.0, 1.0); }
	uv.x = mod(uv.x + start_point, 1.0);
	float a = texture(TEXTURE, uv).a * vcol_a;
	if (path_length_in_uv > 0.0) {
		float f_dist = 0.01 * fade_distance * path_length_in_uv;
		if (FadeIn && orig_x < f_dist) { a *= clamp(orig_x / f_dist, 0.0, 1.0); }
		if (FadeOut && orig_x > path_length_in_uv - f_dist) { a *= 1.0 - clamp((orig_x - (path_length_in_uv - f_dist)) / f_dist, 0.0, 1.0); }
	}
	if (a < 0.01) { discard; }
	COLOR = vec4(shadow_color.rgb, a * shadow_strength);
}
"""
	_realistic_tint_shader = sh
	return sh

func _get_realistic_vp_blur_shader() -> Shader:
	if _realistic_vp_shader != null:
		return _realistic_vp_shader
	var sh = Shader.new()
	sh.code = """
shader_type canvas_item;
uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.6;
uniform vec2 texel = vec2(1.0);          // 1 / taille texture (px)
uniform float blur_px = 0.0;             // rayon de flou en texels
uniform float mip_lod = 0.0;
uniform vec2 vertex_scale = vec2(1.0);   // agrandissement du quad pour loger le halo
uniform int blur_steps = 24;             // nb d'angles du noyau polaire
uniform int blur_quality = 8;            // nb d'anneaux radiaux
uniform float crop_enabled = 0.0;        // Crop Blur (Side A/B) : discard là où crop_mask est opaque
uniform sampler2D crop_mask;
uniform float alpha_gain = 1.0;          // compensation Side sans crop (demi-silhouette) ; clampé à 1

varying vec2 v_scale;

void vertex() {
	v_scale = vertex_scale;
	VERTEX *= mat2(vec2(v_scale.x, 0.0), vec2(0.0, v_scale.y));
}

// Alpha de la source ; 0 hors texture (la texture est serrée, le halo déborde
// dans le quad agrandi -> on ne veut NI répétition NI bord étiré). TEXTURE est
// passé en paramètre car un built-in n'est pas accessible dans une fonction custom.
float samp(sampler2D tex, vec2 p) {
	if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) { return 0.0; }
	return textureLod(tex, p, mip_lod).a;
}

void fragment() {
	// Remappe l'UV du quad agrandi vers la texture (centrée) ; hors [0,1] = halo.
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
	// Noyau POLAIRE (anneaux concentriques) : pas de grille carrée -> pas de carrés
	// sur les bords droits/45°. Poids gaussien doux (cf. shader des objets).
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
	return sh

func remove_shadow(path):
	if path == null or not is_instance_valid(path):
		return
	# Invalide toute capture realistic asynchrone encore en attente sur ce path.
	var nid = path.get_instance_id()
	if _realistic_gen.has(nid):
		_realistic_gen[nid] = _realistic_gen[nid] + 1
	# Libère le viewport d'une éventuelle session live (sa sprite est dans le meta,
	# libérée plus bas avec les autres nœuds d'ombre).
	_teardown_realistic_live(nid)
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
			load_overlay_ui_from_path(node)
			return

	reset_ui_to_defaults()

func _reparent_ui_to_node(node):
	var container = ui_config.get("container")
	if container == null:
		return
	var target_parent = ui_config.get("_path_parent")
	if target_parent == null:
		return
	if container.get_parent() == target_parent:
		_update_transition_visibility("paths")
		return
	if container.get_parent() != null:
		container.get_parent().remove_child(container)
	target_parent.add_child(container)
	target_parent.move_child(container, 0)
	_update_transition_visibility("paths")

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
	# Hide entire transitions section for walls and closed paths (loops have no ends)
	# + en mode Realistic (la silhouette texturée gère fondus/grow via le path).
	var is_realistic = (_get_selected_render_mode() == "realistic")
	var hide_transitions = is_wall or closed or is_realistic
	if ui_config.has("sec_transitions_sep"):
		ui_config["sec_transitions_sep"].visible = not hide_transitions
	if ui_config.has("sec_transitions_header"):
		ui_config["sec_transitions_header"].visible = not hide_transitions
	if ui_config.has("sec_transitions_content"):
		if hide_transitions:
			ui_config["sec_transitions_content"].visible = false
		# For open paths: don't force visible, let the cog toggle control it
	# Hide extend for closed paths/walls (loops have no ends to extend) ou en Realistic
	if closed or is_realistic:
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
	# For paths: update fade row visibility based on extend state and extend_which
	if not is_wall:
		var ext_on = ui_config["extend_check"].pressed
		if ext_on:
			_update_fade_visibility_for_extend_which()
		else:
			if ui_config.has("fade_in_hbox"):
				ui_config["fade_in_hbox"].visible = true
			if ui_config.has("fade_out_hbox"):
				ui_config["fade_out_hbox"].visible = true

func load_shadow_ui_from_path(path):
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
		"swap_ends_check", "skip_portals_check", "behind_layer_check", "shadow_color_picker",
		"mode_btn_0", "mode_btn_1", "realistic_blur_slider", "realistic_blur_spin",
		"bulge_enabled_check", "bulge_link_btn",
		"bulge_entry_slider", "bulge_entry_spin", "bulge_exit_slider", "bulge_exit_spin",
		"bulge_entry_active_check", "bulge_exit_active_check",
		"bulge_entry_len_slider", "bulge_entry_len_spin",
		"bulge_exit_len_slider", "bulge_exit_len_spin",
		"bulge_ramp_slider", "bulge_ramp_spin", "bulge_ramp_link_btn",
		"bulge_entry_smooth_check", "bulge_exit_smooth_check",
		"bulge_smooth_check", "bulge_smooth_link_btn",
		"bulge_distance_slider", "bulge_distance_spin",
		"bulge_angle_slider", "bulge_angle_spin"]
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
	var cfg_blur = config.get("realistic_blur", DEFAULT_SHADOW_CONFIG.get("realistic_blur", 0.0))
	if ui_config.has("realistic_blur_slider"):
		ui_config["realistic_blur_slider"].value = cfg_blur
	if ui_config.has("realistic_blur_spin"):
		ui_config["realistic_blur_spin"].value = cfg_blur
	# Bulge
	if ui_config.has("bulge_enabled_check"):
		ui_config["bulge_enabled_check"].pressed = config.get("bulge_enabled", DEFAULT_SHADOW_CONFIG.get("bulge_enabled", false))
	if ui_config.has("bulge_link_btn"):
		ui_config["bulge_link_btn"].pressed = config.get("bulge_link", DEFAULT_SHADOW_CONFIG.get("bulge_link", true))
	if ui_config.has("bulge_entry_active_check"):
		ui_config["bulge_entry_active_check"].pressed = config.get("bulge_entry_active", DEFAULT_SHADOW_CONFIG.get("bulge_entry_active", true))
	if ui_config.has("bulge_exit_active_check"):
		ui_config["bulge_exit_active_check"].pressed = config.get("bulge_exit_active", DEFAULT_SHADOW_CONFIG.get("bulge_exit_active", true))
	if ui_config.has("bulge_ramp_link_btn"):
		ui_config["bulge_ramp_link_btn"].pressed = config.get("bulge_ramp_link", DEFAULT_SHADOW_CONFIG.get("bulge_ramp_link", true))
	if ui_config.has("bulge_smooth_link_btn"):
		ui_config["bulge_smooth_link_btn"].pressed = config.get("bulge_smooth_link", DEFAULT_SHADOW_CONFIG.get("bulge_smooth_link", true))
	var cfg_esm = config.get("bulge_entry_smooth", DEFAULT_SHADOW_CONFIG.get("bulge_entry_smooth", true))
	var cfg_xsm = config.get("bulge_exit_smooth", DEFAULT_SHADOW_CONFIG.get("bulge_exit_smooth", true))
	if ui_config.has("bulge_entry_smooth_check"):
		ui_config["bulge_entry_smooth_check"].pressed = cfg_esm
	if ui_config.has("bulge_exit_smooth_check"):
		ui_config["bulge_exit_smooth_check"].pressed = cfg_xsm
	if ui_config.has("bulge_smooth_check"):
		ui_config["bulge_smooth_check"].pressed = cfg_esm
	var cfg_bentry = config.get("bulge_entry", DEFAULT_SHADOW_CONFIG.get("bulge_entry", 0.0))
	if ui_config.has("bulge_entry_slider"):
		ui_config["bulge_entry_slider"].value = cfg_bentry
	if ui_config.has("bulge_entry_spin"):
		ui_config["bulge_entry_spin"].value = cfg_bentry
	var cfg_bexit = config.get("bulge_exit", DEFAULT_SHADOW_CONFIG.get("bulge_exit", 1.0))
	if ui_config.has("bulge_exit_slider"):
		ui_config["bulge_exit_slider"].value = cfg_bexit
	if ui_config.has("bulge_exit_spin"):
		ui_config["bulge_exit_spin"].value = cfg_bexit
	var cfg_belen = config.get("bulge_entry_len", DEFAULT_SHADOW_CONFIG.get("bulge_entry_len", 0.3))
	if ui_config.has("bulge_entry_len_slider"):
		ui_config["bulge_entry_len_slider"].value = cfg_belen
	if ui_config.has("bulge_entry_len_spin"):
		ui_config["bulge_entry_len_spin"].value = cfg_belen
	var cfg_bxlen = config.get("bulge_exit_len", DEFAULT_SHADOW_CONFIG.get("bulge_exit_len", 0.3))
	if ui_config.has("bulge_exit_len_slider"):
		ui_config["bulge_exit_len_slider"].value = cfg_bxlen
	if ui_config.has("bulge_exit_len_spin"):
		ui_config["bulge_exit_len_spin"].value = cfg_bxlen
	if ui_config.has("bulge_ramp_slider"):
		ui_config["bulge_ramp_slider"].value = cfg_belen
	if ui_config.has("bulge_ramp_spin"):
		ui_config["bulge_ramp_spin"].value = cfg_belen
	var cfg_bdist = config.get("bulge_distance", DEFAULT_SHADOW_CONFIG.get("bulge_distance", 0.0))
	if ui_config.has("bulge_distance_slider"):
		ui_config["bulge_distance_slider"].value = cfg_bdist
	if ui_config.has("bulge_distance_spin"):
		ui_config["bulge_distance_spin"].value = cfg_bdist
	# Angle affiché : direction de l'offset si lié (grisé), sinon l'angle propre.
	var cfg_bangle = config.get("bulge_angle", DEFAULT_SHADOW_CONFIG.get("bulge_angle", 0.0))
	if config.get("bulge_link", true):
		var ox = config.get("offset_x", 0.0)
		var oy = config.get("offset_y", 0.0)
		if Vector2(ox, oy).length() > 0.5:
			cfg_bangle = rad2deg(atan2(oy, ox))
			if cfg_bangle < 0.0:
				cfg_bangle += 360.0
	if ui_config.has("bulge_angle_slider"):
		ui_config["bulge_angle_slider"].value = cfg_bangle
	if ui_config.has("bulge_angle_spin"):
		ui_config["bulge_angle_spin"].value = cfg_bangle
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
	var cfg_snap = config.get("snap_angle", DEFAULT_SHADOW_CONFIG["snap_angle"])
	if ui_config.has("dial"):
		ui_config["dial"].set_meta("snap_angle", cfg_snap)
	_deactivate_all_snaps()
	if cfg_snap >= 0.0:
		var snap_angles_map = {"snap_45": 45.0, "snap_135": 135.0, "snap_225": 225.0, "snap_315": 315.0}
		for snap_key in snap_angles_map.keys():
			if ui_config.has(snap_key) and abs(snap_angles_map[snap_key] - cfg_snap) < 0.5:
				ui_config[snap_key].pressed = true
	var dir = int(config.get("direction", DEFAULT_SHADOW_CONFIG["direction"]))
	_set_direction_buttons(dir)
	_set_render_mode_buttons(_render_mode_to_index(config.get("render_mode", DEFAULT_SHADOW_CONFIG.get("render_mode", "simple"))))

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
	ui_config["behind_layer_check"].pressed = config.get("behind_layer", DEFAULT_SHADOW_CONFIG.get("behind_layer", false))
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

	# Visibilité des contrôles d'accroche (profil/longueur selon l'état)
	_update_bulge_visibility()

	# Hide transitions section and copy/paste for walls
	_update_wall_ui_visibility()

	# The previous selection's saved snapshot doesn't belong to this path —
	# drop it. _legacy_extend_transitions_cleanup will repopulate if needed.
	_saved_transitions_state.clear()
	# If saved data has both groups active (legacy from before the switch
	# behaviour), snapshot the transitions and prefer extend.
	_legacy_extend_transitions_cleanup()

	_syncing_ui = false

func _update_wall_ui_visibility():
	_update_transition_visibility(_monitored_type)

func reset_ui_to_defaults():
	set_ui_without_signals(DEFAULT_SHADOW_CONFIG)
	# Also reset overlay UI
	_syncing_ui = true
	if overlay_ui.has("enable_check"):
		overlay_ui["enable_check"].pressed = false
	if overlay_ui.has("settings_panel"):
		overlay_ui["settings_panel"].visible = false
	if overlay_ui.has("reset_btn"):
		overlay_ui["reset_btn"].visible = false
	_syncing_ui = false
	# Drop any leftover transitions snapshot from the previous selection.
	_saved_transitions_state.clear()

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

func _style_apply_dialog(timer: Timer):
	timer.queue_free()
	var dialog = ui_config.get("apply_all_dialog")
	if dialog == null:
		return
	# Hide the default (empty) dialog_text label — we use our own in the VBoxContainer
	for child in dialog.get_children():
		if child is Label and child.text == "":
			child.visible = false
	# Set scope radio icons (needs theme to be inherited first)
	_update_scope_radio_icons(1)

func _on_apply_all_confirmed(mode = "all"):
	ui_config["apply_all_dialog"].hide()
	var cfg = get_current_shadow_config()
	cfg["enabled"] = true
	var count = 0
	_history_begin_manual("apply_all")

	# "Selected paths" mode — apply to current selection only
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
		outputlog("Applied shadow to " + str(count) + " selected paths", 0)
		_history_flush()
		return

	# Determine layer scope: 0=all, 1=current, 2=filtered
	var scope = _get_selected_scope()
	var scope_names = ["all_layers", "current_layer", "filtered_layers"]
	var scope_name = scope_names[scope]

	var containers = _get_path_containers_for_scope(scope)
	if containers.size() == 0:
		outputlog("apply_all: no path containers found for scope " + scope_name, 0)
		_history_flush()
		return

	var only_without_shadow = (mode == "no_shadow")
	var scope_z_filter = ui_config.get("_scope_z_filter", null)
	var scope_layer_filter = ui_config.get("_scope_layer_filter", null)
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
						if scope_layer_filter.has(obj.z_index) and not scope_layer_filter[obj.z_index]:
							continue
						if not scope_layer_filter.has(obj.z_index):
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
	outputlog("Applied shadow to " + str(count) + " paths (mode: " + str(mode) + ", scope: " + scope_name + z_info + ")", 0)
	ui_config.erase("_scope_z_filter")
	ui_config.erase("_scope_layer_filter")
	_history_flush()

func _get_path_containers_for_scope(scope: int) -> Array:
	"""Return Pathways containers based on the chosen layer scope.
	0 = all layers, 1 = current layer (same z_index), 2 = filtered layers."""
	var containers = []

	# Collect all Pathways containers across all levels
	var all_path_containers = []
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
				if child.name == "Pathways":
					all_path_containers.append(child)
					break

	if scope == 0:
		return all_path_containers

	if scope == 1:
		# Current layer = same z_index as selected path
		var target_z = 0
		if _monitored_path != null and is_instance_valid(_monitored_path):
			target_z = _monitored_path.z_index
		ui_config["_scope_z_filter"] = target_z
		outputlog("scope=current_layer target_z=" + str(target_z), 0)
		return all_path_containers

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
		return all_path_containers

	return containers

func apply_saved_shadows_to_map():

	outputlog("apply_saved_shadows_to_map", 1)

	if global.ModMapData.has(SHADOW_DATA_KEY):
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
	
	# Also restore overlay shadows
	if global.ModMapData.has(OVERLAY_DATA_KEY):
		var overlay_data = global.ModMapData[OVERLAY_DATA_KEY]
		var ov_count = 0
		for node_id in overlay_data.keys():
			if global.World.HasNodeID(node_id):
				var node = global.World.GetNodeByID(node_id)
				if is_shadow_node_type(node):
					var config = overlay_data[node_id]
					_known_node_ids[node_id] = true
					_all_known_path_ids[node_id] = true
					if not _all_points_hashes.has(node_id):
						_all_points_hashes[node_id] = _get_points_hash(node)
					if config.get("enabled", false):
						remove_overlay_shadow(node)
						create_overlay_shadow(node, config)
						ov_count += 1
			else:
				overlay_data.erase(node_id)
		if ov_count > 0:
			outputlog("Applied overlay shadows to " + str(ov_count) + " paths", 0)

#########################################################################################################
##
## SHADOW OVERLAY
##
#########################################################################################################

var _overlay_shader = null
var _realistic_shader = null
var _realistic_tint_shader = null
var _realistic_vp_shader = null
var _realistic_gen = {}  # instance_id du path -> génération de capture (annule les yields obsolètes)
var _realistic_bake_offset_shader = null  # cache du shader passthrough d'offset (bake flou)
var _realistic_live = {}        # instance_id -> {vp, copy, sprite, converting, color, opacity, blur_px, offset, behind} (session live)
var _realistic_last_req = {}    # instance_id -> dernier ms de (re)build flou (déclenche live / settle)
var _loop_nat_tex = {}          # instance_id -> {tex, sig, origin, content} : bitmap naturel caché (boucle)
var _loop_capturing = {}        # instance_id -> en cours de capture du bitmap naturel





# Signature légère du path pour invalider le cache du bitmap naturel quand sa forme,
# sa texture ou sa largeur change (les éditions radial/offset/couleur ne la changent pas).
func _loop_sig(line):
	var pts = line.points
	var n = pts.size()
	return [n, pts[0] if n > 0 else Vector2.ZERO, pts[n - 1] if n > 0 else Vector2.ZERO, line.width, line.texture]

# Cache valide pour ce path (boucle) ?
func _loop_nat_valid(nid, line) -> bool:
	if not _loop_nat_tex.has(nid):
		return false
	var e = _loop_nat_tex[nid]
	if not is_instance_valid(e["tex"]):
		return false
	return e["sig"] == _loop_sig(line)
var _mip_tex_cache = {}  # RID source (id) -> ImageTexture mipmappée (pour le flou realistic)

func _get_overlay_shader() -> Shader:
	if _overlay_shader != null:
		return _overlay_shader
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float max_opacity : hint_range(0.0, 1.0) = 0.5;
uniform int direction = 2;  // 0=Side A, 1=Side B, 2=Both
uniform int axis = 0;       // 0=Horizontal (le long du path, UV.x), 1=Vertical (hauteur du trait, UV.y)
uniform float fade_length : hint_range(0.01, 1.0) = 0.5;
uniform float uv_max = 1.0;  // max UV.x value (for tiled textures)
// Compatibilité ModifyPaths/universalshader : on réplique les transformations que le
// mod impose au path pour que le masque de l'overlay colle au rendu réel.
uniform float start_point = 0.0;          // décalage de phase texture le long du path
uniform bool path_flip_vertical = false;  // flip vertical de la texture
uniform bool FadeIn = false;              // transition d'entrée
uniform bool FadeOut = false;             // transition de sortie
uniform float path_length_in_uv = 0.0;    // longueur du path en UV (0 = pas de fondus)
uniform float fade_distance = 10.0;       // distance de transition

void fragment() {
	// Échantillonnage texture AVEC les transformations ModifyPaths (offset + flip) ->
	// le masque (tex.a) correspond aux pixels réellement visibles du path modifié.
	float orig_x = UV.x;
	vec2 suv = UV;
	if (path_flip_vertical) { suv.y = clamp(1.0 - suv.y, 0.0, 1.0); }
	suv.x = mod(suv.x + start_point, 1.0);
	vec4 tex = texture(TEXTURE, suv);
	if (tex.a < 0.01) {
		discard;
	}
	
	// Axe du fondu de l'overlay : longueur du path (UV.x, normalisé par le tiling) ou
	// hauteur du trait (UV.y, déjà 0..1 sur la largeur). Position GÉOMÉTRIQUE -> non
	// affectée par le décalage de texture (start_point ne déplace pas la géométrie).
	float t = axis == 1 ? UV.y : UV.x / uv_max;
	t = clamp(t, 0.0, 1.0);
	float alpha = 0.0;
	
	if (direction == 0) {
		// Side A: full at t=0, fade to 0
		alpha = t <= fade_length ? 1.0 - t / fade_length : 0.0;
	} else if (direction == 1) {
		// Side B: full at t=1, fade to 0
		float t_end = 1.0 - t;
		alpha = t_end <= fade_length ? 1.0 - t_end / fade_length : 0.0;
	} else {
		// Both: full at both ends
		float half_fade = fade_length * 0.5;
		float a_start = t <= half_fade ? 1.0 - t / half_fade : 0.0;
		float t_end = 1.0 - t;
		float a_end = t_end <= half_fade ? 1.0 - t_end / half_fade : 0.0;
		alpha = max(a_start, a_end);
	}
	
	// Smoothstep
	alpha = alpha * alpha * (3.0 - 2.0 * alpha);
	alpha *= max_opacity;
	
	// Masque = alpha texture * transitions d'extrémité du path (mêmes formules que
	// universalshader) -> l'overlay disparaît là où le path est fondu.
	float mask = tex.a;
	if (path_length_in_uv > 0.0) {
		float f_dist = 0.01 * fade_distance * path_length_in_uv;
		if (FadeIn && orig_x < f_dist) { mask *= clamp(orig_x / f_dist, 0.0, 1.0); }
		if (FadeOut && orig_x > path_length_in_uv - f_dist) { mask *= 1.0 - clamp((orig_x - (path_length_in_uv - f_dist)) / f_dist, 0.0, 1.0); }
	}
	
	COLOR = vec4(shadow_color.rgb, alpha * mask);
}
"""
	_overlay_shader = shader
	return shader

func create_overlay_shadow(path, config: Dictionary):
	"""Create a shadow overlay on top of the path by creating a Line2D copy with a gradient shader."""
	if path == null or not is_instance_valid(path):
		return
	var line = get_line2d(path)
	if line == null:
		return
	if line.points.size() < 2:
		return
	
	remove_overlay_shadow(path)
	
	var opacity = config.get("opacity", 0.5)
	var direction = int(config.get("direction", 2))
	var axis = int(config.get("axis", 0))
	var fade_length = clamp(config.get("fade_length", 0.5), 0.01, 1.0)
	var shadow_color = config.get("shadow_color", Color(0, 0, 0, 1))
	if shadow_color is String:
		shadow_color = Color(shadow_color)
	
	# Create a clean Line2D with the same visual properties (no children copied)
	var overlay_line = Line2D.new()
	overlay_line.name = "ShadowOverlay"
	overlay_line.points = line.points
	overlay_line.width = line.width
	overlay_line.default_color = Color(1, 1, 1, 1)
	overlay_line.texture = line.texture
	overlay_line.texture_mode = line.texture_mode
	overlay_line.joint_mode = line.joint_mode
	overlay_line.begin_cap_mode = line.begin_cap_mode
	overlay_line.end_cap_mode = line.end_cap_mode
	overlay_line.antialiased = line.antialiased
	if line.gradient != null:
		overlay_line.gradient = line.gradient.duplicate()
	overlay_line.show_behind_parent = false
	overlay_line.z_as_relative = true
	overlay_line.z_index = 0
	overlay_line.position = Vector2.ZERO
	
	# Compute UV max: how many times the texture tiles along the path
	var total_length = 0.0
	var pts = line.points
	for i in range(1, pts.size()):
		total_length += pts[i].distance_to(pts[i - 1])
	var tex_width = 1.0
	if line.texture != null:
		tex_width = line.texture.get_width()
	var uv_max = total_length / tex_width if tex_width > 0 else 1.0
	if uv_max < 0.01:
		uv_max = 1.0
	
	# Paramètres ModifyPaths/universalshader posés sur le matériau du path (décalage,
	# flip, transitions d'entrée/sortie). Neutres si le mod n'est pas actif.
	var sp = _get_path_shader_params(line)
	# path_length_in_uv du mod si présent, sinon notre uv_max calculé (mêmes unités).
	var plu = sp["plu"] if sp["plu"] > 0.0 else uv_max
	
	# Apply shader
	var mat = ShaderMaterial.new()
	mat.shader = _get_overlay_shader()
	mat.set_shader_param("shadow_color", shadow_color)
	mat.set_shader_param("max_opacity", opacity)
	mat.set_shader_param("direction", direction)
	mat.set_shader_param("axis", axis)
	mat.set_shader_param("fade_length", fade_length)
	mat.set_shader_param("uv_max", uv_max)
	mat.set_shader_param("start_point", sp["sp"])
	mat.set_shader_param("path_flip_vertical", sp["flip"])
	mat.set_shader_param("FadeIn", sp["fade_in"])
	mat.set_shader_param("FadeOut", sp["fade_out"])
	mat.set_shader_param("path_length_in_uv", plu)
	mat.set_shader_param("fade_distance", sp["fdist"])
	overlay_line.material = mat
	
	line.add_child(overlay_line)
	# Grow/Shrink (ModifyPaths) : largeurs PAR-POINT posées par DD sur le Line2D. Un
	# simple copie de line.width donne un trait uniforme -> on réplique le tapering.
	_apply_overlay_grow_shrink(overlay_line, line)
	path.set_meta(OVERLAY_META_KEY, [overlay_line])

# Réplique le tapering Grow/Shrink de DD (Pathway.GrowShrinkEnds) sur le Line2D de
# l'overlay : largeurs par-point identiques au path -> l'overlay suit l'évasement /
# rétrécissement. Dégrade proprement (trait uniforme) si le moteur n'expose pas
# set_point_width. Grow effile le DÉBUT, Shrink la FIN.
func _apply_overlay_grow_shrink(overlay_line, line):
	var grow = line.get("Grow")
	var shrink = line.get("Shrink")
	var has_grow = grow is bool and grow
	var has_shrink = shrink is bool and shrink
	if not has_grow and not has_shrink:
		return
	var n = overlay_line.get_point_count()
	if n < 2:
		return
	# Setter par-point exposé par le moteur DD (essaie les deux conventions de nom).
	var setter = ""
	if overlay_line.has_method("set_point_width"):
		setter = "set_point_width"
	elif overlay_line.has_method("SetPointWidth"):
		setter = "SetPointWidth"
	if setter == "":
		return
	var base_w = line.width
	# Même heuristique que DD : distance = pts/3 (<100) sinon 50.
	var distance = (n / 3) if n < 100 else 50
	if distance <= 0:
		return
	var widths = []
	for k in range(n):
		widths.append(base_w)
	# Pour i de 1..distance : t = ease(i/distance, -2), w = lerp(base, 0, t).
	for i in range(1, distance + 1):
		var t = ease(float(i) / float(distance), -2.0)
		var w = lerp(base_w, 0.0, t)
		if has_grow:
			widths[distance - i] = w
		if has_shrink:
			widths[n - distance + i - 1] = w
	for k in range(n):
		overlay_line.call(setter, k, widths[k])

func remove_overlay_shadow(path):
	if path == null or not is_instance_valid(path):
		return
	if path.has_meta(OVERLAY_META_KEY):
		var nodes = path.get_meta(OVERLAY_META_KEY)
		if nodes is Array:
			for node in nodes:
				if is_instance_valid(node):
					node.get_parent().remove_child(node)
					node.free()
		path.remove_meta(OVERLAY_META_KEY)

func save_overlay_data(path, config: Dictionary):
	if not path.has_meta("node_id"):
		return
	var node_id = str(path.get_meta("node_id"))
	if not global.ModMapData.has(OVERLAY_DATA_KEY):
		global.ModMapData[OVERLAY_DATA_KEY] = {}
	var save_config = config.duplicate()
	if save_config.has("shadow_color") and save_config["shadow_color"] is Color:
		save_config["shadow_color"] = "#" + save_config["shadow_color"].to_html(false)
	global.ModMapData[OVERLAY_DATA_KEY][node_id] = save_config
	_known_node_ids[node_id] = true
	_all_known_path_ids[node_id] = true
	if not _all_points_hashes.has(node_id):
		_all_points_hashes[node_id] = _get_points_hash(path)

func load_overlay_data(path) -> Dictionary:
	if not path.has_meta("node_id"):
		return OVERLAY_DEFAULTS.duplicate()
	var node_id = str(path.get_meta("node_id"))
	if global.ModMapData.has(OVERLAY_DATA_KEY) and global.ModMapData[OVERLAY_DATA_KEY].has(node_id):
		var saved = global.ModMapData[OVERLAY_DATA_KEY][node_id].duplicate()
		if saved.has("shadow_color") and saved["shadow_color"] is String:
			saved["shadow_color"] = Color(saved["shadow_color"])
		return saved
	return OVERLAY_DEFAULTS.duplicate()

func apply_overlay_to_selected(toggle_only: bool = false):
	if _syncing_ui:
		return
	_history_touch("overlay")
	var ui_cfg = get_overlay_config()
	var enabled = ui_cfg["enabled"]
	
	var selected = global.Editor.Tools["SelectTool"].Selected
	for sel_node in selected:
		if sel_node == null or not is_instance_valid(sel_node):
			continue
		if not is_shadow_node_type(sel_node):
			continue
		if get_node_type(sel_node) == "walls":
			continue
		
		if toggle_only:
			# Preserve each path's own settings, only change enabled state
			var node_cfg = load_overlay_data(sel_node)
			node_cfg["enabled"] = enabled
			if enabled:
				remove_overlay_shadow(sel_node)
				create_overlay_shadow(sel_node, node_cfg)
			else:
				remove_overlay_shadow(sel_node)
			save_overlay_data(sel_node, node_cfg)
		else:
			# Apply full UI config to all
			if enabled:
				remove_overlay_shadow(sel_node)
				create_overlay_shadow(sel_node, ui_cfg)
				save_overlay_data(sel_node, ui_cfg)
			else:
				remove_overlay_shadow(sel_node)
				save_overlay_data(sel_node, ui_cfg)
	
	# Fallback if nothing selected but monitored exists
	if selected.size() == 0 and _monitored_path != null and is_instance_valid(_monitored_path):
		if is_shadow_node_type(_monitored_path):
			if enabled:
				remove_overlay_shadow(_monitored_path)
				create_overlay_shadow(_monitored_path, ui_cfg)
				save_overlay_data(_monitored_path, ui_cfg)
			else:
				remove_overlay_shadow(_monitored_path)
				save_overlay_data(_monitored_path, ui_cfg)

func get_overlay_config() -> Dictionary:
	var cfg = OVERLAY_DEFAULTS.duplicate()
	if overlay_ui.has("enable_check"):
		cfg["enabled"] = overlay_ui["enable_check"].pressed
	if overlay_ui.has("opacity_slider"):
		cfg["opacity"] = overlay_ui["opacity_slider"].value
	if overlay_ui.has("fade_slider"):
		cfg["fade_length"] = overlay_ui["fade_slider"].value
	# Direction from radio buttons
	for i in range(3):
		var key = "dir_btn_" + str(i)
		if overlay_ui.has(key) and overlay_ui[key].pressed:
			cfg["direction"] = i
			break
	# Axe (Horizontal/Vertical) from radio buttons
	for i in range(2):
		var akey = "axis_btn_" + str(i)
		if overlay_ui.has(akey) and overlay_ui[akey].pressed:
			cfg["axis"] = i
			break
	if overlay_ui.has("color_picker"):
		cfg["shadow_color"] = overlay_ui["color_picker"].color
	return cfg

func load_overlay_ui_from_path(path):
	var cfg = load_overlay_data(path)
	_syncing_ui = true
	if overlay_ui.has("enable_check"):
		overlay_ui["enable_check"].pressed = cfg.get("enabled", false)
	if overlay_ui.has("opacity_slider"):
		overlay_ui["opacity_slider"].value = cfg.get("opacity", 0.5)
	if overlay_ui.has("opacity_spin"):
		overlay_ui["opacity_spin"].value = cfg.get("opacity", 0.5)
	if overlay_ui.has("fade_slider"):
		overlay_ui["fade_slider"].value = cfg.get("fade_length", 0.5)
	if overlay_ui.has("fade_spin"):
		overlay_ui["fade_spin"].value = cfg.get("fade_length", 0.5)
	var dir = int(cfg.get("direction", 2))
	for i in range(3):
		var key = "dir_btn_" + str(i)
		if overlay_ui.has(key):
			overlay_ui[key].pressed = (i == dir)
			if i == dir:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_unchecked", "CheckBox")
	var axis = int(cfg.get("axis", 0))
	for i in range(2):
		var akey = "axis_btn_" + str(i)
		if overlay_ui.has(akey):
			overlay_ui[akey].pressed = (i == axis)
			if i == axis:
				overlay_ui[akey].icon = overlay_ui[akey].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[akey].icon = overlay_ui[akey].get_icon("radio_unchecked", "CheckBox")
	if overlay_ui.has("color_picker"):
		var c = cfg.get("shadow_color", Color(0, 0, 0, 1))
		if c is String:
			c = Color(c)
		overlay_ui["color_picker"].color = c
	# Show/hide settings
	var enabled = cfg.get("enabled", false)
	if overlay_ui.has("settings_panel"):
		overlay_ui["settings_panel"].visible = enabled
	if overlay_ui.has("reset_btn"):
		overlay_ui["reset_btn"].visible = enabled
	_syncing_ui = false

func _build_overlay_ui(parent_container: VBoxContainer):
	var ov_title_hbox = HBoxContainer.new()
	var ov_icon = _create_stairs_icon()
	if ov_icon != null:
		ov_title_hbox.add_child(ov_icon)
	var ov_title = Label.new()
	ov_title.text = "Shadow Overlay"
	ov_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ov_title_hbox.add_child(ov_title)
	var ov_reset = _make_icon_button("icons/reset.png", "Reset overlay to defaults", 0.5)
	ov_reset.visible = false
	ov_reset.connect("pressed", self, "_on_overlay_reset")
	ov_title_hbox.add_child(ov_reset)
	overlay_ui["reset_btn"] = ov_reset
	var ov_enable = CheckButton.new()
	ov_enable.pressed = false
	ov_enable.connect("toggled", self, "_on_overlay_enable_toggled")
	ov_title_hbox.add_child(ov_enable)
	overlay_ui["enable_check"] = ov_enable
	parent_container.add_child(ov_title_hbox)
	var ov_settings = VBoxContainer.new()
	ov_settings.visible = false
	overlay_ui["settings_panel"] = ov_settings
	# Axe du fondu : Horizontal (le long du path) / Vertical (hauteur du trait). Les
	# directions Side A/B/Both et le fade ci-dessous s'appliquent à l'axe choisi.
	var axis_hbox = HBoxContainer.new()
	var axis_names = ["Horizontal", "Vertical"]
	for i in range(2):
		var abtn = Button.new()
		abtn.text = " " + axis_names[i]
		abtn.toggle_mode = true
		abtn.pressed = (i == 0)
		abtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		abtn.align = Button.ALIGN_LEFT
		if i == 0:
			abtn.icon = abtn.get_icon("radio_checked", "CheckBox")
		else:
			abtn.icon = abtn.get_icon("radio_unchecked", "CheckBox")
		abtn.connect("pressed", self, "_on_overlay_axis_pressed", [i])
		axis_hbox.add_child(abtn)
		overlay_ui["axis_btn_" + str(i)] = abtn
	ov_settings.add_child(axis_hbox)
	var dir_hbox = HBoxContainer.new()
	var dir_names = ["Side A", "Side B", "Both"]
	for i in range(3):
		var btn = Button.new()
		btn.text = " " + dir_names[i]
		btn.toggle_mode = true
		btn.pressed = (i == 0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.align = Button.ALIGN_LEFT
		if i == 0:
			btn.icon = btn.get_icon("radio_checked", "CheckBox")
		else:
			btn.icon = btn.get_icon("radio_unchecked", "CheckBox")
		btn.connect("pressed", self, "_on_overlay_dir_pressed", [i])
		dir_hbox.add_child(btn)
		overlay_ui["dir_btn_" + str(i)] = btn
	ov_settings.add_child(dir_hbox)
	var op_hbox = HBoxContainer.new()
	var op_label = Label.new()
	op_label.text = "Opacity"
	op_label.rect_min_size.x = 60
	op_hbox.add_child(op_label)
	var op_slider = HSlider.new()
	op_slider.min_value = 0.01
	op_slider.max_value = 1.0
	op_slider.step = 0.01
	op_slider.value = 0.90
	op_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	op_slider.connect("value_changed", self, "_on_overlay_slider_changed", ["opacity"])
	op_hbox.add_child(op_slider)
	overlay_ui["opacity_slider"] = op_slider
	var op_spin = SpinBox.new()
	op_spin.min_value = 0.01
	op_spin.max_value = 1.0
	op_spin.step = 0.01
	op_spin.value = 0.90
	op_spin.rect_min_size.x = 60
	op_spin.connect("value_changed", self, "_on_overlay_slider_changed", ["opacity"])
	op_hbox.add_child(op_spin)
	overlay_ui["opacity_spin"] = op_spin
	ov_settings.add_child(op_hbox)
	var fl_hbox = HBoxContainer.new()
	var fl_label = Label.new()
	fl_label.text = "Fade"
	fl_label.rect_min_size.x = 60
	fl_hbox.add_child(fl_label)
	var fl_slider = HSlider.new()
	fl_slider.min_value = 0.01
	fl_slider.max_value = 1.0
	fl_slider.step = 0.01
	fl_slider.value = 0.5
	fl_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fl_slider.connect("value_changed", self, "_on_overlay_slider_changed", ["fade"])
	fl_hbox.add_child(fl_slider)
	overlay_ui["fade_slider"] = fl_slider
	var fl_spin = SpinBox.new()
	fl_spin.min_value = 0.01
	fl_spin.max_value = 1.0
	fl_spin.step = 0.01
	fl_spin.value = 0.5
	fl_spin.rect_min_size.x = 60
	fl_spin.connect("value_changed", self, "_on_overlay_slider_changed", ["fade"])
	fl_hbox.add_child(fl_spin)
	overlay_ui["fade_spin"] = fl_spin
	ov_settings.add_child(fl_hbox)
	var color_hbox = HBoxContainer.new()
	var color_label = Label.new()
	color_label.text = "Color"
	color_label.rect_min_size.x = 60
	color_hbox.add_child(color_label)
	var color_picker = ColorPickerButton.new()
	color_picker.color = Color(0, 0, 0, 1)
	color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_picker.connect("color_changed", self, "_on_overlay_color_changed")
	color_picker.connect("pressed", self, "_disable_color_pipette", [color_picker])
	color_hbox.add_child(color_picker)
	overlay_ui["color_picker"] = color_picker
	ov_settings.add_child(color_hbox)
	parent_container.add_child(ov_settings)
	var ov_end_sep = HSeparator.new()
	ov_end_sep.add_constant_override("separation", 8)
	parent_container.add_child(ov_end_sep)

func _on_overlay_enable_toggled(pressed):
	if _syncing_ui:
		return
	if overlay_ui.has("reset_btn"):
		overlay_ui["reset_btn"].visible = pressed
	if overlay_ui.has("settings_panel"):
		overlay_ui["settings_panel"].visible = pressed
	apply_overlay_to_selected(true)

func _on_overlay_slider_changed(value, param_name):
	if _syncing_ui:
		return
	if param_name == "opacity":
		if overlay_ui.has("opacity_slider") and overlay_ui.has("opacity_spin"):
			_syncing_ui = true
			overlay_ui["opacity_spin"].value = overlay_ui["opacity_slider"].value
			_syncing_ui = false
	elif param_name == "fade":
		if overlay_ui.has("fade_slider") and overlay_ui.has("fade_spin"):
			_syncing_ui = true
			overlay_ui["fade_spin"].value = overlay_ui["fade_slider"].value
			_syncing_ui = false
	apply_overlay_to_selected()

func _on_overlay_dir_pressed(dir_idx):
	if _syncing_ui:
		return
	for i in range(3):
		var key = "dir_btn_" + str(i)
		if overlay_ui.has(key):
			overlay_ui[key].pressed = (i == dir_idx)
			if i == dir_idx:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_unchecked", "CheckBox")
	apply_overlay_to_selected()

func _on_overlay_axis_pressed(axis_idx):
	if _syncing_ui:
		return
	for i in range(2):
		var key = "axis_btn_" + str(i)
		if overlay_ui.has(key):
			overlay_ui[key].pressed = (i == axis_idx)
			if i == axis_idx:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_unchecked", "CheckBox")
	apply_overlay_to_selected()

func _on_overlay_color_changed(color):
	if _syncing_ui:
		return
	apply_overlay_to_selected()

func _on_overlay_reset():
	_syncing_ui = true
	if overlay_ui.has("opacity_slider"):
		overlay_ui["opacity_slider"].value = OVERLAY_DEFAULTS["opacity"]
	if overlay_ui.has("opacity_spin"):
		overlay_ui["opacity_spin"].value = OVERLAY_DEFAULTS["opacity"]
	if overlay_ui.has("fade_slider"):
		overlay_ui["fade_slider"].value = OVERLAY_DEFAULTS["fade_length"]
	if overlay_ui.has("fade_spin"):
		overlay_ui["fade_spin"].value = OVERLAY_DEFAULTS["fade_length"]
	var dir = int(OVERLAY_DEFAULTS["direction"])
	for i in range(3):
		var key = "dir_btn_" + str(i)
		if overlay_ui.has(key):
			overlay_ui[key].pressed = (i == dir)
			if i == dir:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[key].icon = overlay_ui[key].get_icon("radio_unchecked", "CheckBox")
	var axis = int(OVERLAY_DEFAULTS["axis"])
	for i in range(2):
		var akey = "axis_btn_" + str(i)
		if overlay_ui.has(akey):
			overlay_ui[akey].pressed = (i == axis)
			if i == axis:
				overlay_ui[akey].icon = overlay_ui[akey].get_icon("radio_checked", "CheckBox")
			else:
				overlay_ui[akey].icon = overlay_ui[akey].get_icon("radio_unchecked", "CheckBox")
	if overlay_ui.has("color_picker"):
		overlay_ui["color_picker"].color = OVERLAY_DEFAULTS["shadow_color"]
	_syncing_ui = false
	apply_overlay_to_selected()
