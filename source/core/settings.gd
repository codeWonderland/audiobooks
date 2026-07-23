extends Node
## Persistent app settings + playback progress, stored in user://settings.cfg.
## Registered as the "Settings" autoload.

const PATH := "user://settings.cfg"

var _cfg := ConfigFile.new()

func _ready() -> void:
	_cfg.load(PATH)  # missing file is fine on first run

func _flush() -> void:
	_cfg.save(PATH)

# --- Library folder ---------------------------------------------------------

func get_library_folder() -> String:
	return _cfg.get_value("library", "folder", "")

func set_library_folder(path: String) -> void:
	_cfg.set_value("library", "folder", path)
	_flush()

# --- Playback speed (global default) ---------------------------------------

func get_speed() -> float:
	return _cfg.get_value("playback", "speed", 1.0)

func set_speed(v: float) -> void:
	_cfg.set_value("playback", "speed", v)
	_flush()

func get_volume_db() -> float:
	return _cfg.get_value("playback", "volume_db", 0.0)

func set_volume_db(v: float) -> void:
	_cfg.set_value("playback", "volume_db", v)
	_flush()

## The most recently opened book's id, so it can be re-selected on next launch.
func get_last_book() -> String:
	return _cfg.get_value("playback", "last_book", "")

func set_last_book(id: String) -> void:
	_cfg.set_value("playback", "last_book", id)
	_flush()

# --- Audible / DRM secrets --------------------------------------------------

## Account-wide activation bytes (8 hex chars) used to decrypt legacy .aax
## files. Populated manually in Settings or by the Audible client (Phase 2).
func get_activation_bytes() -> String:
	return _cfg.get_value("audible", "activation_bytes", "")

func set_activation_bytes(hex: String) -> void:
	_cfg.set_value("audible", "activation_bytes", hex.strip_edges().to_lower())
	_flush()

func has_activation_bytes() -> bool:
	return not get_activation_bytes().is_empty()

# --- Per-book resume position ----------------------------------------------

func get_position(book_id: String) -> float:
	return _cfg.get_value("progress", book_id, 0.0)

## Saved frequently while playing; only flush to disk when asked (Player
## flushes on pause/stop/exit) to avoid hammering the filesystem.
func set_position(book_id: String, seconds: float, flush: bool = false) -> void:
	_cfg.set_value("progress", book_id, seconds)
	if flush:
		_flush()

func has_progress(book_id: String) -> bool:
	return _cfg.has_section_key("progress", book_id) and get_position(book_id) > 1.0
