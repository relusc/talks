#!/usr/bin/env bash

set -euo pipefail

DEPLOYMENT="${1:-}"
REPLICAS="${2:-20}"
ITERATIONS="${3:-5}"

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-60}"
WARMUP="${WARMUP:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-0.05}"

if [[ -z "${DEPLOYMENT}" ]]; then
  echo "Usage:"
  echo "  $0 <deployment> [replicas] [iterations]"
  echo
  echo "Examples:"
  echo "  $0 telemetry-container 20 5"
  echo "  $0 telemetry-wasm 20 5"
  echo
  echo "Environment variables:"
  echo "  NAMESPACE=default"
  echo "  TIMEOUT=60"
  echo "  WARMUP=1"
  echo "  POLL_INTERVAL=0.05"
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "Error: kubectl is required."
  exit 1
}

command -v awk >/dev/null 2>&1 || {
  echo "Error: awk is required."
  exit 1
}

command -v sort >/dev/null 2>&1 || {
  echo "Error: sort is required."
  exit 1
}

command -v sed >/dev/null 2>&1 || {
  echo "Error: sed is required."
  exit 1
}

if [[ ! -x /usr/bin/time ]]; then
  echo "Error: /usr/bin/time is required."
  exit 1
fi

# Verify that the deployment exists.
kubectl get deployment \
  "${DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  >/dev/null

#
# Derive the Pod selector directly from the Deployment.
#
# Using go-template instead of JSONPath because kubectl's JSONPath
# implementation does not support Go-style map iteration.
#
SELECTOR="$(
  kubectl get deployment "${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' \
  | sed 's/,$//'
)"

if [[ -z "${SELECTOR}" ]]; then
  echo "Error: Could not determine matchLabels selector for deployment '${DEPLOYMENT}'." >&2
  exit 1
fi

RESULT_FILE="$(mktemp)"
SORTED_FILE="$(mktemp)"
TIME_FILE="$(mktemp)"

cleanup_files() {
  rm -f \
    "${RESULT_FILE}" \
    "${SORTED_FILE}" \
    "${TIME_FILE}"
}

trap cleanup_files EXIT

pod_count() {
  kubectl get pods \
    -n "${NAMESPACE}" \
    -l "${SELECTOR}" \
    -o name \
    2>/dev/null \
    | wc -l \
    | tr -d ' '
}

running_pod_count() {
  kubectl get pods \
    -n "${NAMESPACE}" \
    -l "${SELECTOR}" \
    --field-selector=status.phase=Running \
    -o name \
    2>/dev/null \
    | wc -l \
    | tr -d ' '
}

scale_to_zero() {
  kubectl scale deployment \
    "${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    --replicas=0 \
    >/dev/null

  local deadline
  deadline=$(( $(date +%s) + TIMEOUT ))

  while true; do
    local count
    count="$(pod_count)"

    if [[ "${count}" -eq 0 ]]; then
      return 0
    fi

    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "Error: Pods did not terminate within ${TIMEOUT}s." >&2

      kubectl get pods \
        -n "${NAMESPACE}" \
        -l "${SELECTOR}" \
        -o wide \
        >&2

      return 1
    fi

    sleep "${POLL_INTERVAL}"
  done
}

run_burst() {
  local replicas="$1"
  local elapsed_seconds
  local duration_ms

  : > "${TIME_FILE}"

  if ! /usr/bin/time -p bash -c '
      deployment="$1"
      selector="$2"
      replicas="$3"
      timeout="$4"
      namespace="$5"
      poll_interval="$6"

      kubectl scale deployment \
        "${deployment}" \
        -n "${namespace}" \
        --replicas="${replicas}" \
        >/dev/null

      deadline=$(( $(date +%s) + timeout ))

      while true; do
        running="$(
          kubectl get pods \
            -n "${namespace}" \
            -l "${selector}" \
            --field-selector=status.phase=Running \
            -o name \
            2>/dev/null \
            | wc -l \
            | tr -d " "
        )"

        if [[ "${running}" -ge "${replicas}" ]]; then
          exit 0
        fi

        if [[ "$(date +%s)" -ge "${deadline}" ]]; then
          echo "Timed out: ${running}/${replicas} Pods Running" >&2
          exit 1
        fi

        sleep "${poll_interval}"
      done
    ' _ \
      "${DEPLOYMENT}" \
      "${SELECTOR}" \
      "${replicas}" \
      "${TIMEOUT}" \
      "${NAMESPACE}" \
      "${POLL_INTERVAL}" \
      2>"${TIME_FILE}"
  then
    echo "Error: Burst failed." >&2
    cat "${TIME_FILE}" >&2

    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${SELECTOR}" \
      -o wide \
      >&2

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
echo "Pod burst startup observation"
echo "============================="
echo "Deployment:  ${DEPLOYMENT}"
echo "Selector:    ${SELECTOR}"
echo "Namespace:   ${NAMESPACE}"
echo "Burst size:  ${REPLICAS}"
echo "Iterations:  ${ITERATIONS}"
echo "Measurement: scale 0 -> ${REPLICAS}, until ${REPLICAS} Pods are Running"
echo "Warm-up:     ${WARMUP}"
echo

echo "Ensuring deployment is scaled to zero..."
scale_to_zero

if [[ "${WARMUP}" == "1" ]]; then
  echo "Warming up artifact/runtime..."

  run_burst 1 >/dev/null
  scale_to_zero

  echo "Warm-up complete."
  echo
fi

echo "Running measurements..."
echo

for ((i = 1; i <= ITERATIONS; i++)); do
  scale_to_zero

  duration="$(run_burst "${REPLICAS}")"

  printf "%2d  %8s ms\n" "${i}" "${duration}"

  echo "${duration}" >> "${RESULT_FILE}"

  scale_to_zero
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
