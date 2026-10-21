# Rust migration performance suite

Suite compares checksum-frozen C oracle with production Rust engine under same
Ubuntu 24.04 image, media workload, process sampler, and decision model. It is
non-SDI; physical DeckLink validation uses `docs/migration/SDI_MANUAL_SIGNOFF.md`.

## Decision gates

`thresholds.json` is approved no-regression contract. Rust must deliver at
least 99% C throughput, add no packet loss, use no more than 110% CPU, 115%
peak RSS, 110% latency, 110% startup time, or 110% failover gap. Any metric
coefficient of variation above 5% makes result inconclusive and requires more
repetitions; it cannot be manually overridden.

## Local tests and dry run

```bash
python3 -m unittest discover -s benchmarks/migration/tests -v
python3 benchmarks/migration/scripts/run_benchmark.py \
  --c-engine native/archive/c-engine/build/blackgate_pipeline \
  --rust-engine native/build/blackgate-engine \
  --workload benchmarks/migration/workloads/srt-1080p25-5m.json \
  --output /tmp/blackgate-benchmark-plan \
  --dry-run
```

`--quick` reduces one workload to one repetition with 0.5-second warm-up and
three-second measurement. Quick results prove lifecycle integration only; they
are not migration sign-off evidence.

## Ubuntu 24.04 image

```bash
docker build --platform linux/amd64 \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -f benchmarks/migration/Dockerfile.ubuntu-24.04 \
  -t blackgate-migration-bench:ubuntu-24.04 .

benchmark_image_digest="$(docker image inspect \
  blackgate-migration-bench:ubuntu-24.04 --format '{{.Id}}')"
docker run --rm --network host --privileged \
  -e BLACKGATE_BENCH_IMAGE_DIGEST="$benchmark_image_digest" \
  -v "$PWD/benchmarks/migration/results:/results" \
  blackgate-migration-bench:ubuntu-24.04 \
  --c-engine /opt/blackgate/engines/blackgate_pipeline \
  --rust-engine /opt/blackgate/engines/blackgate-engine \
  --all --output /results
```

Full run executes six normal workloads, each with 30-second warm-up, 120-second
measurement, and three repetitions per engine. Each engine receives an
unmeasured three-second preflight to remove cold-start bias. Measured runs are
interleaved C then Rust per repetition to limit thermal and time drift. CPU and
peak RSS exclude the warm-up window. Run `non-sdi-soak.json` separately for
one-hour-per-engine stability evidence.

**What `packet_loss_delta` can and cannot see.** The frozen C oracle reads `srtsrc`'s
`packets-received-lost` / `-dropped` / `-retransmitted` with `gst_structure_get_int64`, but
GStreamer stores those as `int` (gint32): the strict type check fails, the getter's FALSE return
is ignored, and the counters stay 0 for the life of the connection. A C-side loss regression
therefore cannot show up in this metric, and a "C reports 0 lost, Rust reports N" result is that
bug, not a Rust regression. Fixing it means versioning the oracle (new manifest), which is a
recorded decision, not a bug fix.

**Pipeline shape is part of the comparison.** Both engines must run the same pipeline or the ratios
mean nothing. The frozen C oracle has no `preview` key and builds its thumbnail branch whenever
`argv[1]` (the route id) is non-empty (`gst_pipeline.c:884`); it takes the route id from argv, never
from the init JSON. The Rust engine builds its preview branch only for `"preview": true`. So
`build_plan()` blanks the C's route-id argument for workloads that do not set `"thumbnail": true`,
and adds `"preview": true` to the Rust init for the ones that do. On bare metal that branch costs
21.5 MB -> 72.2 MB RSS and 6.0 % -> 8.0 % CPU, and its internal state varies run to run — which is
what failed the C's own CV gate in the 2026-10-20 bare-metal run (3 workloads `inconclusive` while
all 42 metrics passed). Every run now asserts the branch is present exactly when the workload asks
for it. Results recorded before this change (`results/verdict-2026-10-17-local-vm` and
`results/baremetal-2026-10-20`) compare a C run that paid for the branch against a Rust run that did
not, so their `peak_rss_ratio` and `cpu_ratio` are flattered in Rust's favour and are not comparable
with runs made after it.

Each run directory contains raw engine JSON, socket/stdout/stderr evidence,
per-workload comparisons, `summary.json`, and `REPORT.md`. Runner exits nonzero
for failed or inconclusive comparisons.

When a full result is inconclusive because variance exceeds 5%, rerun that
workload with additional samples instead of overriding the decision:

```bash
python3 benchmarks/migration/scripts/run_benchmark.py \
  --c-engine /opt/blackgate/engines/blackgate_pipeline \
  --rust-engine /opt/blackgate/engines/blackgate-engine \
  --workload benchmarks/migration/workloads/dual-ingest-failover.json \
  --repetitions 7 --output /results/dual-ingest-rerun
```
