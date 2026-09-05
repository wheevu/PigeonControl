extends Node
class_name CameraDirector

# Four modes over Julia-owned targets only. Never decides pigeon behavior.
# 1 FREECAM (default, FreeCam drives), 2 FOLLOW fight, 3 CINEMATIC orbit, 4 SECURITY corners.

var mode: int = 1
var camera: Camera3D
var swarm: Node3D
var _orbit: float = 0.0
var _sec_index: int = 0
var _sec_timer: float = 0.0
var _corners: Array = [
	Vector3(28, 26, 28), Vector3(-28, 26, 28),
	Vector3(-28, 26, -28), Vector3(28, 26, -28),
]

func setup(cam: Camera3D, s: Node3D) -> void:
	camera = cam
	swarm = s

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: set_mode(1)
			KEY_2: set_mode(2)
			KEY_3: set_mode(3)
			KEY_4: set_mode(4)

func set_mode(m: int) -> void:
	mode = clampi(m, 1, 4)

func mode_name() -> String:
	match mode:
		1: return "FREECAM"
		2: return "FOLLOW"
		3: return "CINEMATIC"
		4: return "SECURITY"
	return "FREECAM"

func _process(delta: float) -> void:
	if mode == 1 or swarm == null or camera == null:
		return
	if mode == 2:
		_follow_tick(delta)
	elif mode == 3:
		_orbit += delta * 0.12
		var r: float = 34.0
		camera.global_position = Vector3(cos(_orbit) * r, 20.0, sin(_orbit) * r)
		camera.look_at(Vector3(0, 2, 0))
	elif mode == 4:
		_sec_timer += delta
		if _sec_timer > 8.0:
			_sec_timer = 0.0
			_sec_index = (_sec_index + 1) % _corners.size()
		camera.global_position = _corners[_sec_index]
		camera.look_at(Vector3(0, 1, 0))

func _follow_tick(_delta: float) -> void:
	# Lowest-ID fighting Bruiser is the most readable brawl; fall back to any
	# fighter, then to the Common centroid so the frame never goes empty.
	var target: Vector3 = Vector3.ZERO
	if swarm.has_method("get_variant_state_position"):
		target = swarm.get_variant_state_position(3, 6)
	if target.is_equal_approx(Vector3.ZERO) and swarm.has_method("get_variant_state_position"):
		for v in [0, 1, 2, 3]:
			target = swarm.get_variant_state_position(v, 6)
			if not target.is_equal_approx(Vector3.ZERO):
				break
	if target.is_equal_approx(Vector3.ZERO) and swarm.has_method("get_variant_centroid"):
		target = swarm.get_variant_centroid(0)
	if target.is_equal_approx(Vector3.ZERO):
		target = Vector3.ZERO
	var want: Vector3 = target + Vector3(6, 5, 6)
	camera.global_position = camera.global_position.lerp(want, 0.04)
	camera.look_at(target + Vector3(0, 1, 0))
