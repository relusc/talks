#!/bin/bash

set -euo pipefail

IMAGE="${1:-}"

REGISTRY="${IMAGE%%/*}"
REMAINDER="${IMAGE#*/}"

if [[ "${REMAINDER}" == *@* ]]; then
  REPOSITORY="${REMAINDER%@*}"
  REFERENCE="${REMAINDER#*@}"
elif [[ "${REMAINDER##*/}" == *:* ]]; then
  REPOSITORY="${REMAINDER%:*}"
  REFERENCE="${REMAINDER##*:}"
else
  REPOSITORY="${REMAINDER}"
  REFERENCE="latest"
fi

ACCEPT_HEADER='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

fetch_manifest() {
  local reference="$1"

  curl \
    --silent \
    --show-error \
    --fail \
    -H "Accept: ${ACCEPT_HEADER}" \
    "http://${REGISTRY}/v2/${REPOSITORY}/manifests/${reference}"
}

MANIFEST="$(fetch_manifest "${REFERENCE}")"

MEDIA_TYPE="$(
  printf '%s' "${MANIFEST}" \
    | jq -r '.mediaType // ""'
)"

#
# Docker Desktop / BuildKit may push an OCI index even for what appears
# to be a single-platform image.
#
# If this is an index, select the first actual platform image and fetch
# its manifest.
#
case "${MEDIA_TYPE}" in
  application/vnd.oci.image.index.v1+json|\
  application/vnd.docker.distribution.manifest.list.v2+json)

    DIGEST="$(
      printf '%s' "${MANIFEST}" |
        jq -r '
          (
            [
              .manifests[]
              | select(
                  (.platform.os // "unknown") != "unknown"
                  and
                  (.platform.architecture // "unknown") != "unknown"
                )
            ][0].digest
          )
          //
          .manifests[0].digest
        '
    )"

    if [[ -z "${DIGEST}" || "${DIGEST}" == "null" ]]; then
      echo "Error: Could not find an image manifest in OCI index." >&2
      exit 1
    fi

    MANIFEST="$(fetch_manifest "${DIGEST}")"

    MEDIA_TYPE="$(
      printf '%s' "${MANIFEST}" \
        | jq -r '.mediaType // ""'
    )"
    ;;
esac

case "${MEDIA_TYPE}" in
  application/vnd.oci.image.manifest.v1+json|\
  application/vnd.docker.distribution.manifest.v2+json|"")
    ;;
  *)
    echo "Error: Unsupported manifest type: ${MEDIA_TYPE}" >&2
    exit 1
    ;;
esac

SIZE_BYTES="$(
  printf '%s' "${MANIFEST}" |
    jq '[.config.size // 0, (.layers[]?.size // 0)] | add'
)"

awk -v bytes="${SIZE_BYTES}" '
BEGIN {
  if (bytes < 1024) {
    printf "%d B\n", bytes
  } else if (bytes < 1024 * 1024) {
    printf "%.2f KiB\n", bytes / 1024
  } else if (bytes < 1024 * 1024 * 1024) {
    printf "%.2f MiB\n", bytes / 1024 / 1024
  } else {
    printf "%.2f GiB\n", bytes / 1024 / 1024 / 1024
  }
}'
