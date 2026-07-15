extends PanelContainer
## A single book tile in the library grid. Single click selects (populates the
## sidebar); double click activates (opens the player).

signal selected(book: Book)
signal activated(book: Book)

const PLACEHOLDER := preload("res://assets/icons/book_placeholder.svg")

var book: Book

@onready var _cover: TextureRect = %Cover
@onready var _title: Label = %CardTitle
@onready var _author: Label = %CardAuthor

func setup(b: Book) -> void:
	book = b
	_title.text = b._display_title()
	_author.text = b.author if not b.author.is_empty() else "Unknown author"
	var tex := Library.cover_texture(b)
	_cover.texture = tex if tex != null else PLACEHOLDER

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
			activated.emit(book)
		else:
			selected.emit(book)

func _on_mouse_entered() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
