extends AudioStreamPlayer

@export var base_volume_db := -12.0
@export var duck_for_voice := false
@export var ducking_db := 6.0
@export var start_automatically := true
@export var fade_in_seconds := 1.5

var start_requested := false
var fade_elapsed := 0.0
var fading_out := false
var exit_fade: Tween

func _ready() -> void:
	bus = &"Music"
	if stream is AudioStreamMP3:
		stream = stream.duplicate()
		stream.loop = true
	volume_db = -60.0
	if start_automatically:
		start_when_visible()

func start_when_visible() -> void:
	if start_requested:
		return
	start_requested = true
	# _ready runs before the window's first rendered frame. Do not spend the
	# beginning of the track on shader setup or behind the transition overlay.
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	while SceneTransition.busy:
		await get_tree().process_frame
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if playing or fading_out:
		return
	_begin_playback()

func _begin_playback() -> void:
	volume_db = -60.0
	fade_elapsed = 0.0
	play(0.0)

func start_for_transition() -> void:
	# Begin beneath the final chapter fade, instead of waiting until it vanishes.
	start_requested = true
	if not playing:
		_begin_playback()

func fade_out(seconds: float = 0.24) -> void:
	fading_out = true
	if exit_fade and exit_fade.is_valid():
		exit_fade.kill()
	exit_fade = create_tween()
	exit_fade.tween_property(self, "volume_db", -60.0, seconds)
	exit_fade.tween_callback(stop)

func resume_after_transition_failure() -> void:
	if exit_fade and exit_fade.is_valid():
		exit_fade.kill()
	fading_out = false
	_begin_playback()

func target_volume_db() -> float:
	var voice_playing := duck_for_voice and is_instance_valid(AudioController.player) and AudioController.player.playing
	return base_volume_db - ducking_db if voice_playing else base_volume_db

func _process(delta: float) -> void:
	if not playing or fading_out:
		return
	var target := target_volume_db()
	if fade_elapsed < fade_in_seconds:
		fade_elapsed = minf(fade_elapsed + delta, fade_in_seconds)
		var gain := maxf(fade_elapsed / fade_in_seconds, 0.0001)
		volume_db = linear_to_db(db_to_linear(target) * gain)
		return
	# Smoothly lower the music during speech, then bring it back after playback.
	var speed := 45.0 if target < volume_db else 24.0
	volume_db = move_toward(volume_db, target, speed * delta)
