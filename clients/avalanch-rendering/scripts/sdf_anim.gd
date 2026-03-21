extends Node3D

## Configuration for the avalanche animation sequence
@export_group("Sequence Settings")
@export var heightmap_base_path: String = "res://data/avalanche1/avalanche1_exr/ca_exp1_hflow"
@export var frame_count: int = 10
@export var fps: float = 10.0

@export_group("References")
@export var mesh_instance: MeshInstance3D
# @export var heightmap: Texture2D
@export var jfa_generator: Node

var _current_frame: int = 0
var _timer: float = 0.0
var _sdf_cache: Array[ImageTexture3D] = []

func _ready() -> void:
	if not mesh_instance or not jfa_generator:
		push_error("Missing references in AvalancheController")
		return
	
	_precompute_sequence()

func _process(delta: float) -> void:
	if _sdf_cache.is_empty():
		return

	_timer += delta
	if _timer >= 1.0 / fps:
		_timer = 0.0
		_current_frame = (_current_frame + 1) % _sdf_cache.size()
		_update_shader(_sdf_cache[_current_frame])

func _precompute_sequence() -> void:
	_sdf_cache.clear()
	
	for i in range(frame_count):
		var frame_suffix = str(i).pad_zeros(4) 
		var path = "%s%s.exr" % [heightmap_base_path, frame_suffix]
		
		var tex = load(path) as Texture2D
		if tex:
			# jfa_generator.heightmap = heightmap
			# Assuming hflow and heightmap use the same sequence or logic
			jfa_generator.hflow = tex 
			
			var sdf = jfa_generator._execute_full_jfa()
			_sdf_cache.append(sdf)
		else:
			push_warning("Could not load frame: " + path)

func _update_shader(sdf_tex: ImageTexture3D) -> void:
	var mat = mesh_instance.get_active_material(0) as ShaderMaterial
	if mat:
		mat.set_shader_parameter("sdf", sdf_tex)
