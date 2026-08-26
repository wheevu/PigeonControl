extends SceneTree

# Standalone headless test for the observer capture slice. Exercises config
# validation, message formatting, frame-path formatting, and idempotent tick
# bookkeeping through ObserverCapture's pure helpers. It does NOT require a live
# Julia generator, a graphics viewport, or PNG output.
#
# Run: godot --headless --path godot -s res://scripts/_observer_test.gd

func _initialize() -> void:
	var ok: bool = _run()
	if ok:
		print("OBSERVER_TEST_OK")
		quit(0)
	else:
		print("OBSERVER_TEST_FAIL")
		quit(1)

func _set_env(k: String, v: String) -> void:
	OS.set_environment(k, v)

func _clear_env() -> void:
	_set_env("OBSERVER_OUTPUT_DIR", "")
	_set_env("OBSERVER_SESSION_ID", "")
	_set_env("OBSERVER_ACK_PORT", "")
	_set_env("OBSERVER_SNAPSHOT_PORT", "")
	_set_env("OBSERVER_EXPECTED_FRAMES", "")
	_set_env("OBSERVER_DT", "")

func _run() -> bool:
	var OC = load("res://scripts/ObserverCapture.gd")
	if OC == null:
		print("fail: could not load res://scripts/ObserverCapture.gd")
		return false

	# --- session id validation (pure) ---
	if not OC.is_valid_session_id("sess_1.A-B"):
		print("fail: valid session id rejected: sess_1.A-B")
		return false
	if OC.is_valid_session_id(""):
		print("fail: empty session id accepted")
		return false
	if OC.is_valid_session_id("bad id"):
		print("fail: session id with space accepted")
		return false
	if OC.is_valid_session_id("bad/id"):
		print("fail: session id with slash accepted")
		return false
	if OC.is_valid_session_id("bad:id"):
		print("fail: session id with colon accepted")
		return false

	# --- message formatting (pure) ---
	if OC.format_ready_message("S1") != "READY S1":
		print("fail: format_ready_message wrong: '%s'" % OC.format_ready_message("S1"))
		return false
	if OC.format_captured_message("S1", 7) != "CAPTURED S1 7":
		print("fail: format_captured_message wrong: '%s'" % OC.format_captured_message("S1", 7))
		return false
	if OC.pack_message("READY S1") != "READY S1".to_utf8_buffer():
		print("fail: pack_message mismatch")
		return false

	# --- frame path formatting (pure) ---
	var fp: String = OC.frame_path("/tmp/out", 7)
	if fp != "/tmp/out/tick_%010d.png" % 7:
		print("fail: frame_path wrong: '%s'" % fp)
		return false

	# --- config validation (pure, drives parse_config) ---
	var cap = OC.new()
	if cap == null:
		print("fail: could not instantiate ObserverCapture")
		return false

	# Missing output dir.
	_clear_env()
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	var c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted missing OBSERVER_OUTPUT_DIR")
		cap.free()
		return false

	# Relative output dir.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "relative/dir")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted relative OBSERVER_OUTPUT_DIR")
		cap.free()
		return false

	# Non-existent output dir.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/nonexistent/path/xyz")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted non-existent OBSERVER_OUTPUT_DIR")
		cap.free()
		return false

	# Bad session id.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "bad id")
	_set_env("OBSERVER_ACK_PORT", "6000")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted bad OBSERVER_SESSION_ID")
		cap.free()
		return false

	# Missing ack port.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted missing OBSERVER_ACK_PORT")
		cap.free()
		return false

	# Out-of-range ack port.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "70000")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted out-of-range OBSERVER_ACK_PORT")
		cap.free()
		return false

	# Valid minimal config -> defaults applied.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	c = cap.parse_config()
	if not c["ok"]:
		print("fail: valid minimal config rejected: %s" % c["error"])
		cap.free()
		return false
	if c["snapshot_port"] != 5100:
		print("fail: default snapshot_port %d != 5100" % c["snapshot_port"])
		cap.free()
		return false
	if c["expected_frames"] != 0:
		print("fail: default expected_frames %d != 0" % c["expected_frames"])
		cap.free()
		return false
	if abs(c["dt"] - (1.0 / 60.0)) > 1e-9:
		print("fail: default dt %f != 1/60" % c["dt"])
		cap.free()
		return false

	# Full valid config -> overrides honored.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess-2.A")
	_set_env("OBSERVER_ACK_PORT", "6100")
	_set_env("OBSERVER_SNAPSHOT_PORT", "5200")
	_set_env("OBSERVER_EXPECTED_FRAMES", "5")
	_set_env("OBSERVER_DT", "0.05")
	c = cap.parse_config()
	if not c["ok"]:
		print("fail: valid full config rejected: %s" % c["error"])
		cap.free()
		return false
	if c["snapshot_port"] != 5200:
		print("fail: snapshot_port override %d != 5200" % c["snapshot_port"])
		cap.free()
		return false
	if c["expected_frames"] != 5:
		print("fail: expected_frames override %d != 5" % c["expected_frames"])
		cap.free()
		return false
	if abs(c["dt"] - 0.05) > 1e-9:
		print("fail: dt override %f != 0.05" % c["dt"])
		cap.free()
		return false

	# Non-positive expected frames rejected.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp not used but set")
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	_set_env("OBSERVER_EXPECTED_FRAMES", "0")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted OBSERVER_EXPECTED_FRAMES=0")
		cap.free()
		return false

	# Non-positive dt rejected.
	_clear_env()
	_set_env("OBSERVER_OUTPUT_DIR", "/tmp")
	_set_env("OBSERVER_SESSION_ID", "sess1")
	_set_env("OBSERVER_ACK_PORT", "6000")
	_set_env("OBSERVER_DT", "0")
	c = cap.parse_config()
	if c["ok"]:
		print("fail: parse_config accepted OBSERVER_DT=0")
		cap.free()
		return false

	# --- idempotent tick bookkeeping (pure) ---
	_clear_env()
	cap.free()
	cap = OC.new()
	if cap == null:
		print("fail: could not reinstantiate ObserverCapture for bookkeeping")
		return false
	# First booking of a tick succeeds.
	if not cap.book_tick(3):
		print("fail: first book_tick(3) returned false")
		cap.free()
		return false
	# Second booking (duplicate, still in flight) fails.
	if cap.book_tick(3):
		print("fail: duplicate book_tick(3) returned true")
		cap.free()
		return false
	# Not yet saved.
	if cap.is_saved(3):
		print("fail: tick 3 reported saved before finalize")
		cap.free()
		return false
	# Finalize, then saved and no longer bookable.
	cap.finalize_tick(3)
	if not cap.is_saved(3):
		print("fail: tick 3 not saved after finalize")
		cap.free()
		return false
	if cap.book_tick(3):
		print("fail: book_tick(3) returned true after finalize")
		cap.free()
		return false
	if cap.saved_count() != 1:
		print("fail: saved_count %d != 1" % cap.saved_count())
		cap.free()
		return false
	# Independent tick still bookable.
	if not cap.book_tick(4):
		print("fail: book_tick(4) returned false")
		cap.free()
		return false
	cap.finalize_tick(4)
	if cap.saved_count() != 2:
		print("fail: saved_count %d != 2" % cap.saved_count())
		cap.free()
		return false
	cap.free()

	# --- Swarm observer API contract (pure-ish, no viewport) ---
	var SwarmScript = load("res://scripts/Swarm.gd")
	if SwarmScript == null:
		print("fail: could not load res://scripts/Swarm.gd")
		return false
	var swarm := Node3D.new()
	swarm.set_script(SwarmScript)
	if not swarm.has_method("set_observer_capture") or not swarm.has_method("apply_observer_tick"):
		print("fail: Swarm missing observer capture API")
		swarm.free()
		return false
	swarm.setup(8)
	# Default (normal) mode must keep interpolation: fx_time advances via delta.
	swarm._process(0.1)
	var fx_normal: float = swarm.fx_time
	# Enable observer capture with dt; fx_time must follow tick*dt.
	swarm.set_observer_capture(true, 0.05)
	swarm.apply_observer_tick(10)
	swarm._process(0.1)
	if abs(swarm.fx_time - 10.0 * 0.05) > 1e-6:
		print("fail: observer fx_time %f != tick*dt (%f)" % [swarm.fx_time, 10.0 * 0.05])
		swarm.free()
		return false
	# Disabling returns to wall-clock accumulation from the observer baseline.
	swarm.set_observer_capture(false, 0.05)
	swarm._process(0.1)
	if not (swarm.fx_time > 10.0 * 0.05 - 1e-6):
		print("fail: normal mode did not resume wall-clock fx_time")
		swarm.free()
		return false
	swarm.free()

	# --- SnapshotReceiver contract (signal + latest tick) ---
	var RcvScript = load("res://scripts/SnapshotReceiver.gd")
	if RcvScript == null:
		print("fail: could not load res://scripts/SnapshotReceiver.gd")
		return false
	var rcv = RcvScript.new()
	if not rcv.has_signal("snapshot_applied"):
		print("fail: SnapshotReceiver missing snapshot_applied signal")
		rcv.free()
		return false
	if rcv.latest_applied_tick != -1:
		print("fail: SnapshotReceiver latest_applied_tick default != -1")
		rcv.free()
		return false
	rcv.free()

	_clear_env()
	return true
