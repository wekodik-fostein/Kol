class_name Character
extends CharacterBody3D
# Один персонаж: локальный игрок (касания/клавиатура), удалённый игрок или бот.

const SPEED := 6.5
const JUMP_VELOCITY := 6.5
const GRAVITY := 22.0
const MAX_HP := 100
const PLAYER_DAMAGE := 25
const BOT_DAMAGE := 10
const FIRE_RANGE := 120.0
const FIRE_COOLDOWN := 0.3
const BOT_COOLDOWN := 1.1
const BOT_RANGE := 45.0

var char_id := ""
var is_bot := false
var is_local := false
var hp := MAX_HP
var alive := true
var yaw := 0.0
var pitch := 0.0
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var sim        # main.gd (untyped, чтобы звать его методы)
var camera: Camera3D
var model: Node3D
var overlay: Control
var fire_cd := 0.0

# Ввод (только для локального игрока)
var move_touch := -1
var move_origin := Vector2.ZERO
var move_input := Vector2.ZERO
var look_touch := -1
var fire_touch := -1
var jump_touch := -1
var want_fire := false
var want_jump := false

# ИИ ботов (работает только на хосте)
var bot_target: Character
var bot_timer := 0.0
var bot_wander := Vector3.ZERO


func setup(main, id: String, bot: bool, local: bool, pos: Vector3) -> void:
	sim = main
	char_id = id
	is_bot = bot
	is_local = local
	global_position = pos
	net_pos = pos

	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)

	model = (load("res://assets/soldier.glb") as PackedScene).instantiate()
	add_child(model)
	_fit_model(model, 1.8)

	camera = Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	add_child(camera)
	camera.current = is_local
	model.visible = not is_local

	if is_local:
		var layer := CanvasLayer.new()
		add_child(layer)
		overlay = Control.new()
		overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.draw.connect(_draw_overlay)
		layer.add_child(overlay)


func _fit_model(root: Node3D, height: float) -> void:
	var box := AABB()
	for m in root.find_children("*", "MeshInstance3D", true, false):
		box = box.merge(m.get_aabb())
	if box.size.y > 0.0:
		var s := height / box.size.y
		root.scale = Vector3.ONE * s
		root.position.y = -box.position.y * s


# ---------- ПУБЛИЧНЫЕ МЕТОДЫ (зовёт main.gd) ----------

func set_net_state(pos: Vector3, y: float) -> void:
	net_pos = pos
	net_yaw = y


func set_hp(v: int) -> void:
	hp = v


func die() -> void:
	alive = false
	hp = 0
	collision_layer = 0
	velocity = Vector3.ZERO
	if model:
		model.visible = false


func respawn(pos: Vector3) -> void:
	alive = true
	hp = MAX_HP
	collision_layer = 1
	global_position = pos
	net_pos = pos
	velocity = Vector3.ZERO
	fire_cd = 0.0
	bot_target = null
	if model:
		model.visible = not is_local


# ---------- ФИЗИКА ----------

func _physics_process(delta: float) -> void:
	fire_cd = maxf(0.0, fire_cd - delta)
	if not alive:
		return
	if is_local:
		_local_update(delta)
	elif is_bot and sim.is_host:
		_bot_update(delta)
	else:
		# Удалённые игроки и боты на клиентах: плавно догоняем присланную позицию
		var k := minf(1.0, delta * 15.0)
		global_position = global_position.lerp(net_pos, k)
		rotation.y = lerp_angle(rotation.y, net_yaw, k)


func _process(_delta: float) -> void:
	if overlay:
		overlay.queue_redraw()


func _local_update(delta: float) -> void:
	rotation.y = yaw
	camera.rotation.x = pitch
	var input := (move_input + _keys()).limit_length(1.0)
	var dir := global_transform.basis * Vector3(input.x, 0.0, -input.y)
	var jump := want_jump or Input.is_key_pressed(KEY_SPACE)
	want_jump = false
	_move(dir, delta, jump)
	if (want_fire or Input.is_key_pressed(KEY_F)) and fire_cd <= 0.0:
		fire_cd = FIRE_COOLDOWN
		_shoot()


func _keys() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		v.y += 1.0
	if Input.is_key_pressed(KEY_S):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_D):
		v.x += 1.0
	if Input.is_key_pressed(KEY_A):
		v.x -= 1.0
	return v


func _move(dir: Vector3, delta: float, jump: bool) -> void:
	if is_on_floor():
		velocity.y = JUMP_VELOCITY if jump else 0.0
	else:
		velocity.y -= GRAVITY * delta
	velocity.x = dir.x * SPEED
	velocity.z = dir.z * SPEED
	move_and_slide()


func _shoot() -> void:
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * FIRE_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var target = hit.collider
	if target is Character and target.alive:
		sim.report_hit(target.char_id, PLAYER_DAMAGE, char_id)


# ---------- БОТ (только хост) ----------

func _bot_update(delta: float) -> void:
	bot_timer -= delta
	if bot_timer <= 0.0 or not is_instance_valid(bot_target) or not bot_target.alive:
		bot_timer = randf_range(0.6, 1.4)
		bot_target = sim.nearest_enemy(self)
		bot_wander = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()

	var dir := bot_wander
	if is_instance_valid(bot_target):
		var to := bot_target.global_position - global_position
		to.y = 0.0
		var dist := to.length()
		yaw = atan2(-to.x, -to.z)
		rotation.y = yaw
		dir = to.normalized() if dist > 6.0 else Vector3.ZERO
		if dist < BOT_RANGE and fire_cd <= 0.0 and _can_see(bot_target) and randf() < 0.6:
			fire_cd = BOT_COOLDOWN
			sim.report_hit(bot_target.char_id, BOT_DAMAGE, char_id)
	_move(dir, delta, false)


func _can_see(t: Character) -> bool:
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 1.5, 0),
		t.global_position + Vector3(0, 1.2, 0))
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	return hit.collider == t


# ---------- КАСАНИЯ / МЫШЬ ----------

func _input(event: InputEvent) -> void:
	if not is_local or not alive:
		return
	var vp := get_viewport().get_visible_rect().size
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			if _fire_rect(vp).has_point(e.position) and fire_touch == -1:
				fire_touch = e.index
				want_fire = true
			elif _jump_rect(vp).has_point(e.position) and jump_touch == -1:
				jump_touch = e.index
				want_jump = true
			elif e.position.x < vp.x * 0.5 and move_touch == -1:
				move_touch = e.index
				move_origin = e.position
			elif look_touch == -1:
				look_touch = e.index
		else:
			if e.index == fire_touch:
				fire_touch = -1
				want_fire = false
			if e.index == jump_touch:
				jump_touch = -1
			if e.index == move_touch:
				move_touch = -1
				move_input = Vector2.ZERO
			if e.index == look_touch:
				look_touch = -1
	elif event is InputEventScreenDrag:
		var e := event as InputEventScreenDrag
		if e.index == move_touch:
			var d := (e.position - move_origin) / 90.0
			move_input = d.limit_length(1.0) * Vector2(1, -1)
		elif e.index == look_touch:
			_look(e.relative * 0.005)
	elif event is InputEventMouseButton and not DisplayServer.is_touchscreen_available():
		var e := event as InputEventMouseButton
		if e.button_index == MOUSE_BUTTON_LEFT:
			want_fire = e.pressed
			if e.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look((event as InputEventMouseMotion).relative * 0.0025)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _look(d: Vector2) -> void:
	yaw -= d.x
	pitch = clampf(pitch - d.y, -1.4, 1.4)


func _fire_rect(vp: Vector2) -> Rect2:
	return Rect2(vp.x - 260, vp.y - 260, 200, 200)


func _jump_rect(vp: Vector2) -> Rect2:
	return Rect2(vp.x - 260, vp.y - 480, 200, 200)


func _draw_overlay() -> void:
	var vp := overlay.get_rect().size
	var f := _fire_rect(vp)
	var j := _jump_rect(vp)
	overlay.draw_rect(f, Color(1, 0.25, 0.2, 0.7 if fire_touch != -1 else 0.35))
	overlay.draw_rect(j, Color(0.3, 0.8, 1, 0.7 if jump_touch != -1 else 0.35))
	overlay.draw_string(ThemeDB.fallback_font, f.position + Vector2(40, 115), "FIRE",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 36)
	overlay.draw_string(ThemeDB.fallback_font, j.position + Vector2(40, 115), "JUMP",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 36)
	if move_touch != -1:
		overlay.draw_circle(move_origin, 90.0, Color(1, 1, 1, 0.12))
