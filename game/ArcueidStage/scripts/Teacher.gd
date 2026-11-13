extends "res://scripts/Main.gd"

const TEACHER_SAVE_NAME := "教教我吧 · 爱尔奎特老师"
const CLASSROOM_STYLE := preload("res://scripts/ClassroomStyle.gd")
const UI_STYLE := preload("res://scripts/UiStyle.gd")
const DIALOGUE_DIRECTOR := preload("res://scripts/DialogueDirector.gd")
const NECO_ANIMATOR := preload("res://scripts/NecoAnimator.gd")

var neco_animator: Node
var dialogue_director: Node

var teacher_save_ready := false
var previous_stage_save: Dictionary = {}
var bubble_generation := 0
var bubble_running: Dictionary = {"arcueid": false, "neco_arc": false}
var bubble_audio_key := ""
var bubble_audio_done := false
const TEXT_ONLY_CHARACTER_SECONDS := 0.085
const STREAM_CHARACTER_SECONDS := 0.11
var classroom_revision := 0
var classroom_operation := false
var leaving_classroom := false
var restoring_progress := false
var progress_serial := 0
var progress_in_flight := false
var progress_dirty := false
var progress_timer: Timer
var confirmation: ConfirmationDialog
var confirmation_action: Callable
var checkpoint_records: Dictionary = {}
var checkpoint_save_buttons: Array[Button] = []
var checkpoint_action_buttons: Array[Button] = []
var checkpoint_list_generation := 0

func _uses_story_cast() -> bool:
	return false

func _ready() -> void:
	previous_stage_save = {"id": AppState.save_id, "name": AppState.save_name, "identity_mode": AppState.identity_mode, "user_name": AppState.user_name}
	AppState.save_id = ""
	dialogue_director = DIALOGUE_DIRECTOR.new()
	add_child(dialogue_director)
	dialogue_director.segment_started.connect(_on_director_segment_started)
	dialogue_director.segment_finished.connect(_on_director_segment_finished)
	dialogue_director.turn_finished.connect(_on_director_turn_finished)
	super._ready()
	AudioController.controlled_playback = true
	AudioController.audio_prepared.connect(_on_audio_prepared)
	%ReturnButton.pressed.connect(_return_to_main)
	for button in [%ReturnButton]:
		button.add_theme_color_override("font_color", Color("#dceeff"))
		button.add_theme_stylebox_override("normal", _make_button_style(false))
		button.add_theme_stylebox_override("hover", _make_button_style(true))
	%SaveButton.visible = true
	%SaveButton.text = "存档 / 读档"
	%TeacherEntryButton.visible = false
	%MemoryButton.pressed.disconnect(_open_memory)
	%MemoryButton.pressed.connect(_open_chat_log)
	%MemoryButton.text = "01\n记录"
	identity_option.disabled = true
	var bubble_style := _make_row_style()
	bubble_style.content_margin_left = 16.0
	bubble_style.content_margin_right = 16.0
	bubble_style.content_margin_top = 12.0
	bubble_style.content_margin_bottom = 12.0
	%NecoBubble.add_theme_stylebox_override("panel", bubble_style)
	%ArcueidBubble.add_theme_stylebox_override("panel", bubble_style.duplicate())
	%ArcueidLine.text = "好啦，今天由我陪你聊。有什么想说的？"
	%LastLine.visible = false
	chat_dock_button.text = "向爱尔奎特提问　↗"
	input_box.placeholder_text = "向爱尔奎特提问，或继续追问……"
	chat_dock_button.position.x = size.x * 0.21
	dialogue_layer.anchor_left = 0.21
	dialogue_layer.offset_left = 0.0
	composer_rest_y = dialogue_layer.position.y
	speaker_option.clear()
	speaker_option.add_item("自由聊天", 0)
	speaker_option.add_item("对爱尔奎特说", 1)
	speaker_option.add_item("对猫姬说", 2)
	selected_speaker_id = "auto"
	speaker_option.reparent(%ClassroomSpeakerRow)
	speaker_option.select(0)
	_update_speaker_ui()
	StageDirector.current_character_id = "arcueid"
	StageDirector.set_expression("smile", "arcueid")
	CLASSROOM_STYLE.apply(self)
	neco_animator = NECO_ANIMATOR.new()
	add_child(neco_animator)
	neco_animator.bind(%NecoPortrait)
	_setup_classroom_saves()
	confirmation.theme = UI_STYLE.THEME
	UI_STYLE.scene_button(confirmation.get_ok_button(), UI_STYLE.BUTTON_BODY_SIZE)
	UI_STYLE.scene_button(confirmation.get_cancel_button(), UI_STYLE.BUTTON_BODY_SIZE)

func _exit_tree() -> void:
	if teacher_save_ready:
		_cache_teacher_ui()
	bubble_generation += 1
	dialogue_director.cancel()
	AudioController.cancel_pending()
	AudioController.controlled_playback = false
	StageDirector.stop_speaking()
	ApiClient.disconnect_chat()
	AppState.save_id = str(previous_stage_save.get("id", ""))
	AppState.save_name = str(previous_stage_save.get("name", "新的记录"))
	AppState.identity_mode = str(previous_stage_save.get("identity_mode", "self"))
	AppState.user_name = str(previous_stage_save.get("user_name", ""))

func _show_recent() -> void:
	# Classroom history is opened explicitly with the record buttons.
	_hide_recent()

func _hide_recent() -> void:
	if recent_tween and recent_tween.is_running():
		recent_tween.kill()
	recent_panel.visible = false

func _show_subtitles() -> void:
	subtitle_layer.visible = false

func _on_director_segment_started(presentation: Dictionary, stream: AudioStream) -> void:
	var speaker_id := str(presentation.get("speaker_id", "arcueid"))
	var text := str(presentation.get("reply", "")).strip_edges()
	var audio_duration := stream.get_length() if stream != null else 0.0
	var delay := audio_duration / maxf(text.length(), 1.0) if audio_duration > 0.0 else STREAM_CHARACTER_SECONDS
	var acting_duration := maxf(audio_duration, delay * text.length())
	if speaker_id == "neco_arc":
		StageDirector.stop_speaking("arcueid")
		neco_animator.present(presentation, acting_duration)
	else:
		neco_animator.stop_speaking()
		StageDirector.present(presentation, acting_duration)
	status_label.text = "●　%s正在说话……" % _speaker_name(speaker_id)
	bubble_audio_key = "%s:%s" % [presentation.get("request_id", ""), presentation.get("segment_index", -1)]
	bubble_audio_done = false
	if stream != null:
		AudioController.play_prepared(stream, presentation)
	_reveal_bubble(presentation, stream != null, bubble_generation)
	_refresh_story_ui()

func _reveal_bubble(presentation: Dictionary, voiced: bool, generation: int) -> void:
	var speaker_id := str(presentation.get("speaker_id", "arcueid"))
	if speaker_id not in bubble_running:
		dialogue_director.text_finished(presentation)
		return
	bubble_running[speaker_id] = true
	var line: Label = %NecoLine if speaker_id == "neco_arc" else %ArcueidLine
	if not line.text.is_empty():
		line.text += "\n"
	var text := str(presentation.get("reply", "")).strip_edges()
	var shown := 0
	var fallback_shown := 0
	var fallback_started := Time.get_ticks_usec()
	var using_fallback := not voiced
	var budget := 0.0
	var last_tick := Time.get_ticks_usec()
	while shown < text.length():
		if generation != bubble_generation:
			return
		var tick := Time.get_ticks_usec()
		budget = minf(budget + (tick - last_tick) / 1000000.0 * 18.0, 1.0)
		last_tick = tick
		var target := shown
		var timing: Dictionary = AudioController.reveal_timing(presentation) if voiced else {}
		if voiced and not using_fallback and (bubble_audio_done or not AppState.voice_enabled or timing.is_empty()):
			using_fallback = true
			fallback_shown = shown
			fallback_started = tick
		if using_fallback:
			target = fallback_shown + int((tick - fallback_started) / 1000000.0 / TEXT_ONLY_CHARACTER_SECONDS)
		elif float(timing.get("duration", 0.0)) > 0.0:
			target = int(text.length() * clampf(float(timing["elapsed"]) / float(timing["duration"]), 0.0, 1.0))
		else:
			# The final character waits for the stream length or playback completion.
			target = mini(int(float(timing.get("elapsed", 0.0)) / STREAM_CHARACTER_SECONDS), maxi(text.length() - 1, 0))
		if target > shown and budget >= 1.0:
			line.text += text[shown]
			shown += 1
			budget -= 1.0
			var scroll: ScrollContainer = %NecoScroll if speaker_id == "neco_arc" else %ArcueidScroll
			scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value))
		await get_tree().process_frame
	if generation != bubble_generation:
		return
	bubble_running[speaker_id] = false
	dialogue_director.text_finished(presentation)
	_refresh_story_ui()

func _on_director_segment_finished(presentation: Dictionary) -> void:
	if str(presentation.get("speaker_id", "")) == "neco_arc":
		neco_animator.stop_speaking()
	else:
		StageDirector.stop_speaking(str(presentation.get("speaker_id", "arcueid")))

func _on_director_turn_finished(request_id: String) -> void:
	if request_id != active_reply_request_id:
		return
	typing = false
	active_reply_request_id = ""
	pending_story_audio_request_id = ""
	_load_recent_history()
	status_label.text = _idle_status()
	_refresh_story_ui()
	_flush_progress()

func _speaker_name(speaker_id: String) -> String:
	if speaker_id == "auto":
		return "大家"
	return "猫姬" if speaker_id == "neco_arc" else super._speaker_name(speaker_id)

func _send() -> void:
	if not teacher_save_ready or classroom_operation or leaving_classroom or dialogue_director.is_busy() or not AudioController.is_idle():
		return
	var previous_request := active_reply_request_id
	super._send()
	if active_reply_request_id == previous_request:
		return
	bubble_generation += 1
	bubble_running = {"arcueid": false, "neco_arc": false}
	AudioController.cancel_pending()
	dialogue_director.begin(active_reply_request_id)
	neco_animator.stop_speaking()
	StageDirector.stop_speaking()
	%ArcueidLine.text = ""
	%NecoLine.text = ""
	_flush_progress()

func _on_socket_event(event: Dictionary) -> void:
	var request_id := str(event.get("request_id", ""))
	if not request_id.is_empty() and request_id != active_reply_request_id:
		return
	match str(event.get("type", "")):
		"assistant.segment.completed":
			var presentation := _presentation_from_event(event)
			segment_presentations[int(event.get("segment_index", 0))] = presentation
			dialogue_director.offer(presentation, AppState.voice_enabled and bool(event.get("voice_available", true)))
		"tts.ready":
			if AppState.voice_enabled:
				var presentation := _presentation_for_tts(event)
				dialogue_director.downloading(presentation)
				AudioController.enqueue_remote(str(event.get("audio_url", "")), presentation)
		"tts.stream.started":
			if AppState.voice_enabled:
				var presentation := _presentation_for_tts(event)
				if not dialogue_director.entries.has(int(event.get("segment_index", -1))):
					return
				dialogue_director.downloading(presentation)
				AudioController.begin_stream(event, presentation)
		"tts.stream.chunk":
			AudioController.receive_stream_chunk(event)
		"tts.stream.completed":
			AudioController.end_stream(event)
		"tts.failed":
			if AppState.voice_enabled:
				dialogue_director.resolve(_presentation_for_tts(event))
		"turn.completed":
			if not AppState.voice_enabled or not bool(event.get("audio_pending", false)):
				dialogue_director.seal()
		"tts.completed":
			dialogue_director.seal()
		"turn.error":
			AudioController.cancel_pending()
			dialogue_director.mute()
			dialogue_director.seal()
			status_label.text = "●　刚才连接中断了，已保留收到的文字。"
		_:
			super._on_socket_event(event)
	_record_socket_latency(event)
	_refresh_story_ui()

func _on_audio_playback_finished(presentation: Dictionary) -> void:
	_mark_bubble_audio_done(presentation)
	dialogue_director.audio_finished(presentation)
	_refresh_story_ui()

func _on_audio_playback_started(presentation: Dictionary, duration: float) -> void:
	_record_audio_started(presentation, duration)
	_refresh_story_ui()

func _on_audio_playback_failed(presentation: Dictionary) -> void:
	_mark_bubble_audio_done(presentation)
	dialogue_director.audio_finished(presentation)
	dialogue_director.resolve(presentation)
	_refresh_story_ui()

func _mark_bubble_audio_done(presentation: Dictionary) -> void:
	if bubble_audio_key == "%s:%s" % [presentation.get("request_id", ""), presentation.get("segment_index", -1)]:
		bubble_audio_done = true

func _on_audio_prepared(presentation: Dictionary, stream: AudioStream) -> void:
	if AppState.voice_enabled and dialogue_director.accepts(presentation) and dialogue_director.entries.has(int(presentation.get("segment_index", -1))):
		dialogue_director.resolve(presentation, stream)
	else:
		AudioController.discard_stream(presentation)

func _on_voice_toggled(enabled: bool) -> void:
	super._on_voice_toggled(enabled)
	if not enabled:
		dialogue_director.mute()
	_refresh_story_ui()

func _on_connection_changed(online: bool) -> void:
	if leaving_classroom or classroom_operation:
		return
	super._on_connection_changed(online)
	if not online and dialogue_director != null and dialogue_director.is_busy():
		AudioController.cancel_pending()
		dialogue_director.mute()
		dialogue_director.seal()
	_refresh_story_ui()

func _on_speaker_selected(index: int, _forced: bool = false) -> void:
	if typing or (dialogue_director != null and dialogue_director.is_busy()) or not AudioController.is_idle():
		_update_speaker_ui()
		return
	selected_speaker_id = ["auto", "arcueid", "neco_arc"][clampi(index, 0, 2)]
	_update_speaker_ui()
	status_label.text = "●　正在和%s对话" % _speaker_name(selected_speaker_id)
	_flush_progress()

func _update_speaker_ui() -> void:
	speaker_option.select(["auto", "arcueid", "neco_arc"].find(selected_speaker_id))
	chat_dock_button.text = "说点什么　↗" if selected_speaker_id == "auto" else "和%s说话　↗" % _speaker_name(selected_speaker_id)
	input_box.placeholder_text = "想问、想分享，或随便聊聊……" if selected_speaker_id == "auto" else "对%s说点什么……" % _speaker_name(selected_speaker_id)
	_refresh_story_ui()

func _ensure_save() -> void:
	status_label.text = "●　正在恢复课堂对话记录"
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/teacher/progress", {}, func(success: bool, progress) -> void:
		if leaving_classroom:
			return
		if success and progress is Dictionary and progress.get("save") is Dictionary:
			_apply_teacher_progress(progress, true)
			_connect_ready()
		else:
			var code := int(progress.get("_http_status", 0)) if progress is Dictionary else 0
			if code == 404:
				status_label.text = "●　Core 版本过旧，请重启后端"
			elif code == 0:
				status_label.text = "●　Core 未连接，正在重试"
			else:
				status_label.text = "●　课堂存档恢复失败（HTTP %d），正在重试" % code
			_retry_ensure_save()
	)

func _retry_ensure_save() -> void:
	if save_retry_pending:
		return
	save_retry_pending = true
	await get_tree().create_timer(3.0).timeout
	save_retry_pending = false
	if not teacher_save_ready and not leaving_classroom:
		_ensure_save()

func _load_story_state(_save_id: String) -> void:
	story_state.clear()
	story_loading = false
	_refresh_story_ui()

func _refresh_story_ui() -> void:
	story_button.visible = false
	story_hint.visible = false
	story_choice_a.visible = false
	story_choice_b.visible = false
	%TeacherEntryButton.visible = false
	%SceneTitle.text = "教教我吧，爱尔奎特老师"
	%SceneSubtitle.text = "全路线知识　｜　课堂进度自动保存"
	%MemoryTeaser.visible = true
	%LastLine.visible = false
	var busy := _classroom_busy()
	speaker_option.disabled = busy or classroom_operation or leaving_classroom or not teacher_save_ready
	send_button.disabled = speaker_option.disabled
	%ReturnButton.disabled = classroom_operation or leaving_classroom
	%SaveSettingsButton.disabled = speaker_option.disabled
	%NewSaveButton.disabled = classroom_operation or leaving_classroom or not teacher_save_ready
	for button in checkpoint_save_buttons:
		if is_instance_valid(button):
			button.disabled = speaker_option.disabled
	for button in checkpoint_action_buttons:
		if is_instance_valid(button):
			button.disabled = classroom_operation or leaving_classroom or not teacher_save_ready

func _load_memory_teaser(_save_id: String) -> void:
	%MemoryTeaser.text = "角色、设定、路线与结局，都可以直接问。"

func _make_conversation_style(is_user: bool) -> StyleBoxFlat:
	var style := super._make_conversation_style(is_user)
	style.bg_color = Color(0.03, 0.075, 0.14, 0.66)
	style.set_corner_radius_all(0)
	style.set_border_width_all(0)
	style.border_width_left = 2
	style.border_color = Color(0.3, 0.83, 1.0, 0.75) if is_user else Color(0.74, 0.88, 1.0, 0.35)
	return style

func _make_button(caption: String) -> Button:
	var button := super._make_button(caption)
	UI_STYLE.scene_button(button, UI_STYLE.BUTTON_BODY_SIZE)
	return button

func _add_conversation_entry(target_list: VBoxContainer, message: Dictionary) -> void:
	super._add_conversation_entry(target_list, message)
	var content := target_list.get_child(target_list.get_child_count() - 1).get_child(0)
	var speaker := content.get_child(0) as Label
	var body := content.get_child(1) as Label
	speaker.add_theme_font_size_override("font_size", UI_STYLE.NAME_SIZE)
	body.add_theme_font_size_override("font_size", UI_STYLE.BODY_SIZE)
	speaker.add_theme_font_override("font", UI_STYLE.THEME.default_font)
	body.add_theme_font_override("font", UI_STYLE.THEME.default_font)

func _add_empty_message(target_list: VBoxContainer, message: String) -> void:
	super._add_empty_message(target_list, message)
	var label := target_list.get_child(target_list.get_child_count() - 1) as Label
	label.add_theme_font_size_override("font_size", UI_STYLE.BODY_SIZE)

func _return_to_main() -> void:
	if classroom_operation or leaving_classroom:
		return
	_confirm_classroom("返回标题界面？已完成的对话会自动保留，草稿也会保存。" +
		("\n当前回答将停止；下次进入时从上一轮完整对话继续。" if _classroom_busy() else ""), _leave_for_title, "返回标题")

func _classroom_busy() -> bool:
	return typing or (dialogue_director != null and dialogue_director.is_busy()) or not AudioController.is_idle()

func _setup_classroom_saves() -> void:
	confirmation = ConfirmationDialog.new()
	confirmation.title = "课堂"
	confirmation.min_size = Vector2i(620, 180)
	confirmation.cancel_button_text = "取消"
	add_child(confirmation)
	confirmation.confirmed.connect(func() -> void:
		if confirmation_action.is_valid():
			confirmation_action.call()
	)
	progress_timer = Timer.new()
	progress_timer.one_shot = true
	progress_timer.wait_time = 0.7
	add_child(progress_timer)
	progress_timer.timeout.connect(_flush_progress)
	input_box.text_changed.connect(func(_text: String) -> void:
		if teacher_save_ready and not restoring_progress and not classroom_operation:
			progress_timer.start()
	)
	save_panel.get_node("Rows/Top/Headings/Title").text = "课堂存档"
	save_panel.get_node("Rows/Top/Headings/Kicker").text = "CLASSROOM / SAVE & LOAD"
	var note: Label = save_panel.get_node("Rows/SaveNote")
	note.text = "完整对话自动保存。手动存档保留历史、对话对象和草稿；读档前自动备份当前进度。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	%SaveNameInput.placeholder_text = "存档名称（可留空）；填写后点击存档位的保存"
	%SaveNameInput.max_length = 80
	input_box.max_length = 2000
	%NewSaveButton.text = "开始新课堂"
	%SaveDoneButton.text = "返回课堂"
	%SaveStatus.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	%SaveStatus.text = "已完成的对话会自动保存。"

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if confirmation.visible:
			return
		if overlay_dim.visible or composer_open:
			super._unhandled_key_input(event)
		else:
			_return_to_main()

func _confirm_classroom(message: String, action: Callable, accept: String) -> void:
	confirmation.dialog_text = message
	confirmation.ok_button_text = accept
	confirmation_action = action
	confirmation.popup_centered()

func _teacher_ui() -> Dictionary:
	return {"revision": classroom_revision, "selected_speaker_id": selected_speaker_id, "draft": input_box.text}

func _cache_teacher_ui() -> void:
	if not teacher_save_ready:
		return
	AppState.classroom_recovery = _teacher_ui().merged({"save_id": AppState.save_id, "core_url": AppState.core_url})
	AppState.save_preferences()

func _flush_progress() -> void:
	if not teacher_save_ready or restoring_progress or classroom_operation or leaving_classroom:
		return
	_cache_teacher_ui()
	if progress_in_flight:
		progress_dirty = true
		return
	progress_serial += 1
	var serial := progress_serial
	var payload := _teacher_ui()
	progress_in_flight = true
	progress_dirty = false
	ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/teacher/progress", payload, func(success: bool, _data) -> void:
		progress_in_flight = false
		if serial != progress_serial or leaving_classroom:
			if progress_dirty and not leaving_classroom:
				_flush_progress()
			return
		if success and payload == _teacher_ui():
			AppState.classroom_recovery.clear()
			AppState.save_preferences()
			%SaveStatus.text = "课堂进度已自动保存。"
		elif not success:
			%SaveStatus.text = "草稿已保存在本机，连接恢复后会再次保存。"
		if progress_dirty:
			_flush_progress()
	)

func _apply_teacher_progress(progress: Dictionary, recover_local: bool = false) -> void:
	restoring_progress = true
	progress_serial += 1
	if progress_timer != null:
		progress_timer.stop()
	classroom_revision = int(progress.get("revision", 0))
	teacher_save_ready = true
	var ui: Dictionary = progress.get("ui_state", {})
	var local := AppState.classroom_recovery
	if recover_local and str(local.get("save_id", "")) == str(progress["save"].get("id", "")) and int(local.get("revision", -1)) == classroom_revision and str(local.get("core_url", "")) == AppState.core_url:
		ui = local
	elif not recover_local:
		AppState.classroom_recovery.clear()
		AppState.save_preferences()
	selected_speaker_id = str(ui.get("selected_speaker_id", "auto"))
	if selected_speaker_id not in ["auto", "arcueid", "neco_arc"]:
		selected_speaker_id = "auto"
	_select_save(progress["save"], false)
	input_box.text = str(ui.get("draft", ""))
	recent_messages = progress.get("recent_messages", [])
	_render_recent_history()
	var lines: Dictionary = progress.get("last_lines", {})
	%ArcueidLine.text = str(lines.get("arcueid", "好啦，今天由我陪你聊。有什么想说的？"))
	%NecoLine.text = str(lines.get("neco_arc", "喵？这堂课可别让我无聊哦。"))
	StageDirector.set_expression("smile", "arcueid")
	if neco_animator != null:
		neco_animator.reset()
	_update_speaker_ui()
	restoring_progress = false
	_flush_progress()

func _load_recent_history(_save_id: String = "") -> void:
	if AppState.save_id.is_empty():
		return
	var revision := classroom_revision
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/teacher/progress", {}, func(success: bool, data) -> void:
		if not success or not (data is Dictionary) or revision != classroom_revision or leaving_classroom:
			return
		recent_messages = data.get("recent_messages", [])
		_render_recent_history()
	)

func _open_saves() -> void:
	_show_panel(save_panel)
	_load_saves()

func _load_saves() -> void:
	checkpoint_list_generation += 1
	var generation := checkpoint_list_generation
	for child in save_list.get_children():
		child.queue_free()
	checkpoint_save_buttons.clear()
	checkpoint_action_buttons.clear()
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/teacher/checkpoints", {}, func(success: bool, records) -> void:
		if leaving_classroom or generation != checkpoint_list_generation:
			return
		if not success or not (records is Array):
			_add_empty_message(save_list, "存档读取失败。关闭后重新打开可重试，已有存档不会被改动。")
			return
		checkpoint_records.clear()
		for record in records:
			checkpoint_records[int(record.get("slot", -1))] = record
		_add_empty_message(save_list, "自动保存 · 当前课堂\n每轮完整对话都会保留，下次从标题进入课堂时自动继续。")
		if checkpoint_records.has(0):
			_add_checkpoint_row(0, checkpoint_records[0])
		for slot in range(1, 7):
			_add_checkpoint_row(slot, checkpoint_records.get(slot, {}))
		_refresh_story_ui()
	)

func _add_checkpoint_row(slot: int, record: Dictionary) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _make_row_style())
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 12)
	card.add_child(columns)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(details)
	var title := Label.new()
	title.text = "自动备份" if slot == 0 else "存档 %02d · %s" % [slot, str(record.get("name", "空存档位"))]
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", UI_STYLE.BODY_SIZE)
	details.add_child(title)
	var description := Label.new()
	description.add_theme_font_size_override("font_size", UI_STYLE.CAPTION_SIZE)
	description.add_theme_color_override("font_color", Color("#a8c5d9"))
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if record.is_empty():
		description.text = "保存当前课堂的完整对话和草稿。"
	else:
		var stamp := str(record.get("updated_at", "")).split(".")[0]
		var unix := Time.get_unix_time_from_datetime_string(stamp)
		var local_time := Time.get_datetime_string_from_unix_time(unix + int(Time.get_time_zone_from_system()["bias"]) * 60, true)
		description.text = "%s · %d 轮 · 对话对象：%s\n%s" % [local_time, int(record.get("completed_turns", 0)), _speaker_name(str(record.get("selected_speaker_id", "arcueid"))), str(record.get("preview", ""))]
	details.add_child(description)
	var actions := VBoxContainer.new()
	columns.add_child(actions)
	if slot > 0:
		var save := _make_button("保存" if record.is_empty() else "覆盖保存")
		save.pressed.connect(_ask_save_checkpoint.bind(slot, not record.is_empty()))
		actions.add_child(save)
		checkpoint_save_buttons.append(save)
	if not record.is_empty():
		var load_button := _make_button("读取")
		load_button.pressed.connect(_ask_load_checkpoint.bind(slot))
		actions.add_child(load_button)
		checkpoint_action_buttons.append(load_button)
		if slot > 0:
			var remove := _make_button("删除")
			remove.pressed.connect(_ask_delete_checkpoint.bind(slot))
			actions.add_child(remove)
			checkpoint_action_buttons.append(remove)
	save_list.add_child(card)

func _ask_save_checkpoint(slot: int, occupied: bool) -> void:
	if _classroom_busy() or classroom_operation or not teacher_save_ready:
		%SaveStatus.text = "请等两位说完，再保存完整对话。"
		return
	if occupied:
		_confirm_classroom("覆盖存档 %02d？该存档原有内容将被当前课堂替换。" % slot, _write_checkpoint.bind(slot), "覆盖保存")
	else:
		_write_checkpoint(slot)

func _write_checkpoint(slot: int) -> void:
	if _classroom_busy():
		return
	classroom_operation = true
	_cache_teacher_ui()
	var payload := _teacher_ui().merged({"name": %SaveNameInput.text.strip_edges()})
	_refresh_story_ui()
	ApiClient.request_json(HTTPClient.METHOD_PUT, "/api/v2/teacher/checkpoints/%d" % slot, payload, func(success: bool, data) -> void:
		classroom_operation = false
		%SaveStatus.text = "已保存到存档 %02d。" % slot if success else _checkpoint_error(data)
		if success:
			%SaveNameInput.clear()
			_load_saves()
		_refresh_story_ui()
	)

func _ask_load_checkpoint(slot: int) -> void:
	_confirm_classroom("读取%s？当前进度会先保存到「自动备份」，可随时恢复。" % ("自动备份" if slot == 0 else "存档 %02d" % slot) +
		("\n当前回答将停止，未完成的这一轮不会进入存档。" if _classroom_busy() else ""), _restore_checkpoint.bind(slot), "读取存档")

func _create_save() -> void:
	if not teacher_save_ready or classroom_operation:
		return
	_confirm_classroom("开始一堂新的课堂？当前进度会先保存到「自动备份」，手动存档会保留。", _restore_checkpoint.bind(-1), "开始新课堂")

func _restore_checkpoint(slot: int) -> void:
	classroom_operation = true
	progress_serial += 1
	progress_timer.stop()
	_cache_teacher_ui()
	_refresh_story_ui()
	ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/teacher/stop", {}, func(stopped: bool, error) -> void:
		if not stopped:
			classroom_operation = false
			%SaveStatus.text = _checkpoint_error(error)
			_refresh_story_ui()
			return
		_cancel_classroom_playback()
		var path := "/api/v2/teacher/new" if slot < 0 else "/api/v2/teacher/checkpoints/%d/load" % slot
		ApiClient.request_json(HTTPClient.METHOD_POST, path, _teacher_ui(), func(success: bool, data) -> void:
			classroom_operation = false
			if success and data is Dictionary:
				_apply_teacher_progress(data)
				_close_overlays(true)
				_connect_ready()
				status_label.text = "●　新课堂已准备好" if slot < 0 else "●　存档已恢复，可以继续追问"
			else:
				%SaveStatus.text = _checkpoint_error(data)
				ApiClient.connect_chat()
			_load_saves()
			_refresh_story_ui()
		)
	)

func _ask_delete_checkpoint(slot: int) -> void:
	_confirm_classroom("删除存档 %02d？当前课堂进度和其他存档会保留。" % slot, _delete_checkpoint.bind(slot), "删除存档")

func _delete_checkpoint(slot: int) -> void:
	classroom_operation = true
	_refresh_story_ui()
	ApiClient.request_json(HTTPClient.METHOD_DELETE, "/api/v2/teacher/checkpoints/%d" % slot, {}, func(success: bool, data) -> void:
		classroom_operation = false
		%SaveStatus.text = "存档已删除。" if success else _checkpoint_error(data)
		_load_saves()
		_refresh_story_ui()
	)

func _checkpoint_error(data) -> String:
	var detail := str(data.get("detail", "连接失败，请重试；已有存档未改变。")) if data is Dictionary else "连接失败，请重试。"
	return "操作未完成：%s" % detail

func _cancel_classroom_playback() -> void:
	bubble_generation += 1
	bubble_running = {"arcueid": false, "neco_arc": false}
	active_reply_request_id = ""
	typing = false
	pending_story_audio_request_id = ""
	segment_presentations.clear()
	dialogue_director.cancel()
	AudioController.cancel_pending()
	StageDirector.stop_speaking()
	neco_animator.stop_speaking()
	ApiClient.disconnect_chat()

func _leave_for_title() -> void:
	leaving_classroom = true
	progress_timer.stop()
	progress_serial += 1
	_cache_teacher_ui()
	_refresh_story_ui()
	var payload := _teacher_ui()
	var was_online := AppState.core_online
	_cancel_classroom_playback()
	if not teacher_save_ready or not was_online:
		SceneTransition.change_to("res://scenes/Title.tscn")
		return
	ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/teacher/stop", {}, func(stopped: bool, _error) -> void:
		if not stopped:
			SceneTransition.change_to("res://scenes/Title.tscn")
			return
		ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/teacher/progress", payload, func(success: bool, _data) -> void:
			if success:
				AppState.classroom_recovery.clear()
				AppState.save_preferences()
			SceneTransition.change_to("res://scenes/Title.tscn")
		)
	)

func _save_settings() -> void:
	if not teacher_save_ready or _classroom_busy() or classroom_operation:
		%SettingsStatus.text = "请等本轮回答结束后再保存设置。"
		return
	ApiClient.request_json(HTTPClient.METHOD_PATCH, "/api/v2/saves/%s" % AppState.save_id.uri_encode(), {"user_name": user_name_input.text.strip_edges()}, func(success: bool, save) -> void:
		if success and save is Dictionary:
			current_save = save.duplicate(true)
			AppState.user_name = str(save.get("user_name", ""))
			%SettingsStatus.text = "课堂设置已保存。"
		else:
			%SettingsStatus.text = "保存失败，请稍后重试。"
	)
