#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'uncommitted')"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/results}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
DESTROY_ON_EXIT="${DESTROY_ON_EXIT:-true}"
APPLIED=false
mkdir -p "$RESULT_DIR"
RESULT_JSON="$RESULT_DIR/$RUN_ID.json"
RESULT_CSV="$RESULT_DIR/$RUN_ID.csv"
LOG_FILE="$RESULT_DIR/$RUN_ID.log"
REPORT_DIR="$ROOT_DIR/benchmarks/runs"
REPORT_MD="$REPORT_DIR/$RUN_ID.md"
GENERATED_KEY=false
KEEP_GENERATED_KEY=false

if [[ -z "${ALLOWED_SSH_CIDR:-}" ]]; then
  SOURCE_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  python3 - "$SOURCE_IP" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
  ALLOWED_SSH_CIDR="$SOURCE_IP/32"
fi

if [[ -z "${KEY_NAME:-}" && -z "${SSH_KEY_PATH:-}" ]]; then
  KEY_NAME="ecs-mi-bench-$RUN_ID"
  SSH_KEY_PATH="$RESULT_DIR/$RUN_ID-key"
  ssh-keygen -q -t ed25519 -N '' -C "$KEY_NAME" -f "$SSH_KEY_PATH"
  chmod 600 "$SSH_KEY_PATH"
  GENERATED_KEY=true
elif [[ -z "${KEY_NAME:-}" || -z "${SSH_KEY_PATH:-}" ]]; then
  printf 'Set both KEY_NAME and SSH_KEY_PATH, or omit both to generate a temporary key pair.\n' >&2
  exit 1
fi

CREATE_KEY_PAIR=false
if [[ "$GENERATED_KEY" == true ]]; then
  CREATE_KEY_PAIR=true
fi
TOFU_VARS=(
  "-var=key_name=$KEY_NAME"
  "-var=create_key_pair=$CREATE_KEY_PAIR"
  "-var=ssh_public_key_path=$SSH_KEY_PATH.pub"
  "-var=allowed_ssh_cidr=$ALLOWED_SSH_CIDR"
  "-var=aws_region=$AWS_REGION"
)

cleanup() {
  local status=$?
  if [[ "$APPLIED" == true && "$DESTROY_ON_EXIT" == true ]]; then
    printf '\nDestroying benchmark infrastructure...\n'
    tofu -chdir="$INFRA_DIR" destroy -auto-approve -input=false "${TOFU_VARS[@]}" >>"$LOG_FILE" 2>&1 || {
      printf 'WARNING: tofu destroy failed; inspect %s and destroy manually.\n' "$LOG_FILE" >&2
      status=1
      KEEP_GENERATED_KEY=true
    }
  fi
  if [[ "$GENERATED_KEY" == true && "$KEEP_GENERATED_KEY" == false && ( "$APPLIED" == false || "$DESTROY_ON_EXIT" == true ) ]]; then
    rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
  fi
  rm -f "$ROOT_DIR/ansible/.inventory.generated.ini"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for binary in tofu ansible-playbook ansible-inventory aws python3; do
  command -v "$binary" >/dev/null || { printf 'Missing required tool: %s\n' "$binary" >&2; exit 1; }
done
[[ -r "$SSH_KEY_PATH" ]] || { printf 'Cannot read SSH key: %s\n' "$SSH_KEY_PATH" >&2; exit 1; }

tofu -chdir="$INFRA_DIR" init -input=false
APPLIED=true
tofu -chdir="$INFRA_DIR" apply -auto-approve -input=false "${TOFU_VARS[@]}" \
  2>&1 | tee -a "$LOG_FILE"

output() { tofu -chdir="$INFRA_DIR" output -raw "$1"; }
RUNNER_IP="$(output runner_public_ip)"
CLUSTER="$(output cluster_name)"
SERVICE="$(output service_name)"
ECR_URL="$(output ecr_repository_url)"
ACCOUNT_ID="$(output aws_account_id)"
DURATION="$(output load_duration_seconds)"
CONNECTIONS="$(output load_connections)"
ECS_INSTANCE_TYPE="$(output ecs_instance_type)"
RUNNER_INSTANCE_TYPE="$(output runner_instance_type)"
RUNNER_VCPUS="$(output runner_vcpus)"
RUNNER_MEMORY_MIB="$(output runner_memory_mib)"
ECS_INSTANCE_VCPUS="$(output ecs_instance_vcpus)"
ECS_INSTANCE_MEMORY_MIB="$(output ecs_instance_memory_mib)"
TASK_CPU_UNITS="$(output task_cpu_units)"
TASK_MEMORY_MIB="$(output task_memory_mib)"
BENCHMARK_AZ="$(output benchmark_az)"
LOAD_THREADS="$(output load_generator_threads)"
IMAGE_REF="$ECR_URL:benchmark"

cat > "$ROOT_DIR/ansible/.inventory.generated.ini" <<EOF
[runner]
benchmark-runner ansible_host=$RUNNER_IP ansible_user=ec2-user ansible_ssh_private_key_file=$SSH_KEY_PATH ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
EOF
chmod 600 "$ROOT_DIR/ansible/.inventory.generated.ini"

printf 'Waiting for SSH on load generator %s...\n' "$RUNNER_IP"
for attempt in $(seq 1 60); do
  if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "ec2-user@$RUNNER_IP" true 2>/dev/null; then break; fi
  [[ "$attempt" -lt 60 ]] || { printf 'SSH did not become available.\n' >&2; exit 1; }
  sleep 10
done

ansible-playbook -i "$ROOT_DIR/ansible/.inventory.generated.ini" "$ROOT_DIR/ansible/benchmark.yml" \
  -e "aws_region=$AWS_REGION" -e "ecs_cluster=$CLUSTER" -e "ecs_service=$SERVICE" -e "ecr_repository_url=$ECR_URL"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "ec2-user@$RUNNER_IP" \
  "python3 - '$CLUSTER' '$SERVICE' '$DURATION' '$CONNECTIONS' '$RUN_ID' '$ACCOUNT_ID' '$AWS_REGION' '$ECS_INSTANCE_TYPE' '$RUNNER_INSTANCE_TYPE' '$TASK_CPU_UNITS' '$TASK_MEMORY_MIB' '$BENCHMARK_AZ' '$LOAD_THREADS' '$IMAGE_REF' '$ECS_INSTANCE_VCPUS' '$ECS_INSTANCE_MEMORY_MIB' '$RUNNER_VCPUS' '$RUNNER_MEMORY_MIB' '$SOURCE_COMMIT'" <<'REMOTE' | tee "$RESULT_JSON"
import ipaddress
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

(
    cluster, service, duration, connections, run_id, account_id, region,
    ecs_instance_type, runner_instance_type, task_cpu_units, task_memory_mib,
    benchmark_az, load_threads, image_ref, ecs_instance_vcpus,
    ecs_instance_memory_mib, runner_vcpus, runner_memory_mib, source_commit,
) = sys.argv[1:]
token_request = urllib.request.Request(
    "http://169.254.169.254/latest/api/token",
    method="PUT",
    headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
)
with urllib.request.urlopen(token_request) as response:
    token = response.read().decode()
metadata_headers = {"X-aws-ec2-metadata-token": token}

def metadata(path):
    request = urllib.request.Request(
        f"http://169.254.169.254/latest/meta-data/{path}", headers=metadata_headers
    )
    with urllib.request.urlopen(request) as response:
        return response.read().decode()

load_generator_instance_type = metadata("instance-type")
load_generator_instance_id = metadata("instance-id")
go_version = subprocess.run(["go", "version"], capture_output=True, text=True, check=True).stdout.strip()
hey_build = subprocess.run(["go", "version", "-m", "/usr/local/bin/hey"], capture_output=True, text=True, check=True).stdout
hey_version_match = re.search(r"^\s*mod\s+github.com/rakyll/hey\s+(\S+)", hey_build, re.M)
hey_version = hey_version_match.group(1) if hey_version_match else "unknown"

task_arn = None
task = None
for _ in range(60):
    listed = subprocess.run(
        ["aws", "ecs", "list-tasks", "--region", region, "--cluster", cluster,
         "--service-name", service, "--desired-status", "RUNNING", "--output", "json"],
        capture_output=True, text=True, check=True,
    )
    task_arns = json.loads(listed.stdout).get("taskArns", [])
    if task_arns:
        described = subprocess.run(
            ["aws", "ecs", "describe-tasks", "--region", region, "--cluster", cluster,
             "--tasks", task_arns[0], "--output", "json"],
            capture_output=True, text=True, check=True,
        )
        tasks = json.loads(described.stdout).get("tasks", [])
        if tasks and tasks[0].get("lastStatus") == "RUNNING":
            task_arn, task = task_arns[0], tasks[0]
            break
    time.sleep(2)

if task is None:
    raise SystemExit(f"No RUNNING task found for ECS service {service} after 120 seconds")

task_ip = None
for attachment in task.get("attachments", []):
    for detail in attachment.get("details", []):
        if detail.get("name") == "privateIPv4Address":
            task_ip = detail.get("value")
            break
    if task_ip:
        break
if not task_ip:
    for container in task.get("containers", []):
        interfaces = container.get("networkInterfaces", [])
        if interfaces and interfaces[0].get("privateIpv4Address"):
            task_ip = interfaces[0]["privateIpv4Address"]
            break
if not task_ip:
    raise SystemExit(f"Could not find the task ENI private IP in ECS task {task_arn}")
ipaddress.IPv4Address(task_ip)
api_url = f"http://{task_ip}:8080"

last_health_error = None
for _ in range(30):
    try:
        with urllib.request.urlopen(f"{api_url}/health", timeout=3) as response:
            if response.status == 204:
                break
            last_health_error = f"unexpected status {response.status}"
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        last_health_error = str(error)
    time.sleep(2)
else:
    print(json.dumps({"task_arn": task_arn, "task_status": task.get("lastStatus"),
                      "task_ip": task_ip, "health_error": last_health_error}), file=sys.stderr)
    service_info = subprocess.run(
        ["aws", "ecs", "describe-services", "--region", region, "--cluster", cluster,
         "--services", service, "--query", "services[0].events[:8].[createdAt,message]", "--output", "json"],
        capture_output=True, text=True,
    )
    print(service_info.stdout, file=sys.stderr)
    raise SystemExit(f"Parking API health check failed at {api_url}/health: {last_health_error}")

tests = []
for endpoint, expected_status in (("health", 204), ("spots", 200)):
    result = subprocess.run(
        ["hey", "-cpus", load_threads, "-t", "5", "-c", connections, "-z", f"{duration}s", f"{api_url}/{endpoint}"],
        capture_output=True,
        text=True,
        timeout=int(duration) + 30,
        check=True,
    )
    print(result.stdout, file=sys.stderr, end="")
    output = result.stdout
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", output).group(1))
    elapsed = float(re.search(r"Total:\s+([\d.]+)\s+secs", output).group(1))
    total_data = int(re.search(r"Total data:\s+(\d+)\s+bytes", output).group(1)) if re.search(r"Total data:\s+(\d+)\s+bytes", output) else 0
    status_block = re.search(r"Status code distribution:(.*?)(?:\n\n|\Z)", output, re.S)
    statuses = {
        int(code): int(count)
        for code, count in re.findall(r"\[(\d+)\]\s+(\d+) responses", status_block.group(1) if status_block else "")
    }
    error_block = re.search(r"Error distribution:(.*?)(?:\n\n|\Z)", output, re.S)
    transport_errors = sum(
        int(count)
        for count in re.findall(r"\[(\d+)\]\s+[^\n]+", error_block.group(1) if error_block else "")
    )
    percentiles = {
        int(percentile): float(seconds)
        for percentile, seconds in re.findall(r"^\s*(\d+)% in\s+([\d.]+) secs", output, re.M)
    }
    tests.append({
        "endpoint": f"/{endpoint}",
        "requests_per_second": rps,
        "estimated_total_requests": round(rps * elapsed),
        "sampled_responses": sum(statuses.values()),
        "transferred_bytes_per_second": total_data / elapsed if elapsed else 0,
        "latency_p50_seconds": percentiles.get(50),
        "latency_p75_seconds": percentiles.get(75),
        "latency_p90_seconds": percentiles.get(90),
        "latency_p95_seconds": percentiles.get(95),
        "latency_p99_seconds": percentiles.get(99),
        "sampled_http_status_counts": {str(code): count for code, count in statuses.items()},
        "unexpected_status_count": sum(count for code, count in statuses.items() if code != expected_status),
        "transport_error_count": transport_errors,
    })

print(json.dumps({
    "run_id": run_id,
    "region": region,
    "account_id": account_id,
    "ecs_instance_type": ecs_instance_type,
    "ecs_instance_vcpus": int(ecs_instance_vcpus),
    "ecs_instance_memory_mib": int(ecs_instance_memory_mib),
    "task_cpu_units": int(task_cpu_units),
    "task_memory_mib": int(task_memory_mib),
    "load_generator_instance_type_configured": runner_instance_type,
    "load_generator_instance_vcpus": int(runner_vcpus),
    "load_generator_instance_memory_mib": int(runner_memory_mib),
    "task_private_ip": task_ip,
    "load_generator_instance_type": load_generator_instance_type,
    "load_generator_instance_id": load_generator_instance_id,
    "availability_zone": benchmark_az,
    "network_path": "VPC private task IP, same subnet/AZ, HTTP",
    "image_ref": image_ref,
    "source_commit": source_commit,
    "load_generator_tool": f"hey {hey_version}",
    "load_generator_go_version": go_version,
    "load_generator_threads": int(load_threads),
    "api_url": api_url,
    "duration_seconds": int(duration),
    "connections": int(connections),
    "tests": tests,
}, separators=(",", ":")))
REMOTE

python3 - "$RESULT_JSON" "$RESULT_CSV" <<'PY'
import csv, json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", newline="", encoding="utf-8") as f:
    fields = ["run_id", "region", "ecs_instance_type", "load_generator_instance_type", "endpoint", "duration_seconds", "connections", "requests_per_second", "estimated_total_requests", "sampled_responses", "transferred_bytes_per_second", "latency_p50_seconds", "latency_p75_seconds", "latency_p90_seconds", "latency_p95_seconds", "latency_p99_seconds", "unexpected_status_count", "transport_error_count"]
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    for test in data["tests"]:
        writer.writerow({**{key: data.get(key, "") for key in fields}, **test, "duration_seconds": data["duration_seconds"], "connections": data["connections"]})
PY

mkdir -p "$REPORT_DIR"
python3 - "$RESULT_JSON" "$REPORT_MD" <<'PY'
import json, sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
lines = [
    f"# ECS Managed Instances benchmark — {data['run_id']}",
    "",
    "## Configuration",
    "",
    f"- Region / AZ: `{data['region']}` / `{data['availability_zone']}`",
    f"- ECS managed instance: `{data['ecs_instance_type']}` — {data['ecs_instance_vcpus']} vCPU, {data['ecs_instance_memory_mib'] / 1024:g} GiB RAM",
    f"- Task: {data['task_cpu_units']} CPU units, {data['task_memory_mib']} MiB memory; desired count 1",
    f"- Load generator: `{data['load_generator_instance_type']}` — {data['load_generator_instance_vcpus']} vCPU, {data['load_generator_instance_memory_mib'] / 1024:g} GiB RAM",
    f"- Load tool: `{data['load_generator_tool']}` ({data['load_generator_go_version']})",
    f"- Test: {data['duration_seconds']} s per endpoint, {data['connections']} concurrent workers, {data['load_generator_threads']} load threads, 5 s request timeout",
    f"- Network: {data['network_path']}; no ALB or NAT Gateway",
    f"- Container image: `{data['image_ref']}`",
    f"- Source commit: `{data['source_commit']}`",
    "",
    "## Results",
    "",
    "| Endpoint | RPS | Estimated requests | Sampled responses | p50 | p95 | p99 | Status codes | Errors |",
    "|---|---:|---:|---:|---:|---:|---:|---|---:|",
]
for test in data["tests"]:
    statuses = ", ".join(f"{code}: {count:,}" for code, count in test["sampled_http_status_counts"].items())
    lines.append(
        f"| `{test['endpoint']}` | {test['requests_per_second']:,.2f} | {test['estimated_total_requests']:,} | "
        f"{test['sampled_responses']:,} | {test['latency_p50_seconds'] * 1000:.3f} ms | "
        f"{test['latency_p95_seconds'] * 1000:.3f} ms | {test['latency_p99_seconds'] * 1000:.3f} ms | "
        f"{statuses} | {test['unexpected_status_count'] + test['transport_error_count']} |"
    )
lines.extend([
    "",
    "> `hey` stores latency/status samples for at most 1,000,000 responses. RPS covers the full duration; estimated requests are rounded from the printed RPS × elapsed time. Percentiles and status counts describe the capped sample.",
    "> This report was reconstructed from the runner output because the IMDS metadata token expired during final JSON serialization; the exact task private IP was not retained. The load measurements themselves completed before that serialization error.",
    "",
])
with open(sys.argv[2], "w", encoding="utf-8") as report:
    report.write("\n".join(lines))
PY

printf '\nResults saved to:\n  %s\n  %s\n' "$RESULT_JSON" "$RESULT_CSV"
