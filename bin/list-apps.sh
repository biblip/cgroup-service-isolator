#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd systemctl
need_cmd awk

REGISTRY_FILE="/var/lib/java-sandbox-manager/registry.tsv"

if [ ! -f "$REGISTRY_FILE" ]; then
  echo "No registry found at ${REGISTRY_FILE}" >&2
  exit 1
fi

printf "%-20s %-16s %-10s %-12s %-12s %-10s %-8s\n" "APP" "USER" "STATE" "MEMORYMAX" "MEMORYCUR" "CPUQUOTA" "TASKSMAX"

awk -F'\t' 'NR>1 {print $1"\t"$2"\t"$3}' "$REGISTRY_FILE" | while IFS=$'\t' read -r app user unit; do
  state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo unknown)"
  memmax="$(systemctl show -p MemoryMax --value "$unit" 2>/dev/null || echo -)"
  memcur="$(systemctl show -p MemoryCurrent --value "$unit" 2>/dev/null || echo -)"
  cpuquota="$(systemctl show -p CPUQuota --value "$unit" 2>/dev/null || echo -)"
  tasksmax="$(systemctl show -p TasksMax --value "$unit" 2>/dev/null || echo -)"
  printf "%-20s %-16s %-10s %-12s %-12s %-10s %-8s\n" "$app" "$user" "$state" "$memmax" "$memcur" "$cpuquota" "$tasksmax"
done
