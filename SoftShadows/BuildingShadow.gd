#########################################################################################################
##
## BUILDING SHADOW MODULE
##
#########################################################################################################
# Injects a "Building Shadow" toggle button into the PatternShapeTool panel.
# When active, clicking inside a building (any enclosed room) computes the outer
# silhouette of the whole structure (interior walls are absorbed), extrudes it
# along a configurable direction/distance, and creates the resulting shadow as a
# regular PatternShape (plain black, semi-transparent) — fully editable with the
# native pattern tools and compatible with third-party pattern effects (blur).
#
# Geometry engine: region_geometry.gd (copied from the Unofficial Patch).

var script_class = "tool"

var global
var core
var logging_level = 0

const BUILD = "BUILDSHADOW-65"
const META_KEY = "SoftShadowsBuildingShadowListener"

# Default appearance / placement
const DEFAULT_LAYER = 499
const DEFAULT_ANGLE_DEG = 45.0      # screen-space: 45 = down-right
const DEFAULT_DISTANCE = 256.0      # pixels
const DEFAULT_OPACITY = 50.0        # percent
const DIAL_SIZE = 90
const DEFAULT_RANGE = 256.0         # dial max offset (px)
const PREVIEW_THROTTLE_MS = 50
const DEFAULT_RIDGE_HEIGHT = 1.3    # ridge offset multiplier
const RIDGE_MIN_EDGE = 128.0        # edges shorter than this stay flat (no peak)
const APPLY_INFLATE = 25.0          # px added around the pattern at Apply time
const SEAM_DEBUG := false           # dump applied rings to user://bs_seam_debug.txt
const BS_TEX_KEY := "BuildingShadowTex"  # ModMapData: {node_id(str): opacity_pct} — mirrored in ShadowToggle.BS_PATTERN_KEY
const SHADOW_TOGGLE_KEY := "DropShadowToggleHidden"  # ShadowToggle's global state
const MIN_RING_AREA = 400.0         # px²: cleanup fragments below this are culled instead of becoming micro-patterns

var _geo = null                     # region_geometry instance
var _tool_injected := false
var _active := false
var _busy := false

# UI
var _opts_margin = null
var _shape_hbox = null
var _shape_buttons = []
var _button = null
var _opts_box = null
var _sl_range = null
var _sl_opacity = null
var _sl_layer = null
var _dial = null
var _dial_dot = null
var _snap_buttons = {}
var _sp_angle = null
var _sp_dist = null
var _ui_syncing := false
var _cb_walls = null
var _cb_paths = null
var _pv_label = null
var _last_range := DEFAULT_RANGE
var _last_click_world := Vector2.ZERO
var _has_last_click := false
var _btn_apply = null
var _btn_cancel = null
var _lbl_confirm = null
var _blur_row = null
var _btn_blur = null
var _btn_invert = null
var _btn_ridge = null
var _sl_ridge = null
var _opt_ridge_mode = null
var _ridge_edges = {}               # manual mode: {"sil:edge": true}
var _lbl_manual_hint = null
var _ridge_mode_row = null
var _ridge_rand_row = null
var _btn_ridge_rand = null
var _btn_reroll = null
var _ridge_rand_seed := 0.0

# Building hover highlight
var _hl_node = null
var _hl_sils = []
var _hl_cache = []                  # previously computed buildings (session)
var _hl_fails = []                  # recent positions where nothing was found
var _hl_last_try := 0
const HL_THROTTLE_MS = 120
const HL_CACHE_MAX = 12
const HL_FAILS_MAX = 16
var _pv_peaked = []                 # segments that actually get a ridge peak
var _dbg_capture := false
var _dbg_lines = []
var _apply_pass := false            # precise bridging only at Apply time
var _last_level_id := 0             # level-switch detection (highlight purge)
var _bs_world_id := -1              # map open/new detection (texture restore)
var _bs_restore_frames := -1
var _solids_cache = null            # barrier solids (C# extraction is costly)
var _solids_cache_key := ""
var _last_extrude_ms := 0
var _hover_line = null
var _hover_key := ""
var _uchideshi = null               # EdgeBlurPatterns instance (uchideshi's mod), if detected

# Shadow offset vector (shadow displacement in px, same convention as the
# other modules: the dial handle points at the SUN, the offset is opposite)
var _offset := Vector2.ZERO

# Preview state
var _pv_sils = []                   # cached cleaned silhouettes (Array of rings)
var _pv_rings = []                  # last computed shadow rings (ready to draw)
var _pv_level = null                # level the preview belongs to
var _pv_node = null                 # Node2D holding the preview Polygon2Ds
var _pv_dirty := false
var _pv_last_compute := 0

# Pending-preview confirmation popup
var _confirm = null
var _popup_pending := false

# Dynamic button placement / tool-switch tracking
var _hbox_child_count := -1
var _was_tool_active := false
var _ep_was_active := false
var _saved_cursor_mode = null
var _align = null
var _hidden_panel_items = []

var input_listener = null


func outputlog(msg, level=0):
	if level <= logging_level:
		printraw("(%d) <BuildingShadow>: " % OS.get_ticks_msec())
		print(msg)


#########################################################################################################
##
## INITIALISE
##
#########################################################################################################

func initialise():
	outputlog("[BUILD: %s] initialising" % BUILD, 0)

	_offset = Vector2(cos(deg2rad(DEFAULT_ANGLE_DEG)), sin(deg2rad(DEFAULT_ANGLE_DEG))) * DEFAULT_DISTANCE

	var geo_script = ResourceLoader.load(global.Root + "region_geometry.gd", "GDScript", true)
	if geo_script == null:
		outputlog("ERROR: region_geometry.gd not found — Building Shadow disabled", 0)
		return
	_geo = geo_script.new()
	outputlog("region_geometry version: %s" % str(_geo.get("RG_VERSION")), 0)

	# Invalidate the building-highlight cache when walls/paths/portals are
	# added, removed or edited (point editing recreates the wall's Line2D
	# children every frame, so it is caught too). Near-zero cost per node:
	# immediate early-out while the caches are empty.
	var tree = global.Editor.get_tree()
	if tree != null:
		if not tree.is_connected("node_added", self, "_on_tree_node_added"):
			tree.connect("node_added", self, "_on_tree_node_added")
		if not tree.is_connected("node_removed", self, "_on_tree_node_removed"):
			tree.connect("node_removed", self, "_on_tree_node_removed")
	_geo._g = global

	_install_listener()
	_try_inject_ui()


# Called every frame by Core.update — retries UI injection until the pattern
# tool panel exists, then handles mode exclusivity with native shape buttons
# and drives the throttled preview refresh.
func on_update(_delta):
	if not _tool_injected:
		_try_inject_ui()
		return
	if _button == null or not is_instance_valid(_button):
		_tool_injected = false
		return

	# Map transition: World/WorldUI/Level are being freed — touch NOTHING
	# world-related this frame, and drop our references to the dead nodes.
	if not _world_ready():
		_drop_world_state()
		return

	# Map open/new detection → deferred texture restore from ModMapData
	# (a few frames after the World appears, once patterns are loaded)
	var wid = global.World.get_instance_id()
	if wid != _bs_world_id:
		_bs_world_id = wid
		_bs_restore_frames = 45
	if _bs_restore_frames > 0:
		_bs_restore_frames -= 1
		if _bs_restore_frames == 0:
			_restore_embedded_textures()

	# Level switch: the green highlight node lives on the level it was
	# created on — DD renders lower levels beneath the current one, so a
	# leftover kept showing through. The silhouette cache is also world-
	# coordinate based and must not leak across levels. Purge on EVERY
	# switch (the old purge only ran while a preview existed).
	var cur_level = _get_current_level()
	var cur_level_id = cur_level.get_instance_id() if cur_level != null else 0
	if cur_level_id != _last_level_id:
		_last_level_id = cur_level_id
		_reset_building_highlight_cache()

	# Keep the button right of the bucket even if the bucket injects later
	if _shape_hbox != null and is_instance_valid(_shape_hbox) \
			and _shape_hbox.get_child_count() != _hbox_child_count:
		_hbox_child_count = _shape_hbox.get_child_count()
		_ensure_button_position()

	# Tool switched away while a preview is pending → ask what to do
	var tool_now = _is_pattern_tool_active()
	if _was_tool_active and not tool_now and _active:
		_maybe_prompt_pending()
	_was_tool_active = tool_now

	# Preview housekeeping (also when inactive, e.g. after tool switch)
	if _pv_node != null:
		if not is_instance_valid(_pv_node) or _get_current_level() != _pv_level:
			_reset_building_highlight_cache()
			_force_discard_pending()
		elif not _active and not _popup_pending:
			_clear_preview()
	var throttle = int(clamp(_last_extrude_ms * 1.5, PREVIEW_THROTTLE_MS, 350))
	if _active and _pv_dirty and _pv_sils.size() > 0 \
			and OS.get_ticks_msec() - _pv_last_compute > throttle:
		_refresh_preview_geometry()

	# Suppress DD's yellow point cursor while our mode is active — the tool
	# re-sets CursorMode = Point every frame, so we override it after it runs
	if _active and _is_pattern_tool_active() and not _edit_points_active():
		var wui = _get_world_ui()
		if wui != null:
			# Remember the original mode the first time we override it, so we
			# can restore it on exit — leaving 0 behind breaks the right-click
			# "finish drawing" of vertex-based tools (paths/walls/patterns)
			# when the next tool does not reset CursorMode itself.
			if _saved_cursor_mode == null:
				_saved_cursor_mode = wui.get("CursorMode")
			wui.set("CursorMode", 0)
	else:
		_restore_cursor_mode()

	# Green highlight of the building under the cursor (pick feedback)
	_update_building_highlight()

	# Manual mode: hover highlight of the segment under the cursor + hint text
	if _lbl_manual_hint != null and is_instance_valid(_lbl_manual_hint):
		_lbl_manual_hint.visible = _active and _ridge_manual_active()
	if _active and _ridge_manual_active() and _pv_node != null and is_instance_valid(_pv_node):
		_update_hover_highlight()
	elif _hover_line != null and is_instance_valid(_hover_line):
		_hover_line.visible = false

	if not _active:
		return

	# Edit Points runs INSIDE our mode: our UI stays, and while it is pressed
	# we simply step aside (no click interception, no cursor override, no
	# building highlight) so the native point editing works untouched.
	# While a preview is pending it is grayed out instead.
	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool != null:
		var ep = pat_tool.get("EditPoints")
		if ep != null:
			var pending = _pv_sils.size() > 0
			if ep.get("disabled") != pending:
				ep.set("disabled", pending)
	# Leaving Edit Points: DD restores its default shape mode (rectangle) —
	# reclaim our mode BEFORE the exclusivity polling below sees that button
	# pressed and deactivates us.
	var ep_now = _edit_points_active()
	if _ep_was_active and not ep_now:
		for _pass in range(2):
			for btn in _iter_other_toggles():
				if btn.pressed:
					btn.pressed = false
	_ep_was_active = ep_now
	for btn in _iter_other_toggles():
		if btn.pressed:
			_set_active(false)
			return


#########################################################################################################
##
## UI INJECTION
##
#########################################################################################################

func _try_inject_ui():
	if _tool_injected:
		return
	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return
	var tool_panel = global.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if tool_panel == null:
		return
	var align = core.get_align_vbox(tool_panel)
	if align == null:
		return
	_align = align

	# Find the HBoxContainer holding the native shape toggle buttons
	_shape_hbox = null
	for child in align.get_children():
		if child is HBoxContainer:
			var has_toggles = false
			for btn in child.get_children():
				if btn is Button and btn.toggle_mode:
					has_toggles = true
					break
			if has_toggles:
				_shape_hbox = child
				break
	if _shape_hbox == null:
		var ep_btn = pat_tool.get("EditPoints")
		if ep_btn != null:
			_shape_hbox = ep_btn.get_parent()
	if _shape_hbox == null:
		outputlog("WARNING: cannot find a place to inject the Building Shadow button", 0)
		_tool_injected = true  # do not retry forever
		return

	_shape_buttons = []
	for child in _shape_hbox.get_children():
		if child is Button and child.toggle_mode:
			_shape_buttons.append(child)
			if not child.is_connected("pressed", self, "_on_shape_button_pressed"):
				child.connect("pressed", self, "_on_shape_button_pressed")

	_button = Button.new()
	_button.toggle_mode = true
	_button.hint_tooltip = "Building Shadow: click inside a building to preview its drop shadow, adjust with the dial, then press Apply.\nThe whole structure outline is detected (interior walls are skipped) and extruded along the configured direction."
	var icon = _load_icon_texture("building_shadow.png")
	if icon != null:
		_button.icon = icon
	else:
		_button.text = "BS"
	_button.connect("toggled", self, "_on_button_toggled")
	_shape_hbox.add_child(_button)

	# Place the button right AFTER the Unofficial Patch bucket button if it is
	# already there; otherwise stay at the end of the row (the bucket injects
	# itself at the end too, so relative order stays correct either way).
	for child in _shape_hbox.get_children():
		if child != _button and child is Button \
				and str(child.hint_tooltip).begins_with("Paint Bucket"):
			_shape_hbox.move_child(_button, child.get_index() + 1)
			break

	_build_options_box(align)

	_tool_injected = true
	outputlog("Building Shadow button injected (%d native shape buttons)" % _shape_buttons.size(), 0)


func _build_options_box(align):
	_opts_box = VBoxContainer.new()

	# Performance warning (organic shapes = thousands of points)
	var lbl_perf = Label.new()
	lbl_perf.text = "Please use this tool on simple geometric shapes. Natural/organic shapes will make it lag."
	lbl_perf.autowrap = true
	lbl_perf.add_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))
	_opts_box.add_child(lbl_perf)

	# Help text
	var help = Label.new()
	help.text = "Click inside a building to generate its outer shadow as a pattern"
	help.autowrap = true
	help.add_color_override("font_color", Color(0.75, 0.75, 0.75, 1.0))
	_opts_box.add_child(help)

	# Barrier types (same idea as the bucket's "Stopped by" row)
	var bar_row = HBoxContainer.new()
	var lbl_b = Label.new()
	lbl_b.text = "Building Borders:"
	bar_row.add_child(lbl_b)
	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	_cb_walls.connect("toggled", self, "_on_barrier_toggled")
	bar_row.add_child(_cb_walls)
	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = false
	_cb_paths.connect("toggled", self, "_on_barrier_toggled")
	bar_row.add_child(_cb_paths)
	_opts_box.add_child(bar_row)

	# ── Offset dial (same system as the other shadow tools: handle = sun
	# position, shadow goes the opposite way; quadratic magnitude mapping;
	# diagonal snap buttons) ────────────────────────────────────────────
	var dial_container = CenterContainer.new()
	dial_container.rect_clip_content = false
	var dial_margin = MarginContainer.new()
	dial_margin.rect_clip_content = false
	dial_margin.add_constant_override("margin_left", 8)
	dial_margin.add_constant_override("margin_right", 8)
	dial_margin.add_constant_override("margin_top", 8)
	dial_margin.add_constant_override("margin_bottom", 8)
	var dial = _create_dial(DIAL_SIZE)
	dial_margin.add_child(dial)
	dial_container.add_child(dial_margin)
	_opts_box.add_child(dial_container)

	# Angle / Distance spinboxes, two-way synced with the dial
	var spin_row = HBoxContainer.new()
	var lbl_a = Label.new()
	lbl_a.text = "Angle"
	spin_row.add_child(lbl_a)
	_sp_angle = SpinBox.new()
	_sp_angle.min_value = 0
	_sp_angle.max_value = 360
	_sp_angle.step = 1
	_sp_angle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp_angle.connect("value_changed", self, "_on_spin_changed")
	spin_row.add_child(_sp_angle)
	var lbl_d = Label.new()
	lbl_d.text = "Distance"
	spin_row.add_child(lbl_d)
	_sp_dist = SpinBox.new()
	_sp_dist.min_value = 0
	_sp_dist.max_value = DEFAULT_RANGE
	_sp_dist.step = 1
	_sp_dist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp_dist.connect("value_changed", self, "_on_spin_changed")
	spin_row.add_child(_sp_dist)
	_opts_box.add_child(spin_row)

	_sl_range = _add_slider_row(_opts_box, "Max Distance", 32.0, 2048.0, 1.0, DEFAULT_RANGE, "px")
	_sl_opacity = _add_slider_row(_opts_box, "Opacity", 0.0, 100.0, 1.0, DEFAULT_OPACITY, "%")
	_sl_layer = _add_slider_row(_opts_box, "Layer", -500.0, 900.0, 1.0, float(DEFAULT_LAYER), "")

	# Ridge: every flat wall facing the shadow gets a midpoint "roof peak"
	# projected further out, turning its shadow front into a gable triangle.
	var ridge_row = HBoxContainer.new()
	var lbl_ridge = Label.new()
	lbl_ridge.text = "Ridge"
	lbl_ridge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl_ridge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ridge_row.add_child(lbl_ridge)
	_btn_ridge = CheckButton.new()
	_btn_ridge.hint_tooltip = "Pointed-roof shadows: the middle of each wall casts further, like a roof ridge"
	_btn_ridge.size_flags_horizontal = Control.SIZE_SHRINK_END
	_btn_ridge.connect("toggled", self, "_on_ridge_toggled")
	ridge_row.add_child(_btn_ridge)
	_opts_box.add_child(ridge_row)
	_ridge_mode_row = HBoxContainer.new()
	var mode_row = _ridge_mode_row
	var lbl_mode = Label.new()
	lbl_mode.text = "Ridge Mode"
	lbl_mode.rect_min_size = Vector2(70, 0)
	lbl_mode.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mode_row.add_child(lbl_mode)
	_opt_ridge_mode = OptionButton.new()
	_opt_ridge_mode.add_item("All Walls", 0)
	_opt_ridge_mode.add_item("Horizontal", 1)
	_opt_ridge_mode.add_item("Vertical", 2)
	_opt_ridge_mode.add_item("Manual", 3)
	_opt_ridge_mode.selected = 1  # Horizontal by default
	_opt_ridge_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opt_ridge_mode.hint_tooltip = "All Walls: every sun-facing wall gets a ridge.\nHorizontal / Vertical: only walls along that axis.\nManual: click wall segments on the map to toggle their ridge (green overlay)."
	_opt_ridge_mode.connect("item_selected", self, "_on_ridge_mode_selected")
	mode_row.add_child(_opt_ridge_mode)
	_opts_box.add_child(mode_row)
	_lbl_manual_hint = Label.new()
	_lbl_manual_hint.text = "Click on the building segments you want to have a ridge (click again to remove ridge)"
	_lbl_manual_hint.autowrap = true
	_lbl_manual_hint.add_color_override("font_color", Color(0.2, 0.9, 0.3, 1.0))
	_lbl_manual_hint.visible = false
	_opts_box.add_child(_lbl_manual_hint)
	_sl_ridge = _add_slider_row(_opts_box, "Ridge Height", 1.0, 3.0, 0.1, DEFAULT_RIDGE_HEIGHT, "x")
	_ridge_rand_row = HBoxContainer.new()
	var lbl_rand = Label.new()
	lbl_rand.text = "Random Height"
	lbl_rand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl_rand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ridge_rand_row.add_child(lbl_rand)
	_btn_reroll = Button.new()
	_btn_reroll.disabled = true
	_btn_reroll.hint_tooltip = "Reroll the random ridge heights"
	var dice = _load_icon_texture("dice-icon.png")
	if dice != null:
		_btn_reroll.icon = dice
	else:
		_btn_reroll.text = "R"
	_btn_reroll.connect("pressed", self, "_on_reroll_pressed")
	_ridge_rand_row.add_child(_btn_reroll)
	_btn_ridge_rand = CheckButton.new()
	_btn_ridge_rand.hint_tooltip = "Randomize each ridge height (deterministic per segment, so the preview stays stable)"
	_btn_ridge_rand.size_flags_horizontal = Control.SIZE_SHRINK_END
	_btn_ridge_rand.connect("toggled", self, "_on_ridge_rand_toggled")
	_ridge_rand_row.add_child(_btn_ridge_rand)
	_opts_box.add_child(_ridge_rand_row)
	_update_ridge_settings_visibility()

	# ── Apply / Cancel ──────────────────────────────────────────────────
	# Optional Blur toggle (only shown when uchideshi's Colour and Modify
	# Things mod is detected): applies an edge blur (smoothness 0, blur
	# range 0.1) through his mod right after the pattern is created.
	# CheckButton = the native DD-themed toggle switch.
	_blur_row = HBoxContainer.new()
	_blur_row.visible = false
	var lbl_blur = Label.new()
	lbl_blur.text = "Blur"
	lbl_blur.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_blur_row.add_child(lbl_blur)
	var lbl_blur_note = Label.new()
	lbl_blur_note.text = "(not visible on preview)"
	lbl_blur_note.add_color_override("font_color", Color(0.65, 0.65, 0.65, 1.0))
	lbl_blur_note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl_blur_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blur_row.add_child(lbl_blur_note)
	_btn_blur = CheckButton.new()
	_btn_blur.hint_tooltip = "Apply an edge blur (smoothness 0, blur range 0.1) to the created shadow via the Colour and Modify Things mod"
	_btn_blur.size_flags_horizontal = Control.SIZE_SHRINK_END
	_blur_row.add_child(_btn_blur)
	_opts_box.add_child(_blur_row)

	# Invert (courtyard mode): stop at the FIRST walls around the click and
	# cast the shadow INSIDE them, for holes/courtyards enclosed in a building
	var invert_row = HBoxContainer.new()
	var lbl_invert = Label.new()
	lbl_invert.text = "Invert"
	lbl_invert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	invert_row.add_child(lbl_invert)
	var lbl_invert_note = Label.new()
	lbl_invert_note.text = "(inner courtyard)"
	lbl_invert_note.add_color_override("font_color", Color(0.65, 0.65, 0.65, 1.0))
	lbl_invert_note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl_invert_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	invert_row.add_child(lbl_invert_note)
	_btn_invert = CheckButton.new()
	_btn_invert.hint_tooltip = "Courtyard mode: stop at the first walls around the click and cast the shadow INSIDE them.\nUse it by clicking inside a courtyard or any hole enclosed in a building."
	_btn_invert.size_flags_horizontal = Control.SIZE_SHRINK_END
	_btn_invert.connect("toggled", self, "_on_invert_toggled")
	invert_row.add_child(_btn_invert)
	_opts_box.add_child(invert_row)

	var btn_row = HBoxContainer.new()
	_btn_apply = Button.new()
	_btn_apply.text = "Apply"
	_btn_apply.disabled = true
	_btn_apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_apply.hint_tooltip = "Create the previewed shadow as a pattern"
	_btn_apply.connect("pressed", self, "_on_apply_pressed")
	_style_outlined_button(_btn_apply)
	btn_row.add_child(_btn_apply)
	_btn_cancel = Button.new()
	_btn_cancel.text = "Cancel"
	_btn_cancel.disabled = true
	_btn_cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_cancel.hint_tooltip = "Discard the preview"
	_btn_cancel.connect("pressed", self, "_on_cancel_pressed")
	_style_outlined_button(_btn_cancel)
	btn_row.add_child(_btn_cancel)
	_opts_box.add_child(btn_row)

	# Pending-preview reminder
	_lbl_confirm = Label.new()
	_lbl_confirm.text = "CLICK APPLY TO CONFIRM SHAPE"
	_lbl_confirm.align = Label.ALIGN_CENTER
	_lbl_confirm.autowrap = true
	_lbl_confirm.add_color_override("font_color", Color(1.0, 0.25, 0.25, 1.0))
	_lbl_confirm.visible = false
	_opts_box.add_child(_lbl_confirm)

	# Insert right below the shape buttons row, with a small right margin so
	# the controls are not glued to the panel edge
	_opts_margin = MarginContainer.new()
	_opts_margin.add_constant_override("margin_right", 10)
	_opts_margin.visible = false
	_opts_box.visible = true
	_opts_margin.add_child(_opts_box)
	var parent = _shape_hbox.get_parent()
	parent.add_child(_opts_margin)
	parent.move_child(_opts_margin, _shape_hbox.get_index() + 1)

	_update_dial_handle()


# Builds a "Label [slider] value" row, returns the HSlider.
func _add_slider_row(box, label_text: String, minv: float, maxv: float, step: float, defv: float, suffix: String):
	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(70, 0)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	var sl = HSlider.new()
	sl.min_value = minv
	sl.max_value = maxv
	sl.step = step
	sl.value = defv
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)
	var spin = SpinBox.new()
	spin.min_value = minv
	spin.max_value = maxv
	spin.step = step
	spin.value = defv
	spin.suffix = suffix
	spin.rect_min_size = Vector2(64, 0)
	row.add_child(spin)
	sl.set_meta("spin", spin)
	sl.connect("value_changed", self, "_on_slider_changed", [sl])
	spin.connect("value_changed", self, "_on_row_spin_changed", [sl])
	box.add_child(row)
	return sl


func _on_slider_changed(value, slider):
	var spin = slider.get_meta("spin")
	if spin != null and is_instance_valid(spin) and spin.value != value:
		_ui_syncing = true
		spin.value = value
		_ui_syncing = false
	if slider == _sl_opacity:
		_update_preview_style()
	elif slider == _sl_layer:
		_update_preview_style()
	elif slider == _sl_ridge:
		_pv_dirty = true
	elif slider == _sl_range:
		# Same behaviour as the other shadow tools: the offset keeps its dial
		# fraction, so the shadow moves proportionally when the max changes,
		# in both directions.
		if _sp_dist != null and is_instance_valid(_sp_dist):
			_sp_dist.max_value = value
		if _last_range > 0.5 and _offset.length() > 0.5:
			_set_offset(_offset * (value / _last_range))
		else:
			_update_dial_handle()
		_last_range = value


# Per-row spinbox → drives its slider (which runs the side effects)
func _on_row_spin_changed(value, slider):
	if _ui_syncing:
		return
	if slider != null and is_instance_valid(slider) and slider.value != value:
		slider.value = value


# Spinbox → offset (dial and handle follow via _set_offset)
func _on_spin_changed(_value):
	if _ui_syncing:
		return
	if _sp_angle == null or _sp_dist == null:
		return
	var ang = deg2rad(float(_sp_angle.value))
	var d = float(_sp_dist.value)
	_set_offset(Vector2(cos(ang), sin(ang)) * d)


func _on_shape_button_pressed():
	if _active:
		_button.pressed = false


func _on_button_toggled(pressed: bool):
	_set_active(pressed)


# Returns every OTHER toggle button currently in the shape row (natives + any
# injected ones like the Unofficial Patch bucket, regardless of load order).
func _iter_other_toggles() -> Array:
	var out = []
	if _shape_hbox == null or not is_instance_valid(_shape_hbox):
		return out
	for child in _shape_hbox.get_children():
		if child != _button and child is Button and child.toggle_mode:
			out.append(child)
	return out


func _set_active(active: bool):
	_active = active
	if not active:
		_restore_cursor_mode()
		_reset_building_highlight_cache()
		# Leaving the mode with an unapplied preview → ask instead of dropping
		if not _maybe_prompt_pending():
			_clear_preview()
	if _button != null and is_instance_valid(_button) and _button.pressed != active:
		_button.pressed = active
	if _opts_margin != null and is_instance_valid(_opts_margin):
		_opts_margin.visible = active

	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return
	var ep_btn = pat_tool.get("EditPoints")
	if not active and ep_btn != null:
		ep_btn.set("disabled", false)
	if active:
		if _uchideshi == null:
			_detect_uchideshi()
		if _blur_row != null and is_instance_valid(_blur_row):
			_blur_row.visible = _uchideshi != null
		_hide_panel_extras()
		# Behave like a shape mode: release every other mode in the row
		# (native shapes AND injected buttons like the bucket) + EditPoints.
		# TWO passes: unpressing the bucket makes it restore its previous
		# native shape mode in its own toggled handler; the second pass
		# clears that restored mode so ours stays the active one.
		for _pass in range(2):
			for btn in _iter_other_toggles():
				if btn.pressed:
					btn.pressed = false
		var ep = pat_tool.get("EditPoints")
		if ep != null and ep.get("pressed") == true:
			ep.set("pressed", false)
	else:
		_restore_panel_extras()


#########################################################################################################
##
## INPUT
##
#########################################################################################################

func _install_listener():
	if Engine.has_meta(META_KEY):
		var old = Engine.get_meta(META_KEY)
		if is_instance_valid(old):
			old.handler = null
			old.queue_free()
	var node = Node.new()
	node.name = "BuildingShadowListener"
	var s = GDScript.new()
	s.source_code = "extends Node\nvar handler = null\nfunc _input(e):\n\tif handler == null: return\n\tif handler._on_input(e):\n\t\tget_tree().set_input_as_handled()\n"
	s.reload()
	node.set_script(s)
	node.handler = self
	Engine.set_meta(META_KEY, node)
	global.Editor.get_tree().get_root().call_deferred("add_child", node)
	input_listener = node


# True when the World is alive and in the tree — false during map load /
# teardown, where touching disposed C# objects (World, WorldUI, Level) from
# per-frame code crashes DD.
func _world_ready() -> bool:
	var world = global.get("World")
	if world == null or not is_instance_valid(world):
		return false
	if not world.is_inside_tree():
		return false
	return true


# WorldUI, guarded the same way (it is recreated per map)
func _get_world_ui():
	var wui = global.get("WorldUI")
	if wui == null or not is_instance_valid(wui):
		return null
	if wui is Node and not wui.is_inside_tree():
		return null
	return wui


func _is_pattern_tool_active() -> bool:
	return global.Editor.ActiveToolName == "PatternShapeTool"


# True while the native Edit Points mode is pressed (it then owns the canvas)
func _edit_points_active() -> bool:
	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return false
	var ep = pat_tool.get("EditPoints")
	return ep != null and ep.get("pressed") == true


func _on_input(event) -> bool:
	if not _active: return false
	if _busy: return false
	if _popup_pending: return false
	if not _world_ready(): return false
	if _edit_points_active(): return false
	if not _is_pattern_tool_active(): return false
	if not (event is InputEventMouseButton): return false
	if not event.pressed: return false
	if event.button_index != BUTTON_LEFT: return false

	# Ignore clicks anywhere on the editor HUD (tool switching column,
	# panels, menus) — otherwise consuming the event blocks tool switching.
	if _is_over_gui(event.position):
		outputlog("click ignored (over HUD: %s)" % _last_hit_desc, 1)
		return false

	var world_ui = _get_world_ui()
	if world_ui == null: return false
	var canvas_xform = world_ui.get_viewport().get_canvas_transform()
	var mouse_world: Vector2 = canvas_xform.affine_inverse().xform(event.position)

	# Manual ridge mode with an active preview: clicks ONLY toggle segments —
	# never re-pick a building (protects the current selection from stray
	# clicks). Switch mode or press Cancel to pick another building.
	if _ridge_manual_active() and _pv_sils.size() > 0:
		var seg = _find_clicked_segment(mouse_world)
		if seg != "":
			if _ridge_edges.has(seg):
				_ridge_edges.erase(seg)
			else:
				_ridge_edges[seg] = true
			_pv_dirty = true
		else:
			outputlog("Manual ridge: no segment within tolerance at %s (switch mode or Cancel to pick another building)" % str(mouse_world), 1)
		return true

	outputlog("consuming left click at %s (building pick)" % str(mouse_world), 1)
	_do_pick_building(mouse_world)
	return true


#########################################################################################################
##
## SHADOW CREATION PIPELINE
##
#########################################################################################################

# Computes the building silhouette(s) at the clicked position and shows the
# live preview. The pattern is only created when Apply is pressed.
func _do_pick_building(mouse_world: Vector2):
	_busy = true
	_last_click_world = mouse_world
	_has_last_click = true
	var t0 = OS.get_ticks_msec()
	var sils = _compute_silhouettes(mouse_world)
	if sils.size() == 0:
		_busy = false
		return
	_pv_sils = sils
	_pv_level = _get_current_level()
	_ridge_edges = {}
	_clear_building_highlight()
	_refresh_preview_geometry()
	outputlog("Building picked: %d silhouette(s) in %d ms — adjust the dial then press Apply" % [sils.size(), OS.get_ticks_msec() - t0], 0)
	_busy = false


# Steps 1-6 of the pipeline: from a click position to the cleaned, filled
# building silhouette ring(s).
func _compute_silhouettes(mouse_world: Vector2, quiet: bool = false) -> Array:
	var use_walls = _cb_walls.pressed if (_cb_walls != null and is_instance_valid(_cb_walls)) else true
	var use_paths = _cb_paths.pressed if (_cb_paths != null and is_instance_valid(_cb_paths)) else false
	if not use_walls and not use_paths:
		if not quiet:
			outputlog("Enable at least one barrier type (Walls / Paths)", 0)
		return []

	# 1) Clicked room. Validates the click is inside an enclosure.
	var room = _geo.compute_region(mouse_world, use_walls, use_paths, false)
	if room == null or room.outer.size() < 3:
		if not quiet:
			outputlog("No enclosed region found at click position (clicked on a wall or outside?)", 0)
		return []
	# Clicking outside any building yields the whole exterior as the region —
	# reject it instead of shadowing the entire map.
	var wnode = global.World
	if wnode != null:
		var mw = wnode.get("Width")
		var mh = wnode.get("Height")
		var ts = wnode.get("TileSize")
		if mw != null and mh != null and ts != null:
			var tsf = ts.x if ts is Vector2 else float(ts)
			var map_area = float(mw) * float(mh) * tsf * tsf
			if map_area > 0.0 and _geo._polygon_area(room.outer) > map_area * 0.6:
				if not quiet:
					outputlog("Click ignored: this region covers most of the map — click INSIDE a building", 0)
				return []

	# Invert (courtyard) mode: the clicked region itself, bounded by the
	# FIRST walls, is the shadow-receiving shape — no silhouette union needed.
	if _invert_on():
		var ring = _clean_ring_basic(_geo._ensure_ccw(room.outer))
		if ring.size() < 3:
			return []
		return [ring]

	# 2) Barrier solids for the whole level (thin bands along the polylines).
	# Cached: extracting wall/path points crosses the C# boundary for every
	# node — the dominant cost of a pick on complex maps. Invalidated by the
	# scene-tree signals (walls/paths edits), barrier toggles and level swaps.
	var cache_key = "%s_%s_%d" % [str(use_walls), str(use_paths), _level_uid()]
	var solids
	if _solids_cache != null and _solids_cache_key == cache_key:
		solids = _solids_cache
	else:
		solids = _geo._build_barrier_solids(use_walls, use_paths, false)
		_solids_cache = solids
		_solids_cache_key = cache_key
	if solids == null:
		return []

	# 3) Prune to solids plausibly connected to the clicked room: BFS on AABB
	#    adjacency seeded by the room bbox. Over-inclusive (nearby but separate
	#    buildings may slip in) — the exact union + adjacency filter below
	#    separates them again. Keeps the union cost local to the building.
	var room_bb = _geo._aabb(room.outer).grow(2.0 * _geo.BARRIER_THICKNESS + 2.0)
	var picked = _bfs_pick_solids(solids, room_bb)
	outputlog("Solids: %d total, %d candidates after AABB pruning" % [solids.size(), picked.size()], 1)

	# 4) Exact union of the candidate wall solids
	var comps = []
	for s in picked:
		comps.append(_geo._solid_to_comp(s))
	comps = _geo._union_components(comps)
	if comps == null:
		return []

	# 5) Keep only the components actually bordering the clicked room
	var room_grown = _grow_polygon(room.outer, 2.0 * _geo.BARRIER_THICKNESS + 2.0)
	var kept = []
	for c in comps:
		var inter = Geometry.intersect_polygons_2d(PoolVector2Array(c.outer), PoolVector2Array(room_grown))
		if inter != null and inter.size() > 0:
			kept.append(c)
	if kept.size() == 0:
		if not quiet:
			outputlog("No wall component borders the clicked room — nothing to do", 0)
		return []

	# 6) Building silhouette(s) = union(room, bordering wall components),
	#    holes (the rooms) discarded → filled footprint(s).
	var bcomps = [_geo._solid_to_comp({"outer": room.outer, "holes": []})]
	for c in kept:
		bcomps.append(_geo._solid_to_comp({"outer": c.outer, "holes": []}))
	bcomps = _geo._union_components(bcomps)
	if bcomps == null:
		return []

	var sils = []
	for bc in bcomps:
		# Clean the union output (dedup + darts) before using it as an exact
		# clip polygon — Clipper merges can leave collinear spikes.
		var sil = _clean_ring_basic(_geo._ensure_ccw(bc.outer))
		if sil.size() >= 3:
			sils.append(sil)
	return sils


#########################################################################################################
##
## PREVIEW
##
#########################################################################################################

# Recomputes the shadow rings for the cached silhouettes with the current
# offset and rebuilds the preview Polygon2Ds.
func _refresh_preview_geometry():
	_pv_dirty = false
	_pv_last_compute = OS.get_ticks_msec()
	var _t0 = OS.get_ticks_msec()
	_pv_rings = []
	_pv_peaked = []
	_hover_key = ""
	_hover_line = null
	if _pv_sils.size() == 0:
		return
	# Preview-only decimation: path curves oversample cave silhouettes into
	# thousands of points; ~1.2 px tolerance keeps the preview visually
	# identical while dividing every downstream cost. Apply always runs on
	# the full-precision silhouettes. Skipped in Invert (mirror-edge keys
	# must match exactly) and in Manual ridge with a selection (edge indices
	# must stay stable).
	var decimate_ok = not _invert_on() \
			and not (_ridge_manual_active() and _ridge_edges.size() > 0)
	if _offset.length() >= 0.5:
		for si in range(_pv_sils.size()):
			var sil_pv = _decimate_ring(_pv_sils[si], 1.2) if decimate_ok else _pv_sils[si]
			var rings = _extrude_inner_shadow_rings(sil_pv, _offset, si) if _invert_on() \
					else _extrude_shadow_rings(sil_pv, _offset, si)
			for ring in rings:
				if ring.size() >= 3:
					_pv_rings.append(ring)
	_last_extrude_ms = OS.get_ticks_msec() - _t0

	# (Re)build the preview node
	var level = _get_current_level()
	if level == null or level != _pv_level:
		_clear_preview()
		return
	if _pv_node == null or not is_instance_valid(_pv_node):
		_pv_node = Node2D.new()
		_pv_node.name = "BuildingShadowPreview"
		level.add_child(_pv_node)
	for child in _pv_node.get_children():
		child.queue_free()
	var col = _preview_color()
	for ring in _pv_rings:
		var poly = Polygon2D.new()
		poly.polygon = PoolVector2Array(ring)
		poly.color = col
		_pv_node.add_child(poly)
		# Dashed blue outline: reminder that the shadow is not committed yet
		var line = Line2D.new()
		line.points = PoolVector2Array(ring)
		line.width = 6.0
		line.loop = true
		line.texture = _get_dash_texture()
		line.texture_mode = Line2D.LINE_TEXTURE_TILE
		line.default_color = Color(0.353, 0.698, 1.0, 0.9)  # #5ab2ff
		_pv_node.add_child(line)
	# Manual mode: dim overlay on selected segments (kept even when a
	# segment is currently back-facing and therefore has no peak)
	if _ridge_manual_active():
		for key in _ridge_edges.keys():
			var parts = key.split(":")
			var si2 = int(parts[0])
			var ei = int(parts[1])
			if si2 < _pv_sils.size() and ei < _pv_sils[si2].size():
				var a = _pv_sils[si2][ei]
				var b = _pv_sils[si2][(ei + 1) % _pv_sils[si2].size()]
				var gl = Line2D.new()
				gl.points = PoolVector2Array([a, b])
				gl.width = 8.0
				gl.default_color = Color(0.2, 0.9, 0.3, 0.45)
				gl.z_as_relative = false
				gl.z_index = 4000
				_pv_node.add_child(gl)
	# All modes: bright overlay on every segment that actually gets a peak
	for seg in _pv_peaked:
		var pl = Line2D.new()
		pl.points = PoolVector2Array([seg[0], seg[1]])
		pl.width = 8.0
		pl.default_color = Color(0.2, 0.9, 0.3, 0.9)
		pl.z_as_relative = false
		pl.z_index = 4000
		_pv_node.add_child(pl)
	_update_preview_style()

	_set_preview_badge(_pv_rings.size() > 0)
	if _btn_apply != null and is_instance_valid(_btn_apply):
		_btn_apply.disabled = _pv_rings.size() == 0
	if _btn_cancel != null and is_instance_valid(_btn_cancel):
		_btn_cancel.disabled = false


var _dash_tex = null

# White dashes on transparency; Line2D tiles it along the outline and
# modulates it with default_color (blue).
func _get_dash_texture():
	if _dash_tex != null:
		return _dash_tex
	var img = Image.new()
	img.create(8, 1, false, Image.FORMAT_RGBA8)
	img.lock()
	for x in range(8):
		img.set_pixel(x, 0, Color(1, 1, 1, 1) if x < 4 else Color(0, 0, 0, 0))
	img.unlock()
	_dash_tex = ImageTexture.new()
	_dash_tex.create_from_image(img, Texture.FLAG_REPEAT)
	return _dash_tex


func _load_icon_texture(filename: String):
	var path = global.Root + "icons/" + filename
	var img = Image.new()
	if img.load(path) != OK:
		outputlog("WARNING: icon not found: %s" % path, 0)
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	return tex


# Small on-screen badge shown while a preview is pending.
func _set_preview_badge(visible_now: bool):
	if visible_now and (_pv_label == null or not is_instance_valid(_pv_label)):
		_pv_label = Label.new()
		_pv_label.text = "SHADOW PREVIEW"
		_pv_label.add_color_override("font_color", Color(1, 1, 1, 1))
		_pv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Red rounded rectangle behind the text
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.78, 0.08, 0.08, 0.78)
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		_pv_label.add_stylebox_override("normal", sb)
		# Larger font (1.8x) with a same-colour outline as pseudo-bold
		var f = _pv_label.get_font("font")
		if f != null and f is DynamicFont:
			var f2 = f.duplicate()
			f2.size = int(f.size * 1.8)
			f2.outline_size = 1
			f2.outline_color = Color(1, 1, 1, 1)
			_pv_label.add_font_override("font", f2)
		global.Editor.add_child(_pv_label)
		# Centered horizontally, ~10% down from the top of the screen
		_pv_label.set_anchors_and_margins_preset(Control.PRESET_CENTER_TOP)
		_pv_label.anchor_top = 0.1
		_pv_label.anchor_bottom = 0.1
		_pv_label.margin_top = 0
		_pv_label.margin_bottom = 0
	if _pv_label != null and is_instance_valid(_pv_label):
		_pv_label.visible = visible_now
	if _lbl_confirm != null and is_instance_valid(_lbl_confirm):
		_lbl_confirm.visible = visible_now


func _preview_color() -> Color:
	var opacity = (_sl_opacity.value if _sl_opacity != null else DEFAULT_OPACITY) / 100.0
	return Color(0.0, 0.0, 0.0, opacity)


# Cheap updates that don't need geometry recomputation (opacity, layer)
func _update_preview_style():
	if _pv_node == null or not is_instance_valid(_pv_node):
		return
	var layer = int(_sl_layer.value) if _sl_layer != null else DEFAULT_LAYER
	_pv_node.z_index = int(clamp(layer, -4000, 4000))
	var col = _preview_color()
	for child in _pv_node.get_children():
		if child is Polygon2D:
			child.color = col


func _clear_preview():
	_set_preview_badge(false)
	_clear_building_highlight()
	if _pv_node != null and is_instance_valid(_pv_node):
		_pv_node.queue_free()
	_pv_node = null
	_pv_sils = []
	_pv_rings = []
	_pv_level = null
	_pv_dirty = false
	if _btn_apply != null and is_instance_valid(_btn_apply):
		_btn_apply.disabled = true
	if _btn_cancel != null and is_instance_valid(_btn_cancel):
		_btn_cancel.disabled = true


func _on_apply_pressed():
	if _pv_rings.size() == 0:
		return
	if _get_current_level() != _pv_level:
		outputlog("WARNING: level changed since the preview was made — discarding it", 0)
		_clear_preview()
		return
	# Recompute the rings with the Apply-time inflation (APPLY_INFLATE px in
	# every direction) — ONLY when Blur is ON: the inflation exists to hide
	# the blurred edge under the walls, a sharp pattern must stay exact.
	var apply_inflate = 0.0
	if _btn_blur != null and is_instance_valid(_btn_blur) and _btn_blur.pressed:
		apply_inflate = APPLY_INFLATE
	_dbg_capture = SEAM_DEBUG
	_dbg_lines = []
	_apply_pass = true
	var apply_rings = []
	for si in range(_pv_sils.size()):
		var rr = _extrude_inner_shadow_rings(_pv_sils[si], _offset, si, apply_inflate) if _invert_on() \
				else _extrude_shadow_rings(_pv_sils[si], _offset, si, apply_inflate)
		for ring in rr:
			if ring.size() >= 3:
				apply_rings.append(ring)
	if apply_rings.size() == 0:
		apply_rings = _pv_rings
	if apply_rings.size() > 1:
		outputlog("WARNING: shadow split into %d rings, creating separate patterns" % apply_rings.size(), 0)
	_apply_pass = false
	_dbg_capture = false
	if SEAM_DEBUG:
		_dump_rings_debug(apply_rings)
	var created = []
	for ring in apply_rings:
		var shape = _draw_shadow_pattern(ring)
		if shape != null:
			created.append(shape)
	if _btn_blur != null and is_instance_valid(_btn_blur) and _btn_blur.pressed:
		for shape in created:
			_apply_uchideshi_blur(shape)
	outputlog("Building shadow: %d pattern(s) created" % created.size(), 0)
	_clear_preview()


func _on_cancel_pressed():
	_clear_preview()


# Moves our button right after the Unofficial Patch bucket button, whenever
# the row composition changes (the bucket may inject itself after us
# depending on mod load order).
func _ensure_button_position():
	if _button == null or not is_instance_valid(_button):
		return
	for child in _shape_hbox.get_children():
		if child != _button and child is Button \
				and str(child.hint_tooltip).begins_with("Paint Bucket"):
			var my_idx = _button.get_index()
			var bucket_idx = child.get_index()
			# move_child indices are positions in the FINAL list: when moving
			# forward, the removal shifts everything after us by -1.
			var target = bucket_idx + 1
			if my_idx < bucket_idx:
				target = bucket_idx
			if my_idx != target:
				_shape_hbox.move_child(_button, target)
			return


#########################################################################################################
##
## PENDING-PREVIEW CONFIRMATION POPUP
##
#########################################################################################################

# If an unapplied preview exists, opens the Apply/Discard popup and returns
# true (the preview is kept until the user decides). Returns false otherwise.
func _maybe_prompt_pending() -> bool:
	if _popup_pending:
		return true
	if _pv_rings.size() == 0 or _pv_node == null or not is_instance_valid(_pv_node):
		return false
	_popup_pending = true
	if _confirm == null or not is_instance_valid(_confirm):
		_open_confirm_first_time()
	else:
		_confirm.popup_centered(_confirm.rect_size)
	return true


# Builds and shows the confirmation dialog, imitating DD's own dialogs (same
# recipe as Save Reminder): WindowDialog under the editor's Windows node,
# centered labels, HSeparator, centered button row, deferred sizing from the
# content minimum size, and theme-derived button styling.
func _open_confirm_first_time():
	_confirm = WindowDialog.new()
	_confirm.window_title = "Building Shadow"

	var vbox = VBoxContainer.new()
	vbox.set("custom_constants/separation", 10)
	_confirm.add_child(vbox)

	var lbl_title = Label.new()
	lbl_title.text = "THE PREVIEWED SHADOW HAS NOT BEEN APPLIED YET"
	lbl_title.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_title)

	var lbl_sub = Label.new()
	lbl_sub.text = "(apply it now, or discard it)"
	lbl_sub.align = Label.ALIGN_CENTER
	vbox.add_child(lbl_sub)

	vbox.add_child(HSeparator.new())

	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGN_CENTER
	btn_row.set("custom_constants/separation", 40)
	var apply_btn = Button.new()
	apply_btn.text = "Apply"
	apply_btn.connect("pressed", self, "_on_confirm_apply")
	btn_row.add_child(apply_btn)
	var discard_btn = Button.new()
	discard_btn.text = "Discard"
	discard_btn.connect("pressed", self, "_on_confirm_discard")
	btn_row.add_child(discard_btn)
	vbox.add_child(btn_row)

	_confirm.connect("popup_hide", self, "_on_confirm_hidden")

	var windows = global.Editor.get_node_or_null("Windows")
	if windows != null:
		windows.add_child(_confirm)
	else:
		global.Editor.get_tree().get_root().add_child(_confirm)
	_confirm.popup_exclusive = true

	# Let Godot compute the content size, then size + center the dialog
	yield(global.Editor.get_tree(), "idle_frame")
	if _confirm == null or not is_instance_valid(_confirm):
		return
	var content_min = vbox.get_combined_minimum_size()
	var title_h = _confirm.get_constant("title_height", "WindowDialog")
	var w = content_min.x + 32
	var h = content_min.y + title_h + 20
	_confirm.rect_size = Vector2(w, h)
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.margin_left = 16
	vbox.margin_right = -16
	vbox.margin_top = 12
	vbox.margin_bottom = -8
	# The user may have decided in the meantime (unlikely, but yield...)
	if _popup_pending:
		_confirm.popup_centered(Vector2(w, h))
	# Style the buttons from the DD theme (deferred, once rendered)
	yield(global.Editor.get_tree(), "idle_frame")
	if _confirm != null and is_instance_valid(_confirm):
		for btn in [apply_btn, discard_btn]:
			_style_dd_button(btn)


# Duplicates the theme's own button stylebox and adds a subtle border, like
# DD's dialog buttons (same approach as Save Reminder).
func _style_dd_button(btn: Button):
	var existing = btn.get_stylebox("normal")
	if existing != null and existing is StyleBoxFlat:
		var style = existing.duplicate()
		style.border_color = Color(0.6, 0.6, 0.6, 0.7)
		style.set_border_width_all(1)
		style.content_margin_left = 20
		style.content_margin_right = 20
		btn.add_stylebox_override("normal", style)


func _on_confirm_apply():
	_popup_pending = false
	if _confirm != null and is_instance_valid(_confirm):
		_confirm.hide()
	_on_apply_pressed()


func _on_confirm_discard():
	# Hiding with _popup_pending still true routes through _on_confirm_hidden,
	# which discards the preview.
	if _confirm != null and is_instance_valid(_confirm):
		_confirm.hide()


# Fired on any hide (after OK too, but _popup_pending is already false then).
# Closing via Discard / Escape / X drops the preview.
func _on_confirm_hidden():
	if _popup_pending:
		_popup_pending = false
		_clear_preview()


# Level changed (or preview node died): drop everything, closing the popup
# first if it is open.
func _force_discard_pending():
	if _popup_pending and _confirm != null and is_instance_valid(_confirm):
		_popup_pending = false
		_confirm.hide()
	_popup_pending = false
	_clear_preview()


# BFS over AABB adjacency: start from solids touching seed_bb, expand through
# overlapping AABBs until fixpoint. Returns the picked solids.
func _bfs_pick_solids(solids: Array, seed_bb: Rect2) -> Array:
	var bbs = []
	for s in solids:
		bbs.append(_geo._aabb(s.outer).grow(1.0))
	var picked_flags = []
	picked_flags.resize(solids.size())
	var queue = []
	for i in range(solids.size()):
		picked_flags[i] = false
		if bbs[i].intersects(seed_bb):
			picked_flags[i] = true
			queue.append(i)
	while queue.size() > 0:
		var i = queue.pop_back()
		for j in range(solids.size()):
			if not picked_flags[j] and bbs[j].intersects(bbs[i]):
				picked_flags[j] = true
				queue.append(j)
	var picked = []
	for i in range(solids.size()):
		if picked_flags[i]:
			picked.append(solids[i])
	return picked


# Outward offset of a (possibly bridged) polygon; falls back to the input if
# the offset degenerates.
func _grow_polygon(poly: Array, amount: float) -> Array:
	return _grow_polygon_full(poly, amount).outer


# Grows a ring, keeping the holes the offset may create: when the growth
# SEALS a narrow channel (a lit pocket connected to the exterior through a
# throat narrower than 2×amount), Clipper outputs the pocket as a CW ring —
# discarding it (the old behaviour) silently FILLED the pocket with shadow.
func _grow_polygon_full(poly: Array, amount: float) -> Dictionary:
	var res = Geometry.offset_polygon_2d(PoolVector2Array(poly), amount, Geometry.JOIN_MITER)
	var best = null
	var best_area = 0.0
	var grow_holes = []
	if res != null:
		for r in res:
			if r.size() < 3:
				continue
			if Geometry.is_polygon_clockwise(r):
				var h = _geo._ensure_ccw(_geo._to_array(r))
				if _geo._polygon_area(h) > 1.0:
					grow_holes.append(h)
			else:
				var a = abs(_geo._polygon_area(_geo._to_array(r)))
				if a > best_area:
					best_area = a
					best = _geo._to_array(r)
	if best == null:
		return {"outer": poly, "holes": []}
	return {"outer": best, "holes": grow_holes}


# Minkowski sweep of the silhouette along `offset`, GROWN by 2 px so the
# silhouette becomes strictly interior, then minus the silhouette → a true
# annulus: ALWAYS one connected ring with the silhouette as a hole, bridged by
# the proven earcut hole-elimination (no naive sibling bridging, which DD's
# triangulator rejected). The 2 px on the lit side hide under the wall art.
const SWEEP_GROW = 2.0

func _extrude_shadow_rings(sil: Array, offset: Vector2, sil_idx: int = -1, inflate: float = 0.0) -> Array:
	# Sweep = union(sil, band per contiguous run of sun-facing edges).
	# Correctness: any swept point leaves the silhouette through a FRONT
	# edge, so front-run bands + sil cover the whole Minkowski sweep — the
	# translated copy and the per-edge quads of the old construction are
	# redundant. A 200-segment curved facade thus contributes ONE union
	# piece instead of 200, which is what made setting drags lag.
	var pieces = [_geo._solid_to_comp({"outer": sil, "holes": []})]
	# The translated copy is REQUIRED as glue: Godot's merge only reliably
	# fuses pieces with AREA overlap — bands touching each other only along
	# their cut edges stayed separate (disconnected patterns, then visible
	# seams at every corner once the runs were split there).
	var moved = []
	for p in sil:
		moved.append(p + offset)
	pieces.append(_geo._solid_to_comp({"outer": _geo._ensure_ccw(moved), "holes": []}))
	var ridge_on = _btn_ridge != null and is_instance_valid(_btn_ridge) and _btn_ridge.pressed
	var ridge_h = _sl_ridge.value if (_sl_ridge != null and is_instance_valid(_sl_ridge)) else DEFAULT_RIDGE_HEIGHT
	var ridge_mode = _opt_ridge_mode.selected if (_opt_ridge_mode != null and is_instance_valid(_opt_ridge_mode)) else 0
	var ccw_sil = not Geometry.is_polygon_clockwise(PoolVector2Array(sil))
	var n = sil.size()
	var facing = []
	for i in range(n):
		var e = sil[(i + 1) % n] - sil[i]
		if e.length() < 0.001:
			facing.append(false)
			continue
		var outward = Vector2(e.y, -e.x) if ccw_sil else Vector2(-e.y, e.x)
		# Front OR near-parallel edges belong to a run (parallel edges kept
		# inside bands close the sun-aligned slit of the old per-edge skip)
		facing.append(outward.dot(offset) > -0.05 * offset.length())
	for run in _facing_runs(facing):
		for sub in _split_run_by_turning(sil, run[0], run[1]):
			_append_run_band(pieces, sil, sub[0], sub[1], offset)
	# Ridge peaks stay per eligible edge (few of them by construction)
	if ridge_on and ridge_h > 1.01:
		for i in range(n):
			var a = sil[i]
			var b = sil[(i + 1) % n]
			if not _edge_wants_ridge(sil_idx, i, a, b, ridge_mode):
				continue
			# Only sun-facing edges get the peak: a back-facing peak could
			# punch through the building and stick out on the lit side.
			var edge = (b - a).normalized()
			var outward2 = Vector2(edge.y, -edge.x) if ccw_sil else Vector2(-edge.y, edge.x)
			if outward2.dot(offset) <= 0.05 * offset.length():
				continue
			var m = (a + b) * 0.5
			var h_eff = ridge_h
			if _btn_ridge_rand != null and is_instance_valid(_btn_ridge_rand) and _btn_ridge_rand.pressed:
				var r = abs(fmod(sin(m.x * 12.9898 + m.y * 78.233 + _ridge_rand_seed) * 43758.5453, 1.0))
				h_eff = 1.0 + (ridge_h - 1.0) * (0.5 + 1.0 * r)
			var piece = _geo._ensure_ccw([a, b, b + offset, m + offset * h_eff, a + offset])
			if piece.size() >= 3 and _geo._polygon_area(piece) > 1.0:
				pieces.append(_geo._solid_to_comp({"outer": piece, "holes": []}))
				if sil_idx >= 0:
					_pv_peaked.append([a, b])
	var swept = _geo._union_components(pieces)
	if swept == null or swept.size() == 0:
		return []
	if swept.size() > 1:
		outputlog("sweep union yielded %d components (bands may have gaps)" % swept.size(), 1)
	if _dbg_capture:
		_dbg_ring("SIL", sil_idx, sil)
		for sw_i in range(swept.size()):
			_dbg_ring("SW_OUTER_%d" % sw_i, sil_idx, swept[sw_i].outer)
			for h_i in range(swept[sw_i].holes.size()):
				_dbg_ring("SW_HOLE_%d_%d" % [sw_i, h_i], sil_idx, swept[sw_i].holes[h_i])

	var finals = []
	for sw in swept:
		# Grow the swept outer so the silhouette is strictly inside it.
		# Pockets sealed by the growth (narrow throats) are kept as holes.
		var g = _grow_polygon_full(sw.outer, SWEEP_GROW)
		var grown = g.outer
		# Subtract the silhouette: expected result = one CCW ring with the
		# silhouette as a CW hole (annulus). This thin ring is the connector —
		# it stays at SWEEP_GROW px and is NEVER inflated.
		var clipped = Geometry.clip_polygons_2d(PoolVector2Array(grown), PoolVector2Array(sil))
		if clipped == null:
			continue
		var outers = []
		var holes = []
		for r in clipped:
			if r.size() < 3:
				continue
			if Geometry.is_polygon_clockwise(r):
				holes.append(_geo._to_array(r))
			else:
				outers.append(_geo._to_array(r))
		# Inflation applies to the REAL shadow only: the core (ungrown sweep
		# minus silhouette), inflated, then unioned with the thin annulus so
		# the 2 px junction lines keep their size.
		if inflate > 0.0:
			var core_big = []
			var inflate_holes = []
			var core = Geometry.clip_polygons_2d(PoolVector2Array(sw.outer), PoolVector2Array(sil))
			if core != null:
				for r in core:
					if r.size() >= 3 and not Geometry.is_polygon_clockwise(r):
						var bigf = _grow_polygon_full(_geo._to_array(r), inflate)
						if bigf.outer.size() >= 3:
							core_big.append(bigf.outer)
							outers.append(bigf.outer)
						for bh in bigf.holes:
							inflate_holes.append(bh)
			var comps2 = []
			for o in outers:
				comps2.append(_geo._solid_to_comp({"outer": o, "holes": []}))
			comps2 = _geo._union_components(comps2)
			outers = []
			if comps2 != null:
				for c2 in comps2:
					outers.append(c2.outer)
					for h2 in c2.holes:
						holes.append(h2)
			# CRITICAL: the silhouette hole (from the annulus clip) would
			# otherwise carve the inflated core back to the wall line — the
			# very 25 px we want UNDER the walls. Trim each hole by the
			# inflated core so it only survives where the core does not
			# cover (the lit side, where the 2 px junction ring remains).
			if core_big.size() > 0:
				var new_holes = []
				for h in holes:
					var frags = [PoolVector2Array(_geo._ensure_ccw(h))]
					for big in core_big:
						var nxt = []
						for f in frags:
							var res = Geometry.clip_polygons_2d(f, PoolVector2Array(big))
							if res != null:
								for rr in res:
									if rr.size() >= 3 and not Geometry.is_polygon_clockwise(rr):
										nxt.append(rr)
						frags = nxt
					for f in frags:
						new_holes.append(_geo._to_array(f))
				holes = new_holes
			# Pockets sealed by the inflation itself must NOT be trimmed by
			# the core (the core covers them) — add them after the trim
			for bh2 in inflate_holes:
				holes.append(bh2)
		# Enclosure holes of the sweep itself (concave shapes closing on
		# themselves) also punch through the shadow — as do pockets sealed
		# by the 2 px growth above
		for h in sw.holes + g.holes:
			var hc = Geometry.clip_polygons_2d(PoolVector2Array(h), PoolVector2Array(sil))
			if hc != null:
				for r in hc:
					if r.size() >= 3 and not Geometry.is_polygon_clockwise(r):
						var hh = _geo._to_array(r)
						if inflate > 0.0:
							hh = _shrink_polygon(hh, inflate)
						if hh.size() >= 3:
							holes.append(hh)
		if _dbg_capture:
			for o_i in range(outers.size()):
				_dbg_ring("CLIP_OUTER_%d" % o_i, sil_idx, outers[o_i])
			for h_i2 in range(holes.size()):
				_dbg_ring("CLIP_HOLE_%d" % h_i2, sil_idx, holes[h_i2])
		# Attach holes to their containing outer and bridge them (earcut)
		var parts = []
		for o in outers:
			for lobe in _ring_lobes_classified(o, holes):
				parts.append({"outer": lobe, "holes": []})
		for h in holes:
			for hl in _ring_to_lobes(h):
				_attach_hole_to_part(hl, parts)
		if _dbg_capture:
			for p_i in range(parts.size()):
				_dbg_ring("PART_OUTER_%d" % p_i, sil_idx, parts[p_i].outer)
				for ph_i in range(parts[p_i].holes.size()):
					_dbg_ring("PART_HOLE_%d_%d" % [p_i, ph_i], sil_idx, parts[p_i].holes[ph_i])
		for part in parts:
			var poly = part.outer
			if part.holes.size() > 0:
				poly = _bridge_part(part.outer, part.holes)
			if poly.size() >= 3 and _geo._polygon_area(poly) < MIN_RING_AREA:
				pass  # cleanup debris (e.g. a 30 px sliver) — not worth a pattern
			elif poly.size() >= 3 and _is_triangulable(poly):
				finals.append(poly)
			elif poly.size() >= 3:
				outputlog("WARNING: skipping a non-triangulable shadow part", 0)
	return finals


func _is_triangulable(poly: Array) -> bool:
	if poly.size() < 3:
		return false
	return Geometry.triangulate_polygon(PoolVector2Array(poly)).size() >= 3


# Inward offset of a ring; returns the largest resulting piece (or []).
func _shrink_polygon(poly: Array, amount: float) -> Array:
	var res = Geometry.offset_polygon_2d(PoolVector2Array(poly), -amount, Geometry.JOIN_MITER)
	var best = []
	var best_area = 0.0
	if res != null:
		for r in res:
			if r.size() >= 3 and not Geometry.is_polygon_clockwise(r):
				var a = _geo._polygon_area(_geo._to_array(r))
				if a > best_area:
					best_area = a
					best = _geo._to_array(r)
	return best


#########################################################################################################
##
## PATTERN CREATION
##
#########################################################################################################

# Cache of generated shadow textures, keyed by opacity percent (int)
var _shadow_tex_cache = {}


# Returns a small solid-black tiling texture with the opacity BAKED INTO the
# pixels. Rationale: third-party pattern shaders (e.g. Colour and Modify
# Things) sample the pattern texture directly and ignore the Polygon2D colour,
# so both the blackness and the transparency must live in the texture itself.
# The PNG is written into the mod's textures/ folder and the texture's
# resource path is taken over, so DD's native save (WriteTexture → path) and
# load (ReadTexture → LoadPNG) round-trip it transparently.
# Shadow textures are PURE MEMORY (8×8 black, opacity baked in the pixels for
# the uchideshi blur shader). The save stores the inert "embedded://" path;
# at map open, _restore_embedded_textures() rebuilds and reassigns them from
# the ModMapData record — no file on disk, maps are self-contained/portable.
# (Legacy maps with the old absolute-path PNGs keep loading from the files.)
func _get_shadow_texture(opacity_pct: int):
	opacity_pct = int(clamp(opacity_pct, 0, 100))
	if _shadow_tex_cache.has(opacity_pct):
		return _shadow_tex_cache[opacity_pct]
	# OPAQUE black: the opacity lives in the pattern's native colour now
	# (baking it here too would render alpha²). One texture fits all.
	var img = Image.new()
	img.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	var tex = ImageTexture.new()
	# FLAG_REPEAT | FLAG_FILTER = 6, same flags DD's ReadTexture uses
	tex.create_from_image(img, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
	# A non-empty resource_path is REQUIRED (empty crashes DD's Infobar) and
	# this is what WriteTexture stores in the save.
	tex.take_over_path("embedded://bs_shadow_a%03d" % opacity_pct)
	_shadow_tex_cache[opacity_pct] = tex
	return tex


# Creates the shadow PatternShape by temporarily swapping the tool's
# Texture/Color/ActiveLayer around DrawPolygon. This way AddPolygon does all
# the native work (triangulation check, layer placement, SetOptions, node id,
# PatternShapeRecord → native undo) with OUR settings, then the tool state is
# restored.
func _draw_shadow_pattern(pts: Array):
	if pts.size() < 3:
		return null
	var level = _get_current_level()
	if level == null:
		return null
	var ps_node = level.get("PatternShapes")
	if ps_node == null:
		return null
	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return null

	var opacity_pct = int(_sl_opacity.value) if _sl_opacity != null else int(DEFAULT_OPACITY)
	var tex = _get_shadow_texture(opacity_pct)
	var layer = int(_sl_layer.value) if _sl_layer != null else DEFAULT_LAYER

	var saved_tex = pat_tool.get("Texture")
	var saved_color = pat_tool.get("Color")
	var saved_layer = pat_tool.get("ActiveLayer")

	pat_tool.set("Texture", tex)
	# Black at the chosen opacity, as the pattern's NATIVE DD colour: it is
	# persisted by DD itself, so a map opened WITHOUT the mod still renders
	# the shadow correctly (untextured pattern = white base × colour), just
	# without the blur.
	pat_tool.set("Color", Color(0.0, 0.0, 0.0, float(clamp(_sl_opacity.value, 0, 100)) / 100.0))
	pat_tool.set("ActiveLayer", layer)

	var node_id = global.World.nextNodeID
	ps_node.DrawPolygon(pts, false)
	var ok = global.World.HasNodeID(node_id)

	# Restore order matters: set_Texture can throw inside DD (Infobar asset
	# lookup) — if that aborts the sequence, a stranded ActiveLayer would
	# poison the Paint Bucket's layer filter (walls below it stop being
	# barriers). Restore the critical state FIRST, Texture LAST.
	pat_tool.set("ActiveLayer", saved_layer)
	pat_tool.set("Color", saved_color)
	pat_tool.set("Texture", saved_tex)

	if not ok:
		outputlog("WARNING: DrawPolygon did not create a shape (bad polygon?)", 0)
		return null
	# Self-contained persistence: DD serialises ModMapData inside the map
	# file; at map open, _restore_embedded_textures() rebuilds the in-memory
	# texture of every recorded pattern (node ids are saved and reassigned
	# identically by DD, and survive Edit Points).
	var md = global.ModMapData
	if md is Dictionary:
		if not md.has(BS_TEX_KEY):
			md[BS_TEX_KEY] = {}
		md[BS_TEX_KEY][str(node_id)] = int(clamp(_sl_opacity.value, 0, 100))
	var new_shape = global.World.GetNodeByID(node_id)
	# Respect the global Shadows toggle: a pattern created while shadows are
	# hidden is born hidden, consistent with every other shadow
	if new_shape != null and md is Dictionary and md.get(SHADOW_TOGGLE_KEY, false):
		new_shape.visible = false
	return new_shape


func _get_current_level():
	if not _world_ready():
		return null
	return global.get("World").call("GetCurrentLevel")


#########################################################################################################
##
## RING CLEANUP (mirrors the Unofficial Patch bucket helpers)
##
#########################################################################################################

# Deduplicates consecutive vertices and removes zero-width "darts", artifacts
# of Clipper unions of segment quads. Does not alter the useful shape.
func _clean_ring_basic(poly: Array) -> Array:
	var pts = []
	for p in poly:
		if pts.size() == 0 or pts[pts.size() - 1].distance_to(p) > 0.03:
			pts.append(p)
	while pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.03:
		pts.pop_back()
	var changed = true
	while changed and pts.size() >= 3:
		changed = false
		var n = pts.size()
		for i in range(n):
			var b = pts[i]
			var ab = (pts[(i - 1 + n) % n] - b)
			var cb = (pts[(i + 1) % n] - b)
			if ab.length() < 0.03 or cb.length() < 0.03:
				pts.remove(i)
				changed = true
				break
			if ab.normalized().dot(cb.normalized()) > 0.999:
				pts.remove(i)
				changed = true
				break
	return pts


# Splits a ring passing (almost) twice through the same vertex — a pinch —
# into strictly simple sub-rings.
func _split_pinched_ring(pts: Array) -> Array:
	var n = pts.size()
	if n < 3: return []
	for i in range(n):
		for j in range(i + 2, n):
			if i == 0 and j == n - 1: continue
			if pts[i].distance_to(pts[j]) <= 0.03:
				var r1 = []
				for k in range(i, j): r1.append(pts[k])
				var r2 = []
				for k in range(j, n): r2.append(pts[k])
				for k in range(0, i): r2.append(pts[k])
				return _split_pinched_ring(r1) + _split_pinched_ring(r2)
	return [pts]


# Cleans a ring and makes it triangulable; decomposes pinches into lobes if
# needed. Returns the list of usable rings.
func _ring_to_lobes(poly: Array) -> Array:
	var c = _clean_ring_basic(poly)
	if c.size() < 3: return []
	if Geometry.triangulate_polygon(PoolVector2Array(c)).size() >= 3:
		return [c]
	var lobes = []
	for r in _split_pinched_ring(c):
		var rc = _clean_ring_basic(r)
		if rc.size() >= 3 and abs(_geo._polygon_area(rc)) > 1.0 \
				and Geometry.triangulate_polygon(PoolVector2Array(rc)).size() >= 3:
			lobes.append(rc)
	if lobes.size() == 0:
		lobes = [c]
	return lobes


func _ring_centroid(ring: Array) -> Vector2:
	var c = Vector2.ZERO
	for p in ring:
		c += p
	return c / max(1, ring.size())


#########################################################################################################
##
## OFFSET DIAL (same system as the other shadow tools)
##
#########################################################################################################
# The handle points at the SUN; the shadow offset is the opposite vector.
# Quadratic magnitude mapping: precise near the center, fast at the edges.

func _create_dial(dial_size: int) -> Control:
	var dial = Control.new()
	dial.name = "OffsetDial"
	dial.rect_min_size = Vector2(dial_size, dial_size)
	dial.rect_size = Vector2(dial_size, dial_size)

	# Background circle (dark)
	var bg_sprite = TextureRect.new()
	bg_sprite.texture = _make_circle_texture(dial_size, Color(0.12, 0.12, 0.12, 1.0))
	bg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg_sprite)

	# Ring guides at 25%, 50%, 75%
	for ring_frac in [0.25, 0.5, 0.75]:
		var ring_size = int(dial_size * ring_frac)
		var ring_rect = TextureRect.new()
		ring_rect.texture = _make_ring_texture(ring_size, Color(0.22, 0.22, 0.22, 1.0))
		ring_rect.rect_position = Vector2((dial_size - ring_size) / 2.0, (dial_size - ring_size) / 2.0)
		ring_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring_rect)

	# Diagonal guide lines (dotted)
	for diag_angle in [45.0, 135.0, 225.0, 315.0]:
		var diag_rad = deg2rad(diag_angle)
		var dx = cos(diag_rad)
		var dy = sin(diag_rad)
		var line_len = dial_size / 2.0 - 2.0
		for s in range(4, int(line_len), 3):
			var dot_line = ColorRect.new()
			dot_line.color = Color(0.20, 0.20, 0.20, 0.5)
			dot_line.rect_min_size = Vector2(1, 1)
			dot_line.rect_position = Vector2(dial_size / 2.0 + dx * s, dial_size / 2.0 + dy * s)
			dot_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_line)

	# Crosshairs
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

	# Center dot
	var center_dot = ColorRect.new()
	center_dot.color = Color(0.4, 0.4, 0.4, 1.0)
	center_dot.rect_min_size = Vector2(3, 3)
	center_dot.rect_position = Vector2(dial_size / 2.0 - 1.5, dial_size / 2.0 - 1.5)
	center_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(center_dot)

	# Handle dot (the draggable point)
	var dot = ColorRect.new()
	dot.name = "Handle"
	dot.color = Color(0.95, 0.6, 0.1, 1.0)
	dot.rect_min_size = Vector2(10, 10)
	dot.rect_position = Vector2(dial_size / 2.0 - 5, dial_size / 2.0 - 5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(dot)

	# Diagonal snap buttons at corners (0°=east, 90°=south)
	var snap_btn_size = 12
	var snap_inactive_color = Color(0.3, 0.3, 0.3, 0.8)
	var snap_active_color = Color(0.353, 0.698, 1.0, 1.0)  # #5ab2ff
	var snap_positions = {
		"snap_315": Vector2(dial_size - 8, -4),               # top-right = NE
		"snap_45":  Vector2(dial_size - 8, dial_size - 8),    # bottom-right = SE
		"snap_135": Vector2(-4, dial_size - 8),               # bottom-left = SW
		"snap_225": Vector2(-4, -4)                           # top-left = NW
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
		_snap_buttons[key] = snap_btn

	dial.set_meta("dial_size", dial_size)
	dial.set_meta("dragging", false)
	dial.set_meta("snap_angle", -1.0)  # -1 = no snap
	dial.rect_clip_content = false
	dial.connect("gui_input", self, "_on_dial_input", [dial])
	_dial = dial
	_dial_dot = dot
	return dial


func _make_circle_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var center = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			if Vector2(x, y).distance_to(center) <= radius:
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
			if abs(Vector2(x, y).distance_to(center) - radius) < 1.0:
				img.set_pixel(x, y, color)
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


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
	var max_offset = _sl_range.value if _sl_range != null else DEFAULT_RANGE
	var center = Vector2(dial_size / 2.0, dial_size / 2.0)
	var radius = dial_size / 2.0

	var delta = pos - center
	var dist_from_center = delta.length()
	if dist_from_center > radius:
		delta = delta.normalized() * radius
		dist_from_center = radius

	# Non-linear: fraction = (dist/radius)^2 — precise near center
	var frac = dist_from_center / radius
	var nonlinear_frac = frac * frac
	var direction = delta.normalized() if dist_from_center > 0.5 else Vector2.ZERO

	# Apply diagonal snap if active
	var snap_angle = dial.get_meta("snap_angle") as float
	if snap_angle >= 0.0:
		var snap_rad = deg2rad(snap_angle)
		var snap_dir = Vector2(cos(snap_rad), sin(snap_rad))
		var projection = delta.dot(snap_dir)
		if projection <= 0.0:
			_set_offset(Vector2.ZERO)
			return
		var projected_dist = min(projection, radius)
		frac = projected_dist / radius
		nonlinear_frac = frac * frac
		direction = snap_dir

	# Handle = sun position → shadow offset is opposite
	_set_offset(Vector2(round(-direction.x * nonlinear_frac * max_offset), round(-direction.y * nonlinear_frac * max_offset)))


func _on_snap_toggled(pressed: bool, key: String, angle: float):
	if _dial == null:
		return
	if pressed:
		# Exclusive toggles
		for other_key in _snap_buttons.keys():
			if other_key != key and _snap_buttons[other_key].pressed:
				_snap_buttons[other_key].pressed = false
		_dial.set_meta("snap_angle", angle)
		# Re-align the current offset onto the snapped axis, keeping magnitude
		var mag = _offset.length()
		if mag > 0.5:
			var snap_rad = deg2rad(angle)
			_set_offset(Vector2(-cos(snap_rad), -sin(snap_rad)) * mag)
	else:
		if _dial.get_meta("snap_angle") == angle:
			_dial.set_meta("snap_angle", -1.0)


# Central setter: updates the handle position, the readout label, and marks
# the preview dirty (throttled recompute happens in on_update).
func _set_offset(v: Vector2):
	_offset = v
	_update_dial_handle()
	_pv_dirty = true


func _update_dial_handle():
	if _dial == null or _dial_dot == null:
		return
	var dial_size = _dial.get_meta("dial_size") as float
	var max_offset = _sl_range.value if _sl_range != null else DEFAULT_RANGE
	var radius = dial_size / 2.0
	var mag = _offset.length()
	var frac = clamp(mag / max(max_offset, 1.0), 0.0, 1.0)
	# Inverse of the quadratic mapping
	var lin = sqrt(frac)
	var dir = Vector2.ZERO
	if mag > 0.01:
		dir = -_offset.normalized()  # back to sun-side handle position
	var handle_pos = Vector2(radius, radius) + dir * lin * radius
	_dial_dot.rect_position = handle_pos - Vector2(5, 5)
	# Mirror into the spinboxes without re-triggering _on_spin_changed
	if _sp_angle != null and is_instance_valid(_sp_angle) \
			and _sp_dist != null and is_instance_valid(_sp_dist):
		var ang = rad2deg(_offset.angle())
		if ang < 0.0:
			ang += 360.0
		_ui_syncing = true
		if mag >= 0.5:
			_sp_angle.value = int(round(ang))
		_sp_dist.value = int(round(mag))
		_ui_syncing = false


#########################################################################################################
##
## MISC UI HELPERS
##
#########################################################################################################

# 1 px white outline around a button, for all states.
func _style_outlined_button(btn: Button):
	var states = {
		"normal":   [Color(0.17, 0.17, 0.17, 1.0), Color(1, 1, 1, 1)],
		"hover":    [Color(0.23, 0.23, 0.23, 1.0), Color(1, 1, 1, 1)],
		"pressed":  [Color(0.12, 0.12, 0.12, 1.0), Color(1, 1, 1, 1)],
		"disabled": [Color(0.15, 0.15, 0.15, 1.0), Color(0.55, 0.55, 0.55, 1.0)]
	}
	for state in states.keys():
		var sb = StyleBoxFlat.new()
		sb.bg_color = states[state][0]
		sb.border_color = states[state][1]
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		btn.add_stylebox_override(state, sb)


# True when the position is over the editor HUD rather than the map canvas.
# Real hit test: any visible Control with mouse_filter = STOP under the cursor
# counts as HUD (tool/subtool icons, top menus, popups, floatbar, hint bar,
# side panels...) EXCEPT the canvas input surface. DD routes world clicks
# through WorldUI (and/or a ViewportContainer), Controls that cover the whole
# canvas with STOP — those, their subtree, and their ancestor chain must never
# match, otherwise every canvas click is misread as HUD. Near-fullscreen
# containers are also excluded, and world (Node2D / Viewport) subtrees are
# pruned for performance.
var _last_hit_desc := ""

func _is_over_gui(pos: Vector2) -> bool:
	if _confirm != null and is_instance_valid(_confirm) and _confirm.visible:
		return true
	# Any visible popup anywhere (dialogs, menus, colour pickers...) makes
	# every click HUD: _input runs BEFORE the GUI's modal handling, so the
	# rect-based hit test alone cannot protect popups.
	if _any_popup_open():
		_last_hit_desc = "open popup"
		return true
	_last_hit_desc = ""
	var wui = global.get("WorldUI")
	var excl = {}
	if wui != null and wui is Node:
		# Ancestor chain: excluded from matching (but still recursed, since
		# HUD siblings live under the same ancestors)
		var n = wui
		while n != null:
			excl[n.get_instance_id()] = true
			n = n.get_parent()
	var root = global.Editor.get_tree().get_root()
	var vp_size = root.size
	var max_area = vp_size.x * vp_size.y * 0.8
	return _hit_test_controls(root, pos, max_area, excl, wui, false)


func _any_popup_open() -> bool:
	return _scan_for_popup(global.Editor.get_tree().get_root())


func _scan_for_popup(node) -> bool:
	for child in node.get_children():
		if child is Viewport or child is Node2D:
			continue
		if child is Popup and child.visible:
			return true
		if _scan_for_popup(child):
			return true
	return false


func _hit_test_controls(node, pos: Vector2, max_area: float, excl: Dictionary, canvas_root, under_canvas: bool) -> bool:
	for child in node.get_children():
		if child is Viewport:
			continue
		if child is ViewportContainer:
			# Canvas host: consumes clicks only to forward them to the world
			continue
		# The canvas subtree (WorldUI and everything under it) never matches
		var child_under = under_canvas or child == canvas_root
		var child_excluded = child_under or excl.has(child.get_instance_id())
		# Split containers are pure layout chrome: their STOP filter only
		# exists for the drag grabber, yet their rect spans the canvas area
		# (confirmed culprit: "HSplit"). Recurse into them, never match them.
		if child is SplitContainer:
			child_excluded = true
		# Base-class Controls are structural hosts, not interactive HUD
		# (confirmed culprit: "Content", the canvas host). Real HUD elements
		# are specialised classes (Button, Panel, Popup, sliders, ...).
		if child.get_class() == "Control":
			child_excluded = true
		if child is Control:
			if not child.visible:
				continue
			if not child_excluded and child.mouse_filter == Control.MOUSE_FILTER_STOP:
				var r = child.get_global_rect()
				if r.has_point(pos):
					var area = r.size.x * r.size.y
					if area > 4.0 and area < max_area:
						_last_hit_desc = "%s (%s) rect=%s filter=STOP" % [str(child.name), child.get_class(), str(r)]
						return true
			if _hit_test_controls(child, pos, max_area, excl, canvas_root, child_under):
				return true
		elif child is Node2D:
			# World content — no HUD in there, skip the whole subtree
			continue
		else:
			# Plain Nodes / CanvasLayers may hold HUD controls
			if _hit_test_controls(child, pos, max_area, excl, canvas_root, child_under):
				return true
	return false


# Barrier checkboxes: recompute the pending preview with the new barrier set,
# reusing the last click position.
func _on_barrier_toggled(_pressed):
	_reset_building_highlight_cache()
	if _cb_walls == null or _cb_paths == null:
		return
	if not _cb_walls.pressed and not _cb_paths.pressed:
		outputlog("At least one barrier type should be enabled (Walls / Paths)", 0)
		return
	if _pv_sils.size() > 0 and _has_last_click and not _busy:
		_do_pick_building(_last_click_world)


# Hides everything in the pattern tool panel below the Apply/Cancel box while
# the shadow mode is active (vanilla controls and other mods' rows alike), and
# remembers exactly which items were visible to restore them afterwards.
func _hide_panel_extras():
	_restore_panel_extras()
	if _align == null or not is_instance_valid(_align):
		return
	if _opts_margin == null or not is_instance_valid(_opts_margin):
		return
	var start = _opts_margin.get_index()
	var ep = null
	var pat_tool = global.Editor.Tools.get("PatternShapeTool")
	if pat_tool != null:
		ep = pat_tool.get("EditPoints")
	for child in _align.get_children():
		if child == _shape_hbox or child == _opts_margin:
			continue
		# Keep the native Edit Points mode reachable from the shadow panel
		if ep != null and (child == ep or (child is Node and child.is_a_parent_of(ep))):
			continue
		if child.get_index() > start and child is CanvasItem and child.visible:
			child.visible = false
			_hidden_panel_items.append(child)


func _restore_panel_extras():
	for item in _hidden_panel_items:
		if is_instance_valid(item):
			item.visible = true
	_hidden_panel_items = []


#########################################################################################################
##
## UCHIDESHI (COLOUR AND MODIFY THINGS) INTEGRATION
##
#########################################################################################################

# Finds the EdgeBlurPatterns instance of uchideshi's mod by introspecting the
# signal connections of the controls it injected into the pattern tool panel:
# his sliders/buttons are connected to his script instance, which exposes
# set_edge_blur_on_pattern(). No cross-mod registry exists, hence this route.
func _detect_uchideshi():
	var tool_panel = global.Editor.Toolset.GetToolPanel("PatternShapeTool")
	if tool_panel == null:
		return
	_uchideshi = _scan_for_blur_target(tool_panel, 0)
	if _uchideshi != null:
		outputlog("Colour and Modify Things detected — Blur option available", 0)


func _scan_for_blur_target(node, depth: int):
	if depth > 12:
		return null
	for child in node.get_children():
		if child is Control:
			for sig in ["value_changed", "toggled", "pressed"]:
				if not child.has_signal(sig):
					continue
				for conn in child.get_signal_connection_list(sig):
					var target = conn.get("target")
					if target != null and target is Object \
							and target.has_method("set_edge_blur_on_pattern"):
						return target
		var found = _scan_for_blur_target(child, depth + 1)
		if found != null:
			return found
	return null


# Applies the fixed edge blur (smoothness 0, blur range 0.1) to a freshly
# created shadow pattern through uchideshi's own apply path, so his shader,
# persistence and undo data all stay coherent.
func _apply_uchideshi_blur(shape):
	if _uchideshi == null or shape == null or not is_instance_valid(shape):
		return
	var config = {
		"has_edge_blur": true,
		"type": "pattern_shapes",
		"blur_range": 0.1,
		"smoothness": 0.0,
		# The blur is tinted through uchideshi's own colour system (which he
		# persists in the map himself): white blur mask × base_color black
		# at our opacity — the shadow blur even survives without SoftShadows.
		"use_texture": false,
		"colour": Color(0.0, 0.0, 0.0, 1.0).to_html(),
		"opacity": float(clamp(_sl_opacity.value, 0, 100)) / 100.0,
		"reverse_alpha": false,
		"shadow_direction": [0, 0]
	}
	_uchideshi.set_edge_blur_on_pattern(shape, config)


func _on_ridge_toggled(_pressed):
	_pv_dirty = true
	_update_ridge_settings_visibility()


# Ridge settings (mode, height, random) are only shown while Ridge is ON
func _update_ridge_settings_visibility():
	var show = _btn_ridge != null and is_instance_valid(_btn_ridge) and _btn_ridge.pressed
	for row in [_ridge_mode_row, _ridge_rand_row]:
		if row != null and is_instance_valid(row):
			row.visible = show
	if _sl_ridge != null and is_instance_valid(_sl_ridge):
		var srow = _sl_ridge.get_parent()
		if srow != null and is_instance_valid(srow):
			srow.visible = show


#########################################################################################################
##
## RIDGE MODES
##
#########################################################################################################

func _on_ridge_mode_selected(_index):
	_pv_dirty = true


func _ridge_manual_active() -> bool:
	return _btn_ridge != null and is_instance_valid(_btn_ridge) and _btn_ridge.pressed \
			and _opt_ridge_mode != null and is_instance_valid(_opt_ridge_mode) \
			and _opt_ridge_mode.selected == 3


# Decides whether the edge (a, b) of silhouette sil_idx receives a roof peak,
# according to the current Ridge Mode. Modes 1/2 filter by axis; mode 3 uses
# the manually selected set (no minimum length there — an explicit click wins).
func _edge_wants_ridge(sil_idx: int, edge_idx: int, a: Vector2, b: Vector2, mode: int) -> bool:
	if mode == 3:
		return _ridge_edges.has("%d:%d" % [sil_idx, edge_idx])
	if a.distance_to(b) < RIDGE_MIN_EDGE:
		return false
	if mode == 1:
		return abs(b.x - a.x) >= abs(b.y - a.y)
	if mode == 2:
		return abs(b.y - a.y) > abs(b.x - a.x)
	return true


# Returns the "sil:edge" key of the silhouette segment closest to the click,
# within a zoom-scaled tolerance, or "" if none is close enough. The
# tolerance is 14 SCREEN pixels, converted to world units via the canvas
# transform (world→screen scale), so it feels identical at every zoom level.
func _find_clicked_segment(pos: Vector2) -> String:
	var scale = 1.0
	var world_ui = _get_world_ui()
	if world_ui != null:
		var xform = world_ui.get_viewport().get_canvas_transform()
		scale = xform.x.length()
	var tol = 14.0 / max(scale, 0.001)
	var best_key = ""
	var best_d = tol
	for si in range(_pv_sils.size()):
		var sil = _pv_sils[si]
		var n = sil.size()
		for i in range(n):
			var a = sil[i]
			var b = sil[(i + 1) % n]
			var closest = Geometry.get_closest_point_to_segment_2d(pos, a, b)
			var d = pos.distance_to(closest)
			if d < best_d:
				best_d = d
				best_key = "%d:%d" % [si, i]
	return best_key


# Shows a pale highlight on the silhouette segment under the mouse cursor in
# Manual ridge mode, so the user knows a click will toggle THAT segment (and
# that a click elsewhere will do nothing).
func _update_hover_highlight():
	var world_ui = _get_world_ui()
	if world_ui == null:
		return
	# Same coordinate path as the (proven) click handler: viewport mouse
	# position through the inverse canvas transform. WorldUI.MousePosition is
	# used when available, viewport fallback otherwise.
	var mouse = world_ui.get("MousePosition")
	if not (mouse is Vector2):
		var vp = world_ui.get_viewport()
		mouse = vp.get_canvas_transform().affine_inverse().xform(vp.get_mouse_position())
	var key = _find_clicked_segment(mouse)
	if key == _hover_key and _hover_line != null and is_instance_valid(_hover_line):
		_hover_line.visible = key != ""
		return
	_hover_key = key
	if _hover_line == null or not is_instance_valid(_hover_line):
		_hover_line = Line2D.new()
		_hover_line.width = 12.0
		_hover_line.default_color = Color(0.6, 1.0, 0.7, 0.5)
		_hover_line.z_as_relative = false
		_hover_line.z_index = 4000
		_pv_node.add_child(_hover_line)
	if key == "":
		_hover_line.visible = false
		return
	var parts = key.split(":")
	var si = int(parts[0])
	var ei = int(parts[1])
	if si >= _pv_sils.size() or ei >= _pv_sils[si].size():
		_hover_line.visible = false
		return
	var a = _pv_sils[si][ei]
	var b = _pv_sils[si][(ei + 1) % _pv_sils[si].size()]
	_hover_line.points = PoolVector2Array([a, b])
	_hover_line.visible = true


func _on_ridge_rand_toggled(pressed):
	if _btn_reroll != null and is_instance_valid(_btn_reroll):
		_btn_reroll.disabled = not pressed
	_pv_dirty = true


func _on_reroll_pressed():
	randomize()
	_ridge_rand_seed = randf() * 1000.0
	_pv_dirty = true


#########################################################################################################
##
## BUILDING HOVER HIGHLIGHT
##
#########################################################################################################

# Highlights (translucent green) the building under the cursor, so the user
# sees what a click would pick. Cached: as long as the mouse stays inside the
# highlighted silhouettes, nothing is recomputed; leaving them triggers a
# throttled recompute, and empty areas are remembered to avoid hammering the
# geometry pipeline while hovering the void.
func _update_building_highlight():
	var ok = _active and _is_pattern_tool_active() and not _busy and not _popup_pending \
			and not _edit_points_active() \
			and not (_ridge_manual_active() and _pv_sils.size() > 0)
	if not ok:
		_clear_building_highlight()
		return
	var world_ui = _get_world_ui()
	if world_ui == null:
		return
	var vp = world_ui.get_viewport()
	var mouse = vp.get_canvas_transform().affine_inverse().xform(vp.get_mouse_position())

	# Still inside the currently highlighted building → nothing to do
	if _hl_sils.size() > 0:
		for sil in _hl_sils:
			if _geo._point_in_polygon(mouse, sil):
				return
	# Previously computed building this session → instant switch, no recompute
	for entry in _hl_cache:
		for sil in entry:
			if _geo._point_in_polygon(mouse, sil):
				_hl_sils = entry
				_draw_building_highlight()
				return
	# Recently failed near any of these spots → skip (sweeping the void would
	# otherwise rebuild the whole barrier-solid set on every attempt)
	for f in _hl_fails:
		if mouse.distance_to(f) < 64.0:
			return
	# Throttle actual recomputes
	if OS.get_ticks_msec() - _hl_last_try < HL_THROTTLE_MS:
		return
	_hl_last_try = OS.get_ticks_msec()

	var sils = _compute_silhouettes(mouse, true)
	if sils.size() == 0:
		_hl_fails.append(mouse)
		if _hl_fails.size() > HL_FAILS_MAX:
			_hl_fails.pop_front()
		_clear_building_highlight()
		return
	_hl_sils = sils
	_hl_cache.append(sils)
	if _hl_cache.size() > HL_CACHE_MAX:
		_hl_cache.pop_front()
	_draw_building_highlight()


func _draw_building_highlight():
	_free_hl_node()
	var level = _get_current_level()
	if level == null:
		return
	_hl_node = Node2D.new()
	_hl_node.name = "BuildingShadowHighlight"
	_hl_node.z_as_relative = false
	_hl_node.z_index = 4000
	level.add_child(_hl_node)
	for sil in _hl_sils:
		var poly = Polygon2D.new()
		poly.polygon = PoolVector2Array(sil)
		poly.color = Color(0.2, 0.9, 0.3, 0.16)
		_hl_node.add_child(poly)


func _clear_building_highlight():
	_free_hl_node()
	_hl_sils = []


# Full reset, including the session caches — call when the underlying
# geometry may have changed (mode exit, level change, barrier toggle).
func _reset_building_highlight_cache():
	_clear_building_highlight()
	_hl_cache = []
	_hl_fails = []
	_solids_cache = null
	_solids_cache_key = ""


func _free_hl_node():
	if _hl_node != null and is_instance_valid(_hl_node):
		_hl_node.queue_free()
	_hl_node = null


# Restores WorldUI.CursorMode to whatever it was before our suppression.
# Called whenever our override stops applying (mode off, tool switched,
# Edit Points active) so a stale "None" mode is never left behind.
func _restore_cursor_mode():
	if _saved_cursor_mode == null:
		return
	var wui = _get_world_ui()
	if wui != null:
		wui.set("CursorMode", _saved_cursor_mode)
	_saved_cursor_mode = null


# Drops every reference tied to the (now freed) map without touching the dead
# nodes: preview, highlight caches, manual selection, cursor memory. UI-side
# state (labels, buttons, popup) lives under the Editor and survives maps.
func _drop_world_state():
	if _pv_node != null and not is_instance_valid(_pv_node):
		_pv_node = null
	_clear_preview()
	_reset_building_highlight_cache()
	_ridge_edges = {}
	_hover_line = null
	_hover_key = ""
	_saved_cursor_mode = null
	if _popup_pending and _confirm != null and is_instance_valid(_confirm):
		_popup_pending = false
		_confirm.hide()
	_popup_pending = false


func _invert_on() -> bool:
	return _btn_invert != null and is_instance_valid(_btn_invert) and _btn_invert.pressed


# Toggling Invert changes what a click means — drop the current preview so
# stale geometry from the other mode is never applied.
func _on_invert_toggled(_pressed):
	_reset_building_highlight_cache()
	_clear_preview()


func _edge_key(a: Vector2, b: Vector2) -> String:
	return "%d,%d|%d,%d" % [int(round(a.x)), int(round(a.y)), int(round(b.x)), int(round(b.y))]


# Inner (courtyard) shadow: the flat band is region minus region translated
# by the offset — it hugs the sun-side walls with exact corners. Ridge peaks
# are added on inward-facing eligible edges and clipped to the region.
# Bridge-cut edges (present twice, once per direction) never get peaks.
func _extrude_inner_shadow_rings(region: Array, offset: Vector2, sil_idx: int = -1, inflate: float = 0.0) -> Array:
	var ridge_on = _btn_ridge != null and is_instance_valid(_btn_ridge) and _btn_ridge.pressed
	var ridge_h = _sl_ridge.value if (_sl_ridge != null and is_instance_valid(_sl_ridge)) else DEFAULT_RIDGE_HEIGHT
	var ridge_mode = _opt_ridge_mode.selected if (_opt_ridge_mode != null and is_instance_valid(_opt_ridge_mode)) else 0
	var ccw = not Geometry.is_polygon_clockwise(PoolVector2Array(region))

	# 1) Flat inner band
	var moved = []
	for p in region:
		moved.append(p + offset)
	var clipped = Geometry.clip_polygons_2d(PoolVector2Array(region), PoolVector2Array(moved))
	var pieces = []
	var extra_holes = []
	if clipped != null:
		for r in clipped:
			if r.size() < 3:
				continue
			if Geometry.is_polygon_clockwise(r):
				var hh = _geo._to_array(r)
				if inflate > 0.0:
					hh = _shrink_polygon(hh, inflate)
				if hh.size() >= 3:
					extra_holes.append(hh)
			else:
				# Inflation applies to the real shadow band pieces only —
				# the connectivity strip below stays at SWEEP_GROW px.
				var oo = _geo._to_array(r)
				if inflate > 0.0:
					var oof = _grow_polygon_full(oo, inflate)
					oo = oof.outer
					for bh in oof.holes:
						extra_holes.append(bh)
				if oo.size() >= 3:
					pieces.append(_geo._solid_to_comp({"outer": oo, "holes": []}))

	# 1.5) Connectivity strip: a thin ring along the WHOLE courtyard
	# boundary (SWEEP_GROW px, hidden under the wall art) that links every
	# sun-side band piece together — the lit interior becomes a hole, bridged
	# by the post-processing below, so the courtyard yields a SINGLE pattern.
	var shr = Geometry.offset_polygon_2d(PoolVector2Array(region), -SWEEP_GROW, Geometry.JOIN_MITER)
	var strip_holes = []
	if shr != null:
		for spiece in shr:
			if spiece.size() >= 3 and not Geometry.is_polygon_clockwise(spiece):
				strip_holes.append(_geo._to_array(spiece))
	if strip_holes.size() > 0:
		pieces.append(_geo._solid_to_comp({"outer": region, "holes": strip_holes}))
	# (a region thinner than the strip has no shrunk interior: the flat band
	# already covers it, no strip needed)

	# 2) Per-edge sweep quads on every sun-side wall (with the ridge peak
	# when eligible), intersected with the region. Unlike the flat band above
	# (final translation only), the quads cover the FULL sweep: adjacent
	# sun-side edges overlap at corners with their full width, so reflex
	# corners (walls jutting into the courtyard) no longer pinch the shadow
	# to zero width — which showed as a hole once blurred.
	var n = region.size()
	var edge_keys = {}
	for i in range(n):
		edge_keys[_edge_key(region[i], region[(i + 1) % n])] = true
	# Run membership: casting or near-parallel edges (parallel kept inside
	# runs closes the sun-aligned slit); mirrored bridge-cut edges and lit
	# edges break the runs.
	var member = []
	for i in range(n):
		var a = region[i]
		var b = region[(i + 1) % n]
		if a.distance_to(b) < 0.001 or edge_keys.has(_edge_key(b, a)):
			member.append(false)
			continue
		var edge = (b - a).normalized()
		var outward = Vector2(edge.y, -edge.x) if ccw else Vector2(-edge.y, edge.x)
		member.append(outward.dot(offset) <= 0.05 * offset.length())
	# One band per contiguous run, intersected with the region ONCE — a
	# curved courtyard wall of 200 segments costs 1 clip instead of 200.
	for run in _facing_runs(member):
		for sub in _split_run_by_turning(region, run[0], run[1]):
			for bp in _run_band_rings(region, sub[0], sub[1], offset):
				var ins = Geometry.intersect_polygons_2d(PoolVector2Array(bp), PoolVector2Array(region))
				if ins == null:
					continue
				for r3 in ins:
					if r3.size() >= 3 and not Geometry.is_polygon_clockwise(r3):
						var po = _geo._to_array(r3)
						if inflate > 0.0:
							var pof = _grow_polygon_full(po, inflate)
							po = pof.outer
							for bh3 in pof.holes:
								extra_holes.append(bh3)
						if po.size() >= 3:
							pieces.append(_geo._solid_to_comp({"outer": po, "holes": []}))
	# Ridge peaks stay per eligible edge
	if ridge_on and ridge_h > 1.01:
		for i in range(n):
			var a = region[i]
			var b = region[(i + 1) % n]
			if a.distance_to(b) < 0.5 or edge_keys.has(_edge_key(b, a)):
				continue
			var edge = (b - a).normalized()
			var outward = Vector2(edge.y, -edge.x) if ccw else Vector2(-edge.y, edge.x)
			if outward.dot(offset) >= -0.05 * offset.length():
				continue
			if not _edge_wants_ridge(sil_idx, i, a, b, ridge_mode):
				continue
			var m = (a + b) * 0.5
			var h_eff = ridge_h
			if _btn_ridge_rand != null and is_instance_valid(_btn_ridge_rand) and _btn_ridge_rand.pressed:
				var r2 = abs(fmod(sin(m.x * 12.9898 + m.y * 78.233 + _ridge_rand_seed) * 43758.5453, 1.0))
				h_eff = 1.0 + (ridge_h - 1.0) * (0.5 + 1.0 * r2)
			var pent = _geo._ensure_ccw([a, b, b + offset, m + offset * h_eff, a + offset])
			if pent.size() < 3 or _geo._polygon_area(pent) <= 1.0:
				continue
			var ins2 = Geometry.intersect_polygons_2d(PoolVector2Array(pent), PoolVector2Array(region))
			var added = false
			if ins2 != null:
				for r4 in ins2:
					if r4.size() >= 3 and not Geometry.is_polygon_clockwise(r4):
						var po2 = _geo._to_array(r4)
						if inflate > 0.0:
							var pof2 = _grow_polygon_full(po2, inflate)
							po2 = pof2.outer
							for bh4 in pof2.holes:
								extra_holes.append(bh4)
						if po2.size() >= 3:
							pieces.append(_geo._solid_to_comp({"outer": po2, "holes": []}))
							added = true
			if added and sil_idx >= 0:
				_pv_peaked.append([a, b])

	if pieces.size() == 0:
		return []
	var comps = _geo._union_components(pieces)
	if comps == null:
		return []

	# 3) Same post-processing as the outer path: lobes, hole attachment,
	# bridging, triangulability fallbacks
	var finals = []
	for c in comps:
		var parts = []
		var pocket_holes = []
		for lobe in _ring_lobes_classified(c.outer, pocket_holes):
			parts.append({"outer": lobe, "holes": []})
		var all_holes = []
		for h in pocket_holes:
			all_holes.append(h)
		for h in c.holes:
			all_holes.append(h)
		for h in extra_holes:
			all_holes.append(h)
		for h in all_holes:
			for hl in _ring_to_lobes(h):
				_attach_hole_to_part(hl, parts)
		for part in parts:
			var poly = part.outer
			if part.holes.size() > 0:
				poly = _bridge_part(part.outer, part.holes)
			if poly.size() >= 3 and _geo._polygon_area(poly) < MIN_RING_AREA:
				pass  # cleanup debris (e.g. a 30 px sliver) — not worth a pattern
			elif poly.size() >= 3 and _is_triangulable(poly):
				finals.append(poly)
			elif poly.size() >= 3:
				outputlog("WARNING: skipping a non-triangulable inner shadow part", 0)
	return finals





# Sweep of one edge along the offset. Returns the plain quad when it has
# area; for edges (near-)parallel to the offset — where the quad collapses —
# returns a thin rectangle along the swept line, widened by ±1.5 px, so long
# sun-aligned walls still contribute to the union instead of leaving a slit.
func _sweep_piece(a: Vector2, b: Vector2, offset: Vector2) -> Array:
	var quad = _geo._ensure_ccw([a, b, b + offset, a + offset])
	if quad.size() >= 3 and _geo._polygon_area(quad) > 1.0:
		return quad
	if offset.length() < 0.5:
		return []
	var offn = offset.normalized()
	var perp = Vector2(-offn.y, offn.x) * 1.5
	var pts = [a, b, a + offset, b + offset]
	var pmin = pts[0]
	var pmax = pts[0]
	for p in pts:
		if p.dot(offn) < pmin.dot(offn):
			pmin = p
		if p.dot(offn) > pmax.dot(offn):
			pmax = p
	var rect = _geo._ensure_ccw([pmin - perp, pmax - perp, pmax + perp, pmin + perp])
	if rect.size() >= 3 and _geo._polygon_area(rect) > 1.0:
		return rect
	return []


# SEAM_DEBUG: writes every applied ring's coordinates (one ring per line,
# "x,y;x,y;...") plus the offset, to user://bs_seam_debug.txt — i.e. in
# Dungeondraft's user data folder (%APPDATA%/Dungeondraft on Windows).
func _dump_rings_debug(rings: Array):
	var f = File.new()
	if f.open("user://bs_seam_debug.txt", File.WRITE) != OK:
		outputlog("SEAM_DEBUG: cannot write user://bs_seam_debug.txt", 0)
		return
	f.store_line("offset=%f,%f invert=%s inflate_blur=%s" % [_offset.x, _offset.y,
			str(_invert_on()), str(_btn_blur != null and is_instance_valid(_btn_blur) and _btn_blur.pressed)])
	for ring in rings:
		var parts = []
		for p in ring:
			parts.append("%.2f,%.2f" % [p.x, p.y])
		f.store_line("FINAL|" + PoolStringArray(parts).join(";"))
	for line in _dbg_lines:
		f.store_line(line)
	f.close()
	outputlog("SEAM_DEBUG: wrote %d ring(s) to user://bs_seam_debug.txt" % rings.size(), 0)


# Hole elimination by NEAREST-PAIR keyholing — the automated version of the
# manual point edit that fixes the visible seam: every bridge crosses the
# shadow at its thinnest point. Holes are merged closest-first; the
# silhouette hole merges through the 2 px junction sliver, which puts the
# building walls on the outer ring, so enclosed lit pockets (which always
# lean against a wall of the building that spawned them) then merge through
# their 1-2 px tangency to that wall — hidden under the wall art. A truly
# isolated hole still gets the shortest possible bridge.
func _eliminate_holes_nearest(outer_in: Array, holes_in: Array) -> Array:
	if holes_in.size() == 0:
		return outer_in
	var outer = []
	for p in outer_in:
		outer.append(p)
	if Geometry.is_polygon_clockwise(PoolVector2Array(outer)):
		outer.invert()
	var holes = []
	for h in holes_in:
		if h.size() < 3:
			continue
		var hh = []
		for p in h:
			hh.append(p)
		if not Geometry.is_polygon_clockwise(PoolVector2Array(hh)):
			hh.invert()  # holes wound opposite to the outer
		holes.append(hh)

	while holes.size() > 0:
		# Spatial hash of the outer vertices (cell 64 px): good bridges are a
		# few px long, so the 3×3 neighbourhood finds them — the former full
		# hole×outer scan was quadratic and froze on multi-thousand-point
		# cave rings.
		var grid = {}
		for j in range(outer.size()):
			var gk = "%d_%d" % [int(floor(outer[j].x / 64.0)), int(floor(outer[j].y / 64.0))]
			if not grid.has(gk):
				grid[gk] = []
			grid[gk].append(j)
		# Top-K nearest (hole vertex, outer vertex) candidate pairs
		var cands = []  # [d2, h_idx, hi, oi], sorted ascending, max 16
		for h_idx in range(holes.size()):
			var hole = holes[h_idx]
			for i in range(hole.size()):
				var cx = int(floor(hole[i].x / 64.0))
				var cy = int(floor(hole[i].y / 64.0))
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						var gk2 = "%d_%d" % [cx + dx, cy + dy]
						if not grid.has(gk2):
							continue
						for j in grid[gk2]:
							var d = hole[i].distance_squared_to(outer[j])
							if cands.size() < 16 or d < cands[cands.size() - 1][0]:
								var ins = cands.size()
								while ins > 0 and cands[ins - 1][0] > d:
									ins -= 1
								cands.insert(ins, [d, h_idx, i, j])
								if cands.size() > 16:
									cands.pop_back()
		if cands.size() == 0:
			# No outer vertex within a cell of any hole vertex (isolated
			# holes) — full scan, rare by construction
			for h_idx in range(holes.size()):
				var hole = holes[h_idx]
				for i in range(hole.size()):
					for j in range(outer.size()):
						var d = hole[i].distance_squared_to(outer[j])
						if cands.size() < 16 or d < cands[cands.size() - 1][0]:
							var ins = cands.size()
							while ins > 0 and cands[ins - 1][0] > d:
								ins -= 1
							cands.insert(ins, [d, h_idx, i, j])
							if cands.size() > 16:
								cands.pop_back()
		# First candidate whose bridge segment cuts nothing wins. A blind
		# nearest pair can slice through the outline (1° of sun was enough),
		# making the keyhole non-triangulable — and the old last-resort then
		# DROPPED the hole, which showed as a wrongly filled lit pocket.
		var done = false
		for c in cands:
			var hole2 = holes[c[1]]
			if not _bridge_clear(outer[c[3]], hole2[c[2]], outer, holes):
				continue
			holes.remove(c[1])
			var res = []
			for k in range(c[3] + 1):
				res.append(outer[k])
			var n = hole2.size()
			for k in range(n + 1):
				res.append(hole2[(c[2] + k) % n])
			res.append(outer[c[3]])
			for k in range(c[3] + 1, outer.size()):
				res.append(outer[k])
			outer = res
			done = true
			break
		if not done:
			return []  # caller falls back to the robust earcut bridging
	return outer


# True when segment P-Q crosses no edge of the given rings (edges touching P
# or Q excluded) — i.e. the keyhole bridge is valid.
func _bridge_clear(P: Vector2, Q: Vector2, outer: Array, holes: Array) -> bool:
	if P.distance_to(Q) < 0.01:
		return true
	var rings = [outer]
	for h in holes:
		rings.append(h)
	for ring in rings:
		var n = ring.size()
		for k in range(n):
			var u = ring[k]
			var v = ring[(k + 1) % n]
			if u == P or v == P or u == Q or v == Q:
				continue
			var inter = Geometry.segment_intersects_segment_2d(P, Q, u, v)
			if inter is Vector2 and inter.distance_to(P) > 0.5 and inter.distance_to(Q) > 0.5:
				return false
	return true


# Bridging ladder for one part: (1) nearest-pair keyhole (invisible seams),
# (2) same with holes shrunk 0.5 px (tangency), (3) robust earcut bridging —
# the seam may be visible but the lit hole is PRESERVED, (4) earcut with
# shrunk holes, (5) only then drop the holes.
func _bridge_part(outer: Array, holes: Array) -> Array:
	var poly
	if not _apply_pass:
		# PREVIEW: the exact seam placement only matters for the final
		# pattern — use the linear earcut bridging so dial drags stay fluid
		# on huge cave rings, and keep the nearest-pair pass for Apply.
		poly = _geo._eliminate_holes(outer, holes)
		if poly.size() >= 3 and _is_triangulable(poly):
			return poly
	poly = _eliminate_holes_nearest(outer, holes)
	if poly.size() >= 3 and _is_triangulable(poly):
		return poly
	var shrunk = []
	for h in holes:
		var sh = _shrink_polygon(h, 0.5)
		if sh.size() >= 3:
			shrunk.append(sh)
	poly = _eliminate_holes_nearest(outer, shrunk)
	if poly.size() >= 3 and _is_triangulable(poly):
		outputlog("Bridging fallback: nearest-pair with shrunk holes", 1)
		return poly
	poly = _geo._eliminate_holes(outer, holes)
	if poly.size() >= 3 and _is_triangulable(poly):
		outputlog("Bridging fallback: earcut bridge (seam may be visible)", 0)
		return poly
	poly = _geo._eliminate_holes(outer, shrunk)
	if poly.size() >= 3 and _is_triangulable(poly):
		outputlog("Bridging fallback: earcut bridge with shrunk holes (seam may be visible)", 0)
		return poly
	outputlog("WARNING: no valid bridging found, dropping holes for this part", 0)
	return outer


# Attaches a hole ring to the part that contains it. The centroid ray test
# alone proved unstable at near-axis sun angles (4°/184°): the geometry is
# then full of near-horizontal edges, parallel to the horizontal ray the
# point-in-polygon test casts, and a parity miscount silently DROPPED the
# hole — the lit pocket filled with shadow. Ladder: custom test → Godot's
# native test → proximity fallback (never drop silently).
func _attach_hole_to_part(hl: Array, parts: Array):
	if parts.size() == 0 or hl.size() < 3:
		return
	var cen = _ring_centroid(hl)
	for part in parts:
		if _geo._point_in_polygon(cen, part.outer):
			part.holes.append(hl)
			return
	for part in parts:
		if Geometry.is_point_in_polygon(cen, PoolVector2Array(part.outer)):
			part.holes.append(hl)
			return
	# Proximity fallback: nearest part by vertex distance
	var best_part = null
	var best_d = INF
	for part in parts:
		for p in part.outer:
			var d = cen.distance_squared_to(p)
			if d < best_d:
				best_d = d
				best_part = part
	if best_part != null:
		best_part.holes.append(hl)
		outputlog("Hole containment test failed — attached by proximity fallback", 1)


# Splits a ring at every coincident vertex pair (O(n) hash scan) — unlike
# _ring_to_lobes, NO triangulability fast-path: a Clipper "figure-eight"
# ring (outer fused with a tangent hole at near-axis sun angles) often still
# triangulates, FILLED — which is exactly the bug this catches.
func _split_ring_pinches_fast(pts: Array) -> Array:
	var n = pts.size()
	if n < 4:
		return [pts]
	var seen = {}
	for idx in range(n):
		var key = "%.1f_%.1f" % [pts[idx].x, pts[idx].y]
		if seen.has(key):
			var i = seen[key]
			if idx > i + 1 and not (i == 0 and idx == n - 1) and pts[i].distance_to(pts[idx]) <= 0.03:
				var r1 = []
				for k in range(i, idx):
					r1.append(pts[k])
				var r2 = []
				for k in range(idx, n):
					r2.append(pts[k])
				for k in range(0, i):
					r2.append(pts[k])
				return _split_ring_pinches_fast(r1) + _split_ring_pinches_fast(r2)
		seen[key] = idx
	return [pts]


# Decomposes a clip/merge output ring into solid lobes, ALWAYS splitting at
# pinches first; lobes wound clockwise (enclosed lit pockets fused into the
# outer by Clipper) are appended to holes_out instead of returned as solids.
func _ring_lobes_classified(o: Array, holes_out: Array) -> Array:
	var solids = []
	var any_solid = false
	for r in _split_ring_pinches_fast(o):
		var rc = _clean_ring_basic(r)
		if rc.size() < 3 or abs(_geo._polygon_area(rc)) <= 1.0:
			continue
		if Geometry.is_polygon_clockwise(PoolVector2Array(rc)):
			holes_out.append(rc)
		else:
			for lobe in _ring_to_lobes(rc):
				solids.append(lobe)
				any_solid = true
	if not any_solid:
		for lobe in _ring_to_lobes(o):
			solids.append(lobe)
	return solids


func _dbg_ring(tag: String, sil_idx: int, ring: Array):
	var parts = []
	for p in ring:
		parts.append("%.2f,%.2f" % [p.x, p.y])
	_dbg_lines.append("%s|sil%d|%s" % [tag, sil_idx, PoolStringArray(parts).join(";")])


#########################################################################################################
##
## BARRIER CHANGE DETECTION (highlight cache invalidation)
##
#########################################################################################################

func _on_tree_node_added(node):
	_maybe_invalidate_highlight(node)


func _on_tree_node_removed(node):
	_maybe_invalidate_highlight(node)


func _maybe_invalidate_highlight(node):
	if _hl_cache.size() == 0 and _hl_sils.size() == 0 and _hl_fails.size() == 0 \
			and _solids_cache == null:
		return
	if not (node is Node):
		return
	var p = node.get_parent()
	if p == null:
		return
	if p.name == "Walls" or p.name == "Pathways" or p.name == "Portals":
		_reset_building_highlight_cache()
		return
	var gp = p.get_parent()
	if gp != null and (gp.name == "Walls" or gp.name == "Pathways" or gp.name == "Portals"):
		_reset_building_highlight_cache()


func _level_uid() -> int:
	var level = _get_current_level()
	return level.get_instance_id() if level != null else 0


# Contiguous runs of `true` in a circular boolean array → [[start, count]].
func _facing_runs(flags: Array) -> Array:
	var n = flags.size()
	var all_true = true
	for f in flags:
		if not f:
			all_true = false
			break
	if all_true:
		return [[0, n]]
	var anchor = 0
	for i in range(n):
		if not flags[i]:
			anchor = i
			break
	var runs = []
	var run_start = -1
	for k in range(1, n + 1):
		var idx = (anchor + k) % n
		if flags[idx] and k < n:
			if run_start == -1:
				run_start = idx
		else:
			if run_start != -1:
				runs.append([run_start, int((idx - run_start + n) % n)])
				run_start = -1
	return runs


# Band swept by the edge chain [start .. start+count] along `offset`, as ONE
# ring (chain + reversed translated chain). Sanity check: a zigzagging chain
# can self-cancel the band — the area must stay comparable to the summed
# per-edge parallelogram areas, otherwise fall back to per-edge sweep
# pieces. A run spanning the whole ring also falls back.
func _run_band_rings(ring: Array, start: int, count: int, offset: Vector2) -> Array:
	var n = ring.size()
	if count <= 0:
		return []
	if count < n:
		# Base shifted 1 px upstream (inside the silhouette): gives every
		# band an AREA overlap with the silhouette piece, so the union fuses
		# them into one polygon — edge-only contact does not merge reliably.
		var up = -offset.normalized()
		var chain = []
		for k in range(count + 1):
			chain.append(ring[(start + k) % n])
		var band = []
		for p in chain:
			band.append(p + up)
		for k in range(chain.size() - 1, -1, -1):
			band.append(chain[k] + offset)
		band = _geo._ensure_ccw(band)
		var quads_sum = 0.0
		for k in range(count):
			var a = ring[(start + k) % n]
			var b = ring[(start + k + 1) % n]
			quads_sum += abs((b - a).cross(offset))
		if band.size() >= 3 and _geo._polygon_area(band) > 1.0 \
				and _geo._polygon_area(band) > 0.55 * quads_sum:
			return [band]
	# Fallback: per-edge sweep pieces (degenerate or self-cancelling chain)
	var out = []
	for k in range(count):
		var sp = _sweep_piece(ring[(start + k) % n], ring[(start + k + 1) % n], offset)
		if sp.size() >= 3:
			out.append(sp)
	return out


# Appends the run band pieces of the outer sweep to `pieces`.
func _append_run_band(pieces: Array, sil: Array, start: int, count: int, offset: Vector2):
	for band in _run_band_rings(sil, start, count, offset):
		pieces.append(_geo._solid_to_comp({"outer": band, "holes": []}))


# O(n) polyline decimation: drops a vertex when it deviates from the segment
# joining its kept predecessor to its successor by less than `eps` px.
func _decimate_ring(ring: Array, eps: float) -> Array:
	var n = ring.size()
	if n <= 16:
		return ring
	var out = []
	var anchor = ring[0]
	out.append(anchor)
	for i in range(1, n):
		var nxt = ring[(i + 1) % n]
		var p = ring[i]
		var closest = Geometry.get_closest_point_to_segment_2d(p, anchor, nxt)
		if p.distance_to(closest) >= eps or out.size() < 3 and i >= n - 2:
			out.append(p)
			anchor = p
	if out.size() < 3:
		return ring
	return out


# Splits an edge run into sub-runs whose cumulative heading change stays
# under ~60°. Bands of gently curving chains are simple polygons; a run that
# U-turns (cave walls wrapping a room) produced a self-intersecting "bowtie"
# band whose union coverage cancelled out — shadow lobes lost their sliver
# connection and split into separate patterns.
func _split_run_by_turning(ring: Array, start: int, count: int) -> Array:
	var n = ring.size()
	if count <= 2:
		return [[start, count]]
	var subs = []
	var sub_start = start
	var sub_count = 0
	var prev_dir = Vector2.ZERO
	var accum = 0.0
	for k in range(count):
		var a = ring[(start + k) % n]
		var b = ring[(start + k + 1) % n]
		var d = (b - a)
		if d.length() < 0.001:
			sub_count += 1
			continue
		d = d.normalized()
		if prev_dir != Vector2.ZERO:
			accum += abs(prev_dir.angle_to(d))
		prev_dir = d
		if accum > 1.047 and sub_count > 0:  # ~60°
			subs.append([sub_start, sub_count])
			sub_start = (start + k) % n
			sub_count = 0
			accum = 0.0
		sub_count += 1
	if sub_count > 0:
		subs.append([sub_start, sub_count])
	return subs


# Registry housekeeping + NON-DESTRUCTIVE texture restore at map open.
# The blur shader needs an opaque pattern_tex as its mask even with
# use_texture:false (it keeps the sampled alpha) — and at load the pattern's
# _Texture is DD's "Null" icon, whose alpha rendered the shadow fully
# transparent. Restoring via SetOptions is FORBIDDEN here: it rebuilds the
# material and wipes the blur ShaderMaterial uchideshi just applied. So we
# only (1) write the public _Texture field directly (no material rebuild)
# and (2) refresh the pattern_tex shader param when a ShaderMaterial is
# present (a no-op on materials without that uniform).
func _restore_embedded_textures():
	var md = global.ModMapData
	if not (md is Dictionary) or not md.has(BS_TEX_KEY):
		return
	var rec = md[BS_TEX_KEY]
	if not (rec is Dictionary):
		return
	var fixed = 0
	var dead = []
	for k in rec.keys():
		var id = int(k)
		if not global.World.HasNodeID(id):
			dead.append(k)
			continue
		var node = global.World.GetNodeByID(id)
		if node == null or not is_instance_valid(node) or not node.has_method("SetOptions"):
			dead.append(k)
			continue
		var tex = _get_shadow_texture(int(rec[k]))
		node._Texture = tex
		if node.material != null and node.material is ShaderMaterial:
			node.material.set_shader_param("pattern_tex", tex)
		fixed += 1
	for k2 in dead:
		rec.erase(k2)
	if fixed > 0 or dead.size() > 0:
		outputlog("Building shadow textures: %d restored (non-destructive), %d stale record(s) purged" % [fixed, dead.size()], 0)
