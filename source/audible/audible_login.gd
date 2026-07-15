extends Control
## Guided Audible sign-in overlay. Uses the external-browser flow: we open
## Amazon's real sign-in page (so CAPTCHA / 2FA happen in a trusted browser),
## the user pastes the post-login redirect URL back, and we register the device.

signal closed

const COUNTRIES := [
	["United States", "us"], ["United Kingdom", "uk"], ["Germany", "de"],
	["France", "fr"], ["Canada", "ca"], ["Australia", "au"], ["Japan", "jp"],
]

@onready var _country: OptionButton = %CountryOption
@onready var _open_btn: Button = %OpenBtn
@onready var _step2: Control = %Step2
@onready var _redirect_edit: LineEdit = %RedirectEdit
@onready var _finish_btn: Button = %FinishBtn
@onready var _status: Label = %StatusLabel
@onready var _close_btn: Button = %CloseBtn

func _ready() -> void:
	for c in COUNTRIES:
		_country.add_item(c[0])
	_open_btn.pressed.connect(_on_open)
	_finish_btn.pressed.connect(_on_finish)
	_close_btn.pressed.connect(func(): closed.emit())
	_redirect_edit.text_submitted.connect(func(_t): _on_finish())
	Audible.login_completed.connect(_on_login_completed)
	Audible.activation_fetched.connect(_on_activation_fetched)
	reset()

func reset() -> void:
	_country.selected = 0
	_step2.visible = false
	_redirect_edit.text = ""
	_finish_btn.disabled = false
	_status.text = ""

func _on_open() -> void:
	var cc: String = COUNTRIES[maxi(0, _country.selected)][1]
	var url := Audible.begin_login(cc)
	OS.shell_open(url)
	_step2.visible = true
	_status.text = "Your browser is opening Amazon's sign-in page. After you sign in, the page will go blank — copy the full address from the address bar and paste it below."

func _on_finish() -> void:
	var url := _redirect_edit.text.strip_edges()
	if url.is_empty():
		_status.text = "Paste the address your browser landed on after signing in."
		return
	_finish_btn.disabled = true
	_status.text = "Registering this device with Amazon…"
	Audible.finish_login(url)

func _on_login_completed(success: bool, message: String) -> void:
	_status.text = message
	if success:
		_status.text = message + "\nRetrieving activation bytes…"
	else:
		_finish_btn.disabled = false

func _on_activation_fetched(_success: bool, message: String) -> void:
	_status.text += "\n" + message
	_close_btn.text = "Done"

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		closed.emit()
		accept_event()
