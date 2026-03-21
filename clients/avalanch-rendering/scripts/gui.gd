extends Panel

var frame: int;
@export var snow: MeshInstance3D;

signal frame_changed(frame)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_frame_slider_value_changed(value: float) -> void:
	var val = int(value)
	frame = val
	%"Frame count text".set_text(str(frame))
	frame_changed.emit(val)
