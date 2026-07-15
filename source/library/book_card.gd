extends PanelContainer
## A tile in the library grid. Represents a library "entry" which may be a local
## (downloaded) book, a cloud-only book from the Audible library, or both.
## Single click selects (populates the sidebar); double click activates
## (plays if downloaded).

signal selected(entry: Dictionary)
signal activated(entry: Dictionary)

const PLACEHOLDER := preload("res://assets/icons/book_placeholder.svg")

var entry: Dictionary

@onready var _cover: TextureRect = %Cover
@onready var _title: Label = %CardTitle
@onready var _author: Label = %CardAuthor
@onready var _badge: Control = %Badge

func setup(e: Dictionary) -> void:
	entry = e
	_title.text = e.get("title", "")
	var author: String = e.get("author", "")
	_author.text = author if not author.is_empty() else "Unknown author"
	var downloaded: bool = e.get("downloaded", false)
	_badge.visible = not downloaded
	# self_modulate dims only the cover texture, not the badge child (modulate
	# would propagate to children and fade the badge's text/icon too).
	_cover.self_modulate = Color(1, 1, 1, 1) if downloaded else Color(1, 1, 1, 0.45)
	var book = e.get("book", null)
	if book != null:
		var tex := Library.cover_texture(book)
		_cover.texture = tex if tex != null else PLACEHOLDER
	else:
		_cover.texture = PLACEHOLDER  # remote cover arrives via set_cover_texture()

func set_cover_texture(tex: Texture2D) -> void:
	if tex != null:
		_cover.texture = tex

func set_selected(on: bool) -> void:
	if on:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Palette.BG_ELEVATED
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(2)
		sb.border_color = Palette.ACCENT
		add_theme_stylebox_override("panel", sb)
	else:
		remove_theme_stylebox_override("panel")

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			activated.emit(entry)
		else:
			selected.emit(entry)

func _on_mouse_entered() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
