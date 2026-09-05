extends Node3D
class_name SkyRig

# Follows Julia's env block only. Drives the existing Ambience sun and fog.
# Sun level 1.0 is midday, 0.22 is latched dusk after KILL_THE_SUN.

var _sun: DirectionalLight3D
var _env: WorldEnvironment
var _base_energy: float = 1.15
var _base_color: Color = Color(1.0, 0.93, 0.82)

func build() -> void:
	# Resolved lazily on first apply since Ambience builds before us.
	pass

func apply_env(env: Dictionary) -> void:
	if env.is_empty():
		return
	if _sun == null:
		_sun = get_node_or_null("../Ambience/Sun") as DirectionalLight3D
		_env = get_node_or_null("../Ambience/WorldEnv") as WorldEnvironment
	if _sun != null:
		var level: float = clampf(float(env.get("sun", 1.0)), 0.0, 1.0)
		_sun.light_energy = _base_energy * lerpf(0.35, 1.0, level)
		_sun.light_color = _base_color.lerp(Color(1.0, 0.45, 0.25), 1.0 - level)
		_sun.rotation_degrees.x = lerpf(-18.0, -48.0, level)
	if _env != null and _env.environment != null:
		var level2: float = clampf(float(env.get("sun", 1.0)), 0.0, 1.0)
		_env.environment.background_color = Color(0.55, 0.68, 0.82).lerp(Color(0.18, 0.12, 0.22), 1.0 - level2)
		_env.environment.ambient_light_energy = lerpf(0.25, 0.55, level2)
