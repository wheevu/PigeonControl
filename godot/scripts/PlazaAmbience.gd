extends Node3D
class_name PlazaAmbience

# Atmosphere only: daylight, environment, and faint drifting motes.
# The static map and the pigeons live in other scripts.

const MOTE_COUNT: int = 16
const MOTE_BOUND: Vector3 = Vector3(30, 6, 30)   # drift volume (centered on origin)
const MOTE_HALF: Vector3 = MOTE_BOUND * 0.5

var _motes: Array[MeshInstance3D] = []
var _velocities: Array[Vector3] = []
var _phase: Array[float] = []
var _built: bool = false
var _elapsed: float = 0.0


func build() -> void:
	if _built:
		return
	_built = true

	_build_environment()
	_build_sun()
	_build_motes()


func _build_environment() -> void:
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.68, 0.82)   # clean daylight sky blue
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.75, 0.80)
	env.ambient_light_energy = 0.55
	# Subtle depth fog: softens the neighborhood ring without hiding it.
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.78, 0.85)
	env.fog_density = 0.0006
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world_env: WorldEnvironment = WorldEnvironment.new()
	world_env.name = "WorldEnv"
	world_env.environment = env
	add_child(world_env)


func _build_sun() -> void:
	# Warm key light with soft readable shadows for the static low-poly props.
	# Shadow cost is bounded: static map only, pigeons are MultiMesh and cheap.
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 90.0
	sun.shadow_bias = 0.06
	add_child(sun)

	# Cheap cool fill so shadowed faces don't crush. No shadows.
	var fill: DirectionalLight3D = DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(40, 150, 0)
	fill.light_color = Color(0.70, 0.76, 0.85)
	fill.light_energy = 0.30
	fill.shadow_enabled = false
	add_child(fill)


func _build_motes() -> void:
	# Deterministic placement from a fixed-seed RNG (no global state).
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 0x9E3779B1

	var group: Node3D = Node3D.new()
	group.name = "BreezeMotes"
	add_child(group)

	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.95, 0.93, 0.86, 0.32)   # warm, faint, not snow
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false

	for i in MOTE_COUNT:
		var mote: MeshInstance3D = MeshInstance3D.new()
		mote.mesh = sphere
		mote.material_override = mat
		mote.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mote.position = Vector3(
			(rng.randf() - 0.5) * MOTE_BOUND.x,
			rng.randf() * MOTE_BOUND.y,
			(rng.randf() - 0.5) * MOTE_BOUND.z
		)
		mote.add_to_group("ambient_mote")
		group.add_child(mote)
		_motes.append(mote)
		_velocities.append(Vector3(
			(rng.randf() - 0.5) * 0.35,
			rng.randf() * 0.15 + 0.04,
			(rng.randf() - 0.5) * 0.35
		))
		_phase.append(rng.randf() * TAU)


func _process(delta: float) -> void:
	_elapsed += delta
	for i in _motes.size():
		var m: MeshInstance3D = _motes[i]
		m.position += _velocities[i] * delta
		m.position.y += sin(_elapsed + _phase[i]) * 0.15 * delta   # gentle bob

		# Wrap inside the bounded volume so motes never leave the plaza.
		if m.position.x > MOTE_HALF.x:  m.position.x -= MOTE_BOUND.x
		if m.position.x < -MOTE_HALF.x: m.position.x += MOTE_BOUND.x
		if m.position.z > MOTE_HALF.z:  m.position.z -= MOTE_BOUND.z
		if m.position.z < -MOTE_HALF.z: m.position.z += MOTE_BOUND.z
		if m.position.y > MOTE_BOUND.y: m.position.y = 0.0
		if m.position.y < 0.0:          m.position.y = MOTE_BOUND.y
