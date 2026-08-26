extends Node3D
class_name Swarm

# Renders up to max_instances pigeons across four archetype MultiMeshes and
# four weapon MultiMeshes. Witnesses positions streamed by Julia and
# interpolates between snapshots renderer-side only.
#
# Variants 0..3 map in order: Common / Goblin / Scout / Bruiser, each with a
# matching weapon (sword / hammer / wand / bomb). FIGHTING (state == 6) makes
# the weapon visible. Unknown variants render with the Common pigeon mesh but
# never show a weapon.

const VARIANT_NAMES := ["Common", "Goblin", "Scout", "Bruiser"]
const PIGEON_NODE_NAMES := ["PigeonsCommon", "PigeonsGoblin", "PigeonsScout", "PigeonsBruiser"]
const WEAPON_NODE_NAMES := ["WeaponsSword", "WeaponsHammer", "WeaponsWand", "WeaponsBomb"]
const WEAPON_BACKPLATE_NODE_NAMES := [
	"WeaponsSwordBackplate", "WeaponsHammerBackplate",
	"WeaponsWandBackplate", "WeaponsBombBackplate",
]
const SHADOW_NODE_NAME := "PigeonShadows"
const IMPACT_NODE_NAME := "ImpactBursts"
const EMOTE_NODE_NAME := "FightEmotes"
const IMPACT_TEX_PATH := "res://assets/vfx/impact_star.png"
const EMOTE_TEX_PATH := "res://assets/vfx/emote_anger.png"
# Authored GLBs are real pigeon scale (~0.5-0.65 m); restrained archetype deltas
# keep final world sizes around 0.45-0.75 m.
const ARCH_SCALE := [1.0, 1.08, 0.94, 1.2]
# Saturated tints per archetype so the white Kenney cursor icons read on pale
# pavement: sword red, hammer orange, wand violet, bomb teal.
const WEAPON_TINTS := [
	Color(1.0, 0.15, 0.15),
	Color(1.0, 0.55, 0.05),
	Color(0.7, 0.25, 1.0),
	Color(0.05, 0.85, 0.75),
]
const PIGEON_MESH_PATHS := [
	"res://assets/pigeons/pigeon_common.glb",
	"res://assets/pigeons/pigeon_crumb_goblin.glb",
	"res://assets/pigeons/pigeon_sky_scout.glb",
	"res://assets/pigeons/pigeon_bruiser.glb",
]
const WEAPON_TEX_PATHS := [
	"res://assets/weapons/sword.png",
	"res://assets/weapons/hammer.png",
	"res://assets/weapons/wand.png",
	"res://assets/weapons/bomb.png",
]
const STATE_FIGHTING := 6
const LERP_RATE := 8.0
const HIDDEN_Y := -1000.0
const TAU := 6.283185307179586

var max_instances: int = 0
var current_count: int = 0
var target_alpha: float = 1.0

# Per-type (index == variant 0..3) rendering state.
var pigeon_mm: Array = []      # MultiMesh per type
var weapon_mm: Array = []      # MultiMesh per type (or null)
var backplate_mm: Array = []   # Dark backing MultiMesh per type
var shadow_mm: MultiMesh = null # Shared contact-shadow MultiMesh
var impact_mm: MultiMesh = null # FIGHTING impact-star garnish
var emote_mm: MultiMesh = null  # FIGHTING anger emote garnish
var fx_time: float = 0.0       # Local visual clock for pulse/bob (no authority)
var prev_t: Array = []         # Array[Array[Transform3D]] last applied bird transform
var target_t: Array = []       # Array[Array[Transform3D]] latest parsed bird transform
var rend_t: Array = []         # Array[Array[Transform3D]] currently drawn bird transform
var last_id: Array = []        # Array[Array[int]] id that occupied each slot last update
var slot_state: Array = []     # Array[Array[int]] state per slot
var slot_unkn: Array = []      # Array[Array[bool]] pigeon is an unknown variant (type 0 only)
var slot_flap: Array = []      # Array[Array[float]] flap_phase per slot
var slot_roll: Array = []      # Array[Array[float]] roll per slot
var type_count: Array = []     # Array[int] current visible count per type
var prev_count: Array = []     # Array[int] visible count last frame (stale-range clearing)

# Observer capture mode: when enabled, rendering snaps directly to the latest
# authoritative target transforms (no interpolation) and the visual FX clock is
# derived from the authoritative tick * dt instead of wall-clock process delta.
# Normal mode keeps the existing interpolation and wall-time FX behavior.
var _observer_mode: bool = false
var _observer_dt: float = 1.0 / 60.0
var _observer_tick: int = 0

func setup(max_n: int) -> void:
	max_instances = max_n
	current_count = 0
	target_alpha = 1.0

	pigeon_mm = []
	weapon_mm = []
	backplate_mm = []
	prev_t = []
	target_t = []
	rend_t = []
	last_id = []
	slot_state = []
	slot_unkn = []
	slot_flap = []
	slot_roll = []
	type_count = []
	prev_count = []

	for t in VARIANT_NAMES.size():
		_setup_type(t, max_n)

	_setup_shared_fx(max_n)

func _setup_shared_fx(max_n: int) -> void:
	# --- shared contact shadows (one flat soft disc under each pigeon) ---
	var smm: MultiMesh = MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_3D
	var sq: QuadMesh = QuadMesh.new()
	sq.size = Vector2(1.0, 1.0)
	sq.orientation = PlaneMesh.FACE_Y
	smm.mesh = sq
	smm.instance_count = max_n
	smm.visible_instance_count = 0
	var smat: StandardMaterial3D = StandardMaterial3D.new()
	smat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.albedo_color = Color(0.0, 0.0, 0.0, 0.38)
	smat.disable_receive_shadows = true
	var smi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	smi.name = SHADOW_NODE_NAME
	smi.multimesh = smm
	smi.material_override = smat
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(smi)
	shadow_mm = smm

	# --- FIGHTING impact bursts (Kenney star, spinning beside fighters) ---
	var imm: MultiMesh = MultiMesh.new()
	imm.transform_format = MultiMesh.TRANSFORM_3D
	imm.mesh = _make_billboard_mesh(0.38)
	imm.instance_count = max_n
	imm.visible_instance_count = 0
	var imat: StandardMaterial3D = _make_billboard_material(IMPACT_TEX_PATH, Color(1.0, 1.0, 1.0))
	imat.render_priority = 2
	imat.no_depth_test = false
	var imi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	imi.name = IMPACT_NODE_NAME
	imi.multimesh = imm
	imi.material_override = imat
	imi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	imi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(imi)
	impact_mm = imm

	# --- FIGHTING anger emotes (above fighters, restrained bob) ---
	var emm: MultiMesh = MultiMesh.new()
	emm.transform_format = MultiMesh.TRANSFORM_3D
	emm.mesh = _make_billboard_mesh(0.30)
	emm.instance_count = max_n
	emm.visible_instance_count = 0
	var emat: StandardMaterial3D = _make_billboard_material(EMOTE_TEX_PATH, Color(1.0, 1.0, 1.0))
	emat.render_priority = 2
	var emi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	emi.name = EMOTE_NODE_NAME
	emi.multimesh = emm
	emi.material_override = emat
	emi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	emi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(emi)
	emote_mm = emm

func _setup_type(t: int, max_n: int) -> void:
	# --- pigeon MultiMesh ---
	var pmesh: Mesh = _load_pigeon_mesh(t)
	var pmm: MultiMesh = MultiMesh.new()
	pmm.transform_format = MultiMesh.TRANSFORM_3D
	pmm.mesh = pmesh
	pmm.use_custom_data = false
	pmm.instance_count = max_n
	pmm.visible_instance_count = 0

	var pmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	pmi.name = PIGEON_NODE_NAMES[t]
	pmi.multimesh = pmm
	add_child(pmi)
	pigeon_mm.append(pmm)

	# --- weapon MultiMesh (billboard quad) with dark backplate ---
	var wmm: MultiMesh = MultiMesh.new()
	wmm.transform_format = MultiMesh.TRANSFORM_3D
	wmm.mesh = _make_billboard_mesh(0.52)
	wmm.use_custom_data = false
	wmm.instance_count = max_n
	wmm.visible_instance_count = 0

	var wmat: StandardMaterial3D = _make_weapon_material(t)
	var wmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	wmi.name = WEAPON_NODE_NAMES[t]
	wmi.multimesh = wmm
	wmi.material_override = wmat
	wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(wmi)
	weapon_mm.append(wmm)

	# Dark backing quad slightly larger than the icon so translucent/white
	# areas stay legible on pale pavement. Drawn first, no depth write.
	var bmm: MultiMesh = MultiMesh.new()
	bmm.transform_format = MultiMesh.TRANSFORM_3D
	bmm.mesh = _make_billboard_mesh(0.64)
	bmm.use_custom_data = false
	bmm.instance_count = max_n
	bmm.visible_instance_count = 0
	var bmat: StandardMaterial3D = _make_backplate_material()
	var bmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	bmi.name = WEAPON_BACKPLATE_NODE_NAMES[t]
	bmi.multimesh = bmm
	bmi.material_override = bmat
	bmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(bmi)
	backplate_mm.append(bmm)

	# --- per-slot state arrays ---
	var pa: Array = []
	var ta: Array = []
	var ra: Array = []
	var li: Array = []
	var st: Array = []
	var un: Array = []
	var fl: Array = []
	var ro: Array = []
	var h: Transform3D = _hidden_transform(false)
	var hz: Transform3D = _hidden_transform(true)
	for _i in max_n:
		pa.append(h)
		ta.append(h)
		ra.append(h)
		li.append(-1)
		st.append(0)
		un.append(false)
		fl.append(0.0)
		ro.append(0.0)
	prev_t.append(pa)
	target_t.append(ta)
	rend_t.append(ra)
	last_id.append(li)
	slot_state.append(st)
	slot_unkn.append(un)
	slot_flap.append(fl)
	slot_roll.append(ro)
	type_count.append(0)
	prev_count.append(0)

func _load_pigeon_mesh(t: int) -> Mesh:
	var mesh: Mesh = _try_load_glb_mesh(PIGEON_MESH_PATHS[t])
	if mesh != null:
		return mesh
	# Fallback to the existing shared pigeon model during concurrent asset work.
	mesh = _try_load_glb_mesh("res://assets/pigeon.glb")
	if mesh != null:
		return mesh
	# Last-resort primitive so the slice is never empty.
	var cm: CapsuleMesh = CapsuleMesh.new()
	cm.radius = 0.25
	cm.height = 0.7
	return cm

func _try_load_glb_mesh(path: String) -> Mesh:
	if not ResourceLoader.exists(path):
		return null
	var res = load(path)
	if res == null or not (res is PackedScene):
		return null
	var inst: Node = res.instantiate()
	var m: Mesh = _find_mesh(inst)
	inst.queue_free()
	return m

func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for c in node.get_children():
		var m: Mesh = _find_mesh(c)
		if m != null:
			return m
	return null

func _make_billboard_mesh(size: float) -> QuadMesh:
	var q: QuadMesh = QuadMesh.new()
	q.size = Vector2(size, size)
	return q

func _make_billboard_material(tex_path: String, tint: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = tint
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists(tex_path):
		var loaded = load(tex_path)
		if loaded != null and (loaded is Texture2D):
			mat.albedo_texture = loaded
	return mat

func _make_backplate_material() -> StandardMaterial3D:
	# A soft round plate keeps pale icons readable without covering the pigeon
	# with the opaque square produced by a plain untextured QuadMesh.
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var uv := Vector2((float(x) + 0.5) / 32.0, (float(y) + 0.5) / 32.0)
			var edge := clampf((0.50 - uv.distance_to(Vector2(0.5, 0.5))) / 0.13, 0.0, 1.0)
			var alpha := edge * edge * (3.0 - 2.0 * edge) * 0.72
			image.set_pixel(x, y, Color(0.035, 0.04, 0.055, alpha))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.disable_receive_shadows = true
	mat.render_priority = -1
	return mat

func _make_weapon_material(t: int) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.disable_receive_shadows = true
	# Draw the icon over its dark backplate.
	mat.render_priority = 1

	var tex = null
	if ResourceLoader.exists(WEAPON_TEX_PATHS[t]):
		var loaded = load(WEAPON_TEX_PATHS[t])
		if loaded != null and (loaded is Texture2D):
			tex = loaded
	if tex != null:
		# Saturated archetype tint keeps the mostly-white cursor icons readable.
		mat.albedo_texture = tex
		mat.albedo_color = WEAPON_TINTS[t]
	else:
		mat.albedo_color = Color(1.0, 0.85, 0.2)
	return mat

func _hidden_transform(scale_zero: bool) -> Transform3D:
	if scale_zero:
		return Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, HIDDEN_Y, 0))
	return Transform3D(Basis(), Vector3(0, HIDDEN_Y, 0))

func update_from_parsed(parsed: Dictionary) -> void:
	var pigeons: Array = parsed["pigeons"]
	var total: int = mini(pigeons.size(), max_instances)
	current_count = total
	target_alpha = 0.0

	# Group by valid variant; unknown variants join the Common (0) group but
	# are flagged so they never receive a weapon.
	var groups: Array = [[], [], [], []]
	var groups_unkn: Array = [[], [], [], []]
	for i in total:
		var p: Dictionary = pigeons[i]
		var v: int = p["variant"]
		var t: int = 0
		var is_unkn: bool = false
		if v < 0 or v > 3:
			t = 0
			is_unkn = true
		else:
			t = v
		groups[t].append(p)
		groups_unkn[t].append(is_unkn)

	# Sort each group by numeric id so wire record ordering never affects
	# slot assignment (and therefore never affects interpolation).
	for t in VARIANT_NAMES.size():
		var ents: Array = []
		for j in groups[t].size():
			ents.append({"id": groups[t][j]["id"], "p": groups[t][j], "unkn": groups_unkn[t][j]})
		ents.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["id"] < b["id"])

		var old_count: int = type_count[t]
		var new_count: int = ents.size()
		type_count[t] = new_count

		for i in new_count:
			var e: Dictionary = ents[i]
			var p: Dictionary = e["p"]
			var basis: Basis = Basis.from_euler(Vector3(p["pitch"], p["yaw"], p["roll"]))
			var s: float = ARCH_SCALE[t]
			basis = basis.scaled(Vector3(s, s, s))
			var tgt: Transform3D = Transform3D(basis, Vector3(p["x"], p["y"], p["z"]))

			# Smoothly interpolate from the rendered transform when the same id
			# occupies this slot; otherwise pop in at the target (never from y=-1000).
			if i < old_count and last_id[t][i] == p["id"]:
				prev_t[t][i] = rend_t[t][i]
			else:
				prev_t[t][i] = tgt

			target_t[t][i] = tgt
			slot_state[t][i] = p["state"]
			slot_unkn[t][i] = e["unkn"]
			slot_flap[t][i] = p["flap_phase"]
			slot_roll[t][i] = p["roll"]
			last_id[t][i] = p["id"]

		# Clear slots that fell out of range this update.
		for i in range(new_count, old_count):
			prev_t[t][i] = _hidden_transform(false)
			target_t[t][i] = _hidden_transform(false)
			rend_t[t][i] = _hidden_transform(false)
			last_id[t][i] = -1
			slot_state[t][i] = 0
			slot_unkn[t][i] = false
			slot_flap[t][i] = 0.0
			slot_roll[t][i] = 0.0

func _process(delta: float) -> void:
	if max_instances == 0:
		return
	if _observer_mode:
		# Visual FX clock follows the authoritative simulation tick, not wall time.
		fx_time = float(_observer_tick) * _observer_dt
		target_alpha = 1.0
	else:
		target_alpha = minf(1.0, target_alpha + delta * LERP_RATE)
		fx_time += delta

	# Shared FX MultiMeshes write into their own flat slot index.
	var fx_i: int = 0
	for t in VARIANT_NAMES.size():
		var mm: MultiMesh = pigeon_mm[t]
		if mm == null:
			continue
		var wm: MultiMesh = weapon_mm[t]
		var bm: MultiMesh = backplate_mm[t]
		var count: int = type_count[t]
		mm.visible_instance_count = count
		if wm != null:
			wm.visible_instance_count = count
		if bm != null:
			bm.visible_instance_count = count

		for i in count:
			var cur: Transform3D = prev_t[t][i].interpolate_with(target_t[t][i], target_alpha)
			rend_t[t][i] = cur
			mm.set_instance_transform(i, cur)
			if shadow_mm != null:
				shadow_mm.set_instance_transform(fx_i, _shadow_transform(cur))
			var wxf: Transform3D = _weapon_transform(t, i, cur, false)
			if wm != null:
				wm.set_instance_transform(i, wxf)
			if bm != null:
				bm.set_instance_transform(i, _weapon_transform(t, i, cur, true))
			var fighting: bool = (not slot_unkn[t][i]) and slot_state[t][i] == STATE_FIGHTING
			if fighting:
				if impact_mm != null:
					impact_mm.set_instance_transform(fx_i, _impact_transform(t, i, cur))
				if emote_mm != null:
					emote_mm.set_instance_transform(fx_i, _emote_transform(t, i, cur))
			else:
				if impact_mm != null:
					impact_mm.set_instance_transform(fx_i, _hidden_transform(true))
				if emote_mm != null:
					emote_mm.set_instance_transform(fx_i, _hidden_transform(true))
			fx_i += 1

		# Only clear the previously-visible range beyond the current count.
		var stale_to: int = prev_count[t]
		for i in range(count, stale_to):
			mm.set_instance_transform(i, _hidden_transform(false))
			if wm != null:
				wm.set_instance_transform(i, _hidden_transform(true))
			if bm != null:
				bm.set_instance_transform(i, _hidden_transform(true))
			rend_t[t][i] = _hidden_transform(false)
			prev_t[t][i] = _hidden_transform(false)
			target_t[t][i] = _hidden_transform(false)
			last_id[t][i] = -1
			slot_state[t][i] = 0
			slot_unkn[t][i] = false
			slot_flap[t][i] = 0.0
			slot_roll[t][i] = 0.0

		prev_count[t] = count

	# Hide shared-FX slots beyond the total rendered pigeon count.
	var vis_total: int = fx_i
	if shadow_mm != null:
		shadow_mm.visible_instance_count = vis_total
		for i in range(vis_total, max_instances):
			shadow_mm.set_instance_transform(i, _hidden_transform(true))
	if impact_mm != null:
		impact_mm.visible_instance_count = vis_total
		for i in range(vis_total, max_instances):
			impact_mm.set_instance_transform(i, _hidden_transform(true))
	if emote_mm != null:
		emote_mm.visible_instance_count = vis_total
		for i in range(vis_total, max_instances):
			emote_mm.set_instance_transform(i, _hidden_transform(true))

# Soft dark disc pinned to the ground under the pigeon. Scales down and fades
# with altitude by shrinking the quad; the material alpha is fixed per mesh so
# scale alone carries the height cue (visual-only, no simulation authority).
func _shadow_transform(bird: Transform3D) -> Transform3D:
	var ground_y: float = 0.02
	var h: float = maxf(0.0, bird.origin.y - ground_y)
	var s: float = clampf(0.55 - h * 0.12, 0.18, 0.55)
	var b: Basis = Basis().scaled(Vector3(s, 1.0, s))
	return Transform3D(b, Vector3(bird.origin.x, ground_y, bird.origin.z))

func _weapon_transform(t: int, i: int, bird: Transform3D, backplate: bool) -> Transform3D:
	if slot_unkn[t][i] or slot_state[t][i] != STATE_FIGHTING:
		return _hidden_transform(true)

	var s: float = ARCH_SCALE[t]
	var flap: float = slot_flap[t][i]
	var roll: float = slot_roll[t][i]

	# Base offset beside/above the bird, with a subtle deterministic swing
	# driven by the authoritative flap_phase.
	var offset: Vector3 = Vector3(0.62 * s, 0.58 * s, 0.0)
	offset.x += sin(flap * TAU) * 0.08 * s
	offset.y += cos(flap * TAU) * 0.05 * s

	# While FIGHTING, orbit/rotate the weapon around the bird using the
	# authoritative roll so it visibly spins with the simulation.
	offset = offset.rotated(Vector3.UP, roll)

	var pos: Vector3 = bird.origin + offset
	var basis: Basis
	if backplate:
		basis = Basis()
	else:
		# Slow deterministic spin on the icon itself for readability at distance.
		basis = Basis(Vector3.UP, fx_time * 1.5 + float(i) * 0.7)
	return Transform3D(basis, pos)

func _impact_transform(t: int, i: int, bird: Transform3D) -> Transform3D:
	var s: float = ARCH_SCALE[t]
	var phase: float = slot_flap[t][i] * TAU + float(i) * 1.3
	# Pulsing star beside/behind the fighter, opposite side from the weapon.
	var offset: Vector3 = Vector3(-0.52 * s, 0.38 * s, 0.0)
	offset = offset.rotated(Vector3.UP, slot_roll[t][i])
	offset += Vector3(0, sin(phase + fx_time * 6.0) * 0.06 * s, 0)
	var pulse: float = 1.0 + 0.25 * sin(phase * 2.0 + fx_time * 8.0)
	var spin: Basis = Basis(Vector3.UP, fx_time * 3.0).scaled(Vector3.ONE * pulse)
	return Transform3D(spin, bird.origin + offset)

func _emote_transform(t: int, i: int, bird: Transform3D) -> Transform3D:
	var s: float = ARCH_SCALE[t]
	var bob: float = sin(slot_flap[t][i] * TAU + fx_time * 2.2) * 0.05 * s
	return Transform3D(Basis(), bird.origin + Vector3(0.0, 0.72 * s + bob, 0.0))

# --- Read-only helpers for capture/debugging ---

# Enables/disables observer capture mode. While enabled, the renderer draws
# exactly the latest authoritative target transforms (no interpolation) and the
# FX clock tracks the authoritative tick (see apply_observer_tick). Normal mode
# is unaffected when this is false.
func set_observer_capture(enabled: bool, dt: float) -> void:
	_observer_mode = enabled
	_observer_dt = dt
	if enabled:
		target_alpha = 1.0

# Marks the authoritative tick currently being captured and snaps the render
# baseline to the latest target transforms so the next composed frame shows the
# exact simulation state for `tick` (one frame per tick, no interpolation).
func apply_observer_tick(tick: int) -> void:
	_observer_tick = tick
	target_alpha = 1.0
	for t in VARIANT_NAMES.size():
		for i in type_count[t]:
			prev_t[t][i] = target_t[t][i]
			rend_t[t][i] = target_t[t][i]

func get_variant_centroid(variant: int) -> Vector3:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return Vector3.ZERO
	var count: int = type_count[variant]
	if count == 0:
		return Vector3.ZERO
	var sum: Vector3 = Vector3.ZERO
	for i in count:
		sum += target_t[variant][i].origin
	return sum / float(count)

func get_variant_count(variant: int) -> int:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return 0
	return type_count[variant]

func get_variant_state_count(variant: int, state: int) -> int:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return 0
	var count: int = type_count[variant]
	var c: int = 0
	for i in count:
		if slot_state[variant][i] == state:
			c += 1
	return c

# Centroid of the rendered target transforms for pigeons of `variant` that are
# currently in `state`. Uses target_t (latest authoritative transform) so the
# observation point stays on real rendered positions. Returns Vector3.ZERO when
# no slot matches; never exposes the internal slot arrays.
func get_variant_state_centroid(variant: int, state: int) -> Vector3:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return Vector3.ZERO
	var count: int = type_count[variant]
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for i in count:
		if slot_state[variant][i] == state:
			sum += target_t[variant][i].origin
			n += 1
	if n == 0:
		return Vector3.ZERO
	return sum / float(n)

# Position of one concrete selected-variant pigeon in `state`. Returns the
# lowest-ID matching slot (slots are sorted by id) so the subject is a real,
# stable pigeon rather than a midpoint between separate fights. Returns
# Vector3.ZERO when no slot matches; never exposes the internal slot arrays.
func get_variant_state_position(variant: int, state: int) -> Vector3:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return Vector3.ZERO
	var count: int = type_count[variant]
	for i in count:
		if slot_state[variant][i] == state:
			return target_t[variant][i].origin
	return Vector3.ZERO

# Lowest rendered pigeon ID for `variant` currently in `state`, or -1.
# Slots are sorted by id, so the first match is deterministic.
func get_variant_state_subject_id(variant: int, state: int) -> int:
	if variant < 0 or variant >= VARIANT_NAMES.size():
		return -1
	var count: int = type_count[variant]
	for i in count:
		if slot_state[variant][i] == state:
			return last_id[variant][i]
	return -1

# True only after the concrete pigeon has a real submitted render transform.
# Capture uses this to avoid saving an empty first frame while a fresh snapshot
# has populated target state but the MultiMesh has not drawn yet.
func is_pigeon_rendered(id: int) -> bool:
	for t in VARIANT_NAMES.size():
		var count: int = type_count[t]
		for i in count:
			if last_id[t][i] == id:
				return rend_t[t][i].origin.y > -900.0
	return false

# Current rendered position for one pigeon by numeric id, or Vector3.ZERO if
# that id is not present. Before its first render pass, fall back to the latest
# authoritative target so capture can acquire the subject without exposing
# internal slot arrays.
func get_pigeon_position(id: int) -> Vector3:
	for t in VARIANT_NAMES.size():
		var count: int = type_count[t]
		for i in count:
			if last_id[t][i] == id:
				var rendered: Vector3 = rend_t[t][i].origin
				if rendered.y > -900.0:
					return rendered
				return target_t[t][i].origin
	return Vector3.ZERO
