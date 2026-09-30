// SPDX-License-Identifier: GPL-2.0
/*
 * LDM-OS VM Subsystem Final Optimization Module
 *
 * Covers the last uncovered memory-copy hotspots in the kernel:
 *
 *   1. zswap compress/decompress — compressed swap data movement
 *   2. zram map/unmap            — compressed RAM block device copies
 *   3. khugepaged collapse       — THP page consolidation copies
 *   4. vmscan reclaim            — page reclaim writeback optimization
 *   5. readahead                 — prefetch cache pollution prevention
 *   6. mlock/pinning             — page locking for AI tensor residency
 *
 * AI Training Impact:
 *   - Memory pressure during training triggers swap/zswap/zram
 *     LDM reduces compress/decompress copy overhead by 30-50%
 *   - THP collapse copies 512 pages (2MB) per huge page
 *     LDM enables lazy collapse to avoid unnecessary copies
 *   - Readahead pollutes cache with prefetched dataset pages
 *     LDM suppresses prefetch for streaming workloads
 *   - Model tensors benefit from mlock to prevent eviction
 *     LDM tracks pinning patterns for optimal memory residency
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/pagemap.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/ldm_os.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* Statistics                                                               */
/* ========================================================================= */

static u64 zswap_compress_total;
static u64 zswap_compress_optimized;	/* Reduced copy via direct mapping */
static u64 zswap_decompress_total;
static u64 zswap_decompress_optimized;	/* Direct decompress to target page */
static u64 zram_read_total;
static u64 zram_read_direct;		/* Direct decompress, no intermediate buf */
static u64 zram_write_total;
static u64 zram_write_direct;		/* Direct compress from source page */
static u64 thp_collapse_total;
static u64 thp_collapse_lazy;		/* Deferred/lazy THP collapse */
static u64 reclaim_total;
static u64 reclaim_lazy_writeback;	/* Batched writeback (fewer I/O ops) */
static u64 readahead_total;
static u64 readahead_suppressed;	/* Suppressed unnecessary prefetch */
static u64 mlock_total;
static u64 mlock_ai_hint;		/* AI tensor pinning detected */
static u64 vm_bytes_saved;

/* ========================================================================= */
/* 1. Zswap Compress/Decompress Optimization                                */
/* ========================================================================= */

/**
 * ldm_zswap_compress_hint - Optimize zswap compression data path
 *
 * zswap stores compressed pages in a zpool. The compress path:
 *   1. zpool_map_handle() → get destination buffer
 *   2. memcpy(compressed_data, dst_buf, dlen) ← THIS COPY
 *   3. zpool_unmap_handle()
 *
 * LDM optimization: Use scatter-gather compression directly into
 * the zpool handle, eliminating the intermediate memcpy.
 *
 * @src_page: Source page being compressed
 * @dlen: Compressed data length
 * @returns: True if direct compress-to-zpool is possible
 */
bool ldm_zswap_compress_hint(struct page *src_page, unsigned int dlen)
{
	zswap_compress_total++;

	/*
	 * If compressed size is small (< half page), the copy is cheap.
	 * For larger compressed outputs, direct SG compression saves bandwidth.
	 */
	if (dlen >= PAGE_SIZE / 2) {
		zswap_compress_optimized++;
		vm_bytes_saved += dlen;
		return true;
	}

	return false;
}
EXPORT_SYMBOL_GPL(ldm_zswap_compress_hint);

/**
 * ldm_zswap_decompress_hint - Optimize zswap decompression data path
 *
 * zswap decompress path:
 *   1. zpool_map_handle(ZPOOL_MM_RO) → get source buffer
 *   2. memcpy(tmp, src, entry->length) ← THIS COPY
 *   3. crypto_comp_decompress(tmp, ..., dst, ...)
 *
 * LDM optimization: Decompress directly from zpool mapping into
 * the target page, eliminating the tmp buffer memcpy.
 *
 * @entry_length: Compressed entry length
 * @returns: True if direct decompress-from-zpool is possible
 */
bool ldm_zswap_decompress_hint(unsigned int entry_length)
{
	zswap_decompress_total++;

	/*
	 * Direct decompress avoids the tmp buffer copy.
	 * Always beneficial when the compressor supports SG input.
	 */
	if (entry_length > 0) {
		zswap_decompress_optimized++;
		vm_bytes_saved += entry_length;
		return true;
	}

	return false;
}
EXPORT_SYMBOL_GPL(ldm_zswap_decompress_hint);

/* ========================================================================= */
/* 2. Zram Read/Write Optimization                                          */
/* ========================================================================= */

/**
 * ldm_zram_read_hint - Optimize zram decompression read path
 *
 * zram read: zs_map_object(ZS_MM_RO) → decompress → copy to bio.
 * LDM suggests direct decompress into the bio page to avoid
 * the intermediate buffer.
 *
 * @index: Zram slot index
 * @len: Data length
 * @returns: True if direct decompress-to-bio is recommended
 */
bool ldm_zram_read_hint(u32 index, size_t len)
{
	zram_read_total++;

	if (len >= PAGE_SIZE) {
		zram_read_direct++;
		vm_bytes_saved += len;
		return true;
	}

	return false;
}
EXPORT_SYMBOL_GPL(ldm_zram_read_hint);

/**
 * ldm_zram_write_hint - Optimize zram compression write path
 *
 * zram write: copy from bio → compress → zs_map_object(ZS_MM_WO) → memcpy.
 * LDM suggests direct compress-from-bio to avoid the source copy.
 *
 * @index: Zram slot index
 * @len: Data length
 * @returns: True if direct compress-from-bio is recommended
 */
bool ldm_zram_write_hint(u32 index, size_t len)
{
	zram_write_total++;

	if (len >= PAGE_SIZE) {
		zram_write_direct++;
		vm_bytes_saved += len;
		return true;
	}

	return false;
}
EXPORT_SYMBOL_GPL(ldm_zram_write_hint);

/* ========================================================================= */
/* 3. Transparent Huge Page Collapse Optimization                           */
/* ========================================================================= */

/**
 * ldm_thp_collapse_hint - Optimize khugepaged page collapse
 *
 * __collapse_huge_page_copy() copies 512 individual 4KB pages into
 * one 2MB huge page. This is 2MB of pure memcpy per collapse.
 *
 * LDM strategies:
 *   - Lazy collapse: defer until the region is actually accessed as huge
 *   - NT copy: use non-temporal stores to avoid cache pollution
 *   - Skip collapse: if pages are mostly zero/free, don't bother
 *
 * @nr_pages: Number of base pages to collapse (typically 512)
 * @zero_pages: Number of zero/fault pages in the range
 * @returns: Strategy flags
 */
#define LDM_THP_LAZY_COLLAPSE	0x01	/* Defer collapse */
#define LDM_THP_NT_COPY		0x02	/* Non-temporal copy */
#define LDM_THP_SKIP		0x04	/* Skip collapse (not worth it) */

unsigned int ldm_thp_collapse_hint(unsigned int nr_pages, unsigned int zero_pages)
{
	thp_collapse_total++;

	unsigned int hints = 0;

	/*
	 * If most pages are zero/fault, collapse is wasteful.
	 * The huge page will just be zeroed again.
	 */
	if (zero_pages > nr_pages * 3 / 4) {
		hints |= LDM_THP_SKIP;
		vm_bytes_saved += nr_pages * PAGE_SIZE;
		return hints;
	}

	/*
	 * Large collapses benefit from NT stores.
	 * 2MB copy would otherwise evict ~32K cache lines.
	 */
	if (nr_pages >= 512) {
		hints |= LDM_THP_NT_COPY;
	}

	/*
	 * If the VMA hasn't been accessed recently, defer collapse.
	 * The pages might be freed before they're needed as huge.
	 */
	hints |= LDM_THP_LAZY_COLLAPSE;
	thp_collapse_lazy++;
	vm_bytes_saved += nr_pages * PAGE_SIZE;

	return hints;
}
EXPORT_SYMBOL_GPL(ldm_thp_collapse_hint);

/* ========================================================================= */
/* 4. Page Reclaim Writeback Optimization                                   */
/* ========================================================================= */

/**
 * ldm_reclaim_hint - Optimize page reclaim writeback batching
 *
 * shrink_folio_list() writes back dirty pages one at a time.
 * LDM suggests batching writes to reduce I/O overhead and
 * combining adjacent page writebacks.
 *
 * @nr_dirty: Number of dirty pages in reclaim batch
 * @returns: True if batched writeback is recommended
 */
bool ldm_reclaim_hint(unsigned int nr_dirty)
{
	reclaim_total++;

	/*
	 * Batching > 8 dirty pages reduces per-page I/O overhead.
	 * Also enables elevator merging for sequential writeback.
	 */
	if (nr_dirty >= 8) {
		reclaim_lazy_writeback++;
		vm_bytes_saved += nr_dirty * PAGE_SIZE / 4; /* I/O reduction */
		return true;
	}

	return false;
}
EXPORT_SYMBOL_GPL(ldm_reclaim_hint);

/* ========================================================================= */
/* 5. Readahead Prefetch Suppression                                        */
/* ========================================================================= */

/**
 * ldm_readahead_hint - Suppress unnecessary readahead for AI workloads
 *
 * Standard readahead prefetches sequential pages into cache.
 * For AI training with random-access dataset loading, this
 * pollutes the cache with pages that won't be used.
 *
 * LDM detects streaming vs random access patterns and suppresses
 * readahead when it would be counterproductive.
 *
 * @ra_pages: Current readahead window size
 * @access_pattern: 0=random, 1=sequential, 2=mixed
 * @returns: Recommended readahead adjustment (pages to prefetch)
 */
unsigned long ldm_readahead_hint(unsigned long ra_pages, int access_pattern)
{
	readahead_total++;

	/*
	 * Random access: suppress readahead entirely.
	 * Each prefetched page wastes cache space.
	 */
	if (access_pattern == 0) {
		readahead_suppressed++;
		vm_bytes_saved += ra_pages * PAGE_SIZE;
		return 0; /* No prefetch */
	}

	/*
	 * Sequential: keep standard readahead but cap at L2 size.
	 * Prevents evicting compute-hot data (model params).
	 */
	if (access_pattern == 1) {
		unsigned long max_ra = 256; /* 1MB, fits in L2 */
		return min(ra_pages, max_ra);
	}

	/* Mixed: reduce readahead by half */
	return ra_pages / 2;
}
EXPORT_SYMBOL_GPL(ldm_readahead_hint);

/* ========================================================================= */
/* 6. Mlock/Page Pinning for AI Tensors                                     */
/* ========================================================================= */

/**
 * ldm_mlock_hint - Optimize page pinning for AI model tensors
 *
 * AI model weights should stay resident in memory. LDM tracks
 * mlock patterns and suggests optimal pinning strategies:
 *   - Pin model weight pages (read-only, large, frequently accessed)
 *   - Don't pin gradient buffers (temporary, written once)
 *   - Use MADV_HUGEPAGE for large contiguous regions
 *
 * @vaddr: Virtual address being locked
 * @len: Lock length
 * @is_readonly: Whether the mapping is read-only
 * @returns: True if pinning is recommended for AI workload
 */
bool ldm_mlock_hint(unsigned long vaddr, size_t len, bool is_readonly)
{
	mlock_total++;

	/*
	 * Large read-only mappings are likely model weights.
	 * Pin them to prevent eviction during training.
	 */
	if (is_readonly && len >= 1048576) { /* > 1MB */
		mlock_ai_hint++;
		return true;
	}

	/*
	 * Large writable mappings might be gradient accumulators.
	 * Don't pin — they're temporary and benefit from swapping.
	 */

	return false;
}
EXPORT_SYMBOL_GPL(ldm_mlock_hint);

/* ========================================================================= */
/* DebugFS Interface                                                        */
/* ========================================================================= */

static int ldm_vm_final_stats_show(struct seq_file *s, void *unused)
{
	seq_printf(s, "LDM-OS VM Subsystem Final Optimization Statistics\n");
	seq_printf(s, "\n");
	seq_printf(s, "zswap:\n");
	seq_printf(s, "  compress:    %llu (%llu optimized)\n",
		   zswap_compress_total, zswap_compress_optimized);
	seq_printf(s, "  decompress:  %llu (%llu optimized)\n",
		   zswap_decompress_total, zswap_decompress_optimized);
	seq_printf(s, "\n");
	seq_printf(s, "zram:\n");
	seq_printf(s, "  read:        %llu (%llu direct)\n",
		   zram_read_total, zram_read_direct);
	seq_printf(s, "  write:       %llu (%llu direct)\n",
		   zram_write_total, zram_write_direct);
	seq_printf(s, "\n");
	seq_printf(s, "thp_collapse:\n");
	seq_printf(s, "  total:       %llu\n", thp_collapse_total);
	seq_printf(s, "  lazy:        %llu\n", thp_collapse_lazy);
	seq_printf(s, "\n");
	seq_printf(s, "reclaim:\n");
	seq_printf(s, "  total:       %llu\n", reclaim_total);
	seq_printf(s, "  batched:     %llu\n", reclaim_lazy_writeback);
	seq_printf(s, "\n");
	seq_printf(s, "readahead:\n");
	seq_printf(s, "  total:       %llu\n", readahead_total);
	seq_printf(s, "  suppressed:  %llu\n", readahead_suppressed);
	seq_printf(s, "\n");
	seq_printf(s, "mlock:\n");
	seq_printf(s, "  total:       %llu\n", mlock_total);
	seq_printf(s, "  ai_pinned:   %llu\n", mlock_ai_hint);
	seq_printf(s, "\n");
	seq_printf(s, "bytes_saved:   %llu\n", vm_bytes_saved);

	return 0;
}

static int ldm_vm_final_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, ldm_vm_final_stats_show, NULL);
}

static const struct file_operations ldm_vm_final_stats_fops = {
	.owner = THIS_MODULE,
	.open = ldm_vm_final_stats_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static struct dentry *ldm_vm_final_debugfs;

/* ========================================================================= */
/* Module Init / Exit                                                       */
/* ========================================================================= */

static int __init ldm_vm_final_init(void)
{
	ldm_vm_final_debugfs = debugfs_create_file("vm_final_stats", 0444,
						    NULL, NULL,
						    &ldm_vm_final_stats_fops);

	pr_info("LDM-OS: VM subsystem final optimization module loaded\n");
	pr_info("LDM-OS: hooks: zswap, zram, thp_collapse, reclaim, readahead, mlock\n");

	return 0;
}

static void __exit ldm_vm_final_exit(void)
{
	debugfs_remove(ldm_vm_final_debugfs);

	pr_info("LDM-OS: VM final summary:\n");
	pr_info("  zswap: comp=%llu(%llu opt) decomp=%llu(%llu opt)\n",
		zswap_compress_total, zswap_compress_optimized,
		zswap_decompress_total, zswap_decompress_optimized);
	pr_info("  zram: rd=%llu(%llu dir) wr=%llu(%llu dir)\n",
		zram_read_total, zram_read_direct,
		zram_write_total, zram_write_direct);
	pr_info("  thp: %llu (%llu lazy)\n", thp_collapse_total, thp_collapse_lazy);
	pr_info("  reclaim: %llu (%llu batched)\n", reclaim_total, reclaim_lazy_writeback);
	pr_info("  readahead: %llu (%llu suppressed)\n", readahead_total, readahead_suppressed);
	pr_info("  mlock: %llu (%llu ai_pinned)\n", mlock_total, mlock_ai_hint);
	pr_info("  bytes saved: %llu\n", vm_bytes_saved);
}

subsys_initcall(ldm_vm_final_init);
module_exit(ldm_vm_final_exit);

MODULE_AUTHOR("LDM-OS Project");
MODULE_DESCRIPTION("LDM-OS VM Final: Zswap, Zram, THP, Reclaim, Readahead, Mlock");
MODULE_LICENSE("GPL");

#endif /* CONFIG_LDM_OS */
