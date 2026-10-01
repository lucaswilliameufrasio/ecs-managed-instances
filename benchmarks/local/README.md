# Local performance suite

The local suite measures the Go handlers and the release HTTP path before another AWS run. It does not provision AWS resources or use an ALB.

## Tool versions

Project-local versions are pinned in `.mise.toml`:

- Go `1.27.1`, matching the pinned Docker builder image.
- Rust `1.98.1`, used to build the Mise-managed Oha crate.
- Oha `1.16.0`, matching the AWS load generator.

Install and verify the tools without changing global Mise settings:

```bash
mise install
mise exec -- go version
"$(mise where cargo:oha)/bin/oha" --version
```

## Run

```bash
./scripts/run-local-performance.sh
```

The defaults run handler microbenchmarks five times and collect CPU/heap/mutex/block profiles. The HTTP sweep runs the Go 1.27.1 release binary natively, pins it to one CPU, and pins Oha to up to eight different CPUs to avoid a shared-core load generator. It measures `/health` and `/spots` for three 10-second samples at each concurrency from 64 through 4,096, repeating with `GOMAXPROCS=1` and `GOMAXPROCS=4`. It records CPU/RSS for both the API and load generator and process-scoped `perf stat` counters, then starts a separate profile-enabled process for an application-level Go CPU profile under Oha traffic. RSS is observed but not cgroup-limited. This direct loopback path avoids rootless Docker's host-port forwarding overhead.

To test capacity above the one-vCPU baseline, assign multiple app CPUs and distinct CPUs to Oha. CPU IDs below match this host; choose two disjoint sets from `Cpus_allowed_list` in `/proc/self/status` on another machine:

```bash
LOCAL_PERF_APP_CPUS="0-1" LOCAL_PERF_OHA_CPUS="2-9" \
LOCAL_PERF_ENDPOINTS="spots" LOCAL_PERF_GOMAXPROCS="2" \
LOCAL_PERF_CONCURRENCIES="64 128 256 512 1024 2048 4096" \
./scripts/run-local-performance.sh
```

The multi-CPU run is an aggregate local-process capacity check; keep the default one-CPU run for comparison with a single ECS task reservation.

A preliminary rootless-Docker sweep is retained at [`20260929T165002Z.md`](20260929T165002Z.md) for comparison. It plateaued around 50–64k req/s while the app used roughly 70% of one CPU; its profile was heavy in syscall/net/http paths. That points to the rootless forwarding path as a confounder, so those rates are not treated as the Go API's ceiling.

The historical single-CPU native run is [`20260929T175318Z.md`](20260929T175318Z.md): `/spots` peaked at 83k req/s at 64 connections. Current pooled-serializer runs: [`20261001T142801Z.md`](20261001T142801Z.md) (2 app CPUs, 158.6k req/s at 256 connections), [`20261001T143525Z.md`](20261001T143525Z.md) (3 app CPUs, median 201.6k at 64 and 177k at 1,024 connections), and [`20261001T144339Z.md`](20261001T144339Z.md) (8 app CPUs, median 277–323k across 64–4,096 connections). All had zero request errors. These are local x86_64 aggregate-capacity measurements; AWS workers are Graviton ARM64, so absolute rates are not directly comparable. The live profile remains syscall-dominated.

Customize the screening duration/repetitions or concurrency matrix with:

```bash
LOCAL_PERF_DURATION_SECONDS=15 LOCAL_PERF_REPEATS=2 \
LOCAL_PERF_CONCURRENCIES="64 128 256 512 1024 2048 4096" \
LOCAL_PERF_GOMAXPROCS="1 4" ./scripts/run-local-performance.sh
```

The project default stays on Go `1.27.1`. To compare the earlier builder runtime against it on the same pinned local HTTP path without changing `.mise.toml`, run the same short matrix once per version:

```bash
LOCAL_PERF_GO_VERSION=1.24.13 LOCAL_PERF_ENDPOINTS="spots" \
LOCAL_PERF_CONCURRENCIES="64 128 256 512 1024 2048" \
LOCAL_PERF_DURATION_SECONDS=10 LOCAL_PERF_REPEATS=3 \
./scripts/run-local-performance.sh

LOCAL_PERF_GO_VERSION=1.27.1 LOCAL_PERF_ENDPOINTS="spots" \
LOCAL_PERF_CONCURRENCIES="64 128 256 512 1024 2048" \
LOCAL_PERF_DURATION_SECONDS=10 LOCAL_PERF_REPEATS=3 \
./scripts/run-local-performance.sh
```

Each run writes raw outputs and profiles to ignored `results/local/<run-id>/` and a durable summary to `benchmarks/local/<run-id>.md`. The report deliberately records the throughput/latency curve rather than enforcing an RPS threshold. Docker, kernel/perf, and eBPF availability are recorded; the script does not modify kernel settings or require AWS credentials.

To inspect an interactive Go profile and its Flame Graph view, open it locally with:

```bash
mise exec -- go tool pprof -http=127.0.0.1:0 results/local/<run-id>/http-spots.cpu.pprof
```

Text top reports are generated beside the pprof files. The profile-enabled native process is used only for the diagnostic pass; the throughput process does not set `ENABLE_PPROF`. Its pprof listener binds only to host loopback. The local x86_64 measurements help identify code/runtime bottlenecks but are not directly comparable to AWS Graviton ARM64 throughput.
