extends Node

var core_url := "http://127.0.0.1:8765"
var voice_enabled := true

var save_id := ""
var save_name := "新的记录"
var identity_mode := "self"
var user_name := ""
var core_online := false
var core_process_id := -1
var classroom_recovery: Dictionary = {}
var park_entry_mode := "start"

func _ready() -> void:
    var preferences := ConfigFile.new()
    if preferences.load("user://preferences.cfg") == OK:
        core_url = str(preferences.get_value("connection", "core_url", core_url)).trim_suffix("/")
        voice_enabled = bool(preferences.get_value("audio", "voice_enabled", voice_enabled))
        var recovery = preferences.get_value("classroom", "unsaved_ui", {})
        if recovery is Dictionary:
            classroom_recovery = recovery
    if OS.has_feature("editor"):
        return
    var executable := ProjectSettings.globalize_path("res://bin/arcueid-core.exe")
    if not FileAccess.file_exists(executable):
        return
    var data_root := OS.get_environment("LOCALAPPDATA").path_join("ArcueidStage")
    core_process_id = OS.create_process(executable, ["--parent-pid", str(OS.get_process_id()), "--data-dir", data_root])

func chat_socket_url() -> String:
    return core_url.replace("https://", "wss://").replace("http://", "ws://") + "/api/v2/chat"

func save_preferences() -> void:
    var preferences := ConfigFile.new()
    preferences.set_value("connection", "core_url", core_url)
    preferences.set_value("audio", "voice_enabled", voice_enabled)
    preferences.set_value("classroom", "unsaved_ui", classroom_recovery)
    preferences.save("user://preferences.cfg")

func _exit_tree() -> void:
    if core_process_id > 0 and OS.is_process_running(core_process_id):
        OS.kill(core_process_id)
