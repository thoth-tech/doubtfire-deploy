#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'Usage: %s [ENV_FILE] [TIMEOUT_SECONDS]\n' "$0" >&2
}

fail() {
  printf 'Production verification failed: %s\n' "$*" >&2
  exit 1
}

(( $# <= 2 )) || {
  usage
  exit 2
}

ENV_FILE="${1:-${SCRIPT_DIR}/.env.production}"
VERIFY_TIMEOUT="${2:-30}"

[[ "${VERIFY_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] &&
  (( ${#VERIFY_TIMEOUT} <= 3 )) &&
  (( 10#${VERIFY_TIMEOUT} <= 300 )) || {
  printf 'Verification timeout must be between 1 and 300 seconds.\n' >&2
  exit 2
}

[[ -f "${ENV_FILE}" ]] || fail "environment file not found: ${ENV_FILE}"

for command_name in curl grep mktemp timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

# Re-run the complete production preflight so this script cannot verify a live
# stack against an invalid, placeholder-bearing, or differently rendered file.
DOUBTFIRE_CONFIG_ONLY=0 "${SCRIPT_DIR}/validate.sh" "${ENV_FILE}"
ENV_FILE="$(cd -- "$(dirname -- "${ENV_FILE}")" && pwd)/$(basename -- "${ENV_FILE}")"

read_environment_value() {
  local wanted_key="$1"
  local line
  local key

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    if [[ "${key}" == "${wanted_key}" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done < "${ENV_FILE}"
  return 1
}

SERVER_NAME="$(read_environment_value SERVER_NAME)" || fail "SERVER_NAME is missing after validation"
[[ -n "${SERVER_NAME}" ]] || fail "SERVER_NAME is empty after validation"

compose=("${SCRIPT_DIR}/compose.sh" --env-file "${ENV_FILE}")
connect_timeout=10
if (( VERIFY_TIMEOUT < connect_timeout )); then
  connect_timeout="${VERIFY_TIMEOUT}"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/doubtfire-verify.XXXXXX")" || fail "cannot create a verification workspace"
cleanup() {
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl_command=(
  curl
  --disable
  --silent
  --show-error
  --noproxy '*'
  --proto '=https'
  --tlsv1.2
  --connect-timeout "${connect_timeout}"
  --max-time "${VERIFY_TIMEOUT}"
  --max-filesize 10485760
)

fetch_public() {
  local label="$1"
  local path="$2"
  local output_file="$3"
  local expected_content_type="${4:-}"
  local metadata
  local status
  local content_type

  if ! metadata="$(
    "${curl_command[@]}" \
      --output "${output_file}" \
      --write-out $'%{http_code}\n%{content_type}' \
      "https://${SERVER_NAME}${path}"
  )"; then
    fail "${label} request failed"
  fi
  status="${metadata%%$'\n'*}"
  content_type="${metadata#*$'\n'}"
  [[ "${status}" == 200 ]] || fail "${label} returned HTTP ${status}, expected 200"
  if [[ "${output_file}" != /dev/null ]]; then
    [[ -s "${output_file}" ]] || fail "${label} returned an empty response"
  fi
  case "${expected_content_type}" in
    "") ;;
    html)
      [[ "${content_type}" == text/html* ]] || fail "${label} returned an unsafe Content-Type"
      ;;
    json)
      [[ "${content_type}" == application/json* ]] || fail "${label} returned an unsafe Content-Type"
      ;;
    javascript)
      [[ "${content_type}" == application/javascript* || "${content_type}" == text/javascript* ]] || fail "${label} returned an unsafe Content-Type"
      ;;
    *)
      fail "${label} has an unknown verifier Content-Type contract"
      ;;
  esac
  printf 'ok - %s\n' "${label}"
}

run_compose_check() {
  local label="$1"
  shift

  if ! timeout --kill-after=5s "${VERIFY_TIMEOUT}s" "${compose[@]}" "$@" >/dev/null; then
    fail "${label} failed"
  fi
  printf 'ok - %s\n' "${label}"
}

fetch_public "public API readiness" /healthz /dev/null
fetch_public "public web readiness" /healthz/web /dev/null

index_file="${temporary_directory}/index.html"
ngsw_file="${temporary_directory}/ngsw.json"
worker_file="${temporary_directory}/ngsw-worker.js"
fetch_public "public web index" /index.html "${index_file}" html
fetch_public "PWA control manifest" /ngsw.json "${ngsw_file}" json
fetch_public "PWA worker script" /ngsw-worker.js "${worker_file}" javascript

grep -Eiq '<!doctype[[:space:]]+html|<html' "${index_file}" || fail "public web index is not HTML"
grep -Eq '"configVersion"[[:space:]]*:[[:space:]]*1' "${ngsw_file}" || fail "ngsw.json has no supported configVersion"
grep -Fq '"assetGroups"' "${ngsw_file}" || fail "ngsw.json has no asset groups"
if grep -Eiq '<!doctype[[:space:]]+html|<html' "${worker_file}"; then
  fail "ngsw-worker.js resolved to HTML instead of the worker"
fi
grep -Fq 'ngsw' "${worker_file}" || fail "ngsw-worker.js does not contain the Angular worker runtime"
printf 'ok - production PWA control files are usable\n'

run_compose_check \
  "API DB and Redis readiness" \
  exec -T apiserver \
  curl --fail --silent --show-error --max-time "${VERIFY_TIMEOUT}" \
  http://127.0.0.1:3000/readiness

run_compose_check \
  "database migration state" \
  exec -T apiserver bundle exec rails db:abort_if_pending_migrations

schema_version_check='expected = 20260824000003; actual = ActiveRecord::Base.connection_pool.migration_context.current_version; abort "Database schema version #{actual} does not match release #{expected}" unless actual == expected'
run_compose_check \
  "release database schema version 20260824000003" \
  exec -T apiserver bundle exec rails runner "${schema_version_check}"

sidekiq_check='require "sidekiq/api"; processes = Sidekiq::ProcessSet.new.to_a; abort "No live Sidekiq process is registered" if processes.empty?; begin; configured_concurrency = Integer(ENV.fetch("DF_SIDEKIQ_CONCURRENCY"), 10); rescue KeyError, ArgumentError; abort "Sidekiq concurrency configuration is missing or invalid"; end; abort "Live Sidekiq concurrency does not match configuration" unless processes.all? { |process| process["concurrency"].to_i == configured_concurrency }; expected = { "aggregate_peer_progress" => "AggregatePeerProgressJob", "poll_communication_set_schedules" => "PollCommunicationSetSchedulesJob", "send_new_task_available_notifications" => "SendNewTaskAvailableNotificationsJob", "send_due_soon_reminders" => "SendDueSoonRemindersJob" }; jobs = Sidekiq::Cron::Job.all; valid = expected.all? { |name, klass| job = jobs.find { |candidate| candidate.name == name }; job && job.klass == klass && job.status == "enabled" }; abort "Required Sidekiq cron jobs are missing, disabled, or mapped to the wrong class" unless valid'
run_compose_check \
  "Sidekiq process, concurrency, and required cron schedule" \
  exec -T sidekiq bundle exec rails runner "${sidekiq_check}"

feature_configuration_check='begin; minimum = Integer(ENV.fetch("DF_PPI_MINIMUM_COHORT_SIZE"), 10); stale_after = Integer(ENV.fetch("DF_PPI_STALE_AFTER_HOURS"), 10); rescue KeyError, ArgumentError; abort "PPI configuration is missing or invalid"; end; api_floor = PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE; abort "PPI configuration is below the API privacy floor" unless minimum >= 21 && minimum >= api_floor; abort "PPI freshness configuration is outside the approved production bounds" unless stale_after.between?(1, 48); vapid_keys = %w[DOUBTFIRE_VAPID_PUBLIC_KEY DOUBTFIRE_VAPID_PRIVATE_KEY DOUBTFIRE_VAPID_SUBJECT]; abort "VAPID configuration is missing" unless vapid_keys.all? { |key| !ENV[key].to_s.empty? }; abort "Web Push is not configured" unless PushNotificationService.configured?'
for service_name in apiserver sidekiq; do
  run_compose_check \
    "live VAPID/PPI configuration for ${service_name}" \
    exec -T "${service_name}" bundle exec rails runner "${feature_configuration_check}"
done

printf '\nAutomated production verification passed.\n'
cat <<'MANUAL_GATES'

MANUAL GATES STILL REQUIRED BEFORE ACCEPTANCE:
- MANUAL-IDP: complete a real production identity-provider login and logout.
- MANUAL-SMTP: trigger a notification and confirm receipt through the approved SMTP service.
- MANUAL-PUSH: opt in on each supported real browser/device, receive a push in the background, and follow its link.
- MANUAL-PPI: verify compact and advanced fresh peer-only views, the default-on profile preference, and remaining-peer/legacy/viewer-stale/vector-suppressed views without recording student-level data.
- MANUAL-PDF-JPLAG: generate a PDF and complete an approved JPlag check.
- MANUAL-SCORM: use a disposable launch token to verify no-referrer and all edge/API/observability log controls, then revoke it.
- MANUAL-RECOVERY: prove the current backup can be restored and the release can be rolled back under the runbook.
MANUAL_GATES
