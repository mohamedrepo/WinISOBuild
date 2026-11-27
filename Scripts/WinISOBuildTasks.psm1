# WinISOBuildTasks.psm1
# Stage implementations for Build-WinISOUpdated.ps1:
#
#   Invoke-WinISOMediaExport      mount the source ISO, copy the media, export
#                                 one or more indexes into sources\install.wim
#   Invoke-WinISOIndexServicing   mount one install.wim index, add packages,
#                                 drivers, capabilities/features, clean up and
#                                 commit it
#   Invoke-WinISOBootWimServicing mount sources\boot.wim (index 2 = WinPE), add
#                                 the storage drivers and the cumulative update
#                                 so Setup can see a VMD/RAID disk
#   Get-WinISOIsoBootData         boot data argument for oscdimg, per
#                                 architecture (x64 = BIOS + UEFI, arm64 = UEFI)
#   New-WinISOIsoFile             run oscdimg
#
# Every function reports through a -Log scriptblock the caller supplies, so the
# orchestrator keeps a single log/status implementation.
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7. ASCII-only,
#                 BOM-less UTF-8.

Set-StrictMode -Version 2

$script:DefaultDism = Join-Path $env:SystemRoot 'System32\Dism.exe'

$script:IntegrityModule = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (Test-Path -LiteralPath $script:IntegrityModule) {
    Import-Module -Name $script:IntegrityModule -Force -ErrorAction SilentlyContinue
}

function Write-TaskLog {
    param([scriptblock]$Log, [string]$Message)
    if ($Log) { & $Log $Message }
}

# Runs DISM with the run's log file attached and returns @{ Code; Text }.
function Invoke-TaskDism {
    param(
        [string[]]$Arguments,
        [string]$LogFile = '',
        [scriptblock]$Log = $null,
        [string]$DismPath = ''
    )
    $dism = $DismPath
    if (-not $dism) { $dism = $script:DefaultDism }
    $callArgs = @($Arguments)
    if ($LogFile -and -not (@($callArgs | Where-Object { ([string]$_) -like '/LogPath:*' }).Count -gt 0)) {
        $callArgs += ('/LogPath:' + $LogFile)
    }
    $out = & $dism @callArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value ($out.TrimEnd()) -Encoding UTF8 } catch { }
    }
    return [pscustomobject]@{ Code = $code; Text = $out }
}

# Parses "Index : 1 / Name : ... / Architecture : x64" blocks from DISM.
function ConvertFrom-TaskImageInfo {
    param([string]$Text)
    $images = @()
    $cur = $null
    foreach ($raw in (([string]$Text) -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^Index\s*:\s*(\d+)$') {
            if ($cur) { $images += $cur }
            $cur = @{ index = [int]$Matches[1]; name = ''; description = ''; architecture = ''; size = 0 }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^Name\s*:\s*(.+)$') { $cur.name = $Matches[1].Trim() }
        elseif ($line -match '^Architecture\s*:\s*(.+)$') { $cur.architecture = $Matches[1].Trim() }
        elseif ($line -match '^Description\s*:\s*(.+)$') { $cur.description = $Matches[1].Trim() }
        elseif ($line -match '^Size\s*:\s*([\d,]+)\s*bytes') { $cur.size = [long]($Matches[1] -replace ',', '') }
    }
    if ($cur) { $images += $cur }
    return $images
}

function Get-TaskDismLevel {
    param([string]$Text)
    $build = 0
    $revision = 0
    $m = [regex]::Match([string]$Text, '(?im)^\s*Version\s*:\s*10\.0\.(\d+)')
    if ($m.Success) { $build = [int]$m.Groups[1].Value }
    $m2 = [regex]::Match([string]$Text, '(?im)^\s*ServicePack Build\s*:\s*(\d+)')
    if ($m2.Success) { $revision = [int]$m2.Groups[1].Value }
    if ($revision -eq 0) {
        $m3 = [regex]::Match([string]$Text, '(?im)^\s*Version\s*:\s*10\.0\.\d+\.(\d+)')
        if ($m3.Success) { $revision = [int]$m3.Groups[1].Value }
    }
    return @{ Build = $build; Revision = $revision }
}

function Get-TaskKb {
    param([string]$Name)
    $m = [regex]::Match([string]$Name, '(?i)kb(\d{6,8})')
    if ($m.Success) { return ('KB' + $m.Groups[1].Value) }
    return ''
}

# ---------------------------------------------------------------------------
# 1-3. mount the source ISO, copy the media, export the requested indexes
# ---------------------------------------------------------------------------

# Copy the source media to -Media and export -IndexList into sources\install.wim.
# -ReuseMedia keeps an existing copy (a resumed run), -ReuseExport keeps the
# already exported image. Both are only honoured when the caller passes -Resume.
function Invoke-WinISOMediaExport {
    param(
        [Parameter(Mandatory)][string]$SourceIso,
        [Parameter(Mandatory)][string]$Media,
        [Parameter(Mandatory)][int[]]$IndexList = @(),
        [switch]$ReuseMedia,
        [switch]$ReuseExport,
        [switch]$Force,
        [string]$LogFile = '',
        [scriptblock]$Log = $null,
        [string]$DismPath = ''
    )
    $result = [ordered]@{
        Ok        = $false
        Error     = ''
        Images    = @()
        UsedEsd   = $false
        ReusedMedia = [bool]$ReuseMedia
        ReusedExport = [bool]$ReuseExport
    }
    $isoMounted = $false
    try {
        $srcWim = Join-Path $Media 'sources\install.wim'
        if (-not $ReuseMedia -or -not (Test-Path -LiteralPath (Join-Path $Media 'sources'))) {
            Write-TaskLog -Log $Log -Message ('STAGE 1/9 mounting source ISO')
            $null = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
            $isoMounted = $true
            $letter = ''
            for ($i = 0; $i -lt 60; $i++) {
                $v = Get-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
                if ($v -and $v.DriveLetter) { $letter = [string]$v.DriveLetter; break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $letter) { throw 'The source ISO mounted but did not get a drive letter.' }
            $root = ($letter + ':\')
            Write-TaskLog -Log $Log -Message ('  mounted at ' + $root)
            if (-not (Test-Path -LiteralPath ($root + 'sources'))) { throw ('Not a Windows ISO: no sources folder at ' + $root) }

            if (Test-Path -LiteralPath $Media) {
                if (-not $Force) { throw ('Work media already exists: ' + $Media + '. Delete it, pass -Force, or pass -Resume to continue the previous run.') }
                Write-TaskLog -Log $Log -Message '  removing previous media (-Force)'
                Remove-Item -LiteralPath $Media -Recurse -Force
            }
            [void](New-Item -ItemType Directory -Path $Media -Force)

            Write-TaskLog -Log $Log -Message ('STAGE 2/9 copying media to ' + $Media)
            $rc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') `
                -ArgumentList @($root, $Media, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:2', '/MT:8') `
                -Wait -PassThru -NoNewWindow
            if ($rc.ExitCode -ge 8) { throw ('robocopy failed copying the ISO media (exit ' + $rc.ExitCode + ')') }
            Write-TaskLog -Log $Log -Message ('  media copied (robocopy exit ' + $rc.ExitCode + ')')
            Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
            $isoMounted = $false

            Get-ChildItem -LiteralPath $Media -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.IsReadOnly) { $_.IsReadOnly = $false }
            }
        }
        else {
            Write-TaskLog -Log $Log -Message ('STAGE 1-2/9 reusing the media already in ' + $Media + ' (-Resume)')
        }

        Write-TaskLog -Log $Log -Message 'STAGE 3/9 inspecting the install image'
        $srcEsd = Join-Path $Media 'sources\install.esd'
        $usingEsd = $false
        if (-not (Test-Path -LiteralPath $srcWim)) {
            if (Test-Path -LiteralPath $srcEsd) { $srcWim = $srcEsd; $usingEsd = $true; $result.UsedEsd = $true }
            else { throw 'Neither sources\install.wim nor sources\install.esd exists in the ISO media.' }
        }
        Write-TaskLog -Log $Log -Message ('  source image: ' + $srcWim)

        if ($ReuseExport -and (Test-Path -LiteralPath (Join-Path $Media 'sources\install.wim'))) {
            $finalWim = Join-Path $Media 'sources\install.wim'
            $info = Invoke-TaskDism -Arguments @('/English', '/Get-WimInfo', ('/WimFile:' + $finalWim)) -LogFile $LogFile -Log $Log -DismPath $DismPath
            if ($info.Code -ne 0) { throw ('the exported image could not be read back: ' + $info.Text.Trim()) }
            $existing = @(ConvertFrom-TaskImageInfo -Text $info.Text)
            if ($existing.Count -ne @($IndexList).Count) {
                Write-TaskLog -Log $Log -Message ('  the existing media holds ' + $existing.Count + ' index(es) but ' + @($IndexList).Count + ' were requested; re-exporting')
            }
            else {
                Write-TaskLog -Log $Log -Message ('  reusing the exported image in ' + $finalWim + ' (-Resume)')
                $mapped = @()
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    $mapped += [pscustomobject]@{
                        index        = ($i + 1)
                        source_index = @($IndexList)[$i]
                        name         = [string]$existing[$i].name
                        description  = [string]$existing[$i].description
                        architecture = [string]$existing[$i].architecture
                        size         = [long]$existing[$i].size
                    }
                }
                $result.Images = @($mapped)
                $result.Ok = $true
                return [pscustomobject]$result
            }
        }

        $info = Invoke-TaskDism -Arguments @('/English', '/Get-WimInfo', ('/WimFile:' + $srcWim)) -LogFile $LogFile -Log $Log -DismPath $DismPath
        if ($info.Code -ne 0) { throw ('DISM could not read the source image (exit ' + $info.Code + '): ' + $info.Text.Trim()) }
        $images = @(ConvertFrom-TaskImageInfo -Text $info.Text)
        Write-TaskLog -Log $Log -Message ('  indexes found: ' + $images.Count)
        foreach ($im in $images) { Write-TaskLog -Log $Log -Message ('    ' + $im.index + '  ' + $im.name) }
        foreach ($wanted in @($IndexList)) {
            $target = @($images | Where-Object { $_.index -eq $wanted })
            if ($target.Count -eq 0) { throw ('Image index ' + $wanted + ' does not exist (found ' + $images.Count + ').') }
        }

        $tmpWim = Join-Path $Media ('sources\install_export_' + [guid]::NewGuid().ToString('N') + '.wim')
        $mapped = @()
        $position = 0
        foreach ($wanted in @($IndexList)) {
            $position++
            $target = @($images | Where-Object { $_.index -eq $wanted })[0]
            Write-TaskLog -Log $Log -Message ('  exporting index ' + $wanted + ' of ' + @($IndexList).Count + ' = ' + $target.name + ' (this reads the whole image)')
            $exportArgs = @('/English', '/Export-Image', ('/SourceImageFile:' + $srcWim), ('/SourceIndex:' + $wanted), ('/DestinationImageFile:' + $tmpWim), ('/DestinationName:' + $target.name), '/Compress:max')
            $exp = Invoke-TaskDism -Arguments $exportArgs -LogFile $LogFile -Log $Log -DismPath $DismPath
            if ($exp.Code -ne 0) { throw ('Export-Image failed for index ' + $wanted + ' (exit ' + $exp.Code + '). See the DISM log for output.') }
            $mapped += [pscustomobject]@{
                index        = $position
                source_index = [int]$wanted
                name         = [string]$target.name
                description  = [string]$target.description
                architecture = [string]$target.architecture
                size         = [long]$target.size
            }
        }
        $tmpGb = [math]::Round((Get-Item -LiteralPath $tmpWim).Length / 1GB, 2)
        Write-TaskLog -Log $Log -Message ('  exported image: ' + $tmpGb + ' GB with ' + $mapped.Count + ' index(es)')

        $finalPath = Join-Path $Media 'sources\install.wim'
        if (Test-Path -LiteralPath $finalPath) { Remove-Item -LiteralPath $finalPath -Force }
        Move-Item -LiteralPath $tmpWim -Destination $finalPath -Force
        if (Test-Path -LiteralPath $srcEsd) { Remove-Item -LiteralPath $srcEsd -Force -ErrorAction SilentlyContinue }
        Write-TaskLog -Log $Log -Message '  sources\install.wim now holds only the requested index(es)'

        $result.Images = @($mapped)
        $result.Ok = $true
        return [pscustomobject]$result
    }
    catch {
        $result.Error = $_.Exception.Message
        return [pscustomobject]$result
    }
    finally {
        if ($isoMounted) { Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# 4-7. service one index
# ---------------------------------------------------------------------------

# Adds one driver INF at a time (the caller has already de-duplicated the set),
# so a single bad package cannot abort the rest.
function Add-TaskDriverSet {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [object[]]$DriverInfs = @(),
        [switch]$ForceUnsigned,
        [string]$LogFile = '',
        [scriptblock]$Log = $null,
        [string]$DismPath = ''
    )
    $stats = @{ added = 0; failed = 0; total = 0; failures = @() }
    foreach ($inf in @($DriverInfs)) {
        if (-not $inf) { continue }
        $stats.total++
        $args = @('/English', ('/Image:' + $MountDir), '/Add-Driver', ('/Driver:' + [string]$inf), '/NoRestart')
        if ($ForceUnsigned) { $args += '/ForceUnsigned' }
        $r = Invoke-TaskDism -Arguments $args -LogFile $LogFile -Log $Log -DismPath $DismPath
        if ($r.Code -eq 0) { $stats.added++ }
        else {
            $stats.failed++
            $msg = (([string]$r.Text -split "`r?`n") | Where-Object { $_ -match '(?i)error|0x[0-9a-f]{8}' } | Select-Object -First 1)
            $stats.failures += [pscustomobject]@{ inf = [string]$inf; code = $r.Code; detail = [string]$msg }
        }
    }
    return [pscustomobject]$stats
}

# Mount, service and commit one index. The image is always unmounted; a failure
# discards instead of committing so a partial image is never left behind.
function Invoke-WinISOIndexServicing {
    param(
        [Parameter(Mandatory)][string]$Wim,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$MountDir,
        [string]$EditionName = '',
        [string[]]$Packages = @(),
        [object[]]$DriverInfs = @(),
        [switch]$ForceUnsigned,
        [string[]]$Capabilities = @(),
        [string[]]$OptionalFeatures = @(),
        [string[]]$RemoveAppx = @(),
        [string]$CapabilitySource = '',
        [switch]$ScanHealth,
        [switch]$StartComponentCleanup,
        [switch]$ResetBase,
        [switch]$SkipHealth,
        [string]$LogFile = '',
        [scriptblock]$Log = $null,
        [string]$DismPath = ''
    )
    $applied = @()
    $present = @()
    $failed = @()
    $features = @()
    $levelBefore = @{ Build = 0; Revision = 0 }
    $levelAfter = @{ Build = 0; Revision = 0 }
    $committed = $false
    $mounted = $false
    try {
        Write-TaskLog -Log $Log -Message ('STAGE 4/9 mounting index ' + $ImageIndex + ' (' + $EditionName + ')')
        if (Test-Path -LiteralPath $MountDir) { Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue }
        [void](New-Item -ItemType Directory -Path $MountDir -Force)
        $mnt = Invoke-TaskDism -Arguments @('/English', '/Mount-Image', ('/ImageFile:' + $Wim), ('/Index:' + $ImageIndex), ('/MountDir:' + $MountDir)) -LogFile $LogFile -Log $Log -DismPath $DismPath
        if ($mnt.Code -ne 0) { throw ('Mount-Image failed for index ' + $ImageIndex + ' (exit ' + $mnt.Code + ').') }
        $mounted = $true
        Write-TaskLog -Log $Log -Message '  mounted'

        $before = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Get-ImageInfo') -LogFile $LogFile -Log $Log -DismPath $DismPath
        $levelBefore = Get-TaskDismLevel -Text $before.Text
        Write-TaskLog -Log $Log -Message ('  image level before servicing: ' + $levelBefore.Build + '.' + $levelBefore.Revision)

        if (-not $SkipHealth) {
            Write-TaskLog -Log $Log -Message 'STAGE 4b/9 checking the image component store health'
            $health = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Cleanup-Image', '/CheckHealth') -LogFile $LogFile -Log $Log -DismPath $DismPath
            $healthText = [string]$health.Text
            if ($health.Code -ne 0 -or $healthText -match '(?i)corrupt|not repairable') {
                throw ('The image component store is damaged: DISM /Cleanup-Image /CheckHealth reported exit ' + $health.Code + '. Repair or replace the source media before servicing.')
            }
            Write-TaskLog -Log $Log -Message '  component store reported healthy'
            if ($ScanHealth) {
                Write-TaskLog -Log $Log -Message '  scanning the component store (-ScanHealth, this takes several minutes)'
                $scan = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Cleanup-Image', '/ScanHealth') -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($scan.Code -ne 0 -or [string]$scan.Text -match '(?i)corrupt|not repairable') {
                    throw ('The image component store needs repair: DISM /Cleanup-Image /ScanHealth reported exit ' + $scan.Code + '.')
                }
                Write-TaskLog -Log $Log -Message '  scan completed without finding corruption'
            }
        }

        if (@($Packages).Count -gt 0) {
            Write-TaskLog -Log $Log -Message ('STAGE 5/9 adding ' + @($Packages).Count + ' package(s)')
            $n = 0
            foreach ($pkg in @($Packages)) {
                $n++
                $kb = Get-TaskKb -Name (Split-Path $pkg -Leaf)
                $info = $null
                $pi = Invoke-TaskDism -Arguments @('/English', '/Get-PackageInfo', ('/PackagePath:' + $pkg)) -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($pi.Code -eq 0) { $info = ConvertFrom-WinISOPackageInfoText -Text $pi.Text }
                if ($info -and (Test-WinISOPackageAlreadyInImage -Kind $info.Kind -PackageBuild $info.Build -PackageRevision $info.Revision -ImageBuild $levelBefore.Build -ImageRevision $levelBefore.Revision)) {
                    $lvl = ([string]$info.Build + '.' + [string]$info.Revision)
                    Write-TaskLog -Log $Log -Message ('  [' + $n + '/' + @($Packages).Count + '] SKIP ' + $kb + ': the image is already at ' + $levelBefore.Build + '.' + $levelBefore.Revision + ' and this package targets ' + $lvl)
                    $present += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'already-present'; level = $lvl }
                    continue
                }
                Write-TaskLog -Log $Log -Message ('  [' + $n + '/' + @($Packages).Count + '] Add-Package ' + (Split-Path $pkg -Leaf))
                $r = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Add-Package', ('/PackagePath:' + $pkg), '/NoRestart') -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($r.Code -eq 0) {
                    Write-TaskLog -Log $Log -Message '    OK'
                    $applied += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'applied' }
                }
                else {
                    $msg = (([string]$r.Text -split "`r?`n") | Where-Object { $_ -match '(?i)error|not applicable|0x[0-9a-f]{8}' } | Select-Object -First 3) -join ' | '
                    Write-TaskLog -Log $Log -Message ('    FAILED (exit ' + $r.Code + ') ' + $msg)
                    $failed += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'failed'; detail = $msg }
                }
            }
        }
        else { Write-TaskLog -Log $Log -Message 'STAGE 5/9 no packages to add' }

        $driverStats = [pscustomobject]@{ added = 0; failed = 0; total = 0; failures = @() }
        if (@($DriverInfs).Count -gt 0) {
            Write-TaskLog -Log $Log -Message ('STAGE 6/9 adding ' + @($DriverInfs).Count + ' driver package(s)')
            $driverStats = Add-TaskDriverSet -MountDir $MountDir -DriverInfs $DriverInfs -ForceUnsigned:$ForceUnsigned -LogFile $LogFile -Log $Log -DismPath $DismPath
            Write-TaskLog -Log $Log -Message ('  drivers added: ' + $driverStats.added + ', failed: ' + $driverStats.failed + ', processed: ' + $driverStats.total)
        }
        else { Write-TaskLog -Log $Log -Message 'STAGE 6/9 drivers skipped' }

        if (@($Capabilities).Count + @($OptionalFeatures).Count + @($RemoveAppx).Count -gt 0) {
            Write-TaskLog -Log $Log -Message 'STAGE 6c/9 offline features and capabilities'
            $sxs = $CapabilitySource
            if (-not $sxs) {
                $candidate = Join-Path (Split-Path -Parent $MountDir) 'Media\sources\sxs'
                if (Test-Path -LiteralPath $candidate) { $sxs = $candidate }
            }
            if ($sxs) { Write-TaskLog -Log $Log -Message ('  capability payload source: ' + $sxs) }
            foreach ($cap in @($Capabilities)) {
                if (-not $cap) { continue }
                $name = [string]$cap
                if ($name -notmatch '~') { $name = ($name + '~~~~0.0.1.0') }
                $args = @('/English', ('/Image:' + $MountDir), '/Add-Capability', ('/CapabilityName:' + $name), '/NoRestart')
                if ($sxs) { $args += ('/Source:' + $sxs) }
                $cr = Invoke-TaskDism -Arguments $args -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($cr.Code -eq 0) {
                    Write-TaskLog -Log $Log -Message ('  capability added: ' + $name)
                    $features += [pscustomobject]@{ kind = 'capability'; name = $name; result = 'added' }
                }
                else {
                    $msg = (([string]$cr.Text -split "`r?`n") | Where-Object { $_ -match '(?i)error|0x[0-9a-f]{8}' } | Select-Object -First 2) -join ' | '
                    Write-TaskLog -Log $Log -Message ('  capability FAILED: ' + $name + ' (exit ' + $cr.Code + ') ' + $msg)
                    $features += [pscustomobject]@{ kind = 'capability'; name = $name; result = 'failed'; detail = $msg }
                }
            }
            foreach ($feat in @($OptionalFeatures)) {
                if (-not $feat) { continue }
                $fr = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Enable-Feature', ('/FeatureName:' + [string]$feat), '/All', '/NoRestart') -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($fr.Code -eq 0) {
                    Write-TaskLog -Log $Log -Message ('  feature enabled: ' + $feat)
                    $features += [pscustomobject]@{ kind = 'feature'; name = [string]$feat; result = 'enabled' }
                }
                else {
                    Write-TaskLog -Log $Log -Message ('  feature FAILED: ' + $feat + ' (exit ' + $fr.Code + ')')
                    $features += [pscustomobject]@{ kind = 'feature'; name = [string]$feat; result = 'failed' }
                }
            }
            foreach ($appx in @($RemoveAppx)) {
                if (-not $appx) { continue }
                $ar = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Remove-ProvisionedAppxPackage', ('/PackageName:' + [string]$appx), '/NoRestart') -LogFile $LogFile -Log $Log -DismPath $DismPath
                if ($ar.Code -eq 0) {
                    Write-TaskLog -Log $Log -Message ('  provisioned package removed: ' + $appx)
                    $features += [pscustomobject]@{ kind = 'appx'; name = [string]$appx; result = 'removed' }
                }
                else {
                    Write-TaskLog -Log $Log -Message ('  provisioned package not removed: ' + $appx + ' (exit ' + $ar.Code + ')')
                    $features += [pscustomobject]@{ kind = 'appx'; name = [string]$appx; result = 'failed' }
                }
            }
        }

        if ($StartComponentCleanup) {
            Write-TaskLog -Log $Log -Message 'STAGE 6b/9 StartComponentCleanup (this can take a long time)'
            $cleanupArgs = @('/English', ('/Image:' + $MountDir), '/Cleanup-Image', '/StartComponentCleanup')
            if ($ResetBase) { $cleanupArgs += '/ResetBase' }
            $cu = Invoke-TaskDism -Arguments $cleanupArgs -LogFile $LogFile -Log $Log -DismPath $DismPath
            if ($cu.Code -ne 0) { Write-TaskLog -Log $Log -Message ('  cleanup returned ' + $cu.Code + '; continuing') }
        }

        Write-TaskLog -Log $Log -Message 'STAGE 7/9 committing the image'
        $un = Invoke-TaskDism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $MountDir), '/Commit') -LogFile $LogFile -Log $Log -DismPath $DismPath
        $mounted = $false
        if ($un.Code -ne 0) { throw ('Unmount/Commit failed for index ' + $ImageIndex + ' (exit ' + $un.Code + '). The image may be left mounted at ' + $MountDir + '.') }
        $committed = $true
        Write-TaskLog -Log $Log -Message '  committed'

        $after = Invoke-TaskDism -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $Wim), ('/Index:' + $ImageIndex)) -LogFile $LogFile -Log $Log -DismPath $DismPath
        $levelAfter = Get-TaskDismLevel -Text $after.Text
        Write-TaskLog -Log $Log -Message ('  image level after servicing: ' + $levelAfter.Build + '.' + $levelAfter.Revision)

        return [pscustomobject]@{
            Ok             = $true
            ImageIndex     = $ImageIndex
            Edition        = $EditionName
            LevelBefore    = $levelBefore
            LevelAfter     = $levelAfter
            Applied        = @($applied)
            AlreadyPresent = @($present)
            FailedPackages = @($failed)
            Features       = @($features)
            DriverStats    = $driverStats
            Error          = ''
        }
    }
    catch {
        if ($mounted) {
            Write-TaskLog -Log $Log -Message ('  discarding the mounted image after a failure')
            $null = Invoke-TaskDism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $MountDir), '/Discard') -LogFile $LogFile -Log $Log -DismPath $DismPath
        }
        return [pscustomobject]@{
            Ok             = $false
            ImageIndex     = $ImageIndex
            Edition        = $EditionName
            LevelBefore    = $levelBefore
            LevelAfter     = $levelAfter
            Applied        = @($applied)
            AlreadyPresent = @($present)
            FailedPackages = @($failed)
            Features       = @($features)
            DriverStats    = [pscustomobject]@{ added = 0; failed = 0; total = 0; failures = @() }
            Error          = $_.Exception.Message
            Committed      = $committed
        }
    }
}

# ---------------------------------------------------------------------------
# boot.wim (WinPE) servicing
# ---------------------------------------------------------------------------

# Adds the storage drivers and cumulative update to the WinPE index of
# sources\boot.wim, so Setup can see a VMD/RAID/NVMe disk on modern hardware.
function Invoke-WinISOBootWimServicing {
    param(
        [Parameter(Mandatory)][string]$BootWim,
        [Parameter(Mandatory)][string]$MountDir,
        [int]$ImageIndex = 2,
        [object[]]$DriverInfs = @(),
        [string[]]$Packages = @(),
        [switch]$ForceUnsigned,
        [string]$LogFile = '',
        [scriptblock]$Log = $null,
        [string]$DismPath = ''
    )
    $applied = @()
    $failed = @()
    $driverStats = [pscustomobject]@{ added = 0; failed = 0; total = 0; failures = @() }
    $mounted = $false
    try {
        Write-TaskLog -Log $Log -Message ('STAGE 6d/9 servicing ' + $BootWim + ' index ' + $ImageIndex + ' (WinPE)')
        if (Test-Path -LiteralPath $MountDir) { Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue }
        [void](New-Item -ItemType Directory -Path $MountDir -Force)
        $mnt = Invoke-TaskDism -Arguments @('/English', '/Mount-Image', ('/ImageFile:' + $BootWim), ('/Index:' + $ImageIndex), ('/MountDir:' + $MountDir)) -LogFile $LogFile -Log $Log -DismPath $DismPath
        if ($mnt.Code -ne 0) { throw ('Mount-Image failed for ' + $BootWim + ' index ' + $ImageIndex + ' (exit ' + $mnt.Code + ').') }
        $mounted = $true

        if (@($DriverInfs).Count -gt 0) {
            $driverStats = Add-TaskDriverSet -MountDir $MountDir -DriverInfs $DriverInfs -ForceUnsigned:$ForceUnsigned -LogFile $LogFile -Log $Log -DismPath $DismPath
            Write-TaskLog -Log $Log -Message ('  WinPE drivers added: ' + $driverStats.added + ', failed: ' + $driverStats.failed)
        }
        foreach ($pkg in @($Packages)) {
            if (-not $pkg) { continue }
            $kb = Get-TaskKb -Name (Split-Path $pkg -Leaf)
            $r = Invoke-TaskDism -Arguments @('/English', ('/Image:' + $MountDir), '/Add-Package', ('/PackagePath:' + $pkg), '/NoRestart') -LogFile $LogFile -Log $Log -DismPath $DismPath
            if ($r.Code -eq 0) {
                Write-TaskLog -Log $Log -Message ('  WinPE package added: ' + $kb)
                $applied += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'applied' }
            }
            else {
                Write-TaskLog -Log $Log -Message ('  WinPE package not applicable: ' + $kb + ' (exit ' + $r.Code + ')')
                $failed += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'failed'; code = $r.Code }
            }
        }

        $un = Invoke-TaskDism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $MountDir), '/Commit') -LogFile $LogFile -Log $Log -DismPath $DismPath
        $mounted = $false
        if ($un.Code -ne 0) { throw ('Unmount/Commit failed for ' + $BootWim + ' (exit ' + $un.Code + ').') }
        return [pscustomobject]@{ Ok = $true; Applied = @($applied); Failed = @($failed); DriverStats = $driverStats; Error = '' }
    }
    catch {
        if ($mounted) {
            $null = Invoke-TaskDism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $MountDir), '/Discard') -LogFile $LogFile -Log $Log -DismPath $DismPath
        }
        return [pscustomobject]@{ Ok = $false; Applied = @($applied); Failed = @($failed); DriverStats = $driverStats; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# 8. rebuild the ISO
# ---------------------------------------------------------------------------

# Builds the -bootdata argument for oscdimg. x64 media carries a BIOS and a UEFI
# loader; arm64 media has no BIOS loader, so only the UEFI entry is used.
function Get-WinISOIsoBootData {
    param(
        [string]$Architecture = 'x64',
        [string]$EtfsbootPath = '',
        [string]$EfisysPath = '',
        [switch]$EtfsbootExists,
        [switch]$EfisysExists
    )
    if ([string]$Architecture -match '(?i)arm') {
        if (-not $EfisysExists) { return [pscustomobject]@{ BootData = ''; Error = ('arm64 media needs a UEFI loader but ' + $EfisysPath + ' does not exist') } }
        return [pscustomobject]@{ BootData = ('-bootdata:1#pEF,e,b' + $EfisysPath); Error = '' }
    }
    if (-not $EtfsbootExists) { return [pscustomobject]@{ BootData = ''; Error = ('Missing BIOS boot file: ' + $EtfsbootPath) } }
    if (-not $EfisysExists) { return [pscustomobject]@{ BootData = ''; Error = ('Missing EFI boot file: ' + $EfisysPath) } }
    return [pscustomobject]@{ BootData = ('-bootdata:2#p0,e,b' + $EtfsbootPath + '#pEF,e,b' + $EfisysPath); Error = '' }
}

function New-WinISOIsoFile {
    param(
        [Parameter(Mandatory)][string]$Oscdimg,
        [Parameter(Mandatory)][string]$Media,
        [Parameter(Mandatory)][string]$OutputIso,
        [Parameter(Mandatory)][string]$BootData
    )
    if (Test-Path -LiteralPath $OutputIso) { Remove-Item -LiteralPath $OutputIso -Force }
    $osc = Start-Process -FilePath $Oscdimg `
        -ArgumentList @('-m', '-o', '-u2', '-udfver102', $BootData, $Media, $OutputIso) `
        -Wait -PassThru -NoNewWindow
    return [pscustomobject]@{
        ExitCode = $osc.ExitCode
        Ok       = ($osc.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutputIso))
    }
}

Export-ModuleMember -Function *
