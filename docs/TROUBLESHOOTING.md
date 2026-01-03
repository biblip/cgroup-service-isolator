# Troubleshooting

## OOMKilled
Symptoms:
- systemctl status shows OOMKilled=yes
- journalctl contains OOM lines

Confirm:
```
./bin/appctl.sh oom jsbx-app1
```

Fix:
- Reduce Xmx (e.g., --jvm-xmx 256m)
- Increase MemoryMax (e.g., --memory 768M)
- Keep heap smaller than MemoryMax to leave overhead

## Permission denied (jar cannot be read or config not accessible)
Common causes:
- App jar not owned by the app user
- Home directory permissions too open or too closed
- ReadWritePaths missing a required directory

Fix:
- Ensure /home/<user>/app and /home/<user>/data are 0700 and owned by the app user
- Recreate with correct user and permissions
- Keep configs under /home/<user>/app

## Network blocked
Symptoms:
- Connection failures with EPERM or EAFNOSUPPORT

Fix:
- Ensure RestrictAddressFamilies includes AF_INET and AF_INET6
- Check with:
  systemctl show jsbx-app1 -p RestrictAddressFamilies

## Seccomp denials
Symptoms:
- journalctl shows SECCOMP entries

Fix:
- Enable syscall logging and capture blocked syscalls:
  ./bin/appctl.sh enable-syscalllog jsbx-app1
- Translate syscall numbers:
  ausyscall <nr>
- Adjust SystemCallFilter only if absolutely necessary and documented

## SELinux (Amazon Linux 2023)
Check mode:
```
getenforce
```

If enforcing, access under /home may be blocked depending on labels.
Conservative guidance:
- Keep jars and data under /home/<user>
- Ensure proper file contexts (use restorecon -Rv /home/<user> if available)
- Avoid disabling SELinux; prefer fixing labels or writing a minimal policy if required

## cgroups v2 not detected
Symptoms:
- /sys/fs/cgroup/cgroup.controllers missing

Fix:
- Ensure systemd is PID 1
- Verify cgroup v2 is enabled on Amazon Linux 2023

## memory.max missing at cgroup root
Symptoms:
- /sys/fs/cgroup/memory.max missing, but cgroup v2 is present

Notes:
- On some AL2023 hosts, the root cgroup may not expose memory.max even when the memory controller is enabled for slices.
- Check for `/sys/fs/cgroup/system.slice/memory.max` and verify `memory` is listed in `/sys/fs/cgroup/cgroup.controllers`.

## Java missing
Symptoms:
- /usr/bin/java not found

Fix:
```
sudo dnf install -y java-17-amazon-corretto-headless
```
