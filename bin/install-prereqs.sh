#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd bash
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd install
need_cmd systemctl

if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  echo "WARN: PID 1 is not systemd. systemctl may not function as expected." >&2
fi

if [ ! -d /sys/fs/cgroup ]; then
  fail "/sys/fs/cgroup is missing; cgroups v2 must be mounted. Ensure systemd is running and cgroup v2 is enabled."
fi

if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
  fail "cgroups v2 not detected (missing /sys/fs/cgroup/cgroup.controllers)."
fi

if [ ! -f /sys/fs/cgroup/memory.max ]; then
  fail "cgroup v2 memory controller not detected (missing /sys/fs/cgroup/memory.max)."
fi

if [ ! -x /usr/bin/java ]; then
  echo "ERROR: /usr/bin/java not found. Install Amazon Corretto or OpenJDK." >&2
  echo "Example (Amazon Linux 2023): dnf install -y java-17-amazon-corretto-headless" >&2
  exit 1
fi

if command -v getenforce >/dev/null 2>&1; then
  echo "SELinux status: $(getenforce)"
else
  echo "SELinux status: getenforce not available"
fi

if ! command -v ausyscall >/dev/null 2>&1; then
  echo "NOTE: ausyscall not found (useful for seccomp diagnostics)." >&2
  echo "Install: dnf install -y audit" >&2
fi

install -d -m 0700 -o root -g root /var/lib/java-sandbox-manager

cat <<'NEXT'
Prereqs OK.
Next steps:
- Create an app: ./bin/create-app.sh --name jsbx-app1 --user jsbx1 --jar ./myprogram.jar --start --enable
- Check status: ./bin/appctl.sh status jsbx-app1
NEXT
