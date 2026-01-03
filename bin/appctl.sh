#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: appctl.sh <command> <appname>

Commands:
  start|stop|restart|status|logs|metrics|limits|oom|enable-syscalllog|disable-syscalllog
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd journalctl

CMD="${1:-}"
APP_NAME="${2:-}"

[ -n "$CMD" ] || { usage; exit 1; }
[ -n "$APP_NAME" ] || { usage; exit 1; }

UNIT_NAME="${APP_NAME}.service"
DROPIN_DIR="/etc/systemd/system/${UNIT_NAME}.d"
CGROUP_PATH="/sys/fs/cgroup/system.slice/${UNIT_NAME}"

case "$CMD" in
  start|stop|restart|status)
    systemctl "$CMD" "$UNIT_NAME"
    ;;
  logs)
    journalctl -u "$UNIT_NAME" -f
    ;;
  metrics)
    systemctl show "$UNIT_NAME" \
      -p MemoryCurrent \
      -p MemoryMax \
      -p CPUUsageNSec \
      -p MainPID
    if [ -f "${CGROUP_PATH}/memory.current" ]; then
      echo "memory.current=$(cat "${CGROUP_PATH}/memory.current")"
    fi
    if [ -f "${CGROUP_PATH}/memory.max" ]; then
      echo "memory.max=$(cat "${CGROUP_PATH}/memory.max")"
    fi
    ;;
  limits)
    systemctl show "$UNIT_NAME" \
      -p MemoryMax \
      -p MemorySwapMax \
      -p CPUQuota \
      -p TasksMax \
      -p RestrictAddressFamilies \
      -p SystemCallFilter \
      -p SystemCallErrorNumber \
      -p ProtectSystem \
      -p ProtectHome \
      -p ReadWritePaths \
      -p NoNewPrivileges \
      -p PrivateDevices \
      -p ProtectKernelTunables \
      -p ProtectKernelModules \
      -p ProtectKernelLogs \
      -p ProtectControlGroups \
      -p RestrictNamespaces \
      -p LockPersonality \
      -p RestrictRealtime
    ;;
  oom)
    systemctl status "$UNIT_NAME" --no-pager || true
    journalctl -u "$UNIT_NAME" --no-pager | grep -i oom || true
    dmesg -T | grep -i 'killed process' || true
    ;;
  enable-syscalllog)
    install -d -m 0755 "$DROPIN_DIR"
    install -m 0644 templates/override-syscalllog.conf "$DROPIN_DIR/syscalllog.conf"
    systemctl daemon-reload
    systemctl restart "$UNIT_NAME"
    ;;
  disable-syscalllog)
    rm -f "$DROPIN_DIR/override.conf" "$DROPIN_DIR/syscalllog.conf"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart "$UNIT_NAME"
    ;;
  *)
    fail "Unknown command: $CMD"
    ;;
esac
