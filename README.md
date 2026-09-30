# ECS Managed Instances benchmark

Benchmark a small Go parking API on ECS Managed Instances using a Graviton EC2 load generator. OpenTofu provisions the temporary AWS environment, Ansible installs/configures the runner, and `oha` measures HTTP throughput and latency through an internal Application Load Balancer (ALB). The runner saves JSON/CSV and archives API stdout/stderr before destroying the infrastructure.

## What gets created

- A dedicated VPC with one public subnet for ECS/runner, an Internet Gateway, and two private subnets across separate AZs for an internal ALB. The ALB accepts HTTP from the runner's security group and forwards to ECS task IPs on port 8080; no NAT Gateway is provisioned.
- A per-run CloudWatch Logs group for the API with seven-day retention. The harness archives app logs locally before teardown; a successful destroy removes the run-scoped log group.
- An ECS cluster, an On-Demand Managed Instances capacity provider restricted to one instance type (`m9g.xlarge` by default), task/service, CPU target-tracking Service Auto Scaling (1–8 tasks by default), IAM roles, and a temporary ECR repository.
- A Graviton load-generator EC2 instance (`m9g.2xlarge` by default, twice the vCPU and memory of the `m9g.xlarge` ECS task host) with a narrowly scoped SSH ingress and an instance role to publish the container and start the ECS service.

The service starts at desired count zero. Ansible builds the Go container on the EC2 runner and pushes it to ECR; a second OpenTofu apply enables CPU target tracking and starts the minimum task count. Oha ramps `/spots` concurrency from 64 to 1,024, doubling each step and sending traffic to the ALB DNS name. Each stage lasts 120 seconds by default, with no intentional idle gap; before the next stage the runner waits for the ECS tasks to become healthy ALB targets. The autoscaler targets 60% ECS service CPU, with 1–8 tasks and 30/300-second scale-out/in cooldowns. The ALB is internal and spans two AZs, while the ECS capacity provider remains pinned to one AZ. No NAT Gateway is provisioned; there is no RDS/database in this API benchmark.

## Prerequisites

On the machine running the script: OpenTofu >= 1.8, AWS CLI plus credentials with permission to create/delete the listed EC2, VPC, ECS, ECR, ELB, CloudWatch Logs, IAM and Application Auto Scaling resources, Ansible, Python 3, `curl`, `ssh`, and `ssh-keygen`. Docker is installed on the remote load generator by Ansible and the image is built there.

Ensure the selected region/account has quota and availability for the chosen M9g sizes, ECS Managed Instances, and an ALB in two AZs. The account needs permission to pass the created IAM roles. The temporary SSH ingress is restricted to the caller's detected public IPv4 `/32`; set `ALLOWED_SSH_CIDR` to override it. SSH ingress cannot be omitted while this harness uses Ansible over SSH. Resources incur AWS charges while running, including ALB-hours and LCU-hours; the ALB subnets are private and the service is not exposed publicly. On teardown failure, the runner attempts to scale in/deregister ECS instances and retry OpenTofu destroy. Check AWS afterward if it still reports a cleanup error.

## Run

```bash
export AWS_REGION=us-east-1 # optional; defaults to us-east-1
./scripts/run-benchmark.sh
```

By default the script creates a temporary Ed25519 key pair and registers only its public key in EC2/OpenTofu. The private key is stored under `results/` during the run and removed after successful teardown. To use an existing EC2 key pair instead, set **both** `KEY_NAME` and `SSH_KEY_PATH`; the existing key pair is not deleted.

Optional environment variables:

| Variable | Default | Meaning |
|---|---:|---|
| `AWS_REGION` | `us-east-1` | AWS region |
| `KEY_NAME` + `SSH_KEY_PATH` | generated | Set both to use an existing EC2 key pair |
| `ALLOWED_SSH_CIDR` | detected public IP `/32` | Narrow SSH ingress override; Ansible needs SSH access |
| `DESTROY_ON_EXIT` | `true` | Set to `false` to keep infrastructure for debugging; run `tofu -chdir=infra destroy` manually afterward with the same variables |
| `RESULT_DIR` | `results/` | Local location for JSON/CSV/log artifacts |

Autoscaling and ramp defaults live in `infra/variables.tf`: target CPU 60%, 1–8 tasks, 64–1,024 Oha connections, 120-second continuous stages, and a 90-second post-load watch for delayed scaling and CloudWatch CPU datapoints. The run report records task/host counts at each stage, post-load scaling observations, service CPU datapoints and ingress type. Use a smaller `autoscaling_max_tasks` or `load_max_connections` for a cheaper bounded run. The latest Go 1.27.1 internal-ALB run completed on 2026-09-29; target tracking raised desired count only after the load window. See [`benchmarks/runs/20260929T230553Z.md`](benchmarks/runs/20260929T230553Z.md) and the AWS policy record below.

Edit `infra/variables.tf` to change ECS/runner instance types, connection count, or test duration. The instance type is intentionally a single explicit selection so placement does not drift between runs.

## Results

Each run writes JSON/CSV/log files under ignored `results/` and a Markdown report at `benchmarks/runs/<UTC-run-id>.md`, ready to review and commit. The report includes instance/task sizing, AZ, ingress type, autoscaling policy, ramp stages, tool/image/source revisions, task counts and results. API stdout/stderr is copied to `results/<UTC-run-id>-app-logs.json`; the per-run CloudWatch Logs group has seven-day retention and is removed by successful teardown. Oha writes structured JSON with throughput, status counts and latency percentiles. The earlier Hey run is documented separately; Hey capped its latency/status samples at one million responses. ALB target health and HTTP requests have bounded timeouts; a failed health check prints task and ECS service diagnostics before teardown.

The AWS load-test policy review and completed run records are in [`docs/aws-load-test-policy.md`](docs/aws-load-test-policy.md), including the [latest Go 1.27.1 internal-ALB run](benchmarks/runs/20260929T230553Z.md). Log-retention decisions and the current CloudTrail/CloudWatch inventory are in [`docs/aws-log-retention.md`](docs/aws-log-retention.md).

For apples-to-apples comparisons, record separate runs with identical settings and change only the ECS instance type. Keep task size, API image and runner type constant. For stronger results, warm up first and repeat each run several times; the harness records CloudWatch CPU, but not memory time series or AWS cost estimates.

## Local checks

```bash
mise exec -- go test -race ./...
mise exec -- go build ./...
bash -n scripts/run-benchmark.sh
```

The repeatable local performance/profiling suite is documented in [`benchmarks/local/README.md`](benchmarks/local/README.md); its latest full native Go 1.27.1 run is [`20260929T175318Z.md`](benchmarks/local/20260929T175318Z.md).
