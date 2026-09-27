#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.production}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

fail() {
  printf 'Production configuration error: %s\n' "$*" >&2
  exit 1
}

for command_name in docker env openssl stat; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

compose_version="$(env -i PATH="${PATH}" docker compose version --short 2>/dev/null)" || fail "Docker Compose v2.33.1 or newer is required"
compose_version="${compose_version#v}"
compose_version="${compose_version%%-*}"
IFS=. read -r compose_major compose_minor compose_patch <<< "${compose_version}"
[[ "${compose_major:-}" =~ ^[0-9]+$ && "${compose_minor:-}" =~ ^[0-9]+$ && "${compose_patch:-}" =~ ^[0-9]+$ ]] || fail "cannot parse Docker Compose version: ${compose_version}"
if (( compose_major < 2 || (compose_major == 2 && compose_minor < 33) || (compose_major == 2 && compose_minor == 33 && compose_patch < 1) )); then
  fail "Docker Compose v2.33.1 or newer is required (found ${compose_version})"
fi

[[ -f "${ENV_FILE}" ]] || fail "environment file not found: ${ENV_FILE}"
ENV_FILE="$(cd -- "$(dirname -- "${ENV_FILE}")" && pwd)/$(basename -- "${ENV_FILE}")"

config_keys=()
config_values=()
line_number=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  line_number=$((line_number + 1))
  line="${line%$'\r'}"
  [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ "${line}" == *=* ]] || fail "${ENV_FILE}:${line_number} is not KEY=VALUE"

  key="${line%%=*}"
  value="${line#*=}"
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "${ENV_FILE}:${line_number} has an invalid key"
  if (( ${#config_keys[@]} > 0 )); then
    for existing_key in "${config_keys[@]}"; do
      [[ "${existing_key}" != "${key}" ]] || fail "${ENV_FILE}:${line_number} repeats ${key}"
    done
  fi

  [[ "${value}" != [[:space:]]* && "${value}" != *[[:space:]] ]] || fail "${ENV_FILE}:${line_number} has leading or trailing whitespace"
  if [[ "${key}" == DF_TEAMS_CHANNEL_MAPPINGS ]]; then
    # This one value is a literal JSON array. Embedded double quotes are JSON,
    # not shell syntax; never source or evaluate the environment file.
    [[ "${value}" != *\'* ]] || fail "DF_TEAMS_CHANNEL_MAPPINGS must be a JSON array without surrounding quotes"
  else
    [[ "${value}" != *\"* && "${value}" != *\'* ]] || fail "${ENV_FILE}:${line_number} contains a quote; use an unquoted literal value"
  fi
  [[ "${value}" != *'#'* ]] || fail "${ENV_FILE}:${line_number} contains #; inline comments are not allowed"
  [[ "${value}" != *'\'* ]] || fail "${ENV_FILE}:${line_number} contains a backslash; escaped values are not allowed"
  [[ "${value}" != *'$'* ]] || fail "${ENV_FILE}:${line_number} contains a dollar sign; use literal generated values without Compose interpolation"

  config_keys+=("${key}")
  config_values+=("${value}")
done < "${ENV_FILE}"

get_value() {
  local wanted_key="$1"
  local index
  VALUE=""
  for ((index = 0; index < ${#config_keys[@]}; index++)); do
    if [[ "${config_keys[${index}]}" == "${wanted_key}" ]]; then
      VALUE="${config_values[${index}]}"
      return 0
    fi
  done
  return 1
}

require_value() {
  local key="$1"
  get_value "${key}" || true
  [[ -n "${VALUE}" ]] || fail "${key} must be set"
}

reject_placeholder() {
  local key="$1"
  local lowered
  require_value "${key}"
  lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
  case "${lowered}" in
    *replace_me*|*replace-me*|*changeme*|*change-me*|*test-secret*|*unifoo*|pwd|password|*your-password*)
      fail "${key} still contains a placeholder value"
      ;;
  esac
}

require_https_url() {
  local key="$1"
  reject_placeholder "${key}"
  [[ "${VALUE}" == https://* ]] || fail "${key} must use https://"
}

file_mode() {
  stat -Lc '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

require_private_file() {
  local path="$1"
  local label="$2"
  local mode
  [[ -f "${path}" && -r "${path}" ]] || fail "${label} is not a readable file: ${path}"
  mode="$(file_mode "${path}")" || fail "cannot inspect permissions for ${label}"
  (( (8#${mode} & 077) == 0 )) || fail "${label} must not be accessible by group or other users (mode ${mode})"
}

mode="$(file_mode "${ENV_FILE}")" || fail "cannot inspect environment file permissions"
(( (8#${mode} & 077) == 0 )) || fail "${ENV_FILE} must not be accessible by group or other users (mode ${mode})"

require_value COMPOSE_PROJECT_NAME
[[ "${VALUE}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "COMPOSE_PROJECT_NAME must use lowercase letters, numbers, underscores, or hyphens"

require_value SERVER_NAME
SERVER_NAME="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
[[ "${SERVER_NAME}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || fail "SERVER_NAME must be a production DNS hostname"
[[ "${SERVER_NAME}" != localhost && "${SERVER_NAME}" != *.local ]] || fail "SERVER_NAME cannot be localhost"

require_value DF_INSTITUTION_HOST
[[ "${VALUE}" == "https://${SERVER_NAME}" ]] || fail "DF_INSTITUTION_HOST must be https://${SERVER_NAME}"

require_value TZ
[[ -f "/usr/share/zoneinfo/${VALUE}" ]] || fail "TZ is not an installed IANA time zone: ${VALUE}"

require_value CLIENT_MAX_BODY_SIZE
[[ "${VALUE}" =~ ^[1-9][0-9]*[mMgG]$ ]] || fail "CLIENT_MAX_BODY_SIZE must look like 100m or 1g"
# Task chat permits files below 30,000,000 bytes. Reserve multipart headroom;
# Rails still enforces its separate per-file and per-context limits.
body_size_number="${VALUE%?}"
body_size_unit="${VALUE: -1}"
if [[ "${body_size_unit}" == [mM] && ${#body_size_number} -le 2 ]]; then
  (( 10#${body_size_number} >= 32 )) || fail "CLIENT_MAX_BODY_SIZE must be at least 32m for chat attachments and multipart overhead"
fi

image_keys=(
  PROXY_IMAGE
  MARIADB_IMAGE
  REDIS_IMAGE
  DOCKER_SOCKET_PROXY_IMAGE
  DOUBTFIRE_API_IMAGE
  DOUBTFIRE_APP_IMAGE
  DOUBTFIRE_WEB_IMAGE
  TEXLIVE_IMAGE
  JPLAG_IMAGE
)
for key in "${image_keys[@]}"; do
  require_value "${key}"
  [[ "${VALUE}" =~ ^[A-Za-z0-9._/:+-]+@sha256:[0-9a-fA-F]{64}$ ]] || fail "${key} must use an immutable sha256 image digest"
done

get_value DOCKER_SOCKET_PROXY_IMAGE
[[ "${VALUE}" =~ (^|/)haproxy:[A-Za-z0-9._-]*alpine@sha256:[0-9a-fA-F]{64}$ ]] || fail "DOCKER_SOCKET_PROXY_IMAGE must pin an HAProxy Alpine image digest"

directory_keys=(
  STUDENT_WORK_PATH
  DOUBTFIRE_LOG_PATH
  MARIADB_DATA_PATH
  REDIS_DATA_PATH
  JPLAG_REPORT_PATH
  JPLAG_ARCHIVE_REPORT_PATH
)
resolved_directories=()
for key in "${directory_keys[@]}"; do
  require_value "${key}"
  [[ "${VALUE}" == /* ]] || fail "${key} must be an absolute path"
  [[ "${VALUE}" != / ]] || fail "${key} cannot use the filesystem root"
  [[ "${VALUE}" != *:* ]] || fail "${key} cannot contain a colon"
  [[ -d "${VALUE}" ]] || fail "${key} directory does not exist: ${VALUE}"
  resolved_directory="$(cd -- "${VALUE}" && pwd -P)"
  for existing_directory in "${resolved_directories[@]-}"; do
    [[ "${existing_directory}" != "${resolved_directory}" ]] || fail "production data paths must use separate directories"
  done
  resolved_directories+=("${resolved_directory}")
done

get_value STUDENT_WORK_PATH
student_work_directory="$(cd -- "${VALUE}" && pwd -P)"
for key in JPLAG_REPORT_PATH JPLAG_ARCHIVE_REPORT_PATH; do
  get_value "${key}"
  resolved_directory="$(cd -- "${VALUE}" && pwd -P)"
  case "${resolved_directory}" in
    "${student_work_directory}"/*) ;;
    *) fail "${key} must be inside STUDENT_WORK_PATH so reports are included in backups" ;;
  esac
done

require_value DOCKER_SOCKET_PATH
[[ "${VALUE}" == /* ]] || fail "DOCKER_SOCKET_PATH must be an absolute path"
[[ "${VALUE}" == /var/run/docker.sock ]] || fail "DOCKER_SOCKET_PATH must be /var/run/docker.sock so deployment targets the validated local daemon"
if [[ "${DOUBTFIRE_CONFIG_ONLY:-0}" != 1 ]]; then
  [[ -S "${VALUE}" && -r "${VALUE}" && -w "${VALUE}" ]] || fail "DOCKER_SOCKET_PATH is not an accessible Unix socket: ${VALUE}"
fi

require_value TLS_CERTIFICATE_PATH
TLS_CERTIFICATE_PATH="${VALUE}"
[[ "${TLS_CERTIFICATE_PATH}" == /* ]] || fail "TLS_CERTIFICATE_PATH must be an absolute path"
[[ -f "${TLS_CERTIFICATE_PATH}" && -r "${TLS_CERTIFICATE_PATH}" ]] || fail "TLS certificate is not readable: ${TLS_CERTIFICATE_PATH}"

require_value TLS_PRIVATE_KEY_PATH
TLS_PRIVATE_KEY_PATH="${VALUE}"
[[ "${TLS_PRIVATE_KEY_PATH}" == /* ]] || fail "TLS_PRIVATE_KEY_PATH must be an absolute path"
require_private_file "${TLS_PRIVATE_KEY_PATH}" "TLS private key"

openssl x509 -in "${TLS_CERTIFICATE_PATH}" -noout >/dev/null 2>&1 || fail "TLS_CERTIFICATE_PATH is not a PEM certificate"
openssl x509 -in "${TLS_CERTIFICATE_PATH}" -noout -checkend 2592000 >/dev/null 2>&1 || fail "TLS certificate is expired or expires within 30 days"
openssl x509 -in "${TLS_CERTIFICATE_PATH}" -noout -checkhost "${SERVER_NAME}" >/dev/null 2>&1 || fail "TLS certificate does not cover ${SERVER_NAME}"

if ! certificate_public_key="$(openssl x509 -in "${TLS_CERTIFICATE_PATH}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"; then
  fail "cannot read the TLS certificate public key"
fi
if ! private_public_key="$(openssl pkey -in "${TLS_PRIVATE_KEY_PATH}" -passin pass: -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"; then
  fail "TLS private key must be a readable, unencrypted PEM key"
fi
[[ -n "${certificate_public_key}" && "${certificate_public_key}" == "${private_public_key}" ]] || fail "TLS certificate and private key do not match"

for key in ALIASES_PATH MSMTPRC_PATH; do
  require_value "${key}"
  [[ "${VALUE}" == /* ]] || fail "${key} must be an absolute path"
  [[ -s "${VALUE}" && -r "${VALUE}" ]] || fail "${key} is not a readable, non-empty file: ${VALUE}"
  if grep -Eiq 'REPLACE_ME|support@email\.address|smtp\.server' "${VALUE}"; then
    fail "${key} still contains placeholder configuration"
  fi
done
require_value MSMTPRC_PATH
require_private_file "${VALUE}" "msmtp configuration"

for key in MARIADB_DATABASE MARIADB_USER; do
  reject_placeholder "${key}"
  [[ "${VALUE}" =~ ^[A-Za-z0-9_]+$ ]] || fail "${key} may contain only letters, numbers, and underscores"
done
get_value MARIADB_USER
lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
[[ "${lowered}" != root ]] || fail "MARIADB_USER cannot be root"
get_value MARIADB_DATABASE
lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
case "${lowered}" in
  information_schema|mysql|performance_schema|sys)
    fail "MARIADB_DATABASE cannot use a MariaDB system database"
    ;;
esac
for key in MARIADB_PASSWORD MARIADB_ROOT_PASSWORD; do
  reject_placeholder "${key}"
  (( ${#VALUE} >= 20 )) || fail "${key} must contain at least 20 characters"
  [[ "${VALUE}" != *'$'* ]] || fail "${key} cannot contain a dollar sign; use a generated hexadecimal value"
done
get_value MARIADB_PASSWORD
database_password="${VALUE}"
get_value MARIADB_ROOT_PASSWORD
[[ "${database_password}" != "${VALUE}" ]] || fail "database user and root passwords must be different"

secret_keys=(
  DF_SECRET_KEY_BASE
  DF_SECRET_KEY_ATTR
  DF_SECRET_KEY_DEVISE
  DF_ENCRYPTION_PRIMARY_KEY
  DF_ENCRYPTION_DETERMINISTIC_KEY
  DF_ENCRYPTION_KEY_DERIVATION_SALT
)
secret_values=()
for key in "${secret_keys[@]}"; do
  reject_placeholder "${key}"
  (( ${#VALUE} >= 32 )) || fail "${key} must contain at least 32 characters"
  [[ "${VALUE}" != *'$'* ]] || fail "${key} cannot contain a dollar sign; use a generated hexadecimal value"
  for existing_secret in "${secret_values[@]-}"; do
    [[ "${existing_secret}" != "${VALUE}" ]] || fail "Rails signing and encryption keys must use independent values"
  done
  secret_values+=("${VALUE}")
done

require_value DF_SIDEKIQ_CONCURRENCY
[[ "${VALUE}" =~ ^[2-5]$ ]] || fail "DF_SIDEKIQ_CONCURRENCY must be an integer from 2 to 5"

require_value DF_PPI_MINIMUM_COHORT_SIZE
[[ "${VALUE}" =~ ^[1-9][0-9]*$ ]] || fail "DF_PPI_MINIMUM_COHORT_SIZE must be a positive integer"
ppi_minimum_cohort_size="${VALUE}"
if (( ${#ppi_minimum_cohort_size} < 2 )) ||
   (( ${#ppi_minimum_cohort_size} == 2 && 10#${ppi_minimum_cohort_size} < 21 )); then
  fail "DF_PPI_MINIMUM_COHORT_SIZE must be at least the privacy floor of 21"
fi

require_value DF_PPI_STALE_AFTER_HOURS
[[ "${VALUE}" =~ ^[1-9][0-9]*$ ]] || fail "DF_PPI_STALE_AFTER_HOURS must be a positive integer"
(( ${#VALUE} <= 2 )) || fail "DF_PPI_STALE_AFTER_HOURS must not exceed the approved maximum of 48 hours"
(( 10#${VALUE} <= 48 )) || fail "DF_PPI_STALE_AFTER_HOURS must not exceed the approved maximum of 48 hours"

legacy_vapid_public_key='BOs-KbIoHK7gUIX3i2_uEuDoouj-GKxB-mY9CRmLNmd4Wn-SSl254E1g6jR1ukL3e37p8uCpaMjOvfAB0BwzvSI='
legacy_vapid_private_key='_NFIWSUTdCdLJJFh87pf4ekQLmNYqsweZ4288NpVZaY='

reject_placeholder DOUBTFIRE_VAPID_PUBLIC_KEY
[[ "${VALUE}" =~ ^B[A-Za-z0-9_-]{86}=?$ ]] || fail "DOUBTFIRE_VAPID_PUBLIC_KEY must be a base64url P-256 public key"
[[ "${VALUE}" != "${legacy_vapid_public_key}" ]] || fail "DOUBTFIRE_VAPID_PUBLIC_KEY must not reuse the checked-in development key"

reject_placeholder DOUBTFIRE_VAPID_PRIVATE_KEY
[[ "${VALUE}" =~ ^[A-Za-z0-9_-]{43}=?$ ]] || fail "DOUBTFIRE_VAPID_PRIVATE_KEY must be a base64url P-256 private key"
[[ "${VALUE}" != "${legacy_vapid_private_key}" ]] || fail "DOUBTFIRE_VAPID_PRIVATE_KEY must not reuse the checked-in development key"

reject_placeholder DOUBTFIRE_VAPID_SUBJECT
vapid_subject="${VALUE}"
case "${vapid_subject}" in
  mailto:*)
    [[ "${vapid_subject}" =~ ^mailto:[^[:space:]@]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || fail "DOUBTFIRE_VAPID_SUBJECT mailto: value must contain an operational email address"
    ;;
  https://*)
    [[ "${vapid_subject}" =~ ^https://[^[:space:]]+$ ]] || fail "DOUBTFIRE_VAPID_SUBJECT HTTPS value is invalid"
    ;;
  *)
    fail "DOUBTFIRE_VAPID_SUBJECT must use mailto: or https://"
    ;;
esac
lowered="$(printf '%s' "${vapid_subject}" | tr '[:upper:]' '[:lower:]')"
case "${lowered}" in
  *localhost*|*.local|*.local/*|*.invalid|*.invalid/*|*.example|*.example/*|*.test|*.test/*)
    fail "DOUBTFIRE_VAPID_SUBJECT must use an operational production contact"
    ;;
esac

for key in DF_INSTITUTION_PRODUCT_NAME DF_INSTITUTION_EMAIL_DOMAIN DF_INSTITUTION_EMAIL_SENDER DF_INSTITUTION_NAME; do
  reject_placeholder "${key}"
done

require_value DF_AUTH_METHOD
auth_method="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
case "${auth_method}" in
  aaf)
    for key in DF_AAF_ISSUER_URL DF_AAF_AUDIENCE_URL DF_AAF_CALLBACK_URL DF_AAF_IDENTITY_PROVIDER_URL DF_AAF_UNIQUE_URL DF_AAF_AUTH_SIGNOUT_URL; do
      require_https_url "${key}"
    done
    reject_placeholder DF_SECRET_KEY_AAF
    (( ${#VALUE} >= 32 )) || fail "DF_SECRET_KEY_AAF must contain at least 32 characters"
    ;;
  saml)
    for key in DF_SAML_METADATA_URL DF_SAML_CONSUMER_SERVICE_URL DF_SAML_SP_ENTITY_ID DF_SAML_IDP_TARGET_URL; do
      require_https_url "${key}"
    done
    reject_placeholder DF_SAML_IDP_SAML_NAME_IDENTIFIER_FORMAT
    ;;
  ldap)
    for key in DF_LDAP_HOST DF_LDAP_PORT DF_LDAP_ATTRIBUTE DF_LDAP_BASE; do
      reject_placeholder "${key}"
    done
    require_value DF_LDAP_SSL
    lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
    [[ "${lowered}" == true ]] || fail "DF_LDAP_SSL must be true in production"
    require_value DF_LDAP_USE_ADMIN_TO_BIND
    lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
    case "${lowered}" in
      true)
        reject_placeholder DF_LDAP_ADMIN_USER
        reject_placeholder DF_LDAP_ADMIN_PWD
        ;;
      false) ;;
      *) fail "DF_LDAP_USE_ADMIN_TO_BIND must be true or false" ;;
    esac
    ;;
  database)
    fail "DF_AUTH_METHOD=database is development-only; configure aaf, saml, or ldap"
    ;;
  *)
    fail "DF_AUTH_METHOD must be aaf, saml, or ldap"
    ;;
esac

require_value DF_MAIL_PERFORM_DELIVERIES
lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
[[ "${lowered}" == yes ]] || fail "DF_MAIL_PERFORM_DELIVERIES must be yes for production notifications"
require_value DF_MAIL_DELIVERY_METHOD
lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
[[ "${lowered}" == smtp ]] || fail "DF_MAIL_DELIVERY_METHOD must be smtp"
for key in DF_SMTP_ADDRESS DF_SMTP_PORT DF_SMTP_DOMAIN; do
  reject_placeholder "${key}"
done
require_value DF_INSTITUTION_EMAIL_SENDER
[[ "${VALUE}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "DF_INSTITUTION_EMAIL_SENDER must be an email address"
get_value DF_SMTP_PORT
smtp_port="${VALUE}"
[[ "${smtp_port}" =~ ^[0-9]+$ ]] && (( smtp_port >= 1 && smtp_port <= 65535 )) || fail "DF_SMTP_PORT must be between 1 and 65535"
get_value DF_SMTP_AUTHENTICATION || true
smtp_auth="${VALUE}"
lowered="$(printf '%s' "${smtp_auth}" | tr '[:upper:]' '[:lower:]')"
if [[ -n "${smtp_auth}" && "${lowered}" != none ]]; then
  reject_placeholder DF_SMTP_USERNAME
  reject_placeholder DF_SMTP_PASSWORD
fi

for key in TEXLIVE_MEMORY_LIMIT JPLAG_MEMORY_LIMIT; do
  require_value "${key}"
  [[ "${VALUE}" =~ ^[1-9][0-9]*[mMgG]$ ]] || fail "${key} must be a positive whole number of megabytes or gigabytes"
done
for key in TEXLIVE_CPU_LIMIT JPLAG_CPU_LIMIT; do
  require_value "${key}"
  [[ "${VALUE}" =~ ^(([1-9][0-9]*)(\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)$ ]] || fail "${key} must be a positive CPU count"
done
for key in TEXLIVE_PIDS_LIMIT JPLAG_PIDS_LIMIT; do
  require_value "${key}"
  [[ "${VALUE}" =~ ^[1-9][0-9]*$ ]] || fail "${key} must be a positive integer"
done

get_value OVERSEER_ENABLED || true
lowered="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
case "${lowered}" in
  ""|0|false|no) ;;
  *) fail "OVERSEER_ENABLED must remain disabled; this stack does not provide its runner contract" ;;
esac

get_value DF_TEAMS_ANNOUNCEMENTS_ENABLED || true
teams_enabled="${VALUE:-false}"
case "${teams_enabled}" in
  true|false) ;;
  *) fail "DF_TEAMS_ANNOUNCEMENTS_ENABLED must be true or false" ;;
esac
get_value DF_TEAMS_CHANNEL_MAPPINGS || true
teams_mappings="${VALUE:-[]}"
if [[ "${teams_enabled}" == true || "${teams_mappings}" != '[]' ]]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for Teams mapping validation"
  if ! printf '%s' "${teams_mappings}" | python3 "${SCRIPT_DIR}/validate-teams-mappings.py" "${teams_enabled}"; then
    fail "Teams channel mappings are invalid"
  fi
fi
if [[ "${teams_enabled}" == true ]]; then
  for key in DF_TEAMS_TENANT_ID DF_TEAMS_CLIENT_ID; do
    reject_placeholder "${key}"
    [[ "${VALUE}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail "${key} must be a Microsoft directory GUID"
  done
  reject_placeholder DF_TEAMS_CLIENT_SECRET
  (( ${#VALUE} <= 4096 )) || fail "DF_TEAMS_CLIENT_SECRET is too long"
fi

[[ -r "${SCRIPT_DIR}/docker-socket-proxy.cfg" ]] || fail "docker-socket-proxy.cfg is missing or unreadable"

if ! env -i PATH="${PATH}" docker compose --env-file "${ENV_FILE}" --file "${COMPOSE_FILE}" config --quiet; then
  fail "Docker Compose rejected the rendered production configuration"
fi

printf 'Production configuration is valid for %s.\n' "${SERVER_NAME}"
