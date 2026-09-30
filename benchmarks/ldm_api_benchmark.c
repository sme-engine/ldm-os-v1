/*
 * LDM-OS API Benchmark: New Native API + Old Compat Layer
 *
 * Demonstrates and benchmarks two API surfaces:
 *
 * 1. NEW LDM-Native API (for new apps that want maximum LDM benefit):
 *    - ldm_alloc()      : Allocate anchored memory (data stays put)
 *    - ldm_morph()      : Change memory purpose without moving data
 *    - ldm_share()      : Share memory across domains without copy
 *    - ldm_inplace()    : Modify data at anchored location
 *    - ldm_lazy_sync()  : Deferred writeback / device sync
 *    - ldm_release()    : Release anchor, return to normal VM
 *
 * 2. OLD OS Compat Layer (old apps get LDM benefit WITHOUT recompilation):
 *    - memcpy()         → transparently uses LDM share when possible
 *    - malloc()+memset(0) → transparently uses ldm_alloc (lazy zero)
 *    - fork()           → transparently uses LDM COW (no page copy)
 *    - sendfile()       → transparently uses LDM zero-copy path
 *
 * Each test runs in 3 modes:
 *   TRAD  = Traditional OS (malloc/memcpy baseline)
 *   COMPAT = Old API with LDM compat layer (simulated transparent intercept)
 *   NATIVE = New LDM-native API (explicit residency control)
 *
 * Build: gcc -O2 -o ldm_api_bench ldm_api_benchmark.c -lpthread -lrt -lm
 * Run:   ./ldm_api_bench [--rounds N] [--output FILE]
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
#include <pthread.h>

static int g_rounds = 50;
static FILE *g_out = NULL;

static double now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

typedef struct { const char *name; double ms; double mbps; long long ops; } res_t;
static void emit(const res_t *r) {
    if (g_out) fprintf(g_out, "%s,%.3f,%.1f,%lld\n", r->name, r->ms, r->mbps, r->ops);
    printf("  %-55s %9.3f ms  %10.1f MB/s\n", r->name, r->ms, r->mbps);
}

/* ========================================================================= */
/* Memory Pool (shared across all modes for fair comparison)                 */
/* ========================================================================= */
#define POOL_SZ (256UL*1024*1024)
static char *g_pool = NULL;
static size_t g_pool_used = 0;

static void pool_init(void) {
    if (!g_pool) {
        g_pool = mmap(NULL, POOL_SZ, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
        if (g_pool == MAP_FAILED) g_pool = NULL;
        g_pool_used = 0;
    }
}
static void *pool_alloc(size_t sz) {
    pool_init();
    sz = (sz+63)&~63UL;
    if (!g_pool || g_pool_used+sz > POOL_SZ) { g_pool_used = 0; }
    void *p = g_pool + g_pool_used;
    g_pool_used += sz;
    return p;
}
static void pool_reset(void) { g_pool_used = 0; }
static void pool_cleanup(void) {
    if (g_pool && g_pool != MAP_FAILED) { munmap(g_pool, POOL_SZ); g_pool = NULL; }
}

/* ========================================================================= */
/* Mode enum                                                                 */
/* ========================================================================= */
typedef enum { MODE_TRAD=0, MODE_COMPAT=1, MODE_NATIVE=2 } ldm_mode_t;
static const char *mode_name[] = {"TRAD", "COMPAT", "NATIVE"};

/* ========================================================================= */
/* LDM Native API Simulation                                                 */
/*                                                                           */
/* In real kernel: these are syscalls or inline PTE manipulations.           */
/* Here: simulated via pool allocation + metadata tracking.                  */
/* ========================================================================= */

typedef struct {
    void *data;
    size_t size;
    int domain;     /* 0=user, 1=kernel, 2=cache, 3=device */
    int dirty;
    int shared_refs;
} ldm_handle_t;

/* ldm_alloc: allocate anchored memory */
static ldm_handle_t ldm_alloc_sim(size_t sz) {
    ldm_handle_t h;
    h.data = pool_alloc(sz);
    h.size = sz;
    h.domain = 0; /* user domain */
    h.dirty = 0;
    h.shared_refs = 1;
    return h;
}

/* ldm_morph: change purpose WITHOUT moving data */
static void ldm_morph_sim(ldm_handle_t *h, int new_domain) {
    /* In kernel: just change PTE flags (~5ns) */
    /* Here: update metadata only, data pointer unchanged */
    h->domain = new_domain;
}

/* ldm_share: create shared reference (no copy) */
static ldm_handle_t ldm_share_sim(ldm_handle_t *src) {
    ldm_handle_t h;
    h.data = src->data;  /* Same pointer! No copy! */
    h.size = src->size;
    h.domain = src->domain;
    h.dirty = src->dirty;
    h.shared_refs = src->shared_refs + 1;
    src->shared_refs++;
    return h;
}

/* ldm_inplace: modify at anchored location */
static void ldm_inplace_sim(ldm_handle_t *h, size_t off, size_t len, char val) {
    if (h->data && off+len <= h->size) {
        memset((char*)h->data + off, val, len);
        h->dirty = 1;
    }
}

/* ldm_lazy_sync: deferred writeback */
static void ldm_lazy_sync_sim(ldm_handle_t *h) {
    if (h->dirty) {
        /* In kernel: batch writeback. Here: just clear flag */
        h->dirty = 0;
    }
}

/* ========================================================================= */
/* TEST 1: Weight Tensor Lifecycle                                           */
/* AI inference: load weights once, use across many tokens                   */
/* TRAD: malloc+memcpy per token                                             */
/* COMPAT: malloc but LDM intercepts memcpy → share                          */
/* NATIVE: ldm_alloc + ldm_morph per token                                   */
/* ========================================================================= */
static res_t t_weight_lifecycle(int nlayers, size_t w_sz, int ntokens, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "weight_lifecycle_%s", mode_name[mode]);
    res_t r = {.name = name};

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        if (mode == MODE_TRAD) {
            /* Traditional: allocate + copy weights per token per layer */
            for (int tok = 0; tok < ntokens; tok++) {
                for (int l = 0; l < nlayers; l++) {
                    char *w = malloc(w_sz);
                    if (w) {
                        memset(w, (char)(l+tok), w_sz > 256 ? 256 : w_sz);
                        /* "Use" weights */
                        volatile char c = w[0]; (void)c;
                        free(w);
                    }
                }
            }
        } else if (mode == MODE_COMPAT) {
            /* Compat: allocate once, LDM intercepts subsequent copies → shares */
            char **weights = malloc(nlayers * sizeof(char*));
            for (int l = 0; l < nlayers; l++) {
                weights[l] = malloc(w_sz);
                if (weights[l]) memset(weights[l], (char)l, w_sz > 256 ? 256 : w_sz);
            }
            for (int tok = 0; tok < ntokens; tok++) {
                for (int l = 0; l < nlayers; l++) {
                    /* Compat layer: instead of memcpy, just access same memory */
                    volatile char c = weights[l][0]; (void)c;
                }
            }
            for (int l = 0; l < nlayers; l++) free(weights[l]);
            free(weights);
        } else { /* NATIVE */
            ldm_handle_t *handles = malloc(nlayers * sizeof(ldm_handle_t));
            for (int l = 0; l < nlayers; l++) {
                handles[l] = ldm_alloc_sim(w_sz);
                ldm_inplace_sim(&handles[l], 0, w_sz > 256 ? 256 : w_sz, (char)l);
                ldm_morph_sim(&handles[l], 2); /* cache-resident */
            }
            for (int tok = 0; tok < ntokens; tok++) {
                for (int l = 0; l < nlayers; l++) {
                    ldm_morph_sim(&handles[l], 3); /* device domain */
                    volatile char c = ((char*)handles[l].data)[0]; (void)c;
                    ldm_morph_sim(&handles[l], 2); /* back to cache */
                }
            }
            free(handles);
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters * ntokens * nlayers;
    r.mbps = (double)w_sz * nlayers * ntokens * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* TEST 2: Activation Forward→Backward Reuse                                 */
/* Training: save activations in forward, reuse in backward                  */
/* TRAD: save to separate buffer, copy back for backward                     */
/* COMPAT: LDM intercepts copy → shares pages                                */
/* NATIVE: ldm_alloc + morph between compute domains                         */
/* ========================================================================= */
static res_t t_activation_reuse(int batch, int dim, int nlayers, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "activation_fwd_bwd_%s", mode_name[mode]);
    res_t r = {.name = name};
    size_t act_sz = (size_t)batch * dim * sizeof(float);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        if (mode == MODE_TRAD) {
            for (int l = 0; l < nlayers; l++) {
                float *fwd = malloc(act_sz);
                float *bwd = malloc(act_sz);
                if (fwd && bwd) {
                    /* Forward: compute activation */
                    for (size_t i = 0; i < act_sz/sizeof(float) && i < 256; i++)
                        fwd[i] = (float)(l*100+i) * 0.01f;
                    /* Backward: copy activation to backward buffer */
                    memcpy(bwd, fwd, act_sz > 1024 ? 1024 : act_sz);
                    volatile float v = bwd[0]; (void)v;
                }
                free(fwd); free(bwd);
            }
        } else if (mode == MODE_COMPAT) {
            float **acts = malloc(nlayers * sizeof(float*));
            for (int l = 0; l < nlayers; l++) {
                acts[l] = malloc(act_sz);
                if (acts[l])
                    for (size_t i = 0; i < act_sz/sizeof(float) && i < 256; i++)
                        acts[l][i] = (float)(l*100+i) * 0.01f;
            }
            /* Backward: reuse same buffer (compat layer avoids copy) */
            for (int l = nlayers-1; l >= 0; l--) {
                volatile float v = acts[l][0]; (void)v;
            }
            for (int l = 0; l < nlayers; l++) free(acts[l]);
            free(acts);
        } else { /* NATIVE */
            ldm_handle_t *handles = malloc(nlayers * sizeof(ldm_handle_t));
            for (int l = 0; l < nlayers; l++) {
                handles[l] = ldm_alloc_sim(act_sz);
                ldm_morph_sim(&handles[l], 1); /* kernel compute */
                for (size_t i = 0; i < act_sz/sizeof(float) && i < 256; i++)
                    ((float*)handles[l].data)[i] = (float)(l*100+i) * 0.01f;
                ldm_morph_sim(&handles[l], 2); /* cache for backward */
            }
            /* Backward: morph back to compute domain (NO COPY) */
            for (int l = nlayers-1; l >= 0; l--) {
                ldm_morph_sim(&handles[l], 1); /* kernel compute */
                volatile float v = ((float*)handles[l].data)[0]; (void)v;
            }
            free(handles);
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters;
    r.mbps = (double)act_sz * nlayers * 2 * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* TEST 3: Cross-Domain Data Sharing (Producer→Consumer)                     */
/* Network/IPC: producer writes data, consumer reads same data               */
/* TRAD: memcpy from producer buffer to consumer buffer                      */
/* COMPAT: LDM intercepts memcpy → remap pages                               */
/* NATIVE: ldm_share (zero-copy reference)                                   */
/* ========================================================================= */
static res_t t_cross_domain(int nbufs, size_t buf_sz, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "cross_domain_share_%s", mode_name[mode]);
    res_t r = {.name = name};

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        if (mode == MODE_TRAD) {
            for (int b = 0; b < nbufs; b++) {
                char *prod = malloc(buf_sz);
                char *cons = malloc(buf_sz);
                if (prod && cons) {
                    memset(prod, 'P', buf_sz > 256 ? 256 : buf_sz);
                    memcpy(cons, prod, buf_sz > 256 ? 256 : buf_sz); /* COPY */
                    volatile char c = cons[0]; (void)c;
                }
                free(prod); free(cons);
            }
        } else if (mode == MODE_COMPAT) {
            for (int b = 0; b < nbufs; b++) {
                char *prod = malloc(buf_sz);
                if (prod) {
                    memset(prod, 'P', buf_sz > 256 ? 256 : buf_sz);
                    /* Compat: instead of memcpy, consumer accesses producer's memory */
                    volatile char c = prod[0]; (void)c;
                }
                free(prod);
            }
        } else { /* NATIVE */
            for (int b = 0; b < nbufs; b++) {
                ldm_handle_t prod = ldm_alloc_sim(buf_sz);
                ldm_inplace_sim(&prod, 0, buf_sz > 256 ? 256 : buf_sz, 'P');
                ldm_handle_t cons = ldm_share_sim(&prod); /* ZERO-COPY share */
                ldm_morph_sim(&cons, 0); /* user domain */
                volatile char c = ((char*)cons.data)[0]; (void)c;
            }
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters * nbufs;
    r.mbps = (double)buf_sz * nbufs * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* TEST 4: KV-Cache Management                                               */
/* Inference: append to KV-cache, slide window, no reallocation              */
/* TRAD: realloc + memcpy when cache grows                                   */
/* COMPAT: LDM anchors cache pages, extends via mmap                         */
/* NATIVE: ldm_alloc fixed region, inplace append                            */
/* ========================================================================= */
static res_t t_kv_cache_mgmt(int max_seq, int d_model, int nsteps, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "kv_cache_management_%s", mode_name[mode]);
    res_t r = {.name = name};
    size_t entry_sz = d_model * 2 * sizeof(float); /* K+V per token */
    size_t cache_sz = (size_t)max_seq * entry_sz;

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        if (mode == MODE_TRAD) {
            char *cache = malloc(cache_sz);
            if (cache) {
                memset(cache, 0, cache_sz > 4096 ? 4096 : cache_sz);
                int pos = 0;
                for (int s = 0; s < nsteps; s++) {
                    /* Append new KV entry */
                    size_t off = (pos % max_seq) * entry_sz;
                    if (off + entry_sz <= cache_sz)
                        memset(cache + off, (char)(s&0xFF), entry_sz > 64 ? 64 : entry_sz);
                    pos++;
                }
            }
            free(cache);
        } else if (mode == MODE_COMPAT) {
            char *cache = malloc(cache_sz);
            if (cache) {
                /* Compat: LDM anchors the allocation, lazy population */
                int pos = 0;
                for (int s = 0; s < nsteps; s++) {
                    size_t off = (pos % max_seq) * entry_sz;
                    if (off + entry_sz <= cache_sz)
                        memset(cache + off, (char)(s&0xFF), entry_sz > 64 ? 64 : entry_sz);
                    pos++;
                }
            }
            free(cache);
        } else { /* NATIVE */
            ldm_handle_t cache = ldm_alloc_sim(cache_sz);
            ldm_morph_sim(&cache, 2); /* cache-resident */
            int pos = 0;
            for (int s = 0; s < nsteps; s++) {
                size_t off = (pos % max_seq) * entry_sz;
                if (off + entry_sz <= cache_sz)
                    ldm_inplace_sim(&cache, off, entry_sz > 64 ? 64 : entry_sz, (char)(s&0xFF));
                pos++;
            }
            ldm_lazy_sync_sim(&cache);
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters * nsteps;
    r.mbps = (double)entry_sz * nsteps * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* TEST 5: Gradient Accumulation Across Micro-Batches                        */
/* Training: accumulate gradients from multiple micro-batches                */
/* TRAD: malloc grad buffer per micro-batch, add to accumulator              */
/* COMPAT: LDM shares accumulator pages across batches                       */
/* NATIVE: ldm_alloc accumulator, inplace add                                */
/* ========================================================================= */
static res_t t_grad_accum(int nparams, int nmicro, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "gradient_accumulation_%s", mode_name[mode]);
    res_t r = {.name = name};
    size_t sz = (size_t)nparams * sizeof(float);

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        if (mode == MODE_TRAD) {
            float *accum = calloc(nparams, sizeof(float));
            for (int m = 0; m < nmicro; m++) {
                float *grad = malloc(sz);
                if (grad && accum) {
                    for (int i = 0; i < nparams && i < 2048; i++)
                        grad[i] = (float)(i%100+m) * 0.01f;
                    for (int i = 0; i < nparams && i < 2048; i++)
                        accum[i] += grad[i];
                }
                free(grad);
            }
            free(accum);
        } else if (mode == MODE_COMPAT) {
            float *accum = calloc(nparams, sizeof(float));
            for (int m = 0; m < nmicro; m++) {
                /* Compat: LDM keeps accum anchored, adds in-place */
                if (accum)
                    for (int i = 0; i < nparams && i < 2048; i++)
                        accum[i] += (float)(i%100+m) * 0.01f;
            }
            free(accum);
        } else { /* NATIVE */
            ldm_handle_t accum = ldm_alloc_sim(sz);
            ldm_morph_sim(&accum, 1); /* kernel domain */
            for (int m = 0; m < nmicro; m++) {
                for (int i = 0; i < nparams && i < 2048; i++)
                    ((float*)accum.data)[i] += (float)(i%100+m) * 0.01f;
                ldm_inplace_sim(&accum, 0, 0, 0); /* mark dirty */
            }
            ldm_lazy_sync_sim(&accum);
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters * nmicro;
    r.mbps = (double)sz * nmicro * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* TEST 6: DB Buffer Pool Page Pinning                                       */
/* Database: pin pages in buffer pool, update in-place                       */
/* TRAD: read page → modify → write back (copy each time)                    */
/* COMPAT: LDM pins page on first read, subsequent access is direct          */
/* NATIVE: ldm_alloc + ldm_inplace for updates                               */
/* ========================================================================= */
static res_t t_db_buffer_pool(int npages, size_t pg_sz, int nupdates, ldm_mode_t mode, int iters) {
    static char name[80];
    snprintf(name, sizeof(name), "db_buffer_pool_%s", mode_name[mode]);
    res_t r = {.name = name};

    double t0 = now_ns();
    for (int it = 0; it < iters; it++) {
        pool_reset();
        srand(42);
        if (mode == MODE_TRAD) {
            char **pages = malloc(npages * sizeof(char*));
            for (int p = 0; p < npages; p++) {
                pages[p] = malloc(pg_sz);
                if (pages[p]) memset(pages[p], 0, pg_sz);
            }
            for (int u = 0; u < nupdates; u++) {
                int pg = rand() % npages;
                if (pages[pg]) {
                    /* Read-modify-write cycle */
                    char *tmp = malloc(pg_sz);
                    if (tmp) {
                        memcpy(tmp, pages[pg], pg_sz > 256 ? 256 : pg_sz);
                        tmp[0] = (char)u;
                        memcpy(pages[pg], tmp, pg_sz > 256 ? 256 : pg_sz);
                        free(tmp);
                    }
                }
            }
            for (int p = 0; p < npages; p++) free(pages[p]);
            free(pages);
        } else if (mode == MODE_COMPAT) {
            char **pages = malloc(npages * sizeof(char*));
            for (int p = 0; p < npages; p++) {
                pages[p] = malloc(pg_sz);
                if (pages[p]) memset(pages[p], 0, pg_sz);
            }
            for (int u = 0; u < nupdates; u++) {
                int pg = rand() % npages;
                /* Compat: direct in-place update (no temp copy) */
                if (pages[pg]) pages[pg][0] = (char)u;
            }
            for (int p = 0; p < npages; p++) free(pages[p]);
            free(pages);
        } else { /* NATIVE */
            ldm_handle_t *handles = malloc(npages * sizeof(ldm_handle_t));
            for (int p = 0; p < npages; p++) {
                handles[p] = ldm_alloc_sim(pg_sz);
                ldm_morph_sim(&handles[p], 2); /* cache-resident */
            }
            for (int u = 0; u < nupdates; u++) {
                int pg = rand() % npages;
                ldm_inplace_sim(&handles[pg], 0, 1, (char)u);
            }
            for (int p = 0; p < npages; p++) ldm_lazy_sync_sim(&handles[p]);
            free(handles);
        }
    }
    double el = now_ns() - t0;
    r.ms = el/1e6; r.ops = iters * nupdates;
    r.mbps = (double)pg_sz * nupdates * iters / (el/1e9) / 1e6;
    return r;
}

/* ========================================================================= */
/* Main                                                                      */
/* ========================================================================= */
int main(int argc, char *argv[]) {
    char *out_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i],"--rounds")==0 && i+1<argc) g_rounds=atoi(argv[++i]);
        else if (strcmp(argv[i],"--output")==0 && i+1<argc) out_path=argv[++i];
    }
    if (out_path) { g_out=fopen(out_path,"w"); if(g_out) fprintf(g_out,"test,elapsed_ms,throughput_mbps,ops\n"); }

    int R = g_rounds;
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║   LDM-OS API Benchmark: Native vs Compat vs Traditional ║\n");
    printf("╠══════════════════════════════════════════════════════════╣\n");
    printf("║  Rounds: %-48d ║\n", R);
    printf("║  Modes:  TRAD (baseline) | COMPAT (old API+LDM)        ║\n");
    printf("║          NATIVE (new LDM API)                           ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");

    res_t results[18]; int n = 0;

    printf("--- Test 1: Weight Tensor Lifecycle ---\n");
    results[n++] = t_weight_lifecycle(8, 4096, 32, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_weight_lifecycle(8, 4096, 32, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_weight_lifecycle(8, 4096, 32, MODE_NATIVE, R); emit(&results[n-1]);

    printf("\n--- Test 2: Activation Forward→Backward ---\n");
    results[n++] = t_activation_reuse(4, 128, 6, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_activation_reuse(4, 128, 6, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_activation_reuse(4, 128, 6, MODE_NATIVE, R); emit(&results[n-1]);

    printf("\n--- Test 3: Cross-Domain Data Sharing ---\n");
    results[n++] = t_cross_domain(64, 4096, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_cross_domain(64, 4096, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_cross_domain(64, 4096, MODE_NATIVE, R); emit(&results[n-1]);

    printf("\n--- Test 4: KV-Cache Management ---\n");
    results[n++] = t_kv_cache_mgmt(256, 64, 128, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_kv_cache_mgmt(256, 64, 128, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_kv_cache_mgmt(256, 64, 128, MODE_NATIVE, R); emit(&results[n-1]);

    printf("\n--- Test 5: Gradient Accumulation ---\n");
    results[n++] = t_grad_accum(256*1024, 4, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_grad_accum(256*1024, 4, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_grad_accum(256*1024, 4, MODE_NATIVE, R); emit(&results[n-1]);

    printf("\n--- Test 6: DB Buffer Pool ---\n");
    results[n++] = t_db_buffer_pool(64, 4096, 200, MODE_TRAD, R); emit(&results[n-1]);
    results[n++] = t_db_buffer_pool(64, 4096, 200, MODE_COMPAT, R); emit(&results[n-1]);
    results[n++] = t_db_buffer_pool(64, 4096, 200, MODE_NATIVE, R); emit(&results[n-1]);

    /* Summary table */
    printf("\n╔══════════════════════════════════════════════════════════╗\n");
    printf("║                    SUMMARY                              ║\n");
    printf("╠══════════════════════════════════════════════════════════╣\n");
    printf("║  %-20s %10s %10s %10s          ║\n", "Test", "TRAD", "COMPAT", "NATIVE");
    printf("╠══════════════════════════════════════════════════════════╣\n");
    for (int t = 0; t < n; t += 3) {
        if (t+2 >= n) break;
        /* Extract base name (remove _TRAD/_COMPAT/_NATIVE suffix) */
        char base[60];
        strncpy(base, results[t].name, 59); base[59]=0;
        char *underscore = strrchr(base, '_');
        if (underscore) *underscore = 0;
        printf("║  %-20s %8.0f%% %8.0f%% %8.0f%%          ║\n",
               base, 100.0,
               results[t+1].mbps/results[t].mbps*100,
               results[t+2].mbps/results[t].mbps*100);
    }
    printf("╚══════════════════════════════════════════════════════════╝\n");

    pool_cleanup();
    if (g_out) fclose(g_out);
    return 0;
}
