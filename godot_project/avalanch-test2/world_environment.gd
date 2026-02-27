extends WorldEnvironment

@onready var georef = get_parent() # Assuming parent is CesiumGeoreference

func _process(_delta: float):
	if georef and "latitude" in georef:
		var lat_deg = georef.latitude
		var long_deg = georef.longitude
		# 1. Convert degrees to radians
		var lat_rad = deg_to_rad(lat_deg)
		var long_rad = deg_to_rad(long_deg)
		# 2. Apply to the sky rotation. 
		# Note: You may need to experiment with which axis (X or Z) 
		# aligns with your specific PhysicalSkyMaterial setup.
		environment.sky_rotation.z = -PI/2+lat_rad 
		environment.sky_rotation.x = -long_rad
		# 3. If using PhysicalSkyMaterial, you might also want to 
		# rotate the 'sky_rotation' of the environment directly:
		environment.set_sky_rotation(Vector3(0, long_rad, -PI/2+lat_rad ))
