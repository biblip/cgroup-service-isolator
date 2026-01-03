#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: remove-app.sh --name <appname> [--purge]

Options:
  --user <username>    User to purge if unit/registry is missing
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd userdel

APP_NAME=""
APP_USER=""
DO_PURGE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      APP_NAME="${2:-}"
      shift 2
      ;;
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

[ -n "$APP_NAME" ] || fail "--name is required"

UNIT_NAME="${APP_NAME}.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
DROPIN_DIR="/etc/systemd/system/${UNIT_NAME}.d"
REGISTRY_FILE="/var/lib/java-sandbox-manager/registry.tsv"
USER_NAME="${APP_USER:-}"
if [ -z "$USER_NAME" ]; then
  USER_NAME="$(systemctl show -p User --value "$UNIT_NAME" 2>/dev/null || true)"
fi
REGISTRY_USER=""

if systemctl list-unit-files | awk '{print $1}' | grep -qx "$UNIT_NAME"; then
  systemctl stop "$UNIT_NAME" || true
  systemctl disable "$UNIT_NAME" || true
fi

rm -f "$UNIT_PATH"
if [ -d "$DROPIN_DIR" ]; then
  rm -f "$DROPIN_DIR/override.conf" "$DROPIN_DIR/syscalllog.conf" "$DROPIN_DIR/nojit.conf"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
fi

systemctl daemon-reload

if [ -f "$REGISTRY_FILE" ]; then
  REGISTRY_USER="$(awk -F'\t' -v app="$APP_NAME" 'NR>1 && $1==app {print $2; exit}' "$REGISTRY_FILE")"
  awk -F'\t' -v app="$APP_NAME" 'NR==1 || $1!=app' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp"
  mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
fi

if [ "$DO_PURGE" = "true" ]; then
  if [ -z "$USER_NAME" ] && [ -n "$REGISTRY_USER" ]; then
    USER_NAME="$REGISTRY_USER"
  fi
  if [ -z "$USER_NAME" ] && [ -f "$UNIT_PATH" ]; then
    USER_NAME="$(awk -F= '/^User=/{print $2; exit}' "$UNIT_PATH")"
  fi
  if [ -z "$USER_NAME" ]; then
    fail "Unable to determine user for ${APP_NAME}; pass --user or re-run without --purge"
  fi
  if id "$USER_NAME" >/dev/null 2>&1; then
    userdel -r "$USER_NAME"
  fi
fi

echo "Removed app ${APP_NAME}"
