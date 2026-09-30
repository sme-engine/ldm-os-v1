# LDM-OS AArch64 (Kunpeng 920) Benchmark Report — 2-run mean (final)

- Generated: 2026-09-21 04:35:51
- Platform : aarch64 / Linux 5.10.0-182.0.0.95.r3582_286.hce2.aarch64
- Method   : 2 full benchmark passes, mean of per-test throughput (50 rounds per mode per pass)
- Total test cases: 130
- Verdict: LDM win (≥+5%) 32 | Equivalent (±5%) 79 | LDM loss (≤-5%) 19
- Excluding api_bench (`--ldm` does not alter its code path): win 30 | eq 69 | loss 13

## Full comparison

| suite | test | trad (MB/s) | ldm (MB/s) | delta | verdict |
|---|---|---:|---:|---:|---|
| ai_bench | ft_adamw_optimizer_step | 4678.0 | 5047.2 | +7.9% | 🚀 LDM |
| ai_bench | ft_backward_gradient | 2260.2 | 2276.3 | +0.7% | ✅ Eq |
| ai_bench | ft_forward_linear_relu | 2592.6 | 2486.8 | -4.1% | ✅ Eq |
| ai_bench | ft_gradient_checkpoint | 9064.7 | 9047.1 | -0.2% | ✅ Eq |
| ai_bench | ft_lora_adapter_forward | 3054.5 | 3109.6 | +1.8% | ✅ Eq |
| ai_bench | infer_batched_matvec_decode | 763.3 | 763.5 | +0.0% | ✅ Eq |
| ai_bench | infer_embedding_posenc | 3838.8 | 3726.3 | -2.9% | ✅ Eq |
| ai_bench | infer_kv_cache_mgmt | 7943.8 | 8766.6 | +10.4% | 🚀 LDM |
| ai_bench | infer_softmax_topk_sample | 481.7 | 482.9 | +0.2% | ✅ Eq |
| ai_bench | infer_transformer_attention | 3356.4 | 3381.1 | +0.7% | ✅ Eq |
| ai_bench | train_activation_save_restore | 18452.3 | 18188.0 | -1.4% | ✅ Eq |
| ai_bench | train_checkpoint_save_load | 63482.9 | 59095.4 | -6.9% | ⚠️ Trad |
| ai_bench | train_dataloader_pipeline | 30643.3 | 30646.2 | +0.0% | ✅ Eq |
| ai_bench | train_lr_schedule_loss | 1303.1 | 1331.4 | +2.2% | ✅ Eq |
| ai_bench | train_mixed_precision_fp16 | 8702.5 | 8723.6 | +0.2% | ✅ Eq |
| ai_bench | train_ring_allreduce | 3107985.5 | 3106863.2 | -0.0% | ✅ Eq |
| ai_fullchain | F1_base_weight_load_anchor | 39561.4 | 50762.1 | +28.3% | 🚀 LDM |
| ai_fullchain | F2_lora_adapter_init | 6396.1 | 6194.3 | -3.2% | ✅ Eq |
| ai_fullchain | F3_frozen_base_forward | 25628.8 | 26418.8 | +3.1% | ✅ Eq |
| ai_fullchain | F4_lora_adapter_forward | 9800.2 | 9743.2 | -0.6% | ✅ Eq |
| ai_fullchain | F5_qlora_quantized_forward | 77.9 | 78.0 | +0.1% | ✅ Eq |
| ai_fullchain | F6_peft_adapter_gradient | 8170.0 | 8115.2 | -0.7% | ✅ Eq |
| ai_fullchain | F7_gradient_checkpoint | 6025.9 | 5951.8 | -1.2% | ✅ Eq |
| ai_fullchain | F8_adapter_merge_export | 9022.9 | 9066.9 | +0.5% | ✅ Eq |
| ai_fullchain | I10_continuous_batch_preempt | 70388.6 | 69738.9 | -0.9% | ✅ Eq |
| ai_fullchain | I1_weight_load_cache_warm | 3557.7 | 3590.9 | +0.9% | ✅ Eq |
| ai_fullchain | I2_prompt_tokenize | 1561.2 | 1568.4 | +0.5% | ✅ Eq |
| ai_fullchain | I3_prefill_parallel_attn | 11957.3 | 12009.4 | +0.4% | ✅ Eq |
| ai_fullchain | I4_kv_cache_populate | 22600.4 | 21978.6 | -2.8% | ✅ Eq |
| ai_fullchain | I5_decode_single_token | 19754.7 | 19712.0 | -0.2% | ✅ Eq |
| ai_fullchain | I6_kv_cache_append_slide | 22023.6 | 20366.0 | -7.5% | ⚠️ Trad |
| ai_fullchain | I7_softmax_topk_sampling | 497.4 | 498.6 | +0.3% | ✅ Eq |
| ai_fullchain | I8_speculative_decode | 25105.5 | 26502.5 | +5.6% | 🚀 LDM |
| ai_fullchain | I9_batch_multi_request | 23089.1 | 29702.7 | +28.6% | 🚀 LDM |
| ai_fullchain | T10_gradient_accumulation | 138578.3 | 120742.9 | -12.9% | ⚠️ Trad |
| ai_fullchain | T11_adamw_optimizer | 158194.6 | 161324.5 | +2.0% | ✅ Eq |
| ai_fullchain | T12_ring_allreduce | 1533292.2 | 1556560.4 | +1.5% | ✅ Eq |
| ai_fullchain | T1_dataset_shard_load | 129489.9 | 278886.2 | +115.4% | 🚀 LDM |
| ai_fullchain | T2_tokenize_pad | 1573.2 | 1582.4 | +0.6% | ✅ Eq |
| ai_fullchain | T3_dataloader_prefetch_collate | 19906.4 | 20589.3 | +3.4% | ✅ Eq |
| ai_fullchain | T4_embedding_posenc | 6185.6 | 5729.9 | -7.4% | ⚠️ Trad |
| ai_fullchain | T5_mha_forward | 9786.8 | 9724.0 | -0.6% | ✅ Eq |
| ai_fullchain | T6_ffn_forward | 910.7 | 939.0 | +3.1% | ✅ Eq |
| ai_fullchain | T7_layernorm_residual | 3751.9 | 3756.9 | +0.1% | ✅ Eq |
| ai_fullchain | T8_cross_entropy_loss | 1228.6 | 1214.9 | -1.1% | ✅ Eq |
| ai_fullchain | T9_backward_all_layers | 6245.8 | 6273.0 | +0.4% | ✅ Eq |
| api_bench | activation_fwd_bwd_COMPAT | 33939.6 | 32862.8 | -3.2% | ✅ Eq |
| api_bench | activation_fwd_bwd_NATIVE | 42350.7 | 42673.3 | +0.8% | ✅ Eq |
| api_bench | activation_fwd_bwd_TRAD | 26838.2 | 25218.4 | -6.0% | ⚠️ Trad |
| api_bench | cross_domain_share_COMPAT | 188767.7 | 161585.2 | -14.4% | ⚠️ Trad |
| api_bench | cross_domain_share_NATIVE | 190501.9 | 206872.5 | +8.6% | 🚀 LDM |
| api_bench | cross_domain_share_TRAD | 90684.6 | 78203.8 | -13.8% | ⚠️ Trad |
| api_bench | db_buffer_pool_COMPAT | 90638.4 | 81477.6 | -10.1% | ⚠️ Trad |
| api_bench | db_buffer_pool_NATIVE | 136152.7 | 132594.5 | -2.6% | ✅ Eq |
| api_bench | db_buffer_pool_TRAD | 54618.3 | 52092.1 | -4.6% | ✅ Eq |
| api_bench | gradient_accumulation_COMPAT | 254609.5 | 264586.0 | +3.9% | ✅ Eq |
| api_bench | gradient_accumulation_NATIVE | 696422.4 | 736196.7 | +5.7% | 🚀 LDM |
| api_bench | gradient_accumulation_TRAD | 163808.2 | 167687.8 | +2.4% | ✅ Eq |
| api_bench | kv_cache_management_COMPAT | 170400.6 | 168390.0 | -1.2% | ✅ Eq |
| api_bench | kv_cache_management_NATIVE | 181394.5 | 181346.0 | -0.0% | ✅ Eq |
| api_bench | kv_cache_management_TRAD | 69839.1 | 70660.9 | +1.2% | ✅ Eq |
| api_bench | weight_lifecycle_COMPAT | 1757067.7 | 1659693.1 | -5.5% | ⚠️ Trad |
| api_bench | weight_lifecycle_NATIVE | 2176371.9 | 2119233.5 | -2.6% | ✅ Eq |
| api_bench | weight_lifecycle_TRAD | 179101.2 | 155418.5 | -13.2% | ⚠️ Trad |
| bench_v2 | ai_dataloader_throughput | 3896.8 | 3898.9 | +0.1% | ✅ Eq |
| bench_v2 | compression_dedup_sim | 1873.5 | 1883.5 | +0.5% | ✅ Eq |
| bench_v2 | db_pagecache_random_rw | 56866.9 | 58310.4 | +2.5% | ✅ Eq |
| bench_v2 | gradient_allreduce | 6118.9 | 6230.1 | +1.8% | ✅ Eq |
| bench_v2 | json_serialize_deserialize | 301.9 | 302.4 | +0.2% | ✅ Eq |
| bench_v2 | kv_store_crud | 3244.0 | 3411.4 | +5.2% | 🚀 LDM |
| bench_v2 | live_migration_dirty_track | 10953.0 | 24568.7 | +124.3% | 🚀 LDM |
| bench_v2 | log_parse_filter_agg | 406.1 | 406.3 | +0.0% | ✅ Eq |
| bench_v2 | matmul_compute_mem | 359.6 | 378.6 | +5.3% | 🚀 LDM |
| bench_v2 | mem_fragmentation_ops | 110.3 | 6093.6 | +5422.1% | 🚀 LDM |
| bench_v2 | memcpy_sequential | 5616764305.1 | 9805895509.2 | +74.6% | 🚀 LDM |
| bench_v2 | net_packet_loopback | 3200.6 | 3205.1 | +0.1% | ✅ Eq |
| bench_v2 | partial_use_alloc_10pct | 79816.4 | 2369856.8 | +2869.1% | 🚀 LDM |
| bench_v2 | producer_consumer_pipe | 628.5 | 555.0 | -11.7% | ⚠️ Trad |
| bench_v2 | security_scrub_cost | 37057.7 | 6869.1 | -81.5% | ⚠️ Trad |
| bench_v2 | string_search_grep | 5591684723.8 | 6116731881.6 | +9.4% | 🚀 LDM |
| bench_v2 | thp_2mb_alloc_touch | 62255.3 | 7560.1 | -87.9% | ⚠️ Trad |
| bench_v2 | web_request_handling | 931.9 | 934.3 | +0.3% | ✅ Eq |
| bench_v3 | ai_dataloader_throughput | 3904.8 | 3912.5 | +0.2% | ✅ Eq |
| bench_v3 | compression_dedup_sim | 1879.1 | 1884.7 | +0.3% | ✅ Eq |
| bench_v3 | db_pagecache_random_rw | 54447.5 | 55405.0 | +1.8% | ✅ Eq |
| bench_v3 | enterprise_docker_layer_dedup | 1593.8 | 1609.2 | +1.0% | ✅ Eq |
| bench_v3 | enterprise_es_inverted_idx | 85.0 | 88.6 | +4.2% | ✅ Eq |
| bench_v3 | enterprise_k8s_pod_schedule | 10796.8 | 10893.2 | +0.9% | ✅ Eq |
| bench_v3 | enterprise_kafka_msg_batch | 2378.1 | 2324.9 | -2.2% | ✅ Eq |
| bench_v3 | enterprise_mysql_btree_pages | 49527.1 | 55577.1 | +12.2% | 🚀 LDM |
| bench_v3 | enterprise_nginx_conn_pool | 5846.8 | 5887.0 | +0.7% | ✅ Eq |
| bench_v3 | enterprise_pg_mvcc_tuples | 9538.2 | 9095.5 | -4.6% | ✅ Eq |
| bench_v3 | enterprise_tls_handshake_mem | 1628.1 | 1622.0 | -0.4% | ✅ Eq |
| bench_v3 | gradient_allreduce | 6384.9 | 6311.9 | -1.1% | ✅ Eq |
| bench_v3 | json_serialize_deserialize | 209.5 | 209.7 | +0.1% | ✅ Eq |
| bench_v3 | kv_store_crud | 3441.9 | 3150.2 | -8.5% | ⚠️ Trad |
| bench_v3 | live_migration_dirty_track | 24315.3 | 22656.0 | -6.8% | ⚠️ Trad |
| bench_v3 | log_parse_filter_agg | 321.4 | 321.5 | +0.0% | ✅ Eq |
| bench_v3 | matmul_compute_mem | 360.1 | 358.9 | -0.3% | ✅ Eq |
| bench_v3 | mem_fragmentation_ops | 387.8 | 18.2 | -95.3% | ⚠️ Trad |
| bench_v3 | memcpy_sequential | 3913627081.8 | 8787673039.8 | +124.5% | 🚀 LDM |
| bench_v3 | net_packet_loopback | 3173.5 | 3183.8 | +0.3% | ✅ Eq |
| bench_v3 | partial_use_alloc_10pct | 86145.4 | 3811229.2 | +4324.2% | 🚀 LDM |
| bench_v3 | producer_consumer_pipe | 617.9 | 638.1 | +3.3% | ✅ Eq |
| bench_v3 | security_scrub_cost | 102012.9 | 101918.2 | -0.1% | ✅ Eq |
| bench_v3 | string_search_grep | 2802228965.5 | 4369066666.6 | +55.9% | 🚀 LDM |
| bench_v3 | thp_2mb_batch_alloc | 1080219.9 | 1203379.5 | +11.4% | 🚀 LDM |
| bench_v3 | web_request_handling | 591.5 | 557.4 | -5.8% | ⚠️ Trad |
| enterprise_bench | ai_dataloader_fork_shm | 3310.6 | 2960.1 | -10.6% | ⚠️ Trad |
| enterprise_bench | container_mem_isolation | 166821.7 | 63698917.5 | +38083.8% | 🚀 LDM |
| enterprise_bench | db_pagecache_random_rw | 58084.8 | 55340.6 | -4.7% | ✅ Eq |
| enterprise_bench | gradient_allreduce_sim | 5985.4 | 5649.7 | -5.6% | ⚠️ Trad |
| enterprise_bench | live_migration_checkpoint | 19309.5 | 20760.8 | +7.5% | 🚀 LDM |
| enterprise_bench | mem_fragmentation_stress | 99.5 | 986.5 | +891.4% | 🚀 LDM |
| enterprise_bench | net_packet_throughput | 3209.8 | 3179.4 | -0.9% | ✅ Eq |
| enterprise_bench | numa_aware_multitenant | 12703.5 | 167954.0 | +1222.1% | 🚀 LDM |
| enterprise_bench | security_mem_scrub | 34466.0 | 62899.9 | +82.5% | 🚀 LDM |
| enterprise_bench | thp_collapse_expand_sim | 59088.9 | 167949.8 | +184.2% | 🚀 LDM |
| residency_bench | ai_activation_forward_backward | 1490.7 | 1656.2 | +11.1% | 🚀 LDM |
| residency_bench | ai_weight_tensor_residency | 4100.2 | 4991.3 | +21.7% | 🚀 LDM |
| residency_bench | db_buffer_pool_pin_update | 13976.4 | 13928.5 | -0.3% | ✅ Eq |
| residency_bench | net_zerocopy_packet_morph | 6820.1 | 24644.2 | +261.3% | 🚀 LDM |
| residency_bench | residency_anchor_morph_cycle | 26694.6 | 46939.3 | +75.8% | 🚀 LDM |
| residency_bench | residency_cache_affinity | 44741.8 | 45120.6 | +0.8% | ✅ Eq |
| residency_bench | residency_cross_domain_share | 25723.0 | 226479.5 | +780.5% | 🚀 LDM |
| residency_bench | residency_device_map_morph | 9627.8 | 66882.4 | +594.7% | 🚀 LDM |
| residency_bench | residency_full_lifecycle | 693.0 | 720.9 | +4.0% | ✅ Eq |
| residency_bench | residency_inplace_modify | 2161.4 | 2116.4 | -2.1% | ✅ Eq |
| residency_bench | residency_lazy_io_batch | 320.5 | 314.1 | -2.0% | ✅ Eq |
| residency_bench | residency_pressure_resilience | 4366.8 | 4303.4 | -1.5% | ✅ Eq |

## LDM-loss cases (≤ -5%)

- **bench_v3/mem_fragmentation_ops**: 387.8 → 18.2 MB/s (-95.3%)
- **bench_v2/thp_2mb_alloc_touch**: 62255.3 → 7560.1 MB/s (-87.9%)
- **bench_v2/security_scrub_cost**: 37057.7 → 6869.1 MB/s (-81.5%)
- **api_bench/cross_domain_share_COMPAT**: 188767.7 → 161585.2 MB/s (-14.4%) (noise: api_bench unaffected by --ldm)
- **api_bench/cross_domain_share_TRAD**: 90684.6 → 78203.8 MB/s (-13.8%) (noise: api_bench unaffected by --ldm)
- **api_bench/weight_lifecycle_TRAD**: 179101.2 → 155418.5 MB/s (-13.2%) (noise: api_bench unaffected by --ldm)
- **ai_fullchain/T10_gradient_accumulation**: 138578.3 → 120742.9 MB/s (-12.9%)
- **bench_v2/producer_consumer_pipe**: 628.5 → 555.0 MB/s (-11.7%)
- **enterprise_bench/ai_dataloader_fork_shm**: 3310.6 → 2960.1 MB/s (-10.6%)
- **api_bench/db_buffer_pool_COMPAT**: 90638.4 → 81477.6 MB/s (-10.1%) (noise: api_bench unaffected by --ldm)
- **bench_v3/kv_store_crud**: 3441.9 → 3150.2 MB/s (-8.5%)
- **ai_fullchain/I6_kv_cache_append_slide**: 22023.6 → 20366.0 MB/s (-7.5%)
- **ai_fullchain/T4_embedding_posenc**: 6185.6 → 5729.9 MB/s (-7.4%)
- **ai_bench/train_checkpoint_save_load**: 63482.9 → 59095.4 MB/s (-6.9%)
- **bench_v3/live_migration_dirty_track**: 24315.3 → 22656.0 MB/s (-6.8%)
- **api_bench/activation_fwd_bwd_TRAD**: 26838.2 → 25218.4 MB/s (-6.0%) (noise: api_bench unaffected by --ldm)
- **bench_v3/web_request_handling**: 591.5 → 557.4 MB/s (-5.8%)
- **enterprise_bench/gradient_allreduce_sim**: 5985.4 → 5649.7 MB/s (-5.6%)
- **api_bench/weight_lifecycle_COMPAT**: 1757067.7 → 1659693.1 MB/s (-5.5%) (noise: api_bench unaffected by --ldm)
