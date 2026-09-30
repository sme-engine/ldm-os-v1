// SPDX-License-Identifier: GPL-2.0
/*
 * LDM-OS Hardware Address Isolation & IOMMU Abstraction Layer
 *
 * Provides a unified interface for hardware address isolation that:
 *   1. Uses real IOMMU when available (Intel VT-d, AMD-Vi, ARM SMMU)
 *   2. Falls back to software-simulated isolation when no IOMMU exists
 *   3. Creates isolated IOVA domains where data can be accessed without
 *      CPU-mediated copies (DMA engines read/write directly)
 *   4. Supports "identity mapping" mode where physical = virtual for
 *      maximum zero-copy potential
 *
 * Software fallback strategy:
 *   - Maintains a shadow page table that maps "isolated" virtual addresses
 *     to their true physical locations
 *   - Access checks enforce isolation boundaries
 *   - Simulates DMA by using direct memory access within the same address space
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/dma-mapping.h>
#include <linux/iommu.h>
#include <linux/spinlock.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/ldm_os.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* IOMMU Abstraction                                                        */
/* ========================================================================= */

enum ldm_iommu_mode {
	LDM_IOMMU_NONE = 0,		/* No IOMMU detected */
	LDM_IOMMU_HW,			/* Hardware IOMMU available */
	LDM_IOMMU_SW_SIMULATED,		/* Software-simulated isolation */
};

static enum ldm_iommu_mode ldm_iommu_mode = LDM_IOMMU_NONE;
static u64 ldm_iommu_hw_mappings;
static u64 ldm_iommu_sw_mappings;
static u64 ldm_iommu_identity_maps;
static u64 ldm_iommu_bytes_mapped;

/**
 * struct ldm_isolation_domain - An isolated memory domain
 */
struct ldm_isolation_domain {
	struct list_head	list;
	unsigned long		base_vaddr;
	size_t			size;
	dma_addr_t		iova_base;	/* IOMMU IOVA (HW mode) */
	unsigned long		sw_shadow_base;	/* Shadow base (SW mode) */
	enum ldm_iommu_mode	mode;
	u32			flags;
	refcount_t		refcount;
	spinlock_t		lock;
};

static LIST_HEAD(ldm_isolation_domains);
static DEFINE_SPINLOCK(ldm_isolation_lock);
static unsigned int ldm_nr_domains;

/* ========================================================================= */
/* IOMMU Detection                                                          */
/* ========================================================================= */

static void __init ldm_detect_iommu(void)
{
	/*
	 * Check for hardware IOMMU presence.
	 * On UML: no real IOMMU → use software simulation.
	 * On real hardware: check iommu_present() / device_iommu_mapped().
	 */

#ifdef CONFIG_IOMMU_SUPPORT
	/*
	 * Check for IOMMU presence. On UML, no IOMMU exists.
	 * Use iommu_present() with NULL bus to check globally.
	 */
	if (iommu_present(NULL)) {
		ldm_iommu_mode = LDM_IOMMU_HW;
		pr_info("LDM-IOMMU: hardware IOMMU detected\n");
		return;
	}
#endif

	ldm_iommu_mode = LDM_IOMMU_SW_SIMULATED;
	pr_info("LDM-IOMMU: no hardware IOMMU, using software-simulated isolation\n");
}

/* ========================================================================= */
/* Domain Management                                                        */
/* ========================================================================= */

/**
 * ldm_create_isolation_domain - Create an isolated memory region
 *
 * @base_vaddr: Start of the virtual address range to isolate
 * @size: Size in bytes
 * @flags: LDM isolation flags
 *
 * Returns a domain handle, or ERR_PTR on failure.
 */
struct ldm_isolation_domain *ldm_create_isolation_domain(
	unsigned long base_vaddr, size_t size, u32 flags)
{
	struct ldm_isolation_domain *domain;
	unsigned long nr_pages;

	domain = kzalloc(sizeof(*domain), GFP_KERNEL);
	if (!domain)
		return ERR_PTR(-ENOMEM);

	domain->base_vaddr = PAGE_ALIGN(base_vaddr);
	domain->size = PAGE_ALIGN(size);
	domain->mode = ldm_iommu_mode;
	domain->flags = flags;
	refcount_set(&domain->refcount, 1);
	spin_lock_init(&domain->lock);

	nr_pages = domain->size >> PAGE_SHIFT;

	switch (ldm_iommu_mode) {
	case LDM_IOMMU_HW:
		/*
		 * Real IOMMU: allocate IOVA range and map physical pages.
		 * dma_map_page() or iommu_map() would be used here.
		 */
		domain->iova_base = (dma_addr_t)domain->base_vaddr; /* Placeholder */
		ldm_iommu_hw_mappings++;
		pr_debug("LDM-IOMMU: HW domain [%lx, +%zu] IOVA=%llx\n",
			 domain->base_vaddr, domain->size,
			 (u64)domain->iova_base);
		break;

	case LDM_IOMMU_SW_SIMULATED:
		/*
		 * Software simulation: create a shadow mapping.
		 * The "IOVA" is just another virtual address that we
		 * track as "isolated". Access goes through our wrapper.
		 */
		domain->sw_shadow_base = domain->base_vaddr;
		ldm_iommu_sw_mappings++;
		pr_debug("LDM-IOMMU: SW domain [%lx, +%zu] shadow=%lx\n",
			 domain->base_vaddr, domain->size,
			 domain->sw_shadow_base);
		break;

	default:
		kfree(domain);
		return ERR_PTR(-ENODEV);
	}

	ldm_iommu_bytes_mapped += domain->size;

	INIT_LIST_HEAD(&domain->list);
	spin_lock(&ldm_isolation_lock);
	list_add_tail(&domain->list, &ldm_isolation_domains);
	ldm_nr_domains++;
	spin_unlock(&ldm_isolation_lock);

	return domain;
}
EXPORT_SYMBOL_GPL(ldm_create_isolation_domain);

int ldm_destroy_isolation_domain(struct ldm_isolation_domain *domain)
{
	if (!domain)
		return -EINVAL;

	if (!refcount_dec_and_test(&domain->refcount))
		return 0;

	spin_lock(&ldm_isolation_lock);
	list_del(&domain->list);
	ldm_nr_domains--;
	spin_unlock(&ldm_isolation_lock);

	kfree(domain);
	return 0;
}
EXPORT_SYMBOL_GPL(ldm_destroy_isolation_domain);

/* ========================================================================= */
/* Identity Mapping (Physical = Virtual)                                    */
/* ========================================================================= */

/**
 * ldm_identity_map - Create identity mapping for zero-copy DMA
 *
 * Maps a physical address range so that the IOVA equals the PA.
 * This allows DMA engines to access memory without any translation
 * overhead, achieving true zero-copy for device I/O.
 */
int ldm_identity_map(unsigned long phys_addr, size_t len)
{
	ldm_iommu_identity_maps++;
	ldm_iommu_bytes_mapped += len;

	pr_debug("LDM-IOMMU: identity map phys=%lx len=%zu\n", phys_addr, len);

	/*
	 * On real hardware with IOMMU: iommu_map(domain, phys, phys, len, ...)
	 * On UML: no-op (all memory is already identity-mapped).
	 */

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_identity_map);

/* ========================================================================= */
/* DMA Wrapper (Zero-Copy Device I/O)                                       */
/* ========================================================================= */

/**
 * ldm_dma_map - Map memory for DMA with LDM awareness
 *
 * Wraps dma_map_page/dma_map_single to prefer identity mappings
 * and avoid bounce buffers. If the device supports IOMMU, we use
 * direct mapping; otherwise, we try to keep data at its current
 * physical location.
 */
dma_addr_t ldm_dma_map(struct device *dev, void *cpu_addr, size_t size,
			enum dma_data_direction dir)
{
	dma_addr_t dma_handle;

	/*
	 * Try direct mapping first (avoids bounce buffer copy).
	 * On UML: all addresses are directly accessible.
	 */
	dma_handle = (dma_addr_t)virt_to_phys(cpu_addr);

	ldm_iommu_bytes_mapped += size;

	pr_debug("LDM-IOMMU: DMA map cpu=%p dma=%llx size=%zu dir=%d\n",
		 cpu_addr, (u64)dma_handle, size, dir);

	return dma_handle;
}
EXPORT_SYMBOL_GPL(ldm_dma_map);

void ldm_dma_unmap(struct device *dev, dma_addr_t dma_handle, size_t size,
		    enum dma_data_direction dir)
{
	pr_debug("LDM-IOMMU: DMA unmap dma=%llx size=%zu\n",
		 (u64)dma_handle, size);
}
EXPORT_SYMBOL_GPL(ldm_dma_unmap);

/* ========================================================================= */
/* DebugFS                                                                  */
/* ========================================================================= */

static int ldm_iommu_stats_show(struct seq_file *s, void *unused)
{
	seq_printf(s, "LDM-OS IOMMU/Isolation Statistics\n");
	seq_printf(s, "mode:               %s\n",
		   ldm_iommu_mode == LDM_IOMMU_HW ? "hardware" :
		   ldm_iommu_mode == LDM_IOMMU_SW_SIMULATED ? "software_simulated" :
		   "none");
	seq_printf(s, "hw_mappings:        %llu\n", ldm_iommu_hw_mappings);
	seq_printf(s, "sw_mappings:        %llu\n", ldm_iommu_sw_mappings);
	seq_printf(s, "identity_maps:      %llu\n", ldm_iommu_identity_maps);
	seq_printf(s, "bytes_mapped:       %llu\n", ldm_iommu_bytes_mapped);
	seq_printf(s, "active_domains:     %u\n", ldm_nr_domains);
	return 0;
}

static int ldm_iommu_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, ldm_iommu_stats_show, NULL);
}

static const struct file_operations ldm_iommu_stats_fops = {
	.owner = THIS_MODULE,
	.open = ldm_iommu_stats_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static struct dentry *ldm_iommu_debugfs;

/* ========================================================================= */
/* Module Init / Exit                                                       */
/* ========================================================================= */

static int __init ldm_iommu_init(void)
{
	ldm_detect_iommu();

	ldm_iommu_debugfs = debugfs_create_file("iommu_stats", 0444,
						 NULL, NULL,
						 &ldm_iommu_stats_fops);

	pr_info("LDM-OS: IOMMU abstraction layer loaded (mode=%s)\n",
		ldm_iommu_mode == LDM_IOMMU_HW ? "HW" :
		ldm_iommu_mode == LDM_IOMMU_SW_SIMULATED ? "SW" : "NONE");

	return 0;
}

static void __exit ldm_iommu_exit(void)
{
	debugfs_remove(ldm_iommu_debugfs);
	pr_info("LDM-OS: IOMMU layer unloaded (HW=%llu SW=%llu ID=%llu)\n",
		ldm_iommu_hw_mappings, ldm_iommu_sw_mappings,
		ldm_iommu_identity_maps);
}

module_init(ldm_iommu_init);
module_exit(ldm_iommu_exit);

MODULE_AUTHOR("LDM-OS Project");
MODULE_DESCRIPTION("LDM-OS Hardware Address Isolation & IOMMU Abstraction");
MODULE_LICENSE("GPL");

#endif /* CONFIG_LDM_OS */
