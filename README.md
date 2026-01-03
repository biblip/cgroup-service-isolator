# cgroup-service-isolator

A hardened, scriptable toolkit to provision and operate isolated services on Amazon Linux 2023 using systemd sandboxing, cgroups v2 resource caps, seccomp syscall filtering, and per-app users. Designed for Java by default, but supports non-Java runtimes (Go, Rust, native binaries) with the same isolation profile.

## What it does
- Creates a dedicated system user per app with a private home
- Enforces hard resource limits (memory/CPU/tasks) using cgroups v2
- Applies strong systemd sandboxing and seccomp filters
- Provides lifecycle and observability commands (logs, metrics, limits, OOM)
- Supports atomic JAR or binary updates

## Target platform
- Amazon Linux 2023 (systemd, cgroups v2)
- arm64 (Graviton) primary target; also works on x86_64 with the same systemd/cgroups v2 requirements
- Java installed system-wide at `/usr/bin/java`

## Quick start
```
./bin/install-prereqs.sh
./bin/create-app.sh --name jsbx-app1 --user jsbx1 --jar ./myprogram.jar --start --enable
./bin/appctl.sh metrics jsbx-app1
```

## Non-Java apps
```
./bin/create-app.sh --name go-api --user goapi --artifact ./go-api --exec "/home/goapi/app/app.bin --port 8080" --start --enable --no-jit
```

## Documentation
- `docs/USAGE.md` — end-to-end usage, examples, and verification steps
- `docs/TROUBLESHOOTING.md` — common failures and remediation
- `SECURITY.md` — threat model and hardening baseline
- `ARCHITECTURE.md` — design and execution model

## Repository layout
- `bin/` — provisioning and operations scripts
- `templates/` — systemd unit templates and drop-ins
- `docs/` — user-facing documentation

## Notes
- Defaults are intentionally strict; relax only if required and documented.
- For non-JIT apps, enable `MemoryDenyWriteExecute` via `--no-jit` to harden against code injection.
