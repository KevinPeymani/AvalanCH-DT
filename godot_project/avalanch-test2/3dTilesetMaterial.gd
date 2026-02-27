#extends Cesium3DTileset
#
#@export var slope_material : ShaderMaterial
#
#func _process(_delta):
	## 1. Find the imagery texture from the Cesium nodes
	## We search for the RasterOverlay child of the Tileset
	#var children = get_children()
	#var imagery_tex = null
	#
	## This part is tricky: Cesium often keeps the actual Texture 
	## in a 'RasterOverlay' internal object.
	#for child in children:
		#if "RasterOverlay" in child.name:
			## If the plugin allows access to the texture:
			#if child.has_method("get_runtime_texture"):
				#print("we got texture")
				#imagery_tex = child.get_runtime_texture()
	#
	## 2. Apply the material and the texture to the tiles
	#for child in children:
		#_apply_to_mesh(child, imagery_tex)
#
#func _apply_to_mesh(node, tex):
	#if node is MeshInstance3D:
		#node.material_override = slope_material
		#if tex != null:
			## This sends the Swisstopo image into your 'base_texture' uniform
			#slope_material.set_shader_parameter("base_texture", tex)
	#
	#for child in node.get_children():
		#_apply_to_mesh(child, tex)
