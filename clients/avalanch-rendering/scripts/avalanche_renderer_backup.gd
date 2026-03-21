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

@export var render_rect: Sprite3D
@export var textures_base_path: String = "res://data/avalanche1/avalanche1_exr/ca_exp1_hflow"

@export var heightmap: Texture2D
@export var hflow_scale: float = 1.;

const PUSH_CONSTANT_SIZE := 16
const SHADER_INIT := preload("res://shaders/jfa/jfa_init.glsl") as RDShaderFile
const SHADER_STEP := preload("res://shaders/jfa/jfa_step.glsl") as RDShaderFile
const SHADER_DISTANCE := preload("res://shaders/jfa/jfa_distance.glsl") as RDShaderFile
const SHADER_SOURCES = [SHADER_INIT, SHADER_STEP, SHADER_DISTANCE]

var rd: RenderingDevice
var shaders: Array[RID]
var pipelines: Array[RID]
var frame_valid: Array[bool]
var sdfs: Array[RID]
# var sdfs: Array[Texture2D]

var textures: Array[Texture2D]
var textures_rid: Array[RID]

var local_heightmap: RID
# var local_hflow: RID
var min_h: float
var max_h: float

var buffer_frame_min: int = -1
var buffer_frame_max: int = -1

var uniformSet: RID

func _ready() -> void:
	rd = RenderingServer.get_rendering_device()

	buffer_frame_min = -1
	buffer_frame_max = -1
	
	shaders.resize(SHADER_SOURCES.size())
	pipelines.resize(SHADER_SOURCES.size())

	for i: int in range(SHADER_SOURCES.size()):
		shaders[i] = rd.shader_create_from_spirv(SHADER_SOURCES[i].get_spirv())
		pipelines[i] = rd.compute_pipeline_create(shaders[i])
	
	_prepare_heightmap()

func _exit_tree() -> void:
	if not rd: return
	
	for i in shaders.size():
		if pipelines[i].is_valid(): rd.free_rid(pipelines[i])
		if shaders[i].is_valid(): rd.free_rid(shaders[i])
	
	if uniformSet.is_valid(): rd.free_rid(uniformSet)
	if local_heightmap.is_valid(): rd.free_rid(local_heightmap)
	for trid in textures_rid:
		if trid.is_valid(): rd.free_rid(trid)


func _on_config_changed() -> void:
	var pool_size = 1 + preload_backward + preload_forward;
	sdfs.resize(pool_size)
	frame_valid.resize(pool_size)
	_preload_textures()
	_on_frame_changed()

func _preload_textures() -> void:
	textures.clear()
	textures.resize(frames_count)
	for rid in textures_rid:
		if rid.is_valid(): rd.free_rid(rid)
	
	textures_rid.clear()
	textures_rid.resize(frames_count)
	for i in range(frames_count):
		var frame_suffix = str(i).pad_zeros(4) 
		var path = "%s%s.exr" % [textures_base_path, frame_suffix]
		prints("Loading", path)
		
		var hflow_img = load(path).get_image()
		if hflow_img.is_compressed():
			hflow_img.decompress()
		hflow_img.convert(Image.FORMAT_RF)
		
		var hflow_fmt = RDTextureFormat.new()
		hflow_fmt.width = hflow_img.get_width()
		hflow_fmt.height = hflow_img.get_height()
		hflow_fmt.depth = 1
		hflow_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		hflow_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		hflow_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

		textures[i] = hflow_img.get_texture()
		textures_rid[i] = rd.texture_create(hflow_fmt, RDTextureView.new(), [hflow_img.get_data()])



func _on_frame_changed() -> void:
	var pool_size = 1 + preload_backward + preload_forward;
	var new_buffer_frame_min = max(0, min(frames_count - pool_size, frame - preload_backward))
	var new_buffer_frame_max = min(frames_count - 1, new_buffer_frame_min + pool_size - 1)

	# push_warning(new_buffer_frame_min, " ", new_buffer_frame_max)
	
	frame_valid.resize(pool_size)
	frame_valid.fill(false)
	# prints(buffer_frame_min, new_buffer_frame_min, buffer_frame_max, new_buffer_frame_max)
	for i in range(max(buffer_frame_min, new_buffer_frame_min), min(buffer_frame_max, new_buffer_frame_max) + 1):
		frame_valid[i % pool_size] = true
	
	# prints(frame_valid[0], frame_valid[1], frame_valid[2], frame_valid[3], frame_valid[4])
	
	for local_frame in range(new_buffer_frame_min, new_buffer_frame_max + 1):
		if !frame_valid[local_frame % pool_size]:
			call_deferred("_generate_frame", local_frame)
	
	_update_viz()
	
	buffer_frame_min = new_buffer_frame_min
	buffer_frame_max = new_buffer_frame_max

func _generate_frame(local_frame: int) -> void:
	var pool_size = 1 + preload_backward + preload_forward;
	var buffer_index = local_frame % pool_size;
	push_warning("Generating index ", buffer_index, " for frame ", local_frame)
	sdfs[buffer_index] = _generate_sdf(local_frame)
	return

func _update_viz() -> void:
	if render_rect:
		var clamped_frame = clamp(frame, 0, frames_count)
		var pool_size = 1 + preload_backward + preload_forward
		var buffer_index = clamped_frame % pool_size
		if sdfs[buffer_index]:
			var mat = self.get_surface_override_material(0) as ShaderMaterial
			if mat:
				mat.set_shader_parameter("sdf", sdfs[buffer_index])
		else:
			push_warning("Texture no existar")

func _get_format(dim: Vector3i, data_fmt: int) -> RDTextureFormat:
	var f = RDTextureFormat.new()
	f.width = dim.x
	f.height = dim.y
	f.depth = dim.z
	f.format = data_fmt
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return f

func _generate_sdf(local_frame: int) -> RID:
	return _execute_full_jfa(textures_rid[local_frame])

func get_texture_min_max(img: Image) -> Vector2:
	var min_val := INF
	var max_val := -INF

	for y in img.get_height():
		for x in img.get_width():
			var c: Color = img.get_pixel(x, y)
			var v = c.r

			if v < min_val:
				min_val = v
			if v > max_val:
				max_val = v

	return Vector2(1000., 2700.)

func _create_uniform(binding: int, type: int, ids: Array) -> RDUniform:
	var u = RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u

func _prepare_heightmap() -> void:
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
	var hflow_min_max = Vector2(0., 200.)

	min_h = heightmap_min_max[0] - hflow_min_max[0];
	max_h = heightmap_min_max[1] + hflow_min_max[1] + hflow_scale;

func _execute_full_jfa(hflow: RID) -> RID:
	if local_heightmap == null:
		push_warning("local_heightmap is null")
		return RID();
	var fmt_rgba = _get_format(resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var fmt_r32 = _get_format(resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	
	var tex_a = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_b = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_final = rd.texture_create(fmt_r32, RDTextureView.new())

	var sampler_heightmap = rd.sampler_create(RDSamplerState.new())
	var sampler_hflow = rd.sampler_create(RDSamplerState.new())
	var u_h = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_heightmap, local_heightmap])
	var u_f = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_hflow, hflow])
	var u_a = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_a])
	var push = PackedFloat32Array([min_h, max_h, hflow_scale, 0]).to_byte_array() # Padding to make std430 happy
	_dispatch(shaders[0], [u_h, u_f, u_a], resolution, push)

	var steps = ceil(log(max(resolution.x, max(resolution.y, resolution.z))) / log(2))
	var current_input = tex_a
	var current_output = tex_b

	for i in range(steps - 1, -1, -1):
		var step_size = int(pow(2, i))
		
		var u_in = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
		var u_out = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_output])
		
		_dispatch(shaders[1], [u_in, u_out], resolution, PackedInt32Array([step_size, 0, 0, 0]).to_byte_array())
		
		var temp = current_input
		current_input = current_output
		current_output = temp

	var u_jfa = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
	var u_sdf = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_final])
	var u_h_dist = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_heightmap, local_heightmap])
	var u_f_dist = _create_uniform(3, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_hflow, hflow])
	
	_dispatch(shaders[2], [u_jfa, u_sdf, u_h_dist, u_f_dist], resolution, push)
	
	rd.free_rid(tex_a)
	rd.free_rid(tex_b)
	
	return tex_final;

func _dispatch(shader: RID, uniforms: Array, dim: Vector3i, push_constants = null):
	var pipeline = rd.compute_pipeline_create(shader)
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	
	if not uniform_set.is_valid():
		push_error("Failed to create uniform set for shader: ", shader)
		return

	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	
	if push_constants:
		rd.compute_list_set_push_constant(list, push_constants, push_constants.size())
		
	rd.compute_list_dispatch(list, ceil(dim.x/8.0), ceil(dim.y/8.0), ceil(dim.z/8.0))
	rd.compute_list_end()
	# rd.submit()
	# rd.sync()


# func _draw() -> void:
# 	var pool_size = 1 + preload_backward + preload_forward
# 	var clamped_frame = clamp(frame, 0, frames_count)
# 	render_rect.texture = sdfs[clamped_frame % pool_size]

# func _recreate_texture():
# 	textureDirty = false
# 	if Engine.is_editor_hint():
# 		return
# 	if uniformSet.is_valid():
# 		rd.free_rid(uniformSet)
# 	if sandTexture.is_valid():
# 		rd.free_rid(sandTexture)
# 	# Create a new texture in a specific format
# 	var sandTextureFormat := RDTextureFormat.new()
# 	sandTextureFormat.format = RenderingDevice.DATA_FORMAT_R8_UNORM
# 	sandTextureFormat.texture_type = RenderingDevice.TEXTURE_TYPE_2D
# 	sandTextureFormat.width = width
# 	sandTextureFormat.height = height
# 		# Sampling Bit allows usage as Texture (i.e. Texture2DRD or a sampler2D in the Compute Shader)
# 		# Storage Bit allows usage as Image (i.e. image2D)
# 	sandTextureFormat.usage_bits = \
# 		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | \
# 		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
# 	sandTexture = rd.texture_create(sandTextureFormat, RDTextureView.new())
	
# 	# This uniform never changes, no need to keep it alive
# 	var sandTextureUniform := RDUniform.new()
# 	sandTextureUniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
# 	sandTextureUniform.binding = 0
# 	sandTextureUniform.add_id(sandTexture)
# 	# Uniform set is typically used for stuff that doesn't change frame-by-frame
# 	uniformSet = rd.uniform_set_create([sandTextureUniform], sandShader, 0)
	
# 	# Wrap the texture RID and pass it to the TextureRect
# 	var sandTextureWrapper := Texture2DRD.new();
# 	sandTextureWrapper.texture_rd_rid = sandTexture
# 	textureRect.texture = sandTextureWrapper
