extends CanvasLayer

var _fetcher: Node = null
var _btn: Button


func _ready() -> void:
	layer = 9  # below the tooltip (layer 10)
	_find_fetcher(get_tree().root)
	_build_ui()


func _find_fetcher(node: Node) -> void:
	if node.has_signal("danger_hovered"):
		_fetcher = node
		return
	for child in node.get_children():
		if _fetcher:
			return
		_find_fetcher(child)


func _build_ui() -> void:
	var panel := Panel.new()
	panel.set_anchor_and_offset(SIDE_RIGHT, 1.0, -10.0)
	panel.set_anchor_and_offset(SIDE_LEFT,  1.0, -175.0)
	panel.set_anchor_and_offset(SIDE_TOP,    0.0,  10.0)
	panel.set_anchor_and_offset(SIDE_BOTTOM, 0.0,  54.0)

	var bg := StyleBoxFlat.new()
	bg.bg_color           = Color(0.07, 0.08, 0.12, 0.88)
	bg.corner_radius_top_left     = 6
	bg.corner_radius_top_right    = 6
	bg.corner_radius_bottom_right = 6
	bg.corner_radius_bottom_left  = 6
	bg.border_width_left   = 1
	bg.border_width_top    = 1
	bg.border_width_right  = 1
	bg.border_width_bottom = 1
	bg.border_color        = Color(0.35, 0.35, 0.45, 0.80)
	bg.content_margin_left   = 8.0
	bg.content_margin_top    = 6.0
	bg.content_margin_right  = 8.0
	bg.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(margin)

	_btn = Button.new()
	_btn.text        = "⚠ Danger Layer"
	_btn.toggle_mode = true
	_btn.button_pressed = _fetcher.use_danger_overlay if _fetcher else true
	_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn.size_flags_vertical   = Control.SIZE_SHRINK_CENTER

	# Normal style (layer off)
	var s_normal := StyleBoxFlat.new()
	s_normal.bg_color      = Color(0.15, 0.16, 0.20, 0.9)
	s_normal.corner_radius_top_left     = 4
	s_normal.corner_radius_top_right    = 4
	s_normal.corner_radius_bottom_right = 4
	s_normal.corner_radius_bottom_left  = 4
	_btn.add_theme_stylebox_override("normal",  s_normal)
	_btn.add_theme_stylebox_override("hover",   s_normal)
	_btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())

	# Pressed style (layer on) — orange tint to match the danger colour scale
	var s_pressed := StyleBoxFlat.new()
	s_pressed.bg_color      = Color(0.75, 0.35, 0.05, 0.95)
	s_pressed.corner_radius_top_left     = 4
	s_pressed.corner_radius_top_right    = 4
	s_pressed.corner_radius_bottom_right = 4
	s_pressed.corner_radius_bottom_left  = 4
	_btn.add_theme_stylebox_override("pressed",      s_pressed)
	_btn.add_theme_stylebox_override("hover_pressed", s_pressed)

	_btn.add_theme_color_override("font_color",         Color(0.70, 0.72, 0.78))
	_btn.add_theme_color_override("font_pressed_color",  Color(1.00, 1.00, 1.00))
	_btn.add_theme_color_override("font_hover_color",    Color(0.90, 0.92, 0.98))
	_btn.add_theme_font_size_override("font_size", 13)

	_btn.toggled.connect(_on_toggled)
	margin.add_child(_btn)


func _on_toggled(enabled: bool) -> void:
	if not _fetcher:
		return
	_fetcher.use_danger_overlay = enabled
	_fetcher._update_materials()
