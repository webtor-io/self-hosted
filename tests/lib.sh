# Shared helpers for smoke scenarios. Sourced, not executed.
set -euo pipefail

# csrf_from TEXT -- the value of the first _csrf hidden input in TEXT.
#
# Bash regex, not grep: it takes the first match by definition, with no pipe
# and no subprocess. The two forms this replaces were both wrong here.
# `grep -o ... | head -1` lets head exit at one line while grep is still
# writing, and `set -o pipefail` (top of this file) turns the resulting EPIPE
# into a failed assertion -- a page that DOES carry a token reported as one
# that does not. `grep -m1 -o` is not a fix either: -m1 stops after the first
# matching LINE but -o still prints every match on it, so a page with two
# _csrf inputs on one line yields two values joined by a newline.
csrf_from() {
  [[ "$1" =~ name=\"_csrf\"[[:space:]]+value=\"([^\"]*)\" ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# first_group PATTERN TEXT -- first capture group of PATTERN in TEXT.
# Same reasoning as csrf_from; PATTERN is an ERE with exactly one group.
first_group() {
  [[ "$2" =~ $1 ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
BASE_URL="${BASE_URL:-http://localhost:${WEBTOR_HOST_PORT:-8080}}"
# Must match the -p passed by run.sh.
COMPOSE_PROJECT="${COMPOSE_PROJECT:-webtor-smoke}"
# The published webtor-cli that 92-cli.sh and 99-private.sh run. Renovate does
# not see this pin (92-cli.sh says why): bump it by hand.
CLI_IMAGE="ghcr.io/webtor-io/webtor-cli:v1.13.0@sha256:924545062d9ad96ed29de6aeb1d68751109daaea342ced67b0cb836f0e94dad5"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  [ "$actual" = "$expected" ] || fail "$msg (got '$actual', want '$expected')"
}

# wait_for <timeout-sec> <description> <command...>
# Retries until the command succeeds or the timeout expires. On timeout the last
# attempt's exit status and combined output are reported: without them every
# failure looks identical, and "rejected immediately" (e.g. a 403) is
# indistinguishable from "genuinely still unavailable".
WAIT_FOR_OUTPUT_LIMIT="${WAIT_FOR_OUTPUT_LIMIT:-500}"
wait_for() {
  local timeout="$1" desc="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  local out rc detail
  while true; do
    # Assignment is the non-final operand of &&, so a failure here does not
    # trip `set -e`; it falls through to the deadline check below.
    out="$("$@" 2>&1)" && return 0
    rc=$?
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done

  # Bash substring, not `printf | head -c`: under `set -o pipefail` that
  # pipeline reports 141 once $out exceeds the pipe buffer, because head
  # exits at its limit and printf dies with EPIPE. As a simple command under
  # `set -e` that killed the script here silently -- no timeout message at
  # all -- and it fired exactly when the timed-out command had produced a
  # large body, i.e. when the diagnostic was most needed.
  detail="${out:0:$WAIT_FOR_OUTPUT_LIMIT}"
  if [ "${#out}" -gt "$WAIT_FOR_OUTPUT_LIMIT" ]; then
    detail="$detail ...[truncated, ${#out} bytes total]"
  fi
  [ -n "$detail" ] || detail='(no output)'
  fail "timed out after ${timeout}s waiting for: $desc
  last attempt: '$*'
  exit status:  $rc
  output:       $detail"
}

# api <method> <path> [extra curl args...]
api() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" "$BASE_URL$path" "$@"
}

# api_key -- returns a cached API key for this run, minting one only if the
# account does not already have one.
#
# The suite's shared container runs with no ADMIN_PASSWORD, so every visitor
# is auto-admin (HasAuth passes with no login) -- that is what lets this mint
# a key with no credentials. Issuing needs a session cookie AND a CSRF token:
# POST /api-credentials/generate is not covered by the CSRF-ignore list (only
# the /api/ prefix is ignored, and that does not reach /api-credentials), so
# a page that renders a form is fetched first to establish a session and
# scrape the _csrf hidden input, exactly like a browser submitting that form
# would (see the login flow in 60-admin-password.sh for the same pattern).
# /profile is used for that page: it is where a real admin goes to manage
# API credentials, and it renders a form carrying the same _csrf input.
#
# GET /api-credentials/key is checked before generating: it returns 200 with
# {"key":"<uuid>"} if a key already exists for the account, 204 with no body
# otherwise. Fetching first (rather than unconditionally generating) means
# re-running scenarios against the same shared container reuses the one key
# already on the account instead of minting a fresh one every time.
#
# Cached in a file, not a plain shell variable: every caller so far invokes
# this through `apiv1`, and every existing call site captures apiv1's output
# with `x="$(apiv1 ...)"` -- command substitution always forks a subshell in
# bash, so a variable assigned inside api_key() would only ever update that
# subshell's copy and vanish the instant it exits, silently re-running the
# whole profile/CSRF/generate dance on every single call. $$ is stable across
# those subshells (bash documents it as "the process ID of the invoking
# shell, not the subshell"), so a $$-scoped file survives them and still
# gives each scenario script -- a fresh `bash scenario.sh` process -- its own
# cache.
#
# Removed at source time, not just left to leak: `run.sh` does `compose
# down -v` between runs, which wipes the embedded Postgres the key is stored
# in. PIDs get reused across separate runs (there is no cross-run identity
# tying a given $$ to a given container instance), so a stale file surviving
# from an earlier run under the same PID would hand a scenario a key for an
# account that no longer exists -- surfacing as 401s that look like an auth
# regression rather than what they are (a leftover temp file). Clearing it
# on every source guarantees each scenario script starts from a clean slate.
# The file itself is still not cleaned up *after* a successful run (a few
# bytes; scoping an EXIT trap here would fight the EXIT trap every scenario
# already sets for its own temp files, since only the last trap wins) --
# only the staleness/collision risk is what this addresses.
_API_KEY_CACHE_FILE="${TMPDIR:-/tmp}/webtor-smoke-api-key.$$"
rm -f "$_API_KEY_CACHE_FILE"
api_key() {
  if [ -s "$_API_KEY_CACHE_FILE" ]; then
    cat "$_API_KEY_CACHE_FILE"
    return 0
  fi

  local jar body csrf_token resp code key_json key

  jar="$(mktemp)"
  # This function only ever runs inside the subshell a caller's command
  # substitution forks (every call site is `key="$(api_key)"` or the
  # nested `$(api_key)` inside apiv1's own -H argument), so an EXIT trap
  # set here is scoped to that subshell alone -- it fires when this
  # function's `fail` calls `exit`, when it returns normally, on every
  # path, and it cannot clobber a scenario's own EXIT trap, which belongs
  # to a different (the parent) shell process entirely.
  # Expand $jar now, not when the trap fires: by then this function has
  # returned and the local is gone, which under `set -u` aborts the subshell
  # with "jar: unbound variable" instead of cleaning anything up.
  trap "rm -f '$jar'" EXIT
  body="$(curl --fail-with-body -sS -c "$jar" "$BASE_URL/profile")"
  csrf_token="$(csrf_from "$body")" || csrf_token=""
  [ -n "$csrf_token" ] || fail "GET /profile did not render an _csrf token to submit"

  resp="$(curl -sS -b "$jar" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/api-credentials/key")"
  code="${resp##*HTTPSTATUS:}"
  key_json="${resp%HTTPSTATUS:*}"

  if [ "$code" = "204" ]; then
    curl --fail-with-body -sS -b "$jar" -c "$jar" \
      -X POST --data-urlencode "_csrf=$csrf_token" \
      "$BASE_URL/api-credentials/generate" >/dev/null

    resp="$(curl -sS -b "$jar" -w 'HTTPSTATUS:%{http_code}' "$BASE_URL/api-credentials/key")"
    code="${resp##*HTTPSTATUS:}"
    key_json="${resp%HTTPSTATUS:*}"
  fi

  [ "$code" = "200" ] || fail "GET /api-credentials/key returned unexpected status $code: $key_json"

  key="$(printf '%s' "$key_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])' 2>&1)" \
    || fail "could not parse API key from /api-credentials/key response: $key ($key_json)"
  [ -n "$key" ] || fail "API key response parsed but was empty: $key_json"

  printf '%s' "$key" > "$_API_KEY_CACHE_FILE"
  cat "$_API_KEY_CACHE_FILE"
}

# apiv1 <method> <path> [extra curl args...]
# Mirrors `api` above but hits web-ui's authenticated /api/v1, which is the
# only way to create/read resources now that nginx no longer exposes
# rest-api directly. A middleware in front of /api/v1 copies the
# Authorization header's key into the query parameter the handler
# cross-checks, so the caller only needs to supply the header.
#
# api_key's own `fail` calls only exit *its* subshell -- inlining
# `$(api_key)` straight into curl's -H argument would silently discard
# that exit status (a failed command substitution used as part of a larger
# argument does not itself trip `set -e`), so curl would still run with an
# empty bearer token, hit the network, get a 401, and report a generic
# curl error instead of api_key's actual diagnostic (a missing CSRF token,
# an unexpected /api-credentials/key status, an unparseable key, ...).
# Capturing into a local first and checking its own exit status here makes
# sure that diagnostic is what the scenario actually fails on, and skips
# the pointless network round-trip.
apiv1() {
  local method="$1" path="$2"
  shift 2
  local key
  key="$(api_key)" || fail "apiv1: could not obtain an API key for $method $path"
  # The explicit Content-Type is load-bearing, not decoration. curl defaults a
  # --data-binary body to application/x-www-form-urlencoded, and the global
  # CSRF middleware parses a form-encoded body looking for its token -- which
  # consumes the request body before the handler reads it. POST /resource then
  # sees nothing and answers 400 "the body must be a .torrent file or a magnet
  # uri". Declaring a non-form type keeps the bytes intact. Harmless on the
  # GETs, which carry no body at all.
  curl --fail-with-body -sS -X "$method" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/x-bittorrent" \
    "$BASE_URL/api/v1$path" "$@"
}

# apiv1_json <method> <path> [extra curl args...]
# Same as apiv1, but declares application/json instead of
# application/x-bittorrent. apiv1's Content-Type is load-bearing for
# POST /resource (see the comment above apiv1), but endpoints that decode a
# JSON body with ShouldBindJSON only need the header to not trigger the CSRF
# middleware's form-parsing path -- x-bittorrent already avoids that, so this
# variant exists for correctness/readability at call sites that send JSON,
# not because apiv1 was observed to fail against them.
apiv1_json() {
  local method="$1" path="$2"
  shift 2
  local key
  key="$(api_key)" || fail "apiv1_json: could not obtain an API key for $method $path"
  curl --fail-with-body -sS -X "$method" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    "$BASE_URL/api/v1$path" "$@"
}

# webtor_exec <cmd...>
# Runs a command inside the running webtor container (the "webtor" service
# in docker-compose.yml) via docker compose exec.
webtor_exec() {
  docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" \
    exec -T webtor "$@"
}
