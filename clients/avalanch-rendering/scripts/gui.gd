extends Panel

signal frame_changed(frame: int)
signal playback_toggled(is_playing: bool)
signal playback_rate_changed(rate: float)

@export var total_frames: int = 40
@export var seconds_per_frame: float = 1.0
@export var autoplay: bool = false

var frame: int = 0
var _is_playing: bool = false
var _playback_rate: float = 1.0
var _accumulator: float = 0.0
var _speed_values: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0]
var _play_icon: Texture2D = preload("res://ui/icons/play.svg")
var _pause_icon: Texture2D = preload("res://ui/icons/pause.svg")

func _ready() -> void:
	_populate_speed_selector()
	_sync_slider_bounds()
	_set_frame(int(%"Frame slider".value), false)
	_set_playing(autoplay)

func _process(delta: float) -> void:
	if not _is_playing:
		return
	if seconds_per_frame <= 0.0:
		return

	_accumulator += delta * _playback_rate
	while _accumulator >= seconds_per_frame:
		_accumulator -= seconds_per_frame
		if frame >= total_frames - 1:
			_set_playing(false)
			return
		_set_frame(frame + 1)

func _populate_speed_selector() -> void:
	var speed_selector: OptionButton = %"Speed selector"
	speed_selector.clear()
	for i in range(_speed_values.size()):
		var speed: float = _speed_values[i]
		speed_selector.add_item("%.2fx" % speed, i)
		if is_equal_approx(speed, 1.0):
			speed_selector.select(i)

func _sync_slider_bounds() -> void:
	var slider: HSlider = %"Frame slider"
	var max_frame: int = max(total_frames - 1, 0)
	slider.max_value = float(max_frame)
	slider.tick_count = max(total_frames, 2)

func _set_frame(new_frame: int, emit_signal: bool = true) -> void:
	var clamped_frame: int = clamp(new_frame, 0, max(total_frames - 1, 0))
	if clamped_frame == frame and emit_signal:
		return

	frame = clamped_frame

	var slider: HSlider = %"Frame slider"
	if int(slider.value) != frame:
		slider.set_value_no_signal(float(frame))

	_update_timeline_labels()

	if emit_signal:
		frame_changed.emit(frame)

func _set_playing(value: bool) -> void:
	if _is_playing == value:
		return

	_is_playing = value
	_accumulator = 0.0

	var play_button: Button = %"Play pause button"
	play_button.set_pressed_no_signal(value)
	play_button.icon = _pause_icon if value else _play_icon

	_update_timeline_labels()
	playback_toggled.emit(_is_playing)

func _update_timeline_labels() -> void:
	var max_frame: int = max(total_frames - 1, 0)
	var sim_time: float = frame * seconds_per_frame
	var total_time: float = max_frame * seconds_per_frame

	%"Frame count text".text = "Frame %d / %d" % [frame, max_frame]
	%"Time text".text = "t=%.1fs / %.1fs" % [sim_time, total_time]
	%"Playback status text".text = "Playing" if _is_playing else "Paused"

func _on_frame_slider_value_changed(value: float) -> void:
	_set_frame(int(value))

func _on_play_pause_button_toggled(button_pressed: bool) -> void:
	_set_playing(button_pressed)

func _on_step_back_button_pressed() -> void:
	_set_playing(false)
	_set_frame(frame - 1)

func _on_step_forward_button_pressed() -> void:
	_set_playing(false)
	_set_frame(frame + 1)

func _on_jump_start_button_pressed() -> void:
	_set_playing(false)
	_set_frame(0)

func _on_jump_end_button_pressed() -> void:
	_set_playing(false)
	_set_frame(max(total_frames - 1, 0))

func _on_speed_selector_item_selected(index: int) -> void:
	if index < 0 or index >= _speed_values.size():
		return

	_playback_rate = _speed_values[index]
	playback_rate_changed.emit(_playback_rate)
