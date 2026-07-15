extends Control
## Library browser: pick a folder, scan it for audiobooks, show them as a grid
## of covers, and reveal a metadata sidebar for the selected book. Emits
## play_requested when the user chooses to listen (sidebar Play or a card
## double-click); Main handles the switch to the player screen.

signal play_requested(book: Book)
signal show_player_requested   ## open the full player for the already-loaded book
signal settings_requested      ## open the settings screen
signal audible_library_requested  ## open the Audible cloud-library browser

const BookCardScene := preload("res://source/library/book_card.tscn")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")

@onready var _open_btn: Button = %OpenFolderBtn
@onready var _settings_btn: Button = %SettingsBtn
@onready var _audible_btn: Button = %AudibleBtn
@onready var _folder_label: Label = %FolderLabel
@onready var _status: Label = %StatusLabel
@onready var _scan_bar: ProgressBar = %ScanBar
@onready var _grid: HFlowContainer = %Grid
@onready var _empty_state: Label = %EmptyState

@onready var _sb_empty: Label = %SidebarEmpty
@onready var _sb_content: Control = %SidebarContent
@onready var _sb_cover: TextureRect = %SbCover
@onready var _sb_title: Label = %SbTitle
@onready var _sb_author: Label = %SbAuthor
@onready var _sb_narrator: Label = %SbNarrator
@onready var _sb_series: Label = %SbSeries
@onready var _sb_stats: Label = %SbStats
@onready var _sb_description: Label = %SbDescription
@onready var _sb_progress: Label = %SbProgress
@onready var _sb_play: Button = %SbPlayBtn

@onready var _mini: PanelContainer = %MiniPlayer
@onready var _mini_cover: TextureRect = %MiniCover
@onready var _mini_title: Label = %MiniTitle
@onready var _mini_chapter: Label = %MiniChapter
@onready var _mini_play: Button = %MiniPlayBtn
@onready var _mini_progress: ProgressBar = %MiniProgress

const PLACEHOLDER := preload("res://assets/icons/book_placeholder.svg")

var _cards: Array[Node] = []
var _selected: Book = null
var _selected_card: Node = null
var _dialog: FileDialog

func _ready() -> void:
	_open_btn.pressed.connect(_pick_folder)
	_settings_btn.pressed.connect(func(): settings_requested.emit())
	_audible_btn.pressed.connect(func(): audible_library_requested.emit())
	_audible_btn.visible = Audible.is_signed_in()
	Audible.state_changed.connect(func(): _audible_btn.visible = Audible.is_signed_in())
	_sb_play.pressed.connect(_on_sidebar_play)
	Library.scan_started.connect(_on_scan_started)
	Library.book_found.connect(_add_card)
	Library.scan_progress.connect(_on_scan_progress)
	Library.scan_finished.connect(_on_scan_finished)

	_mini_play.pressed.connect(Player.toggle)
	_mini.gui_input.connect(_on_mini_input)
	Player.book_changed.connect(_on_player_book_changed)
	Player.state_changed.connect(_on_player_state_changed)
	Player.position_changed.connect(_on_player_position_changed)

	_scan_bar.visible = false
	_update_mini()
	_show_sidebar_empty()
	_rescan()

# --- Folder picking / scanning ---------------------------------------------

func _pick_folder() -> void:
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.use_native_dialog = true
		_dialog.title = "Select your audiobook folder"
		_dialog.dir_selected.connect(_on_dir_selected)
		add_child(_dialog)
	var current := Settings.get_library_folder()
	_dialog.current_dir = current if not current.is_empty() else OS.get_environment("HOME")
	_dialog.popup_centered(Vector2i(960, 620))

func _on_dir_selected(dir: String) -> void:
	Settings.set_library_folder(dir)
	_rescan()

## Rescan the app download folder + optional custom folder.
func _rescan() -> void:
	_update_folder_label()
	_empty_state.visible = false
	for c in _cards:
		c.queue_free()
	_cards.clear()
	_selected = null
	_selected_card = null
	_show_sidebar_empty()
	Library.rescan()

func _update_folder_label() -> void:
	var custom := Settings.get_library_folder()
	if not custom.is_empty() and DirAccess.dir_exists_absolute(custom):
		_folder_label.text = "Downloads + " + custom
	else:
		_folder_label.text = "Downloaded books"

func _on_scan_started(total: int) -> void:
	_empty_state.visible = false
	_scan_bar.visible = total > 0
	_scan_bar.max_value = maxi(1, total)
	_scan_bar.value = 0
	_status.text = "Scanning… (0/%d)" % total

func _on_scan_progress(done: int, total: int) -> void:
	_scan_bar.value = done
	_status.text = "Scanning… (%d/%d)" % [done, total]

func _on_scan_finished(books: Array) -> void:
	_scan_bar.visible = false
	if books.is_empty():
		_status.text = ""
		_empty_state.text = "No audiobooks yet. Connect your Audible account to download your library, or open a folder of mp3/m4b files."
		_empty_state.visible = true
	else:
		_status.text = "%d book%s" % [books.size(), "" if books.size() == 1 else "s"]

# --- Cards ------------------------------------------------------------------

func _add_card(book: Book) -> void:
	var card := BookCardScene.instantiate()
	_grid.add_child(card)
	card.setup(book)
	card.selected.connect(func(b): _select(b, card))
	card.activated.connect(func(b): _select(b, card); play_requested.emit(b))
	_cards.append(card)

func _select(book: Book, card: Node) -> void:
	if _selected_card != null and is_instance_valid(_selected_card):
		_selected_card.set_selected(false)
	_selected_card = card
	_selected = book
	if card != null:
		card.set_selected(true)
	_populate_sidebar(book)

# --- Sidebar ----------------------------------------------------------------

func _show_sidebar_empty() -> void:
	_sb_empty.visible = true
	_sb_content.visible = false

func _populate_sidebar(book: Book) -> void:
	_sb_empty.visible = false
	_sb_content.visible = true

	var tex := Library.cover_texture(book)
	_sb_cover.texture = tex if tex != null else PLACEHOLDER
	_sb_title.text = book._display_title()
	_sb_author.text = "by %s" % (book.author if not book.author.is_empty() else "Unknown author")

	_sb_narrator.text = "Narrated by %s" % book.narrator
	_sb_narrator.visible = not book.narrator.is_empty()

	_sb_series.text = book.series
	_sb_series.visible = not book.series.is_empty() and book.series != book.title

	var stats := "%s · %d chapter%s · %s · %s" % [
		Fmt.duration(book.duration),
		book.chapters.size(), "" if book.chapters.size() == 1 else "s",
		book.format.to_upper(),
		Fmt.file_size(book.file_size),
	]
	_sb_stats.text = stats

	_sb_description.text = book.description
	_sb_description.visible = not book.description.is_empty()

	_update_sidebar_play(book)

## Sets the sidebar's action button + progress line to reflect whether the book
## is the one currently loaded in the Player, resuming, or fresh.
func _update_sidebar_play(book: Book) -> void:
	if book == null:
		return
	if book.encrypted and not book.secret_ready():
		_sb_play.text = "Unlock in Settings"
		var need := "activation bytes" if book.format == "aax" else "a download voucher"
		_sb_progress.text = "🔒 DRM-protected %s — needs %s." % [book.format.to_upper(), need]
		_sb_progress.visible = true
		return
	if _is_current(book):
		_sb_play.text = "Currently playing"
		var pos := Player.get_position()
		_sb_progress.text = "%s · %s" % [Player.chapter_title(), Fmt.clock(pos)]
		_sb_progress.visible = true
	elif Settings.has_progress(book.id):
		var pos := Settings.get_position(book.id)
		var left := maxf(0.0, book.duration - pos)
		_sb_progress.text = "Resume · %s (%s left)" % [Fmt.clock(pos), Fmt.duration(left)]
		_sb_progress.visible = true
		_sb_play.text = "Resume"
	else:
		_sb_progress.visible = false
		_sb_play.text = "Play"

func _is_current(book: Book) -> bool:
	return Player.current_book != null and Player.current_book.id == book.id \
			and Player.has_stream()

func _on_sidebar_play() -> void:
	if _selected == null:
		return
	if _selected.encrypted and not _selected.secret_ready():
		settings_requested.emit()  # let the user add the key
	elif _is_current(_selected):
		show_player_requested.emit()  # already loaded — just open the player
	else:
		play_requested.emit(_selected)

## Re-evaluate the selected book's sidebar (e.g. after activation bytes change).
func refresh_current() -> void:
	if _selected != null:
		_update_sidebar_play(_selected)

## Rescan from disk (e.g. after downloading new books from Audible).
func reload() -> void:
	_rescan()

# --- Mini player ------------------------------------------------------------

func _update_mini() -> void:
	var book := Player.current_book
	if book == null or not Player.has_stream():
		_mini.visible = false
		return
	_mini.visible = true
	var tex := Library.cover_texture(book)
	_mini_cover.texture = tex if tex != null else PLACEHOLDER
	_mini_title.text = book._display_title()
	_mini_chapter.text = Player.chapter_title()
	_mini_play.icon = PAUSE_ICON if Player.is_playing() else PLAY_ICON

func _on_mini_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		show_player_requested.emit()

func _on_player_book_changed(_book: Book) -> void:
	_update_mini()
	if _selected != null:
		_update_sidebar_play(_selected)

func _on_player_state_changed(_playing: bool) -> void:
	# state_changed also fires once the stream finishes loading, so this is where
	# the mini player first becomes visible (book_changed fires before load).
	_update_mini()
	if _selected != null:
		_update_sidebar_play(_selected)

func _on_player_position_changed(pos: float, length: float) -> void:
	if not _mini.visible:
		return
	_mini_chapter.text = Player.chapter_title()
	_mini_progress.value = (pos / length) * 100.0 if length > 0.0 else 0.0
	if _selected != null and _is_current(_selected):
		_sb_progress.text = "%s · %s" % [Player.chapter_title(), Fmt.clock(pos)]
