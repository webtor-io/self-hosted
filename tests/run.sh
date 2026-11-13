#!/usr/bin/env bash
# Run the self-hosted smoke suite against an image.
#   tests/run.sh [image]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WEBTOR_IMAGE="${1:-${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}}"
# Override when 8080 is taken on the host (a local dev server, another suite run).
export WEBTOR_HOST_PORT="${WEBTOR_HOST_PORT:-8080}"
compose=(docker compose -f "$here/docker-compose.yml" -p webtor-smoke)

echo "== image under test: $WEBTOR_IMAGE (host port $WEBTOR_HOST_PORT)"

"$here/fixtures/build.sh"

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "== webtor logs (tail) =="
    "${compose[@]}" logs --tail 200 webtor || true
  fi
  "${compose[@]}" down -v --remove-orphans || true
  exit "$rc"
}
trap cleanup EXIT

"${compose[@]}" up -d --force-recreate

failed=0
# SCENARIOS="00 71" runs only the scenarios whose names start with those
# prefixes, in that order; unset runs them all (CI). read, not an unquoted
# expansion, so the default "*" is not globbed against the current directory.
# A prefix that matches nothing stays a literal path and fails as a scenario.
read -ra prefixes <<<"${SCENARIOS:-*}"
for p in "${prefixes[@]}"; do
  for scenario in "$here"/scenarios/$p*.sh; do
    name="$(basename "$scenario")"
    echo "== running $name"
    if bash "$scenario"; then
      :
    else
      echo "!! $name failed"
      failed=1
    fi
  done
done

[ "$failed" -eq 0 ] || { echo "SUITE FAILED"; exit 1; }
echo "SUITE PASSED"
