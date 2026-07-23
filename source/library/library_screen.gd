extends Control
## Library browser. Shows a unified grid of books filtered by tabs:
##   • All        — everything (downloaded books + cloud-only Audible titles)
##   • Downloaded — only books present locally
##
## Cloud-only titles are dimmed with a DOWNLOAD badge; selecting one shows a
## Download action in the sidebar instead of Play/Resume. Downloading fetches +
## converts the book, after which it becomes a normal local book.

signal play_requested(book: Book)
signal show_player_requested   ## open the full player for the already-loaded book
signal settings_requested      ## open the settings screen

const BookCardScene := preload("res://source/library/book_card.tscn")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const PLACEHOLDER := preload("res://assets/icons/book_placeholder.svg")

const TAB_ALL := 0
const TAB_DOWNLOADED := 1

const SORT_TITLE := 0
const SORT_AUTHOR := 1
const SORT_RELEASE := 2

@onready var _open_btn: Button = %OpenFolderBtn
@onready var _settings_btn: Button = %SettingsBtn
@onready var _refresh_btn: Button = %RefreshBtn
@onready var _folder_label: Label = %FolderLabel
@onready var _status: Label = %StatusLabel
@onready var _scan_bar: ProgressBar = %ScanBar
@onready var _tabs: TabBar = %Tabs
@onready var _search_edit: LineEdit = %SearchEdit
@onready var _sort_option: OptionButton = %SortOption
@onready var _grid: HFlowContainer = %Grid
@onready var _empty_state: Label = %EmptyState

@onready var _sb_empty: Label = %SidebarEmpty
@onready var _detail_scroll: Control = %DetailScroll
@onready var _sb_cover: TextureRect = %SbCover
@onready var _sb_title: Label = %SbTitle
@onready var _sb_author: Label = %SbAuthor
@onready var _sb_narrator: Label = %SbNarrator
@onready var _sb_series: Label = %SbSeries
@onready var _sb_released: Label = %SbReleased
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

var _local_books: Array[Book] = []
var _cloud_items: Array = []
var _cards_by_key: Dictionary = {}   # key -> card
var _selected_entry: Dictionary = {}
var _selected_key: String = ""
var _search := ""
var _sort := SORT_TITLE
var _auto_selected := false   # last-book auto-selection happens once, on launch
var _dialog: FileDialog

func _ready() -> void:
	_open_btn.pressed.connect(_pick_folder)
	_settings_btn.pressed.connect(func(): settings_requested.emit())
	_refresh_btn.pressed.connect(_on_refresh)
	_refresh_btn.visible = Audible.is_signed_in()
	_sb_play.pressed.connect(_on_sidebar_play)

	_tabs.add_tab("All")
	_tabs.add_tab("Downloaded")
	_tabs.tab_changed.connect(func(_i): _rebuild())

	for label in ["Title", "Author", "Release date"]:
		_sort_option.add_item(label)
	_sort_option.item_selected.connect(func(i): _sort = i; _rebuild())
	_search_edit.text_changed.connect(func(t): _search = t; _rebuild())

	Library.scan_finished.connect(_on_scan_finished)
	Library.remote_cover_ready.connect(_on_remote_cover)

	Audible.library_synced.connect(_on_synced)
	Audible.state_changed.connect(_on_audible_state)
	Audible.download_progress.connect(_on_dl_progress)
	Audible.download_converting.connect(_on_dl_converting)
	Audible.download_preparing.connect(_on_dl_preparing)
	Audible.download_finished.connect(_on_dl_finished)

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

func _rescan() -> void:
	_update_folder_label()
	Library.rescan()
	_sync_if_connected()

func _sync_if_connected() -> void:
	if Audible.is_signed_in():
		Audible.sync_library()

func _update_folder_label() -> void:
	var custom := Settings.get_library_folder()
	if not custom.is_empty() and DirAccess.dir_exists_absolute(custom):
		_folder_label.text = "Downloads + " + custom
	else:
		_folder_label.text = "Downloaded books"

func _on_scan_finished(books: Array) -> void:
	_scan_bar.visible = false
	_local_books.assign(books)
	_rebuild()

func _on_synced(items: Array, message: String) -> void:
	_cloud_items = items
	_refresh_btn.disabled = false
	_rebuild()

func _on_audible_state() -> void:
	_refresh_btn.visible = Audible.is_signed_in()
	if Audible.is_signed_in():
		_sync_if_connected()
	else:
		_cloud_items = []
		_rebuild()

## Re-pull the library from Audible (and rescan local files).
func _on_refresh() -> void:
	if not Audible.is_signed_in():
		return
	_refresh_btn.disabled = true
	_status.text = "Refreshing from Audible…"
	Library.rescan()
	Audible.sync_library()

# --- Entry model ------------------------------------------------------------

## Merge local books + cloud items into display entries keyed by asin (or a
## local id for custom-folder books without an asin).
func _compute_entries() -> Array:
	var by_asin: Dictionary = {}
	for it in _cloud_items:
		var asin: String = it.get("asin", "")
		by_asin[asin] = {
			"key": asin, "asin": asin, "cloud": it, "book": null, "downloaded": false,
			"title": it.get("title", ""), "author": it.get("authors", ""),
			"narrator": it.get("narrators", ""), "series": it.get("series", ""),
			"date": str(it.get("release_date", "")),
			"duration_sec": float(int(it.get("runtime_min", 0)) * 60), "description": "",
		}
	var extras: Array = []
	for b in _local_books:
		var asin := _asin_for(b)
		if not asin.is_empty() and by_asin.has(asin):
			var e: Dictionary = by_asin[asin]
			e.book = b
			e.downloaded = true
			e.title = b._display_title()
			e.author = b.author
			e.narrator = b.narrator
			e.series = b.series
			e.date = b.year
			e.duration_sec = b.duration
			e.description = b.description
		else:
			extras.append({
				"key": "local:" + b.id, "asin": asin, "cloud": {}, "book": b, "downloaded": true,
				"title": b._display_title(), "author": b.author, "narrator": b.narrator,
				"series": b.series, "date": b.year, "duration_sec": b.duration,
				"description": b.description,
			})
	var entries: Array = extras + by_asin.values()
	for e in entries:
		e["search"] = ("%s %s %s %s %s" % [e.title, e.author, e.narrator, e.series, e.description]).to_lower()
	return entries

## Ordering used by the Sort dropdown. Ties fall back to title.
func _sort_cmp(a: Dictionary, b: Dictionary) -> bool:
	match _sort:
		SORT_AUTHOR:
			var r := String(a.author).naturalnocasecmp_to(b.author)
			return r < 0 if r != 0 else String(a.title).naturalnocasecmp_to(b.title) < 0
		SORT_RELEASE:
			if a.date == b.date:
				return String(a.title).naturalnocasecmp_to(b.title) < 0
			if String(a.date).is_empty():
				return false
			if String(b.date).is_empty():
				return true
			return a.date > b.date  # newest first
		_:
			return String(a.title).naturalnocasecmp_to(b.title) < 0

func _asin_for(book: Book) -> String:
	var dd := Library.download_dir()
	if book.file_path.begins_with(dd):
		return book.file_path.get_file().get_basename()
	return ""

# --- Grid build -------------------------------------------------------------

func _rebuild() -> void:
	for c in _grid.get_children():
		if c != _empty_state:  # EmptyState lives in the grid; keep it
			c.queue_free()
	_cards_by_key.clear()

	var entries := _compute_entries()
	var downloaded_count := 0
	for e in entries:
		if e.downloaded:
			downloaded_count += 1

	# Search filter (title/author/narrator/series/description), then sort.
	var q := _search.strip_edges().to_lower()
	var filtered: Array = []
	for e in entries:
		if q.is_empty() or e.search.contains(q):
			filtered.append(e)
	filtered.sort_custom(_sort_cmp)

	var shown := 0
	for e in filtered:
		if _tabs.current_tab == TAB_DOWNLOADED and not e.downloaded:
			continue
		_make_card(e)
		shown += 1

	_empty_state.visible = shown == 0
	if shown == 0:
		_empty_state.text = _search_empty_message() if not q.is_empty() else _empty_message()
	if not q.is_empty():
		_status.text = "%d result%s for \"%s\"" % [shown, "" if shown == 1 else "s", _search.strip_edges()]
	elif not _cloud_items.is_empty():
		_status.text = "%d downloaded · %d in cloud" % [downloaded_count, _cloud_items.size()]
	else:
		_status.text = "%d book%s" % [downloaded_count, "" if downloaded_count == 1 else "s"]

	# Restore selection if the selected entry is still visible.
	if not _selected_key.is_empty() and _cards_by_key.has(_selected_key):
		var card: Node = _cards_by_key[_selected_key]
		_select(card.entry, card)
	elif _selected_key.is_empty() and not _auto_select_last():
		_show_sidebar_empty()

## On first launch, open the last-listened book in the sidebar. Runs once, once
## the book appears in the grid (keeps trying across scan/sync rebuilds).
func _auto_select_last() -> bool:
	if _auto_selected:
		return false
	var last := Settings.get_last_book()
	if last.is_empty():
		return false
	for k in _cards_by_key:
		var card: Node = _cards_by_key[k]
		var bk = card.entry.get("book")
		if bk != null and bk.id == last:
			_auto_selected = true
			_select(card.entry, card)
			return true
	return false

func _make_card(entry: Dictionary) -> void:
	var card := BookCardScene.instantiate()
	_grid.add_child(card)
	card.setup(entry)
	card.selected.connect(func(e): _select(e, card))
	card.activated.connect(func(e): _on_card_activated(e, card))
	_cards_by_key[entry.key] = card
	if not entry.downloaded:
		Library.request_remote_cover(entry.asin, entry.cloud.get("cover_url", ""))
		if Audible.is_downloading(entry.asin):
			card.set_progress_text(_download_badge(Audible.download_status(entry.asin)))

func _on_card_activated(entry: Dictionary, card: Node) -> void:
	_select(entry, card)
	if entry.get("book") != null:
		var book: Book = entry.book
		if not (book.encrypted and not book.secret_ready()):
			play_requested.emit(book)

func _on_remote_cover(asin: String, tex: Texture2D) -> void:
	if _cards_by_key.has(asin):
		_cards_by_key[asin].set_cover_texture(tex)
	if _selected_entry.get("asin", "") == asin and _selected_entry.get("book") == null:
		_sb_cover.texture = tex

func _empty_message() -> String:
	if _tabs.current_tab == TAB_DOWNLOADED:
		return "No downloaded books yet. Switch to All to download from your Audible library."
	return "No audiobooks yet. Connect your Audible account in Settings to see your library, or open a folder of mp3/m4b files."

func _search_empty_message() -> String:
	return "No books match \"%s\"." % _search.strip_edges()

# --- Selection --------------------------------------------------------------

func _select(entry: Dictionary, card: Node) -> void:
	for k in _cards_by_key:
		_cards_by_key[k].set_selected(false)
	_selected_entry = entry
	_selected_key = entry.key
	if card != null and is_instance_valid(card):
		card.set_selected(true)
	_populate_sidebar(entry)

# --- Sidebar ----------------------------------------------------------------

func _show_sidebar_empty() -> void:
	_sb_empty.visible = true
	_detail_scroll.visible = false

func _populate_sidebar(entry: Dictionary) -> void:
	_sb_empty.visible = false
	_detail_scroll.visible = true
	var book = entry.get("book")
	if book != null:
		var tex := Library.cover_texture(book)
		_sb_cover.texture = tex if tex != null else PLACEHOLDER
		_sb_title.text = book._display_title()
		_sb_author.text = "by %s" % (book.author if not book.author.is_empty() else "Unknown author")
		_sb_narrator.text = "Narrated by %s" % book.narrator
		_sb_narrator.visible = not book.narrator.is_empty()
		_sb_series.text = book.series
		_sb_series.visible = not book.series.is_empty() and book.series != book.title
		_sb_stats.text = "%s · %d chapter%s · %s · %s" % [
			Fmt.duration(book.duration), book.chapters.size(),
			"" if book.chapters.size() == 1 else "s", book.format.to_upper(),
			Fmt.file_size(book.file_size)]
		_sb_description.text = book.description
		_sb_description.visible = not book.description.is_empty()
	else:
		var cloud: Dictionary = entry.get("cloud", {})
		_sb_cover.texture = PLACEHOLDER
		Library.request_remote_cover(entry.asin, cloud.get("cover_url", ""))
		_sb_title.text = cloud.get("title", "")
		var authors: String = cloud.get("authors", "")
		_sb_author.text = "by %s" % (authors if not authors.is_empty() else "Unknown author")
		var narr: String = cloud.get("narrators", "")
		_sb_narrator.text = "Narrated by %s" % narr
		_sb_narrator.visible = not narr.is_empty()
		_sb_series.text = cloud.get("series", "")
		_sb_series.visible = not str(cloud.get("series", "")).is_empty()
		_sb_stats.text = "%s · in your Audible library" % Fmt.duration(int(cloud.get("runtime_min", 0)) * 60)
		_sb_description.visible = false
	var released := _format_release(str(entry.get("date", "")))
	_sb_released.text = "Released " + released
	_sb_released.visible = not released.is_empty()
	_update_sidebar_action(entry)

## Turns a release date ("2018-05-01" or "2022") into a readable string.
func _format_release(raw: String) -> String:
	if raw.is_empty():
		return ""
	var parts := raw.split("-")
	if parts.size() >= 3 and parts[0].length() == 4:
		var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
				"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		var mi := int(parts[1]) - 1
		if mi >= 0 and mi < 12:
			return "%s %d, %s" % [months[mi], int(parts[2]), parts[0]]
	return raw.left(4) if raw.length() >= 4 else raw

## Sets the sidebar action button for the current entry.
func _update_sidebar_action(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	var book = entry.get("book")
	if book == null:
		var asin: String = entry.get("asin", "")
		if Audible.is_downloading(asin):
			_sb_play.disabled = true
			_sb_play.text = _download_label(Audible.download_status(asin))
		else:
			_sb_play.disabled = false
			_sb_play.text = "Download"
		_sb_progress.visible = false
		return
	if book.encrypted and not book.secret_ready():
		_sb_play.disabled = false
		_sb_play.text = "Unlock in Settings"
		var need := "activation bytes" if book.format == "aax" else "a download voucher"
		_sb_progress.text = "🔒 DRM-protected %s — needs %s." % [book.format.to_upper(), need]
		_sb_progress.visible = true
		return
	_sb_play.disabled = false
	if _is_current(book):
		_sb_play.text = "Currently playing"
		_sb_progress.text = "%s · %s" % [Player.chapter_title(), Fmt.clock(Player.get_position())]
		_sb_progress.visible = true
	elif Settings.has_progress(book.id):
		var pos := Settings.get_position(book.id)
		_sb_progress.text = "Resume · %s (%s left)" % [Fmt.clock(pos), Fmt.duration(maxf(0.0, book.duration - pos))]
		_sb_progress.visible = true
		_sb_play.text = "Resume"
	else:
		_sb_progress.visible = false
		_sb_play.text = "Play"

func _is_current(book: Book) -> bool:
	return Player.current_book != null and Player.current_book.id == book.id \
			and Player.has_stream()

func _on_sidebar_play() -> void:
	if _selected_entry.is_empty():
		return
	var book = _selected_entry.get("book")
	if book == null:
		# Cloud-only: download it. State is tracked in Audible so the card and
		# sidebar stay correct across searches/rebuilds.
		Audible.download_book(_selected_entry.get("cloud", {}))
		_apply_download_ui(_selected_entry.get("asin", ""))
		return
	if book.encrypted and not book.secret_ready():
		settings_requested.emit()
	elif _is_current(book):
		show_player_requested.emit()
	else:
		play_requested.emit(book)

## Re-evaluate the selected book's sidebar (e.g. after activation bytes change).
func refresh_current() -> void:
	if not _selected_entry.is_empty():
		_update_sidebar_action(_selected_entry)

func reload() -> void:
	_rescan()

# --- Download progress (mirrors onto the sidebar action) --------------------

func _is_selected_asin(asin: String) -> bool:
	return _selected_entry.get("asin", "") == asin and not asin.is_empty()

func _on_dl_progress(asin: String, _ratio: float) -> void:
	_apply_download_ui(asin)

func _on_dl_converting(asin: String) -> void:
	_apply_download_ui(asin)

func _on_dl_preparing(asin: String) -> void:
	_apply_download_ui(asin)

func _on_dl_finished(asin: String, success: bool, message: String) -> void:
	if success:
		_selected_key = asin  # re-select once it reappears as a local book
		Library.rescan()
		return
	# Failed: revert the card badge and sidebar action.
	if _cards_by_key.has(asin):
		_cards_by_key[asin].set_progress_text("")
	if _is_selected_asin(asin):
		_sb_play.disabled = false
		_sb_play.text = "Download"
		_sb_progress.text = message
		_sb_progress.visible = true

## Reflect an in-flight download's state on its card badge and, if it's the
## selected book, the sidebar action button. Reads the global state in Audible
## so it's correct even after a search/sort rebuild.
func _apply_download_ui(asin: String) -> void:
	var status := Audible.download_status(asin)
	if _cards_by_key.has(asin):
		_cards_by_key[asin].set_progress_text(_download_badge(status))
	if _is_selected_asin(asin):
		_sb_play.disabled = true
		_sb_play.text = _download_label(status)
		_sb_progress.visible = false

func _download_label(status: Dictionary) -> String:
	match status.get("phase", ""):
		"downloading": return "Downloading %d%%" % int(status.get("ratio", 0.0) * 100.0)
		"converting": return "Converting…"
		"preparing": return "Preparing audio…"
		"starting": return "Starting…"
	return "Download"

func _download_badge(status: Dictionary) -> String:
	match status.get("phase", ""):
		"downloading": return "↓ %d%%" % int(status.get("ratio", 0.0) * 100.0)
		"converting": return "CONVERTING"
		"preparing": return "PREPARING"
		"starting": return "STARTING…"
	return ""

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
	refresh_current()

func _on_player_state_changed(_playing: bool) -> void:
	_update_mini()
	refresh_current()

func _on_player_position_changed(pos: float, length: float) -> void:
	if not _mini.visible:
		return
	_mini_chapter.text = Player.chapter_title()
	_mini_progress.value = (pos / length) * 100.0 if length > 0.0 else 0.0
	var book = _selected_entry.get("book")
	if book != null and _is_current(book):
		_sb_progress.text = "%s · %s" % [Player.chapter_title(), Fmt.clock(pos)]
