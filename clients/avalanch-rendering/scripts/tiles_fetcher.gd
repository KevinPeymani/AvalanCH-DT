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

@export var displace: bool = false

@export var center_e: float = 2623000.0
@export var center_n: float = 1098000.0
@export var base_size: float = 65536.0
@export var lod_levels: int = 5
@export var tile_load_radius: float = 1.5
@export var meters_per_unit: float = 10.0
@export var max_elevation_meters: float = 4000.0
@export var mesh_subdivisions: int = 32

@export var wms_server_url: String = "http://localhost:8080/mapproxy/service"
@export var wms_elevation_url: String = "http://localhost:8080/mapproxy/service"
@export var wms_albedo_layer: String = "ch.swisstopo.swissimage"
@export var wms_albedo_format: String = "image/jpeg"
@export var wms_albedo_transparent: bool = false
@export_enum("SwissImage", "AvalancheDanger") var albedo_preset: int = 0:
	set(value):
		albedo_preset = value
		_apply_albedo_preset()
		if is_inside_tree():
			_clear_meshes()
@export var toggle_albedo_key: Key = KEY_V
@export var wms_elevation_layer: String = "ch.swisstopo.swissalti3d-reliefschattierung"
@export var wms_elevation_format: String = "image/png"
@export var max_concurrent_requests: int = 8

@export var terrain_shader: Shader = preload("res://shaders/terrain_swissalti3d.gdshader")

var active_tiles: Dictionary = {}
var texture_cache: Dictionary = {} # Stores {Vector3(cx,cy,lod): {"albedo": tex, "height": tex}}
var lod_colors: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN, Color.MAGENTA]
var time_since_update: float = 0.0

var request_queue: Array = []
var total_batch_requests: int = 0
var completed_batch_requests: int = 0
var fallback_albedo_tex: ImageTexture
var fallback_height_tex: ImageTexture

func _ready():
	_init_fallback_textures()
	_apply_albedo_preset()

func _init_fallback_textures():
	var albedo_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	# Transparent gray so shader uses nodata fallback color instead of black.
	albedo_img.fill(Color(0.92, 0.92, 0.92, 0.0))
	fallback_albedo_tex = ImageTexture.create_from_image(albedo_img)

	var height_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	# Transparent black means zero elevation in the shader.
	height_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	fallback_height_tex = ImageTexture.create_from_image(height_img)

func _apply_albedo_preset():
	if albedo_preset == 1:
		wms_albedo_layer = "avalanch.danger_latest"
		wms_albedo_format = "image/png"
		wms_albedo_transparent = true
	else:
		wms_albedo_layer = "ch.swisstopo.swissimage"
		wms_albedo_format = "image/jpeg"
		wms_albedo_transparent = false

func _process(delta: float):
	time_since_update += delta
	if time_since_update > 0.5:
		time_since_update = 0.0
		_update_chunks()
	_process_queue()

func _unhandled_input(event: InputEvent):
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == toggle_albedo_key:
		albedo_preset = 1 - albedo_preset
		var preset_name = "AvalancheDanger" if albedo_preset == 1 else "SwissImage"
		print("Albedo preset switched to: %s" % preset_name)

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
	
	# Create the base LOD 0 grid
	var root_size = base_size
	var view_dist = root_size * tile_load_radius
	var min_x = floor((cam_e - view_dist) / root_size)
	var max_x = floor((cam_e + view_dist) / root_size)
	var min_y = floor((cam_n - view_dist) / root_size)
	var max_y = floor((cam_n + view_dist) / root_size)
	
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var cx = (x * root_size) + (root_size / 2.0)
			var cy = (y * root_size) + (root_size / 2.0)
			_process_quadtree(cx, cy, root_size, 0, cam_e, cam_n, required_tiles)

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

func _process_quadtree(cx: float, cy: float, size: float, lod: int, cam_e: float, cam_n: float, required: Dictionary):
	var dist = Vector2(cx, cy).distance_to(Vector2(cam_e, cam_n))
	var subdivide_dist = size * tile_load_radius
	
	# Subdivide if close to camera
	if dist < subdivide_dist and lod < lod_levels - 1:
		var half = size / 2.0
		var quart = size / 4.0
		_process_quadtree(cx - quart, cy - quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx + quart, cy - quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx - quart, cy + quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx + quart, cy + quart, half, lod + 1, cam_e, cam_n, required)
	else:
		# Stop subdividing and spawn the active tile here
		required[Vector3(cx, cy, lod)] = true

func _spawn_tile(cx: float, cy: float, size: float, lod: int):
	var mi = MeshInstance3D.new()
	var mesh = PlaneMesh.new()
	mesh.size = Vector2(size / meters_per_unit, size / meters_per_unit)
	mesh.subdivide_width = mesh_subdivisions
	mesh.subdivide_depth = mesh_subdivisions
	mi.mesh = mesh
	
	mi.set_meta("lod", lod)
	mi.set_meta("cx", cx)
	mi.set_meta("cy", cy)
	mi.set_meta("size", size)
	
	mi.position = Vector3((cx - center_e) / meters_per_unit, 0.0, -(cy - center_n) / meters_per_unit)
	
	var aabb_size = size / meters_per_unit
	mi.custom_aabb = AABB(Vector3(-aabb_size/2.0, -1000.0/meters_per_unit, -aabb_size/2.0), Vector3(aabb_size, 10000.0/meters_per_unit, aabb_size))
	
	var mat = ShaderMaterial.new()
	mat.shader = terrain_shader
	mat.set_shader_parameter("albedo_tex", fallback_albedo_tex)
	mat.set_shader_parameter("height_tex", fallback_height_tex)
	mat.set_shader_parameter("uv_offset_albedo", Vector3.ZERO)
	mat.set_shader_parameter("uv_scale_albedo", Vector3.ONE)
	mat.set_shader_parameter("uv_offset_height", Vector3.ZERO)
	mat.set_shader_parameter("uv_scale_height", Vector3.ONE)
	mat.set_shader_parameter("height_scale", max_elevation_meters / meters_per_unit)
	mat.set_shader_parameter("skirt_depth", 50.0 / meters_per_unit if displace else 0.0)
	mi.material_override = mat
	
	add_child(mi)
	active_tiles[Vector3(cx, cy, lod)] = mi
	
	_apply_material(mi, lod)
	
	var half = size / 2.0
	var tile_key = Vector3(cx, cy, lod)
	
	# Only fetch if it isn't already cached
	if not texture_cache.has(tile_key) or not texture_cache[tile_key].has("albedo"):
		var transparent_albedo = "TRUE" if wms_albedo_transparent else "FALSE"
		var url_albedo = wms_server_url + "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=%s&STYLES=&CRS=EPSG:2056&BBOX=%f,%f,%f,%f&WIDTH=512&HEIGHT=512&FORMAT=%s&TRANSPARENT=%s" % [wms_albedo_layer, cx - half, cy - half, cx + half, cy + half, wms_albedo_format, transparent_albedo]
		request_queue.append({"url": url_albedo, "mi": mi, "type": "albedo"})
		total_batch_requests += 1
		
	if displace and (not texture_cache.has(tile_key) or not texture_cache[tile_key].has("height")):
		var url_height = wms_elevation_url + "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=%s&STYLES=&CRS=EPSG:2056&BBOX=%f,%f,%f,%f&WIDTH=128&HEIGHT=128&FORMAT=%s&TRANSPARENT=TRUE" % [wms_elevation_layer, cx - half, cy - half, cx + half, cy + half, wms_elevation_format]
		request_queue.append({"url": url_height, "mi": mi, "type": "height"})
		total_batch_requests += 1

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
			_execute_request(req["url"], req["mi"], req["type"])
			active += 1
		else:
			total_batch_requests -= 1

func _execute_request(url: String, mi: MeshInstance3D, req_type: String):
	var http = HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(_on_downloaded.bind(mi, http, req_type))
	
	var err = http.request(url)
	if err != OK:
		http.queue_free()
		_update_progress()

func _on_downloaded(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, mi, http, req_type: String):
	if is_instance_valid(http):
		http.queue_free()
		
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and is_instance_valid(mi):
		var img = Image.new()
		var decode_err = FAILED
		
		if req_type == "albedo":
			if wms_albedo_format == "image/png":
				decode_err = img.load_png_from_buffer(body)
			else:
				decode_err = img.load_jpg_from_buffer(body)
		elif req_type == "height":
			decode_err = img.load_png_from_buffer(body)
			
		if decode_err == OK:
			img.fix_alpha_edges()
			var tex = ImageTexture.create_from_image(img)
			
			var cx = mi.get_meta("cx")
			var cy = mi.get_meta("cy")
			var lod = mi.get_meta("lod")
			var key = Vector3(cx, cy, lod)
			
			if not texture_cache.has(key):
				texture_cache[key] = {}
			texture_cache[key][req_type] = tex
			
			_update_materials()
		else:
			push_error(body.get_string_from_utf8())
			
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

func _apply_material(mi: MeshInstance3D, lod: int):
	var mat = mi.material_override as ShaderMaterial
	if not mat: return
	
	if visualize_lod:
		mat.set_shader_parameter("use_debug", true)
		mat.set_shader_parameter("debug_color", lod_colors[lod % lod_colors.size()])
		return
	else:
		mat.set_shader_parameter("use_debug", false)

	var cx = mi.get_meta("cx")
	var cy = mi.get_meta("cy")
	var size = mi.get_meta("size")
	var tile_key = Vector3(cx, cy, lod)

	# ALBEDO FALLBACK
	if texture_cache.has(tile_key) and texture_cache[tile_key].has("albedo"):
		mat.set_shader_parameter("albedo_tex", texture_cache[tile_key]["albedo"])
		mat.set_shader_parameter("uv_scale_albedo", Vector3.ONE)
		mat.set_shader_parameter("uv_offset_albedo", Vector3.ZERO)
	else:
		var found = false
		var p_lod = lod - 1
		while p_lod >= 0 and not found:
			var p_size = base_size / pow(2.0, p_lod)
			var p_cx = (floor(cx / p_size) * p_size) + (p_size / 2.0)
			var p_cy = (floor(cy / p_size) * p_size) + (p_size / 2.0)
			var p_key = Vector3(p_cx, p_cy, p_lod)
			
			if texture_cache.has(p_key) and texture_cache[p_key].has("albedo"):
				mat.set_shader_parameter("albedo_tex", texture_cache[p_key]["albedo"])
				mat.set_shader_parameter("uv_scale_albedo", Vector3(size / p_size, size / p_size, 1.0))
				var u_offset = ((cx - size / 2.0) - (p_cx - p_size / 2.0)) / p_size
				var v_offset = ((p_cy + p_size / 2.0) - (cy + size / 2.0)) / p_size
				mat.set_shader_parameter("uv_offset_albedo", Vector3(u_offset, v_offset, 0.0))
				found = true
			p_lod -= 1

		if not found:
			mat.set_shader_parameter("albedo_tex", fallback_albedo_tex)
			mat.set_shader_parameter("uv_scale_albedo", Vector3.ONE)
			mat.set_shader_parameter("uv_offset_albedo", Vector3.ZERO)

	# HEIGHT FALLBACK
	if texture_cache.has(tile_key) and texture_cache[tile_key].has("height"):
		mat.set_shader_parameter("height_tex", texture_cache[tile_key]["height"])
		mat.set_shader_parameter("uv_scale_height", Vector3.ONE)
		mat.set_shader_parameter("uv_offset_height", Vector3.ZERO)
	else:
		var found = false
		var p_lod = lod - 1
		while p_lod >= 0 and not found:
			var p_size = base_size / pow(2.0, p_lod)
			var p_cx = (floor(cx / p_size) * p_size) + (p_size / 2.0)
			var p_cy = (floor(cy / p_size) * p_size) + (p_size / 2.0)
			var p_key = Vector3(p_cx, p_cy, p_lod)
			
			if texture_cache.has(p_key) and texture_cache[p_key].has("height"):
				mat.set_shader_parameter("height_tex", texture_cache[p_key]["height"])
				mat.set_shader_parameter("uv_scale_height", Vector3(size / p_size, size / p_size, 1.0))
				var u_offset = ((cx - size / 2.0) - (p_cx - p_size / 2.0)) / p_size
				var v_offset = ((p_cy + p_size / 2.0) - (cy + size / 2.0)) / p_size
				mat.set_shader_parameter("uv_offset_height", Vector3(u_offset, v_offset, 0.0))
				found = true
			p_lod -= 1

		if not found:
			mat.set_shader_parameter("height_tex", fallback_height_tex)
			mat.set_shader_parameter("uv_scale_height", Vector3.ONE)
			mat.set_shader_parameter("uv_offset_height", Vector3.ZERO)

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
	texture_cache.clear()
	total_batch_requests = 0
	completed_batch_requests = 0
