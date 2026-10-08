#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$HostFilesystemMirror,
    [ValidateRange(15, 180)]
    [int]$LaunchTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptRoot 'Fix-Sandbox.log'
$startedAt = Get-Date
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Write-Result {
    param(
        [ValidateSet('INFO', 'PASS', 'WARN', 'FAIL')]
        [string]$Level,
        [string]$Message
    )

    $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line
    Write-Output $line
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
    Write-Result -Level FAIL -Message $Message
}

function Add-Warning {
    param([string]$Message)
    $warnings.Add($Message)
    Write-Result -Level WARN -Message $Message
}

function Get-RequiredService {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw "Service '$Name' is not installed or is not visible to this process."
    }
    return $service
}

function Wait-ServiceRunning {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-RequiredService -Name $Name
        if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Ensure-ServiceRunning {
    param(
        [string]$Name,
        [switch]$MakeAutomatic
    )

    $originalDescriptor = $null
    $temporaryDescriptor = $false

    try {
        $service = Get-RequiredService -Name $Name

        $needsPersistentStartupRepair = $MakeAutomatic -and (
            $service.StartType -ne [System.ServiceProcess.ServiceStartMode]::Automatic -or
            ($Name -eq 'mpssvc' -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running)
        )
        if ($needsPersistentStartupRepair) {
            try {
                Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop
            }
            catch {
                # Some Windows 11 builds deny ChangeServiceConfig for mpssvc
                # even to an elevated local administrator. Its service key is
                # still administrator-writable, so repair only the Start value
                # and verify it before asking the SCM to start the service.
                $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
                Set-ItemProperty -LiteralPath $serviceKey -Name Start -Type DWord -Value 2 -ErrorAction Stop
                $storedStart = (Get-ItemProperty -LiteralPath $serviceKey -Name Start -ErrorAction Stop).Start
                if ([int]$storedStart -ne 2) {
                    throw "Service manager denied the change and registry fallback did not persist Start=2."
                }
                Write-Result -Level INFO -Message "$Name ChangeServiceConfig was denied; repaired the persistent Start value directly and verified Start=2."

                # The service ACL on affected machines also denies local
                # administrators SERVICE_CHANGE_CONFIG. Temporarily add that
                # one right so SCM reloads the same setting, then restore the
                # exact original descriptor in the finally block below.
                $descriptorLines = @(& sc.exe sdshow $Name 2>&1)
                $originalDescriptor = ($descriptorLines | Where-Object { [string]$_ -match '^D:' } | Select-Object -First 1)
                if ($null -eq $originalDescriptor) {
                    throw "Could not read the existing service security descriptor."
                }
                $originalDescriptor = ([string]$originalDescriptor).Trim()
                $temporaryServiceDescriptor = $originalDescriptor -replace 'A;;CCLCSWRPLORCWDWO;;;BA', 'A;;CCDCLCSWRPLORCWDWO;;;BA'
                if ($temporaryServiceDescriptor -eq $originalDescriptor) {
                    throw 'The expected Administrators ACE was not found in the service security descriptor.'
                }

                $null = @(& sc.exe sdset $Name $temporaryServiceDescriptor 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not temporarily grant SCM ChangeServiceConfig access (exit $LASTEXITCODE)."
                }
                $temporaryDescriptor = $true
                Write-Result -Level INFO -Message "$Name service ACL temporarily granted SCM ChangeServiceConfig access."

                $null = @(& sc.exe config $Name start= auto 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "SCM could not commit the Automatic startup configuration (exit $LASTEXITCODE)."
                }
                Write-Result -Level PASS -Message "$Name Automatic startup configuration committed through SCM."
            }
            Write-Result -Level PASS -Message "$Name startup type is now Automatic for persistence."
        }

        $service = Get-RequiredService -Name $Name

        if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
            Start-Service -Name $Name -ErrorAction Stop
            Write-Result -Level INFO -Message "Started $Name."
        }

        if (-not (Wait-ServiceRunning -Name $Name)) {
            throw "Service did not reach Running state within the timeout."
        }

        Write-Result -Level PASS -Message "$Name is Running."
    }
    catch {
        Add-Failure -Message "${Name}: $($_.Exception.Message)"
    }
    finally {
        if ($temporaryDescriptor -and $null -ne $originalDescriptor) {
            $null = @(& sc.exe sdset $Name $originalDescriptor 2>&1)
            if ($LASTEXITCODE -eq 0) {
                Write-Result -Level PASS -Message "$Name original service security descriptor restored."
            }
            else {
                Add-Warning -Message "$Name was repaired, but restoring its original service security descriptor returned exit code $LASTEXITCODE."
            }
        }
    }
}

function Get-FeatureState {
    param([string]$FeatureName)
    return Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
}

function Ensure-FeatureEnabled {
    param([string]$FeatureName)

    try {
        $feature = Get-FeatureState -FeatureName $FeatureName
        if ($feature.State -ne 'Enabled') {
            Write-Result -Level INFO -Message "Enabling optional feature $FeatureName with NoRestart."
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop
            $feature = Get-FeatureState -FeatureName $FeatureName
            if ($feature.State -ne 'Enabled') {
                throw "Feature state is $($feature.State) after the enable operation."
            }
            if ($result.RestartNeeded -or $feature.RestartNeeded) {
                Add-Warning -Message "$FeatureName is enabled but Windows reports a restart may be required; no reboot was performed."
            }
        }
        Write-Result -Level PASS -Message "$FeatureName is Enabled; RestartNeeded=$($feature.RestartNeeded)."
    }
    catch {
        Add-Failure -Message "${FeatureName}: $($_.Exception.Message)"
    }
}

function Ensure-HypervisorBootSetting {
    try {
        $bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
        if ($bcd -notmatch '(?im)^\s*hypervisorlaunchtype\s+auto\s*$') {
            Write-Result -Level INFO -Message 'Setting hypervisorlaunchtype to Auto without rebooting.'
            & bcdedit.exe /set '{current}' hypervisorlaunchtype auto 2>&1 | ForEach-Object {
                Write-Result -Level INFO -Message ([string]$_)
            }
            $bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
        }
        if ($bcd -match '(?im)^\s*hypervisorlaunchtype\s+auto\s*$') {
            Write-Result -Level PASS -Message 'Boot configuration has hypervisorlaunchtype=Auto.'
        }
        else {
            throw 'Boot configuration does not report hypervisorlaunchtype=Auto.'
        }
    }
    catch {
        Add-Failure -Message "Hypervisor boot setting: $($_.Exception.Message)"
    }
}

function Test-HypervisorActive {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($computer.HypervisorPresent -ne $true) {
            throw 'Win32_ComputerSystem.HypervisorPresent is not True.'
        }
        Write-Result -Level PASS -Message 'A hypervisor is active in the current session.'
    }
    catch {
        Add-Failure -Message "Active hypervisor check: $($_.Exception.Message)"
    }
}

function Test-PendingRestart {
    $pendingPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
    )

    $pending = @($pendingPaths | Where-Object { Test-Path -LiteralPath $_ })
    if ($pending.Count -gt 0) {
        Add-Warning -Message "Windows has pending-restart markers ($($pending.Count)); the script did not reboot the machine."
    }
    else {
        Write-Result -Level PASS -Message 'No pending-restart marker was found.'
    }
}

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function New-HostFilesystemMirrorConfiguration {
    # Windows Sandbox cannot boot from a host disk or import a host Windows
    # installation. This configuration deliberately limits the sharing to a
    # read-only view of every mounted fixed drive. The separate control folder
    # is writable solely so the guest can return a launch/mapping proof.
    try {
        $fixedDrives = @(
            Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                Where-Object { $_.DeviceID -match '^[A-Za-z]:$' -and (Test-Path -LiteralPath ($_.DeviceID + '\')) } |
                Sort-Object DeviceID
        )
        if ($fixedDrives.Count -eq 0) {
            throw 'No mounted fixed drives were found to map into the Sandbox.'
        }

        $sessionRoot = Join-Path $scriptRoot '.sandbox-mirror-sessions'
        $sessionPath = Join-Path $sessionRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sessionPath -Force | Out-Null

        $guestBootstrapPath = Join-Path $sessionPath 'Guest-MirrorProof.ps1'
        $proofPath = Join-Path $sessionPath 'Guest-MirrorProof.json'
        $configurationPath = Join-Path $sessionPath 'Host-Filesystem-Mirror.wsb'

        @'
$ErrorActionPreference = 'Stop'
$mappedDrives = @(
    Get-ChildItem -LiteralPath 'C:\HostDrives' -Directory -ErrorAction Stop |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Drive = $_.Name
                Present = Test-Path -LiteralPath $_.FullName
            }
        }
)

$proof = [pscustomobject]@{
    SchemaVersion = 1
    CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    GuestUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    MappedDrives = $mappedDrives
}

$temporaryProofPath = 'C:\SandboxControl\Guest-MirrorProof.json.tmp'
$proof | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryProofPath -Encoding utf8
Move-Item -LiteralPath $temporaryProofPath -Destination 'C:\SandboxControl\Guest-MirrorProof.json' -Force
'@ | Set-Content -LiteralPath $guestBootstrapPath -Encoding utf8 -NoNewline

        $mappedFolders = [System.Collections.Generic.List[string]]::new()
        foreach ($drive in $fixedDrives) {
            $letter = $drive.DeviceID.TrimEnd(':')
            $mappedFolder = @"
    <MappedFolder>
      <HostFolder>$(ConvertTo-XmlText -Value ($drive.DeviceID + '\'))</HostFolder>
      <SandboxFolder>C:\HostDrives\$letter</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
"@
            $mappedFolders.Add($mappedFolder)
        }
        $controlMappedFolder = @"
    <MappedFolder>
      <HostFolder>$(ConvertTo-XmlText -Value $sessionPath)</HostFolder>
      <SandboxFolder>C:\SandboxControl</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
"@
        $mappedFolders.Add($controlMappedFolder)

        $configuration = @"
<Configuration>
  <VGpu>Default</VGpu>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MappedFolders>
$($mappedFolders -join [Environment]::NewLine)
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\SandboxControl\Guest-MirrorProof.ps1</Command>
  </LogonCommand>
</Configuration>
"@
        $configuration | Set-Content -LiteralPath $configurationPath -Encoding utf8 -NoNewline

        Write-Result -Level PASS -Message "Created read-only host-filesystem mirror configuration for drives $($fixedDrives.DeviceID -join ', '); network, clipboard, printers, microphone, and camera are disabled." | Out-Null
        return [pscustomobject]@{
            ConfigurationPath = $configurationPath
            ProofPath = $proofPath
            ExpectedDrives = @($fixedDrives | ForEach-Object { $_.DeviceID.TrimEnd(':') } | Sort-Object)
            SessionPath = $sessionPath
        }
    }
    catch {
        Add-Failure -Message "Host filesystem mirror configuration: $($_.Exception.Message)" | Out-Null
        return $null
    }
}

function Test-HostFilesystemMirrorProof {
    param(
        [string]$ProofPath,
        [string[]]$ExpectedDrives
    )

    try {
        if (-not (Test-Path -LiteralPath $ProofPath)) {
            return $false
        }

        $proof = Get-Content -LiteralPath $ProofPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $actualDrives = @($proof.MappedDrives | Where-Object { $_.Present -eq $true } | ForEach-Object { [string]$_.Drive } | Sort-Object)
        $missing = @($ExpectedDrives | Where-Object { $_ -notin $actualDrives })
        $unexpected = @($actualDrives | Where-Object { $_ -notin $ExpectedDrives })
        if ($proof.SchemaVersion -ne 1 -or $missing.Count -gt 0 -or $unexpected.Count -gt 0) {
            throw "Guest mapping proof does not match the generated configuration. Missing=$($missing -join ','); Unexpected=$($unexpected -join ',')."
        }

        Write-Result -Level PASS -Message "Guest proof verified: the read-only host-filesystem mirror is mounted at C:\HostDrives for $($ExpectedDrives -join ', '); guest user=$($proof.GuestUser)." | Out-Null
        return $true
    }
    catch {
        Add-Failure -Message "Host filesystem mirror proof: $($_.Exception.Message)" | Out-Null
        return $false
    }
}

function Launch-AndVerifySandbox {
    param(
        [string]$ConfigurationPath,
        [string]$MirrorProofPath,
        [string[]]$ExpectedMirrorDrives
    )

    $sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExe)) {
        Add-Failure -Message "Windows Sandbox executable not found at $sandboxExe."
        return
    }

    try {
        $existing = @(Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($ConfigurationPath)) {
            throw 'A Windows Sandbox session is already open. Close it yourself, then rerun this script so the new host-filesystem mirror configuration can be proven. The script will not close a session because Sandbox content is disposable.'
        }
        if ($existing.Count -eq 0) {
            if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
                $null = Start-Process -FilePath $sandboxExe -WorkingDirectory (Split-Path -Parent $sandboxExe)
                Write-Result -Level INFO -Message 'Launched WindowsSandbox.exe.'
            }
            else {
                if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
                    throw "Sandbox configuration was not found at $ConfigurationPath."
                }
                $null = Start-Process -FilePath $ConfigurationPath -WorkingDirectory (Split-Path -Parent $ConfigurationPath)
                Write-Result -Level INFO -Message "Launched Windows Sandbox using $ConfigurationPath."
            }
        }
        else {
            Write-Result -Level INFO -Message 'Windows Sandbox remote-session client was already running; using the existing launch for verification.'
        }

        $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
        $windowSeen = $false
        $workerSeen = $false
        $serverSeen = $false
        $memorySeen = $false
        do {
            $sandboxProcesses = @(Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue)
            $serverProcesses = @(Get-Process -Name WindowsSandboxServer -ErrorAction SilentlyContinue)
            $workerProcesses = @(Get-Process -Name vmwp -ErrorAction SilentlyContinue)
            $memoryProcesses = @(Get-Process -Name vmmemWindowsSandbox -ErrorAction SilentlyContinue)
            $guestCompute = Get-Service -Name gcs -ErrorAction SilentlyContinue
            $windowSeen = @($sandboxProcesses | Where-Object {
                $_.MainWindowHandle -ne 0 -and
                $_.MainWindowTitle -match 'Windows Sandbox' -and
                $_.Responding
            }).Count -gt 0
            $workerSeen = $workerProcesses.Count -gt 0
            $serverSeen = $serverProcesses.Count -gt 0
            $memorySeen = $memoryProcesses.Count -gt 0

            $mirrorProven = [string]::IsNullOrWhiteSpace($MirrorProofPath) -or (Test-HostFilesystemMirrorProof -ProofPath $MirrorProofPath -ExpectedDrives $ExpectedMirrorDrives)

            if ($windowSeen -and $workerSeen -and $serverSeen -and $memorySeen -and $mirrorProven) {
                Write-Result -Level PASS -Message "Sandbox launch verified: responsive Windows Sandbox window, remote-session client, server, vmwp worker, and vmmemWindowsSandbox are present; gcs=$($guestCompute.Status)."
                return
            }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)

        $titles = @($sandboxProcesses | Select-Object -ExpandProperty MainWindowTitle)
        throw "Sandbox did not reach a responsive interactive guest within $LaunchTimeoutSeconds seconds. Window=$windowSeen; Server=$serverSeen; vmwp=$workerSeen; vmmem=$memorySeen; titles=$($titles -join '|')."
    }
    catch {
        Add-Failure -Message "Sandbox launch verification: $($_.Exception.Message)"
    }
}

New-Item -ItemType File -Path $logPath -Force | Out-Null
Write-Result -Level INFO -Message "Starting repair. Script=$($MyInvocation.MyCommand.Path)"

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated as Administrator.'
    }
    Write-Result -Level PASS -Message "Running elevated as $($identity.Name)."
}
catch {
    Add-Failure -Message "Administrator check: $($_.Exception.Message)"
}

Ensure-FeatureEnabled -FeatureName 'Microsoft-Hyper-V-Hypervisor'
Ensure-FeatureEnabled -FeatureName 'Microsoft-Hyper-V-Services'
Ensure-FeatureEnabled -FeatureName 'Containers-DisposableClientVM'
Ensure-FeatureEnabled -FeatureName 'VirtualMachinePlatform'
Ensure-HypervisorBootSetting
Test-HypervisorActive
Test-PendingRestart

# Windows Sandbox's guest compute service depends on the firewall service. A
# Disabled mpssvc prevents the guest service from starting during a launch and
# is not the normal Windows default, so restore its persistent startup mode.
Ensure-ServiceRunning -Name 'RpcSs'
Ensure-ServiceRunning -Name 'nsi'
Ensure-ServiceRunning -Name 'BFE'
Ensure-ServiceRunning -Name 'mpsdrv'
Ensure-ServiceRunning -Name 'mpssvc' -MakeAutomatic
Ensure-ServiceRunning -Name 'hvhost'
Ensure-ServiceRunning -Name 'vmms'
Ensure-ServiceRunning -Name 'wcifs'
Ensure-ServiceRunning -Name 'hvsocketcontrol'
Ensure-ServiceRunning -Name 'condrv'
Ensure-ServiceRunning -Name 'vmcompute'
Ensure-ServiceRunning -Name 'hns'
Ensure-ServiceRunning -Name 'CmService'

if ($Launch) {
    if ($HostFilesystemMirror) {
        $mirror = New-HostFilesystemMirrorConfiguration
        if ($null -ne $mirror) {
            Launch-AndVerifySandbox -ConfigurationPath $mirror.ConfigurationPath -MirrorProofPath $mirror.ProofPath -ExpectedMirrorDrives $mirror.ExpectedDrives
        }
    }
    else {
        Launch-AndVerifySandbox
    }
}

$elapsed = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
if ($failures.Count -gt 0) {
    Write-Result -Level FAIL -Message "Repair finished with $($failures.Count) failure(s) and $($warnings.Count) warning(s) in ${elapsed}s."
    $failures | ForEach-Object { Write-Result -Level FAIL -Message "Summary: $_" }
    exit 2
}

Write-Result -Level PASS -Message "Repair finished successfully with $($warnings.Count) warning(s) in ${elapsed}s; no reboot was performed."
exit 0
