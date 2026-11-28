#!/usr/bin/env bash
# Uploads on an instance without Vault (USE_VAULT=false), published on a host
# port other than 8080. Read at startup, so this needs its own container, like
# 72-torrent-store-no-s3.sh.
#
#   1. The browser's address comes from DOMAIN: an UPLOAD_URL in the
#      container's environment is not taken (web-ui's own calls keep its path,
#      and only /torrent-http-proxy/ leads to torrent-http-proxy in here).
#   2. An upload the autocleaner removed is 404, not a Vault error: the
#      seeder must not ask a Vault that does not run.
#   3. The delete works although DOMAIN does not open from inside the
#      container: web-ui sends it to the in-container proxy address.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

name=webtor-smoke-novault
tmp="$(mktemp -d)"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e USE_VAULT=false -e DOMAIN=http://localhost:18098 \
  -e UPLOAD_URL=http://127.0.0.1:1/x -p 18098:8080 "$WEBTOR_IMAGE" >/dev/null
BASE_URL=http://localhost:18098
wait_for 240 "no-Vault instance to boot" curl -fsS -o /dev/null "$BASE_URL/"

# jget, upload_token and upload_delete: copies from 73-uploads.sh.
jget() {
  local doc="$1" expr="$2" what="$3" val
  if ! val="$(printf '%s' "$doc" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($expr)
" 2>&1)"; then
    fail "$what: could not extract it -- $val
  from response: $doc"
  fi
  printf '%s' "$val"
}
jar="$tmp/jar"
profile="$(curl -fsS -c "$jar" -b "$jar" "$BASE_URL/profile")" || fail "GET /profile failed"
csrf="$(csrf_from "$profile")" || fail "GET /profile rendered no _csrf token"
upload_token() {
  local code
  code="$(curl -sS -o "$tmp/token.json" -w '%{http_code}' -b "$jar" -c "$jar" -X POST \
    -H 'Content-Type: application/json' -H "X-CSRF-TOKEN: $csrf" \
    --data-binary "$1" "$BASE_URL/upload/token")" || fail "POST /upload/token did not answer"
  [ "$code" = 200 ] || fail "POST /upload/token $1: $code $(cat "$tmp/token.json")"
  cat "$tmp/token.json"
}
upload_delete() {
  curl -sS -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
    -H 'X-Return-Url: /' -F "resource_id=$1" "$BASE_URL/upload/delete"
}

# new_upload <name> -- the ID of a new upload of one byte.
new_upload() {
  local t id url c
  t="$(upload_token "{\"name\":\"$1\",\"want\":1}")" || exit 1
  id="$(jget "$t" 'd["id"]' id)"
  url="$(jget "$t" 'd["url"]' url)"
  assert_eq "$url" "$BASE_URL/torrent-http-proxy/$id" "upload url"
  printf x >"$tmp/one"
  c="$(curl -s -o /dev/null -w '%{http_code}' -T "$tmp/one" \
    "$url/$1/a.bin?token=$(jget "$t" 'd["token"]' token)&api-key=$(jget "$t" 'd["apiKey"]' key)&offset=0&size=1")"
  assert_eq "$c" "201" "one-byte upload $1"
  printf '%s' "$id"
}

# --- 1 and 2: an evicted upload ---------------------------------------------
id="$(new_upload smoke-novault)"
docker exec "$name" rm -rf "/data/$id" "/data/$id.touch" </dev/null
key="$(api_key)" || fail "could not obtain an API key on the no-Vault instance"
code="$(curl -s -o "$tmp/res" -w '%{http_code}' -H "Authorization: Bearer $key" "$BASE_URL/api/v1/resource/$id")"
assert_eq "$code" "404" "evicted upload without Vault ($(cat "$tmp/res"))"

# --- 3. the delete ----------------------------------------------------------
id2="$(new_upload smoke-novault-del)"
loc="$(upload_delete "$id2")"
case "$loc" in *status=success*) : ;; *) fail "upload delete: $loc" ;; esac
assert_eq "$(docker exec "$name" grep -cx / "/data/$id2/deleted" </dev/null)" "1" "tombstone after the delete"

echo "PASS: uploads-no-vault"
