extends Camera3D
class_name FreeCam

# Lightweight free-fly camera. Click to capture the mouse, WASD + QE to move,
# Shift to sprint, Esc / click-again to release. Never errors if uncaptured.

var _yaw: float = 0.0
var _pitch: float = 0.0
var _speed: float = 12.0
var _mouse_sens: float = 0.0022

func _ready() -> void:
	look_at_from_position(position, Vector3.ZERO, Vector3.UP)
	# Continue mouse-look from the authored starting view instead of snapping
	# back to a level, zero-angle view on the first frame.
	_pitch = rotation.x
	_yaw = rotation.y

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * _mouse_sens
		_pitch -= event.relative.y * _mouse_sens
		_pitch = clampf(_pitch, -1.55, 1.55)
		_apply_rotation()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _apply_rotation() -> void:
	# YXZ: yaw around Y, then pitch around X. Pigeon-like FPS cam.
	var basis: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	transform.basis = basis

func _process(delta: float) -> void:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	var dir: Vector3 = Vector3()
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_E): dir.y += 1
	if Input.is_key_pressed(KEY_Q): dir.y -= 1
	if dir != Vector3.ZERO:
		dir = dir.normalized()
		var spd: float = _speed * (8.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		global_translate(transform.basis * dir * spd * delta)
