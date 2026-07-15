class_name Book
extends RefCounted
## In-memory model of a single audiobook, populated from ffprobe output by
## Library. Purely data + light derived helpers; no I/O of its own.

var file_path: String = ""
var format: String = ""            # "mp3", "m4b", "aax", or "aaxc"
var file_size: int = 0

## DRM: aax needs account activation bytes; aaxc needs a per-file key/iv voucher.
var encrypted: bool = false
var voucher_key: String = ""       # aaxc only (hex)
var voucher_iv: String = ""        # aaxc only (hex)

var title: String = ""
var author: String = ""            # tag: artist
var narrator: String = ""          # tag: composer (Audible convention)
var series: String = ""            # tag: album
var genre: String = ""
var year: String = ""
var description: String = ""       # tag: comment / description

var duration: float = 0.0          # seconds
var bitrate: int = 0
var cover_path: String = ""        # extracted cover in cache dir, or "" if none

## chapters: Array of { "title": String, "start": float, "end": float }
var chapters: Array[Dictionary] = []

## Stable id derived from path + size, used to key the cover/transcode cache
## and saved playback positions. Survives library folder rescans.
var id: String = ""

func _display_title() -> String:
	return title if not title.is_empty() else file_path.get_file().get_basename()

## Chapter index containing time `t` (seconds); 0 if no chapter metadata.
func chapter_at(t: float) -> int:
	for i in range(chapters.size()):
		if t >= chapters[i].start and t < chapters[i].end:
			return i
	return maxi(0, chapters.size() - 1) if not chapters.is_empty() else 0

## Whether we have the secret needed to decrypt/play this book.
func secret_ready() -> bool:
	match format:
		"aax":
			return Settings.has_activation_bytes()
		"aaxc":
			return not voucher_key.is_empty() and not voucher_iv.is_empty()
		_:
			return true

static func compute_id(path: String, size: int) -> String:
	return ("%s|%d" % [path, size]).sha1_text().substr(0, 16)
