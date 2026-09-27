#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage:
  PUBLISH_RELEASE_CONFIRM=1 ./publish-release.sh [--no-cache-web] REGISTRY_NAMESPACE RELEASE_VERSION [PLATFORMS]

Example:
  PUBLISH_RELEASE_CONFIRM=1 ./publish-release.sh \
    registry.example.edu/ontrack "$DF_RELEASE_VERSION" linux/amd64,linux/arm64

The command publishes five multi-platform images and prints immutable digest
references. Authenticate Docker to the approved registry before running it.

For a PWA recovery release from earlier web source, use --no-cache-web and a new
release version. This forces the web image's Angular build to run again, producing
a fresh service-worker manifest. Other images retain normal build caching.
USAGE
}

fail() {
  printf 'Release publication refused: %s\n' "$*" >&2
  exit 1
}

NO_CACHE_WEB=0
POSITIONAL_ARGUMENTS=()
for argument in "$@"; do
  case "${argument}" in
    --no-cache-web)
      [[ "${NO_CACHE_WEB}" == 0 ]] || fail "--no-cache-web may only be specified once"
      NO_CACHE_WEB=1
      ;;
    --*)
      fail "unknown option: ${argument}"
      ;;
    *)
      POSITIONAL_ARGUMENTS+=("${argument}")
      ;;
  esac
done

(( ${#POSITIONAL_ARGUMENTS[@]} >= 2 && ${#POSITIONAL_ARGUMENTS[@]} <= 3 )) || {
  usage
  exit 2
}
set -- "${POSITIONAL_ARGUMENTS[@]}"

REGISTRY_NAMESPACE="$1"
RELEASE_VERSION="$2"
RELEASE_PLATFORMS="${3:-linux/amd64,linux/arm64}"

[[ "${PUBLISH_RELEASE_CONFIRM:-}" == 1 ]] || fail "set PUBLISH_RELEASE_CONFIRM=1 after reviewing RELEASING.md"
[[ "${REGISTRY_NAMESPACE}" =~ ^[a-z0-9][a-z0-9._:/-]*[a-z0-9]$ ]] || fail "registry namespace is malformed or not lowercase"
[[ "${REGISTRY_NAMESPACE}" != *://* && "${REGISTRY_NAMESPACE}" != *@* ]] || fail "registry namespace must not contain a URL scheme or digest"
[[ "${RELEASE_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail "release version is not a valid immutable tag"
[[ "${RELEASE_VERSION}" =~ [0-9] ]] || fail "release version must contain a numeric version or date"
command -v tr >/dev/null 2>&1 || fail "tr is required"
release_version_lower="$(printf '%s' "${RELEASE_VERSION}" | tr '[:upper:]' '[:lower:]')"
case "${release_version_lower}" in
  latest|stable|edge|main|master|develop|development|release|*.x|*replace_me*|*changeme*|*placeholder*|*pending*|*approved_version*|*yyyy*)
    fail "release version is mutable or still contains placeholder text"
    ;;
esac
[[ "${RELEASE_PLATFORMS}" =~ ^linux/(amd64|arm64)(,linux/(amd64|arm64))*$ ]] || fail "platforms must be linux/amd64 and/or linux/arm64"

for command_name in docker git mkdir mktemp sed tar; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required"

cd "${REPOSITORY_DIR}"

git diff --quiet || fail "deploy worktree has unstaged changes"
git diff --cached --quiet || fail "deploy worktree has staged changes"
[[ -z "$(git ls-files --others --exclude-standard)" ]] || fail "deploy worktree has untracked files"

verify_component() {
  local component_path="$1"
  local expected_revision
  local actual_revision

  expected_revision="$(git rev-parse "HEAD:${component_path}")" || fail "cannot read ${component_path} gitlink"
  [[ -d "${component_path}/.git" || -f "${component_path}/.git" ]] || fail "${component_path} submodule is not initialised"
  actual_revision="$(git -C "${component_path}" rev-parse HEAD)" || fail "cannot read ${component_path} revision"
  [[ "${actual_revision}" == "${expected_revision}" ]] || fail "${component_path} does not match its gitlink"
  git -C "${component_path}" diff --quiet || fail "${component_path} has unstaged changes"
  git -C "${component_path}" diff --cached --quiet || fail "${component_path} has staged changes"
  [[ -z "$(git -C "${component_path}" ls-files --others --exclude-standard)" ]] || fail "${component_path} has untracked files"
}

verify_component doubtfire-api
verify_component doubtfire-web

if git -C doubtfire-web submodule status --recursive | grep -Eq '^[+-U]'; then
  fail "doubtfire-web nested submodules are missing or do not match their gitlinks"
fi
if ! git -C doubtfire-web submodule foreach --quiet --recursive '
  git diff --quiet &&
  git diff --cached --quiet &&
  test -z "$(git ls-files --others --exclude-standard)"
'; then
  fail "doubtfire-web nested submodules contain staged, unstaged, or untracked changes"
fi

RELEASE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doubtfire-release.XXXXXX")"
METADATA_DIR="${RELEASE_TEMP_DIR}/metadata"
CONTEXT_DIR="${RELEASE_TEMP_DIR}/contexts"
mkdir -p "${METADATA_DIR}" "${CONTEXT_DIR}"
cleanup() {
  local publication_status=$?
  rm -rf -- "${RELEASE_TEMP_DIR}"
  exit "${publication_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_context() {
  local component_path="$1"
  local destination_path="$2"

  mkdir -p "${destination_path}"
  if ! git -C "${component_path}" archive --format=tar HEAD | \
    tar -xf - -C "${destination_path}"; then
    fail "could not create a clean tracked-file context for ${component_path}"
  fi
}

API_CONTEXT="${CONTEXT_DIR}/doubtfire-api"
WEB_CONTEXT="${CONTEXT_DIR}/doubtfire-web"
PUBLISHED_MANIFEST_LINES=()
prepare_context doubtfire-api "${API_CONTEXT}"
prepare_context doubtfire-web "${WEB_CONTEXT}"

# A superproject archive contains only the nested gitlink directory. Populate
# every nested web submodule from its exact committed tree, never its worktree,
# so ignored/untracked files cannot enter the image build context.
export WEB_CONTEXT
if ! git -C doubtfire-web submodule foreach --quiet --recursive '
  destination="${WEB_CONTEXT}/${displaypath}"
  archive="${destination}.git-archive.tar"
  mkdir -p "${destination}"
  git archive --format=tar --output="${archive}" HEAD &&
  tar -xf "${archive}" -C "${destination}" &&
  rm -f -- "${archive}"
'; then
  fail "could not populate the clean nested web-submodule build context"
fi
export -n WEB_CONTEXT

publish_image() {
  local manifest_key="$1"
  local image_name="$2"
  local dockerfile="$3"
  local context="$4"
  local source_revision="$5"
  local image_tag="${REGISTRY_NAMESPACE}/${image_name}:${RELEASE_VERSION}"
  local metadata_file="${METADATA_DIR}/${manifest_key}.json"
  local digest
  local registry_digest
  local cache_flag=""

  # A new tag or final-image label does not invalidate the cached Angular build
  # stage. Recovery must regenerate ngsw.json, even when the source is unchanged.
  if [[ "${manifest_key}" == DOUBTFIRE_WEB_IMAGE && "${NO_CACHE_WEB}" == 1 ]]; then
    cache_flag=--no-cache
    printf 'Recovery release: bypassing the web image build cache.\n' >&2
  fi

  [[ "${source_revision}" =~ ^[0-9a-f]{40}$ ]] || fail "source revision is invalid for ${image_name}"

  printf 'Publishing %s from %s...\n' "${image_tag}" "${dockerfile}" >&2
  docker buildx build \
    ${cache_flag:+"${cache_flag}"} \
    --file "${dockerfile}" \
    --platform "${RELEASE_PLATFORMS}" \
    --tag "${image_tag}" \
    --label "org.opencontainers.image.revision=${source_revision}" \
    --label "org.opencontainers.image.version=${RELEASE_VERSION}" \
    --sbom=true \
    --provenance=mode=max \
    --push \
    --metadata-file "${metadata_file}" \
    "${context}" >&2

  digest="$(
    sed -nE 's/.*"containerimage\.digest"[[:space:]]*:[[:space:]]*"(sha256:[0-9a-f]{64})".*/\1/p' \
      "${metadata_file}"
  )"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Buildx metadata did not contain exactly one valid digest for ${image_tag}"
  registry_digest="$(
    docker buildx imagetools inspect \
      "${REGISTRY_NAMESPACE}/${image_name}@${digest}" \
      --format '{{.Manifest.Digest}}'
  )"
  [[ "${registry_digest}" == "${digest}" ]] || fail "registry digest verification failed for ${image_tag}"
  PUBLISHED_MANIFEST_LINES+=(
    "${manifest_key}=${REGISTRY_NAMESPACE}/${image_name}@${digest}"
  )
}

DEPLOY_GIT_REVISION="$(git rev-parse HEAD)"
API_GIT_REVISION="$(git rev-parse HEAD:doubtfire-api)"
WEB_GIT_REVISION="$(git rev-parse HEAD:doubtfire-web)"

publish_image DOUBTFIRE_API_IMAGE apiserver "${API_CONTEXT}/deployApi.Dockerfile" "${API_CONTEXT}" "${API_GIT_REVISION}"
publish_image DOUBTFIRE_APP_IMAGE appserver "${API_CONTEXT}/deployAppSvr.Dockerfile" "${API_CONTEXT}" "${API_GIT_REVISION}"
publish_image DOUBTFIRE_WEB_IMAGE doubtfire-web "${WEB_CONTEXT}/deploy.Dockerfile" "${WEB_CONTEXT}" "${WEB_GIT_REVISION}"
publish_image TEXLIVE_IMAGE formatif-latex "${API_CONTEXT}/texlive.Dockerfile" "${API_CONTEXT}" "${API_GIT_REVISION}"
publish_image JPLAG_IMAGE doubtfire-jplag "${API_CONTEXT}/jplag.Dockerfile" "${API_CONTEXT}" "${API_GIT_REVISION}"

# Emit a complete manifest only after all five pushes and digest verifications
# succeed. A failed publication therefore cannot look like a complete release.
printf 'DEPLOY_GIT_REVISION=%s\n' "${DEPLOY_GIT_REVISION}"
printf 'API_GIT_REVISION=%s\n' "${API_GIT_REVISION}"
printf 'WEB_GIT_REVISION=%s\n' "${WEB_GIT_REVISION}"
printf 'RELEASE_VERSION=%s\n' "${RELEASE_VERSION}"
printf 'RELEASE_PLATFORMS=%s\n' "${RELEASE_PLATFORMS}"
printf '%s\n' "${PUBLISHED_MANIFEST_LINES[@]}"

cat >&2 <<'NEXT_STEPS'
Publication completed. Preserve the stdout manifest in the protected change
record, scan every immutable digest, verify BuildKit SBOM/provenance attestations,
sign with the institution-approved identity, and copy only accepted digest
references into .env.production. This script does not publish or choose the
proxy, MariaDB, Redis, or HAProxy images; record their independently reviewed
digests in the same manifest.
NEXT_STEPS
