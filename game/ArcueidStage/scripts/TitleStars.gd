extends Control

var stars: Array[Dictionary] = []
var elapsed := 0.0


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    var random := RandomNumberGenerator.new()
    random.seed = 281
    for index in range(48):
        stars.append({
            "x": random.randf_range(0.035, 0.965),
            "y": random.randf_range(0.0, 1.0),
            "radius": random.randf_range(1.0, 3.5),
            "phase": random.randf_range(0.0, TAU),
            "speed": random.randf_range(0.35, 0.85),
            "velocity": Vector2(random.randf_range(-7.0, 7.0), random.randf_range(12.0, 25.0)),
        })


func _process(delta: float) -> void:
    elapsed += delta
    queue_redraw()


func _draw() -> void:
    for star in stars:
        var phase: float = star["phase"]
        var speed: float = star["speed"]
        var velocity: Vector2 = star["velocity"]
        var travel_height := maxf(size.y * 0.85, 1.0)
        var progress := fposmod(float(star["y"]) - elapsed * velocity.y / travel_height, 1.0)
        var point := Vector2(
            fposmod(float(star["x"]) * size.x + elapsed * velocity.x + sin(elapsed * speed + phase) * 12.0, maxf(size.x, 1.0)),
            size.y * 0.15 + progress * travel_height
        )
        # Fade at both ends so particles loop without visibly jumping.
        var edge_fade := smoothstep(0.0, 0.12, progress) * (1.0 - smoothstep(0.88, 1.0, progress))
        var twinkle := (0.38 + 0.20 * sin(elapsed * (speed + 0.42) + phase)) * edge_fade
        var radius: float = star["radius"]
        draw_circle(point, radius * 2.8, Color(0.26, 0.55, 0.90, twinkle * 0.08))
        draw_circle(point, radius * 1.6, Color(0.34, 0.64, 0.94, twinkle * 0.15))
        draw_circle(point, radius, Color(0.40, 0.69, 0.93, twinkle))
