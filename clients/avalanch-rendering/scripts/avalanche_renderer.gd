@tool
extends MeshInstance3D

@export var resolution: Vector3i = Vector3i(64, 64, 64):
	set(value):
		if resolution != value:
			resolution = value
			_on_config_changed()

@export var preload_forward: int = 4:
	set(value):
		if preload_forward != value:
			preload_forward = value
			_on_config_changed()

@export var preload_backward: int = 2:
	set(value):
		if preload_backward != value:
			preload_backward = value
			_on_config_changed()

@export var frames_count: int = 5:
	set(value):
		if frames_count != value:
			frames_count = value
			_on_config_changed()

@export_range(0, 100, 1, "or_greater") var frame: int = 0:
	set(value):
		if frame != value:
			frame = value
			_on_frame_changed()

@export var build_renderer: bool = false:
	set(value):
		_manual_build()

@export var hflow_base_path: String = "res://data/avalanche1/avalanche1_exr/ca_exp1_hflow"
@export var vflow_base_path: String = "res://data/avalanche1/avalanche1_exr/vflow/ca_exp1_vflow"

@export var heightmap: Texture2D
@export var hflow_scale: float = 1.0

const PUSH_CONSTANT_SIZE := 16
const SHADER_INIT := preload("res://shaders/jfa/jfa_init.glsl") as RDShaderFile
const SHADER_STEP := preload("res://shaders/jfa/jfa_step.glsl") as RDShaderFile
const SHADER_DISTANCE := preload("res://shaders/jfa/jfa_distance.glsl") as RDShaderFile
const SHADER_SOURCES = [SHADER_INIT, SHADER_STEP, SHADER_DISTANCE]

var is_initialized: bool = false
var rd: RenderingDevice
var shaders: Array[RID]
var pipelines: Array[RID]
var frame_valid: Array[bool]
var sdfs: Array[RID]
var hflow_rids: Array[RID]
var local_heightmap: RID
var min_h: float
var max_h: float
var buffer_frame_min: int = -1
var buffer_frame_max: int = -1

var sdf_wrappers: Array[Texture3DRD]
var vflows_rds: Array[Texture2DRD]

func _init() -> void:
	is_initialized = false

func _ready() -> void:
	if not Engine.is_editor_hint():
		_manual_build()

func _manual_build() -> void:
	is_initialized = false
	rd = RenderingServer.get_rendering_device()
	
	if not rd:
		push_error("Rendering device unavailable.")
		return

	buffer_frame_min = -1
	buffer_frame_max = -1

	shaders.resize(SHADER_SOURCES.size())
	pipelines.resize(SHADER_SOURCES.size())

	for i: int in range(SHADER_SOURCES.size()):
		shaders[i] = rd.shader_create_from_spirv(SHADER_SOURCES[i].get_spirv())
		pipelines[i] = rd.compute_pipeline_create(shaders[i])

	_prepare_heightmap()
	_preload_textures()

	is_initialized = true
	_on_frame_changed()

func _on_config_changed() -> void:
	if not is_initialized:
		return
		
	var pool_size = 1 + preload_backward + preload_forward
	sdfs.resize(pool_size)
	sdf_wrappers.resize(pool_size)
	frame_valid.resize(pool_size)
	_preload_textures()
	_on_frame_changed()

func _on_frame_changed() -> void:
	if not is_initialized:
		return
		
	var pool_size = 1 + preload_backward + preload_forward
	var new_buffer_frame_min = max(0, min(frames_count - pool_size, frame - preload_backward))
	var new_buffer_frame_max = min(frames_count - 1, new_buffer_frame_min + pool_size - 1)

	frame_valid.resize(pool_size)
	frame_valid.fill(false)

	for i in range(max(buffer_frame_min, new_buffer_frame_min), min(buffer_frame_max, new_buffer_frame_max) + 1):
		frame_valid[i % pool_size] = true

	for local_frame in range(new_buffer_frame_min, new_buffer_frame_max + 1):
		if not frame_valid[local_frame % pool_size]:
			call_deferred("_generate_frame", local_frame)

	call_deferred("_update_viz")

	buffer_frame_min = new_buffer_frame_min
	buffer_frame_max = new_buffer_frame_max

func _exit_tree() -> void:
	if not rd: 
		return
	
	for i in shaders.size():
		if pipelines.size() > i and pipelines[i].is_valid(): 
			rd.free_rid(pipelines[i])
		if shaders.size() > i and shaders[i].is_valid(): 
			rd.free_rid(shaders[i])
	
	if local_heightmap.is_valid(): 
		rd.free_rid(local_heightmap)
		
	for trid in hflow_rids:
		if trid.is_valid(): 
			rd.free_rid(trid)
			
	for sdf in sdfs:
		if sdf.is_valid():
			rd.free_rid(sdf)

func _preload_textures() -> void:
	if not rd:
		push_warning("RD is null during preload.")
		return

	for rid in hflow_rids:
		if rid.is_valid(): 
			rd.free_rid(rid)
	
	hflow_rids.clear()
	hflow_rids.resize(frames_count)

	vflows_rds.clear()
	vflows_rds.resize(frames_count)

	if hflow_base_path.is_empty() or vflow_base_path.is_empty():
		return

	var hflow_fmt = RDTextureFormat.new()
	hflow_fmt.depth = 1
	hflow_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	hflow_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	hflow_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var vflow_fmt = RDTextureFormat.new()
	vflow_fmt.depth = 1
	vflow_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	vflow_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	vflow_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	for i in range(frames_count):
		var frame_suffix = str(i).pad_zeros(4) 
		var path = "%s%s.exr" % [hflow_base_path, frame_suffix]
		
		if not ResourceLoader.exists(path):
			push_error("Texture not found on disk: ", path)
			continue

		var tex = load(path)
		if not tex:
			push_error("Failed to load resource: ", path)
			continue

		var hflow_img = tex.get_image()
		if not hflow_img or hflow_img.is_empty():
			push_error("Failed to extract image data from: ", path)
			continue
		
		if hflow_img.is_compressed():
			hflow_img.decompress()
		hflow_img.convert(Image.FORMAT_RF)
		hflow_img.clear_mipmaps()
		
		hflow_fmt.width = hflow_img.get_width()
		hflow_fmt.height = hflow_img.get_height()

		hflow_rids[i] = rd.texture_create(hflow_fmt, RDTextureView.new(), [hflow_img.get_data()])
		
		if not hflow_rids[i].is_valid():
			push_error("Failed to create RD texture for frame: ", i)

	for i in range(frames_count):
		var frame_suffix = str(i).pad_zeros(4) 
		var path = "%s%s.exr" % [vflow_base_path, frame_suffix]
		
		if not ResourceLoader.exists(path):
			push_error("Texture not found on disk: ", path)
			continue

		var tex = load(path)
		if not tex:
			push_error("Failed to load resource: ", path)
			continue

		var vflow_img = tex.get_image()
		if not vflow_img or vflow_img.is_empty():
			push_error("Failed to extract image data from: ", path)
			continue
		
		if vflow_img.is_compressed():
			vflow_img.decompress()
		vflow_img.convert(Image.FORMAT_RF)
		vflow_img.clear_mipmaps()
		
		vflow_fmt.width = vflow_img.get_width()
		vflow_fmt.height = vflow_img.get_height()

		vflows_rds[i] = Texture2DRD.new()
		vflows_rds[i].texture_rd_rid = rd.texture_create(vflow_fmt, RDTextureView.new(), [vflow_img.get_data()])
		
		#if not vflows_rds[i].is_valid():
			#push_error("Failed to create RD texture for frame: ", i)

func _generate_frame(local_frame: int) -> void:
	if local_frame < 0 or local_frame >= hflow_rids.size() or not hflow_rids[local_frame].is_valid():
		return
		
	var pool_size = 1 + preload_backward + preload_forward
	var buffer_index = local_frame % pool_size

	if sdfs.size() != pool_size:
		sdfs.resize(pool_size)
	if sdf_wrappers.size() != pool_size:
		sdf_wrappers.resize(pool_size)

	if sdfs[buffer_index] and sdfs[buffer_index].is_valid():
		rd.free_rid(sdfs[buffer_index])
		
	sdfs[buffer_index] = _generate_sdf(local_frame)

	var wrapper = Texture3DRD.new()
	wrapper.texture_rd_rid = sdfs[buffer_index]
	sdf_wrappers[buffer_index] = wrapper

func _update_viz() -> void:
	var clamped_frame = clamp(frame, 0, frames_count - 1)
	var pool_size = 1 + preload_backward + preload_forward
	var buffer_index = clamped_frame % pool_size

	if sdf_wrappers.size() > buffer_index and sdf_wrappers[buffer_index]:
		var mat = self.get_surface_override_material(0) as ShaderMaterial
		if mat:
			mat.set_shader_parameter("sdf_size", resolution)
			mat.set_shader_parameter("sdf", sdf_wrappers[buffer_index])
			mat.set_shader_parameter("s_vflow", vflows_rds[clamped_frame])
	else:
		push_warning("SDF texture wrapper does not exist for frame ", clamped_frame)

func _get_format(dim: Vector3i, data_fmt: int) -> RDTextureFormat:
	var f = RDTextureFormat.new()
	f.width = dim.x
	f.height = dim.y
	f.depth = dim.z
	f.format = data_fmt
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return f

func _generate_sdf(local_frame: int) -> RID:
	return _execute_full_jfa(hflow_rids[local_frame])

func get_texture_min_max(img: Image) -> Vector2:
	var min_val := INF
	var max_val := -INF

	for y in img.get_height():
		for x in img.get_width():
			var v = img.get_pixel(x, y).r
			if v < min_val:
				min_val = v
			if v > max_val:
				max_val = v

	if is_inf(min_val):
		return Vector2(0.0, 1.0)
		
	return Vector2(min_val, max_val)

func _create_uniform(binding: int, type: int, ids: Array) -> RDUniform:
	var u = RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u

func _prepare_heightmap() -> void:
	if not heightmap:
		return
		
	var heightmap_img = heightmap.get_image()
	if heightmap_img.is_compressed():
		heightmap_img.decompress()
	heightmap_img.convert(Image.FORMAT_RF)

	var heightmap_fmt = RDTextureFormat.new()
	heightmap_fmt.width = heightmap_img.get_width()
	heightmap_fmt.height = heightmap_img.get_height()
	heightmap_fmt.depth = 1
	heightmap_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	heightmap_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	heightmap_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	local_heightmap = rd.texture_create(heightmap_fmt, RDTextureView.new(), [heightmap_img.get_data()])

	var heightmap_min_max = get_texture_min_max(heightmap_img)
	var hflow_min_max = Vector2(0.0, 200.0)

	min_h = heightmap_min_max.x - hflow_min_max.x
	max_h = heightmap_min_max.y + hflow_min_max.y + hflow_scale

	prints("Extremums", heightmap_min_max.x, heightmap_min_max.y)

func _execute_full_jfa(hflow: RID) -> RID:
	if not local_heightmap.is_valid():
		push_warning("local_heightmap is null")
		return RID()
		
	var fmt_rgba = _get_format(resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var fmt_r32 = _get_format(resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	
	var tex_a = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_b = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_final = rd.texture_create(fmt_r32, RDTextureView.new())

	var sampler_state = RDSamplerState.new()
	var sampler = rd.sampler_create(sampler_state)
	
	var u_h = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, local_heightmap])
	var u_f = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, hflow])
	var u_a = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_a])
	var push = PackedFloat32Array([min_h, max_h, hflow_scale, 0]).to_byte_array()
	
	_dispatch(pipelines[0], shaders[0], [u_h, u_f, u_a], resolution, push)

	var steps = ceil(log(max(resolution.x, max(resolution.y, resolution.z))) / log(2))
	var current_input = tex_a
	var current_output = tex_b

	for i in range(steps - 1, -1, -1):
		var step_size = int(pow(2, i))
		
		var u_in = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
		var u_out = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_output])
		
		_dispatch(pipelines[1], shaders[1], [u_in, u_out], resolution, PackedInt32Array([step_size, 0, 0, 0]).to_byte_array())
		
		var temp = current_input
		current_input = current_output
		current_output = temp

	var u_jfa = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
	var u_sdf = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_final])
	var u_h_dist = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, local_heightmap])
	var u_f_dist = _create_uniform(3, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler, hflow])
	
	_dispatch(pipelines[2], shaders[2], [u_jfa, u_sdf, u_h_dist, u_f_dist], resolution, push)
	
	rd.free_rid(sampler)
	rd.free_rid(tex_a)
	rd.free_rid(tex_b)

	print(tex_final)
	
	return tex_final

func _dispatch(pipeline: RID, shader: RID, uniforms: Array, dim: Vector3i, push_constants = null) -> void:
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	
	if not uniform_set.is_valid():
		push_error("Failed to create uniform set")
		return

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	
	if push_constants:
		rd.compute_list_set_push_constant(list, push_constants, push_constants.size())
		
	rd.compute_list_dispatch(list, ceil(dim.x / 8.0), ceil(dim.y / 8.0), ceil(dim.z / 8.0))
	rd.compute_list_end()
	
	# rd.submit()
	# rd.sync()


func _on_gui_frame_changed(new_frame: Variant) -> void:
	frame = new_frame
