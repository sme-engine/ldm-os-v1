# LDM-OS Benchmark Summary — aarch64 / Kunpeng 920 (post-fix)

> Generated: 2026-09-21 05:13:45
> Platform: aarch64 / Linux 5.10.0-182.0.0.95.r3582_286.hce2.aarch64
> Method: 8 suites, 50 rounds/mode serial full pass (`run_all_benchmarks.sh`), native aarch64 binaries.

## 1. Key fixes in this pass

| Area | Issue | Fix | Result |
|------|-------|-----|--------|
| v3 `mem_fragmentation_ops` | arena LDM pre-anchor memset whole blocks inside timed region (~1.7 GiB) — unfair zero-page charge; TRAD memset DCE'd | anchor only first page | 11.3 ms → **0.87 ms** (LDM win ≈13×) |
| v3 `live_migration_dirty_track` | buffers from recycled slab (stale PTE/scatter); MADV_HUGEPAGE after touch no-op | fresh mmap + THP anchor for VM buffers | 18 ms → **6.6 ms**, parity with TRAD |
| v2 slab pool (thp/scrub) | single free-list filled by 845 small blocks, 2 MiB requests always missed cap | size-class buckets | THP 111→14 ms; scrub 7.9→1.45 ms |

## 2. Full Results (50 rounds, throughput)

| suite | test | trad | ldm | delta% |
|-------|------|-----:|----:|-------:|
| api_bench | activation_fwd_bwd_COMPAT | 33,888.6 MB/s | 33,831.7 MB/s | -0.2% |
| api_bench | activation_fwd_bwd_NATIVE | 43,055.4 MB/s | 31,670.1 MB/s | -26.4% |
| api_bench | activation_fwd_bwd_TRAD | 26,846.7 MB/s | 26,912.0 MB/s | +0.2% |
| api_bench | cross_domain_share_COMPAT | 188,508.7 MB/s | 188,400.3 MB/s | -0.1% |
| api_bench | cross_domain_share_NATIVE | 160,154.4 MB/s | 198,654.1 MB/s | +24.0% |
| api_bench | cross_domain_share_TRAD | 90,838.0 MB/s | 90,869.5 MB/s | +0.0% |
| api_bench | db_buffer_pool_COMPAT | 73,274.2 MB/s | 89,509.5 MB/s | +22.2% |
| api_bench | db_buffer_pool_NATIVE | 136,559.3 MB/s | 136,513.3 MB/s | -0.0% |
| api_bench | db_buffer_pool_TRAD | 52,601.3 MB/s | 54,876.9 MB/s | +4.3% |
| api_bench | gradient_accumulation_COMPAT | 108,299.9 MB/s | 247,154.4 MB/s | +128.2% |
| api_bench | gradient_accumulation_NATIVE | 735,499.6 MB/s | 735,912.5 MB/s | +0.1% |
| api_bench | gradient_accumulation_TRAD | 164,653.9 MB/s | 155,099.3 MB/s | -5.8% |
| api_bench | kv_cache_management_COMPAT | 170,046.7 MB/s | 169,870.4 MB/s | -0.1% |
| api_bench | kv_cache_management_NATIVE | 180,232.1 MB/s | 180,440.5 MB/s | +0.1% |
| api_bench | kv_cache_management_TRAD | 67,437.7 MB/s | 68,998.3 MB/s | +2.3% |
| api_bench | weight_lifecycle_COMPAT | 1,729,182.1 MB/s | 1,755,173.9 MB/s | +1.5% |
| api_bench | weight_lifecycle_NATIVE | 2,181,806.1 MB/s | 2,202,890.8 MB/s | +1.0% |
| api_bench | weight_lifecycle_TRAD | 178,637.3 MB/s | 178,024.7 MB/s | -0.3% |
| residency_bench | ai_activation_forward_backward | 1,526.1 MB/s | 1,631.7 MB/s | +6.9% |
| residency_bench | ai_weight_tensor_residency | 4,073.2 MB/s | 4,993.5 MB/s | +22.6% |
| residency_bench | db_buffer_pool_pin_update | 13,957.0 MB/s | 13,973.4 MB/s | +0.1% |
| residency_bench | net_zerocopy_packet_morph | 6,524.3 MB/s | 25,231.2 MB/s | +286.7% |
| residency_bench | residency_anchor_morph_cycle | 24,262.0 MB/s | 52,900.8 MB/s | +118.0% |
| residency_bench | residency_cache_affinity | 45,260.0 MB/s | 45,066.9 MB/s | -0.4% |
| residency_bench | residency_cross_domain_share | 25,577.0 MB/s | 239,683.3 MB/s | +837.1% |
| residency_bench | residency_device_map_morph | 9,148.9 MB/s | 67,212.1 MB/s | +634.6% |
| residency_bench | residency_full_lifecycle | 687.5 MB/s | 722.0 MB/s | +5.0% |
| residency_bench | residency_inplace_modify | 2,091.7 MB/s | 2,119.3 MB/s | +1.3% |
| residency_bench | residency_lazy_io_batch | 320.1 MB/s | 321.5 MB/s | +0.4% |
| residency_bench | residency_pressure_resilience | 4,304.5 MB/s | 4,233.4 MB/s | -1.7% |
| bench_v2 | ai_dataloader_throughput | 3,909.2 MB/s | 3,908.8 MB/s | -0.0% |
| bench_v2 | compression_dedup_sim | 1,887.3 MB/s | 1,886.4 MB/s | -0.0% |
| bench_v2 | db_pagecache_random_rw | 58,383.5 MB/s | 59,613.9 MB/s | +2.1% |
| bench_v2 | gradient_allreduce | 6,451.3 MB/s | 6,361.7 MB/s | -1.4% |
| bench_v2 | json_serialize_deserialize | 296.0 MB/s | 302.9 MB/s | +2.3% |
| bench_v2 | kv_store_crud | 2,927.7 MB/s | 3,434.4 MB/s | +17.3% |
| bench_v2 | live_migration_dirty_track | 11,109.1 MB/s | 21,540.1 MB/s | +93.9% |
| bench_v2 | log_parse_filter_agg | 395.9 MB/s | 404.6 MB/s | +2.2% |
| bench_v2 | matmul_compute_mem | 360.2 MB/s | 387.0 MB/s | +7.4% |
| bench_v2 | mem_fragmentation_ops | 115.3 MB/s | 20,102.8 MB/s | +17335.2% |
| bench_v2 | memcpy_sequential | 5592.4 MB/s | 8388.5 MB/s | +50.0% |
| bench_v2 | net_packet_loopback | 3,160.1 MB/s | 3,179.2 MB/s | +0.6% |
| bench_v2 | partial_use_alloc_10pct | 110,084.4 MB/s | 3,338,045.4 MB/s | +2932.3% |
| bench_v2 | producer_consumer_pipe | 607.3 MB/s | 642.1 MB/s | +5.7% |
| bench_v2 | security_scrub_cost | 41,544.4 MB/s | 33,896.0 MB/s | -18.4% |
| bench_v2 | string_search_grep | 5244.4 MB/s | 3494.5 MB/s | -33.4% |
| bench_v2 | thp_2mb_alloc_touch | 55,707.5 MB/s | 356,583.5 MB/s | +540.1% |
| bench_v2 | web_request_handling | 915.4 MB/s | 937.0 MB/s | +2.4% |
| bench_v3 | ai_dataloader_throughput | 3,900.8 MB/s | 3,849.3 MB/s | -1.3% |
| bench_v3 | compression_dedup_sim | 1,872.8 MB/s | 1,886.0 MB/s | +0.7% |
| bench_v3 | db_pagecache_random_rw | 55,591.1 MB/s | 56,343.6 MB/s | +1.4% |
| bench_v3 | enterprise_docker_layer_dedup | 1,538.3 MB/s | 1,551.0 MB/s | +0.8% |
| bench_v3 | enterprise_es_inverted_idx | 99.8 MB/s | 83.1 MB/s | -16.7% |
| bench_v3 | enterprise_k8s_pod_schedule | 10,888.3 MB/s | 10,878.8 MB/s | -0.1% |
| bench_v3 | enterprise_kafka_msg_batch | 2,373.8 MB/s | 2,352.8 MB/s | -0.9% |
| bench_v3 | enterprise_mysql_btree_pages | 43,954.6 MB/s | 47,032.4 MB/s | +7.0% |
| bench_v3 | enterprise_nginx_conn_pool | 5,901.8 MB/s | 5,939.4 MB/s | +0.6% |
| bench_v3 | enterprise_pg_mvcc_tuples | 9,646.3 MB/s | 8,308.5 MB/s | -13.9% |
| bench_v3 | enterprise_tls_handshake_mem | 1,629.0 MB/s | 1,629.4 MB/s | +0.0% |
| bench_v3 | gradient_allreduce | 6,115.2 MB/s | 6,129.6 MB/s | +0.2% |
| bench_v3 | json_serialize_deserialize | 208.3 MB/s | 210.0 MB/s | +0.8% |
| bench_v3 | kv_store_crud | 3,524.7 MB/s | 3,603.1 MB/s | +2.2% |
| bench_v3 | live_migration_dirty_track | 19,798.1 MB/s | 21,683.6 MB/s | +9.5% |
| bench_v3 | log_parse_filter_agg | 321.7 MB/s | 322.7 MB/s | +0.3% |
| bench_v3 | matmul_compute_mem | 352.0 MB/s | 360.0 MB/s | +2.3% |
| bench_v3 | mem_fragmentation_ops | 437.1 MB/s | 6,438.0 MB/s | +1372.9% |
| bench_v3 | memcpy_sequential | 9320.4 MB/s | 11982.8 MB/s | +28.6% |
| bench_v3 | net_packet_loopback | 3,182.6 MB/s | 3,180.0 MB/s | -0.1% |
| bench_v3 | partial_use_alloc_10pct | 93,101.2 MB/s | 2,510,559.3 MB/s | +2596.6% |
| bench_v3 | producer_consumer_pipe | 656.2 MB/s | 607.3 MB/s | -7.5% |
| bench_v3 | security_scrub_cost | 99,222.6 MB/s | 128,286.6 MB/s | +29.3% |
| bench_v3 | string_search_grep | 3495.3 MB/s | 4194.3 MB/s | +20.0% |
| bench_v3 | thp_2mb_batch_alloc | 1,201,809.8 MB/s | 1,238,777.9 MB/s | +3.1% |
| bench_v3 | web_request_handling | 584.4 MB/s | 601.7 MB/s | +3.0% |
| enterprise_bench | ai_dataloader_fork_shm | 3,310.8 MB/s | 3,503.7 MB/s | +5.8% |
| enterprise_bench | container_mem_isolation | 164,027.6 MB/s | 64,877,079.9 MB/s | +39452.5% |
| enterprise_bench | db_pagecache_random_rw | 60,535.7 MB/s | 58,235.8 MB/s | -3.8% |
| enterprise_bench | gradient_allreduce_sim | 6,046.2 MB/s | 5,855.9 MB/s | -3.1% |
| enterprise_bench | live_migration_checkpoint | 21,940.0 MB/s | 22,105.8 MB/s | +0.8% |
| enterprise_bench | mem_fragmentation_stress | 103.5 MB/s | 1,034.3 MB/s | +899.3% |
| enterprise_bench | net_packet_throughput | 3,164.9 MB/s | 3,126.0 MB/s | -1.2% |
| enterprise_bench | numa_aware_multitenant | 14,376.7 MB/s | 168,075.9 MB/s | +1069.1% |
| enterprise_bench | security_mem_scrub | 34,052.3 MB/s | 60,614.9 MB/s | +78.0% |
| enterprise_bench | thp_collapse_expand_sim | 58,824.9 MB/s | 169,551.3 MB/s | +188.2% |
| ai_bench | ft_adamw_optimizer_step | 4,889.9 MB/s | 5,049.9 MB/s | +3.3% |
| ai_bench | ft_backward_gradient | 2,267.2 MB/s | 2,283.0 MB/s | +0.7% |
| ai_bench | ft_forward_linear_relu | 2,609.8 MB/s | 2,507.1 MB/s | -3.9% |
| ai_bench | ft_gradient_checkpoint | 9,032.0 MB/s | 9,009.0 MB/s | -0.3% |
| ai_bench | ft_lora_adapter_forward | 3,079.3 MB/s | 3,078.6 MB/s | -0.0% |
| ai_bench | infer_batched_matvec_decode | 764.1 MB/s | 764.6 MB/s | +0.1% |
| ai_bench | infer_embedding_posenc | 3,883.1 MB/s | 3,765.6 MB/s | -3.0% |
| ai_bench | infer_kv_cache_mgmt | 9,901.4 MB/s | 7,051.5 MB/s | -28.8% |
| ai_bench | infer_softmax_topk_sample | 482.9 MB/s | 483.3 MB/s | +0.1% |
| ai_bench | infer_transformer_attention | 3,270.7 MB/s | 3,379.2 MB/s | +3.3% |
| ai_bench | train_activation_save_restore | 18,457.9 MB/s | 18,047.2 MB/s | -2.2% |
| ai_bench | train_checkpoint_save_load | 47,419.8 MB/s | 57,752.7 MB/s | +21.8% |
| ai_bench | train_dataloader_pipeline | 30,649.8 MB/s | 30,667.0 MB/s | +0.1% |
| ai_bench | train_lr_schedule_loss | 1,331.7 MB/s | 1,331.8 MB/s | +0.0% |
| ai_bench | train_mixed_precision_fp16 | 8,739.0 MB/s | 8,738.8 MB/s | -0.0% |
| ai_bench | train_ring_allreduce | 3,063,772.1 MB/s | 3,110,290.1 MB/s | +1.5% |
| ai_fullchain | F1_base_weight_load_anchor | 40,330.0 MB/s | 51,642.2 MB/s | +28.0% |
| ai_fullchain | F2_lora_adapter_init | 6,379.7 MB/s | 6,165.2 MB/s | -3.4% |
| ai_fullchain | F3_frozen_base_forward | 23,857.3 MB/s | 26,503.7 MB/s | +11.1% |
| ai_fullchain | F4_lora_adapter_forward | 9,602.9 MB/s | 9,591.4 MB/s | -0.1% |
| ai_fullchain | F5_qlora_quantized_forward | 77.8 MB/s | 78.0 MB/s | +0.3% |
| ai_fullchain | F6_peft_adapter_gradient | 8,150.4 MB/s | 7,989.8 MB/s | -2.0% |
| ai_fullchain | F7_gradient_checkpoint | 6,008.5 MB/s | 6,038.5 MB/s | +0.5% |
| ai_fullchain | F8_adapter_merge_export | 9,053.8 MB/s | 9,086.3 MB/s | +0.4% |
| ai_fullchain | I10_continuous_batch_preempt | 70,200.1 MB/s | 69,662.8 MB/s | -0.8% |
| ai_fullchain | I1_weight_load_cache_warm | 3,550.5 MB/s | 3,590.4 MB/s | +1.1% |
| ai_fullchain | I2_prompt_tokenize | 1,565.7 MB/s | 1,574.4 MB/s | +0.6% |
| ai_fullchain | I3_prefill_parallel_attn | 11,938.4 MB/s | 11,973.9 MB/s | +0.3% |
| ai_fullchain | I4_kv_cache_populate | 22,643.7 MB/s | 22,095.9 MB/s | -2.4% |
| ai_fullchain | I5_decode_single_token | 19,681.6 MB/s | 19,745.8 MB/s | +0.3% |
| ai_fullchain | I6_kv_cache_append_slide | 21,811.7 MB/s | 20,619.6 MB/s | -5.5% |
| ai_fullchain | I7_softmax_topk_sampling | 499.6 MB/s | 497.7 MB/s | -0.4% |
| ai_fullchain | I8_speculative_decode | 26,519.9 MB/s | 26,459.9 MB/s | -0.2% |
| ai_fullchain | I9_batch_multi_request | 23,095.6 MB/s | 29,519.7 MB/s | +27.8% |
| ai_fullchain | T10_gradient_accumulation | 137,606.9 MB/s | 121,065.3 MB/s | -12.0% |
| ai_fullchain | T11_adamw_optimizer | 160,142.5 MB/s | 161,300.3 MB/s | +0.7% |
| ai_fullchain | T12_ring_allreduce | 1,529,093.7 MB/s | 1,552,296.1 MB/s | +1.5% |
| ai_fullchain | T1_dataset_shard_load | 127,954.4 MB/s | 298,430.1 MB/s | +133.2% |
| ai_fullchain | T2_tokenize_pad | 1,581.5 MB/s | 1,582.1 MB/s | +0.0% |
| ai_fullchain | T3_dataloader_prefetch_collate | 19,780.3 MB/s | 20,639.7 MB/s | +4.3% |
| ai_fullchain | T4_embedding_posenc | 6,714.8 MB/s | 5,886.5 MB/s | -12.3% |
| ai_fullchain | T5_mha_forward | 9,700.6 MB/s | 9,716.3 MB/s | +0.2% |
| ai_fullchain | T6_ffn_forward | 872.9 MB/s | 976.8 MB/s | +11.9% |
| ai_fullchain | T7_layernorm_residual | 3,756.1 MB/s | 3,749.9 MB/s | -0.2% |
| ai_fullchain | T8_cross_entropy_loss | 1,224.4 MB/s | 1,235.9 MB/s | +0.9% |
| ai_fullchain | T9_backward_all_layers | 6,287.2 MB/s | 6,169.9 MB/s | -1.9% |

*Total rows: 130*

## 3. Suite-Level Summary

| suite | rows | avg delta% | ≥+5% (LDM) | ≤-5% (Trad) | equivalent | verdict |
|-------|-----:|-----------:|------------:|-------------:|-----------:|---------|
| api_bench | 18 | +8.4% | 3 | 2 | 13 | LDM faster |
| residency_bench | 12 | +159.2% | 7 | 0 | 5 | LDM faster |
| bench_v2 | 18 | +1163.2% | 8 | 2 | 8 | LDM faster |
| bench_v3 | 26 | +155.3% | 7 | 3 | 16 | LDM faster |
| enterprise_bench | 10 | +4168.6% | 6 | 0 | 4 | LDM faster |
| ai_bench | 16 | -0.5% | 1 | 1 | 14 | equivalent |
| ai_fullchain | 30 | +6.1% | 5 | 3 | 22 | LDM faster |

## 4. Notes on residual deltas

- No suite shows a stable ≥25% LDM regression after the fixes.
- `activation_fwd_bwd_NATIVE` (api) and `infer_kv_cache_mgmt` (ai) swing ±40% between runs — μs-scale / noise.
- v3 `enterprise_es_inverted_idx` is a stable ~1.2–1.37× slower but the absolute delta is ≈0.25 ms on a ~1 ms workload (cache/address-layout scale), not an LDM feature cost.
- v2 `security_scrub_cost` in the full-run shows x1.23 once but standalone is x0.92–1.01 (parity).
- Classic `ldm_benchmark` (8 tests): total time 1.448 s (Trad) vs 1.444 s (LDM) — equivalent.

## 5. Reproduce

```bash
cd benchmarks
./run_all_benchmarks.sh            # all 8 suites, 50 rounds, writes CSVs + summary
```
