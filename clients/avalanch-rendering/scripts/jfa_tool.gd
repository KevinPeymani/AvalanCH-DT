@tool
extends Node

@export var heightmap: Texture2D
@export var hflow: Texture2D
@export var hflow_scale: float = 1.;
@export var dimensions: Vector3i = Vector3i(64, 64, 64)
@export_file("*.res") var save_path: String = "res://my_sdf.res"
@export var run_jfa: bool = false: set = _trigger_run

func _trigger_run(_val):
	if not heightmap:
		push_warning("Please assign a heightmap first")
		return
	
	if not hflow:
		push_warning("Please assign a hflow first")
		return
		
	var sdf_tex = _execute_full_jfa()
	if sdf_tex:
		save_sdf_to_disk(sdf_tex, save_path)

func get_texture_min_max(img: Image) -> Vector2:
	# img.lock()

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

	# img.unlock()
	return Vector2(1000., 2700.)
	# return Vector2(min_val, max_val)

func _execute_full_jfa() -> ImageTexture3D:
	var rd = RenderingServer.create_local_rendering_device()
	
	var heightmap_img = heightmap.get_image()
	if heightmap_img.is_compressed():
		heightmap_img.decompress()
	heightmap_img.convert(Image.FORMAT_RF)

	var hflow_img = hflow.get_image()
	if hflow_img.is_compressed():
		hflow_img.decompress()
	hflow_img.convert(Image.FORMAT_RF)
	
	var heightmap_fmt = RDTextureFormat.new()
	heightmap_fmt.width = heightmap_img.get_width()
	heightmap_fmt.height = heightmap_img.get_height()
	heightmap_fmt.depth = 1
	heightmap_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	heightmap_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	heightmap_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var hflow_fmt = RDTextureFormat.new()
	hflow_fmt.width = hflow_img.get_width()
	hflow_fmt.height = hflow_img.get_height()
	hflow_fmt.depth = 1
	hflow_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	hflow_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	hflow_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	
	var local_heightmap = rd.texture_create(heightmap_fmt, RDTextureView.new(), [heightmap_img.get_data()])
	var local_hflow = rd.texture_create(hflow_fmt, RDTextureView.new(), [hflow_img.get_data()])

	var heightmap_min_max = get_texture_min_max(heightmap_img)
	# var hflow_min_max = get_texture_min_max(hflow_img)
	var hflow_min_max = Vector2(0., 200.)

	var min_h = heightmap_min_max[0] - hflow_min_max[0];
	var max_h = heightmap_min_max[1] + hflow_min_max[1] + hflow_scale;

	var s_init = _load_shader(rd, "res://shaders/jfa/jfa_init.glsl")
	var s_step = _load_shader(rd, "res://shaders/jfa/jfa_step.glsl")
	var s_dist = _load_shader(rd, "res://shaders/jfa/jfa_distance.glsl")

	var fmt_rgba = _get_format(dimensions, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var fmt_r32 = _get_format(dimensions, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	
	var tex_a = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_b = rd.texture_create(fmt_rgba, RDTextureView.new())
	var tex_final = rd.texture_create(fmt_r32, RDTextureView.new())

	var sampler_heightmap = rd.sampler_create(RDSamplerState.new())
	var sampler_hflow = rd.sampler_create(RDSamplerState.new())
	var u_h = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_heightmap, local_heightmap])
	var u_f = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_hflow, local_hflow])
	var u_a = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_a])
	var push = PackedFloat32Array([min_h, max_h, hflow_scale, 0]).to_byte_array() # Padding to make std430 happy
	_dispatch(rd, s_init, [u_h, u_f, u_a], dimensions, push)

	var steps = ceil(log(max(dimensions.x, max(dimensions.y, dimensions.z))) / log(2))
	var current_input = tex_a
	var current_output = tex_b

	for i in range(steps - 1, -1, -1):
		var step_size = int(pow(2, i))
		
		var u_in = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
		var u_out = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_output])
		
		_dispatch(rd, s_step, [u_in, u_out], dimensions, PackedInt32Array([step_size, 0, 0, 0]).to_byte_array())
		
		var temp = current_input
		current_input = current_output
		current_output = temp

	var u_jfa = _create_uniform(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [current_input])
	var u_sdf = _create_uniform(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [tex_final])
	var u_h_dist = _create_uniform(2, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_heightmap, local_heightmap])
	var u_f_dist = _create_uniform(3, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [sampler_hflow, local_hflow])
	
	_dispatch(rd, s_dist, [u_jfa, u_sdf, u_h_dist, u_f_dist], dimensions, push)

	var byte_data = rd.texture_get_data(tex_final, 0)
	var images: Array[Image] = []

	var bytes_per_pixel = 4
	var layer_size = dimensions.x * dimensions.y * bytes_per_pixel

	for z in range(dimensions.z):
		var start = z * layer_size
		var slice_data = byte_data.slice(start, start + layer_size)
		
		var img = Image.create_from_data(
			dimensions.x,
			dimensions.y,
			false,
			Image.FORMAT_RF,
			slice_data
		)
		images.append(img)

	var sdf_texture = ImageTexture3D.new()
	var err = sdf_texture.create(Image.FORMAT_RF, dimensions.x, dimensions.y, dimensions.z, false, images)

	if err != OK:
		push_error("Texture3D creation failed with error: ", err)
	
	rd.free_rid(local_heightmap)
	rd.free_rid(local_hflow)
	rd.free_rid(tex_a)
	rd.free_rid(tex_b)
	rd.free_rid(tex_final)
	rd.free_rid(sampler_heightmap)
	rd.free_rid(sampler_hflow)
	
	return sdf_texture

func _get_format(dim: Vector3i, data_fmt: int) -> RDTextureFormat:
	var f = RDTextureFormat.new()
	f.width = dim.x
	f.height = dim.y
	f.depth = dim.z
	f.format = data_fmt
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return f

func _create_uniform(binding: int, type: int, ids: Array) -> RDUniform:
	var u = RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u

func _dispatch(rd: RenderingDevice, shader: RID, uniforms: Array, dim: Vector3i, push_constants = null):
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
	rd.submit()
	rd.sync()

func _load_shader(rd: RenderingDevice, path: String) -> RID:
	return rd.shader_create_from_spirv(load(path).get_spirv())

func save_sdf_to_disk(sdf_tex: ImageTexture3D, path: String):
	var resource = sdf_tex
	resource.take_over_path(path)
	# var error = ResourceSaver.save(resource, path)
	var error = ResourceSaver.save(resource, path, ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS | ResourceSaver.FLAG_CHANGE_PATH)
	# sdf_tex.resource_path = path
	if error == OK:
		print("SDF successfully saved to: ", path)
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("Failed to save SDF: ", error)
