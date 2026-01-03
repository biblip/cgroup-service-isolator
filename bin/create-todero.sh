#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: create-todero.sh --jar <path> --conf <path> [options]

Options:
  --user <username>        Default: todero
  --jar <path>             Path to todero.jar
  --conf <path>            Path to todero.conf
  --enable                 Enable service
  --start                  Start service
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd useradd
need_cmd install
need_cmd mktemp

APP_USER="todero"
JAR_SRC=""
CONF_SRC=""
DO_ENABLE="false"
DO_START="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)
      APP_USER="${2:-}"
      shift 2
      ;;
    --jar)
      JAR_SRC="${2:-}"
      shift 2
      ;;
    --conf)
      CONF_SRC="${2:-}"
      shift 2
      ;;
    --enable)
      DO_ENABLE="true"
      shift
      ;;
    --start)
      DO_START="true"
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
[ -n "$CONF_SRC" ] || fail "--conf is required"
[ -f "$JAR_SRC" ] || fail "Jar not found: $JAR_SRC"
[ -f "$CONF_SRC" ] || fail "Conf not found: $CONF_SRC"

if ! [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  fail "Invalid user name: $APP_USER"
fi

UNIT_NAME="todero.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "/home/${APP_USER}" --create-home --shell /usr/sbin/nologin "$APP_USER"
fi

install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}"
install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}/app"

install -m 0640 -o "$APP_USER" -g "$APP_USER" "$JAR_SRC" "/home/${APP_USER}/app/todero.jar"

install -d -m 0755 -o root -g root /etc/todero
install -m 0644 -o root -g root "$CONF_SRC" /etc/todero/todero.conf

if [ ! -f templates/todero.service.template ]; then
  fail "Missing template: templates/todero.service.template"
fi

TMP_UNIT="$(mktemp)"
sed \
  -e "s|@USER@|${APP_USER}|g" \
  -e "s|@GROUP@|${APP_USER}|g" \
  templates/todero.service.template > "$TMP_UNIT"
install -m 0644 "$TMP_UNIT" "$UNIT_PATH"
rm -f "$TMP_UNIT"

systemctl daemon-reload

if [ "$DO_ENABLE" = "true" ]; then
  systemctl enable "$UNIT_NAME"
fi

if [ "$DO_START" = "true" ]; then
  systemctl start "$UNIT_NAME"
fi

echo "Created todero service (user: ${APP_USER})"
