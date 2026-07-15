# Audible / Amazon auth protocol (native implementation notes)

Reference for our GDScript reimplementation of the Audible device-auth flow
(source of truth: the open-source `mkb79/Audible` Python library). No Python at
runtime — Godot's `Crypto`/`HTTPRequest` do the work.

## Marketplaces

| country | domain | marketPlaceId  |
|---------|--------|----------------|
| us      | com    | AF2M0KC94RCEA  |
| uk      | co.uk  | A2I9A3Q2GNFNGQ |
| de      | de     | AN7V1F1VY261K  |
| fr      | fr     | A2728XDNODOQ8T |
| ca      | ca     | A2CQZ5RBY40XE  |
| au      | com.au | AN7EY7DTAW63G  |
| jp      | co.jp  | A1QAP3MOU4173J |

(others: it, in, es, br)

## 1. PKCE + device identity

- `code_verifier = base64url(random 32 bytes)` with padding stripped
- `code_challenge = base64url(sha256(code_verifier))` stripped
- `serial = uuid4().hex.upper()` (40 hex chars; we use 32 random bytes → hex upper)
- `client_id = hex( serial_ascii + "#A2CZJZGLK2JJVM" )`
- device_type `A2CZJZGLK2JJVM` is the Audible-for-iPhone app id.

## 2. Sign-in URL (external browser login)

`https://www.amazon.{domain}/ap/signin?` + urlencode(oauth_params):

```
openid.oa2.response_type        = code
openid.oa2.code_challenge_method= S256
openid.oa2.code_challenge       = {code_challenge}
openid.return_to                = https://www.amazon.{domain}/ap/maplanding
openid.assoc_handle             = amzn_audible_ios_{country}
openid.identity                 = http://specs.openid.net/auth/2.0/identifier_select
pageId                          = amzn_audible_ios
accountStatusPolicy             = P1
openid.claimed_id               = http://specs.openid.net/auth/2.0/identifier_select
openid.mode                     = checkid_setup
openid.ns.oa2                   = http://www.amazon.com/ap/ext/oauth/2
openid.oa2.client_id            = device:{client_id}
openid.ns.pape                  = http://specs.openid.net/extensions/pape/1.0
marketPlaceId                   = {marketPlaceId}
openid.oa2.scope                = device_auth_access
forceMobileLayout               = true
openid.ns                       = http://specs.openid.net/auth/2.0
openid.pape.max_auth_age        = 0
```

User logs in in a real browser (handles CAPTCHA/2FA). Amazon redirects to
`.../ap/maplanding?...&openid.oa2.authorization_code=CODE`. User copies that
final URL back; we extract `openid.oa2.authorization_code`.

## 3. Device registration

`POST https://api.amazon.{domain}/auth/register`  (JSON)

```json
{
  "requested_token_type": ["bearer","mac_dms","website_cookies","store_authentication_cookie"],
  "cookies": {"website_cookies": [], "domain": ".amazon.{domain}"},
  "registration_data": {
    "domain": "Device",
    "app_version": "3.56.2",
    "device_serial": "{serial}",
    "device_type": "A2CZJZGLK2JJVM",
    "device_name": "Audiobooks for Godot",
    "os_version": "15.0.0",
    "software_version": "35602678",
    "device_model": "iPhone",
    "app_name": "Audible"
  },
  "auth_data": {
    "client_id": "{client_id}",
    "authorization_code": "{code}",
    "code_verifier": "{code_verifier}",
    "code_algorithm": "SHA-256",
    "client_domain": "DeviceLegacy"
  },
  "requested_extensions": ["device_info","customer_info"]
}
```

Response → `response.success`:
- `tokens.mac_dms.adp_token`, `tokens.mac_dms.device_private_key` (PEM)
- `tokens.bearer.access_token`, `.refresh_token`, `.expires_in`
- `tokens.store_authentication_cookie`, `tokens.website_cookies`
- `extensions.device_info`, `extensions.customer_info` (name, customer id)

## 4. Signed API requests

```
date = <UTC ISO8601> + "Z"        # same string in data and header
data = method + "\n" + path + "\n" + date + "\n" + body + "\n" + adp_token
sig  = base64( RSA_SHA256_sign(device_private_key, data) )
```
Headers:
- `x-adp-token: {adp_token}`
- `x-adp-alg: SHA256withRSA:1.0`
- `x-adp-signature: {sig}:{date}`

`path` includes the query string.

## 5. Activation bytes (unlocks legacy .aax)

Signed `GET https://www.audible.com/license/token?player_manuf=Audible,iPhone&action=register&player_model=iPhone`
→ binary "activation blob". Extract:
1. take the last `0x238` (568) bytes
2. remove a separator byte every 70 (`unpack "70s1x"*8` → 560 bytes)
3. first 4 bytes as little-endian uint32 → hex, left-pad to 8 chars

## 6. Library + download (Phase 2b)

- `GET https://api.audible.{domain}/1.0/library?response_groups=...&num_results=1000`
- `POST https://api.audible.{domain}/1.0/content/{asin}/licenserequest`
  body `{consumption_type:"Download", drm_type:"Adrm", quality:"High", response_groups:"..."}`
  → `content_license` with an encrypted `license_response` (the AAXC voucher:
  key+iv) and a download URL. Voucher is AES-decrypted with a key/iv derived
  from `device_serial + customer_id + asin`. (Implemented in Phase 2b.)
