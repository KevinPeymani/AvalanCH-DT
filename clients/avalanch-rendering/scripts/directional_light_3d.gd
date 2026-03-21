@tool
extends DirectionalLight3D

@export var target_material: ShaderMaterial

func _process(_delta: float) -> void:
	if target_material:
		target_material.set_shader_parameter("sun_dir", global_basis.z.normalized())
		target_material.set_shader_parameter("sun_color", light_color * light_energy)
