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
#
# SHARED SETTINGS PANEL (cog on the row): the settings every selected asset
# type has in common (objects, walls, paths, patterns — roofs are ignored).
# Only the setting the user touches is written, to every selected asset whose
# shadow is ON; its other settings stay as they are. A setting whose range
# differs between types is shown as a percentage and mapped proportionally
# onto each type's own range. The values shown are those of the first
# selected asset that uses the setting. Each module applies its part through
# shared_apply() (one history transaction per module).

var global
var core = null
var logging_level = 0

var modules = []        # [dropshadow_objects, dropshadow_paths, ...] (set by Core)
var ui = {}
var _syncing = false
var _refresh_timer = null

# Shared settings panel state
var _entries = []       # [{"node", "module", "type", "cfg"}] — supported, non-roof assets
var _types = []         # distinct types present in _entries
var _rows = {}          # row id -> {"spec", "ctrls"...}
var _dial_max = 100.0   # world px at the dial rim

const ALL_TYPES = ["objects", "walls", "paths", "patterns"]
const LINE_TYPES = ["walls", "paths"]
const DIAL_SIZE = 90
const OFFSET_MAX = 100.0          # px per unit of Max Distance
const PATTERN_OFFSET_MAX = 100.0  # DropShadowPatterns.OFFSET_MAX

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
	var cog = Button.new()
	cog.icon = _load_icon("icons/cog.png", 0.55)
	cog.hint_tooltip = "Show/hide the settings shared by the selected asset types"
	cog.toggle_mode = true
	cog.focus_mode = Control.FOCUS_NONE
	cog.visible = false
	cog.connect("toggled", self, "_on_cog_toggled")
	row.add_child(cog)
	ui["cog"] = cog
	var toggle = CheckButton.new()
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.connect("toggled", self, "_on_toggled")
	row.add_child(toggle)
	ui["toggle"] = toggle
	c.add_child(row)
	var shared = VBoxContainer.new()
	shared.name = "SharedSettings"
	shared.visible = false
	c.add_child(shared)
	ui["shared"] = shared
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

func _is_roof(node) -> bool:
	for m in modules:
		if m != null and m.has_method("is_roof") and m.is_roof(node):
			return true
	return false

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

# True when the selection holds several asset types (Soft Shadow ones or
# not): the per-type sections must then stay hidden, this row takes over.
func is_multi_type_selection() -> bool:
	var scan = _scan_selection()
	return not scan[0].empty() and scan[2] >= 2

func on_selection_changed() -> void:
	_refresh()
	_rebuild_shared_panel()

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
	_rebuild_shared_panel()

#########################################################################################################
## SHARED SETTINGS — SPECS
#########################################################################################################
# kind: "slider" | "check" | "color" | "radio" | "dial"
# ranges: per type [min, max] (sliders). Same range for every present type ->
# native values; otherwise the slider shows 0..100 % (proportional mapping).
# extra: keys written along with the value (e.g. the Blur Control style stamp).

func _blur_style() -> bool:
	if core != null:
		var lsp = core.get("level_settings_patch")
		if lsp != null and lsp.has_method("is_simple_blur_style"):
			return lsp.is_simple_blur_style()
	return true

func _row_specs() -> Array:
	var r = []
	r.append({"id": "opacity", "label": "Opacity", "kind": "slider", "types": ALL_TYPES, "step": 0.01,
		"ranges": {"objects": [0.05, 2.0], "walls": [0.05, 1.0], "paths": [0.05, 1.0], "patterns": [0.05, 2.0]}})
	if _blur_style():
		r.append({"id": "blur", "label": "Blur", "kind": "slider", "types": ALL_TYPES, "step": 0.01,
			"ranges": {"objects": [0.0, 1.0], "walls": [0.0, 1.0], "paths": [0.0, 1.0], "patterns": [0.0, 1.0]},
			"extra": {"slider_style": 1}})
	else:
		r.append({"id": "spread", "label": "Spread", "kind": "slider", "types": ALL_TYPES, "step": 0.01,
			"ranges": {"objects": [0.0, 1.0], "walls": [0.0, 3.0], "paths": [0.0, 3.0], "patterns": [0.0, 100.0]},
			"extra": {"slider_style": 0}})
		r.append({"id": "softness", "label": "Softness", "kind": "slider", "types": ALL_TYPES, "step": 0.01,
			"ranges": {"objects": [0.0, 1.0], "walls": [0.1, 5.0], "paths": [0.1, 5.0], "patterns": [0.0, 200.0]},
			"extra": {"slider_style": 0}})
	r.append({"id": "offset", "label": "", "kind": "dial", "types": ALL_TYPES})
	r.append({"id": "range", "label": "Max Distance", "kind": "slider", "types": ["objects", "walls", "paths"], "step": 0.1,
		"ranges": {"objects": [1.0, 20.0], "walls": [1.0, 20.0], "paths": [1.0, 20.0]}})
	r.append({"id": "shadow_color", "label": "Color", "kind": "color", "types": ALL_TYPES})
	r.append({"id": "custom_layer", "label": "Custom Shadow Layer", "kind": "check", "types": ALL_TYPES})
	r.append({"id": "shadow_layer", "label": "Layer", "kind": "slider", "types": ALL_TYPES, "step": 1, "show_if": "custom_layer",
		"ranges": {"objects": [-500, 1100], "walls": [-500, 1100], "paths": [-500, 1100], "patterns": [-500, 1100]}})
	r.append({"id": "behind_layer", "label": "Shadow behind layer", "kind": "check", "types": ["objects", "paths", "patterns"]})
	# Walls + paths only
	r.append({"id": "render_mode", "label": "", "kind": "radio", "types": LINE_TYPES,
		"names": ["Simple", "Realistic"], "values": ["simple", "realistic"]})
	r.append({"id": "direction", "label": "", "kind": "radio", "types": LINE_TYPES,
		"names": ["Side A", "Side B", "Both"], "values": [0, 1, 2]})
	r.append({"id": "crop_blur", "label": "Crop at Center", "kind": "check", "types": LINE_TYPES, "show_if": "realistic_side"})
	r.append({"id": "crop_ends", "label": "Wrap Ends", "kind": "check", "types": LINE_TYPES, "invert": true, "show_if": "realistic"})
	r.append({"id": "wrap_which", "label": "", "kind": "radio", "types": LINE_TYPES,
		"names": ["Start", "End", "Both"], "values": [0, 1, 2], "default": 2, "show_if": "wrap"})
	r.append({"id": "radial_offset", "label": "Radial Offset", "kind": "slider", "types": LINE_TYPES, "step": 1,
		"ranges": {"walls": [-100, 100], "paths": [-100, 100]}})
	r.append({"id": "side_balance", "label": "Side Balance", "kind": "slider", "types": LINE_TYPES, "step": 1, "show_if": "both_sides",
		"ranges": {"walls": [-100, 100], "paths": [-100, 100]}})
	# (Fade In / Fade Out, Swap Ends and Skip Portals are not listed: the walls
	# panel hides the first three and the paths panel the last one.)
	r.append({"id": "extend_enabled", "label": "Extend Ends with Fade", "kind": "check", "types": LINE_TYPES, "show_if": "simple"})
	r.append({"id": "extend_which", "label": "", "kind": "radio", "types": LINE_TYPES, "show_if": "extend",
		"names": ["Start", "End", "Both"], "values": [0, 1, 2]})
	r.append({"id": "fade_extend", "label": "Shape", "kind": "slider", "types": LINE_TYPES, "step": 0.05, "show_if": "extend",
		"ranges": {"walls": [-1.0, 1.0], "paths": [-1.0, 1.0]}})
	return r

# Config key a row writes for one asset, or "" when the row doesn't apply to it.
func _node_key(row_id: String, type: String, cfg: Dictionary) -> String:
	var realistic = cfg.get("render_mode", "simple") == "realistic"
	match row_id:
		"opacity":
			if type in LINE_TYPES and realistic:
				return "opacity_realistic"
		"blur":
			if type == "objects":
				return "blur"
			if type in LINE_TYPES and realistic:
				return "realistic_blur"
			return "simple_blur"
		"spread", "softness":
			if type in LINE_TYPES and realistic:
				return ""
	return row_id

#########################################################################################################
## SHARED SETTINGS — PANEL
#########################################################################################################

func _on_cog_toggled(pressed: bool) -> void:
	if ui.has("shared"):
		ui["shared"].visible = pressed and not _rows.empty()

func _collect_entries() -> void:
	_entries = []
	_types = []
	for node in _scan_selection()[0]:
		if _is_roof(node):
			continue
		var m = _module_for(node)
		if m == null or not m.has_method("shared_apply") or not m.has_method("shared_saved_config"):
			continue
		var t = m.shared_type()
		_entries.append({"node": node, "module": m, "type": t, "cfg": m.shared_saved_config(node)})
		if not _types.has(t):
			_types.append(t)

func _row_applies(spec: Dictionary) -> bool:
	for t in _types:
		if not spec["types"].has(t):
			return false
	return true

# First (entry, key) using the row, among assets whose shadow is ON.
func _first_value(spec: Dictionary):
	for e in _entries:
		if e["cfg"] == null:
			continue
		var k = _node_key(spec["id"], e["type"], e["cfg"])
		if k == "":
			continue
		if spec["kind"] == "dial":
			return e
		if e["cfg"].has(k):
			return [e, e["cfg"][k]]
		if spec.has("default"):
			return [e, spec["default"]]
	return null

# Native range shared by every present type, or null (-> percent mode).
func _common_range(spec: Dictionary):
	var rng = null
	for t in _types:
		var r = spec["ranges"].get(t)
		if r == null:
			continue
		if rng == null:
			rng = r
		elif rng[0] != r[0] or rng[1] != r[1]:
			return null
	return rng

func _rebuild_shared_panel() -> void:
	if not ui.has("shared"):
		return
	var box = ui["shared"]
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	_rows = {}
	_collect_entries()
	var any_on = false
	for e in _entries:
		if e["cfg"] != null:
			any_on = true
			break
	var c = ui["container"]
	if _entries.empty() or not any_on or c.get_parent() == null:
		ui["cog"].visible = false
		box.visible = false
		return
	_syncing = true
	for spec in _row_specs():
		if not _row_applies(spec):
			continue
		var first = _first_value(spec)
		if first == null:
			continue
		match spec["kind"]:
			"slider":
				_build_slider_row(box, spec, first[1], first[0]["type"])
			"check":
				_build_check_row(box, spec, bool(first[1]))
			"color":
				_build_color_row(box, spec, first[1])
			"radio":
				_build_radio_row(box, spec, first[1])
			"dial":
				_build_dial_row(box, first)
	_syncing = false
	_update_layer_row_visibility()
	ui["cog"].visible = not _rows.empty()
	box.visible = ui["cog"].pressed and not _rows.empty()

func _row_label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	l.rect_min_size.x = 85
	return l

func _build_slider_row(box, spec: Dictionary, value, src_type: String) -> void:
	var rng = _common_range(spec)
	var percent = rng == null
	var shown = value
	if percent:
		var r = spec["ranges"][src_type]
		shown = 0.0 if r[1] == r[0] else (float(value) - r[0]) / (r[1] - r[0]) * 100.0
	var row = HBoxContainer.new()
	row.add_child(_row_label(spec["label"]))
	var s = HSlider.new()
	var sb = SpinBox.new()
	var lo = 0.0
	var hi = 100.0
	var step = 1.0
	if not percent:
		lo = rng[0]
		hi = rng[1]
		step = spec["step"]
	for ctrl in [s, sb]:
		ctrl.min_value = lo
		ctrl.max_value = hi
		ctrl.step = step
		ctrl.value = shown
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if percent:
		sb.suffix = "%"
		row.hint_tooltip = "Ranges differ between the selected asset types: the value is mapped proportionally onto each type's own range"
	s.connect("value_changed", self, "_on_slider_changed", [spec["id"], "slider"])
	sb.connect("value_changed", self, "_on_slider_changed", [spec["id"], "spin"])
	row.add_child(s)
	row.add_child(sb)
	box.add_child(row)
	_rows[spec["id"]] = {"spec": spec, "row": row, "slider": s, "spin": sb, "percent": percent}

func _build_check_row(box, spec: Dictionary, value: bool) -> void:
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = spec["label"]
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var cb = CheckButton.new()
	cb.focus_mode = Control.FOCUS_NONE
	cb.pressed = (not value) if spec.get("invert", false) else value
	cb.connect("toggled", self, "_on_check_toggled", [spec["id"]])
	row.add_child(cb)
	box.add_child(row)
	_rows[spec["id"]] = {"spec": spec, "row": row, "check": cb}

func _build_color_row(box, spec: Dictionary, value) -> void:
	var row = HBoxContainer.new()
	row.add_child(_row_label(spec["label"]))
	var cp = ColorPickerButton.new()
	cp.color = Color(value) if value is String else value
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.connect("color_changed", self, "_on_color_changed", [spec["id"]])
	row.add_child(cp)
	box.add_child(row)
	_rows[spec["id"]] = {"spec": spec, "row": row, "color": cp}

func _build_radio_row(box, spec: Dictionary, value) -> void:
	var row = HBoxContainer.new()
	var btns = []
	for i in range(spec["names"].size()):
		var b = Button.new()
		b.text = " " + spec["names"][i]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.align = Button.ALIGN_LEFT
		b.connect("pressed", self, "_on_radio_pressed", [spec["id"], i])
		row.add_child(b)
		btns.append(b)
	box.add_child(row)
	_rows[spec["id"]] = {"spec": spec, "row": row, "buttons": btns}
	_set_radio(spec["id"], max(spec["values"].find(value), 0))

func _set_radio(row_id: String, idx: int) -> void:
	var btns = _rows[row_id]["buttons"]
	for i in range(btns.size()):
		btns[i].pressed = (i == idx)
		btns[i].icon = btns[i].get_icon("radio_checked" if i == idx else "radio_unchecked", "CheckBox")

# Layer slider: only while Custom Shadow Layer is ON.
# Same conditional rows as the per-type panels, evaluated on what the panel
# shows (the first selected asset's values).
func _update_layer_row_visibility() -> void:
	for id in _rows.keys():
		var tag = _rows[id]["spec"].get("show_if", "")
		if tag != "":
			_rows[id]["row"].visible = _show_if(tag)

func _show_if(tag: String) -> bool:
	var realistic = _radio_value("render_mode") == "realistic"
	match tag:
		"custom_layer":
			return _check_pressed("custom_layer")
		"realistic":
			return realistic
		"realistic_side":
			return realistic and _radio_value("direction") != 2
		"wrap":
			return realistic and _check_pressed("crop_ends")   # Wrap Ends ON
		"both_sides":
			return _radio_value("direction") == 2
		"simple":
			return not realistic
		"extend":
			return not realistic and _check_pressed("extend_enabled")
	return true

func _check_pressed(row_id: String) -> bool:
	return _rows.has(row_id) and _rows[row_id].has("check") and _rows[row_id]["check"].pressed

func _radio_value(row_id: String):
	if not _rows.has(row_id) or not _rows[row_id].has("buttons"):
		return null
	var btns = _rows[row_id]["buttons"]
	for i in range(btns.size()):
		if btns[i].pressed:
			return _rows[row_id]["spec"]["values"][i]
	return null

#########################################################################################################
## SHARED SETTINGS — DIAL (handle = sun, shadow falls opposite; quadratic radius)
#########################################################################################################

func _dial_max_for(first_entry: Dictionary) -> float:
	if _types.has("patterns"):
		return PATTERN_OFFSET_MAX
	var cfg = first_entry["cfg"]
	return max(float(cfg.get("range", 1.0)), 1.0) * OFFSET_MAX

func _build_dial_row(box, first_entry: Dictionary) -> void:
	_dial_max = _dial_max_for(first_entry)
	var off = first_entry["module"].get_shadow_offset(first_entry["node"])
	if off == null:
		off = [0.0, 0.0]
	var header = HBoxContainer.new()
	var dl = Label.new()
	dl.text = "Distance"
	header.add_child(dl)
	var dist = SpinBox.new()
	dist.min_value = 0
	dist.max_value = _dial_max
	dist.step = 1
	dist.rect_min_size.x = 85
	dist.connect("value_changed", self, "_on_dial_spin_changed")
	header.add_child(dist)
	var al = Label.new()
	al.text = "Angle"
	header.add_child(al)
	var ang = SpinBox.new()
	ang.min_value = 0
	ang.max_value = 359
	ang.step = 1
	ang.suffix = "°"
	ang.rect_min_size.x = 72
	ang.connect("value_changed", self, "_on_dial_spin_changed")
	header.add_child(ang)
	box.add_child(header)

	var cc = CenterContainer.new()
	var mc = MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_constant_override(m, 8)
	var dial = Control.new()
	dial.rect_min_size = Vector2(DIAL_SIZE, DIAL_SIZE)
	dial.rect_clip_content = false
	var bg = TextureRect.new()
	bg.texture = _make_circle_texture(DIAL_SIZE, Color(0.12, 0.12, 0.12, 1.0))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg)
	for ring_frac in [0.25, 0.5, 0.75]:
		var rs = int(DIAL_SIZE * ring_frac)
		var ring = TextureRect.new()
		ring.texture = _make_ring_texture(rs, Color(0.22, 0.22, 0.22, 1.0))
		ring.rect_position = Vector2((DIAL_SIZE - rs) / 2.0, (DIAL_SIZE - rs) / 2.0)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring)
	for line_def in [[Vector2(0, DIAL_SIZE / 2.0 - 0.5), Vector2(DIAL_SIZE, 1)], [Vector2(DIAL_SIZE / 2.0 - 0.5, 0), Vector2(1, DIAL_SIZE)]]:
		var ln = ColorRect.new()
		ln.color = Color(0.25, 0.25, 0.25, 0.6)
		ln.rect_position = line_def[0]
		ln.rect_min_size = line_def[1]
		ln.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ln)
	var handle = ColorRect.new()
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)
	dial.set_meta("dragging", false)
	dial.connect("gui_input", self, "_on_dial_input", [dial])
	mc.add_child(dial)
	cc.add_child(mc)
	box.add_child(cc)
	_rows["offset"] = {"spec": {"id": "offset", "kind": "dial"}, "row": cc, "dist": dist, "angle": ang, "handle": handle}
	_set_dial(float(off[0]), float(off[1]))

func _make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	for y in range(size):
		for x in range(size):
			img.set_pixel(x, y, color if Vector2(x, y).distance_to(center) <= size / 2.0 else Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

func _make_ring_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	for y in range(size):
		for x in range(size):
			img.set_pixel(x, y, color if abs(Vector2(x, y).distance_to(center) - size / 2.0) < 1.0 else Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex

# Spins + handle from a world offset (px). Angle = sun, 0° = north, clockwise.
func _set_dial(ox: float, oy: float) -> void:
	if not _rows.has("offset"):
		return
	var r = _rows["offset"]
	var was = _syncing
	_syncing = true
	var dist = sqrt(ox * ox + oy * oy)
	r["dist"].max_value = max(_dial_max, ceil(dist))
	r["dist"].value = round(dist)
	if dist > 0.5:
		r["angle"].value = round(fposmod(rad2deg(atan2(-ox, oy)), 360.0))
	var radius = DIAL_SIZE / 2.0
	var frac = sqrt(clamp(dist / max(_dial_max, 1.0), 0.0, 1.0))
	var sun_dir = Vector2(-ox, -oy).normalized() if dist > 0.5 else Vector2.ZERO
	var p = Vector2(radius, radius) + sun_dir * frac * radius
	r["handle"].rect_position = Vector2(p.x - 5, p.y - 5)
	_syncing = was

func _on_dial_input(event: InputEvent, dial: Control) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		dial.set_meta("dragging", event.pressed)
		if event.pressed:
			_dial_from_mouse(event.position)
	elif event is InputEventMouseMotion and dial.get_meta("dragging"):
		_dial_from_mouse(event.position)

func _dial_from_mouse(pos: Vector2) -> void:
	var radius = DIAL_SIZE / 2.0
	var delta = pos - Vector2(radius, radius)
	var d = delta.length()
	if d > radius:
		delta = delta.normalized() * radius
		d = radius
	var ox = 0.0
	var oy = 0.0
	if d > 0.5:
		var frac = d / radius
		var dist = frac * frac * _dial_max
		var dir = delta / d
		ox = round(-dir.x * dist)
		oy = round(-dir.y * dist)
	_set_dial(ox, oy)
	_apply_offset(ox, oy)

func _on_dial_spin_changed(_v) -> void:
	if _syncing or not _rows.has("offset"):
		return
	var r = _rows["offset"]
	var a = deg2rad(r["angle"].value)
	var dist = r["dist"].value
	var ox = round(-dist * sin(a))
	var oy = round(dist * cos(a))
	_set_dial(ox, oy)
	_apply_offset(ox, oy)

#########################################################################################################
## SHARED SETTINGS — HANDLERS
#########################################################################################################

func _on_slider_changed(value, row_id: String, source: String) -> void:
	if _syncing:
		return
	var r = _rows[row_id]
	_syncing = true
	if source == "slider":
		r["spin"].value = value
	else:
		r["slider"].value = value
	_syncing = false
	if row_id == "range":
		_apply_range(float(value))
		return
	var spec = r["spec"]
	_apply_row(spec, funcref(self, "_slider_value_for"), [spec, float(value), r["percent"]])

func _slider_value_for(type: String, args: Array):
	var spec = args[0]
	var v = args[1]
	if args[2]:
		var rng = spec["ranges"][type]
		v = rng[0] + clamp(v / 100.0, 0.0, 1.0) * (rng[1] - rng[0])
	if spec["id"] == "shadow_layer":
		return int(round(v))
	return v

func _on_check_toggled(pressed: bool, row_id: String) -> void:
	_update_layer_row_visibility()
	if _syncing:
		return
	var spec = _rows[row_id]["spec"]
	var v = (not pressed) if spec.get("invert", false) else pressed
	_apply_row(spec, funcref(self, "_const_value"), [v])

func _on_color_changed(color: Color, row_id: String) -> void:
	if _syncing:
		return
	_apply_row(_rows[row_id]["spec"], funcref(self, "_const_value"), [color])

func _on_radio_pressed(row_id: String, idx: int) -> void:
	_set_radio(row_id, idx)
	_update_layer_row_visibility()
	if _syncing:
		return
	var spec = _rows[row_id]["spec"]
	_apply_row(spec, funcref(self, "_const_value"), [spec["values"][idx]])
	# Shape (render mode) changes which keys opacity / blur write: reload.
	if row_id == "render_mode":
		_rebuild_shared_panel()

func _const_value(_type: String, args: Array):
	return args[0]

#########################################################################################################
## SHARED SETTINGS — WRITE
#########################################################################################################

# Sends {key: value} (+ the row's extra keys) to every asset the row applies
# to, grouped by module (one shared_apply call -> one history entry each).
func _apply_row(spec: Dictionary, value_fn: FuncRef, args: Array) -> void:
	var by_module = {}
	for e in _entries:
		if e["cfg"] == null:
			continue
		var k = _node_key(spec["id"], e["type"], e["cfg"])
		if k == "":
			continue
		var changes = {k: value_fn.call_func(e["type"], args)}
		for xk in spec.get("extra", {}).keys():
			changes[xk] = spec["extra"][xk]
		_queue(by_module, e, changes)
	_flush(by_module)

func _apply_offset(ox: float, oy: float) -> void:
	var by_module = {}
	for e in _entries:
		if e["cfg"] != null:
			_queue(by_module, e, {"__offset": [ox, oy]})
	_flush(by_module)

# Max Distance: like the per-type panels, each asset's offset scales with it
# so the handle keeps its place on the dial.
func _apply_range(new_range: float) -> void:
	var by_module = {}
	for e in _entries:
		var cfg = e["cfg"]
		if cfg == null or not cfg.has("range"):
			continue
		var changes = {"range": new_range}
		var old_range = float(cfg.get("range", 1.0))
		if old_range > 0.001 and cfg.get("shadow_mode", "offset") != "projected":
			var f = new_range / old_range
			changes["offset_x"] = round(float(cfg.get("offset_x", 0.0)) * f)
			changes["offset_y"] = round(float(cfg.get("offset_y", 0.0)) * f)
		_queue(by_module, e, changes)
	_flush(by_module)
	_dial_max = max(new_range, 1.0) * OFFSET_MAX
	if _rows.has("offset") and not _entries.empty():
		for e in _entries:
			if e["cfg"] != null:
				var off = e["module"].get_shadow_offset(e["node"])
				if off != null:
					_set_dial(float(off[0]), float(off[1]))
				break

func _queue(by_module: Dictionary, entry: Dictionary, changes: Dictionary) -> void:
	var key = entry["module"].get_instance_id()
	if not by_module.has(key):
		by_module[key] = {"module": entry["module"], "items": []}
	by_module[key]["items"].append([entry["node"], changes])

func _flush(by_module: Dictionary) -> void:
	for key in by_module.keys():
		by_module[key]["module"].shared_apply(by_module[key]["items"])
	# Keep the cached configs current (next value mapping / key choice).
	for e in _entries:
		if e["cfg"] != null:
			e["cfg"] = e["module"].shared_saved_config(e["node"])
