# Burn-WinISOToUsb.ps1
# Writes a finished ISO to a USB flash drive so the drive is a bootable
# installation medium: it wipes the disk, creates one partition, formats it,
# mounts the ISO read-only and copies the media tree onto the drive.
#
# The filesystem defaults to NTFS, which UEFI firmware on current machines
# reads natively and which stores the whole install.wim without splitting.
# -FileSystem FAT32 keeps the drive recognised by the widest range of firmware
# and splits install.wim with DISM /Split-Image into install.swm parts (Windows
# Setup reads them natively) so no single file exceeds the 4 GB FAT32 limit.
# -FileSystem exFAT also stores the image whole and avoids FAT32's per-file
# limit; -FileSystem Auto picks FAT32 unless the media cannot fit it.
#
# Nothing is erased until the media is trusted: the ISO's own autounattend.xml
# and -AnswerFile are audited for a credential that would ship on the stick, and
# the media tree is compared with the per-file <iso>.media.json manifest the
# build writes beside the ISO. A damaged tree or a plaintext password is
# otherwise only discovered at install time, after the drive is already wiped.
#
# Progress protocol: one line per event, echoed to stdout and appended to
# -ProgressPath (the GUI polls that file):
#   PHASE:<text>
#   PROGRESS:<doneBytes>:<totalBytes>
#   DONE:<driveRoot>:<doneBytes>:<totalBytes>
#   ERROR:<text>
#
# Exit codes: 0 = success, 1 = failure (the ERROR line carries the reason).
#
# Examples:
#   .\Burn-WinISOToUsb.ps1 -IsoPath D:\WimMount\Output\win11.iso -DiskNumber 1
#   .\Burn-WinISOToUsb.ps1 -IsoPath D:\WimMount\Output\win11.iso -DiskNumber 1
#   .\Burn-WinISOToUsb.ps1 -IsoPath D:\WimMount\Output\win11.iso -DiskNumber 1 -FileSystem FAT32
#   .\Burn-WinISOToUsb.ps1 -IsoPath D:\WimMount\Output\win11.iso -DiskNumber 1 -DryRun
#   .\Burn-WinISOToUsb.ps1 -IsoPath D:\WimMount\Output\win11.iso -DiskNumber 1 -MediaManifest D:\WimMount\Output\win11.iso.media.json

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][int]$DiskNumber,
    [string]$ProgressPath = '',
    [ValidateSet('NTFS', 'FAT32', 'exFAT', 'Auto')][string]$FileSystem = 'NTFS',
    [string]$Label = 'WINISO',
    [string]$AnswerFile = '',
    [string]$MediaManifest = '',
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw ('Required module not found: ' + $modulePath) }
Import-Module -Name $modulePath -Force -ErrorAction Stop

# Boot files that must survive the copy for the drive to boot at all. Only the
# ones the ISO actually carries are required, so ISOs without a UEFI loader do
# not fail this check.
$script:BootFiles = @(
    'bootmgr',
    'boot\bcd',
    'sources\boot.wim',
    'efi\microsoft\boot\bootmgfw.efi'
)

$script:ProgressFile = $ProgressPath
$script:Done = [double]0
$script:Total = [double]0
$script:LastReport = [datetime]::MinValue

# FAT32 cannot hold a single file of 4 GiB or more; keep a little headroom.
$script:Fat32MaxFile = [double](4294967295 - 1048576)
# Windows refuses to format a FAT32 volume larger than 32 GB.
$script:Fat32MaxVolume = [uint64]32000000000

function Write-BurnLine {
    param([string]$Line)
    Write-Output $Line
    if ($script:ProgressFile) {
        try { [System.IO.File]::AppendAllText($script:ProgressFile, ($Line + [Environment]::NewLine)) } catch { }
    }
}

function Write-BurnProgress {
    param([switch]$ForceWrite)
    if ($script:Total -le 0) { return }
    if (-not $ForceWrite) {
        if (((Get-Date) - $script:LastReport).TotalMilliseconds -lt 400) { return }
    }
    $script:LastReport = Get-Date
    Write-BurnLine ('PROGRESS:' + [int64]$script:Done + ':' + [int64]$script:Total)
}

function Stop-Burn {
    param([string]$Message)
    Write-BurnLine ('ERROR:' + $Message)
    exit 1
}

function Assert-RootAlive {
    param([string]$Root, [string]$Stage)
    if (Test-Path -LiteralPath $Root) { return }
    Stop-Burn ('the drive (' + $Root + ') disappeared while ' + $Stage + '. The medium dropped off the bus mid-write, which usually means a failing or counterfeit flash drive, or a flaky USB port or hub. It cannot be used as installation media until it survives a full write without disconnecting.')
}

# Returns the bytes held by install*.swm in a folder, or -1 when the folder is
# unreachable (the drive vanished). Deliberately avoids -File: on a path whose
# drive has gone, PowerShell rejects that parameter instead of reporting a
# missing path.
function Get-SwmBytes {
    param([string]$Directory)
    $sum = [double]0
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $Directory -ErrorAction Stop)) {
            if (-not $item.PSIsContainer -and $item.Name -like 'install*.swm') { $sum += [double]$item.Length }
        }
    }
    catch { return [double](-1) }
    return $sum
}

function Get-FreeDriveLetter {
    $used = @{}
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue)) { if ($v.DriveLetter) { $used[[string]$v.DriveLetter] = $true } }
    foreach ($l in @('W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F')) {
        if (-not $used.ContainsKey($l)) { return $l }
    }
    return ''
}

function Copy-FileWithProgress {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $inStream = $null
    $outStream = $null
    try {
        $inStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $outStream = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] (4194304)
        while ($true) {
            $read = $inStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $outStream.Write($buffer, 0, $read)
            $script:Done += $read
            Write-BurnProgress
        }
        $outStream.Flush()
    }
    finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream) { $inStream.Dispose() }
    }
    try { [System.IO.File]::SetLastWriteTimeUtc($Destination, [System.IO.File]::GetLastWriteTimeUtc($Source)) } catch { }
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Stop-Burn 'this script must run elevated (formatting a disk and writing its boot sectors requires Administrator).'
}

# An answer file copied to the root of the stick is read by Setup as
# autounattend.xml; a structurally broken one is only discovered at install
# time, long after the drive was erased, so validate it first.
$answerSource = ''
if ($AnswerFile) {
    if (-not (Test-Path -LiteralPath $AnswerFile -PathType Leaf)) { Stop-Burn ('answer file not found: ' + $AnswerFile) }
    $answerCheck = Test-WinUnattendDocument -Path $AnswerFile
    if (-not $answerCheck.Ok) {
        Stop-Burn ('the answer file is not usable: ' + (@($answerCheck.Problems) -join '; '))
    }
    $answerSecrets = Test-WinUnattendSecrets -Path $AnswerFile
    $answerRisky = @($answerSecrets.Findings | Where-Object { $_.Severity -eq 'high' })
    if ($answerRisky.Count -gt 0) {
        Stop-Burn ('the answer file carries a credential that would be copied to the drive root as autounattend.xml (' + (($answerRisky | ForEach-Object { $_.Kind }) -join ', ') + '). Remove the password/product key, or provision it after deployment, before burning.')
    }
    $answerSource = (Resolve-Path -LiteralPath $AnswerFile).ProviderPath
}

$isoFull = [System.IO.Path]::GetFullPath($IsoPath)
if (-not (Test-Path -LiteralPath $isoFull -PathType Leaf)) { Stop-Burn ('source ISO not found: ' + $isoFull) }
$isoItem = Get-Item -LiteralPath $isoFull
if ($isoItem.Length -lt 100MB) { Stop-Burn ('source ISO looks too small to be installation media: ' + $isoFull) }

try { $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop }
catch { Stop-Burn ('disk ' + $DiskNumber + ' was not found: ' + $_.Exception.Message) }
if ($disk.IsBoot -eq $true) { Stop-Burn ('refusing to write to disk ' + $DiskNumber + ': it is the boot disk.') }
if ($disk.IsSystem -eq $true) { Stop-Burn ('refusing to write to disk ' + $DiskNumber + ': it is the system disk.') }
if ($disk.BusType -notmatch 'USB|SD' -and -not $Force) {
    Stop-Burn ('refusing to erase disk ' + $DiskNumber + ' (' + $disk.FriendlyName + ', bus ' + $disk.BusType + '): it is not a removable USB/SD disk. Pass -Force to override.')
}

# ---------------------------------------------------------------------------
# Mount the ISO read-only and plan the copy
# ---------------------------------------------------------------------------
$image = $null
$mounted = $false
try {
    Write-BurnLine ('PHASE:mounting ' + $isoItem.Name + ' (read-only)')
    $image = Mount-DiskImage -ImagePath $isoFull -PassThru -ErrorAction Stop
    $mounted = $true
    $mediaRoot = ''
    for ($i = 0; $i -lt 40; $i++) {
        $mv = Get-DiskImage -ImagePath $isoFull -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
        if ($mv -and $mv.DriveLetter) { $mediaRoot = ([string]$mv.DriveLetter) + ':\'; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $mediaRoot -or -not (Test-Path -LiteralPath $mediaRoot)) {
        Stop-Burn 'the ISO mounted but never received a drive letter, so its media cannot be read.'
    }

    Write-BurnLine ('PHASE:reading the media tree from ' + $mediaRoot)
    $files = @(Get-ChildItem -LiteralPath $mediaRoot -Recurse -File -Force -ErrorAction Stop)
    if ($files.Count -eq 0) { Stop-Burn ('the ISO media tree is empty: ' + $mediaRoot) }

    # An answer file inside the ISO is copied to the stick verbatim and read by
    # Setup, so a credential in it ships with the media.
    foreach ($shippedAnswer in @((Join-Path $mediaRoot 'autounattend.xml'), (Join-Path $mediaRoot 'sources\unattend.xml'))) {
        if (-not (Test-Path -LiteralPath $shippedAnswer -PathType Leaf)) { continue }
        $shippedAudit = Test-WinUnattendSecrets -Path $shippedAnswer
        $shippedRisky = @($shippedAudit.Findings | Where-Object { $_.Severity -eq 'high' })
        if ($shippedRisky.Count -gt 0) {
            Stop-Burn ('the ISO ships a credential in ' + (Split-Path -Leaf $shippedAnswer) + ' (' + (($shippedRisky | ForEach-Object { $_.Kind }) -join ', ') + '), which would be copied to the drive and read by Setup. Remove it and rebuild the ISO before burning.')
        }
    }

    # The build records every media file's size and SHA256 beside the ISO; check
    # the tree against it while the drive is still untouched.
    $manifestPath = $MediaManifest
    if (-not $manifestPath) { $manifestPath = $isoFull + '.media.json' }
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Write-BurnLine ('PHASE:verifying the media tree against ' + [System.IO.Path]::GetFileName($manifestPath))
        try {
            $mediaCheck = Test-WinISOMediaManifest -MediaRoot $mediaRoot -ManifestPath $manifestPath
        }
        catch {
            Stop-Burn ('the media manifest could not be read: ' + $_.Exception.Message)
        }
        if ($mediaCheck.Failed) {
            $details = @()
            foreach ($m in @($mediaCheck.Missing)) { $details += ('missing ' + $m) }
            foreach ($m in @($mediaCheck.Mismatched)) { $details += ($m.Path + ' ' + $m.Reason) }
            Stop-Burn ('the ISO does not match its media manifest (' + $details.Count + ' file(s)): ' + (($details | Select-Object -First 5) -join '; ') + '. Rebuild the ISO instead of burning a damaged one.')
        }
        Write-BurnLine ('PHASE:media manifest verified (' + $mediaCheck.Checked + ' file(s))')
    }
    else {
        Write-BurnLine ('PHASE:no media manifest beside the ISO (' + $manifestPath + '), so the per-file check is skipped')
    }

    $bigImage = ''
    foreach ($candidate in @('install.wim', 'install.esd')) {
        $p = Join-Path (Join-Path $mediaRoot 'sources') $candidate
        if (Test-Path -LiteralPath $p) { $bigImage = $p; break }
    }

    $needsSplit = $false
    $esdTooBig = $false
    if ($bigImage) {
        $bigLength = [double](Get-Item -LiteralPath $bigImage).Length
        if ($bigLength -ge $script:Fat32MaxFile) {
            if ([System.IO.Path]::GetFileName($bigImage) -ieq 'install.wim') { $needsSplit = $true }
            else { $esdTooBig = $true }
        }
    }

    $fileSystem = $FileSystem
    if ($fileSystem -eq 'Auto') {
        if ($esdTooBig) { $fileSystem = 'NTFS' }
        else { $fileSystem = 'FAT32' }
    }
    if ($fileSystem -eq 'FAT32' -and $esdTooBig) {
        Stop-Burn 'sources\install.esd is 4 GB or larger and cannot be split, so it does not fit on FAT32; re-run with -FileSystem NTFS.'
    }
    # Only FAT32 has the 4 GB per-file limit; NTFS and exFAT store the image whole.
    if ($fileSystem -ne 'FAT32') { $needsSplit = $false }

    $totalBytes = [double]0
    foreach ($f in $files) { $totalBytes += [double]$f.Length }
    $script:Total = $totalBytes

    $plan = 'disk ' + $DiskNumber + ' (' + $disk.FriendlyName + ', ' + [math]::Round($disk.Size / 1GB, 1) + ' GB) as ' + $fileSystem
    if ($needsSplit) { $plan += ', install.wim split into <4 GB parts' }
    if ($answerSource) { $plan += ', autounattend.xml validated and copied to the root' }
    Write-BurnLine ('PHASE:plan = ' + $plan + '; media ' + [math]::Round($totalBytes / 1GB, 2) + ' GB in ' + $files.Count + ' file(s)')

    if ($DryRun) {
        Write-BurnLine ('DONE:' + $mediaRoot + ':' + [int64]$totalBytes + ':' + [int64]$totalBytes)
        exit 0
    }

    # -----------------------------------------------------------------------
    # Partition and format
    # -----------------------------------------------------------------------
    Write-BurnLine ('PHASE:clearing disk ' + $DiskNumber)
    try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue } catch { }
    try { Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue } catch { }
    try {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-BurnLine ('INFO:Clear-Disk reported: ' + $_.Exception.Message)
    }
    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 500

    $disk = Get-Disk -Number $DiskNumber
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-BurnLine ('PHASE:initializing disk ' + $DiskNumber + ' (MBR)')
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -Confirm:$false -ErrorAction Stop
    }

    $wantSize = [uint64]$disk.Size
    if ($fileSystem -eq 'FAT32' -and $wantSize -gt $script:Fat32MaxVolume) { $wantSize = $script:Fat32MaxVolume }

    # Right after Clear-Disk the storage provider can still report the old
    # layout and New-Partition then fails with "Not enough available capacity".
    # Wait until the disk really exposes a free extent before partitioning.
    Write-BurnLine ('PHASE:waiting for disk ' + $DiskNumber + ' to become empty')
    $freeExtent = [uint64]0
    for ($i = 0; $i -lt 40; $i++) {
        try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch { }
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if ($disk) { $freeExtent = [uint64]$disk.LargestFreeExtent }
        if ($freeExtent -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($freeExtent -le 0) { Stop-Burn ('disk ' + $DiskNumber + ' never reported free space after clearing it.') }

    $partSize = $wantSize
    if ($partSize -gt $freeExtent) { $partSize = $freeExtent }
    # New-Partition aligns the first partition on a 1 MB boundary, so keep a
    # megabyte of margin below the reported free extent.
    $partSize = [uint64]([math]::Floor(($partSize - 1MB) / 1MB) * 1MB)
    if ($partSize -lt 1GB) { Stop-Burn ('disk ' + $DiskNumber + ' has too little free space for a usable partition.') }

    Write-BurnLine ('PHASE:creating a ' + [math]::Round($partSize / 1GB, 1) + ' GB partition on disk ' + $DiskNumber)
    $partition = $null
    try { $partition = New-Partition -DiskNumber $DiskNumber -Size $partSize -AssignDriveLetter -ErrorAction Stop }
    catch { Write-BurnLine ('INFO:New-Partition with an explicit size failed (' + $_.Exception.Message + '); retrying with UseMaximumSize') }
    if (-not $partition) {
        try { $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop }
        catch { Stop-Burn ('creating the partition failed: ' + $_.Exception.Message) }
    }

    Write-BurnLine 'PHASE:waiting for the new volume'
    $letter = ''
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $vol = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $letter = [string]$vol.DriveLetter; break }
    }
    if (-not $letter) {
        $free = Get-FreeDriveLetter
        if (-not $free) { Stop-Burn 'the new partition never received a drive letter and no letter is free to assign.' }
        try { Set-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $free -ErrorAction Stop }
        catch { Stop-Burn ('assigning a drive letter to the new partition failed: ' + $_.Exception.Message) }
        $letter = $free
    }

    Write-BurnLine ('PHASE:formatting ' + $letter + ': as ' + $fileSystem)
    try {
        Format-Volume -DriveLetter $letter -FileSystem $fileSystem -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Stop-Burn ('formatting ' + $letter + ': as ' + $fileSystem + ' failed: ' + $_.Exception.Message)
    }

    $volume = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($volume -and $volume.FileSystem) { break }
    }
    if (-not $volume) { Stop-Burn ('the formatted volume ' + $letter + ': did not come back online.') }

    $freeBytes = [double]$volume.SizeRemaining
    if ($freeBytes -lt ($totalBytes + 200MB)) {
        Stop-Burn ('not enough room on ' + $letter + ': (' + [math]::Round($freeBytes / 1GB, 2) + ' GB free, ' + [math]::Round($totalBytes / 1GB, 2) + ' GB of media).')
    }

    $destRoot = $letter + ':\'
    Write-BurnLine ('PHASE:copying media to ' + $destRoot)

    # -----------------------------------------------------------------------
    # Copy the media tree
    # -----------------------------------------------------------------------
    foreach ($dir in @(Get-ChildItem -LiteralPath $mediaRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
        $relDir = $dir.FullName.Substring($mediaRoot.Length)
        $target = Join-Path $destRoot $relDir
        if (-not (Test-Path -LiteralPath $target)) { [void](New-Item -ItemType Directory -Path $target -Force) }
    }

    $splitSource = ''
    $copied = 0
    foreach ($f in $files) {
        $relative = $f.FullName.Substring($mediaRoot.Length)
        if ($needsSplit -and $f.FullName -ieq $bigImage) { $splitSource = $f.FullName; continue }
        Copy-FileWithProgress -Source $f.FullName -Destination (Join-Path $destRoot $relative)
        $copied++
        if (($copied % 25) -eq 0) { Assert-RootAlive -Root $destRoot -Stage ('copying ' + $f.Name) }
    }
    Assert-RootAlive -Root $destRoot -Stage 'the media copy finished'
    $script:Done = $totalBytes
    Write-BurnProgress -ForceWrite

    if ($splitSource) {
        $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
        if (-not (Test-Path -LiteralPath $dism)) { Stop-Burn 'Dism.exe was not found, so install.wim cannot be split for FAT32.' }
        $destSources = Join-Path $destRoot 'sources'
        if (-not (Test-Path -LiteralPath $destSources)) { [void](New-Item -ItemType Directory -Path $destSources -Force) }
        $swmBase = Join-Path $destSources 'install.swm'
        Write-BurnLine 'PHASE:splitting install.wim into 3.8 GB parts (FAT32 file limit)'
        $baseDone = $script:Done - (Get-Item -LiteralPath $splitSource).Length
        $splitArgs = @('/English', '/Split-Image', ('/ImageFile:' + $splitSource), ('/SWMFile:' + $swmBase), '/FileSize:3800', '/NoRestart')
        $dismLog = Join-Path ([System.IO.Path]::GetTempPath()) ('winiso-dism-split-' + [guid]::NewGuid().ToString('N') + '.log')
        try {
            $proc = Start-Process -FilePath $dism -ArgumentList $splitArgs -NoNewWindow -PassThru -ErrorAction Stop -RedirectStandardOutput $dismLog
        }
        catch {
            Stop-Burn ('starting Dism /Split-Image failed: ' + $_.Exception.Message)
        }
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 1000
            $swmBytes = Get-SwmBytes -Directory $destSources
            if ($swmBytes -lt 0) { Assert-RootAlive -Root $destRoot -Stage 'Dism /Split-Image was writing install.swm' }
            $script:Done = $baseDone + $swmBytes
            Write-BurnProgress
        }
        $proc.WaitForExit()
        Assert-RootAlive -Root $destRoot -Stage 'Dism /Split-Image finished'
        if ($proc.ExitCode -ne 0) {
            $detail = ''
            try {
                $dismText = [string](Get-Content -LiteralPath $dismLog -Raw -ErrorAction SilentlyContinue)
                $errLines = @(($dismText -split "`r?`n") | Where-Object { $_ -match '^(Error|The device|An error)' } | Select-Object -First 2)
                if ($errLines.Count -gt 0) { $detail = ' Dism said: ' + ($errLines -join ' ') }
            }
            catch { }
            Stop-Burn ('Dism /Split-Image failed with exit code ' + $proc.ExitCode + '; the drive is formatted but incomplete.' + $detail)
        }
        $swmBytes = Get-SwmBytes -Directory $destSources
        if ($swmBytes -le 0) { Stop-Burn 'Dism /Split-Image reported success but wrote no install*.swm file.' }
        $script:Done = $totalBytes
        Write-BurnProgress -ForceWrite
    }

    # A drive that loses power mid-write can leave truncated files behind, so
    # confirm every copied file is still there at its full size before the burn
    # is called complete.
    Write-BurnLine 'PHASE:verifying the written files'
    $missing = 0
    $short = 0
    foreach ($f in $files) {
        if ($needsSplit -and $f.FullName -ieq $bigImage) { continue }
        $relative = $f.FullName.Substring($mediaRoot.Length)
        $written = Join-Path $destRoot $relative
        $length = -1
        try { $length = [double](Get-Item -LiteralPath $written -ErrorAction Stop).Length } catch { $missing++ ; continue }
        if ($length -ne [double]$f.Length) { $short++ }
    }
    if ($missing -gt 0 -or $short -gt 0) {
        Stop-Burn ('verification failed: ' + $missing + ' file(s) missing and ' + $short + ' file(s) truncated on ' + $destRoot + '. The drive did not keep the data it accepted.')
    }
    if ($needsSplit) {
        $swmTotal = Get-SwmBytes -Directory (Join-Path $destRoot 'sources')
        $wimSize = [double](Get-Item -LiteralPath $bigImage).Length
        if ($swmTotal -lt ($wimSize * 0.99)) {
            Stop-Burn ('verification failed: the split image holds ' + [math]::Round($swmTotal / 1GB, 2) + ' GB of ' + [math]::Round($wimSize / 1GB, 2) + ' GB.')
        }
    }

    # A drive can hold every file and still not boot (a missing bootmgr or bcd
    # is the classic result of a copy that silently skipped the root). Check the
    # boot chain the ISO carried, not just the file sizes.
    Write-BurnLine 'PHASE:verifying the boot files'
    $bootMissing = @()
    foreach ($rel in @($script:BootFiles)) {
        $onIso = Join-Path $mediaRoot $rel
        if (-not (Test-Path -LiteralPath $onIso)) { continue }
        $onDrive = Join-Path $destRoot $rel
        if (-not (Test-Path -LiteralPath $onDrive)) { $bootMissing += $rel }
    }
    if ($bootMissing.Count -gt 0) {
        Stop-Burn ('verification failed: the drive is missing the boot file(s) ' + ($bootMissing -join ', ') + ', so it will not start Setup.')
    }
    Write-BurnLine 'PHASE:boot files verified (bootmgr/bcd/boot.wim/UEFI loader that the ISO carried)'

    if ($answerSource) {
        $answerTarget = Join-Path $destRoot 'autounattend.xml'
        Copy-Item -LiteralPath $answerSource -Destination $answerTarget -Force
        if (-not (Test-Path -LiteralPath $answerTarget)) {
            Stop-Burn 'the answer file could not be copied to the root of the drive.'
        }
        Write-BurnLine ('PHASE:autounattend.xml copied to ' + $answerTarget)
    }

    try { Write-VolumeCache -DriveLetter $letter -ErrorAction SilentlyContinue | Out-Null } catch { }

    Write-BurnLine ('DONE:' + $destRoot + ':' + [int64]$script:Done + ':' + [int64]$script:Total)
    exit 0
}
catch {
    Write-BurnLine ('ERROR:' + $_.Exception.Message)
    exit 1
}
finally {
    if ($mounted) { try { Dismount-DiskImage -ImagePath $isoFull -ErrorAction SilentlyContinue | Out-Null } catch { } }
}
