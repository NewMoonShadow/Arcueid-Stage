extends Control
## Per-shot free dialogue, guarded exits and transparent NVL staging.
const UI_STYLE := preload("res://scripts/UiStyle.gd")
const STORY_CAST := preload("res://scripts/StoryCast.gd")
const PARK_VOICE := preload("res://scripts/ParkVoice.gd")
const SCRIPTED_STAGE := preload("res://scripts/ParkScriptedStage.gd")
const CLOSEUP_STAGE := preload("res://scripts/ParkCloseupStage.gd")
const SEQUENCE_PATH := "res://data/park_sequence.json"
const PROGRESS_PATH := "user://park_dialogue_progress.json"
@export var restore_progress := true
@export var enable_scene_sessions := true

var sequence: Dictionary = {}
var cues: Array = []
var textures: Dictionary = {}
var cue_index := -1
var transition: Tween
var cast: Node
var voice: Node
var scripted_stage: Control
var closeup_stage: Control
var visual_track_done := true
var composer_row: Control
var controls_row: Control
var script_finish_busy := false
var script_retry_button: Button
var normal_dialogue_font: Font
var scripted_dialogue_font: SystemFont
var voice_button: Button
var ui_root: Control
var dialogue_text: RichTextLabel
var input_box: LineEdit
var text_button: Button
var marker_root: Control
var cue_title: Label
var trigger_label: Label
var note_label: RichTextLabel
var hint_label: RichTextLabel
var reader_title: Label
var reader_mode := "history"
var history_panel: Control
var history_text: RichTextLabel
var history_request: HTTPRequest
var opening_logged := false
var opening_read := false
var opening_log_request: HTTPRequest
var debug_base := ""
var debug_prepare := ""
var debug_intent := ""
var local_transcript: Array[Dictionary] = []
var previous_button: Button
var next_button: Button
var jump: OptionButton
var status: Label
var page_lines: Array[String] = []
var text_tween: Tween
var text_visible := true
var markers_visible := false
var clean_view := false
var reading_shade: ColorRect
var shade_tween: Tween
var shade_active := false
var dialogue_request: HTTPRequest
var dialogue_generation := 0
var dialogue_busy := false
var dialogue_history: Array[Dictionary] = []
var decisions: Dictionary = {}
var ended := false
var opening_running := false
var opening_page_lines: Array[String] = []
var line_presentation: Dictionary = {}
var line_audio_started := false
var line_audio_done := false
var line_skip_text := false
var pending_action := false
var scene_session_id := ""
var previous_session_id := ""
var scene_revision := 0
var scene_ready := false
var prepare_request: HTTPRequest
var commit_request: HTTPRequest
var active_turn_id := ""
var prepared_history: Array = []
const PARK_CIEL_BOUNDS := Rect2(0.015, 0.15, 0.70, 1.50)
signal player_line_submitted(text: String, cue_id: String)

@onready var background: Control = $Background
@onready var outgoing: Control = $Outgoing
@onready var character_stage: Control = $CharacterStage

func _ready() -> void:
	theme = UI_STYLE.THEME
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SEQUENCE_PATH))
	if not parsed is Dictionary:
		push_error("公园镜头数据读取失败")
		return
	sequence = parsed
	cues = sequence.get("cues", [])
	for key in sequence.get("assets", {}):
		var path: String = sequence["assets"][key]["path"]
		if ResourceLoader.exists(path):
			textures[key] = load(path)
	cast = STORY_CAST.new()
	add_child(cast)
	cast.bind($CharacterStage/ArcueidPortrait, $CharacterStage/CielPortrait)
	cast.actors["ciel"].set_portrait_bounds(PARK_CIEL_BOUNDS)
	var park_manifest = JSON.parse_string(FileAccess.get_file_as_string("res://data/park_cast.json"))
	for actor_id in cast.actors:
		var actor = cast.actors[actor_id]
		actor.manifests[actor_id] = park_manifest[actor_id]
		actor.normal_texture = null
		actor.set_expression("neutral", actor_id)
	scripted_stage = SCRIPTED_STAGE.new()
	add_child(scripted_stage)
	scripted_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scripted_stage.hide()
	closeup_stage = CLOSEUP_STAGE.new()
	add_child(closeup_stage)
	closeup_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	closeup_stage.backgrounds = textures.duplicate()
	var closeup_sky: Texture2D = closeup_stage._texture("IMG3767.png")
	if closeup_sky: closeup_stage.backgrounds["night_sky"] = closeup_sky
	var black_keys: Texture2D = closeup_stage._texture("img0677.png")
	if black_keys: closeup_stage.backgrounds["black_keys"] = black_keys
	closeup_stage.hide()
	_build_controls()
	var voice_player := AudioStreamPlayer.new()
	voice_player.name = "VoicePlayer"
	add_child(voice_player)
	AudioController.bind(voice_player)
	voice = PARK_VOICE.new()
	add_child(voice)
	voice.state_changed.connect(func(message: String):
		status.text = ("本镜目标已满足，回应结束后推进。 " if pending_action else "") + "空格：全文    T：文字    H：纯净画面    F2：排演导航    " + message)
	voice.speech_started.connect(func(presentation: Dictionary, duration: float):
		line_presentation = presentation
		line_audio_started = true
		if character_stage.visible:
			cast.present(presentation, duration))
	voice.speech_finished.connect(func(presentation: Dictionary):
		line_audio_done = true
		cast.stop_speaking(presentation.get("speaker_id", "")))
	if not cues.is_empty():
		var resume := AppState.park_entry_mode == "continue"
		AppState.park_entry_mode = "start"
		if restore_progress and not resume:
			_backup_progress()
		show_cue(0)
		if restore_progress and resume:
			_restore_progress()

func _build_controls() -> void:
	# Dim the artwork beneath overlapping text, without adding a text panel.
	reading_shade = ColorRect.new()
	reading_shade.name = "ReadingShade"
	add_child(reading_shade)
	reading_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reading_shade.color = Color(0, 0, 0, 0.24)
	reading_shade.modulate.a = 0.0
	reading_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root = Control.new()
	ui_root.name = "Interface"
	add_child(ui_root)
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NVL: text sits on the artwork without a dialogue panel or speaker bubble.
	dialogue_text = RichTextLabel.new()
	dialogue_text.name = "FloatingDialogue"
	ui_root.add_child(dialogue_text)
	dialogue_text.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	dialogue_text.offset_left = 84
	dialogue_text.offset_top = 176
	dialogue_text.offset_right = -84
	dialogue_text.anchor_bottom = 1.0
	dialogue_text.offset_bottom = -364
	dialogue_text.mouse_filter = Control.MOUSE_FILTER_STOP
	dialogue_text.scroll_active = true
	dialogue_text.scroll_following = true
	dialogue_text.scroll_following_visible_characters = true
	dialogue_text.bbcode_enabled = false
	var dialogue_font := UI_STYLE.THEME.default_font.duplicate() as Font
	if dialogue_font is SystemFont:
		dialogue_font.font_weight = 400
	dialogue_text.add_theme_font_override("normal_font", dialogue_font)
	normal_dialogue_font = dialogue_font
	scripted_dialogue_font = SystemFont.new()
	scripted_dialogue_font.font_names = PackedStringArray(["SimSun", "Noto Serif CJK SC", "serif"])
	dialogue_text.add_theme_font_size_override("normal_font_size", 32)
	dialogue_text.add_theme_constant_override("line_separation", 15)
	dialogue_text.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	dialogue_text.add_theme_constant_override("shadow_offset_x", 1)
	dialogue_text.add_theme_constant_override("shadow_offset_y", 2)
	dialogue_text.add_theme_color_override("font_outline_color", Color(0.01, 0.025, 0.05, 0.85))
	dialogue_text.add_theme_constant_override("outline_size", 1)
	marker_root = Control.new()
	marker_root.name = "ShotMarkers"
	ui_root.add_child(marker_root)
	marker_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	marker_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker_root.visible = markers_visible
	var panel := ColorRect.new()
	marker_root.add_child(panel)
	_bottom_bounds(panel, -528, -368)
	panel.color = Color(0.012, 0.02, 0.045, 0.84)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cue_title = _label(marker_root, "", 20)
	_bottom_bounds(cue_title, -516, -483)
	trigger_label = _label(marker_root, "", 20)
	_bottom_bounds(trigger_label, -483, -423)
	trigger_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_label = RichTextLabel.new()
	marker_root.add_child(note_label)
	_bottom_bounds(note_label, -420, -371)
	note_label.add_theme_font_size_override("normal_font_size", 16)
	note_label.scroll_active = true
	note_label.scroll_following = true
	note_label.bbcode_enabled = false
	var bar := HBoxContainer.new()
	controls_row = bar
	bar.name = "Controls"
	ui_root.add_child(bar)
	_bottom_bounds(bar, -342, -296)
	bar.add_theme_constant_override("separation", 20)
	previous_button = _button(bar, "上一镜", func(): show_cue(cue_index - 1))
	next_button = _button(bar, "下一镜", _advance)
	jump = OptionButton.new()
	jump.name = "CueJump"
	jump.focus_mode = Control.FOCUS_NONE
	bar.add_child(jump)
	jump.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jump.fit_to_longest_item = false
	UI_STYLE.scene_button(jump, UI_STYLE.BUTTON_BODY_SIZE)
	for cue in cues:
		jump.add_item("%s  %s" % [cue["time"], cue["title"]])
	jump.item_selected.connect(func(index: int): show_cue(index))
	previous_button.visible = markers_visible
	next_button.visible = markers_visible
	jump.visible = markers_visible
	text_button = _button(bar, "隐藏文字", _toggle_text)
	_button(bar, "历史会话", _open_history)
	_button(bar, "全部触发条件", _open_conditions)
	voice_button = _button(bar, "语音：开" if AppState.voice_enabled else "语音：关", _toggle_voice)
	_button(bar, "镜头标记", _toggle_markers)
	_button(bar, "纯净画面", _toggle_clean_view)
	_button(bar, "重新开始", _restart)
	_button(bar, "返回菜单", _return_to_title)
	script_retry_button = _button(bar, "重试衔接", func(): _finish_scripted_cue(dialogue_generation))
	script_retry_button.hide()
	hint_label = RichTextLabel.new()
	ui_root.add_child(hint_label)
	hint_label.name = "ProgressHint"
	_bottom_bounds(hint_label, -286, -124)
	hint_label.add_theme_font_size_override("normal_font_size", 16)
	hint_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	hint_label.add_theme_constant_override("shadow_offset_y", 2)
	hint_label.scroll_active = true
	hint_label.bbcode_enabled = false
	# Input has its own bottom row and never shares the floating dialogue container.
	var composer := HBoxContainer.new()
	composer_row = composer
	composer.name = "Composer"
	ui_root.add_child(composer)
	_bottom_bounds(composer, -116, -53)
	composer.add_theme_constant_override("separation", 20)
	input_box = LineEdit.new()
	input_box.name = "PlayerInput"
	composer.add_child(input_box)
	input_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_box.placeholder_text = "输入想说的话……"
	input_box.max_length = 300
	input_box.add_theme_font_size_override("font_size", UI_STYLE.BODY_SIZE)
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color(0.025, 0.04, 0.075, 0.78)
	input_style.border_color = Color(0.55, 0.75, 0.9, 0.4)
	input_style.border_width_bottom = 1
	input_style.content_margin_left = 20
	input_style.content_margin_right = 20
	input_box.add_theme_stylebox_override("normal", input_style)
	var focus_style := input_style.duplicate() as StyleBoxFlat
	focus_style.border_color = Color(0.55, 0.85, 1.0, 0.8)
	input_box.add_theme_stylebox_override("focus", focus_style)
	input_box.text_submitted.connect(_submit_player_line)
	_button(composer, "发送", func(): _submit_player_line(input_box.text))
	status = _label(ui_root, "普通镜头可随交流自然推进；关键分支需明确选择。空格：全文    T：文字    H：纯净画面    F2：排演导航", 16)
	_bottom_bounds(status, -36, -12)
	_build_history_panel()

func _build_history_panel() -> void:
	history_panel = Panel.new()
	history_panel.name = "DialogueHistory"
	ui_root.add_child(history_panel)
	history_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	history_panel.offset_left = 64
	history_panel.offset_right = -64
	history_panel.offset_top = 64
	history_panel.offset_bottom = -64
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.015, 0.025, 0.045, 0.96)
	history_panel.add_theme_stylebox_override("panel", style)
	reader_title = _label(history_panel, "历史会话", 28)
	reader_title.position = Vector2(32, 20)
	var close := _button(history_panel, "关闭", _close_history)
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -140
	close.offset_right = -24
	close.offset_top = 20
	close.offset_bottom = 64
	history_text = RichTextLabel.new()
	history_text.name = "HistoryText"
	history_panel.add_child(history_text)
	history_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	history_text.offset_left = 32
	history_text.offset_right = -32
	history_text.offset_top = 88
	history_text.offset_bottom = -24
	history_text.add_theme_font_size_override("normal_font_size", 24)
	history_text.add_theme_constant_override("line_separation", 10)
	history_text.bbcode_enabled = false
	history_text.scroll_active = true
	history_panel.hide()

func _debug_note() -> void:
	note_label.text = "\n".join([debug_base, debug_prepare, debug_intent])

func _show_hint(progress: Dictionary) -> void:
	if _scripted_cue():
		hint_label.text = "原文自动演出：字幕与声音读完后自动衔接，无需输入。"
		return
	var lines: Array[String] = ["第 %02d / %02d 镜 · 触发条件：%s（下列任一意思即可，不必照抄例句）" % [cue_index + 1, cues.size(), progress.get("goal", "")]]
	if progress.get("goal_satisfied", false) and not progress.get("accepted", false):
		lines[0] = "第 %02d / %02d 镜 · 条件已满足，继续交流：%s" % [cue_index + 1, cues.size(), progress.get("goal", "")]
	for condition in progress.get("conditions", []):
		lines.append("• %s　例如：%s" % [condition["meaning"], condition["example"]])
	lines.append("%s　推进后：%s" % [progress.get("detail", ""), progress.get("next_label", "")])
	if progress.get("progression_mode", cues[cue_index]["conversation"].get("progression_mode", "explicit")) == "contextual":
		lines.append("普通镜头：已注意／在听的条件会记住；默认约2至3轮，话题收束后推进。可自然表达继续或暂留，无需按钮。")
	else:
		lines.append("关键分支／结束：须明确表达本镜选择；仅打招呼、听取或提问不替你作决定。")
	if progress.get("accepted", false):
		lines.append("本轮：已确认；角色回应和原文收束演出结束后推进或结束本段。")
	elif not str(progress.get("reason", "")).is_empty():
		lines.append("本轮：" + str(progress["reason"]))
	hint_label.text = "\n".join(lines)
	hint_label.scroll_to_line(0)

func _open_conditions() -> void:
	reader_mode = "conditions"
	reader_title.text = "全部镜头触发条件（34 镜）"
	history_panel.show()
	input_box.release_focus()
	var lines: Array[String] = ["例句只帮助表达；模型根据原话和上下文判断。\n普通镜头：相关回应、打招呼或追问可满足注意／听取条件；记住后继续交流，默认约2至3轮，话题收束后推进。可自然表达继续或暂留，无需按钮或口令。\n关键分支／结束：明确表达选择，问候和提问不替代决定。先完成开场；角色回应与原文收束演出结束后推进。前三镜明确取消赴约会改编结束本段。\n"]
	for i in cues.size():
		var cue: Dictionary = cues[i]
		var hint: Dictionary = cue["conversation"].get("player_hint", {})
		lines.append("%02d / %02d · %s · %s%s" % [i+1, cues.size(), cue["time"], cue["title"], "（当前镜头）" if i==cue_index else ""])
		if cue.get("interaction_mode", "") == "scripted_auto":
			lines.append("原文自动演出；无需玩家参与，演出结束后进入：%s\n" % hint.get("next_label", ""))
			continue
		lines.append("判定：" + ("普通交流可自然推进" if cue["conversation"].get("progression_mode", "explicit") == "contextual" else "须明确选择／结束"))
		for condition in hint.get("conditions", []):
			lines.append("• %s\n  例如：%s" % [condition["meaning"], condition["example"]])
		lines.append("下一步：%s\n" % hint.get("next_label", ""))
	history_text.text = "\n".join(lines)
	history_text.scroll_to_line(0)

func _journal(entry: Dictionary) -> void:
	local_transcript.append({"cue_id": cues[cue_index]["id"], "speaker_id": entry.get("speaker", "player"), "text": entry.get("text", ""), "kind": entry.get("kind", "reply")})

func _open_history() -> void:
	reader_mode = "history"
	reader_title.text = "历史会话"
	history_panel.show()
	input_box.release_focus()
	_render_history(local_transcript, false)
	if scene_session_id.is_empty() or is_instance_valid(history_request):
		return
	await _log_opening()
	if not is_inside_tree() or not history_panel.visible or reader_mode != "history":
		return
	var identity := scene_session_id
	var token := dialogue_generation
	var request := HTTPRequest.new()
	request.timeout = 15
	add_child(request)
	history_request = request
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		request.queue_free()
		history_request = null
		if token != dialogue_generation or identity != scene_session_id or not history_panel.visible or reader_mode != "history":
			return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var data = JSON.parse_string(bytes.get_string_from_utf8())
			if data is Dictionary:
				_render_history(data.get("entries", []), data.get("partial_legacy", false))
		else:
			history_text.text += "\n（服务器历史暂时不可用，当前显示本次运行记录。）"
	)
	if request.request(AppState.core_url + "/api/v2/park/session/%s/history" % identity) != OK:
		request.queue_free()
		history_request = null

func _render_history(entries: Array, partial: bool) -> void:
	var lines: Array[String] = []
	if partial:
		lines.append("旧版存档只保留了部分历史；此前已丢弃的记录无法恢复。\n")
	var previous := ""
	for entry in entries:
		var cue_id: String = entry.get("cue_id", "")
		if cue_id != previous:
			for cue in cues:
				if cue["id"] == cue_id:
					lines.append("—— %s　%s ——" % [cue["time"], cue["title"]])
			previous = cue_id
		var speaker: String = entry.get("speaker_id", "narrator")
		var name: String = {"player": "你", "shiki": "志贵（原作）", "narrator": "旁白", "ciel": "西耶尔", "arcueid": "爱尔奎特"}.get(speaker, speaker)
		lines.append("%s：%s\n" % [name, entry.get("text", "")])
	if dialogue_busy or opening_running:
		lines.append("（当前演出仍在进行，完成后写入持久历史；关闭再打开可刷新。）")
	history_text.text = "\n".join(lines) if not lines.is_empty() else "尚无已完成的会话。"

func _close_history() -> void:
	history_panel.hide()

func _log_opening() -> void:
	while is_instance_valid(opening_log_request):
		await get_tree().process_frame
	if opening_logged or not opening_read or not scene_ready:
		return
	var token := dialogue_generation
	var request := HTTPRequest.new()
	request.timeout = 15
	add_child(request)
	opening_log_request = request
	var outcome := {"done": false, "ok": false}
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _bytes: PackedByteArray):
		outcome["done"] = true
		outcome["ok"] = result == HTTPRequest.RESULT_SUCCESS and code == 200
	)
	if request.request(AppState.core_url + "/api/v2/park/session/%s/opening" % scene_session_id, PackedStringArray(), HTTPClient.METHOD_POST) == OK:
		while not outcome["done"] and token == dialogue_generation:
			await get_tree().process_frame
	if token != dialogue_generation:
		return
	request.queue_free()
	opening_log_request = null
	opening_logged = outcome["ok"]

func _label(parent: Node, text: String, font_size: int) -> Label:
	var label := Label.new()
	parent.add_child(label)
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label

func _bottom_bounds(control: Control, top: float, bottom: float) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	control.offset_left = 48
	control.offset_right = -48
	control.offset_top = top
	control.offset_bottom = bottom

func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	parent.add_child(button)
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UI_STYLE.text_button(button, UI_STYLE.BUTTON_BODY_SIZE)
	button.pressed.connect(callback)
	return button

func show_cue(index: int, immediate: bool = false) -> void:
	if cues.is_empty():
		return
	index = clampi(index, 0, cues.size() - 1)
	if index == cue_index and not immediate:
		return
	_cancel_dialogue()
	previous_session_id = scene_session_id
	scene_session_id = ""
	scene_revision = 0
	scene_ready = false
	opening_logged = false
	opening_read = false
	prepared_history.clear()
	ended = false
	var previous_index := cue_index
	if index < previous_index:
		dialogue_history.clear()
		for branch in ["D1", "D2", "D3"]:
			var branch_index: int = {"D1": 1, "D2": 4, "D3": 22}[branch]
			if index <= branch_index:
				decisions.erase(branch)
	if transition:
		transition.kill()
	if cue_index >= 0 and not immediate:
		_set_background(outgoing, cues[cue_index])
		outgoing.modulate.a = 1.0
	else:
		outgoing.modulate.a = 0.0
	cue_index = index
	var cue: Dictionary = cues[index]
	_set_background(background, cue)
	if not immediate:
		transition = create_tween()
		transition.tween_property(outgoing, "modulate:a", 0.0, 0.35)
	_update_cast(cue, immediate)
	var scripted := _scripted_cue()
	scripted_stage.visible = scripted
	if scripted:
		character_stage.hide()
		scripted_stage.present(cue.get("scripted_staging", {}))
	var visuals: Dictionary = cue.get("visual_staging", {})
	if not visuals.is_empty():
		_present_visual(visuals.get("preview", visuals.get("initial", {})) if immediate else visuals.get("initial", {}), immediate)
		if not immediate and closeup_stage.visible and visuals.has("animate_to"):
			closeup_stage.animate_to(visuals["animate_to"], float(visuals.get("animate_seconds", 1.4)))
	composer_row.visible = not scripted
	controls_row.offset_top = -92 if scripted else -342
	controls_row.offset_bottom = -46 if scripted else -296
	hint_label.visible = not scripted
	input_box.editable = not scripted
	dialogue_text.offset_top = 136 if scripted else 176
	dialogue_text.offset_left = 280 if scripted else 84
	dialogue_text.add_theme_font_override("normal_font", scripted_dialogue_font if scripted else normal_dialogue_font)
	dialogue_text.add_theme_font_size_override("normal_font_size", 34 if scripted else 32)
	# Continue a short text page only when moving forward within the same shot.
	var same_shot := previous_index == index - 1 and previous_index >= 0
	if same_shot:
		var previous: Dictionary = cues[previous_index]
		same_shot = previous["background"] == cue["background"] and previous["mode"] == cue["mode"]
	if not same_shot or immediate:
		page_lines.clear()
	var lines: Array[String] = []
	var card: Dictionary = cue.get("conversation", {}).duplicate(true)
	var opening: Array = cue.get("script", cue.get("dialogue", []))
	for branch in card.get("branch_openings", {}):
		var choice: String = decisions.get(branch, {}).get("choice", "")
		var variant: Dictionary = card["branch_openings"][branch].get(choice, {})
		if not variant.is_empty():
			card["guide"] = variant["guide"]
			opening = variant.get("script", variant["dialogue"])
	for entry in opening:
		if entry.get("kind", "") != "player_slot":
			lines.append(_format_line(entry))
	page_lines.clear()
	opening_page_lines = lines.duplicate()
	cue_title.text = "%02d / %02d  %s  %s" % [index + 1, cues.size(), cue["time"], cue["title"]]
	trigger_label.text = "原作定位：%s\n原作时机：%s" % [cue["trigger"], cue["timing"]]
	var asset_text := ""
	for key in [cue["background"], cue["second_background"]]:
		if key != "":
			asset_text += sequence["assets"][key]["path"].get_file() + "  "
	debug_base = "%s　%s" % [asset_text, cue["note"]]
	debug_prepare = ""
	debug_intent = ""
	_debug_note()
	_show_hint(card.get("player_hint", {}))
	previous_button.disabled = index == 0
	next_button.disabled = index == cues.size() - 1
	jump.select(index)
	voice.cancel()
	if scripted:
		status.text = "原文自动演出，无需玩家输入。" if not immediate else "原文演出预览；F2可逐镜查看。"
	if immediate:
		opening_read = true
		_present_lines(lines, true)
		for entry in opening:
			var actor_id: String = entry.get("speaker", "")
			if actor_id in cast.actors and entry.has("expression"):
				cast.actors[actor_id].set_expression(entry["expression"], actor_id)
	else:
		var visual_track: Array = visuals.get("track", [])
		if not visual_track.is_empty():
			visual_track_done = false
			_run_visual_track(visual_track, float(visuals.get("track_duration", 0.0)), dialogue_generation)
		_play_opening(opening, dialogue_generation)
	if enable_scene_sessions and not immediate:
		_begin_prepare(dialogue_generation)

func _begin_prepare(token: int) -> void:
	if not enable_scene_sessions or is_instance_valid(prepare_request):
		return
	var request := HTTPRequest.new()
	request.timeout = 100.0
	add_child(request)
	prepare_request = request
	var cue_id: String = cues[cue_index]["id"]
	var request_id := "park-prepare-%s-%s" % [token, Time.get_ticks_usec()]
	var body := {"cue_id": cue_id, "request_id": request_id, "session_id": scene_session_id,
		"previous_session_id": previous_session_id if scene_session_id.is_empty() else "",
		"history": dialogue_history, "decisions": decisions, "rehearsal": markers_visible, "discard_pending": true}
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		request.queue_free()
		if token != dialogue_generation:
			return
		prepare_request = null
		if code == 404 and (not scene_session_id.is_empty() or not previous_session_id.is_empty()):
			scene_session_id = ""
			previous_session_id = ""
			_begin_prepare(token) # Core data moved: bootstrap once from the local checkpoint.
			return
		if result != HTTPRequest.RESULT_SUCCESS or code != 200 or bytes.is_empty():
			status.text = "镜头会话准备失败；发送时可以重试。"
			return
		var payload = JSON.parse_string(bytes.get_string_from_utf8())
		if not payload is Dictionary or payload.get("cue_id", "") != cue_id or payload.get("request_id", "") != request_id or not payload.get("ready", false):
			return
		scene_session_id = str(payload["session_id"])
		scene_revision = int(payload["revision"])
		scene_ready = true
		prepared_history = payload.get("history", [])
		if not opening_running:
			_adopt_prepared_history()
		decisions = payload.get("decisions", decisions)
		debug_prepare = "镜头准备：%s%s" % [payload.get("prepared_by", ""), "（已复用）" if payload.get("reused", false) else ""]
		_debug_note()
		if not dialogue_busy:
			_show_hint(payload.get("progress", cues[cue_index]["conversation"].get("player_hint", {})))
		if opening_read and (not _scripted_cue() or payload.get("opening_logged", false)):
			_log_opening()
		var next_id: String = payload.get("next_cue_id", "")
		if not markers_visible and not next_id.is_empty() and cue_index + 1 < cues.size() and cues[cue_index+1]["id"] == next_id:
			show_cue(cue_index+1)
		elif _scripted_cue() and not opening_running and not script_finish_busy and not markers_visible:
			if payload.get("opening_logged", false):
				_finish_scripted_cue(token)
			else:
				page_lines.clear()
				_play_opening(cues[cue_index]["script"], token)
		elif not opening_running and not dialogue_busy and not _scripted_cue():
			status.text = "镜头会话已准备，可以自由交流。"
			_save_progress()
	)
	if request.request(AppState.core_url + "/api/v2/park/session/prepare", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		request.queue_free()
		prepare_request = null

func _adopt_prepared_history() -> void:
	if prepared_history.is_empty():
		return
	dialogue_history.clear()
	for row in prepared_history.slice(maxi(0, prepared_history.size()-16)):
		if row is Dictionary:
			dialogue_history.append(row.duplicate(true))
	prepared_history.clear()

func _commit_turn(payload: Dictionary, token: int) -> bool:
	if str(payload.get("session_id", "")).is_empty():
		return true # Compatibility with older offline/API fixtures.
	for attempt in 3:
		if token != dialogue_generation:
			return false
		var request := HTTPRequest.new()
		request.timeout = 15.0
		add_child(request)
		commit_request = request
		var outcome := {"done": false, "ok": false, "revision": scene_revision}
		request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
			outcome["done"] = true
			if result == HTTPRequest.RESULT_SUCCESS and code == 200 and not bytes.is_empty():
				var value = JSON.parse_string(bytes.get_string_from_utf8())
				if value is Dictionary and value.get("committed", false):
					outcome["ok"] = true
					outcome["revision"] = value["revision"]
		)
		var body := {"request_id": payload["request_id"], "revision": payload["revision"]}
		var error := request.request(AppState.core_url + "/api/v2/park/session/%s/commit" % payload["session_id"], PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body))
		if error == OK:
			while not outcome["done"] and token == dialogue_generation:
				await get_tree().process_frame
		if token != dialogue_generation:
			return false
		request.queue_free()
		commit_request = null
		if outcome["ok"]:
			scene_revision = int(outcome["revision"])
			active_turn_id = ""
			return true
		await get_tree().create_timer(0.3).timeout
	return false

func _cancel_server_turn() -> void:
	if scene_session_id.is_empty() or active_turn_id.is_empty() or not is_inside_tree():
		return
	var request := HTTPRequest.new()
	request.timeout = 5.0
	get_tree().root.add_child(request)
	request.request_completed.connect(func(_result: int, _code: int, _headers: PackedStringArray, _bytes: PackedByteArray): request.queue_free())
	var body := {"request_id": active_turn_id}
	request.request(AppState.core_url + "/api/v2/park/session/%s/cancel" % scene_session_id, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body))
	active_turn_id = ""

func _play_opening(opening: Array, token: int) -> void:
	opening_running = true
	opening_read = false
	input_box.editable = false
	var index := 0
	while index < opening.size():
		var entry: Dictionary = opening[index]
		if entry.get("kind", "") == "player_slot":
			index += 1
			continue
		var performed: Array = [entry]
		var group: String = entry.get("performance_group", "")
		if not group.is_empty():
			while index + performed.size() < opening.size() and opening[index + performed.size()].get("performance_group", "") == group:
				performed.append(opening[index + performed.size()])
		if performed.size() > 1:
			await _perform_line({"speaker": "both", "lines": performed, "presentation": entry.get("presentation", {})}, token)
		else:
			await _perform_line(entry, token)
		if token != dialogue_generation:
			return
		for unit in performed:
			_journal(unit)
			if unit.get("speaker", "") in ["arcueid", "ciel"]:
				dialogue_history.append({"role": "assistant", "speaker_id": str(unit["speaker"]), "content": str(unit["text"]), "mood": str(unit.get("mood", "neutral")), "expression": str(unit.get("expression", cues[cue_index].get("expressions", {}).get(unit["speaker"], "neutral"))), "source": "fixed"})
				while dialogue_history.size() > 16:
					dialogue_history.pop_front()
		index += performed.size()
		await get_tree().create_timer(0.25).timeout
		if token != dialogue_generation:
			return
	if not visual_track_done:
		status.text = "固定原文已读完，正在播放本镜画面。"
		while not visual_track_done and token == dialogue_generation:
			await get_tree().process_frame
	if token != dialogue_generation: return
	opening_running = false
	opening_read = true
	var after_visual: Dictionary = cues[cue_index].get("visual_staging", {}).get("after_opening", {})
	if not after_visual.is_empty(): _present_visual(after_visual)
	if _scripted_cue():
		await _finish_scripted_cue(token)
		return
	await _log_opening()
	if token != dialogue_generation:
		return
	_adopt_prepared_history()
	input_box.editable = not ended
	status.text = "开场已交代，可以自由回应眼前的人物与事件。"
	_save_progress()

func _scripted_cue() -> bool:
	return cue_index >= 0 and cues[cue_index].get("interaction_mode", "") == "scripted_auto"

func _finish_scripted_cue(token: int) -> void:
	if script_finish_busy or token != dialogue_generation or not _scripted_cue():
		return
	if markers_visible:
		status.text = "原文演出已完成；排演模式停在本镜，可用导航继续。"
		return
	script_finish_busy = true
	script_retry_button.hide()
	if enable_scene_sessions:
		if not scene_ready:
			_begin_prepare(token)
			while is_instance_valid(prepare_request) and token == dialogue_generation:
				await get_tree().process_frame
		if token != dialogue_generation:
			return
		await _log_opening()
		if token != dialogue_generation:
			return
		var committed := false
		if scene_ready and opening_logged:
			var request := HTTPRequest.new()
			request.timeout = 15
			add_child(request)
			commit_request = request
			var outcome := {"done": false, "ok": false}
			request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
				outcome["done"] = true
				if result == HTTPRequest.RESULT_SUCCESS and code == 200:
					var data = JSON.parse_string(bytes.get_string_from_utf8())
					outcome["ok"] = data is Dictionary and data.get("committed", false)
			)
			var body := {"request_id": "script-" + scene_session_id, "revision": scene_revision}
			if request.request(AppState.core_url + "/api/v2/park/session/%s/script/complete" % scene_session_id, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body)) == OK:
				while not outcome["done"] and token == dialogue_generation:
					await get_tree().process_frame
			if token != dialogue_generation:
				return
			request.queue_free()
			commit_request = null
			committed = outcome["ok"]
		if not committed:
			script_finish_busy = false
			status.text = "原文演出已读完；会话服务暂不可用，可启动服务后重试衔接。"
			script_retry_button.show()
			return
	while history_panel.visible and token == dialogue_generation:
		await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	if token != dialogue_generation:
		return
	script_finish_busy = false
	if markers_visible:
		status.text = "原文演出已完成；关闭排演导航后继续自动衔接。"
		return
	show_cue(cue_index + 1)

func _perform_line(entry: Dictionary, token: int) -> void:
	if entry.has("visual_presentation"):
		_present_visual(entry["visual_presentation"])
	if _scripted_cue() and entry.has("presentation") and not closeup_stage.visible:
		scripted_stage.present(entry["presentation"])
		if entry["presentation"].get("clear_text", false):
			page_lines.clear()
	var formatted := _format_line(entry)
	var lines: Array[String] = [formatted]
	_present_lines(lines, true)
	var start := dialogue_text.text.length() - formatted.length()
	dialogue_text.visible_characters = start
	line_presentation = {}
	line_audio_started = false
	line_audio_done = false
	line_skip_text = false
	var voiced: bool = AppState.voice_enabled and (entry.get("speaker", "") in ["arcueid", "ciel"] or entry.has("lines"))
	if voiced:
		if entry.has("lines"):
			voice.speak_group(entry["lines"], cues[cue_index]["id"])
		else:
			var actor: String = entry["speaker"]
			voice.speak_reply({"cue_id": cues[cue_index]["id"], "speaker_id": actor,
				"reply": entry["text"], "tts_text": entry.get("tts_text", ""),
				"bypass_cache": entry.get("bypass_cache", false),
				"mood": entry.get("mood", "neutral"), "expression": entry.get("expression", cues[cue_index].get("expressions", {}).get(actor, "neutral"))})
		status.text = ("已确认行动，回应结束后推进。 " if pending_action else "") + "准备日语语音…"
		while token == dialogue_generation and not line_audio_started and voice.is_busy():
			await get_tree().process_frame
		if token != dialogue_generation:
			return
		voiced = line_audio_started
	var shown := 0
	if not voiced and entry.get("speaker", "") in ["arcueid", "ciel"] and character_stage.visible:
		cast.present({"speaker_id": entry["speaker"], "mood": entry.get("mood", "neutral"), "expression": entry.get("expression", cues[cue_index].get("expressions", {}).get(entry["speaker"], "neutral")), "reply": entry["text"]}, formatted.length() / 12.0)
	var fallback_at := Time.get_ticks_usec()
	var fallback_start := 0
	var fallback: bool = not voiced
	while token == dialogue_generation and (shown < formatted.length() or voice.is_busy()):
		var timing: Dictionary = AudioController.reveal_timing(line_presentation) if voiced else {}
		if not fallback and (line_audio_done or not AppState.voice_enabled or timing.is_empty()):
			fallback = true
			fallback_start = shown
			fallback_at = Time.get_ticks_usec()
		var target := shown
		if line_skip_text:
			target = formatted.length()
		elif fallback:
			target = fallback_start + int((Time.get_ticks_usec() - fallback_at) / 1000000.0 * 12.0)
		elif float(timing.get("duration", 0.0)) > 0:
			target = int(formatted.length() * clampf(float(timing["elapsed"]) / float(timing["duration"]), 0, 1))
		else:
			target = mini(int(float(timing.get("elapsed", 0.0)) * 9.0), maxi(0, formatted.length() - 1))
		shown = clampi(maxi(shown, target), 0, formatted.length())
		dialogue_text.visible_characters = start + shown
		await get_tree().process_frame
	if token == dialogue_generation:
		dialogue_text.visible_characters = -1
		cast.stop_speaking(str(entry.get("speaker", "")))

func _present_visual(settings: Dictionary, immediate: bool = false) -> void:
	if settings.get("restore_background", false):
		closeup_stage.reset()
		scripted_stage.visible = _scripted_cue()
		character_stage.visible = cues[cue_index].get("cast_visible", true) and not _scripted_cue()
	elif closeup_stage.present(settings, immediate):
		scripted_stage.hide()
		character_stage.hide()

func _run_visual_track(track: Array, duration: float, token: int) -> void:
	# Video-relative timings are local to this fixed opening. They never select a branch.
	var started := Time.get_ticks_msec()
	for beat in track:
		var delay := float(beat.get("at", 0.0)) - (Time.get_ticks_msec()-started)/1000.0
		if delay > 0.0:
			await get_tree().create_timer(delay, true, false, true).timeout
		if token != dialogue_generation: return
		_present_visual(beat.get("frame", {}))
	var remaining := duration - (Time.get_ticks_msec()-started)/1000.0
	if remaining > 0.0:
		await get_tree().create_timer(remaining, true, false, true).timeout
	if token == dialogue_generation: visual_track_done = true

func _settle_visual() -> void:
	# A completed checkpoint restores the final framing, not an unplayed cut-in.
	for entry in cues[cue_index].get("script", []):
		if entry.has("visual_presentation"):
			_present_visual(entry["visual_presentation"], true)
	var final_frame: Dictionary = cues[cue_index].get("visual_staging", {}).get("after_opening", {})
	if not final_frame.is_empty(): _present_visual(final_frame, true)

func _toggle_voice() -> void:
	AudioController.set_voice_enabled(not AppState.voice_enabled)
	voice_button.text = "语音：开" if AppState.voice_enabled else "语音：关"
	voice.cancel()
	cast.stop_speaking()
	status.text = "语音已开启，下一句生效。" if AppState.voice_enabled else "语音已关闭，文字继续。"

func _update_cast(cue: Dictionary, immediate: bool) -> void:
	character_stage.visible = cue.get("cast_visible", true)
	for actor_id in cast.actors:
		var actor = cast.actors[actor_id]
		var introduced: bool = actor_id in cue.get("introduced_actors", [])
		actor.stop_speaking()
		if not introduced:
			if actor.entrance_tween:
				actor.entrance_tween.kill()
			actor.portrait.position = actor.rest_position
			actor.hide_until_first_speech(1.0 if actor_id == "arcueid" else -1.0)
			continue
		actor.set_expression(cue.get("expressions", {}).get(actor_id, "neutral"), actor_id)
		if immediate:
			if actor.entrance_tween:
				actor.entrance_tween.kill()
			actor.has_entered = true
			actor.portrait.visible = true
			actor.portrait.position = actor.rest_position
			actor.portrait.modulate.a = 1.0
		elif not actor.has_entered:
			actor.start_speaking(0.1, actor_id)
		if cue.get("speaker", "narrator") in [actor_id, "both"] and character_stage.visible:
			actor.start_speaking(minf(cue["trigger"].length() / 28.0, 4.0), actor_id)

func _format_line(entry: Dictionary) -> String:
	if entry.has("lines"):
		var text_lines: Array[String] = []
		for unit in entry["lines"]:
			text_lines.append(_format_line(unit))
		return "\n".join(text_lines)
	var text: String = entry.get("text", "")
	return text if entry.get("speaker", "narrator") == "narrator" else "「%s」" % text

func _present_lines(lines: Array[String], immediate: bool = false) -> void:
	if text_tween:
		text_tween.kill()
	# Keep all text accessible; scrolling follows revealed wrapped lines within the
	# space above the input. A logical entry can wrap to many visual lines.
	var new_text := "\n".join(lines)
	var retained := "\n".join(page_lines)
	if page_lines.size() + lines.size() > 5:
		page_lines.clear()
		retained = ""
	page_lines.append_array(lines)
	dialogue_text.text = "\n".join(page_lines)
	var start := retained.length() + (1 if not retained.is_empty() else 0)
	dialogue_text.visible_characters = -1 if immediate else start
	if not immediate:
		text_tween = create_tween()
		text_tween.tween_property(dialogue_text, "visible_characters", dialogue_text.text.length(), maxf(new_text.length() / 36.0, 0.15))

func _submit_player_line(value: String) -> void:
	var text := value.strip_edges()
	if text.is_empty() or cue_index < 0 or dialogue_busy or opening_running or ended or history_panel.visible or _scripted_cue():
		return
	if enable_scene_sessions and not scene_ready:
		var prepare_token := dialogue_generation
		dialogue_busy = true
		input_box.editable = false
		status.text = "正在准备本镜头的交流…"
		_begin_prepare(prepare_token)
		while is_instance_valid(prepare_request) and prepare_token == dialogue_generation:
			await get_tree().process_frame
		if prepare_token != dialogue_generation:
			return
		dialogue_busy = false
		if not scene_ready:
			_dialogue_failed(text)
			return
	voice.cancel()
	cast.stop_speaking()
	var submit_token := dialogue_generation
	dialogue_busy = true
	input_box.editable = false
	await _log_opening()
	if submit_token != dialogue_generation:
		return
	page_lines = opening_page_lines.duplicate()
	var lines: Array[String] = ["你：「%s」" % text]
	_present_lines(lines)
	input_box.clear()
	player_line_submitted.emit(text, cues[cue_index]["id"])
	dialogue_busy = true
	input_box.editable = false
	status.text = "角色正在回应…"
	var token := dialogue_generation
	var cue_id: String = cues[cue_index]["id"]
	var request_id := "park-turn-%s-%s" % [token, Time.get_ticks_usec()]
	active_turn_id = request_id if enable_scene_sessions else ""
	var request := HTTPRequest.new()
	request.timeout = 100.0
	add_child(request)
	dialogue_request = request
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		request.queue_free()
		if token != dialogue_generation:
			return
		dialogue_request = null
		if result != HTTPRequest.RESULT_SUCCESS or code != 200 or bytes.is_empty():
			_dialogue_failed(text)
			return
		var payload = JSON.parse_string(bytes.get_string_from_utf8())
		if not payload is Dictionary or not payload.get("available", false) or payload.get("request_id", "") != request_id or payload.get("cue_id", "") != cue_id:
			set_meta("last_park_turn", payload)
			_dialogue_failed(text)
			return
		set_meta("last_park_turn", payload)
		_accept_reply(payload, text, token)
	)
	var body: Dictionary = {"cue_id": cue_id, "request_id": request_id, "message": text,
		"history": dialogue_history, "decisions": decisions}
	if enable_scene_sessions:
		body = {"session_id": scene_session_id, "revision": scene_revision, "request_id": request_id, "message": text}
	var error := request.request(AppState.core_url + "/api/v2/park/dialogue", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		request.queue_free()
		dialogue_request = null
		_dialogue_failed(text)

func _dialogue_failed(text: String) -> void:
	_cancel_server_turn()
	if enable_scene_sessions:
		scene_ready = false
	dialogue_busy = false
	input_box.editable = true
	input_box.text = text
	status.text = "角色暂时无法回应；镜头保持原处，可以重试。"

func _accept_reply(payload: Dictionary, text: String, token: int) -> void:
	pending_action = not str(payload.get("action", "")).is_empty()
	var intent: Dictionary = payload.get("intent", {})
	if not intent.is_empty():
		debug_intent = "本轮语义：%s / %s；证据：%s" % [intent.get("dialogue_act", ""), payload.get("action", "保持交流"), intent.get("evidence", "")]
		_debug_note()
	_show_hint(payload.get("progress", cues[cue_index]["conversation"].get("player_hint", {})))
	var history_before := dialogue_history.duplicate(true)
	var transcript_before := local_transcript.size()
	_journal({"speaker": "player", "text": text, "kind": "player"})
	dialogue_history.append({"role": "user", "content": text})
	status.text = "本镜目标已满足，回应与原文演出结束后推进。" if pending_action else "角色回应中，本镜头继续交流。"
	var segments: Array = payload.get("segments", [payload])
	var last_actor := ""
	for segment in segments:
		var actor: String = segment["speaker_id"]
		if not last_actor.is_empty() and last_actor != actor:
			await get_tree().create_timer(0.2).timeout
			if token != dialogue_generation:
				return
		await _perform_line({"speaker": actor, "text": segment["reply"], "tts_text": segment.get("tts_text", ""), "mood": segment.get("mood", "neutral"), "expression": segment.get("expression", "neutral")}, token)
		if token != dialogue_generation:
			return
		_journal({"speaker": actor, "text": segment["reply"]})
		var semantic := {"park_dialogue_act": intent.get("dialogue_act", "conversation"), "park_action": payload.get("action", ""), "park_evidence": intent.get("evidence", ""), "park_certainty": intent.get("certainty", "unclear"), "park_beat_status": intent.get("beat_status", ""), "park_goal_status": intent.get("goal_status", "")}
		semantic["park_expects_response"] = segment.get("expects_response", "")
		semantic["park_response_to"] = segment.get("response_to", "")
		dialogue_history.append({"role": "assistant", "content": str(segment["reply"]), "speaker_id": actor, "mood": str(segment.get("mood", "neutral")), "expression": str(segment.get("expression", "neutral")), "semantic": JSON.stringify(semantic), "tts_text": str(segment.get("tts_text", ""))})
		last_actor = actor
	for entry in payload.get("outro", []):
		await _perform_line(entry, token)
		if token != dialogue_generation:
			return
		_journal(entry)
		if entry.get("speaker", "") in ["arcueid", "ciel"]:
			dialogue_history.append({"role": "assistant", "speaker_id": entry["speaker"], "content": entry["text"], "source": "fixed"})
	while dialogue_history.size() > 16:
		dialogue_history.pop_front()
	if token != dialogue_generation:
		return
	cast.stop_speaking()
	if not await _commit_turn(payload, token):
		if token == dialogue_generation:
			dialogue_history = history_before
			local_transcript.resize(transcript_before)
			_dialogue_failed(text)
		return
	var branch_id: String = payload.get("branch_id", "")
	while history_panel.visible and token == dialogue_generation:
		await get_tree().process_frame
	if token != dialogue_generation:
		return
	# Keep the completed reaction readable before switching to the next shot.
	if not str(payload.get("action", "")).is_empty():
		await get_tree().create_timer(1.2).timeout
		if token != dialogue_generation:
			return
	if not branch_id.is_empty():
		decisions[branch_id] = {"choice": str(payload["action"]), "text": text}
	var ending: String = payload.get("ending", "")
	if not ending.is_empty():
		ended = true
		dialogue_busy = false
		status.text = "已取消今晚的赴约（改编收束）。可返回菜单或用镜头标记重新排演。" if ending == "leave" else "本段完成：视频到战斗开端为止，后续剧情待接入。"
		_save_progress()
		return
	var next_id: String = payload.get("next_cue_id", "")
	if not next_id.is_empty() and cue_index + 1 < cues.size() and cues[cue_index + 1]["id"] == next_id:
		show_cue(cue_index + 1)
		_save_progress()
	else:
		dialogue_busy = false
		input_box.editable = true
		status.text = str(payload.get("progress", {}).get("reason", "可以继续交流；当前回应方式见输入框上方。"))
		_save_progress()

func _save_progress() -> void:
	if not restore_progress or markers_visible or dialogue_busy or opening_running:
		return
	var file := FileAccess.open(PROGRESS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"version": 1, "script_revision": "canon-v1", "cue_id": cues[cue_index]["id"], "history": dialogue_history, "decisions": decisions, "ended": ended, "draft": input_box.text, "session_id": scene_session_id, "scene_revision": scene_revision}))

func _restore_progress() -> void:
	if not FileAccess.file_exists(PROGRESS_PATH):
		return
	var saved = JSON.parse_string(FileAccess.get_file_as_string(PROGRESS_PATH))
	if not saved is Dictionary or saved.get("version", 0) != 1:
		return
	for i in cues.size():
		if cues[i]["id"] != saved.get("cue_id", ""):
			continue
		show_cue(i, true)
		_settle_visual()
		var history = saved.get("history", [])
		if history is Array:
			for entry in history.slice(maxi(0, history.size() - 16)):
				if entry is Dictionary and entry.get("role", "") in ["user", "assistant"]:
					if saved.get("script_revision", "") != "canon-v1" and entry["role"] == "assistant":
						continue # Old invented summaries/promises are not canonical history.
					var restored_entry := {"role": str(entry["role"]), "content": str(entry.get("content", "")).left(600)}
					for key in ["speaker_id", "mood", "expression", "semantic", "tts_text"]:
						if entry.has(key):
							restored_entry[key] = str(entry[key]).left(1200 if key == "tts_text" else 600 if key == "semantic" else 24)
					dialogue_history.append(restored_entry)
		var restored_decisions = saved.get("decisions", {})
		if restored_decisions is Dictionary:
			for key in ["D1", "D2", "D3"]:
				if restored_decisions.get(key) is Dictionary:
					decisions[key] = {"choice": str(restored_decisions[key].get("choice", "")).left(24), "text": str(restored_decisions[key].get("text", "")).left(300)}
		ended = bool(saved.get("ended", false))
		input_box.editable = not ended
		input_box.text = str(saved.get("draft", "")).left(300)
		voice.cancel() # Reading a completed checkpoint never replays old speech.
		scene_session_id = str(saved.get("session_id", ""))
		previous_session_id = ""
		scene_revision = int(saved.get("scene_revision", 0))
		if enable_scene_sessions:
			_begin_prepare(dialogue_generation)
		status.text = "已恢复本地公园进度。" if not ended else "本段已结束；可以重新开始或返回菜单。"
		if saved.get("script_revision", "") != "canon-v1":
			status.text = "已恢复镜头位置；旧版改编对白未载入，固定选段已按原著修正。"
		return

func _backup_progress() -> void:
	if FileAccess.file_exists(PROGRESS_PATH):
		DirAccess.copy_absolute(ProjectSettings.globalize_path(PROGRESS_PATH), ProjectSettings.globalize_path(PROGRESS_PATH + ".bak"))

func _restart() -> void:
	_cancel_dialogue()
	scene_session_id = ""
	previous_session_id = ""
	if restore_progress:
		_backup_progress()
	decisions.clear()
	dialogue_history.clear()
	local_transcript.clear()
	input_box.clear()
	cue_index = -1
	show_cue(0)

func _text_is_revealing() -> bool:
	return dialogue_text.visible_characters >= 0 and dialogue_text.visible_characters < dialogue_text.text.length()

func _cancel_dialogue() -> void:
	if is_instance_valid(closeup_stage): closeup_stage.reset()
	visual_track_done = true
	_cancel_server_turn()
	dialogue_generation += 1
	pending_action = false
	opening_running = false
	script_finish_busy = false
	if is_instance_valid(script_retry_button):
		script_retry_button.hide()
	line_skip_text = true
	if is_instance_valid(dialogue_request):
		dialogue_request.cancel_request()
		dialogue_request.queue_free()
	dialogue_request = null
	for request in [prepare_request, commit_request, opening_log_request, history_request]:
		if is_instance_valid(request):
			request.cancel_request()
			request.queue_free()
	prepare_request = null
	commit_request = null
	opening_log_request = null
	history_request = null
	if is_instance_valid(history_panel):
		history_panel.hide()
	dialogue_busy = false
	if is_instance_valid(input_box):
		input_box.editable = true

func _advance() -> void:
	if opening_running or dialogue_busy:
		line_skip_text = true
		dialogue_text.visible_characters = -1
		return
	if dialogue_text.visible_characters >= 0 and dialogue_text.visible_characters < dialogue_text.text.length():
		if text_tween:
			text_tween.kill()
		dialogue_text.visible_characters = -1
	else:
		if markers_visible:
			show_cue(cue_index + 1)
		else:
			status.text = "请自由输入回应当前人物；F2 打开手工排演导航。"

func _set_background(layer: Control, cue: Dictionary) -> void:
	var fill: ColorRect = layer.get_node("Fill")
	var first: TextureRect = layer.get_node("First")
	var second: TextureRect = layer.get_node("Second")
	fill.color = Color.BLACK
	if cue["mode"] == "red":
		fill.color = Color(0.65, 0.005, 0.02)
	elif cue["mode"] == "white":
		fill.color = Color.WHITE
	first.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	second.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	first.texture = textures.get(cue["background"])
	second.texture = textures.get(cue["second_background"])
	first.visible = first.texture != null
	second.visible = second.texture != null
	if cue["mode"] == "vertical":
		# Keep each viewpoint behind its actor: Ciel left, Arcueid right.
		first.anchor_left = 0.5
		second.anchor_right = 0.5
	elif cue["mode"] == "horizontal":
		first.anchor_bottom = 0.5
		second.anchor_top = 0.5

func _toggle_text() -> void:
	text_visible = not text_visible
	dialogue_text.visible = text_visible
	text_button.text = "隐藏文字" if text_visible else "显示文字"
	_update_reading_shade()

func _toggle_markers() -> void:
	markers_visible = not markers_visible
	marker_root.visible = markers_visible
	previous_button.visible = markers_visible
	next_button.visible = markers_visible
	jump.visible = markers_visible
	dialogue_text.offset_bottom = -550 if markers_visible else -364
	if not markers_visible and _scripted_cue() and opening_read and not opening_running:
		_finish_scripted_cue(dialogue_generation)

func _toggle_clean_view() -> void:
	clean_view = not clean_view
	if clean_view:
		input_box.release_focus()
	ui_root.visible = not clean_view
	_update_reading_shade()

func _process(_delta: float) -> void:
	if is_instance_valid(dialogue_text):
		dialogue_text.get_v_scroll_bar().visible = dialogue_text.get_content_height() > dialogue_text.size.y + 1.0
		_update_reading_shade()

func _update_reading_shade() -> void:
	if is_instance_valid(closeup_stage) and closeup_stage.visible:
		closeup_stage.set_reading(text_visible and not clean_view)
	if is_instance_valid(scripted_stage) and scripted_stage.visible:
		scripted_stage.set_reading(text_visible and not clean_view)
	var overlaps := false
	if not clean_view and text_visible and not dialogue_text.text.is_empty() and character_stage.visible:
		var text_bounds := Rect2(dialogue_text.global_position, Vector2(dialogue_text.size.x, minf(dialogue_text.size.y, dialogue_text.get_content_height())))
		for actor in cast.actors.values():
			if actor.portrait.visible and text_bounds.intersects(actor.portrait.get_global_rect()):
				overlaps = true
				break
	if overlaps == shade_active:
		return
	shade_active = overlaps
	if shade_tween:
		shade_tween.kill()
	shade_tween = create_tween()
	shade_tween.tween_property(reading_shade, "modulate:a", 1.0 if overlaps else 0.0, 0.16)

func _return_to_title() -> void:
	if not SceneTransition.busy:
		_save_progress()
		_cancel_dialogue()
		voice.cancel()
		SceneTransition.change_to("res://scenes/Title.tscn")

func _exit_tree() -> void:
	_cancel_dialogue()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if history_panel.visible:
		if event.keycode == KEY_ESCAPE:
			_close_history()
		return
	if input_box.has_focus() and event.keycode == KEY_ESCAPE:
		input_box.release_focus()
		return
	if input_box.has_focus() and not opening_running and not dialogue_busy:
		if event.keycode == KEY_ESCAPE:
			input_box.release_focus()
		return
	match event.keycode:
		KEY_RIGHT:
			if markers_visible:
				show_cue(cue_index + 1)
		KEY_SPACE:
			_advance()
		KEY_LEFT:
			if markers_visible:
				show_cue(cue_index - 1)
		KEY_T:
			_toggle_text()
		KEY_H:
			_toggle_clean_view()
		KEY_F2:
			_toggle_markers()
		KEY_ESCAPE:
			if clean_view:
				_toggle_clean_view()
			else:
				_return_to_title()
		_:
			return
	get_viewport().set_input_as_handled()
