class_name Ffmpeg
extends RefCounted
## Resolves the absolute path to the ffmpeg / ffprobe binaries.
##
## GUI apps launched from Finder/Dock on macOS do NOT inherit the shell PATH, so
## a bare "ffmpeg" fails even after `brew install ffmpeg` succeeds: Homebrew
## installs to /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel),
## neither of which is on a bundled app's minimal PATH. We look in the usual
## install dirs, then ask the login shell, and finally fall back to the bare
## name (which still resolves when the app is launched from a terminal, or on
## platforms where GUI apps inherit a full PATH). Results are cached per name.

static var _cache: Dictionary = {}

## Absolute path to `tool_name` (e.g. "ffmpeg" / "ffprobe"), or the bare name if
## it can't be located anywhere. Safe to pass straight to OS.execute /
## OS.create_process.
static func tool_path(tool_name: String) -> String:
	if _cache.has(tool_name):
		return _cache[tool_name]
	var resolved := _locate(tool_name)
	_cache[tool_name] = resolved
	return resolved

## True if the resolved ffmpeg advertises `encoder_name` in its -encoders list.
## Cached. Used to pick an output codec this particular ffmpeg build actually
## supports — the default Homebrew build, for instance, ships libmp3lame but
## not libvorbis.
static func has_encoder(encoder_name: String) -> bool:
	var key := "encoder:" + encoder_name
	if _cache.has(key):
		return _cache[key]
	var out: Array = []
	var present := false
	if OS.execute(tool_path("ffmpeg"), ["-hide_banner", "-encoders"], out, false) == 0 \
			and not out.is_empty():
		# Lines look like " A....D libmp3lame  libmp3lame MP3 ..."; token[1] is the name.
		for line in String(out[0]).split("\n"):
			var parts := line.strip_edges().split(" ", false)
			if parts.size() >= 2 and parts[1] == encoder_name:
				present = true
				break
	_cache[key] = present
	return present

## Forget cached lookups so a freshly-installed binary is picked up without an
## app restart (used by the "Re-check" button on the ffmpeg notice).
static func reset() -> void:
	_cache.clear()

static func _locate(tool_name: String) -> String:
	var exe := tool_name
	if OS.get_name() == "Windows":
		exe += ".exe"
	# 1. Common install locations, checked directly (no subprocess).
	for d in _search_dirs():
		var p := d.path_join(exe)
		if FileAccess.file_exists(p):
			return p
	# 2. Ask the user's login shell (covers custom PATHs: MacPorts, nix, asdf, a
	#    non-standard Homebrew prefix, etc.).
	if OS.get_name() != "Windows":
		var shell := OS.get_environment("SHELL")
		if shell.is_empty():
			shell = "/bin/sh"
		var out: Array = []
		if OS.execute(shell, ["-lc", "command -v " + tool_name], out, false) == 0 \
				and not out.is_empty():
			var line := String(out[0]).strip_edges().get_slice("\n", 0).strip_edges()
			if not line.is_empty() and FileAccess.file_exists(line):
				return line
	# 3. Fall back to the bare name.
	return tool_name

static func _search_dirs() -> PackedStringArray:
	match OS.get_name():
		"macOS":
			return PackedStringArray([
				"/opt/homebrew/bin",  # Apple Silicon Homebrew
				"/usr/local/bin",     # Intel Homebrew
				"/opt/local/bin",     # MacPorts
				"/usr/bin",
			])
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return PackedStringArray([
				"/usr/local/bin", "/usr/bin", "/bin", "/snap/bin",
			])
	return PackedStringArray()
