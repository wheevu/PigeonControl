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
	if not _observer_mode:
		_build_commander()
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
