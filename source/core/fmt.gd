class_name Fmt
extends RefCounted
## Static formatting helpers for durations, shared by the library and player UI.

## "9:43", "1:09:43" — compact elapsed/remaining clock used on the player.
static func clock(seconds: float) -> String:
	seconds = maxf(0.0, floorf(seconds))
	var h := int(seconds) / 3600
	var m := (int(seconds) % 3600) / 60
	var s := int(seconds) % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]

## "11h 0m left" — human summary used under the scrubber.
static func time_left(seconds: float) -> String:
	seconds = maxf(0.0, floorf(seconds))
	var h := int(seconds) / 3600
	var m := (int(seconds) % 3600) / 60
	if h > 0:
		return "%dh %dm left" % [h, m]
	return "%dm left" % m

## "11h 32m" — total duration shown in the sidebar.
static func duration(seconds: float) -> String:
	seconds = maxf(0.0, floorf(seconds))
	var h := int(seconds) / 3600
	var m := (int(seconds) % 3600) / 60
	if h > 0:
		return "%dh %dm" % [h, m]
	return "%dm" % m

static func file_size(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (bytes / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (bytes / 1048576.0)
	return "%.0f KB" % (bytes / 1024.0)
