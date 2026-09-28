# AWS policy-alignment record for the ECS benchmark

**Reviewed:** 2026-09-28
**Purpose:** Record the AWS policies reviewed and the scope/configuration of the benchmark in case the activity is reported to AWS. This is a technical record of our interpretation, not legal advice, AWS authorization, or a warranty that AWS will classify every future workload the same way.

## Activity and ownership

The benchmark sends ordinary HTTP `GET` requests from one temporary EC2 load generator to the parking API task in an ECS cluster in the same AWS account, region, VPC, and Availability Zone. The destination is the benchmark operator's own application; the task is reached by its private IP. The generated traffic is not sent to AWS service endpoints, other customers, or third-party systems.

The application is a small Go `net/http` service with an in-memory counter. The measured endpoints are `GET /health` and `GET /spots`; they return normal HTTP responses (`204` and `200`). The harness does not perform vulnerability scanning, credential attacks, malformed-packet generation, reflection/amplification, port flooding, or multi-source traffic generation. It is intended as an application-capacity/load test, not as a DDoS simulation.

## AWS policies reviewed

- [AWS Acceptable Use Policy](https://aws.amazon.com/aup/): prohibits use that violates the security, integrity, or availability of a user, network, system, or application. This benchmark is bounded to the operator's own private ECS task.
- [Amazon EC2 Testing Policy](https://aws.amazon.com/ec2/testing/): describes a network stress/load test as legitimate or test traffic to a specific intended application that is expected to handle it. It recommends keeping an AWS-hosted target in the local AWS Region. This benchmark uses one generator and a same-VPC/same-AZ private task endpoint. AWS notes it may traffic-shape at very high network rates (25 Gbit/s or 100 Gbit/s depending on path); the recorded `/spots` response throughput was about 4.08 MB/s, roughly 0.033 Gbit/s.
- [AWS Penetration Testing Policy](https://aws.amazon.com/security/penetration-testing/): directs customers performing network stress/load tests to the EC2 Testing Policy and distinguishes these from DDoS simulation testing.
- [AWS DDoS Simulation Testing Policy](https://aws.amazon.com/security/ddos-simulation-testing/): applies to DDoS simulations, which are subject to separate requirements and limits. It is not the test type this harness is designed to perform. The measured application request rate exceeded 50,000 requests/s, so that figure is recorded explicitly rather than conflated with the DDoS-simulation request limit. If a future test is intended to simulate DDoS, uses multiple traffic sources, targets anything beyond this owned application, or its classification is uncertain, stop and ask AWS Support/account team before running it.

## Completed baseline run

- Run report: [`../benchmarks/runs/20260928T032108Z.md`](../benchmarks/runs/20260928T032108Z.md)
- Source revision: `03bf706`
- Region/AZ: `us-east-1` / `us-east-1a`

- One `m9g.2xlarge` load generator (`8` vCPU, `32` GiB) sent traffic directly to one `m9g.xlarge` ECS Managed Instance (`4` vCPU, `16` GiB).
- ECS task reservation: `1` vCPU and `2` GiB; On-Demand; private task IP; no ALB or NAT Gateway.
- Tool: `hey v0.1.4`; 64 concurrent workers; 30 seconds per GET endpoint; no separate warm-up.
- Results: `/health` ≈ `102,972` requests/s (204); `/spots` ≈ `91,904` requests/s (200), p95 `0.4 ms` for both.
- This baseline kept ECS desired count at one. It did **not** test saturation, scale-out, or autoscaling.

`hey` caps latency/status samples at one million responses. The recorded requests/s covers the full test duration; estimated request totals and sample limitations are called out in the run report. The JSON/CSV/log artifacts remain in the ignored local `results/` directory; the Markdown run report is the durable, public record.

## Prepared follow-up (not yet run)

The next-round code configures ECS Service Auto Scaling with CPU target tracking at `60%`, minimum `1` and maximum `8` tasks, `30 s` scale-out cooldown, and `300 s` scale-in cooldown. Oha will ramp `/spots` concurrency from `64` to `1,024`, doubling each step, for `60 s` per step with a `60 s` settle period, distributing requests among currently running tasks over private VPC IPs. The load generator remains `m9g.2xlarge`; the ECS instance type remains pinned to `m9g.xlarge`.

This configuration has passed local validation and an OpenTofu plan, but **has not been applied to AWS**. It adds a bounded, single-account scale-out test; it does not turn the benchmark into a DDoS simulation.

## Cleanup evidence

After the completed baseline run, the OpenTofu state was empty; checks found no benchmark EC2 instances, VPC, load balancer, ECR repository, volume, or generated key pair. ECS cluster/capacity-provider records remained `INACTIVE` with zero active services/tasks. The next run must repeat the same post-destroy audit; AWS billing may report already-incurred usage later.
