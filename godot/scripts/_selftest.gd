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

	# Pigeon 2 — variant 3 (Bruiser) in FIGHTING (6) with explicit ragdoll
	# pitch/roll so the parser exercises a four-archetype + fighting fixture.
	put_u32(b, 103)
	put_f32(b, 10.0); put_f32(b, 1.0); put_f32(b, -10.0)
	put_f32(b, 3.14); put_f32(b, 0.5); put_f32(b, -0.4)
	b.append(6)    # FIGHTING
	b.append(3)    # variant 3 Bruiser
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

# Recursively count nodes (detached host, so SceneTree group APIs are unsafe)
# that belong to the given group. Used for PlazaMap prop/group assertions.
func _count_group(node: Node, group: String) -> int:
	var count := 0
	if node.is_in_group(group):
		count += 1
	for child in node.get_children():
		count += _count_group(child, group)
	return count

# A visible weapon uses an identity basis at a real world height (never parked
# at HIDDEN_Y). A hidden weapon is either zero-scaled (det ~ 0) or parked at y=-1000.
func _weapon_visible(t: Transform3D) -> bool:
	var det: float = t.basis.determinant()
	return det > 0.5 and t.origin.y > -900.0

func _weapon_hidden(t: Transform3D) -> bool:
	var det: float = t.basis.determinant()
	return det < 0.001 or t.origin.y <= -900.0

# Shared structural check: named MultiMeshInstance3D child with a real mesh
# and zero initially visible instances. Prints the failure and returns null.
func _require_multimesh(root: Node, name: String) -> Node:
	var n = root.find_child(name, true, false)
	if n == null or not (n is MultiMeshInstance3D):
		print("fail: missing MultiMesh '%s'" % name)
		return null
	if n.multimesh == null or n.multimesh.mesh == null:
		print("fail: MultiMesh '%s' has null mesh" % name)
		return null
	if n.multimesh.visible_instance_count != 0:
		print("fail: MultiMesh '%s' initial visible count != 0" % name)
		return null
	return n

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
	if p2.state != 6 or p2.variant != 3:
		print("fail: p2 state/variant %d/%d (expected 6/3 FIGHTING Bruiser)" % [p2.state, p2.variant])
		return false
	if abs(p2.pitch - 0.5) > 0.0001:
		print("fail: p2.pitch %f != 0.5 (FIGHTING ragdoll fixture)" % p2.pitch)
		return false
	if abs(p2.roll - -0.4) > 0.0001:
		print("fail: p2.roll %f != -0.4 (FIGHTING ragdoll fixture)" % p2.roll)
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

	# Regression: PlazaMap contract. Build on a detached Node3D host (never
	# added to the SceneTree) so Main._ready() and the UDP receiver never start.
	# Representative authored Tiny Treats GLTF assets (not every copied file).
	var REQUIRED_ASSETS := [
		"res://assets/tiny_treats/pretty_park/gltf/fountain.gltf",
		"res://assets/tiny_treats/pretty_park/gltf/bench.gltf",
		"res://assets/tiny_treats/pretty_park/gltf/tree.gltf",
		"res://assets/tiny_treats/pretty_park/gltf/bush.gltf",
		"res://assets/tiny_treats/homely_house/gltf/house.gltf",
		"res://assets/tiny_treats/homely_house/gltf/mailbox.gltf",
		"res://assets/tiny_treats/homely_house/gltf/fence_straight_long.gltf",
	]
	for asset_path in REQUIRED_ASSETS:
		if not ResourceLoader.exists(asset_path):
			print("fail: PlazaMap asset missing - %s" % asset_path)
			return false

	var PlazaMapScript = load("res://scripts/PlazaMap.gd")
	if PlazaMapScript == null:
		print("fail: could not load res://scripts/PlazaMap.gd")
		return false

	var map_host := Node3D.new()
	map_host.set_script(PlazaMapScript)
	map_host.build()

	var required_nodes := [
		"OuterGround", "PlazaSurface", "FountainCourt",
		"NorthPath", "SouthPath", "EastPath", "WestPath",
	]
	for rn in required_nodes:
		if map_host.find_child(rn, true, false) == null:
			print("fail: PlazaMap.build() produced no '%s' child" % rn)
			map_host.free()
			return false

	# Ground planes must be horizontal: a MeshInstance3D whose mesh is a
	# FACE_Y PlaneMesh, whose transformed normal stays aligned to world +Y.
	for plane_name in ["OuterGround", "PlazaSurface"]:
		var pn = map_host.find_child(plane_name, true, false)
		if not (pn is MeshInstance3D):
			print("fail: %s is not a MeshInstance3D (got %s)"
					% [plane_name, pn.get_class()])
			map_host.free()
			return false
		if not (pn.mesh is PlaneMesh):
			var mesh_cls: String = "null" if pn.mesh == null else pn.mesh.get_class()
			print("fail: %s.mesh is not a PlaneMesh (got %s)" % [plane_name, mesh_cls])
			map_host.free()
			return false
		var pm := pn.mesh as PlaneMesh
		if pm.orientation != PlaneMesh.FACE_Y:
			print("fail: %s PlaneMesh does not face +Y" % plane_name)
			map_host.free()
			return false
		var world_normal: Vector3 = pn.transform.basis * Vector3.UP
		var align: float = world_normal.dot(Vector3(0, 1, 0))
		if align < 0.999:
			print("fail: %s is not horizontal - local face normal maps to %s (dot with world +Y = %f, expected > 0.999)" % [plane_name, world_normal, align])
			map_host.free()
			return false

	var prop_count: int = _count_group(map_host, "creative_prop")
	if prop_count < 10:
		print("fail: creative_prop count %d < 10" % prop_count)
		map_host.free()
		return false
	var city_prop_count: int = _count_group(map_host, "city_prop")
	if city_prop_count < 5:
		print("fail: city_prop count %d < 5" % city_prop_count)
		map_host.free()
		return false

	# At least one authored house and representative authored park props must
	# be instantiated (identified by their source scene path).
	var found_house := false
	var found_park_props := 0
	var stack: Array = [map_host]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var sp := str(n.get("scene_file_path"))
		if sp.contains("homely_house/gltf/house"):
			found_house = true
		elif sp.contains("pretty_park"):
			found_park_props += 1
		for child in n.get_children():
			stack.append(child)
	if not found_house:
		print("fail: PlazaMap did not instantiate an authored house from homely_house")
		map_host.free()
		return false
	if found_park_props < 3:
		print("fail: PlazaMap instantiated only %d authored park props (< 3)" % found_park_props)
		map_host.free()
		return false

	# build() must be idempotent: a second call must not change prop count.
	map_host.build()
	var prop_count2: int = _count_group(map_host, "creative_prop")
	if prop_count2 != prop_count:
		print("fail: PlazaMap.build() not idempotent - creative_prop %d after second build != %d" % [prop_count2, prop_count])
		map_host.free()
		return false

	# Regression: CityBackdrop contract. The city framing (road ring, skyline,
	# street furniture) must exist. Old creative PNG assets are gone; the
	# backdrop is authored geometry.
	var city := map_host.find_child("CityBackdrop", true, false)
	if city == null:
		print("fail: PlazaMap.build() produced no 'CityBackdrop' child")
		map_host.free()
		return false

	# Representative road/city elements (semantic, not every decorative node).
	var required_city_nodes := [
		"RoadNorth", "RoadSouth", "RoadEast", "RoadWest",
		"WalkNorth", "CurbNorth", "LaneNorth",
		"CityBuilding0",
	]
	for rn in required_city_nodes:
		if map_host.find_child(rn, true, false) == null:
			print("fail: CityBackdrop produced no '%s' child" % rn)
			map_host.free()
			return false

	map_host.free()

	# FreeCam must keep its initial downward plaza view when mouse-look starts.
	var FreeCamScript = load("res://scripts/FreeCam.gd")
	if FreeCamScript == null:
		print("fail: could not load res://scripts/FreeCam.gd")
		return false
	var camera := Camera3D.new()
	camera.position = Vector3(0, 30, 34)
	camera.set_script(FreeCamScript)
	camera._ready()
	var camera_forward: Vector3 = -camera.transform.basis.z.normalized()
	var toward_origin: Vector3 = (Vector3.ZERO - camera.position).normalized()
	if camera_forward.dot(toward_origin) < 0.999:
		print("fail: FreeCam initial view does not point toward the plaza")
		camera.free()
		return false
	camera.free()

	# Regression: Swarm archetype + weapon contract. Build a detached Swarm
	# host (never added to the SceneTree) and drive it with a parsed dict. This
	# exercises variant grouping, FIGHTING weapon visibility, and the unknown
	# variant fallback without any viewport, timer, or network.
	var SwarmScript = load("res://scripts/Swarm.gd")
	if SwarmScript == null:
		print("fail: could not load res://scripts/Swarm.gd")
		return false

	# Required archetype resources must exist for all four types.
	for path in Swarm.PIGEON_MESH_PATHS:
		if not ResourceLoader.exists(path):
			print("fail: pigeon mesh missing - %s" % path)
			return false
	for path in Swarm.WEAPON_TEX_PATHS:
		if not ResourceLoader.exists(path):
			print("fail: weapon texture missing - %s" % path)
			return false

	var swarm := Node3D.new()
	swarm.set_script(SwarmScript)
	swarm.setup(8)

	var EXPECTED_PIGEON_NODES := ["PigeonsCommon", "PigeonsGoblin", "PigeonsScout", "PigeonsBruiser"]
	var EXPECTED_WEAPON_NODES := ["WeaponsSword", "WeaponsHammer", "WeaponsWand", "WeaponsBomb"]

	# FX/overlay MultiMeshes added by the visual contract: shadows, fight
	# impacts, fight emotes, per-weapon backplates, plus sim-owned event pools
	# (feathers, dust, fighter trails).
	var EXPECTED_FX_NODES := [
		"PigeonShadows", "ImpactBursts", "FightEmotes",
		"WeaponsSwordBackplate", "WeaponsHammerBackplate",
		"WeaponsWandBackplate", "WeaponsBombBackplate",
		"FeatherPuffs", "DustPuffs", "FighterTrails",
	]

	for kt in 4:
		if _require_multimesh(swarm, EXPECTED_PIGEON_NODES[kt]) == null:
			swarm.free()
			return false
		if _require_multimesh(swarm, EXPECTED_WEAPON_NODES[kt]) == null:
			swarm.free()
			return false
	for fx_name in EXPECTED_FX_NODES:
		if _require_multimesh(swarm, fx_name) == null:
			swarm.free()
			return false

	# Feed a small parsed dictionary: all four variants plus one unknown, with
	# the Bruiser in FIGHTING and the unknown also marked FIGHTING (its weapon
	# must stay hidden via the fallback path).
	var swarm_parsed := {
		"pigeons": [
			{"id": 1, "variant": 0, "state": 0, "x": 1.0, "y": 0.0, "z": 1.0, "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "flap_phase": 0.0},
			{"id": 2, "variant": 1, "state": 0, "x": 2.0, "y": 0.0, "z": 2.0, "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "flap_phase": 0.0},
			{"id": 3, "variant": 2, "state": 0, "x": 3.0, "y": 0.0, "z": 3.0, "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "flap_phase": 0.0},
			{"id": 4, "variant": 3, "state": 6, "x": 4.0, "y": 0.0, "z": 4.0, "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "flap_phase": 0.25},
			{"id": 5, "variant": 99, "state": 6, "x": 5.0, "y": 0.0, "z": 5.0, "pitch": 0.0, "yaw": 0.0, "roll": 0.0, "flap_phase": 0.0},
		],
		"foods": [],
		"tick": 1,
	}
	swarm.update_from_parsed(swarm_parsed)

	# Per-type counts after grouping by valid variant (unknown -> Common).
	var expect_counts := [2, 1, 1, 1]
	for ct in 4:
		if swarm.type_count[ct] != expect_counts[ct]:
			print("fail: Swarm type_count[%d]=%d expected %d" % [ct, swarm.type_count[ct], expect_counts[ct]])
			swarm.free()
			return false

	# Unknown variant must be grouped into Common (type 0) by id.
	if not (5 in swarm.last_id[0]):
		print("fail: unknown variant did not fall back into Common group (last_id[0]=%s)" % swarm.last_id[0])
		swarm.free()
		return false

	# Advance rendering deterministically (no real frame/timer): push alpha to 1.
	swarm._process(0.10)
	swarm._process(0.10)

	# Every slot's weapon must match its visibility contract:
	#   FIGHTING && !unknown -> visible; everything else -> hidden.
	# We read the authoritative transform from the production _weapon_transform
	# path (pure GDScript) rather than MultiMesh.get_instance_transform, which
	# round-trips through the rendering server and returns identity headless.
	for vt in 4:
		for i in swarm.type_count[vt]:
			var st: int = swarm.slot_state[vt][i]
			var unkn: bool = swarm.slot_unkn[vt][i]
			var wt: Transform3D = swarm._weapon_transform(vt, i, swarm.rend_t[vt][i], false)
			if st == 6 and not unkn:
				if not _weapon_visible(wt):
					print("fail: FIGHTING type %d slot %d weapon not visible (det/y=%f/%f)"
							% [vt, i, wt.basis.determinant(), wt.origin.y])
					swarm.free()
					return false
			else:
				if not _weapon_hidden(wt):
					print("fail: non-fighting/unknown type %d slot %d weapon not hidden (det/y=%f/%f)"
							% [vt, i, wt.basis.determinant(), wt.origin.y])
					swarm.free()
					return false

	# Explicit unknown check: the variant-99 pigeon occupies type 0 slot 1 and
	# must never show a weapon even though it is marked FIGHTING.
	var unkn_w: Transform3D = swarm._weapon_transform(0, 1, swarm.rend_t[0][1], false)
	if not _weapon_hidden(unkn_w):
		print("fail: unknown-variant weapon is visible (should stay hidden)")
		swarm.free()
		return false

	# Focused FX contract. Shared impact/emote pools carry one slot per
	# rendered pigeon; Swarm writes hidden transforms for non-fighting slots
	# at update time (pooled instance transforms are not readable headless),
	# so we verify the production pure helpers plus the pool wiring:
	#   - FIGHTING known-variant slots produce visible impact/emote/backplate
	#     transforms from the same helpers Swarm calls.
	#   - The backplate variant of _weapon_transform stays gated (hidden for
	#     non-fighting/unknown) since it gates internally.
	#   - ImpactBursts/FightEmotes visible_instance_count equals the rendered
	#     pigeon total.
	var fx_i := 0
	for vt in 4:
		for i in swarm.type_count[vt]:
			var st: int = swarm.slot_state[vt][i]
			var unkn2: bool = swarm.slot_unkn[vt][i]
			var bird: Transform3D = swarm.rend_t[vt][i]
			if st == 6 and not unkn2:
				# Impact pulses its scale, so a strict det threshold would be
				# flaky; assert "not hidden" (real position, non-zero basis).
				var ixt: Transform3D = swarm._impact_transform(vt, i, bird)
				if _weapon_hidden(ixt):
					print("fail: FIGHTING type %d slot %d impact transform not visible" % [vt, i])
					swarm.free()
					return false
				if not _weapon_visible(swarm._emote_transform(vt, i, bird)):
					print("fail: FIGHTING type %d slot %d emote transform not visible" % [vt, i])
					swarm.free()
					return false
				if not _weapon_visible(swarm._weapon_transform(vt, i, bird, true)):
					print("fail: FIGHTING type %d slot %d backplate transform not visible" % [vt, i])
					swarm.free()
					return false
			else:
				if not _weapon_hidden(swarm._weapon_transform(vt, i, bird, true)):
					print("fail: non-fighting/unknown type %d slot %d backplate transform not hidden" % [vt, i])
					swarm.free()
					return false
			fx_i += 1

	var impact_mm := swarm.find_child("ImpactBursts", true, false) as MultiMeshInstance3D
	var emote_mm := swarm.find_child("FightEmotes", true, false) as MultiMeshInstance3D
	if impact_mm == null or emote_mm == null or impact_mm.multimesh == null or emote_mm.multimesh == null:
		print("fail: shared FX pools missing")
		swarm.free()
		return false
	if impact_mm.multimesh.visible_instance_count != fx_i or emote_mm.multimesh.visible_instance_count != fx_i:
		print("fail: shared FX pool counts %d/%d != rendered total %d"
				% [impact_mm.multimesh.visible_instance_count, emote_mm.multimesh.visible_instance_count, fx_i])
		swarm.free()
		return false

	# Helper lookup contract: known FIGHTING Bruiser resolves to its id and
	# position; absent variant/state -> -1; unknown id -> Vector3.ZERO.
	if not swarm.has_method("get_variant_state_subject_id") or not swarm.has_method("get_pigeon_position") or not swarm.has_method("is_pigeon_rendered"):
		print("fail: Swarm is missing an action-capture lookup helper")
		swarm.free()
		return false
	var resolved_id: int = swarm.get_variant_state_subject_id(3, 6)
	if resolved_id != 4:
		print("fail: get_variant_state_subject_id(3, 6) = %d, expected 4" % resolved_id)
		swarm.free()
		return false
	var resolved_pos: Vector3 = swarm.get_pigeon_position(resolved_id)
	if not resolved_pos.is_equal_approx(Vector3(4.0, 0.0, 4.0)):
		print("fail: get_pigeon_position(%d) = %s, expected (4, 0, 4)" % [resolved_id, resolved_pos])
		swarm.free()
		return false
	if not swarm.is_pigeon_rendered(resolved_id) or swarm.is_pigeon_rendered(9999):
		print("fail: is_pigeon_rendered did not distinguish rendered/unknown ids")
		swarm.free()
		return false
	if swarm.get_variant_state_subject_id(3, 0) != -1:
		print("fail: absent variant/state should return -1")
		swarm.free()
		return false
	if not swarm.get_pigeon_position(9999).is_equal_approx(Vector3.ZERO):
		print("fail: unknown id should return Vector3.ZERO")
		swarm.free()
		return false

	swarm.free()

	# v2 parses with bank/hunger/amount plus env/threat/stats/fx trailer.
	var v2b: PackedByteArray = _build_v2_packet()
	var v2p: Dictionary = Parser.parse_snapshot(v2b)
	if not v2p.ok:
		print("fail: v2 packet reported ok == false, error=", v2p.error)
		return false
	if v2p.version != 2:
		print("fail: v2 version %d != 2" % v2p.version)
		return false
	if abs(float(v2p.pigeons[0]["bank"]) - 0.25) > 0.0001:
		print("fail: v2 bank not decoded")
		return false
	if abs(float(v2p.foods[0]["amount"]) - 25.0) > 0.0001:
		print("fail: v2 food amount not decoded")
		return false
	if v2p.env.is_empty() or v2p.stats.is_empty() or v2p.fx.size() != 1:
		print("fail: v2 trailer missing (env/stats/fx)")
		return false

	# Unsupported protocol version -> ok == false (must reject before decoding).
	var uv: PackedByteArray = b.duplicate()
	uv[4] = 3
	var up: Dictionary = Parser.parse_snapshot(uv)
	if up.ok:
		print("fail: unsupported version 3 reported ok == true")
		return false
	if up.error == "":
		print("fail: unsupported version 3 produced no error string")
		return false

	return true

func _build_v2_packet() -> PackedByteArray:
	var v2b: PackedByteArray = PackedByteArray()
	put_u32(v2b, 0x50494345)
	v2b.append(2)
	v2b.append(0); v2b.append(0); v2b.append(0)
	put_u32(v2b, 9)
	put_u32(v2b, 1)
	put_u32(v2b, 1)
	# Pigeon 48B: v1 40B plus bank + hunger.
	put_u32(v2b, 7)
	put_f32(v2b, 1.0); put_f32(v2b, 2.0); put_f32(v2b, 3.0)
	put_f32(v2b, 0.0); put_f32(v2b, 0.0); put_f32(v2b, 0.25)
	v2b.append(0); v2b.append(0)
	put_f32(v2b, 0.5); put_f32(v2b, 3.0)
	v2b.append(0); v2b.append(0)
	put_f32(v2b, 0.25); put_f32(v2b, 0.6)
	# Food 20B: v1 plus amount.
	put_u32(v2b, 11)
	put_f32(v2b, 4.0); put_f32(v2b, 0.2); put_f32(v2b, 5.0)
	put_f32(v2b, 25.0)
	# Env 20B.
	put_f32(v2b, 0.8); put_f32(v2b, 10.5)
	put_f32(v2b, 0.5); put_f32(v2b, 0.0); put_f32(v2b, -0.3)
	# Threat 16B active.
	v2b.append(1); v2b.append(0); v2b.append(0); v2b.append(0)
	put_f32(v2b, 2.0); put_f32(v2b, 0.0); put_f32(v2b, 2.0)
	# Stats 16B.
	put_u32(v2b, 1); put_u32(v2b, 2); put_u32(v2b, 3)
	put_f32(v2b, 120.0)
	# One fx record 20B.
	put_u32(v2b, 1)
	put_u32(v2b, 5)
	put_f32(v2b, 1.0); put_f32(v2b, 1.5); put_f32(v2b, 1.0)
	put_f32(v2b, 1.0)
	return v2b
