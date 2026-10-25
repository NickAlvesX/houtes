extends Node2D
class_name House

@export var color: Color = Color.RED
var size: float = 36.0

func set_color(c: Color) -> void:
	color = c
	queue_redraw()

func _draw() -> void:
	var half := size * 0.5
	var body := Rect2(Vector2(-half, 0.0), Vector2(size, half))
	draw_rect(body, color)
	draw_rect(body, Color.BLACK, false, 2.0)

	var roof := PackedVector2Array([
		Vector2(-half * 1.15, 0.0),
		Vector2(0.0, -half),
		Vector2(half * 1.15, 0.0),
	])
	draw_colored_polygon(roof, color)
	draw_polyline(PackedVector2Array([roof[0], roof[1], roof[2]]), Color.BLACK, 2.0, true)
