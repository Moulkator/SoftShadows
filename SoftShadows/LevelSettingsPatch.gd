#########################################################################################################
##
## LEVEL SETTINGS PATCH - Adds shadow controls to DD's native LevelSettings tool
##
#########################################################################################################
# Three additions, injected at runtime into the LevelSettings tool panel:
#
#   1. A "cloud" icon button at the end of each level row in the Levels tree.
#      Click toggles enable/disable for that level (all asset types).
#
#   2. A control row at the top: Enable/Disable dropdown + scope dropdown
#      (Current/Other/All Levels) + Apply button.
#
#   3. A quality slider row: drives a global "quality broadcast" for ALL
#      objects on the map. Replaces the per-object quality slider, which
#      DropShadowObjects no longer exposes.
#
# State persisted in ModMapData under:
#   STATE_KEY     -> { <level_name>: { "disabled_ids": [<node_id>, ...] } }
#   QUALITY_KEY   -> int (0..100) ; absent = no global override
#
# Asset types covered: objects, walls, paths, roofs (all four).

var global
var reference_to_script = null
var core = null

# Module refs (injected by Core)
var dropshadow_paths = null
var dropshadow_walls = null
var dropshadow_objects = null
var dropshadow_roofs = null
var shadow_toggle = null
var overlay_shadow_objects = null

const ENABLE_LOGGING = true
var logging_level = 0

const STATE_KEY = "DropShadowDisabledLevels"
const QUALITY_KEY = "DropShadowGlobalQuality"
const INIT_FLAG_KEY = "DropShadowLevelInitDone"

# Object (form) overlay shadows — owned by OverlayShadowObjects. Disabling a
# level masks these too. Tracked under the "obj_overlays" pseudo asset-type.
const OBJ_OVERLAY_DATA_KEY = "OverlayShadow"
const OBJ_OVERLAY_META_KEY = "overlay_shadow_obj_nodes"
const OBJ_OVERLAY_CONTAINERS = ["Objects", "Roofs"]

# Path overlay shadows — owned by DropShadowPaths (create_overlay_shadow /
# remove_overlay_shadow). Tracked under the "path_overlays" pseudo asset-type.
const PATH_OVERLAY_DATA_KEY = "DropShadowOverlay"
const PATH_OVERLAY_META_KEY = "overlay_shadow_nodes"
const PATH_OVERLAY_CONTAINER = "Pathways"

# Global bake-mode (objects-only). Mirrors the constants in DropShadowObjects.
const BAKE_MODE_KEY = "DropShadowBakeMode"
const BAKE_MODE_LIVE = 0
const BAKE_MODE_AUTO = 1
const BAKE_MODE_MANUAL = 2

# The rendering mode is a per-USER preference (remembered across maps), not a
# per-map setting. Persisted to a config file under user:// and used to seed
# the per-map runtime value (ModMapData[BAKE_MODE_KEY]) on every map open.
const GLOBAL_CFG_PATH = "user://dropshadow_softshadows.cfg"
const GLOBAL_CFG_SECTION = "rendering"
const GLOBAL_CFG_MODE_KEY = "bake_mode"

const ASSET_TYPES = ["objects", "walls", "paths", "roofs"]

const META_KEYS = {
	"objects": "drop_shadow_obj_nodes",
	"walls":   "drop_shadow_nodes",
	"paths":   "drop_shadow_nodes",
	"roofs":   "drop_shadow_nodes"
}
const CONTAINER_NAMES = {
	"objects": "Objects",
	"walls":   "Walls",
	"paths":   "Pathways",
	"roofs":   "Roofs"
}
const SHADOW_DATA_KEYS = {
	"objects": "DropShadow",
	"walls":   "DropShadow",
	"paths":   "DropShadow",
	"roofs":   "DropShadowRoof"
}

# Tree row icons: three tinted variants of cloud.png.
# Loaded once at init, used as Texture for TreeItem.add_button().
var _cloud_icon_on: Texture = null      # blue, level enabled
var _cloud_icon_off: Texture = null     # grey, level disabled
var _cloud_icon_hover: Texture = null   # white, mouse over (only on disabled rows)

# Track which TreeItem is currently being hovered so we can swap textures
# without re-decorating the whole tree on every mouse move.
var _hovered_item = null

# Refs to injected UI parts (lookup helpers, not authoritative)
var _level_tree = null         # The DragDropTree<Level> inside LevelSettings
var _injected_root: VBoxContainer = null  # Our wrapper for top-of-tool controls
var _action_option: OptionButton = null
var _scope_option: OptionButton = null
var _apply_button: Button = null
var _quality_slider: HSlider = null
var _quality_label: Label = null

# Bake-mode controls
var _bake_mode_option: OptionButton = null   # Live / Bake Auto / Bake Manual
var _bake_mode_desc: Label = null            # explains the current mode
var _rendering_apply_frame: PanelContainer = null  # "Apply" — bake now (Auto only)
var _bake_scope_option: OptionButton = null  # All / Current / Other (manual only)
var _bake_button: Button = null
var _bake_manual_row: HBoxContainer = null

# Poll cadence for "is the LevelSettings panel built yet?" — fires from
# Core.update(delta) at most a few times before injection succeeds.
var _inject_attempts = 0
var _injected = false

# Tracks last-seen level row signatures so we can re-decorate when the
# native LevelSettings rebuilds the tree (after Create/Delete/Reorder).
var _last_tree_signature = ""

func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <LevelSettingsPatch>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	if not global.ModMapData.has(STATE_KEY):
		global.ModMapData[STATE_KEY] = {}
	# Seed the per-map runtime rendering mode from the saved user preference,
	# so the choice carries over between maps. Runs before the modules create
	# shadows (gating reads ModMapData[BAKE_MODE_KEY]) and before the tool UI.
	global.ModMapData[BAKE_MODE_KEY] = _load_global_bake_mode()
	_cloud_icon_on    = _build_cloud_icon_variant("on")
	_cloud_icon_off   = _build_cloud_icon_variant("off")
	_cloud_icon_hover = _build_cloud_icon_variant("hover")
	# Hook DD's new-node signal so we can intercept fresh shadows on disabled
	# levels (set cfg.enabled=false before the module's monitor creates them).
	if global.World.has_signal("OnAssignNode"):
		global.World.connect("OnAssignNode", self, "_on_new_node_added")
	outputlog("Initialised (injection deferred to tool-panel readiness)", 0)


# Queue freshly placed nodes for deferred processing. We can't act directly
# in the signal handler because the modules haven't created the shadow yet —
# we process them in on_update, and re-queue ones that aren't ready (the
# module's monitor only ticks every 10ms, but the shadow can take longer
# to materialise — e.g. paths only commit on draw-end).
#
# Entries are [node, attempts_left]. Drop after N tries to avoid leaks.
const _MAX_PENDING_ATTEMPTS = 60   # ~1s at 60fps
var _pending_new_nodes = []
func _on_new_node_added(node):
	if node == null or not is_instance_valid(node):
		return
	_pending_new_nodes.append([node, _MAX_PENDING_ATTEMPTS])


# Walks recently-placed nodes and applies our level state to them.
# Runs from on_update polling — fast enough that the shadow doesn't get a
# chance to flash visible (the module's monitor + ours run in parallel).
func _process_pending_new_nodes():
	if _pending_new_nodes.size() == 0:
		return
	var still_pending = []
	var levels_by_name = _build_levels_by_name_map()
	var hidden = false
	if shadow_toggle != null:
		hidden = global.ModMapData.get(shadow_toggle.STATE_KEY, false)
	for entry in _pending_new_nodes:
		var node = entry[0]
		var attempts = entry[1]
		if not is_instance_valid(node):
			continue
		var owner_level = _find_ancestor_level(node, levels_by_name)
		if owner_level == null:
			# Not parented yet; try again later
			if attempts > 1:
				still_pending.append([node, attempts - 1])
			continue
		var level_disabled = _is_level_disabled(owner_level.name)
		var asset_type = _identify_asset_type(node)
		if asset_type == "":
			# Not a shadowable asset; drop it
			continue
		var meta_key = META_KEYS[asset_type]
		var has_shadow = node.has_meta(meta_key)
		# Disabled level — kill any shadow that may exist, regardless of timing.
		# We don't need to wait: removing nothing is a no-op.
		if level_disabled:
			_kill_new_shadow(node, asset_type)
			# Re-queue a few times in case the monitor recreates the shadow
			# right after we stripped it.
			if attempts > 1:
				still_pending.append([node, attempts - 1])
			continue
		# Hidden globally — we MUST wait for the shadow to actually exist,
		# otherwise setting visible=false on nothing is wasted.
		if hidden:
			if has_shadow:
				_hide_new_shadow(node, asset_type)
				# Continue to re-queue: subsequent module ticks (e.g. bake
				# replacement, ShadowBaker swapping the sprite) can reset
				# .visible=true. Keep enforcing until attempts run out.
				if attempts > 1:
					still_pending.append([node, attempts - 1])
			else:
				if attempts > 1:
					still_pending.append([node, attempts - 1])
			continue
		# Neither disabled nor hidden — nothing to do, drop from queue
	_pending_new_nodes = still_pending


func _identify_asset_type(node):
	if dropshadow_roofs != null and dropshadow_roofs.is_roof(node):
		return "roofs"
	if dropshadow_objects != null and dropshadow_objects.is_shadow_node_type(node):
		return "objects"
	if dropshadow_walls != null and dropshadow_walls.is_shadow_node_type(node):
		return "walls"
	if dropshadow_paths != null and dropshadow_paths.is_shadow_node_type(node):
		return "paths"
	return ""


# Disable the shadow for a node that just got placed on a disabled level.
# Set cfg.enabled=false in saved data, remove any shadow nodes, and track
# the id so Enable can revive it later.
func _kill_new_shadow(node, asset_type):
	if not node.has_meta("node_id"):
		return
	var node_id = str(node.get_meta("node_id"))
	var data_key = SHADOW_DATA_KEYS[asset_type]
	if not global.ModMapData.has(data_key):
		return
	var shadow_data = global.ModMapData[data_key]
	var meta_key = META_KEYS[asset_type]
	var module = _module_for(asset_type)
	if module == null:
		return
	# Resolve owning level
	var level_name = ""
	var levels_by_name = _build_levels_by_name_map()
	var level = _find_ancestor_level(node, levels_by_name)
	if level != null:
		level_name = level.name
	if level_name == "":
		return
	# Flip cfg if present
	if shadow_data.has(node_id):
		var cfg = shadow_data[node_id]
		if cfg is Dictionary and cfg.get("enabled", false):
			cfg["enabled"] = false
			# Track id under level
			var ids = _get_disabled_ids(level_name, asset_type)
			if not ids.has(node_id):
				ids.append(node_id)
			_set_disabled_ids(level_name, asset_type, ids)
	# Roofs in-memory cache mirror
	if asset_type == "roofs" and module._configs_by_id != null:
		var iid = node.get_instance_id()
		if module._configs_by_id.has(iid):
			module._configs_by_id[iid]["enabled"] = false
	# Strip existing shadow if module already created one
	if node.has_meta(meta_key):
		module.remove_shadow(node)


# Force visible=false on a freshly-placed node's shadow nodes.
func _hide_new_shadow(node, asset_type):
	if shadow_toggle == null:
		return
	var meta_key = META_KEYS[asset_type]
	if not node.has_meta(meta_key):
		return
	var nodes = node.get_meta(meta_key)
	if not (nodes is Array):
		return
	for n in nodes:
		if is_instance_valid(n):
			n.visible = false


# ObjectTool and PathTool render preview shadows during asset placement
# (before OnAssignNode fires). _on_new_node_added doesn't see them. We poll
# the modules' preview refs and enforce visibility ourselves.
func _enforce_preview_state():
	var hidden = false
	if shadow_toggle != null:
		hidden = global.ModMapData.get(shadow_toggle.STATE_KEY, false)
	var current = global.World.GetCurrentLevel()
	var level_disabled = (current != null) and _is_level_disabled(current.name)
	if not hidden and not level_disabled:
		return

	# ObjectTool preview
	if dropshadow_objects != null:
		var ot_preview = dropshadow_objects.get("_obj_tool_preview_node")
		if ot_preview != null and is_instance_valid(ot_preview):
			if level_disabled:
				# Strip the shadow outright — the user shouldn't see one at all.
				if ot_preview.has_meta(META_KEYS["objects"]):
					dropshadow_objects.remove_shadow(ot_preview)
			elif hidden:
				_apply_invisible_to_meta(ot_preview, META_KEYS["objects"])

	# PathTool live shadow
	if dropshadow_paths != null:
		var pt_editing = dropshadow_paths.get("_pt_editing_path")
		if pt_editing != null and is_instance_valid(pt_editing):
			if level_disabled:
				if pt_editing.has_meta(META_KEYS["paths"]):
					dropshadow_paths.remove_shadow(pt_editing)
			elif hidden:
				_apply_invisible_to_meta(pt_editing, META_KEYS["paths"])


func _apply_invisible_to_meta(owner, meta_key):
	if not owner.has_meta(meta_key):
		return
	var nodes = owner.get_meta(meta_key)
	if not (nodes is Array):
		return
	for n in nodes:
		if is_instance_valid(n):
			n.visible = false


func cleanup():
	if _injected_root != null and is_instance_valid(_injected_root):
		_injected_root.queue_free()
	_injected_root = null
	_level_tree = null
	_injected = false


func _load_icon_from_disk(path: String) -> Texture:
	# Match the exact pattern used by DropShadowObjects._load_icon — no
	# error checking, no flags. Some Godot 3 builds behave inconsistently
	# with the `flags` parameter on create_from_image.
	var image = Image.new()
	image.load(global.Root + path)
	if image.get_width() == 0 or image.get_height() == 0:
		outputlog("Icon load failed or empty: %s (full path: %s)" % [path, global.Root + path], 0)
		return null
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	outputlog("Icon loaded: %s (%dx%d)" % [path, image.get_width(), image.get_height()], 0)
	return texture


# Builds a tinted cloud icon. Three states:
#   "off"   = grey (level disabled, mouse not over)
#   "hover" = white (level disabled, mouse over) — visual cue that it's clickable
#   "on"    = blue (level enabled)
func _build_cloud_icon_variant(state) -> Texture:
	var image = Image.new()
	if image.load(global.Root + "icons/cloud.png") != OK:
		outputlog("Cloud icon load failed", 0)
		return null
	if image.get_width() == 0 or image.get_height() == 0:
		return null
	var tint
	match state:
		"on":    tint = Color("#5ab2ff")              # blue
		"hover": tint = Color(1.0, 1.0, 1.0, 1.0)     # white (no tint = pass-through)
		_:       tint = Color(0.55, 0.55, 0.55, 1.0)  # grey
	image.lock()
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var c = image.get_pixel(x, y)
			if c.a > 0.01:
				image.set_pixel(x, y, Color(c.r * tint.r, c.g * tint.g, c.b * tint.b, c.a))
	image.unlock()
	# Resize to 28x28 — readable size that doesn't blow up row height.
	image.resize(28, 28, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(image)
	return tex


# Called from Core.update(delta) once a second or so. Cheap when already
# injected; retries injection if the panel wasn't ready earlier.
func on_update(_delta):
	# Always try to hide the per-object quality row — runs even before
	# LevelSettings panel injection (the objects panel can exist without
	# LevelSettings being open).
	_hide_individual_object_quality_controls()
	# Process freshly placed nodes (set cfg.enabled=false on disabled levels,
	# set visible=false on hidden mode).
	_process_pending_new_nodes()
	# Enforce hidden/disabled on the per-tool preview shadows (ObjectTool,
	# PathTool) that the modules render in real-time during placement.
	_enforce_preview_state()
	# Sweep disabled levels for shadows that the modules' monitors may have
	# auto-created (e.g. clone detection). Throttled — runs every 0.5s.
	_sweep_disabled_levels_throttled(_delta)
	# Update tool-panel toggle button enabled/disabled states based on the
	# current level's enabled state.
	_update_tool_toggle_states()
	if not _injected:
		_try_inject()
		return
	# Detect tree mutations (Create/Delete/Reorder) by comparing a cheap signature
	# of the current tree against our last snapshot.
	if _level_tree == null or not is_instance_valid(_level_tree):
		_injected = false  # Tool got torn down; will re-inject next cycle
		return
	var sig = _compute_tree_signature()
	if sig != _last_tree_signature:
		_last_tree_signature = sig
		_decorate_tree_rows()
	# Hover detection: update _hovered_item based on current mouse position
	# and redecorate only if it changed. Cheap — runs at the polling cadence.
	_update_hover_state()


const _LOCK_OVERLAY_NAME = "_DropShadowLevelLockOverlay"

# Per-asset lock state: remember whether the cog/settings/dir was visible
# BEFORE we locked, so we can restore correctly. Otherwise repeated lock/unlock
# would leave the user's settings panel state confused.
var _lock_memory = {}


# Greys the entire "Soft Shadow" section in each panel when the current level
# is disabled. Three layers of effect:
#   1. Wrapper container modulate=0.4 + click-blocker overlay   (visual + mouse)
#   2. Cog button (settings expander) hidden                     (reduce space)
#   3. Settings panel (sliders) hidden + direction row hidden    (reduce space)
func _update_tool_toggle_states():
	var current = global.World.GetCurrentLevel()
	if current == null:
		return
	var level_disabled = _is_level_disabled(current.name)

	# --- Tool panels (ObjectTool, WallTool, PathTool, RoofTool) ----------
	# Wrapper grey
	var wrappers = []
	_collect_wrapper(wrappers, "ObjectTool", "SoftShadowObjectToolWrapper")
	_collect_wrapper(wrappers, "ScatterTool", "SoftShadowScatterWrapper")
	_collect_wrapper(wrappers, "WallTool", "DropShadowWallTool")
	_collect_wrapper(wrappers, "PathTool", "DropShadowPathTool")
	_collect_wrapper(wrappers, "RoofTool", "DropShadowRoofsContainer")
	for w in wrappers:
		_apply_lock_to_wrapper(w, level_disabled)

	# Tool-side extras (cog/settings/dir within wt_ui / pt_ui / rt_ui_config)
	_lock_module_dict("walls",    level_disabled, dropshadow_walls, "wt_ui",        "cog_btn", "settings", "dir_wrapper")
	_lock_module_dict("paths",    level_disabled, dropshadow_paths, "pt_ui",        "cog_btn", "settings", "dir_wrapper")
	_lock_module_dict("walls_pt", level_disabled, dropshadow_walls, "pt_ui",        "cog_btn", "settings", "dir_wrapper")
	_lock_module_dict("roofs",    level_disabled, dropshadow_roofs, "rt_ui_config", "",        "settings", "")

	# --- SelectTool panels: grey the whole module container + hide extras ----
	# Each module's SelectTool block lives in ui_config["container"]. Apply the
	# same wrapper greying treatment to those.
	for module in [dropshadow_objects, dropshadow_walls, dropshadow_paths, dropshadow_roofs]:
		if module == null:
			continue
		var ui = module.get("ui_config")
		if ui != null and ui is Dictionary:
			var container = ui.get("container", null)
			if container != null and is_instance_valid(container):
				_apply_lock_to_wrapper(container, level_disabled)
	# Hide cog (settings_toggle), settings_panel, dir_wrapper for each module's SelectTool UI
	_lock_module_dict("sel_objects", level_disabled, dropshadow_objects, "ui_config", "settings_toggle", "settings_panel", "")
	_lock_module_dict("sel_walls",   level_disabled, dropshadow_walls,   "ui_config", "settings_toggle", "settings_panel", "dir_wrapper")
	_lock_module_dict("sel_paths",   level_disabled, dropshadow_paths,   "ui_config", "settings_toggle", "settings_panel", "dir_wrapper")
	_lock_module_dict("sel_roofs",   level_disabled, dropshadow_roofs,   "ui_config", "settings_toggle", "settings_panel", "")

	# Object (form) overlay UI lives in the SelectTool panel under ui["container"];
	# grey it (enable toggle + settings) when the level is disabled.
	if overlay_shadow_objects != null:
		var ov_ui = overlay_shadow_objects.get("ui")
		if ov_ui != null and ov_ui is Dictionary:
			var ov_cont = ov_ui.get("container", null)
			if ov_cont != null and is_instance_valid(ov_cont):
				_apply_lock_to_wrapper(ov_cont, level_disabled)


func _collect_wrapper(out: Array, tool_name: String, container_name: String):
	var panel = global.Editor.Toolset.GetToolPanel(tool_name) if global.Editor.Toolset else null
	if panel == null:
		return
	_collect_named_descendants(panel, container_name, out)


func _collect_named_descendants(node, target_name, out):
	for child in node.get_children():
		if child is Control and str(child.name) == target_name:
			out.append(child)
			continue
		_collect_named_descendants(child, target_name, out)


func _apply_lock_to_wrapper(wrapper, locked: bool):
	if wrapper == null or not is_instance_valid(wrapper):
		return
	var overlay = wrapper.get_node_or_null(_LOCK_OVERLAY_NAME)
	if locked:
		if wrapper.modulate.a > 0.5:
			wrapper.modulate = Color(1, 1, 1, 0.4)
		if overlay == null:
			overlay = Control.new()
			overlay.name = _LOCK_OVERLAY_NAME
			overlay.anchor_left = 0.0
			overlay.anchor_top = 0.0
			overlay.anchor_right = 1.0
			overlay.anchor_bottom = 1.0
			overlay.mouse_filter = Control.MOUSE_FILTER_STOP
			wrapper.add_child(overlay)
		wrapper.move_child(overlay, wrapper.get_child_count() - 1)
	else:
		if wrapper.modulate.a < 0.99:
			wrapper.modulate = Color(1, 1, 1, 1)
		if overlay != null and is_instance_valid(overlay):
			overlay.queue_free()


# Hide / restore a set of named visibility-controlled children inside a module's
# UI dict. Empty `key_*` arguments mean "no such control in this dict".
# slot_key: a unique cache key for the lock memory (per dict instance)
# module:   the dropshadow_* module ref
# dict_key: attribute name on the module ("wt_ui", "pt_ui", "rt_ui_config", "ui_config")
# key_cog, key_settings, key_dir: the dict keys to hide; pass "" if absent
func _lock_module_dict(slot_key, locked, module, dict_key, key_cog, key_settings, key_dir):
	if module == null:
		return
	var ui = module.get(dict_key)
	if ui == null or not (ui is Dictionary):
		return
	var cog = ui.get(key_cog, null) if key_cog != "" else null
	var settings = ui.get(key_settings, null) if key_settings != "" else null
	var dir_w = ui.get(key_dir, null) if key_dir != "" else null

	var mem = _lock_memory.get(slot_key, {})
	if locked:
		if not mem.has("locked"):
			mem["cog_was_visible"] = _is_visible(cog)
			mem["settings_was_visible"] = _is_visible(settings)
			mem["dir_was_visible"] = _is_visible(dir_w)
			mem["locked"] = true
			_lock_memory[slot_key] = mem
		_set_visible(cog, false)
		_set_visible(settings, false)
		_set_visible(dir_w, false)
	else:
		if mem.has("locked"):
			_set_visible(cog, mem.get("cog_was_visible", false))
			_set_visible(settings, mem.get("settings_was_visible", false))
			_set_visible(dir_w, mem.get("dir_was_visible", false))
			_lock_memory.erase(slot_key)


func _is_visible(node) -> bool:
	return node != null and is_instance_valid(node) and node.visible


func _set_visible(node, vis):
	if node != null and is_instance_valid(node):
		node.visible = vis


func _update_hover_state():
	if _level_tree == null or not is_instance_valid(_level_tree):
		return
	var new_hover = null
	var mouse_global = _level_tree.get_global_mouse_position()
	var rect = _level_tree.get_global_rect()
	if rect.has_point(mouse_global):
		var local_pos = mouse_global - rect.position
		var hit = _level_tree.get_item_at_position(local_pos)
		if hit != null:
			# Only count as hover if the cursor is over column 1 (where the
			# icon button lives). Otherwise hovering the label would highlight
			# the icon, which is confusing.
			var col = _level_tree.get_column_at_position(local_pos)
			if col == 1:
				new_hover = hit
	if new_hover != _hovered_item:
		_hovered_item = new_hover
		_decorate_tree_rows()


var _sweep_accum = 0.0
const _SWEEP_INTERVAL = 0.5  # seconds

func _sweep_disabled_levels_throttled(delta):
	_sweep_accum += delta
	if _sweep_accum < _SWEEP_INTERVAL:
		return
	_sweep_accum = 0.0
	_sweep_disabled_levels()


# Walks every level that's currently marked disabled in our state and removes
# any shadow nodes that have been (re)created on it — typically because the
# user just placed a new asset or a monitor rebuilt an orphan. Also flips
# the new owners' cfg.enabled=false and adds their node_ids to our tracked list.
func _sweep_disabled_levels():
	var state = global.ModMapData.get(STATE_KEY, {})
	if state.empty():
		return
	var levels_by_name = _build_levels_by_name_map()
	if levels_by_name.empty():
		return
	for level_name in state.keys():
		if not levels_by_name.has(level_name):
			continue
		if not _is_level_disabled(level_name):
			continue
		var level = levels_by_name[level_name]
		for at in ASSET_TYPES:
			_disable_level_asset(level, at)
		_disable_level_obj_overlays(level)
		_disable_level_path_overlays(level)

#########################################################################################################
## INJECTION
#########################################################################################################

func _try_inject():
	_inject_attempts += 1
	if _inject_attempts > 200:
		# 200 * 0.25s = 50s of trying. Give up silently to avoid noise.
		return

	# At attempt 5, dump everything we can find — gives the user logs to
	# diagnose where LevelSettings actually lives in this DD version.
	if _inject_attempts == 5:
		_log_discovery_dump()

	var panel = global.Editor.Toolset.GetToolPanel("LevelSettings") if global.Editor.Toolset else null
	if panel == null:
		return

	# At attempt 5, also dump the panel internals once we have a ref.
	if _inject_attempts == 5:
		_log_panel_internals(panel)

	# LevelSettings exposes its Tree as Controls["Level"] (C# dict).
	# Try several access patterns.
	var tree = _find_level_tree(panel)
	if tree == null:
		return

	outputlog("Found Level tree (class=%s, name=%s)" % [tree.get_class(), tree.name], 0)
	_level_tree = tree
	# Autonomous controls now live in the Soft Shadows tool (Effects category);
	# here we only decorate the level tree with the per-level cloud icons.
	_decorate_tree_rows()
	_injected = true
	outputlog("Injected cloud icons into LevelSettings tool", 0)


func _find_level_tree(panel):
	# Path 1: panel.Controls["Level"] (the documented Tool API)
	var controls = panel.get("Controls") if panel else null
	if controls != null:
		if controls is Dictionary and controls.has("Level"):
			var t = controls["Level"]
			if t is Tree:
				return t
		# Some Dictionary-like objects don't pass the `is Dictionary` check
		# but do support .has()/[]. Try defensively.
		if controls.has_method("has") and controls.has("Level"):
			var t = controls["Level"]
			if t is Tree:
				return t
	# Path 2: walk the panel subtree looking for any Tree (LevelSettings has
	# only one, named "Level").
	var found = _find_first_tree(panel)
	if found != null:
		return found
	return null


func _find_first_tree(node):
	if node == null:
		return null
	for child in node.get_children():
		if child is Tree:
			return child
		var sub = _find_first_tree(child)
		if sub != null:
			return sub
	return null


# Logs class/name/property snapshot of the LevelSettings panel, plus a
# recursive children tree. Helps locate the Tree node and any anchors.
func _log_panel_internals(panel):
	outputlog("--- LevelSettings panel internals ---", 0)
	outputlog("  panel class: %s, name: %s" % [panel.get_class(), str(panel.name)], 0)
	var ctrl = panel.get("Controls")
	if ctrl == null:
		outputlog("  panel.Controls = null", 0)
	elif ctrl is Dictionary:
		outputlog("  panel.Controls (Dict, %d keys): %s" % [ctrl.size(), str(ctrl.keys())], 0)
	else:
		outputlog("  panel.Controls type: %s" % typeof(ctrl), 0)
	# Walk children up to depth 4
	_log_subtree(panel, 0, 4)
	outputlog("--- end LevelSettings panel internals ---", 0)


func _log_subtree(node, depth, max_depth):
	if depth > max_depth or node == null:
		return
	var pad = "  " + ("  " * depth)
	outputlog("%s[%s] %s" % [pad, node.get_class(), str(node.name)], 0)
	for child in node.get_children():
		_log_subtree(child, depth + 1, max_depth)


# Dumps everything we can introspect about the editor state. Helps diagnose
# why injection isn't working — what's the tool actually named, where is it.
func _log_discovery_dump():
	outputlog("=== DISCOVERY DUMP ===", 0)
	if global.Editor == null:
		outputlog("global.Editor is null!", 0)
		return
	# Tools
	if global.Editor.get("Tools") != null:
		var tools = global.Editor.Tools
		if tools is Dictionary:
			outputlog("Tools (%d): %s" % [tools.size(), str(tools.keys())], 0)
	# Toolset.Panels
	if global.Editor.get("Toolset") != null:
		var ts = global.Editor.Toolset
		# Try to enumerate panels by guessing common Tool names
		var guesses = ["LevelSettings", "LevelTool", "Levels", "LevelManager",
			"SelectTool", "ObjectTool", "WallTool", "PathTool", "RoofTool"]
		for g in guesses:
			var p = ts.GetToolPanel(g)
			outputlog("  Toolset.GetToolPanel('%s') = %s" % [g, "found" if p != null else "null"], 0)
	# Windows
	if global.Editor.get("Windows") != null:
		var w = global.Editor.Windows
		if w is Dictionary:
			outputlog("Windows (%d): %s" % [w.size(), str(w.keys())], 0)
	outputlog("=== END DUMP ===", 0)


# DropShadowObjects' SelectTool panel exposes a Quality row (label + lock
# toggle + slider + spin + apply-to-all). With the global quality now driven
# from LevelSettings, this row would let the user desync state. Hide it.
var _hide_quality_logged = false
func _hide_individual_object_quality_controls():
	if dropshadow_objects == null:
		return
	var cfg = dropshadow_objects.ui_config
	if cfg == null:
		return
	var slider = cfg.get("quality_slider", null)
	if slider == null or not is_instance_valid(slider):
		return
	var row = slider.get_parent()
	if row == null or not is_instance_valid(row):
		return
	if row.visible:
		row.visible = false
		if not _hide_quality_logged:
			outputlog("Hid quality row in objects SelectTool panel", 0)
			_hide_quality_logged = true


func _find_descendant_by_name(node, target_name):
	if node == null:
		return null
	for child in node.get_children():
		if str(child.name) == target_name:
			return child
		var found = _find_descendant_by_name(child, target_name)
		if found != null:
			return found
	return null


# Builds the mod's autonomous shadow controls (rendering mode, quality,
# enable/disable scope, manual bake) and adds them to the given container —
# the Soft Shadows tool panel (Effects category). The per-level cloud icons
# are handled separately and stay on the native LevelSettings tree.
func build_tool_controls(container):
	_injected_root = VBoxContainer.new()
	_injected_root.name = "DropShadowLevelControls"
	_injected_root.add_constant_override("separation", 12)

	# Row 1: action + scope + apply
	var row1 = HBoxContainer.new()
	row1.add_constant_override("separation", 6)

	_action_option = OptionButton.new()
	_action_option.add_item("Enable", 0)
	_action_option.add_item("Disable", 1)
	_action_option.selected = 0
	_action_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_action_option)

	_scope_option = OptionButton.new()
	_scope_option.add_item("All Levels", 0)
	_scope_option.add_item("Current Level", 1)
	_scope_option.add_item("Other Levels", 2)
	_scope_option.selected = 0
	_scope_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_scope_option)

	_apply_button = Button.new()
	_apply_button.text = "Apply"
	_apply_button.connect("pressed", self, "_on_apply_pressed")
	# Wrap in a PanelContainer for a 1px white outline (same as the bake button).
	var apply_frame = PanelContainer.new()
	var apply_sb = StyleBoxFlat.new()
	apply_sb.bg_color = Color(0, 0, 0, 0)
	apply_sb.set_border_width_all(1)
	apply_sb.border_color = Color(1, 1, 1, 1)
	apply_sb.set_content_margin_all(0)
	apply_frame.add_stylebox_override("panel", apply_sb)
	apply_frame.add_child(_apply_button)
	row1.add_child(apply_frame)

	_injected_root.add_child(row1)

	# Row 2: global quality slider
	var row2 = HBoxContainer.new()
	row2.add_constant_override("separation", 6)
	var qlbl = Label.new()
	qlbl.text = "Quality:"
	row2.add_child(qlbl)

	_quality_slider = HSlider.new()
	_quality_slider.min_value = 0
	_quality_slider.max_value = 100
	_quality_slider.step = 5
	_quality_slider.value = global.ModMapData.get(QUALITY_KEY, 100)
	_quality_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quality_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_quality_slider.hint_tooltip = "Global quality for object shadows on every level. Replaces per-object settings."
	_quality_slider.connect("value_changed", self, "_on_quality_slider_changed")
	row2.add_child(_quality_slider)

	_quality_label = Label.new()
	_quality_label.text = str(int(_quality_slider.value))
	_quality_label.rect_min_size = Vector2(32, 0)
	row2.add_child(_quality_label)

	_injected_root.add_child(row2)

	# Row: bake mode — single dropdown (Live / Bake Auto / Bake Manual).
	# Item ids match the BAKE_MODE_* enum directly.
	var row3 = HBoxContainer.new()
	row3.add_constant_override("separation", 6)
	var mlbl = Label.new()
	mlbl.text = "Rendering:"
	row3.add_child(mlbl)

	_bake_mode_option = OptionButton.new()
	_bake_mode_option.add_item("Live", BAKE_MODE_LIVE)
	_bake_mode_option.add_item("Bake Auto", BAKE_MODE_AUTO)
	_bake_mode_option.add_item("Bake Manual", BAKE_MODE_MANUAL)
	_bake_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bake_mode_option.hint_tooltip = "Live = shader shadows (no baking). Bake Auto = bake automatically after edits. Bake Manual = stay live and bake on demand."
	_bake_mode_option.connect("item_selected", self, "_on_bake_mode_changed")
	row3.add_child(_bake_mode_option)

	# "Apply" — bake existing live object shadows now. Only relevant (and only
	# shown) in Bake Auto: switching Live -> Bake Auto otherwise leaves existing
	# shadows live until the next edit / reload.
	var rapply = Button.new()
	rapply.text = "Apply"
	rapply.hint_tooltip = "Bake existing object shadows now, on every level."
	rapply.connect("pressed", self, "_on_rendering_apply_pressed")
	_rendering_apply_frame = PanelContainer.new()
	var rapply_sb = StyleBoxFlat.new()
	rapply_sb.bg_color = Color(0, 0, 0, 0)
	rapply_sb.set_border_width_all(1)
	rapply_sb.border_color = Color(1, 1, 1, 1)
	rapply_sb.set_content_margin_all(0)
	_rendering_apply_frame.add_stylebox_override("panel", rapply_sb)
	_rendering_apply_frame.add_child(rapply)
	row3.add_child(_rendering_apply_frame)

	_injected_root.add_child(row3)

	# Explanation of the currently-selected rendering mode (updates on change).
	_bake_mode_desc = Label.new()
	_bake_mode_desc.autowrap = true
	_bake_mode_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bake_mode_desc.add_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
	_injected_root.add_child(_bake_mode_desc)

	# Row: manual bake (scope + button) — only visible when mode == Bake Manual
	_bake_manual_row = HBoxContainer.new()
	_bake_manual_row.add_constant_override("separation", 6)

	_bake_scope_option = OptionButton.new()
	_bake_scope_option.add_item("All Levels", 0)
	_bake_scope_option.add_item("Current Level", 1)
	_bake_scope_option.add_item("Other Levels", 2)
	_bake_scope_option.selected = 0
	_bake_scope_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bake_manual_row.add_child(_bake_scope_option)

	_bake_button = Button.new()
	_bake_button.text = "Bake object shadows"
	_bake_button.connect("pressed", self, "_on_bake_now_pressed")
	# Wrap in a PanelContainer so we can draw a 1px white outline around it
	# without overriding the button's own themed look.
	var bake_btn_frame = PanelContainer.new()
	var bake_btn_sb = StyleBoxFlat.new()
	bake_btn_sb.bg_color = Color(0, 0, 0, 0)
	bake_btn_sb.set_border_width_all(1)
	bake_btn_sb.border_color = Color(1, 1, 1, 1)
	bake_btn_sb.set_content_margin_all(0)
	bake_btn_frame.add_stylebox_override("panel", bake_btn_sb)
	bake_btn_frame.add_child(_bake_button)
	_bake_manual_row.add_child(bake_btn_frame)
	_injected_root.add_child(_bake_manual_row)

	_sync_bake_ui_from_mode()

	if container != null:
		# Wrap in a MarginContainer to add breathing room at the top and on the
		# right side (content was flush against the panel edges).
		var margin = MarginContainer.new()
		margin.add_constant_override("margin_top", 12)
		margin.add_constant_override("margin_right", 10)
		margin.add_constant_override("margin_left", 2)
		margin.add_constant_override("margin_bottom", 4)
		margin.add_child(_injected_root)
		container.add_child(margin)

#########################################################################################################
## TREE DECORATION (cloud icon per level row)
#########################################################################################################

# Each TreeItem in DD's level tree holds a Level instance in its "meta" metadata.
# We attach a cloud icon to the row via set_icon() on a dedicated column.
# Since DD's tree appears to be single-column, we re-use column 0's icon slot
# but only when our state says the level is disabled. For enabled levels, we
# keep DD's original (no) icon.

func _compute_tree_signature() -> String:
	if _level_tree == null:
		return ""
	var root = _level_tree.get_root()
	if root == null:
		return ""
	var sig = ""
	var item = root.get_children()
	while item != null:
		var lvl_name = ""
		if item.has_meta("meta"):
			var lvl = item.get_meta("meta")
			if lvl != null and is_instance_valid(lvl):
				lvl_name = str(lvl.name)
		sig += lvl_name + "|"
		item = item.get_next()
	return sig


# Walks the tree, applies the on/off cloud icon based on our state.
func _decorate_tree_rows():
	if _level_tree == null or not is_instance_valid(_level_tree):
		return
	var root = _level_tree.get_root()
	if root == null:
		return
	# We connect a button-clicked handler once per tree (not per row)
	_ensure_tree_click_handler()
	# Use an extra column for our icon-as-button. If the tree only has 1
	# column, we increment its columns count to 2. (Safe — DD treats unused
	# columns as empty.)
	if _level_tree.columns < 2:
		_level_tree.columns = 2
		_level_tree.set_column_expand(0, true)
		_level_tree.set_column_expand(1, false)
		# 38px = 28px icon + padding
		_level_tree.set_column_min_width(1, 38)

	var item = root.get_children()
	while item != null:
		if item.has_meta("meta"):
			var lvl = item.get_meta("meta")
			var lvl_name = str(lvl.name) if (lvl != null and is_instance_valid(lvl)) else ""
			var is_disabled = _is_level_disabled(lvl_name)
			# Hover always wins → white. Otherwise blue if enabled, grey if disabled.
			var icon
			if item == _hovered_item:
				icon = _cloud_icon_hover
			elif not is_disabled:
				icon = _cloud_icon_on
			else:
				icon = _cloud_icon_off
			# Clear any pre-existing button on column 1 (from a previous decorate pass)
			# erase_button() expects (column, index) - remove button 0 if it exists.
			while item.get_button_count(1) > 0:
				item.erase_button(1, 0)
			# add_button() signature: (column, button: Texture, button_idx=-1, disabled=false, tooltip="")
			if icon != null:
				item.add_button(1, icon, -1, false,
					"Disabled — click to enable" if is_disabled else "Enabled — click to disable")
		item = item.get_next()


# Connect once — Tree fires "button_pressed" with (item, column, id) when a
# button placed via set_button() is clicked.
var _tree_click_connected = false
func _ensure_tree_click_handler():
	if _tree_click_connected:
		return
	if _level_tree.is_connected("button_pressed", self, "_on_tree_button_pressed"):
		_tree_click_connected = true
		return
	_level_tree.connect("button_pressed", self, "_on_tree_button_pressed")
	_tree_click_connected = true


func _on_tree_button_pressed(item, column, _id):
	if column != 1:
		return
	if not item.has_meta("meta"):
		return
	var lvl = item.get_meta("meta")
	if lvl == null or not is_instance_valid(lvl):
		return
	var lvl_name = str(lvl.name)
	var did_enable = false
	if _is_level_disabled(lvl_name):
		_enable_level(lvl)
		did_enable = true
	else:
		_disable_level(lvl)
	_decorate_tree_rows()
	if shadow_toggle != null:
		shadow_toggle.refresh_after_level_change()
	if did_enable:
		_queue_auto_bake_for_levels([lvl])

#########################################################################################################
## CONTROL ROW HANDLERS
#########################################################################################################

func _on_apply_pressed():
	if _action_option == null or _scope_option == null:
		return
	var action_idx = _action_option.selected
	var scope_idx = _scope_option.selected
	var levels = _get_scoped_levels(scope_idx)
	outputlog("Apply action=%d scope=%d -> %d level(s)" % [action_idx, scope_idx, levels.size()], 0)
	for level in levels:
		if action_idx == 0:
			_enable_level(level)
		else:
			_disable_level(level)
	_decorate_tree_rows()
	if shadow_toggle != null:
		shadow_toggle.refresh_after_level_change()
	if action_idx == 0:
		_queue_auto_bake_for_levels(levels)


# Authoritative list of the map's real Level nodes (NOT the children of the
# World node, which also include Bounds/ExportFX/GridMesh/etc.). Uses the
# documented World.levels property, with a defensive fallback.
func _all_levels() -> Array:
	var lv = global.World.get("levels")
	if lv is Array:
		var out = []
		for l in lv:
			if is_instance_valid(l):
				out.append(l)
		return out
	# Fallback (older API): enumerate the current level's parent. Note this can
	# over-count, but only triggers if World.levels is unavailable.
	var current = global.World.GetCurrentLevel()
	if current == null:
		return []
	var world_root = current.get_parent()
	if world_root == null:
		return [current]
	var fb = []
	for i in range(world_root.get_child_count()):
		var c = world_root.get_child(i)
		if is_instance_valid(c):
			fb.append(c)
	return fb


func _get_scoped_levels(scope_idx) -> Array:
	var all = _all_levels()
	var current = global.World.GetCurrentLevel()
	match scope_idx:
		0: return all                                  # All Levels
		1: return [current] if current != null else [] # Current Level
		2:                                             # Other Levels
			var out = []
			for l in all:
				if l != current:
					out.append(l)
			return out
	return []


#########################################################################################################
## BAKE MODE CONTROLS (objects-only)
#########################################################################################################

func _current_bake_mode() -> int:
	return int(global.ModMapData.get(BAKE_MODE_KEY, BAKE_MODE_AUTO))


# The single OptionButton's item ids ARE the enum values, so selection maps
# straight through.
func _compute_bake_mode_from_ui() -> int:
	if _bake_mode_option == null:
		return BAKE_MODE_AUTO
	return _bake_mode_option.get_selected_id()


func _persist_bake_mode():
	var mode = _compute_bake_mode_from_ui()
	global.ModMapData[BAKE_MODE_KEY] = mode   # per-map runtime value
	_save_global_bake_mode(mode)              # remembered across maps
	_update_bake_ui_visibility()


# Read the user's saved rendering mode from user://. Returns AUTO if the file
# is missing or unreadable (preserves the original default).
func _load_global_bake_mode() -> int:
	var cfg = ConfigFile.new()
	if cfg.load(GLOBAL_CFG_PATH) != OK:
		return BAKE_MODE_AUTO
	var mode = int(cfg.get_value(GLOBAL_CFG_SECTION, GLOBAL_CFG_MODE_KEY, BAKE_MODE_AUTO))
	if mode < BAKE_MODE_LIVE or mode > BAKE_MODE_MANUAL:
		return BAKE_MODE_AUTO
	return mode


# Write the user's rendering mode to user:// so it carries over between maps.
func _save_global_bake_mode(mode):
	var cfg = ConfigFile.new()
	cfg.load(GLOBAL_CFG_PATH)  # ignore error; preserves any other keys if present
	cfg.set_value(GLOBAL_CFG_SECTION, GLOBAL_CFG_MODE_KEY, int(mode))
	if cfg.save(GLOBAL_CFG_PATH) != OK:
		outputlog("Could not save rendering mode preference", 0)


# Initialise the dropdown from the persisted mode (default AUTO).
func _sync_bake_ui_from_mode():
	if _bake_mode_option == null:
		return
	var idx = _bake_mode_option.get_item_index(_current_bake_mode())
	if idx >= 0:
		_bake_mode_option.selected = idx
	_update_bake_ui_visibility()


# Manual row visible only in Bake Manual.
func _update_bake_ui_visibility():
	if _bake_mode_option == null:
		return
	var mode = _bake_mode_option.get_selected_id()
	if _bake_manual_row != null and is_instance_valid(_bake_manual_row):
		_bake_manual_row.visible = mode == BAKE_MODE_MANUAL
	# Apply (bake now) only matters in Bake Auto.
	if _rendering_apply_frame != null and is_instance_valid(_rendering_apply_frame):
		_rendering_apply_frame.visible = mode == BAKE_MODE_AUTO
	_update_bake_mode_desc()


# Sets the explanation text under the Rendering dropdown for the current mode.
func _update_bake_mode_desc():
	if _bake_mode_desc == null or not is_instance_valid(_bake_mode_desc):
		return
	if _bake_mode_option == null:
		return
	var txt = ""
	match _bake_mode_option.get_selected_id():
		BAKE_MODE_LIVE:
			txt = "Shadows are drawn live by a shader. No baked textures (lowest memory), but a higher GPU cost every frame."
		BAKE_MODE_AUTO:
			txt = "Shadows bake to a texture automatically after each edit. Lower per-frame GPU cost, uses a bit more memory."
		BAKE_MODE_MANUAL:
			txt = "Shadows stay live while you edit, then bake on demand with the button below. Hybrid of Live and Bake Auto."
	_bake_mode_desc.text = txt


func _on_bake_mode_changed(_idx):
	_persist_bake_mode()


# "Apply" next to Rendering — bake every live object shadow now (all levels).
# No-op outside Bake Auto (button is hidden then anyway).
func _on_rendering_apply_pressed():
	var levels = _all_levels()
	outputlog("Rendering Apply: baking object shadows on %d level(s)" % levels.size(), 0)
	_queue_auto_bake_for_levels(levels)


func _on_bake_now_pressed():
	if dropshadow_objects == null or _bake_scope_option == null:
		return
	var levels = _get_scoped_levels(_bake_scope_option.selected)
	var owners = _collect_bakeable_object_owners(levels)
	outputlog("Manual bake: %d object(s) queued (scope=%d)" % [owners.size(), _bake_scope_option.selected], 0)
	if owners.size() == 0:
		return
	dropshadow_objects.bake_objects_sequential(owners)


# In AUTO mode, route a freshly-enabled batch of object shadows through the
# serial bake queue (one viewport at a time) instead of letting every object's
# debounce fire at once. No-op in Live/Manual (nothing auto-bakes). Objects
# placed one-by-one still use the per-prop debounce (this is only called on
# enable / map-load batches).
func _queue_auto_bake_for_levels(levels):
	if dropshadow_objects == null:
		return
	if int(global.ModMapData.get(BAKE_MODE_KEY, BAKE_MODE_AUTO)) != BAKE_MODE_AUTO:
		return
	var owners = _collect_bakeable_object_owners(levels)
	if owners.size() > 0:
		dropshadow_objects.bake_objects_sequential(owners)


# Object owners on the scoped levels that have a live (un-baked) shadow.
# Disabled levels have no shadow nodes, so their objects are skipped naturally.
func _collect_bakeable_object_owners(levels) -> Array:
	var out = []
	var meta_key = META_KEYS["objects"]
	var container_name = CONTAINER_NAMES["objects"]
	for level in levels:
		if level == null or not is_instance_valid(level):
			continue
		var container = level.get_node_or_null(container_name)
		if container == null:
			continue
		for child in container.get_children():
			if not child.has_meta(meta_key):
				continue
			if dropshadow_objects.is_object_baked(child):
				continue
			out.append(child)
	return out


# Slider drag — debounced via the change handler is fine for now since the
# user typically settles on a value. If perf becomes an issue, add a Timer
# with 200ms debounce here.
func _on_quality_slider_changed(value):
	var v = int(value)
	if _quality_label != null:
		_quality_label.text = str(v)
	global.ModMapData[QUALITY_KEY] = v
	_apply_global_quality(v)


# Walks every object shadow on every level and rebuilds with the new quality.
# Walls / paths / roofs ignored — quality is an objects-only setting.
func _apply_global_quality(quality_value):
	if dropshadow_objects == null:
		return
	var data_key = SHADOW_DATA_KEYS["objects"]
	if not global.ModMapData.has(data_key):
		return
	var data = global.ModMapData[data_key]
	var current = global.World.GetCurrentLevel()
	if current == null:
		return
	var world_root = current.get_parent()
	if world_root == null:
		return
	var count = 0
	for i in range(world_root.get_child_count()):
		var level = world_root.get_child(i)
		if not is_instance_valid(level):
			continue
		var container = level.get_node_or_null(CONTAINER_NAMES["objects"])
		if container == null:
			continue
		for child in container.get_children():
			if not child.has_meta("node_id"):
				continue
			var node_id = str(child.get_meta("node_id"))
			if not data.has(node_id):
				continue
			var cfg = data[node_id]
			if not (cfg is Dictionary):
				continue
			cfg["quality"] = quality_value
			# Only rebuild the shadow if one currently exists. Disabled levels
			# will get the new quality when re-enabled (cfg is updated above).
			if child.has_meta(META_KEYS["objects"]) and cfg.get("enabled", false):
				dropshadow_objects.remove_shadow(child)
				dropshadow_objects.create_shadow(child, cfg)
				count += 1
	outputlog("Applied quality=%d to %d object shadow(s)" % [quality_value, count], 0)

#########################################################################################################
## ENABLE / DISABLE (per level)
#########################################################################################################

func _is_level_disabled(level_name) -> bool:
	if level_name == "":
		return false
	var root = global.ModMapData.get(STATE_KEY, {})
	if not root.has(level_name):
		return false
	var s = root[level_name]
	if not (s is Dictionary):
		return false
	# Explicit "disabled" marker has priority — set by the first-open init
	# and by every Disable action.
	if s.get("disabled", false):
		return true
	# Backwards-compatible: also treat any non-empty tracked _ids list as disabled.
	for at in ASSET_TYPES:
		var ids = s.get(at + "_ids", [])
		if ids is Array and ids.size() > 0:
			return true
	return false


func _disable_level(level):
	if level == null or not is_instance_valid(level):
		return
	_force_level_disabled_marker(level.name)
	for at in ASSET_TYPES:
		_disable_level_asset(level, at)
	_disable_level_obj_overlays(level)
	_disable_level_path_overlays(level)


func _enable_level(level):
	if level == null or not is_instance_valid(level):
		return
	# Clear the marker first — otherwise _is_level_disabled stays true
	# and the sweep would immediately undo our enable.
	var root = global.ModMapData.get(STATE_KEY, {})
	if root.has(level.name) and root[level.name] is Dictionary:
		root[level.name].erase("disabled")
	for at in ASSET_TYPES:
		_enable_level_asset(level, at)
	_enable_level_obj_overlays(level)
	_enable_level_path_overlays(level)
	# Clean up the level entry if everything's empty
	_tidy_state(level.name)


# Set cfg.enabled=false on every owner with a saved enabled shadow under the
# given (level, asset) and remove their shadow nodes. Tracks the ids.
func _disable_level_asset(level, asset_type):
	var module = _module_for(asset_type)
	if module == null:
		return
	var container = level.get_node_or_null(CONTAINER_NAMES[asset_type])
	if container == null:
		return
	var data_key = SHADOW_DATA_KEYS[asset_type]
	if not global.ModMapData.has(data_key):
		return
	var shadow_data = global.ModMapData[data_key]
	var meta_key = META_KEYS[asset_type]

	# Snapshot first — remove_shadow may mutate iteration
	var matching = []
	for child in container.get_children():
		var is_match = false
		if asset_type == "roofs":
			is_match = module.is_roof(child)
		else:
			is_match = module.is_shadow_node_type(child)
		if is_match and child.has_meta("node_id"):
			matching.append(child)

	var newly_disabled = []
	for child in matching:
		if not is_instance_valid(child):
			continue
		var node_id = str(child.get_meta("node_id"))
		if not shadow_data.has(node_id):
			continue
		var cfg = shadow_data[node_id]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		cfg["enabled"] = false
		newly_disabled.append(node_id)
		if asset_type == "roofs" and module._configs_by_id != null:
			var iid = child.get_instance_id()
			if module._configs_by_id.has(iid):
				module._configs_by_id[iid]["enabled"] = false
		if child.has_meta(meta_key):
			module.remove_shadow(child)

	if newly_disabled.size() == 0:
		return
	var existing = _get_disabled_ids(level.name, asset_type)
	for nid in newly_disabled:
		if not existing.has(nid):
			existing.append(nid)
	_set_disabled_ids(level.name, asset_type, existing)


func _enable_level_asset(level, asset_type):
	var module = _module_for(asset_type)
	if module == null:
		return
	var ids = _get_disabled_ids(level.name, asset_type)
	if ids.size() == 0:
		return
	var data_key = SHADOW_DATA_KEYS[asset_type]
	if not global.ModMapData.has(data_key):
		_set_disabled_ids(level.name, asset_type, [])
		return
	var shadow_data = global.ModMapData[data_key]
	var meta_key = META_KEYS[asset_type]
	# Apply the global quality override (if any) when reviving objects
	var override_quality = global.ModMapData.get(QUALITY_KEY, null)

	for node_id in ids:
		if not shadow_data.has(node_id):
			continue
		var cfg = shadow_data[node_id]
		cfg["enabled"] = true
		if asset_type == "objects" and override_quality != null:
			cfg["quality"] = override_quality
		var int_id = int(node_id)
		if not global.World.HasNodeID(int_id):
			continue
		var owner = global.World.GetNodeByID(int_id)
		if owner == null or not is_instance_valid(owner):
			continue
		if asset_type == "roofs" and module._configs_by_id != null:
			var iid = owner.get_instance_id()
			if module._configs_by_id.has(iid):
				module._configs_by_id[iid]["enabled"] = true
		if not owner.has_meta(meta_key):
			module.create_shadow(owner, cfg)

	_set_disabled_ids(level.name, asset_type, [])

#########################################################################################################
## OBJECT (FORM) OVERLAY SHADOWS — masked alongside drop shadows on disabled levels
#########################################################################################################

# Strip enabled object-overlay shadows on a disabled level: flip cfg.enabled,
# remove the overlay node, and track the id under the "obj_overlays" type so
# Enable can revive it. Walks Objects + Roofs (overlays can live on both).
func _disable_level_obj_overlays(level):
	if overlay_shadow_objects == null:
		return
	if not global.ModMapData.has(OBJ_OVERLAY_DATA_KEY):
		return
	var data = global.ModMapData[OBJ_OVERLAY_DATA_KEY]
	var newly_disabled = []
	for cont_name in OBJ_OVERLAY_CONTAINERS:
		var cont = level.get_node_or_null(cont_name)
		if cont == null:
			continue
		# Snapshot first — remove_shadow may mutate the child list.
		var matching = []
		for child in cont.get_children():
			if overlay_shadow_objects.is_obj(child) and child.has_meta("node_id"):
				matching.append(child)
		for child in matching:
			if not is_instance_valid(child):
				continue
			var nid = str(child.get_meta("node_id"))
			if not data.has(nid):
				continue
			var cfg = data[nid]
			if not (cfg is Dictionary) or not cfg.get("enabled", false):
				continue
			cfg["enabled"] = false
			newly_disabled.append(nid)
			if child.has_meta(OBJ_OVERLAY_META_KEY):
				overlay_shadow_objects.remove_shadow(child)
	if newly_disabled.size() == 0:
		return
	var existing = _get_disabled_ids(level.name, "obj_overlays")
	for nid in newly_disabled:
		if not existing.has(nid):
			existing.append(nid)
	_set_disabled_ids(level.name, "obj_overlays", existing)


func _enable_level_obj_overlays(level):
	if overlay_shadow_objects == null:
		return
	var ids = _get_disabled_ids(level.name, "obj_overlays")
	if ids.size() == 0:
		return
	if not global.ModMapData.has(OBJ_OVERLAY_DATA_KEY):
		_set_disabled_ids(level.name, "obj_overlays", [])
		return
	var data = global.ModMapData[OBJ_OVERLAY_DATA_KEY]
	for nid in ids:
		if not data.has(nid):
			continue
		var cfg = data[nid]
		cfg["enabled"] = true
		var iid = int(nid)
		if not global.World.HasNodeID(iid):
			continue
		var owner = global.World.GetNodeByID(iid)
		if owner == null or not is_instance_valid(owner):
			continue
		if not owner.has_meta(OBJ_OVERLAY_META_KEY):
			overlay_shadow_objects.create_shadow(owner, cfg)
	_set_disabled_ids(level.name, "obj_overlays", [])


# Strip enabled path-overlay shadows on a disabled level: flip cfg.enabled,
# remove the overlay node, and track the id under "path_overlays".
func _disable_level_path_overlays(level):
	if dropshadow_paths == null:
		return
	if not global.ModMapData.has(PATH_OVERLAY_DATA_KEY):
		return
	var data = global.ModMapData[PATH_OVERLAY_DATA_KEY]
	var cont = level.get_node_or_null(PATH_OVERLAY_CONTAINER)
	if cont == null:
		return
	var matching = []
	for child in cont.get_children():
		if dropshadow_paths.is_shadow_node_type(child) and child.has_meta("node_id"):
			matching.append(child)
	var newly_disabled = []
	for child in matching:
		if not is_instance_valid(child):
			continue
		var nid = str(child.get_meta("node_id"))
		if not data.has(nid):
			continue
		var cfg = data[nid]
		if not (cfg is Dictionary) or not cfg.get("enabled", false):
			continue
		cfg["enabled"] = false
		newly_disabled.append(nid)
		if child.has_meta(PATH_OVERLAY_META_KEY):
			dropshadow_paths.remove_overlay_shadow(child)
	if newly_disabled.size() == 0:
		return
	var existing = _get_disabled_ids(level.name, "path_overlays")
	for nid in newly_disabled:
		if not existing.has(nid):
			existing.append(nid)
	_set_disabled_ids(level.name, "path_overlays", existing)


func _enable_level_path_overlays(level):
	if dropshadow_paths == null:
		return
	var ids = _get_disabled_ids(level.name, "path_overlays")
	if ids.size() == 0:
		return
	if not global.ModMapData.has(PATH_OVERLAY_DATA_KEY):
		_set_disabled_ids(level.name, "path_overlays", [])
		return
	var data = global.ModMapData[PATH_OVERLAY_DATA_KEY]
	for nid in ids:
		if not data.has(nid):
			continue
		var cfg = data[nid]
		cfg["enabled"] = true
		var iid = int(nid)
		if not global.World.HasNodeID(iid):
			continue
		var owner = global.World.GetNodeByID(iid)
		if owner == null or not is_instance_valid(owner):
			continue
		if not owner.has_meta(PATH_OVERLAY_META_KEY):
			dropshadow_paths.create_overlay_shadow(owner, cfg)
	_set_disabled_ids(level.name, "path_overlays", [])

#########################################################################################################
## STATE HELPERS
#########################################################################################################

func _get_disabled_ids(level_name, asset_type) -> Array:
	var root = global.ModMapData.get(STATE_KEY, {})
	if not root.has(level_name):
		return []
	var s = root[level_name]
	if not (s is Dictionary):
		return []
	var ids = s.get(asset_type + "_ids", [])
	if ids is Array:
		return ids
	return []


func _set_disabled_ids(level_name, asset_type, ids):
	if not global.ModMapData.has(STATE_KEY):
		global.ModMapData[STATE_KEY] = {}
	var root = global.ModMapData[STATE_KEY]
	if not root.has(level_name):
		root[level_name] = {}
	root[level_name][asset_type + "_ids"] = ids
	_tidy_state(level_name)


func _tidy_state(level_name):
	var root = global.ModMapData.get(STATE_KEY, {})
	if not root.has(level_name):
		return
	var s = root[level_name]
	if not (s is Dictionary):
		root.erase(level_name)
		return
	# Keep the entry alive if it carries the disabled marker or any tracked ids
	# (drop-shadow asset types OR object overlays).
	if s.get("disabled", false):
		return
	var any_ids = false
	for at in ASSET_TYPES:
		var ids = s.get(at + "_ids", [])
		if ids is Array and ids.size() > 0:
			any_ids = true
			break
	if not any_ids:
		var ov_ids = s.get("obj_overlays_ids", [])
		if ov_ids is Array and ov_ids.size() > 0:
			any_ids = true
	if not any_ids:
		var pov_ids = s.get("path_overlays_ids", [])
		if pov_ids is Array and pov_ids.size() > 0:
			any_ids = true
	if not any_ids:
		root.erase(level_name)


func _module_for(asset_type):
	match asset_type:
		"objects": return dropshadow_objects
		"walls":   return dropshadow_walls
		"paths":   return dropshadow_paths
		"roofs":   return dropshadow_roofs
	return null

#########################################################################################################
## MAP-LOAD INTEGRATION (pre/post around modules' apply_saved_shadows_to_map)
#########################################################################################################

# Called BEFORE the modules — mutate ModMapData so the modules skip shadows
# that should remain disabled. Avoids the create-then-destroy flash.
func pre_apply_state():
	# Replay the persisted per-level disabled_ids. On first open there are none,
	# so shadows stay enabled by default.
	var root = global.ModMapData.get(STATE_KEY, {})
	for level_name in root.keys():
		var s = root[level_name]
		if not (s is Dictionary):
			continue
		for at in ASSET_TYPES:
			var ids = s.get(at + "_ids", [])
			if not (ids is Array):
				continue
			var data_key = SHADOW_DATA_KEYS[at]
			if not global.ModMapData.has(data_key):
				continue
			var shadow_data = global.ModMapData[data_key]
			for nid in ids:
				if not shadow_data.has(nid):
					continue
				var cfg = shadow_data[nid]
				if cfg is Dictionary:
					cfg["enabled"] = false
		# Object overlays tracked on this disabled level — same treatment so the
		# overlay module skips them on load (no create-then-destroy flash).
		var ov_ids = s.get("obj_overlays_ids", [])
		if ov_ids is Array and global.ModMapData.has(OBJ_OVERLAY_DATA_KEY):
			var ov_data = global.ModMapData[OBJ_OVERLAY_DATA_KEY]
			for ovid in ov_ids:
				if ov_data.has(ovid) and ov_data[ovid] is Dictionary:
					ov_data[ovid]["enabled"] = false
		# Path overlays — same.
		var pov_ids = s.get("path_overlays_ids", [])
		if pov_ids is Array and global.ModMapData.has(PATH_OVERLAY_DATA_KEY):
			var pov_data = global.ModMapData[PATH_OVERLAY_DATA_KEY]
			for povid in pov_ids:
				if pov_data.has(povid) and pov_data[povid] is Dictionary:
					pov_data[povid]["enabled"] = false


# Called AFTER the modules — finalises first-open state.
func apply_saved_state():
	if not global.ModMapData.get(INIT_FLAG_KEY, false):
		# First open: leave everything enabled (no levels marked disabled).
		global.ModMapData[INIT_FLAG_KEY] = true
		outputlog("First-open: shadows enabled by default", 0)

	# Apply persisted global quality to the (now-created) shadows
	if global.ModMapData.has(QUALITY_KEY):
		_apply_global_quality(global.ModMapData[QUALITY_KEY])
		if _quality_slider != null:
			_quality_slider.value = global.ModMapData[QUALITY_KEY]

	# Force a redecorate — STATE_KEY may have changed since the last polling
	# pass (e.g. first-open just marked everything disabled). Without this,
	# rows remain visually "enabled" until the user mutates the tree.
	if _injected:
		_decorate_tree_rows()

	# In AUTO mode, bake the just-loaded object shadows through the serial queue
	# (one viewport at a time) instead of letting every debounce fire at once on
	# a freshly opened map.
	_queue_auto_bake_for_levels(_build_levels_by_name_map().values())


# Set a level-level boolean "disabled" alongside the asset_type entries.
# Used as the authoritative "this level is disabled" flag, distinct from
# the per-asset tracked node_ids.
func _force_level_disabled_marker(level_name):
	if not global.ModMapData.has(STATE_KEY):
		global.ModMapData[STATE_KEY] = {}
	var root = global.ModMapData[STATE_KEY]
	if not root.has(level_name):
		root[level_name] = {}
	root[level_name]["disabled"] = true


func _build_levels_by_name_map() -> Dictionary:
	var out = {}
	for l in _all_levels():
		if is_instance_valid(l):
			out[l.name] = l
	return out


func _find_ancestor_level(node, levels_by_name):
	var n = node
	while n != null:
		if levels_by_name.has(n.name):
			return n
		n = n.get_parent()
	return null
