extends Node
class_name SnapshotReceiver

# Binds a UDP socket, parses incoming packets (single PICE or fragmented FRAG),
# and feeds the Swarm + food markers. Godot only WITNESSES reality here; it
# never simulates.

const SnapshotParser = preload("res://scripts/SnapshotParser.gd")

const FRAG_MAGIC = 0x46524147
const MAGIC_PICE = 0x50494345

signal snapshot_applied(tick: int)

var swarm: Node
var port: int
var peer: PacketPeerUDP
var food_parent: Node3D
var last_food_markers: Array = []   # pooled MeshInstance3D
var _error_printed: bool = false

# Most recently applied (fully fed) snapshot tick, plus the parser's error
# string for that tick. Exposed so observer capture can validate a tick:
# a nonempty error with ok=true must be treated as invalid for capture.
var latest_applied_tick: int = -1
var latest_applied_error: String = ""
var latest_version: int = 1
var latest_env: Dictionary = {}
var latest_threat: Dictionary = {}
var latest_stats: Dictionary = {}
var latest_fx: Array = []

# Reassembly buffers keyed by frame id. Each value: {"count":int, "chunks":Array}
var _reasm: Dictionary = {}

func setup(s: Node, p: int) -> void:
	swarm = s
	port = p
	peer = PacketPeerUDP.new()
	var err: int = peer.bind(port)   # wildcard bind; fine for 127.0.0.1 locally
	if err != OK:
		push_warning("SnapshotReceiver: failed to bind UDP port %d (err %d)" % [port, err])
	food_parent = Node3D.new()
	food_parent.name = "Foods"
	add_child(food_parent)

# Feed one raw UDP packet. Returns a parsed snapshot Dictionary when a complete
# frame is available (single packet or final fragment), otherwise an empty Dict.
func feed_packet(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 4:
		return {}
	var magic: int = pkt.decode_u32(0)

	if magic == MAGIC_PICE:
		return SnapshotParser.parse_snapshot(pkt)

	if magic == FRAG_MAGIC:
		var frame_id: int = pkt.decode_u32(4)
		var idx: int = pkt.decode_u16(8)
		var count: int = pkt.decode_u16(10)
		var seglen: int = pkt.decode_u16(12)
		var data: PackedByteArray = pkt.slice(14, 14 + seglen)
		if not _reasm.has(frame_id):
			var chunks: Array = []
			for _k in range(count):
				chunks.append(null)
			_reasm[frame_id] = {"count": count, "chunks": chunks}
		var entry: Dictionary = _reasm[frame_id]
		if idx >= 0 and idx < entry["count"]:
			entry["chunks"][idx] = data
		# Cap buffer growth (localhost loopback rarely loses, but be safe).
		if _reasm.size() > 16:
			var first_key = _reasm.keys()[0]
			_reasm.erase(first_key)
		# Check completeness.
		var complete: bool = true
		for c in entry["chunks"]:
			if c == null:
				complete = false
				break
		if complete:
			var full: PackedByteArray = PackedByteArray()
			for c in entry["chunks"]:
				full.append_array(c)
			_reasm.erase(frame_id)
			return SnapshotParser.parse_snapshot(full)

	return {}

func _process(_delta: float) -> void:
	if peer == null:
		return
	while peer.get_available_packet_count() > 0:
		var pkt: PackedByteArray = peer.get_packet()
		var parsed: Dictionary = feed_packet(pkt)
		if parsed.has("ok") and parsed["ok"]:
			swarm.update_from_parsed(parsed)
			if parsed.has("fx"):
				swarm.apply_fx_events(parsed["fx"])
			_update_food_markers(parsed["foods"])
			latest_applied_tick = parsed["tick"]
			latest_applied_error = parsed["error"]
			latest_version = parsed.get("version", 1)
			latest_env = parsed.get("env", {})
			latest_threat = parsed.get("threat", {})
			latest_stats = parsed.get("stats", {})
			latest_fx = parsed.get("fx", [])
			emit_signal("snapshot_applied", parsed["tick"])
			_error_printed = false
		elif parsed.has("ok") and not parsed["ok"]:
			if not _error_printed:
				print("SnapshotReceiver: parse error: ", parsed["error"])
				_error_printed = true

func _update_food_markers(foods: Array) -> void:
	var need: int = foods.size()
	while last_food_markers.size() < need:
		var mi: MeshInstance3D = MeshInstance3D.new()
		var sm: SphereMesh = SphereMesh.new()
		sm.radius = 0.15
		sm.height = 0.3
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.42, 0.26, 0.12)
		mat.roughness = 0.8
		mi.mesh = sm
		mi.material_override = mat
		food_parent.add_child(mi)
		last_food_markers.append(mi)

	for i in last_food_markers.size():
		if i < need:
			var f: Dictionary = foods[i]
			last_food_markers[i].global_position = Vector3(f["x"], f["y"], f["z"])
			# v2 crumbs shrink as pigeons drain them; v1 stays full size.
			var amount: float = float(f.get("amount", 50.0))
			var s: float = clampf(amount / 50.0, 0.25, 1.0)
			last_food_markers[i].scale = Vector3.ONE * s
			last_food_markers[i].visible = true
		else:
			last_food_markers[i].visible = false
