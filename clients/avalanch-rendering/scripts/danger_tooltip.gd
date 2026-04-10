extends CanvasLayer

# European Avalanche Danger Scale colors and labels.
const DANGER_COLORS: Array[Color] = [
	Color(0.70, 0.70, 0.70),  # 0 – No rating
	Color(0.20, 0.65, 0.10),  # 1 – Low          (green)
	Color(1.00, 0.85, 0.00),  # 2 – Limited       (yellow)
	Color(1.00, 0.45, 0.00),  # 3 – Considerable  (orange)
	Color(0.85, 0.08, 0.08),  # 4 – High          (red)
	Color(0.10, 0.00, 0.00),  # 5 – Very High     (near-black)
]
const DANGER_LABELS: Array[String] = [
	"No Rating",
	"Low",
	"Limited",
	"Considerable",
	"High",
	"Very High",
]

# Padding between the cursor tip and the panel edge (px).
const CURSOR_OFFSET := Vector2(14.0, 10.0)

var _panel:       Panel
var _color_swatch: ColorRect
var _level_label: Label
var _desc_label:  Label
var _coords_label: Label


func _ready() -> void:
	layer = 10
	_build_ui()
	_panel.visible = false

	# Connect to the tiles_fetcher signal. The fetcher node is a sibling in the
	# Tiles scene tree; find it by script class rather than hard-coding a path.
	for node in get_tree().get_nodes_in_group("tiles_fetcher"):
		if node.has_signal("danger_hovered"):
			node.danger_hovered.connect(on_danger_hovered)
			return

	# Fallback: scan all nodes for the signal (works without groups too).
	_connect_to_fetcher(get_tree().root)


func _connect_to_fetcher(node: Node) -> void:
	if node.has_signal("danger_hovered"):
		node.danger_hovered.connect(on_danger_hovered)
		return
	for child in node.get_children():
		_connect_to_fetcher(child)


# ---------------------------------------------------------------------------
func on_danger_hovered(info: Dictionary) -> void:
	if not info.get("has_data", false):
		_panel.visible = false
		return

	var danger_int: int = clampi(info.get("danger_int", 0), 0, 5)

	_color_swatch.color = DANGER_COLORS[danger_int]
	_level_label.text   = "Danger Level %d" % danger_int
	_desc_label.text    = DANGER_LABELS[danger_int]

	var e: float = info.get("e", 0.0)
	var n: float = info.get("n", 0.0)
	_coords_label.text = "E %.0f   N %.0f" % [e, n]

	# Recompute the panel's minimum size so it fits its content.
	_panel.reset_size()

	# Position near the cursor, clamped to stay inside the viewport.
	var screen_size: Vector2 = get_viewport().get_visible_rect().size
	var panel_size:  Vector2 = _panel.size
	var pos: Vector2 = info["screen_pos"] + CURSOR_OFFSET
	pos.x = minf(pos.x, screen_size.x - panel_size.x - 4.0)
	pos.y = minf(pos.y, screen_size.y - panel_size.y - 4.0)
	_panel.position = pos

	_panel.visible = true


# ---------------------------------------------------------------------------
func _build_ui() -> void:
	_panel = Panel.new()
	_panel.name = "TooltipPanel"
	_panel.custom_minimum_size = Vector2(195.0, 70.0)

	var style := StyleBoxFlat.new()
	style.bg_color              = Color(0.07, 0.08, 0.12, 0.93)
	style.corner_radius_top_left     = 6
	style.corner_radius_top_right    = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left  = 6
	style.border_width_left   = 1
	style.border_width_top    = 1
	style.border_width_right  = 1
	style.border_width_bottom = 1
	style.border_color        = Color(0.35, 0.35, 0.45, 0.80)
	style.content_margin_left   = 10.0
	style.content_margin_top    = 8.0
	style.content_margin_right  = 10.0
	style.content_margin_bottom = 8.0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	# ── Row 1: colour swatch + "Danger Level N" ──
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(hbox)

	_color_swatch = ColorRect.new()
	_color_swatch.custom_minimum_size = Vector2(14.0, 14.0)
	_color_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(_color_swatch)

	_level_label = Label.new()
	_level_label.add_theme_color_override("font_color",  Color.WHITE)
	_level_label.add_theme_font_size_override("font_size", 14)
	hbox.add_child(_level_label)

	# ── Row 2: danger description ──
	_desc_label = Label.new()
	_desc_label.add_theme_color_override("font_color",  Color(0.80, 0.80, 0.80))
	_desc_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_desc_label)

	# ── Row 3: LV95 coordinates ──
	_coords_label = Label.new()
	_coords_label.add_theme_color_override("font_color",  Color(0.50, 0.55, 0.65))
	_coords_label.add_theme_font_size_override("font_size", 10)
	vbox.add_child(_coords_label)
