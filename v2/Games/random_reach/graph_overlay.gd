extends Control

signal closed

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()

func _build_ui() -> void:
	var vp := get_viewport_rect().size

	var btn := Button.new()
	btn.text = "Back to menu"
	btn.custom_minimum_size = Vector2(170.0, 44.0)
	btn.position = Vector2(vp.x * 0.5 - 85.0, vp.y - 52.0)
	btn.pressed.connect(func(): closed.emit())
	add_child(btn)

func _draw() -> void:
	var size := get_rect().size
	var font := ThemeDB.fallback_font
	var fs := ThemeDB.fallback_font_size

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.05, 0.12, 0.92))

	var log: Array = AdaptiveManager.outcome_log
	var trial_log: Array = AdaptiveManager.trial_log
	var lmin: float = AdaptiveManager.LIFETIME_MIN
	var lmax: float = AdaptiveManager.LIFETIME_MAX
	var target: float = AdaptiveManager.assigned_rate
	var n_catch := 0
	var n_miss := 0
	for e in log:
		if e["hit"] == 1: n_catch += 1
		else: n_miss += 1

	# Title
	draw_string(font, Vector2(0, 34), "Session summary",
		HORIZONTAL_ALIGNMENT_CENTER, int(size.x), 20, Color(0.90, 0.95, 1.0))

	# Stats
	var stats := "caught: %d   missed: %d   target: %d%%" % [n_catch, n_miss, int(target * 100)]
	draw_string(font, Vector2(0, 60), stats,
		HORIZONTAL_ALIGNMENT_CENTER, int(size.x - 180), fs, Color(0.65, 0.75, 0.92))

	# Legend (top-right)
	var leg_x: float = size.x - 170.0
	draw_circle(Vector2(leg_x, 50), 5.0, Color(0.18, 0.88, 0.32))
	draw_string(font, Vector2(leg_x + 10, 56),
		"caught", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.18, 0.88, 0.32))
	draw_circle(Vector2(leg_x + 80, 50), 5.0, Color(0.95, 0.20, 0.16))
	draw_string(font, Vector2(leg_x + 90, 56),
		"missed", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.95, 0.20, 0.16))

	# --- Graph 1: Apple lifetime ---
	var gx := 72.0
	var gy := 82.0
	var gw := size.x - gx - 32.0
	var gh := size.y * 0.34

	draw_rect(Rect2(gx, gy, gw, gh), Color(0.07, 0.09, 0.16, 1.0))
	draw_rect(Rect2(gx, gy, gw, gh), Color(0.28, 0.32, 0.52, 0.85), false, 1.5)

	for yi in range(6):
		var t := float(yi) / 5.0
		var lt_val: float = lmin + t * (lmax - lmin)
		var py := gy + gh - t * gh
		var grid_alpha := 0.45 if yi > 0 else 0.85
		draw_line(Vector2(gx, py), Vector2(gx + gw, py),
			Color(0.25, 0.28, 0.44, grid_alpha), 1.0)
		draw_string(font, Vector2(4.0, py + 5.0), "%.1fs" % lt_val,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.60, 0.68, 0.85))

	draw_string(font, Vector2(4.0, gy - 10.0), "lifetime",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.50, 0.56, 0.72))
	draw_string(font, Vector2(gx + gw * 0.5 - 24, gy + gh + 16),
		"apple #", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.50, 0.56, 0.72))

	draw_line(Vector2(gx, gy + gh), Vector2(gx + gw, gy + gh), Color(0.38, 0.42, 0.62), 1.5)
	draw_line(Vector2(gx, gy), Vector2(gx, gy + gh), Color(0.38, 0.42, 0.62), 1.5)

	if log.is_empty():
		draw_string(font, Vector2(gx + gw * 0.5 - 50, gy + gh * 0.5),
			"No data yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.45, 0.50, 0.65))
	else:
		var start_lt: float = lerp(lmax, lmin, 0.5)
		var ref_py: float = gy + gh - ((start_lt - lmin) / (lmax - lmin)) * gh
		draw_dashed_line(Vector2(gx, ref_py), Vector2(gx + gw, ref_py),
			Color(1.0, 0.82, 0.28, 0.50), 1.5, 10.0)
		draw_string(font, Vector2(gx + gw - 38, ref_py - 14), "start",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, Color(1.0, 0.82, 0.28, 0.75))

		var n: int = log.size()
		var prev_p: Vector2 = Vector2.ZERO
		for i in range(n):
			var entry: Dictionary = log[i]
			var lt: float = float(entry["lt"])
			var px: float = gx + (float(i) / max(float(n - 1), 1.0)) * gw
			var py: float = gy + gh - ((lt - lmin) / (lmax - lmin)) * gh
			px = clamp(px, gx, gx + gw)
			py = clamp(py, gy, gy + gh)
			var p: Vector2 = Vector2(px, py)
			if i > 0:
				draw_line(prev_p, p, Color(0.52, 0.62, 0.95, 0.65), 2.0)
			var dot_col: Color = Color(0.18, 0.88, 0.32) if entry["hit"] == 1 else Color(0.95, 0.20, 0.16)
			draw_circle(p, 5.5, dot_col)
			prev_p = p

	# --- Graph 2: Per-trial success rate ---
	var gy2: float = gy + gh + 44.0
	var gh2: float = size.y * 0.26

	draw_string(font, Vector2(gx, gy2 - 14.0), "Success rate per trial",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.50, 0.56, 0.72))

	draw_rect(Rect2(gx, gy2, gw, gh2), Color(0.07, 0.09, 0.16, 1.0))
	draw_rect(Rect2(gx, gy2, gw, gh2), Color(0.28, 0.32, 0.52, 0.85), false, 1.5)

	for yi in range(6):
		var t := float(yi) / 5.0
		var grid_py := gy2 + gh2 - t * gh2
		var grid_alpha := 0.45 if yi > 0 else 0.85
		draw_line(Vector2(gx, grid_py), Vector2(gx + gw, grid_py),
			Color(0.25, 0.28, 0.44, grid_alpha), 1.0)
		draw_string(font, Vector2(4.0, grid_py + 5.0), "%d%%" % int(t * 100),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.60, 0.68, 0.85))

	draw_line(Vector2(gx, gy2 + gh2), Vector2(gx + gw, gy2 + gh2), Color(0.38, 0.42, 0.62), 1.5)
	draw_line(Vector2(gx, gy2), Vector2(gx, gy2 + gh2), Color(0.38, 0.42, 0.62), 1.5)

	# Target rate dashed line
	var target_py: float = gy2 + gh2 - target * gh2
	draw_dashed_line(Vector2(gx, target_py), Vector2(gx + gw, target_py),
		Color(1.0, 0.65, 0.10, 0.70), 1.5, 10.0)
	draw_string(font, Vector2(gx + gw - 62, target_py - 14), "%d%% target" % int(target * 100),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, Color(1.0, 0.65, 0.10, 0.90))

	if trial_log.is_empty():
		draw_string(font, Vector2(gx + gw * 0.5 - 50, gy2 + gh2 * 0.5),
			"No trial data yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.45, 0.50, 0.65))
	else:
		var nt: int = trial_log.size()
		var prev_tp: Vector2 = Vector2.ZERO
		for i in range(nt):
			var tentry: Dictionary = trial_log[i]
			var rate: float = float(tentry["rate"])
			var tpx: float = gx + (float(i) / max(float(nt - 1), 1.0)) * gw
			var tpy: float = gy2 + gh2 - rate * gh2
			tpx = clamp(tpx, gx, gx + gw)
			tpy = clamp(tpy, gy2, gy2 + gh2)
			var tp: Vector2 = Vector2(tpx, tpy)
			if i > 0:
				draw_line(prev_tp, tp, Color(0.95, 0.75, 0.30, 0.80), 2.0)
			draw_circle(tp, 5.5, Color(1.0, 0.85, 0.30))
			prev_tp = tp
