extends Node
## Turns a Book into something Godot can actually play.
##
##   * mp3  -> played directly (Godot decodes MP3 natively)
##   * m4b  -> transcoded once to Ogg Vorbis with ffmpeg and cached under
##            user://cache/audio/<id>.ogg, so re-opens are instant.
##   * aax  -> decrypted with the account activation bytes, then transcoded/cached
##   * aaxc -> decrypted with the per-file voucher key/iv, then transcoded/cached
##
## Registered as the "Transcoder" autoload. This is the single choke point for
## turning a file into a playable stream; the Audible DRM decrypt happens here in
## the same ffmpeg pass, so library/player code stays format-agnostic.
##
## ffmpeg runs as a child process (OS.create_process) so it can be cancelled and
## its `-progress` file polled for a real progress bar.

signal transcode_started(book: Book)
signal transcode_progress(book: Book, ratio: float)
signal transcode_finished(book: Book, ok: bool, path: String)

var _pid: int = -1
var _book: Book = null
var _out_final: String = ""
var _out_part: String = ""
var _progress_file: String = ""
var _total: float = 0.0

func _ready() -> void:
	set_process(false)

## Path to a ready-to-play file, or "" if a transcode is required first.
func playable_path(book: Book) -> String:
	if book.format == "mp3":
		return book.file_path
	var ogg := _audio_cache().path_join(book.id + ".ogg")
	return ogg if FileAccess.file_exists(ogg) else ""

func is_busy() -> bool:
	return _pid != -1

## Whether ffmpeg + ffprobe are callable on the user's PATH. Used at startup to
## warn if the one external dependency is missing.
func ffmpeg_available() -> bool:
	return _tool_ok("ffmpeg") and _tool_ok("ffprobe")

func _tool_ok(tool_name: String) -> bool:
	var out: Array = []
	return OS.execute(tool_name, ["-version"], out, false) == 0

# --- Playback-cache pre-generation ------------------------------------------

func ogg_cache_path(book_id: String) -> String:
	return _audio_cache().path_join(book_id + ".ogg")

func _file_len(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return int(f.get_length()) if f != null else 0

## True if the playback ogg for a (non-DRM) source file already exists.
func has_ogg_for(src_path: String) -> bool:
	var size := _file_len(src_path)
	if size <= 0:
		return false
	return FileAccess.file_exists(ogg_cache_path(Book.compute_id(src_path, size)))

## Pre-build the playback ogg for a decrypted file (e.g. a freshly downloaded
## m4b) so the first open is instant. Deletes any stale .part first to avoid
## resuming onto a corrupt file. Uses its own ffmpeg process, independent of the
## playback job. Returns true on success.
func pregenerate_ogg(src_path: String) -> bool:
	var size := _file_len(src_path)
	if size <= 0:
		return false
	var dest := ogg_cache_path(Book.compute_id(src_path, size))
	if FileAccess.file_exists(dest):
		return true
	var part := dest + ".part"
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	var pid := OS.create_process("ffmpeg", [
		"-y", "-loglevel", "error",
		"-i", src_path,
		"-vn", "-c:a", "libvorbis", "-q:a", "4", "-f", "ogg",
		part,
	])
	if pid <= 0:
		return false
	while OS.is_process_running(pid):
		await get_tree().create_timer(0.3).timeout
	if OS.get_process_exit_code(pid) == 0 and _file_len(part) > 0:
		DirAccess.rename_absolute(part, dest)
		return true
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	return false

## Ensures `book` is playable. Emits transcode_finished(book, true, path) as soon
## as it's ready (immediately for mp3 / cached ogg), otherwise starts ffmpeg and
## emits progress until done. Ignored if a transcode is already running.
func request(book: Book) -> void:
	var ready_path := playable_path(book)
	if not ready_path.is_empty():
		transcode_finished.emit.call_deferred(book, true, ready_path)
		return
	if is_busy():
		return
	# Decryption needs a secret; a cached ogg (checked above) wouldn't.
	if book.encrypted and not book.secret_ready():
		push_warning("Transcoder: %s is encrypted but no key/activation bytes available" % book.format)
		transcode_finished.emit.call_deferred(book, false, "")
		return
	_start(book)

func cancel() -> void:
	if _pid != -1:
		OS.kill(_pid)
		_cleanup_partial()
		_reset()

func _start(book: Book) -> void:
	_book = book
	_total = maxf(1.0, book.duration)
	_out_final = _audio_cache().path_join(book.id + ".ogg")
	_out_part = _out_final + ".part"
	_progress_file = _audio_cache().path_join(book.id + ".progress")
	if FileAccess.file_exists(_out_part):
		DirAccess.remove_absolute(_out_part)

	# Decryption options are INPUT options and must precede -i.
	var args := PackedStringArray(["-y", "-loglevel", "error", "-progress", _progress_file])
	match book.format:
		"aax":
			args.append_array(["-activation_bytes", Settings.get_activation_bytes()])
		"aaxc":
			args.append_array(["-audible_key", book.voucher_key, "-audible_iv", book.voucher_iv])
	args.append_array([
		"-i", book.file_path,
		"-vn",
		"-c:a", "libvorbis",
		"-q:a", "4",
		"-f", "ogg",  # explicit: the .part extension hides the real container
		_out_part,
	])
	_pid = OS.create_process("ffmpeg", args)
	if _pid <= 0:
		transcode_finished.emit(book, false, "")
		_reset()
		return
	transcode_started.emit(book)
	set_process(true)

func _process(_delta: float) -> void:
	if _pid == -1:
		return
	_report_progress()
	if not OS.is_process_running(_pid):
		_finish()

func _report_progress() -> void:
	if not FileAccess.file_exists(_progress_file):
		return
	var f := FileAccess.open(_progress_file, FileAccess.READ)
	if f == null:
		return
	var us := -1
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("out_time_us="):
			var v := line.get_slice("=", 1)
			if v.is_valid_int():
				us = v.to_int()
	if us >= 0:
		transcode_progress.emit(_book, clampf((us / 1_000_000.0) / _total, 0.0, 1.0))

func _finish() -> void:
	var ok := false
	if OS.get_process_exit_code(_pid) == 0 and FileAccess.file_exists(_out_part) \
			and FileAccess.open(_out_part, FileAccess.READ).get_length() > 0:
		DirAccess.rename_absolute(_out_part, _out_final)
		ok = true
	else:
		_cleanup_partial()
	var book := _book
	var path := _out_final if ok else ""
	if FileAccess.file_exists(_progress_file):
		DirAccess.remove_absolute(_progress_file)
	_reset()
	transcode_finished.emit(book, ok, path)

func _cleanup_partial() -> void:
	if not _out_part.is_empty() and FileAccess.file_exists(_out_part):
		DirAccess.remove_absolute(_out_part)

func _reset() -> void:
	set_process(false)
	_pid = -1
	_book = null
	_out_final = ""
	_out_part = ""
	_progress_file = ""

func _audio_cache() -> String:
	return Library.cache_dir("audio")

func _exit_tree() -> void:
	cancel()
