#########################################################################################################
##
## PERSIST DROP SHADOW ON COPY LEVEL
## Ensures path, wall, and object drop shadows are visually applied when cloning a level.
## Settings are already preserved by Dungeondraft, but shadows need to be recreated
## on the new nodes since their node_ids change.
##
#########################################################################################################

var script_class = "tool"

var newlevelwindow = null
var dropshadow_paths = null
var dropshadow_walls = null
var dropshadow_objects = null
var overlay_shadow_objects = null
var level_settings = null
var dropshadow_roofs = null

# Captured during a clone: [[clone_node, cfg], ...] for overlays whose creation
# is deferred until AFTER the drop-shadow applies (so they aren't wiped).
var _clone_path_overlay_nodes = []
var _clone_obj_overlay_nodes = []

const SHADOW_DATA_KEY = "DropShadow"
const OVERLAY_DATA_KEY = "DropShadowOverlay"
const OBJ_OVERLAY_KEY = "OverlayShadow"
const ROOF_DATA_KEY = "DropShadowRoof"

# Per-level enable/disable state owned by LevelSettingsPatch.gd. Keyed by level
# NAME -> { "disabled": bool, "<asset>_ids": [...] }. We only need to read the
# source level's marker and set it on the clone; LevelSettingsPatch's on_update
# sweep then strips/retracks the shadows on the cloned (disabled) level.
const DISABLED_LEVELS_KEY = "DropShadowDisabledLevels"

# Logging Functions
const ENABLE_LOGGING = true

func outputlog(msg):
	if ENABLE_LOGGING:
		printraw("(%d) <PersistDropShadowOnCopyLevel>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
##
## SHADOW COPY LOGIC
##
#########################################################################################################

# True if the given level name is flagged disabled in LevelSettingsPatch state.
# Mirrors LevelSettingsPatch._is_level_disabled (marker OR any tracked _ids).
func _is_level_disabled(level_name: String) -> bool:
	if level_name == "":
		return false
	var root = Global.ModMapData.get(DISABLED_LEVELS_KEY, {})
	if not root.has(level_name):
		return false
	var s = root[level_name]
	if not (s is Dictionary):
		return false
	if s.get("disabled", false):
		return true
	for at in ["objects", "walls", "paths", "roofs"]:
		var ids = s.get(at + "_ids", [])
		if ids is Array and ids.size() > 0:
			return true
	return false

# Map a (cloned) shadow-owner node to its level-disable asset type.
# Mirrors _create_shadow_on_node's detection order. Roofs aren't handled by this
# clone module (no ref), so they return "" and are not id-tracked here.
func _asset_type_of(node) -> String:
	if dropshadow_paths != null and dropshadow_paths.is_shadow_node_type(node):
		return "paths"
	if dropshadow_walls != null and dropshadow_walls.is_shadow_node_type(node):
		return "walls"
	if dropshadow_objects != null and dropshadow_objects.is_shadow_node_type(node):
		return "objects"
	return ""

# Write the cloned level's disabled state: per-asset tracked ids + marker, then
# refresh the Levels-tree cloud icons. Falls back to direct ModMapData writes if
# the LevelSettingsPatch ref is unavailable (marker/ids only; no icon refresh).
func _apply_disabled_state_to_clone(level_name: String, ids_by_type: Dictionary):
	if level_settings != null:
		for at in ids_by_type.keys():
			var ids = ids_by_type[at]
			if ids is Array and ids.size() > 0:
				level_settings._set_disabled_ids(level_name, at, ids)
		# Marker LAST: _set_disabled_ids -> _tidy_state may erase a markerless,
		# id-less entry, so set the marker after the id lists are populated.
		level_settings._force_level_disabled_marker(level_name)
		level_settings._decorate_tree_rows()
		return
	# Fallback: direct writes (structure mirrors LevelSettingsPatch).
	if not Global.ModMapData.has(DISABLED_LEVELS_KEY):
		Global.ModMapData[DISABLED_LEVELS_KEY] = {}
	var root = Global.ModMapData[DISABLED_LEVELS_KEY]
	if not root.has(level_name):
		root[level_name] = {}
	for at in ids_by_type.keys():
		var ids2 = ids_by_type[at]
		if ids2 is Array and ids2.size() > 0:
			root[level_name][at + "_ids"] = ids2
	root[level_name]["disabled"] = true

# Apply a source roof's config onto a cloned roof. We must use the source's
# LIVE config (shadow_color as Color), not the raw ModMapData copy where the
# color is a hex string — create_shadow expects a Color. _save_config_for_roof
# does all the bookkeeping (_configs_by_id + meta + persisted hex).
func _apply_roof_config_to_clone(source_roof, new_roof, want_enabled: bool):
	if dropshadow_roofs == null or new_roof == null or not is_instance_valid(new_roof):
		return
	var src_cfg = null
	if source_roof != null and is_instance_valid(source_roof):
		var siid = source_roof.get_instance_id()
		if dropshadow_roofs._configs_by_id.has(siid):
			src_cfg = dropshadow_roofs._configs_by_id[siid]
		else:
			src_cfg = dropshadow_roofs._load_persisted_config(source_roof)
	if not (src_cfg is Dictionary):
		return
	var cfg = src_cfg.duplicate(true)
	cfg["enabled"] = want_enabled
	dropshadow_roofs._save_config_for_roof(new_roof, cfg)
	if want_enabled:
		dropshadow_roofs.create_shadow(new_roof, cfg)
	else:
		dropshadow_roofs.remove_shadow(new_roof)

func _copy_dropshadow_values(source_level_index: int):
	var has_shadow = Global.ModMapData.has(SHADOW_DATA_KEY)
	var has_overlay = Global.ModMapData.has(OVERLAY_DATA_KEY)
	var has_obj_overlay = Global.ModMapData.has(OBJ_OVERLAY_KEY)
	var has_roof = Global.ModMapData.has(ROOF_DATA_KEY)
	if not has_shadow and not has_overlay and not has_obj_overlay and not has_roof:
		outputlog("No shadow/overlay data found, nothing to copy.")
		return

	var source_level = Global.World.TryGetLevel(source_level_index)
	if source_level == null:
		outputlog("Source level not found at index " + str(source_level_index))
		return

	# If the source level is disabled, the clone must stay disabled too: copy the
	# (enabled=false) configs verbatim so settings survive, but create NO live
	# shadows. The disabled marker on the clone lets LevelSettingsPatch's sweep
	# keep it masked and retrack the new node_ids.
	var source_level_disabled = _is_level_disabled(source_level.name)
	if source_level_disabled:
		outputlog("Source level '" + str(source_level.name) + "' is disabled — clone will inherit disabled state.")
	# New node_ids on the clone, grouped by asset type, so the clone's disabled
	# state can be re-enabled later (cloud click) with the right ids. Includes the
	# two overlay pseudo-types so overlays come back on enable too.
	var disabled_ids_by_type = {"objects": [], "walls": [], "paths": [], "obj_overlays": [], "path_overlays": [], "roofs": []}
	_clone_path_overlay_nodes = []
	_clone_obj_overlay_nodes = []

	# The cloned level is always inserted at index 0
	var new_level = Global.World.levels[0]
	if new_level == null:
		outputlog("New level (index 0) not found.")
		return

	# Clean up cloned BelowAll container (it has orphan mesh copies from the source level)
	var ba_container = new_level.get_node_or_null("DropShadowBelowAll")
	if ba_container != null:
		new_level.remove_child(ba_container)
		ba_container.queue_free()
		outputlog("Removed cloned BelowAll container from new level")

	# Collect all node_ids that need copying (from shadow OR overlay data)
	var all_node_ids = {}
	if has_shadow:
		var shadow_snap = Global.ModMapData[SHADOW_DATA_KEY].duplicate(true)
		for nid in shadow_snap.keys():
			all_node_ids[nid] = {"shadow": shadow_snap[nid]}
	if has_overlay:
		var overlay_snap = Global.ModMapData[OVERLAY_DATA_KEY].duplicate(true)
		for nid in overlay_snap.keys():
			if all_node_ids.has(nid):
				all_node_ids[nid]["overlay"] = overlay_snap[nid]
			else:
				all_node_ids[nid] = {"overlay": overlay_snap[nid]}
	if has_obj_overlay:
		var obj_overlay_snap = Global.ModMapData[OBJ_OVERLAY_KEY].duplicate(true)
		for nid in obj_overlay_snap.keys():
			if all_node_ids.has(nid):
				all_node_ids[nid]["obj_overlay"] = obj_overlay_snap[nid]
			else:
				all_node_ids[nid] = {"obj_overlay": obj_overlay_snap[nid]}
	if has_roof:
		var roof_snap = Global.ModMapData[ROOF_DATA_KEY].duplicate(true)
		for nid in roof_snap.keys():
			if all_node_ids.has(nid):
				all_node_ids[nid]["roof"] = roof_snap[nid]
			else:
				all_node_ids[nid] = {"roof": roof_snap[nid]}

	var count = 0


	for node_id in all_node_ids.keys():
		var configs = all_node_ids[node_id]
		var shadow_config = configs.get("shadow")
		var overlay_config = configs.get("overlay")
		var obj_overlay_config = configs.get("obj_overlay")
		var roof_config = configs.get("roof")
		
		# Skip if nothing is enabled
		var shadow_enabled = shadow_config != null and shadow_config.get("enabled", false)
		var overlay_enabled = overlay_config != null and overlay_config.get("enabled", false)
		var obj_overlay_enabled = obj_overlay_config != null and obj_overlay_config.get("enabled", false)
		var roof_enabled = roof_config != null and roof_config.get("enabled", false)
		if source_level_disabled:
			# On a disabled level all configs are enabled=false; we still copy
			# them so settings survive. Skip only if there's truly no config.
			if shadow_config == null and overlay_config == null and obj_overlay_config == null and roof_config == null:
				continue
		elif not shadow_enabled and not overlay_enabled and not obj_overlay_enabled and not roof_enabled:
			continue

		# Check if this node belongs to the source level
		if not Global.World.HasNodeID(node_id):
			outputlog("  node_id " + str(node_id) + ": not found in world, skipping")
			continue
		var source_node = Global.World.GetNodeByID(node_id)
		if source_node == null or not is_instance_valid(source_node):
			outputlog("  node_id " + str(node_id) + ": invalid instance, skipping")
			continue

		# Determine the parent container
		var source_parent = source_node.get_parent()
		if source_parent == null:
			continue

		outputlog("  node_id " + str(node_id) + ": " + str(source_node.name) + " parent=" + str(source_parent.name))

		# Check this node is on the source level
		var node_level = null
		if source_parent.has_method("get") and source_parent.get("Level") != null:
			node_level = source_parent.get("Level")
		elif source_parent.get_parent() != null and source_parent.get_parent().get("Level") != null:
			node_level = source_parent.get_parent().get("Level")
		else:
			var walker = source_parent
			while walker != null:
				if walker == source_level:
					node_level = source_level
					break
				if walker.get("Level") != null:
					node_level = walker.get("Level")
					break
				walker = walker.get_parent()

		if node_level != source_level:
			outputlog("    -> not on source level, skipping")
			continue

		var source_index = source_node.get_index()
		var container_name = source_parent.name
		outputlog("    -> on source level, container=" + container_name + " index=" + str(source_index))

		# Find equivalent container in new level
		var new_parent = null
		for child in new_level.get_children():
			if child.name == container_name:
				new_parent = child
				break

		if new_parent == null:
			continue

		if source_index >= new_parent.get_child_count():
			continue

		var new_node = new_parent.get_child(source_index)
		if new_node == null or not is_instance_valid(new_node):
			continue
		if not new_node.has_meta("node_id"):
			continue

		var new_node_id = new_node.get_meta("node_id")
		var new_id_str = str(new_node_id)

		# Disabled source level: store every present config with enabled=false so
		# the settings survive the clone, but do NOT create any live shadow. The
		# clone's disabled marker (set after the loop) keeps it masked.
		if source_level_disabled:
			if shadow_config != null:
				var d_shadow = shadow_config.duplicate(true)
				d_shadow["enabled"] = false
				Global.ModMapData[SHADOW_DATA_KEY][new_id_str] = d_shadow
			if overlay_config != null:
				var d_overlay = overlay_config.duplicate(true)
				d_overlay["enabled"] = false
				if not Global.ModMapData.has(OVERLAY_DATA_KEY):
					Global.ModMapData[OVERLAY_DATA_KEY] = {}
				Global.ModMapData[OVERLAY_DATA_KEY][new_id_str] = d_overlay
			if obj_overlay_config != null:
				var d_obj = obj_overlay_config.duplicate(true)
				d_obj["enabled"] = false
				if not Global.ModMapData.has(OBJ_OVERLAY_KEY):
					Global.ModMapData[OBJ_OVERLAY_KEY] = {}
				Global.ModMapData[OBJ_OVERLAY_KEY][new_id_str] = d_obj
			if roof_config != null:
				# Persist + register in the module's memory with enabled=false; no
				# shadow created. The "roofs" id lets cloud-enable revive it.
				_apply_roof_config_to_clone(source_node, new_node, false)
			# Track the new id under its asset type (drop-shadow only — that's
			# what the cloud enable/disable governs) so re-enabling works.
			if shadow_config != null:
				var at = _asset_type_of(new_node)
				if at != "" and disabled_ids_by_type.has(at):
					disabled_ids_by_type[at].append(new_id_str)
			# Track overlay ids too, so enabling the clone restores overlays.
			if overlay_config != null:
				disabled_ids_by_type["path_overlays"].append(new_id_str)
			if obj_overlay_config != null:
				disabled_ids_by_type["obj_overlays"].append(new_id_str)
			if roof_config != null:
				disabled_ids_by_type["roofs"].append(new_id_str)
			count += 1
			continue

		# Copy shadow config
		if shadow_enabled:
			var new_config = shadow_config.duplicate(true)
			Global.ModMapData[SHADOW_DATA_KEY][new_id_str] = new_config
			# Walls self-clone via DropShadowWalls' OnAssignNode handler (and its
			# monitor heal). If we ALSO create here, the two creators race and the
			# stale-meta strip orphans one set → doubled wall shadows. So for walls
			# we only persist the config; the module + the apply pass below build
			# (and dedupe) the single shadow set. Paths/objects still create here.
			var is_wall = dropshadow_walls != null and dropshadow_walls.is_shadow_node_type(new_node)
			if not is_wall:
				_create_shadow_on_node(new_node, new_config)

		# Copy overlay (path) config — defer creation until after the drop-shadow
		# applies (which can otherwise wipe it). Strip the stale meta now so the
		# later recreate can't free the SOURCE level's overlay.
		if overlay_enabled:
			var new_ov_config = overlay_config.duplicate(true)
			if not Global.ModMapData.has(OVERLAY_DATA_KEY):
				Global.ModMapData[OVERLAY_DATA_KEY] = {}
			Global.ModMapData[OVERLAY_DATA_KEY][new_id_str] = new_ov_config
			if new_node.has_meta("overlay_shadow_nodes"):
				new_node.remove_meta("overlay_shadow_nodes")
			_clone_path_overlay_nodes.append([new_node, new_ov_config])

		# Copy object overlay (form) config — same deferral. Strip the stale meta
		# now so neither the recreate nor the modules' apply can free the source.
		if obj_overlay_enabled and overlay_shadow_objects != null:
			var new_oo_config = obj_overlay_config.duplicate(true)
			if not Global.ModMapData.has(OBJ_OVERLAY_KEY):
				Global.ModMapData[OBJ_OVERLAY_KEY] = {}
			Global.ModMapData[OBJ_OVERLAY_KEY][new_id_str] = new_oo_config
			if new_node.has_meta("overlay_shadow_obj_nodes"):
				new_node.remove_meta("overlay_shadow_obj_nodes")
			_clone_obj_overlay_nodes.append([new_node, new_oo_config])

		# Copy roof config — the roof module has no clone-source matching, so a
		# cloned roof would fall back to a disabled default. Persist + register in
		# the module's memory and create the shadow here.
		if roof_enabled:
			_apply_roof_config_to_clone(source_node, new_node, true)

		count += 1

	outputlog("Copied drop shadows/overlays to " + str(count) + " nodes on cloned level.")

	# Inherit the disabled state onto the clone: tracked ids (so cloud re-enable
	# restores the right shadows) + the disabled marker + an immediate refresh of
	# the Levels-tree cloud icons (the polling re-decorate only fires on tree
	# signature changes, so we trigger it here).
	if source_level_disabled:
		_apply_disabled_state_to_clone(new_level.name, disabled_ids_by_type)
		outputlog("Applied disabled state to cloned level '" + str(new_level.name) + "'.")

func _create_shadow_on_node(node, config: Dictionary):
	# Strip stale SHADOW_META_KEY from cloned nodes — it points to the
	# ORIGINAL level's mesh nodes. Calling remove_shadow with it would
	# destroy the source level's shadows.
	for meta_key in ["drop_shadow_nodes", "drop_shadow_obj_nodes"]:
		if node.has_meta(meta_key):
			node.remove_meta(meta_key)

	# Try paths first, then walls, then objects
	if dropshadow_paths != null:
		if dropshadow_paths.is_shadow_node_type(node):
			outputlog("  -> matched as PATH, creating shadow")
			dropshadow_paths.remove_shadow(node)
			dropshadow_paths.create_shadow(node, config)
			return

	if dropshadow_walls != null:
		if dropshadow_walls.is_shadow_node_type(node):
			outputlog("  -> matched as WALL, creating shadow")
			dropshadow_walls.remove_shadow(node)
			dropshadow_walls.create_shadow(node, config)
			return

	if dropshadow_objects != null:
		if dropshadow_objects.is_shadow_node_type(node):
			outputlog("  -> matched as OBJECT, creating shadow")
			dropshadow_objects.remove_shadow(node)
			dropshadow_objects.create_shadow(node, config)
			return
	
	outputlog("  -> NOT MATCHED by any shadow module! node=" + str(node.name) + " parent=" + str(node.get_parent().name if node.get_parent() else "null"))
	outputlog("     dropshadow_paths=" + str(dropshadow_paths != null) + " dropshadow_walls=" + str(dropshadow_walls != null) + " dropshadow_objects=" + str(dropshadow_objects != null))
	if dropshadow_paths != null:
		outputlog("     paths.get_node_type=" + str(dropshadow_paths.get_node_type(node)))
	if dropshadow_walls != null:
		outputlog("     walls.get_node_type=" + str(dropshadow_walls.get_node_type(node)))
	if dropshadow_objects != null:
		outputlog("     objects.is_shadow_node_type=" + str(dropshadow_objects.is_shadow_node_type(node)))
	else:
		var p = node.get_parent()
		outputlog("     no objects ref, parent.name=" + str(p.name if p else "null") + " has_meta_node_id=" + str(node.has_meta("node_id")))

# Recreate the deferred overlays on the cloned level, AFTER the drop-shadow
# applies have run. For each captured clone node we free any orphan overlay
# child copied by the native clone, then create a fresh overlay. The stale meta
# was already stripped at capture time, so create_*'s internal remove can't
# reach back into the SOURCE level.
func _recreate_clone_overlays():
	# Path overlays (child Line2D named "ShadowOverlay" on the path)
	if dropshadow_paths != null:
		for entry in _clone_path_overlay_nodes:
			var node = entry[0]
			var cfg = entry[1]
			if node == null or not is_instance_valid(node):
				continue
			if node.has_meta("overlay_shadow_nodes"):
				node.remove_meta("overlay_shadow_nodes")
			for child in node.get_children():
				if str(child.name).begins_with("ShadowOverlay"):
					node.remove_child(child)
					child.queue_free()
			dropshadow_paths.create_overlay_shadow(node, cfg)

	# Object (form) overlays (child named "OverlayShadowObj" on the object)
	if overlay_shadow_objects != null:
		for entry2 in _clone_obj_overlay_nodes:
			var onode = entry2[0]
			var ocfg = entry2[1]
			if onode == null or not is_instance_valid(onode):
				continue
			if onode.has_meta("overlay_shadow_obj_nodes"):
				onode.remove_meta("overlay_shadow_obj_nodes")
			for child2 in onode.get_children():
				if str(child2.name).begins_with("OverlayShadowObj"):
					onode.remove_child(child2)
					child2.queue_free()
			overlay_shadow_objects.create_shadow(onode, ocfg)

	_clone_path_overlay_nodes = []
	_clone_obj_overlay_nodes = []

#########################################################################################################
##
## BUTTON HOOK
##
#########################################################################################################

func _on_create_new_level_pressed():
	var timer = Timer.new()
	timer.autostart = false
	timer.one_shot = true
	Global.Editor.get_node("Windows").add_child(timer)

	if not Global.ModMapData.has(SHADOW_DATA_KEY) and not Global.ModMapData.has(OVERLAY_DATA_KEY) and not Global.ModMapData.has(OBJ_OVERLAY_KEY) and not Global.ModMapData.has(ROOF_DATA_KEY):
		Global.Editor.get_node("Windows").remove_child(timer)
		timer.queue_free()
		return

	# Only act when cloning (selected index > 0)
	var clone_option = newlevelwindow.get_node("VAlign").get_node("CloneLevel").get_node("CloneLevelOptionButton")
	if clone_option.selected > 0:
		timer.start(1.0)
		yield(timer, "timeout")
		_copy_dropshadow_values(clone_option.selected)
		# Force recreate all shadows on the new level
		timer.start(0.5)
		yield(timer, "timeout")
		if dropshadow_paths != null:
			dropshadow_paths.apply_saved_shadows_to_map()
		if dropshadow_walls != null:
			dropshadow_walls.apply_saved_shadows_to_map()
		if dropshadow_objects != null:
			dropshadow_objects.apply_saved_shadows_to_map()
		if overlay_shadow_objects != null:
			overlay_shadow_objects.apply_saved_shadows_to_map()
		# Overlays last: their creation was deferred so the drop-shadow applies
		# above couldn't wipe them. Safe to run after apply (idempotent).
		_recreate_clone_overlays()

	Global.Editor.get_node("Windows").remove_child(timer)
	timer.queue_free()

#########################################################################################################
##
## ENTRY POINT
##
#########################################################################################################

func start() -> void:
	outputlog("PersistDropShadowOnCopyLevel mod loaded.")

	# Find references to the drop shadow scripts via Core
	var timer = Timer.new()
	timer.wait_time = 1.0
	timer.one_shot = true
	timer.connect("timeout", self, "_deferred_init")
	Global.Editor.add_child(timer)
	timer.start()

func _deferred_init():
	outputlog("_deferred_init: start")
	# Get references from Core mod via ModMapData
	if Global.ModMapData.has("_dropshadow_refs"):
		var refs = Global.ModMapData["_dropshadow_refs"]
		dropshadow_paths = refs.get("paths")
		dropshadow_walls = refs.get("walls")
		dropshadow_objects = refs.get("objects")
		overlay_shadow_objects = refs.get("overlay_objects")
		level_settings = refs.get("level_settings")
		dropshadow_roofs = refs.get("roofs")
		outputlog("Found refs: paths=" + str(dropshadow_paths != null) + " walls=" + str(dropshadow_walls != null) + " objects=" + str(dropshadow_objects != null) + " overlay_objects=" + str(overlay_shadow_objects != null))
	else:
		outputlog("Warning: _dropshadow_refs not found in ModMapData. Core mod may not be loaded.")

	if dropshadow_paths == null:
		outputlog("Warning: Could not find Core mod references. Shadow creation on clone may not work.")
	outputlog("References: paths=" + str(dropshadow_paths != null) + " walls=" + str(dropshadow_walls != null) + " objects=" + str(dropshadow_objects != null))

	# Find the Create Level window
	for win in Global.Editor.get_node("Windows").get_children():
		for sub_win in win.get_children():
			if sub_win.name == "Margins":
				for thing in sub_win.get_child(0).get_children():
					if thing.name == "CloneLevel":
						newlevelwindow = sub_win
						break
			if newlevelwindow != null:
				break
		if newlevelwindow != null:
			break

	if newlevelwindow == null:
		outputlog("Warning: Could not find Create Level window.")
		return

	# Connect to the Create button
	var ok_button = newlevelwindow.get_node("VAlign").get_node("Buttons").get_node("OkayButton")
	if ok_button != null:
		ok_button.connect("pressed", self, "_on_create_new_level_pressed")
		outputlog("Connected to Create Level button.")
