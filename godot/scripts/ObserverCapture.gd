extends Node

# Synchronized observer capture. Godot only WITNESSES the simulation: it renders
# existing Julia UDP snapshot v1 frames and saves exactly one PNG per applied
# tick, then acknowledges each captured tick back to the Julia generator over a
# dedicated experiment ack UDP port (separate from the runtime control port).
#
# Handshake contract with the Julia generator:
#   - After scene + socket setup, send `READY <session_id>` to 127.0.0.1:<ack_port>.
#   - For each newly applied snapshot tick, snap capture-only rendering to the
#     latest authoritative target transforms, wait for
#     RenderingServer.frame_post_draw, save PNG as `<output>/tick_%010d.png`,
#     then send `CAPTURED <session_id> <tick>` only after save_png returns OK.
#   - One frame per tick, idempotent: a duplicate tick already saved is not
#     rewritten; its ACK is resent. Parser or save failures are never
#     acknowledged, and the process exits nonzero.
#
# Configuration (environment):
#   OBSERVER_OUTPUT_DIR       required existing absolute directory
#   OBSERVER_SESSION_ID       required safe [A-Za-z0-9_.-]+
#   OBSERVER_ACK_PORT         required valid 1..65535
#   OBSERVER_SNAPSHOT_PORT    default 5100
#   OBSERVER_EXPECTED_FRAMES  optional positive int; quit 0 when reached
#   OBSERVER_DT               default 1/60 (authoritative tick spacing)

const FRAME_NAME_FMT := "tick_%010d.png"

# --- pure helpers (headless-testable, no side effects) ----------------------

static func is_valid_session_id(s: String) -> bool:
	if s == null or s.is_empty():
		return false
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9_.-]+$")
	return re.search(s) != null

static func format_ready_message(session_id: String) -> String:
	return "READY " + session_id

static func format_captured_message(session_id: String, tick: int) -> String:
	return "CAPTURED %s %d" % [session_id, tick]

static func pack_message(msg: String) -> PackedByteArray:
	return msg.to_utf8_buffer()

static func frame_path(output_dir: String, tick: int) -> String:
	return output_dir.path_join(FRAME_NAME_FMT % tick)

# Parse and validate configuration from the environment. Returns a Dictionary
# with keys: ok, error, output_dir, session_id, ack_port, snapshot_port,
# expected_frames, dt.
func parse_config() -> Dictionary:
	var res := {
		"ok": false,
		"error": "",
		"output_dir": "",
		"session_id": "",
		"ack_port": 0,
		"snapshot_port": 5100,
		"expected_frames": 0,
		"dt": 1.0 / 60.0,
	}

	var out: String = OS.get_environment("OBSERVER_OUTPUT_DIR")
	if out == "":
		res["error"] = "OBSERVER_OUTPUT_DIR is required (existing absolute directory)"
		return res
	if not out.is_absolute_path():
		res["error"] = "OBSERVER_OUTPUT_DIR must be absolute: '%s'" % out
		return res
	if not DirAccess.dir_exists_absolute(out):
		res["error"] = "OBSERVER_OUTPUT_DIR does not exist: '%s'" % out
		return res
	res["output_dir"] = out

	var sid: String = OS.get_environment("OBSERVER_SESSION_ID").strip_edges()
	if not is_valid_session_id(sid):
		res["error"] = "OBSERVER_SESSION_ID must match [A-Za-z0-9_.-]+: '%s'" % sid
		return res
	res["session_id"] = sid

	var ack_raw: String = OS.get_environment("OBSERVER_ACK_PORT").strip_edges()
	if ack_raw == "":
		res["error"] = "OBSERVER_ACK_PORT is required (1..65535)"
		return res
	var ack: int = int(ack_raw)
	if ack < 1 or ack > 65535:
		res["error"] = "OBSERVER_ACK_PORT out of range 1..65535: '%s'" % ack_raw
		return res
	res["ack_port"] = ack

	var snap_raw: String = OS.get_environment("OBSERVER_SNAPSHOT_PORT").strip_edges()
	if snap_raw != "":
		var sp: int = int(snap_raw)
		if sp < 1 or sp > 65535:
			res["error"] = "OBSERVER_SNAPSHOT_PORT out of range 1..65535: '%s'" % snap_raw
			return res
		res["snapshot_port"] = sp

	var ef_raw: String = OS.get_environment("OBSERVER_EXPECTED_FRAMES").strip_edges()
	if ef_raw != "":
		var ef: int = int(ef_raw)
		if ef <= 0:
			res["error"] = "OBSERVER_EXPECTED_FRAMES must be positive: '%s'" % ef_raw
			return res
		res["expected_frames"] = ef

	var dt_raw: String = OS.get_environment("OBSERVER_DT").strip_edges()
	if dt_raw != "":
		var dt: float = float(dt_raw)
		if not dt > 0.0:
			res["error"] = "OBSERVER_DT must be positive: '%s'" % dt_raw
			return res
		res["dt"] = dt

	res["ok"] = true
	return res

# --- idempotent tick bookkeeping (headless-testable) -------------------------

var _saved_ticks := {}    # tick -> true (PNG written)
var _pending_ticks := {}  # tick -> true (capture in flight)

# Book a tick for capture. Returns false if it is already saved or already in
# flight (idempotent duplicate handling); true only on first booking.
func book_tick(tick: int) -> bool:
	if _saved_ticks.has(tick) or _pending_ticks.has(tick):
		return false
	_pending_ticks[tick] = true
	return true

func finalize_tick(tick: int) -> void:
	_pending_ticks.erase(tick)
	_saved_ticks[tick] = true

func is_saved(tick: int) -> bool:
	return _saved_ticks.has(tick)

func saved_count() -> int:
	return _saved_ticks.size()

# --- runtime ----------------------------------------------------------------

var _cfg := {}
var _session_id: String = ""
var _ack_peer: PacketPeerUDP = null
var _swarm: Node = null
var _receiver: Node = null

func _ready() -> void:
	# This scene IS the observer: force observer mode on the shared Main scene so
	# it builds the fixed camera and suppresses the Commander.
	OS.set_environment("OBSERVER_MODE", "1")

	_cfg = parse_config()
	if not _cfg["ok"]:
		printerr("ObserverCapture: bad config - %s" % _cfg["error"])
		get_tree().quit(1)
		return
	_session_id = _cfg["session_id"]

	# Build the shared scene (ambience + map + fixed cam + swarm + receiver).
	var main_scene: PackedScene = load("res://main.tscn")
	if main_scene == null:
		printerr("ObserverCapture: could not load res://main.tscn")
		get_tree().quit(1)
		return
	var main: Node = main_scene.instantiate()
	add_child(main)
	await get_tree().process_frame

	_swarm = main.find_child("Swarm", true, false)
	_receiver = main.find_child("Receiver", true, false)
	if _swarm == null or _receiver == null:
		printerr("ObserverCapture: could not locate Swarm/Receiver in scene")
		get_tree().quit(1)
		return
	if not _swarm.has_method("set_observer_capture") or not _swarm.has_method("apply_observer_tick"):
		printerr("ObserverCapture: Swarm lacks observer capture API")
		get_tree().quit(1)
		return

	_swarm.set_observer_capture(true, _cfg["dt"])

	# Dedicated experiment ack socket to the Julia generator.
	_ack_peer = PacketPeerUDP.new()
	var bind_err: int = _ack_peer.connect_to_host("127.0.0.1", _cfg["ack_port"])
	if bind_err != OK:
		printerr("ObserverCapture: failed to open ack socket to 127.0.0.1:%d (err %d)" % [_cfg["ack_port"], bind_err])
		get_tree().quit(1)
		return

	if not _receiver.has_signal("snapshot_applied"):
		printerr("ObserverCapture: Receiver missing snapshot_applied signal")
		get_tree().quit(1)
		return
	_receiver.connect("snapshot_applied", _on_snapshot_applied)

	_send_ack(format_ready_message(_session_id))
	print("ObserverCapture ready session=%s ack=:%d snap=:%d out=%s" % [
		_session_id, _cfg["ack_port"], _cfg["snapshot_port"], _cfg["output_dir"]])

func _send_ack(msg: String) -> void:
	if _ack_peer == null:
		return
	var buf: PackedByteArray = pack_message(msg)
	var err: int = _ack_peer.put_packet(buf)
	if err != OK:
		printerr("ObserverCapture: failed to send ack '%s' (err %d)" % [msg, err])
		get_tree().quit(1)

func _on_snapshot_applied(tick: int) -> void:
	# Never acknowledge a tick the parser flagged (ok=true but error nonempty).
	if _receiver != null and _receiver.get("latest_applied_error") != "":
		return

	# Duplicate of an already-saved tick: resend its ACK (idempotent), then
	# exit if the expected frame count was reached. Never rewrite the PNG.
	if is_saved(tick):
		_send_ack(format_captured_message(_session_id, tick))
		_maybe_quit()
		return

	if not book_tick(tick):
		# Already in flight for this tick; ignore.
		return

	# Snap capture-only rendering to the latest authoritative target transforms.
	_swarm.apply_observer_tick(tick)

	# Wait for the composed frame so the PNG matches the drawn transforms.
	await RenderingServer.frame_post_draw

	var img: Image = get_viewport().get_texture().get_image()
	var path: String = frame_path(_cfg["output_dir"], tick)
	var err: Error = img.save_png(path)
	if err != OK:
		printerr("ObserverCapture: failed to save %s (err %d)" % [path, err])
		get_tree().quit(1)
		return

	finalize_tick(tick)
	_send_ack(format_captured_message(_session_id, tick))
	_maybe_quit()

func _maybe_quit() -> void:
	if _cfg["expected_frames"] > 0 and saved_count() >= _cfg["expected_frames"]:
		get_tree().quit(0)
