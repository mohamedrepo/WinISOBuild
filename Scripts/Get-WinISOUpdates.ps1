# Get-WinISOUpdates.ps1
# Finds the Microsoft updates that apply to a given Windows build/architecture
# (Servicing Stack, latest Cumulative Update, .NET cumulative update, Safe OS
# and Setup dynamic updates) and can download them (.msu) into the workspace
# Updates folder. Reuses the catalog search helper in WinISOService.psm1.
#
# It can also report ONLY the updates the target image is MISSING: it reads the
# image's installed cumulative-update level and marks each candidate as
# MISSED (newer than the image) or ALREADY-PRESENT.
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only.
#
# Examples:
#   .\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso -ListOnly -MissedOnly
#   .\Get-WinISOUpdates.ps1 -Build 26200 -Architecture x64 -MissedOnly
#   .\Get-WinISOUpdates.ps1 -Build 26200 -ImageRevision 9457 -ListOnly
#   .\Get-WinISOUpdates.ps1 -Build 26300 -Kb KB5127648,KB5127694
#   .\Get-WinISOUpdates.ps1 -SelfTest

[CmdletBinding()]
param(
    [int]$Build = 0,
    [string]$Architecture = 'x64',
    [string]$Workspace = 'D:\WimMount',
    [string]$OutDir = '',
    [string]$Iso = '',
    [int]$ImageBuild = 0,
    [int]$ImageRevision = 0,
    [string[]]$Kb = @(),
    [ValidateSet('SSU', 'LatestCU', 'DotNetCU', 'SafeOS', 'SetupDU')]
    [string[]]$Kinds = @('SSU', 'LatestCU', 'DotNetCU', 'SafeOS', 'SetupDU'),
    [switch]$MissedOnly,
    [switch]$IncludeOptional,
    [switch]$ListOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:ModulePath = Join-Path $PSScriptRoot 'WinISOService.psm1'
$script:DownloadDialog = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
# The catalog identifies the tool by its release version; VERSION is the source.
$script:AppVersion = '0.0.0-unknown'
$script:VersionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
if (Test-Path -LiteralPath $script:VersionPath -PathType Leaf) {
    $versionText = ([string](Get-Content -LiteralPath $script:VersionPath -TotalCount 1 -ErrorAction SilentlyContinue)).Trim()
    if ($versionText) { $script:AppVersion = $versionText }
}
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinISOBuild/' + $script:AppVersion

# The catalog search page publishes a rounded size ("512.3 MB"). The download
# dialog for the same update also publishes each file's base64 SHA1 ("digest")
# and base64 SHA256, which is what a download is verified against. The rounded
# size is kept as a secondary check because it is the only value in the results.
function ConvertFrom-CatalogSize {
    param([string]$Text)
    $t = [string]$Text
    if (-not $t) { return [long]0 }
    $m = [regex]::Match($t, '([0-9]+(?:[.,][0-9]+)?)\s*(bytes|B|KB|MB|GB)')
    if (-not $m.Success) { return [long]0 }
    $value = [double](($m.Groups[1].Value) -replace ',', '.')
    switch ($m.Groups[2].Value.ToUpperInvariant()) {
        'BYTES' { return [long]$value }
        'B' { return [long]$value }
        'KB' { return [long]($value * 1KB) }
        'MB' { return [long]($value * 1MB) }
        'GB' { return [long]($value * 1GB) }
    }
    return [long]0
}

function Test-WinISOCatalogSize {
    param([string]$Text, [long]$Bytes)
    $catalog = ConvertFrom-CatalogSize -Text $Text
    $ok = $true
    $detail = ''
    if ($catalog -gt 0 -and $Bytes -gt 0) {
        # The catalog rounds to one decimal, so allow 2% plus a megabyte.
        $tolerance = [math]::Max([double](1MB), ($catalog * 0.02))
        $delta = [math]::Abs([double]$catalog - [double]$Bytes)
        if ($delta -gt $tolerance) {
            $ok = $false
            $detail = ('the catalog lists ' + $Text + ' (' + $catalog + ' bytes) but the file is ' + $Bytes + ' bytes')
        }
    }
    return [pscustomobject]@{ CatalogBytes = $catalog; Ok = $ok; Detail = $detail }
}

# The download dialog publishes a base64 digest per file. Converting it to the
# hex form Get-FileHash prints is what makes the published hash comparable.
# A digest of the wrong length for the algorithm is rejected, not compared.
function ConvertFrom-CatalogDigest {
    param([string]$Base64 = '', [int]$ExpectedBytes = 0)
    $t = ([string]$Base64).Trim()
    if (-not $t) { return '' }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($t) } catch { return '' }
    if ($null -eq $bytes) { return '' }
    if ($ExpectedBytes -gt 0 -and $bytes.Length -ne $ExpectedBytes) { return '' }
    return ((@($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Compares a downloaded file with the digests the catalog published for it. With
# no published digest there is nothing to compare, so the check passes and says
# so instead of pretending the file was verified.
function Test-WinISOFileDigest {
    param([string]$Path = '', [string]$ExpectedSha1 = '', [string]$ExpectedSha256 = '')
    $wantSha1 = ([string]$ExpectedSha1).Trim().ToLowerInvariant()
    $wantSha256 = ([string]$ExpectedSha256).Trim().ToLowerInvariant()
    if ($wantSha1 -notmatch '^[0-9a-f]{40}$') { $wantSha1 = '' }
    if ($wantSha256 -notmatch '^[0-9a-f]{64}$') { $wantSha256 = '' }
    $result = [ordered]@{
        Ok       = $true
        Checked  = @()
        Sha1     = ''
        Sha256   = ''
        Detail   = 'the catalog published no digest for this file'
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Ok = $false
        $result.Detail = ('file not found: ' + $Path)
        return [pscustomobject]$result
    }
    $result.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($wantSha1) { $result.Sha1 = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant() }
    $problems = @()
    if ($wantSha256) {
        $result.Checked += 'SHA256'
        if ($result.Sha256 -ne $wantSha256) { $problems += ('SHA256 is ' + $result.Sha256 + ' but the catalog published ' + $wantSha256) }
    }
    if ($wantSha1) {
        $result.Checked += 'SHA1'
        if ($result.Sha1 -ne $wantSha1) { $problems += ('SHA1 is ' + $result.Sha1 + ' but the catalog published ' + $wantSha1) }
    }
    if ($problems.Count -gt 0) {
        $result.Ok = $false
        $result.Detail = ($problems -join '; ')
    }
    elseif ($result.Checked.Count -gt 0) {
        $result.Detail = ('matches the catalog ' + ($result.Checked -join ' and '))
    }
    return [pscustomobject]$result
}
$script:Dism = "$env:SystemRoot\System32\Dism.exe"

# Build -> marketing version hints. Hint only.
$script:VersionHints = @(
    @{ Build = 28000; Version = '26H1' }, @{ Build = 26300; Version = '26H2' },
    @{ Build = 26200; Version = '25H2' }, @{ Build = 26100; Version = '24H2' },
    @{ Build = 22631; Version = '23H2' }, @{ Build = 22621; Version = '22H2' },
    @{ Build = 22000; Version = '21H2' },
    @{ Build = 19045; Version = '22H2' }, @{ Build = 19044; Version = '21H2' },
    @{ Build = 19041; Version = '2004' }, @{ Build = 18363; Version = '1909' },
    @{ Build = 14393; Version = '1607' }, @{ Build = 10240; Version = '1507' }
)

function Get-WinISOProductFromBuild { param([int]$B)
    if ($B -ge 22000) { return 'Windows 11' }
    if ($B -ge 10240) { return 'Windows 10' }
    return ''
}
function Get-WinISOVersionFromBuild { param([int]$B)
    foreach ($h in $script:VersionHints) { if ($B -eq $h.Build) { return [string]$h.Version } }
    return ''
}
function New-WinISOCatalogSearchUrl { param([string]$Query)
    return ('https://www.catalog.update.microsoft.com/Search.aspx?q=' + [System.Uri]::EscapeDataString($Query))
}
function New-WinISODownloadDialogBody { param([string]$Guid)
    return ('updateIDs=[{"size":0,"updateID":"' + $Guid + '","uidInfo":"' + $Guid + '"}]')
}

# "KB5129195 (26200.9457)" -> @{ Build = 26200; Revision = 9457 }
function Get-WinISOTargetLevel {
    param([string]$Title)
    $m = [regex]::Match([string]$Title, '\((\d{5,6})\.(\d{1,6})\)')
    if ($m.Success) { return @{ Build = [int]$m.Groups[1].Value; Revision = [int]$m.Groups[2].Value } }
    return @{ Build = 0; Revision = 0 }
}

# Classify a catalog row by its title, so a package is not mislabelled just
# because a broader catalog query happened to match it first.
function Get-WinISOKindFromTitle {
    param([string]$Title, [string]$Fallback = '')
    $t = [string]$Title
    if (-not $t) { return $Fallback }
    if ($t -match '(?i)servicing stack') { return 'SSU' }
    if ($t -match '(?i)safe ?os dynamic') { return 'SafeOS' }
    if ($t -match '(?i)setup dynamic') { return 'SetupDU' }
    if ($t -match '(?i)\.net framework') { return 'DotNetCU' }
    if ($t -match '(?i)cumulative update') { return 'LatestCU' }
    return $Fallback
}

# Classify a candidate against the image level.
function Get-WinISOMissedState {
    param([string]$Title, [int]$ImageBuild, [int]$ImageRevision)
    $t = Get-WinISOTargetLevel -Title $Title
    if ($t.Build -eq 0) { return 'unknown' }
    if ($ImageBuild -le 0) { return 'unknown' }
    if ($t.Build -gt $ImageBuild) { return 'missed' }
    if ($t.Build -lt $ImageBuild) { return 'already-present' }
    if ($t.Revision -gt $ImageRevision) { return 'missed' }
    return 'already-present'
}

# Rows are kept only when they really target the requested build. The catalog
# returns one row per (KB, version, architecture) and a search for a KB also
# reloads rows for sibling builds, so filtering on the marketing version alone
# is not enough: the (build.revision) suffix in the title is authoritative.
function Select-WinISOApplicable {
    param([object[]]$Rows, [string]$Version, [string]$Architecture, [int]$Build = 0, [switch]$IncludeOptional)
    $out = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
    foreach ($r in @($Rows)) {
        $title = [string]$r.Title
        $tv = ''
        $m = [regex]::Match($title, '(?i)version\s+(\d{2}H\d)')
        if ($m.Success) { $tv = $m.Groups[1].Value.ToUpper() }
        $ta = ''
        if ($title -match '(?i)\bx64\b') { $ta = 'x64' }
        elseif ($title -match '(?i)\barm64\b') { $ta = 'arm64' }
        elseif ($title -match '(?i)\bx86\b') { $ta = 'x86' }
        $ok = $true
        if (-not $IncludeOptional -and $title -match '(?i)\bpreview\b') { $ok = $false }
        if ($Version -and $tv -and $tv -ne $Version.ToUpper()) { $ok = $false }
        if ($Architecture -and $ta -and $ta -ne $Architecture) { $ok = $false }
        if ($Build -gt 0) {
            $lvl = Get-WinISOTargetLevel -Title $title
            if ($lvl.Build -gt 0 -and $lvl.Build -ne $Build) { $ok = $false }
        }
        if ($ok) { $out.Add($r) }
    }
    return ,$out
}

# The dialog writes one JavaScript object per file: url, digest (base64 SHA1),
# sha256 (base64) and fileName. Reading them together keeps each hash with the
# file it belongs to, even when one update offers several packages.
function ConvertFrom-WinISODownloadDialogHtml {
    param([string]$Html = '')
    $text = [string]$Html
    $records = @()
    if (-not $text) { return @() }
    $pattern = "files\[(?<i>\d+)\]\.url = '(?<url>[^']+)';[\s\S]{0,300}?files\[\k<i>\]\.digest = '(?<digest>[^']*)';[\s\S]{0,300}?files\[\k<i>\]\.sha256 = '(?<sha256>[^']*)';[\s\S]{0,600}?files\[\k<i>\]\.fileName = '(?<fileName>[^']+)';"
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $url = [System.Net.WebUtility]::HtmlDecode($m.Groups['url'].Value)
        if ($url -notmatch '(?i)\.msu$') { continue }
        $records += [pscustomobject]@{
            Url      = $url
            FileName = [System.Net.WebUtility]::HtmlDecode($m.Groups['fileName'].Value)
            Sha1     = ConvertFrom-CatalogDigest -Base64 $m.Groups['digest'].Value -ExpectedBytes 20
            Sha256   = ConvertFrom-CatalogDigest -Base64 $m.Groups['sha256'].Value -ExpectedBytes 32
        }
    }
    if ($records.Count -eq 0) {
        # A dialog without digest fields still names the files; the download then
        # falls back to the rounded-size check.
        $seen = @{}
        foreach ($m in [regex]::Matches($text, 'https?://[^\s"'']+\.msu')) {
            $url = $m.Value
            if ($seen.ContainsKey($url)) { continue }
            $seen[$url] = $true
            $records += [pscustomobject]@{ Url = $url; FileName = ($url.Split('/'))[-1]; Sha1 = ''; Sha256 = '' }
        }
    }
    # Returned flat: a nested array makes "$record.Url" fail under StrictMode.
    return @($records)
}

function Get-WinISODownloadFiles {
    param([string]$Guid)
    $body = New-WinISODownloadDialogBody -Guid $Guid
    $resp = Invoke-WebRequest -Uri $script:DownloadDialog -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -UserAgent $script:UserAgent -TimeoutSec 120
    return @(ConvertFrom-WinISODownloadDialogHtml -Html ([string]$resp.Content))
}

function Get-WinISODownloadUrls {
    param([string]$Guid)
    return @(Get-WinISODownloadFiles -Guid $Guid | ForEach-Object { [string]$_.Url })
}

function Get-WinISOIsoDriveLetter {
    param([string]$IsoPath, [int]$TimeoutSeconds = 60)
    $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    for ($i = 0; $i -lt ($TimeoutSeconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $now = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
        $new = @($now | Where-Object { $before -notcontains $_ })
        foreach ($l in $new) { if (Test-Path -LiteralPath ("${l}:\sources\install.wim")) { return $l } }
    }
    return ''
}

# Detect the image's current build/revision from an ISO (or its inventory).
function Get-WinISOImageLevel {
    param([string]$IsoPath, [string]$Workspace)
    $res = @{ Build = 0; Revision = 0; Source = '' }
    if ($IsoPath -and (Test-Path -LiteralPath $IsoPath)) {
        $letter = ''
        try { $letter = Get-WinISOIsoDriveLetter -IsoPath $IsoPath } catch { $letter = '' }
        if ($letter) {
            $wim = ("${letter}:\sources\install.wim")
            if (-not (Test-Path -LiteralPath $wim)) { $wim = ("${letter}:\sources\install.esd") }
            try {
                Write-Host ('  reading image level (fast) from ' + $wim)
                $gi = & $script:Dism /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
                $gmV = [regex]::Match($gi, '(?im)^\s*Version\s+:\s*10\.0\.(\d+)')
                if ($gmV.Success) { $res.Build = [int]$gmV.Groups[1].Value }
                $gmR = [regex]::Match($gi, '(?im)^\s*ServicePack Build\s+:\s*(\d+)')
                if ($gmR.Success) { $res.Revision = [int]$gmR.Groups[1].Value }
                if ($res.Build -gt 0) { $res.Source = 'image /Get-ImageInfo' }
            }
            finally {
                Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    if ($res.Build -eq 0) {
        $inv = Join-Path ([System.IO.Path]::GetFullPath($Workspace)) 'Reports\ISO-INVENTORY.json'
        if (Test-Path -LiteralPath $inv) {
            try {
                $j = Get-Content -LiteralPath $inv -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.detected.build) { $res.Build = [int]$j.detected.build }
                if ($j.detected.revision) { $res.Revision = [int]$j.detected.revision }
                $res.Source = 'inventory'
            }
            catch { }
        }
    }
    return $res
}

function Invoke-WinISOUpdateSelfTest {
    $problems = @()
    if (-not (Test-Path -LiteralPath $script:ModulePath)) { $problems += ('module not found: ' + $script:ModulePath) }
    if ((Get-WinISOVersionFromBuild 26300) -ne '26H2') { $problems += 'version map failed for 26300 (26H2)' }
    if ((Get-WinISOVersionFromBuild 28000) -ne '26H1') { $problems += 'version map failed for 28000 (26H1)' }
    if ((Get-WinISOProductFromBuild 26100) -ne 'Windows 11') { $problems += 'product map failed for 26100' }
    if ((Get-WinISOVersionFromBuild 26200) -ne '25H2') { $problems += 'version map failed for 26200' }
    $u = New-WinISOCatalogSearchUrl -Query 'Windows 11 Cumulative Update'
    if ($u -notmatch '^https://www\.catalog\.update\.microsoft\.com/Search\.aspx\?q=') { $problems += 'search URL construction failed' }
    if ($u -notmatch 'Cumulative%20Update') { $problems += 'search URL did not encode spaces' }
    $b = New-WinISODownloadDialogBody -Guid '00000000-0000-0000-0000-000000000000'
    if ($b -notmatch 'updateIDs=\[\{"size":0,"updateID":"00000000-0000-0000-0000-000000000000","uidInfo":') { $problems += 'download body construction failed' }

    $tl = Get-WinISOTargetLevel -Title '2026-09 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5129195) (26200.9457)'
    if ($tl.Build -ne 26200 -or $tl.Revision -ne 9457) { $problems += 'target level parse failed' }
    if ((Get-WinISOMissedState -Title '... (KB1) (26200.9457)' -ImageBuild 26200 -ImageRevision 9457) -ne 'already-present') { $problems += 'missed-state should be already-present at equal level' }
    if ((Get-WinISOMissedState -Title '... (KB2) (26200.9550)' -ImageBuild 26200 -ImageRevision 9457) -ne 'missed') { $problems += 'missed-state should be missed for newer revision' }
    if ((Get-WinISOMissedState -Title '... (KB3) (26200.8037)' -ImageBuild 26200 -ImageRevision 9457) -ne 'already-present') { $problems += 'missed-state should be already-present for older revision' }
    if ((Get-WinISOMissedState -Title 'no build here' -ImageBuild 26200 -ImageRevision 9457) -ne 'unknown') { $problems += 'missed-state should be unknown without a build' }
    if ((Get-WinISOKindFromTitle -Title '2026-10 Setup Dynamic Update for Windows 11' -Fallback 'LatestCU') -ne 'SetupDU') { $problems += 'title kind should detect a setup dynamic update' }
    if ((Get-WinISOKindFromTitle -Title '2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1' -Fallback 'LatestCU') -ne 'DotNetCU') { $problems += 'title kind should detect a .NET cumulative update' }
    if ((Get-WinISOKindFromTitle -Title '2026-10 Safe OS Dynamic Update for Windows 11' -Fallback 'LatestCU') -ne 'SafeOS') { $problems += 'title kind should detect a safe OS dynamic update' }
    if ((Get-WinISOKindFromTitle -Title '2026-10 Cumulative Update for Windows 11' -Fallback 'SetupDU') -ne 'LatestCU') { $problems += 'title kind should detect a cumulative update' }
    if ((Get-WinISOKindFromTitle -Title 'mystery package' -Fallback 'SSU') -ne 'SSU') { $problems += 'title kind should fall back to the query kind' }

    $sel = Select-WinISOApplicable -Rows @(
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB1)' },
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for Windows 11, version 26H1 for x64-based Systems (KB2)' },
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for .NET Framework for Windows 11, version 25H2 for arm64 (KB3)' }
    ) -Version '25H2' -Architecture 'x64'
    if (@($sel).Count -ne 1) { $problems += ('applicability filter expected 1 row, got ' + @($sel).Count) }

    # Build filter: sibling-build rows for the same KB must be dropped even when
    # the marketing version is identical (the catalog repeats a KB per build).
    $selB = Select-WinISOApplicable -Rows @(
        [pscustomobject]@{ Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB1) (26300.9711)' },
        [pscustomobject]@{ Title = '2026-10 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB1) (26100.9711)' },
        [pscustomobject]@{ Title = '2026-10 Cumulative Update for .NET Framework for Windows 11, version 26H2 for x64 (KB9)' }
    ) -Version '26H2' -Architecture 'x64' -Build 26300
    if (@($selB).Count -ne 2) { $problems += ('build filter expected 2 rows, got ' + @($selB).Count) }

    # Catalog size cross-check: parse the published size and judge the file.
    if ((ConvertFrom-CatalogSize -Text '512.3 MB') -ne [long](512.3 * 1MB)) { $problems += 'catalog size parse failed for MB' }
    if ((ConvertFrom-CatalogSize -Text '1.5 GB') -ne [long](1.5 * 1GB)) { $problems += 'catalog size parse failed for GB' }
    if ((ConvertFrom-CatalogSize -Text 'no size here') -ne 0) { $problems += 'catalog size parse should return 0 without a unit' }
    $same = Test-WinISOCatalogSize -Text '10.0 MB' -Bytes ([long](10.0 * 1MB))
    if (-not $same.Ok) { $problems += 'catalog size check rejected a matching file' }
    $short = Test-WinISOCatalogSize -Text '10.0 MB' -Bytes ([long](4 * 1MB))
    if ($short.Ok) { $problems += 'catalog size check accepted a file far smaller than published' }

    # Catalog digest cross-check: base64 -> hex, a real file comparison, and the
    # download-dialog parser that keeps each hash with its file.
    if ((ConvertFrom-CatalogDigest -Base64 'qED0j4Hnn0UTESj5+CNjOln1eHk=' -ExpectedBytes 20) -ne 'a840f48f81e79f45131128f9f823633a59f57879') { $problems += 'base64 SHA1 digest conversion failed' }
    if ((ConvertFrom-CatalogDigest -Base64 'qED0j4Hnn0UTESj5+CNjOln1eHk=' -ExpectedBytes 32) -ne '') { $problems += 'a digest of the wrong length was accepted' }
    if ((ConvertFrom-CatalogDigest -Base64 'not base64 !!') -ne '') { $problems += 'invalid base64 digest was accepted' }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('winiso-digest-' + [guid]::NewGuid().ToString('N') + '.bin')
    try {
        [System.IO.File]::WriteAllText($probe, 'catalog digest self test')
        $probeSha1 = (Get-FileHash -LiteralPath $probe -Algorithm SHA1).Hash.ToLowerInvariant()
        $probeSha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()
        $known = Test-WinISOFileDigest -Path $probe -ExpectedSha1 $probeSha1 -ExpectedSha256 $probeSha256
        if (-not $known.Ok) { $problems += ('digest check rejected a matching file: ' + $known.Detail) }
        if (@($known.Checked) -notcontains 'SHA1' -or @($known.Checked) -notcontains 'SHA256') { $problems += 'digest check did not report both algorithms' }
        $wrong = Test-WinISOFileDigest -Path $probe -ExpectedSha256 (('0' * 64) -join '')
        if ($wrong.Ok) { $problems += 'digest check accepted a wrong SHA256' }
        $none = Test-WinISOFileDigest -Path $probe
        if (-not $none.Ok -or @($none.Checked).Count -ne 0) { $problems += 'digest check should pass without a published digest' }
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }

    $dialog = @'
downloadInformation[0] = new Object();
downloadInformation[0].files = new Array();
downloadInformation[0].files[0] = new Object();
downloadInformation[0].files[0].url = 'https://catalog.example/files/windows11.0-kb1-x64_abc.msu';
downloadInformation[0].files[0].digest = 'qED0j4Hnn0UTESj5+CNjOln1eHk=';
downloadInformation[0].files[0].sha256 = 'USYH7IgD8wXw1aHcLzNSfWrDVsyRqg3BcUA8Ct7Ma8w=';
downloadInformation[0].files[0].architectures = '';
downloadInformation[0].files[0].languages = '';
downloadInformation[0].files[0].longLanguages = '';
downloadInformation[0].files[0].fileName = 'windows11.0-kb1-x64_abc.msu';
downloadInformation[0].files[1] = new Object();
downloadInformation[0].files[1].url = 'https://catalog.example/files/other.cab';
downloadInformation[0].files[1].digest = '';
downloadInformation[0].files[1].sha256 = '';
downloadInformation[0].files[1].fileName = 'other.cab';
'@
    $parsed = @(ConvertFrom-WinISODownloadDialogHtml -Html $dialog)
    if ($parsed.Count -ne 1) { $problems += ('dialog parser expected 1 .msu record, got ' + $parsed.Count) }
    elseif ($parsed[0] -is [array]) { $problems += 'dialog parser returned a nested array, so the Url lookup would fail' }
    elseif (-not $parsed[0].PSObject.Properties['Url']) { $problems += 'dialog parser record has no Url property' }
    elseif ($parsed[0].FileName -ne 'windows11.0-kb1-x64_abc.msu') { $problems += 'dialog parser lost the file name' }
    elseif ($parsed[0].Sha1 -ne 'a840f48f81e79f45131128f9f823633a59f57879') { $problems += 'dialog parser lost the SHA1 digest' }
    elseif ([string]$parsed[0].Sha256 -notmatch '^[0-9a-f]{64}$') { $problems += 'dialog parser lost the SHA256 digest' }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        $problems | ForEach-Object { Write-Host ('  - ' + $_) }
        exit 2
    }
    Write-Host 'SELFTEST OK: module found; build/version maps; search URL + download body; target-level parse; missed-state classification; applicability filter; catalog size cross-check; catalog SHA1/SHA256 digest cross-check and download-dialog parsing.'
    exit 0
}

if ($SelfTest) { Invoke-WinISOUpdateSelfTest }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Import-Module -Name $script:ModulePath -Force -ErrorAction Stop

$fullWs = [System.IO.Path]::GetFullPath($Workspace)
if (-not $OutDir) { $OutDir = Join-Path $fullWs 'Updates' }
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

if ($Build -eq 0 -and $Iso) {
    Write-Host ('Detecting build/architecture from ISO: ' + $Iso)
    $det = Get-WinISOImageLevel -IsoPath $Iso -Workspace $fullWs
    if ($det.Build -gt 0) { $Build = $det.Build }
}
if ($Build -eq 0) {
    $inv = Join-Path $fullWs 'Reports\ISO-INVENTORY.json'
    if (Test-Path -LiteralPath $inv) {
        try { $j = Get-Content -LiteralPath $inv -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.detected.build) { $Build = [int]$j.detected.build }; if ($j.detected.architecture) { $Architecture = [string]$j.detected.architecture } } catch { }
    }
}
if ($Build -eq 0) { throw 'Build number unknown. Pass -Build or -Iso (or run the toolchain inventory first).' }

$product = Get-WinISOProductFromBuild -B $Build
$version = Get-WinISOVersionFromBuild -B $Build
if (-not $product) { throw ('Unsupported build ' + $Build) }

# Image current level (for missed-only classification).
$imgLevel = @{ Build = $ImageBuild; Revision = $ImageRevision; Source = 'parameter' }
if ($imgLevel.Build -eq 0) {
    $det = Get-WinISOImageLevel -IsoPath $Iso -Workspace $fullWs
    if ($det.Build -gt 0 -and $det.Build -eq $Build) { $imgLevel = $det }
    elseif ($det.Build -gt 0) {
        # A stale inventory from a *different* ISO must not decide whether a
        # package is missed: it silently inverted the whole classification.
        Write-Host ('Ignoring recorded image level ' + $det.Build + '.' + $det.Revision + ' (' + $det.Source + '): not build ' + $Build + '.')
    }
}
if ($imgLevel.Build -eq 0) { $imgLevel = @{ Build = $Build; Revision = 0; Source = 'assumed equal build, unknown revision' } }

Write-Host ('Target : ' + $product + ' build ' + $Build + ' (' + $version + ') ' + $Architecture)
Write-Host ('Image  : build ' + $imgLevel.Build + '.' + $imgLevel.Revision + '  (source: ' + $imgLevel.Source + ')')
if ($MissedOnly) { Write-Host 'Mode   : MISSED ONLY' }
if ($ListOnly) { Write-Host 'Mode   : LIST ONLY (no download)' }

$queryPlan = @()
if ($Kinds -contains 'SSU')      { $queryPlan += [pscustomobject]@{ Kind = 'SSU';      Query = 'Servicing Stack Update "' + $product + '"' } }
if ($Kinds -contains 'LatestCU') { $queryPlan += [pscustomobject]@{ Kind = 'LatestCU'; Query = '"' + $product + '" Cumulative Update for ' + $Architecture } }
if ($Kinds -contains 'DotNetCU') { $queryPlan += [pscustomobject]@{ Kind = 'DotNetCU'; Query = '.NET Framework Cumulative Update "' + $product + '"' } }
if ($Kinds -contains 'SafeOS')   { $queryPlan += [pscustomobject]@{ Kind = 'SafeOS';   Query = 'Safe OS Dynamic Update "' + $product + '"' } }
if ($Kinds -contains 'SetupDU')  { $queryPlan += [pscustomobject]@{ Kind = 'SetupDU';  Query = 'Setup Dynamic Update "' + $product + '"' } }

$all = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
foreach ($q in $queryPlan) {
    Write-Host ('Searching catalog: [' + $q.Kind + '] ' + $q.Query)
    $res = Get-WinISOCatalogSearch -Query $q.Query -MaxResults 30
    if (-not $res.Ok) { Write-Host ('  catalog query failed: ' + $res.Error); continue }
    $rows = @($res.Rows)
    Write-Host ('  rows: ' + $rows.Count)
    $applicable = Select-WinISOApplicable -Rows $rows -Version $version -Architecture $Architecture -Build $Build -IncludeOptional:$IncludeOptional
    foreach ($r in @($applicable)) {
        # The catalog queries overlap (a cumulative-update search also returns
        # setup/safe-OS rows). Classify from the package title and keep the
        # first classification for a KB that matches several queries.
        $titleKind = Get-WinISOKindFromTitle -Title ([string]$r.Title) -Fallback $q.Kind
        $existing = $r.PSObject.Properties['Kind']
        if (-not $existing -or -not [string]$existing.Value) {
            $r | Add-Member -NotePropertyName 'Kind' -NotePropertyValue $titleKind -Force
        }
        $all.Add($r)
    }
}

# Deduplicate on the catalog update id, not the KB number: one KB has a
# separate row (and GUID) per Windows version and architecture.
$byKey = @{}
foreach ($r in $all) {
    $key = [string]$r.UpdateGuid
    if (-not $key) { $key = [string]$r.Kb + '|' + [string]$r.Title }
    if ($key -and -not $byKey.ContainsKey($key)) { $byKey[$key] = $r }
}
$candidates = @($byKey.Values | Sort-Object { [string]$_.Kb })
if (@($Kb).Count -gt 0) {
    $wanted = @($Kb | ForEach-Object { ([string]$_).ToUpper() })
    $candidates = @($candidates | Where-Object { $wanted -contains ([string]$_.Kb).ToUpper() })
    Write-Host ('KB filter: ' + ($wanted -join ', ') + ' -> ' + $candidates.Count + ' row(s)')
}

foreach ($c in $candidates) {
    $c | Add-Member -NotePropertyName 'MissedState' -NotePropertyValue (Get-WinISOMissedState -Title ([string]$c.Title) -ImageBuild $imgLevel.Build -ImageRevision $imgLevel.Revision) -Force
    $c | Add-Member -NotePropertyName 'Optional' -NotePropertyValue ([bool]([string]$c.Title -match '(?i)\bpreview\b|\boptional\b')) -Force
}

$missed = @($candidates | Where-Object { $_.MissedState -eq 'missed' })
$present = @($candidates | Where-Object { $_.MissedState -eq 'already-present' })
$unknown = @($candidates | Where-Object { $_.MissedState -eq 'unknown' })

Write-Host ''
Write-Host ('Applicable updates (' + $candidates.Count + '): ' + $missed.Count + ' missed, ' + $present.Count + ' already-present, ' + $unknown.Count + ' unknown build')
foreach ($c in $candidates) {
    $tag = '[UNKNOWN]'
    if ($c.MissedState -eq 'missed') { $tag = '[MISSED]' }
    elseif ($c.MissedState -eq 'already-present') { $tag = '[PRESENT]' }
    $opt = ''; if ($c.Optional) { $opt = ' (optional)' }
    Write-Host ('  ' + $tag + ' ' + [string]$c.Kb + '  [' + [string]$c.Kind + ']' + $opt + '  ' + [string]$c.Title)
}

$toProcess = $candidates
if ($MissedOnly) { $toProcess = $missed }

if (@($toProcess).Count -eq 0) {
    if ($MissedOnly) { Write-Host ''; Write-Host ('No missed updates: the image is already at ' + $imgLevel.Build + '.' + $imgLevel.Revision + ' for every applicable package found.') }
    else { Write-Host 'No applicable updates found (or catalog unreachable).' }
    exit 0
}

if ($ListOnly) {
    Write-Host ''
    Write-Host ('LIST ONLY - nothing downloaded. Re-run without -ListOnly to download into: ' + $OutDir)
    exit 0
}

$manifestFiles = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
$hashFailures = @()
$quarantined = @()
$totalBytes = 0
$dlIndex = 0
foreach ($c in $toProcess) {
    $guid = [string]$c.UpdateGuid
    if (-not $guid) { Write-Host ('SKIP ' + $c.Kb + ': no catalog GUID'); continue }
    Write-Host ('Resolving download URL for ' + $c.Kb + ' ...')
    $files = @()
    try { $files = @(Get-WinISODownloadFiles -Guid $guid) } catch { Write-Host ('  failed: ' + $_.Exception.Message); continue }
    if ($files.Count -eq 0) { Write-Host ('  the catalog dialog lists no .msu file for ' + $c.Kb) }
    foreach ($file in $files) {
        $u = [string]$file.Url
        $name = [string]$file.FileName
        if (-not $name) { $name = ($u.Split('/'))[-1] }
        $dest = Join-Path $OutDir $name
        $catalogSha1 = [string]$file.Sha1
        $catalogSha256 = [string]$file.Sha256
        if (Test-Path -LiteralPath $dest) {
            Write-Host ('  exists, checking: ' + $name)
            $existingBytes = [long](Get-Item -LiteralPath $dest).Length
            $sizeCheck = Test-WinISOCatalogSize -Text ([string]$c.Size) -Bytes $existingBytes
            $hashCheck = Test-WinISOFileDigest -Path $dest -ExpectedSha1 $catalogSha1 -ExpectedSha256 $catalogSha256
            if ($hashCheck.Ok) {
                if (-not $sizeCheck.Ok) { Write-Host ('  WARNING: ' + $name + ' does not match the catalog size: ' + $sizeCheck.Detail) }
                else { Write-Host ('  ' + $hashCheck.Detail) }
                $manifestFiles.Add([pscustomobject]@{ kb = [string]$c.Kb; kind = [string]$c.Kind; missed_state = [string]$c.MissedState; url = $u; file = $name; bytes = $existingBytes; catalog_bytes = $sizeCheck.CatalogBytes; size_match = $sizeCheck.Ok; catalog_sha1 = $catalogSha1; catalog_sha256 = $catalogSha256; hash_match = [bool]$hashCheck.Ok; digest = $hashCheck.Detail; sha256 = $hashCheck.Sha256.ToUpperInvariant() })
                continue
            }
            # An existing file that fails its published digest must leave Updates\,
            # otherwise the next build picks the bad copy up again.
            Write-Host ('  WARNING: ' + $name + ' failed its catalog digest: ' + $hashCheck.Detail)
            Write-Host '  moving it to quarantine and downloading it again'
            $moved = Move-WinISOToQuarantine -Path $dest -QuarantineDir $QuarantineDir -Reason ('digest mismatch: ' + $hashCheck.Detail)
            if ($moved) {
                $quarantined += [pscustomobject]@{ file = $name; path = $moved; reason = ('digest mismatch: ' + $hashCheck.Detail) }
                Write-Host ('  quarantined: ' + $moved)
            }
            else { $quarantined += [pscustomobject]@{ file = $name; path = ''; reason = 'digest mismatch (the file was already gone)' } }
        }
        $len = 0
        try {
            $resp = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -UserAgent $script:UserAgent -TimeoutSec 60 -ErrorAction Stop
            if ($resp.Headers['Content-Length']) { $len = [long]($resp.Headers['Content-Length']) }
        } catch { }
        if ($len -le 0) { $len = 64MB }
        $totalBytes += $len
        $dlIndex++
        $expectedMb = [math]::Round($len / 1MB, 1)
        Write-Host ('DL-PROGBAR ' + $name + ' 0.0MB / ' + $expectedMb + 'MB 0.0%')
        Write-Host ('  downloading: ' + $name)
        $saved = Save-WinISOUpdateFile -Url $u -DestPath $dest -Name $name -Sha1 $catalogSha1 -Sha256 $catalogSha256 -QuarantineDir $QuarantineDir -UserAgent $script:UserAgent
        foreach ($q in @($saved.Quarantined)) {
            $quarantined += [pscustomobject]@{ file = $name; path = [string]$q; reason = 'digest mismatch after re-download' }
        }
        if (-not $saved.Ok) {
            Write-Host ('  not usable: ' + $saved.Detail)
            $hashFailures += $name
            $manifestFiles.Add([pscustomobject]@{ kb = [string]$c.Kb; kind = [string]$c.Kind; missed_state = [string]$c.MissedState; url = $u; file = $name; bytes = [long]$saved.Bytes; catalog_bytes = 0; size_match = $false; catalog_sha1 = $catalogSha1; catalog_sha256 = $catalogSha256; hash_match = $false; digest = [string]$saved.Detail; sha256 = [string]$saved.Sha256 })
            continue
        }
        $actualBytes = [long]$saved.Bytes
        Write-Host ('DL-DONE ' + $name + ' ' + [math]::Round($actualBytes / 1MB, 1) + 'MB')
        $sizeCheck = Test-WinISOCatalogSize -Text ([string]$c.Size) -Bytes $actualBytes
        if (-not $sizeCheck.Ok) { Write-Host ('  WARNING: ' + $name + ' does not match the catalog size: ' + $sizeCheck.Detail) }
        else { Write-Host ('  ' + $saved.Detail) }
        $manifestFiles.Add([pscustomobject]@{ kb = [string]$c.Kb; kind = [string]$c.Kind; missed_state = [string]$c.MissedState; url = $u; file = $name; bytes = $actualBytes; catalog_bytes = $sizeCheck.CatalogBytes; size_match = $sizeCheck.Ok; catalog_sha1 = $catalogSha1; catalog_sha256 = $catalogSha256; hash_match = $true; digest = [string]$saved.Detail; sha256 = [string]$saved.Sha256 })
    }
}
$totalMb = [math]::Round($totalBytes / 1MB, 1)
Write-Host ('DL-DONE-ALL ' + @($manifestFiles).Count + ' package file(s)  total ' + $totalMb + ' MB')
if (@($hashFailures).Count -gt 0) {
    Write-Host ('DL-VERIFY FAILED for ' + @($hashFailures).Count + ' file(s): ' + (@($hashFailures) -join ', '))
    Write-Host 'Each bad copy was moved out of Updates\ into quarantine and downloaded once more; what is left still fails, so the file was not kept.'
}
else { Write-Host 'DL-VERIFY OK: every file matches the digest the catalog publishes.' }
if (@($quarantined).Count -gt 0) {
    Write-Host ('DL-QUARANTINE ' + @($quarantined).Count + ' bad copy(ies) moved to ' + $QuarantineDir)
}

$manifest = [ordered]@{
    generated_utc  = [DateTime]::UtcNow.ToString('o')
    product        = $product
    build          = $Build
    version        = $version
    architecture   = $Architecture
    image_build    = $imgLevel.Build
    image_revision = $imgLevel.Revision
    image_source   = $imgLevel.Source
    missed_only    = [bool]$MissedOnly
    missed_count   = $missed.Count
    present_count  = $present.Count
    out_dir        = $OutDir
    quarantine_dir = $QuarantineDir
    hash_verified  = (@($manifestFiles | Where-Object { $_.hash_match }).Count)
    hash_failures  = @($hashFailures)
    quarantined    = @($quarantined)
    files          = @($manifestFiles)
}
$reportDir = Join-Path $fullWs 'Reports'
if (-not (Test-Path -LiteralPath $reportDir)) { [void](New-Item -ItemType Directory -Path $reportDir -Force) }
$manifestPath = Join-Path $reportDir 'DOWNLOAD-MANIFEST.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ('Downloaded/verified ' + @($manifestFiles).Count + ' package file(s), ' + (@($manifestFiles | Where-Object { $_.hash_match }).Count) + ' with a matching catalog digest.')
Write-Host ('Manifest: ' + $manifestPath)
