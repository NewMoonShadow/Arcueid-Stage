extends Node

const LOG_PATH := "user://latency_client.jsonl"

var turn_started_usec: Dictionary = {}

func begin_turn(request_id: String, started_usec: int) -> void:
    turn_started_usec[request_id] = started_usec
    record("turn.sent", {"request_id": request_id, "client_elapsed_ms": 0.0})

func elapsed_ms(request_id: String) -> float:
    var started := int(turn_started_usec.get(request_id, 0))
    if started <= 0:
        return -1.0
    return snappedf((Time.get_ticks_usec() - started) / 1000.0, 0.1)

func record(event_name: String, fields: Dictionary = {}) -> void:
    var payload := fields.duplicate(true)
    payload["timestamp"] = Time.get_datetime_string_from_system(true, true)
    payload["component"] = "godot_client"
    payload["event"] = event_name
    payload["client_monotonic_ms"] = snappedf(Time.get_ticks_usec() / 1000.0, 0.1)
    var line := JSON.stringify(payload)
    print("ARCUEID_LATENCY ", line)
    var mode := FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE
    var file := FileAccess.open(LOG_PATH, mode)
    if file != null:
        file.seek_end()
        file.store_line(line)

func log_path() -> String:
    return ProjectSettings.globalize_path(LOG_PATH)
