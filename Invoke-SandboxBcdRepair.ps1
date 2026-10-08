#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$TargetVhd,

    [ValidateRange(60, 600)]
    [int]$TimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-XmlText {
    param([string]$Value)
    [System.Security.SecurityElement]::Escape($Value)
}

function Get-FreeDriveLetter {
    foreach ($codePoint in 70..89) {
        $letter = [char]$codePoint
        if (-not (Test-Path ("{0}:\" -f $letter))) {
            return [string]$letter
        }
    }
    throw 'No free temporary drive letter is available.'
}

$sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) {
    throw "Windows Sandbox is unavailable at $sandboxExe."
}

$targetVhd = (Resolve-Path -LiteralPath $TargetVhd).Path
$sessionRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '.sandbox-bcd-sessions'
$sessionPath = Join-Path $sessionRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionPath -Force | Out-Null

$guestScript = Join-Path $sessionPath 'Guest-BcdFactory.ps1'
$proofPath = Join-Path $sessionPath 'BcdFactory-proof.json'
$genericBcdPath = Join-Path $sessionPath 'Generic-BCD'
$wsbPath = Join-Path $sessionPath 'Create-Generic-Bcd.wsb'

@'
$ErrorActionPreference = 'Stop'
$proofPath = 'C:\SandboxControl\BcdFactory-proof.json'
$outputStore = 'C:\SandboxControl\Generic-BCD'
$factoryVhd = 'C:\BcdFactory.vhdx'
$store = 'S:\EFI\Microsoft\Boot\BCD'
$attached = $false

try {
    if (Test-Path -LiteralPath 'S:\') {
        throw 'Drive letter S is unexpectedly in use inside Windows Sandbox.'
    }

    $createScript = Join-Path $env:TEMP 'create-bcd-factory-vhd.txt'
    @"
create vdisk file="$factoryVhd" maximum=128 type=expandable
select vdisk file="$factoryVhd"
attach vdisk
convert gpt
create partition efi size=100
format quick fs=fat32 label=BCD
assign letter=S
"@ | Set-Content -LiteralPath $createScript -Encoding ascii

    $diskpartOutput = & diskpart.exe /s $createScript 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath 'S:\')) {
        throw "diskpart factory disk creation failed (exit $LASTEXITCODE): $($diskpartOutput -join ' ')"
    }
    $attached = $true

    $bcdbootOutput = & bcdboot.exe 'C:\Windows' /s 'S:' /f UEFI /c /nofirmwaresync 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $store)) {
        throw "bcdboot failed (exit $LASTEXITCODE): $($bcdbootOutput -join ' ')"
    }

    # LOCATE asks Boot Manager to find the volume containing the loader path
    # (or SystemRoot for osdevice), avoiding source-machine partition IDs.
    $commands = @(
        @('/store', $store, '/set', '{bootmgr}', 'device', 'boot'),
        @('/store', $store, '/set', '{default}', 'device', 'locate'),
        @('/store', $store, '/set', '{default}', 'osdevice', 'locate'),
        @('/store', $store, '/set', '{default}', 'path', '\Windows\System32\winload.efi'),
        @('/store', $store, '/set', '{default}', 'systemroot', '\Windows')
    )
    foreach ($arguments in $commands) {
        $editOutput = & bcdedit.exe @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "bcdedit failed (exit $LASTEXITCODE): $($editOutput -join ' ')"
        }
    }

    $enumOutput = & bcdedit.exe /store $store /enum '{default}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit validation failed (exit $LASTEXITCODE): $($enumOutput -join ' ')"
    }
    $enumText = $enumOutput -join "`n"
    if ($enumText -notmatch '(?im)^device\s+locate' -or $enumText -notmatch '(?im)^osdevice\s+locate') {
        throw "Generated store does not contain LOCATE device entries: $enumText"
    }

    Copy-Item -LiteralPath $store -Destination $outputStore -Force
    $hash = (Get-FileHash -LiteralPath $outputStore -Algorithm SHA256).Hash
    [pscustomobject]@{
        SchemaVersion = 2
        Success = $true
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        GuestUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        BcdSha256 = $hash
        Enumeration = $enumText
    } | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding utf8
}
catch {
    [pscustomobject]@{
        SchemaVersion = 2
        Success = $false
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Error = $_.Exception.Message
    } | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding utf8
}
finally {
    if ($attached) {
        $detachScript = Join-Path $env:TEMP 'detach-bcd-factory-vhd.txt'
        @"
select vdisk file="$factoryVhd"
detach vdisk
"@ | Set-Content -LiteralPath $detachScript -Encoding ascii
        & diskpart.exe /s $detachScript | Out-Null
    }
    Remove-Item -LiteralPath $factoryVhd -Force -ErrorAction SilentlyContinue
}
'@ | Set-Content -LiteralPath $guestScript -Encoding utf8 -NoNewline

$wsb = @"
<Configuration>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(ConvertTo-XmlText $sessionPath)</HostFolder>
      <SandboxFolder>C:\SandboxControl</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\SandboxControl\Guest-BcdFactory.ps1</Command>
  </LogonCommand>
</Configuration>
"@
$wsb | Set-Content -LiteralPath $wsbPath -Encoding utf8 -NoNewline

if (@(Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'A Windows Sandbox session is already open. Close it before generating the isolated BCD store.'
}

Start-Process -FilePath $wsbPath -WorkingDirectory $sessionPath | Out-Null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    if (Test-Path -LiteralPath $proofPath) {
        $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
        if ($proof.Success -ne $true -or $proof.SchemaVersion -ne 2) {
            throw "Sandbox BCD factory failed: $($proof.Error)"
        }
        if (-not (Test-Path -LiteralPath $genericBcdPath -PathType Leaf)) {
            throw 'Sandbox reported success but did not return Generic-BCD.'
        }
        $actualHash = (Get-FileHash -LiteralPath $genericBcdPath -Algorithm SHA256).Hash
        if ($actualHash -ne $proof.BcdSha256) {
            throw 'Generic-BCD hash does not match the Sandbox proof.'
        }
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if (-not (Test-Path -LiteralPath $proofPath)) {
    throw "Sandbox did not return a BCD factory proof within $TimeoutSeconds seconds. Session=$sessionPath"
}

$mounted = $false
$diskNumber = $null
$efiAccessPath = $null
$efiLetterWasAdded = $false
try {
    $disk = Mount-VHD -Path $targetVhd -Passthru
    $mounted = $true
    $diskNumber = $disk.DiskNumber
    $physicalDisk = Get-Disk -Number $diskNumber
    if ($physicalDisk.IsOffline) { Set-Disk -Number $diskNumber -IsOffline $false }
    if ($physicalDisk.IsReadOnly) { Set-Disk -Number $diskNumber -IsReadOnly $false }

    $efi = @(Get-Partition -DiskNumber $diskNumber | Where-Object {
        $_.GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    })
    if ($efi.Count -ne 1) {
        throw "Expected exactly one EFI partition in the target VHD; found $($efi.Count)."
    }

    $existingAccessPath = @($efi[0].AccessPaths | Where-Object { $_ -match '^[A-Z]:\\$' } | Select-Object -First 1)
    if ($existingAccessPath.Count -eq 1) {
        $efiAccessPath = $existingAccessPath[0]
    }
    else {
        $letter = Get-FreeDriveLetter
        Set-Partition -DiskNumber $diskNumber -PartitionNumber $efi[0].PartitionNumber -NewDriveLetter $letter
        $efiAccessPath = "${letter}:\"
        $efiLetterWasAdded = $true
    }

    $destination = Join-Path $efiAccessPath 'EFI\Microsoft\Boot\BCD'
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        $backupName = 'BCD.before-sandbox-locate-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $destination -Destination (Join-Path $sessionPath $backupName) -Force
    }
    Copy-Item -LiteralPath $genericBcdPath -Destination $destination -Force
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($destinationHash -ne $actualHash) {
        throw 'The BCD store written to the target EFI partition failed hash verification.'
    }
}
finally {
    if ($mounted) {
        if ($efiLetterWasAdded -and $efiAccessPath) {
            Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $efi[0].PartitionNumber -AccessPath $efiAccessPath -ErrorAction SilentlyContinue
        }
        Dismount-VHD -Path $targetVhd -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    SchemaVersion = 2
    Success = $true
    TargetVhd = $targetVhd
    BcdSha256 = $actualHash
    SandboxProof = $proofPath
    SandboxEnumeration = $proof.Enumeration
}
