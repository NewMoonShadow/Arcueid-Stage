extends RefCounted

const THEME := preload("res://assets/ui/shared_theme.tres")
const FEEDBACK := preload("res://scripts/ButtonFeedback.gd")
const TEXT_GLASS := preload("res://assets/shaders/ui_text_glass.gdshader")
const ACTION_SIZE := 30
const BODY_SIZE := 24
const NAME_SIZE := 18
const CAPTION_SIZE := 16
const BUTTON_ACTION_SIZE := 24
const BUTTON_BODY_SIZE := 20

static func text_button(button: Button, font_size: int = BUTTON_ACTION_SIZE) -> void:
	button.theme = THEME
	button.add_theme_font_override("font", THEME.default_font)
	button.add_theme_font_size_override("font_size", font_size)
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		button.add_theme_color_override(state, Color("#fafcff"))
	var text_material := button.material as ShaderMaterial
	if not text_material or text_material.shader != TEXT_GLASS:
		text_material = ShaderMaterial.new()
		text_material.shader = TEXT_GLASS
		button.material = text_material
	text_material.set_shader_parameter("font_height", font_size * 1.35)
	button.add_theme_color_override("font_disabled_color", Color(0.62, 0.72, 0.79, 0.65))
	button.add_theme_color_override("font_shadow_color", Color(0.015, 0.04, 0.11, 0.9))
	button.add_theme_constant_override("shadow_offset_y", 2)
	button.add_theme_color_override("font_outline_color", Color(0.015, 0.10, 0.21, 0.8))
	button.add_theme_constant_override("outline_size", 2)
	if not button.has_meta("compact_ui"):
		button.custom_minimum_size *= 0.82
		button.set_meta("compact_ui", true)
	if not button is CheckButton:
		button.flat = true
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			var style := StyleBoxEmpty.new()
			style.content_margin_left = 8
			style.content_margin_right = 8
			style.content_margin_top = 4
			style.content_margin_bottom = 4
			button.add_theme_stylebox_override(state, style)
	FEEDBACK.install(button)

static func scene_button(button: Button, font_size: int = BUTTON_BODY_SIZE) -> void:
	text_button(button, font_size)
	button.flat = false
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := StyleBoxEmpty.new()
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		button.add_theme_stylebox_override(state, style)

static func typography(root: Node) -> void:
	for node in root.find_children("*", "Control", true, false):
		if node is Label:
			var label := node as Label
			label.add_theme_font_override("font", THEME.default_font)
			label.add_theme_font_size_override("font_size", _label_size(label))
		elif node is RichTextLabel:
			var text := node as RichTextLabel
			text.add_theme_font_override("normal_font", THEME.default_font)
			text.add_theme_font_size_override("normal_font_size", BODY_SIZE)
		elif node is LineEdit or node is TextEdit:
			var field := node as Control
			field.add_theme_font_override("font", THEME.default_font)
			field.add_theme_font_size_override("font_size", BODY_SIZE)

static func _label_size(label: Label) -> int:
	var name := str(label.name)
	if name in ["Title", "SceneTitle"]:
		return ACTION_SIZE
	if name in ["ArcueidLine", "NecoLine", "BrandTitle"]:
		return BODY_SIZE
	if name in ["Name", "NecoName", "SpeakerSubtitle"]:
		return NAME_SIZE
	if name.contains("Subtitle") or name.contains("Note") or name.contains("Status") or name.contains("Label") or name.contains("Description") or name in ["Kicker", "Eyebrow", "MemoryTeaser", "VoiceBadge", "CoreAddressValue", "VoiceAddressValue"]:
		return CAPTION_SIZE
	return BODY_SIZE
