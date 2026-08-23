extends Node

# Captures viewport frames of the running renderer to PNGs so the repo can
# ship a real GIF of the simulation. Driven by env vars:
#   CAPTURE_DIR     absolute output directory (must exist)
#   CAPTURE_FRAMES  how many frames to save before quitting
#   CAPTURE_EVERY   save every Nth rendered frame
#   CAPTURE_ORBIT   "1" overrides FreeCam with a slow cinematic orbit camera
# Frame counting starts at the first snapshot that actually contains pigeons,
# so recordings never open on an empty plaza.

var out_dir: String = OS.get_environment("CAPTURE_DIR")
var target: int = int(OS.get_environment("CAPTURE_FRAMES"))
var every: int = maxi(1, int(OS.get_environment("CAPTURE_EVERY")))
var swarm: Node
var orbit_cam: Camera3D
var orbit_angle: float = -0.7
var count: int = 0
var tick: int = 0

func _ready() -> void:
	add_child(load("res://main.tscn").instantiate())
	await get_tree().process_frame
	swarm = get_viewport().find_child("Swarm", true, false)
	if OS.get_environment("CAPTURE_ORBIT") == "1":
		orbit_cam = Camera3D.new()
		orbit_cam.name = "OrbitCam"
		orbit_cam.fov = 55.0
		add_child(orbit_cam)
		orbit_cam.make_current()

func _process(delta: float) -> void:
	if orbit_cam != null:
		orbit_angle += delta * 0.11
		orbit_cam.position = Vector3(sin(orbit_angle) * 26.0, 10.5, cos(orbit_angle) * 26.0)
		orbit_cam.look_at(Vector3(0, 1.2, 0))
	if count >= target:
		return
	if swarm == null or swarm.get("current_count") == null or swarm.current_count == 0:
		return
	tick += 1
	if tick % every != 0:
		return
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/frame_%04d.png" % [out_dir, count])
	count += 1
	if count >= target:
		get_tree().quit()
