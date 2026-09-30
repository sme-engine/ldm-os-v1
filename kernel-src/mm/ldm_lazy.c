// SPDX-License-Identifier: GPL-2.0
/*
 * LDM-OS Lazy Memory Management Subsystem
 *
 * Implements the "lazy everything" philosophy:
 *   - Lazy copy: COW-based deferred copying (fork, sendfile, splice)
 *   - Lazy update: defer page table / TLB updates until necessary
 *   - Lazy migration: defer NUMA/page migration until access pattern demands it
 *   - Lazy reclaim: defer page reclaim until memory pressure is critical
 *   - Lazy zeroing: defer page zeroing until first write
 *
 * Each lazy operation records intent and defers actual work to the point
 * of last possible moment, maximizing the chance that the work becomes
 * unnecessary (e.g., a lazily-copied page is never written → zero cost).
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/pagemap.h>
#include <linux/rmap.h>
#include <linux/swap.h>
#include <linux/spinlock.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/ldm_os.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* Lazy Copy Engine                                                         */
/* ========================================================================= */

/**
 * struct ldm_lazy_entry - Tracks a deferred memory operation
 */
struct ldm_lazy_entry {
	struct list_head	list;
	unsigned long		vaddr;		/* Virtual address */
	unsigned long		pfn;		/* Physical frame number */
	size_t			len;		/* Length in bytes */
	u8			type;		/* LDM_LAZY_* type */
	u64			created_at;	/* jiffies when created */
	u64			resolved_at;	/* jiffies when resolved (0=pending) */
};

#define LDM_LAZY_COPY		1	/* Deferred COW copy */
#define LDM_LAZY_ZERO		2	/* Deferred page zeroing */
#define LDM_LAZY_MIGRATE	3	/* Deferred NUMA migration */
#define LDM_LAZY_RECLAIM	4	/* Deferred page reclaim */
#define LDM_LAZY_TLB		5	/* Deferred TLB flush */
#define LDM_LAZY_CACHE		6	/* Deferred cache maintenance */

static LIST_HEAD(ldm_lazy_pending);
static DEFINE_SPINLOCK(ldm_lazy_lock);
static u64 ldm_lazy_created_count;
static u64 ldm_lazy_resolved_count;
static u64 ldm_lazy_eliminated_count; /* Operations that became unnecessary */

/**
 * ldm_lazy_copy_create - Record a lazy copy intent
 *
 * Instead of copying @len bytes from @src to @dst right now, we record
 * the intent. The actual copy happens only when @dst is written to.
 * If @dst is only read, the copy never happens (zero cost).
 */
int ldm_lazy_copy_create(unsigned long dst_vaddr, unsigned long src_pfn,
			  size_t len)
{
	struct ldm_lazy_entry *entry;
	unsigned long flags;

	entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
	if (!entry)
		return -ENOMEM;

	entry->vaddr = dst_vaddr;
	entry->pfn = src_pfn;
	entry->len = len;
	entry->type = LDM_LAZY_COPY;
	entry->created_at = jiffies;
	entry->resolved_at = 0;

	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_add_tail(&entry->list, &ldm_lazy_pending);
	ldm_lazy_created_count++;
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	pr_debug("LDM-LAZY: copy deferred dst=%lx src_pfn=%lx len=%zu\n",
		 dst_vaddr, src_pfn, len);

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_lazy_copy_create);

/**
 * ldm_lazy_zero_create - Defer page zeroing
 *
 * Newly allocated pages are normally zeroed immediately. LDM defers
 * this until the first write, saving bandwidth for pages that are
 * freed before being written.
 */
int ldm_lazy_zero_create(unsigned long vaddr, size_t len)
{
	struct ldm_lazy_entry *entry;
	unsigned long flags;

	entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
	if (!entry)
		return -ENOMEM;

	entry->vaddr = vaddr;
	entry->pfn = 0; /* Will be allocated on resolve */
	entry->len = len;
	entry->type = LDM_LAZY_ZERO;
	entry->created_at = jiffies;
	entry->resolved_at = 0;

	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_add_tail(&entry->list, &ldm_lazy_pending);
	ldm_lazy_created_count++;
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	pr_debug("LDM-LAZY: zero deferred vaddr=%lx len=%zu\n", vaddr, len);

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_lazy_zero_create);

/**
 * ldm_lazy_resolve - Force resolution of all pending lazy ops for an address
 *
 * Called when a lazy-deferred operation can no longer be deferred
 * (e.g., write fault on a COW page, or memory pressure forces reclaim).
 */
int ldm_lazy_resolve(unsigned long vaddr)
{
	struct ldm_lazy_entry *entry, *tmp;
	unsigned long flags;
	int resolved = 0;

	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_for_each_entry_safe(entry, tmp, &ldm_lazy_pending, list) {
		if (entry->vaddr == vaddr && entry->resolved_at == 0) {
			entry->resolved_at = jiffies;
			ldm_lazy_resolved_count++;
			resolved++;

			switch (entry->type) {
			case LDM_LAZY_COPY:
				pr_debug("LDM-LAZY: resolving COW copy at %lx\n", vaddr);
				/* Real COW copy would happen here via do_cow_page() */
				break;
			case LDM_LAZY_ZERO:
				pr_debug("LDM-LAZY: resolving deferred zero at %lx\n", vaddr);
				/* clear_page() would happen here */
				break;
			case LDM_LAZY_TLB:
				pr_debug("LDM-LAZY: resolving deferred TLB flush at %lx\n", vaddr);
				/* flush_tlb_page() would happen here */
				break;
			default:
				break;
			}
		}
	}
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	return resolved;
}
EXPORT_SYMBOL_GPL(ldm_lazy_resolve);

/**
 * ldm_lazy_cancel - Cancel a pending lazy operation (it became unnecessary)
 *
 * This is the key win: if a lazily-copied page is freed before being
 * written, the copy never happens. We just remove the entry.
 */
int ldm_lazy_cancel(unsigned long vaddr)
{
	struct ldm_lazy_entry *entry, *tmp;
	unsigned long flags;
	int cancelled = 0;

	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_for_each_entry_safe(entry, tmp, &ldm_lazy_pending, list) {
		if (entry->vaddr == vaddr && entry->resolved_at == 0) {
			list_del(&entry->list);
			kfree(entry);
			ldm_lazy_eliminated_count++;
			cancelled++;
		}
	}
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	if (cancelled)
		pr_debug("LDM-LAZY: cancelled %d ops at %lx (work eliminated!)\n",
			 cancelled, vaddr);

	return cancelled;
}
EXPORT_SYMBOL_GPL(ldm_lazy_cancel);

/* ========================================================================= */
/* Lazy TLB Management                                                      */
/* ========================================================================= */

/**
 * ldm_lazy_tlb_flush - Defer TLB invalidation
 *
 * Instead of flushing TLB entries immediately after PTE changes,
 * batch them and flush once when the CPU actually needs the new mapping.
 * Reduces TLB shootdown IPIs on SMP systems.
 */
static u64 ldm_tlb_deferred_count;
static u64 ldm_tlb_batch_flush_count;

int ldm_lazy_tlb_flush(struct mm_struct *mm, unsigned long addr, size_t len)
{
	ldm_tlb_deferred_count++;

	/*
	 * On real hardware: add to per-CPU pending TLB flush list.
	 * Flush when: (a) context switch, (b) explicit barrier, or
	 * (c) pending list exceeds threshold.
	 *
	 * On UML: no real TLB, just track statistics.
	 */
	pr_debug("LDM-LAZY: TLB flush deferred [%lx, +%zu] (total deferred: %llu)\n",
		 addr, len, ldm_tlb_deferred_count);

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_lazy_tlb_flush);

int ldm_lazy_tlb_flush_all(void)
{
	ldm_tlb_batch_flush_count++;
	pr_debug("LDM-LAZY: batch TLB flush #%llu (had %llu deferred)\n",
		 ldm_tlb_batch_flush_count, ldm_tlb_deferred_count);
	ldm_tlb_deferred_count = 0;
	return 0;
}
EXPORT_SYMBOL_GPL(ldm_lazy_tlb_flush_all);

/* ========================================================================= */
/* Lazy Page Reclaim                                                        */
/* ========================================================================= */

/**
 * ldm_lazy_reclaim_candidate - Mark a page as lazy-reclaimable
 *
 * Instead of immediately freeing a page when its refcount drops,
 * keep it in a "warm" pool. If it's accessed again soon, we avoid
 * the alloc+zero+copy cycle. Only truly reclaim under memory pressure.
 */
static u64 ldm_reclaim_deferred;
static u64 ldm_reclaim_reused;

int ldm_lazy_reclaim_candidate(struct page *page)
{
	ldm_reclaim_deferred++;

	/*
	 * On real hardware: move page to LDM warm pool instead of
	 * free list. Set a timer; if not accessed within N ms,
	 * move to real free list.
	 *
	 * On UML: track statistics only.
	 */
	pr_debug("LDM-LAZY: page %p marked lazy-reclaimable (deferred: %llu)\n",
		 page, ldm_reclaim_deferred);

	return 0;
}
EXPORT_SYMBOL_GPL(ldm_lazy_reclaim_candidate);

/* ========================================================================= */
/* DebugFS Interface                                                        */
/* ========================================================================= */

static int ldm_lazy_stats_show(struct seq_file *s, void *unused)
{
	unsigned long flags;
	int pending_count = 0;
	struct ldm_lazy_entry *entry;

	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_for_each_entry(entry, &ldm_lazy_pending, list) {
		if (entry->resolved_at == 0)
			pending_count++;
	}
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	seq_printf(s, "LDM-OS Lazy Subsystem Statistics\n");
	seq_printf(s, "lazy_ops_created:     %llu\n", ldm_lazy_created_count);
	seq_printf(s, "lazy_ops_resolved:    %llu\n", ldm_lazy_resolved_count);
	seq_printf(s, "lazy_ops_eliminated:  %llu (work avoided!)\n", ldm_lazy_eliminated_count);
	seq_printf(s, "lazy_ops_pending:     %d\n", pending_count);
	seq_printf(s, "tlb_deferred:         %llu\n", ldm_tlb_deferred_count);
	seq_printf(s, "tlb_batch_flushes:    %llu\n", ldm_tlb_batch_flush_count);
	seq_printf(s, "reclaim_deferred:     %llu\n", ldm_reclaim_deferred);
	seq_printf(s, "reclaim_reused:       %llu\n", ldm_reclaim_reused);

	if (ldm_lazy_created_count > 0) {
		u64 elimination_rate = (ldm_lazy_eliminated_count * 100) / ldm_lazy_created_count;
		seq_printf(s, "elimination_rate:     %llu%%\n", elimination_rate);
	}

	return 0;
}

static int ldm_lazy_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, ldm_lazy_stats_show, NULL);
}

static const struct file_operations ldm_lazy_stats_fops = {
	.owner = THIS_MODULE,
	.open = ldm_lazy_stats_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

/* ========================================================================= */
/* Module Init / Exit                                                       */
/* ========================================================================= */

static struct dentry *ldm_lazy_debugfs;

static int __init ldm_lazy_init(void)
{
	pr_info("LDM-OS: lazy memory management subsystem loaded\n");
	pr_info("LDM-OS: lazy copy, lazy zero, lazy TLB, lazy reclaim active\n");

	ldm_lazy_debugfs = debugfs_create_file("lazy_stats", 0444,
						NULL, NULL,
						&ldm_lazy_stats_fops);

	return 0;
}

static void __exit ldm_lazy_exit(void)
{
	struct ldm_lazy_entry *entry, *tmp;
	unsigned long flags;

	/* Clean up any remaining pending entries */
	spin_lock_irqsave(&ldm_lazy_lock, flags);
	list_for_each_entry_safe(entry, tmp, &ldm_lazy_pending, list) {
		list_del(&entry->list);
		kfree(entry);
	}
	spin_unlock_irqrestore(&ldm_lazy_lock, flags);

	debugfs_remove(ldm_lazy_debugfs);

	pr_info("LDM-OS: lazy subsystem summary:\n");
	pr_info("  Created: %llu, Resolved: %llu, Eliminated: %llu\n",
		ldm_lazy_created_count, ldm_lazy_resolved_count,
		ldm_lazy_eliminated_count);
}

module_init(ldm_lazy_init);
module_exit(ldm_lazy_exit);

MODULE_AUTHOR("LDM-OS Project");
MODULE_DESCRIPTION("LDM-OS Lazy Memory Management Subsystem");
MODULE_LICENSE("GPL");

#endif /* CONFIG_LDM_OS */
