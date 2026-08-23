extends Node3D

# Builds the entire 3D world in code. Godot only WITNESSES the simulation;
# Julia streams reality over UDP and we render it.

const MAX_PIGEONS: int = 2000

func _ready() -> void:
	_build_lighting()
	_build_camera()
	_build_ground()
	_build_props()
	_build_swarm()
	_build_receiver()
	_build_commander()
	print("PigeonControl ready — listening on :5000")

func _build_lighting() -> void:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-60, 0, 0)
	light.light_color = Color(1.0, 0.95, 0.85)
	light.light_energy = 1.1
	light.shadow_enabled = true
	add_child(light)

func _build_camera() -> void:
	var camera: Camera3D = Camera3D.new()
	camera.name = "FreeCam"
	camera.position = Vector3(0, 18, 30)
	camera.set_script(load("res://scripts/FreeCam.gd"))
	add_child(camera)
	camera.make_current()

func _build_ground() -> void:
	var ground: MeshInstance3D = MeshInstance3D.new()
	ground.name = "Ground"
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(50, 50)
	ground.mesh = plane
	ground.rotation_degrees.x = -90   # lay flat on y=0
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.5)
	mat.roughness = 0.9
	ground.material_override = mat
	add_child(ground)

func _build_props() -> void:
	_add_box("statue", Vector3(2, 4, 2), Vector3(0, 2, 0), Color(0.72, 0.72, 0.75))
	_add_box("bench1", Vector3(3, 0.5, 1), Vector3(-6, 0.25, -4), Color(0.42, 0.30, 0.20))
	_add_box("bench2", Vector3(3, 0.5, 1), Vector3(6, 0.25, -4), Color(0.42, 0.30, 0.20))
	_add_cylinder("fountain", 2.0, 1.0, Vector3(8, 0.5, 8), Color(0.62, 0.72, 0.82))

func _add_box(name_str: String, size: Vector3, pos: Vector3, col: Color) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = name_str
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.8
	mi.material_override = mat
	add_child(mi)

func _add_cylinder(name_str: String, radius: float, height: float, pos: Vector3, col: Color) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = name_str
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	mi.mesh = cyl
	mi.position = pos
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.6
	mi.material_override = mat
	add_child(mi)

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
