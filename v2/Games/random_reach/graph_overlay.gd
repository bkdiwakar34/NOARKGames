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
	draw_string(font, Vector2(4.0, gy - 10.0), "lifetime (s)",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.50, 0.56, 0.72))
	draw_string(font, Vector2(gx + gw * 0.5 - 24, gy + gh + 16),
		"apple #", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.50, 0.56, 0.72))
	draw_line(Vector2(gx, gy + gh), Vector2(gx + gw, gy + gh), Color(0.38, 0.42, 0.62), 1.5)
	draw_line(Vector2(gx, gy), Vector2(gx, gy + gh), Color(0.38, 0.42, 0.62), 1.5)

	if log.is_empty():
		draw_string(font, Vector2(gx + gw * 0.5 - 50, gy + gh * 0.5),
			"No data yet", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.45, 0.50, 0.65))
	else:
		var n: int = log.size()

		# Extract threshold first so it can be included in the Y range
		var lt_thr: float = -1.0
		for te1 in trial_log:
			if te1.has("lt_threshold"):
				lt_thr = float(te1.get("lt_threshold"))
				break

		# Data-adaptive Y range
		var y_lo: float = lmax
		var y_hi: float = lmin
		for e in log:
			var lt: float = float(e["lt"])
			y_lo = min(y_lo, lt)
			y_hi = max(y_hi, lt)
		if lt_thr > lmin:
			y_lo = min(y_lo, lt_thr)
			y_hi = max(y_hi, lt_thr)
		var y_span: float = max(y_hi - y_lo, 0.5)
		var pad: float = y_span * 0.15
		y_lo = max(lmin, y_lo - pad)
		y_hi = min(lmax, y_hi + pad)

		# Grid lines at nice tick intervals
		var tick_step: float = _nice_step(y_hi - y_lo)
		var tick_v: float = ceil(y_lo / tick_step) * tick_step
		while tick_v <= y_hi + tick_step * 0.01:
			var t_frac: float = (tick_v - y_lo) / (y_hi - y_lo)
			var py: float = gy + gh - t_frac * gh
			draw_line(Vector2(gx, py), Vector2(gx + gw, py),
				Color(0.25, 0.28, 0.44, 0.35), 1.0)
			draw_string(font, Vector2(4.0, py + 5.0), "%.1f" % tick_v,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.60, 0.68, 0.85))
			tick_v += tick_step

		# Threshold line
		if lt_thr > lmin:
			var thr_x: float = gx
			for ti1 in range(trial_log.size()):
				if int(trial_log[ti1].get("trial", 1)) >= 2:
					thr_x = gx + float(int(trial_log[ti1].get("apple_start", 0))) / float(max(n - 1, 1)) * gw
					break
			var thr_py: float = clamp(gy + gh - ((lt_thr - y_lo) / (y_hi - y_lo)) * gh, gy, gy + gh)
			draw_dashed_line(Vector2(thr_x, thr_py), Vector2(gx + gw, thr_py),
				Color(1.0, 0.60, 0.18, 0.65), 1.5, 8.0)
			draw_string(font, Vector2(gx + gw - 72, thr_py - 12), "threshold",
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, Color(1.0, 0.60, 0.18, 0.80))

		# Trial sampling bands
		for ti2 in range(trial_log.size()):
			var te2: Dictionary = trial_log[ti2]
			if not te2.has("lt_lo") or not te2.has("lt_hi"):
				continue
			var band_lo: float = float(te2.get("lt_lo"))
			var band_hi: float = float(te2.get("lt_hi"))
			if band_lo <= lmin and band_hi >= lmax:
				continue
			var a_start: int = int(te2.get("apple_start", 0))
			var a_end: int = int(trial_log[ti2 + 1].get("apple_start", n)) if ti2 + 1 < trial_log.size() else n
			if a_end <= a_start:
				continue
			var bx1: float = gx + float(a_start) / float(max(n - 1, 1)) * gw
			var bx2: float = gx + float(max(a_end - 1, a_start)) / float(max(n - 1, 1)) * gw
			var by_top: float = clamp(gy + gh - (band_hi - y_lo) / (y_hi - y_lo) * gh, gy, gy + gh)
			var by_bot: float = clamp(gy + gh - (band_lo - y_lo) / (y_hi - y_lo) * gh, gy, gy + gh)
			draw_rect(Rect2(bx1, by_top, bx2 - bx1, by_bot - by_top), Color(0.38, 0.72, 1.0, 0.08))
			draw_rect(Rect2(bx1, by_top, bx2 - bx1, by_bot - by_top), Color(0.38, 0.72, 1.0, 0.22), false, 1.0)

		# Connecting line + dots
		var prev_p: Vector2 = Vector2.ZERO
		for i in range(n):
			var entry: Dictionary = log[i]
			var lt: float = float(entry["lt"])
			var px: float = gx + (float(i) / max(float(n - 1), 1.0)) * gw
			var py: float = gy + gh - ((lt - y_lo) / (y_hi - y_lo)) * gh
			px = clamp(px, gx, gx + gw)
			py = clamp(py, gy, gy + gh)
			var p: Vector2 = Vector2(px, py)
			if i > 0:
				draw_line(prev_p, p, Color(0.52, 0.58, 0.82, 0.28), 1.5)
			var dot_col: Color = Color(0.38, 0.75, 0.48) if entry["hit"] == 1 else Color(0.88, 0.40, 0.32)
			draw_circle(p, 3.0, dot_col)
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
			draw_circle(tp, 4.0, Color(0.92, 0.78, 0.30))
			prev_tp = tp

func _nice_step(range_val: float) -> float:
	if range_val <= 0.0:
		return 0.5
	var raw: float = range_val / 6.0
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var norm: float = raw / mag
	if norm <= 1.5:   return 1.0 * mag
	elif norm <= 3.0: return 2.0 * mag
	elif norm <= 7.0: return 5.0 * mag
	return 10.0 * mag
