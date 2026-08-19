#!/usr/bin/env bash

set -euo pipefail

MANIFEST="${1:-}"
ITERATIONS="${2:-10}"

TIMEOUT="${TIMEOUT:-30s}"
WARMUP="${WARMUP:-1}"

if [[ -z "${MANIFEST}" ]]; then
  echo "Usage: $0 <pod-manifest.yaml> [iterations]"
  echo
  echo "Examples:"
  echo "  $0 container.yaml 10"
  echo "  $0 wasm.yaml 10"
  echo
  echo "Environment variables:"
  echo "  WARMUP=1      Perform an unmeasured warm-up run (default: 1)"
  echo "  TIMEOUT=30s   Timeout for each Pod startup"
  exit 1
fi

if [[ ! -f "${MANIFEST}" ]]; then
  echo "Error: Manifest '${MANIFEST}' does not exist."
  exit 1
fi

if [[ ! -x /usr/bin/time ]]; then
  echo "Error: /usr/bin/time is required."
  exit 1
fi


# Resolve the Pod resource name from the manifest.
RESOURCE="$(
  kubectl create \
    --dry-run=client \
    -f "${MANIFEST}" \
    -o name
)"

RESOURCE_COUNT="$(printf '%s\n' "${RESOURCE}" | wc -l | tr -d ' ')"

if [[ "${RESOURCE_COUNT}" != "1" ]]; then
  echo "Error: Manifest must contain exactly one Kubernetes resource."
  exit 1
fi

if [[ "${RESOURCE}" != pod/* ]]; then
  echo "Error: Manifest must contain a Pod."
  echo "Found: ${RESOURCE}"
  exit 1
fi


RESULT_FILE="$(mktemp)"
SORTED_FILE="$(mktemp)"
TIME_FILE="$(mktemp)"


delete_pod() {
  kubectl delete \
    -f "${MANIFEST}" \
    --ignore-not-found \
    --wait=true \
    >/dev/null 2>&1
}


cleanup() {
  delete_pod || true

  rm -f \
    "${RESULT_FILE}" \
    "${SORTED_FILE}" \
    "${TIME_FILE}"
}

trap cleanup EXIT


run_once() {
  local elapsed_seconds
  local duration_ms

  delete_pod

  : > "${TIME_FILE}"

  # Measure:
  #
  #   kubectl create
  #       ↓
  #   Kubernetes reports Pod phase Running
  #
  # /usr/bin/time writes its result to stderr.
  if ! /usr/bin/time -p sh -c '
      kubectl create -f "$1" >/dev/null &&
      kubectl wait \
        --for="jsonpath={.status.phase}=Running" \
        "$2" \
        --timeout="$3" \
        >/dev/null
    ' sh "${MANIFEST}" "${RESOURCE}" "${TIMEOUT}" \
      2>"${TIME_FILE}"
  then
    echo "Error: Pod failed to reach Running state." >&2
    cat "${TIME_FILE}" >&2
    return 1
  fi

  elapsed_seconds="$(
    awk '$1 == "real" { print $2 }' "${TIME_FILE}"
  )"

  if [[ -z "${elapsed_seconds}" ]]; then
    echo "Error: Could not determine elapsed time." >&2
    cat "${TIME_FILE}" >&2
    return 1
  fi

  duration_ms="$(
    awk \
      -v seconds="${elapsed_seconds}" \
      'BEGIN { printf "%.2f", seconds * 1000 }'
  )"

  echo "${duration_ms}"
}


echo
echo "Pod startup observation"
echo "======================="
echo "Manifest:    ${MANIFEST}"
echo "Pod:         ${RESOURCE#pod/}"
echo "Iterations:  ${ITERATIONS}"
echo "Measurement: Pod creation -> Running"
echo "Warm-up:     ${WARMUP}"
echo


if [[ "${WARMUP}" == "1" ]]; then
  echo "Warming up workload..."

  run_once >/dev/null

  delete_pod

  echo "Warm-up complete."
  echo
fi


echo "Running measurements..."
echo

for ((i = 1; i <= ITERATIONS; i++)); do
  duration="$(run_once)"

  printf "%2d  %8s ms\n" "${i}" "${duration}"

  echo "${duration}" >> "${RESULT_FILE}"

  delete_pod
done


echo

sort -n "${RESULT_FILE}" > "${SORTED_FILE}"

awk '
{
  values[NR] = $1
  sum += $1
}

END {
  count = NR

  if (count == 0) {
    exit 1
  }

  min = values[1]
  max = values[count]
  mean = sum / count

  if (count % 2 == 1) {
    median = values[(count + 1) / 2]
  } else {
    median = (values[count / 2] + values[count / 2 + 1]) / 2
  }

  p95_index = int(count * 0.95)

  if (p95_index < count * 0.95) {
    p95_index++
  }

  if (p95_index < 1) {
    p95_index = 1
  }

  p95 = values[p95_index]

  printf "Results\n"
  printf "-------\n"
  printf "min:     %8.2f ms\n", min
  printf "median:  %8.2f ms\n", median
  printf "mean:    %8.2f ms\n", mean
  printf "p95:     %8.2f ms\n", p95
  printf "max:     %8.2f ms\n", max
}
' "${SORTED_FILE}"
