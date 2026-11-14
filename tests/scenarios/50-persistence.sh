#!/usr/bin/env bash
# State survives a container restart (`docker compose restart`, same
# container -- not a full recreate/replace): the resource stays registered,
# the listing is unchanged, and the downloaded bytes are still exactly the
# fixture's, not just "some front page returned 200".
#
# What this actually proves, and what it doesn't: probing the running
# baseline image (see task-7-report.md for the full transcript) shows that
# postgres data under /pgdata and downloaded torrent content under /data are
# genuinely volume-backed -- they survive a full container recreate, not just
# a restart. But the resource *registration* itself (torrent-http-proxy's
# badger provider, which backs GET /resource/<id> and the listing) lives at
# /tmp/badger in this image, which is NOT on either named volume. It survives
# `docker compose restart` only because that command keeps the same
# container's writable layer intact; a full recreate (`down`/`up`, or a pod
# reschedule in k8s) loses it even with both volumes fully retained -- this
# was verified directly, see the negative control in the report. So this
# scenario proves crash-restart-in-place survival (postgres recovery +
# resource/content integrity), not durable-volume-backed resource state
# across pod replacement -- that distinction matters for the version jump
# this suite gates and is called out explicitly rather than implied.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# jget <json-doc> <python-expr> <description>
# Evaluates the expression with `d` bound to the parsed document and a `walk(n)`
# generator that yields every entry under `n`, at any depth. See 10-ddl.sh for
# the rationale: this mirrors that scenario's helper so both stay consistent.
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

compose=(docker compose -f "$TESTS_DIR/docker-compose.yml" -p webtor-smoke)

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"

listing_before="$(apiv1 GET "/resource/$id/list?path=/")"
names_before="$(jget "$listing_before" \
  '"\n".join(sorted({i["name"] for i in walk(d) if i.get("type") == "file"}))' \
  'pre-restart file names')"
for want in video.mp4 readme.txt subtitle.srt; do
  grep -qx -- "$want" <<<"$names_before" \
    || fail "fixture file '$want' missing before restart: $listing_before"
done

# The private-trackers key lives in the container's layer, not a volume: a
# restart must keep it, or every saved private tracker becomes unreadable.
# Only its hash leaves the container, and it is never printed. A missing file
# leaves the hash empty, which fails below instead of exiting silently here.
k1="$(webtor_exec sha256sum /etc/webtor/secrets/private-trackers.env </dev/null | cut -d' ' -f1)" || k1=

"${compose[@]}" restart webtor

wait_for 240 "front page after restart" curl -fsS "$BASE_URL/"
# The API-key session/cookie jar established in api_key() lives only for
# this script's process, and the container restart below does not affect
# it (the key itself is account-scoped, persisted in the embedded
# Postgres, not tied to the pre-restart session) -- so `apiv1` keeps
# working unchanged after the restart.
wait_for 120 "resource after restart" apiv1 GET "/resource/$id"

k2="$(webtor_exec sha256sum /etc/webtor/secrets/private-trackers.env </dev/null | cut -d' ' -f1)" || k2=
[ -n "$k1" ] && [ "$k1" = "$k2" ] || fail "PRIVATE_TRACKERS_KEY changed across a restart"

# Getting a 200 back proves almost nothing by itself -- an empty, freshly
# re-initialized resource could 200 too. Re-read the listing and require the
# same fixture files to still be there.
listing_after="$(apiv1 GET "/resource/$id/list?path=/")"
names_after="$(jget "$listing_after" \
  '"\n".join(sorted({i["name"] for i in walk(d) if i.get("type") == "file"}))' \
  'post-restart file names')"
assert_eq "$names_after" "$names_before" "file listing changed across restart"

# Prove it further: pull the actual bytes back down post-restart and
# checksum them against the fixture. This is the part a bare listing check
# cannot catch -- a stale/corrupt entry could still list correctly by name.
content_id="$(jget "$listing_after" \
  '[i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0]' \
  'video.mp4 content id')"
export_json="$(apiv1 GET "/resource/$id/export/$content_id")"
url="$(jget "$export_json" 'd["exports"]["download"]["url"]' 'download url')"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
wait_for 180 "download url to serve bytes after restart" curl -fsS -o "$out" "$url"

want="$(shasum -a 256 "$FIXTURE_DIR/content/webtor-smoke/video.mp4" | cut -d' ' -f1)"
got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
assert_eq "$got" "$want" "post-restart video.mp4 checksum"

# A second boot must not re-run migrations destructively or crash-loop.
#
# NB: this is an `if`, not `printf ... | grep -q ... && fail`. That construct
# was a false-pass generator, which is the worst kind of test bug: when a panic
# WAS present, `grep -q` matched and exited immediately, `printf` took SIGPIPE
# on its remaining write, `set -o pipefail` (from lib.sh) turned the pipeline's
# status into failure, so `&&` skipped `fail` entirely -- and since a failing
# left operand of `&&` is exempt from `set -e`, the scenario fell through to
# `echo "PASS: persistence"`. A real panic printed a green scenario. The
# here-string has no pipe, and `if` makes the failure path unconditional.
logs="$("${compose[@]}" logs --tail 400 webtor)"
if grep -qiE 'panic:|migration failed' <<<"$logs"; then
  fail "restart logs contain fatal errors: $(tail -60 <<<"$logs")"
fi

echo "PASS: persistence"
