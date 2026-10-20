// SPDX-License-Identifier: GPL-2.0
/*
 * LDM-OS Compatibility Layer
 *
 * Provides drop-in replacements for standard memory operations so that
 * existing applications and kernel code automatically benefit from LDM
 * without source modification.
 *
 * Strategy:
 *   - ldm_memcpy() replaces memcpy in hot paths via #define or wrapper
 *   - ldm_memmove() replaces memmove similarly
 *   - ldm_copy_page() replaces copy_user_highpage / copy_page
 *   - ldm_sendfile() provides zero-copy file-to-socket transfer
 *   - Legacy apps link against libldm_compat.so (userspace, future)
 *
 * Copyright (C) 2026 LDM-OS Project
 */

#include <linux/module.h>
#include <linux/string.h>
#include <linux/mm.h>
#include <linux/highmem.h>
#include <linux/pagemap.h>
#include <linux/uaccess.h>
#include <linux/ldm_os.h>

#ifdef CONFIG_LDM_OS

/* ========================================================================= */
/* LDM-Aware Memory Copy Primitives                                         */
/* ========================================================================= */


/**
 * ldm_memmove - LDM-aware memmove with overlap detection
 *
 * For overlapping regions, we must use a real copy (can't COW).
 * For non-overlapping, delegates to ldm_memcpy.
 */
void *ldm_memmove(void *dst, const void *src, size_t len)
{
	unsigned long d = (unsigned long)dst;
	unsigned long s = (unsigned long)src;

	if (len == 0)
		return dst;

	/* Check for overlap */
	if ((d < s && d + len > s) || (s < d && s + len > d)) {
		/* Overlapping: must use real memmove */
		memmove(dst, src, len);
		return dst;
	}

	/* Non-overlapping: use LDM zero-copy path */
	return ldm_memcpy(dst, src, len);
}
EXPORT_SYMBOL_GPL(ldm_memmove);

/**
 * ldm_copy_page - LDM-aware page copy
 *
 * Replaces copy_page() / copy_user_highpage() in the page allocator
 * and fork() paths. Uses lazy COW when possible.
 */
void ldm_copy_page(void *dst, const void *src)
{
	/*
	 * Page copies are the #1 source of memory bandwidth waste.
	 * In fork(), every page is copied even though most are never
	 * written by the child. LDM makes this lazy.
	 *
	 * For now, we do a real copy but track it. Future: integrate
	 * with do_cow_page() to make fork() truly zero-copy.
	 */
	copy_page(dst, (void *)src);

	pr_debug("LDM: copy_page %p -> %p (candidate for lazy COW)\n", src, dst);
}
EXPORT_SYMBOL_GPL(ldm_copy_page);

/**
 * ldm_copy_to_user - LDM-aware copy_to_user
 *
 * Attempts to map kernel pages directly into user space instead
 * of copying through the CPU.
 */
unsigned long ldm_copy_to_user(void __user *to, const void *from, unsigned long n)
{
	/*
	 * On UML: direct memory access, no real user/kernel boundary.
	 * On real hardware: would attempt remap_pfn_range() for large
	 * transfers, falling back to __copy_to_user() for small ones.
	 */
	if (n <= 64) {
		return copy_to_user(to, from, n);
	}

	/* Large transfer: try LDM zero-copy mapping */
	ldm_zerocopy_transfer((void __force *)to, from, n,
			       LDM_XFER_ZEROCOPY | LDM_XFER_SW_FALLBACK);
	return 0;
}
EXPORT_SYMBOL_GPL(ldm_copy_to_user);


/* ========================================================================= */
/* Socket / Network Zero-Copy                                               */
/* ========================================================================= */

/**
 * ldm_skb_zerocopy_headlen - Calculate zero-copy-safe head length
 *
 * For network packets, avoid copying skb head data by keeping it
 * at its original location and using scatter-gather references.
 */
int ldm_skb_zerocopy_headlen(size_t total_len)
{
	/*
	 * Keep headers (typically < 128 bytes) in-place.
	 * Payload uses zero-copy page references.
	 */
	if (total_len <= 128)
		return total_len; /* Small packet: keep all in-place */

	return 128; /* Headers only; payload via page refs */
}
EXPORT_SYMBOL_GPL(ldm_skb_zerocopy_headlen);

/* ========================================================================= */
/* Module Registration                                                      */
/* ========================================================================= */

static int __init ldm_compat_init(void)
{
	pr_info("LDM-OS: compatibility layer loaded\n");
	pr_info("LDM-OS: ldm_memcpy, ldm_memmove, ldm_copy_page available\n");
	pr_info("LDM-OS: legacy apps can use these as drop-in replacements\n");
	return 0;
}

static void __exit ldm_compat_exit(void)
{
	pr_info("LDM-OS: compatibility layer unloaded\n");
}

module_init(ldm_compat_init);
module_exit(ldm_compat_exit);

MODULE_AUTHOR("LDM-OS Project");
MODULE_DESCRIPTION("LDM-OS Compatibility Layer for Legacy Applications");
MODULE_LICENSE("GPL");

#endif /* CONFIG_LDM_OS */
