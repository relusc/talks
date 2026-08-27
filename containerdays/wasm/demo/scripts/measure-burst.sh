#!/usr/bin/env bash

set -euo pipefail

DEPLOYMENT="${1:-}"
REPLICAS="${2:-20}"
ITERATIONS="${3:-20}"

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-120}"
WARMUP="${WARMUP:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-0.05}"
READY_GATE="${READY_GATE:-0}"   # 0 = gate on phase=Running (fast, cheap)
                                 # 1 = gate on condition=Ready (respects readinessProbe, closer to "can serve traffic")

if [[ -z "${DEPLOYMENT}" ]]; then
  echo "Usage:"
  echo "  $0 <deployment> [replicas] [iterations]"
  echo
  echo "Examples:"
  echo "  $0 telemetry-container 20 20"
  echo "  $0 telemetry-wasm 20 20"
  echo
  echo "Environment variables:"
  echo "  NAMESPACE=default"
  echo "  TIMEOUT=120"
  echo "  WARMUP=1        # do one throwaway burst first to warm image/module cache"
  echo "  POLL_INTERVAL=0.05"
  echo "  READY_GATE=0    # 1 = wait for Ready condition instead of Running phase"
  exit 1
fi

for bin in kubectl awk sort sed python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "Error: ${bin} is required."; exit 1; }
done

if [[ ! -x /usr/bin/time ]]; then
  echo "Error: /usr/bin/time is required."
  exit 1
fi

if [[ "${ITERATIONS}" -lt 20 && "${READY_GATE}" == "0" ]]; then
  echo "Note: with ${ITERATIONS} iterations, percentile stats on burst-duration are weak (n=${ITERATIONS})." >&2
  echo "      Per-pod latency stats below use a much larger sample (iterations x replicas) and are more trustworthy." >&2
  echo >&2
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

RESULT_FILE="$(mktemp)"          # burst-completion wall time per iteration (old metric, kept for comparison)
SORTED_FILE="$(mktemp)"
TIME_FILE="$(mktemp)"
POD_LATENCY_FILE="$(mktemp)"     # per-pod creationTimestamp -> running.startedAt, aggregated across ALL iterations

cleanup_files() {
  rm -f "${RESULT_FILE}" "${SORTED_FILE}" "${TIME_FILE}" "${POD_LATENCY_FILE}"
}
trap cleanup_files EXIT

pod_count() {
  kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o name 2>/dev/null | wc -l | tr -d ' '
}

running_pod_count() {
  kubectl get pods \
    -n "${NAMESPACE}" -l "${SELECTOR}" \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | wc -l | tr -d ' '
}

ready_pod_count() {
  # No --field-selector for conditions, so pull condition status per pod and count "True".
  kubectl get pods \
    -n "${NAMESPACE}" -l "${SELECTOR}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$' || true
}

scale_to_zero() {
  kubectl scale deployment "${DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0 >/dev/null

  local deadline=$(( $(date +%s) + TIMEOUT ))
  while true; do
    [[ "$(pod_count)" -eq 0 ]] && return 0
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "Error: Pods did not terminate within ${TIMEOUT}s." >&2
      kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o wide >&2
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

# Server-side truth: pull each pod's creationTimestamp and running.startedAt directly
# from the API server. This is independent of our polling loop's granularity/overhead,
# so it isolates scheduling+runtime-start latency instead of measurement-harness noise.
collect_pod_latencies() {
  kubectl get pods \
    -n "${NAMESPACE}" -l "${SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' \
    2>/dev/null \
  | python3 -c '
import sys, datetime

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) != 2:
        continue
    created_s, started_s = parts
    try:
        created = datetime.datetime.fromisoformat(created_s.replace("Z", "+00:00"))
        started = datetime.datetime.fromisoformat(started_s.replace("Z", "+00:00"))
    except ValueError:
        continue
    delta_ms = (started - created).total_seconds() * 1000
    if delta_ms >= 0:
        print(f"{delta_ms:.2f}")
' >> "${POD_LATENCY_FILE}"
}

run_burst() {
  local replicas="$1"
  local elapsed_seconds
  local duration_ms

  : > "${TIME_FILE}"

  if ! /usr/bin/time -p bash -c '
      deployment="$1"; selector="$2"; replicas="$3"
      timeout="$4"; namespace="$5"; poll_interval="$6"; ready_gate="$7"

      kubectl scale deployment "${deployment}" -n "${namespace}" --replicas="${replicas}" >/dev/null

      deadline=$(( $(date +%s) + timeout ))

      while true; do
        if [[ "${ready_gate}" == "1" ]]; then
          count="$(
            kubectl get pods -n "${namespace}" -l "${selector}" \
              -o jsonpath="{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}{end}" \
              2>/dev/null | grep -c "^True$" || true
          )"
        else
          count="$(
            kubectl get pods -n "${namespace}" -l "${selector}" \
              --field-selector=status.phase=Running -o name \
              2>/dev/null | wc -l | tr -d " "
          )"
        fi

        if [[ "${count}" -ge "${replicas}" ]]; then
          exit 0
        fi

        if [[ "$(date +%s)" -ge "${deadline}" ]]; then
          echo "Timed out: ${count}/${replicas} Pods ready" >&2
          exit 1
        fi

        sleep "${poll_interval}"
      done
    ' _ \
      "${DEPLOYMENT}" "${SELECTOR}" "${replicas}" "${TIMEOUT}" "${NAMESPACE}" "${POLL_INTERVAL}" "${READY_GATE}" \
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
echo "Deployment:  ${DEPLOYMENT}"
echo "Selector:    ${SELECTOR}"
echo "Namespace:   ${NAMESPACE}"
echo "Burst size:  ${REPLICAS}"
echo "Iterations:  ${ITERATIONS}"
echo "Gate:        $([[ "${READY_GATE}" == "1" ]] && echo "Ready condition" || echo "Running phase")"
echo "Warm-up:     ${WARMUP}"
echo

echo "Ensuring deployment is scaled to zero..."
scale_to_zero

if [[ "${WARMUP}" == "1" ]]; then
  echo "Warming up artifact/runtime (also pre-pulls image/module onto the node)..."
  run_burst "${REPLICAS}" >/dev/null
  scale_to_zero
  echo "Warm-up complete."
  echo
fi

echo "Running measurements..."
echo

for ((i = 1; i <= ITERATIONS; i++)); do
  scale_to_zero

  duration="$(run_burst "${REPLICAS}")"
  printf "%2d  burst-complete: %8s ms\n" "${i}" "${duration}"
  echo "${duration}" >> "${RESULT_FILE}"

  # Pull authoritative per-pod timestamps before scaling back down.
  collect_pod_latencies

  scale_to_zero
done

echo
echo "======================================================================"
echo "Burst-completion time (harness wall clock, includes poll/kubectl overhead)"
echo "----------------------------------------------------------------------"
print_stats "${RESULT_FILE}" "burst-to-${REPLICAS}-${READY_GATE:+ready}"
echo
echo "Per-pod instantiation latency (API-server timestamps: creationTimestamp -> running.startedAt)"
echo "----------------------------------------------------------------------"
print_stats "${POD_LATENCY_FILE}" "per-pod creation->running"
echo "======================================================================"
