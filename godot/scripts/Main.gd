extends Node3D

# Builds the 3D world in code. Godot only WITNESSES the simulation;
# Julia streams reality over UDP and we render it.
#
# Authored low-poly 3D models frame an open plaza; instanced pigeons and their
# lightweight billboard VFX stay renderer-only. The static map and atmosphere
# live in PlazaMap and PlazaAmbience.

const MAX_PIGEONS: int = 2000

func _ready() -> void:
	_build_ambience()
	_build_camera()
	_build_map()
	_build_swarm()
	_build_receiver()
	_build_commander()
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
	receiver.setup(get_node("Swarm"), 5000)

func _build_commander() -> void:
	var cs: Node = Node.new()
	cs.name = "Commander"
	cs.set_script(load("res://scripts/CommandSender.gd"))
	add_child(cs)
	cs.setup(get_node("FreeCam"), 5001)
