#########################################################################################################
##
## SHADOW PRESETS — shared helper (one instance per module section)
##
#########################################################################################################
# Global presets (all maps): user://softshadows_presets.json
#   {"<type>": {"<name>": {key: value, ...}}}   colors stored as html strings.
#
# A module creates one instance and gives it an adapter — itself — implementing:
#   preset_get_config(scope) -> Dictionary      current UI values ("select", or any tool scope)
#   preset_apply(scope, cfg)                     apply to the selection / to the tool defaults
#   preset_selected_ids() -> Array               node ids (String) of the selected assets of
#                                                its type, first = the one the UI shows
#   preset_snapshot(scope) -> Dictionary         {id | "__tool": full config or null} — state to
#                                                restore when going back to None
#   preset_restore(scope, snapshot)              put that state back (null = default shadow)
#   preset_exclude_keys() -> Array               never stored (enabled, layer...)
#   preset_offset_keys() -> Array                stored only when "Include offset" is ticked
#
# build_row(parent, scope) adds:  Preset: [--- None --- v] [Save] [Ren] [Del]
# (Save / Rename / Delete only for the "select" scope; scopes other than
# "select" are tool scopes and share one assignment). Picking a preset applies
# it; "None" restores what the asset / tool had before its first preset
# (kept in ModMapData "ShadowPresetsBackup"). Which preset an asset uses is remembered per node
# (ModMapData "ShadowPresetsAssigned"), so selecting another asset shows its
# own preset (or None). A "*" follows the name once the current values drift
# from the preset. Save pre-fills the current preset's name; an existing name
# asks Replace / another name. Mouse wheel over the list steps through it.

var global
var module = null
var type_name: String = ""
var _rows = {}          # scope -> {parent, option, save, rename, delete}
var _current = {}       # scope -> preset name ("" = none)
var _syncing = false
var _timer = null
var _dialog = null
var _dialog_mode = ""   # "save" | "rename"
var _dialog_scope = ""
var _confirm = null
var _pending = null     # data for the confirm dialog

const FILE_PATH = "user://softshadows_presets.json"
const NONE_LABEL = "--- None ---"
const ASSIGNED_KEY = "ShadowPresetsAssigned"   # ModMapData: {type: {node_id | "__tool": name}}
const BACKUP_KEY = "ShadowPresetsBackup"       # ModMapData: {type: {node_id | "__tool": cfg | null}}
const TOOL_ID = "__tool"

#########################################################################################################
## STORAGE (shared file, loaded/saved on every access — small)
#########################################################################################################

static func _load_all() -> Dictionary:
	var f = File.new()
	if not f.file_exists(FILE_PATH):
		return {}
	if f.open(FILE_PATH, File.READ) != OK:
		return {}
	var txt = f.get_as_text()
	f.close()
	var res = JSON.parse(txt)
	if res.error != OK or not (res.result is Dictionary):
		return {}
	return res.result

static func _save_all(all: Dictionary) -> void:
	var f = File.new()
	if f.open(FILE_PATH, File.WRITE) != OK:
		return
	f.store_string(JSON.print(all, "\t"))
	f.close()

func _presets() -> Dictionary:
	var all = _load_all()
	if all.has(type_name) and all[type_name] is Dictionary:
		return all[type_name]
	return {}

func _names() -> Array:
	var names = _presets().keys()
	names.sort()
	return names

func _store(name: String, cfg: Dictionary) -> void:
	var all = _load_all()
	if not all.has(type_name) or not (all[type_name] is Dictionary):
		all[type_name] = {}
	all[type_name][name] = _serialize(cfg)
	_save_all(all)

func _remove(name: String) -> void:
	var all = _load_all()
	if all.has(type_name) and all[type_name].has(name):
		all[type_name].erase(name)
		_save_all(all)

func _rename(old_name: String, new_name: String) -> void:
	var all = _load_all()
	if all.has(type_name) and all[type_name].has(old_name):
		all[type_name][new_name] = all[type_name][old_name]
		all[type_name].erase(old_name)
		_save_all(all)

#########################################################################################################
## ASSIGNMENT (which preset an asset / the tool uses) — per map
#########################################################################################################

func _assigned() -> Dictionary:
	if not global.ModMapData.has(ASSIGNED_KEY) or not (global.ModMapData[ASSIGNED_KEY] is Dictionary):
		global.ModMapData[ASSIGNED_KEY] = {}
	var all = global.ModMapData[ASSIGNED_KEY]
	if not all.has(type_name) or not (all[type_name] is Dictionary):
		all[type_name] = {}
	return all[type_name]

func _assigned_name(scope: String) -> String:
	var a = _assigned()
	var name = ""
	if scope == "select":
		var ids = module.preset_selected_ids()
		if ids.size() > 0:
			name = str(a.get(str(ids[0]), ""))
	else:
		name = str(a.get(TOOL_ID, ""))
	if name != "" and not _presets().has(name):
		return ""
	return name

func _assign(scope: String, name: String) -> void:
	var a = _assigned()
	if scope == "select":
		for nid in module.preset_selected_ids():
			if name == "":
				a.erase(str(nid))
			else:
				a[str(nid)] = name
	else:
		if name == "":
			a.erase(TOOL_ID)
		else:
			a[TOOL_ID] = name

func _backups() -> Dictionary:
	if not global.ModMapData.has(BACKUP_KEY) or not (global.ModMapData[BACKUP_KEY] is Dictionary):
		global.ModMapData[BACKUP_KEY] = {}
	var all = global.ModMapData[BACKUP_KEY]
	if not all.has(type_name) or not (all[type_name] is Dictionary):
		all[type_name] = {}
	return all[type_name]

# Before the first preset touches an asset / the tool: remember its state.
func _backup_before_apply(scope: String) -> void:
	var b = _backups()
	var snap = module.preset_snapshot(scope)
	if snap == null:
		return
	for id in snap.keys():
		if b.has(str(id)):
			continue
		var cfg = snap[id]
		b[str(id)] = _serialize(cfg) if cfg is Dictionary else null

# None: restore the pre-preset state of the selected assets / the tool.
func _restore_backup(scope: String) -> void:
	var b = _backups()
	var snap = {}
	var ids = module.preset_selected_ids() if scope == "select" else [TOOL_ID]
	for id in ids:
		var k = str(id)
		if not b.has(k):
			continue
		var cfg = b[k]
		snap[k] = _deserialize(cfg) if cfg is Dictionary else null
		b.erase(k)
	if snap.size() > 0:
		module.preset_restore(scope, snap)

func _assign_renamed(old_name: String, new_name: String) -> void:
	var a = _assigned()
	for k in a.keys():
		if a[k] == old_name:
			a[k] = new_name

func _assign_removed(name: String) -> void:
	var a = _assigned()
	for k in a.keys():
		if a[k] == name:
			a.erase(k)

func _serialize(cfg: Dictionary) -> Dictionary:
	var out = {}
	for k in cfg.keys():
		var v = cfg[k]
		out[k] = v.to_html(true) if v is Color else v
	return out

# Preset -> config usable by the module (colors back to Color).
func _deserialize(cfg: Dictionary) -> Dictionary:
	var out = {}
	for k in cfg.keys():
		var v = cfg[k]
		if k == "shadow_color" and v is String:
			v = Color(v)
		out[k] = v
	return out

# Current UI values reduced to what a preset stores.
func _preset_from_config(cfg: Dictionary, include_offset: bool) -> Dictionary:
	var out = {}
	var excl = module.preset_exclude_keys()
	var offk = module.preset_offset_keys()
	for k in cfg.keys():
		if k in excl:
			continue
		if (k in offk) and not include_offset:
			continue
		out[k] = cfg[k]
	return out

#########################################################################################################
## UI
#########################################################################################################

func build_row(parent, scope: String) -> void:
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Preset:"
	lbl.rect_min_size.x = 60
	row.add_child(lbl)
	var opt = OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.focus_mode = Control.FOCUS_NONE
	opt.connect("item_selected", self, "_on_selected", [scope])
	opt.connect("gui_input", self, "_on_option_input", [scope])
	row.add_child(opt)
	var r = {"parent": parent, "row": row, "option": opt}
	if scope == "select":
		var save = _make_icon_button("icons/save.png", "Save the current settings as a preset", "Save")
		save.connect("pressed", self, "_on_save_pressed", [scope])
		row.add_child(save)
		var ren = _make_icon_button("icons/rename.png", "Rename the selected preset", "Ren")
		ren.connect("pressed", self, "_on_rename_pressed", [scope])
		row.add_child(ren)
		var del = _make_icon_button("icons/delete.png", "Delete the selected preset", "Del")
		del.connect("pressed", self, "_on_delete_pressed", [scope])
		row.add_child(del)
		r["rename"] = ren
		r["delete"] = del
	parent.add_child(row)
	_rows[scope] = r
	_current[scope] = ""
	_refresh_list(scope)
	if _timer == null:
		_timer = Timer.new()
		_timer.wait_time = 0.3
		_timer.autostart = true
		_timer.connect("timeout", self, "_on_tick")
		global.Editor.add_child(_timer)

func _load_icon(icon_path: String, scale: float = 0.65) -> ImageTexture:
	var image = Image.new()
	if image.load(global.Root + icon_path) != OK:
		return null
	if scale != 1.0:
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

# Icon button (same look as the reset / copy / paste buttons); falls back to
# `fallback_text` if the icon file is missing.
func _make_icon_button(icon_path: String, tooltip: String, fallback_text: String) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	btn.focus_mode = Control.FOCUS_NONE
	var tex = _load_icon(icon_path)
	if tex != null:
		btn.icon = tex
		# Tighter inner padding than the default button style: the icon
		# fills the button instead of floating in it.
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			var sbx = btn.get_stylebox(st).duplicate()
			sbx.content_margin_left = 3
			sbx.content_margin_right = 3
			sbx.content_margin_top = 2
			sbx.content_margin_bottom = 2
			btn.add_stylebox_override(st, sbx)
	else:
		btn.text = fallback_text
	return btn

func _refresh_list(scope: String) -> void:
	var r = _rows[scope]
	var opt = r["option"]
	_syncing = true
	opt.clear()
	opt.add_item(NONE_LABEL, 0)
	var names = _names()
	var sel = 0
	for i in range(names.size()):
		opt.add_item(names[i], i + 1)
		if names[i] == _current[scope]:
			sel = i + 1
	if sel == 0:
		_current[scope] = ""
	opt.selected = sel
	_syncing = false
	_update_buttons(scope)
	_update_label(scope, false)

func _update_buttons(scope: String) -> void:
	var r = _rows[scope]
	var has = _current[scope] != ""
	if r.has("rename"):
		r["rename"].disabled = not has
		r["delete"].disabled = not has

func _update_label(scope: String, dirty: bool) -> void:
	var r = _rows[scope]
	var opt = r["option"]
	var idx = opt.selected
	if idx <= 0:
		opt.set_item_text(0, NONE_LABEL)
		return
	var name = _current[scope]
	opt.set_item_text(idx, name + (" *" if dirty else ""))

# Refresh both rows from disk (after a save / rename / delete in any scope).
func _refresh_all() -> void:
	for scope in _rows.keys():
		_refresh_list(scope)

#########################################################################################################
## DIRTY MARKER
#########################################################################################################

func _cfg_equal(a, b) -> bool:
	if a is Color and b is Color:
		return a.to_html(true) == b.to_html(true)
	if a is Color and b is String:
		return a.to_html(true) == b
	if a is String and b is Color:
		return a == b.to_html(true)
	if (a is float or a is int) and (b is float or b is int):
		return abs(float(a) - float(b)) < 0.0005
	return str(a) == str(b)

func _is_dirty(scope: String) -> bool:
	var name = _current[scope]
	if name == "":
		return false
	var presets = _presets()
	if not presets.has(name):
		return false
	var cur = module.preset_get_config(scope)
	if cur == null:
		return false
	var p = presets[name]
	for k in p.keys():
		if not cur.has(k):
			continue
		if not _cfg_equal(cur[k], p[k]):
			return true
	return false

func _on_tick() -> void:
	for scope in _rows.keys():
		var r = _rows[scope]
		if not is_instance_valid(r["option"]) or not r["option"].is_visible_in_tree():
			continue
		# Follow the selection / tool assignment.
		var name = _assigned_name(scope)
		if name != _current[scope]:
			_current[scope] = name
			_refresh_list(scope)
		if _current[scope] == "":
			continue
		_update_label(scope, _is_dirty(scope))

func _on_option_input(event: InputEvent, scope: String) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var opt = _rows[scope]["option"]
	var step = 0
	if event.button_index == BUTTON_WHEEL_UP:
		step = -1
	elif event.button_index == BUTTON_WHEEL_DOWN:
		step = 1
	if step == 0:
		return
	var idx = clamp(opt.selected + step, 0, opt.get_item_count() - 1)
	if idx != opt.selected:
		opt.selected = idx
		_on_selected(idx, scope)
	opt.accept_event()

#########################################################################################################
## HANDLERS
#########################################################################################################

func _on_selected(idx: int, scope: String) -> void:
	if _syncing:
		return
	var r = _rows[scope]
	if idx <= 0:
		_current[scope] = ""
		_assign(scope, "")
		_restore_backup(scope)
		_update_buttons(scope)
		return
	var name = r["option"].get_item_text(idx).trim_suffix(" *")
	var presets = _presets()
	if not presets.has(name):
		_refresh_list(scope)
		return
	_current[scope] = name
	_backup_before_apply(scope)
	module.preset_apply(scope, _deserialize(presets[name]))
	_assign(scope, name)
	_update_buttons(scope)
	_update_label(scope, false)

func _on_save_pressed(scope: String) -> void:
	_open_name_dialog("save", scope, _current[scope])

func _on_rename_pressed(scope: String) -> void:
	if _current[scope] == "":
		return
	_open_name_dialog("rename", scope, _current[scope])

func _on_delete_pressed(scope: String) -> void:
	var name = _current[scope]
	if name == "":
		return
	_pending = {"kind": "delete", "name": name, "scope": scope}
	_open_confirm("Delete preset \"%s\"?" % name, "Delete")

#########################################################################################################
## DIALOGS
#########################################################################################################

func _ensure_dialog() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	_dialog = ConfirmationDialog.new()
	_dialog.window_title = "Shadow preset"
	_dialog.rect_min_size = Vector2(320, 150)
	var box = VBoxContainer.new()
	box.name = "Box"
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.margin_left = 8
	box.margin_top = 8
	box.margin_right = -8
	box.margin_bottom = -40
	var nl = Label.new()
	nl.text = "Name"
	box.add_child(nl)
	var edit = LineEdit.new()
	edit.name = "NameEdit"
	edit.connect("text_entered", self, "_on_dialog_text_entered")
	box.add_child(edit)
	var inc = CheckBox.new()
	inc.name = "IncludeOffset"
	inc.text = "Include offset"
	inc.pressed = true
	box.add_child(inc)
	_dialog.add_child(box)
	_dialog.get_ok().text = "OK"
	_dialog.connect("confirmed", self, "_on_dialog_confirmed")
	global.Editor.get_node("Windows").add_child(_dialog)

func _open_name_dialog(mode: String, scope: String, prefill: String) -> void:
	_ensure_dialog()
	_dialog_mode = mode
	_dialog_scope = scope
	_dialog.window_title = "Save shadow preset" if mode == "save" else "Rename shadow preset"
	var edit = _dialog.get_node("Box/NameEdit")
	var inc = _dialog.get_node("Box/IncludeOffset")
	edit.text = prefill
	inc.visible = (mode == "save")
	_dialog.popup_centered()
	edit.grab_focus()
	edit.select_all()

func _on_dialog_text_entered(_t) -> void:
	_dialog.hide()
	_on_dialog_confirmed()

func _on_dialog_confirmed() -> void:
	var edit = _dialog.get_node("Box/NameEdit")
	var inc = _dialog.get_node("Box/IncludeOffset")
	var name = edit.text.strip_edges()
	if name == "":
		return
	var scope = _dialog_scope
	if _dialog_mode == "save":
		var cfg = module.preset_get_config(scope)
		if cfg == null:
			return
		var preset = _preset_from_config(cfg, inc.pressed)
		if _presets().has(name) and name != _current[scope]:
			_pending = {"kind": "save", "name": name, "cfg": preset, "scope": scope}
			_open_confirm("A preset named \"%s\" already exists." % name, "Replace", "Choose another name")
			return
		_store(name, preset)
		_backup_before_apply(scope)
		_current[scope] = name
		_assign(scope, name)
		_refresh_all()
	elif _dialog_mode == "rename":
		var old = _current[scope]
		if old == "" or name == old:
			return
		if _presets().has(name):
			_pending = {"kind": "rename", "name": name, "old": old, "scope": scope}
			_open_confirm("A preset named \"%s\" already exists." % name, "Replace", "Choose another name")
			return
		_rename(old, name)
		_assign_renamed(old, name)
		_current[scope] = name
		_refresh_all()

func _open_confirm(text: String, ok_text: String, cancel_text: String = "Cancel") -> void:
	if _confirm == null or not is_instance_valid(_confirm):
		_confirm = ConfirmationDialog.new()
		_confirm.window_title = "Shadow preset"
		_confirm.connect("confirmed", self, "_on_confirm_ok")
		_confirm.get_cancel().connect("pressed", self, "_on_confirm_cancel")
		global.Editor.get_node("Windows").add_child(_confirm)
	_confirm.dialog_text = text
	_confirm.get_ok().text = ok_text
	_confirm.get_cancel().text = cancel_text
	_confirm.popup_centered()

func _on_confirm_ok() -> void:
	if _pending == null:
		return
	var p = _pending
	_pending = null
	match p["kind"]:
		"save":
			_store(p["name"], p["cfg"])
			_backup_before_apply(p["scope"])
			_current[p["scope"]] = p["name"]
			_assign(p["scope"], p["name"])
		"rename":
			_remove(p["name"])
			_assign_removed(p["name"])
			_rename(p["old"], p["name"])
			_assign_renamed(p["old"], p["name"])
			_current[p["scope"]] = p["name"]
		"delete":
			_remove(p["name"])
			_assign_removed(p["name"])
			for scope in _current.keys():
				if _current[scope] == p["name"]:
					_current[scope] = ""
	_refresh_all()

func _on_confirm_cancel() -> void:
	if _pending == null:
		return
	var p = _pending
	_pending = null
	if p["kind"] == "save" or p["kind"] == "rename":
		# "Choose another name": reopen the name dialog with the typed name.
		_open_name_dialog(p["kind"], p["scope"], p["name"])
