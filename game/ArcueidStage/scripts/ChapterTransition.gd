extends Control

@onready var composition: Control = $Composition
@onready var moon: TextureRect = $Composition/Moon
@onready var music: AudioStreamPlayer = $ChapterMusic
var music_started_usec := 0
@export var display_seconds := 4.0
@export var local_music_path := "res://assets/music/chapter-transition.mp3"
var motion_tween: Tween
var lettering_tween: Tween
const TEXT_GLASS := preload("res://assets/shaders/ui_text_glass.gdshader")

func _ready() -> void:
	# The source checkpoint excludes local copyrighted audio. Missing optional
	# music must not prevent SceneTransition's autoload from parsing this scene.
	if ResourceLoader.exists(local_music_path):
		music.stream = load(local_music_path)
	resized.connect(_layout)
	_layout()
	for label in [$Composition/Kind, $Composition/Number]:
		var glass := ShaderMaterial.new()
		glass.shader = TEXT_GLASS
		glass.set_shader_parameter("hover", 1.0)
		glass.set_shader_parameter("grain", 0.45)
		glass.set_shader_parameter("control_size", label.size)
		glass.set_shader_parameter("font_height", label.get_theme_font_size("font_size") * 1.15)
		label.material = glass
		label.add_theme_color_override("font_color", Color.WHITE)

func _layout() -> void:
	var ratio := size.y / 1080.0
	composition.scale = Vector2.ONE * ratio
	composition.position = Vector2((size.x - 1920.0 * ratio) * 0.5, 0.0)

func configure(chapter: Dictionary) -> void:
	var kind := str(chapter.get("kind", "DAY"))
	var spaced_kind := ""
	for letter in kind:
		if not spaced_kind.is_empty():
			spaced_kind += " "
		spaced_kind += letter
	$Composition/Kind.text = spaced_kind
	$Composition/Kind.add_theme_font_size_override("font_size", 21 if kind.length() > 3 else 28)
	$Composition/Kind.material.set_shader_parameter("font_height", $Composition/Kind.get_theme_font_size("font_size") * 1.15)
	$Composition/Number.text = str(chapter.get("number", "1"))
	$Composition/NumberGlow.text = $Composition/Number.text
	$Composition/ChapterTitle.text = str(chapter.get("title", ""))
	$Composition/ChapterTitle.add_theme_font_size_override("font_size", 54 if $Composition/ChapterTitle.text.length() > 10 else 72)
	moon.position.x = 1280.0
	modulate.a = 0.0
	visible = true
	if motion_tween and motion_tween.is_valid():
		motion_tween.kill()
	motion_tween = create_tween()
	motion_tween.tween_property(moon, "position:x", 1160.0, soundtrack_duration()).set_trans(Tween.TRANS_LINEAR)
	if lettering_tween and lettering_tween.is_valid():
		lettering_tween.kill()
	$Composition/ChapterTitle.modulate.a = 0.0
	$Composition/SlashGlow.modulate.a = 1.0
	lettering_tween = create_tween().set_parallel(true)
	lettering_tween.tween_method(_sweep_slash, 0.0, 1.0, 0.6)
	lettering_tween.tween_property($Composition/ChapterTitle, "modulate:a", 1.0, 0.75).set_delay(0.25)
	lettering_tween.tween_property($Composition/SlashGlow, "modulate:a", 0.15, 0.75)

func _sweep_slash(progress: float) -> void:
	$Composition/SlashGlow.points = PackedVector2Array([Vector2(40, 440), Vector2(40, 440).lerp(Vector2(276, 700), progress)])

func soundtrack_duration() -> float:
	return maxf(display_seconds, 1.5)

func start_music() -> void:
	music_started_usec = Time.get_ticks_usec()
	if music.stream != null:
		music.play()

func remaining_before_fade(fade_seconds: float) -> float:
	var elapsed := (Time.get_ticks_usec() - music_started_usec) / 1000000.0
	return maxf(soundtrack_duration() - fade_seconds - elapsed, 0.0)

func clear() -> void:
	music.stop()
	music_started_usec = 0
	if motion_tween and motion_tween.is_valid():
		motion_tween.kill()
	if lettering_tween and lettering_tween.is_valid():
		lettering_tween.kill()
	visible = false
	modulate.a = 0.0
