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

## Completed internal-ALB autoscaling run

- Run report: [`../benchmarks/runs/20260929T141726Z.md`](../benchmarks/runs/20260929T141726Z.md)
- Source revision: `ff383c9`
- Traffic entered an **internal ALB** on HTTP port `80`, forwarding to ECS private task IPs on port `8080`. The ALB used private subnets in two AZs; ECS Managed Instances and the load generator remained in `us-east-1a`. The API was not exposed to the public internet.
- Oha ramped `/spots` through five continuous `120 s` stages at `64`, `128`, `256`, `512`, and `1,024` concurrent connections. The ECS CPU target was `60%`, min/max task counts were `1/8`, with `30/300 s` scale-out/in cooldowns.
- The run scaled from one to two ECS tasks by the end of the highest-concurrency stage; Managed Instance host count remained one. Throughput rose from `15.1k` requests/s at 64 connections to `101.3k` at 1,024. All `34.4M` requests returned HTTP `200`, with zero transport errors. At 1,024 connections, p95 was `76.4 ms` and p99 was `81.9 ms`.
- ECS service CPU one-minute averages peaked at approximately `99.9%` (maximum datapoint `100%`). This shows the sustained ramp produced the high CPU signal missing from the prior run, with scale-out observable by the final stage.

This remained a bounded, single-account application-capacity test, not a DDoS simulation. The ALB incurred billable load-balancer hours and LCU usage during the run.

## Completed Go 1.27.1 internal-ALB run

- Run report: [`../benchmarks/runs/20260929T230553Z.md`](../benchmarks/runs/20260929T230553Z.md)
- Source revision: `4994144`
- Go `1.27.1`, Oha `1.16.0`, same internal-ALB HTTP:80 → task HTTP:8080 path and continuous `120 s` concurrency ramp.
- It reached `74.8k` req/s at 1,024 connections (`p95 65.4 ms`, `p99 78.2 ms`). All `27.8M` requests returned HTTP `200`, with zero transport errors.
- Across the measured Oha stages, desired/running tasks and Managed Instance hosts remained at `1/1/1`. CloudWatch service CPU one-minute averages peaked at `99.9%`.
- The target-tracking high alarm entered `ALARM` at `2026-09-29T23:21:43.484Z` after three >60% datapoints (23:16–23:18 UTC). Application Auto Scaling successfully set desired tasks to `2` at `23:21:43.675Z`, about 3.5 seconds after the load window ended (`23:21:40.201Z`); that scaling activity completed at `23:22:19.678Z`.
- Thus target tracking did act, but only after the last Oha stage. The harness's stage snapshots show one task and it did not poll task/target health during the post-load CloudWatch wait, so it is unknown whether the second task became healthy before teardown. The observed 74.8k req/s did not include a measured scale-out interval.
- The earlier Go 1.24 ALB run reached `101.3k` req/s and showed two tasks at its final sample. Because that earlier stage included scale-out while this run stayed at one task, the two end-to-end totals do not isolate a Go-version regression.

The run remains a bounded, single-account application-capacity test, not a DDoS simulation. It incurred ALB-hours and LCU usage while running.

## Completed eight-task throughput run

- Run report: [`../benchmarks/runs/20261001T205742Z.md`](../benchmarks/runs/20261001T205742Z.md)
- Source revision: `26bb89a`; region/AZ `us-east-1` / `us-east-1a`.
- Eight ECS tasks were held at the configured min/max of `8`, placed across two `m9g.xlarge` Managed Instance hosts. One `m9g.2xlarge` runner drove the internal ALB with Oha 1.16.0, using 120-second stages from 64 through 8,192 connections.
- Peak: `569.1k` req/s at 4,096 connections; the 8,192-connection stage yielded `548.0k` req/s. All `252.6M` requests returned HTTP 200 with zero transport errors. The initial `598.6k` estimate (eight times the earlier 74.8k single-task result) was an extrapolation; the measured peak was about 5% below it.
- CloudWatch `AWS/ApplicationELB/CapacityUtilization` reached 100% for seven consecutive minutes at the high load. AWS documents this as a possible indicator that demand briefly exceeded the ALB's automatic scaling capacity. No LCU reservation was configured. There were no reported ALB rejected connections, ALB 5XXs, or target connection errors.
- The runner's available five-minute EC2 CPU samples peaked at 68.4%; CPU saturation of the load generator was not observed, though this does not rule out network/socket/Oha limits. ECS service CPU maximum reached 100%. The result therefore indicates both target-side CPU pressure and a possible ALB capacity constraint; it does not isolate either as the sole ceiling.
- The retry required the existing ECS teardown recovery path after the first destroy attempt. The final audit confirmed empty OpenTofu state, no benchmark VPC, active instances, ENIs, ALB, ECR repository, log group, ECS services, tasks, or active container instances. ECS retains only inactive cluster metadata; terminated runner records remain in EC2 history.

This was ordinary bounded application load against the operator-owned service, not a DDoS simulation. AWS charges already incurred may appear on a later bill.

## Cleanup evidence

After the baseline, direct autoscaling, interrupted Go 1.27.1 attempt, and completed internal-ALB runs, OpenTofu state was empty. AWS audits found no benchmark EC2 instances, VPCs, load balancers, target groups, ECR repositories, security groups, network interfaces, EBS volumes, IAM roles/instance profiles, autoscaling targets/policies, CloudWatch alarms/log groups, generated key pair, or task-definition revisions. ECS retains only the cluster as `INACTIVE` metadata and its capacity provider as `INACTIVE` with `DELETE_COMPLETE`; there are zero active services, tasks, or container instances, and neither is listed as active. These ECS control-plane tombstones have no running/billable resources. The direct autoscaling run and both Go 1.27.1 attempts needed ECS drain/deregistration recovery; OpenTofu destroy ultimately completed. AWS billing may report already-incurred usage later.
