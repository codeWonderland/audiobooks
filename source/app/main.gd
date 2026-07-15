extends Control
## App root. Hosts the library and player screens and toggles between them.
## Audio itself lives in the Player autoload, so switching screens never
## interrupts playback.

@onready var _library: Control = %LibraryScreen
@onready var _player: Control = %PlayerScreen

func _ready() -> void:
	_library.play_requested.connect(_on_play_requested)
	_library.show_player_requested.connect(_show_player)
	_player.closed.connect(_show_library)
	_show_library()

func _on_play_requested(book: Book) -> void:
	Player.open(book, true)
	_show_player()

func _show_player() -> void:
	_library.visible = false
	_player.visible = true

func _show_library() -> void:
	_player.visible = false
	_library.visible = true
