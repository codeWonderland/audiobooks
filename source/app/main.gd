extends Control
## App root. Hosts the library and player screens and toggles between them.
## Audio itself lives in the Player autoload, so switching screens never
## interrupts playback.

@onready var _library: Control = %LibraryScreen
@onready var _player: Control = %PlayerScreen
@onready var _settings: Control = %SettingsScreen
@onready var _login: Control = %AudibleLogin

func _ready() -> void:
	_library.play_requested.connect(_on_play_requested)
	_library.show_player_requested.connect(_show_player)
	_library.settings_requested.connect(_show_settings)
	_player.closed.connect(_show_library)
	_settings.closed.connect(_hide_settings)
	_settings.changed.connect(_library.refresh_current)
	_settings.connect_requested.connect(_show_login)
	_login.closed.connect(_hide_login)
	# Activation bytes arriving (login or manual) unlocks books — refresh sidebar.
	Audible.activation_fetched.connect(func(_ok, _m): _library.refresh_current())
	_show_library()

func _show_settings() -> void:
	_settings.refresh()
	_settings.visible = true

func _hide_settings() -> void:
	_settings.visible = false

func _show_login() -> void:
	_settings.visible = false
	_login.reset()
	_login.visible = true

func _hide_login() -> void:
	_login.visible = false
	_show_settings()

func _on_play_requested(book: Book) -> void:
	Player.open(book, true)
	_show_player()

func _show_player() -> void:
	_library.visible = false
	_player.visible = true

func _show_library() -> void:
	_player.visible = false
	_library.visible = true
