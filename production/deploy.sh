#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'Usage: %s [ENV_FILE] [WAIT_TIMEOUT_SECONDS]\n' "$0" >&2
}

(( $# <= 2 )) || {
  usage
  exit 2
}

ENV_FILE="${1:-${SCRIPT_DIR}/.env.production}"
WAIT_TIMEOUT="${2:-300}"

[[ "${WAIT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] &&
  (( ${#WAIT_TIMEOUT} <= 5 )) &&
  (( 10#${WAIT_TIMEOUT} <= 86400 )) || {
  printf 'Deployment wait timeout must be between 1 and 86400 seconds.\n' >&2
  exit 2
}

command -v timeout >/dev/null 2>&1 || {
  printf 'GNU timeout is required for the bounded maintenance stop.\n' >&2
  exit 1
}

DOUBTFIRE_CONFIG_ONLY=0 "${SCRIPT_DIR}/validate.sh" "${ENV_FILE}"

ENV_FILE="$(cd -- "$(dirname -- "${ENV_FILE}")" && pwd)/$(basename -- "${ENV_FILE}")"

compose=("${SCRIPT_DIR}/compose.sh" --env-file "${ENV_FILE}")

"${compose[@]}" pull

# The hardened web accepts both legacy query callbacks and fragment callbacks,
# while the hardened API emits fragments that an older web build cannot read.
# Stage and health-check web first so a forward rollout cannot expose the
# incompatible API-new/web-old combination through the existing proxy.
if "${compose[@]}" up \
  --detach \
  --no-deps \
  --wait \
  --wait-timeout "${WAIT_TIMEOUT}" \
  webserver; then
  printf 'Hardened web image is healthy; continuing with API and workers.\n'
else
  web_status=$?
  printf 'Web compatibility stage failed; API and workers were not updated and public ingress will be stopped.\n' >&2
  "${compose[@]}" ps --all webserver >&2 || true
  "${compose[@]}" logs --no-color --tail 100 webserver >&2 || true
  timeout --kill-after=10s 120s \
    "${compose[@]}" stop --timeout 60 proxy >&2 || true
  exit "${web_status}"
fi

# Block ingress and quiesce every application writer before the one-shot
# migration. The compatible web stays healthy but is not publicly reachable
# while API/Sidekiq/PDF writers are stopped. Database/Redis remain available.
maintenance_services=(proxy apiserver sidekiq pdfgen migrate)
printf 'Entering bounded migration maintenance window.\n'
if timeout --kill-after=10s 120s \
  "${compose[@]}" stop --timeout 60 "${maintenance_services[@]}"; then
  printf 'Public ingress and application writers are stopped; applying release.\n'
else
  maintenance_status=$?
  printf 'Could not quiesce the running release; migration was not started.\n' >&2
  "${compose[@]}" ps --all "${maintenance_services[@]}" >&2 || true
  timeout --kill-after=10s 120s \
    "${compose[@]}" stop --timeout 60 "${maintenance_services[@]}" >&2 || true
  exit "${maintenance_status}"
fi

if "${compose[@]}" up \
  --detach \
  --wait \
  --wait-timeout "${WAIT_TIMEOUT}" \
  --remove-orphans; then
  :
else
  rollout_status=$?
  printf 'Deployment did not become healthy; ingress and writers will remain stopped.\n' >&2
  "${compose[@]}" ps --all >&2 || true
  "${compose[@]}" logs \
    --no-color \
    --tail 100 \
    migrate apiserver webserver proxy sidekiq pdfgen >&2 || true
  timeout --kill-after=10s 120s \
    "${compose[@]}" stop --timeout 60 "${maintenance_services[@]}" >&2 || true
  exit "${rollout_status}"
fi
"${compose[@]}" ps
