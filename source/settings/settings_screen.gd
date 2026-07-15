extends Control
## Modal settings overlay. Phase 1 exposes the Audible activation bytes (used to
## decrypt legacy AAX) and a placeholder for connecting an Audible account, which
## the native Audible client (Phase 2) will drive.

signal closed
signal changed            ## activation bytes changed — library should refresh
signal connect_requested  ## user wants to connect their Audible account (Phase 2)

@onready var _account_status: Label = %AccountStatus
@onready var _connect_btn: Button = %ConnectBtn
@onready var _bytes_edit: LineEdit = %BytesEdit
@onready var _save_btn: Button = %SaveBytesBtn
@onready var _bytes_status: Label = %BytesStatus
@onready var _done_btn: Button = %DoneBtn
@onready var _close_btn: Button = %CloseBtn

func _ready() -> void:
	_save_btn.pressed.connect(_on_save)
	_bytes_edit.text_submitted.connect(func(_t): _on_save())
	_done_btn.pressed.connect(func(): closed.emit())
	_close_btn.pressed.connect(func(): closed.emit())
	_connect_btn.pressed.connect(func(): connect_requested.emit())
	refresh()

func refresh() -> void:
	_bytes_edit.text = Settings.get_activation_bytes()
	_update_bytes_status()
	_account_status.text = "Not connected"  # Phase 2 populates this

func _update_bytes_status() -> void:
	_bytes_status.text = "Activation bytes are set ✓" if Settings.has_activation_bytes() \
			else "No activation bytes set — AAX books stay locked."

func _on_save() -> void:
	var v := _bytes_edit.text.strip_edges()
	if not v.is_empty() and not _is_hex8(v):
		_bytes_status.text = "Must be exactly 8 hex characters (e.g. 1a2b3c4d)."
		return
	Settings.set_activation_bytes(v)
	_update_bytes_status()
	changed.emit()

func _is_hex8(s: String) -> bool:
	if s.length() != 8:
		return false
	for c in s.to_lower():
		if not "0123456789abcdef".contains(c):
			return false
	return true

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		closed.emit()
		accept_event()
