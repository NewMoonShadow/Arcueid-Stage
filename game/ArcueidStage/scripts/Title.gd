extends Control

@onready var moon: TextureRect = $Moon
@onready var halo: ColorRect = $MoonHalo
@onready var stars: Control = $Starfield
@onready var logo: Control = $Logo
@onready var menu: Control = $Menu

var elapsed := 0.0
var intro_finished := false
var menu_positions: Dictionary = {}
var changing_scene := false
const BUTTON_FEEDBACK := preload("res://scripts/ButtonFeedback.gd")
const UI_STYLE := preload("res://scripts/UiStyle.gd")
var menu_disabled: Dictionary = {}
var intro_tween: Tween
var intro_started := false
var exit_tween: Tween


func _ready() -> void:
    theme = UI_STYLE.THEME
    moon.pivot_offset = moon.size * 0.5
    halo.pivot_offset = halo.size * 0.5
    logo.modulate.a = 0.0
    logo.position.y -= 15.0
    moon.modulate.a = 0.0
    stars.modulate.a = 0.0
    for child in menu.get_children():
        if child is Button:
            var button := child as Button
            button.pivot_offset = button.size * 0.5
            menu_positions[button] = button.position
            button.modulate.a = 0.0
            button.position.y += 17.0
            UI_STYLE.text_button(button)
            BUTTON_FEEDBACK.install(button).enabled = false
            menu_disabled[button] = button.disabled
            button.disabled = true
    $Menu/TeacherButton.pressed.connect(_open_scene.bind("res://scenes/Teacher.tscn"))
    $Menu/ParkButton.pressed.connect(_open_scene.bind("res://scenes/Park.tscn"))
    $Menu/ParkSequenceButton.pressed.connect(_open_park.bind(false))
    $Menu/ParkContinueButton.pressed.connect(_open_park.bind(true))
    menu_disabled[$Menu/ParkContinueButton] = not FileAccess.file_exists("user://park_dialogue_progress.json")
    SceneTransition.transition_failed.connect(_on_transition_failed)
    if SceneTransition.busy:
        _play_intro()
    await $BGM.start_when_visible()
    if is_inside_tree() and not changing_scene and not intro_started:
        _play_intro()


func _open_scene(path: String) -> void:
    if changing_scene or SceneTransition.busy:
        return
    changing_scene = true
    var chapter := {"kind": "LESSON", "number": "1", "title": "教教我吧，爱尔奎特老师"} if path.ends_with("Teacher.tscn") else {"kind": "DAY", "number": "1", "title": "公园前的阻拦"}
    if path.ends_with("ParkSequence.tscn"):
        chapter = {"kind": "DAY", "number": "9", "title": "空之弓Ⅰ · 公园演出"}
    SceneTransition.change_to(path, chapter)

func _open_park(resume: bool) -> void:
    if changing_scene or SceneTransition.busy:
        return
    AppState.park_entry_mode = "continue" if resume else "start"
    _open_scene("res://scenes/ParkSequence.tscn")


func _on_transition_failed(path: String, error: int) -> void:
    changing_scene = false
    if path.ends_with("ParkSequence.tscn"):
        AppState.park_entry_mode = "start"
    push_error("无法打开场景 %s：%s" % [path, error_string(error)])


func _process(delta: float) -> void:
    elapsed += delta
    if changing_scene:
        return
    moon.scale = Vector2.ONE * (1.0 + sin(elapsed * 0.54) * 0.006)
    halo.scale = Vector2.ONE * (1.0 + sin(elapsed * 0.46) * 0.025)
    halo.modulate.a = 0.86 + sin(elapsed * 0.57) * 0.10


func _play_intro() -> void:
    intro_started = true
    intro_tween = create_tween().set_parallel(true)
    var tween := intro_tween
    tween.tween_property(stars, "modulate:a", 1.0, 1.5).set_trans(Tween.TRANS_SINE)
    tween.tween_property(moon, "modulate:a", 1.0, 1.25).set_delay(0.12).set_trans(Tween.TRANS_SINE)
    tween.tween_property(logo, "modulate:a", 1.0, 0.85).set_delay(0.58).set_trans(Tween.TRANS_SINE)
    tween.tween_property(logo, "position:y", logo.position.y + 15.0, 0.85).set_delay(0.58).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    var index := 0
    for child in menu.get_children():
        if child is Button:
            var button := child as Button
            var target: Vector2 = menu_positions[button]
            var delay := 1.08 + index * 0.11
            tween.tween_property(button, "modulate:a", 1.0, 0.48).set_delay(delay).set_trans(Tween.TRANS_SINE)
            tween.tween_property(button, "position:y", target.y, 0.48).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
            index += 1
    tween.finished.connect(func() -> void:
        intro_finished = true
        for button in menu_positions:
            button.disabled = bool(menu_disabled[button])
            button.get_node("ButtonFeedback").enabled = true
            button.get_node("ButtonFeedback")._hover(true)
    )


func _prepare_scene_exit() -> void:
    if intro_tween:
        intro_tween.kill()
    exit_tween = create_tween().set_parallel(true)
    var tween := exit_tween
    tween.tween_property(menu, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_SINE)
    tween.tween_property(menu, "position:y", menu.position.y + 10.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
    tween.tween_property(logo, "modulate:a", 0.0, 0.32).set_trans(Tween.TRANS_SINE)
    tween.tween_property(moon, "scale", Vector2.ONE * 1.055, 0.4).set_trans(Tween.TRANS_SINE)
    tween.tween_property(halo, "scale", Vector2.ONE * 1.07, 0.4).set_trans(Tween.TRANS_SINE)


func _cancel_scene_exit() -> void:
    if exit_tween:
        exit_tween.kill()
    menu.modulate.a = 1.0
    menu.position.y -= 10.0
    logo.modulate.a = 1.0
    changing_scene = false
