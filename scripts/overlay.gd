extends Node2D
class_name Overlay

const VIOLATION_COLOR := Color(0.85, 0.25, 0.2)

# Godot draws a parent's own _draw() content, then its children, on top of it —
# so anything drawn inside game_board.gd's _draw() (roads, buildings, labels)
# is structurally stuck underneath the Car/House child nodes. This node is
# added with a higher z_index specifically so informational overlays (name
# tags, violation notes, hover tooltip) always render above every car and
# house, regardless of where they happen to sit on the board.
var board: Node2D = null


func _draw() -> void:
	if board == null:
		return
	for item in board.block_decor:
		if item.type == "landmark":
			var label_pos: Vector2 = item.rect.get_center() + Vector2(0.0, item.rect.size.y * 0.5 + 12.0 * board.draw_scale)
			_draw_label_plate(item.name, label_pos, 12)

	# Violation notes are persistent (shown regardless of hover, until the
	# player resets) — there's no live fuel/ETA readout while drawing on
	# purpose, so this is the player's only feedback on what went wrong.
	for id in board.violations.keys():
		var d = board._get_car_def(id)
		if d != null and board.car_nodes.has(id):
			_draw_tooltip(board.car_nodes[id].position, _violation_lines(d), VIOLATION_COLOR)

	if board.hovered_car_id != "" and not board.violations.has(board.hovered_car_id):
		var hovered = board._get_car_def(board.hovered_car_id)
		if hovered != null:
			_draw_tooltip(board.car_nodes[hovered.id].position, board._car_tooltip_lines(hovered), hovered.color)


func _violation_lines(d) -> Array:
	var lines: Array = [d.id.capitalize()]
	lines.append_array(board.violations[d.id])
	return lines


# A name tag with its own opaque background, since whatever is underneath a
# label (dark asphalt, a light lot, a car) varies — plain text would often
# be unreadable or, pre-overlay, invisible entirely.
func _draw_label_plate(text: String, center: Vector2, font_size: int) -> void:
	var font := ThemeDB.fallback_font
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pad: Vector2 = Vector2(5.0, 3.0) * board.draw_scale
	var plate := Rect2(center - text_size * 0.5 - pad, text_size + pad * 2.0)
	draw_rect(plate, Color(1.0, 1.0, 1.0, 0.92), true)
	draw_rect(plate, Color(0.0, 0.0, 0.0, 0.55), false, 1.0 * board.draw_scale)
	var text_pos := Vector2(center.x - text_size.x * 0.5, center.y + text_size.y * 0.32)
	draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.08, 0.08, 0.08))


func _draw_tooltip(car_pos: Vector2, lines: Array, accent: Color) -> void:
	var font := ThemeDB.fallback_font
	var font_size := 13
	var line_height: float = font.get_height(font_size) + 3.0
	var max_w := 0.0
	for line in lines:
		max_w = max(max_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var pad := Vector2(10.0, 8.0)
	var box_size := Vector2(max_w, line_height * lines.size()) + pad * 2.0
	var box_pos := car_pos + Vector2(18.0, -box_size.y - 10.0)
	box_pos.x = clamp(box_pos.x, 10.0, board.WINDOW_W - box_size.x - 10.0)
	box_pos.y = max(box_pos.y, 10.0)
	var box := Rect2(box_pos, box_size)

	draw_rect(box, Color(0.1, 0.1, 0.12, 0.92), true)
	draw_rect(box, accent, false, 2.0)
	for i in range(lines.size()):
		var line_pos := box_pos + Vector2(pad.x, pad.y + line_height * (i + 1) - 4.0)
		draw_string(font, line_pos, lines[i], HORIZONTAL_ALIGNMENT_LEFT, box_size.x - pad.x * 2.0, font_size, Color(1.0, 1.0, 1.0))
