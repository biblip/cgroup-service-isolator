# Usage

## Architecture
Each Java app runs as its own Linux system user and a dedicated systemd service. Isolation is enforced via:
- systemd sandboxing (filesystem, namespaces, devices, privileges)
- cgroups v2 (hard memory cap, CPU quota, tasks limit)
- seccomp syscall filtering

Created apps are recorded in `/var/lib/java-sandbox-manager/registry.tsv` for inventory and listing.

The app directory layout is:
- /home/<user>/app/myprogram.jar
- /home/<user>/app/app.env (optional)
- /home/<user>/data (optional, writable)

The `/home/<user>/app` directory is mounted read-only at runtime. Use `/home/<user>/data` for writable state. Because `ProtectHome=true` hides `/home` by default, the unit uses `BindReadOnlyPaths`/`BindPaths` to explicitly expose these directories.

## Prerequisites (Amazon Linux 2023)
Most `bin/` scripts require root because they manage system users and systemd units. Use `sudo` in the examples below.

Install Java and validate the path:

```
# Amazon Corretto 17 headless
sudo dnf install -y java-17-amazon-corretto-headless

# Verify
/usr/bin/java -version
```

Validate systemd + cgroups v2 and set up registry (requires sudo):

```
sudo ./bin/install-prereqs.sh
```

Note: On some AL2023 hosts, `/sys/fs/cgroup/memory.max` may be missing at the root even when memory accounting works. The memory controller can still be enabled for slices (e.g., `/sys/fs/cgroup/system.slice/memory.max`). The prereq script accounts for this.

## Create your first app (Java)

```
sudo ./bin/create-app.sh --name jsbx-app1 --user jsbx1 --jar ./myprogram.jar --start --enable
```

Defaults:
- MemoryMax=512M, MemorySwapMax=0
- CPUQuota=100%
- TasksMax=64
- JVM flags: -Xms256m -Xmx320m -XX:MaxMetaspaceSize=96m -XX:MaxDirectMemorySize=96m -XX:+ExitOnOutOfMemoryError

The JAR (or binary) is copied into `/home/<user>/app` and owned by root with read-only permissions for the app user.

## Logs

```
journalctl -u jsbx-app1 -f
# or
sudo ./bin/appctl.sh logs jsbx-app1
```

## Monitoring

```
sudo ./bin/appctl.sh metrics jsbx-app1
sudo ./bin/appctl.sh limits jsbx-app1
```

## Update jar

```
sudo ./bin/update-jar.sh --name jsbx-app1 --jar ./new.jar
```

## Non-Java apps (Go, Rust, native binaries)

You can run non-Java services with the same isolation profile. Provide an artifact and exec command:

```
sudo ./bin/create-app.sh --name native-app1 --user native1 --artifact ./myserver --exec "/home/native1/app/app.bin --config /home/native1/app/app.env" --start --enable --no-jit
```

Notes:
- `--no-jit` enables `MemoryDenyWriteExecute=true`, which is safe for non-JIT runtimes and increases protection.
- If `--exec` is omitted, the default ExecStart becomes `/home/<user>/app/app.bin`.

More examples:

Go (static binary):
```
sudo ./bin/create-app.sh --name go-api --user goapi --artifact ./go-api --exec "/home/goapi/app/app.bin --port 8080" --start --enable --no-jit
```

Rust (static binary):
```
sudo ./bin/create-app.sh --name rust-worker --user rustwk --artifact ./worker --exec "/home/rustwk/app/app.bin --queue q1" --start --enable --no-jit
```

JIT runtimes (like Node.js) should not use `--no-jit`. Use `--exec` without it.

## Create many apps (loop example)

```
for i in 1 2 3; do
  sudo ./bin/create-app.sh --name jsbx-app${i} --user jsbx${i} --jar ./myprogram.jar --enable
  sudo ./bin/appctl.sh start jsbx-app${i}
done
```

## JVM memory policy
MemoryMax is a hard cgroup limit. The JVM heap must be smaller than the cgroup limit to leave room for:
- metaspace
- direct buffers
- native threads
- JVM overhead

Defaults are sized for a 512M cgroup: Xmx=320m, MaxMetaspaceSize=96m, MaxDirectMemorySize=96m.
If you raise MemoryMax, also adjust Xmx and other caps accordingly.

## Enable syscall logging (seccomp debug)

```
./bin/appctl.sh enable-syscalllog jsbx-app1
journalctl -u jsbx-app1 -f
# When you see a blocked syscall number, translate it:
# ausyscall 313
```

To disable:

```
./bin/appctl.sh disable-syscalllog jsbx-app1
```

## Security checklist
- Runs as dedicated non-root user
- Filesystem access limited to /home/<user>/app and /home/<user>/data
- /etc and other system paths are not accessible
- cgroups v2 hard limits applied (memory, CPU, tasks)
- No new privileges, private devices, locked namespaces
- Seccomp syscall filters enabled

## How to verify isolation
1) Try reading /etc from inside the app (should fail):
   - Run a test jar that attempts to read /etc/passwd and logs the result.
2) Confirm memory limits:
   - systemctl show jsbx-app1 -p MemoryMax -p MemoryCurrent
3) Confirm cgroup memory.current increases under load:
   - cat /sys/fs/cgroup/system.slice/jsbx-app1.service/memory.current
4) Confirm RestrictAddressFamilies is set:
   - systemctl show jsbx-app1 -p RestrictAddressFamilies
5) Confirm seccomp logs appear when enabled:
   - ./bin/appctl.sh enable-syscalllog jsbx-app1
   - journalctl -u jsbx-app1 | grep -i SECCOMP
