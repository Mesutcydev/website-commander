#!/bin/bash
# Attach "What to Test" (whatsNew) text to a TestFlight build via App Store Connect API.
#
# Usage (usually called from release-build-siteagent.sh after upload):
#   ./Scripts/set-testflight-whatsnew.sh \
#     --build 2026070906 \
#     --notes Documentation/WhatsNew.txt
#
# Env (same defaults as the release script):
#   KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID / ASC_APP_ID
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_NUMBER=""
NOTES_FILE="${WHATS_NEW_FILE:-$ROOT/Documentation/WhatsNew.txt}"
LOCALE="${WHATS_NEW_LOCALE:-en-US}"
APP_ID="${ASC_APP_ID:-6780267869}"
BLITZ_ASC_DIR="${HOME}/.blitz/asc-agent"
BLITZ_ASC_CONFIG="${BLITZ_ASC_DIR}/config.json"
if [[ -f "${BLITZ_ASC_DIR}/AuthKey_BlitzKey.p8" ]]; then
  DEFAULT_KEY_PATH="${BLITZ_ASC_DIR}/AuthKey_BlitzKey.p8"
else
  DEFAULT_KEY_PATH="${HOME}/Downloads/AuthKey_B7AYY3B2FT.p8"
fi
config_value() {
  local key="$1"
  local fallback="$2"
  local value=""
  if [[ -f "$BLITZ_ASC_CONFIG" ]]; then
    value="$(plutil -extract "$key" raw "$BLITZ_ASC_CONFIG" 2>/dev/null || true)"
  fi
  echo "${value:-$fallback}"
}
KEY_PATH="${KEY_PATH:-$DEFAULT_KEY_PATH}"
KEY_ID="${ASC_KEY_ID:-$(config_value key_id B7AYY3B2FT)}"
ISSUER_ID="${ASC_ISSUER_ID:-$(config_value issuer_id 5ddc2a8a-c374-4f06-b9bd-916f198652be)}"
MAX_WAIT_SEC="${WHATS_NEW_WAIT_SEC:-600}"
POLL_SEC="${WHATS_NEW_POLL_SEC:-15}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --notes) NOTES_FILE="$2"; shift 2 ;;
    --locale) LOCALE="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$BUILD_NUMBER" ]]; then
  echo "Error: --build CURRENT_PROJECT_VERSION is required (e.g. 2026070906)"
  exit 1
fi
if [[ ! -f "$NOTES_FILE" ]]; then
  echo "Error: What's New file not found: $NOTES_FILE"
  exit 1
fi
if [[ ! -f "$KEY_PATH" ]]; then
  echo "Error: API key not found: $KEY_PATH"
  exit 1
fi

WHATS_NEW="$(python3 - <<'PY' "$NOTES_FILE"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
# ASC whatsNew soft limit ~4000 chars for beta build localization.
if len(text) > 3900:
    text = text[:3900].rstrip() + "..."
print(text)
PY
)"

if [[ -z "$WHATS_NEW" ]]; then
  echo "Error: What's New text is empty: $NOTES_FILE"
  exit 1
fi

echo "==> Attaching What's New to TestFlight build ${BUILD_NUMBER} (app ${APP_ID})..."
echo "    Notes: $NOTES_FILE"
echo "    Locale: $LOCALE"

# Mint a short-lived ASC JWT (ES256) with openssl + python3 (no PyJWT required).
ASC_TOKEN="$(
  KEY_PATH="$KEY_PATH" KEY_ID="$KEY_ID" ISSUER_ID="$ISSUER_ID" python3 - <<'PY'
import base64, json, os, subprocess, time

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

key_path = os.environ["KEY_PATH"]
key_id = os.environ["KEY_ID"]
issuer = os.environ["ISSUER_ID"]
now = int(time.time())
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {
    "iss": issuer,
    "iat": now,
    "exp": now + 15 * 60,
    "aud": "appstoreconnect-v1",
}
signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
sig = subprocess.check_output(
    ["openssl", "dgst", "-sha256", "-sign", key_path],
    input=signing_input.encode("ascii"),
)
# Convert DER ECDSA signature to raw R||S (32+32) for JWT.
# openssl asn1parse is awkward; use python to decode DER SEQUENCE.
from typing import Tuple

def der_to_raw_es256(der: bytes) -> bytes:
    # Very small DER parser for SEQUENCE { INTEGER r, INTEGER s }
    assert der[0] == 0x30
    idx = 2 if der[1] < 0x80 else 3
    assert der[idx] == 0x02
    idx += 1
    rlen = der[idx]; idx += 1
    r = der[idx:idx + rlen]; idx += rlen
    assert der[idx] == 0x02
    idx += 1
    slen = der[idx]; idx += 1
    s = der[idx:idx + slen]
    def i32(x: bytes) -> bytes:
        x = x.lstrip(b"\x00") or b"\x00"
        return x.rjust(32, b"\x00")[-32:]
    return i32(r) + i32(s)

print(f"{signing_input}.{b64url(der_to_raw_es256(sig))}")
PY
)"

asc_get() {
  local url="$1"
  curl -g -sS -H "Authorization: Bearer ${ASC_TOKEN}" -H "Content-Type: application/json" "$url"
}

asc_post() {
  local url="$1"
  local body="$2"
  curl -g -sS -X POST -H "Authorization: Bearer ${ASC_TOKEN}" -H "Content-Type: application/json" \
    -d "$body" "$url"
}

asc_patch() {
  local url="$1"
  local body="$2"
  curl -g -sS -X PATCH -H "Authorization: Bearer ${ASC_TOKEN}" -H "Content-Type: application/json" \
    -d "$body" "$url"
}

# Wait until ASC has ingested the build (upload finishes before processing).
deadline=$((SECONDS + MAX_WAIT_SEC))
BUILD_ID=""
while (( SECONDS < deadline )); do
  resp="$(asc_get "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=${APP_ID}&filter[version]=${BUILD_NUMBER}&sort=-uploadedDate&limit=5")"
  BUILD_ID="$(python3 - <<'PY' "$resp"
import json, sys
data = json.loads(sys.argv[1])
items = data.get("data") or []
print(items[0]["id"] if items else "")
PY
)"
  if [[ -n "$BUILD_ID" ]]; then
    echo "Found build id $BUILD_ID"
    break
  fi
  echo "    Waiting for App Store Connect to list build ${BUILD_NUMBER}..."
  sleep "$POLL_SEC"
done

if [[ -z "$BUILD_ID" ]]; then
  echo "Error: timed out waiting for build ${BUILD_NUMBER} in App Store Connect."
  echo "   Upload may still be processing - re-run:"
  echo "     ./Scripts/set-testflight-whatsnew.sh --build ${BUILD_NUMBER} --notes \"$NOTES_FILE\""
  exit 1
fi

# Create or update betaBuildLocalizations.whatsNew for the locale.
find_localization_id() {
  python3 - "$LOCALE" "$1" <<'PY'
import json, sys
target = sys.argv[1]
data = json.loads(sys.argv[2])
for item in data.get("data") or []:
    attrs = item.get("attributes") or {}
    if attrs.get("locale") == target:
        print(item.get("id") or "")
        break
PY
}

existing="$(asc_get "https://api.appstoreconnect.apple.com/v1/builds/${BUILD_ID}/betaBuildLocalizations?filter[locale]=${LOCALE}&limit=1")"
LOC_ID="$(find_localization_id "$existing")"

if [[ -z "$LOC_ID" ]]; then
  existing="$(asc_get "https://api.appstoreconnect.apple.com/v1/builds/${BUILD_ID}/betaBuildLocalizations?limit=200")"
  LOC_ID="$(find_localization_id "$existing")"
fi

NOTES_JSON="$(WHATS_NEW="$WHATS_NEW" python3 - <<'PY'
import json, os
print(json.dumps(os.environ["WHATS_NEW"]))
PY
)"

if [[ -n "$LOC_ID" ]]; then
  body="$(cat <<EOF
{"data":{"type":"betaBuildLocalizations","id":"${LOC_ID}","attributes":{"whatsNew":${NOTES_JSON}}}}
EOF
)"
  result="$(asc_patch "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/${LOC_ID}" "$body")"
else
  body="$(cat <<EOF
{"data":{"type":"betaBuildLocalizations","attributes":{"locale":"${LOCALE}","whatsNew":${NOTES_JSON}},"relationships":{"build":{"data":{"type":"builds","id":"${BUILD_ID}"}}}}}
EOF
)"
  result="$(asc_post "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations" "$body")"
fi

python3 - <<'PY' "$result"
import json, sys
data = json.loads(sys.argv[1])
if "errors" in data:
    print("App Store Connect API error:")
    print(json.dumps(data["errors"], indent=2))
    sys.exit(1)
attrs = (data.get("data") or {}).get("attributes") or {}
print("What's New attached")
print("    locale:", attrs.get("locale"))
wn = attrs.get("whatsNew") or ""
print("    preview:", (wn[:160] + ("..." if len(wn) > 160 else "")).replace("\n", " / "))
PY

echo "App Store Connect: https://appstoreconnect.apple.com/apps/${APP_ID}/testflight/ios"
