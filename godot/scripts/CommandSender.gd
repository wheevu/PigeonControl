extends Node
class_name CommandSender

# Sends text UDP control commands to the Julia simulation and visualizes a
# "human" threat with a red marker. Camera + control port are injected via
# setup() from Main.gd.

var camera: Camera3D
var ctrl_port: int = 5001
var peer: PacketPeerUDP
var human_marker: Node3D
var hud: Label

# Capture runs suppress the HUD so frames are clean. Normal game HUD is
# unchanged.
func _capture_clean() -> bool:
	return OS.get_environment("CAPTURE_CLEAN") == "1" \
		or OS.get_environment("CAPTURE_MODE").strip_edges() != ""

func setup(cam: Camera3D, port: int) -> void:
	camera = cam
	ctrl_port = port
	peer = PacketPeerUDP.new()
	_build_human_marker()
	if not _capture_clean():
		_build_hud()

func _build_human_marker() -> void:
	if get_tree() == null or get_tree().root == null:
		return
	human_marker = Node3D.new()
	human_marker.name = "HumanMarker"
	human_marker.visible = false
	# Godot 4 has no ConeMesh primitive; a CylinderMesh with a zero top radius
	# is an exact cone. radius -> bottom radius, top_radius -> apex (0).
	var cone: MeshInstance3D = MeshInstance3D.new()
	var m: CylinderMesh = CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = 0.6
	m.height = 2.0
	cone.mesh = m
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.15, 0.1)
	mat.emission = Color(0.45, 0.0, 0.0)
	cone.material_override = mat
	cone.position = Vector3(0, 1.0, 0)
	human_marker.add_child(cone)
	# setup() runs during the parent's _ready, when the tree is busy; a deferred
	# add is required or the marker silently never enters the scene.
	get_tree().root.add_child.call_deferred(human_marker)

func _build_hud() -> void:
	if get_tree() == null or get_tree().root == null:
		return
	hud = Label.new()
	hud.position = Vector2(14, 12)
	hud.add_theme_color_override("font_color", Color(1, 1, 1))
	hud.add_theme_font_override("font", load("res://assets/2d/Kenney_Pixel.ttf"))
	hud.add_theme_font_size_override("font_size", 17)
	get_tree().root.add_child.call_deferred(hud)
	hud.text = "controls: [B] drop bread  [H] spawn human  [C] clear human  [K] kill the sun"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_B: _drop_bread()
			KEY_H: _spawn_human()
			KEY_C: _clear_human()
			KEY_K: _kill_sun()
			_: return

func _ground_point() -> Vector3:
	var vp = get_viewport()
	var center: Vector2 = vp.get_visible_rect().size * 0.5
	var origin: Vector3 = camera.project_ray_origin(center)
	var dir: Vector3 = camera.project_ray_normal(center)
	if abs(dir.y) < 1e-4:
		return Vector3.ZERO
	var t: float = -origin.y / dir.y
	if t < 0.0:
		return Vector3.ZERO
	return origin + dir * t

func _send(cmd: String) -> void:
	peer.set_dest_address("127.0.0.1", ctrl_port)
	var err: int = peer.put_packet(cmd.to_utf8_buffer())
	if err != OK:
		_hud("cmd send error %d" % err)

func _drop_bread() -> void:
	var p: Vector3 = _ground_point()
	var cmd: String = "DROP_BREAD %.2f %.2f %.2f %d" % [p.x, 0.2, p.z, 25]
	_send(cmd)
	_hud("DROP_BREAD @ (%.1f, %.1f)" % [p.x, p.z])

func _spawn_human() -> void:
	var p: Vector3 = _ground_point()
	var cmd: String = "SPAWN_HUMAN %.2f %.2f %.2f" % [p.x, 0.0, p.z]
	_send(cmd)
	human_marker.global_position = Vector3(p.x, 0.0, p.z)
	human_marker.visible = true
	_hud("SPAWN_HUMAN @ (%.1f, %.1f)" % [p.x, p.z])

func _clear_human() -> void:
	_send("CLEAR_HUMAN")
	human_marker.visible = false
	_hud("CLEAR_HUMAN")

func _kill_sun() -> void:
	_send("KILL_THE_SUN")
	_hud("KILL_THE_SUN (no-op)")

func _hud(msg: String) -> void:
	if hud == null:
		return
	hud.text = msg + "\ncontrols: [B] drop bread  [H] spawn human  [C] clear human  [K] kill the sun"
