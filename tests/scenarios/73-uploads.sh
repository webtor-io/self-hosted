#!/usr/bin/env bash
# A user's own upload end to end in the shared container: web-ui grants a
# write token, the browser's parts go through nginx and torrent-http-proxy to
# the seeder, the files play back through an export link, and web-ui's own
# calls (the seal before a Vault pledge, the delete) reach the seeder.
#
# What is checked, in order:
#   1. The seeder, rest-api and web-ui each log "uploads: on".
#   2. A token for a new upload: its ID, the browser's address, the cap of an
#      instance without a claims provider (50 GiB).
#   3. The preflight, then a 16 MiB part (nginx's 1m default would answer
#      413 itself) and the last 1 MiB; the files land in DATA_DIR.
#   4. rest-api lists the upload as private, and its export plays.
#   5. A browser's token may not read the manifest, delete or seal the whole
#      upload, and a client's own write headers grant nothing: the seeder
#      trusts the headers torrent-http-proxy sets, so a proxy that let the
#      client's through would fail here. The seeder's own port does not
#      connect from outside the container.
#   6. A padded ID is refused.
#   7. A Vault pledge seals the upload; the delete leaves a tombstone and
#      takes the Vault copy with it (80-vault.sh runs after this in the same
#      container and checks /storage/vault for its own torrent).
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jget: a copy from 99-private.sh (each scenario stays self-contained).
jget() {
  local doc="$1" expr="$2" what="$3" val
  if ! val="$(printf '%s' "$doc" | python3 -c "
import json, sys

def walk(n):
    for it in (n.get('items') or []):
        yield it
        for sub in walk(it):
            yield sub

d = json.load(sys.stdin)
print($expr)
" 2>&1)"; then
    fail "$what: could not extract it -- $val
  from response: $doc"
  fi
  printf '%s' "$val"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jar="$tmp/jar"

# One browser session for the token and the delete: its cookie in $jar, its
# CSRF token from /profile's _csrf input (the page's window._CSRF is
# JS-escaped).
profile="$(curl -fsS -c "$jar" -b "$jar" "$BASE_URL/profile")" || fail "GET /profile failed"
csrf="$(csrf_from "$profile")" || fail "GET /profile rendered no _csrf token"

# upload_token <json> -- the grant of POST /upload/token, as the drop zone asks.
upload_token() {
  local code
  code="$(curl -sS -o "$tmp/token.json" -w '%{http_code}' -b "$jar" -c "$jar" -X POST \
    -H 'Content-Type: application/json' -H "X-CSRF-TOKEN: $csrf" \
    --data-binary "$1" "$BASE_URL/upload/token")" || fail "POST /upload/token did not answer"
  [ "$code" = 200 ] || fail "POST /upload/token $1: $code $(cat "$tmp/token.json")"
  cat "$tmp/token.json"
}

# upload_delete <id> -- the redirect of the upload's Delete button.
upload_delete() {
  curl -sS -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" -H "X-CSRF-TOKEN: $csrf" \
    -H 'X-Return-Url: /' -F "resource_id=$1" "$BASE_URL/upload/delete"
}

# code <curl args...> -- the status alone.
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# lines <id> <line> -- how many lines of the upload's deleted file are <line>;
# 0 without the file.
lines() {
  webtor_exec sh -c "cat /data/$1/deleted 2>/dev/null | grep -cxF -- '$2' || true" </dev/null | tr -d '\r'
}

# --- 1. uploads: on ---------------------------------------------------------
logs="$(docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" logs webtor)"
for s in torrent-web-seeder rest-api web-ui; do
  grep -q "\[$s\].*uploads: on" <<<"$logs" || fail "$s does not say uploads: on"
done

# --- 2. a new upload's token ------------------------------------------------
t="$(upload_token '{"name":"smoke-upload","want":17825792}')"
id="$(jget "$t" 'd["id"]' id)"
url="$(jget "$t" 'd["url"]' url)"
[[ "$id" =~ ^9c5db5752b7c0[0-9a-f]{27}$ ]] || fail "upload id $id"
assert_eq "$url" "$BASE_URL/torrent-http-proxy/$id" "upload url"
assert_eq "$(jget "$t" 'd["cap"]' cap)" "53687091200" "cap without a claims provider (50 GiB)"
assert_eq "$(jget "$t" 'd["used"]' used)" "0" "used on a fresh instance"
q="token=$(jget "$t" 'd["token"]' token)&api-key=$(jget "$t" 'd["apiKey"]' key)"

# --- 3. the parts -----------------------------------------------------------
curl -s -o /dev/null -D "$tmp/pre.h" -w '%{http_code}' -X OPTIONS -H 'Origin: http://example.com' \
  -H 'Access-Control-Request-Method: PUT' "$url/smoke-upload/a.bin?$q" >"$tmp/pre.code"
assert_eq "$(cat "$tmp/pre.code")" "204" "preflight of a part"
grep -qix 'access-control-allow-origin: \*' <(tr -d '\r' <"$tmp/pre.h") || fail "preflight without Access-Control-Allow-Origin: * ($(cat "$tmp/pre.h"))"
grep -qix 'access-control-allow-methods: PUT, DELETE' <(tr -d '\r' <"$tmp/pre.h") || fail "preflight without Access-Control-Allow-Methods: PUT, DELETE ($(cat "$tmp/pre.h"))"

head -c 17825792 /dev/urandom >"$tmp/a.bin"
head -c 16777216 "$tmp/a.bin" >"$tmp/p1"
tail -c 1048576 "$tmp/a.bin" >"$tmp/p2"
# No cookie and no Origin: the token in the query is the whole grant.
c="$(code -X PUT -T "$tmp/p1" "$url/smoke-upload/a.bin?$q&offset=0&size=17825792")"
[ "$c" = 204 ] || fail "16 MiB part: $c"
c="$(code -X PUT -T "$tmp/p2" "$url/smoke-upload/a.bin?$q&offset=16777216&size=17825792")"
[ "$c" = 201 ] || fail "last part: $c"
# DATA_DIR has no "*" here: the upload sits next to the torrent cache, where
# the autocleaner works.
webtor_exec test -f "/data/$id/files/smoke-upload/a.bin" </dev/null || fail "no /data/$id/files/smoke-upload/a.bin"
webtor_exec test -f "/data/$id.touch" </dev/null || fail "no /data/$id.touch"

# --- 4. rest-api's view and an export ---------------------------------------
res="$(apiv1 GET "/resource/$id")" || fail "GET /resource of the upload: $res"
assert_eq "$(jget "$res" 'd["private"]' private)" "True" "the upload is private"
listing="$(apiv1 GET "/resource/$id/list?path=/")" || fail "the upload's listing: $listing"
cid="$(jget "$listing" '[i["id"] for i in walk(d) if i.get("name") == "a.bin" and i.get("type") == "file"][0]' 'a.bin id')"
ex="$(apiv1 GET "/resource/$id/export/$cid")" || fail "export of a.bin: $ex"
dl="$(jget "$ex" 'd["exports"]["download"]["url"]' 'download url')"
curl -fsS -o "$tmp/dl.bin" "$dl" || fail "download of a.bin failed"
cmp -s "$tmp/dl.bin" "$tmp/a.bin" || fail "the downloaded a.bin differs from the upload"

# --- 5. what a browser's token may not do -----------------------------------
# The owner's renewed token: up=add, without the service's internal mark.
t2="$(upload_token "{\"id\":\"$id\",\"want\":0}")"
qa="token=$(jget "$t2" 'd["token"]' token)&api-key=$(jget "$t2" 'd["apiKey"]' key)"
# The manifest names the owner and every file: rest-api's alone (it got it in
# step 4 through its own token).
assert_eq "$(code "$url/?$qa")" "404" "the manifest to a browser's token"
assert_eq "$(code -X DELETE "$url/?$qa")" "403" "delete of the whole upload with a browser's token"
webtor_exec test -f "/data/$id/files/smoke-upload/a.bin" </dev/null || fail "a refused delete removed a.bin"
# The seeder trusts these headers from torrent-http-proxy, which sets them
# from the verified token: a client's own must never get through.
assert_eq "$(code -X DELETE -H 'X-Internal: true' -H 'X-Upload-Up: add' -H 'X-Upload-Lim: 1' "$url/?$qa")" "403" \
  "delete of the whole upload with a client's own write headers"
webtor_exec test -f "/data/$id/files/smoke-upload/a.bin" </dev/null || fail "a client's own X-Internal deleted a.bin"
assert_eq "$(lines "$id" /)" "0" "tombstone after refused deletes"
assert_eq "$(code -X PUT -H 'Content-Length: 0' "$url/?$qa")" "403" "seal with a browser's token"
assert_eq "$(lines "$id" '~')" "0" "seal line after a refused seal"
# Nor can anyone skip the proxy: the seeder listens on loopback only. From
# another container on the network, the service's delete of the whole upload,
# headers forged, sent straight to the seeder's port does not connect; the web
# port of the same container does (the control).
direct_delete() { # direct_delete <port> -- the status, or the error's name
  docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" exec -T tracker python3 -c '
import http.client, sys
c = http.client.HTTPConnection("webtor", int(sys.argv[1]), timeout=10)
try:
    c.request("DELETE", "/%s/" % sys.argv[2], headers={"X-Info-Hash": sys.argv[2],
              "X-Internal": "true", "X-Upload-Up": "add", "X-Upload-Lim": "1"})
    print(c.getresponse().status)
except OSError as e:
    print(type(e).__name__)
' "$1" "$id" </dev/null
}
c="$(direct_delete 8080)"
[[ "$c" =~ ^[0-9]{3}$ ]] || fail "the web port does not answer from another container: $c"
assert_eq "$(direct_delete 8091)" "ConnectionRefusedError" "a forged delete straight to the seeder's port"
webtor_exec test -f "/data/$id/files/smoke-upload/a.bin" </dev/null || fail "a forged delete straight to the seeder removed a.bin"

# --- 6. a padded ID ---------------------------------------------------------
# nginx passes the padding through as is; the token, bound to the bare ID,
# does not match it.
for pad in %20 %09; do
  assert_eq "$(code "$BASE_URL/torrent-http-proxy/$pad$id/smoke-upload/a.bin?$qa")" "403" "a.bin under the ID padded with $pad"
done

# --- 7. web-ui's own calls: seal on a pledge, then delete -------------------
# They go to the in-container proxy address (USE_INTERNAL_TORRENT_HTTP_PROXY),
# not to DOMAIN, so the host port does not matter here.
vault_files() { webtor_exec sh -c 'find /storage/vault -type f | wc -l' </dev/null | tr -d ' \r'; }
before="$(vault_files)"
apiv1_json POST /vault/pledges --data-binary "{\"resource_id\":\"$id\"}" >/dev/null || fail "pledge of an upload was rejected"
assert_eq "$(lines "$id" '~')" "1" "seal line after the pledge"
vaulted() {
  apiv1 GET "/vault/pledges/$id" | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("vaulted") else 1)'
}
wait_for 240 "the pledged upload to be vaulted" vaulted
[ "$(vault_files)" -gt "$before" ] || fail "the upload is vaulted but /storage/vault holds nothing new"

loc="$(upload_delete "$id")"
case "$loc" in *status=success*) : ;; *) fail "upload delete: $loc" ;; esac
assert_eq "$(lines "$id" /)" "1" "tombstone after the delete"
webtor_exec test ! -e "/data/$id/files/smoke-upload/a.bin" </dev/null || fail "a.bin is still there after the delete"
vault_clean() { [ "$(vault_files)" = "$before" ]; }
wait_for 240 "the upload's objects to leave /storage/vault" vault_clean

echo "PASS: uploads"
