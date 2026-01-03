#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: update-jar.sh --name <appname> --jar <path> [--no-stop]
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd install

APP_NAME=""
JAR_SRC=""
NO_STOP="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --jar)
      JAR_SRC="${2:-}"
      shift 2
      ;;
    --no-stop)
      NO_STOP="true"
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
[ -n "$JAR_SRC" ] || fail "--jar is required"
[ -f "$JAR_SRC" ] || fail "Jar not found: $JAR_SRC"

UNIT_NAME="${APP_NAME}.service"
USER_NAME="$(systemctl show -p User --value "$UNIT_NAME" 2>/dev/null || true)"
EXEC_START="$(systemctl show -p ExecStart --value "$UNIT_NAME" 2>/dev/null || true)"

[ -n "$USER_NAME" ] || fail "Unable to determine User for ${UNIT_NAME}. Is it installed?"
[ -n "$EXEC_START" ] || fail "Unable to determine ExecStart for ${UNIT_NAME}"

JAR_PATH="$(echo "$EXEC_START" | sed -n 's/.*-jar[[:space:]]\\([^[:space:]]*\\).*/\\1/p')"
if [ -z "$JAR_PATH" ]; then
  fail "Unable to determine jar path from ExecStart; ensure -jar is used"
fi

DEST_DIR="$(dirname "$JAR_PATH")"
DEST_JAR="$JAR_PATH"
TMP_JAR="${DEST_DIR}/.$(basename "$JAR_PATH").tmp"

if [ "$NO_STOP" = "false" ]; then
  systemctl stop "$UNIT_NAME"
fi

install -m 0644 -o root -g root "$JAR_SRC" "$TMP_JAR"

mv -f "$TMP_JAR" "$DEST_JAR"
chown root:root "$DEST_JAR"

if [ "$NO_STOP" = "true" ]; then
  systemctl restart "$UNIT_NAME"
else
  systemctl start "$UNIT_NAME"
fi

echo "Updated jar for ${APP_NAME}"
