extends Node

signal socket_event(event: Dictionary)
signal connection_changed(online: bool)

var socket := WebSocketPeer.new()
var connecting := false
var reconnect_after_ms := 0
var last_online := false
var chat_started_usec: Dictionary = {}

func _process(_delta: float) -> void:
    if socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING or socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
        socket.poll()
    if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
        AppState.core_online = true
        connecting = false
        _publish_connection(true)
        while socket.get_available_packet_count() > 0:
            var packet := socket.get_packet().get_string_from_utf8()
            var parsed = JSON.parse_string(packet)
            if parsed is Dictionary:
                if str(parsed.get("type", "")) == "turn.completed":
                    get_node("/root/SaveIndicator").confirmed_turn(str(parsed.get("request_id", "")))
                socket_event.emit(parsed)
    elif connecting and socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
        connecting = false
        AppState.core_online = false
        reconnect_after_ms = Time.get_ticks_msec() + 2000
        _publish_connection(false)
    elif socket.get_ready_state() == WebSocketPeer.STATE_CLOSED and reconnect_after_ms > 0 and Time.get_ticks_msec() >= reconnect_after_ms:
        connect_chat()

func _publish_connection(online: bool) -> void:
    if last_online == online:
        return
    last_online = online
    connection_changed.emit(online)

func connect_chat() -> void:
    if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
        return
    socket = WebSocketPeer.new()
    connecting = true
    var result := socket.connect_to_url(AppState.chat_socket_url())
    if result != OK:
        connecting = false
        AppState.core_online = false
        reconnect_after_ms = Time.get_ticks_msec() + 2000
        _publish_connection(false)

func send_chat(message: String, speaker_id: String = "arcueid") -> String:
    if socket.get_ready_state() != WebSocketPeer.STATE_OPEN or AppState.save_id.is_empty():
        return ""
    var request_id := str(Time.get_ticks_usec())
    var started_usec := Time.get_ticks_usec()
    var payload := {"type": "chat.send", "request_id": request_id, "save_id": AppState.save_id, "message": message, "speaker_id": speaker_id, "audio_streaming": AppState.voice_enabled}
    if socket.send_text(JSON.stringify(payload)) != OK:
        return ""
    chat_started_usec[request_id] = started_usec
    return request_id

func disconnect_chat() -> void:
    connecting = false
    reconnect_after_ms = 0
    socket.close()
    socket = WebSocketPeer.new()
    AppState.core_online = false
    _publish_connection(false)

func get_chat_started_usec(request_id: String) -> int:
    return int(chat_started_usec.get(request_id, 0))

func request_json(method: int, path: String, body: Dictionary, completed: Callable) -> void:
    var save_indicator := get_node("/root/SaveIndicator")
    var saving_token: int = save_indicator.begin() if _is_save_write(method, path) else 0
    var request := HTTPRequest.new()
    request.timeout = 25.0 if path == "/api/v2/settings/model/test" else 10.0
    add_child(request)
    request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray) -> void:
        var parsed = JSON.parse_string(bytes.get_string_from_utf8())
        var success := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
        if saving_token > 0:
            save_indicator.finish(saving_token, success)
        if not success:
            if not (parsed is Dictionary):
                parsed = {}
            parsed["_http_status"] = code
            parsed["_http_result"] = result
        if completed.is_valid():
            completed.call(success, parsed)
        request.queue_free()
    )
    var headers := PackedStringArray(["Content-Type: application/json"])
    var error := request.request(AppState.core_url + path, headers, method, JSON.stringify(body))
    if error != OK:
        if saving_token > 0:
            save_indicator.finish(saving_token, false)
        if completed.is_valid():
            completed.call(false, {})
        request.queue_free()

func _is_save_write(method: int, path: String) -> bool:
    if method not in [HTTPClient.METHOD_POST, HTTPClient.METHOD_PUT, HTTPClient.METHOD_PATCH, HTTPClient.METHOD_DELETE]:
        return false
    return path.begins_with("/api/v2/saves") or path.begins_with("/api/v2/memories") or path == "/api/v2/teacher/progress" or path.begins_with("/api/v2/teacher/checkpoints") or path == "/api/v2/teacher/new"

func fetch_audio(path: String, completed: Callable) -> void:
    var request := HTTPRequest.new()
    request.timeout = 30.0
    add_child(request)
    request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray) -> void:
        completed.call(result == HTTPRequest.RESULT_SUCCESS and code == 200, bytes)
        request.queue_free()
    )
    var error := request.request(AppState.core_url + path)
    if error != OK:
        completed.call(false, PackedByteArray())
        request.queue_free()
