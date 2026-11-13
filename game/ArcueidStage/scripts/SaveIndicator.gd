extends CanvasLayer

const UI_THEME := preload("res://assets/ui/shared_theme.tres")
var panel: PanelContainer
var caption: Label
var dots: Label
var pending: Dictionary = {}
var recent_turns: Dictionary = {}
var serial := 0
var batch_failed := false
var shown_at := 0
var hide_at := 0
var elapsed := 0.0
var fade: Tween

func _ready() -> void:
	layer = 90
	panel = PanelContainer.new()
	panel.name = "SavingBadge"
	panel.theme = UI_THEME
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_left = -210
	panel.offset_right = -40
	panel.offset_top = -148
	panel.offset_bottom = -106
	var style := StyleBoxEmpty.new()
	panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 0)
	panel.add_child(row)
	caption = Label.new()
	caption.text = "Saving"
	_style_caption(caption)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(caption)
	dots = Label.new()
	dots.custom_minimum_size.x = 30
	_style_caption(dots)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(dots)
	panel.visible = false

func _style_caption(label: Label) -> void:
	label.add_theme_font_size_override("font_size", 23)
	label.add_theme_color_override("font_color", Color("#58d8ff"))
	label.add_theme_color_override("font_outline_color", Color(0.015, 0.10, 0.21, 0.8))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.28, 0.6, 0.8))
	label.add_theme_constant_override("shadow_offset_y", 2)

func begin() -> int:
	if pending.is_empty():
		batch_failed = false
	if fade and fade.is_valid():
		fade.kill()
	serial += 1
	pending[serial] = true
	hide_at = 0
	if not panel.visible:
		shown_at = Time.get_ticks_msec()
		panel.modulate.a = 0.0
		panel.visible = true
	panel.modulate = Color(1, 1, 1, panel.modulate.a)
	caption.text = "Saving"
	fade = create_tween()
	fade.tween_property(panel, "modulate:a", 1.0, 0.12)
	return serial

func finish(token: int, success: bool) -> void:
	if not pending.has(token):
		return
	pending.erase(token)
	batch_failed = batch_failed or not success
	if not pending.is_empty():
		return
	if batch_failed:
		caption.text = "Save failed"
		dots.text = ""
		panel.modulate = Color(1.0, 0.65, 0.65, 1.0)
		hide_at = Time.get_ticks_msec() + 1800
	else:
		hide_at = maxi(shown_at + 650, Time.get_ticks_msec() + 150)

func confirmed_turn(request_id: String) -> void:
	# turn.completed acknowledges that the backend has already committed the turn.
	if request_id.is_empty() or recent_turns.has(request_id):
		return
	recent_turns[request_id] = true
	if recent_turns.size() > 64:
		recent_turns.erase(recent_turns.keys()[0])
	var token := begin()
	finish(token, true)

func _process(delta: float) -> void:
	if not panel.visible:
		return
	elapsed += delta
	if not batch_failed or not pending.is_empty():
		dots.text = ".".repeat(int(elapsed * 3.5) % 4)
	if hide_at > 0 and Time.get_ticks_msec() >= hide_at:
		hide_at = 0
		if fade and fade.is_valid():
			fade.kill()
		fade = create_tween()
		fade.tween_property(panel, "modulate:a", 0.0, 0.25)
		fade.finished.connect(func() -> void: panel.visible = false)
