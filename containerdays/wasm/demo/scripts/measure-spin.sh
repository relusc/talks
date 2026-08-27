#!/usr/bin/env bash
#
# Burst-scale measurement script for SpinKube SpinApps.
#
# SpinApps don't support `kubectl scale` (the CRD has no `scale` subresource),
# so we drive `spec.replicas` via `kubectl patch spinapp ... --type=merge`.
# SpinApps also can't be scaled to 0 replicas -- at least one pod must always
# be running -- so "baseline" here means BASELINE_REPLICAS (default: 1), not
# zero, as it was for plain Deployments.
#
# Because of that floor, one pod is already warm/running before each burst
# starts. We record the wall-clock moment we trigger the burst and only count
# pods created at or after that moment towards the per-pod latency stats, so
# the pre-existing baseline pod doesn't pollute the numbers.

set -euo pipefail

SPINAPP="${1:-}"
REPLICAS="${2:-20}"
ITERATIONS="${3:-20}"

NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-120}"
WARMUP="${WARMUP:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-0.05}"
READY_GATE="${READY_GATE:-0}"                 # 0 = gate on phase=Running, 1 = gate on condition=Ready
BASELINE_REPLICAS="${BASELINE_REPLICAS:-1}"   # SpinApps enforce a floor >= 1

if [[ -z "${SPINAPP}" ]]; then
  echo "Usage:"
  echo "  $0 <spinapp> [replicas] [iterations]"
  echo
  echo "Examples:"
  echo "  $0 wasm-webserver 20 20"
  echo
  echo "Environment variables:"
  echo "  NAMESPACE=default"
  echo "  TIMEOUT=120"
  echo "  WARMUP=1             # do one throwaway burst first to warm image/module cache"
  echo "  POLL_INTERVAL=0.05"
  echo "  READY_GATE=1         # 1 = wait for Ready condition, 0 = wait for Running phase"
  echo "  BASELINE_REPLICAS=1  # SpinApps can't scale to 0; this is the floor between bursts"
  exit 1
fi

for bin in kubectl awk sort sed python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "Error: ${bin} is required."; exit 1; }
done

if [[ ! -x /usr/bin/time ]]; then
  echo "Error: /usr/bin/time is required."
  exit 1
fi

if [[ "${REPLICAS}" -le "${BASELINE_REPLICAS}" ]]; then
  echo "Error: replicas (${REPLICAS}) must be greater than BASELINE_REPLICAS (${BASELINE_REPLICAS})." >&2
  exit 1
fi

if [[ "${ITERATIONS}" -lt 20 && "${READY_GATE}" == "0" ]]; then
  echo "Note: with ${ITERATIONS} iterations, percentile stats on burst-duration are weak (n=${ITERATIONS})." >&2
  echo "      Per-pod latency stats below use a much larger sample and are more trustworthy." >&2
  echo >&2
fi

kubectl get spinapp "${SPINAPP}" -n "${NAMESPACE}" >/dev/null

# spin-operator names the Deployment it creates after the SpinApp, so we read
# the pod selector off that Deployment even though we scale via the SpinApp.
SELECTOR="$(
  kubectl get deployment "${SPINAPP}" \
    -n "${NAMESPACE}" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' \
  | sed 's/,$//'
)"

if [[ -z "${SELECTOR}" ]]; then
  echo "Error: Could not determine matchLabels selector from deployment/${SPINAPP}." >&2
  exit 1
fi

RESULT_FILE="$(mktemp)"
SORTED_FILE="$(mktemp)"
TIME_FILE="$(mktemp)"
POD_LATENCY_FILE="$(mktemp)"

cleanup_files() {
  rm -f "${RESULT_FILE}" "${SORTED_FILE}" "${TIME_FILE}" "${POD_LATENCY_FILE}"
}
trap cleanup_files EXIT

patch_replicas() {
  local n="$1"
  kubectl patch spinapp "${SPINAPP}" -n "${NAMESPACE}" \
    --type=merge -p "{\"spec\":{\"replicas\":${n}}}" >/dev/null
}

pod_count() {
  kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o name 2>/dev/null | wc -l | tr -d ' '
}

# Wall-clock (UTC) marker used to separate "already running from baseline"
# pods from pods actually created by this burst.
now_iso() {
  python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat())'
}

scale_to_baseline() {
  patch_replicas "${BASELINE_REPLICAS}"

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

# Pull creationTimestamp -> running.startedAt for pods created at/after $1
# (ISO8601 UTC), so the pre-existing baseline pod doesn't skew the burst
# latency numbers.
collect_pod_latencies() {
  local since="$1"

  kubectl get pods \
    -n "${NAMESPACE}" -l "${SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' \
    2>/dev/null \
  | python3 -c '
import sys, datetime

since = datetime.datetime.fromisoformat(sys.argv[1])

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
    if created < since:
        continue
    delta_ms = (started - created).total_seconds() * 1000
    if delta_ms >= 0:
        print(f"{delta_ms:.2f}")
' "${since}" >> "${POD_LATENCY_FILE}"
}

run_burst() {
  local replicas="$1"
  local patch_json="{\"spec\":{\"replicas\":${replicas}}}"
  local elapsed_seconds
  local duration_ms

  : > "${TIME_FILE}"

  # NOTE: patch_json is passed in as $8 rather than interpolated into the
  # single-quoted inner script -- embedding a second single-quoted JSON
  # string inside the outer 'bash -c ...' would prematurely close the quote.
  if ! /usr/bin/time -p bash -c '
      spinapp="$1"; selector="$2"; replicas="$3"
      timeout="$4"; namespace="$5"; poll_interval="$6"; ready_gate="$7"; patch_json="$8"

      kubectl patch spinapp "${spinapp}" -n "${namespace}" --type=merge -p "${patch_json}" >/dev/null

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
      "${SPINAPP}" "${SELECTOR}" "${replicas}" "${TIMEOUT}" "${NAMESPACE}" "${POLL_INTERVAL}" "${READY_GATE}" "${patch_json}" \
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
echo "SpinApp burst startup observation"
echo "=================================="
echo "SpinApp:            ${SPINAPP}"
echo "Selector:            ${SELECTOR}"
echo "Namespace:           ${NAMESPACE}"
echo "Baseline replicas:   ${BASELINE_REPLICAS}  (SpinApps can't scale to 0)"
echo "Burst size:          ${REPLICAS}"
echo "Iterations:          ${ITERATIONS}"
echo "Gate:                $([[ "${READY_GATE}" == "1" ]] && echo "Ready condition" || echo "Running phase")"
echo "Warm-up:             ${WARMUP}"
echo

echo "Ensuring SpinApp is scaled to baseline (${BASELINE_REPLICAS})..."
scale_to_baseline

if [[ "${WARMUP}" == "1" ]]; then
  echo "Warming up artifact/runtime (also pre-pulls image/module onto the node)..."
  run_burst "${REPLICAS}" >/dev/null
  scale_to_baseline
  echo "Warm-up complete."
  echo
fi

echo "Running measurements..."
echo

for ((i = 1; i <= ITERATIONS; i++)); do
  scale_to_baseline

  burst_start="$(now_iso)"
  duration="$(run_burst "${REPLICAS}")"
  printf "%2d  burst-complete: %8s ms\n" "${i}" "${duration}"
  echo "${duration}" >> "${RESULT_FILE}"

  # Pull authoritative per-pod timestamps before scaling back down, filtering
  # out the pre-existing baseline pod via burst_start.
  collect_pod_latencies "${burst_start}"

  scale_to_baseline
done

echo
echo "======================================================================"
echo "Burst-completion time (harness wall clock, includes poll/kubectl overhead)"
echo "----------------------------------------------------------------------"
print_stats "${RESULT_FILE}" "burst-${BASELINE_REPLICAS}-to-${REPLICAS}"
echo
echo "Per-pod instantiation latency (API-server timestamps: creationTimestamp -> running.startedAt)"
echo "New pods only -- baseline pod(s) excluded"
echo "----------------------------------------------------------------------"
print_stats "${POD_LATENCY_FILE}" "per-pod creation->running"
echo "======================================================================"
