#requires -RunAsAdministrator

<#
.SYNOPSIS
    Creates and launches an isolated Hyper-V disk-level P2V replica of every
    local physical disk except the dedicated destination disk.

.DESCRIPTION
    Windows Sandbox cannot boot a host image. This is the persistent-VM path:
    each source physical disk is copied to a VHDX, attached to a Generation 2
    Hyper-V VM, and the VM is started without a network adapter. The destination
    disk is deliberately excluded, because it stores the replica and cannot be
    a stable source while it is being written.

    This is a disk-level P2V workflow, not a claim of an identical live-machine
    snapshot. A running host can change files while physical disks are copied;
    RAM, device state, cloud sessions, hardware-bound licensing, and external
    state are outside a disk image. For the strongest disk consistency, capture
    from an offline maintenance environment or a VSS-aware backup/P2V product.

    Run with -PreflightOnly first. The destination must be a dedicated NTFS or
    ReFS volume on a physical disk that is not one of the disks being cloned.
#>

[CmdletBinding()]
param(
    [string]$ReplicaRoot,

    [string]$VMName,

    [ValidateRange(4, 64)]
    [int]$StartupMemoryGB = 16,

    [ValidateRange(1, 32)]
    [int]$ProcessorCount = 4,

    [ValidateRange(60, 900)]
    [int]$BootTimeoutSeconds = 300,

    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptRoot 'Full-Replica-VM.log'
$startedAt = Get-Date
$failures = [System.Collections.Generic.List[string]]::new()

function Write-ReplicaResult {
    param(
        [ValidateSet('INFO', 'PASS', 'WARN', 'FAIL')]
        [string]$Level,
        [string]$Message
    )

    $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line
    Write-Output $line
}

function Add-ReplicaFailure {
    param([string]$Message)

    $failures.Add($Message)
    Write-ReplicaResult -Level FAIL -Message $Message
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run from an elevated Administrator PowerShell session.'
    }
    Write-ReplicaResult -Level PASS -Message "Running elevated as $($identity.Name)."
}

function Get-ReplicaPlan {
    param([string]$DestinationRoot)

    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        throw 'ReplicaRoot is required. Attach a dedicated NTFS/ReFS disk with at least the required free capacity, then supply a path on it (for example, G:\Full-Host-Replica).'
    }

    $absoluteRoot = [IO.Path]::GetFullPath($DestinationRoot)
    $volumeRoot = [IO.Path]::GetPathRoot($absoluteRoot)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "ReplicaRoot '$DestinationRoot' must be on a local drive-letter volume."
    }

    $driveLetter = $volumeRoot.TrimEnd('\\').TrimEnd(':')
    $destinationPartition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $destinationDisk = Get-Disk -Number $destinationPartition.DiskNumber -ErrorAction Stop
    $destinationVolume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop

    if ($destinationDisk.IsBoot -or $destinationDisk.IsSystem) {
        throw "ReplicaRoot '$absoluteRoot' is on the current boot/system disk. A clone cannot be written onto its source disk."
    }
    if ($destinationDisk.OperationalStatus -notcontains 'Online') {
        throw "Destination disk $($destinationDisk.Number) is not online."
    }
    if ($destinationVolume.FileSystem -notin @('NTFS', 'ReFS')) {
        throw "ReplicaRoot '$absoluteRoot' is on $($destinationVolume.FileSystem), but VHDX output requires a dedicated NTFS or ReFS destination."
    }

    $sourceDisks = @(
        Get-Disk | Where-Object {
            $_.Number -ne $destinationDisk.Number -and
            $_.OperationalStatus -contains 'Online' -and
            -not $_.IsOffline -and
            $_.PartitionStyle -ne 'RAW'
        } | Sort-Object Number
    )
    if ($sourceDisks.Count -eq 0) {
        throw 'No eligible source disks remain after excluding the replica destination disk.'
    }
    if (-not ($sourceDisks | Where-Object IsBoot)) {
        throw 'The current boot disk is not among the eligible source disks.'
    }

    # New-VHD -SourceDisk copies the physical disk image. Reserve the exact
    # logical disk total plus 1 GiB per disk for VHDX metadata and manifests.
    $requiredBytes = [uint64](($sourceDisks | Measure-Object -Property Size -Sum).Sum + (1GB * $sourceDisks.Count))
    if ([uint64]$destinationVolume.SizeRemaining -lt $requiredBytes) {
        throw ("Destination free space is insufficient. Required={0:N2} TiB; available={1:N2} TiB; source disks={2}." -f `
            ($requiredBytes / 1TB), ([uint64]$destinationVolume.SizeRemaining / 1TB), ($sourceDisks.Number -join ', '))
    }

    $firmware = Get-ComputerInfo -Property BiosFirmwareType | Select-Object -ExpandProperty BiosFirmwareType
    if ($firmware -ne 2) {
        throw "The host firmware type is '$firmware'; this script requires UEFI so the cloned boot disk can use a Generation 2 VM."
    }

    $bitLocker = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.ProtectionStatus -ne 0 })
    if ($bitLocker.Count -gt 0) {
        $protectedVolumes = $bitLocker.MountPoint -join ', '
        throw "BitLocker protection is active on $protectedVolumes. Disable protection and confirm recovery material before cloning; a new VM TPM cannot transparently unlock the host's protected volumes."
    }

    $logicalProcessors = [int](Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($ProcessorCount -gt $logicalProcessors) {
        throw "ProcessorCount=$ProcessorCount exceeds the host's $logicalProcessors logical processors."
    }
    $availableMemory = [uint64](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if (($StartupMemoryGB * 1GB) -gt $availableMemory) {
        throw "StartupMemoryGB=$StartupMemoryGB exceeds installed host memory."
    }

    return [pscustomobject]@{
        ReplicaRoot = $absoluteRoot
        DestinationDisk = $destinationDisk
        DestinationVolume = $destinationVolume
        SourceDisks = $sourceDisks
        RequiredBytes = $requiredBytes
        Firmware = $firmware
    }
}

function Save-ReplicaManifest {
    param(
        [string]$Path,
        [object]$Plan,
        [object[]]$ClonedDisks,
        [string]$Name
    )

    [pscustomobject]@{
        SchemaVersion = 1
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        VMName = $Name
        DestinationDiskNumber = $Plan.DestinationDisk.Number
        SourceDisks = @($Plan.SourceDisks | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, Size, IsBoot, IsSystem)
        VhdxDisks = $ClonedDisks
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Wait-ReplicaBoot {
    param(
        [string]$Name,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $vm = Get-VM -Name $Name -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            throw "VM state changed to '$($vm.State)' before the guest heartbeat was healthy."
        }

        $heartbeat = Get-VMIntegrationService -VMName $Name -Name Heartbeat -ErrorAction SilentlyContinue
        if ($null -ne $heartbeat -and $heartbeat.PrimaryStatusDescription -eq 'OK') {
            Write-ReplicaResult -Level PASS -Message "VM '$Name' is Running and reports a healthy guest heartbeat."
            return
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "VM '$Name' is Running but did not report a healthy guest heartbeat within $TimeoutSeconds seconds. Open its console to inspect boot state."
}

New-Item -ItemType File -Path $logPath -Force | Out-Null
Write-ReplicaResult -Level INFO -Message "Starting disk-level P2V workflow. Script=$($MyInvocation.MyCommand.Path)"

try {
    Test-Administrator
    Import-Module Hyper-V -ErrorAction Stop
    $plan = Get-ReplicaPlan -DestinationRoot $ReplicaRoot
    Write-ReplicaResult -Level PASS -Message ("P2V preflight passed: source disks={0}; destination disk={1}; required={2:N2} TiB; available={3:N2} TiB." -f `
        ($plan.SourceDisks.Number -join ', '), $plan.DestinationDisk.Number, ($plan.RequiredBytes / 1TB), ([uint64]$plan.DestinationVolume.SizeRemaining / 1TB))

    if ($PreflightOnly) {
        Write-ReplicaResult -Level PASS -Message 'Preflight-only mode completed. No VM or VHDX files were created.'
        exit 0
    }

    Write-ReplicaResult -Level WARN -Message 'The source host is running. The produced disks are a structural P2V copy, not a provably atomic live-state snapshot.'

    if ([string]::IsNullOrWhiteSpace($VMName)) {
        $VMName = 'Full-Host-Replica-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "A VM named '$VMName' already exists. Refusing to overwrite or modify it."
    }

    $replicaPath = Join-Path $plan.ReplicaRoot $VMName
    if (Test-Path -LiteralPath $replicaPath) {
        throw "Replica output path '$replicaPath' already exists. Refusing to overwrite it."
    }
    $diskPath = Join-Path $replicaPath 'Disks'
    New-Item -ItemType Directory -Path $diskPath -Force | Out-Null

    $clonedDisks = [System.Collections.Generic.List[object]]::new()
    foreach ($sourceDisk in $plan.SourceDisks) {
        $vhdxPath = Join-Path $diskPath ("Disk-{0}.vhdx" -f $sourceDisk.Number)
        Write-ReplicaResult -Level INFO -Message "Cloning physical disk $($sourceDisk.Number) ($([math]::Round($sourceDisk.Size / 1TB, 2)) TiB) to $vhdxPath."
        New-VHD -Path $vhdxPath -SourceDisk $sourceDisk.Number -Dynamic -ErrorAction Stop | Out-Null
        $vhdx = Get-VHD -Path $vhdxPath -ErrorAction Stop
        if ([uint64]$vhdx.Size -ne [uint64]$sourceDisk.Size) {
            throw "VHDX size mismatch for source disk $($sourceDisk.Number): expected $($sourceDisk.Size), got $($vhdx.Size)."
        }
        $clonedDisks.Add([pscustomobject]@{
            SourceDiskNumber = $sourceDisk.Number
            SourceSize = $sourceDisk.Size
            VhdxPath = $vhdxPath
            VhdxSize = $vhdx.Size
            VhdxFileSize = $vhdx.FileSize
            IsBootDisk = $sourceDisk.IsBoot
        })
        Write-ReplicaResult -Level PASS -Message "Disk $($sourceDisk.Number) cloned and structurally verified as a $($vhdx.VhdFormat) $($vhdx.VhdType) VHDX."
    }

    $manifestPath = Join-Path $replicaPath 'Replica-Manifest.json'
    Save-ReplicaManifest -Path $manifestPath -Plan $plan -ClonedDisks @($clonedDisks) -Name $VMName

    $vmPath = Join-Path $replicaPath 'VirtualMachine'
    New-VM -Name $VMName -Generation 2 -Path $vmPath -NoVHD -MemoryStartupBytes ($StartupMemoryGB * 1GB) -ErrorAction Stop | Out-Null
    Set-VM -Name $VMName -ProcessorCount $ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction TurnOff -ErrorAction Stop | Out-Null
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop | Out-Null

    $bootVhdx = $null
    foreach ($clonedDisk in $clonedDisks) {
        Add-VMHardDiskDrive -VMName $VMName -Path $clonedDisk.VhdxPath -ErrorAction Stop | Out-Null
        if ($clonedDisk.IsBootDisk) {
            $bootVhdx = $clonedDisk.VhdxPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($bootVhdx)) {
        throw 'No cloned boot disk was identified.'
    }
    $bootDrive = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $bootVhdx } | Select-Object -First 1
    if ($null -eq $bootDrive) {
        throw "Could not find the attached boot VHDX '$bootVhdx'."
    }
    Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDrive -ErrorAction Stop | Out-Null

    $adapters = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue)
    if ($adapters.Count -gt 0) {
        throw "VM '$VMName' unexpectedly has $($adapters.Count) network adapter(s). The replica must start isolated."
    }
    Write-ReplicaResult -Level PASS -Message "Created isolated Generation 2 VM '$VMName' with $($clonedDisks.Count) cloned physical disks and no network adapter."

    Start-VM -Name $VMName -ErrorAction Stop | Out-Null
    Write-ReplicaResult -Level INFO -Message "Started VM '$VMName'."
    Wait-ReplicaBoot -Name $VMName -TimeoutSeconds $BootTimeoutSeconds

    $vmConnect = Join-Path $env:WINDIR 'System32\vmconnect.exe'
    if (Test-Path -LiteralPath $vmConnect) {
        Start-Process -FilePath $vmConnect -ArgumentList @('localhost', $VMName) -ErrorAction Stop
        Write-ReplicaResult -Level PASS -Message "Opened the VM console for '$VMName'."
    }
}
catch {
    Add-ReplicaFailure -Message $_.Exception.Message
}

$elapsed = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
if ($failures.Count -gt 0) {
    Write-ReplicaResult -Level FAIL -Message "Disk-level P2V workflow finished with $($failures.Count) failure(s) in ${elapsed}s."
    exit 2
}

Write-ReplicaResult -Level PASS -Message "Disk-level P2V workflow finished successfully in ${elapsed}s."
exit 0
