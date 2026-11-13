extends Node

signal transition_failed(path: String, error: int)

const DISSOLVE := preload("res://assets/shaders/scene_dissolve.gdshader")
const CHAPTER_PAGE := preload("res://scenes/ChapterTransition.tscn")
var chapter_page: Control
var busy := false
var shade: ColorRect
var outgoing: TextureRect
var dissolve_material: ShaderMaterial

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    var layer := CanvasLayer.new()
    layer.layer = 100
    add_child(layer)
    # Transparent input blocker; the outgoing image carries the transition.
    shade = ColorRect.new()
    layer.add_child(shade)
    shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    shade.color = Color(0, 0, 0, 0)
    shade.mouse_filter = Control.MOUSE_FILTER_STOP
    shade.visible = false
    outgoing = TextureRect.new()
    layer.add_child(outgoing)
    outgoing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    outgoing.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    outgoing.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dissolve_material = ShaderMaterial.new()
    dissolve_material.shader = DISSOLVE
    outgoing.material = dissolve_material
    outgoing.visible = false
    chapter_page = CHAPTER_PAGE.instantiate()
    layer.add_child(chapter_page)
    chapter_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    chapter_page.visible = false

func change_to(path: String, chapter: Dictionary = {}) -> Error:
    if busy:
        return ERR_BUSY
    if not ResourceLoader.exists(path, "PackedScene"):
        transition_failed.emit(path, ERR_FILE_NOT_FOUND)
        return ERR_FILE_NOT_FOUND
    var error := ResourceLoader.load_threaded_request(path, "PackedScene")
    if error != OK:
        transition_failed.emit(path, error)
        return error
    busy = true
    shade.visible = true
    # Leave enough time for the button's confirmation pulse to be visible.
    await get_tree().create_timer(0.12).timeout
    var source := get_tree().current_scene
    if not chapter.is_empty():
        return await _change_with_chapter(path, source, chapter)
    while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
        await get_tree().process_frame
    if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED:
        _clear()
        transition_failed.emit(path, ERR_CANT_OPEN)
        return ERR_CANT_OPEN
    if source and source.has_method("_prepare_scene_exit"):
        source.call("_prepare_scene_exit")
    await get_tree().create_timer(0.24).timeout
    var has_snapshot := DisplayServer.get_name() != "headless"
    if has_snapshot:
        await RenderingServer.frame_post_draw
        var viewport := get_viewport()
        var frame := viewport.get_texture().get_image()
        has_snapshot = frame != null and not frame.is_empty()
        if has_snapshot:
            outgoing.texture = ImageTexture.create_from_image(frame)
            dissolve_material.set_shader_parameter("aspect", float(frame.get_width()) / maxf(frame.get_height(), 1.0))
            _set_progress(0.0)
            outgoing.visible = true
    var scene := ResourceLoader.load_threaded_get(path) as PackedScene
    error = get_tree().change_scene_to_packed(scene)
    if error != OK:
        if is_instance_valid(source) and source.has_method("_cancel_scene_exit"):
            source.call("_cancel_scene_exit")
        _clear()
        transition_failed.emit(path, error)
        return error
    await get_tree().scene_changed
    await get_tree().process_frame
    var destination := get_tree().current_scene
    if destination and destination.has_method("_prepare_scene_enter"):
        destination.call("_prepare_scene_enter")
    if has_snapshot:
        # The previous image covers the new scene until it has rendered a frame.
        await RenderingServer.frame_post_draw
        var tween := create_tween()
        tween.tween_method(_set_progress, 0.0, 1.0, 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
        await tween.finished
    _clear()
    return OK

func _change_with_chapter(path: String, source: Node, chapter: Dictionary) -> Error:
    var source_bgm := source.get_node_or_null("BGM") if source else null
    if source_bgm and source_bgm.has_method("fade_out"):
        source_bgm.fade_out(0.24)
    if source and source.has_method("_prepare_scene_exit"):
        source.call("_prepare_scene_exit")
    await get_tree().create_timer(0.24).timeout
    chapter_page.configure(chapter)
    chapter_page.start_music()
    var reveal := create_tween()
    reveal.tween_property(chapter_page, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    await reveal.finished
    # The next scene loads in the background while the chapter page is visible.
    while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
        await get_tree().process_frame
    if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED:
        if is_instance_valid(source_bgm) and source_bgm.has_method("resume_after_transition_failure"):
            source_bgm.resume_after_transition_failure()
        if is_instance_valid(source) and source.has_method("_cancel_scene_exit"):
            source.call("_cancel_scene_exit")
        _clear()
        transition_failed.emit(path, ERR_CANT_OPEN)
        return ERR_CANT_OPEN
    var remaining: float = chapter_page.remaining_before_fade(0.85)
    if remaining > 0.0:
        await get_tree().create_timer(remaining).timeout
    var scene := ResourceLoader.load_threaded_get(path) as PackedScene
    var error := get_tree().change_scene_to_packed(scene)
    if error != OK:
        if is_instance_valid(source_bgm) and source_bgm.has_method("resume_after_transition_failure"):
            source_bgm.resume_after_transition_failure()
        if is_instance_valid(source) and source.has_method("_cancel_scene_exit"):
            source.call("_cancel_scene_exit")
        _clear()
        transition_failed.emit(path, error)
        return error
    await get_tree().scene_changed
    await get_tree().process_frame
    var destination := get_tree().current_scene
    if destination is CanvasItem:
        destination.modulate.a = 0.0
    if destination and destination.has_method("_prepare_scene_enter"):
        destination.call("_prepare_scene_enter")
    var destination_bgm := destination.get_node_or_null("BGM") if destination else null
    if destination_bgm and destination_bgm.has_method("start_for_transition"):
        destination_bgm.start_for_transition()
    var crossfade := create_tween().set_parallel(true)
    crossfade.tween_property(chapter_page, "modulate:a", 0.0, 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    if destination is CanvasItem:
        crossfade.tween_property(destination, "modulate:a", 1.0, 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    await crossfade.finished
    _clear()
    return OK

func _set_progress(value: float) -> void:
    dissolve_material.set_shader_parameter("progress", value)

func _clear() -> void:
    chapter_page.clear()
    outgoing.visible = false
    outgoing.texture = null
    shade.visible = false
    busy = false
