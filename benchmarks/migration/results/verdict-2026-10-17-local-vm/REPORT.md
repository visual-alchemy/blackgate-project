# Blackgate C versus Rust performance report

Overall state: FAIL

## Environment

| Field | Value |
| --- | --- |
| Ubuntu image digest | local |
| Kernel | Linux dvls 6.8.0-147-generic #147-Ubuntu SMP PREEMPT_DYNAMIC Thu Sep 24 11:33:16 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux |
| CPU | Architecture:                            x86_64
CPU op-mode(s):                          32-bit, 64-bit
Address sizes:                           39 bits physical, 48 bits virtual
Byte Order:                              Little Endian
CPU(s):                                  4
On-line CPU(s) list:                     0-3
Vendor ID:                               GenuineIntel
Model name:                              Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz
CPU family:                              6
Model:                                   158
Thread(s) per core:                      1
Core(s) per socket:                      2
Socket(s):                               2
Stepping:                                9
BogoMIPS:                                7200.00
Flags:                                   fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss ht syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon rep_good nopl xtopology cpuid tsc_known_freq pni pclmulqdq vmx ssse3 fma cx16 pdcm pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch cpuid_fault pti tpr_shadow flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 hle avx2 smep bmi2 erms invpcid rtm mpx rdseed adx smap clflushopt xsaveopt xsavec xgetbv1 xsaves arat vnmi umip arch_capabilities
Virtualization:                          VT-x
Hypervisor vendor:                       KVM
Virtualization type:                     full
L1d cache:                               128 KiB (4 instances) |
| Rust | rustc 1.96.0 (ac68faa20 2026-05-25) |
| FFmpeg | ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023 the FFmpeg developers |
| Git commit | 670a87888a09b5e99bd413bd99e8f79cbc88e8a0 |
| Started | 2026-10-17T16:35:00.344868+00:00 |
| Finished | 2026-10-17T18:07:39.424504+00:00 |

## dual-ingest-failover

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 6.176022 | 4.490502 | 0.727087 | <= 1.100000 | yes |
| failover_gap_ratio | 50.461123 | 50.442807 | 0.999637 | <= 1.100000 | yes |
| latency_ratio | 0.054000 | 0.058000 | 1.074074 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 87326720.000000 | 22351872.000000 | 0.255957 | <= 1.150000 | yes |
| startup_ratio | 252.303317 | 252.120883 | 0.999277 | <= 1.100000 | yes |
| throughput_ratio | 9.713232 | 9.713172 | 0.999994 | >= 0.990000 | yes |

Reasons:

- Rust latency_ms coefficient of variation 0.175421 exceeds 0.050000

## srt-1080p25-5m

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 9.656550 | 8.024781 | 0.831019 | <= 1.100000 | yes |
| failover_gap_ratio | 0.000000 | 0.000000 | 1.000000 | <= 1.100000 | yes |
| latency_ratio | 0.056500 | 0.055000 | 0.973451 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 86659072.000000 | 23265280.000000 | 0.268469 | <= 1.150000 | yes |
| startup_ratio | 251.560218 | 251.660325 | 1.000398 | <= 1.100000 | yes |
| throughput_ratio | 5.456090 | 5.456632 | 1.000099 | >= 0.990000 | yes |

Reasons:

- C cpu_percent coefficient of variation 0.086971 exceeds 0.050000
- C peak_rss_bytes coefficient of variation 0.106652 exceeds 0.050000

## srt-1080p50-25m

Decision: PASS

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 19.249904 | 17.947551 | 0.932345 | <= 1.100000 | yes |
| failover_gap_ratio | 0.000000 | 0.000000 | 1.000000 | <= 1.100000 | yes |
| latency_ratio | 0.055000 | 0.055000 | 1.000000 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 81227776.000000 | 29581312.000000 | 0.364177 | <= 1.150000 | yes |
| startup_ratio | 251.659087 | 251.660009 | 1.000004 | <= 1.100000 | yes |
| throughput_ratio | 26.764902 | 26.766265 | 1.000051 | >= 0.990000 | yes |

## srt-three-destinations

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 20.095205 | 18.461478 | 0.918701 | <= 1.100000 | yes |
| failover_gap_ratio | 0.000000 | 0.000000 | 1.000000 | <= 1.100000 | yes |
| latency_ratio | 0.046000 | 0.047000 | 1.021739 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 90750976.000000 | 26947584.000000 | 0.296940 | <= 1.150000 | yes |
| startup_ratio | 252.259497 | 252.175734 | 0.999668 | <= 1.100000 | yes |
| throughput_ratio | 9.715199 | 9.713830 | 0.999859 | >= 0.990000 | yes |

Reasons:

- C peak_rss_bytes coefficient of variation 0.096725 exceeds 0.050000

## srt-thumbnail

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 3.301046 | 2.608115 | 0.790087 | <= 1.100000 | yes |
| failover_gap_ratio | 0.000000 | 0.000000 | 1.000000 | <= 1.100000 | yes |
| latency_ratio | 0.062000 | 0.059000 | 0.951613 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 67588096.000000 | 19845120.000000 | 0.293619 | <= 1.150000 | yes |
| startup_ratio | 251.583202 | 251.743796 | 1.000638 | <= 1.100000 | yes |
| throughput_ratio | 9.715381 | 9.713848 | 0.999842 | >= 0.990000 | yes |

Reasons:

- C cpu_percent coefficient of variation 0.238412 exceeds 0.050000
- C peak_rss_bytes coefficient of variation 0.094283 exceeds 0.050000

## udp-to-srt

Decision: INCONCLUSIVE

| Metric | C median | Rust median | Observed | Gate | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cpu_ratio | 10.153498 | 9.778761 | 0.963093 | <= 1.100000 | yes |
| failover_gap_ratio | 0.000000 | 0.000000 | 1.000000 | <= 1.100000 | yes |
| latency_ratio | 0.053500 | 0.015000 | 0.280374 | <= 1.100000 | yes |
| packet_loss_delta | 0.000000 | 0.000000 | 0.000000 | <= 0.000000 | yes |
| peak_rss_ratio | 23359488.000000 | 20520960.000000 | 0.878485 | <= 1.150000 | yes |
| startup_ratio | 251.692064 | 251.654419 | 0.999850 | <= 1.100000 | yes |
| throughput_ratio | 9.633066 | 9.633389 | 1.000034 | >= 0.990000 | yes |

Reasons:

- Rust latency_ms coefficient of variation 0.127108 exceeds 0.050000
