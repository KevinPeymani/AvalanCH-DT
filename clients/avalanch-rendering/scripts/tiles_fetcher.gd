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
@export var wms_elevation_url: String = "http://localhost:8081/geoserver/switzerland/wms"
@export var max_concurrent_requests: int = 8

@export var terrain_shader: Shader = preload("res://shaders/terrain_swissalti3d.gdshader")

# active_tiles: tiles that are currently visible (key = Vector3(cx, cy, lod))
var active_tiles: Dictionary = {}

# texture_cache: {Vector3(cx,cy,lod): {"albedo": tex, "height": tex}}
var texture_cache: Dictionary = {}

var lod_colors: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN, Color.MAGENTA]
var time_since_update: float = 0.0
var request_queue: Array = []
var _pending_requests: int = 0

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

# ---------------------------------------------------------------------------
# Returns true if the tile at (cx, cy, lod) has a usable texture already
# cached — either its own or a parent-LOD fallback.
# ---------------------------------------------------------------------------
func _has_usable_texture(cx: float, cy: float, size: float, lod: int, tex_type: String) -> bool:
	var key = Vector3(cx, cy, lod)
	if texture_cache.has(key) and texture_cache[key].has(tex_type):
		return true
	var p_lod = lod - 1
	while p_lod >= 0:
		var p_size = base_size / pow(2.0, p_lod)
		var p_cx = (floor(cx / p_size) * p_size) + (p_size / 2.0)
		var p_cy = (floor(cy / p_size) * p_size) + (p_size / 2.0)
		var p_key = Vector3(p_cx, p_cy, p_lod)
		if texture_cache.has(p_key) and texture_cache[p_key].has(tex_type):
			return true
		p_lod -= 1
	return false

func _update_chunks():
	var cam = _get_camera()
	if not cam: return

	var cam_pos = cam.global_position
	var cam_e = center_e + (cam_pos.x * meters_per_unit)
	var cam_n = center_n - (cam_pos.z * meters_per_unit)

	var required_tiles = {}

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

	# ------------------------------------------------------------------
	# REMOVAL: only remove a tile once every required tile that covers
	# the same geographic footprint already has something to show.
	# This works symmetrically for both directions:
	#   Zoom in  — parent waits for its 4 children to be texture-ready.
	#   Zoom out — 4 children wait for their coarser replacement to be ready.
	# A "replacement" tile is any required tile whose footprint overlaps
	# the outgoing tile's footprint (regardless of whether it is coarser
	# or finer).
	# ------------------------------------------------------------------
	var keys_to_remove = []
	for key in active_tiles.keys():
		if required_tiles.has(key):
			continue

		var old_cx:   float = key.x
		var old_cy:   float = key.y
		var old_lod:  int   = int(key.z)
		var old_size: float = base_size / pow(2.0, old_lod)
		var old_half: float = old_size / 2.0

		var replacements_ready := true
		for req_key in required_tiles.keys():
			var req_cx:   float = req_key.x
			var req_cy:   float = req_key.y
			var req_lod:  int   = int(req_key.z)
			var req_size: float = base_size / pow(2.0, req_lod)
			var req_half: float = req_size / 2.0

			# Does this required tile overlap the outgoing tile's footprint?
			# Two axis-aligned squares overlap when they overlap on both axes.
			var overlaps_x := req_cx + req_half > old_cx - old_half and req_cx - req_half < old_cx + old_half
			var overlaps_y := req_cy + req_half > old_cy - old_half and req_cy - req_half < old_cy + old_half
			if not (overlaps_x and overlaps_y):
				continue

			# This required tile is a replacement — it must be texture-ready.
			if not _has_usable_texture(req_cx, req_cy, req_size, req_lod, "albedo"):
				replacements_ready = false
				break

		if replacements_ready:
			if is_instance_valid(active_tiles[key]):
				active_tiles[key].queue_free()
			keys_to_remove.append(key)

	for key in keys_to_remove:
		active_tiles.erase(key)

	# Spawn any tile that is required but not yet active.
	for key in required_tiles.keys():
		if not active_tiles.has(key):
			_spawn_tile(key.x, key.y, base_size / pow(2.0, key.z), int(key.z))

	# Purge stale queue entries (tile was freed before request fired).
	for i in range(request_queue.size() - 1, -1, -1):
		if not is_instance_valid(request_queue[i]["mi"]):
			request_queue.remove_at(i)

	# After any change, recompute edge-stitch flags for all active tiles.
	_update_stitch_flags()

func _process_quadtree(cx: float, cy: float, size: float, lod: int,
		cam_e: float, cam_n: float, required: Dictionary):
	var dist = Vector2(cx, cy).distance_to(Vector2(cam_e, cam_n))
	var subdivide_dist = size * tile_load_radius

	if dist < subdivide_dist and lod < lod_levels - 1:
		var half  = size / 2.0
		var quart = size / 4.0
		_process_quadtree(cx - quart, cy - quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx + quart, cy - quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx - quart, cy + quart, half, lod + 1, cam_e, cam_n, required)
		_process_quadtree(cx + quart, cy + quart, half, lod + 1, cam_e, cam_n, required)
	else:
		required[Vector3(cx, cy, lod)] = true

func _spawn_tile(cx: float, cy: float, size: float, lod: int):
	var mi = MeshInstance3D.new()
	var mesh = PlaneMesh.new()
	mesh.size = Vector2(size / meters_per_unit, size / meters_per_unit)
	mesh.subdivide_width  = mesh_subdivisions
	mesh.subdivide_depth  = mesh_subdivisions
	mi.mesh = mesh

	mi.set_meta("lod",  lod)
	mi.set_meta("cx",   cx)
	mi.set_meta("cy",   cy)
	mi.set_meta("size", size)

	mi.position = Vector3(
		(cx - center_e) / meters_per_unit,
		0.0,
		-(cy - center_n) / meters_per_unit
	)

	var aabb_size = size / meters_per_unit
	mi.custom_aabb = AABB(
		Vector3(-aabb_size / 2.0, -1000.0 / meters_per_unit, -aabb_size / 2.0),
		Vector3(aabb_size, 10000.0 / meters_per_unit, aabb_size)
	)

	var mat = ShaderMaterial.new()
	mat.shader = terrain_shader
	mat.set_shader_parameter("uv_scale_albedo",  Vector3.ONE)
	mat.set_shader_parameter("uv_scale_height",  Vector3.ONE)
	mat.set_shader_parameter("height_scale",     max_elevation_meters / meters_per_unit)

	var skirt = 0.0
	if displace:
		skirt = (size * 0.02) / meters_per_unit
	mat.set_shader_parameter("skirt_depth", skirt)

	# Edge-stitch flags — will be filled by _update_stitch_flags() shortly.
	# Each component of the Vector4 is 1.0 if that edge borders a coarser tile.
	# Convention matching the shader: x=North(+Z), y=South(-Z), z=West(-X), w=East(+X)
	# (in world space, +Z is south in Godot's default orientation, but we use
	#  geographic convention where +cy = North, so the mapping is inverted on Z).
	mat.set_shader_parameter("stitch_edges",    Vector4(0, 0, 0, 0))
	# subdivisions count so the shader knows the grid spacing.
	mat.set_shader_parameter("mesh_subdivisions", float(mesh_subdivisions))

	mi.material_override = mat
	mi.visible = false   # hidden until _apply_material confirms a texture exists
	add_child(mi)
	active_tiles[Vector3(cx, cy, lod)] = mi

	_apply_material(mi, lod)

	var half     = size / 2.0
	var tile_key = Vector3(cx, cy, lod)

	if not texture_cache.has(tile_key) or not texture_cache[tile_key].has("albedo"):
		var url_albedo = (wms_server_url
			+ "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap"
			+ "&LAYERS=ch.swisstopo.swissimage&STYLES=&CRS=EPSG:2056"
			+ "&BBOX=%f,%f,%f,%f&WIDTH=512&HEIGHT=512&FORMAT=image/jpeg"
			) % [cx - half, cy - half, cx + half, cy + half]
		request_queue.append({"url": url_albedo, "mi": mi, "type": "albedo"})

	if displace and (not texture_cache.has(tile_key) or not texture_cache[tile_key].has("height")):
		var url_height = (wms_elevation_url
			+ "?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap"
			+ "&LAYERS=switzerland:swissalti3d-combined&STYLES=&CRS=EPSG:2056"
			+ "&BBOX=%f,%f,%f,%f&WIDTH=128&HEIGHT=128&FORMAT=image/png&TRANSPARENT=TRUE"
			) % [cx - half, cy - half, cx + half, cy + half]
		request_queue.append({"url": url_height, "mi": mi, "type": "height"})

# ---------------------------------------------------------------------------
# Edge-stitching: for every active tile, determine which of its 4 edges
# touches a coarser LOD neighbour (or has no neighbour at all, which also
# means the edge is "free" and doesn't need stitching).
#
# The shader receives a Vector4(north, south, west, east) where each
# component is 1.0 when that edge must be stitched down to the coarser
# neighbour's vertex grid.  The shader then snaps edge-vertex UV samples
# to the nearest coarser-grid interval so that height lookups on both
# sides of the boundary are identical, eliminating cracks.
# ---------------------------------------------------------------------------
func _update_stitch_flags():
	for key in active_tiles.keys():
		var mi = active_tiles[key]
		if not is_instance_valid(mi): continue

		var cx:   float = key.x
		var cy:   float = key.y
		var lod:  int   = int(key.z)
		var size: float = base_size / pow(2.0, lod)
		var half: float = size / 2.0

		# Neighbour centres in geographic space (E/N).
		# Godot +X = East, Godot +Z = South → geographic -N.
		var neighbours = {
			"north": Vector2(cx,        cy + size),   # +N
			"south": Vector2(cx,        cy - size),   # -N
			"west":  Vector2(cx - size, cy),
			"east":  Vector2(cx + size, cy)
		}

		var stitch := Vector4(0, 0, 0, 0)

		for dir in neighbours.keys():
			var nc: Vector2 = neighbours[dir]
			# Find what LOD is active at that neighbour position.
			var neighbour_lod := _lod_at(nc.x, nc.y)
			# Stitch if the neighbour is coarser (higher lod number = finer
			# in this system: lod 0 is coarsest, lod N-1 is finest).
			# We stitch when OUR lod is higher (finer) than neighbour's lod.
			if neighbour_lod < lod:
				match dir:
					"north": stitch.x = 1.0
					"south": stitch.y = 1.0
					"west":  stitch.z = 1.0
					"east":  stitch.w = 1.0

		var mat = mi.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("stitch_edges", stitch)

# Returns the LOD of whichever active tile covers geographic point (e, n),
# or -1 if no tile covers it (treated as "coarser than anything" so we don't
# stitch toward a void).
func _lod_at(e: float, n: float) -> int:
	for key in active_tiles.keys():
		var cx:   float = key.x
		var cy:   float = key.y
		var lod:  int   = int(key.z)
		var half: float = (base_size / pow(2.0, lod)) / 2.0
		if e >= cx - half and e <= cx + half and n >= cy - half and n <= cy + half:
			return lod
	return -1

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

func _execute_request(url: String, mi: MeshInstance3D, req_type: String):
	var http = HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(_on_downloaded.bind(mi, http, req_type))

	var err = http.request(url)
	if err != OK:
		http.queue_free()
		return

	_pending_requests += 1

func _on_downloaded(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, mi, http, req_type: String):
	if is_instance_valid(http):
		http.queue_free()

	_pending_requests = max(0, _pending_requests - 1)
	if _pending_requests == 0 and request_queue.is_empty():
		print("All tile requests completed.")

	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and is_instance_valid(mi):
		var img = Image.new()
		var decode_err = FAILED

		if req_type == "albedo":
			decode_err = img.load_jpg_from_buffer(body)
		elif req_type == "height":
			decode_err = img.load_png_from_buffer(body)

		if decode_err == OK:
			img.fix_alpha_edges()
			var tex = ImageTexture.create_from_image(img)

			var cx  = mi.get_meta("cx")
			var cy  = mi.get_meta("cy")
			var lod = mi.get_meta("lod")
			var key = Vector3(cx, cy, lod)

			if not texture_cache.has(key):
				texture_cache[key] = {}
			texture_cache[key][req_type] = tex

			_update_materials()
			# A newly loaded tile may change which neighbours need stitching.
			_update_stitch_flags()
		else:
			push_error(body.get_string_from_utf8())

func _update_materials():
	for mi in active_tiles.values():
		if is_instance_valid(mi):
			_apply_material(mi, mi.get_meta("lod"))

func _apply_material(mi: MeshInstance3D, lod: int):
	var mat = mi.material_override as ShaderMaterial
	if not mat: return

	var cx       = mi.get_meta("cx")
	var cy       = mi.get_meta("cy")
	var size     = mi.get_meta("size")
	var tile_key = Vector3(cx, cy, lod)

	if visualize_lod:
		# In debug mode show all tiles regardless, so LOD boundaries are visible.
		mi.visible = true
		mat.set_shader_parameter("use_debug",   true)
		mat.set_shader_parameter("debug_color", lod_colors[lod % lod_colors.size()])
		return
	else:
		mat.set_shader_parameter("use_debug", false)

	# --- ALBEDO ---
	var albedo_ready := false
	if texture_cache.has(tile_key) and texture_cache[tile_key].has("albedo"):
		mat.set_shader_parameter("albedo_tex",       texture_cache[tile_key]["albedo"])
		mat.set_shader_parameter("uv_scale_albedo",  Vector3.ONE)
		mat.set_shader_parameter("uv_offset_albedo", Vector3.ZERO)
		albedo_ready = true
	else:
		var p_lod := lod - 1
		while p_lod >= 0 and not albedo_ready:
			var p_size = base_size / pow(2.0, p_lod)
			var p_cx   = (floor(cx / p_size) * p_size) + (p_size / 2.0)
			var p_cy   = (floor(cy / p_size) * p_size) + (p_size / 2.0)
			var p_key  = Vector3(p_cx, p_cy, p_lod)
			if texture_cache.has(p_key) and texture_cache[p_key].has("albedo"):
				mat.set_shader_parameter("albedo_tex",      texture_cache[p_key]["albedo"])
				mat.set_shader_parameter("uv_scale_albedo", Vector3(size / p_size, size / p_size, 1.0))
				var u_off = ((cx - size / 2.0) - (p_cx - p_size / 2.0)) / p_size
				var v_off = ((p_cy + p_size / 2.0) - (cy + size / 2.0)) / p_size
				mat.set_shader_parameter("uv_offset_albedo", Vector3(u_off, v_off, 0.0))
				albedo_ready = true
			p_lod -= 1

	# Hide the tile entirely if there is nothing to show yet.
	# This prevents white geometry fighting with whatever is already visible.
	mi.visible = albedo_ready

	# --- HEIGHT ---
	if texture_cache.has(tile_key) and texture_cache[tile_key].has("height"):
		mat.set_shader_parameter("height_tex",       texture_cache[tile_key]["height"])
		mat.set_shader_parameter("uv_scale_height",  Vector3.ONE)
		mat.set_shader_parameter("uv_offset_height", Vector3.ZERO)
	else:
		var found := false
		var p_lod := lod - 1
		while p_lod >= 0 and not found:
			var p_size = base_size / pow(2.0, p_lod)
			var p_cx   = (floor(cx / p_size) * p_size) + (p_size / 2.0)
			var p_cy   = (floor(cy / p_size) * p_size) + (p_size / 2.0)
			var p_key  = Vector3(p_cx, p_cy, p_lod)
			if texture_cache.has(p_key) and texture_cache[p_key].has("height"):
				mat.set_shader_parameter("height_tex",      texture_cache[p_key]["height"])
				mat.set_shader_parameter("uv_scale_height", Vector3(size / p_size, size / p_size, 1.0))
				var u_off = ((cx - size / 2.0) - (p_cx - p_size / 2.0)) / p_size
				var v_off = ((p_cy + p_size / 2.0) - (cy + size / 2.0)) / p_size
				mat.set_shader_parameter("uv_offset_height", Vector3(u_off, v_off, 0.0))
				found = true
			p_lod -= 1

func _clear_meshes():
	for key in active_tiles.keys():
		if is_instance_valid(active_tiles[key]):
			active_tiles[key].queue_free()
	active_tiles.clear()

	for child in get_children():
		if child is HTTPRequest:
			child.queue_free()

	request_queue.clear()
	texture_cache.clear()
	_pending_requests = 0
