# SECURITY.md

## Overview

This project provisions and manages **multiple isolated Java applications** on a single Linux host (Amazon Linux 2023) using:

- **Dedicated Linux users per app**
- **systemd cgroups v2** for hard resource enforcement (memory/CPU/tasks)
- **systemd sandboxing** for filesystem and privilege isolation
- **seccomp syscall filtering** (via systemd) to reduce kernel attack surface
- **journald-based logging** and operational tooling for monitoring and incident response
- **Scripted lifecycle tooling** (`bin/*.sh`) to create/update/remove apps safely and consistently

The goal is to provide a *container-like security posture for single-host multi-tenant Java workloads*, without requiring Docker/Kubernetes.

---

## Threat Model

### In scope

This project aims to mitigate the following risks, assuming an attacker can control or exploit a Java program running under management:

- **Reading system secrets/config** (e.g., `/etc/shadow`, instance config under `/etc`, service credentials in `/var`)
- **Accessing other tenants’ data** (other app users’ home directories)
- **Privilege escalation** to root (via setuid binaries, capabilities, kernel interfaces, namespace tricks)
- **Resource exhaustion** of the host:
  - excessive memory usage (OOM risk)
  - runaway thread/process creation
  - uncontrolled CPU usage (fair-share disruption)
- **Kernel attack surface** reduction by restricting syscalls and namespaces
- **Device access** restriction (raw block devices, `/dev` interfaces)

### Out of scope / not guaranteed

These are not fully prevented by this approach:

- **Network-based exfiltration** (network is required; this toolkit does not implement IP allow-lists by default)
- **Side-channel attacks** (CPU cache timing, shared hardware effects)
- **Data exfiltration from allowed directories** (the app can read what it can access)
- **Supply-chain attacks** in the JAR itself (malicious dependencies)
- **Kernel vulnerabilities** (seccomp reduces exposure, but cannot eliminate kernel bugs)
- **Denial-of-service via network** (flooding its own sockets) unless additionally rate-limited externally
- **Full isolation comparable to VMs** (containers/VMs can still be stronger depending on configuration)

---

## Security Controls

### 1) Identity isolation (per-app user)

Each application runs under a dedicated system account (e.g., `javaapp1`) with:

- `nologin` shell
- a private home directory (mode `0700`)
- owned exclusively by the app user

**Security benefit:** prevents straightforward cross-tenant file reads and reduces blast radius of a compromise.

**Operational note:** avoid group-sharing home directories or making them world-readable.

**Enforcement note:** other users’ homes are protected by standard UNIX permissions (`0700`). With `ProtectHome=read-only`, the service cannot write to them and cannot read them without DAC permissions.

---

### 2) Filesystem isolation (systemd sandboxing)

Recommended unit hardening baseline includes:

- `ProtectSystem=strict` — mounts most of the filesystem read-only
- `ProtectHome=read-only` — makes `/home`, `/root`, `/run/user` read-only
- `ReadOnlyPaths=/home/<user>` — ensures app home is read-only at runtime
- `ReadWritePaths=/home/<user>/data` — explicit allow-list for writable directories
- `PrivateTmp=true` — per-service `/tmp` and `/var/tmp` namespaces
- `NoNewPrivileges=true` — disallows privilege escalation through execve
- `PrivateDevices=true` — hides device nodes
- `CapabilityBoundingSet=` and `AmbientCapabilities=` — clears any ambient or inherited capabilities
- `RestrictSUIDSGID=true` — blocks setuid/setgid executables from elevating privileges
- `ProtectClock=true` and `ProtectHostname=true` — blocks clock/hostname changes
- `ProcSubset=pid` and `ProtectProc=invisible` — limit `/proc` exposure to reduce cross-process discovery
- `UMask=0077` — defaults to owner-only permissions for files created by the service

**Expected outcome:** the service can read/write only inside its own allowed directories. Attempts to read `/etc` or other public directories should fail with `EACCES`/`EPERM`.

**Important caveat:** filesystem sandboxing controls *paths*; it does not prevent network access or reading from allowed directories.

**Java note:** `MemoryDenyWriteExecute=true` is not enabled by default because it breaks the JVM JIT on most workloads. For non-JIT runtimes (e.g., Go, Rust, static binaries), enable it via the `--no-jit` option in `bin/create-app.sh` to reduce code injection risk.

---

### 3) Privilege reduction and kernel hardening (systemd)

Recommended baseline includes:

- `NoNewPrivileges=true` — blocks acquiring additional privileges (e.g., via setuid)
- `PrivateDevices=true` — hides most device nodes
- `ProtectKernelTunables=true`, `ProtectKernelModules=true`, `ProtectKernelLogs=true`
- `ProtectControlGroups=true` — prevents tampering with cgroup settings
- `RestrictNamespaces=true` — blocks creation/usage of namespaces (reduces container-escape style primitives)
- `LockPersonality=true` and `RestrictRealtime=true` — reduces attack surface and mischief

**Expected outcome:** the service cannot mount filesystems, load modules, manipulate kernel parameters/logs, or gain new privileges.

---

### 4) Resource enforcement (cgroups v2)

Per-service enforcement is done via systemd properties such as:

- `MemoryMax=512M` (default)
- `MemorySwapMax=0` (default; prevents swap usage for this service)
- `CPUQuota=` (configurable; e.g., `100%` for “one core worth”)
- `TasksMax=` (limits threads/processes)

**Security benefit:** prevents “noisy neighbor” resource starvation and reduces blast radius of memory leaks or fork bombs.

**OOM behavior:** If memory usage exceeds `MemoryMax`, the kernel may OOM-kill the process inside the cgroup.

---

### 5) Syscall filtering (seccomp via systemd)

Default policy should start from:

- `SystemCallFilter=@system-service @basic-io @file-system @network-io`
- `SystemCallErrorNumber=EPERM`

Optionally enable:

- `SystemCallLog=yes` (debug mode)

**Security benefit:** reduces kernel attack surface and blocks dangerous classes of syscalls (mounting, low-level kernel interfaces, etc.) depending on the effective filter.

**Operational best practice:** start with the baseline filter and tighten gradually, validating under load.

---

### 6) Network controls

Because networking is required, the toolkit uses:

- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`

This blocks many less-common address families and raw kernel networking interfaces.

**Not provided by default:** outbound allow-lists (iptables/nftables) and per-destination policies. These can be layered externally if needed.

---

## Operational Guarantees (as implemented)

- App lifecycle scripts enforce: non-root user, 0700 home, dedicated app/data dirs, and unit hardening.
- JAR updates are atomic: new artifact is staged then moved into place before restart.
- App inventory is tracked in `/var/lib/java-sandbox-manager/registry.tsv` for listing and auditing.

---

## Recommended Defaults

### Memory sizing guidance

The cgroup limit (`MemoryMax`) applies to **total process memory**, not just Java heap. For a `512M` cap, recommended defaults are:

- `-Xmx320m` (or lower if many threads/off-heap)
- `-XX:MaxMetaspaceSize=96m`
- `-XX:MaxDirectMemorySize=96m`
- `-XX:+ExitOnOutOfMemoryError`

**Rationale:** Leave headroom for thread stacks, code cache, native allocations, and JVM internals.

---

## Verification Checklist

Use these checks after provisioning an app service:

1. **User identity**
   - Service runs as the dedicated user (`systemctl show -p User <unit>`)
2. **Filesystem denial**
   - Attempts to read `/etc` from within the app should fail
3. **cgroup enforcement**
   - `systemctl show <unit> -p MemoryMax -p MemoryCurrent`
   - `/sys/fs/cgroup/system.slice/<unit>/memory.max` equals `536870912` (512 MiB)
4. **OOM visibility**
   - `systemctl status <unit>` and `journalctl -u <unit>` show `OOMKilled` or OOM lines when applicable
5. **Network allowed**
   - App can resolve DNS and connect to required endpoints
6. **Seccomp behavior**
   - With `SystemCallLog=yes`, blocked syscalls appear in `journalctl -u <unit>` (SECCOMP lines)

---

## Incident Response Notes

### Detecting OOM kills

- `systemctl status <unit>` may show `OOMKilled=yes`
- `journalctl -u <unit> -b | grep -i oom`
- `dmesg -T | grep -i 'killed process'` (requires root)

### Typical mitigations

- Lower heap: reduce `-Xmx`
- Reduce threads: lower concurrency, shrink stack size carefully (`-Xss`), or reduce `TasksMax` if appropriate
- Increase cgroup memory cap only if the host has headroom
- Identify off-heap usage: direct buffers, JNI, native libs

---

## Secure Operations Guidance

- Patch Java system-wide regularly (Amazon Corretto / OpenJDK updates).
- Keep each app’s home directory `0700` and avoid shared writable paths.
- Prefer immutable deployment artifacts (versioned JARs) and atomic updates.
- Treat enabling `SystemCallLog` as temporary; it may generate noisy logs.
- If stronger network containment is required, add external firewall rules (security groups, NACLs, iptables/nftables) layered on top.

---

## Reporting Security Issues

If you discover a security weakness in the toolkit (e.g., sandbox bypass, misconfigured defaults, or documentation that leads to insecure use), treat it as sensitive and report it through your organization’s standard security disclosure process.
