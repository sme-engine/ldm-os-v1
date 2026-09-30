# LDM-OS API Benchmark Report: Native vs Compat vs Traditional

> Generated: 2026-09-19 19:34:41
> Rounds: 50 per mode | 6 scenarios x 3 modes = 18 tests

## New LDM-Native API
| Function | Purpose |
|----------|---------|
| `ldm_alloc(size)` | Allocate anchored memory (data stays put) |
| `ldm_morph(handle, domain)` | Change purpose without moving data |
| `ldm_share(handle)` | Create zero-copy reference |
| `ldm_inplace(handle, off, len, val)` | Modify at anchored location |
| `ldm_lazy_sync(handle)` | Deferred writeback |
| `ldm_release(handle)` | Release anchor |

## Old OS Compat Layer (no recompile needed)
| Original Call | LDM Intercept |
|--------------|---------------|
| `malloc()+memset(0)` | Lazy zero via ldm_alloc |
| `memcpy(dst,src,n)` | Zero-copy page remap when possible |
| `fork()` | LDM COW (no physical page copy) |
| `sendfile()` | Zero-copy kernel path |

## Results

| Test | TRAD | COMPAT | NATIVE | Compat vs Trad | Native vs Trad |
|------|------|--------|--------|----------------|----------------|
| õÛIâ@ | 37453 MB/s | 407467 MB/s | 312765 MB/s | **1088%** | **835%** |
| ñÖ¡I­@ | 3780 MB/s | 4770 MB/s | 4757 MB/s | **126%** | **126%** |
|  3QÈüÒ@ | 19443 MB/s | 44294 MB/s | 29266 MB/s | **228%** | **151%** |
| ÓzÜÈÎÇ@ | 12190 MB/s | 54532 MB/s | 58882 MB/s | **447%** | **483%** |
| @¡9Ì@úÙ@ | 26601 MB/s | 33115 MB/s | 116750 MB/s | **124%** | **439%** |
| ÊÃÇþïwÊ@ | 13552 MB/s | 22051 MB/s | 76501 MB/s | **163%** | **565%** |

## Key Findings

- **Weight Lifecycle**: Compat **10.9x** faster (eliminates per-token copy)
- **Activation Reuse**: Both Compat and Native **1.3x** (eliminate fwd-bwd copy)
- **Cross-Domain Sharing**: Compat **2.3x**, Native **1.5x** (zero-copy share)
- **KV-Cache**: Native **4.8x**, Compat **4.5x** (anchored cache region)
- **Gradient Accumulation**: Native **4.4x** (anchored accumulator)
- **DB Buffer Pool**: Native **5.7x** (in-place page updates)

## Conclusion

The new LDM-native API delivers **1.5-5.7x speedup** over traditional APIs
for memory-intensive workloads. The compat layer provides **1.3-10.9x**
speedup for existing applications WITHOUT recompilation.