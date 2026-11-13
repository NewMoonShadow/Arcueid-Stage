extends RefCounted

# Original UI parts supplied in the project's UI folder.
const TEACHER_BUBBLE := preload("res://assets/ui/classroom/teacher-bubble.png")
const NECO_BUBBLE := preload("res://assets/ui/classroom/neco-bubble.png")
const UI_STYLE := preload("res://scripts/UiStyle.gd")
const FROST_EDGE := preload("res://assets/ui/classroom/frost-edge.png")
const MENU_VIGNETTE := preload("res://assets/ui/classroom/menu-vignette.png")

static func apply(stage) -> void:
	stage.theme = UI_STYLE.THEME
	_place(stage.get_node("SceneInfo"), Rect2(0.055, 0.275, 0.235, 0.17))
	stage.get_node("SceneInfo/Eyebrow").text = "―  AFTER SCHOOL / CLASSROOM"
	stage.get_node("SceneInfo/SceneRule").color = Color(0.5, 0.83, 0.95, 0.35)
	stage.get_node("SceneInfo").add_theme_constant_override("separation", 10)
	stage.get_node("TopBar/BrandText/BrandTitle").text = "教教我吧，爱尔奎特老师"
	stage.get_node("TopBar/BrandText/BrandSubtitle").text = "A PIECE OF BLUE GLASS MOON / AFTER SCHOOL"
	stage.get_node("TopBar").offset_top = 18.0
	stage.get_node("TopBar").offset_bottom = 76.0
	_place(stage.get_node("ClassroomHeader"), Rect2(0, 0, 1, 0.088))
	stage.get_node("ClassroomHeader").color = Color(0.018, 0.035, 0.10, 0.72)
	var edge := _image(FROST_EDGE)
	edge.modulate = Color(0.58, 0.88, 1.0, 0.4)
	stage.get_node("ClassroomHeader").add_child(edge)
	_place(edge, Rect2(0, 0.88, 1, 0.25))

	# Keep the close framing, with the actors flanking the central dialogue column.
	stage.get_node("/root/StageDirector").set_portrait_bounds(Rect2(0.41, 0.09, 0.70, 1.50))
	_place(stage.get_node("%ArcueidBubble"), Rect2(0.315, 0.405, 0.345, 0.235))
	_place(stage.get_node("%NecoPortrait"), Rect2(0.045, 0.625, 0.14, 0.28))
	_place(stage.get_node("%NecoBubble"), Rect2(0.195, 0.665, 0.345, 0.155))
	_bubble(stage.get_node("%ArcueidBubble"), TEACHER_BUBBLE, 78, 65, 65, 35)
	_bubble(stage.get_node("%NecoBubble"), NECO_BUBBLE, 44, 34, 42, 25)
	stage.get_node("ArcueidBubble/Rows/Name").text = "アルクェイド  /  爱尔奎特"
	stage.get_node("NecoBubble/NecoBubbleRows/NecoName").text = "ネコアルク  /  猫姬"
	for line in [stage.get_node("%ArcueidLine"), stage.get_node("%NecoLine")]:
		line.add_theme_font_size_override("font_size", UI_STYLE.BODY_SIZE)
		line.add_theme_color_override("font_color", Color("#f0f7ff"))
		line.add_theme_constant_override("line_spacing", 6)
	stage.get_node("%ArcueidScroll").custom_minimum_size.y = 105
	stage.get_node("%NecoScroll").custom_minimum_size.y = 68
	for scroll in [stage.get_node("%ArcueidScroll"), stage.get_node("%NecoScroll")]:
		_scroll_style(scroll)

	_place(stage.get_node("ToolRail"), Rect2(0.865, 0.13, 0.10, 0.225))
	stage.get_node("ToolRail").add_theme_constant_override("separation", 14)
	stage.get_node("%MemoryButton").text = "对话记录"
	for button in [stage.get_node("%MemoryButton"), stage.get_node("%SettingsButton"), stage.get_node("%SaveButton")]:
		button.custom_minimum_size = Vector2(176, 48)
	stage.get_node("%SettingsButton").text = "系统设置"
	stage.get_node("%ReturnButton").text = "返回标题"
	_place(stage.get_node("%ReturnButton"), Rect2(0.05, 0.92, 0.11, 0.043))
	_place(stage.get_node("%ClassroomSpeakerRow"), Rect2(0.215, 0.846, 0.31, 0.044))
	stage.get_node("%ClassroomSpeakerRow").add_theme_constant_override("separation", 14)
	stage.get_node("ClassroomSpeakerRow/Label").text = "CHAT / 自由交流"
	stage.speaker_option.custom_minimum_size = Vector2(176, 40)
	_place(stage.chat_dock_button, Rect2(0.215, 0.92, 0.17, 0.043))
	_place(stage.dialogue_layer, Rect2(0.215, 0.92, 0.745, 0.052))
	stage.composer_rest_y = stage.dialogue_layer.position.y
	stage.send_button.text = "发送  ›"
	stage.get_node("%ChatLogButton").text = "记录"
	for button in stage.find_children("*", "Button", true, false):
		var in_overlay: bool = stage.get_node("OverlayLayer").is_ancestor_of(button)
		UI_STYLE.scene_button(button, UI_STYLE.BUTTON_BODY_SIZE if in_overlay or button is OptionButton else UI_STYLE.BUTTON_ACTION_SIZE)
	stage.get_node("%SettingsButton").tooltip_text = "系统设置"
	stage.get_node("%ReturnButton").tooltip_text = "返回标题界面"
	for panel in [stage.chat_log_panel, stage.settings_panel, stage.save_panel]:
		var style := StyleBoxTexture.new()
		style.texture = MENU_VIGNETTE
		style.content_margin_left = 36
		style.content_margin_right = 36
		style.content_margin_top = 28
		style.content_margin_bottom = 28
		panel.add_theme_stylebox_override("panel", style)
	stage.chat_log_panel.get_node("Rows/Top/Headings/Title").text = "对话记录"
	stage.chat_log_panel.get_node("Rows/Top/Headings/Kicker").text = "BACKLOG / CLASSROOM"
	stage.chat_log_panel.get_node("Rows/ChatLogNote").text = "按时间顺序记录你与爱尔奎特、猫姬的课堂对话。"
	var field: StyleBoxFlat = stage._make_field_style()
	field.set_corner_radius_all(0)
	field.border_color = Color(0.28, 0.70, 0.91, 0.65)
	stage.input_box.add_theme_stylebox_override("normal", field)
	var focused: StyleBoxFlat = field.duplicate()
	focused.border_color = Color(0.35, 0.91, 1.0, 1.0)
	stage.input_box.add_theme_stylebox_override("focus", focused)
	stage.speaker_option.get_popup().theme = UI_STYLE.THEME
	UI_STYLE.typography(stage)

static func _place(control: Control, bounds: Rect2) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	control.anchor_left = bounds.position.x
	control.anchor_top = bounds.position.y
	control.anchor_right = bounds.end.x
	control.anchor_bottom = bounds.end.y
	control.offset_left = 0
	control.offset_top = 0
	control.offset_right = 0
	control.offset_bottom = 0

static func _image(texture: Texture2D) -> TextureRect:
	var image := TextureRect.new()
	image.texture = texture
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	return image

static func _bubble(panel: PanelContainer, texture: Texture2D, left: float, top: float, right: float, bottom: float) -> void:
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.modulate_color = Color(0.78, 0.90, 1.0, 0.92)
	style.content_margin_left = left
	style.content_margin_top = top
	style.content_margin_right = right
	style.content_margin_bottom = bottom
	panel.add_theme_stylebox_override("panel", style)

static func _scroll_style(scroll: ScrollContainer) -> void:
	var bar := scroll.get_v_scroll_bar()
	bar.custom_minimum_size.x = 5
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.35, 0.77, 0.91, 0.5)
		style.content_margin_left = 2
		style.content_margin_right = 2
		bar.add_theme_stylebox_override(state, style)
