#########################################################################################################
##
## SHADOW TOGGLE - Floatbar button: global Show/Hide for all shadows
##
#########################################################################################################
# Simple visibility toggle. Iterates every shadow node across every level and
# flips .visible. Does NOT touch saved cfg.enabled. The enable/disable feature
# is handled separately by LevelSettingsPatch (per-level granularity).
#
# State: one persistent boolean `hidden` in ModMapData under STATE_KEY.
# Button ON = shadows visible. OFF = shadows hidden.

var global
var reference_to_script = null
var core = null

# Module refs (injected by Core)
var dropshadow_paths = null
var dropshadow_walls = null
var dropshadow_objects = null
var dropshadow_roofs = null

# Cross-link with LevelSettingsPatch — set by Core after both are constructed.
# Used so a Show after an Enable-per-level can refresh visibility on the
# shadows the patch just created.
var level_settings_patch = null

const ENABLE_LOGGING = true
var logging_level = 0

const STATE_KEY = "DropShadowToggleHidden"
const BS_PATTERN_KEY = "BuildingShadowTex"  # mirror of BuildingShadow.BS_TEX_KEY

const ASSET_TYPES = ["objects", "walls", "paths", "roofs"]

const META_KEYS = {
	"objects": "drop_shadow_obj_nodes",
	"walls":   "drop_shadow_nodes",
	"paths":   "drop_shadow_nodes",
	"roofs":   "drop_shadow_nodes"
}
# Overlay (form) shadow meta keys checked IN ADDITION to META_KEYS, so the
# floatbar toggle hides/shows overlays too. Objects use the object-overlay key
# (also possible on roofs); paths use the path-overlay key.
const OVERLAY_META_KEYS = {
	"objects": "overlay_shadow_obj_nodes",
	"walls":   "",
	"paths":   "overlay_shadow_nodes",
	"roofs":   "overlay_shadow_obj_nodes"
}
const CONTAINER_NAMES = {
	"objects": "Objects",
	"walls":   "Walls",
	"paths":   "Pathways",
	"roofs":   "Roofs"
}

var _bar_button = null

func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <ShadowToggle>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	if not global.ModMapData.has(STATE_KEY):
		global.ModMapData[STATE_KEY] = false  # default: shadows visible
	call_deferred("_try_inject_bar_button", 0)
	outputlog("Initialised", 0)


func cleanup():
	if _bar_button != null and is_instance_valid(_bar_button):
		_bar_button.queue_free()
	_bar_button = null

#########################################################################################################
## BAR BUTTON (modeled on grid_ruler.gd / native Grid/Snap/Lighting toggles)
#########################################################################################################

func _try_inject_bar_button(attempt):
	if attempt > 25:
		outputlog("Bar button injection gave up after 25 attempts", 0)
		return
	if _bar_button != null and is_instance_valid(_bar_button):
		return

	var zoom_opts = global.Editor.get("ZoomOptions") if global.Editor else null
	if zoom_opts == null or not is_instance_valid(zoom_opts):
		_retry_inject_bar_button(attempt)
		return
	var parent = zoom_opts.get_parent()
	if parent == null or not is_instance_valid(parent):
		_retry_inject_bar_button(attempt)
		return

	# Find a sibling toggle button (Grid/Snap/Lighting) to clone for theme parity
	var zoom_idx = zoom_opts.get_index()
	var insert_idx = zoom_idx
	var reference_btn = null
	for i in range(zoom_idx - 1, -1, -1):
		var child = parent.get_child(i)
		if child is BaseButton and child.get("toggle_mode") == true:
			var txt = str(child.get("text")) if child.get("text") != null else ""
			if txt != "":
				reference_btn = child
				insert_idx = i + 1
				break

	if reference_btn != null:
		_bar_button = reference_btn.duplicate()
		_disconnect_all_signals(_bar_button)
		if _bar_button.get("icon") != null:
			_bar_button.set("icon", null)
		if _bar_button.get("shortcut") != null:
			_bar_button.set("shortcut", null)
	else:
		_bar_button = CheckButton.new()

	_bar_button.text = "Shadows"
	_bar_button.hint_tooltip = "Show / hide all shadows on every level"
	_bar_button.focus_mode = Control.FOCUS_NONE
	_bar_button.connect("toggled", self, "_on_bar_button_toggled")
	parent.add_child(_bar_button)
	parent.move_child(_bar_button, insert_idx)
	outputlog("Bar button injected at index %d" % insert_idx, 0)

	_sync_bar_button()


func _disconnect_all_signals(n):
	if n == null:
		return
	for sig in n.get_signal_list():
		for c in n.get_signal_connection_list(sig.name):
			if n.is_connected(sig.name, c.target, c.method):
				n.disconnect(sig.name, c.target, c.method)


func _retry_inject_bar_button(attempt):
	var tree = global.World.get_tree() if global.World else null
	if tree == null:
		return
	var t = tree.create_timer(0.3)
	t.connect("timeout", self, "_try_inject_bar_button", [attempt + 1])


# Clicking the button flips the global hidden flag and applies it.
func _on_bar_button_toggled(pressed):
	# Button "pressed" (ON) == shadows visible. So hidden = not pressed.
	var want_hidden = not pressed
	global.ModMapData[STATE_KEY] = want_hidden
	_apply_global_visibility()
	outputlog("Toggled: shadows %s" % ("hidden" if want_hidden else "visible"), 0)


# Reflects ModMapData[STATE_KEY] — pressed (ON) when shadows are visible.
func _sync_bar_button():
	if _bar_button == null or not is_instance_valid(_bar_button):
		return
	var hidden = global.ModMapData.get(STATE_KEY, false)
	_set_button_pressed_silent(not hidden)


func _set_button_pressed_silent(pressed):
	if _bar_button.has_method("set_pressed_no_signal"):
		_bar_button.set_pressed_no_signal(pressed)
	else:
		_bar_button.set_block_signals(true)
		_bar_button.pressed = pressed
		_bar_button.set_block_signals(false)

#########################################################################################################
## VISIBILITY APPLICATION
#########################################################################################################

# Walks every level, every asset_type, every shadow node, and applies the
# global hidden flag as .visible. Cheap (just sets a property) — safe to
# call after any structural change to shadows.
func apply_global_visibility():
	_apply_global_visibility()


func _apply_global_visibility():
	var hidden = global.ModMapData.get(STATE_KEY, false)
	var visible = not hidden
	var current = global.World.GetCurrentLevel()
	if current == null:
		return
	var world_root = current.get_parent()
	if world_root == null:
		return
	var total = 0
	for i in range(world_root.get_child_count()):
		var level = world_root.get_child(i)
		if not is_instance_valid(level):
			continue
		for at in ASSET_TYPES:
			total += _apply_visibility_in_level(level, at, visible)
	total += _apply_visibility_building_shadows(visible)
	outputlog("Visibility=%s applied to %d shadow node(s)" % [str(visible), total], 1)


# Building Shadow patterns (created by BuildingShadow.gd) are ordinary DD
# pattern shapes — they are identified through the ModMapData registry the
# module maintains ({node_id: opacity} under BS_PATTERN_KEY, mirrored const).
func _apply_visibility_building_shadows(visible) -> int:
	var rec = global.ModMapData.get(BS_PATTERN_KEY, null)
	if not (rec is Dictionary):
		return 0
	var count = 0
	for k in rec.keys():
		var id = int(k)
		if not global.World.HasNodeID(id):
			continue
		var n = global.World.GetNodeByID(id)
		if n != null and is_instance_valid(n):
			n.visible = visible
			count += 1
	return count


func _apply_visibility_in_level(level, asset_type, visible) -> int:
	var container = level.get_node_or_null(CONTAINER_NAMES[asset_type])
	if container == null:
		return 0
	# Check both the drop-shadow meta and the overlay meta on each child.
	var meta_keys = [META_KEYS[asset_type]]
	var overlay_key = OVERLAY_META_KEYS.get(asset_type, "")
	if overlay_key != "":
		meta_keys.append(overlay_key)
	var count = 0
	for child in container.get_children():
		for meta_key in meta_keys:
			if not child.has_meta(meta_key):
				continue
			var nodes = child.get_meta(meta_key)
			if not (nodes is Array):
				continue
			for n in nodes:
				if is_instance_valid(n):
					n.visible = visible
					count += 1
	return count

#########################################################################################################
## POST-LOAD: re-apply hidden state after modules' apply_saved_shadows_to_map
## Called by Core._on_map_load_timer.
#########################################################################################################

func apply_saved_state():
	_sync_bar_button()
	# Only walk the scene if there's actually something to hide. Default
	# state is visible, which is what fresh shadows are anyway.
	if global.ModMapData.get(STATE_KEY, false):
		_apply_global_visibility()


# Called by LevelSettingsPatch after it has enabled/disabled levels — the
# patch can create new shadow nodes that need their visibility synced with
# the global flag.
func refresh_after_level_change():
	if global.ModMapData.get(STATE_KEY, false):
		_apply_global_visibility()
