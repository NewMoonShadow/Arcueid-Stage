extends Control
## Originals and labelled AI CG rebuilds, without stretching or story advancement.
const ROOT := "res://assets/characters/park_sequence/closeups/"
var current: Dictionary = {}
var previous: Dictionary = {}
var textures: Dictionary = {}
var backgrounds: Dictionary = {}
var blend := 1.0
var fade: Tween
var animation: Tween
var generation := 0
var reading := false
var motion_time := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	queue_redraw()

func _texture(path: String) -> Texture2D:
	if path.is_empty(): return null
	if not path.begins_with("res://"): path = ROOT + path
	if textures.has(path): return textures[path]
	var texture: Texture2D
	if ResourceLoader.exists(path):
		texture = load(path)
	elif FileAccess.file_exists(path):
		var raster := Image.load_from_file(ProjectSettings.globalize_path(path))
		if not raster.is_empty(): texture = ImageTexture.create_from_image(raster)
	textures[path] = texture
	return texture

func available(settings: Dictionary) -> bool:
	for panel in settings.get("panels", []):
		var image_path: String = panel.get("image", "")
		if not image_path.is_empty():
			if _texture(image_path) == null: return false
			continue
		var sprite: String = panel.get("sprite", "")
		if not sprite.is_empty() and _texture(sprite) == null: return false
		var key: String = panel.get("background", "")
		if not key.is_empty() and not backgrounds.has(key): return false
		if sprite.is_empty() and key.is_empty(): return false
	return not settings.get("panels", []).is_empty()

func reset() -> void:
	generation += 1
	if fade: fade.kill()
	if animation: animation.kill()
	current = {}
	previous = {}
	blend = 1.0
	hide()
	queue_redraw()

func present(settings: Dictionary, immediate: bool = false) -> bool:
	if not available(settings): return false
	if animation:
		animation.kill()
		animation = null
	if fade: fade.kill()
	previous = current.duplicate(true) if visible and not immediate else {}
	current = settings.duplicate(true)
	motion_time = 0.0
	blend = 1.0 if previous.is_empty() else 0.0
	show()
	if blend < 1.0:
		fade = create_tween()
		fade.tween_method(func(value: float): blend = value; queue_redraw(), 0.0, 1.0, float(settings.get("fade_seconds", .35)))
	queue_redraw()
	return true

func animate_to(settings: Dictionary, seconds: float) -> void:
	if animation: animation.kill()
	var token := generation
	animation = create_tween()
	animation.tween_interval(seconds)
	animation.tween_callback(func():
		if token == generation and visible: present(settings))

func set_reading(value: bool) -> void:
	if reading == value: return
	reading = value
	queue_redraw()

func _process(delta: float) -> void:
	if visible and float(current.get("motion_strength",0.0)) > 0.0:
		motion_time += delta
		queue_redraw()

func _draw() -> void:
	if current.is_empty(): return
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	if blend < 1.0: _draw_frame(previous, 1.0)
	_draw_frame(current, blend)

func _draw_frame(settings: Dictionary, alpha: float) -> void:
	var shade := 0.78 if reading else 1.0
	var tint: Array = settings.get("tint", [1.0, 1.0, 1.0])
	var color := Color(tint[0] * shade, tint[1] * shade, tint[2] * shade, alpha)
	for panel in settings.get("panels", []):
		var bounds: Array = panel.get("bounds", [0,0,1,1])
		var rect := Rect2(size * Vector2(bounds[0], bounds[1]), size * Vector2(bounds[2], bounds[3]))
		# Paint bars in the incoming frame too, so a wide image cannot linger beneath them.
		draw_rect(rect, Color(0,0,0,alpha))
		var image_path: String = panel.get("image", "")
		if not image_path.is_empty():
			var cg := _texture(image_path)
			if cg:
				var cg_size := cg.get_size()
				var cg_factor := maxf(rect.size.x/cg_size.x,rect.size.y/cg_size.y) * float(settings.get("zoom",1.0))
				var cg_crop_size := rect.size/cg_factor
				var cg_origin := (cg_size-cg_crop_size)*.5
				var strength: float = settings.get("motion_strength",0.0)
				cg_origin += Vector2(sin(motion_time*12.0)*2.0,cos(motion_time*9.0))*strength
				cg_origin = cg_origin.clamp(Vector2.ZERO,cg_size-cg_crop_size)
				draw_texture_rect_region(cg,rect,Rect2(cg_origin,cg_crop_size),color)
			continue
		var bg: Texture2D = backgrounds.get(panel.get("background", ""))
		if bg:
			var bg_size := bg.get_size()
			var factor := maxf(rect.size.x / bg_size.x, rect.size.y / bg_size.y)
			var crop := Rect2((bg_size - rect.size / factor) * 0.5, rect.size / factor)
			draw_texture_rect_region(bg, rect, crop, color)
		var sprite := _texture(panel.get("sprite", ""))
		if sprite == null: continue
		var focus: Array = panel.get("focus", [0,0])
		var anchor: Array = panel.get("anchor", [.5,.43])
		var factor: float = float(panel.get("scale", 1.0)) * size.y / 1080.0
		var position := rect.position + rect.size * Vector2(anchor[0], anchor[1]) - Vector2(focus[0], focus[1]) * factor
		var image_rect := Rect2(position, sprite.get_size() * factor)
		var clipped := image_rect.intersection(rect)
		if clipped.has_area():
			var crop := Rect2((clipped.position - position) / factor, clipped.size / factor)
			draw_texture_rect_region(sprite, clipped, crop, color)
		if float(bounds[1]) > 0.0 and float(bounds[3]) > .5 and float(bounds[3]) < 1.0:
			# Soft horizontal masks reproduce the original eye/mouth cut-ins.
			var depth := size.y * .045
			for step in 16:
				var edge := depth * float(step) / 16.0
				var opacity := alpha * (1.0 - float(step) / 16.0)
				draw_rect(Rect2(rect.position + Vector2(0,edge),Vector2(rect.size.x,depth/16.0+1)),Color(0,0,0,opacity))
				draw_rect(Rect2(Vector2(rect.position.x,rect.end.y-edge-depth/16.0),Vector2(rect.size.x,depth/16.0+1)),Color(0,0,0,opacity))
	var red: float = settings.get("red", 0.0)
	if red > 0.0: draw_rect(Rect2(Vector2.ZERO,size),Color(.7,0,.015,red * alpha))
