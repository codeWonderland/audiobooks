extends Control
## Browse the connected account's Audible library and download titles into the
## app's books folder. Downloaded files (aaxc + voucher) are then picked up by
## the normal library scan and play via the Transcoder's decrypt path.

signal closed

@onready var _sync_btn: Button = %SyncBtn
@onready var _close_btn: Button = %CloseBtn
@onready var _status: Label = %StatusLabel
@onready var _list: VBoxContainer = %List

var _rows: Dictionary = {}   # asin -> Button
var _synced := false

func _ready() -> void:
	_sync_btn.pressed.connect(_sync)
	_close_btn.pressed.connect(func(): closed.emit())
	Audible.library_synced.connect(_on_synced)
	Audible.download_progress.connect(_on_progress)
	Audible.download_converting.connect(_on_converting)
	Audible.download_finished.connect(_on_finished)

func open() -> void:
	if not _synced:
		_sync()

func _sync() -> void:
	_status.text = "Syncing your library…"
	_sync_btn.disabled = true
	Audible.sync_library()

func _on_synced(items: Array, message: String) -> void:
	_synced = true
	_sync_btn.disabled = false
	_status.text = message
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	for it in items:
		_add_row(it)

func _add_row(item: Dictionary) -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = &"Card"
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 14)
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 10)
	card.add_child(m)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	m.add_child(row)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 1)
	row.add_child(info)
	var title := Label.new()
	title.text = item.get("title", "")
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(title)
	var sub := Label.new()
	sub.theme_type_variation = &"Muted"
	sub.text = "%s · %s" % [item.get("authors", "Unknown"), _runtime(item.get("runtime_min", 0))]
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(sub)

	var btn := Button.new()
	btn.theme_type_variation = &"Pill"
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if item.get("downloaded", false):
		btn.text = "Downloaded ✓"
		btn.disabled = true
	else:
		btn.text = "Download"
		btn.pressed.connect(_download.bind(item, btn))
	row.add_child(btn)
	_list.add_child(card)
	_rows[item.get("asin", "")] = btn

func _download(item: Dictionary, btn: Button) -> void:
	btn.disabled = true
	btn.text = "0%"
	Audible.download_book(item)

func _on_progress(asin: String, ratio: float) -> void:
	if _rows.has(asin):
		_rows[asin].text = "%d%%" % int(ratio * 100.0)

func _on_converting(asin: String) -> void:
	if _rows.has(asin):
		_rows[asin].text = "Converting…"

func _on_finished(asin: String, success: bool, message: String) -> void:
	if _rows.has(asin):
		var btn: Button = _rows[asin]
		if success:
			btn.text = "Downloaded ✓"
			btn.disabled = true
		else:
			btn.text = "Retry"
			btn.disabled = false
	if not success:
		_status.text = message

func _runtime(mins: int) -> String:
	var h := mins / 60
	var m := mins % 60
	return "%dh %dm" % [h, m] if h > 0 else "%dm" % m

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		closed.emit()
		accept_event()
