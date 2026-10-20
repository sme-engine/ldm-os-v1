#!/bin/sh
# 执行方式: doas ./run_benchmark_v3.sh

echo "=================================================="
echo "   LDM-OS 隐式内存搬运 Benchmark Suite v3  "
echo "=================================================="

WORKDIR="/tmp/ldm_bench_v3"
mkdir -p $WORKDIR
cd $WORKDIR

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "[!] 错误: 此脚本必须以 root (doas) 权限执行。"
    exit 1
fi

# ---------------------------------------------------------
# 编译阶段
# ---------------------------------------------------------
echo "[*] 正在编译测试程序..."

cat << 'EOF' > bench_cow.c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <string.h>
#include <time.h>

#define SIZE (128 * 1024 * 1024)
#define CHILDREN 4

int main() {
    char *buf = malloc(SIZE);
    memset(buf, 1, SIZE);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int i = 0; i < CHILDREN; i++) {
        pid_t pid = fork();
        if (pid == 0) {
            for (int j = 0; j < SIZE; j += 4096) buf[j] = 2;
            exit(0);
        }
    }
    for (int i = 0; i < CHILDREN; i++) wait(NULL);
    clock_gettime(CLOCK_MONOTONIC, &end);
    printf("%.4f\n", (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9);
    return 0;
}
EOF

cat << 'EOF' > bench_pipe.c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <string.h>
#include <time.h>

#define TOTAL_SIZE (512 * 1024 * 1024)
#define CHUNK 65536

int main() {
    int pipefd[2];
    pipe(pipefd);
    char *buf = malloc(CHUNK);
    memset(buf, 1, CHUNK);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[1]);
        long received = 0;
        while (received < TOTAL_SIZE) {
            int n = read(pipefd[0], buf, CHUNK);
            if (n <= 0) break;
            received += n;
        }
        close(pipefd[0]);
        exit(0);
    } else {
        close(pipefd[0]);
        long sent = 0;
        while (sent < TOTAL_SIZE) {
            int n = write(pipefd[1], buf, CHUNK);
            sent += n;
        }
        close(pipefd[1]);
        wait(NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    printf("%.4f\n", (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9);
    return 0;
}
EOF

gcc -O3 bench_cow.c -o bench_cow
gcc -O3 bench_pipe.c -o bench_pipe

# ---------------------------------------------------------
# 运行阶段
# ---------------------------------------------------------
RUNS=5

echo -e "\n[方案 A] CoW 风暴测试 (4个子进程并发写 128MB)..."
COW_TOTAL=0
for i in $(seq 1 $RUNS); do
    RES=$(./bench_cow)
    echo "  Round $i: $RES 秒"
    COW_TOTAL=$(echo "$COW_TOTAL + $RES" | bc)
done
COW_AVG=$(echo "scale=4; $COW_TOTAL / $RUNS" | bc)
echo "  -> 平均耗时: $COW_AVG 秒"

echo -e "\n[方案 B] 管道大数据传输测试 (512MB)..."
PIPE_TOTAL=0
for i in $(seq 1 $RUNS); do
    RES=$(./bench_pipe)
    echo "  Round $i: $RES 秒"
    PIPE_TOTAL=$(echo "$PIPE_TOTAL + $RES" | bc)
done
PIPE_AVG=$(echo "scale=4; $PIPE_TOTAL / $RUNS" | bc)
echo "  -> 平均耗时: $PIPE_AVG 秒"

echo -e "\n[方案 C] 大文件读写测试 (1GB)..."
# 确保测试文件存在，后续只测读取
dd if=/dev/zero of=/tmp/test_big_file bs=1M count=1024 2>/dev/null
sync
# 清理缓存，保证每次都从磁盘或页缓存真实读取
echo 3 > /proc/sys/vm/drop_caches

FILE_TOTAL=0
for i in $(seq 1 $RUNS); do
    START=$(date +%s.%N)
    cat /tmp/test_big_file > /dev/null
    END=$(date +%s.%N)
    RES=$(echo "$END - $START" | bc)
    echo "  Round $i: $RES 秒"
    FILE_TOTAL=$(echo "$FILE_TOTAL + $RES" | bc)
    # 每次读完清一下缓存，模拟冷读
    echo 3 > /proc/sys/vm/drop_caches
done
FILE_AVG=$(echo "scale=4; $FILE_TOTAL / $RUNS" | bc)
echo "  -> 平均耗时: $FILE_AVG 秒"

rm -f /tmp/test_big_file

echo -e "\n=================================================="
echo "  测试结果汇总"
echo "=================================================="
echo " 方案A (CoW 拷贝):  $COW_AVG 秒"
echo " 方案B (管道通信):  $PIPE_AVG 秒"
echo " 方案C (文件冷读):  $FILE_AVG 秒"
echo "=================================================="
