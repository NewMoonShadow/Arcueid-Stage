extends Node

const FEEDBACK := preload("res://scripts/ButtonFeedback.gd")
const STYLE := preload("res://scripts/UiStyle.gd")

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_install.call_deferred(node)

func _install(button: BaseButton) -> void:
	if is_instance_valid(button) and button.is_inside_tree() and not button.is_queued_for_deletion():
		if button is Button and button.find_parent("Title") == null:
			var font_size := button.get_theme_font_size("font_size") if button.has_theme_font_size_override("font_size") else STYLE.BUTTON_BODY_SIZE
			STYLE.scene_button(button, font_size)
		else:
			FEEDBACK.install(button)
