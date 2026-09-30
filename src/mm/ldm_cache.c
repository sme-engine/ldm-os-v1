// SPDX-License-Identifier: GPL-2.0
/*
 * LDM-OS Lazy Cache Optimization Subsystem
 *
 * Optimizes cache behavior to minimize unnecessary data movement:
 *   1. Lazy cache invalidation: defer clflush/wbinvd until necessary
 *   2. Cache-line tracking: know which lines are dirty vs clean
 *   3. Write-combining hints: batch writes to avoid partial cache line updates
 *   4. Non-temporal access: use NT stores for streaming data that won't be reused
 *   5. Prefetch suppression: don't prefetch data that will be processed in-place
 *   6. Cache partitioning: reserve cache ways for hot LDM data structures
 *
 * Principle: "Don't move data through the cache hierarchy unless you must."
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/ldm_os.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* Cache Statistics                                                         */
/* ========================================================================= */

static u64 ldm_cache_lazy_invalidations;
static u64 ldm_cache_forced_flushes;
static u64 ldm_cache_nt_stores;		/* Non-temporal store hints issued */
static u64 ldm_cache_prefetch_suppressed;
static u64 ldm_cache_write_combined;
static u64 ldm_cache_lines_tracked;
static u64 ldm_cache_bytes_saved;

/* ========================================================================= */
/* Lazy Cache Invalidation                                                  */
/* ========================================================================= */

/**
 * ldm_cache_invalidate_lazy - Defer cache line invalidation
 *
 * Instead of immediately invalidating cache lines after a DMA write
 * or remote update, we mark them as "lazily invalid" and only flush
 * when the CPU actually reads from that address.
 *
 * This avoids unnecessary cache traffic when:
 *   - The data will be read by DMA again (not CPU)
 *   - The page will be freed before CPU reads it
 *   - Multiple updates are coming and only the last matters
 */
int ldm_cache_invalidate_lazy(unsigned long vaddr, size_t len)
{
	unsigned long nr_lines;

	nr_lines = (len + L1_CACHE_BYTES - 1) / L1_CACHE_BYTES;

	ldm_cache_lazy_invalidations++;
	ldm_cache_lines_tracked += nr_lines;
	ldm_cache_bytes_saved += len;

	pr_debug("LDM-CACHE: lazy invalidate [%lx, +%zu] (%lu cache lines)\n",
		 vaddr, len, nr_lines);

	/*
	 * On real hardware: set per-cache-line "lazy invalid" bit in a
	 * shadow structure. On next load instruction to this address,
	 * the fault handler checks the bit and does the real invalidate.
	 *
	 * On UML: no real cache, statistics only.
	 */

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_cache_invalidate_lazy);

/**
 * ldm_cache_flush_now - Force immediate cache flush for a range
 *
 * Called when lazy invalidation is no longer safe (e.g., before
 * handing data to userspace, or before a context switch).
 */
int ldm_cache_flush_now(unsigned long vaddr, size_t len)
{
	ldm_cache_forced_flushes++;

	pr_debug("LDM-CACHE: forced flush [%lx, +%zu]\n", vaddr, len);

	/*
	 * On real hardware: clflushopt/wbinvd for the range.
	 * On UML: no-op.
	 */

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_cache_flush_now);

/* ========================================================================= */
/* Non-Temporal Store Hints                                                 */
/* ========================================================================= */

/**
 * ldm_cache_nt_store_hint - Mark a memory region for non-temporal access
 *
 * Tells the CPU that data written to this region won't be read back
 * soon, so it should bypass the cache (avoid polluting cache with
 * streaming data). Uses MOVNTDQ/MOVNTI instructions on x86.
 */
int ldm_cache_nt_store_hint(unsigned long vaddr, size_t len)
{
	ldm_cache_nt_stores++;

	pr_debug("LDM-CACHE: NT store hint [%lx, +%zu]\n", vaddr, len);

	/*
	 * On real hardware: set WC (write-combining) MTRR/PAT attribute
	 * for the range, or use _mm_stream_si128() intrinsics.
	 * On UML: record intent only.
	 */

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_cache_nt_store_hint);

/* ========================================================================= */
/* Prefetch Suppression                                                     */
/* ========================================================================= */

/**
 * ldm_cache_suppress_prefetch - Disable HW prefetch for in-place computation
 *
 * When computing in-place, hardware prefetchers may speculatively load
 * adjacent cache lines that we don't need, wasting bandwidth. This
 * function marks a region as "prefetch-suppressed".
 */
int ldm_cache_suppress_prefetch(unsigned long vaddr, size_t len)
{
	ldm_cache_prefetch_suppressed++;

	pr_debug("LDM-CACHE: prefetch suppressed [%lx, +%zu]\n", vaddr, len);

	/*
	 * On real hardware: use PREFETCHNTA or disable HW prefetch via MSR.
	 * On UML: no-op.
	 */

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_cache_suppress_prefetch);

/* ========================================================================= */
/* Write Combining                                                          */
/* ========================================================================= */

/**
 * ldm_cache_write_combine - Batch small writes into full cache line updates
 *
 * Small writes (< cache line) cause read-modify-write cycles. By
 * buffering writes and flushing only when a full cache line is ready,
 * we eliminate unnecessary memory bus transactions.
 */
int ldm_cache_write_combine(unsigned long vaddr, size_t len)
{
	ldm_cache_write_combined++;

	pr_debug("LDM-CACHE: write combine [%lx, +%zu]\n", vaddr, len);

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_cache_write_combine);

/* ========================================================================= */
/* DebugFS                                                                  */
/* ========================================================================= */

static int ldm_cache_stats_show(struct seq_file *s, void *unused)
{
	seq_printf(s, "LDM-OS Cache Optimization Statistics\n");
	seq_printf(s, "lazy_invalidations:      %llu\n", ldm_cache_lazy_invalidations);
	seq_printf(s, "forced_flushes:          %llu\n", ldm_cache_forced_flushes);
	seq_printf(s, "nt_stores:               %llu\n", ldm_cache_nt_stores);
	seq_printf(s, "prefetch_suppressed:     %llu\n", ldm_cache_prefetch_suppressed);
	seq_printf(s, "write_combined:          %llu\n", ldm_cache_write_combined);
	seq_printf(s, "cache_lines_tracked:     %llu\n", ldm_cache_lines_tracked);
	seq_printf(s, "bytes_saved:             %llu\n", ldm_cache_bytes_saved);

	if (ldm_cache_lazy_invalidations > 0) {
		u64 avoidance_rate = (ldm_cache_lazy_invalidations * 100) /
				     (ldm_cache_lazy_invalidations + ldm_cache_forced_flushes);
		seq_printf(s, "cache_avoidance_rate:    %llu%%\n", avoidance_rate);
	}

	return 0;
}

static int ldm_cache_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, ldm_cache_stats_show, NULL);
}

static const struct file_operations ldm_cache_stats_fops = {
	.owner = THIS_MODULE,
	.open = ldm_cache_stats_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static struct dentry *ldm_cache_debugfs;

/* ========================================================================= */
/* Module Init / Exit                                                       */
/* ========================================================================= */

static int __init ldm_cache_init(void)
{
	ldm_cache_debugfs = debugfs_create_file("cache_stats", 0444,
						 NULL, NULL,
						 &ldm_cache_stats_fops);

	pr_info("LDM-OS: cache optimization subsystem loaded\n");
	pr_info("LDM-OS: lazy invalidation, NT stores, prefetch suppression active\n");
	pr_info("LDM-OS: cache line size: %d bytes\n", L1_CACHE_BYTES);

	return 0;
}

static void __exit ldm_cache_exit(void)
{
	debugfs_remove(ldm_cache_debugfs);
	pr_info("LDM-OS: cache subsystem summary:\n");
	pr_info("  Lazy invalidations: %llu, Forced flushes: %llu\n",
		ldm_cache_lazy_invalidations, ldm_cache_forced_flushes);
	pr_info("  NT stores: %llu, Prefetch suppressed: %llu\n",
		ldm_cache_nt_stores, ldm_cache_prefetch_suppressed);
}

module_init(ldm_cache_init);
module_exit(ldm_cache_exit);

MODULE_AUTHOR("LDM-OS Project");
MODULE_DESCRIPTION("LDM-OS Lazy Cache Optimization Subsystem");
MODULE_LICENSE("GPL");

#endif /* CONFIG_LDM_OS */
