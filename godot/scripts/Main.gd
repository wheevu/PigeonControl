extends Node3D

# Builds the entire 3D world in code. Godot only WITNESSES the simulation;
# Julia streams reality over UDP and we render it.

const MAX_PIGEONS: int = 2000

func _ready() -> void:
	_build_lighting()
	_build_environment()
	_build_camera()
	_build_ground()
	_build_props()
	_build_trees()
	_build_swarm()
	_build_receiver()
	_build_commander()
	print("PigeonControl ready — listening on :5000")

func _build_lighting() -> void:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-48, -32, 0)
	light.light_color = Color(1.0, 0.93, 0.82)
	light.light_energy = 1.25
	light.shadow_enabled = true
	add_child(light)

func _build_environment() -> void:
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.78)
	sky_mat.sky_horizon_color = Color(0.83, 0.85, 0.86)
	sky_mat.ground_bottom_color = Color(0.45, 0.45, 0.43)
	sky_mat.ground_horizon_color = Color(0.80, 0.81, 0.80)
	sky_mat.sun_angle_max = 20.0
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.85, 0.88)
	env.fog_density = 0.006
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env: WorldEnvironment = WorldEnvironment.new()
	world_env.name = "WorldEnv"
	world_env.environment = env
	add_child(world_env)

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
	mat.albedo_color = Color(0.53, 0.52, 0.50)
	mat.roughness = 0.95
	ground.material_override = mat
	add_child(ground)

func _build_props() -> void:
	_add_box("statue", Vector3(2, 4, 2), Vector3(0, 2, 0), Color(0.72, 0.72, 0.75))
	_add_box("bench1", Vector3(3, 0.5, 1), Vector3(-6, 0.25, -4), Color(0.42, 0.30, 0.20))
	_add_box("bench2", Vector3(3, 0.5, 1), Vector3(6, 0.25, -4), Color(0.42, 0.30, 0.20))
	_add_cylinder("fountain", 2.0, 1.0, Vector3(8, 0.5, 8), Color(0.62, 0.72, 0.82))

func _build_trees() -> void:
	for pos: Vector3 in [Vector3(-21, 0, -13), Vector3(19, 0, -18), Vector3(-16, 0, 17),
			Vector3(22, 0, 12), Vector3(-3, 0, 22), Vector3(15, 0, -7)]:
		_add_tree(pos)

func _add_tree(pos: Vector3) -> void:
	var trunk: MeshInstance3D = MeshInstance3D.new()
	var tm: CylinderMesh = CylinderMesh.new()
	tm.top_radius = 0.14
	tm.bottom_radius = 0.22
	tm.height = 2.6
	trunk.mesh = tm
	trunk.position = pos + Vector3(0, 1.3, 0)
	var wood: StandardMaterial3D = StandardMaterial3D.new()
	wood.albedo_color = Color(0.36, 0.26, 0.18)
	wood.roughness = 0.95
	trunk.material_override = wood
	add_child(trunk)
	for offset: Vector3 in [Vector3(0, 3.1, 0), Vector3(0.7, 3.7, 0.3), Vector3(-0.6, 3.5, -0.4)]:
		var canopy: MeshInstance3D = MeshInstance3D.new()
		var cm: SphereMesh = SphereMesh.new()
		cm.radius = 1.4
		cm.height = 2.8
		canopy.mesh = cm
		canopy.position = pos + offset
		var leaf: StandardMaterial3D = StandardMaterial3D.new()
		leaf.albedo_color = Color(0.28, 0.40, 0.22)
		leaf.roughness = 0.9
		canopy.material_override = leaf
		add_child(canopy)

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
