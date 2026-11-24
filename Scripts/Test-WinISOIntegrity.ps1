# Test-WinISOIntegrity.ps1
# Verifies that the files the toolchain depends on are intact, before a build
# spends half an hour on DISM:
#
#   * hashes an ISO with MD5 and SHA256 in one call and compares it with the
#     ISO-SHA256.txt sidecar the build wrote earlier
#   * re-hashes every package listed in Reports\DOWNLOAD-MANIFEST.json and
#     reports the ones whose size or SHA256 no longer matches (a truncated
#     multi-gigabyte .msu otherwise fails deep inside Add-Package)
#   * validates an unattend.xml structurally (passes, components, local account)
#
# It never mounts an image, touches a disk or needs elevation.
#
# Exit codes : 0 = everything verified, 1 = a verification failed, 2 = usage or
#              self-test problem.
#
# Examples:
#   .\Test-WinISOIntegrity.ps1 -IsoPath D:\WimMount\Output\win11.iso
#   .\Test-WinISOIntegrity.ps1 -IsoPath D:\WimMount\Output\win11.iso -CopyHash
#   .\Test-WinISOIntegrity.ps1 -IsoPath D:\WimMount\Output\win11.iso -WriteSidecar
#   .\Test-WinISOIntegrity.ps1 -Updates D:\WimMount\Updates -Manifest D:\WimMount\Reports\DOWNLOAD-MANIFEST.json
#   .\Test-WinISOIntegrity.ps1 -Unattend D:\WimMount\Output\unattend.xml
#   .\Test-WinISOIntegrity.ps1 -SelfTest

[CmdletBinding()]
param(
    [string]$IsoPath = '',
    [string]$Sidecar = '',
    [string]$Updates,
    [string]$Manifest = '',
    [string]$DownloadDir = '',
    [string[]]$Algorithm = @('MD5', 'SHA256'),
    [string]$Unattend = '',
    [switch]$WriteSidecar,
    [switch]$CopyHash,
    [switch]$RequireAllPayloads,
    [switch]$Quiet,
    [switch]$SelfTest
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw ('Required module not found: ' + $modulePath) }
Import-Module -Name $modulePath -Force -ErrorAction Stop

$script:Workspace = Split-Path -Parent $PSScriptRoot
$script:Failures = 0

function Say {
    param([string]$Text)
    if (-not $Quiet) { Write-Host $Text }
}

function Fail {
    param([string]$Text)
    $script:Failures++
    Write-Host ('FAIL: ' + $Text)
}

function Invoke-SelfTest {
    $problems = @()
    $tmp = Join-Path $env:TEMP ('winiso-integrity-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        # 1. hashing: the empty file has well-known digests
        $empty = Join-Path $tmp 'empty.bin'
        [System.IO.File]::WriteAllText($empty, '')
        $h = @(Get-WinISOFileHash -Path $empty -Algorithm @('MD5', 'SHA256'))
        if ($h.Count -ne 2) { $problems += 'hashing an empty file did not return MD5 and SHA256' }
        elseif ($h[0].Hash -ne 'd41d8cd98f00b204e9800998ecf8427e') { $problems += ('MD5 of the empty file was ' + $h[0].Hash) }
        elseif ($h[1].Hash -ne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') { $problems += ('SHA256 of the empty file was ' + $h[1].Hash) }
        if (-not (Format-WinISOHashText -Hashes $h)) { $problems += 'hash text formatting returned nothing' }

        # 2. sidecar parsing
        $sidecar = Join-Path $tmp 'ISO-SHA256.txt'
        [System.IO.File]::WriteAllText($sidecar, ($h[1].Hash + '  ' + $empty))
        $entries = @(Read-WinISOHashSidecar -Path $sidecar)
        if ($entries.Count -ne 1) { $problems += 'sidecar parsing did not return one entry' }
        elseif ($entries[0].Hash -ne $h[1].Hash) { $problems += 'sidecar hash was not parsed' }
        elseif (-not (Test-WinISOHashMatch -Expected $entries[0].Hash -Actual ('SHA256: ' + $h[1].Hash))) { $problems += 'hash comparison rejected an equal digest' }
        if (Test-WinISOHashMatch -Expected $h[1].Hash -Actual $h[0].Hash) { $problems += 'hash comparison accepted two different digests' }

        # 3. manifest verification: one intact package, one wrong hash, one absent
        $good = Join-Path $tmp 'good.msu'
        $bad = Join-Path $tmp 'bad.msu'
        [System.IO.File]::WriteAllText($good, 'payload')
        [System.IO.File]::WriteAllText($bad, 'payload')
        $goodHash = (Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = Join-Path $tmp 'DOWNLOAD-MANIFEST.json'
        $doc = [ordered]@{
            generated_utc = 'x'
            files         = @(
                [ordered]@{ kb = 'KB1'; file = 'good.msu'; bytes = 7; sha256 = $goodHash },
                [ordered]@{ kb = 'KB2'; file = 'bad.msu'; bytes = 7; sha256 = ('0' * 64) },
                [ordered]@{ kb = 'KB3'; file = 'gone.msu'; bytes = 7; sha256 = $goodHash }
            )
        }
        [System.IO.File]::WriteAllText($manifest, ($doc | ConvertTo-Json -Depth 5))
        $mf = @(Get-WinISOManifestFiles -ManifestPath $manifest)
        if ($mf.Count -ne 3) { $problems += ('manifest parsing returned ' + $mf.Count + ' entries') }
        $res = Test-WinISOManifestPayload -ManifestPath $manifest -DownloadDir $tmp
        if (@($res.Ok).Count -ne 1) { $problems += ('manifest verification accepted ' + @($res.Ok).Count + ' packages, expected 1') }
        if (@($res.Mismatched).Count -ne 1) { $problems += 'manifest verification did not flag the altered package' }
        if (@($res.Missing).Count -ne 1) { $problems += 'manifest verification did not flag the absent package' }
        if (-not $res.Failed) { $problems += 'manifest verification reported success for a broken set' }

        # 4. package order: SSU, LCU, .NET
        $ordered = @(Get-WinISOPackageOrder -Packages @(
            'windows11.0-kb5127694-x64-ndp481.msu',
            'windows11.0-kb5127648-x64.msu',
            'windows11.0-kb5005-x64-ssu.msu'))
        if ($ordered.Count -ne 3) { $problems += 'package ordering dropped entries' }
        elseif ($ordered[0].Kind -ne 'ssu') { $problems += ('the servicing stack was not ordered first (got ' + $ordered[0].Kind + ')') }
        elseif ($ordered[1].Kind -ne 'lcu') { $problems += 'the cumulative update was not ordered second' }
        elseif ($ordered[2].Kind -ne 'netfx') { $problems += 'the .NET update was not ordered last' }
        $badOrder = @(Test-WinISOPackageOrder -Packages @(
            'windows11.0-kb5127648-x64.msu',
            'windows11.0-kb5005-x64-ssu.msu'))
        if ($badOrder.Count -ne 1) { $problems += 'the order guard did not flag an LCU before the SSU' }
        $goodOrder = @(Test-WinISOPackageOrder -Packages @(
            'windows11.0-kb5005-x64-ssu.msu',
            'windows11.0-kb5127648-x64.msu'))
        if ($goodOrder.Count -ne 0) { $problems += ('the order guard rejected a legal order: ' + ($goodOrder -join '; ')) }

        # 5. package info parsing and the already-applied rule
        $infoText = @'
Deployment Image Servicing and Management tool

Package information:

Package Identity : Package_for_RollupFix~31bf3856ad364e35~amd64~~22621.4317.1.11
State : Not Present
Release Type : Security Update

Applicable : Yes
'@
        $info = ConvertFrom-WinISOPackageInfoText -Text $infoText
        if ($info.Kind -ne 'lcu') { $problems += ('package kind parsing returned ' + $info.Kind) }
        if ($info.Build -ne 22621 -or $info.Revision -ne 4317) { $problems += ('package level parsing returned ' + $info.Build + '.' + $info.Revision) }
        if ($info.Applicable -ne 'Yes') { $problems += 'package applicability was not parsed' }
        if (-not (Test-WinISOPackageAlreadyInImage -Kind 'lcu' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 4400)) { $problems += 'an already-superseded LCU was not detected' }
        if (Test-WinISOPackageAlreadyInImage -Kind 'lcu' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 4000) { $problems += 'an LCU newer than the image was reported as present' }
        if (Test-WinISOPackageAlreadyInImage -Kind 'netfx' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 9999) { $problems += 'the .NET rollup must not be judged by image level' }

        # 6. unattend validation, using the real generator
        $gen = Join-Path $PSScriptRoot 'New-UnattendXml.ps1'
        $answer = Join-Path $tmp 'unattend.xml'
        & $gen -OutputPath $answer -ComputerName 'LAB01' -LocalAccountName 'labuser' -LocalAccountPassword 'ChangeMe123!' -LocalAccountAdmin | Out-Null
        $val = Test-WinUnattendDocument -Path $answer
        if (-not $val.Ok) { $problems += ('a generated answer file failed validation: ' + ($val.Problems -join '; ')) }
        if (@($val.Passes).Count -lt 3) { $problems += 'answer file validation did not find the three passes' }
        $broken = Join-Path $tmp 'broken.xml'
        [System.IO.File]::WriteAllText($broken, '<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="windowsPE"></settings></unattend>')
        $val2 = Test-WinUnattendDocument -Path $broken
        if ($val2.Ok) { $problems += 'answer file validation accepted a file with no specialize/oobeSystem passes' }
        if (-not (@($val2.Problems) -match 'specialize')) { $problems += 'answer file validation did not name the missing pass' }

        # 7. profile round-trip
        $profile = Join-Path $tmp 'BuildProfile.json'
        [void](Save-WinISOProfile -Path $profile -Values @{ edition_index = 6; drivers = 'D:\x'; run_cleanup = $true })
        $read = Read-WinISOProfile -Path $profile
        if ([int]$read['edition_index'] -ne 6) { $problems += 'profile round-trip lost edition_index' }
        if ([string]$read['drivers'] -ne 'D:\x') { $problems += 'profile round-trip lost drivers' }

        # 8. ADK guidance names a supported install route
        $guidance = Get-WinISOAdkGuidanceText
        if ($guidance -notmatch 'winget install') { $problems += 'the ADK guidance text does not mention winget' }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        foreach ($p in $problems) { Write-Host ('  - ' + $p) }
        exit 2
    }
    Write-Host 'SELFTEST OK: MD5/SHA256 hashing, sidecar parsing, manifest payload verification, package ordering and already-applied rules, unattend validation, profile round-trip, ADK guidance.'
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# ---------------------------------------------------------------------------
# ISO hash + sidecar comparison
# ---------------------------------------------------------------------------
$verifiedIso = $false
$hashObjects = @()
if ($IsoPath) {
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        Fail ('the ISO was not found: ' + $IsoPath)
    }
    else {
        $isoFull = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
        $hashObjects = @(Get-WinISOFileHash -Path $isoFull -Algorithm $Algorithm)
        Say ('ISO     : ' + $isoFull)
        Say ('Size    : ' + [math]::Round((Get-Item -LiteralPath $isoFull).Length / 1GB, 2) + ' GB')
        foreach ($h in $hashObjects) { Say ($h.Algorithm.PadRight(7) + ': ' + $h.Hash) }
        foreach ($h in $hashObjects) { Write-Host ('HASH:' + $h.Algorithm + ':' + $h.Hash) }

        $expectedPath = $Sidecar
        if (-not $expectedPath) {
            foreach ($candidate in @(
                (Join-Path (Split-Path -Parent $isoFull) 'ISO-SHA256.txt'),
                (Join-Path (Split-Path -Parent (Split-Path -Parent $isoFull)) 'ISO-SHA256.txt'))) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $expectedPath = $candidate; break }
            }
        }

        if ($WriteSidecar -and -not $Sidecar) {
            $sha = @($hashObjects | Where-Object { $_.Algorithm -eq 'SHA256' })
            if ($sha.Count -eq 0) { $sha = @($hashObjects)[0] }
            $target = Join-Path (Split-Path -Parent $isoFull) 'ISO-SHA256.txt'
            [System.IO.File]::WriteAllText($target, ([string]$sha[0].Hash + '  ' + $isoFull), (New-Object System.Text.UTF8Encoding($false)))
            Say ('Sidecar : written -> ' + $target)
            $expectedPath = $target
        }

        if ($expectedPath) {
            if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
                Fail ('the checksum file was given but does not exist: ' + $expectedPath)
            }
            else {
                Say ('Sidecar : ' + $expectedPath)
                $entries = @(Read-WinISOHashSidecar -Path $expectedPath)
                if ($entries.Count -eq 0) {
                    Fail ('no checksum could be read from ' + $expectedPath)
                }
                else {
                    foreach ($e in $entries) {
                        $actual = @($hashObjects | Where-Object { $_.Algorithm -eq $e.Algorithm })
                        if ($actual.Count -eq 0) { continue }
                        if (Test-WinISOHashMatch -Expected $e.Hash -Actual ([string]$actual[0].Hash)) {
                            Say ('MATCH   : ' + $e.Algorithm + ' ' + $e.Hash)
                        }
                        else {
                            Fail ($e.Algorithm + ' mismatch: sidecar says ' + $e.Hash + ', the file is ' + $actual[0].Hash + '. The ISO was modified or truncated after it was built.')
                        }
                    }
                    if ($script:Failures -eq 0) { $verifiedIso = $true }
                }
            }
        }
        else {
            Say 'Sidecar : none found (pass -WriteSidecar to record the current hash)'
        }
    }
}

# ---------------------------------------------------------------------------
# Update package verification
# ---------------------------------------------------------------------------
$manifestSummary = $null
if ($Updates -or $Manifest -or $DownloadDir) {
    if (-not $Manifest) { $Manifest = Join-Path $script:Workspace 'Reports\DOWNLOAD-MANIFEST.json' }
    if (-not $DownloadDir) {
        if ($Updates) { $DownloadDir = $Updates } else { $DownloadDir = Join-Path $script:Workspace 'Updates' }
    }
    Say ('Manifest: ' + $Manifest)
    Say ('Packages: ' + $DownloadDir)
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        Say 'MATCH   : no download manifest yet, so there is nothing to compare (packages may predate the manifest)'
    }
    else {
        $result = Test-WinISOManifestPayload -ManifestPath $Manifest -DownloadDir $DownloadDir -RequireAll:$RequireAllPayloads
        Say ('Checked : ' + $result.Checked + ' manifest entr(ies), ' + @($result.Ok).Count + ' intact')
        foreach ($m in @($result.Mismatched)) {
            Fail ($m.File + ': ' + $m.Reason + ' (manifest ' + $m.Expected + ', file ' + $m.Actual + ')')
        }
        foreach ($m in @($result.Missing)) {
            $line = ($m.File + ': listed in the manifest but not present in ' + $DownloadDir)
            if ($RequireAllPayloads) { Fail $line } else { Say ('SKIP    : ' + $line) }
        }
        $manifestSummary = $result
    }
}

# ---------------------------------------------------------------------------
# unattend.xml validation
# ---------------------------------------------------------------------------
if ($Unattend) {
    Say ('Unattend: ' + $Unattend)
    $doc = Test-WinUnattendDocument -Path $Unattend
    if ($doc.Ok) {
        Say ('MATCH   : answer file is structurally valid (' + (@($doc.Passes) -join ', ') + ')')
    }
    else {
        foreach ($p in @($doc.Problems)) { Fail ('unattend: ' + $p) }
    }
}

if ($CopyHash -and $hashObjects.Count -gt 0) {
    $text = Format-WinISOHashText -Hashes $hashObjects -IncludePath
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Clipboard]::SetText($text)
        Say 'Copied  : the hashes are on the clipboard'
    }
    catch {
        Say ('Copied  : failed to reach the clipboard (' + $_.Exception.Message + ')')
    }
}

if (-not $IsoPath -and -not $Updates -and -not $Manifest -and -not $Unattend -and -not $DownloadDir) {
    Say 'Nothing to verify: pass -IsoPath, -Updates/-Manifest, or -Unattend. Use -SelfTest to exercise the rules.'
}

if ($script:Failures -gt 0) {
    Write-Host ('INTEGRITY FAILED: ' + $script:Failures + ' check(s) failed.')
    exit 1
}
if ($verifiedIso) { Write-Host 'INTEGRITY OK: the ISO matches its recorded SHA256.' }
else { Write-Host 'INTEGRITY OK: every check that could run passed.' }
exit 0
