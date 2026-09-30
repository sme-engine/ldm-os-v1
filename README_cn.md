# ldm-os-v1


## Introduction / 简介

LDM-OS-v1，基于Alpine Linux制作的低内存搬运操作系统（LDM-OS）的探索版：

## Test ENV.  / 测试环境
 
| 组件 | 版本 | 说明 |
| :--- | :--- | :--- |
| Alpine Linux | v3.20 | 稳定发行版 |
| Linux Kernel | 6.6.142 | Alpine v3.20 对应的 virt 内核 |
| BusyBox | 1.36.1 | Alpine v3.20 用户态工具集 |
| GCC (构建) | 8.4.1 | 沙箱编译器（Alpine 原生为 13.2.1） |
| musl libc | 1.2.4 | Alpine v3.20 C 库（UML 运行在 glibc 宿主上） |



## bootstrap / 初始化

### 在源码目录 ldm-build.sh 一键编译启动脚本:UML跑测模式


```bash
./ldm-build.sh              # 一键编译 + 启动 UML
./ldm-build.sh build        # 仅编译
./ldm-build.sh boot         # 仅启动（需先编译）
./ldm-build.sh test         # 编译 + 自动验证
./ldm-build.sh shell        # 启动进入交互式 debug shell
./ldm-build.sh clean        # 清理构建产物
```

### 环境变量覆盖

```bash
JOBS=16 UML_MEM=256M ./ldm-build.sh test
SKIP_CONFIG=1 ./ldm-build.sh build   # 跳过配置再生成（增量编译）
```

### 在源码目录 ldm-os-build.sh 一键编译启动脚本:构建QEMU镜像

```bash
./ldm-os-build.sh              # 构建UML（默认）
./ldm-os-build.sh uml          # 构建UML二进制
./ldm-os-build.sh qemu         # 构建QEMU镜像（含UML）
./ldm-os-build.sh all          # 构建UML + QEMU
./ldm-os-build.sh test         # 构建 + 运行企业级测试
./ldm-os-build.sh clean        # 清理构建产物
./ldm-os-build.sh status       # 查看构建状态
```

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| JOBS | nproc | 并行编译数 |
| UML_MEM | 128M | UML 客户机内存 |
| QEMU_FMT | qcow2 | 镜像格式(qcow2/raw) |
| QEMU_SIZE | 2G | 磁盘大小 |
| VERBOSE | 0 | 详细输出 |
| SKIP_CONFIG | 0 | 跳过内核重配置 |



## LDM-OS 对 AI 训练性能影响核心结论

### 端到端训练加速估算

| 估计级别 | 加速比 | 前提条件 |
|---|---|---|
| 保守 | 15-25% | 仅内核 hook 生效，无硬件 IOMMU，用户态未适配 |
| 中等 | 25-40% | 内核 hook + LD_PRELOAD shim + 部分框架适配 |
| 乐观 | 40-60% | 全栈适配 + 硬件 IOMMU + RDMA |

###  内存墙缓解程度

| 内存墙层级 | 缓解程度 | 关键机制 |
|---|---|---|
| 带宽墙 | 50-80% | Zero-copy transfer + DMA offload + NT stores |
| 延迟墙 | 40-70% | Lazy zero + TLB batching + COW deferral |
| 容量墙 | 30-50% | Lazy loading + in-place compute + warm pool reuse |

### 各子系统贡献分解

| 子系统 | AI 训练受益场景 | 该阶段加速 | 加权贡献 |
|---|---|---|---|
| copy_page hook | DataLoader fork / page cache | 1.3-1.8× | 6-16% |
| Zero-copy engine | GPU↔Host / gradient sync | 1.3-1.7× | 7.5-17.5% |
| Lazy memory | torch.zeros / prefetch alloc | 1.5-3× | 5-20% |
| Cache optimization | Streaming data / DMA completion | 1.05-1.15× | 2-6% |
| IOMMU abstraction | GDS / GPUDirect RDMA | 1.3-2× | 2.5-10% |



## LICENSE / 开源许可证

遵循Alpine Linux的GPL V2许可证
