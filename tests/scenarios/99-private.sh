#!/usr/bin/env bash
# Private (BEP 27) torrents end to end, with PRIVATE_ACCESS_ENFORCE on in every
# service (docker-compose.yml). The private fixture has no webseed: its only
# peer is the compose "tracker" service (fixtures/fake_tracker.py), which also
# logs every announce with the passkey from its URL path.
#
# Two accounts. A is the open instance's auto-admin (every browser visitor and
# lib.sh's api_key); A uploads private-a.torrent and so owns the record. B is a
# second "user" row with an API key, made through psql: an open instance has
# one browser user, so "B is refused" is checked through /api/v1 and the CLI.
#
# What is checked, in order:
#   1. B exists.
#   2. A's upload answers the infohash with "private": true.
#   3. Every path of A plays under enforce: download (with no cookie and no
#      key -- the holder of a link plays it), ~vtt, ~arch, ~hls, ~vod, ~vod
#      inside the grace window of a page start, and WebDAV.
#   4. The tracker saw that infohash announced with A's key and no other one:
#      the seeder took the trackers of A's record from torrent-store (Pull
#      with caller.uid), not those of whoever uploaded first.
#   5. B gets 403 private_torrent / no_record.
#   6. B's token in A's link is refused.
#   7. source.torrent of the private torrent is never served.
#   8. webtor-cli: A adds and downloads; B exits 8 with the re-upload hint; a
#      private .torrent without a tracker exits 8.
#
# Not here: "bad = 0" and "never account_required" from metrics -- USE_PROM is
# off in self-hosted; under enforce each of those would be a 403 on its path,
# and every path above must answer 2xx. Stremio needs an imdb id the fixture
# has none of.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jget and resolve_url: copies from 30-hls.sh (each scenario stays
# self-contained, the suite's convention).
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

resolve_url() {
  local playlist_url="$1" entry="$2"
  case "$entry" in
    *://*) printf '%s' "$entry" ;;
    /*)
      local origin="${playlist_url%%://*}://"
      local rest="${playlist_url#*://}"
      origin="$origin${rest%%/*}"
      printf '%s%s' "$origin" "$entry"
      ;;
    *)
      local no_query="${playlist_url%%\?*}"
      printf '%s/%s' "${no_query%/*}" "$entry"
      ;;
  esac
}

H="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["infohash"])' "$FIXTURE_DIR/private-summary.json")"
KEY_A=0123456789abcdef0123456789abcdef
B_TOKEN=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
PRIV="$FIXTURE_DIR/private/webtor-smoke-private"
compose=(docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT")

tmp="$(mktemp -d)"
tracker_log() { "${compose[@]}" exec -T tracker wget -qO- http://127.0.0.1:6969/log </dev/null; }
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    # Fake passkeys only, so the log is safe to print.
    echo "== fake tracker log =="
    tracker_log || true
    echo
  fi
  rm -rf "$tmp"
}
trap on_exit EXIT

# apiv1_as <key> <method> <path> [curl args...] -- apiv1 with the given key.
apiv1_as() {
  local key="$1" method="$2" path="$3"
  shift 3
  curl --fail-with-body -sS -X "$method" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/x-bittorrent" \
    "$BASE_URL/api/v1$path" "$@"
}

# qparam <url> <name> -- one query parameter, decoded.
qparam() {
  python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query).get(sys.argv[2], [""])[0])' "$1" "$2"
}

# with_param <url> <name> <value> -- the url with that query parameter replaced.
with_param() {
  python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
q = [(k, sys.argv[3] if k == sys.argv[2] else v) for k, v in u.parse_qsl(p.query)]
print(u.urlunsplit(p._replace(query=u.urlencode(q))))' "$1" "$2" "$3"
}

# first_segment <playlist-url> -- the first segment's URL, following a master
# playlist one level down (30-hls.sh and 31-transcode.sh do the same inline).
first_segment() {
  local url="$1" pl="$tmp/playlist.m3u8" entry
  wait_for 300 "playlist $url" curl -fsS -o "$pl" "$url"
  [[ "$(head -1 "$pl")" == '#EXTM3U'* ]] || fail "not an m3u8: $url"
  entry="$(grep -m1 -v '^#' "$pl")" || fail "playlist has no entries: $url"
  case "$entry" in
    *.m3u8*)
      url="$(resolve_url "$url" "$entry")"
      wait_for 120 "media playlist $url" curl -fsS -o "$pl" "$url"
      entry="$(grep -m1 -v '^#' "$pl")" || fail "media playlist has no segments: $url"
      ;;
  esac
  resolve_url "$url" "$entry"
}

# get_segment <url> <description> -- fetches a segment, which must be media-sized.
get_segment() {
  wait_for 120 "$2" curl -fsS -o "$tmp/segment" "$1"
  [ "$(wc -c <"$tmp/segment")" -gt 1000 ] || fail "$2 is suspiciously small: $1"
}

# psql_app -- the SQL on stdin, against web-ui's database. Stdin, not -c as in
# 80-vault.sh: "user" is quoted, which a nested sh -c string would mangle.
psql_app() {
  webtor_exec su -s /bin/sh -c 'psql -U postgres -d app -v ON_ERROR_STOP=1 -qtA' postgres
}

# --- 1. B -----------------------------------------------------------------
psql_app >/dev/null <<SQL || fail "could not create user B"
INSERT INTO "user"(email) VALUES ('b@smoke.invalid') ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email;
INSERT INTO access_token(token, user_id, name, scope)
  SELECT '$B_TOKEN', user_id, 'api', '{api:read,api:write}' FROM "user" WHERE email = 'b@smoke.invalid'
  ON CONFLICT (user_id, name) DO UPDATE SET token = EXCLUDED.token;
SQL

# --- 2. A uploads -----------------------------------------------------------
res="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/private-a.torrent")" || fail "A's private upload failed: $res"
assert_eq "$(jget "$res" 'd["id"]' 'resource id')" "$H" "id of A's private upload"
assert_eq "$(jget "$res" 'd["private"]' 'private flag')" "True" "private flag of A's upload"

# --- 3. A's paths, each 2xx under enforce -----------------------------------
listing="$(apiv1 GET "/resource/$H/list?path=/")" || fail "A cannot list the private torrent: $listing"
# item <name> <field> [type] -- a field of the listing entry with that name.
item() {
  jget "$listing" "[i['$2'] for i in walk(d) if i.get('name') == '$1' and i.get('type') == '${3:-file}'][0]" "$1 $2"
}
readme_id="$(item readme.txt id)"
readme_path="$(item readme.txt path)"
srt_id="$(item subtitle.srt id)"
video_id="$(item video.mp4 id)"
subs_id="$(item subs id directory)"
export_url() { # export_url <content-id> <download|stream>
  local ex
  ex="$(apiv1 GET "/resource/$H/export/$1")" || fail "A cannot export $1: $ex"
  jget "$ex" "d['exports']['$2']['url']" "$2 url of $1"
}

# Download, fetched with no cookie and no key: whoever holds A's link plays it
# (signed to A and to this torrent, for at most 24 h). The first fetch waits
# for the seeder to announce and reach the tracker's peer.
dl_url="$(export_url "$readme_id" download)"
wait_for 240 "private readme.txt from the tracker's peer" curl -fsS -o "$tmp/readme.txt" "$dl_url"
cmp -s "$tmp/readme.txt" "$PRIV/readme.txt" || fail "downloaded readme.txt differs from the fixture"

url="$(export_url "$srt_id" stream)"
case "$url" in *'~vtt/'*) : ;; *) fail "subtitle stream url is not ~vtt: $url" ;; esac
wait_for 120 "private ~vtt" curl -fsS -o "$tmp/sub.vtt" "$url"
[[ "$(head -1 "$tmp/sub.vtt")" == WEBVTT* ]] || fail "~vtt is not WebVTT: $(head -3 "$tmp/sub.vtt")"
grep -qx 'webtor smoke test' "$tmp/sub.vtt" || fail "cue text missing from ~vtt: $(cat "$tmp/sub.vtt")"

url="$(export_url "$subs_id" download)"
case "$url" in *arch*) : ;; *) fail "directory download url is not ~arch: $url" ;; esac
wait_for 180 "private ~arch" curl -fsS -o "$tmp/subs.zip" "$url"
python3 - "$tmp/subs.zip" "$PRIV/subs/subtitle.srt" <<'EOF' || fail "~arch zip does not hold the fixture's subtitle.srt"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = [n for n in z.namelist() if n.endswith("subtitle.srt")]
    assert names, z.namelist()
    assert z.read(names[0]) == open(sys.argv[2], "rb").read()
EOF

vod_url="$(export_url "$video_id" stream)"
case "$vod_url" in *'~vod/'*'?'*) : ;; *) fail "video stream url is not ~vod with a query: $vod_url" ;; esac
seg="$(first_segment "$vod_url")" || exit 1
get_segment "$seg" "private ~vod first segment"

# ~hls: the transcoder session, reached as 31-transcode.sh does (same signed
# query, the ~vod segment swapped for ~hls).
prefix="${vod_url%%~vod/*}"
query="${vod_url#*\?}"
wait_for 300 "private transcoder session" curl -fsS -X POST -o "$tmp/session.json" "${prefix}~hls/session?${query}"
sid="$(jget "$(cat "$tmp/session.json")" 'd["id"]' 'transcoder session id')"
seg="$(first_segment "${prefix}~hls/session/${sid}/index.m3u8?${query}")" || exit 1
get_segment "$seg" "private ~hls first segment"

# ~vod in the grace window: started as a browser does from the torrent's page
# (session cookie, CSRF token, POST /stream-video), the player's <source> read
# from the job's event stream. Under grace THP puts the grace token on the
# segments, so their token differs from the manifest's. The token comes from
# /profile's _csrf input, as in lib.sh: one per session, and the page's own
# window._CSRF is JS-escaped.
jar="$tmp/jar"
curl -fsSL -o /dev/null -c "$jar" "$BASE_URL/$H" || fail "A's page of the private torrent failed"
profile="$(curl -fsS -b "$jar" -c "$jar" "$BASE_URL/profile")" || fail "GET /profile failed"
csrf="$(csrf_from "$profile")" || fail "GET /profile rendered no _csrf token"
# The page posts the form as an async fragment request (lib/async.js); the
# job card with its log URL is rendered into that fragment.
started="$(curl -fsS -b "$jar" -c "$jar" -H 'X-Requested-With: XMLHttpRequest' \
  -H 'X-Layout: {{ template "main" . }}' -F "_csrf=$csrf" -F "resource-id=$H" -F "item-id=$video_id" "$BASE_URL/stream-video")" \
  || fail "POST /stream-video failed: ${started:0:500}"
log_path="$(first_group 'data-async-progress-log="([^"]+)"' "$started")" \
  || fail "POST /stream-video started no job: ${started:0:500}"
src="$(python3 - "$BASE_URL$log_path" <<'EOF'
import html, json, re, sys, time, urllib.request
deadline = time.monotonic() + 300
with urllib.request.urlopen(sys.argv[1], timeout=60) as r:
    for line in r:  # pings every 5 s keep this moving
        if time.monotonic() > deadline:
            sys.exit("no <source> in the job log within 300 s")
        if not line.startswith(b"data:"):
            continue
        try:
            it = json.loads(line[5:])
        except ValueError:
            continue
        m = re.search(r'<source src="([^"]+)"', it.get("body") or "")
        if m:
            print(html.unescape(m.group(1)))
            sys.exit(0)
        if it.get("level") == "error":
            sys.exit("stream job failed: %s" % it.get("message"))
sys.exit("job log ended without a <source>")
EOF
)" || fail "the page's stream job gave no player source"
src_token="$(qparam "$src" token)"
[ -n "$src_token" ] || fail "player source carries no token: $src"
seg="$(first_segment "$src")" || exit 1
seg_token="$(qparam "$seg" token)"
[ -n "$seg_token" ] || fail "grace segment carries no token: $seg"
[ "$seg_token" != "$src_token" ] || fail "segment token equals the manifest's: THP gave no grace"
get_segment "$seg" "private ~vod segment in the grace window"

# WebDAV: the library entry under all/<torrent name>/ (services/libfs:
# torrents/ holds the .torrent files, all/ the content).
apiv1_json POST /library -d "{\"resource_id\":\"$H\"}" >/dev/null || fail "A cannot add the private torrent to the library"
webdav_field() { # as in 93-webdav.sh
  local raw sl="/"
  raw="$(first_group 'var webdavUrl = "([^"]*)"' "$1")" || return 1
  printf '%s' "${raw//\\$sl/$sl}"
}
profile="$(curl -fsS -b "$jar" -c "$jar" "$BASE_URL/profile")" || fail "GET /profile failed"
webdav_url="$(webdav_field "$profile" || true)"
if [ -z "$webdav_url" ]; then
  curl -fsS -o /dev/null -b "$jar" -c "$jar" -X POST --data-urlencode "_csrf=$(csrf_from "$profile")" \
    "$BASE_URL/webdav/url/generate" || fail "POST /webdav/url/generate failed"
  profile="$(curl -fsS -b "$jar" -c "$jar" "$BASE_URL/profile")" || fail "GET /profile failed"
  webdav_url="$(webdav_field "$profile")" || fail "no WebDAV URL on /profile after generating one"
fi
wait_for 120 "private readme.txt over WebDAV" curl -fsSL -o "$tmp/dav.txt" "${webdav_url}all/webtor-smoke-private/readme.txt"
cmp -s "$tmp/dav.txt" "$PRIV/readme.txt" || fail "readme.txt over WebDAV differs from the fixture"

# --- 4. The tracker saw A's key only ----------------------------------------
tlog="$(tracker_log)" || fail "could not read the fake tracker's log"
python3 -c '
import json, sys
log, h, key = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
mine = [e for e in log if e["info_hash"] == h]
assert mine, "the tracker never saw this torrent announced"
keys = {e["key"] for e in mine}
assert keys == {key}, "announced with keys %r, want only %r (A)" % (sorted(keys), key)
assert any(e["event"] == "started" for e in mine), "no started announce"
' "$tlog" "$H" "$KEY_A" || fail "the tracker's announces of $H are not A's alone"

# --- 5. B, without a record -------------------------------------------------
code="$(apiv1_as "$B_TOKEN" GET "/resource/$H" -o "$tmp/b.json" -w '%{http_code}')" || true
assert_eq "$code" "403" "B's GET of A's private torrent ($(cat "$tmp/b.json"))"
python3 -c '
import json, sys
e = json.load(open(sys.argv[1]))["error"]
assert (e["code"], e.get("reason")) == ("private_torrent", "no_record"), e
' "$tmp/b.json" || fail "B's refusal is not private_torrent/no_record: $(cat "$tmp/b.json")"

# --- 6. B's token on A's link -----------------------------------------------
# A token of B's own (from a public export) put in A's link. Replacing it with
# A's own token instead is the control: that is the link of step 3, a 200.
pub="$(apiv1_as "$B_TOKEN" POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")" || fail "B's public upload failed: $pub"
pub_id="$(jget "$pub" 'd["id"]' 'public resource id')"
pl="$(apiv1_as "$B_TOKEN" GET "/resource/$pub_id/list?path=/")" || fail "B cannot list the public torrent: $pl"
pr="$(jget "$pl" '[i["id"] for i in walk(d) if i.get("name") == "readme.txt"][0]' 'public readme.txt id')"
pex="$(apiv1_as "$B_TOKEN" GET "/resource/$pub_id/export/$pr")" || fail "B cannot export the public readme.txt: $pex"
b_token="$(qparam "$(jget "$pex" 'd["exports"]["download"]["url"]' 'public download url')" token)"
[ -n "$b_token" ] || fail "B's public export carries no token"
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$(with_param "$dl_url" token "$b_token")")" "403" \
  "A's link with B's token"

# --- 7. source.torrent ------------------------------------------------------
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "${dl_url%%"$H/"*}$H/source.torrent?${dl_url#*\?}")" "403" \
  "source.torrent of the private torrent on A's link"

# --- 8. webtor-cli ------------------------------------------------------------
# The published CLI, pinned like in 92-cli.sh. It runs in the webtor
# container's network namespace: the export URLs it downloads name DOMAIN,
# http://localhost:$WEBTOR_HOST_PORT, which is that container's own port 8080
# only when the host port is 8080 too.
# ponytail: one more host port would need a DOMAIN the CLI container can reach.
[ "${WEBTOR_HOST_PORT:-8080}" = 8080 ] || fail "the CLI step needs WEBTOR_HOST_PORT=8080 (DOMAIN must be reachable from the CLI container)"
CLI_IMAGE="ghcr.io/webtor-io/webtor-cli:v1.13.0@sha256:924545062d9ad96ed29de6aeb1d68751109daaea342ced67b0cb836f0e94dad5"
docker pull -q "$CLI_IMAGE" >/dev/null || fail "could not pull $CLI_IMAGE"
webtor_cid="$("${compose[@]}" ps -q webtor)"
[ -n "$webtor_cid" ] || fail "the suite's webtor container is not running"
cli() { # cli <key> <args...>
  local key="$1"
  shift
  docker run --rm --network "container:$webtor_cid" -v "$FIXTURE_DIR:/fixtures:ro" \
    -e WEBTOR_BACKEND=webui -e WEBTOR_BASE_URL=http://localhost:8080/api/v1 \
    -e WEBTOR_API_KEY="$key" -e WEBTOR_NO_KEYRING=1 "$CLI_IMAGE" "$@" </dev/null
}
key_a="$(api_key)" || fail "could not obtain A's API key"

out="$(cli "$key_a" --json add /fixtures/private-a.torrent 2>&1)" || fail "A: webtor add private-a.torrent failed: $out"
assert_eq "$(jget "$out" 'd["id"]' 'cli add id')" "$H" "id from A's webtor add"

cli "$key_a" download --stdout "$H" "${readme_path#/}" >"$tmp/cli.txt" 2>"$tmp/cli.err" \
  || fail "A: webtor download failed: $(cat "$tmp/cli.err")"
cmp -s "$tmp/cli.txt" "$PRIV/readme.txt" || fail "readme.txt from webtor download differs from the fixture"

rc=0
out="$(cli "$B_TOKEN" download --stdout "$H" "${readme_path#/}" 2>&1)" || rc=$?
assert_eq "$rc" "8" "B: webtor download exit code ($out)"
grep -qF 'webtor add file.torrent' <<<"$out" || fail "B's refusal does not tell to add the .torrent: $out"

rc=0
out="$(cli "$key_a" add /fixtures/private-notracker.torrent 2>&1)" || rc=$?
assert_eq "$rc" "8" "A: webtor add of a private torrent without a tracker, exit code ($out)"

echo "PASS: private"
