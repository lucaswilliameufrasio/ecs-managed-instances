# ECS Managed Instances benchmark

Benchmark a small Go parking API on ECS Managed Instances using a Graviton EC2 load generator. OpenTofu provisions the temporary AWS environment, Ansible installs/configures the runner, `hey` measures HTTP throughput and latency against the task's private IP, and the runner saves JSON/CSV before destroying the infrastructure.

## What gets created

- A dedicated VPC with one public subnet and an Internet Gateway. The API is reached directly over its private task IP; no load balancer or NAT Gateway is provisioned.
- An ECS cluster, an On-Demand Managed Instances capacity provider restricted to one instance type (`m9g.xlarge` by default), task/service, IAM roles, and a temporary ECR repository.
- A Graviton load-generator EC2 instance (`m9g.2xlarge` by default, twice the vCPU and memory of the `m9g.xlarge` ECS task host) with a narrowly scoped SSH ingress and an instance role to publish the container and start the ECS service.

The service starts at desired count zero. Ansible builds the Go container on the EC2 runner, pushes it to ECR, and starts the service. The generator discovers the running task's private IP through ECS and calls it over the VPC-local path, avoiding public ingress and ALB latency/cost. It uses `hey` for HTTP load; there is no RDS/database in this first API benchmark.

## Prerequisites

On the machine running the script: OpenTofu >= 1.8, AWS CLI plus credentials with permission to create/delete the listed EC2, VPC, ECS, ECR, IAM and ELB resources, Ansible, Python 3, `curl`, `ssh`, and `ssh-keygen`. Docker is installed on the remote load generator by Ansible and the image is built there.

Ensure the selected region/account has quota and availability for the chosen M9g sizes and ECS Managed Instances. The account needs permission to pass the created IAM roles. The temporary SSH ingress is restricted to the caller's detected public IPv4 `/32`; set `ALLOWED_SSH_CIDR` to override it. SSH ingress cannot be omitted while this harness uses Ansible over SSH. Resources incur AWS charges while running; the script destroys them on success or failure after apply, but check AWS afterward if destroy reports an error.

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
| `RESULT_DIR` | `results/` | Local location for result artifacts |

Edit `infra/variables.tf` to change ECS/runner instance types, connection count, or test duration. The instance type is intentionally a single explicit selection so placement does not drift between runs.

## Results

Each run writes JSON/CSV/log files under ignored `results/` and a Markdown report at `benchmarks/runs/<UTC-run-id>.md`, ready to review and commit. The report includes instance/task sizing, AZ, concurrency, duration, tool/image/source revisions and results. The tests are `GET /health` and `GET /spots`; default duration is 30 seconds with 64 concurrent connections per endpoint. `hey` caps its latency/status samples at one million responses; its requests/sec covers the full duration, while sampled status counts and percentiles describe that bounded sample. Health checks and HTTP requests have bounded timeouts; a failed health check prints task and ECS service diagnostics before teardown.

For apples-to-apples comparisons, record separate runs with identical settings and change only the ECS instance type. Keep task size, API image and runner type constant. For stronger results, warm up first and repeat each run several times; this initial harness does not collect CloudWatch service/host metrics or estimate AWS cost.

## Local checks

```bash
go test -race ./...
go build ./...
bash -n scripts/run-benchmark.sh
```
