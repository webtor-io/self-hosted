#!/usr/bin/env bash
# The embedded S3 store (versitygw over /storage) is provisioned and
# actually serving, not just registered with s6.
#
# Not to be confused with 91-s3-webui.sh, which covers a completely
# different "s3": web-ui's own /s3 endpoint, an S3-protocol gateway over the
# user's torrent library (buckets torrents/all/movies/series), reached
# through nginx on the public web port. This scenario is about versitygw on
# 127.0.0.1:8099, internal-only, buckets vault/posters/subtitles/thumbnails/
# torrent-store.
# Same three letters, unrelated services -- see 91-s3-webui.sh's own header.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# 1. The five bucket directories exist inside the container. s3/run creates
# them itself (a bucket is just a directory under $STORAGE_DIR to versitygw's
# posix backend) after its writability/xattr probes pass.
for b in vault posters subtitles thumbnails torrent-store; do
  webtor_exec test -d "/storage/$b" </dev/null \
    || fail "bucket directory /storage/$b does not exist"
done

# 2. s6 supervises the s3 service and reports it up.
s3_up() {
  webtor_exec /command/s6-svstat /run/service/s3 </dev/null 2>/dev/null | grep -q '^up'
}
wait_for 60 "s3 service up in s6" s3_up

# 3. The check that actually distinguishes "supervised" from "serving": an
# object written through the S3 endpoint comes back byte-identical.
#
# This is load-bearing, not redundant with #2. s3/run execs `sleep infinity`
# instead of exiting whenever it hits a fatal storage problem (unwritable
# STORAGE_DIR, no xattr support, an occupied bucket path) -- deliberately,
# so s6 doesn't crash-loop it -- which means s6-svstat reports "up" for that
# idle sleep exactly the same as for a live versitygw. Only actually talking
# to the endpoint tells the two apart.
#
# Driven via `docker exec` (webtor_exec) rather than publishing 8099 in
# tests/docker-compose.yml: the endpoint is bound to 127.0.0.1 inside the
# container and deliberately not proxied by nginx or published anywhere in
# production (see s6-overlay/s6-rc.d/s3/run) -- it has no auth of its own
# beyond the generated key/secret, so publishing it would test a topology
# that does not exist in production. The container's own curl (Alpine
# 3.22, curl 8.14.1) supports --aws-sigv4, so no host-only tooling is
# needed to sign the request.
creds="$(webtor_exec sh -c 'set -a; . /etc/webtor/secrets/s3.env; set +a; printf "%s %s" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"' </dev/null)" \
  || fail "could not read S3 credentials from inside the container"
access_key="${creds%% *}"
secret_key="${creds##* }"
[ -n "$access_key" ] && [ -n "$secret_key" ] && [ "$access_key" != "$secret_key" ] \
  || fail "S3 credentials read from the container look empty or malformed: '$creds'"

obj_key="smoke-$$-$(date +%s)"
payload="$(head -c 4096 /dev/urandom | base64)"

# The credentials and the key travel as positional arguments, and the
# container-side script is single-quoted so the host expands none of it.
# Interpolating them into the string instead would let one apostrophe in a
# credential close the quoting and run whatever follows inside the container.
# Today's generated values are hex and cannot contain one -- but the same
# generator hands through an operator-supplied AWS_ACCESS_KEY_ID verbatim,
# which is a documented way to run this image, so the safety of this test
# would rest on a user's choice of password characters.
s3_curl() {
  webtor_exec sh -c '
    key=$1; secret=$2; obj=$3; shift 3
    exec curl --fail-with-body -sS \
      --aws-sigv4 "aws:amz:us-east-1:s3" \
      --user "$key:$secret" \
      "$@" \
      "http://127.0.0.1:8099/thumbnails/$obj"
  ' _ "$access_key" "$secret_key" "$obj_key" "$@"
}

# Remove the object however this scenario ends -- including the assertion
# failure below, which exits before any cleanup that follows it in the body.
# run.sh does `compose down -v` either way, so this matters for the manual
# iteration workflow against a container kept alive between runs.
cleanup_object() {
  s3_curl -X DELETE </dev/null >/dev/null 2>&1 || true
}
trap cleanup_object EXIT

put_object() {
  printf '%s' "$payload" | s3_curl -X PUT --data-binary @-
}
wait_for 30 "PUT object through the S3 endpoint" put_object

got="$(s3_curl </dev/null)" || fail "GET object through the S3 endpoint failed"

assert_eq "$got" "$payload" "object round-tripped through the S3 endpoint is not byte-identical"

echo "PASS: s3"
