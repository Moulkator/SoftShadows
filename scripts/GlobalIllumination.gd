#########################################################################################################
##
## GLOBAL ILLUMINATION — map-wide override of the soft shadows' sun (Soft Shadows tool)
##
#########################################################################################################
# ON: every enabled soft shadow (objects, paths, walls, roofs, patterns) gets
# the global offset — angle and/or distance, per the two checkboxes. Each
# shadow's previous offset is backed up once. Shadows created while ON get it
# too (monitor). A shadow edited by hand while ON is left alone by later dial
# moves, and keeps its hand-edited value when switching OFF; every other shadow
# is restored to its backup on OFF.
#
# A STYLE change (Offset <-> Projected for objects, Simple <-> Realistic for
# paths / walls / patterns) is not a hand edit: modules that expose
# get_shadow_style() have their style recorded next to the applied offset, and
# a shadow whose style changed is simply re-applied on the next pass.
#
# Distance is the pixel reach of the shadow tip for EVERY style: 50 px puts an
# Offset shadow 50 px away and gives a Stretch / Extrude shadow a 50 px tip
# (the object module maps proj_angle/proj_length onto the same vector).
#
# Overlays (objects, patterns): the global sun angle is imposed at render time
# on every overlay — linked, unlinked and locked alike — through the modules'
# set_global_sun(); their own settings are untouched and come back on OFF.
# "Invert Overlays" lights them from the opposite side. Distance never applies
# to overlays.
#
# One dial per asset type (Objects / Paths / Walls / Patterns / Roofs) plus
# "All": moving the All dial copies its offset to every type; a type's dial
# only drives that type. The menu picks which dial is shown.
#
# ModMapData:
#   GlobalIllumination        {enabled, use_angle, use_distance, invert_overlays, active, range,
#                              targets: {all|objects|paths|walls|patterns|roofs: [ox, oy]}}
#   GlobalIlluminationBackup  {key: [ox, oy]}   offset before the override
#   GlobalIlluminationApplied {key: [ox, oy]}   what the override last wrote (read back)
# key = "<type>:<node_id>".

var global
var core = null
var logging_level = 0
var shadow_history = null
# Set by Core: {"objects", "paths", "walls", "roofs", "patterns"} soft-shadow
# modules + "overlays_objects" / "overlays_patterns" (set_global_sun API).
var modules = {}

const DATA_KEY = "GlobalIllumination"
const BACKUP_KEY = "GlobalIlluminationBackup"
const APPLIED_KEY = "GlobalIlluminationApplied"
const TYPES = ["objects", "paths", "walls", "patterns", "roofs"]
const MENU = ["all", "objects", "paths", "walls", "patterns", "roofs"]
const MENU_LABELS = ["All", "Objects", "Paths", "Walls", "Patterns", "Roofs"]
const DEFAULTS = {"enabled": false, "use_angle": true, "use_distance": true, "invert_overlays": false, "active": "all", "range": 1.0}
const RANGE_MAX = 10.0   # dial reach = range × OFFSET_MAX px (1 = 100 px, 10 = 1000 px)
# overlay module key -> the dial (target type) that drives it
const OVERLAY_MODULES = {"overlays_objects": "objects", "overlays_patterns": "patterns"}

const OFFSET_MAX = 100.0
const DIAL_SIZE = 90
const SNAP_KEYS = ["snap_45", "snap_135", "snap_225", "snap_315"]
# Manual-edit detection tolerance (px). "Applied" values are READ BACK from the
# module after writing (patterns round through an angle, roofs re-propagate a
# normalized direction), so a small slack is enough and avoids false positives.
const TOL = 1.5
const DEBUG_APPLY = false  # set true to trace each write in the log

var ui = {}
var _syncing = false
var _monitor_timer = null
var _txn_before = null

const ENABLE_LOGGING = true
func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <GlobalIllumination>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise() -> void:
	_monitor_timer = Timer.new()
	_monitor_timer.wait_time = 0.5
	_monitor_timer.autostart = true
	_monitor_timer.connect("timeout", self, "_on_monitor_tick")
	global.Editor.add_child(_monitor_timer)
	outputlog("Global Illumination initialised.", 0)

# Map (re)load: sync the UI from the map data (Core calls this after the
# modules restored their shadows).
func apply_saved_shadows_to_map() -> void:
	_sync_ui()
	_push_overlay_suns()

func _data() -> Dictionary:
	if not global.ModMapData.has(DATA_KEY) or not (global.ModMapData[DATA_KEY] is Dictionary):
		global.ModMapData[DATA_KEY] = DEFAULTS.duplicate(true)
	var d = global.ModMapData[DATA_KEY]
	for k in DEFAULTS.keys():
		if not d.has(k):
			d[k] = DEFAULTS[k]
	if not d.has("targets") or not (d["targets"] is Dictionary):
		# Migration from the single-dial version.
		var ox = float(d.get("offset_x", 0.0))
		var oy = float(d.get("offset_y", 0.0))
		d["targets"] = {}
		for t in MENU:
			d["targets"][t] = [ox, oy]
	for t in MENU:
		if not d["targets"].has(t):
			d["targets"][t] = [0.0, 0.0]
	return d

# Pixel reach of the dial edge (Range × 100 px).
func _dial_max() -> float:
	return clamp(float(_data().get("range", 1.0)), 1.0, RANGE_MAX) * OFFSET_MAX

func _target_offset(type_name: String) -> Vector2:
	var t = _data()["targets"][type_name]
	return Vector2(float(t[0]), float(t[1]))

func _dict(key: String) -> Dictionary:
	if not global.ModMapData.has(key) or not (global.ModMapData[key] is Dictionary):
		global.ModMapData[key] = {}
	return global.ModMapData[key]

#########################################################################################################
## SHADOW ENUMERATION (all levels, by map data)
#########################################################################################################

func _node_of(nid) -> Node:
	var iid = int(nid)
	if iid < 0 or not global.World.HasNodeID(iid):
		return null
	var n = global.World.GetNodeByID(iid)
	return n if (n != null and is_instance_valid(n)) else null

# Array of [key, module, node] for every enabled soft shadow on the map.
func _all_shadows() -> Array:
	var out = []
	var seen = {}
	# Objects / paths / walls share the "DropShadow" dictionary.
	if global.ModMapData.has("DropShadow"):
		for nid in global.ModMapData["DropShadow"].keys():
			var node = _node_of(nid)
			if node == null:
				continue
			for mname in ["objects", "paths", "walls"]:
				var m = modules.get(mname)
				if m != null and m.has_method("is_shadow_node_type") and m.is_shadow_node_type(node) and m.has_shadow_enabled(node):
					var key = mname + ":" + str(nid)
					if not seen.has(key):
						seen[key] = true
						out.append([key, m, node])
					break
	# Roofs: the module's live registry (_configs_by_id, instance ids) is the
	# truth — a roof may carry a config that was never persisted yet.
	var roofs = modules.get("roofs")
	if roofs != null:
		# Walk every level's Roofs container: a roof placed with the Roof Tool
		# may only carry its config as node meta until the module touches it
		# (has_shadow_enabled loads it lazily).
		for level in global.World.levels:
			if level == null or not is_instance_valid(level):
				continue
			var roofs_node = level.get_node_or_null("Roofs")
			if roofs_node == null:
				continue
			for node in roofs_node.get_children():
				if not roofs.is_roof(node) or not roofs.has_shadow_enabled(node):
					continue
				var rk = "roofs:" + (str(node.get_meta("node_id")) if node.has_meta("node_id") else "i" + str(node.get_instance_id()))
				if not seen.has(rk):
					seen[rk] = true
					out.append([rk, roofs, node])
		var reg = roofs.get("_configs_by_id")
		if reg is Dictionary:
			for iid in reg.keys():
				var node = instance_from_id(int(iid))
				if node == null or not is_instance_valid(node) or not roofs.is_roof(node):
					continue
				if not roofs.has_shadow_enabled(node):
					continue
				var rk = "roofs:" + (str(node.get_meta("node_id")) if node.has_meta("node_id") else "i" + str(iid))
				if not seen.has(rk):
					seen[rk] = true
					out.append([rk, roofs, node])
		if global.ModMapData.has("DropShadowRoof"):
			for nid in global.ModMapData["DropShadowRoof"].keys():
				var node = _node_of(nid)
				if node == null or not roofs.is_roof(node) or not roofs.has_shadow_enabled(node):
					continue
				var rk = "roofs:" + str(nid)
				if not seen.has(rk):
					seen[rk] = true
					out.append([rk, roofs, node])
	var patterns = modules.get("patterns")
	if patterns != null and global.ModMapData.has("DropShadowPatterns"):
		for nid in global.ModMapData["DropShadowPatterns"].keys():
			var node = _node_of(nid)
			if node != null and patterns.is_pattern(node) and patterns.has_shadow_enabled(node):
				out.append(["patterns:" + str(nid), patterns, node])
	return out

func _same(a, b) -> bool:
	if a == null or b == null:
		return false
	return abs(float(a[0]) - float(b[0])) < TOL and abs(float(a[1]) - float(b[1])) < TOL

# Style tag of a shadow ("" when the module has none); stored as applied[key][2].
func _style_of(entry) -> String:
	if entry[1].has_method("get_shadow_style"):
		var st = entry[1].get_shadow_style(entry[2])
		return str(st) if st != null else ""
	return ""

# True when the shadow's style changed since GI last applied it.
func _restyled(entry, applied_val) -> bool:
	return applied_val.size() > 2 and str(applied_val[2]) != _style_of(entry)

#########################################################################################################
## OVERRIDE LOGIC
#########################################################################################################

# Target offset for a shadow of `type_name` currently at `cur`, per the flags.
func _target_for(cur: Array, type_name: String) -> Array:
	var d = _data()
	var g = _target_offset(type_name)
	var c = Vector2(float(cur[0]), float(cur[1]))
	var use_a = d["use_angle"]
	var use_d = d["use_distance"]
	if use_a and use_d:
		return [round(g.x), round(g.y)]
	if use_a:
		# Global direction, the shadow's own distance (a zero offset stays zero).
		var len_c = c.length()
		if len_c < 0.5 or g.length() < 0.5:
			return [round(c.x), round(c.y)]
		var v = g.normalized() * len_c
		return [round(v.x), round(v.y)]
	# Distance only: the shadow's own direction (global one if it has none).
	var dir = c.normalized() if c.length() >= 0.5 else (g.normalized() if g.length() >= 0.5 else Vector2.ZERO)
	var v2 = dir * g.length()
	return [round(v2.x), round(v2.y)]

# Public, for placement previews: the offset GI would give a shadow of
# `type_name` whose current offset is `cur` ([ox, oy]), or null when GI is
# off. Pure computation — nothing is written or backed up.
func preview_offset(type_name: String, cur):
	var d = _data()
	if not d["enabled"] or cur == null or not d["targets"].has(type_name):
		return null
	return _target_for(cur, type_name)

# Apply the override to every shadow not edited by hand since the last write.
# `only_new` restricts to shadows never touched by the override (monitor).
# Three passes: (1) read every current offset — the manual-edit test uses this
# snapshot, so a write that makes the module re-propagate OTHER shadows (roofs
# share one sun direction) can't get them mis-flagged; (2) write; (3) read
# back what was actually stored as the new reference.
func _apply_all(only_new: bool = false) -> void:
	var backup = _dict(BACKUP_KEY)
	var applied = _dict(APPLIED_KEY)
	var entries = _all_shadows()
	var cur_by_key = {}
	for entry in entries:
		var cur = entry[1].get_shadow_offset(entry[2])
		if cur != null:
			cur_by_key[entry[0]] = cur
	var to_write = []
	for entry in entries:
		var key = entry[0]
		if not cur_by_key.has(key):
			continue
		var cur = cur_by_key[key]
		if applied.has(key) and not _restyled(entry, applied[key]):
			if only_new:
				continue
			if not _same(cur, applied[key]):
				if DEBUG_APPLY:
					outputlog("skip %s (hand-edited): cur=%s applied=%s" % [key, str(cur), str(applied[key])], 0)
				continue   # hand-edited while ON: left alone
		if not backup.has(key):
			backup[key] = [cur[0], cur[1]]
		to_write.append([entry, _target_for(cur, key.split(":")[0])])
	for item in to_write:
		var entry = item[0]
		var target = item[1]
		var cur = cur_by_key[entry[0]]
		if not _same(cur, target):
			entry[1].set_shadow_offset(entry[2], target[0], target[1])
	for item in to_write:
		var entry = item[0]
		var stored = entry[1].get_shadow_offset(entry[2])
		applied[entry[0]] = [stored[0], stored[1], _style_of(entry)] if stored != null else [item[1][0], item[1][1], _style_of(entry)]
		if DEBUG_APPLY:
			outputlog("apply %s cur=%s target=%s stored=%s" % [entry[0], str(cur_by_key[entry[0]]), str(item[1]), str(stored)], 0)

# OFF: restore the backup of every shadow still at the overridden value.
func _restore_all() -> void:
	var backup = _dict(BACKUP_KEY)
	var applied = _dict(APPLIED_KEY)
	var by_key = {}
	for entry in _all_shadows():
		by_key[entry[0]] = entry
	for key in backup.keys():
		if not by_key.has(key):
			continue
		var m = by_key[key][1]
		var node = by_key[key][2]
		var cur = m.get_shadow_offset(node)
		if cur == null:
			continue
		if applied.has(key) and not _restyled(by_key[key], applied[key]) and not _same(cur, applied[key]):
			continue   # hand-edited while ON: keeps its value
		var b = backup[key]
		if not _same(cur, b):
			m.set_shadow_offset(node, float(b[0]), float(b[1]))
	global.ModMapData[BACKUP_KEY] = {}
	global.ModMapData[APPLIED_KEY] = {}

func _on_monitor_tick() -> void:
	if _data()["enabled"]:
		_apply_all(true)

#########################################################################################################
## OVERLAYS (render-time sun override, no per-overlay data)
#########################################################################################################

# World sun angle (deg, 0 = right / 90 = down) to impose on the overlays driven
# by `type_name`'s dial, or null (off, angle not overridden, or dial at center).
func _overlay_sun_for(type_name: String):
	var d = _data()
	if not d["enabled"] or not d["use_angle"]:
		return null
	var g = _target_offset(type_name)
	if g.length() < 0.5:
		return null
	var sun = fposmod(rad2deg(atan2(-g.y, -g.x)), 360.0)
	if d["invert_overlays"]:
		sun = fposmod(sun + 180.0, 360.0)
	return sun

func _push_overlay_suns() -> void:
	for mkey in OVERLAY_MODULES.keys():
		var m = modules.get(mkey)
		if m != null and m.has_method("set_global_sun"):
			m.set_global_sun(_overlay_sun_for(OVERLAY_MODULES[mkey]))

#########################################################################################################
## HISTORY
#########################################################################################################

func _snapshot() -> Dictionary:
	var offsets = {}
	for entry in _all_shadows():
		var cur = entry[1].get_shadow_offset(entry[2])
		if cur != null:
			offsets[entry[0]] = [cur[0], cur[1]]
	return {
		"data": _data().duplicate(true),
		"backup": _dict(BACKUP_KEY).duplicate(true),
		"applied": _dict(APPLIED_KEY).duplicate(true),
		"offsets": offsets}

func _txn_begin() -> void:
	if _txn_before == null:
		_txn_before = _snapshot()

func _txn_end(label: String) -> void:
	if _txn_before == null:
		return
	var before = _txn_before
	_txn_before = null
	var after = _snapshot()
	if JSON.print(before) != JSON.print(after) and shadow_history != null:
		shadow_history.record(self, "history_apply", before, after, label)

func history_apply(payload) -> void:
	if not (payload is Dictionary):
		return
	global.ModMapData[DATA_KEY] = payload["data"].duplicate(true)
	global.ModMapData[BACKUP_KEY] = payload["backup"].duplicate(true)
	global.ModMapData[APPLIED_KEY] = payload["applied"].duplicate(true)
	var offsets = payload["offsets"]
	for entry in _all_shadows():
		var key = entry[0]
		if not offsets.has(key):
			continue
		var cur = entry[1].get_shadow_offset(entry[2])
		if cur != null and not _same(cur, offsets[key]):
			entry[1].set_shadow_offset(entry[2], float(offsets[key][0]), float(offsets[key][1]))
	_sync_ui()
	_push_overlay_suns()

#########################################################################################################
## UI (built into the Soft Shadows tool panel)
#########################################################################################################

func build_controls(container) -> void:
	var c = VBoxContainer.new()
	c.name = "GlobalIllumination"
	var sep = HSeparator.new()
	sep.add_constant_override("separation", 4)
	c.add_child(sep)

	var trow = HBoxContainer.new()
	var title = Label.new()
	title.text = "Global Illumination"
	title.hint_tooltip = "Impose one sun direction and/or distance on every soft shadow of the map. OFF restores the previous offsets (hand-edited shadows keep theirs)."
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trow.add_child(title)
	var enable = CheckButton.new()
	enable.focus_mode = Control.FOCUS_NONE
	enable.connect("toggled", self, "_on_enable_toggled")
	trow.add_child(enable)
	ui["enable"] = enable
	c.add_child(trow)

	var panel = VBoxContainer.new()
	panel.visible = false
	ui["panel"] = panel

	# What is imposed
	var frow = HBoxContainer.new()
	var fl = Label.new()
	fl.text = "Override"
	fl.rect_min_size.x = 70
	frow.add_child(fl)
	var cb_a = CheckBox.new()
	cb_a.text = "Angle"
	cb_a.pressed = true
	cb_a.focus_mode = Control.FOCUS_NONE
	cb_a.connect("toggled", self, "_on_flag_toggled", ["use_angle"])
	frow.add_child(cb_a)
	ui["use_angle"] = cb_a
	var cb_d = CheckBox.new()
	cb_d.text = "Distance"
	cb_d.pressed = true
	cb_d.focus_mode = Control.FOCUS_NONE
	cb_d.connect("toggled", self, "_on_flag_toggled", ["use_distance"])
	frow.add_child(cb_d)
	ui["use_distance"] = cb_d
	panel.add_child(frow)

	# Overlays: lit from the global sun, optionally from the opposite side.
	var orow = HBoxContainer.new()
	var ol = Label.new()
	ol.text = "Overlays"
	ol.rect_min_size.x = 70
	orow.add_child(ol)
	var cb_i = CheckBox.new()
	cb_i.text = "Invert"
	cb_i.hint_tooltip = "Overlay shadows follow the global sun (angle only). Invert lights them from the opposite side."
	cb_i.focus_mode = Control.FOCUS_NONE
	cb_i.connect("toggled", self, "_on_invert_toggled")
	orow.add_child(cb_i)
	ui["invert_overlays"] = cb_i
	panel.add_child(orow)

	# Which dial is shown: All (drives every type) or one asset type.
	var mrow = HBoxContainer.new()
	var ml = Label.new()
	ml.text = "Dial"
	ml.rect_min_size.x = 70
	mrow.add_child(ml)
	var menu = OptionButton.new()
	for i in range(MENU.size()):
		menu.add_item(MENU_LABELS[i], i)
	menu.hint_tooltip = "All: one sun for every asset type. A type: its own sun (the All dial copies its value to every type when moved)."
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.focus_mode = Control.FOCUS_NONE
	menu.connect("item_selected", self, "_on_menu_selected")
	mrow.add_child(menu)
	ui["menu"] = menu
	panel.add_child(mrow)

	# Dial header: Distance [spin]  Angle [spin]  [reset]
	var header = HBoxContainer.new()
	var dl = Label.new()
	dl.text = "Distance"
	header.add_child(dl)
	var dist_spin = SpinBox.new()
	dist_spin.min_value = 0
	dist_spin.max_value = OFFSET_MAX
	dist_spin.step = 1
	dist_spin.suffix = " px"
	dist_spin.hint_tooltip = "Pixel reach of the shadow tip, whatever the style: an Offset shadow is moved this far, a Stretch / Extrude one is projected this far."
	dist_spin.rect_min_size.x = 85
	dist_spin.connect("value_changed", self, "_on_spin_changed")
	header.add_child(dist_spin)
	ui["dist_spin"] = dist_spin
	var al = Label.new()
	al.text = "Angle"
	header.add_child(al)
	var angle_spin = SpinBox.new()
	angle_spin.min_value = 0
	angle_spin.max_value = 359
	angle_spin.step = 1
	angle_spin.suffix = "°"
	angle_spin.rect_min_size.x = 72
	angle_spin.connect("value_changed", self, "_on_spin_changed")
	header.add_child(angle_spin)
	ui["angle_spin"] = angle_spin
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var rb = _make_icon_button("icons/reset.png", "Reset sun", 0.5)
	rb.connect("pressed", self, "_on_reset")
	header.add_child(rb)
	panel.add_child(header)

	# Range: [Label] [Slider] [SpinBox] — dial reach = Range × 100 px
	var rrow = HBoxContainer.new()
	var rl = Label.new()
	rl.text = "Max Distance"
	rl.rect_min_size.x = 85
	rrow.add_child(rl)
	var range_slider = HSlider.new()
	range_slider.min_value = 1
	range_slider.max_value = RANGE_MAX
	range_slider.step = 1
	range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	range_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	range_slider.focus_mode = Control.FOCUS_NONE
	range_slider.connect("value_changed", self, "_on_range_changed")
	rrow.add_child(range_slider)
	ui["range_slider"] = range_slider
	var range_spin = SpinBox.new()
	range_spin.min_value = 1
	range_spin.max_value = RANGE_MAX
	range_spin.step = 1
	range_spin.suffix = "x"
	range_spin.hint_tooltip = "Dial reach: 1 = 100 px, 10 = 1000 px. Only widens the dial, the current sun keeps its value."
	range_spin.rect_min_size.x = 60
	range_spin.connect("value_changed", self, "_on_range_changed")
	rrow.add_child(range_spin)
	ui["range_spin"] = range_spin
	panel.add_child(rrow)

	var cc = CenterContainer.new()
	cc.rect_clip_content = false
	var mc = MarginContainer.new()
	mc.rect_clip_content = false
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_constant_override(m, 8)
	mc.add_child(_create_dial())
	cc.add_child(mc)
	panel.add_child(cc)

	c.add_child(panel)
	container.add_child(c)
	_sync_ui()

func _sync_ui() -> void:
	if not ui.has("enable"):
		return
	var d = _data()
	_syncing = true
	ui["enable"].pressed = d["enabled"]
	ui["panel"].visible = d["enabled"]
	ui["use_angle"].pressed = d["use_angle"]
	ui["use_distance"].pressed = d["use_distance"]
	ui["invert_overlays"].pressed = d["invert_overlays"]
	var rv = clamp(float(d.get("range", 1.0)), 1.0, RANGE_MAX)
	ui["range_spin"].value = rv
	ui["range_slider"].value = rv
	ui["dist_spin"].max_value = _dial_max()
	ui["menu"].selected = max(MENU.find(d["active"]), 0)
	var t = _target_offset(d["active"])
	_set_dial_from_xy(t.x, t.y)
	_syncing = false

func _on_menu_selected(idx: int) -> void:
	if _syncing:
		return
	var d = _data()
	d["active"] = MENU[clamp(idx, 0, MENU.size() - 1)]
	_deactivate_snaps()
	var t = _target_offset(d["active"])
	_set_dial_from_xy(t.x, t.y)

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

#########################################################################################################
## UI HANDLERS
#########################################################################################################

func _on_enable_toggled(pressed: bool) -> void:
	if _syncing:
		return
	ui["panel"].visible = pressed
	_txn_begin()
	var d = _data()
	d["enabled"] = pressed
	if pressed:
		_apply_all()
	else:
		_restore_all()
	_push_overlay_suns()
	_txn_end("global illumination " + ("on" if pressed else "off"))

func _on_flag_toggled(pressed: bool, key: String) -> void:
	if _syncing:
		return
	var d = _data()
	# At least one of the two stays on.
	if not pressed and not (ui["use_angle"].pressed or ui["use_distance"].pressed):
		_syncing = true
		ui[key].pressed = true
		_syncing = false
		return
	_txn_begin()
	d[key] = pressed
	if d["enabled"]:
		_apply_all()
	_push_overlay_suns()
	_txn_end("global illumination " + key)

func _on_invert_toggled(pressed: bool) -> void:
	if _syncing:
		return
	_txn_begin()
	_data()["invert_overlays"] = pressed
	_push_overlay_suns()
	_txn_end("global illumination invert overlays")

func _on_spin_changed(_v) -> void:
	if _syncing:
		return
	var angle = ui["angle_spin"].value
	var dist = ui["dist_spin"].value
	var dial = ui.get("dial")
	if dial != null and (dial.get_meta("snap_angle") as float) >= 0.0:
		var sr = deg2rad(dial.get_meta("snap_angle") as float)
		var expected = fposmod(rad2deg(atan2(cos(sr), -sin(sr))), 360.0)
		if abs(angle - round(expected)) > 0.5:
			_deactivate_snaps()
	var a = deg2rad(angle)
	_txn_begin()
	_commit_offset(round(-sin(a) * dist), round(cos(a) * dist))
	_txn_end("global illumination sun")

# Range only rescales the dial; the current sun keeps its px value (clamped
# to the new reach if the range shrinks below it).
func _on_range_changed(v) -> void:
	if _syncing:
		return
	var rv = clamp(float(v), 1.0, RANGE_MAX)
	if rv == float(_data().get("range", 1.0)):
		return
	_txn_begin()
	_data()["range"] = rv
	var dmax = _dial_max()
	_syncing = true
	ui["range_slider"].value = rv
	ui["range_spin"].value = rv
	ui["dist_spin"].max_value = dmax
	_syncing = false
	var g = _target_offset(_data()["active"])
	if g.length() > dmax:
		g = g.normalized() * dmax
		_commit_offset(round(g.x), round(g.y))
	else:
		_set_dial_from_xy(g.x, g.y)
	_txn_end("global illumination range")

func _on_reset() -> void:
	_deactivate_snaps()
	_txn_begin()
	_commit_offset(0.0, 0.0)
	_txn_end("global illumination reset")

# Writes the shown dial's offset (All -> copied to every type), refreshes the
# dial, re-applies when ON.
func _commit_offset(ox: float, oy: float) -> void:
	var d = _data()
	var active = d["active"]
	d["targets"][active] = [ox, oy]
	if active == "all":
		for t in TYPES:
			d["targets"][t] = [ox, oy]
	_set_dial_from_xy(ox, oy)
	if d["enabled"]:
		_apply_all()
	_push_overlay_suns()

#########################################################################################################
## DIAL (same widget as the other tools: handle = sun, non-linear radius)
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

func _create_dial() -> Control:
	var size = DIAL_SIZE
	var dial = Control.new()
	dial.name = "SunDial"
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
		for dd in range(4, int(size / 2.0 - 2.0), 3):
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(size / 2.0 + cos(dr) * dd, size / 2.0 + sin(dr) * dd)
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
	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_min_size = Vector2(10, 10)
	handle.rect_position = Vector2(size / 2.0 - 5, size / 2.0 - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)
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
		b.connect("toggled", self, "_on_snap_toggled", [key, snap_deg[key]])
		dial.add_child(b)
		ui[key] = b
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)
	dial.connect("gui_input", self, "_on_dial_input", [dial])
	ui["dial"] = dial
	ui["dial_dot"] = handle
	return dial

func _on_dial_input(event: InputEvent, dial: Control) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		dial.set_meta("dragging", event.pressed)
		if event.pressed:
			_txn_begin()
			_update_dial_from_mouse(event.position, dial)
		else:
			_txn_end("global illumination sun")
	elif event is InputEventMouseMotion and dial.get_meta("dragging"):
		_update_dial_from_mouse(event.position, dial)

func _update_dial_from_mouse(pos: Vector2, dial: Control) -> void:
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
		frac = 0.0 if proj <= 0.0 else min(proj, radius) / radius
		direction = sd
	# Handle = sun direction, shadow offset = opposite; quadratic radius.
	var dmax = _dial_max()
	_commit_offset(round(-direction.x * frac * frac * dmax), round(-direction.y * frac * frac * dmax))

func _on_snap_toggled(pressed: bool, key: String, angle: float) -> void:
	var dial = ui.get("dial")
	if dial == null:
		return
	if pressed:
		for k in SNAP_KEYS:
			if k != key:
				ui[k].pressed = false
		dial.set_meta("snap_angle", angle)
		var d = ui["dist_spin"].value
		if d > 0:
			var r = deg2rad(angle)
			_txn_begin()
			_commit_offset(round(-d * cos(r)), round(-d * sin(r)))
			_txn_end("global illumination sun")
	else:
		dial.set_meta("snap_angle", -1.0)

func _deactivate_snaps() -> void:
	for k in SNAP_KEYS:
		if ui.has(k):
			ui[k].pressed = false
	if ui.has("dial"):
		ui["dial"].set_meta("snap_angle", -1.0)

func _set_dial_from_xy(ox: float, oy: float) -> void:
	if not ui.has("dial"):
		return
	var was = _syncing
	_syncing = true
	var dist = sqrt(ox * ox + oy * oy)
	var angle = fposmod(rad2deg(atan2(-ox, oy)), 360.0) if dist > 0.5 else ui["angle_spin"].value
	ui["angle_spin"].value = round(angle)
	ui["dist_spin"].value = round(dist)
	var radius = DIAL_SIZE / 2.0
	var frac = clamp(dist / _dial_max(), 0.0, 1.0)   # handle linear in the value
	var direction = Vector2(-ox, -oy).normalized() if dist > 0.5 else Vector2.ZERO
	var p = Vector2(radius, radius) + direction * frac * radius
	ui["dial_dot"].rect_position = Vector2(p.x - 5, p.y - 5)
	_syncing = was
