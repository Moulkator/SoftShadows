#########################################################################################################
##
## SHADOW HISTORY — undo / redo for the mod's own parameter changes
##
#########################################################################################################
#
# Slice A1 : undo/redo des réglages PROPRES au mod (commence par l'offset objets).
# La sync avec l'undo natif (move/delete) viendra dans le Slice B.
#
# Pas de `extends` au niveau fichier (DD auto-parse chaque .gd). Le handler clavier
# vit dans un nœud Control créé via script inline (même technique que la sonde).
#
# ── Modèle ──────────────────────────────────────────────────────────────────────
# Une liste ordonnée d'entrées + un curseur (style undo/redo classique).
#   entry = {
#     "module": <objet qui sait appliquer>,
#     "method": <String — méthode appelée pour appliquer un snapshot>,
#     "undo":   <payload à appliquer pour annuler>,
#     "redo":   <payload à appliquer pour rétablir>,
#     "type":   "mod",   # "mod" | "native"  (native = Slice B)
#     "label":  <String — debug>
#   }
# undo()  -> module.call(method, entry.undo) ; curseur--
# redo()  -> module.call(method, entry.redo) ; curseur++
# record()-> tronque la queue de redo, empile, curseur = fin
#
# ── Clavier ─────────────────────────────────────────────────────────────────────
# Ctrl+Z : si can_undo() -> undo() + set_input_as_handled() (on bloque le natif)
#          sinon -> on laisse passer (l'undo natif s'applique)
# Ctrl+Y : symétrique avec can_redo()
# (Slice B raffinera la décision bloquer/laisser-passer selon le type d'entrée.)
#
#########################################################################################################

var global
var core = null
var logging_level = 0
var _monitor_timer = null   # compat Core._pause/_resume_monitor (inutilisé)

const REDO_KEY = KEY_Y       # DD utilise Ctrl+Y pour redo (confirmé)
const NATIVE_COALESCE_MS = 350   # ops natives rapprochées = 1 seul marqueur
const NATIVE_SUPPRESS_MS = 300   # après un passthrough, ignorer la détection native

var _stack = []
var _cursor = 0              # nombre d'entrées "faites" ; [0.._cursor) = annulables
var _listener = null
var _flushers = []          # [{module, method}] appelés avant chaque undo/redo
var _resync_callbacks = []  # [{module, method}] appelés après un passthrough natif
var _resync_timer = null
var _last_native_ms = 0
var _native_suppress_until = 0

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	_stack = []
	_cursor = 0

	var src = "extends Control\n" \
		+ "var hist = null\n" \
		+ "func _ready():\n" \
		+ "\tmouse_filter = MOUSE_FILTER_IGNORE\n" \
		+ "func _input(event):\n" \
		+ "\tif hist != null:\n" \
		+ "\t\thist._on_input(event, get_tree(), get_focus_owner())\n"
	var gd = GDScript.new()
	gd.source_code = src
	var err = gd.reload()
	if err != OK:
		_log("échec compilation du listener (err=%d)" % err)
		return
	_listener = gd.new()
	_listener.hist = self
	global.Editor.add_child(_listener)

	# Timer court : après un passthrough natif, on laisse DD finir puis on
	# resynchronise les shadows (couvre les nœuds réapparus à géométrie identique).
	_resync_timer = Timer.new()
	_resync_timer.wait_time = 0.08
	_resync_timer.one_shot = true
	_resync_timer.connect("timeout", self, "_run_resync")
	global.Editor.add_child(_resync_timer)

	_log("historique initialisé")

#########################################################################################################
## API PUBLIQUE (appelée par les modules de shadow)
#########################################################################################################

# Enregistre un changement réversible.
#   module  : l'objet qui sait appliquer un snapshot (ex. dropshadow_objects)
#   method  : nom de la méthode d'application -> module.method(payload)
#   undo    : payload restaurant l'état AVANT
#   redo    : payload restaurant l'état APRÈS
func record(module, method, undo, redo, label = "", type = "mod"):
	# Tronque toute la queue redo au-delà du curseur.
	if _cursor < _stack.size():
		_stack.resize(_cursor)
	_stack.append({
		"module": module,
		"method": method,
		"undo": undo,
		"redo": redo,
		"type": type,
		"label": label,
	})
	_cursor = _stack.size()
	_log("record [%s] '%s' (pile=%d)" % [type, label, _stack.size()])

# Un module avec des transactions en attente s'enregistre ici pour être "flushé"
# (commit forcé) juste avant chaque undo/redo, évitant toute course de debounce.
func register_flusher(module, method):
	for f in _flushers:
		if f["module"] == module and f["method"] == method:
			return
	_flushers.append({"module": module, "method": method})

# Un module enregistre ici un resync appelé après chaque passthrough natif.
func register_resync(module, method):
	for r in _resync_callbacks:
		if r["module"] == module and r["method"] == method:
			return
	_resync_callbacks.append({"module": module, "method": method})

func _run_resync():
	for r in _resync_callbacks:
		var m = r["module"]
		if m != null and m.has_method(r["method"]):
			m.call(r["method"])

func _schedule_resync():
	if _resync_timer != null:
		_resync_timer.start()

func _run_flushers():
	for f in _flushers:
		var m = f["module"]
		if m != null and m.has_method(f["method"]):
			m.call(f["method"])

# Signalé par un module quand il détecte une op NATIVE (move/add/delete) que DD
# rendra annulable. On insère un marqueur dans la timeline unifiée, anti-rebond
# pour qu'un geste continu (drag) = un seul marqueur.
func note_native_op():
	var now = OS.get_ticks_msec()
	if now < _native_suppress_until:
		return   # changement provoqué par un passthrough undo/redo : ignorer
	# Coalescence : si le sommet est déjà un marqueur natif récent, on prolonge.
	if _cursor > 0 and _stack[_cursor - 1].get("type", "mod") == "native" \
			and (now - _last_native_ms) < NATIVE_COALESCE_MS:
		_last_native_ms = now
		return
	# Nouvelle op native : on flushe d'abord les transactions mod en attente pour
	# qu'elles se rangent AVANT ce marqueur (ordre temporel correct), puis on
	# tronque la queue de redo et on empile le marqueur.
	_run_flushers()
	if _cursor < _stack.size():
		_stack.resize(_cursor)
	_stack.append({"type": "native"})
	_cursor = _stack.size()
	_last_native_ms = now

func _suppress_native_detection():
	_native_suppress_until = OS.get_ticks_msec() + NATIVE_SUPPRESS_MS

func can_undo() -> bool:
	return _cursor > 0

func can_redo() -> bool:
	return _cursor < _stack.size()

func undo() -> bool:
	if not can_undo():
		return false
	var entry = _stack[_cursor - 1]
	_cursor -= 1
	_apply(entry, entry["undo"])
	_log("undo '%s' (curseur=%d)" % [entry.get("label", ""), _cursor])
	return true

func redo() -> bool:
	if not can_redo():
		return false
	var entry = _stack[_cursor]
	_cursor += 1
	_apply(entry, entry["redo"])
	_log("redo '%s' (curseur=%d)" % [entry.get("label", ""), _cursor])
	return true

func clear():
	_stack = []
	_cursor = 0

func _apply(entry, payload):
	var m = entry.get("module")
	var meth = entry.get("method")
	if m != null and meth != null and m.has_method(meth):
		m.call(meth, payload)
	else:
		_log("WARN: méthode d'application introuvable (%s)" % str(meth))

#########################################################################################################
## CLAVIER
#########################################################################################################

func _on_input(event, tree, focus_owner):
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	var ctrl = bool(event.control) or bool(event.command)
	if not ctrl:
		return

	# Préserver l'undo d'une VRAIE zone de texte (recherche, libellés DD…),
	# mais PAS pour le LineEdit interne d'un SpinBox : là l'utilisateur attend
	# l'undo des shadows, pas l'undo du texte saisi.
	if focus_owner != null and (focus_owner is LineEdit or focus_owner is TextEdit):
		var p = focus_owner.get_parent()
		if not (p != null and p is SpinBox):
			return

	if event.scancode == KEY_Z and not event.shift:
		_run_flushers()   # commit des transactions en attente
		if _cursor > 0:
			var e = _stack[_cursor - 1]
			if e.get("type", "mod") == "native":
				# Sommet = op native : on laisse DD annuler, on descend le curseur.
				_cursor -= 1
				_suppress_native_detection()
				_schedule_resync()
			else:
				undo()
				tree.set_input_as_handled()   # bloque l'undo natif
		# pile vide -> on laisse passer le natif
	elif event.scancode == REDO_KEY:
		_run_flushers()
		if _cursor < _stack.size():
			var er = _stack[_cursor]
			if er.get("type", "mod") == "native":
				_cursor += 1
				_suppress_native_detection()
				_schedule_resync()
				# laisse passer le redo natif
			else:
				redo()
				tree.set_input_as_handled()   # bloque le redo natif
		# rien à refaire -> on laisse passer le natif
		# rien à refaire -> on laisse passer le natif

#########################################################################################################
## LOG
#########################################################################################################

func _log(msg):
	if core != null and core.has_method("outputlog"):
		core.outputlog("[ShadowHistory] " + msg, 0)
	else:
		print("[ShadowHistory] " + msg)
