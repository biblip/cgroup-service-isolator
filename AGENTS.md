# AGENTS.md

## Purpose

This repository provides a **secure, scriptable toolkit** for provisioning and managing **isolated Java applications** on **Amazon Linux 2023** using:

- systemd services
- cgroups v2 (memory / CPU enforcement)
- filesystem sandboxing
- seccomp syscall filtering
- per-application Linux users
- strong operational observability

This file defines **rules, boundaries, and expectations** for any AI agent, automation tool, or human contributor working on this codebase.

---

## Target Environment (Hard Constraints)

Agents MUST assume:

- OS: **Amazon Linux 2023**
- Init system: **systemd**
- Cgroups: **v2**
- Architecture: **arm64 (Graviton)**
- Java: **installed system-wide** (`/usr/bin/java`)
- Privileges: scripts are executed as **root** when provisioning, but services run as **non-root users**

Agents MUST NOT assume:
- Containers (Docker/Podman)
- Kubernetes
- systemd-nspawn
- SELinux disabled (it may be enforcing)
- Interactive shells or TTYs

---

## Core Security Model (Do Not Break)

Each managed Java application MUST:

1. Run as its **own dedicated system user**
2. Be isolated by **systemd cgroups**
3. Have a **hard memory cap** (default: 512 MiB)
4. Have **filesystem access restricted** to its own home directory
5. Have **no access** to:
   - `/etc`
   - `/var`
   - `/usr` (read-only at most)
   - other users’ home directories
6. Be subject to **seccomp syscall filtering**
7. Have **no privilege escalation paths**

Agents MUST NOT weaken or remove these guarantees without explicit instruction.

---

## What Agents ARE Allowed To Do

Agents MAY:

- Add new scripts under `bin/`
- Modify existing scripts to improve:
  - safety
  - idempotency
  - error handling
  - observability
- Improve documentation under `docs/`
- Add optional configuration knobs **without weakening defaults**
- Add validation, diagnostics, or dry-run modes
- Improve portability *within Amazon Linux 2023*

---

## What Agents MUST NOT Do

Agents MUST NOT:

- Disable systemd sandboxing features
- Remove cgroup memory enforcement
- Set `-Xmx` ≥ `MemoryMax`
- Run Java as root
- Modify global permissions under `/etc`, `/usr`, `/var`
- Introduce interactive prompts
- Hardcode secrets or credentials
- Install Java per user
- Assume permissive SELinux
- Add container runtimes or orchestrators

---

## Script Design Rules

All scripts MUST:

- Use **bash** with:
  ```bash
  set -euo pipefail
  ```
- Be **idempotent**
- Fail fast with **clear error messages**
- Validate all inputs
- Be safe to rerun
- Avoid global side effects
- Use `install(1)` for permissions where applicable
- Avoid `chmod -R` on non-owned paths

Scripts MUST be **non-interactive** and suitable for automation.

---

## systemd Rules

All systemd units MUST:

- Use `Type=simple`
- Use `User=` and `Group=` (non-root)
- Set `WorkingDirectory` explicitly
- Enforce:
  - `MemoryMax`
  - `MemorySwapMax`
  - `CPUQuota`
  - `TasksMax`
- Enable filesystem sandboxing:
  - `ProtectSystem=strict`
  - `ProtectHome=true`
  - `ReadWritePaths=` (minimal)
- Enable privilege hardening:
  - `NoNewPrivileges=true`
  - `PrivateDevices=true`
  - `RestrictNamespaces=true`
- Restrict networking explicitly via `RestrictAddressFamilies`
- Use seccomp syscall filters

---

## JVM Rules

Agents MUST assume:

- JVM heap is **not** the same as process memory
- cgroup memory limits are **hard**
- Default JVM flags MUST fit safely under 512 MiB

Default JVM policy:
- Heap < cgroup memory
- Explicit metaspace and direct memory caps
- Exit on OOM

Agents MUST document any JVM flag changes.

---

## Observability Expectations

The toolkit MUST provide:

- Clear commands to inspect:
  - MemoryCurrent / MemoryMax
  - CPUQuota
  - TasksMax
  - OOM kill events
- Access to logs via `journalctl`
- cgroup filesystem inspection guidance
- Seccomp denial diagnostics (audit / journal)

Agents SHOULD improve observability when possible.

---

## Documentation Requirements

Any functional change MUST be reflected in:

- `docs/USAGE.md` (how to use)
- `docs/TROUBLESHOOTING.md` (what can go wrong)

Docs MUST include:
- Copy/paste examples
- Failure scenarios
- Recovery steps

---

## Testing Expectations

Agents SHOULD test changes by:

- Creating a sample app user
- Starting a sandboxed Java process
- Verifying:
  - `/etc` access is denied
  - memory limits are enforced
  - OOM kills occur when expected
  - network access works
- Confirming no regressions in isolation

Automated tests are optional but welcome.

---

## Out of Scope (Explicitly)

This project does NOT aim to:

- Replace containers
- Provide multi-host orchestration
- Handle secrets management
- Enforce network allow-lists (iptables/nftables)
- Protect against side-channel attacks

---

## Security Philosophy

This project follows **defense in depth**:

- OS user isolation
- systemd sandboxing
- cgroups enforcement
- seccomp syscall filtering
- JVM memory discipline

Agents MUST preserve this layered approach.

---

## Final Rule

If a change would make it **easier for a Java process to escape its sandbox**, **consume unlimited resources**, or **access system files**, it is **not acceptable** unless explicitly approved.

When in doubt: **fail closed, document clearly, and keep defaults strict**.
