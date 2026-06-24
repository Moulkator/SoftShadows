#########################################################################################################
##
## PATHS, WALLS & OBJECTS DROP SHADOW - CORE MOD
##
#########################################################################################################
# Version 1.2.1

var script_class = "tool"

var DropShadowPathsScript
var DropShadowWallsScript
var DropShadowObjectsScript
var DropShadowRoofsScript
var ShadowToggleScript
var LevelSettingsPatchScript
var SoftShadowsToolScript
var OverlayShadowObjectsScript
var ShadowHistoryScript
var ShadowBakeAllScript
var dropshadow_paths
var dropshadow_walls
var dropshadow_objects
var dropshadow_roofs
var shadow_toggle
var level_settings_patch
var soft_shadows_tool
var overlay_shadow_objects
var shadow_history
var shadow_bake_all

var store_last_valid_selection = []

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
			printraw("(%d) <PathsWallsDropShadow>: " % OS.get_ticks_msec())
			print(msg)
	else:
		pass

#########################################################################################################
##
## SHARED UTILITIES
##
#########################################################################################################

# Returns the Align VBoxContainer of a tool panel.
# Robust against mods (e.g. ResizeLeftPanel) that re-parent Align into an
# HBoxContainer for a resize handle. Returns null if not found.
func get_align_vbox(tool_panel):
	if tool_panel == null:
		return null
	# Preferred: documented .Align property (works regardless of re-parenting)
	if tool_panel.get("Align") != null:
		return tool_panel.Align
	# Fallback 1: direct VBoxContainer child
	for i in range(tool_panel.get_child_count()):
		var child = tool_panel.get_child(i)
		if child is VBoxContainer:
			return child
	# Fallback 2: VBoxContainer nested inside an HBoxContainer (e.g. ResizeLeftPanel layout)
	for i in range(tool_panel.get_child_count()):
		var child = tool_panel.get_child(i)
		if child is HBoxContainer:
			for j in range(child.get_child_count()):
				var sub = child.get_child(j)
				if sub is VBoxContainer:
					return sub
	return null

#########################################################################################################
##
## SELECTION CHANGE DETECTION
##
#########################################################################################################

func has_selection_changed() -> bool:

	var current_selection = Global.Editor.Tools["SelectTool"].Selected

	# Check if selection has changed
	if current_selection.size() != store_last_valid_selection.size():
		store_last_valid_selection = current_selection.duplicate()
		return true

	for i in range(current_selection.size()):
		if current_selection[i] != store_last_valid_selection[i]:
			store_last_valid_selection = current_selection.duplicate()
			return true

	return false

#########################################################################################################
##
## INITIALISE
##
#########################################################################################################

func initialise_dropshadow():

	# ── Historique undo/redo (créé en premier : sans dépendance) ─────────
	ShadowHistoryScript = ResourceLoader.load(Global.Root + "ShadowHistory.gd", "GDScript", true)
	if ShadowHistoryScript != null:
		shadow_history = ShadowHistoryScript.new()
		shadow_history.global = Global
		shadow_history.core = self
		shadow_history.logging_level = logging_level
		shadow_history.initialise()
	else:
		outputlog("Warning: ShadowHistory.gd not found, undo/redo disabled", 0)

	DropShadowPathsScript = ResourceLoader.load(Global.Root + "DropShadowPaths.gd", "GDScript", true)
	dropshadow_paths = DropShadowPathsScript.new()
	dropshadow_paths.global = Global
	dropshadow_paths.reference_to_script = Script
	dropshadow_paths.core = self
	dropshadow_paths.logging_level = logging_level
	dropshadow_paths.shadow_history = shadow_history
	dropshadow_paths.initialise()
	_pause_monitor(dropshadow_paths)

	DropShadowWallsScript = ResourceLoader.load(Global.Root + "DropShadowWalls.gd", "GDScript", true)
	dropshadow_walls = DropShadowWallsScript.new()
	dropshadow_walls.global = Global
	dropshadow_walls.reference_to_script = Script
	dropshadow_walls.core = self
	dropshadow_walls.logging_level = logging_level
	dropshadow_walls.shadow_history = shadow_history
	dropshadow_walls.initialise()
	_pause_monitor(dropshadow_walls)

	DropShadowObjectsScript = ResourceLoader.load(Global.Root + "DropShadowObjects.gd", "GDScript", true)
	if DropShadowObjectsScript != null:
		dropshadow_objects = DropShadowObjectsScript.new()
		dropshadow_objects.global = Global
		dropshadow_objects.core = self
		dropshadow_objects.logging_level = logging_level
		dropshadow_objects.dropshadow_paths = dropshadow_paths
		dropshadow_objects.dropshadow_walls = dropshadow_walls
		dropshadow_objects.shadow_history = shadow_history
		dropshadow_objects.initialise()
		_pause_monitor(dropshadow_objects)
	else:
		outputlog("Warning: DropShadowObjects.gd not found, objects shadows disabled", 0)

	DropShadowRoofsScript = ResourceLoader.load(Global.Root + "DropShadowRoofs.gd", "GDScript", true)
	if DropShadowRoofsScript != null:
		dropshadow_roofs = DropShadowRoofsScript.new()
		dropshadow_roofs.global = Global
		dropshadow_roofs.core = self
		dropshadow_roofs.logging_level = logging_level
		dropshadow_roofs.dropshadow_objects = dropshadow_objects
		dropshadow_roofs.shadow_history = shadow_history
		dropshadow_roofs.initialise()
		_pause_monitor(dropshadow_roofs)
		# Wire back into objects so it can delegate roof shadow creation
		if dropshadow_objects != null:
			dropshadow_objects.dropshadow_roofs = dropshadow_roofs
	else:
		outputlog("Warning: DropShadowRoofs.gd not found, roof sync disabled", 0)

	# ── Shadow toggle (floatbar Show/Hide) ──────────────────────────────
	ShadowToggleScript = ResourceLoader.load(Global.Root + "ShadowToggle.gd", "GDScript", true)
	if ShadowToggleScript != null:
		shadow_toggle = ShadowToggleScript.new()
		shadow_toggle.global = Global
		shadow_toggle.core = self
		shadow_toggle.logging_level = logging_level
		shadow_toggle.dropshadow_paths = dropshadow_paths
		shadow_toggle.dropshadow_walls = dropshadow_walls
		shadow_toggle.dropshadow_objects = dropshadow_objects
		shadow_toggle.dropshadow_roofs = dropshadow_roofs
		shadow_toggle.initialise()
	else:
		outputlog("Warning: ShadowToggle.gd not found, floatbar toggle disabled", 0)

	# ── Level Settings patch (per-level enable/disable + global quality) ─
	LevelSettingsPatchScript = ResourceLoader.load(Global.Root + "LevelSettingsPatch.gd", "GDScript", true)
	if LevelSettingsPatchScript != null:
		level_settings_patch = LevelSettingsPatchScript.new()
		level_settings_patch.global = Global
		level_settings_patch.core = self
		level_settings_patch.logging_level = logging_level
		level_settings_patch.dropshadow_paths = dropshadow_paths
		level_settings_patch.dropshadow_walls = dropshadow_walls
		level_settings_patch.dropshadow_objects = dropshadow_objects
		level_settings_patch.dropshadow_roofs = dropshadow_roofs
		level_settings_patch.shadow_toggle = shadow_toggle
		level_settings_patch.initialise()
		# Cross-link so ShadowToggle can refresh after patch creates shadows
		if shadow_toggle != null:
			shadow_toggle.level_settings_patch = level_settings_patch
	else:
		outputlog("Warning: LevelSettingsPatch.gd not found, level controls disabled", 0)

	# ── Global shadow bake (must exist BEFORE SoftShadowsTool builds controls) ─
	ShadowBakeAllScript = ResourceLoader.load(Global.Root + "ShadowBakeAll.gd", "GDScript", true)
	if ShadowBakeAllScript != null:
		shadow_bake_all = ShadowBakeAllScript.new()
		shadow_bake_all.global = Global
		shadow_bake_all.core = self
		shadow_bake_all.logging_level = logging_level
		shadow_bake_all.dropshadow_objects = dropshadow_objects
		shadow_bake_all.initialise()
	else:
		outputlog("Warning: ShadowBakeAll.gd not found, global bake disabled", 0)

	# Soft Shadows tool (Effects category) — hosts the autonomous controls,
	# built by level_settings_patch into the tool's panel. Created after the
	# patch so its control-building method and member state are ready.
	SoftShadowsToolScript = ResourceLoader.load(Global.Root + "SoftShadowsTool.gd", "GDScript", true)
	if SoftShadowsToolScript != null and level_settings_patch != null:
		soft_shadows_tool = SoftShadowsToolScript.new()
		soft_shadows_tool.global = Global
		soft_shadows_tool.core = self
		soft_shadows_tool.logging_level = logging_level
		soft_shadows_tool.level_settings_patch = level_settings_patch
		soft_shadows_tool.initialise()
	else:
		outputlog("Warning: SoftShadowsTool.gd not found or no level patch, Effects tool disabled", 0)

	Global.ModMapData["_dropshadow_refs"] = {
		"paths": dropshadow_paths,
		"walls": dropshadow_walls,
		"objects": dropshadow_objects,
		"roofs": dropshadow_roofs,
		"level_settings": level_settings_patch
	}

	# ── Overlay (form) shadow for objects ───────────────────────────────
	OverlayShadowObjectsScript = ResourceLoader.load(Global.Root + "OverlayShadowObjects.gd", "GDScript", true)
	if OverlayShadowObjectsScript != null:
		overlay_shadow_objects = OverlayShadowObjectsScript.new()
		overlay_shadow_objects.global = Global
		overlay_shadow_objects.core = self
		overlay_shadow_objects.logging_level = logging_level
		overlay_shadow_objects.shadow_history = shadow_history
		overlay_shadow_objects.initialise()
		_pause_monitor(overlay_shadow_objects)
		Global.ModMapData["_dropshadow_refs"]["overlay_objects"] = overlay_shadow_objects
		# Let the level-settings patch mask/grey object overlays on disabled levels.
		if level_settings_patch != null:
			level_settings_patch.overlay_shadow_objects = overlay_shadow_objects
	else:
		outputlog("Warning: OverlayShadowObjects.gd not found, overlay shadows disabled", 0)


# Pause/resume each module's _monitor_timer during the map-load critical
# window. Without this, monitors (especially walls' aggressive "orphaned
# shadow → rebuild") create shadows for cfg.enabled=true entries before
# shadow_toggle's pre_apply_state has a chance to flip them. Since
# autostart timers don't fire until at least one frame after add_child,
# pausing them synchronously here is safe.
func _pause_monitor(module):
	if module == null:
		return
	var t = module.get("_monitor_timer")
	if t != null and is_instance_valid(t):
		t.stop()


func _resume_monitor(module):
	if module == null:
		return
	var t = module.get("_monitor_timer")
	if t != null and is_instance_valid(t):
		t.start()

#########################################################################################################
##
## PROCESS LOOP
##
#########################################################################################################

func update(_delta):

	# Detect selection changes in SelectTool
	if Global.Editor.ActiveToolName == "SelectTool":
		if has_selection_changed():
			if dropshadow_paths != null:
				dropshadow_paths.on_selection_changed()
			if dropshadow_walls != null:
				dropshadow_walls.on_selection_changed()
			if dropshadow_objects != null:
				dropshadow_objects.on_selection_changed()
			if dropshadow_roofs != null:
				dropshadow_roofs.on_selection_changed()
			if overlay_shadow_objects != null:
				overlay_shadow_objects.on_selection_changed()

	# LevelSettingsPatch: polls for tool-panel readiness + tree mutations
	if level_settings_patch != null:
		level_settings_patch.on_update(_delta)

	# ShadowBakeAll: refresh bake/unbake button state when the level changes
	if shadow_bake_all != null:
		shadow_bake_all.on_update()

#########################################################################################################
##
## MOD ENTRY POINT
##
#########################################################################################################

func start() -> void:

	outputlog("Paths & Walls Drop Shadow Mod Has been loaded.", 0)

	randomize()

	# Register with _lib if available
	if Engine.has_signal("_lib_register_mod"):
		Engine.emit_signal("_lib_register_mod", self)
		# Branche le verificateur de mise a jour de _Lib (si cette version le fournit)
		if "API" in Global and Global.API.has("UpdateChecker"):
			var uc = Global.API.UpdateChecker
			uc.register(uc.builder()\
				.fetcher(uc.github_fetcher("Moulkator", "SoftShadows"))\
				.downloader(uc.github_downloader("Moulkator", "SoftShadows"))\
				.build())

	# Initialise the drop shadow system
	initialise_dropshadow()

	# Apply saved shadows to the current map
	# Use a small delay to ensure the map is fully loaded
	var timer = Timer.new()
	timer.wait_time = 0.5
	timer.one_shot = true
	timer.connect("timeout", self, "_on_map_load_timer")
	Global.Editor.add_child(timer)
	timer.start()

func _on_map_load_timer():
	# Pre-process: LevelSettingsPatch mutates ModMapData first so modules
	# skip creating shadows we'd just remove. Flash-free map load.
	if level_settings_patch != null:
		level_settings_patch.pre_apply_state()
	# Bake save/reload safety: re-enable any shadows that were saved in a baked
	# state (overlay persistence comes in a later slice) before they're applied.
	if shadow_bake_all != null:
		shadow_bake_all.on_map_load()
	if dropshadow_paths != null:
		dropshadow_paths.apply_saved_shadows_to_map()
	if dropshadow_walls != null:
		dropshadow_walls.apply_saved_shadows_to_map()
	if dropshadow_objects != null:
		dropshadow_objects.apply_saved_shadows_to_map()
	if dropshadow_roofs != null:
		dropshadow_roofs.apply_saved_state()
	if overlay_shadow_objects != null:
		overlay_shadow_objects.apply_saved_shadows_to_map()
	# Post-process: finalise STATE_KEY from preempted ids, apply global quality
	if level_settings_patch != null:
		level_settings_patch.apply_saved_state()
	# ShadowToggle: replay global hidden flag on the final shadow set
	if shadow_toggle != null:
		shadow_toggle.apply_saved_state()
	# Scene is now in its final post-load state — safe to resume monitors
	# (they were paused in initialise_dropshadow to prevent flash creation
	# during the 0.5s map-load window).
	_resume_monitor(dropshadow_paths)
	_resume_monitor(dropshadow_walls)
	_resume_monitor(dropshadow_objects)
	_resume_monitor(dropshadow_roofs)
	_resume_monitor(overlay_shadow_objects)
