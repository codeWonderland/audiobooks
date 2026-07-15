class_name Book
extends RefCounted
## In-memory model of a single audiobook, populated from ffprobe output by
## Library. Purely data + light derived helpers; no I/O of its own.

var file_path: String = ""
var format: String = ""            # "mp3" or "m4b"
var file_size: int = 0

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

static func compute_id(path: String, size: int) -> String:
	return ("%s|%d" % [path, size]).sha1_text().substr(0, 16)
