extends Control

const BUTTON_FEEDBACK := preload("res://scripts/ButtonFeedback.gd")
const SCENE_UI := preload("res://scripts/UiStyle.gd")
const STORY_CAST := preload("res://scripts/StoryCast.gd")
var stage_director: Node
var scene_entry_tween: Tween
var scene_exit_tween: Tween

@onready var portrait: TextureRect = %Portrait
@onready var reply_text: RichTextLabel = %ReplyText
@onready var speaker_subtitle: Label = %SpeakerSubtitle
@onready var user_subtitle: Label = %UserSubtitle
@onready var subtitle_layer: VBoxContainer = %SubtitleLayer
@onready var recent_panel: PanelContainer = %RecentPanel
@onready var dialogue_layer: HBoxContainer = %DialogueLayer
@onready var chat_dock_button: Button = %ChatDockButton
@onready var input_box: LineEdit = %InputBox
@onready var send_button: Button = %SendButton
@onready var status_label: Label = %StatusLabel
@onready var memory_list: VBoxContainer = %MemoryList
@onready var save_list: VBoxContainer = %SaveList
@onready var memory_panel: PanelContainer = %MemoryPanel
@onready var save_panel: PanelContainer = %SavePanel
@onready var settings_panel: PanelContainer = %SettingsPanel
@onready var overlay_dim: ColorRect = %OverlayDim
@onready var identity_option: OptionButton = %IdentityOption
@onready var user_name_input: LineEdit = %UserNameInput
@onready var voice_toggle: CheckButton = %VoiceEnabled
@onready var voice_badge: Label = %VoiceBadge
@onready var speaker_option: OptionButton = %SpeakerOption
@onready var audio_player: AudioStreamPlayer = %AudioStreamPlayer
@onready var recent_scroll: ScrollContainer = %RecentScroll
@onready var recent_list: VBoxContainer = %RecentList
@onready var chat_log_panel: PanelContainer = %ChatLogPanel
@onready var chat_log_scroll: ScrollContainer = %ChatLogScroll
@onready var chat_log_list: VBoxContainer = %ChatLogList
@onready var story_button: Button = %StoryButton
@onready var story_hint: Label = %StoryHint
@onready var story_choice_a: Button = %StoryChoiceA
@onready var story_choice_b: Button = %StoryChoiceB

var typing := false
var save_retry_pending := false
var reveal_generation := 0
var segment_presentations: Dictionary = {}
var first_audio_started: Dictionary = {}
var current_save: Dictionary = {}
var recent_messages: Array = []
var active_reply_request_id := ""
var selected_speaker_id := "arcueid"
var speaker_switching := false
var story_state: Dictionary = {}
var pending_story_state: Dictionary = {}
var pending_story_audio_request_id := ""
var story_transitioning := false
var story_transition_generation := 0
var queued_story_state: Dictionary = {}
var story_loading := false
var recent_tween: Tween
var subtitle_tween: Tween
var overlay_tween: Tween
var overlay_generation := 0
var recent_rest_y := 0.0
var composer_tween: Tween
var composer_generation := 0
var composer_open := false
var composer_rest_y := 0.0
var leaving_story := false
var model_api_settings: VBoxContainer

func _ready() -> void:
	if _uses_story_cast():
		stage_director = STORY_CAST.new()
		add_child(stage_director)
		stage_director.bind(portrait, %CielPortrait)
		get_node("CharacterStage/PortraitHalo").visible = false
	else:
		stage_director = StageDirector
		stage_director.bind(portrait)
	AudioController.bind(audio_player)
	if not AudioController.playback_started.is_connected(_on_audio_playback_started):
		AudioController.playback_started.connect(_on_audio_playback_started)
	if not AudioController.playback_finished.is_connected(_on_audio_playback_finished):
		AudioController.playback_finished.connect(_on_audio_playback_finished)
	if not AudioController.playback_failed.is_connected(_on_audio_playback_failed):
		AudioController.playback_failed.connect(_on_audio_playback_failed)
	ApiClient.socket_event.connect(_on_socket_event)
	ApiClient.connection_changed.connect(_on_connection_changed)
	send_button.pressed.connect(_send)
	chat_dock_button.pressed.connect(_open_composer)
	input_box.text_submitted.connect(_on_message_submitted)
	input_box.focus_entered.connect(_on_input_focus_entered)
	input_box.focus_exited.connect(_on_input_focus_exited)
	%MemoryButton.pressed.connect(_open_memory)
	%SaveButton.pressed.connect(_open_saves)
	%SettingsButton.pressed.connect(_open_settings)
	%ReturnTitleButton.visible = _uses_story_cast()
	%ReturnTitleButton.pressed.connect(_return_to_title)
	%CloseMemoryButton.pressed.connect(_close_overlays)
	%MemoryDoneButton.pressed.connect(_close_overlays)
	%CloseSaveButton.pressed.connect(_close_overlays)
	%SaveDoneButton.pressed.connect(_close_overlays)
	%CloseSettingsButton.pressed.connect(_close_overlays)
	%CloseSettingsDoneButton.pressed.connect(_close_overlays)
	%ChatLogButton.pressed.connect(_open_chat_log)
	%CloseChatLogButton.pressed.connect(_close_overlays)
	%CloseChatLogDoneButton.pressed.connect(_close_overlays)
	%NewSaveButton.pressed.connect(_create_save)
	%SaveSettingsButton.pressed.connect(_save_settings)
	_install_model_api_settings()
	story_button.pressed.connect(_start_story)
	%TeacherEntryButton.pressed.connect(_open_teacher_stage)
	story_choice_a.pressed.connect(func() -> void: _send_story_suggestion(0))
	story_choice_b.pressed.connect(func() -> void: _send_story_suggestion(1))
	overlay_dim.gui_input.connect(_on_overlay_input)
	identity_option.add_item("以自己身份相遇", 0)
	identity_option.add_item("以远野志贵身份相遇", 1)
	speaker_option.add_item("爱尔奎特", 0)
	speaker_option.add_item("希耶尔", 1)
	speaker_option.select(0)
	speaker_option.item_selected.connect(_on_speaker_selected)
	_update_speaker_ui()
	voice_toggle.button_pressed = AppState.voice_enabled
	_update_voice_badge()
	voice_toggle.toggled.connect(_on_voice_toggled)
	%CoreAddressValue.text = AppState.core_url
	memory_panel.visible = false
	save_panel.visible = false
	settings_panel.visible = false
	_close_overlays(true)
	recent_rest_y = recent_panel.position.y
	composer_rest_y = dialogue_layer.position.y
	recent_panel.visible = false
	dialogue_layer.visible = false
	subtitle_layer.visible = false
	user_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reply_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_action_buttons()
	_refresh_story_ui()
	print("Latency log: ", LatencyLog.log_path())
	_ensure_save()
	if not SceneTransition.busy:
		_prepare_scene_enter()

func _uses_story_cast() -> bool:
	return true

func _return_to_title() -> void:
	if leaving_story or SceneTransition.busy:
		return
	leaving_story = true
	reveal_generation += 1
	story_transition_generation += 1
	typing = false
	AudioController.cancel_pending()
	stage_director.stop_speaking()
	ApiClient.disconnect_chat()
	_close_overlays(true)
	var error: int = await SceneTransition.change_to("res://scenes/Title.tscn")
	if error != OK and is_inside_tree():
		leaving_story = false
		ApiClient.connect_chat()
		_refresh_story_ui()

func _exit_tree() -> void:
	reveal_generation += 1
	story_transition_generation += 1
	AudioController.cancel_pending()
	ApiClient.disconnect_chat()

func _prepare_scene_enter() -> void:
	if scene_entry_tween:
		scene_entry_tween.kill()
	scene_entry_tween = create_tween().set_parallel(true)
	var groups: Array[Node] = [get_node("CharacterStage"), get_node("TopBar"), get_node("SceneInfo"), get_node("ToolRail"), chat_dock_button]
	for name in ["NecoPortrait", "NecoBubble", "ArcueidBubble", "ClassroomSpeakerRow"]:
		var control := get_node_or_null(name)
		if control:
			groups.append(control)
	for index in groups.size():
		var control := groups[index] as CanvasItem
		control.modulate.a = 0.0
		scene_entry_tween.tween_property(control, "modulate:a", 1.0, 0.55).set_delay(minf(index * 0.035, 0.18)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _prepare_scene_exit() -> void:
	if scene_entry_tween:
		scene_entry_tween.kill()
	scene_exit_tween = create_tween().set_parallel(true)
	for control in [get_node("TopBar"), get_node("SceneInfo"), get_node("ToolRail"), chat_dock_button, dialogue_layer]:
		scene_exit_tween.tween_property(control, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_SINE)

func _cancel_scene_exit() -> void:
	if scene_exit_tween:
		scene_exit_tween.kill()
	for control in [get_node("TopBar"), get_node("SceneInfo"), get_node("ToolRail"), chat_dock_button, dialogue_layer]:
		control.modulate.a = 1.0

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		input_box.release_focus()
		_hide_recent()
		_close_composer()
		_close_overlays()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if input_box.has_focus() and not input_box.get_global_rect().has_point(event.position):
			input_box.release_focus()

func _on_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_overlays()

func _close_overlays(immediate: bool = false) -> void:
	overlay_generation += 1
	var generation := overlay_generation
	if overlay_tween and overlay_tween.is_running():
		overlay_tween.kill()
	if immediate or not overlay_dim.visible:
		for panel in [memory_panel, save_panel, settings_panel, chat_log_panel]:
			panel.visible = false
		overlay_dim.visible = false
		return
	overlay_tween = create_tween().set_parallel(true)
	overlay_tween.tween_property(overlay_dim, "modulate:a", 0.0, 0.16)
	for panel in [memory_panel, save_panel, settings_panel, chat_log_panel]:
		if panel.visible:
			overlay_tween.tween_property(panel, "modulate:a", 0.0, 0.16)
	overlay_tween.chain().tween_callback(func() -> void:
		if generation != overlay_generation:
			return
		for panel in [memory_panel, save_panel, settings_panel, chat_log_panel]:
			panel.visible = false
		overlay_dim.visible = false
	)

func _show_panel(panel: PanelContainer) -> void:
	_close_overlays(true)
	_hide_recent()
	_close_composer()
	overlay_dim.visible = true
	overlay_dim.modulate.a = 0.0
	panel.visible = true
	panel.modulate.a = 0.0
	overlay_tween = create_tween().set_parallel(true)
	overlay_tween.tween_property(overlay_dim, "modulate:a", 1.0, 0.2)
	overlay_tween.tween_property(panel, "modulate:a", 1.0, 0.2)

func _on_input_focus_entered() -> void:
	_show_recent()

func _show_recent() -> void:
	if overlay_dim.visible or not input_box.has_focus():
		return
	if recent_tween and recent_tween.is_running():
		recent_tween.kill()
	if not recent_panel.visible:
		recent_panel.visible = true
		recent_panel.modulate.a = 0.0
		recent_panel.position.y = recent_rest_y + 12.0
	recent_tween = create_tween().set_parallel(true)
	recent_tween.tween_property(recent_panel, "modulate:a", 1.0, 0.2)
	recent_tween.tween_property(recent_panel, "position:y", recent_rest_y, 0.2)
	_scroll_to_bottom(recent_scroll)

func _hide_recent() -> void:
	if recent_tween and recent_tween.is_running():
		recent_tween.kill()
	if not recent_panel.visible:
		return
	recent_tween = create_tween().set_parallel(true)
	recent_tween.tween_property(recent_panel, "modulate:a", 0.0, 0.16)
	recent_tween.tween_property(recent_panel, "position:y", recent_rest_y + 12.0, 0.16)
	recent_tween.chain().tween_callback(func() -> void: recent_panel.visible = false)

func _on_input_focus_exited() -> void:
	_hide_recent()
	_close_composer()

func _open_composer() -> void:
	if composer_open or overlay_dim.visible:
		return
	composer_generation += 1
	composer_open = true
	if composer_tween and composer_tween.is_running():
		composer_tween.kill()
	chat_dock_button.visible = false
	dialogue_layer.visible = true
	dialogue_layer.modulate.a = 0.0
	dialogue_layer.position.y = composer_rest_y + 12.0
	composer_tween = create_tween().set_parallel(true)
	composer_tween.tween_property(dialogue_layer, "modulate:a", 1.0, 0.2)
	composer_tween.tween_property(dialogue_layer, "position:y", composer_rest_y, 0.2)
	input_box.grab_focus()

func _close_composer() -> void:
	if not composer_open:
		return
	composer_open = false
	composer_generation += 1
	var generation := composer_generation
	if input_box.has_focus():
		input_box.release_focus()
	if composer_tween and composer_tween.is_running():
		composer_tween.kill()
	composer_tween = create_tween().set_parallel(true)
	composer_tween.tween_property(dialogue_layer, "modulate:a", 0.0, 0.16)
	composer_tween.tween_property(dialogue_layer, "position:y", composer_rest_y + 12.0, 0.16)
	composer_tween.chain().tween_callback(func() -> void:
		if generation != composer_generation:
			return
		dialogue_layer.visible = false
		chat_dock_button.text = "继续输入　↗" if not input_box.text.is_empty() else "和%s说话　↗" % _speaker_name(selected_speaker_id)
		chat_dock_button.visible = true
		chat_dock_button.modulate.a = 0.0
		var dock_tween := create_tween()
		dock_tween.tween_property(chat_dock_button, "modulate:a", 1.0, 0.16)
	)

func _show_subtitles() -> void:
	if subtitle_tween and subtitle_tween.is_running():
		subtitle_tween.kill()
	if not subtitle_layer.visible:
		subtitle_layer.visible = true
		subtitle_layer.modulate.a = 0.0
	subtitle_tween = create_tween()
	subtitle_tween.tween_property(subtitle_layer, "modulate:a", 1.0, 0.2)

func _hide_subtitles(generation: int) -> void:
	if generation != reveal_generation or not subtitle_layer.visible:
		return
	if subtitle_tween and subtitle_tween.is_running():
		subtitle_tween.kill()
	subtitle_tween = create_tween()
	subtitle_tween.tween_property(subtitle_layer, "modulate:a", 0.0, 0.2)
	subtitle_tween.tween_callback(func() -> void:
		if generation == reveal_generation:
			subtitle_layer.visible = false
	)

func _open_memory() -> void:
	_show_panel(memory_panel)
	_load_memories()

func _open_saves() -> void:
	_show_panel(save_panel)
	%SaveStatus.text = ""
	_load_current_save()
	_load_saves()

func _open_settings() -> void:
	_show_panel(settings_panel)
	model_api_settings.refresh()
	%SettingsStatus.text = ""
	%CoreAddressValue.text = AppState.core_url
	voice_toggle.button_pressed = AppState.voice_enabled
	_load_current_save()

func _install_model_api_settings() -> void:
	var rows := settings_panel.get_node("Rows")
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rows.add_child(scroll)
	rows.move_child(scroll, 1)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	scroll.add_child(content)
	for node_name in ["SettingsDescription", "SettingsGrid", "VoiceEnabled"]:
		rows.get_node(node_name).reparent(content)
	content.get_node("SettingsGrid").size_flags_vertical = Control.SIZE_FILL
	content.get_node("SettingsDescription").text = "故事偏好与大模型 API 可分别保存。向下滚动可查看 API 配置和新手指南。"
	content.get_node("SettingsDescription").autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	model_api_settings = preload("res://scripts/ModelApiSettings.gd").new()
	content.add_child(model_api_settings)
	%SaveSettingsButton.text = "保存故事偏好"

func _open_chat_log() -> void:
	_show_panel(chat_log_panel)
	_load_chat_log()

func _load_current_save() -> void:
	if AppState.save_id.is_empty():
		return
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves", {}, func(success: bool, saves) -> void:
		if not success or not (saves is Array):
			return
		for save in saves:
			if str(save.get("id", "")) == AppState.save_id:
				current_save = save.duplicate(true)
				identity_option.select(1 if str(save.get("identity_mode", "self")) == "shiki" else 0)
				user_name_input.text = str(save.get("user_name", ""))
				return
	)

func _ensure_save() -> void:
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves", {}, func(success: bool, saves) -> void:
		if success and saves is Array and not saves.is_empty():
			for save in saves:
				if str(save.get("module", "stage")) != "teacher" and str(save.get("name", "")) != "教教我吧 · 爱尔奎特老师":
					_select_save(save, false)
					_connect_ready()
					return
		ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/saves", {"name": AppState.save_name, "identity_mode": AppState.identity_mode, "user_name": AppState.user_name}, func(created: bool, save) -> void:
			if created and save is Dictionary:
				_select_save(save, false)
				_connect_ready()
			else:
				status_label.text = "●　未连接到 Arcueid Core"
				_retry_ensure_save()
		)
	)

func _retry_ensure_save() -> void:
	if save_retry_pending:
		return
	save_retry_pending = true
	await get_tree().create_timer(2.0).timeout
	save_retry_pending = false
	if AppState.save_id.is_empty():
		_ensure_save()

func _connect_ready() -> void:
	ApiClient.connect_chat()
	status_label.text = "●　正在等待爱尔奎特"

func _on_connection_changed(online: bool) -> void:
	status_label.text = "●　可以说话了" if online else "●　Arcueid Core 未启动"
	status_label.add_theme_color_override("font_color", Color("#a4edcf") if online else Color("#f2c4d3"))

func _on_message_submitted(_text: String) -> void:
	_send()

func _story_active() -> bool:
	return not story_state.is_empty() and bool(story_state.get("active", false))

func _load_story_state(save_id: String) -> void:
	story_loading = true
	send_button.disabled = true
	_refresh_story_ui()
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves/%s/story" % save_id.uri_encode(), {}, func(success: bool, result) -> void:
		if AppState.save_id != save_id:
			return
		story_loading = false
		if success and result is Dictionary:
			var loaded = result.get("story")
			_set_story_state(loaded if loaded is Dictionary else {})
		_refresh_story_ui()
		if not typing and not story_transitioning and pending_story_state.is_empty() and not speaker_switching:
			send_button.disabled = false
	)

func _start_story() -> void:
	if story_transitioning:
		_finish_queued_story()
		return
	if AppState.save_id.is_empty() or typing or speaker_switching or story_loading:
		return
	if AppState.identity_mode != "shiki":
		_open_settings()
		%SettingsStatus.text = "这段《月姬R》样机需要先选择「以远野志贵身份相遇」。"
		return
	story_button.disabled = true
	var target_save_id := AppState.save_id
	var restart := not story_state.is_empty() and str(story_state.get("node_id", "")) == "complete"
	ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/saves/%s/story/start" % target_save_id.uri_encode(), {"restart": restart}, func(success: bool, result) -> void:
		if AppState.save_id != target_save_id:
			return
		if success and result is Dictionary and result.get("story") is Dictionary:
			_set_story_state(result["story"])
			status_label.text = "●　剧情已开始"
		else:
			story_button.disabled = false
			status_label.text = "●　剧情启动失败，请检查 Core 连接"
	)

func _open_teacher_stage() -> void:
	if typing or story_transitioning:
		return
	SceneTransition.change_to("res://scenes/Teacher.tscn", {"kind": "LESSON", "number": "1", "title": "教教我吧，爱尔奎特老师"})

func _send_story_suggestion(index: int) -> void:
	if not _story_active() or typing or story_transitioning or not pending_story_state.is_empty():
		return
	var suggestions: Array = story_state.get("suggestions", [])
	if index >= suggestions.size():
		return
	input_box.text = str(suggestions[index])
	_send()

func _queue_story_state(next_state: Dictionary) -> void:
	story_transition_generation += 1
	var generation := story_transition_generation
	var save_id := AppState.save_id
	queued_story_state = next_state.duplicate(true)
	story_transitioning = true
	send_button.disabled = true
	story_choice_a.disabled = true
	story_choice_b.disabled = true
	status_label.text = "●　剧情即将继续……"
	_refresh_story_ui()
	await get_tree().create_timer(8.0).timeout
	if generation != story_transition_generation or save_id != AppState.save_id:
		return
	_finish_queued_story()

func _finish_queued_story() -> void:
	if not story_transitioning or queued_story_state.is_empty():
		return
	story_transition_generation += 1
	story_transitioning = false
	var next_state := queued_story_state.duplicate(true)
	queued_story_state.clear()
	_set_story_state(next_state)
	if pending_story_state.is_empty() and not speaker_switching:
		send_button.disabled = false

func _set_story_state(next_state: Dictionary) -> void:
	story_state = next_state.duplicate(true)
	if _story_active():
		pending_story_state = story_state.duplicate(true)
	else:
		pending_story_state.clear()
	_refresh_story_ui()
	if _story_active():
		_try_apply_pending_story()

func _refresh_story_ui() -> void:
	story_button.disabled = not story_transitioning and (AppState.save_id.is_empty() or _story_active() or typing or story_loading)
	story_button.visible = story_transitioning or not _story_active()
	if story_state.is_empty():
		%SceneTitle.text = "黄昏的十字路口"
		%SceneSubtitle.text = "秋日 · 18:42　　｜　　双角色对话舞台"
		story_hint.visible = false
		story_button.text = "开始剧情样机"
		story_choice_a.visible = false
		story_choice_b.visible = false
		%MemoryTeaser.visible = true
		%LastLine.visible = selected_speaker_id == "arcueid"
		return
	story_hint.visible = true
	%SceneTitle.text = str(story_state.get("title", "公园前的阻拦"))
	%SceneSubtitle.text = "月姬R · 西耶尔线片段样机"
	var suggestions: Array = story_state.get("suggestions", [])
	story_hint.text = "%s\n\n目标：%s" % [str(story_state.get("situation", "")), str(story_state.get("goal", ""))]
	story_choice_a.visible = _story_active() and suggestions.size() >= 1
	story_choice_b.visible = _story_active() and suggestions.size() >= 2
	story_choice_a.disabled = typing or story_transitioning or not pending_story_state.is_empty()
	story_choice_b.disabled = story_choice_a.disabled
	var node_id := str(story_state.get("node_id", ""))
	story_choice_a.text = "直接请她别同行" if node_id == "ciel_warning" else "表明情感界限" if node_id == "arc_confrontation" else "说一句关心的话"
	story_choice_b.text = "说明冲突风险" if node_id == "ciel_warning" else "解释伤害后果"
	story_button.text = "继续剧情　→" if story_transitioning else "剧情进行中" if _story_active() else "重玩剧情样机"
	%MemoryTeaser.visible = not _story_active()
	%LastLine.visible = not _story_active() and selected_speaker_id == "arcueid"
	speaker_option.disabled = _story_active() or typing or speaker_switching

func _try_apply_pending_story() -> void:
	if pending_story_state.is_empty() or typing or speaker_switching or not pending_story_audio_request_id.is_empty() or not AudioController.is_idle():
		return
	var next_speaker := str(pending_story_state.get("speaker_id", ""))
	if next_speaker == selected_speaker_id or next_speaker.is_empty():
		pending_story_state.clear()
		send_button.disabled = false
		_refresh_story_ui()
		return
	pending_story_state.clear()
	var index := 1 if next_speaker == "ciel" else 0
	speaker_option.select(index)
	_on_speaker_selected(index, true)

func _speaker_name(speaker_id: String) -> String:
	return "希耶尔" if speaker_id == "ciel" else "爱尔奎特"

func _update_voice_badge() -> void:
	voice_badge.text = "VOICE　●　JAPANESE" if AppState.voice_enabled else "VOICE　○　OFF"

func _update_speaker_ui() -> void:
	var name := _speaker_name(selected_speaker_id)
	input_box.placeholder_text = "和%s说点什么……" % name
	chat_dock_button.text = "和%s说话　↗" % name
	%SceneSubtitle.text = "秋日 · 18:42　　｜　　双角色对话舞台"
	%LastLine.visible = selected_speaker_id == "arcueid"
	%MemoryNote.text = "希耶尔的专属记忆尚未建立。" if selected_speaker_id == "ciel" else "重要的片段会留在这里。固定的记忆会帮助爱尔奎特记住你们的故事。"
	_update_voice_badge()
	_refresh_story_ui()
	if not AppState.save_id.is_empty():
		_load_memory_teaser(AppState.save_id)

func _on_speaker_selected(index: int, forced: bool = false) -> void:
	if typing or speaker_switching or (_story_active() and not forced):
		speaker_option.select(0 if selected_speaker_id == "arcueid" else 1)
		return
	var next_speaker := "ciel" if index == 1 else "arcueid"
	if next_speaker == selected_speaker_id:
		return
	speaker_switching = true
	speaker_option.disabled = true
	send_button.disabled = true
	_close_composer()
	selected_speaker_id = next_speaker
	reveal_generation += 1
	reply_text.text = ""
	speaker_subtitle.text = ""
	user_subtitle.text = ""
	subtitle_layer.visible = false
	await stage_director.switch_character(next_speaker)
	speaker_switching = false
	speaker_option.disabled = _story_active()
	send_button.disabled = false
	_update_speaker_ui()
	status_label.text = "●　正在等待%s" % _speaker_name(selected_speaker_id)

func _send() -> void:
	if leaving_story:
		return
	var message := input_box.text.strip_edges()
	if message.is_empty() or typing or speaker_switching or story_loading or story_transitioning or not pending_story_state.is_empty():
		return
	var request_id := ApiClient.send_chat(message, selected_speaker_id)
	if request_id.is_empty():
		status_label.text = "●　连接还没有准备好"
		return
	LatencyLog.begin_turn(request_id, ApiClient.get_chat_started_usec(request_id))
	recent_messages.append({"role": "user", "display_text": message, "turn_id": request_id})
	active_reply_request_id = request_id
	_render_recent_history()
	input_box.clear()
	input_box.release_focus()
	_hide_recent()
	_close_composer()
	user_subtitle.text = "你：%s" % message
	speaker_subtitle.text = ""
	reply_text.text = ""
	reveal_generation += 1
	_show_subtitles()
	segment_presentations.clear()
	typing = true
	send_button.disabled = true
	story_choice_a.disabled = true
	story_choice_b.disabled = true
	speaker_option.disabled = true
	status_label.text = "●　%s正在想……" % _speaker_name(selected_speaker_id)

func _on_socket_event(event: Dictionary) -> void:
	if leaving_story:
		return
	match str(event.get("type", "")):
		"story.state":
			if event.get("story") is Dictionary:
				_queue_story_state(event["story"])
		"assistant.text.delta":
			var segment_index := int(event.get("segment_index", 0))
			var cached: Dictionary = segment_presentations.get(segment_index, {})
			cached["reply"] = str(event.get("text", ""))
			segment_presentations[segment_index] = cached
		"assistant.segment.completed":
			segment_presentations[int(event.get("segment_index", 0))] = _presentation_from_event(event)
			if not bool(event.get("voice_available", true)) or not AppState.voice_enabled:
				_present_text(_presentation_from_event(event), 0.0)
		"assistant.text.completed":
			pass
		"tts.ready":
			var presentation := _presentation_for_tts(event)
			if AppState.voice_enabled:
				AudioController.enqueue_remote(str(event.get("audio_url", "")), presentation)
		"tts.stream.started":
			if AppState.voice_enabled:
				AudioController.begin_stream(event, _presentation_for_tts(event))
		"tts.stream.chunk":
			AudioController.receive_stream_chunk(event)
		"tts.stream.completed":
			AudioController.end_stream(event)
		"tts.failed":
			if AppState.voice_enabled:
				_present_text(_presentation_for_tts(event), 0.0)
		"turn.completed":
			if bool(event.get("audio_pending", false)) and AppState.voice_enabled:
				pending_story_audio_request_id = str(event.get("request_id", ""))
			if not bool(event.get("audio_pending", false)) or not AppState.voice_enabled:
				typing = false
				send_button.disabled = story_transitioning or not pending_story_state.is_empty()
				speaker_option.disabled = _story_active()
				_refresh_story_ui()
				status_label.text = _idle_status()
		"tts.completed":
			if str(event.get("request_id", "")) == pending_story_audio_request_id:
				pending_story_audio_request_id = ""
			typing = false
			send_button.disabled = story_transitioning or not pending_story_state.is_empty()
			speaker_option.disabled = _story_active() or (AppState.voice_enabled and not AudioController.is_idle())
			_refresh_story_ui()
			status_label.text = _idle_status()
			if str(event.get("request_id", "")) == active_reply_request_id:
				active_reply_request_id = ""
				_load_recent_history()
			_try_apply_pending_story()
		"turn.error":
			pending_story_audio_request_id = ""
			typing = false
			send_button.disabled = false
			speaker_option.disabled = _story_active()
			_refresh_story_ui()
			status_label.text = "●　……刚才没有连上，再说一次。"
			if str(event.get("request_id", "")) == active_reply_request_id:
				active_reply_request_id = ""
				_load_recent_history()
				_hide_subtitles(reveal_generation)
			if _story_active() and not AppState.save_id.is_empty():
				_load_story_state(AppState.save_id)
			_try_apply_pending_story()
	_record_socket_latency(event)

func _presentation_from_event(event: Dictionary) -> Dictionary:
	var request_id := str(event.get("request_id", ""))
	return {
		"reply": str(event.get("reply", "")),
		"mood": str(event.get("mood", "neutral")),
		"expression": str(event.get("expression", "neutral")),
		"request_id": request_id,
		"speaker_id": str(event.get("speaker_id", "arcueid")),
		"segment_index": int(event.get("segment_index", -1)),
		"server_timing": event.get("timing", {}),
		"tts_ready_usec": Time.get_ticks_usec(),
	}

func _presentation_for_tts(event: Dictionary) -> Dictionary:
	var presentation := _presentation_from_event(event)
	if not str(presentation.get("reply", "")).is_empty():
		return presentation
	var replies: Array[String] = []
	var indices: Array = event.get("segment_indices", [int(event.get("segment_index", 0))])
	for raw_index in indices:
		var cached: Dictionary = segment_presentations.get(int(raw_index), {})
		var cached_reply := str(cached.get("reply", "")).strip_edges()
		if not cached_reply.is_empty():
			replies.append(cached_reply)
		presentation["mood"] = str(cached.get("mood", presentation.get("mood", "neutral")))
		presentation["expression"] = str(cached.get("expression", presentation.get("expression", "neutral")))
	presentation["reply"] = "\n".join(replies)
	return presentation

func _on_audio_playback_started(presentation: Dictionary, duration: float) -> void:
	_record_audio_started(presentation, duration)
	var speaking_id := str(presentation.get("speaker_id", "arcueid"))
	status_label.text = "●　%s正在说话……" % _speaker_name(speaking_id)
	_present_text(presentation, duration)

func _record_audio_started(presentation: Dictionary, duration: float) -> void:
	var request_id := str(presentation.get("request_id", ""))
	var first := not first_audio_started.has(request_id)
	first_audio_started[request_id] = true
	LatencyLog.record("audio.playback_started", {
		"request_id": request_id,
		"segment_index": int(presentation.get("segment_index", -1)),
		"first_audio": first,
		"ttfa_ms": LatencyLog.elapsed_ms(request_id),
		"audio_download_ms": presentation.get("audio_download_ms", null),
		"playback_queue_wait_ms": presentation.get("playback_queue_wait_ms", null),
		"tts_ready_to_playback_ms": presentation.get("tts_ready_to_playback_ms", null),
		"audio_duration_ms": snappedf(duration * 1000.0, 0.1),
		"server_timing": presentation.get("server_timing", {}),
	})

func _on_audio_playback_finished(_presentation: Dictionary) -> void:
	stage_director.stop_speaking(str(_presentation.get("speaker_id", "arcueid")))
	if not typing:
		status_label.text = _idle_status()
		if AudioController.is_idle():
			speaker_option.disabled = _story_active()
			_try_apply_pending_story()

func _on_audio_playback_failed(presentation: Dictionary) -> void:
	LatencyLog.record("audio.playback_failed", {
		"request_id": str(presentation.get("request_id", "")),
		"segment_index": int(presentation.get("segment_index", -1)),
		"client_elapsed_ms": LatencyLog.elapsed_ms(str(presentation.get("request_id", ""))),
	})
	_present_text(presentation, 0.0)
	status_label.text = _idle_status()
	if not typing and AudioController.is_idle():
		speaker_option.disabled = _story_active()
		_try_apply_pending_story()

func _idle_status() -> String:
	return "●　可以说话了" if AppState.core_online else "●　Arcueid Core 未启动"

func _record_socket_latency(event: Dictionary) -> void:
	var event_type := str(event.get("type", ""))
	if event_type not in ["turn.accepted", "retrieval.completed", "assistant.segment.completed", "assistant.text.completed", "tts.started", "tts.ready", "tts.failed", "tts.stream.started", "tts.stream.completed", "turn.completed", "tts.completed", "turn.error"]:
		return
	var request_id := str(event.get("request_id", ""))
	LatencyLog.record("ws.%s" % event_type, {
		"request_id": request_id,
		"segment_index": int(event.get("segment_index", -1)),
		"client_elapsed_ms": LatencyLog.elapsed_ms(request_id),
		"server_timing": event.get("timing", {}),
	})

func _present_text(presentation: Dictionary, audio_duration: float) -> void:
	var text := str(presentation.get("reply", "")).strip_edges()
	if text.is_empty():
		return
	var speaking_id := str(presentation.get("speaker_id", "arcueid"))
	speaker_subtitle.text = _speaker_name(speaking_id)
	reveal_generation += 1
	var generation := reveal_generation
	user_subtitle.text = ""
	_show_subtitles()
	var visible_characters: int = max(1, text.length())
	var reveal_duration: float = clampf(audio_duration - 0.08, 0.35, 8.0) if audio_duration > 0.0 else clampf(visible_characters * 0.055, 0.35, 4.0)
	stage_director.present(presentation, audio_duration if audio_duration > 0.0 else reveal_duration)
	_reveal_text(text, clampf(reveal_duration / visible_characters, 0.025, 0.11), generation, speaking_id)

func _reveal_text(text: String, delay: float, generation: int, speaking_id: String) -> void:
	for character in text:
		if generation != reveal_generation:
			return
		reply_text.append_text(character)
		reply_text.scroll_to_line(reply_text.get_line_count())
		await get_tree().create_timer(delay).timeout
	if generation == reveal_generation:
		await get_tree().create_timer(4.0).timeout
		while generation == reveal_generation and is_instance_valid(AudioController.player) and AudioController.player.playing and bool(AudioController.current_presentation.get("streaming", false)):
			await get_tree().process_frame
		_hide_subtitles(generation)

func _load_memories() -> void:
	for child in memory_list.get_children():
		child.queue_free()
	if selected_speaker_id == "ciel":
		_add_empty_message(memory_list, "希耶尔的独立记忆尚未启用；当前只保留公开对话记录。")
		return
	if AppState.save_id.is_empty():
		return
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves/%s/memories" % AppState.save_id.uri_encode(), {}, func(success: bool, memories) -> void:
		if selected_speaker_id != "arcueid":
			return
		if not success or not (memories is Array):
			_add_empty_message(memory_list, "记忆暂时无法读取，请确认 Core 已启动。")
			return
		if memories.is_empty():
			_add_empty_message(memory_list, "还没有保存的记忆。和爱尔奎特多聊几句，这里会慢慢留下你们的故事。")
			return
		for memory in memories:
			_add_memory_row(memory)
	)

func _add_memory_row(memory: Dictionary) -> void:
	var memory_id := str(memory.get("id", ""))
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _make_row_style())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 9)
	row.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)
	var editor := TextEdit.new()
	editor.custom_minimum_size = Vector2(0, 60)
	editor.text = str(memory.get("content", ""))
	editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	editor.add_theme_color_override("font_color", Color("#e6eef9"))
	editor.add_theme_stylebox_override("normal", _make_field_style())
	content.add_child(editor)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	content.add_child(controls)
	var state := Label.new()
	state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	state.text = _memory_status(str(memory.get("status", "candidate")))
	state.add_theme_color_override("font_color", Color("#a9efff"))
	controls.add_child(state)
	var save := _make_button("保存")
	save.pressed.connect(func() -> void:
		ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/memories/%s" % memory_id.uri_encode(), {"content": editor.text}, func(_ok: bool, _result) -> void: _load_memories())
	)
	controls.add_child(save)
	var pin := _make_button("固定")
	pin.pressed.connect(func() -> void:
		var next_status := "active" if str(memory.get("status", "")) == "pinned" else "pinned"
		ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/memories/%s" % memory_id.uri_encode(), {"status": next_status}, func(_ok: bool, _result) -> void: _load_memories())
	)
	controls.add_child(pin)
	var delete := _make_button("删除")
	delete.pressed.connect(func() -> void:
		ApiClient.request_json(HTTPClient.METHOD_DELETE, "/api/v2/memories/%s" % memory_id.uri_encode(), {}, func(_ok: bool, _result) -> void: _load_memories())
	)
	controls.add_child(delete)
	memory_list.add_child(row)

func _memory_status(status: String) -> String:
	match status:
		"pinned": return "已固定"
		"active": return "已保存"
		"candidate": return "待确认"
		_: return status

func _load_saves() -> void:
	for child in save_list.get_children():
		child.queue_free()
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves", {}, func(success: bool, saves) -> void:
		if not success or not (saves is Array):
			_add_empty_message(save_list, "存档暂时无法读取，请确认 Core 已启动。")
			return
		if saves.is_empty():
			_add_empty_message(save_list, "还没有故事存档。可以在下方开始新的相遇。")
			return
		for save in saves:
			if str(save.get("module", "stage")) != "teacher" and str(save.get("name", "")) != "教教我吧 · 爱尔奎特老师":
				_add_save_row(save)
	)

func _add_save_row(save: Dictionary) -> void:
	var record := save.duplicate(true)
	var save_id := str(record.get("id", ""))
	var selected := save_id == AppState.save_id
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _make_row_style())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 11)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 11)
	row.add_child(margin)
	var layout := HBoxContainer.new()
	layout.add_theme_constant_override("separation", 13)
	margin.add_child(layout)
	var icon := Label.new()
	icon.custom_minimum_size = Vector2(52, 52)
	icon.text = "☾"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.add_theme_color_override("font_color", Color("#b7e8ff"))
	icon.add_theme_font_size_override("font_size", 27)
	layout.add_child(icon)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 4)
	layout.add_child(details)
	var title := Label.new()
	title.text = str(record.get("name", "新的记录"))
	title.add_theme_color_override("font_color", Color("#edf4ff"))
	title.add_theme_font_size_override("font_size", 17)
	details.add_child(title)
	var mode := "公主线" if str(record.get("identity_mode", "self")) == "self" else "志贵视角"
	var timestamp := str(record.get("updated_at", "")).replace("T", " ").split(".")[0]
	var meta := Label.new()
	meta.text = "%s　·　%s" % [timestamp if not timestamp.is_empty() else "尚未开始", mode]
	meta.add_theme_color_override("font_color", Color("#99aec9"))
	meta.add_theme_font_size_override("font_size", 11)
	details.add_child(meta)
	var select := _make_button("当前故事" if selected else "继续")
	select.custom_minimum_size = Vector2(108, 40)
	select.disabled = selected
	select.pressed.connect(func() -> void: _select_save(record))
	layout.add_child(select)
	save_list.add_child(row)

func _select_save(save: Dictionary, refresh: bool = true) -> void:
	story_transition_generation += 1
	story_transitioning = false
	queued_story_state.clear()
	story_loading = false
	story_state.clear()
	pending_story_state.clear()
	pending_story_audio_request_id = ""
	current_save = save.duplicate(true)
	AppState.save_id = str(save.get("id", ""))
	AppState.save_name = str(save.get("name", "新的记录"))
	AppState.identity_mode = str(save.get("identity_mode", "self"))
	AppState.user_name = str(save.get("user_name", ""))
	identity_option.select(1 if AppState.identity_mode == "shiki" else 0)
	user_name_input.text = AppState.user_name
	_load_memory_teaser(AppState.save_id)
	reply_text.text = ""
	active_reply_request_id = ""
	_load_recent_history()
	_refresh_story_ui()
	_load_story_state(AppState.save_id)
	if refresh:
		%SaveStatus.text = "已切换到「%s」" % AppState.save_name
		_load_saves()

func _load_memory_teaser(save_id: String) -> void:
	if selected_speaker_id == "ciel":
		%MemoryTeaser.text = "希耶尔的专属记忆尚未启用。"
		return
	%MemoryTeaser.text = "和爱尔奎特多聊几句，一起留下新的回忆。"
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves/%s/memories" % save_id.uri_encode(), {}, func(success: bool, memories) -> void:
		if selected_speaker_id != "arcueid" or AppState.save_id != save_id:
			return
		if not success or not (memories is Array):
			return
		for memory in memories:
			if str(memory.get("status", "")) in ["pinned", "active"]:
				%MemoryTeaser.text = "她还记得：\n%s" % str(memory.get("content", ""))
				return
	)

func _load_recent_history(save_id: String = "") -> void:
	var target_save_id := save_id if not save_id.is_empty() else AppState.save_id
	if target_save_id.is_empty():
		recent_messages.clear()
		_render_recent_history()
		return
	var path := "/api/v2/saves/%s/messages?limit=6" % target_save_id.uri_encode()
	ApiClient.request_json(HTTPClient.METHOD_GET, path, {}, func(success: bool, messages) -> void:
		if not success or not (messages is Array) or AppState.save_id != target_save_id:
			return
		var pending_user: Dictionary = {}
		if not active_reply_request_id.is_empty():
			for recent_message in recent_messages:
				if str(recent_message.get("turn_id", "")) == active_reply_request_id and str(recent_message.get("role", "")) == "user":
					pending_user = recent_message
					break
		recent_messages = messages
		if not pending_user.is_empty():
			var pending_is_saved := false
			for saved_message in recent_messages:
				if str(saved_message.get("turn_id", "")) == active_reply_request_id and str(saved_message.get("role", "")) == "user":
					pending_is_saved = true
					break
			if not pending_is_saved:
				recent_messages.append(pending_user)
		_render_recent_history()
	)

func _render_recent_history() -> void:
	for child in recent_list.get_children():
		child.queue_free()
	if recent_messages.is_empty():
		_add_empty_message(recent_list, "还没有对话记录。输入一句话，开始你们的故事。")
		return
	var first_message := maxi(0, recent_messages.size() - 6)
	for index in range(first_message, recent_messages.size()):
		_add_conversation_entry(recent_list, recent_messages[index])
	_scroll_to_bottom(recent_scroll)

func _load_chat_log() -> void:
	for child in chat_log_list.get_children():
		child.queue_free()
	%ChatLogStatus.text = "正在读取对话记录……"
	if AppState.save_id.is_empty():
		_add_empty_message(chat_log_list, "当前还没有可读取的故事存档。")
		%ChatLogStatus.text = ""
		return
	var target_save_id := AppState.save_id
	var path := "/api/v2/saves/%s/messages?limit=0" % target_save_id.uri_encode()
	ApiClient.request_json(HTTPClient.METHOD_GET, path, {}, func(success: bool, messages) -> void:
		if AppState.save_id != target_save_id:
			return
		for child in chat_log_list.get_children():
			child.queue_free()
		if not success or not (messages is Array):
			_add_empty_message(chat_log_list, "记录读取失败，请确认 Arcueid Core 已启动。")
			%ChatLogStatus.text = ""
			return
		var log_messages: Array = messages
		if not active_reply_request_id.is_empty():
			var pending_is_saved := false
			for saved_message in log_messages:
				if str(saved_message.get("turn_id", "")) == active_reply_request_id and str(saved_message.get("role", "")) == "user":
					pending_is_saved = true
					break
			if not pending_is_saved:
				for recent_message in recent_messages:
					if str(recent_message.get("turn_id", "")) == active_reply_request_id and str(recent_message.get("role", "")) == "user":
						log_messages.append(recent_message)
						break
		if log_messages.is_empty():
			_add_empty_message(chat_log_list, "这段故事还没有对话记录。")
		else:
			for message in log_messages:
				_add_conversation_entry(chat_log_list, message)
		%ChatLogStatus.text = "%d 条对话记录" % log_messages.size()
		_scroll_to_bottom(chat_log_scroll)
	)

func _add_conversation_entry(target_list: VBoxContainer, message: Dictionary) -> void:
	var is_user := str(message.get("role", "")) == "user"
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _make_conversation_style(is_user))
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 4)
	card.add_child(content)
	var speaker := Label.new()
	speaker.text = "你" if is_user else _speaker_name(str(message.get("speaker_id", "arcueid")))
	speaker.add_theme_font_size_override("font_size", 12)
	speaker.add_theme_color_override("font_color", Color("#a9efff") if is_user else Color("#f2c4d3"))
	content.add_child(speaker)
	var body := Label.new()
	body.text = str(message.get("display_text", message.get("content", "")))
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 15)
	body.add_theme_color_override("font_color", Color("#eaf1fc"))
	content.add_child(body)
	target_list.add_child(card)

func _scroll_to_bottom(scroll: ScrollContainer) -> void:
	await get_tree().process_frame
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)

func _create_save() -> void:
	var save_name: String = %SaveNameInput.text.strip_edges()
	if save_name.is_empty():
		save_name = "月下的新故事"
	var identity_mode := "shiki" if identity_option.selected == 1 else "self"
	ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/saves", {"name": save_name, "identity_mode": identity_mode, "user_name": user_name_input.text.strip_edges()}, func(success: bool, save) -> void:
		if success and save is Dictionary:
			_select_save(save)
			%SaveNameInput.clear()
			%SaveStatus.text = "新故事已经开始。"
		else:
			%SaveStatus.text = "新建失败，请检查 Core 连接。"
	)

func _save_settings() -> void:
	if AppState.save_id.is_empty():
		%SettingsStatus.text = "当前还没有可设置的存档。"
		return
	var identity_mode := "shiki" if identity_option.selected == 1 else "self"
	var changes := {"identity_mode": identity_mode, "user_name": user_name_input.text.strip_edges()}
	ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/saves/%s" % AppState.save_id.uri_encode(), changes, func(success: bool, save) -> void:
		if success and save is Dictionary:
			_select_save(save)
			%SettingsStatus.text = "设置已保存到当前故事。"
		else:
			%SettingsStatus.text = "保存失败，请检查 Core 连接。"
	)

func _on_voice_toggled(enabled: bool) -> void:
	AudioController.set_voice_enabled(enabled)
	_update_voice_badge()
	%SettingsStatus.text = "语音播放已%s。" % ("开启" if enabled else "关闭")

func _add_empty_message(list: VBoxContainer, message: String) -> void:
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(0, 56)
	label.add_theme_color_override("font_color", Color("#a9bbd2"))
	list.add_child(label)

func _make_button(caption: String) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(70, 36)
	SCENE_UI.scene_button(button, SCENE_UI.BUTTON_BODY_SIZE)
	return button

func _make_row_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.14, 0.25, 0.72)
	style.border_color = Color(0.65, 0.78, 0.94, 0.16)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	return style

func _make_conversation_style(is_user: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.16, 0.27, 0.62) if is_user else Color(0.14, 0.1, 0.2, 0.62)
	style.border_color = Color(0.45, 0.77, 0.98, 0.22) if is_user else Color(0.91, 0.62, 0.74, 0.2)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _make_field_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.055, 0.115, 0.95)
	style.border_color = Color(0.65, 0.78, 0.94, 0.28)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style

func _make_button_style(highlight: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.19, 0.37, 0.58, 0.6) if highlight else Color(0.07, 0.13, 0.24, 0.8)
	style.border_color = Color(0.66, 0.88, 1, 0.57) if highlight else Color(0.65, 0.78, 0.94, 0.25)
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _style_action_buttons() -> void:
	theme = SCENE_UI.THEME
	for control in find_children("*", "Button", true, false):
		var button := control as Button
		SCENE_UI.scene_button(button, SCENE_UI.BUTTON_BODY_SIZE)
	var rail := get_node("ToolRail") as Control
	rail.offset_left = -208
	%MemoryButton.text = "记忆"
	%SaveButton.text = "存档"
	%SettingsButton.text = "系统设置"
	SCENE_UI.typography(self)
