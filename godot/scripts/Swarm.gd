extends Node3D
class_name Swarm

# Renders up to max_instances pigeons via a single MultiMesh.
# Witnesses positions streamed by Julia; interpolates between snapshots.

var multimesh: MultiMesh
var mesh: Mesh
var max_instances: int = 0
var current_count: int = 0
var prev: Array = []      # Array of Transform3D (last applied)
var target: Array = []    # Array of Transform3D (latest parsed)
var target_alpha: float = 1.0

const LERP_RATE: float = 8.0

func setup(max_n: int) -> void:
	max_instances = max_n
	_load_mesh()

	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.use_custom_data = false
	multimesh.instance_count = max_n

	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mmi.name = "MultiMeshInstance3D"
	mmi.multimesh = multimesh
	add_child(mmi)

	var hidden: Transform3D = _hidden_transform()
	for i in max_n:
		multimesh.set_instance_transform(i, hidden)
		prev.append(hidden)
		target.append(hidden)
	current_count = 0

func _load_mesh() -> void:
	mesh = null
	var res = load("res://assets/pigeon.glb")
	if res != null and res is PackedScene:
		var inst: Node = res.instantiate()
		mesh = _find_mesh(inst)
		inst.queue_free()
	if mesh == null:
		# Fallback: always renders so the vertical slice is never empty.
		var cm: CapsuleMesh = CapsuleMesh.new()
		cm.radius = 0.25
		cm.height = 0.7
		mesh = cm

func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for c in node.get_children():
		var m: Mesh = _find_mesh(c)
		if m != null:
			return m
	return null

func _hidden_transform() -> Transform3D:
	return Transform3D(Basis(), Vector3(0, -1000, 0))

func update_from_parsed(parsed: Dictionary) -> void:
	var pigeons: Array = parsed["pigeons"]
	current_count = mini(pigeons.size(), max_instances)
	target_alpha = 0.0

	var hidden: Transform3D = _hidden_transform()
	for i in current_count:
		var p: Dictionary = pigeons[i]
		var basis: Basis = Basis.from_euler(Vector3(p["pitch"], p["yaw"], p["roll"]))
		var t: Transform3D = Transform3D(basis, Vector3(p["x"], p["y"], p["z"]))
		prev[i] = multimesh.get_instance_transform(i)
		target[i] = t
	for i in range(current_count, max_instances):
		target[i] = hidden

func _process(delta: float) -> void:
	if multimesh == null:
		return
	target_alpha = minf(1.0, target_alpha + delta * LERP_RATE)

	var hidden: Transform3D = _hidden_transform()
	for i in current_count:
		var t: Transform3D = prev[i].interpolate_with(target[i], target_alpha)
		multimesh.set_instance_transform(i, t)
	for i in range(current_count, max_instances):
		multimesh.set_instance_transform(i, hidden)
