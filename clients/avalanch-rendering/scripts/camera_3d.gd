extends Camera3D

var pos: Vector3;
var t: float = 0;

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pos = self.position


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	t += delta
	position.x = cos(t) * pos.y
	position.z = sin(t) * pos.z
	rotation.y = -t + PI / 2.
