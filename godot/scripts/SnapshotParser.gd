extends Object
class_name SnapshotParser

# Pure, dependency-free parser for Julia's UDP binary pigeon snapshot.
# Network contract (LITTLE-ENDIAN, Y-up, meters):
#   Header 20 bytes: magic u32=0x50494345, version u8, pad3, tick u32, pigeons u32, foods u32
#   Pigeon 40 bytes: id u32, pos_x f32, pos_y f32, pos_z f32, yaw f32, pitch f32, roll f32,
#                     state u8, variant u8, flap_phase f32, speed f32, pad2
#   Food 16 bytes: id u32, pos_x f32, pos_y f32, pos_z f32
#
# Archetypes (derived from `variant`, NOT sent on the wire):
#   0 Common       -> Sword
#   1 Crumb Goblin -> Hammer
#   2 Sky Scout    -> Wand
#   3 Bruiser      -> Bomb
# Unknown variants remain parseable; the renderer should fall back to Common
# and hide the weapon. The weapon is shown only while state == FIGHTING (6).
# FIGHTING pitch/roll carry Julia's authoritative ragdoll pose; Godot only
# interpolates. The 2 pad bytes per pigeon (offsets 38-39) stay reserved zero.

const MAGIC: int = 0x50494345

static func parse_snapshot(bytes: PackedByteArray) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"error": "",
		"tick": 0,
		"pigeons": [],
		"foods": [],
	}

	if bytes.size() < 20:
		result["error"] = "packet too small: %d bytes (need >= 20)" % bytes.size()
		return result

	var magic: int = bytes.decode_u32(0)
	if magic != MAGIC:
		result["error"] = "bad magic: 0x%08X (expected 0x%08X)" % [magic, MAGIC]
		return result

	# version = bytes[4]; pad bytes 5,6,7
	# Reject unsupported protocol versions before decoding counts.
	var version: int = bytes[4]
	if version != 1:
		result["error"] = "unsupported protocol version: %d (expected 1)" % version
		result["ok"] = false
		return result

	var tick: int = bytes.decode_u32(8)
	var pigeon_count: int = bytes.decode_u32(12)
	var food_count: int = bytes.decode_u32(16)
	result["tick"] = tick

	var offset: int = 20
	var truncated: bool = false

	for pi in pigeon_count:
		if offset + 40 > bytes.size():
			result["error"] = "truncated pigeon record %d (need %d, have %d)" % [pi, offset + 40, bytes.size()]
			truncated = true
			break
		var p: Dictionary = {}
		p["id"] = bytes.decode_u32(offset + 0)
		p["x"] = bytes.decode_float(offset + 4)
		p["y"] = bytes.decode_float(offset + 8)
		p["z"] = bytes.decode_float(offset + 12)
		p["yaw"] = bytes.decode_float(offset + 16)
		p["pitch"] = bytes.decode_float(offset + 20)
		p["roll"] = bytes.decode_float(offset + 24)
		p["state"] = bytes[offset + 28]
		p["variant"] = bytes[offset + 29]
		p["flap_phase"] = bytes.decode_float(offset + 30)
		p["speed"] = bytes.decode_float(offset + 34)
		# pad bytes 38,39
		result["pigeons"].append(p)
		offset += 40

	for fi in food_count:
		if offset + 16 > bytes.size():
			result["error"] = "truncated food record %d (need %d, have %d)" % [fi, offset + 16, bytes.size()]
			truncated = true
			break
		var f: Dictionary = {}
		f["id"] = bytes.decode_u32(offset + 0)
		f["x"] = bytes.decode_float(offset + 4)
		f["y"] = bytes.decode_float(offset + 8)
		f["z"] = bytes.decode_float(offset + 12)
		result["foods"].append(f)
		offset += 16

	# Soft validation: trailing extra bytes -> error string but data still returned.
	if offset != bytes.size() and result["error"] == "":
		result["error"] = "size mismatch: consumed %d bytes, packet has %d" % [offset, bytes.size()]

	result["ok"] = not truncated
	return result
