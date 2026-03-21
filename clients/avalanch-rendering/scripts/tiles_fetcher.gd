@tool
extends Node3D

@export var clear_meshes: bool = false:
	set(value):
		if value:
			_clear_meshes()
			clear_meshes = false

@export var visualize_lod: bool = false:
	set(value):
		visualize_lod = value
		_update_materials()

@export var center_e: float = 2600000.0
@export var center_n: float = 1200000.0
@export var base_size: float = 65536.0
@export var lod_levels: int = 5
@export var tile_load_radius: float = 2.0
@export var meters_per_unit: float = 10.0

@export var wms_server_url: String = "http://localhost:8080/mapproxy/service"
@export var max_concurrent_requests: int = 8

var active_tiles: Dictionary = {}
var lod_colors: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN, Color.MAGENTA]
var time_since_update: float = 0.0

var request_queue: Array = []
var total_batch_requests: int = 0
var completed_batch_requests: int = 0

func _process(delta: float):
	time_since_update += delta
	if time_since_update > 0.5:
		time_since_update = 0.0
		_update_chunks()
	_process_queue()

func _get_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport:
			return viewport.get_camera_3d()
		return null
	return get_viewport().get_camera_3d()

func _update_chunks():
	var cam = _get_camera()
	if not cam: return
	
	var cam_pos = cam.global_position
	var cam_e = center_e + (cam_pos.x * meters_per_unit)
	var cam_n = center_n - (cam_pos.z * meters_per_unit)
	
	var required_tiles = {}
	
	for lod in range(lod_levels):
		var tile_size = base_size / pow(2.0, lod)
		var view_dist = tile_size * tile_load_radius
		
		var min_x = floor((cam_e - view_dist) / tile_size)
		var max_x = floor((cam_e + view_dist) / tile_size)
		var min_y = floor((cam_n - view_dist) / tile_size)
		var max_y = floor((cam_n + view_dist) / tile_size)
		
		for x in range(min_x, max_x + 1):
			for y in range(min_y, max_y + 1):
				var cx = (x * tile_size) + (tile_size / 2.0)
				var cy = (y * tile_size) + (tile_size / 2.0)
				var key = Vector3(cx, cy, lod)
				required_tiles[key] = true

	var keys_to_remove = []
	for key in active_tiles.keys():
		if not required_tiles.has(key):
			if is_instance_valid(active_tiles[key]):
				active_tiles[key].queue_free()
			keys_to_remove.append(key)
			
	for key in keys_to_remove:
		active_tiles.erase(key)
		
	for key in required_tiles.keys():
		if not active_tiles.has(key):
			_spawn_tile(key.x, key.y, base_size / pow(2.0, key.z), int(key.z))

	for i in range(request_queue.size() - 1, -1, -1):
		if not is_instance_valid(request_queue[i]["mi"]):
			request_queue.remove_at(i)
			total_batch_requests -= 1

func _spawn_tile(cx: float, cy: float, size: float, lod: int):
	var mi = MeshInstance3D.new()
	var mesh = PlaneMesh.new()
	mesh.size = Vector2(size / meters_per_unit, size / meters_per_unit)
	mi.mesh = mesh
	
	mi.set_meta("lod", lod)
	mi.set_meta("cx", cx)
	mi.set_meta("cy", cy)
	mi.set_meta("size", size)
	
	mi.position = Vector3((cx - center_e) / meters_per_unit, lod * 0.5, -(cy - center_n) / meters_per_unit)
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = lod
	mi.material_override = mat
	
	if lod == lod_levels - 1:
		mi.visibility_range_begin = 0.0
	else:
		mi.visibility_range_begin = max(0.0, ((base_size / pow(2.0, lod + 1)) * 0.9) / meters_per_unit)
		
	mi.visibility_range_end = (((base_size / pow(2.0, lod)) * 1.5) / meters_per_unit) if lod > 0 else 0.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	
	add_child(mi)
	active_tiles[Vector3(cx, cy, lod)] = mi
	
	_apply_material(mi, lod)
	
	var half = size / 2.0
	var url = wms_server_url + "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=ch.swisstopo.swissimage&STYLES=&CRS=EPSG:2056&BBOX=%f,%f,%f,%f&WIDTH=512&HEIGHT=512&FORMAT=image/jpeg" % [cx - half, cy - half, cx + half, cy + half]
	
	request_queue.append({"url": url, "mi": mi})
	total_batch_requests += 1

func _on_downloaded(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, mi, http):
	if is_instance_valid(http):
		http.queue_free()
		
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and is_instance_valid(mi):
		var img = Image.new()
		if img.load_jpg_from_buffer(body) == OK:
			var tex = ImageTexture.create_from_image(img)
			mi.set_meta("tex", tex)
			_update_materials()
			
	_update_progress()

func _apply_material(mi: MeshInstance3D, lod: int):
	var mat = mi.material_override as StandardMaterial3D
	if not mat: return
	
	if visualize_lod:
		mat.albedo_texture = null
		mat.albedo_color = lod_colors[lod % lod_colors.size()]
		mat.uv1_scale = Vector3.ONE
		mat.uv1_offset = Vector3.ZERO
		return

	mat.albedo_color = Color.WHITE
	if mi.has_meta("tex"):
		mat.albedo_texture = mi.get_meta("tex")
		mat.uv1_scale = Vector3.ONE
		mat.uv1_offset = Vector3.ZERO
		return

	var cx = mi.get_meta("cx")
	var cy = mi.get_meta("cy")
	var size = mi.get_meta("size")
	
	var parent_tex = null
	var p_lod = lod - 1
	var p_cx = cx
	var p_cy = cy
	var p_size = size
	
	while p_lod >= 0:
		p_size = base_size / pow(2.0, p_lod)
		p_cx = (floor(cx / p_size) * p_size) + (p_size / 2.0)
		p_cy = (floor(cy / p_size) * p_size) + (p_size / 2.0)
		var p_key = Vector3(p_cx, p_cy, p_lod)
		
		if active_tiles.has(p_key) and is_instance_valid(active_tiles[p_key]) and active_tiles[p_key].has_meta("tex"):
			parent_tex = active_tiles[p_key].get_meta("tex")
			break
		p_lod -= 1
		
	if parent_tex:
		mat.albedo_texture = parent_tex
		mat.uv1_scale = Vector3(size / p_size, size / p_size, 1.0)
		var u_offset = ((cx - size / 2.0) - (p_cx - p_size / 2.0)) / p_size
		var v_offset = ((p_cy + p_size / 2.0) - (cy + size / 2.0)) / p_size
		mat.uv1_offset = Vector3(u_offset, v_offset, 0.0)
	else:
		mat.albedo_texture = null
		mat.uv1_scale = Vector3.ONE
		mat.uv1_offset = Vector3.ZERO

func _get_active_request_count() -> int:
	var count = 0
	for child in get_children():
		if child is HTTPRequest and not child.is_queued_for_deletion():
			count += 1
	return count

func _process_queue():
	var active = _get_active_request_count()
	while active < max_concurrent_requests and request_queue.size() > 0:
		var req = request_queue.pop_front()
		if is_instance_valid(req["mi"]):
			_execute_request(req["url"], req["mi"])
			active += 1
		else:
			total_batch_requests -= 1

func _execute_request(url: String, mi: MeshInstance3D):
	var http = HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(_on_downloaded.bind(mi, http))
	
	var err = http.request(url)
	if err != OK:
		http.queue_free()
		_update_progress()

func _update_progress():
	completed_batch_requests += 1
	if total_batch_requests > 0:
		var pct = int((float(completed_batch_requests) / float(total_batch_requests)) * 100.0)
		print("Tile Progress: %d%% (%d/%d)" % [pct, completed_batch_requests, total_batch_requests])
		
	if completed_batch_requests >= total_batch_requests:
		print("All active tiles loaded.")
		total_batch_requests = 0
		completed_batch_requests = 0

func _update_materials():
	for mi in active_tiles.values():
		if is_instance_valid(mi):
			_apply_material(mi, mi.get_meta("lod"))

func _clear_meshes():
	var keys_to_remove = []
	for key in active_tiles.keys():
		if is_instance_valid(active_tiles[key]):
			active_tiles[key].queue_free()
		keys_to_remove.append(key)
			
	for key in keys_to_remove:
		active_tiles.erase(key)
		
	for child in get_children():
		if child is HTTPRequest:
			child.queue_free()
			
	request_queue.clear()
	total_batch_requests = 0
	completed_batch_requests = 0
