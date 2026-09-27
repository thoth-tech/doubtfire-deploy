#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY_DIR="$(cd -- "${PRODUCTION_DIR}/.." && pwd)"

# Prevent a development identity-provider registration from being committed
# again. Values are intentionally not printed because the failure itself may
# represent a credential exposure.
python3 - "${REPOSITORY_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
configuration_files = [
    root / ".devcontainer/devcontainer.env",
    root / ".devcontainer/docker-compose.yml",
    root / "development/api.env",
    root / "development/docker-compose.yml",
    root / "development/docker-compose.full.yml",
    root / "production/.env.production.example",
    root / "production/docker-compose.yml",
]
institution_markers = (
    "rapid.test.aaf.edu.au",
    "signon-uat.deakin.edu.au",
    "sync-uat.deakin.edu.au",
)
literal_secret = re.compile(r"^\s*DF_SECRET_KEY_AAF\s*(?::|=)\s*(.*)$")
failures = []

for path in configuration_files:
    text = path.read_text(encoding="utf-8")
    lowered = text.lower()
    if any(marker in lowered for marker in institution_markers):
        failures.append(f"{path.relative_to(root)} contains an institution AAF endpoint")
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = literal_secret.match(line)
        if not match:
            continue
        value = match.group(1).strip()
        if value and not value.startswith("${") and value != "REPLACE_ME":
            failures.append(
                f"{path.relative_to(root)}:{line_number} contains a literal AAF secret"
            )

if failures:
    raise SystemExit("\n".join(failures))
print("ok - tracked configuration has no institution AAF credential")
PY

grep -Fq 'DF_AUTH_METHOD: ${DF_AUTH_METHOD:-database}' \
  "${REPOSITORY_DIR}/.devcontainer/docker-compose.yml"
grep -Fq 'DF_AUTH_METHOD=database' \
  "${REPOSITORY_DIR}/.devcontainer/.env.example"
grep -Fq 'DF_AUTH_METHOD: ${DF_AUTH_METHOD:-database}' \
  "${REPOSITORY_DIR}/development/docker-compose.yml"
grep -Fq 'DF_AUTH_METHOD=database' \
  "${REPOSITORY_DIR}/development/.env.example"
printf 'ok - optional development AAF configuration keeps an explicit safe auth default\n'

# Unix socket paths are short on some platforms (notably macOS), so keep this
# fixture directly under /tmp instead of a potentially long TMPDIR path.
FIXTURE_DIR="$(mktemp -d "/tmp/df-production-test.XXXXXX")"
cleanup() {
  rm -rf -- "${FIXTURE_DIR}"
}
trap cleanup EXIT INT TERM

HOSTNAME_UNDER_TEST=ontrack.test.edu.au
CERTIFICATE_PATH="${FIXTURE_DIR}/fullchain.pem"
PRIVATE_KEY_PATH="${FIXTURE_DIR}/private.key"
BASE_ENV="${FIXTURE_DIR}/valid.env"

mkdir -p \
  "${FIXTURE_DIR}/student-work" \
  "${FIXTURE_DIR}/logs" \
  "${FIXTURE_DIR}/mariadb" \
  "${FIXTURE_DIR}/redis" \
  "${FIXTURE_DIR}/student-work/jplag" \
  "${FIXTURE_DIR}/student-work/archive/jplag"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "${PRIVATE_KEY_PATH}" \
  -out "${CERTIFICATE_PATH}" \
  -subj "/CN=${HOSTNAME_UNDER_TEST}" \
  -addext "subjectAltName=DNS:${HOSTNAME_UNDER_TEST}" \
  >/dev/null 2>&1
chmod 600 "${PRIVATE_KEY_PATH}"

# Compose rendering does not contact the daemon. CI uses config-only mode for
# its fixture and separately verifies that the live preflight remains
# fail-closed when the standard local daemon socket is unavailable.
export DOUBTFIRE_CONFIG_ONLY=1

cat > "${FIXTURE_DIR}/aliases" <<'EOF'
root: operations@test.edu.au
EOF
cat > "${FIXTURE_DIR}/msmtprc" <<'EOF'
defaults
auth on
tls on
account server
host smtp.test.edu.au
port 587
from ontrack@test.edu.au
user ontrack-service
password fixture-only-random-value
account default : server
EOF
chmod 600 "${FIXTURE_DIR}/msmtprc"

DIGEST_ONE="sha256:1111111111111111111111111111111111111111111111111111111111111111"
DIGEST_TWO="sha256:2222222222222222222222222222222222222222222222222222222222222222"
DIGEST_THREE="sha256:3333333333333333333333333333333333333333333333333333333333333333"

cat > "${BASE_ENV}" <<EOF
COMPOSE_PROJECT_NAME=doubtfire-production-test
SERVER_NAME=${HOSTNAME_UNDER_TEST}
DF_INSTITUTION_HOST=https://${HOSTNAME_UNDER_TEST}
TZ=Australia/Melbourne
CLIENT_MAX_BODY_SIZE=1g
PROXY_IMAGE=nginx@${DIGEST_ONE}
MARIADB_IMAGE=mariadb@${DIGEST_TWO}
REDIS_IMAGE=redis@${DIGEST_THREE}
DOCKER_SOCKET_PROXY_IMAGE=haproxy:3.2-alpine@${DIGEST_ONE}
DOUBTFIRE_API_IMAGE=lmsdoubtfire/apiserver@${DIGEST_TWO}
DOUBTFIRE_APP_IMAGE=lmsdoubtfire/appserver@${DIGEST_THREE}
DOUBTFIRE_WEB_IMAGE=lmsdoubtfire/doubtfire-web@${DIGEST_ONE}
TEXLIVE_IMAGE=lmsdoubtfire/formatif-latex@${DIGEST_TWO}
JPLAG_IMAGE=lmsdoubtfire/doubtfire-jplag@${DIGEST_THREE}
STUDENT_WORK_PATH=${FIXTURE_DIR}/student-work
DOUBTFIRE_LOG_PATH=${FIXTURE_DIR}/logs
MARIADB_DATA_PATH=${FIXTURE_DIR}/mariadb
REDIS_DATA_PATH=${FIXTURE_DIR}/redis
JPLAG_REPORT_PATH=${FIXTURE_DIR}/student-work/jplag
JPLAG_ARCHIVE_REPORT_PATH=${FIXTURE_DIR}/student-work/archive/jplag
TLS_CERTIFICATE_PATH=${CERTIFICATE_PATH}
TLS_PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH}
ALIASES_PATH=${FIXTURE_DIR}/aliases
MSMTPRC_PATH=${FIXTURE_DIR}/msmtprc
DOCKER_SOCKET_PATH=/var/run/docker.sock
MARIADB_DATABASE=doubtfire
MARIADB_USER=dfire
MARIADB_PASSWORD=fixture-database-password-123456789
MARIADB_ROOT_PASSWORD=fixture-root-password-987654321
DF_SECRET_KEY_BASE=base_0123456789abcdef0123456789abcdef
DF_SECRET_KEY_ATTR=attr_0123456789abcdef0123456789abcdef
DF_SECRET_KEY_DEVISE=devise_0123456789abcdef0123456789abcdef
DF_SECRET_KEY_MOSS=
DF_ENCRYPTION_PRIMARY_KEY=primary_0123456789abcdef0123456789abcdef
DF_ENCRYPTION_DETERMINISTIC_KEY=deterministic_0123456789abcdef0123456789abcdef
DF_ENCRYPTION_KEY_DERIVATION_SALT=salt_0123456789abcdef0123456789abcdef
DF_SIDEKIQ_CONCURRENCY=5
DF_PPI_MINIMUM_COHORT_SIZE=21
DF_PPI_STALE_AFTER_HOURS=48
DF_TEAMS_ANNOUNCEMENTS_ENABLED=false
DF_TEAMS_TENANT_ID=
DF_TEAMS_CHANNEL_MAPPINGS=[]
DF_TEAMS_CLIENT_ID=
DF_TEAMS_CLIENT_SECRET=
DOUBTFIRE_VAPID_PUBLIC_KEY=BGmEh2DUs9VeJOXeMyaM4Lp5dGpe7qvFrcZn6o-3YMmQdl_mU6T4G0f4ZUfpmMb-NVNK5PaxmV8fcom_r65BujA
DOUBTFIRE_VAPID_PRIVATE_KEY=seHBhwGDAn88u-5mzxBV-6jn2cSn_zFp2BpkLDn95uw
DOUBTFIRE_VAPID_SUBJECT=mailto:push-operations@test.edu.au
DF_INSTITUTION_PRODUCT_NAME=OnTrack
DF_INSTITUTION_SETTINGS_RB=no_institution_setting.rb
DF_INSTITUTION_EMAIL_DOMAIN=test.edu.au
DF_INSTITUTION_EMAIL_SENDER=ontrack@test.edu.au
DF_INSTITUTION_NAME=Test University
DF_AUTH_METHOD=saml
DF_AAF_ISSUER_URL=
DF_AAF_AUDIENCE_URL=
DF_AAF_CALLBACK_URL=
DF_AAF_IDENTITY_PROVIDER_URL=
DF_AAF_UNIQUE_URL=
DF_AAF_AUTH_SIGNOUT_URL=
DF_SECRET_KEY_AAF=
DF_SAML_METADATA_URL=https://identity.test.edu.au/metadata
DF_SAML_CONSUMER_SERVICE_URL=https://${HOSTNAME_UNDER_TEST}/api/auth/jwt
DF_SAML_SP_ENTITY_ID=https://${HOSTNAME_UNDER_TEST}
DF_SAML_IDP_TARGET_URL=https://identity.test.edu.au/saml2
DF_SAML_IDP_SAML_NAME_IDENTIFIER_FORMAT=urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress
DF_LDAP_HOST=
DF_LDAP_PORT=
DF_LDAP_ATTRIBUTE=
DF_LDAP_BASE=
DF_LDAP_SSL=true
DF_LDAP_USE_ADMIN_TO_BIND=false
DF_LDAP_ADMIN_USER=
DF_LDAP_ADMIN_PWD=
TEXLIVE_MEMORY_LIMIT=2g
TEXLIVE_CPU_LIMIT=2
TEXLIVE_PIDS_LIMIT=256
JPLAG_MEMORY_LIMIT=4g
JPLAG_CPU_LIMIT=2
JPLAG_PIDS_LIMIT=256
DF_MAIL_PERFORM_DELIVERIES=yes
DF_MAIL_DELIVERY_METHOD=smtp
DF_SMTP_ADDRESS=smtp.test.edu.au
DF_SMTP_PORT=587
DF_SMTP_DOMAIN=test.edu.au
DF_SMTP_USERNAME=ontrack-service
DF_SMTP_PASSWORD=fixture-smtp-password
DF_SMTP_AUTHENTICATION=plain
OVERSEER_ENABLED=0
EOF
chmod 600 "${BASE_ENV}"

replace_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local replacement="${file}.replacement"
  awk -v key="${key}" -v value="${value}" '
    index($0, key "=") == 1 { $0 = key "=" value }
    { print }
  ' "${file}" > "${replacement}"
  mv "${replacement}" "${file}"
  chmod 600 "${file}"
}

expect_failure() {
  local name="$1"
  local key="$2"
  local value="$3"
  local expected="$4"
  local fixture="${FIXTURE_DIR}/${name}.env"
  local output

  cp "${BASE_ENV}" "${fixture}"
  replace_value "${fixture}" "${key}" "${value}"

  if output="$("${PRODUCTION_DIR}/validate.sh" "${fixture}" 2>&1)"; then
    printf 'Expected %s to fail.\n' "${name}" >&2
    exit 1
  fi
  printf '%s' "${output}" | grep -Fq "${expected}" || {
    printf 'Unexpected %s failure: %s\n' "${name}" "${output}" >&2
    exit 1
  }
  printf 'ok - %s\n' "${name}"
}

"${PRODUCTION_DIR}/validate.sh" "${BASE_ENV}" >/dev/null
printf 'ok - valid production configuration\n'

MARIADB_PASSWORD=ambient-override \
  "${PRODUCTION_DIR}/compose.sh" --env-file "${BASE_ENV}" config --format json \
  > "${FIXTURE_DIR}/compose.json"
if grep -Fq ambient-override "${FIXTURE_DIR}/compose.json"; then
  printf 'Ambient shell values overrode the validated environment file.\n' >&2
  exit 1
fi
printf 'ok - ambient Compose overrides are ignored\n'
python3 -B "${SCRIPT_DIR}/compose_contract_test.py" "${FIXTURE_DIR}/compose.json"

teams_env="${FIXTURE_DIR}/teams.env"
cp "${BASE_ENV}" "${teams_env}"
replace_value "${teams_env}" DF_TEAMS_ANNOUNCEMENTS_ENABLED true
replace_value "${teams_env}" DF_TEAMS_TENANT_ID 11111111-1111-1111-1111-111111111111
replace_value "${teams_env}" DF_TEAMS_CLIENT_ID 44444444-4444-4444-4444-444444444444
replace_value "${teams_env}" DF_TEAMS_CLIENT_SECRET fixture-only-teams-application-secret
replace_value "${teams_env}" DF_TEAMS_CHANNEL_MAPPINGS '[{"unit_id":111,"team_id":"22222222-2222-2222-2222-222222222222","channel_id":"19:fixture@thread.tacv2","publisher_ids":["33333333-3333-3333-3333-333333333333"],"student_visible":true}]'
"${PRODUCTION_DIR}/validate.sh" "${teams_env}" >/dev/null
"${PRODUCTION_DIR}/compose.sh" --env-file "${teams_env}" config --format json > "${FIXTURE_DIR}/teams-compose.json"
python3 -B "${SCRIPT_DIR}/compose_contract_test.py" "${FIXTURE_DIR}/teams-compose.json" --teams-configured
printf 'ok - Teams metadata is shared only by API and worker; credentials are worker-only\n'

ordinary_base_env="${BASE_ENV}"
BASE_ENV="${teams_env}"
expect_failure teams-missing-tenant DF_TEAMS_TENANT_ID '' "must be set"
expect_failure teams-invalid-client DF_TEAMS_CLIENT_ID invalid-guid "directory GUID"
expect_failure teams-missing-secret DF_TEAMS_CLIENT_SECRET '' "must be set"
expect_failure teams-no-mappings DF_TEAMS_CHANNEL_MAPPINGS '[]' "Teams channel mappings are invalid"
expect_failure teams-malformed-mapping DF_TEAMS_CHANNEL_MAPPINGS '[invalid]' "Teams channel mappings are invalid"
expect_failure teams-private-channel DF_TEAMS_CHANNEL_MAPPINGS '[{"unit_id":111,"team_id":"22222222-2222-2222-2222-222222222222","channel_id":"19:fixture@thread.tacv2","publisher_ids":["33333333-3333-3333-3333-333333333333"],"student_visible":false}]' "Teams channel mappings are invalid"
expect_failure teams-missing-publisher DF_TEAMS_CHANNEL_MAPPINGS '[{"unit_id":111,"team_id":"22222222-2222-2222-2222-222222222222","channel_id":"19:fixture@thread.tacv2","student_visible":true}]' "Teams channel mappings are invalid"
expect_failure teams-invalid-enabled DF_TEAMS_ANNOUNCEMENTS_ENABLED yes "must be true or false"
BASE_ENV="${ordinary_base_env}"

grep -Fq 'resolver 127.0.0.11' "${PRODUCTION_DIR}/proxy-nginx.conf.template"
grep -Fq 'proxy_pass http://$api_upstream/readiness' "${PRODUCTION_DIR}/proxy-nginx.conf.template"
grep -Fq 'proxy_pass http://$web_upstream' "${PRODUCTION_DIR}/proxy-nginx.conf.template"
printf 'ok - proxy refreshes service discovery\n'

proxy_template="${PRODUCTION_DIR}/proxy-nginx.conf.template"
grep -Fq 'map $uri $doubtfire_access_loggable' "${proxy_template}"
grep -Fq 'map $uri $doubtfire_referrer_policy' "${proxy_template}"
grep -Fq '~^/api/scorm(?:/|$) 0;' "${proxy_template}"
grep -Fq '~^/api/scorm(?:/|$) no-referrer;' "${proxy_template}"
server_count="$(grep -Ec '^server \{' "${proxy_template}")"
conditional_access_log_count="$(grep -Fc 'access_log /var/log/nginx/access.log main if=$doubtfire_access_loggable;' "${proxy_template}")"
[[ "${server_count}" -gt 0 && "${conditional_access_log_count}" -eq "${server_count}" ]] || {
  printf 'Every proxy virtual server must suppress credential-bearing SCORM access logs.\n' >&2
  exit 1
}
referrer_policy_header_count="$(grep -Fc 'add_header Referrer-Policy $doubtfire_referrer_policy always;' "${proxy_template}")"
[[ "${referrer_policy_header_count}" -eq 2 ]] || {
  printf 'The public HTTP redirect and HTTPS application servers must apply the mapped referrer policy.\n' >&2
  exit 1
}
if grep -Eiq 'location[^\{]*scorm' "${proxy_template}"; then
  printf 'SCORM mitigation must not duplicate or bypass the common API proxy location.\n' >&2
  exit 1
fi
grep -Fq 'location ~ ^/api(?:/|$)' "${proxy_template}"
printf 'ok - proxy suppresses SCORM credential paths without changing API routing\n'

grep -Fq 'helper_exec_path' "${PRODUCTION_DIR}/docker-socket-proxy.cfg"
grep -Fq '__PROJECT_NAME__-texlive-' "${PRODUCTION_DIR}/docker-socket-proxy.cfg"
grep -Fq 'http-request deny deny_status 403' "${PRODUCTION_DIR}/docker-socket-proxy.cfg"
printf 'ok - Docker API policy is default-deny and helper-scoped\n'

grep -Fq -- '--wait-timeout' "${PRODUCTION_DIR}/deploy.sh"
printf 'ok - deployment wait is bounded\n'

grep -Fq 'Stage and health-check web first' "${PRODUCTION_DIR}/deploy.sh"
grep -Fq -- '--no-deps' "${PRODUCTION_DIR}/deploy.sh"
grep -Fq 'Entering bounded migration maintenance window' "${PRODUCTION_DIR}/deploy.sh"
grep -Fq 'maintenance_services=(proxy apiserver sidekiq pdfgen migrate)' "${PRODUCTION_DIR}/deploy.sh"
grep -Fq 'stop --timeout 60 "${maintenance_services[@]}"' "${PRODUCTION_DIR}/deploy.sh"
grep -Fq '10#${WAIT_TIMEOUT} <= 86400' "${PRODUCTION_DIR}/deploy.sh"
if "${PRODUCTION_DIR}/deploy.sh" one two three >/dev/null 2>&1; then
  printf 'deploy.sh accepted extra arguments.\n' >&2
  exit 1
fi
if "${PRODUCTION_DIR}/deploy.sh" /does/not/exist 86401 >/dev/null 2>&1; then
  printf 'deploy.sh accepted an excessive wait timeout.\n' >&2
  exit 1
fi
printf 'ok - forward rollout stages callback-compatible web before API\n'

publish_script="${PRODUCTION_DIR}/publish-release.sh"
[[ -x "${publish_script}" ]] || {
  printf 'Production release publisher must be executable.\n' >&2
  exit 1
}
bash -n "${publish_script}"
grep -Fq -- '--sbom=true' "${publish_script}"
grep -Fq -- '--provenance=mode=max' "${publish_script}"
grep -Fq 'org.opencontainers.image.revision=${source_revision}' "${publish_script}"
grep -Fq 'org.opencontainers.image.version=${RELEASE_VERSION}' "${publish_script}"
grep -Fq '"containerimage\.digest"' "${publish_script}"
grep -Fq '"${REGISTRY_NAMESPACE}/${image_name}@${digest}"' "${publish_script}"
grep -Fq 'submodule foreach --quiet --recursive' "${publish_script}"
grep -Fq 'git -C "${component_path}" archive --format=tar HEAD' "${publish_script}"
grep -Fq 'git archive --format=tar --output="${archive}" HEAD' "${publish_script}"
grep -Fq '"${API_CONTEXT}/deployApi.Dockerfile" "${API_CONTEXT}"' "${publish_script}"
grep -Fq 'PUBLISHED_MANIFEST_LINES+=(' "${publish_script}"
grep -Fq 'printf '\''%s\n'\'' "${PUBLISHED_MANIFEST_LINES[@]}"' "${publish_script}"
if grep -Fq 'imagetools inspect "${image_tag}"' "${publish_script}"; then
  printf 'Release publisher must resolve the digest from its Buildx metadata, not a mutable tag.\n' >&2
  exit 1
fi
grep -Fq 'deployApi.Dockerfile' "${publish_script}"
grep -Fq 'deployAppSvr.Dockerfile' "${publish_script}"
for unsafe_release_version in latest 11.0.x RELEASE_OWNER_APPROVED_VERSION; do
  if PUBLISH_RELEASE_CONFIRM=1 "${publish_script}" \
    registry.example.edu/ontrack "${unsafe_release_version}" linux/amd64 \
    >/dev/null 2>&1; then
    printf 'Release publisher accepted unsafe version: %s\n' "${unsafe_release_version}" >&2
    exit 1
  fi
done
printf 'ok - release publication is revision-locked and emits attested image digests\n'

verify_script="${PRODUCTION_DIR}/verify.sh"
[[ -x "${verify_script}" ]] || {
  printf 'verify.sh must be executable.\n' >&2
  exit 1
}
for required_source in \
  '/healthz' \
  '/healthz/web' \
  '/index.html' \
  '/ngsw.json' \
  '/ngsw-worker.js' \
  'http://127.0.0.1:3000/readiness' \
  'db:abort_if_pending_migrations' \
  '20260824000003' \
  'ActiveRecord::Base.connection_pool.migration_context.current_version' \
  'Sidekiq::ProcessSet' \
  'aggregate_peer_progress' \
  'poll_communication_set_schedules' \
  'send_new_task_available_notifications' \
  'send_due_soon_reminders' \
  'DF_SIDEKIQ_CONCURRENCY' \
  'process["concurrency"].to_i == configured_concurrency' \
  'DF_PPI_MINIMUM_COHORT_SIZE' \
  'PeerProgressApi::MINIMUM_SAFE_COHORT_SIZE' \
  'DOUBTFIRE_VAPID_PRIVATE_KEY' \
  'MANUAL GATES STILL REQUIRED'; do
  grep -Fq "${required_source}" "${verify_script}" || {
    printf 'verify.sh is missing required check: %s\n' "${required_source}" >&2
    exit 1
  }
done
grep -Fq 'expected final Rails schema version is `20260824000003`' \
  "${REPOSITORY_DIR}/MIGRATING.md"
grep -Fq '| `20260824000003` |' "${REPOSITORY_DIR}/MIGRATING.md"
grep -Fq 'peer_progress_snapshots.submitted_count' "${REPOSITORY_DIR}/MIGRATING.md"
grep -Fq 'new API deliberately withholds compact and detailed output until reaggregation' \
  "${REPOSITORY_DIR}/MIGRATING.md"
printf 'ok - migration dossier matches the release schema gate\n'
grep -Fq 'DOUBTFIRE_CONFIG_ONLY=0 "${SCRIPT_DIR}/validate.sh" "${ENV_FILE}"' "${verify_script}"
if grep -Eq 'printenv|docker (container )?inspect.*Env' "${verify_script}"; then
  printf 'verify.sh must not print container environments.\n' >&2
  exit 1
fi
printf 'ok - post-deploy verification source contract\n'

if output="$(${verify_script} one two three 2>&1)"; then
  printf 'Expected verify.sh to reject extra arguments.\n' >&2
  exit 1
fi
printf '%s' "${output}" | grep -Fq 'Usage:'
if output="$(${verify_script} "${BASE_ENV}" 0 2>&1)"; then
  printf 'Expected verify.sh to reject a zero timeout.\n' >&2
  exit 1
fi
printf '%s' "${output}" | grep -Fq 'between 1 and 300 seconds'
if output="$(${verify_script} "${BASE_ENV}" 301 2>&1)"; then
  printf 'Expected verify.sh to reject an excessive timeout.\n' >&2
  exit 1
fi
printf '%s' "${output}" | grep -Fq 'between 1 and 300 seconds'
if output="$(${verify_script} "${FIXTURE_DIR}/missing.env" 5 2>&1)"; then
  printf 'Expected verify.sh to reject a missing environment file.\n' >&2
  exit 1
fi
printf '%s' "${output}" | grep -Fq 'environment file not found'
printf 'ok - post-deploy verification rejects invalid invocation\n'

verify_fixture="${FIXTURE_DIR}/verify-runtime"
mkdir -p "${verify_fixture}/bin"
cp "${verify_script}" "${verify_fixture}/verify.sh"
cat > "${verify_fixture}/validate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${verify_fixture}/compose.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *Sidekiq::ProcessSet*)
    case "${VERIFY_STUB_FAIL_AT:-}" in
      cron|concurrency) exit 1 ;;
    esac
    ;;
esac
exit 0
EOF
cat > "${verify_fixture}/bin/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == --* ]]; do
  shift
done
shift
exec "$@"
EOF
cat > "${verify_fixture}/bin/curl" <<'EOF'
#!/usr/bin/env bash
output_file=/dev/null
url=
while (( $# > 0 )); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    --write-out|--noproxy|--proto|--connect-timeout|--max-time|--max-filesize)
      shift 2
      ;;
    --disable|--silent|--show-error|--tlsv1.2)
      shift
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ "${VERIFY_STUB_FAIL_AT:-}" == public-health && "${url}" == */healthz ]]; then
  printf '503'
  exit 0
fi
case "${url}" in
  */index.html)
    content='<!doctype html><html></html>'
    content_type='text/html'
    ;;
  */ngsw.json)
    content='{"configVersion":1,"assetGroups":[]}'
    content_type='application/json'
    ;;
  */ngsw-worker.js)
    if [[ "${VERIFY_STUB_FAIL_AT:-}" == pwa-worker ]]; then
      content='<!doctype html><html></html>'
    else
      content='const cacheName = "ngsw:test";'
    fi
    content_type='application/javascript'
    ;;
  *)
    content='ok'
    content_type='text/plain'
    ;;
esac
if [[ "${output_file}" != /dev/null ]]; then
  printf '%s' "${content}" > "${output_file}"
fi
printf '200\n%s' "${content_type}"
EOF
cat > "${verify_fixture}/runtime.env" <<EOF
SERVER_NAME=${HOSTNAME_UNDER_TEST}
EOF
chmod 700 \
  "${verify_fixture}/verify.sh" \
  "${verify_fixture}/validate.sh" \
  "${verify_fixture}/compose.sh" \
  "${verify_fixture}/bin/timeout" \
  "${verify_fixture}/bin/curl"
chmod 600 "${verify_fixture}/runtime.env"

PATH="${verify_fixture}/bin:${PATH}" \
  "${verify_fixture}/verify.sh" "${verify_fixture}/runtime.env" 5 \
  > "${verify_fixture}/success.out"
grep -Fq 'Automated production verification passed.' "${verify_fixture}/success.out"
grep -Fq 'MANUAL GATES STILL REQUIRED' "${verify_fixture}/success.out"

if VERIFY_STUB_FAIL_AT=cron PATH="${verify_fixture}/bin:${PATH}" \
  "${verify_fixture}/verify.sh" "${verify_fixture}/runtime.env" 5 \
  > "${verify_fixture}/cron-failure.out" 2>&1; then
  printf 'Expected verify.sh to fail when required Sidekiq cron jobs are absent.\n' >&2
  exit 1
fi
grep -Fq 'Sidekiq process, concurrency, and required cron schedule failed' "${verify_fixture}/cron-failure.out"

if VERIFY_STUB_FAIL_AT=concurrency PATH="${verify_fixture}/bin:${PATH}" \
  "${verify_fixture}/verify.sh" "${verify_fixture}/runtime.env" 5 \
  > "${verify_fixture}/concurrency-failure.out" 2>&1; then
  printf 'Expected verify.sh to fail when live Sidekiq concurrency differs from configuration.\n' >&2
  exit 1
fi
grep -Fq 'Sidekiq process, concurrency, and required cron schedule failed' "${verify_fixture}/concurrency-failure.out"

if VERIFY_STUB_FAIL_AT=pwa-worker PATH="${verify_fixture}/bin:${PATH}" \
  "${verify_fixture}/verify.sh" "${verify_fixture}/runtime.env" 5 \
  > "${verify_fixture}/pwa-failure.out" 2>&1; then
  printf 'Expected verify.sh to fail when the PWA worker resolves to HTML.\n' >&2
  exit 1
fi
grep -Fq 'ngsw-worker.js resolved to HTML' "${verify_fixture}/pwa-failure.out"
printf 'ok - post-deploy verification fails closed on runtime regressions\n'

expect_failure placeholder-secret DF_SECRET_KEY_BASE REPLACE_ME "placeholder value"
expect_failure unlimited-upload CLIENT_MAX_BODY_SIZE 0 "must look like"
expect_failure undersized-upload CLIENT_MAX_BODY_SIZE 31m "at least 32m"
expect_failure undersized-upload-uppercase CLIENT_MAX_BODY_SIZE 1M "at least 32m"

minimum_upload_env="${FIXTURE_DIR}/minimum-upload.env"
sed 's/^CLIENT_MAX_BODY_SIZE=.*/CLIENT_MAX_BODY_SIZE=32m/' "${BASE_ENV}" > "${minimum_upload_env}"
"${PRODUCTION_DIR}/validate.sh" "${minimum_upload_env}" >/dev/null
printf 'ok - minimum upload limit allows multipart overhead\n'
expect_failure inline-comment-padding DF_SECRET_KEY_BASE 'x # padding-padding-padding-padding' "inline comments are not allowed"
expect_failure compose-interpolation DF_SMTP_PASSWORD 'unsafe$value' "contains a dollar sign"
expect_failure mutable-image DOUBTFIRE_WEB_IMAGE lmsdoubtfire/doubtfire-web:latest "immutable sha256 image digest"
expect_failure development-auth DF_AUTH_METHOD database "development-only"
expect_failure invalid-processor-memory TEXLIVE_MEMORY_LIMIT unlimited "positive whole number"
expect_failure unsupported-overseer OVERSEER_ENABLED 1 "must remain disabled"
expect_failure missing-sidekiq-concurrency DF_SIDEKIQ_CONCURRENCY '' "must be set"
expect_failure low-sidekiq-concurrency DF_SIDEKIQ_CONCURRENCY 1 "integer from 2 to 5"
expect_failure excessive-sidekiq-concurrency DF_SIDEKIQ_CONCURRENCY 6 "integer from 2 to 5"
expect_failure invalid-sidekiq-concurrency DF_SIDEKIQ_CONCURRENCY 2.5 "integer from 2 to 5"
expect_failure missing-ppi-cohort DF_PPI_MINIMUM_COHORT_SIZE '' "must be set"
expect_failure unsafe-ppi-cohort DF_PPI_MINIMUM_COHORT_SIZE 20 "privacy floor of 21"
expect_failure invalid-ppi-cohort DF_PPI_MINIMUM_COHORT_SIZE 21.5 "positive integer"
expect_failure missing-ppi-staleness DF_PPI_STALE_AFTER_HOURS '' "must be set"
expect_failure zero-ppi-staleness DF_PPI_STALE_AFTER_HOURS 0 "positive integer"
expect_failure excessive-ppi-staleness DF_PPI_STALE_AFTER_HOURS 49 "approved maximum of 48 hours"
expect_failure missing-vapid-public DOUBTFIRE_VAPID_PUBLIC_KEY '' "must be set"
expect_failure placeholder-vapid-public DOUBTFIRE_VAPID_PUBLIC_KEY REPLACE_ME_WITH_VAPID_PUBLIC_KEY "placeholder value"
expect_failure malformed-vapid-public DOUBTFIRE_VAPID_PUBLIC_KEY not-a-vapid-key "base64url P-256 public key"
expect_failure missing-vapid-private DOUBTFIRE_VAPID_PRIVATE_KEY '' "must be set"
expect_failure malformed-vapid-private DOUBTFIRE_VAPID_PRIVATE_KEY not-a-vapid-key "base64url P-256 private key"
expect_failure missing-vapid-subject DOUBTFIRE_VAPID_SUBJECT '' "must be set"
expect_failure invalid-vapid-subject DOUBTFIRE_VAPID_SUBJECT ftp://push.test.edu.au "must use mailto: or https://"
expect_failure non-production-vapid-subject DOUBTFIRE_VAPID_SUBJECT mailto:noreply@ontrack-demo.invalid "operational production contact"
expect_failure placeholder-vapid-subject DOUBTFIRE_VAPID_SUBJECT mailto:push@REPLACE_ME.edu.au "placeholder value"
expect_failure development-vapid-public DOUBTFIRE_VAPID_PUBLIC_KEY BOs-KbIoHK7gUIX3i2_uEuDoouj-GKxB-mY9CRmLNmd4Wn-SSl254E1g6jR1ukL3e37p8uCpaMjOvfAB0BwzvSI= "checked-in development key"
expect_failure development-vapid-private DOUBTFIRE_VAPID_PRIVATE_KEY _NFIWSUTdCdLJJFh87pf4ekQLmNYqsweZ4288NpVZaY= "checked-in development key"

insecure_env="${FIXTURE_DIR}/insecure-mode.env"
cp "${BASE_ENV}" "${insecure_env}"
chmod 644 "${insecure_env}"
if output="$("${PRODUCTION_DIR}/validate.sh" "${insecure_env}" 2>&1)"; then
  printf 'Expected insecure environment mode to fail.\n' >&2
  exit 1
fi
printf '%s' "${output}" | grep -Fq 'must not be accessible by group or other users'
printf 'ok - insecure environment permissions\n'

expect_failure non-local-daemon DOCKER_SOCKET_PATH "${FIXTURE_DIR}/docker.sock" "must be /var/run/docker.sock"

if [[ ! -S /var/run/docker.sock || ! -r /var/run/docker.sock || ! -w /var/run/docker.sock ]]; then
  if output="$(DOUBTFIRE_CONFIG_ONLY=0 "${PRODUCTION_DIR}/validate.sh" "${BASE_ENV}" 2>&1)"; then
    printf 'Expected an inaccessible Docker socket to fail.\n' >&2
    exit 1
  fi
  printf '%s' "${output}" | grep -Fq 'not an accessible Unix socket'
  printf 'ok - Docker socket preflight is fail-closed\n'
else
  printf 'ok - live Docker socket is accessible\n'
fi

mismatch_key="${FIXTURE_DIR}/mismatch.key"
openssl genpkey -algorithm RSA -out "${mismatch_key}" >/dev/null 2>&1
chmod 600 "${mismatch_key}"
expect_failure mismatched-tls TLS_PRIVATE_KEY_PATH "${mismatch_key}" "do not match"

printf 'All production validation tests passed.\n'
