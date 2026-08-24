extends SceneTree

# Standalone self-test run via:  godot --headless -s res://scripts/_selftest.gd
# Pure logic only — no display, no windowed renderer required.

func _initialize() -> void:
	var ok: bool = _run()
	if ok:
		print("SELFTEST_OK")
		quit(0)
	else:
		print("SELFTEST_FAIL")
		quit(1)

func put_u32(b: PackedByteArray, v: int) -> void:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = false
	sp.put_u32(v)
	b.append_array(sp.data_array)

func put_f32(b: PackedByteArray, v: float) -> void:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = false
	sp.put_float(v)
	b.append_array(sp.data_array)

func _build_packet() -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	put_u32(b, 0x50494345)   # magic "PICE"
	b.append(1)              # version
	b.append(0); b.append(0); b.append(0)   # pad 3
	put_u32(b, 7)            # tick
	put_u32(b, 3)            # pigeons
	put_u32(b, 2)            # foods

	# Pigeon 0
	put_u32(b, 101)
	put_f32(b, 1.5); put_f32(b, 2.5); put_f32(b, 3.5)
	put_f32(b, 0.10); put_f32(b, 0.20); put_f32(b, 0.30)
	b.append(0)    # state FLYING
	b.append(2)    # variant
	put_f32(b, 0.70)   # flap_phase
	put_f32(b, 4.0)    # speed
	b.append(0); b.append(0)   # pad 2

	# Pigeon 1
	put_u32(b, 102)
	put_f32(b, -1.0); put_f32(b, 0.0); put_f32(b, 2.0)
	put_f32(b, 1.57); put_f32(b, -0.1); put_f32(b, 0.0)
	b.append(3)    # FLEEING
	b.append(0)
	put_f32(b, 0.10)
	put_f32(b, 7.5)
	b.append(0); b.append(0)

	# Pigeon 2
	put_u32(b, 103)
	put_f32(b, 10.0); put_f32(b, 1.0); put_f32(b, -10.0)
	put_f32(b, 3.14); put_f32(b, 0.5); put_f32(b, -0.4)
	b.append(2)    # EATING
	b.append(1)
	put_f32(b, 0.0)
	put_f32(b, 0.2)
	b.append(0); b.append(0)

	# Food 0
	put_u32(b, 201)
	put_f32(b, 5.0); put_f32(b, 0.0); put_f32(b, -5.0)
	# Food 1
	put_u32(b, 202)
	put_f32(b, -8.0); put_f32(b, 0.0); put_f32(b, 8.0)

	return b

func _run() -> bool:
	var Parser = load("res://scripts/SnapshotParser.gd")
	var b: PackedByteArray = _build_packet()
	if b.size() != 20 + 3 * 40 + 2 * 16:
		print("fail: unexpected built size %d" % b.size())
		return false

	var parsed: Dictionary = Parser.parse_snapshot(b)
	if not parsed.ok:
		print("fail: parsed.ok == false, error=", parsed.error)
		return false
	if parsed.tick != 7:
		print("fail: tick %d != 7" % parsed.tick)
		return false
	if parsed.pigeons.size() != 3:
		print("fail: pigeon count %d != 3" % parsed.pigeons.size())
		return false
	if parsed.foods.size() != 2:
		print("fail: food count %d != 2" % parsed.foods.size())
		return false

	var p0: Dictionary = parsed.pigeons[0]
	if p0.id != 101:
		print("fail: p0.id %d != 101" % p0.id)
		return false
	if abs(p0.x - 1.5) > 0.0001:
		print("fail: p0.x %f != 1.5" % p0.x)
		return false
	if p0.state != 0 or p0.variant != 2:
		print("fail: p0 state/variant %d/%d" % [p0.state, p0.variant])
		return false
	if abs(p0.speed - 4.0) > 0.0001:
		print("fail: p0.speed %f != 4.0" % p0.speed)
		return false

	var p2: Dictionary = parsed.pigeons[2]
	if abs(p2.yaw - 3.14) > 0.0001:
		print("fail: p2.yaw %f != 3.14" % p2.yaw)
		return false

	var f1: Dictionary = parsed.foods[1]
	if f1.id != 202:
		print("fail: f1.id %d != 202" % f1.id)
		return false
	if abs(f1.z - 8.0) > 0.0001:
		print("fail: f1.z %f != 8.0" % f1.z)
		return false

	# Corrupted magic -> ok == false
	var c: PackedByteArray = b.duplicate()
	c[0] = 0x00
	var cp: Dictionary = Parser.parse_snapshot(c)
	if cp.ok:
		print("fail: corrupted packet reported ok == true")
		return false

	# Truncated payload -> ok == false
	var t: PackedByteArray = b.slice(0, b.size() - 5)
	var tp: Dictionary = Parser.parse_snapshot(t)
	if tp.ok:
		print("fail: truncated packet reported ok == true")
		return false

	# Pad-byte offset / size-mismatch detection
	var extra: PackedByteArray = b.duplicate()
	extra.append(0)
	var ep: Dictionary = Parser.parse_snapshot(extra)
	if ep.ok and ep.error == "":
		print("fail: trailing-byte packet reported no error")
		return false

	# Regression: Main._build_ground() must build a horizontal ground plane.
	# We build it on a detached node (never entering the tree) so _ready() and
	# the UDP receiver are never triggered.
	var MainScript = load("res://scripts/Main.gd")
	if MainScript == null:
		print("fail: could not load res://scripts/Main.gd")
		return false
	var ground_host := Node3D.new()
	ground_host.set_script(MainScript)
	ground_host._build_ground()
	var ground_node = ground_host.get_node_or_null("Ground")
	if ground_node == null:
		print("fail: Main._build_ground() produced no 'Ground' child")
		ground_host.free()
		return false
	if not (ground_node is MeshInstance3D):
		print("fail: Ground child is not a MeshInstance3D (got %s)"
				% ground_node.get_class())
		ground_host.free()
		return false
	if not (ground_node.mesh is PlaneMesh):
		var mesh_cls: String = "null" if ground_node.mesh == null else ground_node.mesh.get_class()
		print("fail: Ground.mesh is not a PlaneMesh (got %s)" % mesh_cls)
		ground_host.free()
		return false
	var ground_plane := ground_node.mesh as PlaneMesh
	if ground_plane.orientation != PlaneMesh.FACE_Y:
		print("fail: Ground PlaneMesh does not face +Y")
		ground_host.free()
		return false
	# FACE_Y is horizontal in local space. Its transformed normal must remain
	# aligned with world +Y so the orbit camera cannot cross a vertical ground.
	var world_normal: Vector3 = ground_node.transform.basis * Vector3.UP
	var align: float = world_normal.dot(Vector3(0, 1, 0))
	if align < 0.999:
		print("fail: Ground is not horizontal — local face normal maps to %s (dot with world +Y = %f, expected > 0.999)" % [world_normal, align])
		ground_host.free()
		return false
	ground_host.free()

	return true
