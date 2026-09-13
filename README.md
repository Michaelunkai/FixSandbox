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

