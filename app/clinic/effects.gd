extends RefCounted

# Visual-only physics for the participant screens (mockup: "caught apples fly
# into a basket and bounce; missed ones dull, fall, bounce and roll away"),
# plus particle bursts and the "+3" pops. Screen pixels, simple ballistic
# motion under GRAVITY. Nothing here touches the data: an apple is logged as
# caught or missed before its effect starts.

const Art := preload("res://app/clinic/game_art.gd")

const GRAVITY := 1500.0     # px / s², logical 1152 x 648 screen
const FLY_S := 0.8          # flight time from the catch to the basket
const PILE_MAX := 9

var basket: Rect2           # the basket's body, px
var ground_y: float         # where missed apples land
var pile: int = 0           # apples resting in the basket

var _flyers: Array = []     # caught apples on their way: {pos, vel, rot, spin, r, tones, bounced}
var _fallers: Array = []    # missed apples: {pos, vel, rot, r, t, bounces}
var _parts: Array = []      # {pos, vel, t, life, col, leaf, size, rot, spin, g}
var _pops: Array = []       # {pos, t, text}


func _init(vp: Vector2) -> void:
	basket = Rect2(vp.x - 190.0, vp.y - 92.0, 150.0, 76.0)
	ground_y = vp.y * 0.935


func _rim() -> Vector2:
	return Vector2(basket.get_center().x, basket.position.y + 4.0)


# A caught apple: it flies into the basket (aimed to arrive in FLY_S), with a
# burst of leaves and juice and an optional "+3".
func catch_at(pos: Vector2, r: float, tones: Array, pop_text: String) -> void:
	var target := _rim() + Vector2(randf_range(-30.0, 30.0), -6.0)
	var vel := (target - pos - Vector2(0.0, 0.5 * GRAVITY * FLY_S * FLY_S)) / FLY_S
	_flyers.append({"pos": pos, "vel": vel, "rot": 0.0, "spin": randf_range(4.0, 7.0),
		"r": r, "tones": tones, "bounced": false, "t": 0.0})
	for i in 14:
		var a := randf() * TAU
		var leaf := i % 3 == 0
		_parts.append({"pos": pos, "vel": Vector2(cos(a), sin(a) - 0.6) * randf_range(140.0, 320.0),
			"t": 0.0, "life": randf_range(0.6, 1.0), "leaf": leaf, "g": GRAVITY * 0.6,
			"col": Art.LEAF if leaf else Color("FFD45A").lerp(Color("FFB23D"), randf()),
			"size": randf_range(6.0, 10.0) if leaf else randf_range(2.5, 5.0),
			"rot": randf() * TAU, "spin": randf_range(-8.0, 8.0)})
	if pop_text != "":
		_pops.append({"pos": pos + Vector2(0.0, -r - 16.0), "t": 0.0, "text": pop_text})


# A missed apple: it dulls, drops to the grass, bounces twice and rolls away.
func miss_at(pos: Vector2, r: float) -> void:
	_fallers.append({"pos": pos, "vel": Vector2(randf_range(-30.0, 30.0), -60.0), "rot": 0.0,
		"r": r, "t": 0.0, "bounces": 0})


# Slowly falling leaves (session complete).
func leaf_shower(vp: Vector2) -> void:
	_parts.append({"pos": Vector2(randf() * vp.x, -20.0), "vel": Vector2(randf_range(-30.0, 30.0), 70.0),
		"t": 0.0, "life": 9.0, "leaf": true, "g": 0.0, "size": randf_range(7.0, 11.0),
		"col": [Art.LEAF, Color("E6A92A"), Color("CC3524"), Color("7DBE55")].pick_random(),
		"rot": randf() * TAU, "spin": randf_range(-2.0, 2.0)})


func update(dt: float) -> void:
	var keep: Array = []
	var rim_y: float = _rim().y
	for f in _flyers:
		var vel: Vector2 = f["vel"] + Vector2(0.0, GRAVITY * dt)
		var pos: Vector2 = f["pos"] + vel * dt
		f["t"] += dt
		f["rot"] += f["spin"] * dt
		if float(f["t"]) > 0.3 and pos.y >= rim_y and vel.y > 0.0:
			if f["bounced"]:
				pile = mini(pile + 1, PILE_MAX)   # settles into the pile
				continue
			f["bounced"] = true                  # one small bounce off the rim
			pos.y = rim_y
			vel = Vector2(vel.x * 0.25, -vel.y * 0.28)
			f["spin"] = float(f["spin"]) * 0.3
		f["vel"] = vel
		f["pos"] = pos
		keep.append(f)
	_flyers = keep

	keep = []
	for f in _fallers:
		var r: float = f["r"]
		var vel: Vector2 = f["vel"] + Vector2(0.0, GRAVITY * dt)
		var pos: Vector2 = f["pos"] + vel * dt
		f["t"] += dt
		if pos.y >= ground_y - r and vel.y > 0.0:
			pos.y = ground_y - r
			if int(f["bounces"]) < 2:
				vel.y = -vel.y * 0.38
				f["bounces"] += 1
				if absf(vel.x) < 40.0:
					vel.x = 90.0 if randf() < 0.5 else -90.0
			else:
				vel.y = 0.0
				vel.x *= maxf(0.0, 1.0 - 1.1 * dt)   # rolling friction
		f["rot"] += vel.x / r * dt                 # rolling without slipping
		f["vel"] = vel
		f["pos"] = pos
		if float(f["t"]) < 2.6:
			keep.append(f)
	_fallers = keep

	keep = []
	for p in _parts:
		var vel: Vector2 = p["vel"] + Vector2(0.0, float(p["g"]) * dt)
		p["vel"] = vel
		p["pos"] += vel * dt
		p["t"] += dt
		p["rot"] += p["spin"] * dt
		if float(p["t"]) < float(p["life"]):
			keep.append(p)
	_parts = keep

	keep = []
	for p in _pops:
		p["t"] += dt
		if p["t"] < 0.9:
			keep.append(p)
	_pops = keep


func draw_basket(ci: CanvasItem) -> void:
	var b := basket
	var rim := _rim()
	ci.draw_set_transform(Vector2(b.get_center().x, b.end.y + 4.0), 0.0, Vector2(b.size.x * 0.55, 8.0))
	ci.draw_circle(Vector2.ZERO, 1.0, Color(0.1, 0.15, 0.05, 0.3))
	ci.draw_set_transform(rim, 0.0, Vector2(b.size.x * 0.5, 13.0))
	ci.draw_circle(Vector2.ZERO, 1.0, Color("5E3719"))
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# The pile: apples resting in the basket's mouth.
	var slots: Array = [[-40, 2], [0, 0], [40, 2], [-20, -12], [20, -12], [-58, 6], [58, 6], [0, -22], [-38, -18]]
	for i in pile:
		var s: Array = slots[i]
		Art.draw_apple(ci, rim + Vector2(s[0], s[1] - 8.0), 17.0, Art.RED if i % 3 != 1 else Art.RIPE_GOLD,
			0.25 * sin(float(i) * 2.1))


func draw_basket_front(ci: CanvasItem) -> void:
	var b := basket
	var body := PackedVector2Array([b.position, Vector2(b.end.x, b.position.y),
		Vector2(b.end.x - 16.0, b.end.y), Vector2(b.position.x + 16.0, b.end.y)])
	ci.draw_polygon(body, PackedColorArray([Color("CC9254"), Color("CC9254"), Color("7A4820"), Color("7A4820")]))
	for i in 3:
		var y := b.position.y + b.size.y * (0.3 + 0.25 * float(i))
		var inset := 16.0 * (y - b.position.y) / b.size.y
		ci.draw_line(Vector2(b.position.x + inset + 2.0, y), Vector2(b.end.x - inset - 2.0, y),
			Color(0.37, 0.2, 0.09, 0.55), 2.5, true)
	for i in 5:
		var x := b.position.x + b.size.x * (0.15 + 0.175 * float(i))
		ci.draw_line(Vector2(x, b.position.y + 4.0), Vector2(x + (b.get_center().x - x) * 0.2, b.end.y - 2.0),
			Color(0.37, 0.2, 0.09, 0.4), 2.0, true)
	ci.draw_line(b.position, Vector2(b.end.x, b.position.y), Color("E0A86C"), 7.0, true)


func draw(ci: CanvasItem) -> void:
	for f in _flyers:
		Art.draw_apple(ci, f["pos"], f["r"], f["tones"], f["rot"])
	for f in _fallers:
		var fade := clampf((2.6 - float(f["t"])) / 0.8, 0.0, 1.0)
		Art.draw_apple(ci, f["pos"], f["r"], Art.DULL, f["rot"], fade)
	for p in _parts:
		var a := clampf(1.0 - float(p["t"]) / float(p["life"]), 0.0, 1.0)
		if p["leaf"]:
			ci.draw_set_transform(p["pos"], p["rot"], Vector2(p["size"], p["size"] * 0.45))
			ci.draw_circle(Vector2.ZERO, 1.0, Color(p["col"], a))
			ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			ci.draw_circle(p["pos"], p["size"], Color(p["col"], a))
	for p in _pops:
		var t: float = p["t"]
		var rise := 60.0 * t
		var s := 1.0 + 0.25 * maxf(0.0, 1.0 - t * 6.0)
		var a := clampf(1.0 - (t - 0.5) / 0.4, 0.0, 1.0)
		var pos: Vector2 = p["pos"] + Vector2(0.0, -rise)
		Art.text(ci, pos + Vector2(0.0, 3.0), p["text"], int(34 * s), Color(0.66, 0.42, 0.0, a))
		Art.text(ci, pos, p["text"], int(34 * s), Color(Art.GOLD, a))
