extends Node

signal playback_started(presentation: Dictionary, duration: float)
signal playback_finished(presentation: Dictionary)
signal playback_failed(presentation: Dictionary)
signal audio_prepared(presentation: Dictionary, stream: AudioStream)

var player: AudioStreamPlayer
var remote_queue: Array[Dictionary] = []
var playback_queue: Array[Dictionary] = []
var downloading := false
var current_presentation: Dictionary = {}
var controlled_playback := false
var generation := 0
var pcm_streams: Dictionary = {}
var current_pcm_key := ""
var generator_capacity := 0
var drain_wait := -1.0

func _stream_key(event: Dictionary) -> String:
    return "%s:%s" % [str(event.get("request_id", "")), int(event.get("segment_index", -1))]

func discard_stream(presentation: Dictionary) -> void:
    var key := _stream_key(presentation)
    if key != current_pcm_key:
        pcm_streams.erase(key)

func begin_stream(event: Dictionary, presentation: Dictionary) -> void:
    if not AppState.voice_enabled or str(event.get("format", "")) != "pcm_s16le":
        playback_failed.emit(presentation)
        return
    var rate := int(event.get("sample_rate", 0))
    var channels := int(event.get("channels", 0))
    if rate < 8000 or rate > 96000 or channels not in [1, 2]:
        playback_failed.emit(presentation)
        return
    var key := _stream_key(event)
    pcm_streams[key] = {"pcm": PackedByteArray(), "cursor": 0, "sequence": 0,
        "rate": rate, "channels": channels, "ended": false, "prepared": false,
        "presentation": presentation, "last_usec": Time.get_ticks_usec()}

func receive_stream_chunk(event: Dictionary) -> void:
    var key := _stream_key(event)
    if not pcm_streams.has(key):
        return
    var record: Dictionary = pcm_streams[key]
    if bool(record["ended"]):
        return
    var bytes := Marshalls.base64_to_raw(str(event.get("pcm", "")))
    var pcm: PackedByteArray = record["pcm"]
    if int(event.get("sequence", -1)) != int(record["sequence"]) or bytes.is_empty() or bytes.size() > 16384 or bytes.size() % (int(record["channels"]) * 2) != 0 or pcm.size() + bytes.size() > int(record["rate"]) * int(record["channels"]) * 2 * 120:
        end_stream({"request_id": event.get("request_id"), "segment_index": event.get("segment_index"), "failed": true})
        return
    pcm.append_array(bytes)
    record["pcm"] = pcm
    record["sequence"] = int(record["sequence"]) + 1
    record["last_usec"] = Time.get_ticks_usec()
    _prepare_pcm(key)

func end_stream(event: Dictionary) -> void:
    var key := _stream_key(event)
    if not pcm_streams.has(key):
        return
    var record: Dictionary = pcm_streams[key]
    record["ended"] = true
    record["failed"] = bool(event.get("failed", false))
    var pcm: PackedByteArray = record["pcm"]
    if not bool(record["failed"]) and (int(event.get("chunks", -1)) != int(record["sequence"]) or int(event.get("frames", -1)) != pcm.size() / (int(record["channels"]) * 2)):
        record["failed"] = true
    _prepare_pcm(key)

func _prepare_pcm(key: String) -> void:
    var record: Dictionary = pcm_streams[key]
    if bool(record["prepared"]):
        return
    var pcm: PackedByteArray = record["pcm"]
    if not bool(record["ended"]) and pcm.size() < int(record["rate"]) * int(record["channels"]) * 2 * 0.12:
        return
    if pcm.is_empty():
        pcm_streams.erase(key)
        playback_failed.emit(record["presentation"])
        return
    record["prepared"] = true
    var stream := AudioStreamGenerator.new()
    stream.mix_rate = float(record["rate"])
    stream.buffer_length = 0.3
    var presentation: Dictionary = record["presentation"]
    presentation["pcm_key"] = key
    presentation["streaming"] = true
    presentation["playback_ready_usec"] = Time.get_ticks_usec()
    if controlled_playback:
        audio_prepared.emit(presentation, stream)
    else:
        playback_queue.append({"stream": stream, "presentation": presentation})
        _play_next()

func _process(delta: float) -> void:
    # An interrupted socket must not leave a generator running forever.
    for key in pcm_streams.keys():
        var record: Dictionary = pcm_streams[key]
        if not bool(record["ended"]) and Time.get_ticks_usec() - int(record["last_usec"]) > 30000000:
            var presentation: Dictionary = record["presentation"]
            end_stream({"request_id": presentation.get("request_id"), "segment_index": presentation.get("segment_index"), "failed": true})
    if current_pcm_key.is_empty() or not pcm_streams.has(current_pcm_key) or not is_instance_valid(player) or not player.playing:
        return
    _fill_generator()
    var record: Dictionary = pcm_streams[current_pcm_key]
    var pcm: PackedByteArray = record["pcm"]
    var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
    if bool(record["ended"]) and int(record["cursor"]) >= pcm.size() and playback.get_frames_available() >= generator_capacity:
        if drain_wait < 0.0:
            drain_wait = maxf(AudioServer.get_output_latency(), 0.03)
        drain_wait -= delta
        if drain_wait <= 0.0:
            player.stop()
            pcm_streams.erase(current_pcm_key)
            current_pcm_key = ""
            _on_player_finished()
    else:
        drain_wait = -1.0

func _fill_generator() -> void:
    var record: Dictionary = pcm_streams[current_pcm_key]
    var pcm: PackedByteArray = record["pcm"]
    var cursor := int(record["cursor"])
    var channels := int(record["channels"])
    var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
    var count := mini(playback.get_frames_available(), (pcm.size() - cursor) / (channels * 2))
    if count <= 0:
        return
    var frames := PackedVector2Array()
    frames.resize(count)
    for index in range(count):
        var left := float(pcm.decode_s16(cursor)) / 32768.0
        var right := float(pcm.decode_s16(cursor + 2)) / 32768.0 if channels == 2 else left
        frames[index] = Vector2(left, right)
        cursor += channels * 2
    if playback.push_buffer(frames):
        record["cursor"] = cursor

func is_idle() -> bool:
    return pcm_streams.is_empty() and not downloading and remote_queue.is_empty() and playback_queue.is_empty() and (player == null or not player.playing)

func bind(target: AudioStreamPlayer) -> void:
    cancel_pending()
    controlled_playback = false
    player = target
    player.bus = &"Voice"
    if not player.finished.is_connected(_on_player_finished):
        player.finished.connect(_on_player_finished)

func set_voice_enabled(enabled: bool) -> void:
    AppState.voice_enabled = enabled
    AppState.save_preferences()
    if not enabled:
        cancel_pending()

func cancel_pending() -> void:
    generation += 1
    remote_queue.clear()
    playback_queue.clear()
    downloading = false
    pcm_streams.clear()
    current_pcm_key = ""
    drain_wait = -1.0
    if is_instance_valid(player):
        player.stop()
    current_presentation = {}

func play_prepared(stream: AudioStream, presentation: Dictionary) -> void:
    if not is_instance_valid(player) or stream == null:
        playback_failed.emit(presentation)
        return
    _play_item({"stream": stream, "presentation": presentation})

func reveal_timing(presentation: Dictionary) -> Dictionary:
    if not is_instance_valid(player) or not player.playing or _stream_key(presentation) != _stream_key(current_presentation):
        return {}
    if not current_pcm_key.is_empty() and pcm_streams.has(current_pcm_key):
        var record: Dictionary = pcm_streams[current_pcm_key]
        var bytes_per_frame := int(record["channels"]) * 2
        var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
        var buffered := generator_capacity - playback.get_frames_available()
        var consumed := maxf(float(record["cursor"]) / bytes_per_frame - buffered, 0.0)
        var elapsed := maxf(consumed / float(record["rate"]) - AudioServer.get_output_latency(), 0.0)
        var pcm: PackedByteArray = record["pcm"]
        var duration := float(pcm.size()) / bytes_per_frame / float(record["rate"]) if bool(record["ended"]) else 0.0
        return {"elapsed": elapsed, "duration": duration}
    return {"elapsed": maxf(player.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency(), 0.0), "duration": player.stream.get_length()}

func enqueue_remote(audio_path: String, presentation: Dictionary = {}) -> void:
    if audio_path.is_empty():
        playback_failed.emit(presentation)
        return
    remote_queue.append({"audio_path": audio_path, "presentation": presentation, "enqueued_usec": Time.get_ticks_usec()})
    _download_next()

func play_remote(audio_path: String) -> void:
    enqueue_remote(audio_path)

func _download_next() -> void:
    if downloading or remote_queue.is_empty():
        return
    downloading = true
    var request: Dictionary = remote_queue.pop_front()
    var audio_path := str(request.get("audio_path", ""))
    var presentation: Dictionary = request.get("presentation", {})
    var download_started_usec := Time.get_ticks_usec()
    var download_generation := generation
    ApiClient.fetch_audio(audio_path, func(success: bool, bytes: PackedByteArray) -> void:
        if download_generation != generation:
            return
        downloading = false
        var queued := false
        var download_finished_usec := Time.get_ticks_usec()
        presentation["audio_download_ms"] = snappedf((download_finished_usec - download_started_usec) / 1000.0, 0.1)
        presentation["playback_ready_usec"] = download_finished_usec
        LatencyLog.record("audio.download_completed", {
            "request_id": str(presentation.get("request_id", "")),
            "segment_index": int(presentation.get("segment_index", -1)),
            "success": success and not bytes.is_empty(),
            "audio_download_ms": presentation["audio_download_ms"],
            "remote_queue_wait_ms": snappedf((download_started_usec - int(request.get("enqueued_usec", download_started_usec))) / 1000.0, 0.1),
            "audio_bytes": bytes.size(),
        })
        if AppState.voice_enabled and success and not bytes.is_empty():
            var stream: AudioStreamWAV = AudioStreamWAV.load_from_buffer(bytes)
            if stream:
                queued = true
                if controlled_playback:
                    audio_prepared.emit(presentation, stream)
                else:
                    playback_queue.append({"stream": stream, "presentation": presentation})
                    _play_next()
        if not queued:
            playback_failed.emit(presentation)
        _download_next()
    )

func _play_next() -> void:
    if player == null or player.playing or playback_queue.is_empty():
        return
    var item: Dictionary = playback_queue.pop_front()
    _play_item(item)

func _play_item(item: Dictionary) -> void:
    player.stream = item.get("stream")
    current_presentation = item.get("presentation", {})
    var playback_started_usec := Time.get_ticks_usec()
    var playback_ready_usec := int(current_presentation.get("playback_ready_usec", playback_started_usec))
    var tts_ready_usec := int(current_presentation.get("tts_ready_usec", playback_started_usec))
    current_presentation["playback_queue_wait_ms"] = snappedf((playback_started_usec - playback_ready_usec) / 1000.0, 0.1)
    current_presentation["tts_ready_to_playback_ms"] = snappedf((playback_started_usec - tts_ready_usec) / 1000.0, 0.1)
    player.play()
    current_pcm_key = str(current_presentation.get("pcm_key", ""))
    if not current_pcm_key.is_empty():
        generator_capacity = (player.get_stream_playback() as AudioStreamGeneratorPlayback).get_frames_available()
        drain_wait = -1.0
        _fill_generator()
    playback_started.emit(current_presentation, maxf(player.stream.get_length(), 0.0))

func _on_player_finished() -> void:
    var completed := current_presentation
    current_presentation = {}
    playback_finished.emit(completed)
    if not controlled_playback:
        _play_next()
