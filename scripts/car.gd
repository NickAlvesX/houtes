extends Node2D
class_name Car

@export var color: Color = Color.RED
var radius: float = 20.0

func set_color(c: Color) -> void:
	color = c
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, color)
	draw_circle(Vector2.ZERO, radius, Color.BLACK, false, 2.0)
