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

## Completed autoscaling run

- Run report: [`../benchmarks/runs/20260928T163422Z.md`](../benchmarks/runs/20260928T163422Z.md)
- Source revision: `2531da6`
- Oha 1.16.0 ramped `/spots` concurrency from `64` to `1,024`, doubling each step, with `60 s` load and `60 s` no-load settle per step.
- ECS Service Auto Scaling target was `60%` CPU, minimum `1` and maximum `8` tasks, `30 s` scale-out cooldown, and `300 s` scale-in cooldown. The load generator was `m9g.2xlarge`; the ECS Managed Instance type was pinned to `m9g.xlarge`.
- Traffic remained ordinary HTTP requests from one load generator to the operator-owned private task in the same VPC/AZ. No ALB or NAT Gateway was used.
- The run did not scale out: desired/running tasks and Managed Instance hosts remained at one. It reached approximately `84–87k` requests/s, with p99 latency rising to approximately `82 ms` at the highest concurrency. CloudWatch one-minute service CPU averages ranged approximately `33–67%`, with maxima near `99–100%`.
- The 60-second no-load intervals may have weakened the sustained target-tracking signal, but the run does not establish the cause of the missing scale-out.

## Prepared next attempt (not yet run)

The next run is configured to send traffic through an **internal ALB**: an HTTP listener on port `80` forwards to the ECS service's private task IPs on port `8080`, with `/health` returning `204`. The ALB uses private subnets in two AZs; ECS Managed Instances and the load generator remain in the existing single AZ. The API remains inaccessible from the public internet. The ramp uses five continuous `120 s` load steps at `64`, `128`, `256`, `512`, and `1,024` Oha connections, without intentional no-load gaps. It will collect one-minute ECS CPU metrics after the ramp, with a `90 s` CloudWatch metric-settle period. The autoscaling target and instance sizing remain unchanged. This is intended to provide a more sustained scaling signal and diagnostic CPU data; it does not guarantee scale-out.

The revised configuration **has not yet been applied to AWS**. It remains a bounded, single-account application-capacity test and does not turn the benchmark into a DDoS simulation. The ALB adds billable load-balancer hours and LCU usage for the duration of the run.

## Cleanup evidence

After the baseline and autoscaling runs, teardown audits found empty OpenTofu state, no active benchmark EC2/VPC/load-balancer/ECR resources, and only inactive ECS metadata with no active services/tasks. The autoscaling run required manual ECS drain/deregistration recovery and a retry of OpenTofu destroy; see its run report. The next run must repeat the post-destroy audit. AWS billing may report already-incurred usage later.
