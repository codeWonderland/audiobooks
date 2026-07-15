extends Node
## Scans for audiobooks (mp3, m4b, aax, aaxc), reads metadata and chapters with
## ffprobe, and extracts embedded cover art with ffmpeg. Registered as the
## "Library" autoload.
##
## Two roots are scanned and merged: the app's own download folder
## (user://books, where Audible downloads land) which is always included, plus
## an optional user-chosen custom folder from Settings.
##
## Scanning happens on a worker thread; results are marshalled back to the main
## thread via call_deferred so UI code can rely on main-thread signal delivery.
## Probe results + covers are cached under user://cache keyed by a stable book
## id (path + size), making subsequent scans effectively instant.

signal scan_started(total: int)
signal book_found(book: Book)
signal scan_progress(done: int, total: int)
signal scan_finished(books: Array)

const AUDIO_EXTS := ["mp3", "m4b", "m4a", "aax", "aaxc"]

var books: Array[Book] = []
var _thread: Thread = null
var _cover_textures: Dictionary = {}  # book.id -> Texture2D

func _exit_tree() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()

# --- Cache paths ------------------------------------------------------------

func cache_dir(sub: String) -> String:
	var p := "user://cache/%s" % sub
	DirAccess.make_dir_recursive_absolute(p)
	return ProjectSettings.globalize_path(p)

## Where Audible downloads are stored (always scanned). Real OS path.
func download_dir() -> String:
	DirAccess.make_dir_recursive_absolute("user://books")
	return ProjectSettings.globalize_path("user://books")

## The folders scanned by rescan(): the app download folder plus, if set and
## still present, the user's custom folder.
func roots() -> Array[String]:
	var out: Array[String] = [download_dir()]
	var custom := Settings.get_library_folder()
	if not custom.is_empty() and DirAccess.dir_exists_absolute(custom) \
			and custom.simplify_path() != download_dir().simplify_path():
		out.append(custom)
	return out

# --- Scanning ---------------------------------------------------------------

## Rescan all roots (download folder + optional custom folder).
func rescan() -> void:
	scan(roots())

func scan(scan_roots: Array[String]) -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	books.clear()
	_thread = Thread.new()
	_thread.start(_scan_thread.bind(scan_roots))

func _scan_thread(scan_roots: Array) -> void:
	var files := _gather_files(scan_roots)
	call_deferred("_emit_started", files.size())
	var done := 0
	for path in files:
		var book := _load_book(path)
		done += 1
		if book != null:
			call_deferred("_emit_found", book, done, files.size())
		else:
			call_deferred("_emit_progress", done, files.size())
	call_deferred("_emit_finished")

func _gather_files(scan_roots: Array) -> Array[String]:
	var result: Array[String] = []
	var seen := {}
	var stack: Array[String] = []
	for r in scan_roots:
		stack.append(r)
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not name.begins_with("."):
				var full := dir_path.path_join(name)
				if dir.current_is_dir():
					stack.push_back(full)
				elif AUDIO_EXTS.has(name.get_extension().to_lower()) and not seen.has(full):
					seen[full] = true
					result.append(full)
			name = dir.get_next()
		dir.list_dir_end()
	result.sort()
	return result

# Signal emitters (run on main thread via call_deferred).
func _emit_started(total: int) -> void:
	scan_started.emit(total)

func _emit_found(book: Book, done: int, total: int) -> void:
	books.append(book)
	book_found.emit(book)
	scan_progress.emit(done, total)

func _emit_progress(done: int, total: int) -> void:
	scan_progress.emit(done, total)

func _emit_finished() -> void:
	scan_finished.emit(books)

# --- Per-file metadata ------------------------------------------------------

func _load_book(path: String) -> Book:
	var size := _file_size(path)
	if size <= 0:
		return null
	var id := Book.compute_id(path, size)
	var meta_path := "user://cache/meta/%s.json" % id
	DirAccess.make_dir_recursive_absolute("user://cache/meta")

	var data: Dictionary
	if FileAccess.file_exists(meta_path):
		var f := FileAccess.open(meta_path, FileAccess.READ)
		if f:
			data = JSON.parse_string(f.get_as_text())
	if data.is_empty():
		data = _probe(path)
		if data.is_empty():
			return null
		var wf := FileAccess.open(meta_path, FileAccess.WRITE)
		if wf:
			wf.store_string(JSON.stringify(data))

	var book := _book_from_data(path, size, id, data)
	_ensure_cover(book)
	return book

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	return int(n)

func _probe(path: String) -> Dictionary:
	var out: Array = []
	var code := OS.execute("ffprobe", [
		"-v", "quiet",
		"-output_format", "json",
		"-show_format",
		"-show_chapters",
		path,
	], out, false)
	if code != 0 or out.is_empty():
		return {}
	var parsed = JSON.parse_string(out[0])
	return parsed if parsed is Dictionary else {}

func _book_from_data(path: String, size: int, id: String, data: Dictionary) -> Book:
	var book := Book.new()
	book.file_path = path
	book.file_size = size
	book.id = id
	book.format = path.get_extension().to_lower()
	if book.format == "m4a":
		book.format = "m4b"  # same aac container, treat identically
	book.encrypted = book.format in ["aax", "aaxc"]
	if book.format == "aaxc":
		var voucher := _load_voucher(path)
		book.voucher_key = voucher.get("key", "")
		book.voucher_iv = voucher.get("iv", "")

	var fmt: Dictionary = data.get("format", {})
	book.duration = float(fmt.get("duration", "0"))
	book.bitrate = int(fmt.get("bit_rate", "0"))

	var tags: Dictionary = _lower_keys(fmt.get("tags", {}))
	book.title = tags.get("title", "")
	book.author = tags.get("artist", tags.get("album_artist", ""))
	book.narrator = tags.get("composer", "")
	book.series = tags.get("album", "")
	book.genre = tags.get("genre", "")
	book.year = str(tags.get("date", tags.get("year", ""))).left(4)
	book.description = tags.get("description", tags.get("comment", ""))

	for c in data.get("chapters", []):
		var ctags: Dictionary = _lower_keys(c.get("tags", {}))
		book.chapters.append({
			"title": ctags.get("title", "Chapter %d" % (book.chapters.size() + 1)),
			"start": float(c.get("start_time", "0")),
			"end": float(c.get("end_time", "0")),
		})
	return book

func _lower_keys(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d.keys():
		out[str(k).to_lower()] = d[k]
	return out

## Reads the AES key/iv for an .aaxc file from a companion "<name>.voucher" JSON.
## Accepts our simple {"key","iv"} shape or an audible-cli decrypted voucher
## ({"content_license": {"license_response": {"key","iv"}}}).
func _load_voucher(aaxc_path: String) -> Dictionary:
	var vp := aaxc_path.get_basename() + ".voucher"
	if not FileAccess.file_exists(vp):
		return {}
	var f := FileAccess.open(vp, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		if data.has("key") and data.has("iv"):
			return {"key": data["key"], "iv": data["iv"]}
		var lr = data.get("content_license", {}).get("license_response", {})
		if lr is Dictionary and lr.has("key") and lr.has("iv"):
			return {"key": lr["key"], "iv": lr["iv"]}
	return {}

# --- Cover art --------------------------------------------------------------

func _ensure_cover(book: Book) -> void:
	var covers := cache_dir("covers")
	var jpg := covers.path_join(book.id + ".jpg")
	if FileAccess.file_exists(jpg):
		book.cover_path = jpg
		return
	# Attempt to extract an embedded cover; harmless no-op if none present.
	var out: Array = []
	OS.execute("ffmpeg", [
		"-y", "-loglevel", "quiet",
		"-i", book.file_path,
		"-map", "0:v:0",
		"-frames:v", "1",
		"-f", "image2",
		jpg,
	], out, true)
	if FileAccess.file_exists(jpg) and _file_size(jpg) > 0:
		book.cover_path = jpg

## Returns the cover as a Texture2D (cached), or null if the book has none.
func cover_texture(book: Book) -> Texture2D:
	if _cover_textures.has(book.id):
		return _cover_textures[book.id]
	if book.cover_path.is_empty():
		return null
	var img := Image.new()
	if img.load(book.cover_path) != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	_cover_textures[book.id] = tex
	return tex
