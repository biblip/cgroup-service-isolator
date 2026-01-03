#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: create-app.sh --name <appname> --jar <path> [options]

Options:
  --user <username>        Default: derived from app name
  --memory <size>          Default: 512M
  --memory-swap <size>     Default: 0
  --cpu-quota <pct>        Default: 100%
  --tasks-max <N>          Default: 64
  --jvm-xmx <size>         Default: 320m (uses fixed JVM policy)
  --jvm-flags <flags>      Override full JVM flags
  --exec <command>         Override ExecStart (non-Java or custom)
  --app-args <args>        Arguments appended to ExecStart
  --args-file <path>       Read APP_ARGS from file and install to aia-remote.conf
  --plugins-dir <path>     Create a plugins dir under /home/<user>/data (default: /home/<user>/data/plugins)
  --artifact <path>        Non-Java artifact to copy as /home/<user>/app/app.bin
  --no-jit                 Enable MemoryDenyWriteExecute (non-JIT apps only)
  --enable                 Enable service
  --start                  Start service
  --syscall-log            Enable SystemCallLog via drop-in
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd useradd
need_cmd install
need_cmd sed
need_cmd awk
need_cmd tr
need_cmd mktemp
need_cmd printf

APP_NAME=""
APP_USER=""
JAR_SRC=""
ARTIFACT_SRC=""
ARTIFACT_DEST=""
MEMORY_MAX="512M"
MEMORY_SWAP_MAX="0"
CPU_QUOTA="100%"
TASKS_MAX="64"
JVM_XMX="320m"
JVM_FLAGS=""
EXEC_START=""
APP_ARGS=""
ARGS_FILE=""
PLUGINS_DIR=""
DO_ENABLE="false"
DO_START="false"
DO_SYSCALL_LOG="false"
DO_NO_JIT="false"

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
    --jar)
      JAR_SRC="${2:-}"
      shift 2
      ;;
    --artifact)
      ARTIFACT_SRC="${2:-}"
      shift 2
      ;;
    --memory)
      MEMORY_MAX="${2:-}"
      shift 2
      ;;
    --memory-swap)
      MEMORY_SWAP_MAX="${2:-}"
      shift 2
      ;;
    --cpu-quota)
      CPU_QUOTA="${2:-}"
      shift 2
      ;;
    --tasks-max)
      TASKS_MAX="${2:-}"
      shift 2
      ;;
    --jvm-xmx)
      JVM_XMX="${2:-}"
      shift 2
      ;;
    --jvm-flags)
      JVM_FLAGS="${2:-}"
      shift 2
      ;;
    --exec)
      EXEC_START="${2:-}"
      shift 2
      ;;
    --app-args)
      APP_ARGS="${2:-}"
      shift 2
      ;;
    --args-file)
      ARGS_FILE="${2:-}"
      shift 2
      ;;
    --plugins-dir)
      PLUGINS_DIR="${2:-}"
      shift 2
      ;;
    --no-jit)
      DO_NO_JIT="true"
      shift
      ;;
    --enable)
      DO_ENABLE="true"
      shift
      ;;
    --start)
      DO_START="true"
      shift
      ;;
    --syscall-log)
      DO_SYSCALL_LOG="true"
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
[ -n "$JAR_SRC" ] || [ -n "$ARTIFACT_SRC" ] || [ -n "$EXEC_START" ] || fail "Provide --jar (Java) or --artifact/--exec (non-Java)"
if [ -n "$ARGS_FILE" ] && [ ! -f "$ARGS_FILE" ]; then
  fail "Args file not found: $ARGS_FILE"
fi

if [ -n "$JAR_SRC" ] && [ -n "$ARTIFACT_SRC" ]; then
  fail "Use either --jar or --artifact, not both"
fi

if [ -n "$JAR_SRC" ] && [ ! -f "$JAR_SRC" ]; then
  fail "Jar not found: $JAR_SRC"
fi

if [ -n "$ARTIFACT_SRC" ] && [ ! -f "$ARTIFACT_SRC" ]; then
  fail "Artifact not found: $ARTIFACT_SRC"
fi

if ! [[ "$APP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then
  fail "Invalid app name: $APP_NAME"
fi

if [ -z "$APP_USER" ]; then
  APP_USER="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | cut -c1-32)"
fi

if ! [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  fail "Invalid user name: $APP_USER"
fi

if [ -z "$JVM_FLAGS" ]; then
  JVM_FLAGS="-Xms256m -Xmx${JVM_XMX} -XX:MaxMetaspaceSize=96m -XX:MaxDirectMemorySize=96m -XX:+ExitOnOutOfMemoryError"
fi

if [ -n "$EXEC_START" ] && [ -n "$JAR_SRC" ]; then
  fail "Do not use --exec with --jar; use --exec with --artifact for non-Java apps"
fi

if [ -n "$EXEC_START" ] && [ -n "$JVM_FLAGS" ]; then
  echo "WARN: --jvm-flags ignored when --exec is used" >&2
fi

parse_size() {
  local s="$1"
  local num unit
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    echo "$s"
    return 0
  fi
  if [[ "$s" =~ ^([0-9]+)([KkMmGg])$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      K|k) echo $((num * 1024)) ;;
      M|m) echo $((num * 1024 * 1024)) ;;
      G|g) echo $((num * 1024 * 1024 * 1024)) ;;
    esac
    return 0
  fi
  return 1
}

if [ "${MEMORY_MAX}" != "infinity" ]; then
  if [ -n "$JAR_SRC" ]; then
    if MEM_BYTES="$(parse_size "$MEMORY_MAX")" && XMX_BYTES="$(parse_size "$JVM_XMX")"; then
      if [ "$XMX_BYTES" -ge "$MEM_BYTES" ]; then
        fail "--jvm-xmx must be smaller than --memory (cgroup MemoryMax)"
      fi
    else
      echo "WARN: Unable to parse sizes for --memory=${MEMORY_MAX} or --jvm-xmx=${JVM_XMX}; skipping size check" >&2
    fi
  fi
fi

UNIT_NAME="${APP_NAME}.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
DROPIN_DIR="/etc/systemd/system/${UNIT_NAME}.d"
REGISTRY_DIR="/var/lib/java-sandbox-manager"
REGISTRY_FILE="${REGISTRY_DIR}/registry.tsv"

if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "/home/${APP_USER}" --create-home --shell /usr/sbin/nologin "$APP_USER"
fi

install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}"
install -d -m 0755 -o root -g root "/home/${APP_USER}/app"
install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}/data"

if [ -z "$PLUGINS_DIR" ]; then
  PLUGINS_DIR="/home/${APP_USER}/data/plugins"
fi

if [[ "$PLUGINS_DIR" != "/home/${APP_USER}/data/"* ]]; then
  fail "--plugins-dir must be under /home/${APP_USER}/data"
fi

install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$PLUGINS_DIR"

if [ -n "$JAR_SRC" ]; then
  ARTIFACT_DEST="/home/${APP_USER}/app/$(basename "$JAR_SRC")"
  install -m 0644 -o root -g root "$JAR_SRC" "$ARTIFACT_DEST"
  EXEC_START="/usr/bin/java ${JVM_FLAGS} -jar ${ARTIFACT_DEST}"
fi

if [ -n "$ARTIFACT_SRC" ]; then
  ARTIFACT_DEST="/home/${APP_USER}/app/$(basename "$ARTIFACT_SRC")"
  install -m 0555 -o root -g root "$ARTIFACT_SRC" "$ARTIFACT_DEST"
  if [ -z "$EXEC_START" ]; then
    EXEC_START="${ARTIFACT_DEST}"
  fi
fi

if [ -n "$ARGS_FILE" ]; then
  install -m 0644 -o root -g root "$ARGS_FILE" "/home/${APP_USER}/app/aia-remote.conf"
fi

if [ -n "$APP_ARGS" ]; then
  printf "APP_ARGS=%q\n" "$APP_ARGS" > "/tmp/${APP_NAME}.aia-remote.conf"
  install -m 0644 -o root -g root "/tmp/${APP_NAME}.aia-remote.conf" "/home/${APP_USER}/app/aia-remote.conf"
  rm -f "/tmp/${APP_NAME}.aia-remote.conf"
fi

RUN_SH_TMP="$(mktemp)"
cat > "$RUN_SH_TMP" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_ARGS=""
if [ -f "/home/${APP_USER}/app/aia-remote.conf" ]; then
  # shellcheck source=/home/${APP_USER}/app/aia-remote.conf
  . "/home/${APP_USER}/app/aia-remote.conf"
fi
exec ${EXEC_START} \${APP_ARGS:-}
EOF
install -m 0555 -o root -g root "$RUN_SH_TMP" "/home/${APP_USER}/app/run.sh"
rm -f "$RUN_SH_TMP"

if [ -z "$EXEC_START" ]; then
  fail "Unable to determine ExecStart; provide --jar or --exec/--artifact"
fi

if [ ! -f templates/app.service.template ]; then
  fail "Missing template: templates/app.service.template"
fi

TMP_UNIT="$(mktemp)"
sed \
  -e "s|@APPNAME@|${APP_NAME}|g" \
  -e "s|@USER@|${APP_USER}|g" \
  -e "s|@GROUP@|${APP_USER}|g" \
  -e "s|@MEMORYMAX@|${MEMORY_MAX}|g" \
  -e "s|@MEMORYSWAPMAX@|${MEMORY_SWAP_MAX}|g" \
  -e "s|@CPUQUOTA@|${CPU_QUOTA}|g" \
  -e "s|@TASKSMAX@|${TASKS_MAX}|g" \
  -e "s|@EXECSTART@|${EXEC_START}|g" \
  -e "s|@APPARGS@|${APP_ARGS}|g" \
  templates/app.service.template > "$TMP_UNIT"
install -m 0644 "$TMP_UNIT" "$UNIT_PATH"
rm -f "$TMP_UNIT"

systemctl daemon-reload

if [ "$DO_SYSCALL_LOG" = "true" ]; then
  install -d -m 0755 "$DROPIN_DIR"
  install -m 0644 templates/override-syscalllog.conf "$DROPIN_DIR/syscalllog.conf"
fi

if [ "$DO_NO_JIT" = "true" ]; then
  install -d -m 0755 "$DROPIN_DIR"
  install -m 0644 templates/override-nojit.conf "$DROPIN_DIR/nojit.conf"
fi

install -d -m 0700 -o root -g root "$REGISTRY_DIR"
if [ ! -f "$REGISTRY_FILE" ]; then
  printf "app\tuser\tunit\n" > "$REGISTRY_FILE"
fi

if ! awk -F'\t' -v app="$APP_NAME" 'NR>1 && $1==app {found=1} END {exit found?0:1}' "$REGISTRY_FILE"; then
  printf "%s\t%s\t%s\n" "$APP_NAME" "$APP_USER" "$UNIT_NAME" >> "$REGISTRY_FILE"
fi

if [ "$DO_ENABLE" = "true" ]; then
  systemctl enable "$UNIT_NAME"
fi

if [ "$DO_START" = "true" ]; then
  systemctl start "$UNIT_NAME"
fi

echo "Created app ${APP_NAME} (user: ${APP_USER})"
