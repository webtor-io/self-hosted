#!/usr/bin/env bash
# An instance with no S3 at all (USE_LOCALS3=false, no AWS_ENDPOINT):
# torrent-store runs on Badger alone, without USE_S3, and public uploads keep
# working. Also: a key given with -e PRIVATE_TRACKERS_KEY is stored as given,
# which is what lets an operator keep it across a container recreate.
#
# Both are read at startup, so this needs its own container, like
# 60-admin-password.sh. The key is a fake one.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

name=webtor-smoke-nos3
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e USE_LOCALS3=false \
  -e PRIVATE_TRACKERS_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -p 18097:8080 "$WEBTOR_IMAGE" >/dev/null
BASE_URL=http://localhost:18097

wait_for 240 "no-S3 instance to boot" curl -fsS -o /dev/null "$BASE_URL/"
x() { docker exec "$name" "$@" </dev/null; }
wait_for 60 "torrent-store up" sh -c "docker exec $name /command/s6-svstat /run/service/torrent-store | grep -q '^up'"
x sh -c 'pid=$(pgrep -o -f "/app/torrent-store serve") && ! tr "\0" "\n" </proc/$pid/environ | grep -qx "USE_S3=true"' || fail "USE_S3 without an S3"
x grep -qx "PRIVATE_TRACKERS_KEY='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'" /etc/webtor/secrets/private-trackers.env \
  || fail "a key from the environment is not stored as given"
resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")" || fail "a public upload fails without S3"
assert_eq "$(printf '%s' "$resource" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["infohash"])' "$FIXTURE_DIR/summary.json")" "public upload id without S3"
echo "PASS: torrent-store-no-s3"
