extends Node3D
# Главный скрипт: меню, LAN (ENet), спавн, урон, боты-хост.

const PORT := 7777
const MAX_PLAYERS := 8
const BOT_COUNT := 4
const RESPAWN_TIME := 3.0
const SPAWNS := [
	Vector3(0, 3, 0),
	Vector3(12, 3, 12),
	Vector3(-12, 3, 10),
	Vector3(10, 3, -14),
	Vector3(-14, 3, -12),
	Vector3(0, 3, -22),
]

var chars := {}          # id (String) -> Character
var is_host := false
var started := false
var net_timer := 0.0
var hud_msg := ""
var hud_msg_time := 0.0
var rng := RandomNumberGenerator.new()
var menu: Control
var ip_field: LineEdit
var status: Label
var hud: Label


func _ready() -> void:
	rng.randomize()
	_setup_env()
	_build_menu()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _my_id() -> String:
	return str(multiplayer.get_unique_id())


func _name_of(id: String) -> String:
	return "Бот%s" % id.substr(3) if id.begins_with("bot") else "Игрок " + id


# ---------- МЕНЮ ----------

func _setup_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_menu() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu = CenterContainer.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(menu)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	menu.add_child(box)
	var title := Label.new()
	title.text = "KOL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 72)
	box.add_child(title)
	box.add_child(_button("Играть против ботов", _play_bots))
	box.add_child(_button("Создать LAN-сервер", _host))
	ip_field = LineEdit.new()
	ip_field.placeholder_text = "IP хоста, например 192.168.1.20"
	ip_field.custom_minimum_size = Vector2(0, 110)
	box.add_child(ip_field)
	box.add_child(_button("Подключиться по IP", _join))
	status = Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(status)

	hud = Label.new()
	hud.position = Vector2(24, 24)
	hud.add_theme_font_size_override("font_size", 30)
	hud.visible = false
	layer.add_child(hud)


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 120)
	b.add_theme_font_size_override("font_size", 36)
	b.pressed.connect(cb)
	return b


func _play_bots() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_host = true
	_start_match()


func _host() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		status.text = "Не смог открыть порт %d (код ошибки %d)." % [PORT, err]
		return
	multiplayer.multiplayer_peer = peer
	is_host = true
	_start_match()
	hud_msg = "Сервер на порту %d. Друзья в той же Wi-Fi вводят IP этого телефона." % PORT
	hud_msg_time = 6.0


func _join() -> void:
	var ip := ip_field.text.strip_edges()
	if ip.is_empty():
		status.text = "Сначала впиши IP хоста."
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		status.text = "Не получилось начать подключение к %s." % ip
		return
	multiplayer.multiplayer_peer = peer
	is_host = false
	status.text = "Подключаюсь к %s..." % ip


func _start_match() -> void:
	if started:
		return
	started = true
	menu.visible = false
	hud.visible = true
	_build_map()
	if is_host:
		_spawn_char(_my_id(), _spawn_pos(), false)
		for i in BOT_COUNT:
			_spawn_char("bot%d" % i, _spawn_pos(), true)


func _build_map() -> void:
	var map: Node3D = (load("res://assets/map.glb") as PackedScene).instantiate()
	add_child(map)
	for m in map.find_children("*", "MeshInstance3D", true, false):
		m.create_trimesh_collision()
	# Страховочный пол, чтобы никто не улетел в вечность
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 2, 600)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0, -40, 0)
	add_child(floor_body)


func _spawn_pos() -> Vector3:
	return SPAWNS[rng.randi() % SPAWNS.size()]


func _spawn_char(id: String, pos: Vector3, bot: bool) -> Character:
	if chars.has(id):
		return chars[id]
	var c := Character.new()
	c.name = "C_" + id
	add_child(c)
	c.setup(self, id, bot, id == _my_id(), pos)
	chars[id] = c
	return c


func nearest_enemy(me: Character) -> Character:
	var best: Character = null
	var best_d := INF
	for id in chars:
		var c: Character = chars[id]
		if c == me or not c.alive:
			continue
		var d := me.global_position.distance_squared_to(c.global_position)
		if d < best_d:
			best_d = d
			best = c
	return best


# ---------- СЕТЬ: подключения ----------

# Вызывает всё локально и (если есть пиры) шлёт остальным.
func _bcast(fn: StringName, args: Array) -> void:
	if multiplayer.get_peers().size() > 0:
		callv("rpc", [fn] + args)
	callv(fn, args)


func _on_peer_connected(pid: int) -> void:
	if not is_host:
		return
	var sid := str(pid)
	for cid in chars:
		var c: Character = chars[cid]
		rpc_id(pid, "_spawn_remote", cid, c.global_position, c.is_bot)
	_bcast("_spawn_remote", [sid, _spawn_pos(), false])
	_bcast("_announce", ["%s зашёл в игру" % _name_of(sid)])


func _on_peer_disconnected(pid: int) -> void:
	if not is_host:
		return
	_bcast("_despawn", [str(pid)])


func _on_connected_to_server() -> void:
	_start_match()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	started = false
	menu.visible = true
	status.text = "Хост не отвечает. Проверь IP и что оба в одной Wi-Fi (порт %d)." % PORT


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	get_tree().reload_current_scene()


# ---------- СЕТЬ: RPC ----------

@rpc("authority", "reliable")
func _spawn_remote(id: String, pos: Vector3, bot: bool) -> void:
	_spawn_char(id, pos, bot)


@rpc("authority", "reliable")
func _despawn(id: String) -> void:
	if chars.has(id):
		chars[id].queue_free()
		chars.erase(id)


# Хост рассылает состояние всех персонажей ~20 раз в секунду.
@rpc("authority", "unreliable")
func _state_down(id: String, pos: Vector3, y: float) -> void:
	if id == _my_id() or not chars.has(id):
		return
	chars[id].set_net_state(pos, y)


# Клиент шлёт хосту своё положение.
@rpc("any_peer", "unreliable")
func _state_up(pos: Vector3, y: float) -> void:
	var sid := str(multiplayer.get_remote_sender_id())
	if chars.has(sid):
		chars[sid].set_net_state(pos, y)


# Клиент говорит «я попал в X» — хост проверяет и применяет урон.
@rpc("any_peer", "reliable")
func _hit_up(target_id: String, dmg: int) -> void:
	var shooter := str(multiplayer.get_remote_sender_id())
	apply_damage(target_id, clampi(dmg, 0, 30), shooter)


@rpc("authority", "reliable")
func _sync_hp(id: String, hp: int) -> void:
	if chars.has(id):
		chars[id].set_hp(hp)


@rpc("authority", "reliable")
func _sync_death(id: String) -> void:
	if chars.has(id):
		chars[id].die()


@rpc("authority", "reliable")
func _sync_respawn(id: String, pos: Vector3) -> void:
	if chars.has(id):
		chars[id].respawn(pos)


@rpc("authority", "reliable")
func _announce(text: String) -> void:
	hud_msg = text
	hud_msg_time = 4.0


# ---------- УРОН ----------

# Вызывается Character'ами (стрельба, бот-AI).
func report_hit(target_id: String, dmg: int, shooter_id: String) -> void:
	if is_host:
		apply_damage(target_id, dmg, shooter_id)
	else:
		rpc_id(1, "_hit_up", target_id, dmg)


func apply_damage(target_id: String, dmg: int, shooter_id: String) -> void:
	if not is_host or not chars.has(target_id):
		return
	var t: Character = chars[target_id]
	if not t.alive or dmg <= 0:
		return
	var new_hp := t.hp - dmg
	if new_hp > 0:
		_bcast("_sync_hp", [target_id, new_hp])
	else:
		_bcast("_sync_death", [target_id])
		_bcast("_announce", ["%s → %s" % [_name_of(shooter_id), _name_of(target_id)]])
		get_tree().create_timer(RESPAWN_TIME).timeout.connect(_respawn.bind(target_id))


func _respawn(id: String) -> void:
	if chars.has(id):
		_bcast("_sync_respawn", [id, _spawn_pos()])


# ---------- ЦИКЛ ----------

func _physics_process(delta: float) -> void:
	if not started:
		return
	net_timer -= delta
	if net_timer <= 0.0:
		net_timer = 0.05
		if is_host:
			if multiplayer.get_peers().size() > 0:
				for id in chars:
					var c: Character = chars[id]
					rpc("_state_down", id, c.global_position, c.yaw)
		else:
			var me = chars.get(_my_id())
			if me:
				rpc_id(1, "_state_up", me.global_position, me.yaw)
	if is_host:
		# Упал в бездну — умер
		for id in chars.keys():
			var c: Character = chars[id]
			if c.alive and c.global_position.y < -20.0:
				apply_damage(id, 9999, "бездна")


func _process(delta: float) -> void:
	if not started:
		return
	var me = chars.get(_my_id())
	var text := ""
	if me:
		text = ("HP: %d" % me.hp) if me.alive else "ТЫ МЁРТВ, возрождение..."
	text += "\nНа арене: %d" % chars.size()
	if hud_msg_time > 0.0:
		hud_msg_time -= delta
		text += "\n" + hud_msg
	hud.text = text
