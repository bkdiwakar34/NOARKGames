extends RefCounted

# Table-space geometry for the clinic study (docs/clinic_study_interface.md §3.4).
# Targets are placed and hit-tested in table millimetres; the screen only draws.
#
# The tracker sends the grip position in metres in the origin-lock frame, and
# the table plane is x-z (pyscripts/main.py, _placement), so
#     hand (mm) = 1000 * (raw_x, raw_z)
# Drawing goes through WorkspaceConfig's 4-corner affine (metres -> px). That
# affine may scale x and y differently, so a circle in mm can be a slight
# ellipse on screen — which is correct: the hand still covers W mm.

# Used when the 4-corner mapping has not been done (mouse-only development):
# 3 px per mm, table origin at the screen centre.
const FALLBACK_PX_PER_MM := 3.0

var mapped: bool = false
var _m: Transform2D     # table mm -> screen px
var _inv: Transform2D   # screen px -> table mm


func _init(viewport_size: Vector2) -> void:
	if WorkspaceConfig.sensor_calibrated:
		var a: Array = WorkspaceConfig.affine[0]
		var b: Array = WorkspaceConfig.affine[1]
		# Transform2D(x column, y column, origin); /1000 turns px-per-metre into px-per-mm.
		_m = Transform2D(Vector2(a[0], b[0]) / 1000.0, Vector2(a[1], b[1]) / 1000.0,
			Vector2(a[2], b[2]))
		mapped = true
	else:
		_m = Transform2D(Vector2(FALLBACK_PX_PER_MM, 0.0), Vector2(0.0, FALLBACK_PX_PER_MM),
			viewport_size * 0.5)
	_inv = _m.affine_inverse()


static func tracker_to_mm(raw_x: float, raw_z: float) -> Vector2:
	return Vector2(raw_x, raw_z) * 1000.0


func mm_to_screen(p: Vector2) -> Vector2:
	return _m * p


func screen_to_mm(s: Vector2) -> Vector2:
	return _inv * s


# Screen pixels per table mm along the table's x and y (the affine's column lengths).
func px_per_mm() -> Vector2:
	return Vector2(_m.x.length(), _m.y.length())


static func inside(hand: Vector2, centre: Vector2, w_mm: float) -> bool:
	return hand.distance_to(centre) <= w_mm * 0.5


# n screen points around a table circle (not closed: append [0] for a polyline).
func circle_outline(centre: Vector2, r_mm: float, n: int = 64) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var t := TAU * float(i) / float(n)
		pts.append(mm_to_screen(centre + Vector2(cos(t), sin(t)) * r_mm))
	return pts


# True when the whole table circle lands on screen, margin_px in from the edges.
func fits_on_screen(centre: Vector2, r_mm: float, viewport_size: Vector2, margin_px: float) -> bool:
	var rect := Rect2(Vector2.ZERO, viewport_size).grow(-margin_px)
	for p in circle_outline(centre, r_mm, 16):
		if not rect.has_point(p):
			return false
	return true
