extends Control
## Shown at startup when ffmpeg/ffprobe aren't found on PATH. Explains, per OS,
## how to install the app's one external dependency.

signal closed

@onready var _title: Label = %Title
@onready var _body: Label = %Body
@onready var _cmd: LineEdit = %CmdEdit
@onready var _copy_btn: Button = %CopyBtn
@onready var _note: Label = %Note
@onready var _status: Label = %Status
@onready var _open_btn: Button = %OpenBtn
@onready var _recheck_btn: Button = %RecheckBtn
@onready var _close_btn: Button = %CloseBtn

func _ready() -> void:
	_close_btn.pressed.connect(func(): closed.emit())
	_open_btn.pressed.connect(func(): OS.shell_open("https://ffmpeg.org/download.html"))
	_copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(_cmd.text)
		_status.text = "Command copied to clipboard.")
	_recheck_btn.pressed.connect(_on_recheck)
	_populate()

func _populate() -> void:
	_status.text = ""
	_body.text = "Audiobooks uses ffmpeg to read, decrypt and play your audiobooks. " \
			+ "It doesn't look like ffmpeg is installed, or it isn't on your PATH."
	var cmd := ""
	var note := ""
	match OS.get_name():
		"macOS":
			cmd = "brew install ffmpeg"
			note = "Needs Homebrew — get it from brew.sh first if you don't have it."
		"Windows":
			cmd = "winget install Gyan.FFmpeg"
			note = "Or download a build from ffmpeg.org and add its bin\\ folder to your PATH, then restart the app."
		"Linux":
			cmd = "sudo apt install ffmpeg"
			note = "Use your distro's package manager (dnf, pacman, zypper, …) if you're not on Debian/Ubuntu."
		_:
			note = "Install ffmpeg from ffmpeg.org and make sure both ffmpeg and ffprobe are on your PATH."
	_cmd.text = cmd
	_cmd.visible = not cmd.is_empty()
	_copy_btn.visible = not cmd.is_empty()
	_note.text = note

func _on_recheck() -> void:
	if Transcoder.ffmpeg_available():
		closed.emit()
	else:
		_status.text = "Still not found. Make sure it's installed and on your PATH (a restart may be needed)."

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		closed.emit()
		accept_event()
