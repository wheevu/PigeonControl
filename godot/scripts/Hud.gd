extends Label
class_name PigeonHud

# Text HUD from authoritative stats only. No sim decisions, no styling battles.
# Keys: B bread, H human, C clear, K dusk, 1-4 cameras.

var receiver: Node
var swarm: Node3D
var director: Node

func setup(r: Node, s: Node3D, d: Node) -> void:
	receiver = r
	swarm = s
	director = d
	position = Vector2(14, 38)
	add_theme_color_override("font_color", Color(1, 1, 1))
	add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	add_theme_constant_override("shadow_offset_x", 1)
	add_theme_constant_override("shadow_offset_y", 1)
	if ResourceLoader.exists("res://assets/2d/Kenney_Pixel.ttf"):
		add_theme_font_override("font", load("res://assets/2d/Kenney_Pixel.ttf"))
	add_theme_font_size_override("font_size", 16)

func _process(_delta: float) -> void:
	if receiver == null or swarm == null:
		return
	var tick: int = receiver.latest_applied_tick
	var stats: Dictionary = receiver.latest_stats
	var fighting: int = int(stats.get("fighting", 0)) if not stats.is_empty() else _count_state(6)
	var fleeing: int = int(stats.get("fleeing", 0)) if not stats.is_empty() else _count_state(3)
	var eating: int = int(stats.get("eating", 0)) if not stats.is_empty() else _count_state(2)
	var food_left: float = float(stats.get("food_left", 0.0)) if not stats.is_empty() else 0.0
	var cam: String = director.mode_name() if director != null and director.has_method("mode_name") else "FREECAM"
	var threat: String = "none"
	if not receiver.latest_threat.is_empty() and bool(receiver.latest_threat.get("active", false)):
		threat = "(%.0f, %.0f)" % [float(receiver.latest_threat.get("x", 0.0)), float(receiver.latest_threat.get("z", 0.0))]
	text = "tick %d  fight %d  flee %d  eat %d  food %.0f  threat %s  [%s]\n[B] bread  [H] human  [C] clear  [K] dusk  [1-4] cam" % [tick, fighting, fleeing, eating, food_left, threat, cam]

func _count_state(state: int) -> int:
	var total: int = 0
	for v in 4:
		if swarm.has_method("get_variant_state_count"):
			total += swarm.get_variant_state_count(v, state)
	return total
