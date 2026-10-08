# Windows Sandbox Repair

An idempotent, no-reboot PowerShell repair script for Windows Sandbox on Windows 11.

This repository captures a real repair of the error:

> The Container Manager service or one of its dependencies is not running.

## What the script does

`Fix-Sandbox.ps1` performs a complete health check and repair in one repeatable run:

- Confirms that Windows Sandbox, Hyper-V, and Virtual Machine Platform are enabled.
- Confirms that the hypervisor is active and configured to launch automatically.
- Restores the Windows Defender Firewall service (`mpssvc`) to persistent Automatic startup when it has been disabled.
- Starts the firewall driver and the Container Manager/Hyper-V service dependency chain.
- Works around a restricted `mpssvc` service ACL without permanently weakening it: the required SCM permission is granted only long enough to commit the startup configuration, then the exact original security descriptor is restored.
- Optionally launches Windows Sandbox and verifies a responsive `Windows Sandbox` window plus the remote-session client, server, Hyper-V worker, and sandbox memory process.
- Can launch an isolated session with a verified, read-only view of every mounted fixed host drive at `C:\HostDrives\<letter>`.
- Never reboots the computer. If Windows reports a restart marker, the script reports it and continues safely.

## Requirements

- Windows 11 Pro, Enterprise, or Education.
- An elevated PowerShell session.
- Windows Sandbox/Hyper-V capable hardware with virtualization enabled in firmware.
- The script uses only built-in Windows components and does not download or install software.

## Use it

Open PowerShell as Administrator and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& .\Fix-Sandbox.ps1 -Launch
```

`-Launch` is the recommended mode. It repairs the host and leaves a verified sandbox open. To run only the host health check, omit `-Launch`.

For a slower machine, increase the launch wait period:

```powershell
& .\Fix-Sandbox.ps1 -Launch -LaunchTimeoutSeconds 180
```

### Read-only host-filesystem mirror

Use this only when the files on every mounted fixed host drive must be available
inside an isolated Sandbox session:

```powershell
& .\Fix-Sandbox.ps1 -Launch -HostFilesystemMirror
```

The same script generates a per-run `.wsb` configuration and guest proof,
launches it, and succeeds only after the responsive Sandbox VM and the guest
proof both confirm that the host drives are mounted read-only at
`C:\HostDrives\C`, `C:\HostDrives\E`, and so on. It disables networking,
clipboard, printers, microphone, and camera for that session. A Sandbox session
already open is never closed by the script, because closing it destroys its
contents; close it yourself and rerun if a new mirrored session is required.

This is a **filesystem mirror, not a full Windows-machine replica**. Windows
Sandbox always starts from its own disposable, clean Windows image. Host
installed apps do not become installed in the guest, and the host registry,
services, drivers, credentials, activation, device state, running processes,
and exact user profile cannot be copied into or booted by Sandbox. Accordingly,
no Windows Sandbox script can honestly guarantee that every host shortcut or
application will work in the guest. Use a persistent Hyper-V virtual machine
created from a proper disk image/P2V workflow when an actual machine clone is
required.

### Persistent disk-replica VM

`New-VssReplicaVm.ps1` is the preferred one-script workflow for this machine.
It captures C: plus EFI and Recovery with Windows Backup/VSS, embeds a tested
partition-independent UEFI BCD store, and recreates every other fixed disk as a
dynamic VHDX. Data disks keep the source MBR signature, partition offsets and
types, active flag, filesystem, label, allocation unit, and source drive-letter
mapping. NTFS snapshots are exposed through a direct temporary DOS-device
mapping, so the copy traverses the immutable snapshot instead of copying a
snapshot-link object. When a data disk also stores its own replica, the script
avoids a fragile same-disk snapshot and instead requires repeated live passes
to converge exactly. exFAT/FAT data is mirrored the same way. During the
storage-intensive phase, the one script temporarily disables Storage Optimizer
and ScheduledDefrag, verifies that guard, and restores their original states
before any VM may start. Durable system/VM artifacts default beneath
`C:\ProgramData\Verified-Windows-Replicas`; large data-disk artifacts and the
fresh backup archive live beneath `F:\backup`, where the host cleanup workflow
preserves them. No required artifact remains in a purgeable C:\ or F:\ root.
A volume is
accepted only when Robocopy stabilizes with a clean final log and independent
checks confirm normal (non-reparse) roots, root-entry parity, sampled file
lengths/SHA-256 hashes, and a non-empty-copy used-space floor.

Run its non-writing preflight first. `-PreflightOnly` does not create a VM or
replica files, and `-NoLaunch` is included as an additional explicit guard:

```powershell
& .\New-VssReplicaVm.ps1 -BackupTarget F: -ReuseLatestBackup -PreflightOnly -NoLaunch
```

Then run the exact same script normally. It creates the VM only after every
copy/layout/identity gate passes, and starts it only after all offline gates:

```powershell
& .\New-VssReplicaVm.ps1 -BackupTarget F: -VMName Full-Host-Replica
```

Use `-NoLaunch` to build and validate while leaving the VM powered off. The
default `NetworkMode=Isolated` prevents cloned host identity from appearing on
the network; pass `-NetworkMode DefaultSwitch` only when network access is
deliberately wanted. `-SkipFixedDataVolumes` creates a smaller system-only VM
and is therefore not complete fixed-volume coverage.

The script records the unavoidable same-disk exclusions (the protected backup
archive, its replica-data store, the selected replica output root, Recycle Bin,
and System Volume Information) so recursive self-copy is never misrepresented
as possible. Everything else on C:, E:, F:, and Z: is included on this host.

`New-FullReplicaVm.ps1` remains available for raw physical-disk cloning, but it
requires a separate destination larger than every source disk combined (about
6 TB for this host). Neither approach can mathematically reproduce volatile
RAM, identical physical hardware, hardware-bound licensing, TPM secrets,
currently open network sessions, or remote/cloud state. The VSS workflow is the
closest bootable, repeatable replica possible with the storage currently
attached.

The script exits with code `0` only when every required check passes. A detailed local run log is written beside the script as `Fix-Sandbox.log`.

## Why the repair is needed

The affected host had all Sandbox and Hyper-V optional features enabled, an active hypervisor, and healthy Hyper-V/container services. The failure was caused by the Windows Defender Firewall service being `Disabled` and `Stopped`. Its service security descriptor also denied local Administrators the `ChangeServiceConfig` right, so a normal `Set-Service` call returned Access Denied even from an elevated shell.

The script repairs both layers: it persists `mpssvc` as Automatic, commits that value through the Service Control Manager using a temporary narrowly scoped ACL adjustment, restores the original ACL, starts the dependency chain, and validates the real interactive sandbox session.

## Safety and repeatability

The script is designed to be run repeatedly. It does not delete files, reset HNS networking, stop unrelated virtual machines, change firewall rules, or reboot the host. Existing healthy services are left running. The only persistent service setting it changes is `mpssvc` startup mode from Disabled to Automatic, which is required for Windows Sandbox to start reliably.

If the script reports a failure, read the final `FAIL` lines and inspect `Fix-Sandbox.log`. Do not treat a process appearing briefly as success; the launch check requires the responsive titled window and the complete host-side sandbox process set.

## Verified outcome

The repair was run repeatedly without rebooting. Final verification showed:

- Windows Sandbox, Hyper-V, and Virtual Machine Platform enabled.
- Active hypervisor with `hypervisorlaunchtype=Auto`.
- `mpssvc=Running` and `Automatic`.
- `CmService`, `vmcompute`, `hns`, and `mpsdrv` running.
- A responsive window titled `Windows Sandbox` with `WindowsSandboxRemoteSession`, `WindowsSandboxServer`, `vmwp`, and `vmmemWindowsSandbox` present.
