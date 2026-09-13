#########################################################################################################
##
## SHADOW HISTORY — undo / redo for the mod's own parameter changes
##
#########################################################################################################
#
# The mod no longer keeps a parallel undo stack. Every reversible shadow change is
# recorded directly into Dungeondraft's native history via
#     Global.Editor.History.CreateCustomRecord(reference)
# where `reference` is a Reference exposing undo() / redo() (see CustomHistoryRecord.cs).
#
# Benefits: ordering with native operations (terrain, water, material, objects…) is
# guaranteed by DD itself, redo truncation / MaxUndos are handled by DD, and both the
# Ctrl+Z / Ctrl+Y shortcuts and the top-bar Undo / Redo buttons go through the same path.
#
# The only thing the mod still has to do is FLUSH pending debounced transactions
# (slider drags are coalesced by a 0.4 s timer in each module) right before DD runs an
# undo or redo. Two non-blocking hooks do that:
#   - an `_input` listener on Ctrl+Z / Ctrl+Y (runs before DD's button shortcut, which
#     is processed in `_unhandled_input`); it never calls set_input_as_handled()
#   - `button_down` on the Undo / Redo buttons (emitted before `pressed`)
#
# Public API kept for the modules: record(), register_flusher(), register_resync().
# Legacy methods (note_native_op, can_undo, can_redo, undo, redo, clear) are no-ops.
#
#########################################################################################################

var global
var core = null
var logging_level = 0
var _monitor_timer = null   # compat Core._pause/_resume_monitor (unused)

const REDO_KEY = KEY_Y      # DD uses Ctrl+Y for redo

var _record_script = null   # GDScript used to instance one Reference per history entry
var _listener = null
var _flushers = []          # [{module, method}] called before each undo/redo
var _resync_callbacks = []  # [{module, method}] called after each undo/redo
var _resync_timer = null
var _history = null         # Global.Editor.History (native)

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	_history = _get_native_history()
	if _history == null:
		_log("WARN: Global.Editor.History not found, undo/redo disabled")
		return

	# Reference instanced for every recorded entry; DD calls undo()/redo() on it.
	var rec_src = "extends Reference\n" \
		+ "var module = null\n" \
		+ "var method = \"\"\n" \
		+ "var undo_payload = null\n" \
		+ "var redo_payload = null\n" \
		+ "var label = \"\"\n" \
		+ "var hist = null\n" \
		+ "func undo():\n" \
		+ "\tif hist != null:\n" \
		+ "\t\thist._apply(self, undo_payload, \"undo\")\n" \
		+ "func redo():\n" \
		+ "\tif hist != null:\n" \
		+ "\t\thist._apply(self, redo_payload, \"redo\")\n"
	_record_script = GDScript.new()
	_record_script.source_code = rec_src
	if _record_script.reload() != OK:
		_log("WARN: record script failed to compile, undo/redo disabled")
		_record_script = null
		return

	# Keyboard listener: flush pending transactions on Ctrl+Z / Ctrl+Y, never block.
	var src = "extends Control\n" \
		+ "var hist = null\n" \
		+ "func _ready():\n" \
		+ "\tmouse_filter = MOUSE_FILTER_IGNORE\n" \
		+ "func _input(event):\n" \
		+ "\tif hist != null:\n" \
		+ "\t\thist._on_input(event)\n"
	var gd = GDScript.new()
	gd.source_code = src
	if gd.reload() == OK:
		_listener = gd.new()
		_listener.hist = self
		global.Editor.add_child(_listener)
	else:
		_log("WARN: keyboard listener failed to compile (pending changes may not flush before Ctrl+Z)")

	# Top-bar buttons: button_down is emitted before pressed (which triggers History.Undo/Redo).
	_connect_button_down(global.Editor.get("undoButton"))
	_connect_button_down(global.Editor.get("redoButton"))

	# Short timer: after a native undo/redo let DD finish, then resync the shadows.
	_resync_timer = Timer.new()
	_resync_timer.wait_time = 0.08
	_resync_timer.one_shot = true
	_resync_timer.connect("timeout", self, "_run_resync")
	global.Editor.add_child(_resync_timer)

	_log("history initialised (native DD history)")

func _get_native_history():
	if global == null or global.Editor == null:
		return null
	var h = global.Editor.get("History")
	if h != null and h.has_method("CreateCustomRecord"):
		return h
	return null

func _connect_button_down(button):
	if button != null and button is BaseButton and not button.is_connected("button_down", self, "_on_button_down"):
		button.connect("button_down", self, "_on_button_down")

#########################################################################################################
## PUBLIC API (called by the shadow modules)
#########################################################################################################

# Records a reversible change into DD's native history.
#   module  : object that knows how to apply a snapshot (e.g. dropshadow_objects)
#   method  : name of the apply method -> module.method(payload)
#   undo    : payload restoring the state BEFORE
#   redo    : payload restoring the state AFTER
func record(module, method, undo, redo, label = "", type = "mod"):
	if _history == null or _record_script == null:
		return
	var rec = _record_script.new()
	rec.module = module
	rec.method = method
	rec.undo_payload = undo
	rec.redo_payload = redo
	rec.label = label
	rec.hist = self
	_history.CreateCustomRecord(rec)
	_log("record '%s'" % label)

# A module with pending (debounced) transactions registers here to be flushed
# (forced commit) right before each undo/redo.
func register_flusher(module, method):
	for f in _flushers:
		if f["module"] == module and f["method"] == method:
			return
	_flushers.append({"module": module, "method": method})

# A module registers here a resync called shortly after each undo/redo.
func register_resync(module, method):
	for r in _resync_callbacks:
		if r["module"] == module and r["method"] == method:
			return
	_resync_callbacks.append({"module": module, "method": method})

# ── Legacy no-ops (DD's history now owns ordering and native ops) ──────────────
func note_native_op():
	pass

func can_undo() -> bool:
	return false

func can_redo() -> bool:
	return false

func undo() -> bool:
	return false

func redo() -> bool:
	return false

func clear():
	pass

#########################################################################################################
## INTERNALS
#########################################################################################################

func _run_flushers():
	for f in _flushers:
		var m = f["module"]
		if m != null and is_instance_valid(m) and m.has_method(f["method"]):
			m.call(f["method"])

func _run_resync():
	for r in _resync_callbacks:
		var m = r["module"]
		if m != null and is_instance_valid(m) and m.has_method(r["method"]):
			m.call(r["method"])

func _schedule_resync():
	if _resync_timer != null:
		_resync_timer.start()

# Called by DD (through the record Reference) when it undoes / redoes our entry.
func _apply(rec, payload, what):
	var m = rec.module
	var meth = rec.method
	if m != null and is_instance_valid(m) and meth != null and m.has_method(meth):
		m.call(meth, payload)
		_log("%s '%s'" % [what, rec.label])
	else:
		_log("WARN: apply method not found (%s)" % str(meth))
	_schedule_resync()

# Undo / Redo button pressed with the mouse: flush before `pressed` fires.
func _on_button_down():
	_run_flushers()
	_schedule_resync()

# Ctrl+Z / Ctrl+Y: flush before DD's shortcut handles it. Never consumes the event.
func _on_input(event):
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	if not (bool(event.control) or bool(event.command)):
		return
	if event.scancode == KEY_Z or event.scancode == REDO_KEY:
		_run_flushers()
		_schedule_resync()

#########################################################################################################
## LOG
#########################################################################################################

func _log(msg):
	if core != null and core.has_method("outputlog"):
		core.outputlog("[ShadowHistory] " + msg, 0)
	else:
		print("[ShadowHistory] " + msg)
