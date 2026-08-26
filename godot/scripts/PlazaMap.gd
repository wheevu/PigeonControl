extends Node3D

# PlazaMap builds a static low-poly city-park plaza for the PigeonControl
# renderer, using CC0 Tiny Treats GLTF assets (see assets/tiny_treats/).
#
# This file renders ONLY a composed static map. It owns no simulation state
# (Julia owns that) and makes no collision bodies, input, networking, or
# simulation decisions. Paving, roads, and curbs are simple shaded geometry;
# focal objects are authored 3D models.
#
# Call build() exactly once. It is idempotent: a second call returns early
# rather than duplicating the map.

class_name PlazaMap

const TT := "res://assets/tiny_treats/"
const ROAD_IN: float = 29.0
const ROAD_OUT: float = 42.0

# Imported-scene cache keyed by "pack/asset". Tiny Treats GLTF+BIN pairs are
# imported by the regular Godot import pipeline, so we load the resulting
# PackedScenes and instantiate them (this preserves scene_file_path).
static var _scene_cache: Dictionary = {}

var _park: Node3D
var _city: Node3D


func build() -> void:
	# Idempotent guard: the plaza surface is the canonical marker node.
	if has_node("PlazaSurface"):
		return

	_build_ground()
	_build_paths()
	_build_court()
	_build_seams()
	_build_corner_beds()

	_park = Node3D.new()
	_park.name = "CreativeProps"
	add_child(_park)

	_build_fountain()
	_build_benches()
	_build_lamps()
	_build_greenery()
	_build_bins()

	_city = Node3D.new()
	_city.name = "CityBackdrop"
	add_child(_city)

	_build_roads(_city)
	_build_houses(_city)
	_build_street_life(_city)


# ----- asset loading -----

# Instantiate a Tiny Treats gltf model from its imported PackedScene, cached
# by path. Returns null (with a pushed error) if loading fails so callers
# never dereference null.
func _model(pack: String, asset: String, display_name: String) -> Node3D:
	var key := pack + "/" + asset
	if not _scene_cache.has(key):
		var res := load(TT + key + ".gltf")
		if res == null or not (res is PackedScene):
			push_error("PlazaMap: cannot load %s" % (TT + key + ".gltf"))
			_scene_cache[key] = null
			return null
		_scene_cache[key] = res
	var packed: PackedScene = _scene_cache[key]
	if packed == null:
		return null
	var inst: Node3D = packed.instantiate()
	inst.name = display_name
	return inst


# Place one model under `parent`, joined to `group`.
func _place(parent: Node3D, pack: String, asset: String, display_name: String,
		group: String, pos: Vector3, yaw_deg: float = 0.0, scale_f: float = 1.0) -> void:
	var m := _model(pack, asset, display_name)
	if m == null:
		return
	m.position = pos
	m.rotation_degrees.y = yaw_deg
	m.scale = Vector3.ONE * scale_f
	parent.add_child(m)
	m.add_to_group(group)


func _park_prop(asset: String, name_: String, pos: Vector3, yaw := 0.0, s := 1.0) -> void:
	_place(_park, "pretty_park/gltf", asset, name_, "creative_prop", pos, yaw, s)


func _city_model(asset_dir: String, asset: String, name_: String,
		pos: Vector3, yaw := 0.0, s := 1.0) -> void:
	_place(_city, asset_dir, asset, name_, "city_prop", pos, yaw, s)


# ----- simple geometry helpers (paving only; props are authored models) -----

func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	return m


func _plane_on(parent: Node3D, name_: String, sx: float, sz: float,
		x: float, z: float, y: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	var p := PlaneMesh.new()
	p.size = Vector2(sx, sz)
	p.orientation = PlaneMesh.FACE_Y
	mi.mesh = p
	mi.material_override = _material(color)
	mi.position = Vector3(x, y, z)
	parent.add_child(mi)
	return mi


func _box_on(parent: Node3D, name_: String, sx: float, sy: float, sz: float,
		pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	var b := BoxMesh.new()
	b.size = Vector3(sx, sy, sz)
	mi.mesh = b
	mi.material_override = _material(color)
	mi.position = pos
	parent.add_child(mi)
	return mi


# ----- static world -----

func _build_ground() -> void:
	_plane_on(self, "OuterGround", 130.0, 130.0, 0.0, 0.0, -0.04, Color(0.42, 0.55, 0.32))
	_plane_on(self, "PlazaSurface", 54.0, 54.0, 0.0, 0.0, 0.0, Color(0.84, 0.78, 0.66))


func _build_paths() -> void:
	# Four axial pedestrian paths from the plaza edge out to the lawn.
	var w: float = 8.0
	var len: float = 33.0
	var mid: float = 27.0 + len * 0.5
	var col: Color = Color(0.77, 0.72, 0.62)
	_plane_on(self, "NorthPath", w, len, 0.0, -mid, -0.02, col)
	_plane_on(self, "SouthPath", w, len, 0.0, mid, -0.02, col)
	_plane_on(self, "EastPath", len, w, mid, 0.0, -0.02, col)
	_plane_on(self, "WestPath", len, w, -mid, 0.0, -0.02, col)


func _build_court() -> void:
	var court := _plane_on(self, "FountainCourt", 16.0, 16.0, 16.0, -14.0, 0.006, Color(0.67, 0.61, 0.53))
	court.position.y = 0.006


func _build_seams() -> void:
	var col: Color = Color(0.63, 0.58, 0.50)
	for z in [-18.0, -9.0, 9.0, 18.0]:
		_box_on(self, "SeamX_%.0f" % z, 54.0, 0.04, 0.5, Vector3(0.0, 0.01, z), col)
	for x in [-18.0, -9.0, 9.0, 18.0]:
		_box_on(self, "SeamZ_%.0f" % x, 0.5, 0.04, 54.0, Vector3(x, 0.01, 0.0), col)


func _build_corner_beds() -> void:
	var col: Color = Color(0.35, 0.48, 0.27)
	var off: float = 22.0
	var corners: Array[Vector3] = [
		Vector3(-off, 0.008, -off), Vector3(off, 0.008, -off),
		Vector3(-off, 0.008, off), Vector3(off, 0.008, off),
	]
	for i in corners.size():
		_plane_on(self, "Bed%d" % i, 10.0, 10.0, corners[i].x, corners[i].z, 0.008, col)


# ----- park props (creative_prop group) -----

func _build_fountain() -> void:
	_park_prop("fountain", "Fountain", Vector3(16.0, 0.0, -14.0))
	var fountain := _park.get_node_or_null("Fountain")
	if fountain != null:
		fountain.add_to_group("plaza_fountain")


func _build_benches() -> void:
	# Conversational clusters: benches face each other across a small gap.
	# The center crosshair lanes stay clear.
	var clusters: Array = [
		# [pos_a, yaw_a, pos_b, yaw_b]
		[Vector3(-11.5, 0, -7.0), 25.0, Vector3(-8.5, 0, -10.0), -155.0],
		[Vector3(-12.0, 0, 9.0), 90.0, Vector3(-12.0, 0, 13.0), -90.0],
		[Vector3(11.0, 0, -4.0), -30.0, Vector3(14.0, 0, -6.5), 150.0],
		[Vector3(3.0, 0, 15.0), 180.0, Vector3(-1.0, 0, 15.0), 180.0],
		[Vector3(-20.0, 0, 20.0), 45.0, Vector3(-23.0, 0, 17.5), -135.0],
	]
	for i in clusters.size():
		var c: Array = clusters[i]
		_park_prop("bench", "Bench%d" % (i * 2), c[0], c[1])
		_park_prop("bench", "Bench%d" % (i * 2 + 1), c[2], c[3])


func _build_lamps() -> void:
	var spots: Array[Vector3] = [
		Vector3(-18, 0, -18), Vector3(19, 0, -19),
		Vector3(-19, 0, 19), Vector3(19, 0, 19),
		Vector3(0, 0, -21), Vector3(21, 0, 2), Vector3(-21, 0, -3),
	]
	for i in spots.size():
		_park_prop("street_lantern", "Lamp%d" % i, spots[i])
		# Warm bulbs on the four inner corners only; keep light count cheap.
		if i < 4:
			var light := OmniLight3D.new()
			light.name = "LampLight%d" % i
			light.position = spots[i] + Vector3(0.0, 3.6, 0.0)
			light.light_color = Color(1.0, 0.82, 0.52)
			light.light_energy = 0.6
			light.omni_range = 8.0
			light.shadow_enabled = false
			_park.add_child(light)


func _build_greenery() -> void:
	# Low hedges framing two sides of the fountain court.
	for i in 3:
		_park_prop("hedge_straight", "HedgeW%d" % i, Vector3(6.5, 0, -20.0 + i * 2.6), 90.0, 0.8)
	for i in 2:
		_park_prop("hedge_straight", "HedgeS%d" % i, Vector3(10.5 + i * 2.6, 0, -5.5), 0.0, 0.8)

	# Bushes and flowers tucked into beds and along edges; irregular spacing.
	var bushes: Array = [
		[Vector3(-22, 0, -22), 1.0], [Vector3(22, 0, -22), 1.3],
		[Vector3(-22, 0, 22), 1.15], [Vector3(23, 0, 21), 0.9],
		[Vector3(-14, 0, 22), 1.1], [Vector3(15, 0, 22), 0.95],
		[Vector3(-24, 0, 4), 1.2], [Vector3(24, 0, -8), 1.0],
		[Vector3(8, 0, -22), 1.05],
	]
	for i in bushes.size():
		var b: Array = bushes[i]
		_park_prop("bush_large" if i % 2 == 0 else "bush",
				"Bush%d" % i, b[0], float(i) * 37.0, b[1])

	var flowers: Array[Vector3] = [
		Vector3(-20, 0, -20), Vector3(20, 0, -20), Vector3(-20, 0, 20),
		Vector3(-16, 0, 23), Vector3(17, 0, 23), Vector3(24, 0, -3),
		Vector3(-25, 0, -8), Vector3(6, 0, 23), Vector3(-4, 0, -23),
	]
	for i in flowers.size():
		_park_prop("flower_A" if i % 2 == 0 else "flower_B",
				"Flowers%d" % i, flowers[i], float(i) * 53.0, 1.4)

	# Trees at the plaza edges and just outside on the lawns.
	var trees: Array = [
		[Vector3(-24, 0, -16), "tree_large"], [Vector3(24, 0, -14), "tree"],
		[Vector3(-25, 0, 10), "tree"], [Vector3(26, 0, 12), "tree_large"],
		[Vector3(-10, 0, 25), "tree_large"], [Vector3(10, 0, -25), "tree"],
		[Vector3(0, 0, 26), "tree"], [Vector3(-33, 0, -33), "tree_large"],
		[Vector3(33, 0, -34), "tree"], [Vector3(-34, 0, 33), "tree"],
		[Vector3(34, 0, 33), "tree_large"], [Vector3(0, 0, -34), "tree_large"],
		[Vector3(35, 0, 0), "tree"], [Vector3(-35, 0, 0), "tree_large"],
	]
	for i in trees.size():
		var t: Array = trees[i]
		_park_prop(t[1], "Tree%d" % i, t[0], float(i) * 47.0,
				0.95 + float(i % 3) * 0.15)


func _build_bins() -> void:
	var spots: Array[Vector3] = [
		Vector3(-7, 0, -9.5), Vector3(12.5, 0, -4.0),
		Vector3(-10.5, 0, 11.0), Vector3(17.5, 0, -11.5),
	]
	for i in spots.size():
		_park_prop("trashcan", "TrashBin%d" % i, spots[i], float(i) * 71.0)


# ----- roads / crossings (simple paving) -----

func _build_roads(parent: Node3D) -> void:
	var asphalt: Color = Color(0.19, 0.19, 0.22)
	var walk: Color = Color(0.81, 0.75, 0.64)
	var lane: Color = Color(0.87, 0.81, 0.36)
	var curb: Color = Color(0.86, 0.86, 0.83)
	var mid: float = (ROAD_IN + ROAD_OUT) * 0.5
	var band: float = ROAD_OUT - ROAD_IN

	_plane_on(parent, "WalkNorth", 58.0, 2.0, 0.0, -28.0, 0.012, walk)
	_plane_on(parent, "WalkSouth", 58.0, 2.0, 0.0, 28.0, 0.012, walk)
	_plane_on(parent, "WalkEast", 2.0, 58.0, 28.0, 0.0, 0.012, walk)
	_plane_on(parent, "WalkWest", 2.0, 58.0, -28.0, 0.0, 0.012, walk)

	_plane_on(parent, "RoadNorth", ROAD_OUT * 2.0, band, 0.0, -mid, 0.02, asphalt)
	_plane_on(parent, "RoadSouth", ROAD_OUT * 2.0, band, 0.0, mid, 0.02, asphalt)
	_plane_on(parent, "RoadEast", band, ROAD_OUT * 2.0, mid, 0.0, 0.02, asphalt)
	_plane_on(parent, "RoadWest", band, ROAD_OUT * 2.0, -mid, 0.0, 0.02, asphalt)

	_plane_on(parent, "LaneNorth", 80.0, 0.4, 0.0, -mid, 0.03, lane)
	_plane_on(parent, "LaneSouth", 80.0, 0.4, 0.0, mid, 0.03, lane)
	_plane_on(parent, "LaneEast", 0.4, 80.0, mid, 0.0, 0.03, lane)
	_plane_on(parent, "LaneWest", 0.4, 80.0, -mid, 0.0, 0.03, lane)

	_plane_on(parent, "CurbNorth", ROAD_OUT * 2.0, 0.5, 0.0, -ROAD_IN, 0.031, curb)
	_plane_on(parent, "CurbSouth", ROAD_OUT * 2.0, 0.5, 0.0, ROAD_IN, 0.031, curb)
	_plane_on(parent, "CurbEast", 0.5, ROAD_OUT * 2.0, ROAD_IN, 0.0, 0.031, curb)
	_plane_on(parent, "CurbWest", 0.5, ROAD_OUT * 2.0, -ROAD_IN, 0.0, 0.031, curb)

	_zebra_ns(parent, -mid)
	_zebra_ns(parent, mid)
	_zebra_ew(parent, mid)
	_zebra_ew(parent, -mid)


func _zebra_ns(parent: Node3D, zc: float) -> void:
	var white: Color = Color(0.92, 0.92, 0.88)
	for i in 10:
		var xf: float = -4.0 + float(i) * 0.9
		_plane_on(parent, "Zebra_%.0f_%.1f" % [zc, xf], 0.7, 13.0, xf, zc, 0.026, white)


func _zebra_ew(parent: Node3D, xc: float) -> void:
	var white: Color = Color(0.92, 0.92, 0.88)
	for i in 10:
		var zf: float = -4.0 + float(i) * 0.9
		_plane_on(parent, "Zebra_%.0f_%.1f" % [xc, zf], 13.0, 0.7, xc, zf, 0.026, white)


# ----- neighborhood frame (city_prop group) -----

# Homely House models ring north/east/west beyond the road, rotated toward
# the square with varied scale and spacing. South foreground stays open.
func _build_houses(parent: Node3D) -> void:
	var houses: Array = [
		# [pack asset dir, pos, yaw deg toward square, scale]
		["homely_house/gltf", Vector3(-30, 0, -49), 8.0, 1.45],
		["homely_house/gltf", Vector3(-14, 0, -52), -6.0, 1.3],
		["homely_house/gltf", Vector3(3, 0, -50), 4.0, 1.55],
		["homely_house/gltf", Vector3(20, 0, -53), -9.0, 1.35],
		["homely_house/gltf", Vector3(36, 0, -49), 12.0, 1.5],
		["homely_house/gltf", Vector3(51, 0, -28), -80.0, 1.4],
		["homely_house/gltf", Vector3(53, 0, -6), -95.0, 1.3],
		["homely_house/gltf", Vector3(52, 0, 18), -85.0, 1.5],
		["homely_house/gltf", Vector3(-51, 0, -20), 95.0, 1.35],
		["homely_house/gltf", Vector3(-53, 0, 4), 82.0, 1.5],
		["homely_house/gltf", Vector3(-51, 0, 26), 100.0, 1.3],
	]
	for i in houses.size():
		var h: Array = houses[i]
		var m := _model(h[0], "house", "CityBuilding%d" % i)
		if m == null:
			continue
		m.position = h[1]
		m.rotation_degrees = Vector3(0.0, h[2], 0.0)
		m.scale = Vector3.ONE * h[3]
		parent.add_child(m)
		m.add_to_group("city_prop")

	# Front-yard dressing: fences, mailboxes, packages, and mixed trees.
	var yards: Array = [
		[Vector3(-30, 0, -44.5), 0.0], [Vector3(3, 0, -45.5), 0.0],
		[Vector3(20, 0, -46.0), 0.0],
		[Vector3(45.5, 0, -28), -90.0], [Vector3(46.5, 0, 18), -90.0],
		[Vector3(-45.5, 0, -20), 90.0], [Vector3(-46.5, 0, 26), 90.0],
	]
	for i in yards.size():
		var y: Array = yards[i]
		_city_model("homely_house/gltf", "fence_straight_long",
				"YardFence%d" % i, y[0], y[1], 1.2)

	var mailboxes: Array[Vector3] = [
		Vector3(-24, 0, -43.5), Vector3(9, 0, -44.0), Vector3(43.5, 0, -2),
		Vector3(-43.5, 0, 12),
	]
	for i in mailboxes.size():
		_city_model("homely_house/gltf", "mailbox",
				"Mailbox%d" % i, mailboxes[i], float(i) * 90.0 - 20.0, 1.1)

	for i in 3:
		_city_model("homely_house/gltf", "package", "PorchPackage%d" % i,
				Vector3(-27 + i * 17.0, 0, -43.0), float(i) * 40.0, 1.0)

	var yard_trees: Array = [
		[Vector3(-40, 0, -38), 1.1], [Vector3(41, 0, -36), 1.0],
		[Vector3(42, 0, 8), 1.15], [Vector3(-42, 0, -2), 0.95],
		[Vector3(-40, 0, 34), 1.05], [Vector3(40, 0, 32), 1.1],
	]
	for i in yard_trees.size():
		var t: Array = yard_trees[i]
		var asset := "tree_large" if i % 2 == 0 else "tree"
		_city_model("homely_house/gltf", asset,
				"YardTree%d" % i, t[0], float(i) * 61.0, t[1])


func _build_street_life(parent: Node3D) -> void:
	# Park birds loitering near the bins (flavor, city_prop side of the fence).
	_place(parent, "pretty_park/gltf", "bird", "StreetBird0", "city_prop",
			Vector3(-6.2, 0, -8.6), 120.0, 1.0)
	_place(parent, "pretty_park/gltf", "bird", "StreetBird1", "city_prop",
			Vector3(13.4, 0, -3.2), -40.0, 1.0)
	_place(parent, "pretty_park/gltf", "bird", "StreetBird2", "city_prop",
			Vector3(30.5, 0, 22.0), 200.0, 1.0)
