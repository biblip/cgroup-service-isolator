# ARCHITECTURE.md

## Goals

This toolkit provides a repeatable way to run **many Java applications** on a single host with:

- **Hard resource limits** (memory/CPU/tasks) per app
- **Strong filesystem isolation** (deny access to system directories like `/etc`)
- **Reduced privilege and kernel attack surface**
- **Operational ergonomics**: create/update/remove apps, view logs and metrics quickly
- **Production readiness** on Amazon Linux 2023, systemd, cgroups v2

The architecture is intentionally simple: **bash scripts + systemd unit files**.

---

## High-level Design

### Components

1. **Provisioning / management scripts** (`bin/`)
   - Idempotent CLI tools to create and manage apps
   - Render systemd unit files from templates
   - Apply updates safely (atomic JAR replacement)
   - Provide observability helpers (memory usage, limits, OOM evidence)

2. **systemd unit template(s)** (`templates/`)
   - A hardened baseline unit definition with placeholders
   - Optional drop-in overrides for debug features (e.g., syscall logging)

3. **Documentation** (`docs/`)
   - USAGE: how to install and operate the toolkit
   - TROUBLESHOOTING: common failure modes and fixes

4. **(Optional) Registry** (`/var/lib/java-sandbox-manager/`)
   - A record of managed applications (service name → user → paths → limits)
   - Used by `bin/list-apps.sh` to inventory managed services
   - If used, must be root-owned and mode `0700`

---

## Execution Model

### Lifecycle overview

For each application instance (a “tenant”):

1. Create a dedicated Linux system user (e.g., `jsbx_app1`).
2. Create directories:
   - `/home/<user>/app` (JAR + config)
   - `/home/<user>/data` (optional writable state)
3. Copy the JAR into `/home/<user>/app/` and set ownership.
4. Render and install a systemd unit file at:
   - `/etc/systemd/system/<appname>.service`
5. `systemctl daemon-reload`, then enable/start the unit (optionally).
6. The service runs as the dedicated user with:
   - cgroups v2 resource caps
   - filesystem sandbox rules
   - privilege reduction
   - seccomp syscall filtering

### Why systemd is the “control plane”

systemd already manages:

- process supervision (start/stop/restart)
- cgroups v2 configuration and accounting
- journald logging integration
- sandboxing, namespaces, and seccomp filters

The toolkit’s scripts focus on **safe creation and consistent configuration**, not re-implementing a supervisor.

---

## Isolation Layers

### 1) User isolation

Each app runs under a unique UID/GID. This provides:

- primary DAC-based separation between tenants
- prevents accidental reads/writes across tenants (when home dirs are `0700`)

### 2) Filesystem sandboxing

The unit is configured to:

- treat system directories as read-only or inaccessible
- allow writes only to allow-listed paths (typically the app home)

This is the main mechanism to enforce:
- “cannot read `/etc`”
- “cannot read other home directories”

### 3) cgroups v2 (hard resource enforcement)

systemd places each service into its own cgroup under `system.slice`. Limits apply to the entire process tree:

- memory hard limit (`MemoryMax`)
- CPU quota (`CPUQuota`)
- tasks/threads limit (`TasksMax`)

### 4) Seccomp syscall filtering

systemd applies a seccomp policy to restrict syscalls. The recommended starting point allows typical service behavior and networking while reducing kernel surface area.

---

## Resource Sizing Strategy

### The key principle

**cgroup memory limits apply to total process memory**, not Java heap.

Therefore, `-Xmx` must be comfortably smaller than `MemoryMax`, with headroom for:

- thread stacks
- metaspace
- code cache and JIT
- direct buffers / off-heap allocations
- native libraries

For `MemoryMax=512M`, a common safe starting configuration is:

- `-Xmx320m`
- `-XX:MaxMetaspaceSize=96m`
- `-XX:MaxDirectMemorySize=96m`
- `TasksMax=64` (adjust based on thread usage)

This is a baseline. Real workloads should be validated under load.

---

## Data and State

The toolkit expects app state to live under the app user’s home:

- `/home/<user>/app` → binaries and configuration
- `/home/<user>/data` → persistent data (if needed)
- `/home/<user>/logs` → optional if the application writes logs to files (journald is preferred)

If file logging is required, the unit should allow write access only to those explicit directories.

---

## Observability Design

### Logs

- Logs are captured by systemd/journald by default.
- Primary log access is via:
  - `journalctl -u <unit>`
- Scripts should provide short-hands:
  - tail logs
  - show last N lines
  - show boot-scoped logs

### Metrics

Metrics are derived from systemd and cgroup files:

- `systemctl show <unit> -p MemoryCurrent -p MemoryMax -p CPUQuota -p TasksMax`
- `/sys/fs/cgroup/system.slice/<unit>/memory.current`
- `/sys/fs/cgroup/system.slice/<unit>/cpu.stat` (optional)
- `MainPID` can be used to collect process-level views for debugging (`ps`, `top`)

### OOM detection

OOM kills are detected via:

- `systemctl status` (may show `OOMKilled`)
- `journalctl` for kernel or service messages
- `dmesg -T` for authoritative kernel messages (requires privileges)

---

## Configuration Model

### Template-driven units

The unit template uses placeholders such as:

- app/service name
- user name
- memory/CPU/tasks limits
- ExecStart command (Java or non-Java)
- allowed read/write paths
- syscall filter settings

The baseline template includes strict sandboxing defaults: `ProtectSystem=strict`, `ProtectHome=true`, `ReadWritePaths=/home/<user>/app /home/<user>/data`, `NoNewPrivileges=true`, `PrivateDevices=true`, `CapabilityBoundingSet=`/`AmbientCapabilities=`, `RestrictSUIDSGID=true`, `ProtectClock=true`, `ProtectHostname=true`, `ProcSubset=pid`, `ProtectProc=invisible`, `RestrictNamespaces=true`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, and a seccomp filter.

### Per-app overrides

Per-app customizations should be expressed in one of these ways:

1. A per-app environment file (e.g., `/home/<user>/app/app.env`), referenced by `EnvironmentFile=`
2. systemd drop-in overrides under:
   - `/etc/systemd/system/<unit>.d/*.conf`
3. Script arguments at creation time that render into the unit

Prefer drop-ins for changes that may be toggled (e.g., enabling syscall logging).

---

## Non-Java Workloads

The isolation model is runtime-agnostic. Non-Java binaries can be managed by using:
- `--artifact` to install a binary at `/home/<user>/app/app.bin`
- `--exec` to set a custom `ExecStart`
- `--no-jit` to enable `MemoryDenyWriteExecute=true` for non-JIT processes

Java defaults remain unchanged and continue to enforce JVM memory discipline under cgroup limits.

---

## Script Entry Points

Primary commands in `bin/`:
- `install-prereqs.sh` — validate systemd/cgroups/Java; create registry dir
- `create-app.sh` — create user, directories, unit, and optionally start/enable
- `update-jar.sh` — atomic JAR update with safe restart
- `remove-app.sh` — remove unit and optionally purge user
- `appctl.sh` — service control and observability shortcuts
- `list-apps.sh` — inventory managed apps from registry

---

## Operational Workflows

### Create an app

- Provision user + directories
- Copy JAR
- Install unit
- Enable/start service

### Update an app (atomic)

- Stop service (default safest path)
- Copy new jar to a temp file in the same filesystem
- `mv` into place (atomic rename)
- Start service

Optionally, if the application supports zero-downtime reload, a future enhancement could support `ExecReload=`.

### Remove an app

- Stop/disable service
- Remove unit file and drop-ins
- Optional purge:
  - remove user
  - remove home directory

Purge must require an explicit flag to prevent accidental data loss.

---

## Extensibility

Reasonable future extensions (without changing the core model):

- Optional outbound network allow-listing helpers (iptables/nftables), documented as additive
- Optional per-service `IPAddressDeny/Allow` if available and appropriate
- Optional health-check integration (systemd watchdog, or HTTP checkers)
- Optional JVM profile sets (Spring Boot vs lightweight worker vs Netty-heavy)

---

## Non-goals

This toolkit intentionally does not:

- implement multi-host orchestration
- manage secrets distribution
- replace containers or VMs
- provide a comprehensive firewall policy (can be layered externally)

---

## Design Principles

- **Fail closed** by default (deny access unless explicitly allowed)
- **Idempotent automation** (safe to rerun)
- **Minimal global state** (prefer systemd as source of truth)
- **Clear observability** (operators can quickly answer “what is it doing?”)
- **Least privilege** everywhere

---

## Quick “Proof of Isolation”

After provisioning an app:

- Confirm limits:
  - `systemctl show <unit> -p MemoryMax -p CPUQuota -p TasksMax`
- Confirm cgroup accounting:
  - `cat /sys/fs/cgroup/system.slice/<unit>/memory.current`
- Confirm filesystem denial:
  - from within the app, attempts to read `/etc` should fail
- Confirm network:
  - DNS + outbound connections succeed if required
- Confirm seccomp (debug mode):
  - enable `SystemCallLog=yes` and verify SECCOMP entries appear when a blocked syscall is attempted
