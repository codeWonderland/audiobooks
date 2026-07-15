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
