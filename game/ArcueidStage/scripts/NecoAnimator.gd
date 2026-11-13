extends Node

const MANIFEST_PATH := "res://assets/characters/neco_arc/performance_manifest.json"
const EXPRESSION_NAMES := ["neutral", "smile", "curious", "serious", "annoyed", "surprised", "excited", "sad", "smug", "wink", "laughing", "thinking", "confused", "stunned", "cheer", "energetic", "explaining", "pouting", "scheming"]
const ALIASES := {"cheeky": "smug", "happy": "smile", "laugh": "laughing", "pout": "pouting", "shock": "stunned", "dance": "energetic", "joy": "cheer"}
const POSE_SCALE := 2048.0 / 1637.0

var portrait: TextureRect
var previous_layer: TextureRect
var manifest: Dictionary = {}
var textures: Dictionary = {}
var variant_bags: Dictionary = {}
var expression := "neutral"
var current_variant := ""
var held_variant := ""
var last_request_id := ""
var rest_top := 0.0
var rest_bottom := 0.0
var elapsed := 0.0
var speaking_until := 0.0
var emphasis := 0.0
var speaking_weight := 0.0
var reaction_elapsed := 1.0
var reaction_height := 0.0
var performance_state := "listening"
var fade_elapsed := 1.0
var animation_frames: Array = []
var animation_elapsed := 0.0
var animation_fps := 14.0
var animation_frame := -1
var animation_deadlines: Dictionary = {}
var motion_weight := 0.0

func bind(target: TextureRect) -> void:
    portrait = target
    rest_top = portrait.offset_top
    rest_bottom = portrait.offset_bottom
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    manifest = parsed if parsed is Dictionary else {}
    previous_layer = TextureRect.new()
    previous_layer.name = "NecoPoseTransition"
    previous_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    previous_layer.texture_filter = portrait.texture_filter
    previous_layer.expand_mode = portrait.expand_mode
    previous_layer.stretch_mode = portrait.stretch_mode
    previous_layer.modulate.a = 0.0
    portrait.add_child(previous_layer)
    previous_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    portrait.resized.connect(_update_pivot)
    _update_pivot()
    set_expression("neutral")

func _update_pivot() -> void:
    portrait.pivot_offset = Vector2(portrait.size.x * 0.5, portrait.size.y)

static func resolve_expression(presentation: Dictionary) -> String:
    var requested := str(presentation.get("expression", "neutral")).to_lower()
    requested = str(ALIASES.get(requested, requested))
    var text := str(presentation.get("reply", ""))
    var mood := str(presentation.get("mood", "neutral"))
    # Refine broad happy metadata when the line contains a concrete comic beat.
    if requested in ["neutral", "smile", "smug"] and mood not in ["serious", "sad", "annoyed"]:
        for pair in [["scheming", ["小算盘", "计划通", "我有个主意", "本喵有个计划", "偷偷盖章", "偷盖"]],
            ["laughing", ["哈哈", "喵哈", "笑死", "好好笑"]],
            ["cheer", ["万岁", "好耶", "大获全胜", "成功啦"]],
            ["energetic", ["跳起来", "跳个舞", "冲呀", "出动"]],
            ["wink", ["眨眨眼", "眨眼", "你懂的", "开玩笑"]],
            ["pouting", ["不理你", "哼哼", "抗议"]],
            ["stunned", ["目瞪口呆", "石化", "怎么可能"]]]:
            for clue in pair[1]:
                if clue in text:
                    return pair[0]
    if requested != "neutral" and requested in EXPRESSION_NAMES:
        return requested
    # Specific emotions remain authoritative; neutral metadata has a text fallback.
    for pair in [["pouting", ["不理你", "不许", "哼哼", "气死"]],
        ["sad", ["难过", "伤心", "呜呜", "对不起"]],
        ["stunned", ["目瞪口呆", "脑袋空白", "石化", "怎么可能"]],
        ["confused", ["没听懂", "什么意思", "搞不懂", "一头雾水"]],
        ["thinking", ["让我想想", "想一想", "琢磨"]],
        ["laughing", ["哈哈", "喵哈", "笑死", "好好笑"]],
        ["cheer", ["万岁", "好耶", "太棒"]],
        ["energetic", ["跳起来", "跳个舞", "冲呀"]],
        ["wink", ["眨眨眼", "眨眼", "你懂的", "开玩笑"]],
        ["scheming", ["偷偷", "小算盘", "计划通"]],
        ["smug", ["本喵", "天才", "得意"]],
        ["surprised", ["吓", "震惊", "居然"]]]:
        for clue in pair[1]:
            if clue in text:
                return pair[0]
    if mood in ["annoyed", "serious", "curious", "sad", "excited"]:
        return mood
    if "？" in text or "?" in text:
        return "curious"
    if mood == "playful":
        return "smug"
    if "！" in text or "!" in text:
        return "smile"
    return "neutral"

func present(presentation: Dictionary, duration: float) -> void:
    var previous := expression
    var request_id := str(presentation.get("request_id", ""))
    var next := resolve_expression(presentation)
    # A new turn may vary the pose; contiguous same-emotion segments stay steady.
    var vary := request_id != last_request_id or next != expression
    last_request_id = request_id
    set_expression(next, vary)
    if speaking_weight < 0.1 or expression != previous:
        reaction_elapsed = 0.0
        reaction_height = 6.0 if expression in ["excited", "surprised", "cheer", "energetic"] else 2.5
    if duration > 0.0:
        speaking_until = elapsed + duration
    if vary:
        _start_action(presentation)

func _choose_variant(kind: String) -> String:
    var pool: Array = manifest.get("expressions", {}).get(kind, [])
    if pool.is_empty():
        return ""
    var bag: Array = variant_bags.get(kind, [])
    if bag.is_empty():
        bag = pool.duplicate()
        bag.shuffle()
    if bag.size() > 1 and str(bag[-1]) == current_variant:
        var first = bag[0]
        bag[0] = bag[-1]
        bag[-1] = first
    var chosen := str(bag.pop_back())
    variant_bags[kind] = bag
    return chosen

func _texture_for(variant: String) -> Texture2D:
    if textures.has(variant):
        return textures[variant]
    var asset: Dictionary = manifest.get("assets", {}).get(variant, {})
    var path := str(asset.get("asset", ""))
    if path.is_empty():
        return null
    var texture := load(path) as Texture2D
    if texture != null:
        textures[variant] = texture
    return texture

func _show_variant(variant: String, blend: bool = true) -> void:
    if variant.is_empty() or variant == current_variant:
        return
    var texture := _texture_for(variant)
    if texture == null:
        return
    if blend and portrait.texture != null:
        previous_layer.texture = portrait.texture
        previous_layer.modulate.a = 1.0
        fade_elapsed = 0.0
    else:
        previous_layer.modulate.a = 0.0
        fade_elapsed = 1.0
    portrait.texture = texture
    current_variant = variant

func set_expression(value: String, vary: bool = false) -> void:
    if not is_instance_valid(portrait):
        return
    var next := str(ALIASES.get(value, value))
    if next not in EXPRESSION_NAMES:
        next = "neutral"
    if next == expression and not current_variant.is_empty() and not vary:
        return
    animation_frames.clear()
    if next != expression:
        emphasis = 0.005 if next in ["excited", "surprised", "cheer", "energetic"] else 0.002
    expression = next
    held_variant = _choose_variant(next)
    _show_variant(held_variant)

func _start_action(presentation: Dictionary) -> void:
    var action: Dictionary = manifest.get("animations", {}).get(expression, {})
    if action.is_empty() or elapsed < float(animation_deadlines.get(expression, -1.0)):
        return
    # Flame excitement is reserved for strong reactions, not every cheerful line.
    var text := str(presentation.get("reply", ""))
    if expression == "excited" and str(presentation.get("mood", "")) != "excited" and not ("！！" in text or "!!" in text or "兴奋" in text):
        return
    animation_frames = action.get("frames", []).duplicate()
    animation_fps = float(action.get("fps", 14.0))
    animation_elapsed = 0.0
    animation_frame = -1
    animation_deadlines[expression] = elapsed + float(action.get("cooldown", 10.0))
    if not animation_frames.is_empty():
        _show_variant(str(animation_frames[0]))

func talk_pulse() -> void:
    speaking_until = maxf(speaking_until, elapsed + 0.25)

func stop_speaking() -> void:
    speaking_until = elapsed
    animation_frames.clear()
    _show_variant(held_variant)

func reset() -> void:
    stop_speaking()
    variant_bags.clear()
    animation_deadlines.clear()
    last_request_id = ""
    set_expression("neutral", true)

func _process(delta: float) -> void:
    if not is_instance_valid(portrait):
        return
    elapsed += delta
    emphasis = move_toward(emphasis, 0.0, delta * 0.07)
    fade_elapsed += delta
    previous_layer.modulate.a = 1.0 - smoothstep(0.0, 0.12, fade_elapsed)
    var speaking := elapsed < speaking_until
    if is_instance_valid(AudioController.player) and AudioController.player.playing and str(AudioController.current_presentation.get("speaker_id", "")) == "neco_arc":
        speaking = true
    speaking_weight = move_toward(speaking_weight, 1.0 if speaking else 0.0, delta / (0.12 if speaking else 0.20))
    performance_state = "speaking" if speaking else "settling" if speaking_weight > 0.0 else "listening"
    reaction_elapsed += delta
    var action_playing := not animation_frames.is_empty()
    motion_weight = move_toward(motion_weight, 1.0 if action_playing else 0.0, delta * 7.0)
    if action_playing:
        animation_elapsed += delta
        var frame := int(animation_elapsed * animation_fps)
        if frame >= animation_frames.size():
            animation_frames.clear()
            _show_variant(held_variant)
        elif frame != animation_frame:
            animation_frame = frame
            # These are matching authored motion frames, not unrelated expressions.
            _show_variant(str(animation_frames[frame]), false)
    var breath := sin(elapsed * 2.0) * 0.003
    portrait.scale = Vector2.ONE * POSE_SCALE * (1.0 + breath + emphasis)
    var bounce := -absf(sin(elapsed * 4.0)) * (2.0 if expression not in ["serious", "sad", "thinking", "stunned"] else 0.6) * speaking_weight
    bounce -= sin(minf(reaction_elapsed / 0.38, 1.0) * PI) * reaction_height
    bounce -= absf(sin(animation_elapsed * 5.0)) * 3.0 * motion_weight
    portrait.offset_top = rest_top + bounce
    portrait.offset_bottom = rest_bottom + bounce
    var sway := 0.0
    if expression in ["wink", "laughing", "scheming", "energetic"]:
        sway = sin(elapsed * 2.4) * 0.012 * speaking_weight
    portrait.rotation = lerpf(portrait.rotation, sway, minf(delta * 8.0, 1.0))
