extends Node2D

const WINDOW_W := 900.0
const BOARD_LEFT := 150.0
const BOARD_TOP := 110.0
const BOARD_MAX_SIZE := 560.0
const CELL_MIN := 38.0
const CELL_MAX := 68.0
const BASE_CELL := 60.0
const STEP_DURATION := 0.22
const FAST_FORWARD_SCALE := 3.0
const MINUTES_PER_TICK := 1

const ASPHALT := Color(0.24, 0.24, 0.27)
const LANE_LINE := Color(0.92, 0.92, 0.86, 0.9)
const SIDEWALK := Color(0.89, 0.89, 0.91)
const LOT := Color(0.78, 0.78, 0.8)
const ROOF_COLORS := [
	Color(0.85, 0.3, 0.12),
	Color(0.88, 0.47, 0.2),
	Color(0.76, 0.22, 0.1),
	Color(0.92, 0.56, 0.3),
]
const SCHOOL_COLOR := Color(0.42, 0.52, 0.64)
const MARKET_COLOR := Color(0.85, 0.68, 0.22)

# FAILED is distinct from CRASHED: no car hit another, but something else
# went wrong during the drive (ran out of fuel, broke a condition, arrived
# late) — see _run_simulation()'s post-drive check and violations below.
enum State { DRAWING, PLAYING, CRASHED, FAILED, WON }

# A car's grid coordinates are stored as Vector2i(row, col), both 1-based.
# Exactly one of entry.row / entry.col is 0 — that marks which edge the car
# enters from, and the car itself sits one cell outside the grid there.
# move_ticks is how many simulation ticks it takes to cross one cell (lower =
# faster) — and, since 1 tick = 1 in-game minute (see MINUTES_PER_TICK), also
# how many in-game minutes that costs, before any radar on the way slows it
# down further. fuel is the max number of path cells the car can be given
# (-1 = unlimited) — nothing stops the player from drawing past it; running
# out just strands the car on the street during the drive (see
# _run_simulation()). conditions is a list of extra rules, all checked only
# once Play is pressed — not while drawing — and surfaced afterwards as a
# per-car violation note rather than blocking anything (see violations):
#   {"type": "avoid_car", "other": <car id>}      — never share a cell with that car's road
#   {"type": "avoid_building", "name": <landmark>} — never use that landmark's frontage cell
#   {"type": "require_building", "name": <landmark>} — must pass through its frontage cell
#   {"type": "arrive_by", "minutes": <minutes since midnight>} — must reach the house by this in-game time
class CarDef:
	var id: String
	var color: Color
	var entry: Vector2i
	var house: Vector2i
	# Where the House building is actually drawn — a non-road cell next to
	# `house`, so the house sits beside the street like a real driveway
	# instead of being painted on top of the asphalt. Filled in by
	# _assign_house_cells() once a level's road layout is known; `house`
	# itself stays the real gameplay destination (fuel, win check, sim).
	var house_cell: Vector2i
	var move_ticks: int = 2
	var fuel: int = -1
	var conditions: Array = []

# A level is two sets of "full street" rows/cols (always including the outer
# ring, row/col 1 and grid_size). Any cell on one of those rows/cols is road;
# everything else falls into a rectangular city block between streets.
# Because every street row spans every column (and vice versa), the whole
# road network is always one connected lattice — so as long as every car's
# entry and house sit on it, the level is reachable by construction. Whether
# it's solvable under fuel/condition constraints is verified separately
# (see the one-off level-check script used during development).
class LevelDef:
	var grid_size: int
	var cars: Array
	var road_rows: Dictionary
	var road_cols: Dictionary
	var landmarks: Array = []
	var radars: Array = []
	var start_minutes: int = 660

var LEVELS: Array = []
var current_level_index: int = 0

var grid_size: int = 8
var cell_size: float = BASE_CELL
var grid_origin: Vector2 = Vector2.ZERO
var draw_scale: float = 1.0

var car_defs: Array = []
var road_rows: Dictionary = {}
var road_cols: Dictionary = {}
var landmarks: Array = []
var radars: Array = []
var level_start_minutes: int = 660
var blocks: Array = []
var block_decor: Array = []
var paths: Dictionary = {}
var car_nodes: Dictionary = {}
var house_nodes: Dictionary = {}

var state: State = State.DRAWING
var drawing_car_id: String = ""
var _last_drag_pos: Vector2 = Vector2.ZERO
var hovered_car_id: String = ""
var overlay: Overlay = null

# car id -> Array[String] of problems found after a non-crashed drive (ran
# out of fuel, broke a condition, arrived late). Persists on screen (see
# overlay.gd) until Reset/Clear/a level change explicitly clears it.
var violations: Dictionary = {}

@onready var play_button: Button = $UI/PlayButton
@onready var clear_button: Button = $UI/ClearButton
@onready var reset_button: Button = $UI/ResetButton
@onready var next_button: Button = $UI/NextButton
@onready var prev_button: Button = $UI/PrevButton
@onready var status_label: Label = $UI/StatusLabel
@onready var clock_label: Label = $UI/ClockLabel


func _ready() -> void:
	_build_levels()
	play_button.pressed.connect(_on_play_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	next_button.pressed.connect(_on_next_pressed)
	prev_button.pressed.connect(_on_prev_pressed)

	overlay = Overlay.new()
	overlay.board = self
	overlay.z_index = 10
	add_child(overlay)

	_load_level(0)


# Redraws the board itself and the overlay together — anything that changes
# path/hover/level state needs both repainted, since they're separate
# CanvasItems (see overlay.gd for why the split exists).
func _redraw_all() -> void:
	queue_redraw()
	overlay.queue_redraw()


# Engine.time_scale uniformly speeds up the simulation's tick timers and the
# cars' tweens together, so holding Space just scales it up for as long as
# it's held — no need to touch the simulation loop's own durations. Only
# applies while cars are actually driving; reset the instant that ends.
func _process(_delta: float) -> void:
	var target_scale: float = FAST_FORWARD_SCALE if (state == State.PLAYING and Input.is_key_pressed(KEY_SPACE)) else 1.0
	if Engine.time_scale != target_scale:
		Engine.time_scale = target_scale


# ---- Level data ----

func _make_car(id: String, color: Color, entry: Vector2i, house: Vector2i,
		move_ticks: int = 2, fuel: int = -1, conditions: Array = []) -> CarDef:
	var d := CarDef.new()
	d.id = id
	d.color = color
	d.entry = entry
	d.house = house
	d.house_cell = house
	d.move_ticks = move_ticks
	d.fuel = fuel
	d.conditions = conditions
	return d


func _make_landmark(name: String, cell: Vector2i, road_cell: Vector2i, color: Color) -> Dictionary:
	return {"name": name, "cell": cell, "road_cell": road_cell, "color": color}


func _make_radar(cell: Vector2i, speed_ticks: int) -> Dictionary:
	return {"cell": cell, "speed_ticks": speed_ticks}


# HH:MM, purely for readability when authoring level data below.
func _time(hh: int, mm: int) -> int:
	return hh * 60 + mm


func _format_time(total_minutes: int) -> String:
	var m: int = ((total_minutes % 1440) + 1440) % 1440
	return "%02d:%02d" % [m / 60, m % 60]


func _find_radar(cell: Vector2i):
	for r in radars:
		if r.cell == cell:
			return r
	return null


# The ticks a move into `to_cell` actually costs: the car's own pace, unless
# a radar guards that cell and enforces a slower (higher-tick) limit — a
# radar can only slow a car down, never speed it past its own top speed.
func _move_ticks_for(d: CarDef, to_cell: Vector2i) -> int:
	var ticks: int = max(1, d.move_ticks)
	var radar = _find_radar(to_cell)
	if radar != null:
		ticks = max(ticks, radar.speed_ticks)
	return ticks


func _arrive_by_minutes(d: CarDef) -> int:
	for cond in d.conditions:
		if cond.type == "arrive_by":
			return cond.minutes
	return -1


# The non-road cell next to a house's road-cell destination where the House
# building itself gets drawn. Tries the four neighbors in a fixed order and
# falls back to the road cell itself only if a level design leaves no
# adjacent block cell at all (shouldn't happen — every level's houses are
# placed so at least one side isn't also a street).
func _assign_house_cells(level: LevelDef) -> void:
	var offsets := [Vector2i(-1, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1)]
	for d in level.cars:
		d.house_cell = d.house
		for off in offsets:
			var n: Vector2i = d.house + off
			if n.x < 1 or n.x > level.grid_size or n.y < 1 or n.y > level.grid_size:
				continue
			if not (level.road_rows.has(n.x) or level.road_cols.has(n.y)):
				d.house_cell = n
				break


func _set_from(nums: Array) -> Dictionary:
	var s := {}
	for n in nums:
		s[n] = true
	return s


func _build_levels() -> void:
	LEVELS.clear()

	# Level 1: tutorial. Two cars, equal speed, no fuel limit, no conditions.
	var level1 := LevelDef.new()
	level1.grid_size = 8
	level1.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(8, 6)),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(5, 0), Vector2i(2, 8)),
	]
	level1.road_rows = _set_from([1, 4, 8])
	level1.road_cols = _set_from([1, 4, 8])
	_assign_house_cells(level1)
	LEVELS.append(level1)

	# Level 2: introduces fuel (max road length) — same layout shape as before.
	var level2 := LevelDef.new()
	level2.grid_size = 8
	level2.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(8, 6), 2, 13),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(6, 0), Vector2i(2, 8), 2, 13),
	]
	level2.road_rows = _set_from([1, 5, 8])
	level2.road_cols = _set_from([1, 5, 8])
	_assign_house_cells(level2)
	LEVELS.append(level2)

	# Level 3: introduces differing speeds — red is fast, blue is slow.
	# Blue's house sits one cell short of the grid corner (4,8) rather than
	# (3,8) — a corner-adjacent road cell with both axes on the street grid
	# would leave no non-road cell next to it for the house itself.
	var level3 := LevelDef.new()
	level3.grid_size = 8
	level3.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(8, 7), 1, -1),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(7, 0), Vector2i(4, 8), 3, -1),
	]
	level3.road_rows = _set_from([1, 3, 6, 8])
	level3.road_cols = _set_from([1, 4, 8])
	_assign_house_cells(level3)
	LEVELS.append(level3)

	# Level 4: bigger grid, a third car, and the "avoid car" condition.
	# Red's house is at (4,5), not the rows/cols intersection (5,5), for the
	# same reason as level 3's blue house.
	var level4 := LevelDef.new()
	level4.grid_size = 10
	level4.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(4, 5), 2, -1),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(0, 8), Vector2i(6, 10), 2, -1),
		_make_car("green", Color(0.25, 0.72, 0.35), Vector2i(6, 0), Vector2i(10, 3), 2, -1,
			[{"type": "avoid_car", "other": "red"}]),
	]
	level4.road_rows = _set_from([1, 5, 10])
	level4.road_cols = _set_from([1, 5, 10])
	_assign_house_cells(level4)
	LEVELS.append(level4)

	# Level 5: smaller grid, tight fuel, differing speed, and named-building
	# conditions — avoid the School, must pass the Market, avoid red's road.
	# Both houses are nudged off the rows/cols intersections for the same
	# "needs a non-road neighbor" reason as levels 3 and 4.
	var level5 := LevelDef.new()
	level5.grid_size = 6
	level5.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(3, 1), 3, 6,
			[{"type": "avoid_building", "name": "School"}]),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(5, 0), Vector2i(3, 6), 1, 16,
			[{"type": "require_building", "name": "Market"}, {"type": "avoid_car", "other": "red"}]),
	]
	level5.road_rows = _set_from([1, 4, 6])
	level5.road_cols = _set_from([1, 4, 6])
	level5.landmarks = [
		_make_landmark("Market", Vector2i(2, 5), Vector2i(1, 5), MARKET_COLOR),
		_make_landmark("School", Vector2i(5, 5), Vector2i(4, 5), SCHOOL_COLOR),
	]
	_assign_house_cells(level5)
	LEVELS.append(level5)

	# Level 6: introduces the clock. Blue is normally fast (60km/h) but its
	# most direct route to the house runs straight through a radar enforcing
	# 20km/h — budget for that slowdown or miss the 11:54 deadline. Red is a
	# plain, unconstrained car for contrast; the radar doesn't touch its route.
	var level6 := LevelDef.new()
	level6.grid_size = 8
	level6.start_minutes = _time(11, 40)
	level6.cars = [
		_make_car("red", Color(0.85, 0.2, 0.2), Vector2i(0, 2), Vector2i(8, 6)),
		_make_car("blue", Color(0.2, 0.45, 0.9), Vector2i(5, 0), Vector2i(2, 8), 1, -1,
			[{"type": "arrive_by", "minutes": _time(11, 54)}]),
	]
	level6.road_rows = _set_from([1, 4, 8])
	level6.road_cols = _set_from([1, 4, 8])
	level6.radars = [
		_make_radar(Vector2i(4, 5), 3),
	]
	_assign_house_cells(level6)
	LEVELS.append(level6)


func _load_level(index: int) -> void:
	current_level_index = index
	var level: LevelDef = LEVELS[index]
	car_defs = level.cars
	road_rows = level.road_rows
	road_cols = level.road_cols
	landmarks = level.landmarks
	radars = level.radars
	level_start_minutes = level.start_minutes
	_layout_grid(level.grid_size)
	blocks = _compute_blocks(road_rows, road_cols)
	_generate_block_decor()

	var has_deadline := false
	for d in car_defs:
		if _arrive_by_minutes(d) >= 0:
			has_deadline = true
			break
	clock_label.visible = has_deadline
	_update_clock(level_start_minutes)

	paths = {}
	for d in car_defs:
		paths[d.id] = []

	for id in car_nodes.keys():
		car_nodes[id].queue_free()
	for id in house_nodes.keys():
		house_nodes[id].queue_free()
	car_nodes.clear()
	house_nodes.clear()

	for d in car_defs:
		var house := House.new()
		house.color = d.color
		house.size = cell_size * 0.6
		house.position = cell_to_world(d.house_cell.x, d.house_cell.y)
		add_child(house)
		house_nodes[d.id] = house

	for d in car_defs:
		var car := Car.new()
		car.color = d.color
		car.radius = cell_size * 0.33
		car.position = cell_to_world(d.entry.x, d.entry.y)
		add_child(car)
		car_nodes[d.id] = car

	state = State.DRAWING
	drawing_car_id = ""
	hovered_car_id = ""
	violations = {}
	reset_button.hide()
	clear_button.disabled = false
	_update_nav_buttons()
	_check_ready()
	_redraw_all()


func _layout_grid(size: int) -> void:
	grid_size = size
	cell_size = clamp(BOARD_MAX_SIZE / float(size + 1), CELL_MIN, CELL_MAX)
	draw_scale = cell_size / BASE_CELL
	var grid_pixel := cell_size * size
	var origin_x: float = max(BOARD_LEFT + cell_size, (WINDOW_W - grid_pixel) / 2.0)
	grid_origin = Vector2(origin_x, BOARD_TOP + cell_size)


# ---- Road / block layout ----

func _bands(road_set: Dictionary, size: int) -> Array:
	var bands := []
	var start := -1
	for i in range(1, size + 1):
		if road_set.has(i):
			if start != -1:
				bands.append(Vector2i(start, i - 1))
				start = -1
		elif start == -1:
			start = i
	if start != -1:
		bands.append(Vector2i(start, size))
	return bands


func _compute_blocks(rows: Dictionary, cols: Dictionary) -> Array:
	var row_bands := _bands(rows, grid_size)
	var col_bands := _bands(cols, grid_size)
	var result := []
	for rb in row_bands:
		for cb in col_bands:
			result.append({"r0": rb.x, "r1": rb.y, "c0": cb.x, "c1": cb.y})
	return result


func _generate_block_decor() -> void:
	block_decor = []
	var block_index := 0
	for block in blocks:
		block_index += 1
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%d_%d" % [current_level_index, block_index])

		var half := Vector2(cell_size, cell_size) * 0.5
		var top_left: Vector2 = cell_to_world(block.r0, block.c0) - half
		var bottom_right: Vector2 = cell_to_world(block.r1, block.c1) + half
		var block_rect := Rect2(top_left, bottom_right - top_left)
		var lot_rect: Rect2 = block_rect.grow(-5.0)

		block_decor.append({"type": "sidewalk", "rect": block_rect})
		block_decor.append({"type": "lot", "rect": lot_rect})

		var placed: Array = []
		for lm in landmarks:
			var lc: Vector2i = lm.cell
			if lc.x >= block.r0 and lc.x <= block.r1 and lc.y >= block.c0 and lc.y <= block.c1:
				var lm_center: Vector2 = cell_to_world(lc.x, lc.y)
				var lm_rect := Rect2(lm_center - half * 0.8, half * 1.6)
				placed.append(lm_rect)
				block_decor.append({"type": "landmark", "rect": lm_rect, "color": lm.color, "name": lm.name})

		# Reserve space for any car's house that lands in this block too, so a
		# randomly-placed decorative building never overlaps it.
		for d in car_defs:
			var hc: Vector2i = d.house_cell
			if hc.x >= block.r0 and hc.x <= block.r1 and hc.y >= block.c0 and hc.y <= block.c1:
				var house_center: Vector2 = cell_to_world(hc.x, hc.y)
				placed.append(Rect2(house_center - half * 0.8, half * 1.6))

		var cell_count: int = (block.r1 - block.r0 + 1) * (block.c1 - block.c0 + 1)
		var building_count: int = clampi(int(round(cell_count / 2.5)), 1, 5)
		var decorative_added := 0
		var attempts := 0
		while decorative_added < building_count and attempts < building_count * 15:
			attempts += 1
			var w: float = rng.randf_range(cell_size * 0.55, cell_size * 0.95)
			var h: float = rng.randf_range(cell_size * 0.55, cell_size * 0.95)
			if lot_rect.size.x <= w or lot_rect.size.y <= h:
				continue
			var x: float = lot_rect.position.x + rng.randf() * (lot_rect.size.x - w)
			var y: float = lot_rect.position.y + rng.randf() * (lot_rect.size.y - h)
			var rect := Rect2(Vector2(x, y), Vector2(w, h))
			var overlaps := false
			for p in placed:
				if (rect as Rect2).grow(6.0).intersects(p):
					overlaps = true
					break
			if overlaps:
				continue
			placed.append(rect)
			decorative_added += 1
			block_decor.append({"type": "building", "rect": rect, "color": ROOF_COLORS[rng.randi() % ROOF_COLORS.size()]})

		var tree_count: int = clampi(int(round(cell_count * 1.2)), 2, 10)
		for i in range(tree_count):
			var pos := Vector2(
				lot_rect.position.x + rng.randf() * lot_rect.size.x,
				lot_rect.position.y + rng.randf() * lot_rect.size.y
			)
			block_decor.append({"type": "tree", "pos": pos})

		var mid_row := int(round((block.r0 + block.r1) / 2.0))
		var mid_col := int(round((block.c0 + block.c1) / 2.0))
		block_decor.append({"type": "crosswalk", "cell": Vector2i(block.r0 - 1, mid_col), "horizontal_road": true})
		block_decor.append({"type": "crosswalk", "cell": Vector2i(block.r1 + 1, mid_col), "horizontal_road": true})
		block_decor.append({"type": "crosswalk", "cell": Vector2i(mid_row, block.c0 - 1), "horizontal_road": false})
		block_decor.append({"type": "crosswalk", "cell": Vector2i(mid_row, block.c1 + 1), "horizontal_road": false})


# ---- Grid <-> world geometry ----

func cell_to_world(row: int, col: int) -> Vector2:
	return grid_origin + Vector2(
		(col - 1) * cell_size + cell_size * 0.5,
		(row - 1) * cell_size + cell_size * 0.5
	)


func world_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - grid_origin
	var col := int(floor(local.x / cell_size)) + 1
	var row := int(floor(local.y / cell_size)) + 1
	if row < 1 or row > grid_size or col < 1 or col > grid_size:
		return Vector2i(-1, -1)
	return Vector2i(row, col)


func get_required_start_cell(d: CarDef) -> Vector2i:
	if d.entry.x == 0:
		return Vector2i(1, d.entry.y)
	return Vector2i(d.entry.x, 1)


func is_road(cell: Vector2i) -> bool:
	if cell.x < 1 or cell.x > grid_size or cell.y < 1 or cell.y > grid_size:
		return false
	return road_rows.has(cell.x) or road_cols.has(cell.y)


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1


func _get_car_def(id: String) -> CarDef:
	for d in car_defs:
		if d.id == id:
			return d
	return null


func _find_landmark(lm_name: String):
	for lm in landmarks:
		if lm.name == lm_name:
			return lm
	return null


# ---- Input / path drawing ----

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(get_global_mouse_position())

	if state != State.DRAWING:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_drag(get_global_mouse_position())
		else:
			_end_drag()
	elif event is InputEventMouseMotion and drawing_car_id != "":
		_extend_drag(get_global_mouse_position())


# The tooltip box is only repainted when the overlay redraws, so tracking
# hover during PLAYING (while cars tween between cells on their own, with no
# new mouse events to trigger a repaint) would leave a stale box behind a car
# that has since moved on — simplest fix is to just not track hover then.
func _update_hover(pos: Vector2) -> void:
	if state == State.PLAYING:
		if hovered_car_id != "":
			hovered_car_id = ""
			overlay.queue_redraw()
		return
	var found := ""
	for d in car_defs:
		var car: Car = car_nodes.get(d.id)
		if car != null and car.position.distance_to(pos) <= car.radius + 6.0:
			found = d.id
			break
	if found != hovered_car_id:
		hovered_car_id = found
		overlay.queue_redraw()


func _try_start_drag(pos: Vector2) -> void:
	var cell := world_to_cell(pos)
	if cell == Vector2i(-1, -1) or not is_road(cell):
		return
	for d in car_defs:
		var path: Array = paths.get(d.id, [])
		# Grabbing anywhere on a road you've already drawn resumes dragging
		# from that point (trimming what came after) instead of forcing a
		# full restart from the car's entry every time you let go.
		var existing_index: int = path.find(cell)
		if existing_index != -1:
			drawing_car_id = d.id
			paths[d.id] = path.slice(0, existing_index + 1)
			_last_drag_pos = pos
			_redraw_all()
			return
		if cell == get_required_start_cell(d):
			drawing_car_id = d.id
			paths[d.id] = [cell]
			_last_drag_pos = pos
			_redraw_all()
			return


func _extend_drag(pos: Vector2) -> void:
	var d := _get_car_def(drawing_car_id)
	if d == null:
		return
	# Mouse-motion events don't fire for every pixel — on a fast or diagonal
	# drag the pointer can jump straight past several cells between events.
	# Sample along the segment from the last known point instead of only
	# looking at the latest one, so the path keeps up with the cursor.
	var from: Vector2 = _last_drag_pos
	var steps: int = max(1, int(ceil(from.distance_to(pos) / (cell_size * 0.5))))
	for i in range(1, steps + 1):
		_apply_drag_point(d, from.lerp(pos, float(i) / float(steps)))
		if drawing_car_id == "":
			break
	_last_drag_pos = pos


# Fuel, avoid/require-building, avoid-car and arrive-by are all deliberately
# NOT enforced here — the player can draw any connected road they like and
# only finds out at Play time whether it actually worked (see
# _run_simulation()'s post-drive violations check). The only things that
# still matter while drawing are the physical ones: stay on road, stay
# adjacent, don't revisit a cell except to trim back along your own road.
func _apply_drag_point(d: CarDef, pos: Vector2) -> void:
	var cell := world_to_cell(pos)
	if cell == Vector2i(-1, -1) or not is_road(cell):
		return
	var path: Array = paths[d.id]
	if path.is_empty() or cell == path[-1]:
		return

	var existing_index: int = path.find(cell)
	if existing_index != -1:
		paths[d.id] = path.slice(0, existing_index + 1)
		_redraw_all()
		if paths[d.id][-1] == d.house:
			drawing_car_id = ""
			_check_ready()
		return

	if not _is_adjacent(path[-1], cell):
		return

	path.append(cell)
	_redraw_all()
	if paths[d.id][-1] == d.house:
		drawing_car_id = ""
		_check_ready()


func _end_drag() -> void:
	drawing_car_id = ""
	_check_ready()


# Only checks that every car's road actually reaches its house — fuel,
# conditions and deadlines are no longer gates on Play (see
# _apply_drag_point()'s comment); they're discovered after the drive instead.
func _check_ready() -> void:
	if state != State.DRAWING:
		return
	var all_done := true
	for d in car_defs:
		var p: Array = paths[d.id]
		if p.is_empty() or p[-1] != d.house:
			all_done = false
	play_button.disabled = not all_done
	var prefix := "Level %d — " % (current_level_index + 1)
	status_label.text = prefix + ("All roads are ready. Press Play!" if all_done \
		else "Draw a road from each car to its matching house.")


# move_ticks is ticks-per-cell (lower = faster); expressed here as a plain
# km/h figure so the tooltip reads as a real stat instead of a vague label.
func _speed_kmh(move_ticks: int) -> int:
	return int(round(60.0 / max(1, move_ticks)))


func _car_tooltip_lines(d: CarDef) -> Array:
	var lines: Array = [d.id.capitalize()]
	lines.append("Speed: %dkm/h" % _speed_kmh(d.move_ticks))
	lines.append("Fuel: %d cells" % d.fuel if d.fuel >= 0 else "Fuel: unlimited")
	for cond in d.conditions:
		match cond.type:
			"avoid_car":
				lines.append("Avoid %s's road" % _get_car_def(cond.other).id.capitalize())
			"avoid_building":
				lines.append("Avoid the %s" % cond.name)
			"require_building":
				lines.append("Must pass by the %s" % cond.name)
			"arrive_by":
				lines.append("Home by %s" % _format_time(cond.minutes))
	return lines


# ---- Drawing ----

func _draw() -> void:
	for row in range(1, grid_size + 1):
		for col in range(1, grid_size + 1):
			var cell := Vector2i(row, col)
			if is_road(cell):
				_draw_road_cell(cell)
	for item in block_decor:
		match item.type:
			"sidewalk":
				draw_rect(item.rect, SIDEWALK, true)
			"lot":
				draw_rect(item.rect, LOT, true)
			"building":
				_draw_building(item.rect, item.color)
			"tree":
				_draw_bush(item.pos)
			"crosswalk":
				_draw_crosswalk(cell_to_world(item.cell.x, item.cell.y), item.horizontal_road)
			"landmark":
				_draw_landmark(item.rect, item.color)
	for r in radars:
		_draw_radar(r.cell, r.speed_ticks)
	for d in car_defs:
		_draw_start_highlight(d)
	for d in car_defs:
		_draw_driveway(d)
	for d in car_defs:
		_draw_path(d)


func _cell_rect(cell: Vector2i) -> Rect2:
	var center := cell_to_world(cell.x, cell.y)
	return Rect2(center - Vector2(cell_size, cell_size) * 0.5, Vector2(cell_size, cell_size))


func _draw_road_cell(cell: Vector2i) -> void:
	var rect := _cell_rect(cell)
	draw_rect(rect, ASPHALT, true)

	var center := rect.get_center()
	var half := cell_size * 0.5
	if is_road(Vector2i(cell.x, cell.y - 1)):
		_draw_dashes(center - Vector2(half, 0.0), center)
	if is_road(Vector2i(cell.x, cell.y + 1)):
		_draw_dashes(center, center + Vector2(half, 0.0))
	if is_road(Vector2i(cell.x - 1, cell.y)):
		_draw_dashes(center - Vector2(0.0, half), center)
	if is_road(Vector2i(cell.x + 1, cell.y)):
		_draw_dashes(center, center + Vector2(0.0, half))


func _draw_dashes(from: Vector2, to: Vector2) -> void:
	var dash_len := 8.0 * draw_scale
	var gap_len := 6.0 * draw_scale
	var total := from.distance_to(to)
	if total <= 0.0:
		return
	var dir := (to - from) / total
	var travelled := 0.0
	while travelled < total:
		var seg_end: float = min(travelled + dash_len, total)
		draw_line(from + dir * travelled, from + dir * seg_end, LANE_LINE, 3.0 * draw_scale)
		travelled += dash_len + gap_len


func _draw_crosswalk(center: Vector2, horizontal_road: bool) -> void:
	var bar_count := 5
	var span := cell_size * 0.6
	var bar_len := cell_size * 0.5
	for i in range(bar_count):
		var t: float = (float(i) / float(bar_count - 1) - 0.5) * span
		# Each stripe runs parallel to the road's own direction of travel and
		# the stripes are spaced out across the pedestrian's crossing width —
		# so a horizontal road (lane lines running left-right) gets horizontal
		# stripes stacked vertically, not the other way around.
		if horizontal_road:
			draw_line(center + Vector2(-bar_len * 0.5, t), center + Vector2(bar_len * 0.5, t), LANE_LINE, 5.0 * draw_scale)
		else:
			draw_line(center + Vector2(t, -bar_len * 0.5), center + Vector2(t, bar_len * 0.5), LANE_LINE, 5.0 * draw_scale)


# A round speed-limit sign sitting on the road cell it guards — white face,
# red ring, the km/h limit in the middle, like a real traffic sign. It's its
# own opaque background (the circle), so unlike the landmark name it's fine
# drawn in the normal pass even though a car will later drive over it.
func _draw_radar(cell: Vector2i, speed_ticks: int) -> void:
	var center := cell_to_world(cell.x, cell.y)
	var r := cell_size * 0.24
	draw_circle(center, r, Color(0.96, 0.96, 0.96))
	draw_circle(center, r, Color(0.78, 0.12, 0.12), false, 3.0 * draw_scale)
	var text := "%d" % _speed_kmh(speed_ticks)
	var font := ThemeDB.fallback_font
	var font_size := int(round(11 * draw_scale))
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var text_pos := Vector2(center.x - text_size.x * 0.5, center.y + text_size.y * 0.32)
	draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.1, 0.1, 0.1))


func _draw_building(rect: Rect2, color: Color) -> void:
	var shadow := rect
	shadow.position += Vector2(4.0, 5.0) * draw_scale
	draw_rect(shadow, Color(0.0, 0.0, 0.0, 0.25), true)

	draw_rect(rect, color, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * 0.22, rect.size.y)), Color(1.0, 1.0, 1.0, 0.18), true)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.35), false, 2.0 * draw_scale)


func _draw_landmark(rect: Rect2, color: Color) -> void:
	var shadow := rect
	shadow.position += Vector2(4.0, 5.0) * draw_scale
	draw_rect(shadow, Color(0.0, 0.0, 0.0, 0.3), true)
	draw_rect(rect, color, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * 0.22, rect.size.y)), Color(1.0, 1.0, 1.0, 0.22), true)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.5), false, 2.5 * draw_scale)
	# The name label itself is drawn by Overlay (see overlay.gd) — it needs to
	# render above every car/house, which this node's own _draw() cannot do.


func _draw_bush(pos: Vector2) -> void:
	var base := Color(0.42, 0.42, 0.44)
	var r := 6.0 * draw_scale
	draw_circle(pos + Vector2(0.0, -0.5 * r), r * 0.85, base.lightened(0.08))
	draw_circle(pos + Vector2(0.85 * r, 0.3 * r), r * 0.85, base.lightened(0.12))
	draw_circle(pos + Vector2(-0.85 * r, 0.3 * r), r * 0.85, base.darkened(0.1))
	draw_circle(pos, r, base)


func _draw_start_highlight(d: CarDef) -> void:
	var cell := get_required_start_cell(d)
	var center := cell_to_world(cell.x, cell.y)
	var half := cell_size * 0.5
	var highlight := d.color
	highlight.a = 0.25
	draw_rect(Rect2(center - Vector2(half, half), Vector2(cell_size, cell_size)), highlight, true)


# A short dashed "driveway" from the house's road-cell destination out to
# where the building itself is drawn — marks exactly which cell the road
# needs to reach. _draw_path() draws a solid line over this same stretch
# once the player's road actually gets there, so the dash visually turns
# into part of the connected road.
func _draw_driveway(d: CarDef) -> void:
	var from: Vector2 = cell_to_world(d.house.x, d.house.y)
	var to: Vector2 = cell_to_world(d.house_cell.x, d.house_cell.y)
	var total := from.distance_to(to)
	if total <= 0.0:
		return
	var dir := (to - from) / total
	var dash_len := 6.0 * draw_scale
	var gap_len := 4.0 * draw_scale
	var muted := d.color
	muted.a = 0.55
	var travelled := 0.0
	while travelled < total:
		var seg_end: float = min(travelled + dash_len, total)
		draw_line(from + dir * travelled, from + dir * seg_end, muted, 4.0 * draw_scale)
		travelled += dash_len + gap_len


func _draw_path(d: CarDef) -> void:
	var cells: Array = paths.get(d.id, [])
	if cells.is_empty():
		return
	var pts := PackedVector2Array()
	pts.append(cell_to_world(d.entry.x, d.entry.y))
	for c in cells:
		pts.append(cell_to_world(c.x, c.y))
	if cells[-1] == d.house:
		pts.append(cell_to_world(d.house_cell.x, d.house_cell.y))
	draw_polyline(pts, Color(0.0, 0.0, 0.0, 0.55), 14.0 * draw_scale, true)
	draw_polyline(pts, d.color, 8.0 * draw_scale, true)
	for c in cells:
		draw_circle(cell_to_world(c.x, c.y), 5.0 * draw_scale, d.color)


# ---- Simulation ----

func _update_clock(minutes: int) -> void:
	clock_label.text = "Time: %s" % _format_time(minutes)


func _on_play_pressed() -> void:
	if state != State.DRAWING:
		return
	state = State.PLAYING
	play_button.disabled = true
	clear_button.disabled = true
	reset_button.hide()
	_update_nav_buttons()
	status_label.text = "Cars are on their way..."
	await _run_simulation()


# Expands a car's cell-by-cell route into a per-tick occupancy timeline: each
# move takes however many ticks that specific step costs (the car's own pace,
# or slower if a radar guards the cell being entered — see _move_ticks_for),
# dwelling at the source cell before jumping to the destination on the move's
# last tick. Since 1 tick = 1 in-game minute, this also doubles as exactly
# the timeline an arrive_by deadline gets checked against — including the
# tick index at which the car reaches its actual house (not house_cell).
func _expand_car_sequence(d: CarDef, raw: Array) -> Dictionary:
	var expanded := [raw[0]]
	var arrival_tick := -1
	for i in range(1, raw.size()):
		var ticks: int = _move_ticks_for(d, raw[i])
		for _k in range(ticks - 1):
			expanded.append(raw[i - 1])
		expanded.append(raw[i])
		if raw[i] == d.house and arrival_tick == -1:
			arrival_tick = expanded.size() - 1
	return {"sequence": expanded, "arrival_tick": arrival_tick}


func _run_simulation() -> void:
	# Each car's own timeline runs straight from its entry, along its drawn
	# road, and on into its house — house_cell is a private, non-road cell no
	# other car's path can ever touch, so a car that finishes early keeps
	# going into its driveway immediately instead of idling in the street
	# until every other car has also arrived. A car that was drawn past its
	# fuel limit gets its road truncated right there — it never gets the
	# house_cell leg, so it just stops and stays put on the street.
	var sequences := {}
	var arrival_ticks := {}
	var ran_out_of_fuel := {}
	var active_tweens: Dictionary = {}
	for d in car_defs:
		var drawn: Array = paths[d.id]
		var out_of_fuel: bool = d.fuel >= 0 and drawn.size() > d.fuel
		ran_out_of_fuel[d.id] = out_of_fuel
		var effective_path: Array = drawn.slice(0, d.fuel) if out_of_fuel else drawn

		var raw: Array = [d.entry]
		raw.append_array(effective_path)
		if not out_of_fuel:
			raw.append(d.house_cell)

		var expanded := _expand_car_sequence(d, raw)
		sequences[d.id] = expanded.sequence
		arrival_ticks[d.id] = expanded.arrival_tick

		# One continuous tween per car, legs chained in order — each leg's own
		# duration already reflects that specific move's speed (car's own pace,
		# or a radar's slower limit), and chaining guarantees they always play
		# strictly one-after-another, which is what keeps this glitch-free: a
		# fresh tween created mid-loop for every move (the old approach) could
		# start before the previous, slower move's tween had actually finished.
		#
		# Easing is only applied where the speed actually changes — pulling
		# away from a stop, into/out of a radar zone, parking at the house —
		# not on every leg uniformly, or consecutive same-speed legs would
		# each decelerate and reaccelerate at their shared cell boundary
		# instead of flowing through it at a constant pace.
		var leg_ticks: Array = []
		for i in range(1, raw.size()):
			leg_ticks.append(_move_ticks_for(d, raw[i]))

		var tw := create_tween()
		for i in range(leg_ticks.size()):
			var target: Vector2 = cell_to_world(raw[i + 1].x, raw[i + 1].y)
			var duration: float = STEP_DURATION * leg_ticks[i]
			var ease_in: bool = i == 0 or leg_ticks[i] != leg_ticks[i - 1]
			var ease_out: bool = i == leg_ticks.size() - 1 or leg_ticks[i] != leg_ticks[i + 1]
			var tweener := tw.tween_property(car_nodes[d.id], "position", target, duration)
			if ease_in and ease_out:
				tweener.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			elif ease_in:
				tweener.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
			elif ease_out:
				tweener.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		active_tweens[d.id] = tw

	var max_len := 0
	for id in sequences.keys():
		max_len = max(max_len, sequences[id].size())
	for id in sequences.keys():
		var seq: Array = sequences[id]
		while seq.size() < max_len:
			seq.append(seq[-1])

	_update_clock(level_start_minutes)

	var crashed := false
	var step := 1
	while step < max_len and not crashed:
		# A head-on swap (two cars crossing the same edge from opposite ends in
		# the same step) never shares a cell at a tick boundary, so it has to be
		# caught before moving — otherwise the cars just slide through each other.
		var swap_pos = null
		for i in range(car_defs.size()):
			for j in range(i + 1, car_defs.size()):
				var a: CarDef = car_defs[i]
				var b: CarDef = car_defs[j]
				var a_prev: Vector2i = sequences[a.id][step - 1]
				var a_next: Vector2i = sequences[a.id][step]
				var b_prev: Vector2i = sequences[b.id][step - 1]
				var b_next: Vector2i = sequences[b.id][step]
				if a_prev != a_next and a_next == b_prev and b_next == a_prev:
					swap_pos = cell_to_world(a_prev.x, a_prev.y).lerp(cell_to_world(a_next.x, a_next.y), 0.5)

		if swap_pos != null:
			_kill_tweens(active_tweens)
			for d in car_defs:
				var seq: Array = sequences[d.id]
				if seq[step] != seq[step - 1]:
					var tw := create_tween()
					tw.tween_property(car_nodes[d.id], "position", swap_pos, STEP_DURATION * 0.5)
			await get_tree().create_timer(STEP_DURATION * 0.5).timeout
			crashed = true
			_spawn_crash_marker(swap_pos)
			break

		await get_tree().create_timer(STEP_DURATION).timeout
		_update_clock(level_start_minutes + step * MINUTES_PER_TICK)

		var occupied := {}
		for d in car_defs:
			var cell: Vector2i = sequences[d.id][step]
			if occupied.has(cell):
				crashed = true
				_kill_tweens(active_tweens)
				_spawn_crash_marker(cell_to_world(cell.x, cell.y))
				break
			occupied[cell] = true
		step += 1

	clear_button.disabled = false
	if crashed:
		state = State.CRASHED
		status_label.text = "Crash! The cars collided. Press Reset to try again."
		reset_button.show()
	else:
		violations = _collect_violations(ran_out_of_fuel, arrival_ticks)
		if violations.size() > 0:
			state = State.FAILED
			status_label.text = "Trouble on the road — see the notes below. Press Reset to try again."
			reset_button.show()
		else:
			state = State.WON
			if current_level_index + 1 < LEVELS.size():
				status_label.text = "You win! Press Next to continue."
			else:
				status_label.text = "You win! All levels complete."
	_update_nav_buttons()
	overlay.queue_redraw()


# Checked only now, after the drive, instead of gating Play — see
# _apply_drag_point()'s comment for why. Each message is written as what
# actually happened, not as a rule restated.
func _collect_violations(ran_out_of_fuel: Dictionary, arrival_ticks: Dictionary) -> Dictionary:
	var result := {}
	for d in car_defs:
		var msgs: Array = []
		if ran_out_of_fuel[d.id]:
			msgs.append("Ran out of fuel")
		for cond in d.conditions:
			match cond.type:
				"avoid_car":
					var other_path: Array = paths[cond.other]
					for c in paths[d.id]:
						if other_path.has(c):
							msgs.append("Crossed %s's road" % _get_car_def(cond.other).id.capitalize())
							break
				"avoid_building":
					var lm = _find_landmark(cond.name)
					if lm != null and paths[d.id].has(lm.road_cell):
						msgs.append("Drove past the %s" % cond.name)
				"require_building":
					var lm2 = _find_landmark(cond.name)
					if lm2 == null or not paths[d.id].has(lm2.road_cell):
						msgs.append("Never passed by the %s" % cond.name)
				"arrive_by":
					# Already covered by the fuel message above if that's why
					# it never got home — no need to say "never arrived" twice.
					if not ran_out_of_fuel[d.id]:
						var arrival: int = arrival_ticks[d.id]
						if arrival == -1:
							msgs.append("Never made it home")
						else:
							var arrival_time: int = level_start_minutes + arrival
							if arrival_time > cond.minutes:
								msgs.append("Arrived at %s, needed %s" % [_format_time(arrival_time), _format_time(cond.minutes)])
		if msgs.size() > 0:
			result[d.id] = msgs
	return result


# Stops every car's chained movement tween in place. Needed on a crash since
# the whole journey is scheduled up front — without this, cars not directly
# involved in the collision would keep gliding toward their house in the
# background even after the simulation has already ended.
func _kill_tweens(tweens: Dictionary) -> void:
	for id in tweens.keys():
		if is_instance_valid(tweens[id]):
			tweens[id].kill()


func _spawn_crash_marker(world_pos: Vector2) -> void:
	var marker := Node2D.new()
	marker.position = world_pos
	add_child(marker)
	var half := cell_size * 0.3
	for diag in [[Vector2(-half, -half), Vector2(half, half)], [Vector2(-half, half), Vector2(half, -half)]]:
		var line := Line2D.new()
		line.add_point(diag[0])
		line.add_point(diag[1])
		line.width = 6.0 * draw_scale
		line.default_color = Color.RED
		marker.add_child(line)
	get_tree().create_timer(2.0).timeout.connect(marker.queue_free)


# ---- Reset / Clear / Next / Prev ----

# Prev/Next are always visible so the player can browse levels freely without
# completing one first — but disabled at the ends of the list, and while a
# simulation is actively playing (jumping levels mid-sim would leave the old
# _run_simulation() coroutine still suspended on a timer; it would resume
# later holding stale state/UI for a level the player has since left).
func _update_nav_buttons() -> void:
	var busy: bool = state == State.PLAYING
	prev_button.disabled = busy or current_level_index <= 0
	next_button.disabled = busy or current_level_index + 1 >= LEVELS.size()


func _reset_board(clear_paths: bool) -> void:
	if clear_paths:
		for d in car_defs:
			paths[d.id] = []
	state = State.DRAWING
	drawing_car_id = ""
	violations = {}
	for d in car_defs:
		car_nodes[d.id].position = cell_to_world(d.entry.x, d.entry.y)
	reset_button.hide()
	clear_button.disabled = false
	_update_clock(level_start_minutes)
	_update_nav_buttons()
	_check_ready()
	_redraw_all()


func _on_reset_pressed() -> void:
	_reset_board(false)


func _on_clear_pressed() -> void:
	_reset_board(true)


func _on_next_pressed() -> void:
	if current_level_index + 1 < LEVELS.size():
		_load_level(current_level_index + 1)


func _on_prev_pressed() -> void:
	if current_level_index > 0:
		_load_level(current_level_index - 1)
