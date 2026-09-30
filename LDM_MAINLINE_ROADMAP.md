# LDM-OS Linux Mainline Integration Roadmap

> Version: 1.0 | Date: 2026-09-21
> Target: Linux 6.x mainline kernel

## Patch Series Structure (15 patches)

```
Patch 01/15: mm: introduce LDM subsystem framework and sysctl interface
  Files: mm/Kconfig.ldm, mm/Makefile.ldm, mm/ldm_core.c, include/linux/ldm_os.h
  Size: ~800 lines
  Depends: none

Patch 02/15: mm/ldm: add memory anchoring and morph API
  Files: mm/ldm_core.c (anchor/morph/share functions)
  Size: ~400 lines
  Depends: 01

Patch 03/15: mm/ldm: add lazy zero and lazy COW engine
  Files: mm/ldm_lazy.c
  Size: ~375 lines
  Depends: 01, 02

Patch 04/15: mm/ldm: add IOMMU abstraction layer
  Files: mm/ldm_iommu.c
  Size: ~326 lines
  Depends: 01

Patch 05/15: mm/ldm: add cache affinity optimization
  Files: mm/ldm_cache.c
  Size: ~248 lines
  Depends: 01

Patch 06/15: mm/ldm: add compatibility wrappers for legacy apps
  Files: mm/ldm_compat.c
  Size: ~216 lines
  Depends: 01, 02

Patch 07/15: mm/ldm: add first-pass kernel path hooks
  Files: mm/ldm_hooks.c
  Size: ~349 lines
  Depends: 01, 02, 06

Patch 08/15: mm/ldm: add second-pass deep optimization hooks
  Files: mm/ldm_deep_hooks.c
  Size: ~394 lines
  Depends: 07

Patch 09/15: net/ldm: add network stack zero-copy optimization
  Files: mm/ldm_net.c
  Size: ~484 lines
  Depends: 01, 07

Patch 10/15: fs/ldm: add VFS and I/O zero-copy optimization
  Files: mm/ldm_vfs.c
  Size: ~421 lines
  Depends: 01, 07

Patch 11/15: mm/ldm: add scheduler and block device optimization
  Files: mm/ldm_sched_block.c
  Size: ~414 lines
  Depends: 01, 07

Patch 12/15: mm/ldm: add advanced MM features (migration, shmem, swap)
  Files: mm/ldm_mm_advanced.c
  Size: ~418 lines
  Depends: 01, 03

Patch 13/15: mm/ldm: add VM subsystem optimization (zswap, THP, reclaim)
  Files: mm/ldm_vm_final.c
  Size: ~455 lines
  Depends: 01, 03, 12

Patch 14/15: Documentation/admin-guide: add LDM-OS documentation
  Files: Documentation/admin-guide/ldm-os.rst
  Size: ~300 lines
  Depends: 01

Patch 15/15: MAINTAINERS: add LDM-OS entry
  Files: MAINTAINERS
  Size: ~10 lines
  Depends: 01
```

## Timeline & Milestones

```
Phase 1: Preparation (Week 1-2)
├── [DONE] Code cleanup to CodingStyle compliance
├── [DONE] Add kdoc comments to all exported functions
├── [DONE] Create Kconfig with tristate support
├── [DONE] Add sysctl runtime interface
├── [TODO] Run checkpatch.pl on all patches
└── [TODO] Verify build on x86_64 + arm64 + riscv

Phase 2: RFC Submission (Week 3-4)
├── [TODO] Send RFC to linux-mm@kvack.org
├── [TODO] CC: Andrew Morton, Matthew Wilcox, David Hildenbrand
├── [TODO] Include benchmark results (x86 UML + arm64 Kunpeng)
└── [TODO] Respond to initial feedback (2-4 weeks)

Phase 3: v1 Patchset (Month 2-3)
├── [TODO] Incorporate RFC feedback
├── [TODO] Split into 15 clean patches
├── [TODO] Add selftests under tools/testing/selftests/ldm/
├── [TODO] Submit v1 patchset to linux-mm
└── [TODO] Iterate on review (expect 2-3 rounds)

Phase 4: Staging Entry (Month 3-5)
├── [TODO] If mm acceptance is slow, submit to drivers/staging/
├── [TODO] Greg KH review for staging
├── [TODO] Fix staging-specific issues
└── [TODO] Merge into staging tree

Phase 5: Promotion to mm/ (Month 5-8)
├── [TODO] Demonstrate real-world usage in staging
├── [TODO] Gather performance data from production users
├── [TODO] Submit promotion patch to move from staging to mm/
└── [TODO] Final review by mm maintainers

Phase 6: Mainline Merge (Month 8-12)
├── [TODO] Enter linux-next testing tree
├── [TODO] Pass automated testing (0-day, syzbot)
├── [TODO] Wait for merge window
└── [TODO] Linus merge → mainline release
```

## Node Patches (Formal Kernel Patch Format)

Each patch follows the standard kernel format:

```
From: LDM-OS Maintainer <ldm-os@linux.dev>
Subject: [PATCH vX NN/15] mm/ldm: <description>
To: linux-mm@kvack.org
Cc: Andrew Morton <akpm@linux-foundation.org>,
    Matthew Wilcox <willy@infradead.org>,
    David Hildenbrand <david@redhat.com>,
    linux-kernel@vger.kernel.org

<commit message body explaining WHY, not WHAT>

Signed-off-by: Author Name <email>
---
 mm/Kconfig.ldm     | XX +++
 mm/Makefile.ldm    | XX +++
 mm/ldm_core.c      | XXX ++++++++++++++++++++++++++++++
 include/linux/ldm_os.h | XXX ++++++++++++++++++++++++++++++
 4 files changed, XXX insertions(+)
 create mode 100644 mm/Kconfig.ldm
 create mode 100644 mm/Makefile.ldm
```

## Quick Start: Generate Patches

```bash
# Generate all 15 patches from current source
cd /path/to/ldm-os
./ldm-switch.sh patch

# Or manually with git format-patch
git format-patch --cover-letter -15 origin/main
```

## Configuration Quick Reference

| Mode | Command | Use Case |
|------|---------|----------|
| All built-in | `./ldm-switch.sh builtin` | Maximum performance, embedded |
| Hybrid module | `./ldm-switch.sh module` | Flexible deployment, servers |
| Disabled | `./ldm-switch.sh off` | Debugging, comparison testing |
| Runtime toggle | `sysctl vm.ldm_enabled=0` | No-reboot disable |
| Aggressive mode | `sysctl vm.ldm_mode=3` | AI training workloads |
