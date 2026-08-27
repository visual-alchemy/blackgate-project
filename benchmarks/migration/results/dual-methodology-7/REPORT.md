# Blackgate C versus Rust performance report

Overall state: FAIL

## Environment

| Field | Value |
| --- | --- |
| Ubuntu image digest | sha256:d2f0dabe7fc920a78f6bd1119c1e3dd10bde6f19e0ce410cf6a7e8334592296a |
| Kernel | Linux orbstack 7.0.14-orbstack-00380-ga7e0a2dc9535 #1 SMP PREEMPT Fri Aug  7 03:48:40 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux |
| CPU | Architecture:                            x86_64
CPU op-mode(s):                          32-bit
Byte Order:                              Little Endian
CPU(s):                                  8
On-line CPU(s) list:                     0-7
Vendor ID:                               Apple
Model name:                              -
Model:                                   0
Thread(s) per core:                      1
Core(s) per socket:                      8
Socket(s):                               1
Stepping:                                0x0
CPU(s) scaling MHz:                      100%
CPU max MHz:                             2000.0000
CPU min MHz:                             2000.0000
BogoMIPS:                                48.00
Flags:                                   fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 asimddp sha512 asimdfhm dit uscat ilrcpc flagm sb dcpodp flagm2 frint i8mm bf16 ecv
L1d cache:                               1 MiB (8 instances)
L1i cache:                               1.5 MiB (8 instances)
L2 cache:                                32 MiB (2 instances) |
| Rust | rustc 1.96.0 |
| FFmpeg | ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023 the FFmpeg developers |
| Git commit | 6cb052d3050e1d4426898214d5ec3845f41bf059 |
| Started | 2026-08-27T17:10:37.958972+00:00 |
| Finished | 2026-08-27T17:46:45.272691+00:00 |

## dual-ingest-failover

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 5.948512 | 5.776545 | 0.971091 | <= 1.100000 | yes |
| failover_gap_ratio | 55.651750 | 54.150455 | 0.973023 | <= 1.100000 | yes |
| latency_ratio | 0.028000 | 0.029000 | 1.035714 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 104775680.000000 | 105410560.000000 | 1.006059 | <= 1.150000 | yes |
| startup_ratio | 359.697219 | 382.495664 | 1.063382 | <= 1.100000 | yes |
| throughput_ratio | 9.708456 | 9.707017 | 0.999852 | >= 0.990000 | yes |

Reasons:

- C cpu_percent coefficient of variation 0.377719 exceeds 0.050000
- C latency_ms coefficient of variation 0.731371 exceeds 0.050000
- C startup_ms coefficient of variation 0.447476 exceeds 0.050000
- Rust cpu_percent coefficient of variation 0.451779 exceeds 0.050000
- Rust latency_ms coefficient of variation 0.778764 exceeds 0.050000
- Rust startup_ms coefficient of variation 0.089233 exceeds 0.050000
