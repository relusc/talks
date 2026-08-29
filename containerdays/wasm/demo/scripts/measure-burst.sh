#!/usr/bin/env bash

set -euo pipefail

DEPLOYMENT="${1:-}"
REPLICAS="${2:-}"
ITERATIONS="${3:-}"

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-0.05}"
BASELINE_REPLICAS="${BASELINE_REPLICAS:-1}"

if [[ -z "${DEPLOYMENT}" || -z "${REPLICAS}" || -z "${ITERATIONS}" ]]; then
  echo "Usage:"
  echo "  $0 <deployment> <replicas> <iterations>"
  echo
  echo "Examples:"
  echo "  $0 container-webserver 20 20"
  echo
  echo "Environment variables:"
  echo "  NAMESPACE=default"
  echo "  TIMEOUT=120"
  echo "  POLL_INTERVAL=0.05"
  echo "  BASELINE_REPLICAS=1  # replica floor to return to between bursts"
  exit 1
fi

if [[ "${REPLICAS}" -le "${BASELINE_REPLICAS}" ]]; then
  echo "Error: replicas (${REPLICAS}) must be greater than BASELINE_REPLICAS (${BASELINE_REPLICAS})." >&2
  exit 1
fi

kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null

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

RESULT_FILE="$(mktemp)"          # burst-completion wall time per iteration
SORTED_FILE="$(mktemp)"
TIME_FILE="$(mktemp)"

cleanup_files() {
  rm -f "${RESULT_FILE}" "${SORTED_FILE}" "${TIME_FILE}"
}
trap cleanup_files EXIT

pod_count() {
  kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o name 2>/dev/null | wc -l | tr -d ' '
}

scale_to_baseline() {
  kubectl scale deployment "${DEPLOYMENT}" -n "${NAMESPACE}" --replicas="${BASELINE_REPLICAS}" >/dev/null

  local deadline=$(( $(date +%s) + TIMEOUT ))
  while true; do
    [[ "$(pod_count)" -eq "${BASELINE_REPLICAS}" ]] && return 0
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "Error: Pods did not settle at baseline (${BASELINE_REPLICAS}) within ${TIMEOUT}s." >&2
      kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o wide >&2
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
      deployment="$1"; selector="$2"; replicas="$3"
      timeout="$4"; namespace="$5"; poll_interval="$6"

      kubectl scale deployment "${deployment}" -n "${namespace}" --replicas="${replicas}" >/dev/null

      deadline=$(( $(date +%s) + timeout ))

      while true; do
        count="$(
          kubectl get pods -n "${namespace}" -l "${selector}" \
            --field-selector=status.phase=Running -o name \
            2>/dev/null | wc -l | tr -d " "
        )"

        if [[ "${count}" -ge "${replicas}" ]]; then
          exit 0
        fi

        if [[ "$(date +%s)" -ge "${deadline}" ]]; then
          echo "Timed out: ${count}/${replicas} Pods running" >&2
          exit 1
        fi

        sleep "${poll_interval}"
      done
    ' _ \
      "${DEPLOYMENT}" "${SELECTOR}" "${replicas}" "${TIMEOUT}" "${NAMESPACE}" "${POLL_INTERVAL}" \
      2>"${TIME_FILE}"
  then
    echo "Error: Burst failed." >&2
    cat "${TIME_FILE}" >&2
    kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o wide >&2
    return 1
  fi

  elapsed_seconds="$(awk '$1 == "real" { print $2 }' "${TIME_FILE}")"
  if [[ -z "${elapsed_seconds}" ]]; then
    echo "Error: Could not determine elapsed time." >&2
    cat "${TIME_FILE}" >&2
    return 1
  fi

  duration_ms="$(awk -v seconds="${elapsed_seconds}" 'BEGIN { printf "%.2f", seconds * 1000 }')"
  echo "${duration_ms}"
}

print_stats() {
  local file="$1"
  local label="$2"

  sort -n "${file}" > "${SORTED_FILE}"

  awk -v label="${label}" '
  { values[NR] = $1; sum += $1 }
  END {
    count = NR
    if (count == 0) { print "  (no data)"; exit 0 }
    min = values[1]; max = values[count]; mean = sum / count
    if (count % 2 == 1) { median = values[(count + 1) / 2] }
    else { median = (values[count / 2] + values[count / 2 + 1]) / 2 }
    p95_index = int(count * 0.95)
    if (p95_index < count * 0.95) { p95_index++ }
    if (p95_index < 1) { p95_index = 1 }
    p95 = values[p95_index]
    printf "%s (n=%d)\n", label, count
    printf "  min:     %8.2f ms\n", min
    printf "  median:  %8.2f ms\n", median
    printf "  mean:    %8.2f ms\n", mean
    printf "  p95:     %8.2f ms\n", p95
    printf "  max:     %8.2f ms\n", max
  }
  ' "${SORTED_FILE}"
}

echo
echo "Pod burst startup observation"
echo "============================="
echo "Deployment:          ${DEPLOYMENT}"
echo "Selector:            ${SELECTOR}"
echo "Namespace:           ${NAMESPACE}"
echo "Baseline replicas:   ${BASELINE_REPLICAS}"
echo "Burst size:          ${REPLICAS}"
echo "Iterations:          ${ITERATIONS}"
echo "Gate:                Running phase"
echo

echo "Ensuring deployment is scaled to baseline (${BASELINE_REPLICAS})..."
scale_to_baseline

echo "Warming up artifact/runtime (also pre-pulls image/module onto the node)..."
run_burst "${REPLICAS}" >/dev/null
scale_to_baseline
echo "Warm-up complete."
echo

echo "Running measurements..."
echo

for ((i = 1; i <= ITERATIONS; i++)); do
  scale_to_baseline

  duration="$(run_burst "${REPLICAS}")"
  printf "%2d  burst-complete: %8s ms\n" "${i}" "${duration}"
  echo "${duration}" >> "${RESULT_FILE}"

  scale_to_baseline
done

echo
echo "======================================================================"
echo "Burst-completion time (harness wall clock, includes poll/kubectl overhead)"
echo "----------------------------------------------------------------------"
print_stats "${RESULT_FILE}" "burst-${BASELINE_REPLICAS}-to-${REPLICAS}"
echo "======================================================================"
