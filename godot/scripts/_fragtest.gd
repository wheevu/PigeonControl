extends SceneTree

# Headless test: build a large synthetic PICE snapshot, fragment it exactly like
# the Julia server (FRAG envelope), feed the fragments through
# SnapshotReceiver.feed_packet, and assert the reassembled parse is correct.
# Run: godot --headless -s res://scripts/_fragtest.gd

const FRAG_MAGIC = 0x46524147
const MAGIC_PICE = 0x50494345
const CHUNK_SIZE = 8000

func put_u32(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF); b.append((v >> 8) & 0xFF); b.append((v >> 16) & 0xFF); b.append((v >> 24) & 0xFF)

func put_u16(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF); b.append((v >> 8) & 0xFF)

func put_f32(b: PackedByteArray, v: float) -> void:
	var sp: StreamPeerBuffer = StreamPeerBuffer.new()
	sp.big_endian = false
	sp.put_float(v)
	b.append_array(sp.data_array)

func build_pigeon(b: PackedByteArray, id: int) -> void:
	# variant cycles 0..3 across the four archetypes (Common/Crumb Goblin/
	# Sky Scout/Bruiser) so a fragmented frame exercises every weapon. The
	# renderer derives the weapon from `variant`; it is never sent on the wire.
	put_u32(b, id)
	put_f32(b, float(id) * 0.1)
	put_f32(b, 1.0)
	put_f32(b, float(id) * 0.2)
	put_f32(b, 0.5)
	put_f32(b, 0.0)
	put_f32(b, -0.1)
	b.append(0)            # state
	b.append(id % 4)       # variant (cycles 0..3)
	put_f32(b, 0.3)        # flap_phase
	put_f32(b, 2.0)        # speed
	b.append(0); b.append(0)  # pad (reserved, zero)

func build_food(b: PackedByteArray, id: int) -> void:
	put_u32(b, id)
	put_f32(b, float(id))
	put_f32(b, 0.2)
	put_f32(b, float(id) * 0.5)

func _build_full_snapshot(pigeons: int, foods: int) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	put_u32(b, MAGIC_PICE)
	b.append(1)            # version
	b.append(0); b.append(0); b.append(0)  # pad
	put_u32(b, 42)         # tick
	put_u32(b, pigeons)
	put_u32(b, foods)
	for i in range(pigeons):
		build_pigeon(b, i + 1)
	for i in range(foods):
		build_food(b, i + 1)
	return b

func _wrap_fragment(full: PackedByteArray, frame_id: int, idx: int, count: int) -> PackedByteArray:
	var seg: PackedByteArray = full.slice(idx * CHUNK_SIZE, mini((idx + 1) * CHUNK_SIZE, full.size()))
	var pkt: PackedByteArray = PackedByteArray()
	put_u32(pkt, FRAG_MAGIC)
	put_u32(pkt, frame_id)
	put_u16(pkt, idx)
	put_u16(pkt, count)
	put_u16(pkt, seg.size())
	pkt.append_array(seg)
	return pkt

func _done(code: int, msg: String) -> void:
	print(msg)
	quit(code)

func _initialize():
	var pigeons: int = 300
	var foods: int = 5
	var full: PackedByteArray = _build_full_snapshot(pigeons, foods)
	if full.size() <= CHUNK_SIZE:
		_done(1, "FRAGTEST_FAIL: snapshot fits in one datagram; not exercising fragmentation (size=%d)" % full.size())
		return

	var count: int = ceil(full.size() / float(CHUNK_SIZE))
	var rcv = load("res://scripts/SnapshotReceiver.gd").new()
	var got: Dictionary = {}
	# Feed in REVERSE order to prove ordering is handled by index, not arrival.
	for idx in range(count - 1, -1, -1):
		var pkt: PackedByteArray = _wrap_fragment(full, 99, idx, count)
		var res: Dictionary = rcv.feed_packet(pkt)
		if res.has("ok") and res["ok"]:
			got = res
	# Only the final fragment should yield a parsed frame.
	if not got.has("ok") or not got["ok"]:
		_done(1, "FRAGTEST_FAIL: no complete frame after feeding %d fragments" % count)
		return
	if got["tick"] != 42:
		_done(1, "FRAGTEST_FAIL: tick mismatch (got %d)" % got["tick"])
		return
	if got["pigeons"].size() != pigeons:
		_done(1, "FRAGTEST_FAIL: pigeon count mismatch (got %d want %d)" % [got["pigeons"].size(), pigeons])
		return
	if got["foods"].size() != foods:
		_done(1, "FRAGTEST_FAIL: food count mismatch (got %d want %d)" % [got["foods"].size(), foods])
		return
	# Spot-check first pigeon fields round-tripped.
	var p0: Dictionary = got["pigeons"][0]
	if abs(p0["x"] - 0.1) > 1e-3 or p0["state"] != 0:
		_done(1, "FRAGTEST_FAIL: first pigeon fields wrong (x=%f state=%d)" % [p0["x"], p0["state"]])
		return
	if p0["variant"] != 1:   # id 1 -> 1 % 4 == 1 (Crumb Goblin)
		_done(1, "FRAGTEST_FAIL: first pigeon variant wrong (got %d want 1)" % p0["variant"])
		return
	# Confirm the four archetypes parse across the fragmented frame (id%4 spans 0..3).
	var seen_variants: Dictionary = {}
	for pg in got["pigeons"]:
		seen_variants[pg["variant"]] = true
	if not (seen_variants.has(0) and seen_variants.has(1) and seen_variants.has(2) and seen_variants.has(3)):
		_done(1, "FRAGTEST_FAIL: fragmented frame did not exercise all four variants")
		return
	_done(0, "FRAGTEST_OK pigeons=%d foods=%d fragments=%d" % [pigeons, foods, count])
	return
