extends Node

# Independent directors keep each actor's pose, breathing and speaking state.
const ACTOR_DIRECTOR := preload("res://scripts/StageDirector.gd")
const ARCUEID_BOUNDS := Rect2(0.34, 0.15, 0.70, 1.50)
const CIEL_BOUNDS := Rect2(0.065, 0.15, 0.70, 1.50)

var actors: Dictionary = {}
var current_character_id := "arcueid"

func bind(arcueid_portrait: TextureRect, ciel_portrait: TextureRect) -> void:
	_bind_actor("arcueid", arcueid_portrait, ARCUEID_BOUNDS, 1.0)
	_bind_actor("ciel", ciel_portrait, CIEL_BOUNDS, -1.0)

func _bind_actor(character_id: String, target: TextureRect, bounds: Rect2, direction: float) -> void:
	var director := ACTOR_DIRECTOR.new()
	director.name = character_id.capitalize() + "Director"
	director.current_character_id = character_id
	add_child(director)
	director.bind(target)
	director.set_portrait_bounds(bounds)
	director.hide_until_first_speech(direction)
	actors[character_id] = director

func switch_character(character_id: String) -> void:
	# Selecting an interlocutor does not introduce them before they speak.
	if actors.has(character_id):
		current_character_id = character_id

func present(presentation: Dictionary, duration: float) -> void:
	var character_id := str(presentation.get("speaker_id", "arcueid"))
	if actors.has(character_id):
		actors[character_id].present(presentation, duration)

func stop_speaking(character_id: String = "") -> void:
	if character_id.is_empty():
		for actor in actors.values():
			actor.stop_speaking()
	elif actors.has(character_id):
		actors[character_id].stop_speaking(character_id)
