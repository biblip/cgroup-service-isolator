#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: update-todero-jar.sh --jar <path> [--no-stop]
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd install

JAR_SRC=""
NO_STOP="false"

while [ $# -gt 0 ]; do
  case "$1" in
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

[ -n "$JAR_SRC" ] || fail "--jar is required"
[ -f "$JAR_SRC" ] || fail "Jar not found: $JAR_SRC"

UNIT_NAME="todero.service"
USER_NAME="$(systemctl show -p User --value "$UNIT_NAME" 2>/dev/null || true)"

[ -n "$USER_NAME" ] || fail "Unable to determine User for ${UNIT_NAME}. Is it installed?"

DEST_DIR="/home/${USER_NAME}/app"
DEST_JAR="${DEST_DIR}/todero.jar"
TMP_JAR="${DEST_DIR}/.todero.jar.tmp"

if [ "$NO_STOP" = "false" ]; then
  systemctl stop "$UNIT_NAME"
fi

install -m 0640 -o "$USER_NAME" -g "$USER_NAME" "$JAR_SRC" "$TMP_JAR"

mv -f "$TMP_JAR" "$DEST_JAR"
chown "$USER_NAME":"$USER_NAME" "$DEST_JAR"

if [ "$NO_STOP" = "true" ]; then
  systemctl restart "$UNIT_NAME"
else
  systemctl start "$UNIT_NAME"
fi

echo "Updated todero jar"
