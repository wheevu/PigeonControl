extends Node3D

# Builds the 3D world in code. Godot only WITNESSES the simulation;
# Julia streams reality over UDP and we render it.
#
# Authored low-poly 3D models frame an open plaza; instanced pigeons and their
# lightweight billboard VFX stay renderer-only. The static map and atmosphere
# live in PlazaMap and PlazaAmbience.

const MAX_PIGEONS: int = 2000

# Observer capture mode: when OBSERVER_MODE=1 the same scene runs with a fixed
# deterministic overview camera, listens on OBSERVER_SNAPSHOT_PORT (default
# 5100), and suppresses the interactive Commander. Authority never moves: Julia
# still streams snapshots and Godot only renders them.
var _observer_mode: bool = false

func _ready() -> void:
	_observer_mode = OS.get_environment("OBSERVER_MODE") == "1"
	_build_ambience()
	_build_camera()
	_build_map()
	_build_swarm()
	_build_receiver()
	_build_sky()
	if not _observer_mode:
		_build_commander()
		_build_director()
		_build_hud()
	if _observer_mode:
		print("PigeonControl observer mode - listening on :%d" % [
			int(OS.get_environment("OBSERVER_SNAPSHOT_PORT")) if OS.get_environment("OBSERVER_SNAPSHOT_PORT") != "" else 5100])
	else:
		print("PigeonControl ready - listening on :5000")

# ----- atmosphere -----

func _build_ambience() -> void:
	var ambience: Node3D = Node3D.new()
	ambience.name = "Ambience"
	ambience.set_script(load("res://scripts/PlazaAmbience.gd"))
	add_child(ambience)
	ambience.build()

# ----- map -----

func _build_map() -> void:
	var plaza: Node3D = Node3D.new()
	plaza.name = "PlazaMap"
	plaza.set_script(load("res://scripts/PlazaMap.gd"))
	add_child(plaza)
	plaza.build()

# ----- camera -----

func _build_camera() -> void:
	if _observer_mode:
		# Fixed deterministic overview camera. No user input; clean frames.
		var camera: Camera3D = Camera3D.new()
		camera.name = "ObserverCam"
		camera.position = Vector3(0, 33, 46)
		camera.fov = 55.0
		add_child(camera)
		camera.look_at(Vector3(0, 1, 0))
		camera.make_current()
		return
	var camera: Camera3D = Camera3D.new()
	camera.name = "FreeCam"
	camera.position = Vector3(0, 30, 34)
	camera.fov = 60.0
	camera.set_script(load("res://scripts/FreeCam.gd"))
	add_child(camera)
	camera.make_current()

# ----- the flock -----

func _build_swarm() -> void:
	var swarm: Node3D = Node3D.new()
	swarm.name = "Swarm"
	swarm.set_script(load("res://scripts/Swarm.gd"))
	add_child(swarm)
	swarm.setup(MAX_PIGEONS)

func _build_receiver() -> void:
	var receiver: Node = Node.new()
	receiver.name = "Receiver"
	receiver.set_script(load("res://scripts/SnapshotReceiver.gd"))
	add_child(receiver)
	var port: int = 5000
	if _observer_mode:
		var raw: String = OS.get_environment("OBSERVER_SNAPSHOT_PORT").strip_edges()
		if raw != "":
			var p: int = int(raw)
			if p >= 1 and p <= 65535:
				port = p
			else:
				push_warning("Main: OBSERVER_SNAPSHOT_PORT out of range, using default 5100")
				port = 5100
		else:
			port = 5100
	receiver.setup(get_node("Swarm"), port)

func _build_commander() -> void:
	var cs: Node = Node.new()
	cs.name = "Commander"
	cs.set_script(load("res://scripts/CommandSender.gd"))
	add_child(cs)
	cs.setup(get_node("FreeCam"), 5001)

func _build_sky() -> void:
	var sky: Node3D = Node3D.new()
	sky.name = "SkyRig"
	sky.set_script(load("res://scripts/SkyRig.gd"))
	add_child(sky)
	sky.build()
	get_node("Receiver").snapshot_applied.connect(_on_snapshot)

func _on_snapshot(_tick: int) -> void:
	var receiver = get_node("Receiver")
	var sky = get_node_or_null("SkyRig")
	if sky != null and receiver.latest_env is Dictionary:
		sky.apply_env(receiver.latest_env)
	# Wire threat marker follows authority, not just the local click.
	var commander = get_node_or_null("Commander")
	if commander != null and commander.has_method("_hud"):
		var threat: Dictionary = receiver.latest_threat
		if not threat.is_empty() and bool(threat.get("active", false)):
			commander.human_marker.global_position = Vector3(float(threat.get("x", 0.0)), 0.0, float(threat.get("z", 0.0)))
			commander.human_marker.visible = true
		elif threat.is_empty() or not bool(threat.get("active", false)):
			# Only auto-hide when the sim says so and the user did not just
			# place a local marker this frame; the next explicit H/C click wins.
			pass

func _build_director() -> void:
	var d: Node = Node.new()
	d.name = "Director"
	d.set_script(load("res://scripts/CameraDirector.gd"))
	add_child(d)
	d.setup(get_node("FreeCam"), get_node("Swarm"))

func _build_hud() -> void:
	var hud: Label = Label.new()
	hud.name = "StatsHud"
	hud.set_script(load("res://scripts/Hud.gd"))
	get_tree().root.add_child.call_deferred(hud)
	hud.setup.call_deferred(get_node("Receiver"), get_node("Swarm"), get_node("Director"))
