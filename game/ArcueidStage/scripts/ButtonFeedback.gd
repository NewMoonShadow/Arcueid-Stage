extends Control

const EFFECT := preload("res://assets/shaders/button_feedback.gdshader")
var button: BaseButton
var enabled := true
var hovered := false
var held := false
var resting_scale := Vector2.ONE
var motion: Tween
var sweep: Tween
var pulse: Tween
var effect_material: ShaderMaterial

static func install(target: BaseButton) -> Control:
	var existing := target.get_node_or_null("ButtonFeedback")
	if existing != null:
		return existing as Control
	var feedback := load("res://scripts/ButtonFeedback.gd").new() as Control
	feedback.name = "ButtonFeedback"
	target.add_child(feedback)
	return feedback

func _ready() -> void:
	button = get_parent() as BaseButton
	show_behind_parent = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resting_scale = button.scale
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_color_override("font_hover_color", Color("#71edff"))
	button.add_theme_color_override("font_focus_color", Color("#71edff"))
	button.add_theme_color_override("font_pressed_color", Color("#c7faff"))
	button.resized.connect(_update_pivot)
	_update_pivot()
	effect_material = ShaderMaterial.new()
	effect_material.shader = EFFECT
	effect_material.set_shader_parameter("hover", 0.0)
	effect_material.set_shader_parameter("press", 0.0)
	effect_material.set_shader_parameter("pulse", 1.0)
	effect_material.set_shader_parameter("sweep", 1.2)
	var surface := ColorRect.new()
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.material = effect_material
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.mouse_entered.connect(_hover.bind(true))
	button.mouse_exited.connect(_hover.bind(false))
	button.focus_entered.connect(_hover.bind(true))
	button.focus_exited.connect(_hover.bind(false))
	button.button_down.connect(_press)
	button.button_up.connect(_release)
	button.pressed.connect(_confirm)
	button.visibility_changed.connect(_reset_if_hidden)

func _update_pivot() -> void:
	button.pivot_offset = button.size * 0.5

func _process(_delta: float) -> void:
	if hovered and not held:
		effect_material.set_shader_parameter("pointer", (button.get_local_mouse_position() / button.size.max(Vector2.ONE)).clamp(Vector2.ZERO, Vector2.ONE))
	if button.material is ShaderMaterial:
		button.material.set_shader_parameter("control_size", button.size)
	if (button.disabled or not enabled) and (hovered or held):
		hovered = false
		held = false
		_animate()

func _hover(_entering: bool) -> void:
	if not enabled or button.disabled:
		return
	var next := button.is_hovered() or button.has_focus()
	if next and not hovered:
		if sweep:
			sweep.kill()
		effect_material.set_shader_parameter("sweep", -0.2)
		sweep = create_tween()
		sweep.tween_method(_set_sweep, -0.2, 1.2, 0.5).set_trans(Tween.TRANS_SINE)
	hovered = next
	_animate()

func _press() -> void:
	if not enabled or button.disabled:
		return
	held = true
	var local := button.get_local_mouse_position() / button.size.max(Vector2.ONE)
	effect_material.set_shader_parameter("origin", local.clamp(Vector2.ZERO, Vector2.ONE))
	_animate()

func _release() -> void:
	held = false
	_animate(true)

func _confirm() -> void:
	if not enabled or button.disabled:
		return
	if pulse:
		pulse.kill()
	effect_material.set_shader_parameter("pulse", 0.0)
	pulse = create_tween()
	pulse.tween_method(_set_pulse, 0.0, 1.0, 0.4).set_trans(Tween.TRANS_SINE)

func _animate(rebound: bool = false) -> void:
	if motion:
		motion.kill()
	var target_scale := 0.975 if held else (1.025 if hovered else 1.0)
	motion = create_tween().set_parallel(true)
	motion.tween_property(button, "scale", resting_scale * target_scale, 0.23 if rebound else 0.14).set_trans(Tween.TRANS_BACK if rebound else Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var current: float = effect_material.get_shader_parameter("hover")
	motion.tween_method(_set_hover, current, 1.0 if hovered else 0.0, 0.18)
	var current_press: float = effect_material.get_shader_parameter("press")
	motion.tween_method(_set_press, current_press, 1.0 if held else 0.0, 0.10)

func _reset_if_hidden() -> void:
	if button.is_visible_in_tree():
		return
	for tween in [motion, sweep, pulse]:
		if tween:
			tween.kill()
	hovered = false
	held = false
	button.scale = resting_scale
	_set_hover(0.0)
	_set_press(0.0)
	_set_pulse(1.0)

func _set_hover(value: float) -> void:
	effect_material.set_shader_parameter("hover", value)
	if button.material is ShaderMaterial:
		button.material.set_shader_parameter("hover", value)

func _set_press(value: float) -> void:
	effect_material.set_shader_parameter("press", value)

func _set_sweep(value: float) -> void:
	effect_material.set_shader_parameter("sweep", value)

func _set_pulse(value: float) -> void:
	effect_material.set_shader_parameter("pulse", value)
