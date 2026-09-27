#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.production"

if [[ "${1:-}" == --env-file ]]; then
  (( $# >= 2 )) || {
    printf 'Usage: %s [--env-file PATH] COMPOSE_ARGUMENTS...\n' "$0" >&2
    exit 2
  }
  ENV_FILE="$2"
  shift 2
fi

(( $# > 0 )) || {
  printf 'Usage: %s [--env-file PATH] COMPOSE_ARGUMENTS...\n' "$0" >&2
  exit 2
}

[[ -f "${ENV_FILE}" ]] || {
  printf 'Production environment file not found: %s\n' "${ENV_FILE}" >&2
  exit 1
}

ENV_FILE="$(cd -- "$(dirname -- "${ENV_FILE}")" && pwd)/$(basename -- "${ENV_FILE}")"
docker_cli_config="${DOCKER_CONFIG:-${HOME}/.docker}"

exec env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  DOCKER_CONFIG="${docker_cli_config}" \
  DOCKER_HOST=unix:///var/run/docker.sock \
  docker compose \
    --env-file "${ENV_FILE}" \
    --file "${SCRIPT_DIR}/docker-compose.yml" \
    "$@"
