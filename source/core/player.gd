extends Node
## Persistent playback engine (autoload "Player"). Owns the AudioStreamPlayer so
## audio keeps running while the user moves between the library and the player
## screens.
##
## Speed control uses a dedicated audio bus with an AudioEffectPitchShift: the
## stream plays faster via pitch_scale while the effect shifts pitch back down,
## giving Audible-style time-stretch without the chipmunk effect.
##
## Resume positions are persisted through Settings (throttled while playing,
## flushed on pause/stop/exit).

signal book_changed(book: Book)
signal state_changed(playing: bool)
signal position_changed(position: float, length: float)
signal loading_changed(active: bool, ratio: float)
signal speed_changed(speed: float)

const BUS_NAME := "Audiobook"
const SAVE_INTERVAL := 5.0

var current_book: Book = null

var _player: AudioStreamPlayer
var _bus_idx: int = -1
var _pitch: AudioEffectPitchShift
var _length: float = 0.0
var _speed: float = 1.0
var _loading: bool = false
var _pending_book: Book = null   # book we're waiting on a transcode for
var _save_accum: float = 0.0

func _ready() -> void:
	_setup_bus()
	_player = AudioStreamPlayer.new()
	_player.bus = BUS_NAME
	add_child(_player)
	_player.finished.connect(_on_finished)

	_speed = Settings.get_speed()
	_apply_speed()
	_player.volume_db = Settings.get_volume_db()

	Transcoder.transcode_started.connect(_on_transcode_started)
	Transcoder.transcode_progress.connect(_on_transcode_progress)
	Transcoder.transcode_finished.connect(_on_transcode_finished)
	set_process(false)

func _setup_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS_NAME)
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bus_idx, BUS_NAME)
		AudioServer.set_bus_send(_bus_idx, "Master")
	_pitch = AudioEffectPitchShift.new()
	_pitch.fft_size = AudioEffectPitchShift.FFT_SIZE_2048
	AudioServer.add_bus_effect(_bus_idx, _pitch)

# --- Opening / loading ------------------------------------------------------

## Load a book and (by default) start playing from its saved position.
func open(book: Book, autoplay: bool = true) -> void:
	if current_book != null and current_book.id == book.id and _player.stream != null:
		if autoplay:
			play()
		return
	_save_position(true)
	stop()
	current_book = book
	_pending_book = book
	book_changed.emit(book)
	_pending_autoplay = autoplay
	Transcoder.request(book)

var _pending_autoplay: bool = true

func _on_transcode_started(book: Book) -> void:
	if _pending_book and book.id == _pending_book.id:
		_loading = true
		loading_changed.emit(true, 0.0)

func _on_transcode_progress(book: Book, ratio: float) -> void:
	if _pending_book and book.id == _pending_book.id:
		loading_changed.emit(true, ratio)

func _on_transcode_finished(book: Book, ok: bool, path: String) -> void:
	if _pending_book == null or book.id != _pending_book.id:
		return
	_pending_book = null
	_loading = false
	loading_changed.emit(false, 1.0)
	if not ok:
		return
	var stream := _load_stream(path)
	if stream == null:
		return
	_player.stream = stream
	_length = stream.get_length()
	var resume := Settings.get_position(book.id)
	if resume >= _length - 1.0:
		resume = 0.0
	if _pending_autoplay:
		_player.play(resume)
		set_process(true)
		state_changed.emit(true)
	else:
		# Prime the stream at the resume point without audibly playing.
		_player.play(resume)
		_player.stream_paused = true
		state_changed.emit(false)
	position_changed.emit(resume, _length)

func _load_stream(path: String) -> AudioStream:
	if path.get_extension().to_lower() == "mp3":
		return AudioStreamMP3.load_from_file(path)
	return AudioStreamOggVorbis.load_from_file(path)

# --- Transport --------------------------------------------------------------

func is_playing() -> bool:
	return _player != null and _player.playing and not _player.stream_paused

func has_stream() -> bool:
	return _player != null and _player.stream != null

func play() -> void:
	if _player.stream == null:
		return
	if _player.stream_paused:
		_player.stream_paused = false
	elif not _player.playing:
		_player.play(Settings.get_position(current_book.id))
	set_process(true)
	state_changed.emit(true)

func pause() -> void:
	if not is_playing():
		return
	_player.stream_paused = true
	_save_position(true)
	state_changed.emit(false)

func toggle() -> void:
	if is_playing():
		pause()
	else:
		play()

func stop() -> void:
	if _player == null:
		return
	if _player.playing:
		_player.stop()
	set_process(false)
	state_changed.emit(false)

func seek(seconds: float) -> void:
	if _player.stream == null:
		return
	seconds = clampf(seconds, 0.0, _length)
	var was_paused := _player.stream_paused
	if not _player.playing:
		_player.play(seconds)
		_player.stream_paused = was_paused
	else:
		_player.seek(seconds)
	position_changed.emit(seconds, _length)
	_save_position(true)

func skip(delta: float) -> void:
	seek(get_position() + delta)

func get_position() -> float:
	if _player == null or _player.stream == null:
		return 0.0
	return clampf(_player.get_playback_position(), 0.0, _length)

func get_length() -> float:
	return _length

## Absolute [start, end] seconds of the current chapter, or the whole book if
## the file has no chapter metadata. Used to scope the player scrubber to the
## current chapter (elapsed/remaining are chapter-relative; "time left" is not).
func chapter_bounds() -> Vector2:
	if current_book == null or current_book.chapters.is_empty() or _length <= 0.0:
		return Vector2(0.0, maxf(_length, 1.0))
	var c := current_book.chapters[current_chapter()]
	var start: float = clampf(c.start, 0.0, _length)
	var end: float = clampf(c.end, start + 0.1, _length)
	return Vector2(start, end)

# --- Chapters ---------------------------------------------------------------

func current_chapter() -> int:
	if current_book == null:
		return 0
	return current_book.chapter_at(get_position())

func chapter_title() -> String:
	if current_book == null or current_book.chapters.is_empty():
		return current_book._display_title() if current_book else ""
	return current_book.chapters[current_chapter()].title

func next_chapter() -> void:
	if current_book == null or current_book.chapters.is_empty():
		skip(30.0)
		return
	var i := current_chapter() + 1
	if i < current_book.chapters.size():
		seek(current_book.chapters[i].start)

func prev_chapter() -> void:
	if current_book == null or current_book.chapters.is_empty():
		seek(0.0)
		return
	var i := current_chapter()
	# If we're more than 3s into a chapter, restart it; else go to the previous.
	if get_position() - current_book.chapters[i].start > 3.0:
		seek(current_book.chapters[i].start)
	elif i > 0:
		seek(current_book.chapters[i - 1].start)

# --- Speed / volume ---------------------------------------------------------

func get_speed() -> float:
	return _speed

func set_speed(v: float) -> void:
	_speed = clampf(v, 0.5, 3.5)
	_apply_speed()
	Settings.set_speed(_speed)
	speed_changed.emit(_speed)

func _apply_speed() -> void:
	_player.pitch_scale = _speed
	if _pitch:
		_pitch.pitch_scale = 1.0 / _speed

func set_volume_db(db: float) -> void:
	_player.volume_db = db
	Settings.set_volume_db(db)

# --- Per-frame position + throttled save ------------------------------------

func _process(delta: float) -> void:
	if not is_playing():
		return
	var pos := get_position()
	position_changed.emit(pos, _length)
	Settings.set_position(current_book.id, pos, false)
	_save_accum += delta
	if _save_accum >= SAVE_INTERVAL:
		_save_accum = 0.0
		_save_position(true)

func _save_position(flush: bool) -> void:
	if current_book != null and _player != null and _player.stream != null:
		Settings.set_position(current_book.id, get_position(), flush)

func _on_finished() -> void:
	set_process(false)
	Settings.set_position(current_book.id, 0.0, true)
	position_changed.emit(_length, _length)
	state_changed.emit(false)

func _exit_tree() -> void:
	_save_position(true)
