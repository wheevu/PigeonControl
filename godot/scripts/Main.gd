extends Node3D

# Builds the entire 3D world in code. Godot only WITNESSES the simulation;
# Julia streams reality over UDP and we render it.
#
# 2.5D style: the environment is billboarded pixel-art cards (Kenney, CC0)
# facing the camera on a fixed vertical axis, each grounded by a soft blob
# shadow. The pigeons themselves stay 3D.

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

# ----- helpers -----

# A billboarded pixel-art card whose feet sit at `base` (y is usually 0).
func _sprite(path: String, base: Vector3, px: float) -> Sprite3D:
	var t: Texture2D = load(path)
	var s: Sprite3D = Sprite3D.new()
	s.texture = t
	s.pixel_size = px
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var h: float = float(t.get_height()) * px
	s.position = Vector3(base.x, base.y + h * 0.5, base.z)
	add_child(s)
	return s

# A soft contact shadow so billboards read as standing on the plaza.
func _blob(base: Vector3, width_m: float) -> void:
	var s: Sprite3D = Sprite3D.new()
	s.texture = load("res://assets/2d/shadow.png")
	s.pixel_size = width_m / 64.0
	s.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	s.rotation_degrees.x = -90
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.position = Vector3(base.x, base.y + 0.02, base.z)
	add_child(s)

# ----- static world -----

func _build_lighting() -> void:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-48, -32, 0)
	light.light_color = Color(1.0, 0.93, 0.82)
	light.light_energy = 1.25
	light.shadow_enabled = false   # top-down blob decals carry the shadows
	add_child(light)

func _build_environment() -> void:
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.84, 0.84, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.80, 0.80, 0.79)
	env.ambient_light_energy = 1.15
	env.fog_enabled = false
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
	plane.size = Vector2(1000, 1000)
	ground.mesh = plane
	# PlaneMesh is already horizontal (XZ), facing +Y; no rotation needed.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.84, 0.84, 0.82)
	ground.material_override = mat
	add_child(ground)

func _build_props() -> void:
	# Centerpiece angel statue.
	_sprite("res://assets/2d/statue.png", Vector3(0, 0, -2.5), 0.018)
	_blob(Vector3(0, 0, -2.5), 2.2)

	# Two benches flanking the walkway.
	_sprite("res://assets/2d/bench.png", Vector3(-6, 0, -4), 0.024)
	_blob(Vector3(-6, 0, -4), 2.4)
	_sprite("res://assets/2d/bench.png", Vector3(6, 0, -4), 0.024)
	_blob(Vector3(6, 0, -4), 2.4)

	# Fountain removed: its billboard filled the frame at the orbit's closest
	# approach, so the plaza goes without one for now.

	# Flower beds around the fountain.
	for i in 15:
		var ang: float = float(i) / 15.0 * TAU
		var fx: float = 6.0 + cos(ang) * 3.2
		var fz: float = 6.0 + sin(ang) * 3.2
		var petal: String = ["flower_red", "flower_pink", "flower_yellow"][i % 3]
		_sprite("res://assets/2d/%s.png" % petal, Vector3(fx, 0, fz), 0.05)
		_blob(Vector3(fx, 0, fz), 0.9)

	# Birdhouses on poles near the statue.
	_pole(Vector3(-4, 0, 1), 1.9, 0.05)
	_sprite("res://assets/2d/birdhouse.png", Vector3(-4, 1.9, 1), 0.03)
	_pole(Vector3(4, 0, 1), 1.9, 0.05)
	_sprite("res://assets/2d/birdhouse.png", Vector3(4, 1.9, 1), 0.03)

func _build_trees() -> void:
	# Ring of billboarded trees around the perimeter.
	var trees: Array[Dictionary] = [
		{"p": Vector3(-21, 0, -13), "t": "tree1", "px": 0.05},
		{"p": Vector3(19, 0, -18),  "t": "tree5", "px": 0.046},
		{"p": Vector3(-16, 0, 17),  "t": "tree2", "px": 0.052},
		{"p": Vector3(22, 0, 12),   "t": "tree1", "px": 0.044},
		{"p": Vector3(-3, 0, 22),   "t": "tree5", "px": 0.05},
		{"p": Vector3(15, 0, -7),   "t": "tree2", "px": 0.048},
	]
	for tree: Dictionary in trees:
		_sprite("res://assets/2d/%s.png" % tree["t"], tree["p"], tree["px"])
		_blob(tree["p"], 5.5)

	# Low bushes hedging the plaza.
	var bushes: Array[Vector3] = [Vector3(-2, 0, 6), Vector3(9, 0, -2), Vector3(-9, 0, 5), Vector3(2, 0, 12)]
	var names: Array[String] = ["bush1", "bush2", "bush3"]
	for i in bushes.size():
		_sprite("res://assets/2d/%s.png" % names[i % names.size()], bushes[i], 0.05)
		_blob(bushes[i], 1.6)

func _pole(base: Vector3, h: float, r: float) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = h
	mi.mesh = cyl
	mi.position = base + Vector3(0, h * 0.5, 0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.40, 0.32, 0.24)
	mat.roughness = 0.9
	mi.material_override = mat
	add_child(mi)

func _fountain(base: Vector3, px: float) -> void:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.add_animation("water")
	frames.set_animation_speed("water", 8.0)
	frames.set_animation_loop("water", true)
	for i in 4:
		frames.add_frame("water", load("res://assets/2d/fountain_%d.png" % (i + 1)))
	var a: AnimatedSprite3D = AnimatedSprite3D.new()
	a.sprite_frames = frames
	a.animation = &"water"
	a.play()
	a.pixel_size = px
	a.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	a.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	a.position = Vector3(base.x, base.y + 96.0 * px * 0.5, base.z)
	add_child(a)
	_blob(base, maxf(1.4, 64.0 * px))

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
