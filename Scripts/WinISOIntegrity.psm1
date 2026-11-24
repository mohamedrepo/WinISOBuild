# WinISOIntegrity.psm1
# Verification helpers shared by Test-WinISOIntegrity.ps1, the build script, the
# update-integration script and the USB burner.
#
# Everything here is pure: it takes file paths or the text DISM printed and
# returns objects. No DISM, disk, network or clipboard access happens inside, so
# the rules that decide "is this download intact", "is this package order legal"
# and "is this answer file complete" can be unit tested without an image.
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only content.

Set-StrictMode -Version 2

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

# Returns one object per requested algorithm so MD5 and SHA256 come out of a
# single pass over the caller's list. Throws for a missing file or an algorithm
# Get-FileHash does not support.
function Get-WinISOFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Algorithm = @('MD5', 'SHA256')
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('file not found: ' + $Path) }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $bytes = (Get-Item -LiteralPath $full).Length
    $allowed = @('MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512')
    $results = @()
    foreach ($a in @($Algorithm)) {
        $name = ([string]$a).Trim().ToUpperInvariant()
        if ($allowed -notcontains $name) { throw ('unsupported hash algorithm: ' + $a) }
        $hash = (Get-FileHash -LiteralPath $full -Algorithm $name).Hash.ToLowerInvariant()
        $results += [pscustomobject]@{
            Algorithm = $name
            Hash      = $hash
            Path      = $full
            Bytes     = [long]$bytes
        }
    }
    return $results
}

# Renders hash objects as the "<ALGORITHM>  <hash>" lines a checksum file uses,
# optionally with the file path appended for pasting into a bug report.
function Format-WinISOHashText {
    param(
        [object[]]$Hashes = @(),
        [switch]$IncludePath
    )
    $lines = @()
    foreach ($h in @($Hashes)) {
        if ($null -eq $h) { continue }
        $line = ([string]$h.Algorithm + '  ' + [string]$h.Hash)
        if ($IncludePath) { $line += ('  ' + [string]$h.Path) }
        $lines += $line
    }
    return ($lines -join [Environment]::NewLine)
}

# Parses a checksum file ("<hex>  <path>" or "<hex> *<path>", as written by
# certutil, sha256sum and this toolchain's ISO-SHA256.txt).
function Read-WinISOHashSidecar {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('checksum file not found: ' + $Path) }
    $entries = @()
    foreach ($raw in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $line = ([string]$raw).Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $m = [regex]::Match($line, '^([0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})[ \t]+\*?(.+?)\s*$')
        if ($m.Success) {
            $hex = $m.Groups[1].Value.ToLowerInvariant()
            $algorithm = 'SHA256'
            if ($hex.Length -eq 32) { $algorithm = 'MD5' }
            elseif ($hex.Length -eq 40) { $algorithm = 'SHA1' }
            $entries += [pscustomobject]@{
                Algorithm = $algorithm
                Hash      = $hex
                File      = $m.Groups[2].Value
            }
        }
    }
    return $entries
}

# Compares two hashes, ignoring case, whitespace and an optional algorithm
# prefix ("SHA256: <hex>").
function Test-WinISOHashMatch {
    param([string]$Expected, [string]$Actual)
    if (-not $Expected -or -not $Actual) { return $false }
    $e = ([string]$Expected) -replace '(?i)\b(sha-?256|sha-?1|md5)\s*:?', ''
    $a = ([string]$Actual) -replace '(?i)\b(sha-?256|sha-?1|md5)\s*:?', ''
    $e = ($e -replace '\s', '').ToLowerInvariant()
    $a = ($a -replace '\s', '').ToLowerInvariant()
    if (-not $e -or -not $a) { return $false }
    return ($e -eq $a)
}

# ---------------------------------------------------------------------------
# Download manifest (Reports\DOWNLOAD-MANIFEST.json, written by Get-WinISOUpdates)
# ---------------------------------------------------------------------------

# Reads the manifest's files[] entries. Returns an empty array when the manifest
# does not exist yet (a first run that downloaded nothing has no manifest).
function Get-WinISOManifestFiles {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $list = @()
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $list }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw ('the download manifest is not valid JSON: ' + $ManifestPath + ' (' + $_.Exception.Message + ')') }
    $files = $null
    if ($null -ne $doc -and $doc.PSObject.Properties['files']) { $files = $doc.files }
    foreach ($f in @($files)) {
        if ($null -eq $f) { continue }
        $name = ''
        foreach ($key in @('file', 'name')) {
            $prop = $f.PSObject.Properties[$key]
            if ($prop -and $prop.Value) { $name = [string]$prop.Value; break }
        }
        if (-not $name) { continue }
        $sha = ''
        $shaProp = $f.PSObject.Properties['sha256']
        if ($shaProp -and $shaProp.Value) { $sha = [string]$shaProp.Value }
        $size = -1
        $sizeProp = $f.PSObject.Properties['bytes']
        if ($sizeProp -and $null -ne $sizeProp.Value) { $size = [long]$sizeProp.Value }
        $kb = ''
        $kbProp = $f.PSObject.Properties['kb']
        if ($kbProp -and $kbProp.Value) { $kb = [string]$kbProp.Value }
        $list += [pscustomobject]@{ File = $name; Sha256 = $sha.ToLowerInvariant(); Bytes = $size; Kb = $kb }
    }
    return $list
}

# Re-hashes every manifest entry present in -DownloadDir and reports what does
# not match. This is the "was the 4 GB download truncated" gate: an .msu whose
# size or SHA256 differs from the manifest is refused before integration.
function Test-WinISOManifestPayload {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$DownloadDir,
        [switch]$RequireAll
    )
    $ok = @()
    $mismatched = @()
    $missing = @()
    $entries = @(Get-WinISOManifestFiles -ManifestPath $ManifestPath)
    foreach ($e in $entries) {
        $candidate = Join-Path $DownloadDir $e.File
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $missing += $e
            continue
        }
        $length = [long](Get-Item -LiteralPath $candidate).Length
        if ($e.Bytes -ge 0 -and $length -ne $e.Bytes) {
            $mismatched += [pscustomobject]@{
                File     = $e.File
                Reason   = ('size ' + $length + ' bytes, manifest says ' + $e.Bytes)
                Expected = [string]$e.Bytes
                Actual   = [string]$length
            }
            continue
        }
        if ($e.Sha256) {
            $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not (Test-WinISOHashMatch -Expected $e.Sha256 -Actual $actual)) {
                $mismatched += [pscustomobject]@{
                    File     = $e.File
                    Reason   = 'SHA256 differs from the manifest'
                    Expected = $e.Sha256
                    Actual   = $actual
                }
                continue
            }
        }
        $ok += $e
    }
    $failed = ($mismatched.Count -gt 0)
    if ($RequireAll -and $missing.Count -gt 0) { $failed = $true }
    return [pscustomobject]@{
        Ok         = @($ok)
        Mismatched = @($mismatched)
        Missing    = @($missing)
        Checked    = $entries.Count
        Failed     = $failed
    }
}

# ---------------------------------------------------------------------------
# Package classification and ordering (SSU before LCU before .NET)
# ---------------------------------------------------------------------------

# Maps a DISM package identity or a file name to a servicing package kind.
function Get-WinISOPackageKind {
    param([string]$Identity)
    $t = [string]$Identity
    if (-not $t) { return 'other' }
    if ($t -match '(?i)servicing\s*stack|[-_ ]ssu') { return 'ssu' }
    if ($t -match '(?i)dotnet\s*rollup|[-_ ]ndp\d*|\.net\s*framework') { return 'netfx' }
    if ($t -match '(?i)rollupfix|(?i)\bkb\d{6,8}\b.*\-x64_|cumulative') { return 'lcu' }
    if ($t -match '(?i)\bkb\d{6,8}\b') { return 'lcu' }
    return 'other'
}

function Get-WinISOKindRank {
    param([string]$Kind)
    switch ([string]$Kind) {
        'ssu' { return 0 }
        'lcu' { return 1 }
        'netfx' { return 2 }
        default { return 3 }
    }
}

# Orders packages for integration: servicing stack first, then the cumulative
# update, then .NET, then anything else. Stable inside a rank (input order kept).
function Get-WinISOPackageOrder {
    param([string[]]$Packages = @())
    $items = @()
    $i = 0
    foreach ($p in @($Packages)) {
        if (-not $p) { continue }
        $kind = Get-WinISOPackageKind -Identity ([System.IO.Path]::GetFileName([string]$p))
        $items += [pscustomobject]@{
            Package = [string]$p
            Name    = [System.IO.Path]::GetFileName([string]$p)
            Kind    = $kind
            Rank    = (Get-WinISOKindRank -Kind $kind)
            Index   = $i
        }
        $i++
    }
    $sorted = @($items | Sort-Object -Property Rank, Index)
    return $sorted
}

# Returns the ordering violations in a package list. An LCU or .NET update
# applied before the servicing stack in the same list is what produces
# 0x800f081e on an offline image, so that combination is reported instead of
# being discovered three DISM calls later.
function Test-WinISOPackageOrder {
    param([string[]]$Packages = @())
    $problems = @()
    $items = @(Get-WinISOPackageOrder -Packages $Packages)
    $ssu = @($items | Where-Object { $_.Kind -eq 'ssu' })
    if ($ssu.Count -eq 0) { return $problems }
    $firstSsu = ($ssu | Sort-Object -Property Index)[0].Index
    foreach ($it in $items) {
        if ($it.Kind -eq 'ssu') { continue }
        if ($it.Index -lt $firstSsu) {
            $problems += ('the ' + $it.Kind + ' package ' + $it.Name + ' is listed before the servicing stack ' + $ssu[0].Name + '; a servicing stack update must be applied first')
        }
    }
    $lcu = @($items | Where-Object { $_.Kind -eq 'lcu' })
    if ($lcu.Count -gt 0) {
        $firstLcu = ($lcu | Sort-Object -Property Index)[0].Index
        foreach ($it in $items) {
            if ($it.Kind -ne 'netfx') { continue }
            if ($it.Index -lt $firstLcu) {
                $problems += ('the .NET update ' + $it.Name + ' is listed before the cumulative update ' + $lcu[0].Name + '; the cumulative update must be applied first')
            }
        }
    }
    return $problems
}

# Parses the output of
#   DISM /English /Get-PackageInfo /PackagePath:<file.msu>
# which reads the package metadata without mounting an image. Only the fields
# the ordering and already-applied checks need are extracted.
function ConvertFrom-WinISOPackageInfoText {
    param([string]$Text)
    $identity = ''
    $version = ''
    $applicable = ''
    foreach ($raw in (([string]$Text) -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '(?i)^Package Identity\s*:\s*(.+)$') { $identity = $Matches[1].Trim(); continue }
        if ($line -match '(?i)^Version\s*:\s*(\S+)$') { $version = $Matches[1].Trim(); continue }
        if ($line -match '(?i)^Applicable\s*:\s*(\S+)$') { $applicable = $Matches[1].Trim(); continue }
    }
    $build = 0
    $revision = 0
    if ($identity) {
        # Package_for_RollupFix~31bf3856ad364e35~amd64~~22621.4317.1.11
        $m = [regex]::Match($identity, '~~(\d+)\.(\d+)')
        if ($m.Success) {
            $build = [int]$m.Groups[1].Value
            $revision = [int]$m.Groups[2].Value
        }
    }
    if ($build -eq 0 -and $version) {
        $m2 = [regex]::Match($version, '10\.0\.(\d+)\.(\d+)')
        if ($m2.Success) {
            $build = [int]$m2.Groups[1].Value
            $revision = [int]$m2.Groups[2].Value
        }
    }
    $kind = Get-WinISOPackageKind -Identity $identity
    return [pscustomobject]@{
        Identity   = $identity
        Version    = $version
        Build      = $build
        Revision   = $revision
        Kind       = $kind
        Applicable = $applicable
    }
}

# True when a package of this build/revision is already part of an image whose
# level is imageBuild.imageRevision. Only cumulative updates carry a comparable
# level; .NET rollups use their own numbering and are not judged this way.
function Test-WinISOPackageAlreadyInImage {
    param(
        [string]$Kind,
        [int]$PackageBuild,
        [int]$PackageRevision,
        [int]$ImageBuild,
        [int]$ImageRevision
    )
    if ([string]$Kind -ne 'lcu') { return $false }
    if ($PackageBuild -le 0 -or $PackageRevision -le 0) { return $false }
    if ($ImageBuild -le 0 -or $ImageRevision -le 0) { return $false }
    if ($PackageBuild -ne $ImageBuild) { return $false }
    return ($ImageRevision -ge $PackageRevision)
}

# ---------------------------------------------------------------------------
# unattend.xml validation
# ---------------------------------------------------------------------------

# Structural validation of an answer file: root element and namespace, the three
# passes Setup needs, the components that must be present in each, and the local
# account fields when a local account is declared. Does not attempt to validate
# against the (unavailable offline) Windows SIM schema.
function Test-WinUnattendDocument {
    param([Parameter(Mandatory)][string]$Path)
    $problems = @()
    $passes = @()
    $components = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Problems = @('file not found: ' + $Path); Passes = @(); Components = @() }
    }
    $doc = $null
    try { $doc = [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8) }
    catch {
        return [pscustomobject]@{ Ok = $false; Problems = @('not well-formed XML: ' + $_.Exception.Message); Passes = @(); Components = @() }
    }
    $root = $doc.DocumentElement
    if (-not $root -or $root.LocalName -ne 'unattend') {
        $problems += ('the root element is "' + [string]$root.LocalName + '"; an answer file must start with <unattend>')
    }
    elseif ($root.NamespaceURI -ne 'urn:schemas-microsoft-com:unattend') {
        $problems += ('the root namespace is "' + $root.NamespaceURI + '"; expected urn:schemas-microsoft-com:unattend')
    }

    foreach ($settings in @($doc.SelectNodes("//*[local-name()='settings']"))) {
        $pass = ''
        if ($settings.Attributes['pass']) { $pass = [string]$settings.Attributes['pass'].Value }
        if ($pass -and ($passes -notcontains $pass)) { $passes += $pass }
        foreach ($c in @($settings.SelectNodes(".//*[local-name()='component']"))) {
            $name = ''
            if ($c.Attributes['name']) { $name = [string]$c.Attributes['name'].Value }
            if ($name) { $components += ($pass + ':' + $name) }
        }
    }
    foreach ($required in @('windowsPE', 'specialize', 'oobeSystem')) {
        if ($passes -notcontains $required) { $problems += ('the ' + $required + ' pass is missing') }
    }

    $setup = @($components | Where-Object { $_ -match ':Microsoft-Windows-Setup$' })
    if ($setup.Count -eq 0) { $problems += 'Microsoft-Windows-Setup is missing from the windowsPE pass' }
    elseif (-not ($setup -like 'windowsPE:*')) { $problems += 'Microsoft-Windows-Setup must be in the windowsPE pass' }

    $shell = @($components | Where-Object { $_ -match ':Microsoft-Windows-Shell-Setup$' })
    if ($shell.Count -eq 0) { $problems += 'Microsoft-Windows-Shell-Setup is missing' }
    if (-not ($shell -like 'oobeSystem:*')) { $problems += 'Microsoft-Windows-Shell-Setup is missing from the oobeSystem pass' }

    foreach ($required in @('Microsoft-Windows-International-Core-WinPE', 'Microsoft-Windows-International-Core')) {
        if (-not ($components | Where-Object { $_ -match (':' + [regex]::Escape($required) + '$') })) {
            $problems += ('the ' + $required + ' component is missing')
        }
    }

    # Local account completeness: a declared account without a name is silently
    # ignored by Setup, and a plaintext password without the PlainText flag makes
    # OOBE reject the file.
    $accounts = @($doc.SelectNodes("//*[local-name()='LocalAccount']"))
    foreach ($acct in $accounts) {
        $nameNode = @($acct.SelectNodes("./*[local-name()='Name']"))
        if ($nameNode.Count -eq 0 -or -not $nameNode[0].InnerText) { $problems += 'a LocalAccount entry has no Name' }
        $pwdNode = @($acct.SelectNodes("./*[local-name()='Password']"))
        if ($pwdNode.Count -gt 0) {
            $plain = @($pwdNode[0].SelectNodes("./*[local-name()='PlainText']"))
            if ($plain.Count -eq 0 -or [string]$plain[0].InnerText -ne 'true') {
                $problems += 'a LocalAccount password is set without <PlainText>true</PlainText>'
            }
        }
    }
    $eula = @($doc.SelectNodes("//*[local-name()='AcceptEula']"))
    if ($eula.Count -eq 0) { $problems += 'AcceptEula is missing from Microsoft-Windows-Setup/UserData' }

    return [pscustomobject]@{
        Ok         = ($problems.Count -eq 0)
        Problems   = @($problems)
        Passes     = @($passes)
        Components = @($components)
    }
}

# ---------------------------------------------------------------------------
# Build profile (State\BuildProfile.json)
# ---------------------------------------------------------------------------

function Read-WinISOProfile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('build profile not found: ' + $Path) }
    try { $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw ('the build profile is not valid JSON: ' + $Path + ' (' + $_.Exception.Message + ')') }
    $values = @{}
    foreach ($p in @($doc.PSObject.Properties)) { $values[$p.Name] = $p.Value }
    return $values
}

function Save-WinISOProfile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $out = [ordered]@{}
    foreach ($k in $Values.Keys) { $out[[string]$k] = $Values[$k] }
    $out['saved_utc'] = [DateTime]::UtcNow.ToString('o')
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

# ---------------------------------------------------------------------------
# ADK guidance
# ---------------------------------------------------------------------------

# The message shown when oscdimg.exe is missing. Kept here so the build script,
# the orchestrator and the GUI all point at the same supported install route.
function Get-WinISOAdkGuidanceText {
    $lines = @(
        'oscdimg.exe was not found, so the bootable ISO cannot be rebuilt.',
        'Install the Windows ADK Deployment Tools with either:',
        '    winget install --id Microsoft.WindowsADK -e --accept-source-agreements --accept-package-agreements',
        '    or download https://learn.microsoft.com/windows-hardware/get-started/adk-install',
        '      and select ONLY "Deployment Tools" in the ADK installer.',
        'Then re-run; oscdimg.exe is under Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\.'
    )
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Answer-file secret audit
# ---------------------------------------------------------------------------

# Reports the credential material an answer file carries: passwords (with or
# without PlainText), AutoLogon credentials and a hard-coded product key. The
# generator warns while writing; this reads a file that already exists, such as
# the autounattend.xml on a USB stick or inside an ISO, before it is handed out.
function Test-WinUnattendSecrets {
    param([Parameter(Mandatory)][string]$Path)
    $findings = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Ok         = $false
            HasSecrets = $false
            Findings   = @()
            Summary    = ('file not found: ' + $Path)
        }
    }
    $doc = $null
    try { $doc = [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8) }
    catch {
        return [pscustomobject]@{
            Ok         = $false
            HasSecrets = $false
            Findings   = @()
            Summary    = ('not well-formed XML: ' + $Path)
        }
    }

    foreach ($pw in @($doc.SelectNodes("//*[local-name()='Password']"))) {
        $valueNodes = @($pw.SelectNodes("./*[local-name()='Value']"))
        $value = ''
        if ($valueNodes.Count -gt 0) { $value = [string]$valueNodes[0].InnerText }
        if (-not $value) { continue }
        $plainNodes = @($pw.SelectNodes("./*[local-name()='PlainText']"))
        $plain = 'false'
        if ($plainNodes.Count -gt 0) { $plain = [string]$plainNodes[0].InnerText }
        $owner = 'unattend'
        if ($pw.ParentNode -and $pw.ParentNode.LocalName) { $owner = [string]$pw.ParentNode.LocalName }
        $detail = 'a password is stored in the answer file without PlainText=true (Setup may ignore it), so it is recoverable from the media'
        if ($plain -eq 'true') { $detail = 'a password is stored in PLAINTEXT (PlainText=true) and is recoverable from the media by anyone who has the file' }
        $findings += [pscustomobject]@{ Kind = 'password'; Severity = 'high'; Where = $owner; Detail = $detail }
    }

    $autoLogon = @($doc.SelectNodes("//*[local-name()='AutoLogon']"))
    if ($autoLogon.Count -gt 0) {
        $findings += [pscustomobject]@{
            Kind     = 'autologon'
            Severity = 'medium'
            Where    = 'AutoLogon'
            Detail   = 'AutoLogon is enabled; the machine signs in without an operator and any stored credential stays on the installed system'
        }
    }

    foreach ($keyNode in @($doc.SelectNodes("//*[local-name()='ProductKey']"))) {
        $keyValue = ''
        foreach ($child in @($keyNode.SelectNodes("./*[local-name()='Key']"))) {
            if ([string]$child.InnerText) { $keyValue = [string]$child.InnerText }
        }
        $ownText = [string]$keyNode.InnerText
        if ($keyValue -or ($ownText -and -not ($keyNode.SelectNodes('./*').Count -gt 0))) { $keyValue = $ownText }
        if ($keyValue -and $keyValue.Trim()) {
            $findings += [pscustomobject]@{
                Kind     = 'product-key'
                Severity = 'high'
                Where    = 'ProductKey'
                Detail   = 'a product key is embedded in the answer file and ships on the media'
            }
        }
    }

    $summary = 'no credentials, AutoLogon or product key found in the answer file'
    if ($findings.Count -gt 0) {
        $summary = (@($findings | ForEach-Object { $_.Kind + ': ' + $_.Detail }) -join ' | ')
    }
    return [pscustomobject]@{
        Ok         = $true
        HasSecrets = ($findings.Count -gt 0)
        Findings   = @($findings)
        Summary    = $summary
    }
}

# ---------------------------------------------------------------------------
# Media identity (Windows 10 vs 11, x64 vs arm64) and output naming
# ---------------------------------------------------------------------------

# Derives the media family and architecture token from the image itself. The
# build number is authoritative for the family (22000 and later is Windows 11),
# and the edition name is only a fallback, so a renamed file cannot change the
# result.
function Get-WinISOMediaIdentity {
    param(
        [string]$EditionName = '',
        [int]$Build = 0,
        [string]$Architecture = ''
    )
    $family = 'Windows'
    if ($Build -ge 22000) { $family = 'Windows 11' }
    elseif ($Build -gt 0) { $family = 'Windows 10' }
    elseif ([string]$EditionName -match '(?i)Windows\s*11') { $family = 'Windows 11' }
    elseif ([string]$EditionName -match '(?i)Windows\s*10') { $family = 'Windows 10' }

    $arch = ([string]$Architecture).Trim().ToLowerInvariant()
    $archToken = ''
    if ($arch -match 'arm64|aarch64') { $archToken = 'arm64' }
    elseif ($arch -match 'x86|i386|i686') { $archToken = 'x86' }
    elseif ($arch -match 'amd64|x64|x86_64') { $archToken = 'x64' }

    $shortToken = ''
    if ($family -eq 'Windows 11') { $shortToken = 'Win11' }
    elseif ($family -eq 'Windows 10') { $shortToken = 'Win10' }
    else { $shortToken = 'Win' }

    $editionToken = ''
    foreach ($candidate in @('Enterprise', 'Education', 'Pro', 'Home', 'Core', 'IoT', 'Server')) {
        if ([string]$EditionName -match ('(?i)\b' + $candidate + '\b')) { $editionToken = $candidate; break }
    }
    if (-not $editionToken) { $editionToken = 'Edition' }

    return [pscustomobject]@{
        Family      = $family
        ShortToken  = $shortToken
        Architecture = $arch
        ArchToken   = $archToken
        Edition     = $editionToken
    }
}

# Canonical output file name: family, edition and level in lower case without
# separators, for example windows11pro26300.10075.iso. Non-x64 media keeps an
# architecture suffix so an arm64 build cannot overwrite the x64 ISO.
function New-WinISOOutputName {
    param(
        [string]$EditionName = '',
        [int]$Build = 0,
        [int]$Revision = 0,
        [string]$Architecture = ''
    )
    $identity = Get-WinISOMediaIdentity -EditionName $EditionName -Build $Build -Architecture $Architecture
    $familyToken = 'windows'
    if ($identity.Family -eq 'Windows 11') { $familyToken = 'windows11' }
    elseif ($identity.Family -eq 'Windows 10') { $familyToken = 'windows10' }
    $editionToken = ([string]$identity.Edition).ToLowerInvariant()
    $archToken = [string]$identity.ArchToken
    if (-not $archToken) { $archToken = 'x64' }
    $levelToken = ''
    if ($Build -gt 0) {
        $levelToken = [string]$Build
        if ($Revision -gt 0) { $levelToken = $levelToken + '.' + [string]$Revision }
    }
    $name = $familyToken + $editionToken + $levelToken
    if ($archToken -ne 'x64') { $name = $name + '.' + $archToken }
    return ($name + '.iso')
}

# ---------------------------------------------------------------------------
# Latest released build (Microsoft release-health pages)
# ---------------------------------------------------------------------------

# Reads the Windows release information page and returns the newest level listed
# for one base build, for example 26300.10075 / KB5132057. The image metadata
# keeps the base build but not the revision of an LCU that was just added, so
# this is what a serviced ISO should be named after. -Content supplies saved page
# markup for tests, so the parser works without network access.
function Get-WinISOReleaseBuild {
    param(
        [ValidateSet('Windows 11', 'Windows 10')][string]$Family = 'Windows 11',
        [int]$BaseBuild = 0,
        [string]$Url = '',
        [string]$Content = '',
        [int]$TimeoutSec = 30
    )

    if (-not $Url) {
        if ($Family -eq 'Windows 10') { $Url = 'https://learn.microsoft.com/en-us/windows/release-health/release-information' }
        else { $Url = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information' }
    }

    $result = [ordered]@{
        Ok         = $false
        Family     = $Family
        BaseBuild  = $BaseBuild
        Build      = 0
        Revision   = 0
        Kb         = ''
        Url        = $Url
        Candidates = @()
        Error      = ''
    }

    $text = [string]$Content
    if (-not $text) {
        try {
            try {
                $tls12 = [System.Net.SecurityProtocolType]::Tls12
                if (-not ([System.Net.ServicePointManager]::SecurityProtocol -band $tls12)) {
                    [System.Net.ServicePointManager]::SecurityProtocol = ([System.Net.ServicePointManager]::SecurityProtocol -bor $tls12)
                }
            }
            catch { }
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            $text = [string]$response.Content
        }
        catch {
            $result.Error = ('could not read ' + $Url + ': ' + $_.Exception.Message)
            return [pscustomobject]$result
        }
    }

    # One table row per update. Markup is stripped per row so a build number and
    # its KB article stay paired; a plain-text or markdown fetch is read by line.
    $chunks = @()
    $markup = [regex]::Replace($text, '(?is)<(script|style)\b.*?</\1>', ' ')
    $rows = @([regex]::Split($markup, '(?i)<tr[\s>]'))
    if ($rows.Count -gt 1) {
        foreach ($row in $rows) { $chunks += [regex]::Replace($row, '(?s)<[^>]+>', ' ') }
    }
    else {
        foreach ($line in ([string]$text -split "`r?`n")) { $chunks += $line }
    }

    $candidates = @()
    foreach ($chunk in $chunks) {
        $line = [System.Net.WebUtility]::HtmlDecode([string]$chunk)
        $levelMatch = [regex]::Match($line, '(?<!\d)(\d{5})\.(\d{1,5})(?!\d)')
        if (-not $levelMatch.Success) { continue }
        $build = [int]$levelMatch.Groups[1].Value
        if ($BaseBuild -gt 0 -and $build -ne $BaseBuild) { continue }
        $kb = ''
        $kbMatch = [regex]::Match($line, '(?i)KB\s*(\d{6,8})')
        if ($kbMatch.Success) { $kb = 'KB' + $kbMatch.Groups[1].Value }
        $candidates += [pscustomobject]@{
            Build    = $build
            Revision = [int]$levelMatch.Groups[2].Value
            Kb       = $kb
        }
    }

    $result.Candidates = @($candidates)
    if ($candidates.Count -eq 0) {
        $result.Error = ('no build number for ' + $(if ($BaseBuild -gt 0) { 'base build ' + $BaseBuild } else { $Family }) + ' was found on ' + $Url)
        return [pscustomobject]$result
    }

    $withKb = @($candidates | Where-Object { $_.Kb })
    $pool = $candidates
    if ($withKb.Count -gt 0) { $pool = $withKb }
    $best = @($pool | Sort-Object -Property Revision -Descending)[0]

    $result.Ok = $true
    $result.Build = [int]$best.Build
    $result.Revision = [int]$best.Revision
    $result.Kb = [string]$best.Kb
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Driver inventory, de-duplication and storage-controller coverage
# ---------------------------------------------------------------------------

# Reads [Version] from an INF without parsing the whole file as a device list.
function Get-WinISOInfMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $provider = ''
    $driverVer = ''
    $className = ''
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -TotalCount 200 -ErrorAction Stop)) {
            $text = ([string]$line).Trim()
            if ($text -match '(?i)^Provider\s*=\s*(.+)$') { $provider = $Matches[1].Trim() }
            elseif ($text -match '(?i)^DriverVer\s*=\s*(.+)$') { $driverVer = $Matches[1].Trim() }
            elseif ($text -match '(?i)^Class\s*=\s*(.+)$') { $className = $Matches[1].Trim() }
        }
    }
    catch { }
    return [pscustomobject]@{ Provider = $provider; DriverVer = $driverVer; Class = $className }
}

# A driver package is signed when a catalog beside the INF has a valid
# Authenticode signature. The INF itself is normally not signed.
function Test-WinISODriverSigned {
    param([Parameter(Mandatory)][string]$InfPath)
    $folder = Split-Path -Parent $InfPath
    $cats = @()
    try { $cats = @(Get-ChildItem -LiteralPath $folder -Filter *.cat -File -ErrorAction SilentlyContinue) } catch { $cats = @() }
    foreach ($cat in $cats) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName -ErrorAction Stop
            if ([string]$sig.Status -eq 'Valid') { return $true }
        }
        catch { }
    }
    return $false
}

# One record per driver INF, with the package identity needed to de-duplicate.
# -SignedOnly drops packages with no valid catalog signature.
function Get-WinISODriverInventory {
    param(
        [Parameter(Mandatory)][string]$Drivers,
        [switch]$SignedOnly
    )
    $records = @()
    if (-not (Test-Path -LiteralPath $Drivers)) { return $records }
    $infFiles = @(Get-ChildItem -LiteralPath $Drivers -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($inf in $infFiles) {
        $meta = Get-WinISOInfMetadata -Path $inf.FullName
        $signed = $false
        if ($SignedOnly) { $signed = Test-WinISODriverSigned -InfPath $inf.FullName }
        if ($SignedOnly -and -not $signed) { continue }
        $records += [pscustomobject]@{
            Inf        = $inf.FullName
            Name       = $inf.Name
            Folder     = $inf.DirectoryName
            Provider   = $meta.Provider
            DriverVer  = $meta.DriverVer
            Class      = $meta.Class
            Signed     = $signed
            Key        = (([string]$meta.Provider).ToLowerInvariant() + '|' + ([string]$meta.DriverVer).ToLowerInvariant() + '|' + ([string]$meta.Class).ToLowerInvariant())
        }
    }
    return $records
}

# Picks one INF per provider/version/class. The first occurrence wins; every
# later copy is returned separately so the run can report it instead of
# silently adding the same package twice.
function Select-WinISOUniqueDrivers {
    param([object[]]$Inventory = @())
    $seen = @{}
    $unique = @()
    $duplicates = @()
    $conflicts = @()
    foreach ($rec in @($Inventory)) {
        if ($null -eq $rec) { continue }
        $key = [string]$rec.Key
        if (-not $key -or $key -eq '||') { $key = [string]$rec.Name }
        if ($seen.ContainsKey($key)) {
            $first = $seen[$key]
            $duplicates += [pscustomobject]@{ Inf = [string]$rec.Inf; DuplicateOf = [string]$first.Inf; Key = $key }
            if ([string]$rec.Name -ne [string]$first.Name) {
                $conflicts += [pscustomobject]@{
                    Key      = $key
                    Kept     = [string]$first.Inf
                    Ignored  = [string]$rec.Inf
                    Reason   = 'two different INF files declare the same provider, DriverVer and class'
                }
            }
            continue
        }
        $seen[$key] = $rec
        $unique += $rec
    }
    return [pscustomobject]@{
        Unique     = @($unique)
        Duplicates = @($duplicates)
        Conflicts  = @($conflicts)
    }
}

# Tokens that identify storage-controller drivers WinPE needs to see a modern
# disk (Intel VMD/RST, AMD RAID, NVMe). Checked against INF file names and the
# hardware IDs inside them.
$script:StorageDriverTokens = @('iastorvd', 'iastorac', 'iaahcic', 'vmd', 'stornvme', 'irst', 'amdraid', 'rcbottom', 'rcraid', 'rccfg')

function Get-WinISOStorageDriverTokens {
    return @($script:StorageDriverTokens)
}

function Get-WinISOStorageDriverEvidence {
    param([Parameter(Mandatory)][string]$Drivers)
    $evidence = @()
    if (-not (Test-Path -LiteralPath $Drivers)) { return $evidence }
    $infFiles = @(Get-ChildItem -LiteralPath $Drivers -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($inf in $infFiles) {
        $nameHit = ''
        foreach ($token in @($script:StorageDriverTokens)) {
            if ($inf.Name -match ('(?i)' + [regex]::Escape($token))) { $nameHit = $token; break }
        }
        $contentHit = ''
        if (-not $nameHit) {
            try {
                $text = [string](Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop)
                if ($text.Length -gt 400000) { $text = $text.Substring(0, 400000) }
                foreach ($token in @($script:StorageDriverTokens)) {
                    if ($text -match ('(?i)' + [regex]::Escape($token))) { $contentHit = $token; break }
                }
            }
            catch { }
        }
        $hit = $nameHit
        if (-not $hit) { $hit = $contentHit }
        if ($hit) {
            $evidence += [pscustomobject]@{
                Inf      = $inf.FullName
                Token    = $hit
                Location = $(if ($nameHit) { 'file name' } else { 'INF content' })
            }
        }
    }
    return $evidence
}

# Warnings for a driver set that cannot see a VMD/RAID/NVMe disk from WinPE.
# Only reported when the caller says modern storage is expected.
function Test-WinISOStorageDriverCoverage {
    param(
        [Parameter(Mandatory)][string]$Drivers,
        [switch]$RequireModernStorage
    )
    $evidence = @(Get-WinISOStorageDriverEvidence -Drivers $Drivers)
    $warnings = @()
    if (-not $RequireModernStorage) {
        return [pscustomobject]@{ Covered = ($evidence.Count -gt 0); Evidence = @($evidence); Warnings = @() }
    }
    if ($evidence.Count -eq 0) {
        $warnings += ('the driver set under ' + $Drivers + ' contains no Intel VMD/RST, AMD RAID or NVMe storage driver (looked for ' + (@($script:StorageDriverTokens) -join ', ') + '). On such a machine WinPE will start but Setup will list no disks.')
    }
    return [pscustomobject]@{
        Covered  = ($evidence.Count -gt 0)
        Evidence = @($evidence)
        Warnings = @($warnings)
    }
}

# ---------------------------------------------------------------------------
# Per-file media manifest
# ---------------------------------------------------------------------------

# Builds the manifest describing every file on the media tree. -Quick records
# sizes only (fast, catches truncation); otherwise each file is hashed.
function New-WinISOMediaManifest {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [switch]$Quick,
        [string]$IsoName = ''
    )
    $root = [System.IO.Path]::GetFullPath($MediaRoot)
    if (-not $root.EndsWith('\')) { $root += '\' }
    $files = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).Replace('\', '/')
        $sha = ''
        if (-not $Quick) { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        $files += [pscustomobject]@{
            path   = $rel
            bytes  = [long]$f.Length
            sha256 = $sha
        }
    }
    $total = [long]0
    foreach ($f in $files) { $total += [long]$f.bytes }
    return [pscustomobject]@{
        version     = 1
        iso         = $IsoName
        generated_utc = [DateTime]::UtcNow.ToString('o')
        hashed      = (-not $Quick)
        file_count  = $files.Count
        total_bytes = $total
        files       = @($files)
    }
}

# Compares a written drive or extracted tree with a media manifest. -Quick skips
# hashing and compares only presence and size.
function Test-WinISOMediaManifest {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$Quick
    )
    $ok = @()
    $missing = @()
    $mismatched = @()
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw ('media manifest not found: ' + $ManifestPath) }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw ('the media manifest is not valid JSON: ' + $ManifestPath) }
    $root = [System.IO.Path]::GetFullPath($MediaRoot)
    if (-not $root.EndsWith('\')) { $root += '\' }
    $entries = @()
    if ($doc -and $doc.PSObject.Properties['files']) { $entries = @($doc.files) }
    foreach ($e in $entries) {
        if ($null -eq $e) { continue }
        $rel = ([string]$e.path).Replace('/', '\')
        $full = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing += [string]$e.path
            continue
        }
        $length = [long](Get-Item -LiteralPath $full).Length
        if ($length -ne [long]$e.bytes) {
            $mismatched += [pscustomobject]@{ Path = [string]$e.path; Reason = ('size ' + $length + ' bytes, manifest says ' + [long]$e.bytes) }
            continue
        }
        if (-not $Quick -and [string]$e.sha256) {
            $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not (Test-WinISOHashMatch -Expected ([string]$e.sha256) -Actual $actual)) {
                $mismatched += [pscustomobject]@{ Path = [string]$e.path; Reason = 'SHA256 differs from the manifest' }
                continue
            }
        }
        $ok += [string]$e.path
    }
    return [pscustomobject]@{
        Checked    = $entries.Count
        Ok         = @($ok)
        Missing    = @($missing)
        Mismatched = @($mismatched)
        Failed     = (($missing.Count + $mismatched.Count) -gt 0)
    }
}

# ---------------------------------------------------------------------------
# Mounted-image inspection (stale mounts left by a killed build)
# ---------------------------------------------------------------------------

# Parses 'dism /Get-MountedImageInfo' into one record per mount.
function ConvertFrom-WinISOMountedImageText {
    param([string]$Text)
    $mounts = @()
    $cur = $null
    foreach ($raw in (([string]$Text) -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^Mount Dir\s*:\s*(.+)$') {
            if ($cur) { $mounts += $cur }
            $cur = @{ MountDir = $Matches[1].Trim(); ImageFile = ''; Index = 0; Status = '' }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^Image File\s*:\s*(.+)$') { $cur.ImageFile = $Matches[1].Trim() }
        elseif ($line -match '^Image Index\s*:\s*(\d+)$') { $cur.Index = [int]$Matches[1] }
        elseif ($line -match '^Status\s*:\s*(.+)$') { $cur.Status = $Matches[1].Trim() }
    }
    if ($cur) { $mounts += $cur }
    foreach ($m in $mounts) {
        $obj = [pscustomobject]@{
            MountDir  = [string]$m.MountDir
            ImageFile = [string]$m.ImageFile
            Index     = [int]$m.Index
            Status    = [string]$m.Status
        }
        $obj
    }
}

# Mounts whose directory is inside the workspace, i.e. leftovers this tool
# created and can safely discard.
function Get-WinISOStaleMounts {
    param(
        [object[]]$Mounts = @(),
        [Parameter(Mandatory)][string]$Workspace
    )
    $ws = [System.IO.Path]::GetFullPath($Workspace)
    if (-not $ws.EndsWith('\')) { $ws += '\' }
    $stale = @()
    foreach ($m in @($Mounts)) {
        if ($null -eq $m) { continue }
        $dir = [string]$m.MountDir
        if (-not $dir) { continue }
        $full = ''
        try { $full = [System.IO.Path]::GetFullPath($dir) } catch { continue }
        if ($full.StartsWith($ws, [System.StringComparison]::OrdinalIgnoreCase)) { $stale += $m }
    }
    return $stale
}

# ---------------------------------------------------------------------------
# Build checkpoint, single-instance lock and run history
# ---------------------------------------------------------------------------

function Read-WinISOJsonHashtable {
    param([Parameter(Mandatory)][string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    try { $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $values }
    if ($null -eq $doc) { return $values }
    foreach ($p in @($doc.PSObject.Properties)) { $values[$p.Name] = $p.Value }
    return $values
}

function Write-WinISOJsonHashtable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, ($Values | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

# The checkpoint records which stages finished so -Resume can skip them. It is
# advisory: a stage that says complete is still re-validated against the files
# on disk by the caller.
function Read-WinISOBuildCheckpoint {
    param([Parameter(Mandatory)][string]$Path)
    $values = Read-WinISOJsonHashtable -Path $Path
    $stages = @()
    $indexes = @()
    if ($values.ContainsKey('stages')) { $stages = @($values['stages']) }
    if ($values.ContainsKey('indexes_serviced')) { $indexes = @($values['indexes_serviced'] | ForEach-Object { [int]$_ }) }
    return [pscustomobject]@{
        Path            = $Path
        Exists          = (Test-Path -LiteralPath $Path -PathType Leaf)
        Stages          = @($stages | ForEach-Object { [string]$_ })
        IndexesServiced = @($indexes)
        MediaReady      = [bool]($values.ContainsKey('media_ready') -and $values['media_ready'])
        Exported        = [bool]($values.ContainsKey('exported') -and $values['exported'])
        SourceIso       = [string]$(if ($values.ContainsKey('source_iso')) { $values['source_iso'] } else { '' })
    }
}

function Save-WinISOBuildCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Stages = @(),
        [int[]]$IndexesServiced = @(),
        [switch]$MediaReady,
        [switch]$Exported,
        [string]$SourceIso = '',
        [string]$Stage = ''
    )
    $values = @{
        updated_utc      = [DateTime]::UtcNow.ToString('o')
        stages           = @($Stages)
        indexes_serviced = @($IndexesServiced)
        media_ready      = [bool]$MediaReady
        exported         = [bool]$Exported
        source_iso       = $SourceIso
        pid              = $PID
        stage            = $Stage
    }
    [void](Write-WinISOJsonHashtable -Path $Path -Values $values)
    return $Path
}

function Get-WinISOBuildLock {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $values = Read-WinISOJsonHashtable -Path $Path
    $pidValue = 0
    if ($values.ContainsKey('pid')) { $pidValue = [int]$values['pid'] }
    $alive = $false
    if ($pidValue -gt 0) {
        try { $null = Get-Process -Id $pidValue -ErrorAction Stop; $alive = $true } catch { $alive = $false }
    }
    return [pscustomobject]@{
        Path      = $Path
        Pid       = $pidValue
        Alive     = $alive
        Started   = [string]$(if ($values.ContainsKey('started_utc')) { $values['started_utc'] } else { '' })
        Workspace = [string]$(if ($values.ContainsKey('workspace')) { $values['workspace'] } else { '' })
        Stage     = [string]$(if ($values.ContainsKey('stage')) { $values['stage'] } else { '' })
    }
}

function New-WinISOBuildLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Workspace,
        [int]$ProcessId = $PID
    )
    $values = @{
        pid         = $ProcessId
        started_utc = [DateTime]::UtcNow.ToString('o')
        workspace   = $Workspace
        stage       = 'starting'
        host_name   = [string]$env:COMPUTERNAME
    }
    [void](Write-WinISOJsonHashtable -Path $Path -Values $values)
    return $Path
}

function Remove-WinISOBuildLock {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    return (-not (Test-Path -LiteralPath $Path))
}

# Appends this run to Reports\RUN-HISTORY.json, newest last, capped so the file
# stays small enough to read.
function Add-WinISORunHistory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Run,
        [int]$Maximum = 100
    )
    $entries = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($doc -and $doc.PSObject.Properties['runs']) { $entries = @($doc.runs) }
        }
        catch { $entries = @() }
    }
    $entries += [pscustomobject]$Run
    if ($entries.Count -gt $Maximum) { $entries = @($entries[($entries.Count - $Maximum)..($entries.Count - 1)]) }
    $doc = [ordered]@{
        updated_utc = [DateTime]::UtcNow.ToString('o')
        count       = $entries.Count
        runs        = @($entries)
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return @($entries)
}

function Format-WinISORunHistoryTable {
    param([object[]]$Entries = @())
    $lines = @()
    if (@($Entries).Count -eq 0) { return $lines }
    $lines += 'date                 build      edition          iso GB  minutes  outcome'
    foreach ($e in @($Entries)) {
        $date = ''
        try { $date = ([datetime]$e.built_utc).ToString('yyyy-MM-dd HH:mm') } catch { $date = [string]$e.built_utc }
        $level = [string]$e.build + '.' + [string]$e.revision
        $lines += ($date.PadRight(20) + ' ' + $level.PadRight(10) + ' ' + ([string]$e.edition).PadRight(16) + ' ' + ([string]$e.iso_gb).PadRight(7) + ' ' + ([string]$e.elapsed_minutes).PadRight(8) + ' ' + [string]$e.outcome)
    }
    return $lines
}

# ---------------------------------------------------------------------------
# Retention planning
# ---------------------------------------------------------------------------

# Plans which output ISOs and logs a prune would remove. Returns objects with
# the size so the caller can report the reclaimable space before deleting.
function Get-WinISOPrunePlan {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [int]$KeepBuilds = 0,
        [int]$PruneLogsDays = 0,
        [datetime]$Now = (Get-Date)
    )
    $plan = @()
    $ws = [System.IO.Path]::GetFullPath($Workspace)
    if ($KeepBuilds -gt 0) {
        $outDir = Join-Path $ws 'Output'
        if (Test-Path -LiteralPath $outDir) {
            $isos = @(Get-ChildItem -LiteralPath $outDir -Filter *.iso -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            $i = 0
            foreach ($iso in $isos) {
                $i++
                if ($i -le $KeepBuilds) { continue }
                $plan += [pscustomobject]@{
                    Kind   = 'iso'
                    Path   = $iso.FullName
                    Bytes  = [long]$iso.Length
                    Reason = ('older than the ' + $KeepBuilds + ' build(s) to keep')
                }
            }
        }
    }
    if ($PruneLogsDays -gt 0) {
        $cutoff = $Now.AddDays(-1 * $PruneLogsDays)
        foreach ($dirName in @('Logs')) {
            $dir = Join-Path $ws $dirName
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue)) {
                if ($f.LastWriteTime -lt $cutoff) {
                    $plan += [pscustomobject]@{
                        Kind   = 'log'
                        Path   = $f.FullName
                        Bytes  = [long]$f.Length
                        Reason = ('last written ' + $f.LastWriteTime.ToString('yyyy-MM-dd') + ', older than ' + $PruneLogsDays + ' day(s)')
                    }
                }
            }
        }
    }
    return @($plan)
}

# Measured usage of the folders this toolchain fills, for Reports\SPACE-USAGE.json.
function Get-WinISOArtifactUsage {
    param([Parameter(Mandatory)][string]$Workspace)
    $ws = [System.IO.Path]::GetFullPath($Workspace)
    $rows = @()
    foreach ($name in @('Output', 'Updates', 'Logs', 'Work', 'Reports', 'State', 'Backup', 'ExtractedISO')) {
        $dir = Join-Path $ws $name
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $bytes = [long]0
        $count = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $bytes += [long]$f.Length
            $count++
        }
        $rows += [pscustomobject]@{ Folder = $name; Files = $count; Bytes = $bytes; GB = [math]::Round($bytes / 1GB, 2) }
    }
    return [pscustomobject]@{
        generated_utc = [DateTime]::UtcNow.ToString('o')
        workspace     = $ws
        folders       = @($rows)
    }
}

Export-ModuleMember -Function *
