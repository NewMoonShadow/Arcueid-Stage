extends Node

# Scene-local ordering for both voiced and text-only classroom lines.
signal segment_started(presentation: Dictionary, stream: AudioStream)
signal segment_finished(presentation: Dictionary)
signal turn_finished(request_id: String)

const HANDOFF_SECONDS := 0.20
const READY_TIMEOUT_SECONDS := 90.0

var request_id := ""
var entries: Dictionary = {}
var next_index := 0
var current: Dictionary = {}
var sealed := false
var finished := true
var text_done := false
var audio_done := false
var last_speaker := ""
var handoff_after := 0.0
var elapsed := 0.0

func begin(id: String) -> void:
	cancel()
	request_id = id
	finished = false

func cancel() -> void:
	request_id = ""
	entries.clear()
	current.clear()
	next_index = 0
	sealed = false
	finished = true
	last_speaker = ""
	handoff_after = 0.0

func is_busy() -> bool:
	return not finished

func accepts(presentation: Dictionary) -> bool:
	return not finished and str(presentation.get("request_id", "")) == request_id

func offer(presentation: Dictionary, needs_voice: bool) -> void:
	if not accepts(presentation):
		return
	var index := int(presentation.get("segment_index", -1))
	if index < next_index or index < 0 or (not current.is_empty() and index == next_index):
		return
	if not entries.has(index):
		entries[index] = {"presentation": presentation, "state": "waiting" if needs_voice else "text", "stream": null, "since": elapsed}
	_pump()

func downloading(presentation: Dictionary) -> void:
	offer(presentation, true)
	var index := int(presentation.get("segment_index", -1))
	if accepts(presentation) and entries.has(index) and entries[index]["state"] == "waiting":
		entries[index]["state"] = "downloading"

func resolve(presentation: Dictionary, stream: AudioStream = null) -> void:
	offer(presentation, true)
	var index := int(presentation.get("segment_index", -1))
	if not accepts(presentation) or not entries.has(index):
		return
	entries[index]["presentation"] = presentation
	entries[index]["stream"] = stream
	entries[index]["state"] = "audio" if stream != null else "text"
	_pump()

func seal() -> void:
	sealed = true
	# A download already underway must finish; absent TTS results degrade to text.
	for entry in entries.values():
		if entry["state"] == "waiting":
			entry["state"] = "text"
	_pump()

func mute() -> void:
	for entry in entries.values():
		entry["state"] = "text"
		entry["stream"] = null
	if not current.is_empty():
		audio_done = true
		_complete_current()
	_pump()

func text_finished(presentation: Dictionary) -> void:
	if _is_current(presentation):
		text_done = true
		_complete_current()

func audio_finished(presentation: Dictionary) -> void:
	if _is_current(presentation):
		audio_done = true
		_complete_current()

func _is_current(presentation: Dictionary) -> bool:
	return accepts(presentation) and not current.is_empty() and int(presentation.get("segment_index", -1)) == next_index

func _complete_current() -> void:
	if current.is_empty() or not text_done or not audio_done:
		return
	var presentation: Dictionary = current["presentation"]
	last_speaker = str(presentation.get("speaker_id", ""))
	handoff_after = elapsed + HANDOFF_SECONDS
	current = {}
	next_index += 1
	segment_finished.emit(presentation)
	_pump()

func _pump() -> void:
	if finished or not current.is_empty():
		return
	if not entries.has(next_index):
		if sealed and entries.is_empty():
			finished = true
			turn_finished.emit(request_id)
		return
	var entry: Dictionary = entries[next_index]
	if entry["state"] in ["waiting", "downloading"]:
		return
	var presentation: Dictionary = entry["presentation"]
	if not last_speaker.is_empty() and str(presentation.get("speaker_id", "")) != last_speaker and elapsed < handoff_after:
		return
	current = entry
	entries.erase(next_index)
	text_done = false
	audio_done = entry["stream"] == null
	segment_started.emit(presentation, entry["stream"])

func _process(delta: float) -> void:
	elapsed += delta
	for entry in entries.values():
		if entry["state"] in ["waiting", "downloading"] and elapsed - float(entry["since"]) >= READY_TIMEOUT_SECONDS:
			entry["state"] = "text"
	_pump()
