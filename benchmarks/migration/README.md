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
