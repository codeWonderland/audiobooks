extends Control
## Full-screen "now playing" view modelled on the Audible player: frosted cover
## backdrop, large artwork, chapter label, action pills, an orange scrubber with
## elapsed / time-left / remaining, the transport row (prev · -30 · play · +30 ·
## next) and a bottom row (Speed · Car Mode · Timer · + Clip).
##
## All playback state lives in the Player autoload; this screen just renders it
## and forwards user intent.

signal closed

const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const PLACEHOLDER := preload("res://assets/icons/book_placeholder.svg")

const SPEEDS := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
const SLEEP_OPTIONS := [0, 5, 15, 30, 45, 60]  # minutes; 0 = off

@onready var _bg_cover: TextureRect = %BgCover
@onready var _cover: TextureRect = %Cover
@onready var _close_btn: Button = %CloseBtn
@onready var _chapter_btn: Button = %ChapterBtn
@onready var _scrubber: HSlider = %Scrubber
@onready var _elapsed: Label = %ElapsedLabel
@onready var _left: Label = %LeftLabel
@onready var _remaining: Label = %RemainingLabel
@onready var _prev_btn: Button = %PrevBtn
@onready var _back_btn: Button = %Back30Btn
@onready var _play_btn: Button = %PlayBtn
@onready var _fwd_btn: Button = %Fwd30Btn
@onready var _next_btn: Button = %NextBtn
@onready var _speed_btn: Button = %SpeedBtn
@onready var _car_btn: Button = %CarBtn
@onready var _timer_btn: Button = %TimerBtn
@onready var _clip_btn: Button = %ClipBtn
@onready var _toast: Label = %Toast
@onready var _loading: Control = %LoadingOverlay
@onready var _loading_bar: ProgressBar = %LoadingBar
@onready var _loading_label: Label = %LoadingLabel

var _user_seeking := false
var _updating := false
var _sleep_timer: Timer
var _sleep_deadline := 0.0

func _ready() -> void:
	_close_btn.pressed.connect(func(): closed.emit())
	_play_btn.pressed.connect(Player.toggle)
	_back_btn.pressed.connect(func(): Player.skip(-30.0))
	_fwd_btn.pressed.connect(func(): Player.skip(30.0))
	_prev_btn.pressed.connect(Player.prev_chapter)
	_next_btn.pressed.connect(Player.next_chapter)
	_speed_btn.pressed.connect(_cycle_speed)
	_timer_btn.pressed.connect(_cycle_sleep)
	_chapter_btn.pressed.connect(_open_chapters)
	_car_btn.pressed.connect(func(): _show_toast("Car Mode coming soon"))
	_clip_btn.pressed.connect(func(): _show_toast("Clips coming soon"))

	_scrubber.drag_started.connect(func(): _user_seeking = true)
	_scrubber.drag_ended.connect(_on_drag_ended)
	_scrubber.value_changed.connect(_on_scrub_value)

	Player.book_changed.connect(_on_book_changed)
	Player.state_changed.connect(_on_state_changed)
	Player.position_changed.connect(_on_position_changed)
	Player.loading_changed.connect(_on_loading_changed)
	Player.speed_changed.connect(_on_speed_changed)

	_sleep_timer = Timer.new()
	_sleep_timer.one_shot = false
	_sleep_timer.wait_time = 1.0
	add_child(_sleep_timer)
	_sleep_timer.timeout.connect(_on_sleep_tick)

	_toast.modulate.a = 0.0
	_loading.visible = false
	_on_speed_changed(Player.get_speed())
	if Player.current_book != null:
		_on_book_changed(Player.current_book)

# --- Rendering Player state -------------------------------------------------

func _on_book_changed(book: Book) -> void:
	var tex := Library.cover_texture(book)
	_cover.texture = tex if tex != null else PLACEHOLDER
	_bg_cover.texture = tex
	_bg_cover.visible = tex != null
	_chapter_btn.text = book._display_title()
	_elapsed.text = Fmt.clock(0)
	_remaining.text = "-" + Fmt.clock(book.duration)
	_left.text = Fmt.time_left(book.duration)

func _on_state_changed(playing: bool) -> void:
	_play_btn.icon = PAUSE_ICON if playing else PLAY_ICON

func _on_position_changed(pos: float, length: float) -> void:
	if _user_seeking:
		return
	_updating = true
	_scrubber.max_value = maxf(1.0, length)
	_scrubber.value = pos
	_updating = false
	_update_time_labels(pos, length)
	_chapter_btn.text = Player.chapter_title()

func _update_time_labels(pos: float, length: float) -> void:
	var remaining := maxf(0.0, length - pos)
	_elapsed.text = Fmt.clock(pos)
	_remaining.text = "-" + Fmt.clock(remaining)
	# "time left" accounts for playback speed, like Audible.
	_left.text = Fmt.time_left(remaining / maxf(0.1, Player.get_speed()))

func _on_loading_changed(active: bool, ratio: float) -> void:
	_loading.visible = active
	_loading_bar.value = ratio * 100.0
	_loading_label.text = "Preparing audio… %d%%" % int(ratio * 100.0)

func _on_speed_changed(speed: float) -> void:
	_speed_btn.text = "%.2fx" % speed

# --- Scrubbing --------------------------------------------------------------

func _on_scrub_value(v: float) -> void:
	if _updating:
		return
	_update_time_labels(v, _scrubber.max_value)
	if not _user_seeking:
		Player.seek(v)  # a click on the track (no drag)

func _on_drag_ended(_changed: bool) -> void:
	_user_seeking = false
	Player.seek(_scrubber.value)

# --- Speed / sleep timer / chapters ----------------------------------------

func _cycle_speed() -> void:
	var cur := Player.get_speed()
	var idx := 0
	for i in SPEEDS.size():
		if is_equal_approx(SPEEDS[i], cur):
			idx = i
			break
	Player.set_speed(SPEEDS[(idx + 1) % SPEEDS.size()])

func _cycle_sleep() -> void:
	var cur_min := int(round(maxf(0.0, _sleep_deadline - _elapsed_seconds()) / 60.0)) if _sleep_deadline > 0.0 else 0
	var idx := SLEEP_OPTIONS.find(cur_min)
	var next: int = SLEEP_OPTIONS[(idx + 1) % SLEEP_OPTIONS.size()] if idx != -1 else SLEEP_OPTIONS[1]
	if next == 0:
		_sleep_deadline = 0.0
		_sleep_timer.stop()
		_timer_btn.self_modulate = Color.WHITE
		_show_toast("Sleep timer off")
	else:
		_sleep_deadline = _elapsed_seconds() + next * 60.0
		_sleep_timer.start()
		_timer_btn.self_modulate = Palette.ACCENT
		_show_toast("Sleep timer: %d min" % next)

func _on_sleep_tick() -> void:
	if _sleep_deadline <= 0.0:
		return
	if _elapsed_seconds() >= _sleep_deadline:
		_sleep_deadline = 0.0
		_sleep_timer.stop()
		_timer_btn.self_modulate = Color.WHITE
		Player.pause()
		_show_toast("Paused by sleep timer")

# Monotonic wall-clock seconds, avoiding Time.get_ticks divergence concerns.
func _elapsed_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0

func _open_chapters() -> void:
	var book := Player.current_book
	if book == null or book.chapters.is_empty():
		_show_toast("No chapters in this book")
		return
	var menu := PopupMenu.new()
	add_child(menu)
	for i in book.chapters.size():
		menu.add_item(book.chapters[i].title, i)
	menu.id_pressed.connect(func(id): Player.seek(book.chapters[id].start))
	menu.close_requested.connect(func(): menu.queue_free())
	menu.popup_hide.connect(func(): menu.queue_free())
	menu.position = get_viewport().get_mouse_position()
	menu.popup()

# --- Toast + input ----------------------------------------------------------

func _show_toast(msg: String) -> void:
	_toast.text = msg
	_toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.5)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				Player.toggle()
				accept_event()
			KEY_LEFT:
				Player.skip(-30.0)
				accept_event()
			KEY_RIGHT:
				Player.skip(30.0)
				accept_event()
