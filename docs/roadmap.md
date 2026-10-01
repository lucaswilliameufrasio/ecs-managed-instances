# Benchmark roadmap

## Next: characterize load-generator network and socket limits

Before another AWS throughput run, improve the harness to record per-stage load-generator signals alongside Oha results:

- Oha process CPU/RSS and host CPU utilization per core.
- Network bytes and packets per second on the runner interface.
- TCP retransmits and other TCP/IP error counters; socket-state counts, open file descriptors, and ephemeral-port usage.
- EC2/ENA network allowance-exceeded counters where available, with collection resolution and missing metrics stated explicitly.
- Keep the samples timestamped so they can be aligned with each concurrency stage and ALB/ECS metrics.

Use a bounded follow-up run only after this instrumentation is in place and reviewed. The previous eight-task run's runner showed about `125 MB/s` inbound and outbound in peak five-minute CloudWatch samples, but those coarse samples and absent allowance-exceeded datapoints do not establish whether networking or sockets constrained Oha. The local loopback report showed Oha at `94%` peak CPU and a syscall-dominated API profile; those are diagnostic clues, not proof of the AWS load generator's limit.

## Deferred: ALB LCU-reservation comparison

Do not enable or test an ALB LCU reservation as the next step. Reconsider only after load-generator constraints have been characterized and after explicitly reviewing the reservation size and cost. The prior unreserved run recorded `PeakLCUs = 6,385`; at the published us-east-1 example rate of `$0.008` per reserved LCU-hour, a reservation around 6,400 LCUs would be about `$51.20` per reserved hour, before the ALB hourly charge and any usage above the reservation. This is a planning estimate, not approval to incur the cost.

## Interpretation guardrail

Treat benchmark throughput as the capacity of the **tested end-to-end path under the recorded configuration**, not as a universal maximum for the application or infrastructure. A valid capacity claim requires evidence that the load generator and ingress are not limiting, plus a defined success/latency/error criterion and sustained measurements at the target task count. Do not infer capacity by multiplying a single-task result by task count.
