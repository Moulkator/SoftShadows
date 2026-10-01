#########################################################################################################
##
## SELECTION SHADOW TOGGLE — one "Soft Shadows" ON/OFF for the whole selection
##
#########################################################################################################
# A single row in the Select Tool options, right under the divider that
# follows the Separate button, shown only for MULTI-TYPE selections that
# contain at least one asset a Soft Shadow module can handle (objects, paths,
# walls, roofs, patterns). Single-type selections already have their own
# section. Overlays are NOT covered.
#
# Displayed state: ON if every compatible asset has a shadow, OFF if none,
# otherwise the majority (tie -> ON). Clicking applies that state to ALL the
# compatible assets of the selection, each type through its own module's
# set_shadow_enabled(nodes, enabled) (per-node settings are kept; assets never
# shadowed get their tool defaults). The per-type sections resync afterwards.

var global
var core = null
var logging_level = 0

var modules = []        # [dropshadow_objects, dropshadow_paths, ...] (set by Core)
var ui = {}
var _syncing = false
var _refresh_timer = null

const ENABLE_LOGGING = true
func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <SelectionShadowToggle>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT / UI
#########################################################################################################

func initialise() -> void:
	var panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		outputlog("SelectTool panel not found", 0)
		return
	var vbox = core.get_align_vbox(panel)
	if vbox == null:
		outputlog("SelectTool Align VBox not found", 0)
		return
	ui["_parent"] = vbox

	var c = VBoxContainer.new()
	c.name = "SelectionShadowToggleContainer"
	var row = HBoxContainer.new()
	var icon = _create_cloud_icon()
	if icon != null:
		row.add_child(icon)
	var title = Label.new()
	title.text = "Soft Shadows"
	title.hint_tooltip = "Turn the soft shadow on / off for every compatible asset of the selection"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var toggle = CheckButton.new()
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.connect("toggled", self, "_on_toggled")
	row.add_child(toggle)
	ui["toggle"] = toggle
	c.add_child(row)
	c.add_child(HSeparator.new())
	ui["container"] = c
	ui["anchor"] = _find_anchor(vbox)

	# Modules toggled individually (their own checkboxes, undo...) change the
	# state without a selection change: keep the row current.
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 0.25
	_refresh_timer.autostart = true
	_refresh_timer.connect("timeout", self, "_on_refresh_tick")
	global.Editor.add_child(_refresh_timer)
	outputlog("Selection Shadow Toggle initialised.", 0)

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var image = Image.new()
	if image.load(global.Root + icon_path) != OK:
		return null
	if scale != 1.0:
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _create_cloud_icon() -> TextureRect:
	var tex = _load_icon("icons/cloud.png", 0.85)
	if tex == null:
		return null
	var rect = TextureRect.new()
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	rect.rect_min_size = Vector2(18, 18)
	return rect

# The HSeparator that DD adds right after its Separate button (found by the
# button's icon). Null -> the row goes at the top of the panel.
func _find_anchor(vbox):
	var sep_btn = null
	for child in vbox.get_children():
		if child is Button and child.icon != null and str(child.icon.resource_path).ends_with("separate.png"):
			sep_btn = child
			break
	if sep_btn == null:
		return null
	for i in range(sep_btn.get_index() + 1, vbox.get_child_count()):
		var c = vbox.get_child(i)
		if c is HSeparator:
			return c
		if c is Button:
			break
	return null

#########################################################################################################
## STATE
#########################################################################################################

func _module_for(node):
	for m in modules:
		if m == null:
			continue
		if m.has_method("has_shadow_enabled") and m.has_method("set_shadow_enabled"):
			if m.has_method("is_shadow_node_type") and m.is_shadow_node_type(node):
				return m
			if m.has_method("is_roof") and m.is_roof(node):
				return m
			if m.has_method("is_pattern") and m.is_pattern(node):
				return m
	return null

# [compatible nodes, number with a shadow ON, number of distinct asset types]
func _scan_selection() -> Array:
	var nodes = []
	var on = 0
	var types = {}
	if global.Editor.ActiveToolName != "SelectTool":
		return [nodes, on, 0]
	var sel = global.Editor.Tools["SelectTool"].Selected
	if sel == null:
		return [nodes, on, 0]
	for node in sel:
		if node == null or not is_instance_valid(node):
			continue
		var m = _module_for(node)
		if m == null:
			types[node.get_class()] = true
			continue
		types["m" + str(m.get_instance_id())] = true
		nodes.append(node)
		if m.has_shadow_enabled(node):
			on += 1
	return [nodes, on, types.size()]

func on_selection_changed() -> void:
	_refresh()

func _on_refresh_tick() -> void:
	if ui.has("container") and ui["container"].get_parent() != null:
		_refresh()

func _refresh() -> void:
	if not ui.has("container"):
		return
	var scan = _scan_selection()
	var nodes = scan[0]
	var on = scan[1]
	var c = ui["container"]
	# Multi-type selections only (a single type has its own section).
	if nodes.empty() or scan[2] < 2:
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
		return
	if c.get_parent() == null:
		var parent = ui["_parent"]
		parent.add_child(c)
		var anchor = ui.get("anchor")
		if anchor != null and is_instance_valid(anchor) and anchor.get_parent() == parent:
			parent.move_child(c, anchor.get_index() + 1)
		else:
			parent.move_child(c, 0)
	# ON = all, OFF = none, else majority (tie -> ON)
	var state = on * 2 >= nodes.size()
	_syncing = true
	ui["toggle"].pressed = state
	_syncing = false

#########################################################################################################
## APPLY
#########################################################################################################

func _on_toggled(pressed: bool) -> void:
	if _syncing:
		return
	var nodes = _scan_selection()[0]
	if nodes.empty():
		return
	# Group by module so each one gets a single call (one history entry each).
	var by_module = {}
	for node in nodes:
		var m = _module_for(node)
		if m == null:
			continue
		var key = m.get_instance_id()
		if not by_module.has(key):
			by_module[key] = {"module": m, "nodes": []}
		by_module[key]["nodes"].append(node)
	for key in by_module.keys():
		by_module[key]["module"].set_shadow_enabled(by_module[key]["nodes"], pressed)
	# Per-type sections (built from the first selected node) resync from data.
	for key in by_module.keys():
		var m = by_module[key]["module"]
		if m.has_method("on_selection_changed"):
			m.on_selection_changed()
	_refresh()
