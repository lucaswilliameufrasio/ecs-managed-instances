#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RAW_DIR="$ROOT_DIR/results/local/$RUN_ID"
REPORT_DIR="$ROOT_DIR/benchmarks/local"
REPORT_MD="$REPORT_DIR/$RUN_ID.md"
APP_BINARY="$RAW_DIR/parking-api"
PORT="${LOCAL_PERF_PORT:-}"
PPROF_PORT="${LOCAL_PERF_PPROF_PORT:-}"
DURATION_SECONDS="${LOCAL_PERF_DURATION_SECONDS:-10}"
REPEATS="${LOCAL_PERF_REPEATS:-3}"
CONCURRENCY_LEVELS="${LOCAL_PERF_CONCURRENCIES:-64 128 256 512 1024 2048 4096}"
GOMAXPROCS_LEVELS="${LOCAL_PERF_GOMAXPROCS:-1 4}"
PROFILE_SECONDS="${LOCAL_PERF_PROFILE_SECONDS:-10}"
LOCAL_PERF_GO_VERSION="${LOCAL_PERF_GO_VERSION:-1.27.1}"
GO_MISE_TARGET="go@$LOCAL_PERF_GO_VERSION"
ENDPOINTS="${LOCAL_PERF_ENDPOINTS:-health spots}"
APP_CPU_REQUEST="${LOCAL_PERF_APP_CPUS:-}"
OHA_CPU_REQUEST="${LOCAL_PERF_OHA_CPUS:-}"
APP_PID=""
STATS_PID=""

mkdir -p "$RAW_DIR" "$REPORT_DIR"
read -r EPHEMERAL_PORT EPHEMERAL_PPROF_PORT < <(python3 -c 'import socket; a=socket.socket(); b=socket.socket(); a.bind(("127.0.0.1", 0)); b.bind(("127.0.0.1", 0)); print(a.getsockname()[1], b.getsockname()[1]); a.close(); b.close()')
PORT="${PORT:-$EPHEMERAL_PORT}"
PPROF_PORT="${PPROF_PORT:-$EPHEMERAL_PPROF_PORT}"

cleanup() {
  if [[ -n "$STATS_PID" ]]; then
    kill "$STATS_PID" 2>/dev/null || true
    wait "$STATS_PID" 2>/dev/null || true
  fi
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -f "$ROOT_DIR/parking-api.test"
}
trap cleanup EXIT

for binary in mise taskset curl python3; do
  command -v "$binary" >/dev/null || { printf 'Missing required tool: %s\n' "$binary" >&2; exit 1; }
done

read -r APP_CPUS OHA_CPUS < <(python3 - "$APP_CPU_REQUEST" "$OHA_CPU_REQUEST" <<'PY'
import os
import sys

allowed = []
with open("/proc/self/status", encoding="utf-8") as status:
    for line in status:
        if line.startswith("Cpus_allowed_list:"):
            for part in line.split(":", 1)[1].strip().split(","):
                if "-" in part:
                    first, last = map(int, part.split("-", 1))
                    allowed.extend(range(first, last + 1))
                else:
                    allowed.append(int(part))
            break
if len(allowed) < 2:
    raise SystemExit("Need at least two allowed CPUs to separate app and load generator.")

def parse_cpu_set(value):
    result = set()
    for part in value.split(","):
        if not part:
            continue
        if "-" in part:
            first, last = map(int, part.split("-", 1))
            result.update(range(first, last + 1))
        else:
            result.add(int(part))
    return result

app_cpus = parse_cpu_set(sys.argv[1]) if sys.argv[1] else {allowed[0]}
if not app_cpus or not app_cpus.issubset(allowed):
    raise SystemExit(f"App CPUs must be a non-empty subset of the allowed CPUs {allowed}.")
available_for_oha = [cpu for cpu in allowed if cpu not in app_cpus]
oha_cpus = parse_cpu_set(sys.argv[2]) if sys.argv[2] else set(available_for_oha[:8])
if not oha_cpus or not oha_cpus.issubset(allowed) or app_cpus.intersection(oha_cpus):
    raise SystemExit("Oha CPUs must be allowed CPUs and must not overlap the app CPUs.")
print(",".join(map(str, sorted(app_cpus))), ",".join(map(str, sorted(oha_cpus))))
PY
)

GO_VERSION="$(mise exec "$GO_MISE_TARGET" -- go version)"
OHA_BIN="$(mise where cargo:oha)/bin/oha"
OHA_VERSION="$("$OHA_BIN" --version)"
[[ "$GO_VERSION" == *"go$LOCAL_PERF_GO_VERSION"* ]] || {
  printf 'Expected Mise Go %s, got: %s\n' "$LOCAL_PERF_GO_VERSION" "$GO_VERSION" >&2
  exit 1
}
[[ "$OHA_VERSION" == "oha 1.16.0" ]] || { printf 'Expected Mise Oha 1.16.0, got: %s\n' "$OHA_VERSION" >&2; exit 1; }

KERNEL_VERSION="$(uname -sr)"
PERF_PARANOID="unknown"
if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
  PERF_PARANOID="$(< /proc/sys/kernel/perf_event_paranoid)"
fi
PERF_VERSION="unavailable"
if command -v perf >/dev/null; then
  PERF_VERSION="$(perf --version)"
fi
BPFTRACE_VERSION="unavailable (not installed)"
if command -v bpftrace >/dev/null; then
  BPFTRACE_VERSION="$(bpftrace --version 2>&1)"
fi

run_oha() {
  taskset -c "$OHA_CPUS" "$OHA_BIN" "$@"
}

start_api() {
  local gomaxprocs="$1"
  local enable_pprof="${2:-0}"
  local -a app_env=("LISTEN_ADDRESS=127.0.0.1:$PORT")
  if [[ "$gomaxprocs" != "auto" ]]; then
    app_env+=("GOMAXPROCS=$gomaxprocs")
  fi
  if [[ "$enable_pprof" == "1" ]]; then
    app_env+=("ENABLE_PPROF=1" "PPROF_ADDRESS=127.0.0.1:$PPROF_PORT")
  fi
  if [[ "$gomaxprocs" == "auto" ]]; then
    taskset -c "$APP_CPUS" env -u GOMAXPROCS "${app_env[@]}" "$APP_BINARY" \
      >"$RAW_DIR/api-gomaxprocs-${gomaxprocs}.log" 2>&1 &
  else
    taskset -c "$APP_CPUS" env "${app_env[@]}" "$APP_BINARY" \
      >"$RAW_DIR/api-gomaxprocs-${gomaxprocs}.log" 2>&1 &
  fi
  APP_PID=$!
}

stop_api() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
  fi
  if [[ -n "$STATS_PID" ]]; then
    wait "$STATS_PID" 2>/dev/null || true
    STATS_PID=""
  fi
}

printf 'Running unprofiled Go handler microbenchmarks...\n'
mise exec "$GO_MISE_TARGET" -- go test ./cmd/parking-api -run '^$' -bench '^BenchmarkHandler$' \
  -benchmem -count=5 -cpu 1,4 >"$RAW_DIR/handler-benchmarks.txt"

for benchmark in health spots park_leave_pair; do
  printf 'Profiling Go handler benchmark: %s\n' "$benchmark"
  mise exec "$GO_MISE_TARGET" -- go test ./cmd/parking-api -run '^$' \
    -bench "^BenchmarkHandler/${benchmark}/parallel$" \
    -benchmem -benchtime=5s -count=1 -cpu=4 \
    -cpuprofile "$RAW_DIR/${benchmark}.cpu.pprof" \
    -memprofile "$RAW_DIR/${benchmark}.heap.pprof" \
    -mutexprofile "$RAW_DIR/${benchmark}.mutex.pprof" -mutexprofilefraction=1 \
    -blockprofile "$RAW_DIR/${benchmark}.block.pprof" -blockprofilerate=1 \
    >"$RAW_DIR/${benchmark}.profile-run.txt"
  mise exec "$GO_MISE_TARGET" -- go tool pprof -top -nodecount=25 "$RAW_DIR/${benchmark}.cpu.pprof" \
    >"$RAW_DIR/${benchmark}.cpu-top.txt"
  mise exec "$GO_MISE_TARGET" -- go tool pprof -top -alloc_space -nodecount=25 "$RAW_DIR/${benchmark}.heap.pprof" \
    >"$RAW_DIR/${benchmark}.heap-top.txt"
done

printf 'Building native release binary with Go %s...\n' "$LOCAL_PERF_GO_VERSION"
mise exec "$GO_MISE_TARGET" -- env CGO_ENABLED=0 GOOS=linux go build -trimpath \
  -ldflags="-s -w" -o "$APP_BINARY" ./cmd/parking-api

for endpoint in $ENDPOINTS; do
  case "$endpoint" in
    health) path="/health" ;;
    spots) path="/spots" ;;
  esac

  for gomaxprocs in $GOMAXPROCS_LEVELS; do
    start_api "$gomaxprocs"

    ready=false
    for attempt in $(seq 1 60); do
      if curl --fail --silent "http://127.0.0.1:${PORT}/health" >/dev/null; then
        ready=true
        break
      fi
      sleep 1
    done
    if [[ "$ready" != true ]]; then
      python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' \
        "$RAW_DIR/api-gomaxprocs-${gomaxprocs}.log" >&2 || true
      printf 'Local API process did not become healthy.\n' >&2
      exit 1
    fi

    python3 "$ROOT_DIR/scripts/sample-process-usage.py" "$APP_PID" \
      >"$RAW_DIR/process-${endpoint}-gomaxprocs-${gomaxprocs}.csv" &
    STATS_PID=$!

    # Warm the listener before recording its throughput curve.
    run_oha --no-tui --http-version 1.1 --worker-threads 8 \
      --wait-ongoing-requests-after-deadline -t 5s -c 64 -z 5s "http://127.0.0.1:${PORT}${path}" \
      >"$RAW_DIR/warmup-${endpoint}-gomaxprocs-${gomaxprocs}.txt"

    for concurrency in $CONCURRENCY_LEVELS; do
      for repeat in $(seq 1 "$REPEATS"); do
        output="$RAW_DIR/${endpoint}-gomaxprocs-${gomaxprocs}-c${concurrency}-r${repeat}.json"
        printf 'Load: endpoint=%s GOMAXPROCS=%s connections=%s repeat=%s/%s\n' \
          "$endpoint" "$gomaxprocs" "$concurrency" "$repeat" "$REPEATS"
        run_oha --no-tui --http-version 1.1 --worker-threads 8 \
          --wait-ongoing-requests-after-deadline --output-format json -t 5s -c "$concurrency" \
          -z "${DURATION_SECONDS}s" "http://127.0.0.1:${PORT}${path}" >"$output"
      done
    done

    # Record process-scoped perf/eBPF profiles under load separately from the main sweep.
    host_pid="$APP_PID"
    bpftrace_pid=""
    perf_pid=""
    oha_perf_pid=""
    if command -v bpftrace >/dev/null; then
      bpftrace -e "profile:hz:49 /pid == $host_pid/ { @[ustack] = count(); }" \
        >"$RAW_DIR/bpftrace-${endpoint}-gomaxprocs-${gomaxprocs}.txt" 2>&1 &
      bpftrace_pid=$!
      sleep 1
    fi
    if command -v perf >/dev/null; then
      perf stat -x, -e task-clock,context-switches,cpu-migrations -p "$host_pid" \
        -- sleep "$PROFILE_SECONDS" >"$RAW_DIR/perf-stat-${endpoint}-gomaxprocs-${gomaxprocs}.stdout" \
        2>"$RAW_DIR/perf-stat-${endpoint}-gomaxprocs-${gomaxprocs}.txt" &
      perf_pid=$!
    fi
    sleep 1
    taskset -c "$OHA_CPUS" "$OHA_BIN" --no-tui --http-version 1.1 --worker-threads 8 \
      --wait-ongoing-requests-after-deadline --output-format json -t 5s -c 1024 -z "${PROFILE_SECONDS}s" \
      "http://127.0.0.1:${PORT}${path}" \
      >"$RAW_DIR/perf-load-${endpoint}-gomaxprocs-${gomaxprocs}.json" &
    oha_pid=$!
    python3 "$ROOT_DIR/scripts/sample-process-usage.py" "$oha_pid" \
      >"$RAW_DIR/oha-process-${endpoint}-gomaxprocs-${gomaxprocs}.csv" &
    oha_stats_pid=$!
    if command -v perf >/dev/null; then
      perf stat -x, -e task-clock,context-switches,cpu-migrations -p "$oha_pid" \
        -- sleep "$PROFILE_SECONDS" >"$RAW_DIR/perf-stat-oha-${endpoint}-gomaxprocs-${gomaxprocs}.stdout" \
        2>"$RAW_DIR/perf-stat-oha-${endpoint}-gomaxprocs-${gomaxprocs}.txt" &
      oha_perf_pid=$!
    fi
    wait "$oha_pid" || true
    wait "$oha_stats_pid" || true
    if [[ -n "${perf_pid:-}" ]]; then wait "$perf_pid" || true; fi
    if [[ -n "${oha_perf_pid:-}" ]]; then wait "$oha_perf_pid" || true; fi
    if [[ -n "$bpftrace_pid" ]]; then
      kill -INT "$bpftrace_pid" 2>/dev/null || true
      wait "$bpftrace_pid" 2>/dev/null || true
    fi

    stop_api
  done
done

# Capture an application-level Go CPU profile under real HTTP load in a separate
# instrumented process so pprof sampling does not affect the throughput sweep.
PROFILE_GOMAXPROCS=4
if [[ "$GOMAXPROCS_LEVELS" == "auto" ]]; then
  PROFILE_GOMAXPROCS=auto
fi
start_api "$PROFILE_GOMAXPROCS" 1
ready=false
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:${PORT}/health" >/dev/null && \
     curl --fail --silent "http://127.0.0.1:${PPROF_PORT}/debug/pprof/" >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' \
    "$RAW_DIR/api-gomaxprocs-${PROFILE_GOMAXPROCS}.log" >&2 || true
  printf 'Profile-enabled local API did not become ready.\n' >&2
  exit 1
fi

run_oha --no-tui --http-version 1.1 --worker-threads 8 \
  --wait-ongoing-requests-after-deadline -t 5s -c 64 -z 5s \
  "http://127.0.0.1:${PORT}/spots" >"$RAW_DIR/http-profile-warmup.txt"
curl --fail --silent --show-error --max-time "$((PROFILE_SECONDS + 20))" \
  "http://127.0.0.1:${PPROF_PORT}/debug/pprof/profile?seconds=${PROFILE_SECONDS}" \
  >"$RAW_DIR/http-spots.cpu.pprof" &
pprof_pid=$!
sleep 1
run_oha --no-tui --http-version 1.1 --worker-threads 8 \
  --wait-ongoing-requests-after-deadline --output-format json -t 5s -c 1024 \
  -z "${PROFILE_SECONDS}s" "http://127.0.0.1:${PORT}/spots" \
  >"$RAW_DIR/http-profile-oha.json"
wait "$pprof_pid"
curl --fail --silent "http://127.0.0.1:${PPROF_PORT}/debug/pprof/heap" \
  >"$RAW_DIR/http-spots.heap.pprof"
curl --fail --silent "http://127.0.0.1:${PPROF_PORT}/debug/pprof/mutex" \
  >"$RAW_DIR/http-spots.mutex.pprof"
curl --fail --silent "http://127.0.0.1:${PPROF_PORT}/debug/pprof/block" \
  >"$RAW_DIR/http-spots.block.pprof"
mise exec "$GO_MISE_TARGET" -- go tool pprof -top -nodecount=30 "$RAW_DIR/http-spots.cpu.pprof" \
  >"$RAW_DIR/http-spots.cpu-top.txt"
mise exec "$GO_MISE_TARGET" -- go tool pprof -top -alloc_space -nodecount=30 "$RAW_DIR/http-spots.heap.pprof" \
  >"$RAW_DIR/http-spots.heap-top.txt"
stop_api

python3 - "$RAW_DIR" "$REPORT_MD" "$RUN_ID" "$GO_VERSION" "$OHA_VERSION" \
  "$KERNEL_VERSION" "$PERF_VERSION" "$PERF_PARANOID" "$BPFTRACE_VERSION" \
  "$APP_CPUS" "$OHA_CPUS" "$DURATION_SECONDS" "$REPEATS" \
  "$CONCURRENCY_LEVELS" "$GOMAXPROCS_LEVELS" <<'PY'
import csv
import glob
import json
import os
import re
import statistics
import sys

(
    raw_dir, report_path, run_id, go_version, oha_version,
    kernel, perf_version, perf_paranoid, bpftrace_version, app_cpus, oha_cpus,
    duration, repeats, concurrency_levels, gomaxprocs_levels,
) = sys.argv[1:]

groups = {}
process_usage = {}
for path in glob.glob(os.path.join(raw_dir, "*.json")):
    name = os.path.basename(path)
    if name.startswith(("warmup-", "perf-load-", "http-profile-")):
        continue
    parts = name.removesuffix(".json").split("-")
    endpoint = parts[0]
    gomaxprocs = parts[2].removeprefix("gomaxprocs-")
    concurrency = int(parts[3].removeprefix("c"))
    with open(path, encoding="utf-8") as result_file:
        result = json.load(result_file)
    summary = result["summary"]
    status_counts = {int(code): int(count) for code, count in result.get("statusCodeDistribution", {}).items()}
    expected_status = 204 if endpoint == "health" else 200
    status_errors = sum(count for status, count in status_counts.items() if status != expected_status)
    transport_errors = sum(int(count) for count in result.get("errorDistribution", {}).values())
    percentiles = result.get("latencyPercentiles", {})
    key = (endpoint, gomaxprocs, concurrency)
    groups.setdefault(key, []).append({
        "rps": float(summary["requestsPerSec"]),
        "p95_ms": float(percentiles.get("p95", 0)) * 1000,
        "p99_ms": float(percentiles.get("p99", 0)) * 1000,
        "errors": status_errors + transport_errors,
    })

usage_files = glob.glob(os.path.join(raw_dir, "process-*.csv"))
usage_files += glob.glob(os.path.join(raw_dir, "oha-process-*.csv"))
for path in usage_files:
    parts = os.path.basename(path).removesuffix(".csv").split("-")
    if parts[0] == "oha":
        process_name, endpoint, gomaxprocs = "Oha", parts[2], parts[4]
    else:
        process_name, endpoint, gomaxprocs = "API", parts[1], parts[3]
    key = (process_name, endpoint, gomaxprocs)
    samples = []
    with open(path, encoding="utf-8") as usage_file:
        for line in usage_file:
            values = line.strip().split(",")
            if len(values) == 2:
                samples.append({"cpu_percent": float(values[0]), "rss_mib": float(values[1])})
    if samples:
        process_usage[key] = samples

bpftrace_errors = []
for path in glob.glob(os.path.join(raw_dir, "bpftrace-*.txt")):
    with open(path, encoding="utf-8", errors="replace") as bpftrace_file:
        bpftrace_errors.extend(
            line.strip() for line in bpftrace_file if line.lstrip().startswith("ERROR:")
        )
bpftrace_status = bpftrace_version
if bpftrace_errors:
    bpftrace_status += "; probe blocked: " + "; ".join(sorted(set(bpftrace_errors)))

effective_gomaxprocs = {}
for path in glob.glob(os.path.join(raw_dir, "api-gomaxprocs-*.log")):
    run_setting = os.path.basename(path).removesuffix(".log").removeprefix("api-gomaxprocs-")
    with open(path, encoding="utf-8", errors="replace") as app_log:
        for line in app_log:
            match = re.search(r"runtime GOMAXPROCS=(\d+)", line)
            if match:
                effective_gomaxprocs[run_setting] = match.group(1)
                break

handler_benchmarks = {}
benchmark_pattern = re.compile(
    r"^(BenchmarkHandler/\S+)\s+\d+\s+([\d.]+) ns/op\s+"
    r"([\d.]+) requests/op\s+([\d.]+) B/op\s+(\d+) allocs/op"
)
with open(os.path.join(raw_dir, "handler-benchmarks.txt"), encoding="utf-8") as bench_file:
    for line in bench_file:
        match = benchmark_pattern.match(line.strip())
        if not match:
            continue
        name = match.group(1).removeprefix("BenchmarkHandler/").split("/")
        gmp = "4" if name[-1].endswith("-4") else "1"
        mode = name[-1].removesuffix("-4")
        key = (name[0], mode, gmp)
        handler_benchmarks.setdefault(key, []).append({
            "ns_per_op": float(match.group(2)),
            "requests_per_op": float(match.group(3)),
            "bytes_per_op": float(match.group(4)),
            "allocs_per_op": int(match.group(5)),
        })

profile_frames = []
duration_pattern = re.compile(r"^[\d.]+(?:ns|us|ms|s)$")
with open(os.path.join(raw_dir, "http-spots.cpu-top.txt"), encoding="utf-8") as profile_file:
    for line in profile_file:
        fields = line.split()
        if len(fields) >= 6 and duration_pattern.match(fields[0]) and fields[1].endswith("%"):
            profile_frames.append((fields[1], " ".join(fields[5:])))
        if len(profile_frames) == 5:
            break

lines = [
    f"# Local performance run — {run_id}",
    "",
    "## Toolchain and host",
    "",
    f"- Go: `{go_version}`",
    f"- Oha: `{oha_version}`",
    f"- Kernel: `{kernel}`",
    f"- perf: `{perf_version}`; `perf_event_paranoid={perf_paranoid}`",
    f"- bpftrace: `{bpftrace_status}`",
    f"- Native app pinned to CPUs `{app_cpus}`; Oha pinned to CPUs `{oha_cpus}`; direct loopback HTTP/1.1, no Docker network or ALB",
    f"- Oha: 8 worker threads; requested GOMAXPROCS levels `{gomaxprocs_levels}`; runtime values `{effective_gomaxprocs}`",
    f"- Sweep: `{concurrency_levels}` connections, {duration}s per sample, {repeats} repeats, after a 5s warm-up",
    "",
    "## HTTP throughput curve",
    "",
    "| Endpoint | GOMAXPROCS | Connections | Median RPS | Median p95 | Median p99 | Errors (total) |",
    "|---|---:|---:|---:|---:|---:|---:|",
]
for (endpoint, gomaxprocs, concurrency), samples in sorted(
    groups.items(),
    key=lambda item: (
        item[0][0], item[0][1] == "auto",
        int(item[0][1]) if item[0][1] != "auto" else 0,
        item[0][2],
    ),
):
    lines.append(
        f"| `/{endpoint}` | {gomaxprocs} | {concurrency} | "
        f"{statistics.median(s['rps'] for s in samples):,.0f} | "
        f"{statistics.median(s['p95_ms'] for s in samples):.3f} ms | "
        f"{statistics.median(s['p99_ms'] for s in samples):.3f} ms | "
        f"{sum(s['errors'] for s in samples)} |"
    )

lines.extend([
    "",
    "## Handler-only microbenchmarks (no network)",
    "",
    "| Handler | Mode | GOMAXPROCS | Median ns/op | Requests/op | B/op | Allocations/op |",
    "|---|---|---:|---:|---:|---:|---:|",
])
for (handler_name, mode, gomaxprocs), samples in sorted(handler_benchmarks.items()):
    lines.append(
        f"| `{handler_name}` | {mode} | {gomaxprocs} | "
        f"{statistics.median(s['ns_per_op'] for s in samples):.1f} | "
        f"{statistics.median(s['requests_per_op'] for s in samples):.1f} | "
        f"{statistics.median(s['bytes_per_op'] for s in samples):.0f} | "
        f"{statistics.median(s['allocs_per_op'] for s in samples):.0f} |"
    )

lines.extend(["", "## `/spots` live CPU profile: top flat frames", ""])
for percent, function in profile_frames:
    lines.append(f"- `{function}` — {percent} flat CPU")

lines.extend([
    "",
    "## Process resource samples",
    "",
    "| Process | Endpoint | GOMAXPROCS | Mean CPU | Peak CPU | Peak RSS |",
    "|---|---|---:|---:|---:|---:|",
])
for (process_name, endpoint, gomaxprocs), samples in sorted(
    process_usage.items(),
    key=lambda item: (
        item[0][0], item[0][1],
        int(item[0][2]) if item[0][2] != "auto" else 0,
        item[0][2] == "auto",
    ),
):
    lines.append(
        f"| {process_name} | `/{endpoint}` | {gomaxprocs} | "
        f"{statistics.mean(s['cpu_percent'] for s in samples):.1f}% | "
        f"{max(s['cpu_percent'] for s in samples):.1f}% | "
        f"{max(s['rss_mib'] for s in samples):.1f} MiB |"
    )

lines.extend([
    "",
    "## Profiles and raw outputs",
    "",
    f"- Raw Oha JSON, process CPU/RSS samples, warm-up and perf output: `{os.path.relpath(raw_dir, os.path.dirname(report_path))}/` (local, ignored by Git).",
    f"- Go handler microbenchmark output: `{os.path.relpath(os.path.join(raw_dir, 'handler-benchmarks.txt'), os.path.dirname(report_path))}`.",
    f"- Go CPU/heap/mutex/block profiles and top reports: `{os.path.relpath(raw_dir, os.path.dirname(report_path))}/` (open a profile with `go tool pprof -http` and select its Flame Graph view).",
    f"- perf output and bpftrace probe status: `{bpftrace_status}`.",
    "- A separate preliminary rootless-Docker sweep is recorded in `20260929T165002Z.md`; those rates include RootlessKit forwarding overhead and are not a Go-service ceiling.",
    "- Local x86_64 throughput is diagnostic; AWS runs use Graviton ARM64, so absolute rates are not directly comparable.",
    "",
])
with open(report_path, "w", encoding="utf-8") as report:
    report.write("\n".join(lines))
PY

printf '\nLocal performance artifacts:\n  %s\n  %s\n' "$RAW_DIR" "$REPORT_MD"
