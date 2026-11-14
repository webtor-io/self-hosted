#!/usr/bin/env bash
# webtor-cli -- the official command-line client -- against a self-hosted
# instance, using the exact config-less mode a CI pipeline or a curious
# self-hoster would reach for first: WEBTOR_BACKEND=webui plus
# WEBTOR_BASE_URL/WEBTOR_API_KEY in the environment, no config file, no
# keyring (internal/config/config.go:141-155 in the webtor-cli repo --
# Resolve() returns straight from the env branch and never calls Load or
# the keyring at all when WEBTOR_BACKEND is set, so WEBTOR_NO_KEYRING=1 is
# not actually load-bearing on this path; it is set anyway as cheap
# insurance against ever touching a keyring/D-Bus inside the throwaway
# container, and to keep this scenario correct if that early-return ever
# changes).
#
# The CLI runs as the *published* image, pinned by tag+digest the same way
# every component in this repo's own Dockerfile is pinned -- testing a
# locally built binary would prove nothing about what self-hosters actually
# get. This digest is NOT watched by Renovate: renovate.json's docker
# manager only scans Dockerfile-shaped FROM lines and compose "image:"
# fields (there is no regexManagers/customManagers section here), and this
# pin lives in a plain shell variable inside a test script, a file type
# Renovate's default docker manager does not look at -- even though the
# packageName would match the "ghcr.io/webtor-io/**" rule if it were ever
# seen. Bumping it is manual, the same way versitygw's pin in the Dockerfile
# already is (see that file's own comment).
#
# The CLI runs in its own throwaway container on the compose network,
# addressing the instance under test by its compose service name (webtor)
# on its container-internal port (8080) -- not the host-published port --
# because the point is proving the CLI can reach a self-hosted box as a
# separate machine would, the same way webseed already does for
# torrent-web-seeder in the other scenarios.
#
# Re-runnable against a warm container: `add` is content-addressed and
# idempotent (api-sdk-go resource.go's own doc comment; 20-archive.sh
# already relies on the same POST /resource being safe to repeat), so a
# second run just gets back the same resource id and creates no new state
# to clean up -- unlike 80-vault.sh's pledge or 91-s3-webui.sh's library
# row, there is nothing here that needs an EXIT trap.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CLI_IMAGE="ghcr.io/webtor-io/webtor-cli:v1.13.0@sha256:924545062d9ad96ed29de6aeb1d68751109daaea342ced67b0cb836f0e94dad5"
CLI_BASE_URL="http://webtor:8080/api/v1"

docker pull "$CLI_IMAGE" >/dev/null || fail "could not pull the webtor-cli image $CLI_IMAGE"

# The compose network the "webtor" service actually landed on -- not
# hardcoded as "<project>_default", so this keeps working if run.sh's -p or
# compose's own naming ever changes. The webtor service is attached to
# exactly one network (docker-compose.yml declares none of its own, so
# compose creates the implicit default), so a single network name back is
# expected and sufficient.
webtor_cid="$(docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" ps -q webtor)"
[ -n "$webtor_cid" ] || fail "docker compose ps -q webtor returned nothing -- is the suite's container running?"
CLI_NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$webtor_cid")"
[ -n "$CLI_NETWORK" ] || fail "could not determine the compose network of the webtor container"

# cli_run <key> <args...> -- webtor-cli in a throwaway container, config-less
# env mode, no stdin attached.
cli_run() {
  local key="$1"
  shift
  docker run --rm --network "$CLI_NETWORK" \
    -e WEBTOR_BACKEND=webui \
    -e WEBTOR_BASE_URL="$CLI_BASE_URL" \
    -e WEBTOR_API_KEY="$key" \
    -e WEBTOR_NO_KEYRING=1 \
    "$CLI_IMAGE" "$@"
}

# cli_add <key> -- `webtor add` reading the fixture torrent from stdin, the
# way a real user pipes a .torrent file in (README's own first example).
cli_add() {
  local key="$1"
  docker run --rm -i --network "$CLI_NETWORK" \
    -e WEBTOR_BACKEND=webui \
    -e WEBTOR_BASE_URL="$CLI_BASE_URL" \
    -e WEBTOR_API_KEY="$key" \
    -e WEBTOR_NO_KEYRING=1 \
    "$CLI_IMAGE" --json add - < "$FIXTURE_DIR/smoke.torrent"
}

# --- 1. The real round trip: add the fixture, read its own state back ----
key="$(api_key)"

add_json="$(cli_add "$key")" || fail "webtor-cli add was rejected with a freshly minted, valid API key"

# Compared against summary.json for the same reason as the listing below:
# the infohash is a function of the bytes ffmpeg produced, so a literal here
# pins this scenario to one build of the generator image rather than to the
# behaviour under test -- whether the CLI round-trips what the instance
# stored. files_count stays a literal: three files is the fixture's shape,
# which make_fixture.py builds on purpose and no rebuild changes.
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
summary = json.load(open(sys.argv[2]))
assert d.get("id") == summary["infohash"], "id=%r, want %r" % (d.get("id"), summary["infohash"])
assert d.get("multi_file") is True, "multi_file=%r" % (d.get("multi_file"),)
assert d.get("size") == summary["total_length"], "size=%r, want %r" % (d.get("size"), summary["total_length"])
assert d.get("files_count") == 3, "files_count=%r" % (d.get("files_count"),)
' "$add_json" "$FIXTURE_DIR/summary.json" || fail "webtor-cli add did not report the fixture torrent's known id/size/file count: $add_json"

id="$(printf '%s' "$add_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

ls_json="$(cli_run "$key" --json ls "$id")" || fail "webtor-cli ls was rejected with a freshly minted, valid API key"

# Proves the listing came from the instance's own state for *this*
# resource, not just that some JSON came back: the three file entries' names
# and sizes must match the fixture bytes exactly (tests/fixtures/summary.json),
# and nothing else claiming to be a file may be present.
# The expected set is read from summary.json, which make_fixture.py writes
# from the very bytes it packed, rather than copied into this file as
# literals. Literals here were a standing trap: they encode one particular
# ffmpeg build's output, so an upstream rebuild of the generator image turned
# this scenario red over a one-byte difference in a video nobody watches.
# The image is pinned by digest now (tests/fixtures/build.sh); reading the
# summary means a deliberate future re-pin does not also require editing
# numbers here, and the assertion stays about the round trip.
python3 -c '
import json, sys, os
d = json.loads(sys.argv[1])
summary = json.load(open(sys.argv[2]))
want = {(os.path.basename(f["path"]), f["length"]) for f in summary["files"]}
got = {(it["name"], it["size"]) for it in d.get("items", []) if it.get("type") == "file"}
assert got == want, "file entries = %r, want %r" % (got, want)
' "$ls_json" "$FIXTURE_DIR/summary.json" || fail "webtor-cli ls did not list the fixture torrents own three files with their known sizes: $ls_json"

echo "PASS-detail: round trip via webtor-cli add + ls matched the fixture (id=$id)"

# --- 2. Negative control: no valid key must fail, visibly -----------------
# Same well-formed-but-never-issued UUID 90-api.sh uses directly against
# /api/v1: it clears the auto-admin "open instance" gate (this container
# runs with no ADMIN_PASSWORD) and is rejected by the next one down, the
# scope check, as 403 forbidden. What matters here is not which HTTP status
# produces it, but that the CLI itself surfaces exit code 3 (exitcode.Auth,
# internal/exitcode/exitcode.go) for both 401 and 403 -- proving this is
# the instance answering "no", not some client-side/network failure, and
# not a silent fallback to a default endpoint (WEBTOR_BASE_URL was set
# explicitly above and reused unchanged here; if the config-less mode ever
# ignored it and fell back to DefaultWebUIBaseURL, i.e. the real
# https://api.webtor.io/v1, this call would need real internet egress to
# even attempt the request, which the sandboxed suite runner does not
# have -- so that failure mode would show up here as a network error
# instead of a clean exit 3).
bad_key="00000000-0000-0000-0000-000000000000"
set +e
bad_out="$(cli_run "$bad_key" --json ls "$id" 2>&1)"
bad_rc=$?
set -e

assert_eq "$bad_rc" "3" "webtor-cli exit code for ls with an unissued key (output: $bad_out)"

python3 -c '
import json, sys
d = json.loads(sys.argv[1])
code = d.get("error", {}).get("code")
assert code in ("unauthorized", "forbidden"), "error.code=%r" % (code,)
' "$bad_out" || fail "webtor-cli --json error envelope for the bad key was not the documented auth-rejection shape: $bad_out"

echo "PASS-detail: webtor-cli ls with an unissued key failed with exit 3 and an auth error envelope"

echo "PASS: cli"
