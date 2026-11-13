#!/usr/bin/env bash
# torrent-store gets the private-trackers key and the S3 store; the key is
# generated once, kept with mode 600 and warned about, since this container
# generated it. Every check on a value runs inside the container and returns
# only a status: the key itself is never printed.
#
# Which other processes do NOT get the file is held by reading the run
# scripts, not tested here: with -e PRIVATE_TRACKERS_KEY every process sees
# the key anyway (with-contenv), and all of them run as root.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

f=/etc/webtor/secrets/private-trackers.env
assert_eq "$(webtor_exec stat -c %a "$f" </dev/null | tr -d '\r')" "600" "key file mode"
webtor_exec sh -c "grep -Eqx \"PRIVATE_TRACKERS_KEY='[0-9a-f]{64}'\" $f" </dev/null || fail "key file does not hold one 64-hex key"

# proc_env <pgrep pattern> <line> -- status of a line in that process's
# environment. The line is expanded in the container after the key file is
# sourced, so $PRIVATE_TRACKERS_KEY there means the file's key; it is matched
# as a fixed string.
# pgrep -o: the oldest match is the service; this sh carries the pattern in its own argv too
proc_env() {
  webtor_exec sh -c '. '"$f"'; eval "want=\"$2\""; pid=$(pgrep -o -f "$1") && tr "\0" "\n" </proc/$pid/environ | grep -qxF -- "$want"' _ "$1" "$2" </dev/null
}
proc_env '/app/torrent-store serve' 'PRIVATE_TRACKERS_KEY=$PRIVATE_TRACKERS_KEY' || fail "torrent-store does not run with the key file's key"
proc_env '/app/torrent-store serve' 'USE_S3=true' || fail "torrent-store runs without S3"
proc_env '/app/torrent-store serve' 'AWS_BUCKET=torrent-store' || fail "torrent-store bucket is not torrent-store"
proc_env '/app/torrent-http-proxy' 'REST_API_SERVICE_HOST=127.0.0.1' && proc_env '/app/torrent-http-proxy' 'REST_API_SERVICE_PORT=8096' \
  || fail "torrent-http-proxy lacks rest-api's address"
# A here-string, not a pipe: grep -q exits at the first match, and under
# pipefail the writer's EPIPE would turn a found warning into a failure.
grep -q '\[generate-private-trackers-key\] WARNING' <<<"$(docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" logs webtor)" \
  || fail "a generated key was not warned about"

# The record lands in the S3 bucket, not only in Badger.
id="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
wait_for 30 "torrent-store object in S3" webtor_exec test -f "/storage/torrent-store/$id"
echo "PASS: private-key"
