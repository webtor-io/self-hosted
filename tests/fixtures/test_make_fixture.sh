#!/usr/bin/env bash
# Unit test for make_fixture.py: runs it on a synthetic tree and checks the summary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/webtor-smoke/subs"
# 100000 bytes => with piece length 32768 that is 4 pieces (3 full + remainder)
head -c 100000 /dev/zero | tr '\0' 'a' > "$tmp/webtor-smoke/video.mp4"
printf 'hello\n' > "$tmp/webtor-smoke/readme.txt"
printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$tmp/webtor-smoke/subs/subtitle.srt"

summary="$(python3 "$here/make_fixture.py" "$tmp/webtor-smoke" "http://webseed/" "$tmp/out.torrent")"
echo "$summary"

get() { printf '%s' "$summary" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

[ -s "$tmp/out.torrent" ] || { echo "FAIL: torrent not written"; exit 1; }
[ "$(get "['name']")" = "webtor-smoke" ] || { echo "FAIL: wrong name"; exit 1; }
[ "$(get "['piece_length']")" = "32768" ] || { echo "FAIL: wrong piece length"; exit 1; }
[ "$(printf '%s' "$summary" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['files']))")" = "3" ] \
  || { echo "FAIL: expected 3 files"; exit 1; }
total="$(get "['total_length']")"
[ "$total" = "100041" ] || { echo "FAIL: total_length=$total, expected 100041"; exit 1; }
# ceil(100041 / 32768) == 4
[ "$(get "['pieces_count']")" = "4" ] || { echo "FAIL: wrong pieces_count"; exit 1; }
ih="$(get "['infohash']")"
printf '%s' "$ih" | grep -Eq '^[0-9a-f]{40}$' || { echo "FAIL: bad infohash $ih"; exit 1; }

# Exact files list (path + order + length), not just count. Sorted-path
# order for this synthetic tree: readme.txt, subs/subtitle.srt, video.mp4.
# A generator bug that reorders files, mismatches a path to the wrong
# content, or hashes pieces out of manifest order would slip past a
# len(files)==3 check but must fail here.
expected_files='[{"path": "readme.txt", "length": 6}, {"path": "subs/subtitle.srt", "length": 35}, {"path": "video.mp4", "length": 100000}]'
actual_files="$(printf '%s' "$summary" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['files']))")"
[ "$(python3 -c "import json;print(json.loads('''$actual_files''') == json.loads('''$expected_files'''))")" = "True" ] \
  || { echo "FAIL: files list mismatch, got: $actual_files"; exit 1; }

# Pin the infohash to a known value. The synthetic tree above is
# byte-deterministic (fixed content, fixed piece length, fixed webseed
# URL), so the infohash is fixed too. Recompute this constant (rerun this
# script and copy the printed infohash) if the synthetic tree above, the
# PIECE_LENGTH in make_fixture.py, or the webseed URL passed below changes.
expected_infohash="682d2e605dbd38c276f46800c28a4fa3d23ee436"
[ "$ih" = "$expected_infohash" ] \
  || { echo "FAIL: infohash=$ih, expected $expected_infohash"; exit 1; }
# BEP19 webseed must be present in the bencoded output
# -a: force text-mode scan (the pieces blob contains arbitrary bytes,
# including NUL, which BSD grep otherwise treats as a binary file).
# LC_ALL=C: under a UTF-8 locale, BSD grep can silently fail to match an
# ASCII substring that sits next to invalid UTF-8 byte sequences -- which
# the SHA1 piece hashes are full of. The C locale treats bytes as bytes.
LC_ALL=C grep -aq 'url-list' "$tmp/out.torrent" || { echo "FAIL: no url-list"; exit 1; }

# The private variant of the same tree: BEP 27 flag inside info (so another
# infohash), no webseed (a private torrent is fetched from its tracker's
# peers only), and the tracker's announce URL with a fake passkey.
psum="$(python3 "$here/make_fixture.py" "$tmp/webtor-smoke" "" "$tmp/p.torrent" --private --announce http://tracker.example:6969/announce/0123456789abcdef0123456789abcdef)"
[ "$(printf '%s' "$psum" | python3 -c 'import json,sys;print(json.load(sys.stdin)["private"])')" = "True" ] || { echo "FAIL: not private"; exit 1; }
LC_ALL=C grep -aq '7:privatei1e' "$tmp/p.torrent" || { echo "FAIL: no private flag in info"; exit 1; }
LC_ALL=C grep -aq 'url-list' "$tmp/p.torrent" && { echo "FAIL: url-list in a private torrent"; exit 1; }
LC_ALL=C grep -aq '8:announce' "$tmp/p.torrent" || { echo "FAIL: no announce"; exit 1; }
pih="$(printf '%s' "$psum" | python3 -c 'import json,sys;print(json.load(sys.stdin)["infohash"])')"
[ "$pih" != "$expected_infohash" ] || { echo "FAIL: private flag did not change the infohash"; exit 1; }
# pinned like the public one: rerun and copy the printed value if the tree changes
[ "$pih" = "0a1c1d128a15e0302e38e702a81f8a804bf9a9eb" ] || { echo "FAIL: private infohash=$pih"; exit 1; }
echo "PASS: make_fixture"
