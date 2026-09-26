extends RefCounted

# Catch and miss feedback for the fireflies (feedback design 2026-09-26, from
# osu!, Aim Lab, game-juice practice and rehab-game studies). Visual only:
# an apple — a firefly — is logged as caught or missed before its effect starts.
#   catch: hitstop (the firefly squashes and holds still, longer for a better
#          grade), then a flash, sparks, the grade's word ("Perfect!" +3 ...),
#          and it flies into the jar, which glows brighter as it fills;
#   miss:  the light dims, shrinks a little and sinks away;
#   round start: the jar's fireflies are let go.
# Screen pixels.

const Art := preload("res://app/clinic/game_art.gd")

const HITSTOP: Array = [0.08, 0.07, 0.10, 0.14]   # s, by grade (0 = play, no grade)
const FLY_S := 0.75
const JAR_SHOWN := 24                             # at most this many drawn inside

var jar: Rect2
var count: int = 0                                # fireflies in the jar this round

var _hit: Dictionary = {}       # the frozen moment: {pos, size, t, dur, grade}
var _flyers: Array = []         # {p0, c, p1, t}
var _sinkers: Array = []        # {pos, size, t}
var _sparks: Array = []         # {pos, vel, t, life, col, size}
var _flashes: Array = []        # {pos, size, t, col}
var _words: Array = []          # {pos, t, word, sub, col, big}
var _freed: Array = []          # {pos, vel, t}
var _t: float = 0.0


func _init(vp: Vector2) -> void:
	jar = Rect2(vp.x - 150.0, vp.y - 158.0, 104.0, 128.0)


func _mouth() -> Vector2:
	return Vector2(jar.get_center().x, jar.position.y + 18.0)


# Returns how long the hitstop lasts, so the next target waits for it.
func catch_at(pos: Vector2, size: Vector2, grade: int) -> float:
	var dur: float = HITSTOP[clampi(grade, 0, 3)]
	if not _hit.is_empty():
		_burst(_hit)
	_hit = {"pos": pos, "size": size, "t": 0.0, "dur": dur, "grade": grade}
	return dur


func miss_at(pos: Vector2, size: Vector2) -> void:
	_sinkers.append({"pos": pos, "size": size, "t": 0.0})


func word(pos: Vector2, text: String, sub: String, col: Color, big: int = 30) -> void:
	_words.append({"pos": pos, "t": 0.0, "word": text, "sub": sub, "col": col, "big": big})


# A firefly rising from pos (the closing card's gentle celebration).
func float_up(pos: Vector2) -> void:
	_freed.append({"pos": pos, "vel": Vector2(randf_range(-20.0, 20.0), randf_range(-70.0, -40.0)), "t": 0.0})


# Round start: the fireflies in the jar fly off into the night.
func release_jar() -> void:
	for i in mini(count, JAR_SHOWN):
		_freed.append({"pos": _jar_spot(i), "vel": Vector2(randf_range(-90.0, 30.0), randf_range(-160.0, -90.0)),
			"t": 0.0})
	count = 0


func _burst(h: Dictionary) -> void:
	var grade: int = h["grade"]
	var pos: Vector2 = h["pos"]
	var size: Vector2 = h["size"]
	var col: Color = Art.GRADE_COL[grade] if grade > 0 else Art.FF_GLOW
	_flashes.append({"pos": pos, "size": size, "t": 0.0, "col": col})
	var n := 10 + 6 * grade
	for i in n:
		var a := TAU * float(i) / float(n) + randf() * 0.3
		_sparks.append({"pos": pos, "vel": Vector2(cos(a), sin(a)) * randf_range(160.0, 260.0 + 60.0 * grade),
			"t": 0.0, "life": randf_range(0.45, 0.8), "size": randf_range(10.0, 18.0),
			"col": col if i % 2 == 0 else Art.FF_GLOW})
	if grade > 0:
		word(pos + Vector2(0.0, -size.y * 0.5 - 30.0), Art.GRADE_WORD[grade], "+%d" % grade, col,
			26 + 6 * grade)
	var end := _mouth()
	var ctrl := (pos + end) * 0.5 + Vector2(0.0, -160.0)
	_flyers.append({"p0": pos, "c": ctrl, "p1": end, "t": 0.0})


func update(dt: float) -> void:
	_t += dt
	if not _hit.is_empty():
		_hit["t"] += dt
		if float(_hit["t"]) >= float(_hit["dur"]):
			_burst(_hit)
			_hit = {}
	var keep: Array = []
	for f in _flyers:
		f["t"] += dt / FLY_S
		if float(f["t"]) >= 1.0:
			count += 1
		else:
			keep.append(f)
	_flyers = keep
	_sinkers = _aged(_sinkers, dt, 1.0)
	keep = []
	for s in _sparks:
		var vel: Vector2 = s["vel"] * maxf(0.0, 1.0 - 3.2 * dt) + Vector2(0.0, -30.0 * dt)
		s["vel"] = vel
		s["pos"] += vel * dt
		s["t"] += dt
		if float(s["t"]) < float(s["life"]):
			keep.append(s)
	_sparks = keep
	_flashes = _aged(_flashes, dt, 0.45)
	_words = _aged(_words, dt, 1.0)
	keep = []
	for f in _freed:
		f["pos"] += f["vel"] * dt
		f["t"] += dt
		if float(f["t"]) < 2.0:
			keep.append(f)
	_freed = keep


# Ages every item by dt and keeps those younger than life.
func _aged(items: Array, dt: float, life: float) -> Array:
	var keep: Array = []
	for it in items:
		it["t"] += dt
		if float(it["t"]) < life:
			keep.append(it)
	return keep


# Where the i-th firefly in the jar is now: a slow wander inside the glass.
func _jar_spot(i: int) -> Vector2:
	var inner := jar.grow(-18.0)
	inner.position.y += 16.0
	inner.size.y -= 16.0
	var fx := 0.5 + 0.42 * sin(_t * (0.6 + 0.07 * float(i % 5)) + float(i) * 1.9)
	var fy := 0.5 + 0.42 * cos(_t * (0.5 + 0.05 * float(i % 7)) + float(i) * 2.7)
	return inner.position + Vector2(fx, fy) * inner.size


# The jar behind the flying fireflies; its glow grows with what it holds.
func draw_jar(ci: CanvasItem) -> void:
	var tex := Art.glow()
	var fill := clampf(float(count) / 15.0, 0.0, 1.0)
	Art.blit(ci, tex, jar.get_center(), jar.size * (1.6 + 0.8 * fill), Color(Art.FF_GLOW, 0.10 + 0.35 * fill))
	ci.draw_style_box(Art._box(Color(0.75, 0.9, 1.0, 0.07), 22, Color(1, 1, 1, 0.28), 2),
		Rect2(jar.position + Vector2(0.0, 14.0), jar.size - Vector2(0.0, 14.0)))
	for i in mini(count, JAR_SHOWN):
		var blink := 0.55 + 0.45 * sin(_t * 2.3 + float(i) * 1.3)
		Art.blit(ci, tex, _jar_spot(i), Vector2(22.0, 22.0), Color(Art.FF_GLOW, blink))
		Art.blit(ci, Art.disc(), _jar_spot(i), Vector2(4.0, 4.0), Color(Art.FF_CORE, blink))
	ci.draw_line(jar.position + Vector2(14.0, 34.0), jar.position + Vector2(14.0, jar.size.y - 22.0),
		Color(1, 1, 1, 0.22), 3.0, true)
	ci.draw_style_box(Art._box(Color("3C4658"), 6, Color(1, 1, 1, 0.18), 1),
		Rect2(jar.position + Vector2(10.0, 0.0), Vector2(jar.size.x - 20.0, 16.0)))


func draw(ci: CanvasItem) -> void:
	var tex := Art.glow()
	for f in _freed:
		var a := 1.0 - float(f["t"]) / 2.0
		Art.blit(ci, tex, f["pos"], Vector2(20.0, 20.0), Color(Art.FF_GLOW, 0.8 * a))
	for s in _sinkers:
		var t: float = s["t"]
		var size: Vector2 = s["size"]
		var p: Vector2 = s["pos"] + Vector2(0.0, 50.0 * t * t)
		var k := 1.0 - 0.3 * t
		Art.blit(ci, Art.orb(), p, size * k, Color(Art.MISS, (1.0 - t) * 0.7))
	for fl in _flashes:
		var t: float = float(fl["t"]) / 0.45
		var size: Vector2 = fl["size"]
		Art.blit(ci, tex, fl["pos"], size * (1.2 + 2.6 * t), Color(fl["col"], 0.9 * (1.0 - t)))
		ci.draw_arc(fl["pos"], size.x * (0.5 + 0.9 * t), 0.0, TAU, 64, Color(fl["col"], 0.6 * (1.0 - t)), 3.0, true)
	if not _hit.is_empty():
		# The hitstop: squashed, extra bright, still.
		var size: Vector2 = _hit["size"]
		var p: Vector2 = _hit["pos"]
		Art.blit(ci, tex, p, size * 2.6, Color(Art.FF_GLOW, 0.6))
		Art.blit(ci, Art.orb(), p, Vector2(size.x * 1.16, size.y * 0.84))
		Art.blit(ci, Art.disc(), p, Vector2(size.x * 1.16, size.y * 0.84) * 0.9, Color(1, 1, 1, 0.85))
	for s in _sparks:
		var a := 1.0 - float(s["t"]) / float(s["life"])
		Art.blit(ci, tex, s["pos"], Vector2.ONE * float(s["size"]), Color(s["col"], a))
	for f in _flyers:
		var t: float = f["t"]
		var e := t * t * (3.0 - 2.0 * t)   # smoothstep: speeds up, then settles
		var p0: Vector2 = f["p0"]
		var c: Vector2 = f["c"]
		var p1: Vector2 = f["p1"]
		var p := p0.lerp(c, e).lerp(c.lerp(p1, e), e)
		for k in 4:   # a short trail
			var e2 := maxf(0.0, e - 0.04 * float(k + 1))
			var q := p0.lerp(c, e2).lerp(c.lerp(p1, e2), e2)
			Art.blit(ci, tex, q, Vector2.ONE * (16.0 - 3.0 * float(k)), Color(Art.FF_GLOW, 0.35 - 0.07 * float(k)))
		Art.blit(ci, tex, p, Vector2(30.0, 30.0), Color(Art.FF_GLOW, 0.9))
		Art.blit(ci, Art.disc(), p, Vector2(6.0, 6.0), Art.FF_CORE)
	for w in _words:
		var t: float = w["t"]
		var pop := 1.0 + 0.3 * maxf(0.0, 1.0 - t * 7.0)
		var a := clampf((1.0 - t) / 0.35, 0.0, 1.0)
		var p: Vector2 = w["pos"] + Vector2(0.0, -46.0 * t)
		var col: Color = w["col"]
		var big := int(float(w["big"]) * pop)
		Art.text(ci, p, w["word"], big, Color(col, a), Color(0.02, 0.03, 0.08, 0.55 * a))
		if String(w["sub"]) != "":
			Art.text(ci, p + Vector2(0.0, float(big) * 0.9), w["sub"], int(big * 0.7), Color(col, a),
				Color(0.02, 0.03, 0.08, 0.55 * a))
