extends Node
## Native (no-Python) Audible account client. Registered as the "Audible"
## autoload. Implements the device-auth flow documented in
## docs/audible-protocol.md using Godot's Crypto + HTTPRequest.
##
## Phase 2a (here): external-browser login, device registration, RSA-SHA256
## request signing, and activation-bytes retrieval (which unlocks legacy .aax).
## Phase 2b will add library sync + AAXC download/voucher on this foundation.
##
## The auth bundle (tokens + device private key) is stored under
## user://audible/auth.json. TODO: encrypt at rest.

signal login_completed(success: bool, message: String)
signal activation_fetched(success: bool, message: String)
signal state_changed
signal library_synced(items: Array, message: String)
signal download_progress(asin: String, ratio: float)
signal download_converting(asin: String)
signal download_preparing(asin: String)
signal download_finished(asin: String, success: bool, message: String)

const DEVICE_TYPE := "A2CZJZGLK2JJVM"
const AUTH_PATH := "user://audible/auth.json"

const MARKETS := {
	"us": {"domain": "com", "market": "AF2M0KC94RCEA"},
	"uk": {"domain": "co.uk", "market": "A2I9A3Q2GNFNGQ"},
	"de": {"domain": "de", "market": "AN7V1F1VY261K"},
	"fr": {"domain": "fr", "market": "A2728XDNODOQ8T"},
	"ca": {"domain": "ca", "market": "A2CQZ5RBY40XE"},
	"au": {"domain": "com.au", "market": "AN7EY7DTAW63G"},
	"jp": {"domain": "co.jp", "market": "A1QAP3MOU4173J"},
}

var _crypto := Crypto.new()
var _auth: Dictionary = {}          # persisted registration bundle
var _pending: Dictionary = {}       # in-flight login: verifier, serial, client_id, country

func _ready() -> void:
	_load()
	# Resume any interrupted download/convert/prepare pipelines after startup.
	resume_pending.call_deferred()

# --- Public state -----------------------------------------------------------

func is_signed_in() -> bool:
	return _auth.has("adp_token") and _auth.has("device_private_key")

func customer_name() -> String:
	var info: Dictionary = _auth.get("customer_info", {})
	return info.get("name", info.get("given_name", ""))

func country() -> String:
	return _auth.get("country", "us")

func disconnect_account() -> void:
	_auth = {}
	if FileAccess.file_exists(AUTH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTH_PATH))
	state_changed.emit()

# --- Login: step 1, build the sign-in URL -----------------------------------

func begin_login(country_code: String = "us") -> String:
	var cc := country_code if MARKETS.has(country_code) else "us"
	var m: Dictionary = MARKETS[cc]
	var serial := _crypto.generate_random_bytes(16).hex_encode().to_upper()
	var client_id := (serial + "#" + DEVICE_TYPE).to_utf8_buffer().hex_encode()
	var verifier := _b64url(_crypto.generate_random_bytes(32))
	var challenge := _b64url(_sha256(verifier.to_utf8_buffer()))
	_pending = {"country": cc, "serial": serial, "client_id": client_id, "verifier": verifier}

	var dom: String = m.domain
	var params := {
		"openid.oa2.response_type": "code",
		"openid.oa2.code_challenge_method": "S256",
		"openid.oa2.code_challenge": challenge,
		"openid.return_to": "https://www.amazon.%s/ap/maplanding" % dom,
		"openid.assoc_handle": "amzn_audible_ios_" + cc,
		"openid.identity": "http://specs.openid.net/auth/2.0/identifier_select",
		"pageId": "amzn_audible_ios",
		"accountStatusPolicy": "P1",
		"openid.claimed_id": "http://specs.openid.net/auth/2.0/identifier_select",
		"openid.mode": "checkid_setup",
		"openid.ns.oa2": "http://www.amazon.com/ap/ext/oauth/2",
		"openid.oa2.client_id": "device:" + client_id,
		"openid.ns.pape": "http://specs.openid.net/extensions/pape/1.0",
		"marketPlaceId": m.market,
		"openid.oa2.scope": "device_auth_access",
		"forceMobileLayout": "true",
		"openid.ns": "http://specs.openid.net/auth/2.0",
		"openid.pape.max_auth_age": "0",
	}
	return "https://www.amazon.%s/ap/signin?%s" % [dom, _encode_query(params)]

# --- Login: step 2, register the device from the redirect URL ----------------

func finish_login(redirect_url: String) -> void:
	if _pending.is_empty():
		login_completed.emit(false, "Start the sign-in first.")
		return
	var code := _extract_query_value(redirect_url, "openid.oa2.authorization_code")
	if code.is_empty():
		login_completed.emit(false, "Couldn't find an authorization code in that URL. Make sure you pasted the full address after signing in.")
		return

	var cc: String = _pending.country
	var dom: String = MARKETS[cc].domain
	var body := {
		"requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
		"cookies": {"website_cookies": [], "domain": ".amazon.%s" % dom},
		"registration_data": {
			"domain": "Device",
			"app_version": "3.56.2",
			"device_serial": _pending.serial,
			"device_type": DEVICE_TYPE,
			# Amazon fills these %TOKENS% in server-side; must match the real client.
			"device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
			"os_version": "15.0.0",
			"software_version": "35602678",
			"device_model": "iPhone",
			"app_name": "Audible",
		},
		"auth_data": {
			"client_id": _pending.client_id,
			"authorization_code": code,
			"code_verifier": _pending.verifier,
			"code_algorithm": "SHA-256",
			"client_domain": "DeviceLegacy",
		},
		"requested_extensions": ["device_info", "customer_info"],
	}
	# Match the reference client: minimal headers (Content-Type only).
	var headers := PackedStringArray(["Content-Type: application/json"])
	var resp := await _http("https://api.amazon.%s/auth/register" % dom, headers,
			HTTPClient.METHOD_POST, JSON.stringify(body))
	var body_text := (resp.body as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(body_text)
	if resp.get("result", -1) != HTTPRequest.RESULT_SUCCESS:
		login_completed.emit(false, "Couldn't reach Amazon (network error). Check your connection and try again.")
		return
	if not resp.ok:
		push_warning("Audible register failed HTTP %s: %s" % [resp.status, body_text])
		login_completed.emit(false, _register_error(parsed, resp.status))
		return
	var success = parsed.get("response", {}).get("success", {}) if parsed is Dictionary else {}
	if success.is_empty():
		push_warning("Audible register: missing success in %s" % body_text)
		login_completed.emit(false, _register_error(parsed, resp.status))
		return

	var tokens: Dictionary = success.get("tokens", {})
	var mac: Dictionary = tokens.get("mac_dms", {})
	var bearer: Dictionary = tokens.get("bearer", {})
	var ext: Dictionary = success.get("extensions", {})
	_auth = {
		"country": cc,
		"device_serial": _pending.serial,
		"adp_token": mac.get("adp_token", ""),
		"device_private_key": mac.get("device_private_key", ""),
		"access_token": bearer.get("access_token", ""),
		"refresh_token": bearer.get("refresh_token", ""),
		"store_authentication_cookie": tokens.get("store_authentication_cookie", {}),
		"customer_info": ext.get("customer_info", {}),
		"device_info": ext.get("device_info", {}),
	}
	_pending = {}
	if _auth.adp_token.is_empty() or _auth.device_private_key.is_empty():
		_auth = {}
		login_completed.emit(false, "Registration response was missing device credentials.")
		return
	_save()
	state_changed.emit()
	login_completed.emit(true, "Connected as %s." % customer_name())
	fetch_activation_bytes()

## Turns Amazon's register error body into a human-readable message.
func _register_error(parsed, status) -> String:
	if parsed is Dictionary:
		var err = parsed.get("response", {}).get("error", {})
		if err is Dictionary and err.has("message"):
			return "Amazon rejected sign-in (%s): %s" % [err.get("code", str(status)), err.get("message")]
		if parsed.has("error_description"):
			return "Amazon: %s" % parsed["error_description"]
		if parsed.has("message"):
			return "Amazon: %s" % parsed["message"]
	return "Amazon returned HTTP %s. The code is single-use — press \"Open Amazon sign-in\" again to get a fresh one, then paste the new URL right away." % status

# --- Activation bytes (unlocks legacy .aax) ---------------------------------

func fetch_activation_bytes() -> void:
	if not is_signed_in():
		activation_fetched.emit(false, "Not connected.")
		return
	var path := "/license/token?player_manuf=Audible,iPhone&action=register&player_model=iPhone"
	var headers := _sign_headers("GET", path, "")
	headers.append("User-Agent: Audible Download Manager")
	var resp := await _http("https://www.audible.com" + path, headers, HTTPClient.METHOD_GET, "")
	if not resp.ok:
		activation_fetched.emit(false, "Network error fetching activation bytes.")
		return
	var ab := _extract_activation_bytes(resp.body)
	if ab.is_empty():
		activation_fetched.emit(false, "Could not read activation bytes from the response.")
		return
	Settings.set_activation_bytes(ab)
	activation_fetched.emit(true, "Activation bytes retrieved — your AAX books are unlocked.")

func _extract_activation_bytes(blob: PackedByteArray) -> String:
	if blob.size() < 0x238:
		return ""
	var tail := blob.slice(blob.size() - 0x238)  # last 568 bytes
	var key := PackedByteArray()
	for i in range(8):                            # 8 * (70 data + 1 separator)
		key.append_array(tail.slice(i * 71, i * 71 + 70))
	if key.size() < 4:
		return ""
	return "%08x" % key.decode_u32(0)             # first 4 bytes, little-endian

# --- Library sync -----------------------------------------------------------

func _api_domain() -> String:
	return MARKETS.get(country(), {"domain": "com"}).domain

## Fetch the account's library; emits library_synced(items, message).
func sync_library() -> void:
	if not is_signed_in():
		library_synced.emit([], "Not connected.")
		return
	var groups := "contributors,product_desc,product_attrs,media,series"
	var path := "/1.0/library?response_groups=%s&num_results=1000&page=1&sort_by=-PurchaseDate" % groups
	var resp := await _api_get(path)
	if not resp.ok:
		push_warning("Audible library HTTP %s: %s" % [resp.status, (resp.body as PackedByteArray).get_string_from_utf8()])
		library_synced.emit([], "Couldn't fetch your library (HTTP %s)." % resp.status)
		return
	var parsed = JSON.parse_string((resp.body as PackedByteArray).get_string_from_utf8())
	var items: Array = []
	if parsed is Dictionary:
		for it in parsed.get("items", []):
			items.append(_map_item(it))
	library_synced.emit(items, "%d title%s in your Audible library." % [items.size(), "" if items.size() == 1 else "s"])

func _map_item(it: Dictionary) -> Dictionary:
	var authors := PackedStringArray()
	for a in it.get("authors", []):
		authors.append(a.get("name", ""))
	var narrators := PackedStringArray()
	for n in it.get("narrators", []):
		narrators.append(n.get("name", ""))
	var cover := ""
	var imgs = it.get("product_images", {})
	if imgs is Dictionary and not imgs.is_empty():
		cover = imgs.get("500", imgs.values()[0])
	var series := ""
	var ser = it.get("series", [])
	if ser is Array and not ser.is_empty():
		series = ser[0].get("title", "")
	var asin := str(it.get("asin", ""))
	return {
		"asin": asin,
		"title": it.get("title", ""),
		"subtitle": it.get("subtitle", ""),
		"authors": ", ".join(authors),
		"narrators": ", ".join(narrators),
		"runtime_min": int(it.get("runtime_length_min", 0)),
		"cover_url": cover,
		"series": series,
		"release_date": str(it.get("release_date", it.get("issue_date", ""))),
		"downloaded": is_downloaded(asin),
	}

## Pipeline artifacts for a book, keyed by asin. Committed (stage-complete)
## files have stable names; in-progress steps use .part temps that are discarded
## before the step is (re)started, so an interrupted run never corrupts state.
##   download: <asin>.dl.part  -> commits to  <asin>.aaxc (+ <asin>.voucher)
##   convert : <asin>.m4b.part -> commits to  <asin>.m4b (then aaxc+voucher removed)
##   prepare : <id>.ogg.part   -> commits to  cache/audio/<id>.ogg  (Transcoder)
func _m4b_path(asin: String) -> String:
	return Library.download_dir().path_join(asin + ".m4b")

func _aaxc_path(asin: String) -> String:
	return Library.download_dir().path_join(asin + ".aaxc")

func _voucher_path(asin: String) -> String:
	return Library.download_dir().path_join(asin + ".voucher")

func _dl_part(asin: String) -> String:
	return Library.download_dir().path_join(asin + ".dl.part")

func _m4b_part(asin: String) -> String:
	return Library.download_dir().path_join(asin + ".m4b.part")

func is_downloaded(asin: String) -> bool:
	return FileAccess.file_exists(_m4b_path(asin)) or FileAccess.file_exists(_aaxc_path(asin))

func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _write_voucher(asin: String, key: String, iv: String) -> void:
	var f := FileAccess.open(_voucher_path(asin), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"key": key, "iv": iv}))

func _read_voucher(asin: String) -> Dictionary:
	var f := FileAccess.open(_voucher_path(asin), FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}

# --- Download pipeline -------------------------------------------------------

## Full pipeline: download the AAXC, then losslessly decrypt/remux it to a
## DRM-free .m4b (chapters + cover), then pre-build the playback ogg so the
## first open is instant. Each stage commits atomically for safe resume.
func download_book(item: Dictionary) -> void:
	var asin := str(item.get("asin", ""))
	if asin.is_empty():
		download_finished.emit(asin, false, "Missing asin.")
		return
	if FileAccess.file_exists(_m4b_path(asin)):
		download_finished.emit(asin, true, "Already downloaded.")
		return
	var lic := await _get_license(asin)
	if not lic.get("ok", false):
		download_finished.emit(asin, false, lic.get("error", "License request failed."))
		return
	# Stage 1: download to a .part (scanner ignores it), then commit.
	var dl := _dl_part(asin)
	_rm(dl)
	if not await _download_file(lic.url, dl, asin):
		_rm(dl)
		download_finished.emit(asin, false, "Download failed.")
		return
	_write_voucher(asin, lic.key, lic.iv)
	_rm(_aaxc_path(asin))
	DirAccess.rename_absolute(dl, _aaxc_path(asin))
	# Stages 2 + 3.
	await _process_from_aaxc(asin)

## Convert (stage 2) + prepare ogg (stage 3), starting from a committed
## <asin>.aaxc + <asin>.voucher.
func _process_from_aaxc(asin: String) -> void:
	var v := _read_voucher(asin)
	if v.is_empty():
		download_finished.emit(asin, false, "Missing voucher; cannot convert.")
		return
	download_converting.emit(asin)
	var part := _m4b_part(asin)
	_rm(part)  # discard any partial output from a previous interrupted convert
	var ok := await _convert_aaxc_to_m4b(_aaxc_path(asin), v.get("key", ""), v.get("iv", ""), part)
	if not ok:
		_rm(part)
		# Keep the encrypted file + voucher; it still plays via the aaxc path.
		download_finished.emit(asin, true, "Downloaded (kept encrypted file; conversion failed).")
		return
	_rm(_m4b_path(asin))
	DirAccess.rename_absolute(part, _m4b_path(asin))
	_rm(_aaxc_path(asin))
	_rm(_voucher_path(asin))
	# Stage 3: pre-build the playback cache.
	download_preparing.emit(asin)
	await Transcoder.pregenerate_ogg(_m4b_path(asin))
	download_finished.emit(asin, true, "Downloaded & ready to play.")

# --- Resume interrupted pipelines on launch ---------------------------------

## Continue any book whose pipeline is incomplete, from the last completed
## stage, discarding partial next-stage output first. Runs stages sequentially.
func resume_pending() -> void:
	for asin in _pending_asins():
		await _resume_asin(asin)

func _pending_asins() -> Array:
	var found := {}
	var dir := DirAccess.open(Library.download_dir())
	if dir:
		dir.list_dir_begin()
		var n := dir.get_next()
		while n != "":
			if not dir.current_is_dir():
				match n.get_extension():
					"m4b":
						if not Transcoder.has_ogg_for(_m4b_path(n.get_basename())):
							found[n.get_basename()] = true
					"aaxc":
						found[n.get_basename()] = true
					"part":  # "<asin>.dl.part" / "<asin>.m4b.part"
						found[n.get_basename().get_basename()] = true
			n = dir.get_next()
		dir.list_dir_end()
	return found.keys()

func _resume_asin(asin: String) -> void:
	if FileAccess.file_exists(_m4b_path(asin)):
		_rm(_m4b_part(asin))
		if not Transcoder.has_ogg_for(_m4b_path(asin)):
			download_preparing.emit(asin)
			await Transcoder.pregenerate_ogg(_m4b_path(asin))
			download_finished.emit(asin, true, "Ready to play.")
		return
	if FileAccess.file_exists(_aaxc_path(asin)) and FileAccess.file_exists(_voucher_path(asin)):
		await _process_from_aaxc(asin)
		return
	# Incomplete download (or an aaxc with no voucher we can't use): restart.
	_rm(_dl_part(asin))
	if not FileAccess.file_exists(_voucher_path(asin)):
		_rm(_aaxc_path(asin))
	if is_signed_in():
		await download_book({"asin": asin})

## Lossless decrypt+remux AAXC -> m4b, preserving audio, chapters and cover.
func _convert_aaxc_to_m4b(aaxc: String, key: String, iv: String, dest: String) -> bool:
	var pid := OS.create_process(Ffmpeg.tool_path("ffmpeg"), [
		"-y", "-loglevel", "error",
		"-audible_key", key, "-audible_iv", iv,
		"-i", aaxc,
		"-map", "0:a", "-map", "0:v?",  # audio + cover (skip data streams)
		"-c", "copy",
		"-disposition:v:0", "attached_pic",
		"-map_chapters", "0",
		"-f", "mp4",
		dest,
	])
	if pid <= 0:
		return false
	while OS.is_process_running(pid):
		await get_tree().create_timer(0.2).timeout
	return OS.get_process_exit_code(pid) == 0 and FileAccess.file_exists(dest) \
			and FileAccess.open(dest, FileAccess.READ).get_length() > 0

func _get_license(asin: String) -> Dictionary:
	var body := JSON.stringify({
		"supported_drm_types": ["Mpeg", "Adrm"],
		"quality": "High",
		"consumption_type": "Download",
		"response_groups": "content_reference,chapter_info",
	})
	var resp := await _api_post("/1.0/content/%s/licenserequest" % asin, body)
	if not resp.ok:
		push_warning("Audible license HTTP %s: %s" % [resp.status, (resp.body as PackedByteArray).get_string_from_utf8()])
		return {"ok": false, "error": "License request failed (HTTP %s)." % resp.status}
	var parsed = JSON.parse_string((resp.body as PackedByteArray).get_string_from_utf8())
	var cl = parsed.get("content_license", {}) if parsed is Dictionary else {}
	var meta = cl.get("content_metadata", {})
	var url: String = meta.get("content_url", {}).get("offline_url", "")
	var lr: String = cl.get("license_response", "")
	if url.is_empty() or lr.is_empty():
		var reason = cl.get("message", cl.get("status_code", "incomplete license"))
		return {"ok": false, "error": "License response %s." % reason}
	var voucher := _decrypt_voucher(lr, str(cl.get("asin", asin)))
	if voucher.is_empty():
		return {"ok": false, "error": "Could not decrypt the download voucher."}
	return {"ok": true, "url": url, "key": voucher.key, "iv": voucher.iv}

## Derives the AAXC key/iv per docs/audible-protocol.md §6.
func _decrypt_voucher(license_response_b64: String, asin: String) -> Dictionary:
	var di: Dictionary = _auth.get("device_info", {})
	var device_type: String = di.get("device_type", DEVICE_TYPE)
	var serial: String = di.get("device_serial_number", _auth.get("device_serial", ""))
	var customer_id: String = _auth.get("customer_info", {}).get("user_id", "")
	var buf := (device_type + serial + customer_id + asin).to_utf8_buffer()
	var digest := _sha256(buf)
	var enc := Marshalls.base64_to_raw(license_response_b64)
	if enc.is_empty() or enc.size() % 16 != 0:
		return {}
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, digest.slice(0, 16), digest.slice(16, 32))
	var dec := aes.update(enc)
	aes.finish()
	var s := dec.get_string_from_utf8()
	var close := s.rfind("}")
	if close == -1:
		return {}
	var parsed = JSON.parse_string(s.substr(0, close + 1))
	if parsed is Dictionary and parsed.has("key") and parsed.has("iv"):
		return {"key": str(parsed.key), "iv": str(parsed.iv)}
	return {}

func _api_get(path: String) -> Dictionary:
	return await _http("https://api.audible.%s%s" % [_api_domain(), path],
			_sign_headers("GET", path, ""), HTTPClient.METHOD_GET, "")

func _api_post(path: String, body: String) -> Dictionary:
	var headers := _sign_headers("POST", path, body)
	headers.append("Content-Type: application/json")
	return await _http("https://api.audible.%s%s" % [_api_domain(), path],
			headers, HTTPClient.METHOD_POST, body)

## Streams a (pre-signed CDN) URL to disk, emitting download_progress.
func _download_file(url: String, dest_path: String, asin: String) -> bool:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.download_file = dest_path
	add_child(req)
	var done := {"v": false, "r": -1, "c": 0}
	req.request_completed.connect(
		func(r, c, _h, _b): done.v = true; done.r = r; done.c = c, CONNECT_ONE_SHOT)
	if req.request(url) != OK:
		req.queue_free()
		return false
	while not done.v:
		var total := req.get_body_size()
		if total > 0:
			download_progress.emit(asin, clampf(float(req.get_downloaded_bytes()) / float(total), 0.0, 1.0))
		await get_tree().process_frame
	var success: bool = done.r == HTTPRequest.RESULT_SUCCESS and int(done.c) >= 200 and int(done.c) < 400
	req.queue_free()
	return success

# --- Request signing --------------------------------------------------------

func _sign_headers(method: String, path: String, body: String) -> PackedStringArray:
	var date := Time.get_datetime_string_from_system(true, false) + ".000000Z"
	var data := "%s\n%s\n%s\n%s\n%s" % [method, path, date, body, _auth.adp_token]
	var key := CryptoKey.new()
	key.load_from_string(_auth.device_private_key, false)
	var sig := _crypto.sign(HashingContext.HASH_SHA256, _sha256(data.to_utf8_buffer()), key)
	return PackedStringArray([
		"x-adp-token: " + _auth.adp_token,
		"x-adp-alg: SHA256withRSA:1.0",
		"x-adp-signature: %s:%s" % [Marshalls.raw_to_base64(sig), date],
	])

# --- HTTP helper ------------------------------------------------------------

func _http(url: String, headers: PackedStringArray, method: int, body: String) -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "request() = %d" % err, "status": 0}
	var r: Array = await req.request_completed
	req.queue_free()
	return {
		"ok": r[0] == HTTPRequest.RESULT_SUCCESS and int(r[1]) >= 200 and int(r[1]) < 400,
		"result": r[0],
		"status": r[1],
		"headers": r[2],
		"body": r[3] as PackedByteArray,
	}

# --- Persistence ------------------------------------------------------------

func _save() -> void:
	DirAccess.make_dir_recursive_absolute("user://audible")
	var f := FileAccess.open(AUTH_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_auth))

func _load() -> void:
	if not FileAccess.file_exists(AUTH_PATH):
		return
	var f := FileAccess.open(AUTH_PATH, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			_auth = d

# --- Small utilities --------------------------------------------------------

func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(bytes)
	return hc.finish()

func _b64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")

func _encode_query(params: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in params:
		parts.append("%s=%s" % [k.uri_encode(), str(params[k]).uri_encode()])
	return "&".join(parts)

func _extract_query_value(url: String, key: String) -> String:
	var q := url
	var qi := url.find("?")
	if qi != -1:
		q = url.substr(qi + 1)
	for pair in q.split("&"):
		var kv := pair.split("=")
		if kv.size() == 2 and kv[0].uri_decode() == key:
			return kv[1].uri_decode()
	return ""
