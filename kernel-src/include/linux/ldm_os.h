/* SPDX-License-Identifier: GPL-2.0 */
/*
 * LDM-OS: Low Data Movement Operating System
 *
 * Core header for the LDM subsystem. This framework provides:
 *   1. Zero-copy memory transfer primitives (DMA/RDMA/IOMMU abstraction)
 *   2. Lazy memory management (lazy copy, lazy update, lazy migration)
 *   3. Hardware address isolation with software fallback
 *   4. In-place computation support (data stays at origin)
 *   5. Compatibility API for legacy applications
 *
 * Design principle: "Data stays where it is; move references, not bytes."
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

/* ========================================================================= */
/* LDM Configuration                                                        */
/* ========================================================================= */

#ifdef CONFIG_LDM_OS

/* LDM priority levels — LDM operations get top scheduling priority */
#define LDM_PRIO_CRITICAL	0	/* Must complete before any other mem op */
#define LDM_PRIO_HIGH		1	/* Prefer over normal memcpy */
#define LDM_PRIO_NORMAL		2	/* Standard LDM operation */
#define LDM_PRIO_LAZY		3	/* Can be deferred indefinitely */

/* LDM transfer modes */
#define LDM_XFER_DMA		0x01	/* Hardware DMA engine */
#define LDM_XFER_RDMA		0x02	/* Remote DMA (network/storage) */
#define LDM_XFER_IOMMU		0x04	/* IOMMU-mapped direct access */
#define LDM_XFER_ZEROCOPY	0x08	/* Reference transfer, no data move */
#define LDM_XFER_COW		0x10	/* Copy-on-write (lazy copy) */
#define LDM_XFER_INPLACE	0x20	/* Compute at data's current location */
#define LDM_XFER_SW_FALLBACK	0x80	/* Software fallback (no HW accel) */

/* LDM page flags (stored in page->private for LDM-managed pages) */
#define LDM_PAGE_LAZY_COPY	(1UL << 0)	/* Page is a lazy COW copy */
#define LDM_PAGE_PINNED_ORIGIN	(1UL << 1)	/* Original page pinned in place */
#define LDM_PAGE_HW_ISOLATED	(1UL << 2)	/* Hardware address isolated */
#define LDM_PAGE_SW_ISOLATED	(1UL << 3)	/* Software-simulated isolation */
#define LDM_PAGE_DIRTY_LAZY	(1UL << 4)	/* Dirty but update deferred */
#define LDM_PAGE_CACHE_LAZY	(1UL << 5)	/* Cache line update deferred */
#define LDM_PAGE_INPLACE_COMP	(1UL << 6)	/* In-place computation active */

/* Maximum number of LDM regions per process */
#define LDM_MAX_REGIONS		256

/* Statistics counters */
struct ldm_stats {
	u64 zerocopy_transfers;		/* Number of zero-copy operations */
	u64 lazy_copies;		/* Lazy COW copies created */
	u64 lazy_copy_faults;		/* COW faults that triggered real copy */
	u64 hw_dma_transfers;		/* Hardware DMA transfers used */
	u64 sw_fallback_transfers;	/* Software fallback transfers */
	u64 inplace_computations;	/* In-place computation operations */
	u64 lazy_cache_updates;		/* Deferred cache updates */
	u64 lazy_cache_flushes;		/* Actual cache flushes performed */
	u64 iommu_mappings;		/* IOMMU direct mappings created */
	u64 bytes_saved;		/* Estimated bytes NOT copied */
	u64 total_transfer_requests;	/* Total transfer requests */
};

/* ========================================================================= */
/* LDM Memory Region                                                        */
/* ========================================================================= */

/**
 * struct ldm_region - A memory region managed by LDM
 *
 * Represents a contiguous virtual memory area where LDM policies apply.
 * Data within this region is kept at its physical origin whenever possible.
 */
struct ldm_region {
	struct list_head	list;		/* Link in process ldm_regions */
	unsigned long		vaddr_start;	/* Virtual address range start */
	unsigned long		vaddr_end;	/* Virtual address range end */
	unsigned long		pfn_origin;	/* Origin PFN (data stays here) */
	unsigned long		flags;		/* LDM_PAGE_* flags */
	u32			xfer_mode;	/* Preferred transfer mode */
	u8			priority;	/* LDM_PRIO_* */
	refcount_t		refcount;	/* Reference count */
	spinlock_t		lock;		/* Protects flag changes */

	/* Lazy copy tracking */
	unsigned long		cow_bitmap_pages; /* Pages in COW bitmap */
	unsigned long		*cow_bitmap;	/* Per-page COW status bitmap */

	/* IOMMU / address isolation */
	dma_addr_t		hw_iova;	/* IOMMU IO virtual address */
	unsigned long		sw_isolation_base; /* Software isolation base */

	/* Statistics for this region */
	struct ldm_stats	stats;
};

/* ========================================================================= */
/* LDM Per-Process State                                                    */
/* ========================================================================= */

/**
 * struct ldm_task_state - Per-task LDM state
 *
 * Attached to task_struct via ldm_task field. Tracks all LDM regions
 * and policies for a process.
 */
struct ldm_task_state {
	struct list_head	regions;	/* List of ldm_region */
	unsigned int		nr_regions;	/* Number of active regions */
	spinlock_t		lock;		/* Protects region list */
	bool			enabled;	/* LDM enabled for this task */
	u32			default_xfer_mode; /* Default transfer mode */
	u8			default_priority;  /* Default priority */
	struct ldm_stats	global_stats;	/* Aggregate statistics */
};

/* ========================================================================= */
/* Core API                                                                 */
/* ========================================================================= */

/* Initialization / cleanup */
int ldm_init(void);
void ldm_exit(void);
int ldm_task_init(struct task_struct *task);
void ldm_task_exit(struct task_struct *task);

/* Region management */
struct ldm_region *ldm_create_region(unsigned long vaddr, unsigned long len,
				      u32 xfer_mode, u8 priority);
int ldm_destroy_region(struct ldm_region *region);
struct ldm_region *ldm_find_region(unsigned long vaddr);

/* Zero-copy transfer */
int ldm_zerocopy_transfer(void *dst, const void *src, size_t len,
			   u32 xfer_mode);
int ldm_zerocopy_map(unsigned long dst_vaddr, unsigned long src_pfn,
		      size_t len, u32 flags);

/* Lazy copy (COW) */
int ldm_lazy_copy(unsigned long dst_vaddr, unsigned long src_vaddr,
		   size_t len);
int ldm_lazy_copy_fault_handler(struct vm_area_struct *vma,
				 unsigned long addr, unsigned long pfn);

/* In-place computation */
int ldm_inplace_compute(unsigned long vaddr, size_t len,
			 int (*compute_fn)(void *data, size_t len, void *ctx),
			 void *ctx);

/* Address isolation */
int ldm_isolate_address(unsigned long vaddr, size_t len, bool use_hw);
int ldm_deisolate_address(unsigned long vaddr, size_t len);
bool ldm_is_isolated(unsigned long vaddr);

/* Lazy cache management */
int ldm_cache_lazy_update(unsigned long vaddr, size_t len);
int ldm_cache_force_flush(unsigned long vaddr, size_t len);

/* Statistics */
void ldm_get_stats(struct ldm_stats *out);
void ldm_print_stats(void);

/* Sysfs interface */
int ldm_sysfs_init(void);
void ldm_sysfs_exit(void);

#else /* !CONFIG_LDM_OS */

/* Stubs when LDM is disabled */
static inline int ldm_init(void) { return 0; }
static inline void ldm_exit(void) {}
static inline int ldm_task_init(struct task_struct *task) { return 0; }
static inline void ldm_task_exit(struct task_struct *task) {}

#endif /* CONFIG_LDM_OS */

#endif /* _LINUX_LDM_OS_H */
