#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: remove-todero.sh [--purge]

Options:
  --user <username>    User to purge if unit is missing
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd userdel

APP_USER=""
DO_PURGE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)
      APP_USER="${2:-}"
      shift 2
      ;;
    --purge)
      DO_PURGE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

UNIT_NAME="todero.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
USER_NAME="${APP_USER:-}"

if [ -z "$USER_NAME" ]; then
  USER_NAME="$(systemctl show -p User --value "$UNIT_NAME" 2>/dev/null || true)"
fi

if systemctl is-active --quiet "$UNIT_NAME"; then
  fail "Service ${UNIT_NAME} is running; stop it before removal (use: systemctl stop ${UNIT_NAME})"
fi

if systemctl list-unit-files | awk '{print $1}' | grep -qx "$UNIT_NAME"; then
  systemctl stop "$UNIT_NAME" || true
  systemctl disable "$UNIT_NAME" || true
fi

rm -f "$UNIT_PATH"
systemctl daemon-reload

if [ "$DO_PURGE" = "true" ]; then
  if [ -z "$USER_NAME" ] && [ -f "$UNIT_PATH" ]; then
    USER_NAME="$(awk -F= '/^User=/{print $2; exit}' "$UNIT_PATH")"
  fi
  if [ -z "$USER_NAME" ]; then
    fail "Unable to determine user; pass --user or re-run without --purge"
  fi
  if id "$USER_NAME" >/dev/null 2>&1; then
    userdel -r "$USER_NAME"
  fi
  rm -f /etc/todero/todero.conf
  rmdir /etc/todero 2>/dev/null || true
fi

echo "Removed todero service"
