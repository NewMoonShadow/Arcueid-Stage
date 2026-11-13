extends Control

const MOON_SHADER := preload("res://assets/shaders/moon_activity.gdshader")
@export_range(1.0, 12.0, 0.1) var cycle_seconds := 5.0
var phase := 0.0
var angle := 0.0
var moon_material: ShaderMaterial

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	moon_material = ShaderMaterial.new()
	moon_material.shader = MOON_SHADER
	var surface := ColorRect.new()
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.material = moon_material
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _process(delta: float) -> void:
	phase = fmod(phase + delta * TAU / cycle_seconds, TAU)
	# Slow around the upright crescent, smoothly accelerate through the far side.
	# The derivative stays positive, so the moon never pauses or reverses.
	angle = phase - 0.78 * sin(phase)
	moon_material.set_shader_parameter("angle", angle)
