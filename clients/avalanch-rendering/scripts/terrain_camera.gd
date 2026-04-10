extends Camera3D

## Orbit / zoom / pan camera tuned for mountain-scale terrain.
##
## Controls:
##   Left drag   — orbit around the look target
##   Middle drag — pan the look target in the horizontal plane
##   Scroll      — zoom (speed scales with current distance)

@export var orbit_sensitivity: float = 0.005  ## rad per pixel
@export var zoom_factor:       float = 0.12   ## fraction of distance per scroll tick
@export var pan_sensitivity:   float = 0.0008 ## world-units per pixel × distance
@export var min_distance:      float = 30.0   ## Godot units  (~  300 m)
@export var max_distance:      float = 8000.0 ## Godot units  (~ 80 km)
@export var min_pitch:         float = deg_to_rad(3.0)
@export var max_pitch:         float = deg_to_rad(88.0)

## Approximate terrain elevation in Godot units used only to seed the initial
## orbit target at startup.  (Zermatt region ≈ 2000 m / 10 m·u⁻¹ = 200 u)
@export var approx_terrain_y:  float = 200.0

var _target:   Vector3 = Vector3.ZERO
var _distance: float   = 5000.0
var _yaw:      float   = 0.0
var _pitch:    float   = 0.45  # ~26°

var _orbit_active: bool = false
var _pan_active:   bool = false


func _ready() -> void:
	far  = 15000.0  # 150 km — covers the full tile-load radius at 10 m/unit
	near = 1.0      # 10 m   — safe for terrain distances, reduces z-fighting

	# Find the orbit target by projecting the camera's current look direction
	# onto the approximate terrain plane.
	var fwd := -transform.basis.z
	if abs(fwd.y) > 0.001:
		var t := (position.y - approx_terrain_y) / (-fwd.y)
		if t > 0.0:
			_target = position + fwd * t
			_target.y = approx_terrain_y

	# Derive initial spherical coordinates from the scene-set camera position.
	var offset := position - _target
	_distance = max(offset.length(), min_distance)
	_pitch     = asin(clamp(offset.y / _distance, -1.0, 1.0))
	_yaw       = atan2(offset.x, offset.z)
	_update_camera()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_motion(event as InputEventMouseMotion)


func _on_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			_orbit_active = mb.pressed
		MOUSE_BUTTON_MIDDLE:
			_pan_active = mb.pressed
		MOUSE_BUTTON_WHEEL_UP:
			_zoom(-1)
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1)


func _on_motion(mm: InputEventMouseMotion) -> void:
	if _orbit_active:
		# Screen-Y is downward, so negate for pitch so drag-up raises camera.
		_yaw   += mm.relative.x * orbit_sensitivity
		_pitch -= mm.relative.y * orbit_sensitivity
		_pitch  = clamp(_pitch, min_pitch, max_pitch)
		_update_camera()
	elif _pan_active:
		_pan(mm.relative)


func _zoom(dir: int) -> void:
	# Multiplicative zoom keeps the feel consistent across very different distances.
	_distance *= 1.0 + dir * zoom_factor
	_distance  = clamp(_distance, min_distance, max_distance)
	_update_camera()


func _pan(delta: Vector2) -> void:
	# Speed proportional to distance → same number of pixels moves the same
	# fraction of the visible terrain regardless of zoom level.
	var speed    := _distance * pan_sensitivity
	# Camera-right projected onto the horizontal plane.
	var right_h  := Vector3(transform.basis.x.x, 0.0, transform.basis.x.z).normalized()
	# Horizontal direction from camera toward target ("into the scene").
	var toward_h := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	# Grab-world feel: dragging right pulls the terrain right (target moves left).
	_target -= right_h  * delta.x * speed
	# Dragging down pulls the terrain toward the viewer (target moves forward).
	_target += toward_h * delta.y * speed
	_update_camera()


func _update_camera() -> void:
	position = _target + Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw)
	)
	if position.distance_squared_to(_target) > 0.001:
		look_at(_target, Vector3.UP)
