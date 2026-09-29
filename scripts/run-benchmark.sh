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

output() { tofu -chdir="$INFRA_DIR" output -raw "$1"; }

cleanup() {
  local status=$?
  if [[ "$APPLIED" == true && "$DESTROY_ON_EXIT" == true ]]; then
    local cleanup_cluster="${CLUSTER:-}"
    local cleanup_service="${SERVICE:-}"
    if [[ -z "$cleanup_cluster" ]]; then
      cleanup_cluster="$(tofu -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
    fi
    if [[ -z "$cleanup_service" ]]; then
      cleanup_service="$(tofu -chdir="$INFRA_DIR" output -raw service_name 2>/dev/null || true)"
    fi
    printf '\nDestroying benchmark infrastructure...\n'
    if ! tofu -chdir="$INFRA_DIR" destroy -auto-approve -input=false "${TOFU_VARS[@]}" >>"$LOG_FILE" 2>&1; then
      printf 'OpenTofu destroy needs ECS cleanup recovery; forcing service scale-in and container-instance deregistration.\n' >&2
      if [[ -n "$cleanup_cluster" ]]; then
        aws ecs update-service --region "$AWS_REGION" --cluster "$cleanup_cluster" \
          --service "${cleanup_service:-$cleanup_cluster}" --desired-count 0 >>"$LOG_FILE" 2>&1 || true
      fi
      local container_instances=""
      if [[ -n "$cleanup_cluster" ]]; then
        container_instances="$(aws ecs list-container-instances --region "$AWS_REGION" \
          --cluster "$cleanup_cluster" --status ACTIVE --query 'containerInstanceArns' \
          --output text 2>>"$LOG_FILE")" || true
      fi
      if [[ -n "$container_instances" && "$container_instances" != "None" ]]; then
        for container_instance in $container_instances; do
          aws ecs deregister-container-instance --region "$AWS_REGION" \
            --cluster "$cleanup_cluster" --container-instance "$container_instance" \
            --force >>"$LOG_FILE" 2>&1 || true
        done
      fi
      if ! tofu -chdir="$INFRA_DIR" destroy -auto-approve -input=false -lock-timeout=60s \
        "${TOFU_VARS[@]}" >>"$LOG_FILE" 2>&1; then
        printf 'WARNING: tofu destroy still failed; inspect %s and clean up manually.\n' "$LOG_FILE" >&2
        status=1
        KEEP_GENERATED_KEY=true
      fi
    fi
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
AUTOSCALING_MIN="$(output autoscaling_min_tasks)"
AUTOSCALING_MAX="$(output autoscaling_max_tasks)"
AUTOSCALING_CPU="$(output autoscaling_target_cpu_percent)"
AUTOSCALING_SCALE_IN="$(output autoscaling_scale_in_cooldown_seconds)"
AUTOSCALING_SCALE_OUT="$(output autoscaling_scale_out_cooldown_seconds)"
LOAD_MAX_CONNECTIONS="$(output load_max_connections)"
LOAD_SCALE_SETTLE_SECONDS="$(output load_scale_settle_seconds)"
CW_METRIC_SETTLE_SECONDS="$(output cloudwatch_metric_settle_seconds)"
ALB_DNS_NAME="$(output alb_dns_name)"
ALB_TARGET_GROUP_ARN="$(output alb_target_group_arn)"
IMAGE_REF="$ECR_URL:benchmark"

cat > "$ROOT_DIR/ansible/.inventory.generated.ini" <<EOF
[runner]
benchmark-runner ansible_host=$RUNNER_IP ansible_user=ec2-user ansible_ssh_private_key_file=$SSH_KEY_PATH ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes'
EOF
chmod 600 "$ROOT_DIR/ansible/.inventory.generated.ini"

printf 'Waiting for SSH on load generator %s...\n' "$RUNNER_IP"
for attempt in $(seq 1 60); do
  if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes \
    "ec2-user@$RUNNER_IP" true 2>/dev/null; then break; fi
  [[ "$attempt" -lt 60 ]] || { printf 'SSH did not become available.\n' >&2; exit 1; }
  sleep 10
done

ansible-playbook -i "$ROOT_DIR/ansible/.inventory.generated.ini" "$ROOT_DIR/ansible/benchmark.yml" \
  -e "aws_region=$AWS_REGION" -e "ecr_repository_url=$ECR_URL"

# The image is now available in ECR. Enable service scaling and start its minimum task count.
tofu -chdir="$INFRA_DIR" apply -auto-approve -input=false "${TOFU_VARS[@]}" \
  -var=enable_service_autoscaling=true \
  -var="service_desired_count=$AUTOSCALING_MIN" \
  -var="autoscaling_min_tasks=$AUTOSCALING_MIN" \
  -var="autoscaling_max_tasks=$AUTOSCALING_MAX" \
  -var="autoscaling_target_cpu_percent=$AUTOSCALING_CPU" \
  -var="autoscaling_scale_in_cooldown_seconds=$AUTOSCALING_SCALE_IN" \
  -var="autoscaling_scale_out_cooldown_seconds=$AUTOSCALING_SCALE_OUT" \
  2>&1 | tee -a "$LOG_FILE"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "ec2-user@$RUNNER_IP" \
  "aws ecs update-service --cluster '$CLUSTER' --service '$SERVICE' --desired-count '$AUTOSCALING_MIN' --region '$AWS_REGION' >/dev/null"

printf 'Waiting for initial ECS task before the autoscaling ramp...\n'
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "ec2-user@$RUNNER_IP" \
  "aws ecs wait services-stable --cluster '$CLUSTER' --services '$SERVICE' --region '$AWS_REGION'"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes "ec2-user@$RUNNER_IP" \
  "python3 - '$CLUSTER' '$SERVICE' '$DURATION' '$CONNECTIONS' '$LOAD_MAX_CONNECTIONS' '$LOAD_SCALE_SETTLE_SECONDS' '$CW_METRIC_SETTLE_SECONDS' '$ALB_DNS_NAME' '$ALB_TARGET_GROUP_ARN' '$RUN_ID' '$ACCOUNT_ID' '$AWS_REGION' '$ECS_INSTANCE_TYPE' '$RUNNER_INSTANCE_TYPE' '$TASK_CPU_UNITS' '$TASK_MEMORY_MIB' '$BENCHMARK_AZ' '$IMAGE_REF' '$ECS_INSTANCE_VCPUS' '$ECS_INSTANCE_MEMORY_MIB' '$RUNNER_VCPUS' '$RUNNER_MEMORY_MIB' '$SOURCE_COMMIT' '$AUTOSCALING_MIN' '$AUTOSCALING_MAX' '$AUTOSCALING_CPU' '$AUTOSCALING_SCALE_IN' '$AUTOSCALING_SCALE_OUT'" <<'REMOTE' | tee "$RESULT_JSON"
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
import urllib.error
import urllib.request

(
    cluster, service, duration, starting_connections, max_connections, scale_settle_seconds,
    cloudwatch_metric_settle_seconds, alb_dns_name, alb_target_group_arn,
    run_id, account_id, region,
    ecs_instance_type, runner_instance_type, task_cpu_units, task_memory_mib,
    benchmark_az, image_ref, ecs_instance_vcpus,
    ecs_instance_memory_mib, runner_vcpus, runner_memory_mib, source_commit,
    autoscaling_min_tasks, autoscaling_max_tasks, autoscaling_target_cpu,
    autoscaling_scale_in_cooldown, autoscaling_scale_out_cooldown,
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

def aws_json(*args):
    result = subprocess.run(["aws", *args, "--region", region, "--output", "json"],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)

def service_state():
    response = aws_json("ecs", "describe-services", "--cluster", cluster, "--services", service)
    services = response.get("services", [])
    if not services:
        raise RuntimeError(f"ECS service {service} not found")
    current = services[0]
    return {
        "desired": current.get("desiredCount", 0),
        "running": current.get("runningCount", 0),
        "pending": current.get("pendingCount", 0),
    }

def running_task_ips():
    listed = aws_json("ecs", "list-tasks", "--cluster", cluster,
                      "--service-name", service, "--desired-status", "RUNNING")
    task_arns = listed.get("taskArns", [])
    if not task_arns:
        return []
    described = aws_json("ecs", "describe-tasks", "--cluster", cluster, "--tasks", *task_arns)
    ips = []
    for task in described.get("tasks", []):
        if task.get("lastStatus") != "RUNNING":
            continue
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
        if task_ip:
            ipaddress.IPv4Address(task_ip)
            ips.append(task_ip)
    return sorted(set(ips))

def managed_instance_count():
    listed = aws_json("ecs", "list-container-instances", "--cluster", cluster,
                      "--status", "ACTIVE")
    return len(listed.get("containerInstanceArns", []))

def ready_snapshot(timeout_seconds=300):
    deadline = time.monotonic() + timeout_seconds
    last = {}
    while time.monotonic() < deadline:
        last = service_state()
        ips = running_task_ips()
        healthy_targets = aws_json(
            "elbv2", "describe-target-health", "--target-group-arn", alb_target_group_arn
        ).get("TargetHealthDescriptions", [])
        healthy_count = sum(target.get("TargetHealth", {}).get("State") == "healthy" for target in healthy_targets)
        if (last["desired"] > 0 and last["running"] >= last["desired"] and last["pending"] == 0
                and len(ips) >= last["running"] and healthy_count >= last["running"]):
            with urllib.request.urlopen(f"http://{alb_dns_name}/health", timeout=5) as health:
                if health.status != 204:
                    raise RuntimeError(f"internal ALB health endpoint returned {health.status}")
            return last, ips
        time.sleep(5)
    raise TimeoutError(f"service did not become ready within {timeout_seconds}s; last state={last}")

load_generator_instance_type = metadata("instance-type")
load_generator_instance_id = metadata("instance-id")
oha_version = subprocess.run(["oha", "--version"], capture_output=True, text=True, check=True).stdout.strip()

steps = [int(starting_connections)]
while steps[-1] < int(max_connections):
    steps.append(min(steps[-1] * 2, int(max_connections)))

tests = []
max_desired_observed = 0
max_running_observed = 0
max_managed_instances_observed = 0
load_started_at = datetime.now(timezone.utc)
for concurrency in steps:
    before, task_ips = ready_snapshot()
    instances_before = managed_instance_count()
    max_managed_instances_observed = max(max_managed_instances_observed, instances_before)
    print(
        f"Starting /spots stage: concurrency={concurrency}, tasks={before['running']}, "
        f"healthy_targets={len(task_ips)}",
        file=sys.stderr, flush=True,
    )
    url_file = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix="ecs-mi-oha-", suffix=".txt", delete=False) as urls:
            url_file = urls.name
            urls.write(f"http://{alb_dns_name}/spots\n")
        result = subprocess.run(
            ["oha", "--no-tui", "-w", "--http-version", "1.1", "--output-format", "json",
             "-t", "5s", "-c", str(concurrency), "-z", f"{duration}s", "--urls-from-file", url_file],
            capture_output=True, text=True, timeout=int(duration) + 30, check=True,
        )
    finally:
        if url_file and os.path.exists(url_file):
            os.unlink(url_file)

    output = json.loads(result.stdout)
    summary = output["summary"]
    statuses = {str(code): int(count) for code, count in output.get("statusCodeDistribution", {}).items()}
    errors = output.get("errorDistribution", {})
    percentiles = output.get("latencyPercentiles", {})
    total_responses = sum(statuses.values())
    transport_errors = sum(int(count) for count in errors.values())
    print(
        f"Completed /spots stage: concurrency={concurrency}, "
        f"rps={summary['requestsPerSec']:.0f}, responses={total_responses}",
        file=sys.stderr, flush=True,
    )
    time.sleep(int(scale_settle_seconds))
    after, task_ips_after = ready_snapshot(timeout_seconds=300)
    current_instances = managed_instance_count()
    print(
        f"Settled /spots stage: concurrency={concurrency}, desired={after['desired']}, "
        f"running={after['running']}, healthy_targets={len(task_ips_after)}",
        file=sys.stderr, flush=True,
    )
    max_managed_instances_observed = max(max_managed_instances_observed, current_instances)
    max_desired_observed = max(max_desired_observed, before["desired"], after["desired"])
    max_running_observed = max(max_running_observed, before["running"], after["running"])
    tests.append({
        "endpoint": "/spots",
        "concurrency": concurrency,
        "duration_seconds": float(summary["total"]),
        "task_targets": len(task_ips),
        "desired_tasks_before": before["desired"],
        "running_tasks_before": before["running"],
        "managed_instances_before": instances_before,
        "desired_tasks_after": after["desired"],
        "running_tasks_after": after["running"],
        "pending_tasks_after": after["pending"],
        "managed_instances_after": current_instances,
        "requests_per_second": summary["requestsPerSec"],
        "total_requests": total_responses + transport_errors,
        "total_responses": total_responses,
        "transferred_bytes_per_second": summary["sizePerSec"],
        "latency_p50_seconds": percentiles.get("p50"),
        "latency_p75_seconds": percentiles.get("p75"),
        "latency_p90_seconds": percentiles.get("p90"),
        "latency_p95_seconds": percentiles.get("p95"),
        "latency_p99_seconds": percentiles.get("p99"),
        "http_status_counts": statuses,
        "unexpected_status_count": sum(count for code, count in statuses.items() if int(code) != 200),
        "transport_error_count": transport_errors,
    })

load_finished_at = datetime.now(timezone.utc)
time.sleep(int(cloudwatch_metric_settle_seconds))
metric_start = (load_started_at - timedelta(minutes=1)).isoformat(timespec="seconds").replace("+00:00", "Z")
metric_end = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
try:
    cpu_response = aws_json(
        "cloudwatch", "get-metric-statistics", "--namespace", "AWS/ECS",
        "--metric-name", "CPUUtilization",
        "--dimensions", f"Name=ClusterName,Value={cluster}", f"Name=ServiceName,Value={service}",
        "--start-time", metric_start, "--end-time", metric_end, "--period", "60",
        "--statistics", "Average", "Maximum",
    )
    cpu_datapoints = sorted(cpu_response.get("Datapoints", []), key=lambda item: item["Timestamp"])
    cpu_metrics_error = None
except subprocess.CalledProcessError as error:
    cpu_datapoints = []
    cpu_metrics_error = error.stderr.strip() or str(error)

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
    "load_generator_instance_type": load_generator_instance_type,
    "load_generator_instance_id": load_generator_instance_id,
    "availability_zone": benchmark_az,
    "network_path": "load generator -> private internal ALB -> private ECS task IP, HTTP",
    "ingress": {
        "type": "internal-application-load-balancer",
        "scheme": "internal",
        "listener_protocol": "HTTP",
        "listener_port": 80,
        "target_protocol": "HTTP",
        "target_port": 8080,
        "dns_name": alb_dns_name,
        "availability_zones": 2,
    },
    "image_ref": image_ref,
    "source_commit": source_commit,
    "load_generator_tool": oha_version,
    "autoscaling": {
        "metric": "ECSServiceAverageCPUUtilization",
        "target_cpu_percent": float(autoscaling_target_cpu),
        "min_tasks": int(autoscaling_min_tasks),
        "max_tasks": int(autoscaling_max_tasks),
        "scale_in_cooldown_seconds": int(autoscaling_scale_in_cooldown),
        "scale_out_cooldown_seconds": int(autoscaling_scale_out_cooldown),
        "max_desired_tasks_observed": max_desired_observed,
        "max_running_tasks_observed": max_running_observed,
        "max_managed_instances_observed": max_managed_instances_observed,
    },
    "load_ramp": {
        "starting_connections": int(starting_connections),
        "max_connections": int(max_connections),
        "step_multiplier": 2,
        "duration_per_step_seconds": int(duration),
        "settle_between_steps_seconds": int(scale_settle_seconds),
    },
    "autoscaling_cpu_metrics": {
        "metric_name": "CPUUtilization",
        "namespace": "AWS/ECS",
        "load_started_at": load_started_at.isoformat(),
        "load_finished_at": load_finished_at.isoformat(),
        "datapoints": cpu_datapoints,
        "error": cpu_metrics_error,
    },
    "tests": tests,
}, separators=(",", ":")))
REMOTE

python3 - "$RESULT_JSON" "$RESULT_CSV" <<'PY'
import csv, json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", newline="", encoding="utf-8") as f:
    fields = ["run_id", "region", "ecs_instance_type", "load_generator_instance_type", "endpoint", "concurrency", "duration_seconds", "task_targets", "desired_tasks_before", "running_tasks_before", "managed_instances_before", "desired_tasks_after", "running_tasks_after", "pending_tasks_after", "managed_instances_after", "requests_per_second", "total_requests", "total_responses", "transferred_bytes_per_second", "latency_p50_seconds", "latency_p75_seconds", "latency_p90_seconds", "latency_p95_seconds", "latency_p99_seconds", "http_status_counts", "unexpected_status_count", "transport_error_count"]
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    for test in data["tests"]:
        row = {**{key: data.get(key, "") for key in fields}, **test}
        row["http_status_counts"] = json.dumps(test["http_status_counts"], sort_keys=True)
        writer.writerow(row)
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
    f"- Load tool: `{data['load_generator_tool']}`",
    f"- Autoscaling: ECS service CPU target {data['autoscaling']['target_cpu_percent']}%, min/max tasks {data['autoscaling']['min_tasks']}/{data['autoscaling']['max_tasks']}, scale-out/in cooldown {data['autoscaling']['scale_out_cooldown_seconds']}/{data['autoscaling']['scale_in_cooldown_seconds']} s",
    f"- Autoscaling observed: max desired/running tasks {data['autoscaling']['max_desired_tasks_observed']}/{data['autoscaling']['max_running_tasks_observed']}; max Managed Instances hosts {data['autoscaling']['max_managed_instances_observed']}",
    f"- Load ramp: {data['load_ramp']['starting_connections']} to {data['load_ramp']['max_connections']} connections, doubling each stage, {data['load_ramp']['duration_per_step_seconds']} s per stage, {data['load_ramp']['settle_between_steps_seconds']} s settle interval",
    f"- Load tool: HTTP/1.1, 5 s per-request timeout; the ALB distributes requests across healthy task targets",
    f"- Ingress: internal ALB HTTP:{data['ingress']['listener_port']} -> task HTTP:{data['ingress']['target_port']} across {data['ingress']['availability_zones']} AZs",
    f"- Network: {data['network_path']}; no NAT Gateway",
    f"- Container image: `{data['image_ref']}`",
    f"- Source commit: `{data['source_commit']}`",
    f"- CloudWatch CPU data points captured: {len(data['autoscaling_cpu_metrics']['datapoints'])}",
    "",
    "## Results",
    "",
    "| Concurrency | Targets | Tasks desired→after | Tasks running→after | MI hosts before→after | RPS | Requests | p50 | p95 | p99 | Status | Errors |",
    "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|",
]
for test in data["tests"]:
    statuses = ", ".join(f"{code}: {count:,}" for code, count in test["http_status_counts"].items())
    lines.append(
        f"| {test['concurrency']} | {test['task_targets']} | {test['desired_tasks_before']}→{test['desired_tasks_after']} | "
        f"{test['running_tasks_before']}→{test['running_tasks_after']} | "
        f"{test['managed_instances_before']}→{test['managed_instances_after']} | "
        f"{test['requests_per_second']:,.2f} | {test['total_requests']:,} | "
        f"{test['latency_p50_seconds'] * 1000:.3f} ms | "
        f"{test['latency_p95_seconds'] * 1000:.3f} ms | {test['latency_p99_seconds'] * 1000:.3f} ms | "
        f"{statuses} | {test['unexpected_status_count'] + test['transport_error_count']} |"
    )
if data["autoscaling_cpu_metrics"].get("datapoints"):
    points = data["autoscaling_cpu_metrics"]["datapoints"]
    avg_peak = max(point.get("Average", 0) for point in points)
    max_peak = max(point.get("Maximum", 0) for point in points)
    lines.append(f"Peak ECS service CPU: {avg_peak:.1f}% average datapoint / {max_peak:.1f}% maximum datapoint.")
elif data["autoscaling_cpu_metrics"].get("error"):
    lines.append(f"CloudWatch CPU metric collection failed: `{data['autoscaling_cpu_metrics']['error']}`")
lines.extend([
    "",
    "> Results come from Oha's JSON output. Requests go through the ALB and are distributed across healthy targets; tasks that become healthy during a stage can receive traffic immediately. No separate warm-up phase is included.",
    "",
])
with open(sys.argv[2], "w", encoding="utf-8") as report:
    report.write("\n".join(lines))
PY

printf '\nResults saved to:\n  %s\n  %s\n' "$RESULT_JSON" "$RESULT_CSV"
