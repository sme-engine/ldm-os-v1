/* SPDX-License-Identifier: GPL-2.0 */
/*
 * LDM-OS v2: Memory Residency Operating System
 *
 * CORE DESIGN PRINCIPLE (v2 redesign):
 * =====================================
 * "Once data is loaded into memory, it STAYS there. The memory region's
 *  PURPOSE can change (user↔kernel↔cache↔device), but the DATA does not
 *  move between physical locations. External I/O is maximally lazy to
 *  keep memory in cache-resident state."
 *
 * This is fundamentally different from v1's "zero-copy transfer" model.
 * v2 focuses on MEMORY RESIDENCY + PURPOSE MUTATION:
 *
 *   1. ANCHOR: Once a page is populated with data, pin its physical location.
 *      Never migrate, never swap, never copy to another physical page unless
 *      absolutely forced by hardware constraints.
 *
 *   2. MORPH: Change what the page IS without moving what it CONTAINS.
 *      - User page → kernel buffer: remap PTE, don't copy
 *      - Kernel buffer → page cache: change page flags, don't copy
 *      - Page cache → DMA target: set IOMMU mapping, don't copy
 *      - Any state → any other state: in-place metadata change only
 *
 *   3. LAZY-IO: Defer all external exchange (disk/network/GPU) as long as
 *      possible. Keep data in CPU cache / main memory. Only flush when:
 *      - Explicit sync requested
 *      - Memory pressure forces eviction (LRU among anchored pages)
 *      - Device demands data via DMA fault
 *
 *   4. CACHE-AFFINITY: Prefer keeping anchored pages in LLC/cache.
 *      Use CLFLUSH/CLWB selectively. Avoid unnecessary invalidation.
 *      Track per-page access temperature for intelligent retention.
 *
 * OLD OS COMPATIBILITY:
 * All existing memcpy/copy_page/copy_to_user calls work unchanged.
 * LDM intercepts at hook points and applies residency logic transparently.
 * Applications see identical behavior; the kernel manages residency internally.
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#ifndef _LINUX_LDM_OS_H
#define _LINUX_LDM_OS_H

#include <linux/types.h>
#include <linux/mm_types.h>
#include <linux/spinlock.h>
#include <linux/refcount.h>
#include <linux/list.h>
#include <linux/kconfig.h>
#include <linux/compiler.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* Page Residency States                                                      */
/*                                                                            */
/* A page transitions through states WITHOUT moving data:                     */
/*   ANCHORED → MORPHED → LAZY_DIRTY → CACHE_HOT → DEVICE_MAPPED            */
/* Each state change is a metadata operation (PTE/flag update), not a copy.   */
/* ========================================================================= */

enum ldm_page_state {
	LDM_STATE_FREE = 0,		/* Not managed by LDM */
	LDM_STATE_ANCHORED,		/* Data loaded, physical location pinned */
	LDM_STATE_USER_MAPPED,		/* Anchored + mapped to user VMA */
	LDM_STATE_KERNEL_MAPPED,	/* Anchored + mapped to kernel space */
	LDM_STATE_CACHE_RESIDENT,	/* Anchored + in page cache (hot) */
	LDM_STATE_DEVICE_MAPPED,	/* Anchored + IOMMU/DMA mapped */
	LDM_STATE_LAZY_DIRTY,		/* Modified in-place, not yet flushed */
	LDM_STATE_LAZY_IO_PENDING,	/* Scheduled for deferred writeback */
	LDM_STATE_EVICTABLE,		/* Anchor released under memory pressure */
};

/* Page flags for residency tracking */
#define LDM_PF_ANCHORED		(1UL << 0)  /* Physical location is pinned */
#define LDM_PF_INPLACE_MOD	(1UL << 1)  /* Modified without relocation */
#define LDM_PF_CACHE_HOT	(1UL << 2)  /* Recently accessed, retain in cache */
#define LDM_PF_LAZY_WRITEBACK	(1UL << 3)  /* Dirty but writeback deferred */
#define LDM_PF_DEVICE_PINNED	(1UL << 4)  /* DMA/device has active reference */
#define LDM_PF_MORPH_USER	(1UL << 5)  /* Currently user-accessible */
#define LDM_PF_MORPH_KERNEL	(1UL << 6)  /* Currently kernel-accessible */
#define LDM_PF_MORPH_CACHE	(1UL << 7)  /* Currently in page cache */
#define LDM_PF_MORPH_DEVICE	(1UL << 8)  /* Currently device-mapped */
#define LDM_PF_NT_HINT		(1UL << 9)  /* Non-temporal access pattern */
#define LDM_PF_NO_MIGRATE	(1UL << 10) /* Block NUMA migration */
#define LDM_PF_NO_SWAP		(1UL << 11) /* Block swap-out */

/* Transfer mode flags (backward compat with v1 API) */
#define LDM_XFER_DMA		0x01
#define LDM_XFER_RDMA		0x02
#define LDM_XFER_IOMMU		0x04
#define LDM_XFER_ZEROCOPY	0x08
#define LDM_XFER_COW		0x10
#define LDM_XFER_INPLACE	0x20
#define LDM_XFER_NT		0x40
#define LDM_XFER_SW_FALLBACK	0x80
#define LDM_SHOULD_NT(len) ((len) >= LDM_NT_THRESHOLD)

/* Threshold defaults */
#ifndef LDM_ZEROCOPY_THRESHOLD
#define LDM_ZEROCOPY_THRESHOLD		65536
#endif
#ifndef LDM_NT_THRESHOLD
#define LDM_NT_THRESHOLD		262144
#endif
#ifndef LDM_BATCH_THRESHOLD
#define LDM_BATCH_THRESHOLD		1048576
#endif
#ifndef LDM_COW_FORK_THRESHOLD
#define LDM_COW_FORK_THRESHOLD		4096
#endif

/* Morph operations (purpose changes without data movement) */
enum ldm_morph_op {
	LDM_MORPH_USER_TO_KERNEL = 0,	/* Remap PTE to kernel VA */
	LDM_MORPH_KERNEL_TO_USER,	/* Remap PTE to user VA */
	LDM_MORPH_TO_CACHE,		/* Add to page cache radix tree */
	LDM_MORPH_FROM_CACHE,		/* Remove from page cache */
	LDM_MORPH_TO_DEVICE,		/* Create IOMMU/DMA mapping */
	LDM_MORPH_FROM_DEVICE,		/* Release IOMMU/DMA mapping */
	LDM_MORPH_MARK_DIRTY,		/* Mark in-place modification */
	LDM_MORPH_CLEAR_DIRTY,		/* Clear dirty after flush */
	LDM_MORPH_PROMOTE_HOT,		/* Promote to cache-hot tier */
	LDM_MORPH_DEMOTE_COLD,		/* Demote to evictable tier */
};

/* Lazy I/O modes */
#define LDM_LAZY_IO_NONE	0x00	/* No pending I/O */
#define LDM_LAZY_IO_WRITEBACK	0x01	/* Deferred write to backing store */
#define LDM_LAZY_IO_READAHEAD	0x02	/* Prefetch for anticipated access */
#define LDM_LAZY_IO_GPU_SYNC	0x04	/* Deferred GPU↔CPU sync */
#define LDM_LAZY_IO_NET_SEND	0x08	/* Deferred network transmission */

/* ========================================================================= */
/* Statistics                                                                 */
/* ========================================================================= */

struct ldm_stats {
	u64 pages_anchored;		/* Total pages currently anchored */
	u64 morph_operations;		/* Purpose changes performed */
	u64 morph_user_kernel;		/* User↔Kernel morphs */
	u64 morph_cache;		/* Cache residency morphs */
	u64 morph_device;		/* Device mapping morphs */
	u64 inplace_modifications;	/* In-place data changes (no copy) */
	u64 lazy_io_deferred;		/* I/O operations deferred */
	u64 lazy_io_flushed;		/* Deferred I/O actually executed */
	u64 cache_hits;			/* Access to cache-hot anchored page */
	u64 cache_misses;		/* Access requiring page fault/load */
	u64 evictions_forced;		/* Pages evicted under pressure */
	u64 bytes_copied_avoided;	/* Bytes NOT copied due to residency */
	u64 total_accesses;		/* Total page accesses tracked */
};

/* ========================================================================= */
/* Anchored Page Descriptor                                                   */
/*                                                                            */
/* Tracks one anchored physical page and its current purpose/state.           */
/* The physical page NEVER moves while anchored.                              */
/* ========================================================================= */


/* Backward compat: ldm_region (v1 API, maps to ldm_anchor in v2) */
struct ldm_region {
	struct list_head	list;
	unsigned long		vaddr_start;
	unsigned long		vaddr_end;
	unsigned long		pfn_origin;
	unsigned long		flags;
	u32			xfer_mode;
	u8			priority;
	refcount_t		refcount;
	spinlock_t		lock;
	unsigned long		cow_bitmap_pages;
	unsigned long		*cow_bitmap;
	dma_addr_t		hw_iova;
	unsigned long		sw_isolation_base;
	struct ldm_stats	stats;
};

/* Per-task state (v1 compat) */
struct ldm_task_state {
	struct list_head	regions;
	unsigned int		nr_regions;
	spinlock_t		lock;
	bool			enabled;
	u32			default_xfer_mode;
	u8			default_priority;
	struct ldm_stats	global_stats;
};

#define LDM_MAX_REGIONS		256
#define LDM_PRIO_CRITICAL	0
#define LDM_PRIO_HIGH		1
#define LDM_PRIO_NORMAL		2
#define LDM_PRIO_LAZY		3

struct ldm_anchor {
	struct list_head	list;		/* Per-process or global anchor list */
	unsigned long		pfn;		/* Physical frame number (IMMUTABLE) */
	enum ldm_page_state	state;		/* Current residency state */
	unsigned long		flags;		/* LDM_PF_* flags */
	refcount_t		refcount;	/* Active references (user+kernel+device) */
	spinlock_t		lock;

	/* Morph history: last N purpose transitions */
	u8			morph_history[8];
	u8			morph_idx;

	/* Access temperature for cache affinity */
	u64			last_access_ns;
	u32			access_count;
	u8			temperature;	/* 0=cold, 255=hot */

	/* Lazy I/O state */
	u32			lazy_io_pending;
	unsigned long		lazy_io_deadline_ns;

	/* Backing store info (for lazy writeback) */
	struct address_space	*mapping;
	pgoff_t			index;
};

/* ========================================================================= */
/* Per-Task Residency Context                                                 */
/* ========================================================================= */

struct ldm_task_ctx {
	struct list_head	anchors;	/* This task's anchored pages */
	unsigned int		nr_anchors;
	spinlock_t		lock;
	bool			enabled;
	struct ldm_stats	stats;
};

/* ========================================================================= */
/* Core API: Anchor / Morph / Lazy-IO                                        */
/* ========================================================================= */

/**
 * ldm_anchor_page - Pin a page at its current physical location
 *
 * Once anchored, the page will not be migrated, swapped, or copied.
 * Data can be modified in-place. Purpose can be changed via ldm_morph().
 *
 * @page: The page to anchor
 * @flags: Initial LDM_PF_* flags
 * @returns: Anchor descriptor, or ERR_PTR on failure
 */
struct ldm_anchor *ldm_anchor_page(struct page *page, unsigned long flags);

/**
 * ldm_release_anchor - Release anchor, allow normal VM management
 *
 * @anchor: Anchor to release
 */
void ldm_release_anchor(struct ldm_anchor *anchor);

/**
 * ldm_morph - Change page purpose WITHOUT moving data
 *
 * This is the core LDM v2 operation. It changes how a page is accessed
 * (user/kernel/cache/device) by modifying PTEs, page flags, and mappings,
 * but NEVER copies the underlying data.
 *
 * @anchor: The anchored page
 * @op: Morph operation (LDM_MORPH_*)
 * @ctx: Optional context (target VMA, device handle, etc.)
 * @returns: 0 on success, negative errno on failure
 */
int ldm_morph(struct ldm_anchor *anchor, enum ldm_morph_op op, void *ctx);

/**
 * ldm_inplace_modify - Mark page as modified in-place
 *
 * Records that data was changed at the anchored location without
 * triggering any copy or relocation. Sets LAZY_DIRTY flag.
 *
 * @anchor: The anchored page
 * @offset: Offset within page where modification occurred
 * @len: Length of modification
 */
void ldm_inplace_modify(struct ldm_anchor *anchor, unsigned int offset,
			unsigned int len);

/**
 * ldm_lazy_flush - Trigger deferred writeback for dirty anchored pages
 *
 * @anchor: Page to flush (NULL = flush all eligible)
 * @sync: If true, wait for completion; if false, schedule async
 * @returns: 0 on success
 */
int ldm_lazy_flush(struct ldm_anchor *anchor, bool sync);

/**
 * ldm_access_hint - Update access temperature for cache affinity
 *
 * Called on page access to track hotness. Hot pages are retained in
 * cache longer; cold pages are candidates for lazy eviction.
 *
 * @anchor: The accessed page
 * @write: True if this was a write access
 */
void ldm_access_hint(struct ldm_anchor *anchor, bool write);

/* ========================================================================= */
/* Compatibility Wrappers (Old OS API → LDM Residency)                       */
/*                                                                            */
/* These intercept traditional memory operations and apply residency logic.  */
/* Old applications work unchanged; LDM manages residency transparently.     */
/* ========================================================================= */

/**
 * ldm_memcpy_hook - Intercept memcpy for residency-aware copy
 *
 * Instead of copying data, attempts to share the source page via
 * anchor + morph. Falls back to real memcpy if sharing isn't possible.
 */
void *ldm_memcpy_hook(void *dst, const void *src, size_t len);

/**
 * ldm_copy_page_hook - Intercept copy_page for residency
 *
 * Instead of copying 4KB, anchors source and morphs destination mapping.
 */
void ldm_copy_page_hook(void *dst, const void *src);

/**
 * ldm_copy_to_user_hook - Intercept copy_to_user
 *
 * Morphs kernel page to user-accessible instead of copying.
 */
unsigned long ldm_copy_to_user_hook(void __user *to, const void *from,
				    unsigned long n);

/**
 * ldm_copy_from_user_hook - Intercept copy_from_user
 *
 * Anchors user page and morphs to kernel-accessible instead of copying.
 */
unsigned long ldm_copy_from_user_hook(void *to, const void __user *from,
				      unsigned long n);

/* ========================================================================= */
/* DebugFS / Sysfs Interface                                                  */
/* ========================================================================= */

void ldm_debugfs_init(void);
void ldm_debugfs_cleanup(void);
/* debugfs stats callback (implemented in ldm_core.c) */

/* ========================================================================= */
/* Init / Cleanup                                                             */
/* ========================================================================= */

int ldm_core_init(void);
void ldm_core_exit(void);
int ldm_task_init(struct task_struct *task);
void ldm_task_exit(struct task_struct *task);

#else /* !CONFIG_LDM_OS */

/* Stubs: zero overhead when LDM disabled */
static inline void *ldm_memcpy_hook(void *dst, const void *src, size_t len)
{ return memcpy(dst, src, len); }
static inline void ldm_copy_page_hook(void *dst, const void *src)
{ copy_page(dst, src); }
static inline unsigned long ldm_copy_to_user_hook(void __user *to,
	const void *from, unsigned long n)
{ return copy_to_user(to, from, n); }
static inline unsigned long ldm_copy_from_user_hook(void *to,
	const void __user *from, unsigned long n)
{ return copy_from_user(to, from, n); }

#endif /* CONFIG_LDM_OS */


/* Subsystem IDs for runtime control (v1 compat) */
enum ldm_subsystem {
	LDM_SUB_CORE = 0,
	LDM_SUB_LAZY,
	LDM_SUB_IOMMU,
	LDM_SUB_CACHE,
	LDM_SUB_NET,
	LDM_SUB_VFS,
	LDM_SUB_SCHED,
	LDM_SUB_BLOCK,
	LDM_SUB_VM,
	LDM_SUB_MAX,
};

/* Unified transfer API (v1 compat) */
int ldm_transfer(void *dst, const void *src, size_t len, u32 mode);
ssize_t ldm_transfer_batch(void *dst_vecs, void *src_vecs,
			    unsigned int nr_segs, size_t total_len, u32 mode);
int ldm_map_shared(unsigned long dst_vaddr, unsigned long src_pfn,
		    size_t len, unsigned long flags);

#endif /* _LINUX_LDM_OS_H */
