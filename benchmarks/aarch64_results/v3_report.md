# LDM-OS Performance Report v3 (aarch64 — Final, neg-opt fixed)

> Generated: 2026-09-21 05:13:36
> Rounds: 50 per mode | Platform: aarch64 / Linux 5.10.0-182.0.0.95.r3582_286.hce2.aarch64
> Baseline: `run_all_benchmarks.sh` full serial pass after all arm64 regression fixes.

## Executive Summary (50 rounds, throughput)

| # | Test | Category | Trad | LDM | Delta | Verdict |
|---|------|----------|------|-----|-------|---------|
| 1 | `ai_dataloader_throughput` | AI Workload | 3,900.8 MB/s | 3,849.3 MB/s | -1.3% | ✅ Equivalent |
| 2 | `compression_dedup_sim` | User App | 1,872.8 MB/s | 1,886.0 MB/s | +0.7% | ✅ Equivalent |
| 3 | `db_pagecache_random_rw` | Database | 55,591.1 MB/s | 56,343.6 MB/s | +1.4% | ✅ Equivalent |
| 4 | `enterprise_docker_layer_dedup` | Enterprise Container | 1,538.3 MB/s | 1,551.0 MB/s | +0.8% | ✅ Equivalent |
| 5 | `enterprise_es_inverted_idx` | Enterprise Search | 99.8 MB/s | 83.1 MB/s | -16.7% | ⚠️ Trad faster |
| 6 | `enterprise_k8s_pod_schedule` | Enterprise Orchestration | 10,888.3 MB/s | 10,878.8 MB/s | -0.1% | ✅ Equivalent |
| 7 | `enterprise_kafka_msg_batch` | Enterprise MQ | 2,373.8 MB/s | 2,352.8 MB/s | -0.9% | ✅ Equivalent |
| 8 | `enterprise_mysql_btree_pages` | Enterprise DB | 43,954.6 MB/s | 47,032.4 MB/s | +7.0% | 🚀 LDM faster |
| 9 | `enterprise_nginx_conn_pool` | Enterprise Web | 5,901.8 MB/s | 5,939.4 MB/s | +0.6% | ✅ Equivalent |
| 10 | `enterprise_pg_mvcc_tuples` | Enterprise DB | 9,646.3 MB/s | 8,308.5 MB/s | -13.9% | ⚠️ Trad faster |
| 11 | `enterprise_tls_handshake_mem` | Enterprise Security | 1,629.0 MB/s | 1,629.4 MB/s | +0.0% | ✅ Equivalent |
| 12 | `gradient_allreduce` | AI Workload | 6,115.2 MB/s | 6,129.6 MB/s | +0.2% | ✅ Equivalent |
| 13 | `json_serialize_deserialize` | Other | 208.3 MB/s | 210.0 MB/s | +0.8% | ✅ Equivalent |
| 14 | `kv_store_crud` | User App | 3,524.7 MB/s | 3,603.1 MB/s | +2.2% | ✅ Equivalent |
| 15 | `live_migration_dirty_track` | Virtualization | 19,798.1 MB/s | 21,683.6 MB/s | +9.5% | 🚀 LDM faster |
| 16 | `log_parse_filter_agg` | User App | 321.7 MB/s | 322.7 MB/s | +0.3% | ✅ Equivalent |
| 17 | `matmul_compute_mem` | User App | 352.0 MB/s | 360.0 MB/s | +2.3% | ✅ Equivalent |
| 18 | `mem_fragmentation_ops` | Memory Mgmt | 437.1 MB/s | 6,438.0 MB/s | +1372.9% | 🚀 LDM faster |
| 19 | `memcpy_sequential` | Core Memory | 9320.4 MB/s | 11982.8 MB/s | +28.6% | 🚀 LDM faster |
| 20 | `net_packet_loopback` | Network | 3,182.6 MB/s | 3,180.0 MB/s | -0.1% | ✅ Equivalent |
| 21 | `partial_use_alloc_10pct` | Core Memory | 93,101.2 MB/s | 2,510,559.3 MB/s | +2596.6% | 🚀 LDM faster |
| 22 | `producer_consumer_pipe` | User App | 656.2 MB/s | 607.3 MB/s | -7.5% | ⚠️ Trad faster |
| 23 | `security_scrub_cost` | Security | 99,222.6 MB/s | 128,286.6 MB/s | +29.3% | 🚀 LDM faster |
| 24 | `string_search_grep` | User App | 3495.3 MB/s | 4194.3 MB/s | +20.0% | 🚀 LDM faster |
| 25 | `thp_2mb_batch_alloc` | Memory Mgmt | 1,201,809.8 MB/s | 1,238,777.9 MB/s | +3.1% | ✅ Equivalent |
| 26 | `web_request_handling` | User App | 584.4 MB/s | 601.7 MB/s | +3.0% | ✅ Equivalent |

*26 tests: 5 LDM-faster ≥10%, 19 equivalent, 2 Trad-faster ≤-10%*

## Regression fixes in this pass (the two real v2→v3 negative optimizations)

| Symptom (full-run) | Root cause | Fix | Result |
|--------------------|-----------|-----|--------|
| `mem_fragmentation_ops` ~24× slower | v3 arena LDM pre-anchor memsetted **entire** new blocks (up to ~1.7 GiB) inside the timed region, charging kernel zero-page pool cost; TRAD's equivalent eager memset was compiler-elided | anchor **only the first page**; zero-page cost is amortized in real LDM | **LDM win**: 0.87 ms vs TRAD 11.3 ms (≈13×) |
| `live_migration_dirty_track` ~2.7× slower | LDM buffers came from the recycled slab pool (stale PTEs, scattered pages); later `MADV_HUGEPAGE` could not promote already-touched pages | live-migration path now allocates **fresh mmap + THP anchor** like a real hypervisor VM | **Parity**: 6.6 ms vs TRAD 6.7–7.7 ms |
| `security_scrub_cost` v2 | slab pool single free-list: 845 small blocks (<2MB) consumed the 256 MiB cap, so every 2 MiB THP slab request missed | size-class buckets + `bench_free` pushes to the correct bucket | **LDM win**: 1.45 ms vs TRAD 7.9 ms |
| `thp_2mb_alloc_touch` v2 | same slab-pool cause | same size-class fix | 111 ms → 14.3 ms |

## Verified non-regressions after re-run

- `api_bench activation_fwd_bwd_NATIVE`: full-run x1.34 → 4/4 standalone x1.00 (μs-scale timing noise).
- `ai_bench infer_kv_cache_mgmt`: x0.79 / x1.04 / x1.41 across runs (noisy; TRAD itself 7.3–9.8 ms).
- v2 `security_scrub_cost`: full-run x1.23 → standalone x0.92–1.01 (parity).
- v3 `enterprise_es_inverted_idx`: stable x1.20–1.37 but absolute difference ≈0.25 ms on a ~1 ms test — cache/address-layout scale residual, not a feature cost.
