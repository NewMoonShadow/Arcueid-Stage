extends Control
## Native, clipped original portraits for the 8:45 confrontation. No video watermark.

const ROOT := "res://assets/characters/park_sequence/scripted/"
const FX := preload("res://assets/shaders/park_scripted_fx.gdshader")
const POSES := {
	"arc_shout": ["aru_a_00_07_n00.png", Vector2(550, 0), 1.08, -45.0],
	"arc_crossed": ["aru_a_00_05_n00.png", Vector2(565, 0), 1.08, -40.0],
	"arc_reply": ["aru_a_00_05_n02.png", Vector2(565, 0), 1.08, -40.0],
	"arc_eyes": ["aru_a_00_05_n02.png", Vector2(530, 430), 1.0, 0.0],
	"ciel_shout": ["sie_a_09_02_n01.png", Vector2(800, 0), 1.1, -35.0],
	"ciel_taunt": ["sie_a_09_01_n04.png", Vector2(800, 0), 1.1, -30.0],
	"ciel_closed": ["sie_a_09_03_n03.png", Vector2(800, 0), 1.1, -30.0],
	"ciel_eyes": ["sie_a_09_03_n01.png", Vector2(800, 370), 1.0, 0.0],
}

var panels: Dictionary = {}
var images: Dictionary = {}
var backdrops: Dictionary = {}
var cached: Dictionary = {}
var sky: TextureRect
var fx: ColorRect
var framing := "triptych"
var pose_names := {"arcueid":"arc_shout", "ciel":"ciel_shout"}
var shock := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := ColorRect.new()
	add_child(fill)
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fill.color = Color(0.005, 0.008, 0.018)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky = TextureRect.new()
	add_child(sky)
	sky.texture = _texture("sky_strip.png")
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for actor in ["arcueid", "ciel"]:
		var panel := Control.new()
		add_child(panel)
		panel.clip_contents = true
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var backdrop := TextureRect.new()
		panel.add_child(backdrop)
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		backdrop.texture = _texture("res://assets/backgrounds/park_sequence/" + ("img0521.png" if actor == "arcueid" else "img0535.png"))
		backdrop.modulate = Color(0.38, 0.38, 0.38)
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		backdrops[actor] = backdrop
		var image := TextureRect.new()
		panel.add_child(image)
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_SCALE
		panels[actor] = panel
		images[actor] = image
	fx = ColorRect.new()
	add_child(fx)
	fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = FX
	fx.material = material
	resized.connect(_layout)
	_layout()

func _texture(name: String) -> Texture2D:
	if cached.has(name):
		return cached[name]
	var path := name if name.begins_with("res://") else ROOT + name
	var texture: Texture2D
	if ResourceLoader.exists(path):
		texture = load(path)
	elif FileAccess.file_exists(path):
		var raster := Image.load_from_file(ProjectSettings.globalize_path(path))
		if not raster.is_empty():
			texture = ImageTexture.create_from_image(raster)
	cached[name] = texture
	return texture

func present(settings: Dictionary) -> void:
	var previous := framing
	framing = str(settings.get("layout", framing))
	for actor in ["arcueid", "ciel"]:
		var key := "arc_pose" if actor == "arcueid" else "ciel_pose"
		pose_names[actor] = settings.get(key, pose_names[actor])
	if framing == "shout" and previous != "shout":
		shock = 0.2
	_layout()

func _layout() -> void:
	if not is_instance_valid(sky) or size.x <= 0:
		return
	var eyes := framing.begins_with("eyes_")
	sky.visible = not eyes
	sky.position = Vector2(size.x * 0.415, 0)
	sky.size = Vector2(size.x * 0.17, size.y)
	for actor in panels:
		var panel: Control = panels[actor]
		var image: TextureRect = images[actor]
		panel.visible = not eyes or (actor == "arcueid" and framing == "eyes_arc") or (actor == "ciel" and framing == "eyes_ciel")
		backdrops[actor].visible = not eyes
		panel.position = Vector2.ZERO if eyes or actor == "arcueid" else Vector2(size.x * 0.585, 0)
		panel.size = size if eyes else Vector2(size.x * 0.415, size.y)
		var pose: Array = POSES.get(pose_names[actor], POSES["arc_shout"])
		image.texture = _texture(pose[0])
		if image.texture == null:
			continue
		var factor: float = size.x / 770.0 if eyes else float(pose[2]) * size.y / 1080.0
		image.size = image.texture.get_size() * factor
		var origin: Vector2 = pose[1]
		image.position = Vector2(panel.size.x * 0.5 - origin.x * factor, size.y * 0.43 - origin.y * factor) if eyes else Vector2(panel.size.x * 0.5 - origin.x * factor, float(pose[3]) * size.y / 1080.0)
	(fx.material as ShaderMaterial).set_shader_parameter("eye_frame", eyes)
	(fx.material as ShaderMaterial).set_shader_parameter("speed_lines", framing == "shout")

func set_reading(dimmed: bool) -> void:
	modulate = Color(0.78, 0.78, 0.78, 1) if dimmed else Color.WHITE

func _process(delta: float) -> void:
	if shock > 0:
		shock -= delta
		position = Vector2(sin(shock * 140) * 4, cos(shock * 120) * 2)
	else:
		position = Vector2.ZERO
