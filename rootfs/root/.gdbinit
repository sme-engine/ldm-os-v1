# GDB init for UML kernel debugging
# Usage: gdb -x /root/.gdbinit /path/to/linux.uml
set print pretty on
set pagination off
set confirm off
# Load kernel symbols if available
# symbol-file /path/to/vmlinux
# Add kernel source path
# directory /path/to/linux-source
