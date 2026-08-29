#########################################################################################################
##
## SOFT SHADOWS TOOL - Custom tool in the "Effects" category
##
#########################################################################################################
# Registers a tool in DD's Effects category and hosts the mod's autonomous
# shadow controls (rendering mode, quality, enable/disable scope, manual bake).
#
# The control logic itself lives in LevelSettingsPatch — this tool just creates
# the panel via Toolset.CreateModTool() and asks the patch to populate it
# (level_settings_patch.build_tool_controls). The per-level cloud icons remain
# on the native LevelSettings tree (handled by LevelSettingsPatch), hybrid setup.

var global
var core = null
var level_settings_patch = null

const ENABLE_LOGGING = true
var logging_level = 0

const TOOL_ID = "SoftShadowsTool"

var _tool_panel = null

func outputlog(msg, level=0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <SoftShadowsTool>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	if global.Editor == null or global.Editor.Toolset == null:
		outputlog("Toolset not ready — tool not created", 0)
		return
	var icon = global.Root + "icons/cloud.png"
	_tool_panel = global.Editor.Toolset.CreateModTool(self, "Effects", TOOL_ID, "Soft Shadows", icon)
	if _tool_panel == null:
		outputlog("CreateModTool returned null — tool not created", 0)
		return

	# Resolve the panel's content VBox (robust against left-panel resizer mods).
	var container = _tool_panel
	if core != null and core.has_method("get_align_vbox"):
		var vbox = core.get_align_vbox(_tool_panel)
		if vbox != null:
			container = vbox

	if level_settings_patch != null:
		level_settings_patch.build_tool_controls(container)
	else:
		outputlog("level_settings_patch missing — controls not built", 0)

	# Global bake controls (resolution slider + Render/Unbake buttons).
	# Wrapped in a MarginContainer: the section's buttons and dropdown were
	# touching the panel's right edge (ShadowBakeAll adds its controls flush).
	if core != null and core.get("shadow_bake_all") != null:
		var ba_margin = MarginContainer.new()
		ba_margin.add_constant_override("margin_right", 10)
		ba_margin.add_constant_override("margin_left", 2)
		ba_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ba_vbox = VBoxContainer.new()
		ba_margin.add_child(ba_vbox)
		container.add_child(ba_margin)
		core.shadow_bake_all.build_controls(ba_vbox)

	# Bottom section (Simple shadow size cap) — added LAST so it sits below
	# the Bake All Shadows block at the very bottom of the tool panel.
	if level_settings_patch != null and level_settings_patch.has_method("build_bottom_controls"):
		level_settings_patch.build_bottom_controls(container)

	outputlog("[BUILD: TOOL-CAPROW-2] Soft Shadows tool created in Effects category", 0)

#########################################################################################################
## DD TOOL CALLBACKS — no-ops (settings panel, no canvas behaviour)
#########################################################################################################

func update(_delta):
	pass

func on_tool_enable(_tool_id):
	pass

func on_tool_disable(_tool_id):
	pass

func on_content_input(_event):
	pass
