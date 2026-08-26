extends Node

# Captures viewport frames of the running renderer to PNGs so the repo can
# ship real GIFs of the simulation.
#
# Environment variables:
#   CAPTURE_DIR              absolute output directory (must exist)
#   CAPTURE_FRAMES           number of frames to save before quitting (> 0)
#   CAPTURE_EVERY            save every Nth rendered frame (>= 1)
#   CAPTURE_MODE             "" | "overview" | "action"
#   CAPTURE_ORBIT            "1" aliases CAPTURE_MODE=overview (backward compat)
#   CAPTURE_VARIANT          archetype focus for action mode: 1 Crumb Goblin,
#                            2 Sky Scout, 3 Bruiser (default 1)
#   CAPTURE_REQUIRE_FIGHTING "1" (legacy, empty mode): gate on a FIGHTING
#                            member of the selected variant
#
# Mode semantics:
#   overview  Composed plaza-map shot from outside/above the road ring.
#             Radius 46 m, height 33 m, aimed slightly north of center, with a
#             very shallow deterministic drift that keeps the north/east/west
#             context and the active flock in frame. Counting waits for live
#             pigeons.
#   action    Waits for the first real FIGHTING pigeon of the selected variant
#             (via get_variant_state_subject_id), locks its ID, snaps the
#             camera onto it before the first saved frame, then captures
#             continuously for CAPTURE_FRAMES even after that fight ends,
#             following the same pigeon through its aftermath via
#             get_pigeon_position. No pausing, reacquiring, or stitching of
#             unrelated fights. If the ID disappears, the last position is
#             held. Observation only; never mutates simulation state.
#   ""        Legacy behavior preserved (variant focus + optional fighting
#             gate, or FreeCam).
#
# Usage examples (run from repo root):
#
#   # 4.5 s action clip of Bruiser fights (54 saved frames at ~12 fps)
#   mkdir -p /tmp/pigeon_action && \
#   CAPTURE_MODE=action CAPTURE_VARIANT=3 \
#   CAPTURE_DIR=/tmp/pigeon_action CAPTURE_FRAMES=54 CAPTURE_EVERY=5 \
#   CAPTURE_CLEAN=1 godot --path godot capture.tscn
#
#   # 9 s overview of the plaza map (108 saved frames at ~12 fps)
#   mkdir -p /tmp/pigeon_overview && \
#   CAPTURE_MODE=overview \
#   CAPTURE_DIR=/tmp/pigeon_overview CAPTURE_FRAMES=108 CAPTURE_EVERY=5 \
#   CAPTURE_CLEAN=1 godot --path godot capture.tscn
#
# Frames are grabbed after RenderingServer.frame_post_draw so every PNG
# matches the composed frame instead of lagging one draw behind.

const FIGHTING := 6

# Overview camera constants (16:9 plaza framing).
const OVERVIEW_RADIUS := 46.0
const OVERVIEW_HEIGHT := 33.0
const OVERVIEW_DRIFT := 0.02        # rad/s, ~11 degrees over a 10 s clip
const OVERVIEW_START_ANGLE := 0.35  # rad, south-of-east start keeps N/E/W context
const OVERVIEW_AIM := Vector3(0.0, 1.0, -4.0)  # slightly north of center

# Action camera constants (close elevated 3/4 view, with room for opponent/VFX).
const ACTION_OFFSET := Vector3(0.0, 4.5, 3.0)
const CAPTURE_WARMUP_FRAMES := 12

var out_dir: String = OS.get_environment("CAPTURE_DIR")
var target: int = int(OS.get_environment("CAPTURE_FRAMES"))
var every: int = maxi(1, int(OS.get_environment("CAPTURE_EVERY")))
var swarm: Node

var mode: String = ""               # "", "overview", "action"
var variant_focus: int = -1         # legacy / action variant, -1 = none
var require_fighting: bool = false  # legacy gate only
var use_orbit: bool = false         # legacy orbit alias

# Cameras.
var orbit_cam: Camera3D   # shared by overview + legacy orbit
var focus_cam: Camera3D
var orbit_angle: float = OVERVIEW_START_ANGLE

# Legacy smoothing state.
var _focus_pos: Vector3 = Vector3.ZERO
var _focus_had_target: bool = false

# Action lock state machine: WAIT -> locked ID -> continuous capture.
var _action_locked_id: int = -1
var _action_subject_pos: Vector3 = Vector3.ZERO
var _action_smoothed: Vector3 = Vector3.ZERO
var _action_acquired: bool = false
var _action_running: bool = false

var count: int = 0
var tick: int = 0
var _saving: bool = false
var _ready_frames: int = 0

func _ready() -> void:
	add_child(load("res://main.tscn").instantiate())
	await get_tree().process_frame
	swarm = get_viewport().find_child("Swarm", true, false)

	# --- validate output config ---
	if out_dir == "" or not DirAccess.dir_exists_absolute(out_dir):
		printerr("CAPTURE_DIR must be set to an existing directory.")
		get_tree().quit(1)
		return
	if target <= 0:
		printerr("CAPTURE_FRAMES must be > 0.")
		get_tree().quit(1)
		return
	every = maxi(1, every)

	# --- resolve mode ---
	mode = OS.get_environment("CAPTURE_MODE").strip_edges().to_lower()
	if OS.get_environment("CAPTURE_ORBIT") == "1" and mode == "":
		mode = "overview"  # backward compatibility
	if mode != "overview" and mode != "action":
		if mode != "":
			printerr("Unknown CAPTURE_MODE '%s'; using default." % mode)
		mode = ""

	if mode == "action":
		var raw_variant: String = OS.get_environment("CAPTURE_VARIANT").strip_edges()
		variant_focus = 1
		if raw_variant != "":
			var v: int = int(raw_variant)
			if v >= 1 and v <= 3:
				variant_focus = v
		focus_cam = Camera3D.new()
		focus_cam.name = "FocusCam"
		focus_cam.fov = 42.0
		add_child(focus_cam)
		focus_cam.make_current()
	elif mode == "overview":
		orbit_cam = Camera3D.new()
		orbit_cam.name = "OrbitCam"
		orbit_cam.fov = 55.0
		add_child(orbit_cam)
		orbit_cam.make_current()
		_apply_overview()
	else:
		# Legacy empty-mode resolution.
		orbit_angle = -0.7
		var raw_variant: String = OS.get_environment("CAPTURE_VARIANT").strip_edges()
		if raw_variant != "":
			var v: int = int(raw_variant)
			if v >= 1 and v <= 3:
				variant_focus = v
				focus_cam = Camera3D.new()
				focus_cam.name = "FocusCam"
				focus_cam.fov = 45.0
				add_child(focus_cam)
				focus_cam.make_current()
		require_fighting = OS.get_environment("CAPTURE_REQUIRE_FIGHTING") == "1"
		if require_fighting and variant_focus < 0:
			require_fighting = false
		if OS.get_environment("CAPTURE_ORBIT") == "1" and variant_focus < 0:
			use_orbit = true
			orbit_cam = Camera3D.new()
			orbit_cam.name = "OrbitCam"
			orbit_cam.fov = 55.0
			add_child(orbit_cam)
			orbit_cam.make_current()

func _process(delta: float) -> void:
	match mode:
		"overview":
			orbit_angle += delta * OVERVIEW_DRIFT
			_apply_overview()
		"action":
			_update_action(delta)
		_:
			_legacy_process(delta)

	if count >= target or not _should_capture_this_tick():
		return
	tick += 1
	if tick % every != 0:
		return
	_save_frame()

func _should_capture_this_tick() -> bool:
	if count >= target:
		return false
	if swarm == null or swarm.get("current_count") == null or swarm.current_count == 0:
		_ready_frames = 0
		return false
	var mode_ready := false
	match mode:
		"overview":
			mode_ready = true  # current_count > 0 means live pigeons are present
		"action":
			mode_ready = _action_running
		_:
			mode_ready = variant_focus < 0 or _legacy_condition_met()
	if not mode_ready:
		_ready_frames = 0
		return false
	# Let Swarm submit populated MultiMesh transforms before the first saved
	# frame. Without this short warmup, action clips can begin on an empty map.
	_ready_frames += 1
	return _ready_frames >= CAPTURE_WARMUP_FRAMES

# Saves exactly the composed frame by waiting for the next completed draw.
func _save_frame() -> void:
	if _saving:
		return
	_saving = true
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var path := "%s/frame_%04d.png" % [out_dir, count]
	var err: Error = img.save_png(path)
	if err != OK:
		printerr("Failed to save capture frame %s (error %d)." % [path, err])
		_saving = false
		get_tree().quit(1)
		return
	count += 1
	_saving = false
	if count >= target:
		get_tree().quit()

# --- overview -------------------------------------------------------------

func _apply_overview() -> void:
	orbit_cam.position = Vector3(
		sin(orbit_angle) * OVERVIEW_RADIUS,
		OVERVIEW_HEIGHT,
		cos(orbit_angle) * OVERVIEW_RADIUS)
	orbit_cam.look_at(OVERVIEW_AIM)

# --- action ---------------------------------------------------------------

func _update_action(_delta: float) -> void:
	if swarm == null:
		return
	if not _action_running:
		# Wait for the first real FIGHTING member of the selected variant.
		var id: int = swarm.get_variant_state_subject_id(variant_focus, FIGHTING)
		if id < 0:
			return
		if swarm.has_method("is_pigeon_rendered") and not swarm.is_pigeon_rendered(id):
			return
		var pos: Vector3 = swarm.get_pigeon_position(id)
		if pos == Vector3.ZERO:
			return
		# First acquisition snaps; no pre-fight drift, no stitched fights.
		_action_locked_id = id
		_action_subject_pos = pos
		_action_smoothed = pos
		_action_acquired = true
		_action_running = true
		_apply_action()
		return
	# Locked: follow the same pigeon through fight aftermath. If its ID has
	# left the world, hold the last known position; never switch subjects.
	if _action_locked_id >= 0:
		var pos: Vector3 = swarm.get_pigeon_position(_action_locked_id)
		if pos != Vector3.ZERO:
			_action_subject_pos = pos
	# Keep the locked pigeon on-screen through high-speed ragdoll knockback.
	# Snapshot interpolation already smooths its rendered transform; an extra
	# camera lag lets the subject escape the frame and leaves empty pavement.
	_action_smoothed = _action_subject_pos
	_apply_action()

func _apply_action() -> void:
	focus_cam.global_position = _action_smoothed + ACTION_OFFSET
	focus_cam.look_at(_action_smoothed)

# --- legacy empty-mode behavior -------------------------------------------

func _legacy_process(delta: float) -> void:
	if variant_focus >= 0 and focus_cam != null:
		_legacy_update_focus(delta)
	if use_orbit and orbit_cam != null:
		orbit_angle += delta * 0.11
		orbit_cam.position = Vector3(sin(orbit_angle) * 14.0, 18.0, cos(orbit_angle) * 14.0)
		orbit_cam.look_at(Vector3(0, 1.0, 0))

func _legacy_condition_met() -> bool:
	return _legacy_observation_point() != Vector3.ZERO

func _legacy_observation_point() -> Vector3:
	if variant_focus < 0:
		return Vector3.ZERO
	if require_fighting:
		if swarm.get_variant_state_count(variant_focus, FIGHTING) > 0:
			return swarm.get_variant_state_position(variant_focus, FIGHTING)
		return Vector3.ZERO
	if swarm.get_variant_count(variant_focus) > 0:
		return swarm.get_variant_centroid(variant_focus)
	return Vector3.ZERO

func _legacy_update_focus(delta: float) -> void:
	var obs: Vector3 = _legacy_observation_point()
	var has_target: bool = obs != Vector3.ZERO
	if not has_target:
		_focus_had_target = false
		return
	if not _focus_had_target:
		_focus_pos = obs
	else:
		_focus_pos = _focus_pos.lerp(obs, minf(1.0, delta * 4.0))
	_focus_had_target = true
	focus_cam.global_position = _focus_pos + Vector3(0.0, 4.5, 5.5)
	focus_cam.look_at(_focus_pos)
