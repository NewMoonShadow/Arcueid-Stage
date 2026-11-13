extends Node

signal character_changed(character_id: String)

var portrait: TextureRect
var manifests: Dictionary = {}
var current_character_id := "arcueid"
var rest_position := Vector2.ZERO
var rest_top := 0.0
var rest_bottom := 0.0
var switching := false
var current_expression := "neutral"
var expression_scale := 1.0
var expression_tween: Tween
var normal_texture: Texture2D
var idle_elapsed := 0.0
var next_blink := 3.8
var blink_until := 0.0
var speaking_until := 0.0
var speaking_weight := 0.0
var reaction := 0.0
var reaction_elapsed := 1.0
var performance_state := "listening"
var last_performed_expression := ""
var last_request_id := ""
var variant_bags: Dictionary = {}
var selected_asset := ""
var previous_layer: TextureRect
var fade_elapsed := 1.0
var has_entered := true
var entrance_direction := 1.0
var entrance_tween: Tween
const ARCUEID_SCALE := 4400.0 / 4243.0
const CIEL_SCALE := 4400.0 / 4296.0
# Shared story framing: right side, head near 15% of screen height, feet below frame.
# Scenes may shift the shared framing horizontally through set_portrait_bounds.
const PORTRAIT_BOUNDS := Rect2(0.41, 0.15, 0.70, 1.50)
const GESTURES := {
	"listening": Vector3(0.8, 1.0, 0.0),
	"thoughtful": Vector3(0.45, 1.6, 0.010),
	"playful": Vector3(1.5, 2.7, 0.008),
	"firm": Vector3(0.4, 2.0, 0.0),
	"startled": Vector3(0.7, 4.0, -0.012),
	"gentle": Vector3(0.3, 0.7, -0.005),
}
const EXPRESSION_GESTURES := {
	"curious": "thoughtful", "thinking": "thoughtful", "shy": "thoughtful",
	"smile": "playful", "laughing": "playful", "wink": "playful", "proud": "playful", "teasing": "playful", "delighted": "playful",
	"serious": "firm", "annoyed": "firm", "surprised": "startled", "pouting": "gentle", "sad": "gentle",
	"confident": "playful", "concerned": "thoughtful", "stern": "firm",
}

func bind(target: TextureRect) -> void:
	if entrance_tween and entrance_tween.is_valid():
		entrance_tween.kill()
	portrait = target
	has_entered = true
	portrait.visible = true
	portrait.modulate.a = 1.0
	_apply_portrait_layout()
	rest_position = portrait.position
	rest_top = portrait.offset_top
	rest_bottom = portrait.offset_bottom
	idle_elapsed = 0.0
	next_blink = randf_range(3.2, 5.2)
	blink_until = 0.0
	speaking_until = 0.0
	speaking_weight = 0.0
	reaction = 0.0
	expression_scale = 1.0
	last_performed_expression = ""
	last_request_id = ""
	variant_bags.clear()
	selected_asset = ""
	normal_texture = null
	previous_layer = TextureRect.new()
	previous_layer.name = "ArcueidPoseTransition"
	previous_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	previous_layer.expand_mode = portrait.expand_mode
	previous_layer.stretch_mode = portrait.stretch_mode
	previous_layer.texture_filter = portrait.texture_filter
	previous_layer.modulate.a = 0.0
	portrait.add_child(previous_layer)
	previous_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	switching = false
	if not portrait.resized.is_connected(_update_pivot):
		portrait.resized.connect(_update_pivot)
	_update_pivot()
	for character_id in ["arcueid", "ciel"]:
		var path := "res://assets/character_manifest.json" if character_id == "arcueid" else "res://assets/ciel_manifest.json"
		var manifest_file := FileAccess.open(path, FileAccess.READ)
		if manifest_file:
			var parsed = JSON.parse_string(manifest_file.get_as_text())
			if parsed is Dictionary:
				manifests[character_id] = parsed
	set_expression("neutral")

func set_portrait_bounds(bounds: Rect2) -> void:
	if not is_instance_valid(portrait):
		return
	_apply_portrait_layout(bounds)
	rest_position = portrait.position
	rest_top = portrait.offset_top
	rest_bottom = portrait.offset_bottom
	_update_pivot()

func _apply_portrait_layout(bounds: Rect2 = PORTRAIT_BOUNDS) -> void:
	portrait.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	portrait.anchor_left = bounds.position.x
	portrait.anchor_top = bounds.position.y
	portrait.anchor_right = bounds.end.x
	portrait.anchor_bottom = bounds.end.y
	portrait.offset_left = 0.0
	portrait.offset_top = 0.0
	portrait.offset_right = 0.0
	portrait.offset_bottom = 0.0
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE

func hide_until_first_speech(direction: float) -> void:
	has_entered = false
	entrance_direction = direction
	portrait.visible = false
	portrait.modulate.a = 0.0

func _enter_on_first_speech() -> void:
	if has_entered:
		return
	has_entered = true
	portrait.visible = true
	portrait.modulate.a = 0.0
	portrait.position.x = rest_position.x + entrance_direction * 72.0
	entrance_tween = create_tween().set_parallel(true)
	entrance_tween.tween_property(portrait, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	entrance_tween.tween_property(portrait, "position:x", rest_position.x, 0.55).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)

func switch_character(character_id: String) -> void:
	if portrait == null or character_id not in manifests or character_id == current_character_id or switching:
		return
	switching = true
	previous_layer.modulate.a = 0.0
	fade_elapsed = 1.0
	blink_until = 0.0
	portrait.texture = normal_texture
	stop_speaking()
	var departure := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
	departure.tween_property(portrait, "modulate:a", 0.0, 0.18)
	departure.tween_property(portrait, "position:x", rest_position.x + 65.0, 0.18)
	await departure.finished
	current_character_id = character_id
	last_request_id = ""
	normal_texture = null
	selected_asset = ""
	set_expression("neutral")
	portrait.position = rest_position - Vector2(65.0, 0.0)
	var arrival := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
	arrival.tween_property(portrait, "modulate:a", 1.0, 0.26)
	arrival.tween_property(portrait, "position:x", rest_position.x, 0.26)
	await arrival.finished
	switching = false
	character_changed.emit(character_id)

func present(presentation: Dictionary, duration: float) -> void:
	var actor := str(presentation.get("speaker_id", "arcueid"))
	if actor != current_character_id:
		return
	var request_id := str(presentation.get("request_id", ""))
	var next := str(presentation.get("expression", "neutral"))
	var vary := request_id != last_request_id or next != current_expression
	last_request_id = request_id
	set_expression(next, actor, vary)
	start_speaking(duration, actor)

func set_expression(expression: String, character_id: String = "", vary: bool = false) -> void:
	if not is_instance_valid(portrait) or (not character_id.is_empty() and character_id != current_character_id):
		return
	var manifest: Dictionary = manifests.get(current_character_id, {})
	var resolved := expression if expression in manifest else "neutral"
	if resolved == current_expression and normal_texture != null and portrait.texture == normal_texture and not vary:
		return
	var entry: Dictionary = manifest.get(resolved, {})
	var asset_path: String = entry.get("asset", "")
	var variants: Array = entry.get("variants", [])
	if not variants.is_empty():
		var bag_key := current_character_id + ":" + resolved
		var bag: Array = variant_bags.get(bag_key, [])
		if bag.is_empty():
			bag = variants.duplicate()
			bag.shuffle()
		if bag.size() > 1 and str(bag[-1].get("asset", "")) == selected_asset:
			var first = bag[0]
			bag[0] = bag[-1]
			bag[-1] = first
		entry = bag.pop_back()
		variant_bags[bag_key] = bag
		asset_path = str(entry.get("asset", ""))
	if not asset_path.is_empty():
		if normal_texture != null and selected_asset != asset_path:
			previous_layer.texture = normal_texture
			fade_elapsed = 0.0
		else:
			fade_elapsed = 1.0
		portrait.texture = load(asset_path)
		selected_asset = asset_path
	normal_texture = portrait.texture
	current_expression = expression if expression in manifest else "neutral"
	blink_until = 0.0
	var scale_target := 1.002 if expression in ["smile", "curious"] else 1.0
	if expression_tween and expression_tween.is_valid():
		expression_tween.kill()
	expression_tween = create_tween().set_trans(Tween.TRANS_SINE)
	expression_tween.tween_property(self, "expression_scale", scale_target, 0.18)

func _update_pivot() -> void:
	if is_instance_valid(portrait):
		portrait.pivot_offset = Vector2(portrait.size.x * 0.5, portrait.size.y)

func _process(delta: float) -> void:
	if not is_instance_valid(portrait) or switching:
		return
	idle_elapsed += delta
	fade_elapsed += delta
	previous_layer.modulate.a = 1.0 - smoothstep(0.0, 0.14, fade_elapsed)
	var speaking := idle_elapsed < speaking_until
	if is_instance_valid(AudioController.player) and AudioController.player.playing and str(AudioController.current_presentation.get("speaker_id", "")) == current_character_id:
		speaking = true
	speaking_weight = move_toward(speaking_weight, 1.0 if speaking else 0.0, delta / (0.15 if speaking else 0.25))
	performance_state = "speaking" if speaking else "settling" if speaking_weight > 0.0 else "listening"
	reaction_elapsed += delta
	var nod := -sin(minf(reaction_elapsed / 0.42, 1.0) * PI) * reaction
	var gesture: Vector3 = GESTURES[str(EXPRESSION_GESTURES.get(current_expression, "listening"))]
	if current_character_id == "ciel" and current_expression == "explaining":
		gesture = GESTURES["thoughtful"]
	var speaking_offset := sin(idle_elapsed * 3.0) * gesture.x * speaking_weight
	portrait.offset_top = rest_top + speaking_offset + nod
	portrait.offset_bottom = rest_bottom + speaking_offset + nod
	var breath := sin(idle_elapsed * 1.7) * (0.002 if current_character_id == "arcueid" else 0.0015)
	var canvas_scale := ARCUEID_SCALE if current_character_id == "arcueid" else CIEL_SCALE
	portrait.scale = Vector2.ONE * canvas_scale * (expression_scale + breath)
	portrait.rotation = lerpf(portrait.rotation, gesture.z * speaking_weight, minf(delta * 7.0, 1.0))
	if blink_until > 0.0 and idle_elapsed >= blink_until:
		blink_until = 0.0
		portrait.texture = normal_texture
	if idle_elapsed < next_blink:
		return
	next_blink = idle_elapsed + randf_range(3.2, 5.2)
	if current_character_id != "arcueid" or speaking_weight > 0.05:
		return
	if is_instance_valid(AudioController.player) and AudioController.player.playing:
		return
	var manifest: Dictionary = manifests.get(current_character_id, {})
	var entry: Dictionary = manifest.get(current_expression, {})
	var blink_path := str(entry.get("blink_asset", ""))
	if not blink_path.is_empty():
		portrait.texture = load(blink_path)
		blink_until = idle_elapsed + 0.14

func talk_pulse(character_id: String = "") -> void:
	if not is_instance_valid(portrait) or switching or (not character_id.is_empty() and character_id != current_character_id):
		return
	speaking_until = maxf(speaking_until, idle_elapsed + 0.25)

func start_speaking(duration: float, character_id: String = "") -> void:
	if not is_instance_valid(portrait) or (not character_id.is_empty() and character_id != current_character_id):
		return
	_enter_on_first_speech()
	if speaking_weight < 0.1 or (current_expression != last_performed_expression and current_expression in ["surprised", "annoyed"]):
		reaction = GESTURES[str(EXPRESSION_GESTURES.get(current_expression, "listening"))].y
		reaction_elapsed = 0.0
	last_performed_expression = current_expression
	speaking_until = idle_elapsed + maxf(duration, 0.1)

func stop_speaking(character_id: String = "") -> void:
	if not character_id.is_empty() and character_id != current_character_id:
		return
	speaking_until = idle_elapsed
