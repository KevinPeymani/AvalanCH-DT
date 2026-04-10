extends CanvasLayer

var _fetcher: Node = null

# Current selection: "none" | "snow" | "danger"
var _active: String = "none"

# Segmented-button references so we can update their pressed state.
var _btns: Dictionary = {}  # label -> Button


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
	# Determine initial state from the fetcher.
	if _fetcher:
		if _fetcher.use_danger_overlay:
			_active = "danger"
		elif _fetcher.use_snow_overlay:
			_active = "snow"

	# ── Panel ──────────────────────────────────────────────────────────────
	var panel := Panel.new()
	panel.set_anchor_and_offset(SIDE_RIGHT,  1.0, -10.0)
	panel.set_anchor_and_offset(SIDE_LEFT,   1.0, -230.0)
	panel.set_anchor_and_offset(SIDE_TOP,    0.0,  10.0)
	panel.set_anchor_and_offset(SIDE_BOTTOM, 0.0,  72.0)

	var bg := StyleBoxFlat.new()
	bg.bg_color              = Color(0.07, 0.08, 0.12, 0.88)
	bg.corner_radius_top_left     = 6
	bg.corner_radius_top_right    = 6
	bg.corner_radius_bottom_right = 6
	bg.corner_radius_bottom_left  = 6
	bg.border_width_left   = 1
	bg.border_width_top    = 1
	bg.border_width_right  = 1
	bg.border_width_bottom = 1
	bg.border_color        = Color(0.35, 0.35, 0.45, 0.80)
	bg.content_margin_left   = 10.0
	bg.content_margin_top    = 8.0
	bg.content_margin_right  = 10.0
	bg.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# ── Label ──────────────────────────────────────────────────────────────
	var lbl := Label.new()
	lbl.text = "Overlay"
	lbl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.65))
	lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(lbl)

	# ── Segmented button row ───────────────────────────────────────────────
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)
	vbox.add_child(hbox)

	# Each entry: [key, label, active_color, left_radius, right_radius]
	var segments := [
		["none",   "None",   Color(0.38, 0.40, 0.45, 0.95), true,  false],
		["snow",   "Snow",   Color(0.15, 0.45, 0.80, 0.95), false, false],
		["danger", "Danger", Color(0.75, 0.35, 0.05, 0.95), false, true ],
	]

	for seg in segments:
		var key:          String = seg[0]
		var label:        String = seg[1]
		var active_color: Color  = seg[2]
		var round_left:   bool   = seg[3]
		var round_right:  bool   = seg[4]

		var btn := Button.new()
		btn.text        = label
		btn.toggle_mode = true
		btn.button_pressed = (key == _active)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 13)
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

		var r := 4
		# Normal / hover
		var s_off := StyleBoxFlat.new()
		s_off.bg_color = Color(0.15, 0.16, 0.20, 0.90)
		s_off.corner_radius_top_left     = r if round_left  else 0
		s_off.corner_radius_bottom_left  = r if round_left  else 0
		s_off.corner_radius_top_right    = r if round_right else 0
		s_off.corner_radius_bottom_right = r if round_right else 0
		s_off.border_width_top    = 1
		s_off.border_width_bottom = 1
		s_off.border_width_left   = 1 if round_left  else 0
		s_off.border_width_right  = 1 if round_right else 0
		s_off.border_color        = Color(0.30, 0.30, 0.40, 0.70)
		btn.add_theme_stylebox_override("normal", s_off)
		btn.add_theme_stylebox_override("hover",  s_off)

		# Pressed / active
		var s_on := StyleBoxFlat.new()
		s_on.bg_color = active_color
		s_on.corner_radius_top_left     = r if round_left  else 0
		s_on.corner_radius_bottom_left  = r if round_left  else 0
		s_on.corner_radius_top_right    = r if round_right else 0
		s_on.corner_radius_bottom_right = r if round_right else 0
		btn.add_theme_stylebox_override("pressed",       s_on)
		btn.add_theme_stylebox_override("hover_pressed", s_on)

		btn.add_theme_color_override("font_color",         Color(0.65, 0.67, 0.72))
		btn.add_theme_color_override("font_pressed_color", Color(1.00, 1.00, 1.00))
		btn.add_theme_color_override("font_hover_color",   Color(0.90, 0.92, 0.98))

		btn.pressed.connect(_on_segment_pressed.bind(key))
		_btns[key] = btn
		hbox.add_child(btn)


func _on_segment_pressed(key: String) -> void:
	_active = key

	# Keep all buttons in sync (ButtonGroup handles mutual exclusion only for
	# radio buttons; since we manage state manually, update them explicitly).
	for k in _btns:
		_btns[k].button_pressed = (k == key)

	if not _fetcher:
		return

	_fetcher.use_snow_overlay   = (key == "snow")
	_fetcher.use_danger_overlay = (key == "danger")
	_fetcher._update_materials()
