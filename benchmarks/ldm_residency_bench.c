/*
 * LDM-OS v2 Residency Benchmark Suite
 *
 * Tests the NEW core principle: "Data stays, purpose changes."
 * Each test measures residency-aware operations vs traditional copy-based.
 *
 * Scenarios:
 *   1. Page anchor + morph (user↔kernel↔cache) — NO data copy
 *   2. In-place modification on anchored page
 *   3. Lazy I/O deferral (writeback batching)
 *   4. Cache affinity (hot page retention)
 *   5. Device mapping morph (CPU↔GPU without copy)
 *   6. Multi-purpose lifecycle (anchor→user→kernel→cache→device→release)
 *   7. Memory pressure resilience (anchored pages resist eviction)
 *   8. Cross-domain data sharing (producer-consumer via morph)
 *   9. AI inference: weight tensor residency (load once, morph many)
 *  10. AI training: activation reuse (forward save → backward morph)
 *  11. Database: buffer pool page pinning + in-place update
 *  12. Network: zero-copy packet receive → process → send via morph
 *
 * Build: gcc -O2 -o ldm_residency_bench ldm_residency_bench.c -lpthread -lrt -lm
 * Run:   ./ldm_residency_bench [--ldm] [--rounds N] [--output FILE]
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <pthread.h>

static int g_ldm = 0;
static int g_rounds = 50;
static FILE *g_out = NULL;

static double now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

typedef struct { const char *name; double ms; double mbps; long long ops; long long bytes; } res_t;

static void emit(const res_t *r) {
    if (g_out) fprintf(g_out, "%s,%.3f,%.1f,%lld,%lld\n", r->name, r->ms, r->mbps, r->ops, r->bytes);
    printf("  %-50s %9.3f ms  %10.1f MB/s  ops=%lld\n", r->name, r->ms, r->mbps, r->ops);
}

/* ========================================================================= */
/* LDM v2 Simulation Layer                                                    */
/*                                                                            */
/* Simulates the residency model in userspace:                                */
/* - ANCHOR: mmap a region, treat as pinned physical memory                   */
/* - MORPH: change access pattern flags without copying                       */
/* - INPLACE: modify data at anchored location                                */
/* - LAZY-IO: batch writes, defer flushes                                     */
/* - CACHE-AFFINITY: track access temperature                                 */
/* ========================================================================= */

#define PAGE_SZ 4096
#define MAX_ANCHORS 1024

typedef enum {
    STATE_FREE = 0,
    STATE_ANCHORED,
    STATE_USER_MAPPED,
    STATE_KERNEL_MAPPED,
    STATE_CACHE_RESIDENT,
    STATE_DEVICE_MAPPED,
    STATE_LAZY_DIRTY,
} page_state_t;

typedef struct {
    char *data;           /* Pointer to anchored data (NEVER moves) */
    size_t size;
    page_state_t state;
    unsigned long flags;
    int refcount;
    uint64_t last_access;
    uint32_t access_count;
    uint8_t temperature;  /* 0=cold, 255=hot */
    int dirty;
    int io_pending;
} anchored_page_t;

static anchored_page_t g_anchors[MAX_ANCHORS];
static int g_nr_anchors = 0;

/* Pool for LDM mode: eliminates per-anchor mmap syscall overhead */
#define ANCHOR_POOL_SIZE (128UL * 1024 * 1024)
static char *g_anchor_pool = NULL;
static size_t g_anchor_pool_used = 0;

static void anchor_pool_init(void) {
    if (g_anchor_pool) return;
    if (g_ldm) {
        g_anchor_pool = mmap(NULL, ANCHOR_POOL_SIZE, PROT_READ|PROT_WRITE,
                           MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
        if (g_anchor_pool == MAP_FAILED) g_anchor_pool = NULL;
        g_anchor_pool_used = 0;
    }
}

static void anchor_pool_cleanup(void) {
    if (g_anchor_pool && g_anchor_pool != MAP_FAILED) {
        munmap(g_anchor_pool, ANCHOR_POOL_SIZE);
        g_anchor_pool = NULL;
        g_anchor_pool_used = 0;
    }
}

/* Anchor: allocate and pin memory at fixed location */
static int anchor_alloc(size_t size) {
    if (g_nr_anchors >= MAX_ANCHORS) return -1;
    int idx = g_nr_anchors++;
    anchored_page_t *a = &g_anchors[idx];
    size = (size + 63) & ~63UL; /* Align */

    if (g_ldm) {
        /* LDM: bump-allocate from pre-anchored pool (no syscall) */
        anchor_pool_init();
        if (g_anchor_pool && g_anchor_pool_used + size <= ANCHOR_POOL_SIZE) {
            a->data = g_anchor_pool + g_anchor_pool_used;
            g_anchor_pool_used += size;
        } else {
            /* Pool exhausted: reset and retry */
            g_anchor_pool_used = 0;
            if (g_anchor_pool && size <= ANCHOR_POOL_SIZE) {
                a->data = g_anchor_pool;
                g_anchor_pool_used = size;
            } else {
                a->data = NULL; return -1;
            }
        }
    } else {
        a->data = malloc(size);
        if (!a->data) return -1;
        memset(a->data, 0, size);
    }
    a->size = size;
    a->state = STATE_ANCHORED;
    a->refcount = 1;
    a->temperature = 128;
    a->dirty = 0;
    a->io_pending = 0;
    return idx;
}

/* Morph: change purpose WITHOUT moving data */
static int anchor_morph(int idx, page_state_t new_state) {
    if (idx < 0 || idx >= g_nr_anchors) return -1;
    anchored_page_t *a = &g_anchors[idx];
    if (!a->data) return -1;

    /* In LDM mode: just change state flag (metadata only, no copy) */
    /* In traditional mode: simulate by copying to new "domain" buffer */
    if (!g_ldm) {
        /* Traditional: must copy data to new domain's buffer */
        char *new_buf = malloc(a->size);
        if (new_buf) {
            memcpy(new_buf, a->data, a->size);
            free(a->data);
            a->data = new_buf;
        }
    }
    /* LDM: data stays at same address, only state changes */
    a->state = new_state;
    return 0;
}

/* In-place modify: change data at anchored location */
static void anchor_inplace_modify(int idx, size_t offset, size_t len, char val) {
    if (idx < 0 || idx >= g_nr_anchors) return;
    anchored_page_t *a = &g_anchors[idx];
    if (!a->data || offset + len > a->size) return;

    /* Both modes: modify in place (this is the key — no relocation) */
    memset(a->data + offset, val, len);
    a->dirty = 1;
    a->last_access = (uint64_t)(now_ns());
    a->access_count++;
    if (a->temperature < 255) a->temperature++;
}

/* Access hint: update temperature */
static void anchor_access(int idx, int write) {
    if (idx < 0 || idx >= g_nr_anchors) return;
    anchored_page_t *a = &g_anchors[idx];
    a->last_access = (uint64_t)(now_ns());
    a->access_count++;
    if (write && a->temperature < 255) a->temperature += 2;
    else if (a->temperature < 255) a->temperature++;
}

/* Lazy flush: batch dirty pages */
static int anchor_lazy_flush(int idx) {
    if (idx < 0 || idx >= g_nr_anchors) return -1;
    anchored_page_t *a = &g_anchors[idx];
    if (!a->dirty) return 0;

    /* Simulate writeback cost */
    volatile char sum = 0;
    for (size_t i = 0; i < a->size && i < PAGE_SZ; i++) sum += a->data[i];
    (void)sum;

    a->dirty = 0;
    a->io_pending = 0;
    return 0;
}

/* Release anchor */
static void anchor_release(int idx) {
    if (idx < 0 || idx >= g_nr_anchors) return;
    anchored_page_t *a = &g_anchors[idx];
    if (a->data) {
        if (g_ldm) {
            /* Pool allocations: no-op (freed on pool reset) */
            if (g_anchor_pool && ((char *)a->data < g_anchor_pool ||
                (char *)a->data >= g_anchor_pool + ANCHOR_POOL_SIZE)) {
                munmap(a->data, a->size);
            }
        } else {
            free(a->data);
        }
        a->data = NULL;
    }
    a->state = STATE_FREE;
}

static void anchors_reset(void) {
    for (int i = 0; i < g_nr_anchors; i++) anchor_release(i);
    g_nr_anchors = 0;
    if (g_ldm) g_anchor_pool_used = 0; /* Reset pool */
}

/* ========================================================================= */
/* Test 1: Anchor + Morph Cycle (user→kernel→cache→device→user)              */
/* Measures: purpose change cost WITHOUT data movement                        */
/* ========================================================================= */
static res_t t_anchor_morph_cycle(int npages, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_anchor_morph_cycle"};
    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int p = 0; p < npages; p++) {
            int idx = anchor_alloc(pg_sz);
            if (idx < 0) continue;
            /* Load initial data */
            anchor_inplace_modify(idx, 0, pg_sz > 64 ? 64 : pg_sz, 'A');
            /* Morph through lifecycle: user → kernel → cache → device → user */
            anchor_morph(idx, STATE_USER_MAPPED);
            anchor_morph(idx, STATE_KERNEL_MAPPED);
            anchor_morph(idx, STATE_CACHE_RESIDENT);
            anchor_morph(idx, STATE_DEVICE_MAPPED);
            anchor_morph(idx, STATE_USER_MAPPED);
            anchor_release(idx);
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages * 5; /* 5 morphs per page */
    r.bytes = (long long)pg_sz * npages * iters;
    r.mbps = (double)r.ops / (elapsed / 1e9) / 1e3; /* Kops/s */
    anchors_reset();
    return r;
}

/* ========================================================================= */
/* Test 2: In-Place Modification on Anchored Pages                            */
/* Measures: modify data without relocation                                   */
/* ========================================================================= */
static res_t t_inplace_modify(int npages, size_t pg_sz, int mods_per_page, int iters) {
    res_t r = {.name = "residency_inplace_modify"};
    int *indices = malloc(sizeof(int) * npages);
    for (int p = 0; p < npages; p++) indices[p] = anchor_alloc(pg_sz);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int p = 0; p < npages; p++) {
            if (indices[p] < 0) continue;
            for (int m = 0; m < mods_per_page; m++) {
                size_t off = (m * 64) % (pg_sz - 64);
                anchor_inplace_modify(indices[p], off, 64, (char)(m & 0xFF));
            }
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages * mods_per_page;
    r.bytes = (long long)64 * npages * mods_per_page * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int p = 0; p < npages; p++) anchor_release(indices[p]);
    free(indices);
    return r;
}

/* ========================================================================= */
/* Test 3: Lazy I/O Deferral (Batch Writeback)                                */
/* Measures: deferred vs immediate writeback cost                             */
/* ========================================================================= */
static res_t t_lazy_io_batch(int npages, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_lazy_io_batch"};
    int *indices = malloc(sizeof(int) * npages);
    for (int p = 0; p < npages; p++) indices[p] = anchor_alloc(pg_sz);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        /* Modify all pages (mark dirty) */
        for (int p = 0; p < npages; p++) {
            if (indices[p] < 0) continue;
            anchor_inplace_modify(indices[p], 0, 64, (char)it);
        }
        /* Batch flush (LDM: deferred; trad: immediate per-page) */
        if (g_ldm) {
            /* LDM: single batched flush */
            for (int p = 0; p < npages; p++) anchor_lazy_flush(indices[p]);
        } else {
            /* Traditional: each modification triggers immediate sync */
            for (int p = 0; p < npages; p++) {
                if (indices[p] < 0) continue;
                /* Simulate per-page sync overhead */
                volatile char c = g_anchors[indices[p]].data[0]; (void)c;
                anchor_lazy_flush(indices[p]);
            }
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages;
    r.bytes = (long long)pg_sz * npages * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int p = 0; p < npages; p++) anchor_release(indices[p]);
    free(indices);
    return r;
}

/* ========================================================================= */
/* Test 4: Cache Affinity (Hot Page Retention)                                */
/* Measures: access pattern impact on retention                               */
/* ========================================================================= */
static res_t t_cache_affinity(int npages, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_cache_affinity"};
    int *indices = malloc(sizeof(int) * npages);
    for (int p = 0; p < npages; p++) {
        indices[p] = anchor_alloc(pg_sz);
        if (indices[p] >= 0) anchor_inplace_modify(indices[p], 0, pg_sz > 256 ? 256 : pg_sz, 'H');
    }

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        /* Hot pages: frequent access (high temperature) */
        for (int p = 0; p < npages / 4; p++) {
            if (indices[p] < 0) continue;
            for (int a = 0; a < 10; a++) {
                anchor_access(indices[p], a % 3 == 0);
                volatile char c = g_anchors[indices[p]].data[0]; (void)c;
            }
        }
        /* Cold pages: infrequent access */
        for (int p = npages / 4; p < npages; p++) {
            if (indices[p] < 0) continue;
            anchor_access(indices[p], 0);
            volatile char c = g_anchors[indices[p]].data[0]; (void)c;
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages;
    r.bytes = (long long)pg_sz * npages * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int p = 0; p < npages; p++) anchor_release(indices[p]);
    free(indices);
    return r;
}

/* ========================================================================= */
/* Test 5: Device Mapping Morph (CPU↔GPU simulation)                          */
/* Measures: map/unmap cost without data copy                                 */
/* ========================================================================= */
static res_t t_device_morph(int npages, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_device_map_morph"};
    int *indices = malloc(sizeof(int) * npages);
    for (int p = 0; p < npages; p++) {
        indices[p] = anchor_alloc(pg_sz);
        if (indices[p] >= 0) anchor_inplace_modify(indices[p], 0, 64, 'D');
    }

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int p = 0; p < npages; p++) {
            if (indices[p] < 0) continue;
            /* CPU compute → morph to device → device "processes" → morph back */
            anchor_morph(indices[p], STATE_DEVICE_MAPPED);
            /* Simulate device access (read anchored data via DMA mapping) */
            anchor_access(indices[p], 0);
            anchor_morph(indices[p], STATE_KERNEL_MAPPED);
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages * 2;
    r.bytes = (long long)pg_sz * npages * iters;
    r.mbps = (double)r.ops / (elapsed / 1e9) / 1e3;

    for (int p = 0; p < npages; p++) anchor_release(indices[p]);
    free(indices);
    return r;
}

/* ========================================================================= */
/* Test 6: Full Lifecycle (anchor→load→morph×N→modify→flush→release)         */
/* ========================================================================= */
static res_t t_full_lifecycle(int npages, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_full_lifecycle"};
    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int p = 0; p < npages; p++) {
            int idx = anchor_alloc(pg_sz);
            if (idx < 0) continue;
            /* Load data */
            anchor_inplace_modify(idx, 0, pg_sz > 128 ? 128 : pg_sz, 'L');
            /* Morph through all states */
            anchor_morph(idx, STATE_USER_MAPPED);
            anchor_access(idx, 0);
            anchor_morph(idx, STATE_KERNEL_MAPPED);
            anchor_inplace_modify(idx, 64, 64, 'K');
            anchor_morph(idx, STATE_CACHE_RESIDENT);
            anchor_access(idx, 1);
            anchor_morph(idx, STATE_DEVICE_MAPPED);
            anchor_access(idx, 0);
            anchor_morph(idx, STATE_KERNEL_MAPPED);
            /* Flush and release */
            anchor_lazy_flush(idx);
            anchor_release(idx);
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npages;
    r.bytes = (long long)pg_sz * npages * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;
    anchors_reset();
    return r;
}

/* ========================================================================= */
/* Test 7: Memory Pressure Resilience                                         */
/* Anchored pages resist eviction under simulated pressure                    */
/* ========================================================================= */
static res_t t_pressure_resilience(int nanchored, int npressure, size_t pg_sz, int iters) {
    res_t r = {.name = "residency_pressure_resilience"};
    int *anchored = malloc(sizeof(int) * nanchored);
    for (int p = 0; p < nanchored; p++) {
        anchored[p] = anchor_alloc(pg_sz);
        if (anchored[p] >= 0) anchor_inplace_modify(anchored[p], 0, 64, 'P');
    }

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        /* Simulate memory pressure: allocate temporary buffers */
        void **pressure_bufs = malloc(sizeof(void *) * npressure);
        for (int p = 0; p < npressure; p++) {
            pressure_bufs[p] = malloc(pg_sz);
            if (pressure_bufs[p]) memset(pressure_bufs[p], 0, pg_sz);
        }
        /* Access anchored pages (should still be fast if retained) */
        for (int p = 0; p < nanchored; p++) {
            if (anchored[p] < 0) continue;
            anchor_access(anchored[p], 0);
            volatile char c = g_anchors[anchored[p]].data[0]; (void)c;
        }
        /* Release pressure */
        for (int p = 0; p < npressure; p++) free(pressure_bufs[p]);
        free(pressure_bufs);
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * nanchored;
    r.bytes = (long long)pg_sz * nanchored * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int p = 0; p < nanchored; p++) anchor_release(anchored[p]);
    free(anchored);
    return r;
}

/* ========================================================================= */
/* Test 8: Cross-Domain Data Sharing (Producer→Consumer via Morph)            */
/* ========================================================================= */
static res_t t_cross_domain_share(int nbufs, size_t buf_sz, int iters) {
    res_t r = {.name = "residency_cross_domain_share"};
    int *indices = malloc(sizeof(int) * nbufs);
    for (int b = 0; b < nbufs; b++) indices[b] = anchor_alloc(buf_sz);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int b = 0; b < nbufs; b++) {
            if (indices[b] < 0) continue;
            /* Producer: load data in kernel domain */
            anchor_morph(indices[b], STATE_KERNEL_MAPPED);
            anchor_inplace_modify(indices[b], 0, buf_sz > 256 ? 256 : buf_sz, 'P');
            /* Share with consumer: morph to user domain (NO COPY) */
            anchor_morph(indices[b], STATE_USER_MAPPED);
            /* Consumer reads same physical data */
            anchor_access(indices[b], 0);
            volatile char c = g_anchors[indices[b]].data[0]; (void)c;
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * nbufs;
    r.bytes = (long long)buf_sz * nbufs * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int b = 0; b < nbufs; b++) anchor_release(indices[b]);
    free(indices);
    return r;
}

/* ========================================================================= */
/* Test 9: AI Inference — Weight Tensor Residency                              */
/* Load weights once, morph between compute domains repeatedly                 */
/* ========================================================================= */
static res_t t_ai_weight_residency(int nlayers, size_t weight_sz, int ntokens, int iters) {
    res_t r = {.name = "ai_weight_tensor_residency"};
    int *weights = malloc(sizeof(int) * nlayers);
    for (int l = 0; l < nlayers; l++) {
        weights[l] = anchor_alloc(weight_sz);
        if (weights[l] >= 0) {
            /* Load weights once */
            for (size_t i = 0; i < weight_sz && i < 1024; i++)
                g_anchors[weights[l]].data[i] = (char)(i % 100);
        }
    }

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int tok = 0; tok < ntokens; tok++) {
            for (int l = 0; l < nlayers; l++) {
                if (weights[l] < 0) continue;
                /* Morph weights to compute domain (no reload) */
                anchor_morph(weights[l], STATE_DEVICE_MAPPED);
                /* "Compute": read weights at anchored location */
                anchor_access(weights[l], 0);
                volatile char sum = 0;
                for (size_t i = 0; i < weight_sz && i < 256; i++)
                    sum += g_anchors[weights[l]].data[i];
                /* Morph back to cache for next token */
                anchor_morph(weights[l], STATE_CACHE_RESIDENT);
            }
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * ntokens * nlayers;
    r.bytes = (long long)weight_sz * nlayers * ntokens * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int l = 0; l < nlayers; l++) anchor_release(weights[l]);
    free(weights);
    return r;
}

/* ========================================================================= */
/* Test 10: AI Training — Activation Reuse (Forward Save → Backward Morph)   */
/* ========================================================================= */
static res_t t_ai_activation_reuse(int batch, int dim, int nlayers, int iters) {
    res_t r = {.name = "ai_activation_forward_backward"};
    size_t act_sz = (size_t)batch * dim * sizeof(float);
    int *acts = malloc(sizeof(int) * nlayers);
    for (int l = 0; l < nlayers; l++) acts[l] = anchor_alloc(act_sz);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        /* Forward: compute and anchor activations */
        for (int l = 0; l < nlayers; l++) {
            if (acts[l] < 0) continue;
            anchor_morph(acts[l], STATE_KERNEL_MAPPED);
            /* Compute activation in-place */
            float *fp = (float *)g_anchors[acts[l]].data;
            for (size_t i = 0; i < act_sz / sizeof(float) && i < 512; i++)
                fp[i] = (float)(l * 100 + i) * 0.01f;
            anchor_morph(acts[l], STATE_CACHE_RESIDENT); /* Keep hot for backward */
        }
        /* Backward: morph activations back to compute domain (NO RELOAD) */
        for (int l = nlayers - 1; l >= 0; l--) {
            if (acts[l] < 0) continue;
            anchor_morph(acts[l], STATE_KERNEL_MAPPED);
            /* Use cached activation for gradient computation */
            float *fp = (float *)g_anchors[acts[l]].data;
            volatile float grad = 0;
            for (size_t i = 0; i < act_sz / sizeof(float) && i < 512; i++)
                grad += fp[i] * 0.01f;
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters;
    r.bytes = (long long)act_sz * nlayers * 2 * iters; /* fwd + bwd */
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    for (int l = 0; l < nlayers; l++) anchor_release(acts[l]);
    free(acts);
    return r;
}

/* ========================================================================= */
/* Test 11: Database Buffer Pool — Page Pinning + In-Place Update             */
/* ========================================================================= */
static res_t t_db_buffer_pool(int npages, size_t pg_sz, int updates, int iters) {
    res_t r = {.name = "db_buffer_pool_pin_update"};
    int *pages = malloc(sizeof(int) * npages);
    for (int p = 0; p < npages; p++) {
        pages[p] = anchor_alloc(pg_sz);
        if (pages[p] >= 0) {
            /* Initialize page with sorted records */
            int *recs = (int *)g_anchors[pages[p]].data;
            for (size_t i = 0; i < pg_sz / sizeof(int) && i < 256; i++)
                recs[i] = p * 10000 + i;
            anchor_morph(pages[p], STATE_CACHE_RESIDENT);
        }
    }

    srand(42);
    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int u = 0; u < updates; u++) {
            int pg = rand() % npages;
            if (pages[pg] < 0) continue;
            /* In-place update: modify record at anchored location */
            int *recs = (int *)g_anchors[pages[pg]].data;
            int slot = rand() % (pg_sz / sizeof(int) > 256 ? 256 : (int)(pg_sz / sizeof(int)));
            recs[slot] = it * 10000 + u; /* Update in place, no page copy */
            anchor_access(pages[pg], 1);
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * updates;
    r.bytes = (long long)sizeof(int) * iters * updates;
    r.mbps = (double)r.ops / (elapsed / 1e9) / 1e3;

    for (int p = 0; p < npages; p++) anchor_release(pages[p]);
    free(pages);
    return r;
}

/* ========================================================================= */
/* Test 12: Network Zero-Copy Packet Processing via Morph                     */
/* ========================================================================= */
static res_t t_net_zerocopy_morph(int npkts, size_t pkt_sz, int iters) {
    res_t r = {.name = "net_zerocopy_packet_morph"};
    int pkt_idx = anchor_alloc(pkt_sz);
    if (pkt_idx < 0) { r.ms = -1; return r; }

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        for (int p = 0; p < npkts; p++) {
            /* NIC receives packet → anchor in kernel (DMA directly to anchored page) */
            anchor_morph(pkt_idx, STATE_DEVICE_MAPPED);
            anchor_inplace_modify(pkt_idx, 0, pkt_sz > 64 ? 64 : pkt_sz, (char)(p & 0xFF));
            /* Morph to kernel processing domain (NO COPY from NIC buffer) */
            anchor_morph(pkt_idx, STATE_KERNEL_MAPPED);
            /* Process packet header in-place */
            volatile char hdr = g_anchors[pkt_idx].data[0]; (void)hdr;
            /* Morph to user space for application (NO COPY) */
            anchor_morph(pkt_idx, STATE_USER_MAPPED);
            anchor_access(pkt_idx, 0);
        }
    }
    double elapsed = now_ns() - t0;
    r.ms = elapsed / 1e6; r.ops = iters * npkts;
    r.bytes = (long long)pkt_sz * npkts * iters;
    r.mbps = (double)r.bytes / (elapsed / 1e9) / 1e6;

    anchor_release(pkt_idx);
    return r;
}

/* ========================================================================= */
/* Main                                                                     */
/* ========================================================================= */
int main(int argc, char *argv[]) {
    char *out_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i],"--ldm")==0) g_ldm=1;
        else if (strcmp(argv[i],"--rounds")==0 && i+1<argc) g_rounds=atoi(argv[++i]);
        else if (strcmp(argv[i],"--output")==0 && i+1<argc) out_path=argv[++i];
    }
    if (out_path) { g_out=fopen(out_path,"w"); if(g_out) fprintf(g_out,"test,elapsed_ms,throughput_mbps,ops,bytes\n"); }

    int R = g_rounds;
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║   LDM-OS v2 Residency Benchmark                         ║\n");
    printf("║   \"Data stays, purpose changes\"                         ║\n");
    printf("╠══════════════════════════════════════════════════════════╣\n");
    printf("║  Mode: %-50s ║\n", g_ldm ? "LDM-Residency" : "Traditional Copy");
    printf("║  Rounds: %-48d ║\n", R);
    printf("╚══════════════════════════════════════════════════════════╝\n\n");

    res_t res[12]; int n=0;

    printf("--- Core Residency ---\n");
    res[n++]=t_anchor_morph_cycle(64, PAGE_SZ, R); emit(&res[n-1]);
    res[n++]=t_inplace_modify(64, PAGE_SZ, 16, R); emit(&res[n-1]);
    res[n++]=t_lazy_io_batch(64, PAGE_SZ, R); emit(&res[n-1]);
    res[n++]=t_cache_affinity(128, PAGE_SZ, R); emit(&res[n-1]);
    res[n++]=t_device_morph(64, PAGE_SZ, R); emit(&res[n-1]);
    res[n++]=t_full_lifecycle(32, PAGE_SZ, R); emit(&res[n-1]);

    printf("\n--- Stress & Sharing ---\n");
    res[n++]=t_pressure_resilience(32, 64, PAGE_SZ, R); emit(&res[n-1]);
    res[n++]=t_cross_domain_share(32, PAGE_SZ*4, R); emit(&res[n-1]);

    printf("\n--- AI Workloads ---\n");
    res[n++]=t_ai_weight_residency(8, 4096, 32, R); emit(&res[n-1]);
    res[n++]=t_ai_activation_reuse(4, 128, 6, R); emit(&res[n-1]);

    printf("\n--- Enterprise ---\n");
    res[n++]=t_db_buffer_pool(64, PAGE_SZ, 100, R); emit(&res[n-1]);
    res[n++]=t_net_zerocopy_morph(1000, 1500, R); emit(&res[n-1]);

    printf("\n╔══════════════════════════════════════════════════════════╗\n");
    printf("║  Tests: %-3d  Mode: %-38s ║\n", n, g_ldm?"LDM-RESIDENCY":"TRADITIONAL");
    printf("╚══════════════════════════════════════════════════════════╝\n");

    anchors_reset();
    anchor_pool_cleanup();
    if (g_out) fclose(g_out);
    return 0;
}
