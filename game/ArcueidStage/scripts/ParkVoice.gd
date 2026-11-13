extends Node
## Fixed cue voice uses Core's existing model profiles and AudioController WAV queue.
signal state_changed(text: String)
signal speech_started(presentation: Dictionary, duration: float)
signal speech_finished(presentation: Dictionary)

var queue: Array[Dictionary] = []
var active_request: HTTPRequest
var generation := 0
var cue_id := ""
var expressions: Dictionary = {}
var active_presentation: Dictionary = {}
var debounce: Timer
var socket: WebSocketPeer
var socket_body: Dictionary = {}
var socket_sent := false
var socket_finished := false
var socket_announced := false
var socket_deadline := 0

func _ready() -> void:
	debounce = Timer.new()
	debounce.one_shot = true
	debounce.wait_time = 0.05
	add_child(debounce)
	debounce.timeout.connect(_request_next)
	AudioController.playback_started.connect(_on_started)
	AudioController.playback_finished.connect(_on_finished)
	AudioController.playback_failed.connect(_on_failed)

func speak_cue(cue: Dictionary) -> void:
	cancel()
	cue_id = cue.get("id", "")
	expressions = cue.get("expressions", {})
	if not AppState.voice_enabled:
		state_changed.emit("语音关闭")
		return
	for entry in cue.get("dialogue", []):
		if entry.get("speaker", "") in ["arcueid", "ciel"]:
			queue.append(entry)
	if not queue.is_empty():
		state_changed.emit("准备语音…")
		debounce.start()
	else:
		state_changed.emit("")

func cancel() -> void:
	generation += 1
	queue.clear()
	active_presentation = {}
	if is_instance_valid(debounce):
		debounce.stop()
	if is_instance_valid(active_request):
		active_request.cancel_request()
		active_request.queue_free()
	active_request = null
	if socket:
		socket.close()
	socket = null
	AudioController.cancel_pending()

func is_busy() -> bool:
	return not queue.is_empty() or not active_presentation.is_empty() or is_instance_valid(active_request)

func speak_reply(reply: Dictionary) -> void:
	speak_cue({"id": reply.get("cue_id", ""),
		"expressions": {reply["speaker_id"]: reply.get("expression", "neutral")},
		"dialogue": [{"speaker": reply["speaker_id"], "text": reply["reply"], "mood": reply.get("mood", "neutral"), "tts_text": reply.get("tts_text", ""), "bypass_cache": reply.get("bypass_cache", false)} ]})

func speak_group(lines: Array, current_cue_id: String) -> void:
	cancel()
	if not AppState.voice_enabled:
		return
	var token := generation
	active_presentation = {"request_id": "park-group-%s-%s" % [token, Time.get_ticks_usec()], "segment_index": 0,
		"cue_id": current_cue_id, "speaker_id": "both", "reply": "同时打断"}
	var request := HTTPRequest.new()
	request.timeout = 60
	add_child(request)
	active_request = request
	var voice_lines: Array = []
	for line in lines:
		voice_lines.append({"speaker_id": line["speaker"], "text": line["text"], "tts_text": line.get("tts_text", "")})
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		request.queue_free()
		if token != generation:
			return
		active_request = null
		var payload = JSON.parse_string(bytes.get_string_from_utf8())
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and payload is Dictionary and payload.get("voice_available", false):
			AudioController.enqueue_remote(payload["audio_path"], active_presentation)
		else:
			_on_failed(active_presentation.duplicate())
	)
	state_changed.emit("准备双人同时打断…")
	if request.request(AppState.core_url + "/api/v2/park/speech/group", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST,
		JSON.stringify({"request_id": active_presentation["request_id"], "lines": voice_lines})) != OK:
		request.queue_free()
		active_request = null
		_on_failed(active_presentation.duplicate())

func _request_next() -> void:
	if queue.is_empty() or not AppState.voice_enabled:
		state_changed.emit("")
		return
	var entry: Dictionary = queue.pop_front()
	var actor_id: String = entry["speaker"]
	var token := generation
	active_presentation = {"request_id": "park-%s-%s" % [token, Time.get_ticks_usec()],
		"cue_id": cue_id, "segment_index": 0, "speaker_id": actor_id,
		"mood": entry.get("mood", "neutral"),
		"expression": entry.get("expression", expressions.get(actor_id, "neutral")), "reply": entry["text"]}
	var presentation := active_presentation.duplicate()
	socket_body = {"speaker_id": actor_id, "text": entry["text"], "tts_text": entry.get("tts_text", ""), "request_id": presentation["request_id"], "bypass_cache": entry.get("bypass_cache", false)}
	socket = WebSocketPeer.new()
	socket_sent = false
	socket_finished = false
	socket_announced = false
	socket_deadline = Time.get_ticks_msec() + 150000
	var url: String = AppState.core_url.replace("http://", "ws://").replace("https://", "wss://") + "/api/v2/park/voice"
	var connection_error := socket.connect_to_url(url)
	if connection_error != OK:
		socket = null
		_request_wav(presentation, token)

func _process(_delta: float) -> void:
	if not socket:
		return
	socket.poll()
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not socket_sent:
			socket.send_text(JSON.stringify(socket_body))
			socket_sent = true
		while socket and socket.get_available_packet_count() > 0:
			var event = JSON.parse_string(socket.get_packet().get_string_from_utf8())
			if not event is Dictionary or event.get("request_id", "") != active_presentation.get("request_id", ""):
				continue
			match event.get("type", ""):
				"tts.stream.started":
					socket_announced = true
					AudioController.begin_stream(event, active_presentation)
					state_changed.emit("收到流式语音…")
				"tts.stream.chunk":
					AudioController.receive_stream_chunk(event)
				"tts.stream.completed":
					socket_finished = true
					AudioController.end_stream(event)
				"tts.ready":
					socket_finished = true
					AudioController.enqueue_remote(event["audio_path"], active_presentation)
				"tts.failed":
					socket_finished = true
					_on_failed(active_presentation.duplicate())
	if socket and (socket.get_ready_state() == WebSocketPeer.STATE_CLOSED or Time.get_ticks_msec() > socket_deadline):
		socket.close()
		socket = null
		if not socket_finished and not active_presentation.is_empty():
			if socket_announced:
				AudioController.end_stream({"request_id": active_presentation["request_id"], "segment_index": 0, "failed": true})
			else:
				_request_wav(active_presentation.duplicate(), generation)

func _request_wav(presentation: Dictionary, token: int) -> void:
	# Older Core or a failed handshake retains the existing text/WAV fallback.
	var request := HTTPRequest.new()
	request.timeout = 150.0
	add_child(request)
	active_request = request
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray) -> void:
		request.queue_free()
		if token != generation:
			return
		active_request = null
		if result != HTTPRequest.RESULT_SUCCESS or code != 200 or bytes.is_empty():
			_on_failed(presentation)
			return
		var payload = JSON.parse_string(bytes.get_string_from_utf8())
		if not payload is Dictionary or not payload.get("voice_available", false):
			_on_failed(presentation)
			return
		state_changed.emit("加载语音…")
		AudioController.enqueue_remote(payload["audio_path"], presentation)
	)
	var error := request.request(AppState.core_url + "/api/v2/park/speech",
		PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify(socket_body))
	if error != OK:
		request.queue_free()
		active_request = null
		_on_failed(presentation)

func _owns(presentation: Dictionary) -> bool:
	return not active_presentation.is_empty() and presentation.get("request_id", "") == active_presentation.get("request_id", "")

func _on_started(presentation: Dictionary, duration: float) -> void:
	if _owns(presentation):
		state_changed.emit("日语配音中")
		speech_started.emit(presentation, duration)

func _on_finished(presentation: Dictionary) -> void:
	if _owns(presentation):
		speech_finished.emit(presentation)
		active_presentation = {}
		_request_next()

func _on_failed(presentation: Dictionary) -> void:
	if _owns(presentation):
		speech_finished.emit(presentation)
		active_presentation = {}
		# A failed service should not produce one failed request for every queued line.
		queue.clear()
		state_changed.emit("语音暂不可用，文字可继续")

func _exit_tree() -> void:
	cancel()
