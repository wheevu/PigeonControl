extends Object
class_name SnapshotParser

# Pure, dependency-free parser for Julia's UDP binary pigeon snapshot.
# Network contract (LITTLE-ENDIAN, Y-up, meters):
#   Header 20 bytes: magic u32=0x50494345, version u8, pad3, tick u32, pigeons u32, foods u32
#   v1 Pigeon 40 bytes: id u32, pos_x f32, pos_y f32, pos_z f32, yaw f32, pitch f32, roll f32,
#                     state u8, variant u8, flap_phase f32, speed f32, pad2
#   v1 Food 16 bytes: id u32, pos_x f32, pos_y f32, pos_z f32
#   v2 Pigeon 48 bytes: v1 40B plus bank f32, hunger01 f32
#   v2 Food 20 bytes: v1 16B plus amount f32
#   v2 trailer: env 20B (sun, time, wind xyz), threat 16B (active u8 pad3 xyz),
#               stats 16B (fighting, fleeing, eating u32, food_left f32),
#               fx_count u32 plus fx 20B each (type u32, xyz f32, mag f32)
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
		"version": 1,
		"pigeons": [],
		"foods": [],
		"env": {},
		"threat": {},
		"stats": {},
		"fx": [],
	}

	if bytes.size() < 20:
		result["error"] = "packet too small: %d bytes (need >= 20)" % bytes.size()
		return result

	var magic: int = bytes.decode_u32(0)
	if magic != MAGIC:
		result["error"] = "bad magic: 0x%08X (expected 0x%08X)" % [magic, MAGIC]
		return result

	# version = bytes[4]; pad bytes 5,6,7
	# Accept v1 (frozen) and v2 (additive visuals). Reject before decoding counts.
	var version: int = bytes[4]
	if version != 1 and version != 2:
		result["error"] = "unsupported protocol version: %d (expected 1 or 2)" % version
		result["ok"] = false
		return result
	result["version"] = version

	var pigeon_bytes: int = 40 if version == 1 else 48
	var food_bytes: int = 16 if version == 1 else 20

	var tick: int = bytes.decode_u32(8)
	var pigeon_count: int = bytes.decode_u32(12)
	var food_count: int = bytes.decode_u32(16)
	result["tick"] = tick

	var offset: int = 20
	var truncated: bool = false

	for pi in pigeon_count:
		if offset + pigeon_bytes > bytes.size():
			result["error"] = "truncated pigeon record %d (need %d, have %d)" % [pi, offset + pigeon_bytes, bytes.size()]
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
		# pad bytes 38,39; v2 appends bank + hunger01.
		p["bank"] = 0.0
		p["hunger"] = 0.0
		if version == 2:
			p["bank"] = bytes.decode_float(offset + 40)
			p["hunger"] = bytes.decode_float(offset + 44)
		# pad bytes 38,39
		result["pigeons"].append(p)
		offset += pigeon_bytes

	for fi in food_count:
		if offset + food_bytes > bytes.size():
			result["error"] = "truncated food record %d (need %d, have %d)" % [fi, offset + food_bytes, bytes.size()]
			truncated = true
			break
		var f: Dictionary = {}
		f["id"] = bytes.decode_u32(offset + 0)
		f["x"] = bytes.decode_float(offset + 4)
		f["y"] = bytes.decode_float(offset + 8)
		f["z"] = bytes.decode_float(offset + 12)
		f["amount"] = 50.0
		if version == 2:
			f["amount"] = bytes.decode_float(offset + 16)
		result["foods"].append(f)
		offset += food_bytes

	if version == 2 and not truncated:
		if offset + 20 > bytes.size():
			result["error"] = "truncated env block"
			result["ok"] = false
			return result
		result["env"] = {
			"sun": bytes.decode_float(offset + 0),
			"time": bytes.decode_float(offset + 4),
			"wind_x": bytes.decode_float(offset + 8),
			"wind_y": bytes.decode_float(offset + 12),
			"wind_z": bytes.decode_float(offset + 16),
		}
		offset += 20
		if offset + 16 > bytes.size():
			result["error"] = "truncated threat block"
			result["ok"] = false
			return result
		var active: int = bytes[offset + 0]
		result["threat"] = {
			"active": active == 1,
			"x": bytes.decode_float(offset + 4),
			"y": bytes.decode_float(offset + 8),
			"z": bytes.decode_float(offset + 12),
		}
		offset += 16
		if offset + 16 > bytes.size():
			result["error"] = "truncated stats block"
			result["ok"] = false
			return result
		result["stats"] = {
			"fighting": bytes.decode_u32(offset + 0),
			"fleeing": bytes.decode_u32(offset + 4),
			"eating": bytes.decode_u32(offset + 8),
			"food_left": bytes.decode_float(offset + 12),
		}
		offset += 16
		if offset + 4 > bytes.size():
			result["error"] = "truncated fx count"
			result["ok"] = false
			return result
		var fx_count: int = bytes.decode_u32(offset)
		offset += 4
		for fx_i in fx_count:
			if offset + 20 > bytes.size():
				result["error"] = "truncated fx record %d" % fx_i
				truncated = true
				break
			result["fx"].append({
				"type": bytes.decode_u32(offset + 0),
				"x": bytes.decode_float(offset + 4),
				"y": bytes.decode_float(offset + 8),
				"z": bytes.decode_float(offset + 12),
				"mag": bytes.decode_float(offset + 16),
			})
			offset += 20

	# Soft validation: trailing extra bytes -> error string but data still returned.
	if offset != bytes.size() and result["error"] == "":
		result["error"] = "size mismatch: consumed %d bytes, packet has %d" % [offset, bytes.size()]

	result["ok"] = not truncated
	return result
