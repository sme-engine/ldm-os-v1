#!/bin/bash
# =============================================================================
# Alpine UML Root Filesystem Builder
#
# Creates a minimal but complete Alpine rootfs with:
# - busybox-static (from Alpine v3.20)
# - Full /etc structure (passwd, shadow, group, inittab, rc.conf)
# - Debug tools (strace-like via /proc, dmesg, syslog)
# - GDB-ready init script with debug shell fallback
# - Network configuration for UML vector/tap
# - All kernel debug filesystems auto-mounted
#
# Usage: ./build_rootfs.sh
# Output: ${ALPINE_WORKSPACE}/output/alpine-uml-rootfs.cpio.gz
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
source "${WORKSPACE}/toolchain/env.sh"

ROOTFS="${WORKSPACE}/rootfs"
OUTPUT="${WORKSPACE}/output/alpine-uml-rootfs.cpio.gz"
BUSYBOX_SRC="${WORKSPACE}/src/busybox-extract/bin/busybox.static"

echo "[ROOTFS] Building Alpine UML root filesystem"
echo "[ROOTFS] Source busybox: ${BUSYBOX_SRC}"

# Clean previous build
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib,lib64}
mkdir -p "${ROOTFS}"/{etc,proc,sys,dev,tmp,run,var/log,var/run,var/tmp}
mkdir -p "${ROOTFS}"/etc/{init.d,rcS.d,profile.d,modprobe.d,sysctl.d}
mkdir -p "${ROOTFS}"/root

# Install busybox
cp "${BUSYBOX_SRC}" "${ROOTFS}/bin/busybox"
chmod 755 "${ROOTFS}/bin/busybox"

# Create all busybox symlinks
cd "${ROOTFS}"
for applet in $(${ROOTFS}/bin/busybox --list 2>/dev/null); do
    case "$applet" in
        busybox|init|linuxrc) continue ;;
    esac
    # Prefer /usr/bin for most, /bin for core utils
    case "$applet" in
        sh|ash|bash|cat|cp|ls|mv|rm|mkdir|ln|chmod|chown|mount|umount|ps|kill|echo|grep|sed|awk|head|tail|wc|sort|uniq|cut|tr|date|hostname|uname|id|whoami|env|printenv|test|true|false|sleep|expr|vi|ed|more|less|clear|reset|tty|stty|dmesg|insmod|rmmod|lsmod|modprobe|ifconfig|route|ping|netstat|arp|ip|syslogd|klogd|crond|crontab|tar|gzip|gunzip|zcat|find|xargs|diff|patch|md5sum|sha256sum|hexdump|od|strings|free|top|uptime|w|watch|fuser|lsof|strace|nc|telnet|wget|curl|ftp|dnsdomainname|nslookup|traceroute|mdev|hwclock|adjtimex|fdisk|mkfs|mountpoint|pivot_root|switch_root|poweroff|reboot|halt|sulogin|login|su|getty|setsid|nohup|nice|renice|taskset|ionice|timeout|tee|yes|seq|factor|basename|dirname|realpath|readlink|stat|file|touch|install|mktemp|cmp|comm|expand|unexpand|fold|fmt|nl|rev|split|paste|col|column|cal|logger|last|wall|mesg|openvt|deallocvt|chvt|fgconsole|kbd_mode|loadkeys|dumpkeys|setfont|showkey|setkeycodes|getkeycodes|setconsolechars|resize|reset|tput|infocmp|toe|tic|tabs|captoinfo|infotocap|clear|tset|tput)
            ln -sf /bin/busybox "bin/${applet}" 2>/dev/null || true
            ;;
        *)
            ln -sf /bin/busybox "usr/bin/${applet}" 2>/dev/null || true
            ;;
    esac
done
# Ensure critical symlinks exist
ln -sf /bin/busybox bin/sh 2>/dev/null || true
ln -sf /bin/busybox bin/ash 2>/dev/null || true
ln -sf /bin/busybox sbin/init 2>/dev/null || true

echo "[ROOTFS] Busybox installed with $(find . -type l | wc -l) symlinks"

# /etc/passwd
cat > etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/sbin/nologin
bin:x:2:2:bin:/bin:/sbin/nologin
sys:x:3:3:sys:/dev:/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
EOF

# /etc/shadow
cat > etc/shadow << 'EOF'
root:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
sys:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
chmod 640 etc/shadow

# /etc/group
cat > etc/group << 'EOF'
root:x:0:root
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
kmem:x:9:
wheel:x:10:root
nogroup:x:65534:
nobody:x:65534:
EOF

# /etc/hostname
echo "alpine-uml-debug" > etc/hostname

# /etc/hosts
cat > etc/hosts << 'EOF'
127.0.0.1   localhost alpine-uml-debug
::1         localhost
EOF

# /etc/inittab (UML uses tty0 and tty1-6)
cat > etc/inittab << 'EOF'
::sysinit:/etc/init.d/rc.sysinit
tty0::respawn:/sbin/getty 38400 tty0 linux
tty1::respawn:/sbin/getty 38400 tty1 linux
tty2::respawn:/sbin/getty 38400 tty2 linux
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
EOF

# /etc/fstab
cat > etc/fstab << 'EOF'
# <device>    <mount>     <type>  <options>           <dump> <pass>
proc          /proc       proc    defaults,noexec,nosuid,nodev  0 0
sysfs         /sys        sysfs   defaults,noexec,nosuid,nodev  0 0
devtmpfs      /dev        devtmpfs defaults,nosuid              0 0
tmpfs         /tmp        tmpfs   defaults,nosuid,nodev         0 0
tmpfs         /run        tmpfs   defaults,nosuid,nodev,mode=755 0 0
debugfs       /sys/kernel/debug debugfs defaults,noexec,nosuid,nodev 0 0
tracefs       /sys/kernel/tracing tracefs defaults,noexec,nosuid,nodev 0 0
securityfs    /sys/kernel/security securityfs defaults,noexec,nosuid,nodev 0 0
EOF

# /etc/sysctl.conf (enable all debug sysctls)
cat > etc/sysctl.conf << 'EOF'
# Kernel debugging
kernel.printk = 8 8 1 8
kernel.panic = 0
kernel.panic_on_oops = 1
kernel.hung_task_timeout_secs = 120
kernel.softlockup_panic = 0
kernel.watchdog = 1

# Memory debugging
vm.panic_on_oom = 0
vm.oom_kill_allocating_task = 1

# Network debugging
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_retries2 = 5
EOF

# /etc/init.d/rc.sysinit — comprehensive init with debug mounts
cat > etc/init.d/rc.sysinit << 'INITEOF'
#!/bin/sh
# Alpine UML Debug Init Script
# Mounts all debug filesystems and sets up the debug environment

echo "=== Alpine UML Debug Init ==="
echo "Kernel: $(uname -r)"
echo "Date: $(date)"

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null

# Mount debug filesystems
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null && echo "[OK] debugfs mounted" || echo "[--] debugfs not available"
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null && echo "[OK] tracefs mounted" || echo "[--] tracefs not available"
mount -t securityfs securityfs /sys/kernel/security 2>/dev/null && echo "[OK] securityfs mounted" || echo "[--] securityfs not available"
mount -t configfs configfs /sys/kernel/config 2>/dev/null && echo "[OK] configfs mounted" || echo "[--] configfs not available"

# Create essential device nodes if devtmpfs didn't
[ -e /dev/null ] || mknod -m 666 /dev/null c 1 3
[ -e /dev/zero ] || mknod -m 666 /dev/zero c 1 5
[ -e /dev/random ] || mknod -m 444 /dev/random c 1 8
[ -e /dev/urandom ] || mknod -m 444 /dev/urandom c 1 9
[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -e /dev/tty ] || mknod -m 666 /dev/tty c 5 0

# Apply sysctl settings
sysctl -p /etc/sysctl.conf 2>/dev/null

# Set hostname
hostname alpine-uml-debug 2>/dev/null

# Start syslog
syslogd -m 0 2>/dev/null && echo "[OK] syslogd started" || echo "[--] syslogd failed"
klogd 2>/dev/null && echo "[OK] klogd started" || echo "[--] klogd failed"

# Network setup (UML hostfs/vector)
ifconfig lo 127.0.0.1 up 2>/dev/null

echo ""
echo "=== Debug Environment Ready ==="
echo "  /proc/kallsyms : $(wc -l < /proc/kallsyms 2>/dev/null || echo 'N/A') symbols"
echo "  /sys/kernel/debug : $(ls /sys/kernel/debug 2>/dev/null | wc -l) entries"
echo "  /sys/kernel/tracing : $(ls /sys/kernel/tracing 2>/dev/null | wc -l) entries"
echo "  Kernel log buffer: $(dmesg 2>/dev/null | wc -l) lines"
echo ""
echo "=== System Ready ==="
INITEOF
chmod +x etc/init.d/rc.sysinit

# /etc/profile (debug-friendly shell environment)
cat > etc/profile << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='[\u@alpine-uml \W]\$ '
export HISTSIZE=1000
export HISTFILE=/root/.ash_history
export EDITOR=vi
export PAGER=less

# Debug aliases
alias dmesg='dmesg -T 2>/dev/null || dmesg'
alias ksyms='cat /proc/kallsyms | head -50'
alias kmods='cat /proc/modules'
alias kmem='cat /proc/meminfo | head -20'
alias kcpu='cat /proc/cpuinfo | head -20'
alias klocks='cat /proc/lock_stat 2>/dev/null | head -20'
alias kftrace='cat /sys/kernel/tracing/available_filter_functions 2>/dev/null | head -20'
alias kslab='cat /proc/slabinfo 2>/dev/null | head -20'

echo "Alpine UML Debug Shell"
echo "Type 'help' for busybox commands, or use debug aliases above."
EOF

# /root/.gdbinit (GDB helper for kernel debugging)
cat > root/.gdbinit << 'EOF'
# GDB init for UML kernel debugging
# Usage: gdb -x /root/.gdbinit /path/to/linux.uml
set print pretty on
set pagination off
set confirm off
# Load kernel symbols if available
# symbol-file /path/to/vmlinux
# Add kernel source path
# directory /path/to/linux-source
EOF

echo "[ROOTFS] Creating cpio archive..."
cd "${ROOTFS}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${OUTPUT}"

echo "[ROOTFS] Output: ${OUTPUT}"
ls -lh "${OUTPUT}"
echo "[ROOTFS] Contents: $(find . | wc -l) files/dirs"
echo "[ROOTFS] === SUCCESS ==="
