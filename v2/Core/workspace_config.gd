extends Node

var workspace_min: Vector2 = Vector2.ZERO
var workspace_max: Vector2 = Vector2.ZERO
var is_calibrated: bool    = false

# Sensor-to-screen calibration as a 2D affine transform fitted from the
# 4 corner samples. Maps (raw_x, raw_z) → (screen_x, screen_y) via:
#     screen_x = affine[0][0]*raw_x + affine[0][1]*raw_z + affine[0][2]
#     screen_y = affine[1][0]*raw_x + affine[1][1]*raw_z + affine[1][2]
# Stored as a 2×3 row-major nested Array.
var sensor_calibrated: bool  = false
var affine: Array            = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]   # identity by default

const CONFIG_PATH: String = "user://workspace_config.json"


func _ready() -> void:
	_load()


func _load() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not f:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not data is Dictionary:
		return
	workspace_min = Vector2(data.get("min_x", 0.0), data.get("min_y", 0.0))
	workspace_max = Vector2(data.get("max_x", 0.0), data.get("max_y", 0.0))
	if workspace_max.x > workspace_min.x and workspace_max.y > workspace_min.y:
		is_calibrated = true

	if data.get("sensor_calibrated", false) and data.has("affine"):
		var loaded: Array = data["affine"]
		if loaded.size() == 2 and loaded[0].size() == 3 and loaded[1].size() == 3:
			affine = [
				[float(loaded[0][0]), float(loaded[0][1]), float(loaded[0][2])],
				[float(loaded[1][0]), float(loaded[1][1]), float(loaded[1][2])],
			]
			sensor_calibrated = true


func save_config(min_pos: Vector2, max_pos: Vector2) -> void:
	workspace_min = min_pos
	workspace_max = max_pos
	is_calibrated = true
	_write()


# raw_corners is an Array of 4 Vector2(raw_x, raw_z) in the order
# [top-left, top-right, bottom-left, bottom-right]. The function fits a
# 2D affine that maps those four samples to the corresponding viewport
# corners, so a straight motion on the table produces a straight motion
# on the screen even if the camera is tilted relative to the workspace.
func save_sensor_calibration(raw_corners: Array, vp_size: Vector2) -> void:
	if raw_corners.size() < 4:
		return
	var screen_corners: Array = [
		Vector2(0.0,       0.0),
		Vector2(vp_size.x, 0.0),
		Vector2(0.0,       vp_size.y),
		Vector2(vp_size.x, vp_size.y),
	]
	affine            = _fit_affine_2d(raw_corners, screen_corners)
	sensor_calibrated = true
	# Full viewport is now the workspace — scan will discover reachable cells within it
	workspace_min = Vector2.ZERO
	workspace_max = vp_size
	is_calibrated = true
	_write()


func _write() -> void:
	var data: Dictionary = {
		"min_x": workspace_min.x, "min_y": workspace_min.y,
		"max_x": workspace_max.x, "max_y": workspace_max.y,
		"sensor_calibrated": sensor_calibrated,
		"affine": affine,
	}
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()


func sensor_to_screen(rx: float, rz: float, _vp: Vector2) -> Vector2:
	var a: Array = affine[0]
	var b: Array = affine[1]
	return Vector2(
		a[0] * rx + a[1] * rz + a[2],
		b[0] * rx + b[1] * rz + b[2],
	)


# ── Affine fit (least-squares) ────────────────────────────────────────────────
# Fits sx = a*rx + b*rz + c and sy = d*rx + e*rz + f to the (src, dst) pairs
# via normal equations on the 3×3 system A^T A · θ = A^T b for each axis.
# With 4 input pairs the system is overdetermined by 1; least squares uses
# all four to minimise corner-fit error.

func _fit_affine_2d(src: Array, dst: Array) -> Array:
	var n00: float = 0.0
	var n01: float = 0.0
	var n02: float = 0.0
	var n11: float = 0.0
	var n12: float = 0.0
	var n22: float = 0.0
	var bx0: float = 0.0
	var bx1: float = 0.0
	var bx2: float = 0.0
	var by0: float = 0.0
	var by1: float = 0.0
	var by2: float = 0.0
	for i in src.size():
		var rx: float = src[i].x
		var rz: float = src[i].y
		var sx: float = dst[i].x
		var sy: float = dst[i].y
		n00 += rx * rx;  n01 += rx * rz;  n02 += rx
		n11 += rz * rz;  n12 += rz
		n22 += 1.0
		bx0 += rx * sx;  bx1 += rz * sx;  bx2 += sx
		by0 += rx * sy;  by1 += rz * sy;  by2 += sy

	var n: Array = [
		[n00, n01, n02],
		[n01, n11, n12],
		[n02, n12, n22],
	]
	var n_inv: Array = _invert_3x3(n)
	var abc: Array = _mat3_mul_vec3(n_inv, [bx0, bx1, bx2])
	var def: Array = _mat3_mul_vec3(n_inv, [by0, by1, by2])
	return [abc, def]


func _invert_3x3(m: Array) -> Array:
	var a: float = m[0][0]; var b: float = m[0][1]; var c: float = m[0][2]
	var d: float = m[1][0]; var e: float = m[1][1]; var f: float = m[1][2]
	var g: float = m[2][0]; var h: float = m[2][1]; var i: float = m[2][2]
	var det: float = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	if absf(det) < 1.0e-12:
		# Singular — return identity so calibration is recognisably wrong.
		return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	var inv_det: float = 1.0 / det
	return [
		[(e * i - f * h) * inv_det, (c * h - b * i) * inv_det, (b * f - c * e) * inv_det],
		[(f * g - d * i) * inv_det, (a * i - c * g) * inv_det, (c * d - a * f) * inv_det],
		[(d * h - e * g) * inv_det, (b * g - a * h) * inv_det, (a * e - b * d) * inv_det],
	]


func _mat3_mul_vec3(m: Array, v: Array) -> Array:
	return [
		m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
		m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
		m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
	]
