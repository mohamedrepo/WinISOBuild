# WinISOService.psm1
# Windows 10/11 offline ISO servicing toolchain - shared module.
# Implements the 10 servicing phases as functions that each return a
# structured result object, plus shared helpers (state persistence, logging,
# DISM wrappers, host/ADK/source discovery, output parsing).
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7 (no PS7-only syntax).
# Encoding      : BOM-less UTF-8, ASCII-only content.
#
# SAFETY MODEL (full detail in README.md):
#   - Read-only phases never modify the source ISO.
#   - Servicing works on a copy of install.wim under ExtractedISO\; the
#     original ISO/WIM is never written to.
#   - Every DISM mount is wrapped in try/finally; on any failure the image is
#     unmounted with /Discard so nothing is ever left mounted.
#   - Nothing is removed and no update is force-installed without explicit
#     authorization. Unknown DISM error codes are recorded verbatim, never
#     retried blindly.
#   - No KB/build/edition/index/architecture/language is ever guessed; every
#     value comes from the source media, the catalog response, or an explicit
#     parameter.

#requires -Version 5.1

Set-StrictMode -Version 1

# ---------------------------------------------------------------------------
# Module-scope data
# ---------------------------------------------------------------------------

$script:DefaultWorkspace = 'D:\WimMount'

$script:WorkspaceDirs = @(
    'Source', 'ExtractedISO', 'Mount', 'Updates', 'Drivers', 'Scripts',
    'Logs', 'Output', 'Backup', 'Reports', 'State'
)

$script:StateFileName = 'STATE.json'

# Curated DISM/CBS error classification (per Microsoft DISM/CBS documentation).
# Unknown codes are recorded verbatim and never forced.
$script:DismErrorMap = @{
    '0x80070002' = @{ Class = 'FileNotFound';            Description = 'The system cannot find the file specified.';                                                        Action = 'Verify the package path and file existence.' }
    '0x80070005' = @{ Class = 'AccessDenied';            Description = 'Access is denied.';                                                                                Action = 'Run from an elevated PowerShell and check file/folder ACLs.' }
    '0x80070020' = @{ Class = 'SharingViolation';        Description = 'The process cannot access the file because it is being used by another process.';                    Action = 'Close any process holding the image (editors, viewers, stale mounts) and retry.' }
    '0x80070032' = @{ Class = 'NotSupported';            Description = 'The request is not supported (e.g. wrong architecture or version).';                                 Action = 'Verify package architecture and applicability against the image; do not force.' }
    '0x80070070' = @{ Class = 'DiskFull';                Description = 'There is not enough space on the disk.';                                                             Action = 'Free space on the workspace drive (see Phase 1 audit for the measured free space).' }
    '0x800f081f' = @{ Class = 'AlreadyInstalledOrNotApplicable'; Description = 'CBS_E_NOT_APPLICABLE: package is not applicable or is already installed in the image.';      Action = 'Verify with /Get-Packages; treat as benign when the package is already present.' }
    '0x800f0823' = @{ Class = 'MissingPrerequisite';     Description = 'CBS_E_NEW_SERVICING_STACK_REQUIRED: a newer servicing stack must be installed first.';                Action = 'Integrate the latest Servicing Stack Update first, then retry the package.' }
    '0x800f082f' = @{ Class = 'IllegalComponentUpdate';  Description = 'CBS_E_ILLEGAL_COMPONENT_UPDATE: the package cannot be applied to the image in its current state.';    Action = 'Package is incompatible or obsolete for this image; do not force.' }
    '0x800f0830' = @{ Class = 'ImageNotServiceable';     Description = 'CBS_E_IMAGE_NOT_SERVICEABLE: the image cannot be serviced.';                                          Action = 'Check for a damaged WIM; restore the pre-servicing copy from Backup\ and re-run.' }
    '0x800f0982' = @{ Class = 'ComponentStoreCorrupt';   Description = 'CBS_E_COMPONENT_STORE_CORRUPT: component store corruption detected.';                                 Action = 'Run /Cleanup-Image /CheckHealth then /ScanHealth on the mounted image and repair before retrying.' }
    '0x800f0988' = @{ Class = 'ServicingFailure';        Description = 'Update apply failure commonly tied to servicing-stack state (documented DISM failure code).';          Action = 'Verify SSU presence and package state with /Get-Packages; do not force.' }
}

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

function Get-WinISOFilePath {
    # Absolute path inside the workspace. Workspace itself is resolved to an
    # absolute path by the caller (phases use [System.IO.Path]::GetFullPath).
    param([string]$Workspace, [string]$Relative)
    return (Join-Path $Workspace $Relative)
}

function Write-WinISOFile {
    # Writes text as BOM-less UTF-8, creating the parent directory if needed.
    param([Parameter(Mandatory)][string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-WinISOJsonFile {
    param([Parameter(Mandatory)][string]$Path, [object]$Object)
    Write-WinISOFile -Path $Path -Content ($Object | ConvertTo-Json -Depth 10)
}

function Add-WinISOLogLine {
    # Appends a timestamped line to a phase/operation log.
    param([Parameter(Mandatory)][string]$Path, [string]$Line)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -LiteralPath $Path -Value ('[{0}] {1}' -f $stamp, $Line) -Encoding ASCII
}

function New-WinISOLogPath {
    # Creates a timestamped log file under Logs\ and returns its path.
    param([string]$Workspace, [string]$Tag)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $Workspace ('Logs\' + $Tag + '-' + $stamp + '.log')
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    Add-WinISOLogLine -Path $path -Line ('=== ' + $Tag + ' started ===')
    return $path
}

function Get-WinISOResult {
    # Standard structured result object returned by every phase function.
    # Status: Succeeded | Partial | Failed | Skipped.
    param([int]$Phase, [string]$Name)
    $result = [pscustomobject]@{
        Phase          = $Phase
        Name           = $Name
        Status         = 'Succeeded'
        Summary        = ''
        Reason         = ''
        Steps          = (New-Object 'System.Collections.Generic.List[string]')
        FailedSteps    = (New-Object 'System.Collections.Generic.List[string]')
        Artifacts      = [ordered]@{}
        Errors         = (New-Object 'System.Collections.Generic.List[string]')
        DurationSeconds = 0
    }
    return $result
}

function Test-WinISOAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WinISOWorkspaceDrive {
    param([string]$Workspace)
    $full = [System.IO.Path]::GetFullPath($Workspace)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -match '^[A-Za-z]:') { return $root.Substring(0, 2) }
    return $root
}

# ---------------------------------------------------------------------------
# Process / DISM invocation
# ---------------------------------------------------------------------------

function Invoke-WinISOProcess {
    # Runs an external executable, captures stdout+stderr, enforces a timeout,
    # and returns @{ ExitCode; Output; CommandLine; TimedOut }.
    # A timed-out or unstartable process reports ExitCode -1 (never a false 0).
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 3600,
        [string]$LogPath = ''
    )
    $argString = ($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
    }
    catch {
        $msg = ('Failed to start process: ' + $_.Exception.Message)
        if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line $msg }
        return [pscustomobject]@{ ExitCode = -1; Output = $msg; CommandLine = ($FilePath + ' ' + $argString); TimedOut = $false }
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        $timedOut = $true
    }
    else {
        $timedOut = $false
    }
    try { [void]$p.WaitForExit() } catch { }
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { }
    try { $stderr = $errTask.Result } catch { }
    $output = $stdout
    if ($stderr) { $output += "`r`n[STDERR]`r`n" + $stderr }
    $code = -1
    if (-not $timedOut) {
        try { $code = $p.ExitCode } catch { $code = -1 }
    }
    if ($LogPath) {
        Add-WinISOLogLine -Path $LogPath -Line ('CMD> ' + $FilePath + ' ' + $argString)
        Add-WinISOLogLine -Path $LogPath -Line $output
    }
    return [pscustomobject]@{
        ExitCode    = $code
        Output      = $output
        CommandLine = ($FilePath + ' ' + $argString)
        TimedOut    = $timedOut
    }
}

function Get-WinISODismPath {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\Dism.exe'),
        (Join-Path $env:SystemRoot 'Sysnative\Dism.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Get-Item -LiteralPath $c).FullName }
    }
    $cmd = Get-Command dism.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WinISODism {
    # Runs dism.exe with captured output, a timeout, and an optional log.
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 3600,
        [string]$LogPath = ''
    )
    $dism = Get-WinISODismPath
    if (-not $dism) {
        throw 'dism.exe not found under %SystemRoot%\System32. Windows Deployment Image Servicing and Management is unavailable on this host.'
    }
    return Invoke-WinISOProcess -FilePath $dism -ArgumentList $Arguments -TimeoutSeconds $TimeoutSeconds -LogPath $LogPath
}

function Get-WinISODismErrorClass {
    # Maps an exit code to a curated classification. Never guesses: anything
    # unrecognized is returned verbatim with a 'do not force' instruction.
    param([int]$ExitCode, [string]$Output = '')
    if ($ExitCode -eq 0) {
        return @{ Class = 'Success'; Description = 'Operation completed successfully.'; Action = ''; Hex = '0x0' }
    }
    $hex = '0x{0:X8}' -f ([System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$ExitCode), 0))
    if ($script:DismErrorMap.ContainsKey($hex)) {
        $entry = $script:DismErrorMap[$hex]
        return @{ Class = $entry.Class; Description = $entry.Description; Action = $entry.Action; Hex = $hex }
    }
    return @{
        Class       = 'Unclassified'
        Description = ('Unrecognized exit code ' + $hex)
        Action      = 'Record the code verbatim, inspect the DISM log, and do not force the operation.'
        Hex         = $hex
    }
}

# ---------------------------------------------------------------------------
# Host / toolchain discovery
# ---------------------------------------------------------------------------

function Get-WinISONetFrameworkVersion {
    $release = $null
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $release = $key.Release
    }
    catch {
        $release = $null
    }
    $v4 = 'unknown'
    if ($null -ne $release) {
        $map = @{
            378389 = '4.5'; 378675 = '4.5.1'; 378758 = '4.5.1'; 379893 = '4.5.2'
            393295 = '4.6'; 393297 = '4.6'; 394254 = '4.6.1'; 394271 = '4.6.1'
            394802 = '4.6.2'; 394806 = '4.6.2'; 460798 = '4.7'; 460805 = '4.7'
            461308 = '4.7.1'; 461310 = '4.7.1'; 461808 = '4.7.2'; 461814 = '4.7.2'
            528040 = '4.8'; 528049 = '4.8'; 528372 = '4.8'; 528449 = '4.8'
            533320 = '4.8.1'; 533325 = '4.8.1'; 533340 = '4.8.1'
        }
        if ($map.Contains([int]$release)) { $v4 = $map[[int]$release] }
        $v4 = $v4 + ' (release=' + $release + ')'
    }
    $v35 = 'absent'
    try {
        $k35 = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' -ErrorAction Stop
        if ($k35.Install -eq 1) { $v35 = 'enabled' }
    }
    catch {
        $v35 = 'absent'
    }
    return ('v4: ' + $v4 + ' | v3.5: ' + $v35)
}

function Find-WinISO7Zip {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { $paths.Add($cmd.Source) }
    foreach ($base in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($base -and (Test-Path -LiteralPath $base)) { $paths.Add($base) }
    }
    try {
        $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\7-Zip' -ErrorAction Stop
        if ($p.Path) {
            $c = Join-Path $p.Path '7z.exe'
            if (Test-Path -LiteralPath $c) { $paths.Add($c) }
        }
    }
    catch { }
    return @($paths | Select-Object -Unique)
}

function Get-WinISOAdkInfo {
    # Locates Windows Kits roots (registry + well-known paths) and probes for
    # Deployment Tools / oscdimg.exe / WinPE add-on. Returns structured data.
    $info = [ordered]@{
        KitsRoots             = @()
        DeploymentToolsRoots  = @()
        OscdimgCandidates     = @()
        WinPEPaths            = @()
    }
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        if (Test-Path -LiteralPath $key) {
            $p = Get-ItemProperty -LiteralPath $key
            foreach ($n in @('KitsRoot10', 'KitsRoot81')) {
                if ($null -ne $p.PSObject.Properties[$n] -and $p.$n) { $roots.Add([string]$p.$n) }
            }
        }
    }
    $pf = $env:ProgramFiles
    if (Test-Path -LiteralPath "${env:ProgramFiles(x86)}") { $pf = ${env:ProgramFiles(x86)} }
    $roots.Add((Join-Path $pf 'Windows Kits\10'))
    $roots.Add((Join-Path $pf 'Windows Kits\8.1'))
    foreach ($root in @($roots | Select-Object -Unique)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($arch in @('x86', 'amd64', 'arm64')) {
            $cand = Join-Path $root ('Assessment and Deployment Kit\Deployment Tools\' + $arch + '\OSCDIMG\oscdimg.exe')
            if (Test-Path -LiteralPath $cand) { $info.OscdimgCandidates += $cand }
        }
        $dt = Join-Path $root 'Assessment and Deployment Kit\Deployment Tools'
        if (Test-Path -LiteralPath $dt) { $info.DeploymentToolsRoots += $dt }
        $wp = Join-Path $root 'Assessment and Deployment Kit\Windows Preinstallation Environment'
        if (Test-Path -LiteralPath $wp) { $info.WinPEPaths += $wp }
    }
    $info.KitsRoots = @($roots | Select-Object -Unique)
    return [pscustomobject]$info
}

function Find-WinISOOscdimg {
    $adk = Get-WinISOAdkInfo
    if (@($adk.OscdimgCandidates).Count -gt 0) { return @($adk.OscdimgCandidates)[0] }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-WinISOSourceIso {
    # Detection only - Source\*.iso/.wim/.esd plus the explicit -SourceIso
    # parameter. Never scans unrelated directories.
    param([string]$Workspace, [string]$SourceIso = '')
    $found = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
    if ($SourceIso) {
        if (Test-Path -LiteralPath $SourceIso -PathType Leaf) {
            $found.Add((Get-Item -LiteralPath $SourceIso))
        }
    }
    $srcDir = Join-Path $Workspace 'Source'
    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        foreach ($ext in @('*.iso', '*.wim', '*.esd')) {
            Get-ChildItem -LiteralPath $srcDir -Filter $ext -File -ErrorAction SilentlyContinue | ForEach-Object { $found.Add($_) }
        }
    }
    return @($found)
}

# ---------------------------------------------------------------------------
# DISM text-output parsing (never assumes fields the tool did not print)
# ---------------------------------------------------------------------------

function Parse-WinISODismSections {
    # Parses 'Key : Value' and '<KEY>value</KEY>' style DISM output into
    # per-section objects. Sections start at 'Index :', 'Details for image :'
    # or '<IMAGE INDEX="N">' lines.
    param([Parameter(Mandatory)][string]$Text)
    $blocks = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
    $cur = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(Index|Details for image|Image details)\s*:\s*(.+?)\s*$') {
            if ($null -ne $cur) { $blocks.Add([pscustomobject]$cur) }
            $cur = [ordered]@{ __Section__ = $Matches[1]; __Value__ = $Matches[2].Trim() }
        }
        elseif ($line -match '^\s*<IMAGE INDEX="(\d+)"') {
            if ($null -ne $cur) { $blocks.Add([pscustomobject]$cur) }
            $cur = [ordered]@{ __Section__ = 'Index'; __Value__ = $Matches[1] }
        }
        elseif ($null -ne $cur) {
            if ($line -match '^\s*([^:<]+?)\s*:\s*(.*?)\s*$') {
                $cur[$Matches[1].Trim()] = $Matches[2].Trim()
            }
            elseif ($line -match '^\s*<([A-Za-z_]+)>([^<]*)</\1>\s*$') {
                $cur[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    if ($null -ne $cur) { $blocks.Add([pscustomobject]$cur) }
    return @($blocks)
}

function Get-WinISOWimInfo {
    # Runs 'dism /English /Get-WimInfo' and returns structured index objects.
    param([string]$WimPath, [string]$LogPath = '')
    $d = Invoke-WinISODism -Arguments @('/English', '/Get-WimInfo', ('/WimFile:' + $WimPath)) -TimeoutSeconds 900 -LogPath $LogPath
    if ($d.ExitCode -ne 0) {
        return @{ ExitCode = $d.ExitCode; Output = $d.Output; Indexes = @() }
    }
    $blocks = Parse-WinISODismSections -Text $d.Output
    $indexes = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
    $currentFile = ''
    foreach ($b in $blocks) {
        if ($b.__Section__ -match 'Details for image|Image details') { $currentFile = [string]$b.__Value__ }
        if ($b.__Section__ -ne 'Index') { continue }
        $sizeBytes = [long]0
        $sizeRaw = [string]($b.'Size')
        if ($sizeRaw -match '([\d,]+)') { $sizeBytes = [long]($Matches[1] -replace ',', '') }
        $versionRaw = [string]($b.'Version')
        $build = 0
        $revision = 0
        if ($versionRaw -match '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?') {
            $build = [int]$Matches[3]
            if ($Matches[4]) { $revision = [int]$Matches[4] }
        }
        $indexes.Add([pscustomobject]@{
            Index             = [int]($b.__Value__)
            WimFile           = $currentFile
            Name              = [string]($b.'Name')
            Description       = [string]($b.'Description')
            DisplayName       = [string]($b.'DisplayName')
            DisplayDescription = [string]($b.'DisplayDescription')
            EditionId         = [string]($b.'Edition')
            Architecture      = [string]($b.'Architecture')
            Version           = $versionRaw
            Build             = $build
            Revision          = $revision
            ServicePackBuild  = [string]($b.'ServicePack Build')
            ServicePackLevel  = [string]($b.'ServicePack Level')
            Language          = [string]($b.'Languages')
            Flags             = [string]($b.'Flags')
            WimBoot           = [string]($b.'WIM Bootable')
            InstallationType  = [string]($b.'Installation')
            ProductType       = [string]($b.'ProductType')
            SizeBytes         = $sizeBytes
        })
    }
    # Enrich all indexes with WIM-wide metadata from a single /Get-ImageInfo read.
    $gi = Invoke-WinISODism -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $WimPath), '/Index:1') -TimeoutSeconds 900 -LogPath $LogPath
    if ($gi.ExitCode -eq 0) {
        $gblocks = Parse-WinISODismSections -Text $gi.Output
        $gidx = $gblocks | Where-Object { $_.__Section__ -eq 'Index' } | Select-Object -First 1
        if ($gidx) {
            $wimVersion = [string]($gidx.'Version')
            $wimArch = [string]($gidx.'Architecture')
            $wimSpBuild = [string]($gidx.'ServicePack Build')
            $wimSpLevel = [string]($gidx.'ServicePack Level')
            $wimProductType = [string]($gidx.'ProductType')
            $wimInstallation = [string]($gidx.'Installation')
            $wimLanguages = [string]($gidx.'Languages')
            $wimBuild = 0; $wimRevision = 0
            if ($wimVersion -match '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?') {
                $wimBuild = [int]$Matches[3]
                if ($Matches[4]) { $wimRevision = [int]$Matches[4] }
            }
            if ($wimRevision -eq 0 -and $wimSpBuild -match '^(\d+)$') { $wimRevision = [int]$Matches[1] }
            foreach ($ix in $indexes) {
                $ix.Version = $wimVersion
                $ix.Architecture = $wimArch
                $ix.Build = $wimBuild
                $ix.Revision = $wimRevision
                $ix.ServicePackBuild = $wimSpBuild
                $ix.ServicePackLevel = $wimSpLevel
                $ix.ProductType = $wimProductType
                $ix.InstallationType = $wimInstallation
                $ix.Language = $wimLanguages
            }
        }
    }
    return @{ ExitCode = 0; Output = $d.Output; Indexes = @($indexes) }
}

# ---------------------------------------------------------------------------
# State persistence (STATE.json - exact schema: phase, status,
# completed_steps, failed_steps, artifacts, errors, next_action)
# ---------------------------------------------------------------------------

function Get-WinISOStatePath {
    param([string]$Workspace = $script:DefaultWorkspace)
    return (Join-Path $Workspace ('State\' + $script:StateFileName))
}

function Initialize-WinISOState {
    # Creates the initial STATE.json if absent. Never overwrites an existing
    # state file (restartability depends on it).
    param([string]$Workspace = $script:DefaultWorkspace)
    $path = Get-WinISOStatePath -Workspace $Workspace
    if (Test-Path -LiteralPath $path) {
        return Read-WinISOState -Workspace $Workspace
    }
    $state = [ordered]@{
        phase           = 0
        status          = 'idle'
        completed_steps = @()
        failed_steps    = @()
        artifacts       = @{}
        errors          = @()
        next_action     = 'Phase 1 (environment audit) has not been run yet. Run Scripts\Invoke-WinISOService.ps1 -TargetPhase 1.'
    }
    Save-WinISOState -Workspace $Workspace -State $state
    return $state
}

function Save-WinISOState {
    param([string]$Workspace = $script:DefaultWorkspace, [Parameter(Mandatory)][object]$State)
    $normalized = [ordered]@{
        phase           = [int]($State.phase)
        status          = [string]($State.status)
        completed_steps = @($State.completed_steps)
        failed_steps    = @($State.failed_steps)
        artifacts       = $State.artifacts
        errors          = @($State.errors)
        next_action     = [string]($State.next_action)
    }
    Write-WinISOJsonFile -Path (Get-WinISOStatePath -Workspace $Workspace) -Object $normalized
}

function Read-WinISOState {
    param([string]$Workspace = $script:DefaultWorkspace)
    $path = Get-WinISOStatePath -Workspace $Workspace
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# PHASE 1 - Environment audit (read-only, fail-fast gates)
# ---------------------------------------------------------------------------

function Invoke-WinISOEnvironmentAudit {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [int]$MinimumFreeGB = 25,
        [switch]$AllowUnoelevated
    )
    $r = Get-WinISOResult -Phase 1 -Name 'Environment audit'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase1-EnvironmentAudit'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        Add-WinISOLogLine -Path $log -Line ('Workspace: ' + $full)
        $audit = [ordered]@{}

        # Host identity
        $audit.TimestampUtc = [DateTime]::UtcNow.ToString('o')
        $audit.HostName = [string]$env:COMPUTERNAME
        $audit.User = ([Environment]::UserDomainName + '\' + [Environment]::UserName)

        # Operating system
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $audit.OsCaption = [string]$os.Caption
        $audit.OsVersion = [string]$os.Version
        $audit.OsBuildNumber = [string]$os.BuildNumber
        $audit.OsArchitecture = [string]$os.OSArchitecture
        $ubr = ''
        try {
            $ubr = [string]((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).UBR)
        }
        catch { $ubr = '' }
        $audit.OsUbr = $ubr

        # Privilege (fail-fast gate per spec)
        $audit.IsAdministrator = Test-WinISOAdmin

        # CPU
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $audit.CpuName = [string]$cpu.Name
        $audit.CpuCores = [int]$cpu.NumberOfCores
        $audit.CpuLogicalProcessors = [int]$cpu.NumberOfLogicalProcessors
        $audit.ProcessArchitecture = [string]$env:PROCESSOR_ARCHITECTURE

        # Memory
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $audit.RamGB = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 2)

        # Fixed disks (work/output drives)
        $disks = @()
        foreach ($d in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
            $disks += [pscustomobject]@{
                DeviceId   = [string]$d.DeviceID
                VolumeName = [string]$d.VolumeName
                SizeGB     = [math]::Round([double]$d.Size / 1GB, 2)
                FreeGB     = [math]::Round([double]$d.FreeSpace / 1GB, 2)
            }
        }
        $audit.Disks = $disks
        $wsDrive = Get-WinISOWorkspaceDrive -Workspace $full
        $wsDisk = $disks | Where-Object { $_.DeviceId -eq $wsDrive } | Select-Object -First 1
        $audit.WorkspaceDrive = $wsDrive
        $audit.WorkspaceDriveFreeGB = if ($wsDisk) { $wsDisk.FreeGB } else { 0 }
        $audit.MinimumFreeGB = $MinimumFreeGB
        $audit.RecommendedFreeGB = 25

        # DISM
        $dismPath = Get-WinISODismPath
        $audit.DismPath = [string]$dismPath
        $audit.DismVersion = ''
        if ($dismPath) {
            $audit.DismVersion = [string]((Get-Item -LiteralPath $dismPath).VersionInfo.FileVersion)
        }

        # ADK / Deployment Tools / oscdimg / WinPE
        $adk = Get-WinISOAdkInfo
        $audit.AdkKitsRoots = @($adk.KitsRoots)
        $audit.AdkDeploymentToolsRoots = @($adk.DeploymentToolsRoots)
        $audit.AdkOscdimgCandidates = @($adk.OscdimgCandidates)
        $audit.AdkWinPEPaths = @($adk.WinPEPaths)
        $audit.AdkAvailable = (@($adk.DeploymentToolsRoots).Count -gt 0)
        $audit.OscdimgAvailable = (@($adk.OscdimgCandidates).Count -gt 0)
        $audit.WinPEAvailable = (@($adk.WinPEPaths).Count -gt 0)

        # PowerShell
        $audit.PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        $audit.PowerShellEdition = [string]$PSVersionTable.PSEdition
        $audit.PowerShellClrVersion = $PSVersionTable.CLRVersion.ToString()
        $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $audit.Pwsh7Available = ($null -ne $pwshCmd)
        $audit.Pwsh7Path = if ($pwshCmd) { [string]$pwshCmd.Source } else { '' }

        # .NET
        $audit.DotNetFramework = Get-WinISONetFrameworkVersion
        $dotnetCli = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        $audit.DotNetCliAvailable = ($null -ne $dotnetCli)

        # 7-Zip
        $sevenZip = @(Find-WinISO7Zip)
        $audit.SevenZipAvailable = ($sevenZip.Count -gt 0)
        $audit.SevenZipPaths = @($sevenZip)

        # Existing working directories
        $dirStatus = [ordered]@{}
        foreach ($d in $script:WorkspaceDirs) {
            $dirStatus[$d] = (Test-Path -LiteralPath (Join-Path $full $d) -PathType Container)
        }
        $audit.WorkspaceDirectories = $dirStatus
        $audit.WorkspaceComplete = -not (@($dirStatus.Values) -contains $false)

        # Source ISO detection/validation (Source\ only + -SourceIso)
        $candidates = @(Find-WinISOSourceIso -Workspace $full -SourceIso $SourceIso)
        $audit.SourceIsoCandidates = @($candidates | ForEach-Object { [string]$_.FullName })
        $audit.SourceIsoFound = ($candidates.Count -gt 0)

        # Gates (fail-fast per spec: elevation + disk space)
        $gateErrors = New-Object 'System.Collections.Generic.List[string]'
        if (-not $audit.IsAdministrator) {
            if ($AllowUnoelevated) {
                $audit.ElevationOverride = 'AllowUnoelevated was specified: the read-only audit proceeds, but every mutation phase still requires elevation.'
                Add-WinISOLogLine -Path $log -Line 'WARNING: not elevated; proceeding because -AllowUnoelevated was specified (read-only audit only).'
            }
            else {
                $gateErrors.Add('Not elevated. Run from an elevated PowerShell session (Administrator). All servicing phases require elevation.')
            }
        }
        if ($audit.WorkspaceDriveFreeGB -lt $MinimumFreeGB) {
            $gateErrors.Add(('Insufficient free space on workspace drive ' + $wsDrive + ': ' + $audit.WorkspaceDriveFreeGB + ' GB free, minimum configured is ' + $MinimumFreeGB + ' GB.'))
        }
        if ($audit.WorkspaceDriveFreeGB -lt $audit.RecommendedFreeGB) {
            $audit.AdvisoryFreeSpace = ('Advisory: ' + $audit.WorkspaceDriveFreeGB + ' GB free on ' + $wsDrive + ' is below the 25 GB recommended for full servicing (extract + mount + updated WIM + rebuilt ISO).')
        }
        else {
            $audit.AdvisoryFreeSpace = 'Free space meets the 25 GB servicing recommendation.'
        }
        $audit.GateErrors = @($gateErrors)

        # Write reports
        $txtPath = Join-Path $full 'Reports\ENV-AUDIT.txt'
        $jsonPath = Join-Path $full 'Reports\ENV-AUDIT.json'
        Write-WinISOFile -Path $txtPath -Content (Format-WinISOAuditText -Audit $audit)
        Write-WinISOJsonFile -Path $jsonPath -Object $audit
        $r.Artifacts['env-audit.txt'] = $txtPath
        $r.Artifacts['env-audit.json'] = $jsonPath
        $r.Steps.Add('Collected host, OS, privilege, CPU, RAM, disk, DISM, ADK, WinPE, oscdimg, PowerShell, .NET, 7-Zip, workspace and source-ISO data.')
        $r.Steps.Add('Wrote ' + $txtPath + ' and ' + $jsonPath)
        Add-WinISOLogLine -Path $log -Line ('Workspace drive ' + $wsDrive + ' free: ' + $audit.WorkspaceDriveFreeGB + ' GB (configured minimum ' + $MinimumFreeGB + ' GB)')

        if ($gateErrors.Count -gt 0) {
            $r.Status = 'Failed'
            $r.Summary = 'Environment audit completed but FAILED gate checks: ' + ($gateErrors -join ' | ')
            foreach ($g in $gateErrors) {
                $r.Errors.Add([string]$g)
                $r.FailedSteps.Add([string]$g)
                Add-WinISOLogLine -Path $log -Line ('GATE FAIL: ' + $g)
            }
        }
        else {
            $r.Status = 'Succeeded'
            $r.Summary = ('Environment audit succeeded. Workspace ' + $full + '; ' + $audit.WorkspaceDriveFreeGB + ' GB free on ' + $wsDrive + '; elevated=' + $audit.IsAdministrator + '; source ISO found=' + $audit.SourceIsoFound + '.')
        }
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Add-WinISOLogLine -Path $log -Line ('Phase 1 finished with status: ' + $r.Status)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.FailedSteps.Add($msg)
        $r.Summary = 'Environment audit threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

function Format-WinISOAuditText {
    param([object]$Audit)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('WINDOWS ISO SERVICING TOOLCHAIN - ENVIRONMENT AUDIT')
    [void]$sb.AppendLine('Generated (UTC): ' + [string]$Audit.TimestampUtc)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[HOST]')
    [void]$sb.AppendLine('  Host name        : ' + [string]$Audit.HostName)
    [void]$sb.AppendLine('  User             : ' + [string]$Audit.User)
    $osStr = [string]$Audit.OsCaption + ' (' + [string]$Audit.OsVersion + ', build ' + [string]$Audit.OsBuildNumber
    if ($Audit.OsUbr) { $osStr += '.' + [string]$Audit.OsUbr }
    $osStr += ')'
    [void]$sb.AppendLine('  OS               : ' + $osStr)
    [void]$sb.AppendLine('  OS architecture  : ' + [string]$Audit.OsArchitecture)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[PRIVILEGE]')
    [void]$sb.AppendLine('  Administrator    : ' + [string]$Audit.IsAdministrator)
    if ($Audit.PSObject.Properties['ElevationOverride']) {
        [void]$sb.AppendLine('  Override         : ' + [string]$Audit.ElevationOverride)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[CPU]')
    [void]$sb.AppendLine('  Processor        : ' + [string]$Audit.CpuName)
    [void]$sb.AppendLine('  Cores            : ' + [string]$Audit.CpuCores)
    [void]$sb.AppendLine('  Logical CPUs     : ' + [string]$Audit.CpuLogicalProcessors)
    [void]$sb.AppendLine('  Process arch     : ' + [string]$Audit.ProcessArchitecture)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[MEMORY]')
    [void]$sb.AppendLine('  Total RAM        : ' + [string]$Audit.RamGB + ' GB')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[FIXED DISKS]')
    foreach ($d in @($Audit.Disks)) {
        [void]$sb.AppendLine('  ' + [string]$d.DeviceId + '  size=' + [string]$d.SizeGB + ' GB  free=' + [string]$d.FreeGB + ' GB  volume=' + [string]$d.VolumeName)
    }
    [void]$sb.AppendLine('  Workspace drive  : ' + [string]$Audit.WorkspaceDrive + '  free=' + [string]$Audit.WorkspaceDriveFreeGB + ' GB')
    [void]$sb.AppendLine('  Configured min   : ' + [string]$Audit.MinimumFreeGB + ' GB (fail-fast gate)')
    [void]$sb.AppendLine('  Recommended      : ' + [string]$Audit.RecommendedFreeGB + ' GB')
    [void]$sb.AppendLine('  Advisory         : ' + [string]$Audit.AdvisoryFreeSpace)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[DISM]')
    [void]$sb.AppendLine('  Path             : ' + [string]$Audit.DismPath)
    [void]$sb.AppendLine('  Version          : ' + [string]$Audit.DismVersion)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[ADK / DEPLOYMENT TOOLS]')
    [void]$sb.AppendLine('  ADK available    : ' + [string]$Audit.AdkAvailable)
    [void]$sb.AppendLine('  Kits roots       : ' + (@($Audit.AdkKitsRoots) -join '; '))
    [void]$sb.AppendLine('  Deployment tools : ' + (@($Audit.AdkDeploymentToolsRoots) -join '; '))
    [void]$sb.AppendLine('  oscdimg.exe      : ' + $(if ($Audit.OscdimgAvailable) { 'FOUND - ' + (@($Audit.AdkOscdimgCandidates) -join '; ') } else { 'NOT FOUND (install Windows ADK Deployment Tools before Phase 7)' }))
    [void]$sb.AppendLine('  WinPE add-on     : ' + $(if ($Audit.WinPEAvailable) { 'FOUND - ' + (@($Audit.AdkWinPEPaths) -join '; ') } else { 'NOT FOUND' }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[POWERSHELL]')
    [void]$sb.AppendLine('  Version          : ' + [string]$Audit.PowerShellVersion + ' (' + [string]$Audit.PowerShellEdition + ')')
    [void]$sb.AppendLine('  CLR              : ' + [string]$Audit.PowerShellClrVersion)
    [void]$sb.AppendLine('  pwsh 7           : ' + $(if ($Audit.Pwsh7Available) { [string]$Audit.Pwsh7Path } else { 'NOT FOUND' }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[.NET]')
    [void]$sb.AppendLine('  .NET Framework   : ' + [string]$Audit.DotNetFramework)
    [void]$sb.AppendLine('  dotnet CLI       : ' + $(if ($Audit.DotNetCliAvailable) { 'present' } else { 'absent' }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[7-ZIP]')
    [void]$sb.AppendLine('  Available        : ' + [string]$Audit.SevenZipAvailable)
    [void]$sb.AppendLine('  Paths            : ' + (@($Audit.SevenZipPaths) -join '; '))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[WORKSPACE DIRECTORIES]')
    foreach ($k in @($Audit.WorkspaceDirectories.Keys)) {
        [void]$sb.AppendLine('  ' + $k.PadRight(14) + ': ' + $(if ($Audit.WorkspaceDirectories[$k]) { 'PRESENT' } else { 'MISSING' }))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[SOURCE ISO DETECTION]')
    if ($Audit.SourceIsoFound) {
        foreach ($c in @($Audit.SourceIsoCandidates)) { [void]$sb.AppendLine('  FOUND: ' + $c) }
    }
    else {
        [void]$sb.AppendLine('  No source ISO/WIM/ESD found in Source\ and no -SourceIso parameter provided.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[GATE RESULTS]')
    if (@($Audit.GateErrors).Count -gt 0) {
        foreach ($g in @($Audit.GateErrors)) { [void]$sb.AppendLine('  FAIL: ' + $g) }
    }
    else {
        [void]$sb.AppendLine('  PASS: elevated and workspace drive free space above the configured minimum.')
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# PHASE 2 - ISO inspection (read-only metadata)
# ---------------------------------------------------------------------------

function Invoke-WinISOInspectSource {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [switch]$SkipHash
    )
    $r = Get-WinISOResult -Phase 2 -Name 'ISO inspection'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase2-IsoInspection'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $candidates = @(Find-WinISOSourceIso -Workspace $full -SourceIso $SourceIso)
        if ($candidates.Count -eq 0) {
            $r.Status = 'Skipped'
            $r.Reason = 'No source ISO/WIM/ESD found in Source\ and no -SourceIso parameter was provided. Place a source ISO in ' + (Join-Path $full 'Source') + ' and re-run.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $source = $candidates[0]
        Add-WinISOLogLine -Path $log -Line ('Source: ' + $source.FullName)
        $r.Steps.Add('Source: ' + $source.FullName)

        # Attach ISO read-only (never modified) or use the WIM/ESD directly.
        $attach = $null
        $letter = ''
        $srcRoot = ''
        if ($source.Extension -eq '.iso') {
            $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            try { $attach = Mount-DiskImage -ImagePath $source.FullName -PassThru -ErrorAction Stop } catch { $attach = $null }
            if ($null -ne $attach) {
                $after = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
                $newLetters = @($after | Where-Object { $before -notcontains $_ })
                foreach ($l in $newLetters) {
                    if (Test-Path -LiteralPath ($l + ':\sources\boot.wim')) { $letter = $l; break }
                }
                if (-not $letter -and $newLetters.Count -gt 0) { $letter = $newLetters[0] }
            }
            if (-not $letter) {
                $r.Status = 'Failed'
                $r.Errors.Add('Could not attach the ISO read-only (elevation or driver issue). No fallback extractor was available for metadata reading.')
                $r.Summary = 'ISO attach failed.'
                Add-WinISOLogLine -Path $log -Line ('ISO attach failed')
                return $r
            }
            $srcRoot = $letter + ':\'
            $r.Steps.Add('Attached ISO read-only at ' + $srcRoot)
        }
        else {
            $srcRoot = [string](Split-Path -Parent $source.FullName)
        }

        # Locate boot.wim and install.wim/esd - never assumed.
        $bootWim = $null
        $installWim = $null
        if (Test-Path -LiteralPath (Join-Path $srcRoot 'sources\boot.wim')) { $bootWim = Join-Path $srcRoot 'sources\boot.wim' }
        foreach ($n in @('install.wim', 'install.esd')) {
            if (Test-Path -LiteralPath (Join-Path $srcRoot ('sources\' + $n))) { $installWim = Join-Path $srcRoot ('sources\' + $n); break }
        }
        if (-not $installWim -and $source.Extension -ne '.iso') { $installWim = $source.FullName }
        if (-not $installWim) {
            $r.Status = 'Failed'
            $r.Errors.Add('No install.wim/install.esd found under sources\ of the source media.')
            $r.Summary = 'No install image found.'
            return $r
        }

        # Hash the source file (unless skipped) for later source-vs-output comparison.
        $sha256 = ''
        if (-not $SkipHash) {
            Add-WinISOLogLine -Path $log -Line ('Hashing source file (this can take minutes for a large ISO)...')
            $sha256 = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
            Add-WinISOLogLine -Path $log -Line ('SHA-256: ' + $sha256)
        }

        # WIM metadata (indexes, editions, builds, arch, language - all detected).
        $installInfo = Get-WinISOWimInfo -WimPath $installWim -LogPath $log
        if ($installInfo.ExitCode -ne 0) {
            $r.Status = 'Failed'
            $r.Errors.Add('dism /Get-WimInfo failed for ' + $installWim + ': ' + $installInfo.Output)
            $r.Summary = 'WIM metadata read failed.'
            return $r
        }
        # Secondary read via /Get-ImageInfo to capture languages/flags when present.
        $imageInfo = Invoke-WinISODism -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $installWim)) -TimeoutSeconds 900 -LogPath $log
        $imageBlocks = @()
        if ($imageInfo.ExitCode -eq 0) { $imageBlocks = @(Parse-WinISODismSections -Text $imageInfo.Output) }

        $images = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        foreach ($ix in @($installInfo.Indexes)) {
            $lang = [string]$ix.Language
            $flags = [string]$ix.Flags
            $edition = [string]$ix.EditionId
            if ($imageBlocks.Count -gt 0) {
                $extra = $imageBlocks | Where-Object { $_.__Section__ -eq 'Index' -and [string]$_.__Value__ -eq [string]$ix.Index } | Select-Object -First 1
                if ($extra) {
                    if (-not $lang -and $extra.Language) { $lang = [string]$extra.Language }
                    if (-not $flags -and $extra.Flags) { $flags = [string]$extra.Flags }
                    if (-not $edition -and $extra.'Edition') { $edition = [string]$extra.'Edition' }
                }
            }
            $images.Add([pscustomobject]@{
                index            = [int]$ix.Index
                name             = [string]$ix.Name
                description      = [string]$ix.Description
                edition_id       = $edition
                architecture     = [string]$ix.Architecture
                version          = [string]$ix.Version
                build            = [int]$ix.Build
                revision         = [int]$ix.Revision
                language         = $lang
                flags            = $flags
                installation_type = [string]$ix.InstallationType
                product_type     = [string]$ix.ProductType
                size_bytes       = [long]$ix.SizeBytes
            })
        }
        if ($images.Count -eq 0) {
            $r.Status = 'Failed'
            $r.Errors.Add('No image indexes were parsed from ' + $installWim + '.')
            $r.Summary = 'No image indexes parsed.'
            return $r
        }

        $bootInfo = $null
        $bootImages = @()
        if ($bootWim) {
            $bootInfo = Get-WinISOWimInfo -WimPath $bootWim -LogPath $log
            if ($bootInfo.ExitCode -eq 0) {
                $bootImages = @($bootInfo.Indexes | ForEach-Object {
                    [pscustomobject]@{ index = [int]$_.Index; name = [string]$_.Name; build = [int]$_.Build; revision = [int]$_.Revision; architecture = [string]$_.Architecture }
                })
            }
        }

        # Detected aggregates (unique, order-preserving)
        $editions = @($images | ForEach-Object { [string]$_.edition_id } | Where-Object { $_ } | Select-Object -Unique)
        $builds = @($images | ForEach-Object { [int]$_.build } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        $archs = @($images | ForEach-Object { [string]$_.architecture } | Where-Object { $_ } | Select-Object -Unique)
        $langs = @($images | ForEach-Object { [string]$_.language } | Where-Object { $_ } | Select-Object -Unique)
        $product = ''
        if ($images.Count -gt 0) {
            $firstName = [string]$images[0].name
            if ($firstName -match 'Windows 11') { $product = 'Windows 11' }
            elseif ($firstName -match 'Windows 10') { $product = 'Windows 10' }
            elseif ($firstName -match 'Windows Server') { $product = 'Windows Server' }
            else { $product = $firstName }
        }
        $build = if ($builds.Count -gt 0) { [int]$builds[0] } else { 0 }
        $arch = if ($archs.Count -gt 0) { [string]$archs[0] } else { '' }
        $lang = if ($langs.Count -gt 0) { [string]$langs[0] } else { '' }

        $inventory = [ordered]@{
            generated_utc = [DateTime]::UtcNow.ToString('o')
            source = [ordered]@{
                path       = $source.FullName
                kind       = if ($source.Extension -eq '.iso') { 'iso' } elseif ($source.Extension -eq '.esd') { 'esd' } else { 'wim' }
                size_bytes = [long]$source.Length
                sha256     = $sha256
            }
            detected = [ordered]@{
                product      = $product
                build        = $build
                revision     = $(if ($images.Count -gt 0) { [int]$images[0].revision } else { 0 })
                architecture = $arch
                language     = $lang
                editions     = @($editions)
                builds       = @($builds)
                architectures = @($archs)
                languages    = @($langs)
            }
            wim_files = @(
                [ordered]@{
                    file       = [string](Split-Path -Leaf $installWim)
                    path       = [string]$installWim
                    kind       = 'install'
                    format     = if ($installWim -match '\.esd$') { 'esd' } else { 'wim' }
                    size_bytes = if (Test-Path -LiteralPath $installWim) { [long](Get-Item -LiteralPath $installWim).Length } else { 0 }
                    images     = @($images)
                }
            )
            deferred_checks = @(
                'Package inventory (Get-WindowsPackage) and driver inventory (Get-WindowsDriver) require a mounted image and are performed in Phase 4.',
                'Setup version and Dynamic Update state are recorded during Phase 4/Phase 7 when boot.wim is serviced.'
            )
            notes = @('All values below were detected from the media; no edition index, architecture, language, build or WIM/ESD structure was assumed.')
        }
        if ($bootWim) {
            $inventory.wim_files += [ordered]@{
                file       = 'boot.wim'
                path       = [string]$bootWim
                kind       = 'boot'
                format     = 'wim'
                size_bytes = if (Test-Path -LiteralPath $bootWim) { [long](Get-Item -LiteralPath $bootWim).Length } else { 0 }
                images     = @($bootImages)
            }
        }

        $jsonPath = Join-Path $full 'Reports\ISO-INVENTORY.json'
        $txtPath = Join-Path $full 'Reports\ISO-INVENTORY.txt'
        Write-WinISOJsonFile -Path $jsonPath -Object $inventory
        Write-WinISOFile -Path $txtPath -Content (Format-WinISOInventoryText -Inventory $inventory)
        $r.Artifacts['iso-inventory.json'] = $jsonPath
        $r.Artifacts['iso-inventory.txt'] = $txtPath
        $r.Steps.Add('Read image metadata with dism /Get-WimInfo and /Get-ImageInfo (read-only).')
        $r.Steps.Add(('Detected product=' + $product + ' build=' + $build + ' arch=' + $arch + ' lang=' + $lang + ' editions=' + ($editions -join ',')))
        $r.Steps.Add('Wrote ' + $jsonPath + ' and ' + $txtPath)
        $r.Status = 'Succeeded'
        $r.Summary = ('Inventory produced: ' + $images.Count + ' image index(es), build ' + $build + ', ' + $arch + ', ' + $lang + '.')
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'ISO inspection threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

function Format-WinISOInventoryText {
    param([object]$Inventory)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('WINDOWS ISO SERVICING TOOLCHAIN - ISO INVENTORY')
    [void]$sb.AppendLine('Generated (UTC): ' + [string]$Inventory.generated_utc)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[SOURCE]')
    [void]$sb.AppendLine('  Path       : ' + [string]$Inventory.source.path)
    [void]$sb.AppendLine('  Kind       : ' + [string]$Inventory.source.kind)
    [void]$sb.AppendLine('  Size       : ' + [string]$Inventory.source.size_bytes + ' bytes')
    [void]$sb.AppendLine('  SHA-256    : ' + [string]$Inventory.source.sha256)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[DETECTED]')
    [void]$sb.AppendLine('  Product    : ' + [string]$Inventory.detected.product)
    [void]$sb.AppendLine('  Build      : ' + [string]$Inventory.detected.build + '.' + [string]$Inventory.detected.revision)
    [void]$sb.AppendLine('  Arch       : ' + [string]$Inventory.detected.architecture)
    [void]$sb.AppendLine('  Language   : ' + [string]$Inventory.detected.language)
    [void]$sb.AppendLine('  Editions   : ' + (@($Inventory.detected.editions) -join ', '))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[WIM FILES]')
    foreach ($wf in @($Inventory.wim_files)) {
        [void]$sb.AppendLine('  ' + [string]$wf.file + ' (' + [string]$wf.kind + ', ' + [string]$wf.format + ', ' + [string]$wf.size_bytes + ' bytes)')
        foreach ($img in @($wf.images)) {
            [void]$sb.AppendLine('    Index ' + [string]$img.index + ': ' + [string]$img.name + ' | build ' + [string]$img.build + '.' + [string]$img.revision + ' | ' + [string]$img.architecture + ' | ' + [string]$img.language + ' | ' + [string]$img.edition_id)
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[DEFERRED CHECKS]')
    foreach ($d in @($Inventory.deferred_checks)) { [void]$sb.AppendLine('  - ' + $d) }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# PHASE 3 - Update discovery (scaffold; queries the catalog, never downloads)
# ---------------------------------------------------------------------------

function Get-WinISOCatalogSearch {
    # Queries the Microsoft Update Catalog web UI and parses the results table.
    # Returns @{ Ok; Empty; Error; Rows } - on any failure Rows is empty and
    # Ok is false, so callers mark UNKNOWN instead of guessing.
    param([string]$Query, [int]$MaxResults = 30, [string]$LogPath = '')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinISO-Servicing-Toolchain/1.0'
        $encoded = [System.Uri]::EscapeDataString($Query)
        $resp = $null
        try {
            $resp = Invoke-WebRequest -Uri ('https://www.catalog.update.microsoft.com/Search.aspx?q=' + $encoded) -UseBasicParsing -UserAgent $ua -TimeoutSec 60
        }
        catch {
            # Fallback: classic form POST used by the catalog UI.
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $null = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/Search.aspx' -UseBasicParsing -WebSession $session -UserAgent $ua -TimeoutSec 30
            $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/Search.aspx' -Method Post -Body ('q=' + $encoded) -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -WebSession $session -UserAgent $ua -TimeoutSec 60
        }
        $html = [string]$resp.Content
        $rows = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        $tableMatch = [regex]::Match($html, '(?is)<table[^>]*id="ctl00_catalogBody_updateMatches".*?</table>')
        $tableHtml = $html
        if ($tableMatch.Success) { $tableHtml = $tableMatch.Value }
        $rowMatches = [regex]::Matches($tableHtml, '(?is)<tr[^>]*>(.*?)</tr>')
        foreach ($rm in $rowMatches) {
            $cells = [regex]::Matches($rm.Groups[1].Value, '(?is)<td[^>]*>(.*?)</td>')
            if ($cells.Count -lt 3) { continue }
            $titleIdx = -1
            for ($ci = 0; $ci -lt $cells.Count; $ci++) {
                if ($cells[$ci].Groups[1].Value -match '(?i)goToDetails|KB\d{5,8}') { $titleIdx = $ci; break }
            }
            if ($titleIdx -lt 0) { continue }
            $titleHtml = $cells[$titleIdx].Groups[1].Value
            $title = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($titleHtml, '<[^>]+>', ''))).Trim()
            if (-not $title) { continue }
            $kb = ''
            $kbMatch = [regex]::Match($title, 'KB(\d{5,8})')
            if ($kbMatch.Success) { $kb = 'KB' + $kbMatch.Groups[1].Value }
            $guid = ''
            $guidMatch = [regex]::Match($titleHtml, '(?i)goToDetails\(\D*([0-9a-fA-F\-]{36})')
            if (-not $guidMatch.Success) { $guidMatch = [regex]::Match($titleHtml, '(?i)updateid=([a-f0-9\-]+)') }
            if ($guidMatch.Success) { $guid = $guidMatch.Groups[1].Value }
            $products = ''
            $classification = ''
            $lastUpdated = ''
            $size = ''
            if (($titleIdx + 1) -lt $cells.Count) { $products = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($cells[$titleIdx + 1].Groups[1].Value, '<[^>]+>', ''))).Trim() }
            if (($titleIdx + 2) -lt $cells.Count) { $classification = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($cells[$titleIdx + 2].Groups[1].Value, '<[^>]+>', ''))).Trim() }
            if (($titleIdx + 3) -lt $cells.Count) { $lastUpdated = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($cells[$titleIdx + 3].Groups[1].Value, '<[^>]+>', ''))).Trim() }
            if (($titleIdx + 5) -lt $cells.Count) { $size = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($cells[$titleIdx + 5].Groups[1].Value, '<[^>]+>', ''))).Trim() }
            $rows.Add([pscustomobject]@{
                Title = $title; Kb = $kb; UpdateGuid = $guid; Products = $products
                Classification = $classification; LastUpdated = $lastUpdated; Size = $size
            })
            if ($rows.Count -ge $MaxResults) { break }
        }
        if ($rows.Count -eq 0) {
            return @{ Ok = $true; Empty = $true; Error = ''; Rows = @() }
        }
        return @{ Ok = $true; Empty = $false; Error = ''; Rows = @($rows) }
    }
    catch {
        $msg = $_.Exception.Message
        if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Catalog query FAILED: ' + $msg) }
        return @{ Ok = $false; Empty = $true; Error = $msg; Rows = @() }
    }
}

function Invoke-WinISOUpdateDiscovery {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [int]$Build = 0,
        [string]$Architecture = ''
    )
    $r = Get-WinISOResult -Phase 3 -Name 'Update discovery'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase3-UpdateDiscovery'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $inventoryPath = Join-Path $full 'Reports\ISO-INVENTORY.json'
        $inv = $null
        if (Test-Path -LiteralPath $inventoryPath) {
            try { $inv = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $inv = $null }
        }
        $product = ''
        $det = $null
        if ($inv) {
            $det = $inv.detected
            if ($det) {
                if ($Build -eq 0 -and $det.build) { $Build = [int]$det.build }
                if (-not $Architecture -and $det.architecture) { $Architecture = [string]$det.architecture }
                if ($det.product) { $product = [string]$det.product }
            }
        }
        if ($Build -eq 0) {
            $r.Status = 'Skipped'
            $r.Reason = 'Build number unknown: Phase 2 (ISO inspection) has not produced an inventory. Run Phase 2 first or pass -Build explicitly.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        # Marketing version tag is a QUERY HINT only; selections are still
        # validated against the detected build/product and catalog metadata.
        $versionHints = @(
            @{ Build = 26200; Version = '25H2' }, @{ Build = 26100; Version = '24H2' },
            @{ Build = 22631; Version = '23H2' }, @{ Build = 22621; Version = '22H2' },
            @{ Build = 22000; Version = '21H2' },
            @{ Build = 19045; Version = '22H2' }, @{ Build = 19044; Version = '21H2' },
            @{ Build = 19041; Version = '2004' }, @{ Build = 14393; Version = '1607' },
            @{ Build = 10240; Version = '1507' }
        )
        $verHint = ''
        foreach ($h in $versionHints) { if ($Build -eq $h.Build) { $verHint = [string]$h.Version; break } }
        if (-not $product) {
            if ($Build -ge 22000) { $product = 'Windows 11' }
            elseif ($Build -ge 10240) { $product = 'Windows 10' }
            else { $product = '' }
            Add-WinISOLogLine -Path $log -Line ('Product not detected from inventory; using build-derived query hint: ' + $product)
        }
        $archSuffix = ''
        if ($Architecture) { $archSuffix = ' for ' + $Architecture }
        $queries = @()
        if ($product) {
            $queries += [pscustomobject]@{ Type = 'SSU'; Query = 'Servicing Stack Update "' + $product + '"' }
            $queries += [pscustomobject]@{ Type = 'Latest CU'; Query = '"' + $product + '" Cumulative Update' + $archSuffix }
            $queries += [pscustomobject]@{ Type = '.NET CU'; Query = '.NET Framework Cumulative Update "' + $product + '"' }
            $queries += [pscustomobject]@{ Type = 'Setup & Dynamic Updates'; Query = '"Dynamic Update" "' + $product + '"' }
        }

        $allRows = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        $queryLog = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        $catalogOk = $true
        $firstError = ''
        foreach ($q in $queries) {
            $res = Get-WinISOCatalogSearch -Query $q.Query -MaxResults 10 -LogPath $log
            $queryLog.Add([pscustomobject]@{ Type = $q.Type; Query = $q.Query; Ok = $res.Ok; RowCount = @($res.Rows).Count; Error = $res.Error })
            if (-not $res.Ok) {
                $catalogOk = $false
                if (-not $firstError) { $firstError = [string]$res.Error }
            }
            foreach ($row in @($res.Rows)) {
                if (-not $row.Kb) { continue }
                $row | Add-Member -NotePropertyName 'SourceQuery' -NotePropertyValue ([string]$q.Type) -Force
                $allRows.Add($row)
            }
        }
        $byKb = @{}
        foreach ($row in $allRows) {
            if (-not $byKb.ContainsKey([string]$row.Kb)) { $byKb[[string]$row.Kb] = $row }
        }

        $candidates = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        foreach ($kb in @($byKb.Keys)) {
            $row = $byKb[$kb]
            $title = [string]$row.Title
            $isPreview = $title -match '(?i)preview'
            $titleArch = ''
            if ($title -match '(?i)\bx64\b') { $titleArch = 'x64' }
            elseif ($title -match '(?i)\barm64\b') { $titleArch = 'arm64' }
            elseif ($title -match '(?i)\bx86\b') { $titleArch = 'x86' }
            $archOk = $true
            $archNote = 'architecture stated in title or unknown'
            if ($Architecture -and $titleArch -and $titleArch -ne $Architecture) {
                $archOk = $false
                $archNote = 'title architecture mismatch (' + $titleArch + ' vs ' + $Architecture + ')'
            }
            $offline = 'unknown'
            switch -Regex ([string]$row.Classification) {
                'Security Updates|Critical Updates|Update Rollups|Servicing Stack' { $offline = 'yes' }
                'Drivers' { $offline = 'no' }
                default { $offline = 'unknown' }
            }
            $titleVersion = ''
            $tvMatch = [regex]::Match($title, '(?i)version\s+(\d{2}H\d)')
            if ($tvMatch.Success) { $titleVersion = $tvMatch.Groups[1].Value.ToUpper() }
            $verOk = $true
            $verNote = ''
            if ($verHint -and $titleVersion -and $titleVersion -ne $verHint.ToUpper()) {
                $verOk = $false
                $verNote = 'title Windows version mismatch (' + $titleVersion + ' vs ' + $verHint + ')'
            }
            $type = [string]$row.SourceQuery
            $recommendation = 'Optional'
            $reason = 'Unmatched candidate; review manually.'
            switch ($type) {
                'SSU' {
                    if ($archOk -and $offline -ne 'no' -and -not $isPreview) {
                        $recommendation = 'Required'
                        $reason = 'Servicing Stack Updates are prerequisites for cumulative updates; integrate first, then verify not already contained at apply time.'
                    }
                    elseif (-not $archOk) { $recommendation = 'Not applicable'; $reason = $archNote }
                }
                'Latest CU' {
                    if ($isPreview) { $recommendation = 'Do not integrate'; $reason = 'Preview updates are not for production media.' }
                    elseif ($archOk -and $offline -eq 'yes') {
                        $recommendation = 'Required'
                        $reason = 'Latest cumulative update matching the detected build; Phase 4 verifies contained-state before adding.'
                    }
                    elseif ($archOk) { $recommendation = 'Recommended'; $reason = 'Classification not confirmed as offline-integrable; verify before adding.' }
                    else { $recommendation = 'Not applicable'; $reason = $archNote }
                }
                '.NET CU' {
                    if ($isPreview) { $recommendation = 'Do not integrate'; $reason = 'Preview updates are not for production media.' }
                    elseif ($archOk -and $offline -ne 'no') { $recommendation = 'Recommended'; $reason = '.NET Framework cumulative updates are optional but safe; verify applicability before adding.' }
                    else { $recommendation = 'Not applicable'; $reason = $archNote }
                }
                'Setup & Dynamic Updates' {
                    if ($isPreview) { $recommendation = 'Do not integrate'; $reason = 'Preview updates are not for production media.' }
                    elseif ($archOk -and $offline -ne 'no') { $recommendation = 'Recommended'; $reason = 'Dynamic Updates refresh setup/boot media; applies to servicing boot.wim/setup paths only.' }
                    else { $recommendation = 'Not applicable'; $reason = $archNote }
                }
            }
            if (-not $verOk -and $recommendation -ne 'Do not integrate') {
                $recommendation = 'Not applicable'
                $reason = $verNote
            }
            $candidates.Add([pscustomobject]@{
                kb                       = $kb
                title                    = $title
                type                     = $type
                release_date             = [string]$row.LastUpdated
                classification           = [string]$row.Classification
                applicable_build         = $Build
                applicable_architecture  = $titleArch
                prerequisites            = 'unknown'
                supersedes               = 'unknown'
                offline_integrable       = $offline
                already_contained        = $false
                sha256                   = ''
                recommendation           = $recommendation
                reason                   = $reason
                catalog_guid             = [string]$row.UpdateGuid
                catalog_size             = [string]$row.Size
            })
        }

        $buckets = [ordered]@{
            'Required'        = New-Object 'System.Collections.Generic.List[string]'
            'Recommended'     = New-Object 'System.Collections.Generic.List[string]'
            'Optional'        = New-Object 'System.Collections.Generic.List[string]'
            'Not applicable'  = New-Object 'System.Collections.Generic.List[string]'
            'Do not integrate' = New-Object 'System.Collections.Generic.List[string]'
        }
        foreach ($c in $candidates) { $buckets[[string]$c.recommendation].Add([string]$c.kb) }

        $manifest = [ordered]@{
            generated_utc       = [DateTime]::UtcNow.ToString('o')
            catalog_status      = if ($catalogOk) { 'ok' } else { 'unreachable-or-error' }
            catalog_error       = $firstError
            catalog_empty       = ($allRows.Count -eq 0)
            product_was_detected = ($null -ne $inv -and $product -ne '')
            product             = $product
            build               = $Build
            architecture        = $Architecture
            query_log           = @($queryLog)
            candidates          = @($candidates)
            buckets             = $buckets
            notes               = @(
                'No update is selected solely because it is newer; candidates must match the detected build/product/architecture and classification heuristics.',
                'already_contained and sha256 are populated only after Phase 4 verifies the mounted image (downloads are NOT part of this toolchain).',
                'If catalog_status is unreachable-or-error, all selections are UNKNOWN: review the manifest manually before Phase 4.',
                'Newest-first ordering is a review convenience only; supersedence is never assumed from ordering.'
            )
        }
        $manifestPath = Join-Path $full 'Reports\UPDATE-MANIFEST.json'
        Write-WinISOJsonFile -Path $manifestPath -Object $manifest
        $r.Artifacts['update-manifest.json'] = $manifestPath
        $r.Steps.Add('Queried Microsoft Update Catalog with ' + @($queries).Count + ' query(ies); ' + @($candidates).Count + ' unique KB candidate(s).')
        $r.Steps.Add('Classified candidates into Required/Recommended/Optional/Not applicable/Do not integrate buckets.')
        $r.Steps.Add('Wrote ' + $manifestPath)
        Add-WinISOLogLine -Path $log -Line ('catalog_status=' + $manifest.catalog_status + '; candidates=' + @($candidates).Count)
        if (-not $catalogOk) {
            $r.Status = 'Partial'
            $r.Errors.Add('Microsoft Update Catalog query failed: ' + $firstError)
            $r.Summary = ('Catalog unreachable; manifest written with UNKNOWN selections (candidates=' + @($candidates).Count + '). Review manually before Phase 4.')
        }
        elseif (@($candidates).Count -eq 0) {
            $r.Status = 'Partial'
            $r.Errors.Add('Catalog responded but no KB rows matched the queries.')
            $r.Summary = 'No matching updates found; manifest written with empty buckets. Nothing will be integrated.'
        }
        else {
            $r.Status = 'Succeeded'
            $r.Summary = ('Update manifest produced: ' + @($candidates).Count + ' candidates (' + $buckets['Required'].Count + ' required, ' + $buckets['Recommended'].Count + ' recommended).')
        }
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Update discovery threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 4 - Image servicing (mount, inspect, add, health, commit)
# ---------------------------------------------------------------------------

function Copy-WinISOSourceWims {
    # Copies boot.wim and install.wim/esd from the (read-only) source into
    # ExtractedISO\sources\. The original source is never modified; servicing
    # always happens on this copy.
    param([string]$SourcePath, [string]$DestDir, [string]$LogPath = '')
    $srcDir = Join-Path $DestDir 'sources'
    if (-not (Test-Path -LiteralPath $srcDir)) { [void](New-Item -ItemType Directory -Path $srcDir -Force) }
    $mountedIso = $null
    try {
        $srcRoot = ''
        if ($SourcePath -match '\.iso$') {
            $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            try { $mountedIso = Mount-DiskImage -ImagePath $SourcePath -PassThru -ErrorAction Stop } catch { $mountedIso = $null }
            if ($null -eq $mountedIso) { return @{ Ok = $false; Error = 'Could not attach the ISO read-only to copy WIM files.' } }
            $letter = ''
            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                Start-Sleep -Milliseconds 500
                $after = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
                $newLetters = @($after | Where-Object { $before -notcontains $_ })
                foreach ($l in $newLetters) {
                    if (Test-Path -LiteralPath ($l + ':\sources\boot.wim')) { $letter = $l; break }
                }
                if (-not $letter -and $newLetters.Count -gt 0) { $letter = $newLetters[0] }
                if ($letter) { break }
            }
            if (-not $letter) { return @{ Ok = $false; Error = 'ISO attached but no drive letter was assigned.' } }
            $srcRoot = $letter + ':\'
        }
        else {
            $srcRoot = [string](Split-Path -Parent $SourcePath)
        }
        $installSrc = ''
        foreach ($n in @('install.wim', 'install.esd')) {
            if (Test-Path -LiteralPath (Join-Path $srcRoot ('sources\' + $n))) { $installSrc = Join-Path $srcRoot ('sources\' + $n); break }
        }
        if (-not $installSrc -and $SourcePath -notmatch '\.iso$') { $installSrc = $SourcePath }
        $installDest = ''
        $bootDest = ''
        if ($installSrc) {
            $installDest = Join-Path $srcDir ([System.IO.Path]::GetFileName($installSrc))
            if (-not (Test-Path -LiteralPath $installDest)) {
                Copy-Item -LiteralPath $installSrc -Destination $installDest -Force
                if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Copied ' + $installSrc + ' -> ' + $installDest) }
            }
            else {
                if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Reusing existing copy ' + $installDest + ' (idempotent)') }
            }
        }
        $bootSrc = Join-Path $srcRoot 'sources\boot.wim'
        if (Test-Path -LiteralPath $bootSrc) {
            $bootDest = Join-Path $srcDir 'boot.wim'
            if (-not (Test-Path -LiteralPath $bootDest)) {
                Copy-Item -LiteralPath $bootSrc -Destination $bootDest -Force
            }
        }
        if ($installDest) { try { Set-ItemProperty -LiteralPath $installDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { } }
        if ($bootDest) { try { Set-ItemProperty -LiteralPath $bootDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { } }
        return @{ Ok = $true; Error = ''; InstallWim = $installDest; BootWim = $bootDest; Details = 'WIM file(s) copied from ' + $SourcePath }
    }
    catch {
        return @{ Ok = $false; Error = $_.Exception.Message; InstallWim = ''; BootWim = ''; Details = '' }
    }
    finally {
        if ($mountedIso) {
            try { Dismount-DiskImage -ImagePath $SourcePath -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
}

function Expand-WinISOMsuToCab {
    # Extracts the payload .cab from an .msu (expand.exe first; wusa /extract
    # fallback for PSFX-format standalone packages). Never fabricates a path.
    param([string]$PackagePath, [string]$WorkDir, [string]$LogPath = '')
    if ($PackagePath -match '\.cab$') { return $PackagePath }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath)
    $dest = Join-Path $WorkDir $baseName
    if (-not (Test-Path -LiteralPath $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force) }
    $null = Invoke-WinISOProcess -FilePath (Join-Path $env:SystemRoot 'System32\expand.exe') -ArgumentList @('-F:*', $PackagePath, $dest) -TimeoutSeconds 600 -LogPath $LogPath
    $cabs = @(Get-ChildItem -LiteralPath $dest -Filter *.cab -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'WSUSSCAN' })
    if ($cabs.Count -eq 0) {
        $null = Invoke-WinISOProcess -FilePath (Join-Path $env:SystemRoot 'System32\wusa.exe') -ArgumentList @($PackagePath, ('/extract:' + $dest)) -TimeoutSeconds 90 -LogPath $LogPath
        $cabs = @(Get-ChildItem -LiteralPath $dest -Filter *.cab -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'WSUSSCAN' })
    }
    if ($cabs.Count -eq 0) {
        if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Could not extract a payload .cab from ' + $PackagePath) }
        return $null
    }
    $cab = $cabs | Sort-Object Length -Descending | Select-Object -First 1
    if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Payload cab selected: ' + $cab.FullName) }
    return $cab.FullName
}

function Invoke-WinISOServiceImage {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [string]$UpdateManifest = '',
        [string]$DriversPath = '',
        [int[]]$ImageIndexes = @(),
        [switch]$RunCleanup
    )
    $r = Get-WinISOResult -Phase 4 -Name 'Image servicing'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase4-ImageServicing'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $candidates = @(Find-WinISOSourceIso -Workspace $full -SourceIso $SourceIso)
        if ($candidates.Count -eq 0) {
            $r.Status = 'Skipped'
            $r.Reason = 'No source ISO/WIM/ESD present. Servicing requires a source image.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $sourcePath = [string]$candidates[0].FullName

        # Read the update manifest (never fabricate a selection list).
        $manifestPath = $UpdateManifest
        if (-not $manifestPath) { $manifestPath = Join-Path $full 'Reports\UPDATE-MANIFEST.json' }
        $manifest = $null
        if (Test-Path -LiteralPath $manifestPath) {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $manifest = $null }
        }
        $kbsToAdd = @()
        if ($manifest) {
            foreach ($b in @('Required', 'Recommended')) {
                $bk = $manifest.buckets.$b
                if ($bk) {
                    foreach ($k in @($bk)) { if ($kbsToAdd -notcontains [string]$k) { $kbsToAdd += [string]$k } }
                }
            }
        }
        $driversRequested = ($DriversPath -ne '' -and (Test-Path -LiteralPath $DriversPath -PathType Container))
        if ($kbsToAdd.Count -eq 0 -and -not $driversRequested) {
            $r.Status = 'Skipped'
            $r.Reason = 'No updates selected in the manifest (Required/Recommended buckets) and no drivers requested via -Drivers. Nothing to service.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }

        # Locate package files under Updates\ (toolchain never downloads).
        $updatesDir = Join-Path $full 'Updates'
        $pkgFiles = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        $missingKbs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($kb in $kbsToAdd) {
            $matches = @(Get-ChildItem -LiteralPath $updatesDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ('(?i)' + [regex]::Escape($kb) + '.*\.(msu|cab)$') })
            if ($matches.Count -eq 0) {
                $missingKbs.Add($kb)
                $r.Errors.Add('No .msu/.cab package file found under Updates\ for ' + $kb + '. Download it manually (the toolchain never downloads) or remove it from the manifest.')
                continue
            }
            $pkgFiles.Add([pscustomobject]@{ Kb = [string]$kb; Path = [string]$matches[0].FullName })
        }
        if ($pkgFiles.Count -eq 0 -and -not $driversRequested) {
            $r.Status = 'Failed'
            $r.Summary = 'Updates were requested in the manifest but no matching package files exist under Updates\.'
            foreach ($e in $r.Errors) { $r.FailedSteps.Add([string]$e) }
            return $r
        }

        # Copy the WIM(s) out of the source (source remains untouched).
        $extract = Copy-WinISOSourceWims -SourcePath $sourcePath -DestDir (Join-Path $full 'ExtractedISO') -LogPath $log
        if (-not $extract.Ok) {
            $r.Status = 'Failed'
            $r.Errors.Add($extract.Error)
            $r.Summary = 'Could not copy the WIM files from the source.'
            return $r
        }
        $installWim = [string]$extract.InstallWim
        if (-not $installWim) {
            $r.Status = 'Failed'
            $r.Errors.Add('No install.wim/install.esd was found in the source media.')
            $r.Summary = 'No install image to service.'
            return $r
        }
        Add-WinISOLogLine -Path $log -Line ('Servicing target: ' + $installWim)

        # Pristine backup for rollback (referenced by Phase 6 rollback plans).
        $backupPath = Join-Path $full ('Backup\' + [System.IO.Path]::GetFileName($installWim) + '.pre-servicing')
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $installWim -Destination $backupPath -Force
            Add-WinISOLogLine -Path $log -Line ('Pristine backup: ' + $backupPath)
            $r.Steps.Add('Pristine pre-servicing backup written to ' + $backupPath)
        }

        # Enumerate indexes to service (all detected indexes unless restricted).
        $wimInfo = Get-WinISOWimInfo -WimPath $installWim -LogPath $log
        if ($wimInfo.ExitCode -ne 0) {
            $r.Status = 'Failed'
            $r.Errors.Add('Could not read WIM metadata before servicing: ' + $wimInfo.Output)
            $r.Summary = 'WIM metadata read failed before servicing.'
            return $r
        }
        $targetIndexes = @($ImageIndexes)
        if ($targetIndexes.Count -eq 0) { $targetIndexes = @($wimInfo.Indexes | ForEach-Object { [int]$_.Index }) }
        $r.Steps.Add('Will service indexes: ' + ($targetIndexes -join ', '))

        # SSU packages first (prerequisite ordering), everything else after.
        $ssuKbs = @()
        if ($manifest) {
            foreach ($c in @($manifest.candidates)) {
                if ($c.type -eq 'SSU') { $ssuKbs += [string]$c.kb }
            }
        }
        $pkgOrder = @($pkgFiles | Where-Object { $ssuKbs -contains $_.Kb }) + @($pkgFiles | Where-Object { $ssuKbs -notcontains $_.Kb })

        $imageResults = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        foreach ($idx in $targetIndexes) {
            $mountDir = Join-Path $full ('Mount\Image' + $idx)
            if (-not (Test-Path -LiteralPath $mountDir)) { [void](New-Item -ItemType Directory -Path $mountDir -Force) }
            $img = [ordered]@{
                Index      = [int]$idx
                Mounted    = $false
                Committed  = $false
                Health     = ''
                ReclaimableMB = 0
                Updates    = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
                DriversAdded = 0
                Errors     = New-Object 'System.Collections.Generic.List[string]'
                Cleanup    = 'not requested'
            }
            $mounted = $false
            try {
                $m = Invoke-WinISODism -Arguments @('/English', '/Mount-Image', ('/ImageFile:' + $installWim), ('/Index:' + $idx), ('/MountDir:' + $mountDir)) -TimeoutSeconds 2400 -LogPath $log
                if ($m.ExitCode -ne 0) {
                    $cls = Get-WinISODismErrorClass -ExitCode $m.ExitCode -Output $m.Output
                    $img.Errors.Add('Mount failed: ' + $cls.Class + ' - ' + $cls.Description)
                    Add-WinISOLogLine -Path $log -Line ('Mount failed for index ' + $idx + ': ' + $cls.Class)
                    continue
                }
                $mounted = $true
                $img.Mounted = $true
                Add-WinISOLogLine -Path $log -Line ('Mounted index ' + $idx + ' at ' + $mountDir)

                # Package inventory (detects what is already contained).
                $pkgs = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Get-Packages') -TimeoutSeconds 1800 -LogPath $log
                $pkgsText = [string]$pkgs.Output
                $r.Steps.Add('Index ' + $idx + ': package inventory read (' + $(if ($pkgs.ExitCode -eq 0) { 'ok' } else { 'read failed, exit ' + $pkgs.ExitCode }) + ')')

                # Component-store health before changes.
                $health = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Cleanup-Image', '/CheckHealth') -TimeoutSeconds 2400 -LogPath $log
                $img.Health = if ($health.ExitCode -eq 0) { 'CheckHealth OK (component store clean)' } else { 'CheckHealth FAILED (exit ' + $health.ExitCode + ')' }
                $analyze = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Cleanup-Image', '/AnalyzeComponentStore') -TimeoutSeconds 2400 -LogPath $log
                $reclaimMatch = [regex]::Match([string]$analyze.Output, 'Reclaimable\s*:?\s*([\d.,]+)\s*(GB|MB)')
                if ($reclaimMatch.Success) {
                    $val = [double]($reclaimMatch.Groups[1].Value -replace ',', '')
                    $img.ReclaimableMB = if ($reclaimMatch.Groups[2].Value -eq 'GB') { [math]::Round($val * 1024, 0) } else { [math]::Round($val, 0) }
                }

                # Add updates (SSU first). Failures are classified, never forced.
                foreach ($pkg in $pkgOrder) {
                    $pkgResult = [ordered]@{ Kb = [string]$pkg.Kb; Result = ''; Note = '' }
                    if ($pkgsText -match ('(?i)' + [regex]::Escape([string]$pkg.Kb))) {
                        $pkgResult.Result = 'already-contained'
                        $pkgResult.Note = 'Package name matching the KB id already exists in the mounted image; Add-Package skipped.'
                        $img.Updates.Add([pscustomobject]$pkgResult)
                        Add-WinISOLogLine -Path $log -Line ($pkg.Kb + ': already contained; skipped')
                        continue
                    }
                    $cabPath = Expand-WinISOMsuToCab -PackagePath $pkg.Path -WorkDir (Join-Path $full 'Updates\_expanded') -LogPath $log
                    if (-not $cabPath -and (Test-Path -LiteralPath ([string]$pkg.Path) -PathType Leaf)) { $cabPath = [string]$pkg.Path }
                    if (-not $cabPath) {
                        $pkgResult.Result = 'failed-extract'
                        $pkgResult.Note = 'Could not extract a payload .cab (expand.exe and wusa /extract both failed).'
                        $img.Updates.Add([pscustomobject]$pkgResult)
                        $img.Errors.Add($pkg.Kb + ': payload extraction failed.')
                        continue
                    }
                    $add = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Add-Package', ('/PackagePath:' + $cabPath), '/NoRestart') -TimeoutSeconds 3600 -LogPath $log
                    if ($add.ExitCode -eq 0) {
                        $pkgResult.Result = 'integrated'
                        $pkgResult.Note = 'Add-Package succeeded.'
                        Add-WinISOLogLine -Path $log -Line ($pkg.Kb + ': integrated')
                    }
                    else {
                        $cls = Get-WinISODismErrorClass -ExitCode $add.ExitCode -Output $add.Output
                        $pkgResult.Result = $cls.Class
                        $pkgResult.Note = $cls.Description + ' ' + $cls.Action
                        Add-WinISOLogLine -Path $log -Line ($pkg.Kb + ': ' + $cls.Class + ' (' + $cls.Hex + ') - NOT forced, recorded per policy')
                        if ($cls.Class -ne 'AlreadyInstalledOrNotApplicable') {
                            $img.Errors.Add($pkg.Kb + ': Add-Package failed - ' + $cls.Class + ' (' + $cls.Hex + ')')
                        }
                    }
                    $img.Updates.Add([pscustomobject]$pkgResult)
                }

                # Drivers are added ONLY when explicitly requested via -Drivers.
                if ($driversRequested) {
                    $drvBefore = @([regex]::Matches(([string](Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Get-Drivers') -TimeoutSeconds 1800 -LogPath $log).Output), '(?i)Original File Name')).Count
                    $drv = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Add-Driver', ('/Driver:' + $DriversPath), '/Recurse') -TimeoutSeconds 3600 -LogPath $log
                    $drvAfter = @([regex]::Matches(([string](Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Get-Drivers') -TimeoutSeconds 1800 -LogPath $log).Output), '(?i)Original File Name')).Count
                    $img.DriversAdded = [math]::Max(0, $drvAfter - $drvBefore)
                    if ($drv.ExitCode -ne 0) {
                        $img.Errors.Add('Add-Driver failed (exit ' + $drv.ExitCode + '); ' + $drvBefore + ' -> ' + $drvAfter + ' driver packages counted.')
                    }
                    $r.Steps.Add('Index ' + $idx + ': driver import requested, ' + $img.DriversAdded + ' driver package(s) added.')
                }

                # Component cleanup only when explicitly requested.
                if ($RunCleanup) {
                    $cl = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Cleanup-Image', '/StartComponentCleanup') -TimeoutSeconds 3600 -LogPath $log
                    $img.Cleanup = 'StartComponentCleanup ran (exit ' + $cl.ExitCode + ')'
                }

                # Commit only when no hard errors occurred on this image.
                if ($img.Errors.Count -gt 0) {
                    Add-WinISOLogLine -Path $log -Line ('Index ' + $idx + ' has errors; discarding mount without committing.')
                    $u = Invoke-WinISODism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Discard') -TimeoutSeconds 2400 -LogPath $log
                    $mounted = $false
                    $img.Errors.Add('Mount discarded (not committed) because this image had errors.')
                    continue
                }
                $u = Invoke-WinISODism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Commit') -TimeoutSeconds 2400 -LogPath $log
                if ($u.ExitCode -ne 0) {
                    $img.Errors.Add('Commit failed (exit ' + $u.ExitCode + '); see DISM log. Mount will be discarded by cleanup.')
                    continue
                }
                $mounted = $false
                $img.Committed = $true
                Add-WinISOLogLine -Path $log -Line ('Index ' + $idx + ' committed.')
            }
            finally {
                # Guarantee: no image is ever left mounted.
                if ($mounted) {
                    $d = Invoke-WinISODism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Discard') -TimeoutSeconds 1200 -LogPath $log
                    Add-WinISOLogLine -Path $log -Line ('Cleanup: unmounted ' + $mountDir + ' with /Discard (exit ' + $d.ExitCode + ').')
                    $img.Errors.Add('Image was left mounted after a failure and has been discarded by the guaranteed cleanup.')
                }
                $mi = Invoke-WinISODism -Arguments @('/English', '/Get-MountedImageInfo') -TimeoutSeconds 300 -LogPath $log
                if ([string]$mi.Output -notmatch [regex]::Escape($mountDir)) {
                    Add-WinISOLogLine -Path $log -Line ('Verified: ' + $mountDir + ' is not present in mounted-image list.')
                }
                else {
                    Add-WinISOLogLine -Path $log -Line ('WARNING: ' + $mountDir + ' still appears in /Get-MountedImageInfo; manual cleanup required.')
                }
            }
            $imageResults.Add([pscustomobject]$img)
        }

        # Post-mutation verification: WIM still has the expected indexes.
        $verify = Get-WinISOWimInfo -WimPath $installWim -LogPath $log
        $verified = ($verify.ExitCode -eq 0 -and @($verify.Indexes).Count -gt 0)
        $r.Steps.Add('Post-servicing verification: ' + $(if ($verified) { 'WIM readable, ' + @($verify.Indexes).Count + ' index(es) present.' } else { 'WIM verification FAILED.' }))

        $resultsPath = Join-Path $full 'Reports\SERVICING-RESULTS.json'
        $resultsTxtPath = Join-Path $full 'Reports\SERVICING-RESULTS.txt'
        $summary = [ordered]@{
            generated_utc  = [DateTime]::UtcNow.ToString('o')
            source         = $sourcePath
            wim_serviced   = $installWim
            indexes        = @($targetIndexes)
            updates_requested = @($kbsToAdd)
            updates_missing_files = @($missingKbs)
            drivers_requested = $driversRequested
            drivers_path   = $DriversPath
            run_cleanup    = [bool]$RunCleanup
            images         = @($imageResults)
            wim_verified_after = $verified
            backup_path    = $backupPath
        }
        Write-WinISOJsonFile -Path $resultsPath -Object $summary
        $txtSb = New-Object System.Text.StringBuilder
        [void]$txtSb.AppendLine('IMAGE SERVICING RESULTS')
        foreach ($img in @($imageResults)) {
            [void]$txtSb.AppendLine('Index ' + [string]$img.Index + ': mounted=' + [string]$img.Mounted + ' committed=' + [string]$img.Committed + ' health=' + [string]$img.Health)
            foreach ($u in @($img.Updates)) { [void]$txtSb.AppendLine('  ' + [string]$u.Kb + ' -> ' + [string]$u.Result + ' (' + [string]$u.Note + ')') }
            foreach ($e in @($img.Errors)) { [void]$txtSb.AppendLine('  ERROR: ' + $e) }
        }
        [void]$txtSb.AppendLine('WIM verified after servicing: ' + [string]$verified)
        Write-WinISOFile -Path $resultsTxtPath -Content $txtSb.ToString()
        $r.Artifacts['servicing-results.json'] = $resultsPath
        $r.Artifacts['servicing-results.txt'] = $resultsTxtPath
        $r.Steps.Add('Wrote ' + $resultsPath + ' and ' + $resultsTxtPath)

        $hardErrors = 0
        foreach ($img in @($imageResults)) { $hardErrors += @($img.Errors).Count }
        if ($hardErrors -gt 0 -or -not $verified) {
            $r.Status = 'Failed'
            $r.Summary = 'Servicing completed with ' + $hardErrors + ' hard error(s); every mount was cleaned up. See SERVICING-RESULTS.'
            foreach ($img in @($imageResults)) { foreach ($e in @($img.Errors)) { $r.Errors.Add('Index ' + $img.Index + ': ' + $e) } }
            if (-not $verified) { $r.Errors.Add('Post-servicing WIM verification failed.') }
        }
        else {
            $r.Status = 'Succeeded'
            $r.Summary = 'Servicing succeeded for index(es) ' + ($targetIndexes -join ', ') + '; WIM verified after commit.'
        }
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Image servicing threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 5 - OOBE / unattend configuration generation
# ---------------------------------------------------------------------------

function Invoke-WinISOOobeUnattend {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [hashtable]$Unattend = @{},
        [string]$UnattendFile = ''
    )
    $r = Get-WinISOResult -Phase 5 -Name 'OOBE / unattend'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase5-Unattend'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $generator = Join-Path $PSScriptRoot 'New-UnattendXml.ps1'
        if (-not (Test-Path -LiteralPath $generator)) {
            $r.Status = 'Failed'
            $r.Errors.Add('New-UnattendXml.ps1 not found next to the module: ' + $generator)
            $r.Summary = 'Unattend generator script missing.'
            return $r
        }
        $allowed = @(
            'ComputerName', 'Language', 'KeyboardLayout', 'Region', 'TimeZone',
            'LocalAccountName', 'LocalAccountPassword', 'LocalAccountAdmin',
            'AutoLogon', 'NetworkLocation', 'ProtectYourPC',
            'HideWirelessSetupInOOBE', 'HideOnlineAccountScreens', 'SkipUserOOBE',
            'EnableBypassNRO', 'InstallToAvailablePartition', 'ProductKey', 'Architecture'
        )
        $bad = @($Unattend.Keys | Where-Object { $allowed -notcontains $_ })
        if ($bad.Count -gt 0) {
            $r.Status = 'Failed'
            $r.Errors.Add('Unknown unattend parameter(s): ' + ($bad -join ', ') + '. Allowed: ' + ($allowed -join ', '))
            $r.Summary = 'Invalid -Unattend parameters.'
            return $r
        }
        $outPath = Join-Path $full 'Output\unattend.xml'
        if ($UnattendFile) {
            if (-not (Test-Path -LiteralPath $UnattendFile -PathType Leaf)) {
                $r.Status = 'Failed'
                $r.Errors.Add('UnattendFile not found: ' + $UnattendFile)
                $r.Summary = 'UnattendFile missing.'
                return $r
            }
            Copy-Item -LiteralPath $UnattendFile -Destination $outPath -Force
            $r.Steps.Add('Copied caller-provided unattend file to ' + $outPath)
        }
        else {
            $null = & $generator @Unattend -OutputPath $outPath
            $r.Steps.Add('Generated unattend.xml from parameters (supported setup mechanisms only).')
        }
        # Validate the XML is well-formed before accepting it.
        try {
            [void]([xml](Get-Content -LiteralPath $outPath -Raw -Encoding UTF8))
            $r.Steps.Add('XML well-formedness check passed for ' + $outPath)
        }
        catch {
            $r.Status = 'Failed'
            $r.Errors.Add('Generated unattend.xml failed XML validation: ' + $_.Exception.Message)
            $r.Summary = 'unattend.xml is not well-formed XML.'
            return $r
        }
        $r.Artifacts['unattend.xml'] = $outPath
        # Stage to media root (supported mechanism: media-root autounattend.xml
        # is consumed by the windowsPE pass; not a hack).
        if (Test-Path -LiteralPath (Join-Path $full 'ExtractedISO\sources')) {
            $stage = Join-Path $full 'ExtractedISO\autounattend.xml'
            Copy-Item -LiteralPath $outPath -Destination $stage -Force
            $r.Artifacts['autounattend.xml (media root)'] = $stage
            $r.Steps.Add('Staged as autounattend.xml at the media root (supported setup mechanism).')
        }
        else {
            $r.Steps.Add('No extracted media present yet; media-root staging is deferred to Phase 7.')
        }
        $r.Steps.Add('Note: workarounds (e.g. BypassNRO) are opt-in via -EnableBypassNRO and are clearly marked in the XML description fields.')
        $r.Summary = 'unattend.xml generated at ' + $outPath
        $r.Status = 'Succeeded'
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Add-WinISOLogLine -Path $log -Line ('unattend.xml written to ' + $outPath)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'OOBE/unattend generation threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 6 - Customization profiles (SAFE / STANDARD / AGGRESSIVE)
# ---------------------------------------------------------------------------

function Invoke-WinISOProfile {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [ValidateSet('Safe', 'Standard', 'Aggressive')][string]$Profile = 'Safe',
        [switch]$AllowRemoval,
        [string[]]$RemovePackages = @(),
        [hashtable]$RemoveReasons = @{},
        [switch]$SkipDependencyAnalysis
    )
    $r = Get-WinISOResult -Phase 6 -Name 'Customization profile'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase6-Profile'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        # Hard-blocked servicing infrastructure (no override exists).
        $hardBlockPatterns = @('Microsoft-Windows-ServicingStack', 'Microsoft-Windows-Foundation-Package')
        # Protected components: removable only with -AllowRemoval AND an
        # explicit technical justification in -RemoveReasons.
        $protectedPatterns = @('Windows-Defender', 'WinRE', 'WindowsUpdate', 'Microsoft-Windows-Setup', 'Servicing')
        $decision = [ordered]@{
            generated_utc       = [DateTime]::UtcNow.ToString('o')
            profile             = $Profile
            allow_removal       = [bool]$AllowRemoval
            removals_requested  = @($RemovePackages)
            removals_authorized = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
            removals_blocked    = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
            removal_applied     = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
            notes               = New-Object 'System.Collections.Generic.List[string]'
        }
        switch ($Profile) {
            'Safe' { $decision.notes.Add('SAFE profile: updates only, no component removal, minimal OOBE (Phase 5).') }
            'Standard' { $decision.notes.Add('STANDARD profile: updates, drivers if requested (Phase 4), OOBE configuration (Phase 5).') }
            'Aggressive' { $decision.notes.Add('AGGRESSIVE profile: requires explicit -AllowRemoval before any removal is authorized.') }
        }
        if ($RemovePackages.Count -gt 0 -and -not $AllowRemoval) {
            $r.Status = 'Failed'
            $r.Errors.Add('Component removal requested but -AllowRemoval was not specified. The AGGRESSIVE profile requires explicit authorization.')
            $r.Summary = 'Removal requested without -AllowRemoval.'
            $decision.notes.Add('BLOCKED: removal requested without -AllowRemoval.')
            $decisionPath = Join-Path $full 'Reports\PROFILE-DECISION.json'
            Write-WinISOJsonFile -Path $decisionPath -Object $decision
            $r.Artifacts['profile-decision.json'] = $decisionPath
            return $r
        }
        foreach ($pkg in @($RemovePackages)) {
            $hardHit = $null
            foreach ($pat in $hardBlockPatterns) {
                if ($pkg -like ('*' + $pat + '*')) { $hardHit = [string]$pat; break }
            }
            if ($hardHit) {
                $decision.removals_blocked.Add([pscustomobject]@{
                    Package = $pkg
                    Reason  = 'Hard-blocked: matches servicing-infrastructure pattern ' + $hardHit + '. No override exists; removing it would destroy servicing infrastructure.'
                })
                continue
            }
            $protHit = $null
            foreach ($pat in $protectedPatterns) {
                if ($pkg -like ('*' + $pat + '*')) { $protHit = [string]$pat; break }
            }
            if ($protHit) {
                $reasonText = ''
                if ($RemoveReasons.ContainsKey($pkg)) { $reasonText = [string]$RemoveReasons[$pkg] }
                if ($reasonText -notmatch '(?i)justif') {
                    $decision.removals_blocked.Add([pscustomobject]@{
                        Package = $pkg
                        Reason  = 'Protected component (matches ' + $protHit + '): requires -AllowRemoval AND an explicit technical justification in -RemoveReasons.'
                    })
                    continue
                }
            }
            $reasonText2 = ''
            if ($RemoveReasons.ContainsKey($pkg)) { $reasonText2 = [string]$RemoveReasons[$pkg] }
            if (-not $reasonText2) {
                $decision.removals_blocked.Add([pscustomobject]@{
                    Package = $pkg
                    Reason  = 'Every removal requires a documented reason in -RemoveReasons (reason, expected consequences, rollback method).'
                })
                continue
            }
            $decision.removals_authorized.Add([pscustomobject]@{
                Package                = $pkg
                Reason                 = $reasonText2
                ExpectedConsequences   = 'Recorded in the reason above; dependent components may fail and must be re-validated.'
                RollbackMethod         = 'Restore the pre-servicing WIM from Backup\ (created by Phase 4) and rebuild media.'
                DependencyAnalysis     = if ($SkipDependencyAnalysis) { 'SKIPPED (explicit -SkipDependencyAnalysis)' } else { 'performed at removal time via dism /Get-PackageInfo on the mounted image' }
            })
        }
        $decisionPath = Join-Path $full 'Reports\PROFILE-DECISION.json'
        $decisionTxtPath = Join-Path $full 'Reports\PROFILE-DECISION.txt'
        Write-WinISOJsonFile -Path $decisionPath -Object $decision
        $txtSb = New-Object System.Text.StringBuilder
        [void]$txtSb.AppendLine('CUSTOMIZATION PROFILE DECISION')
        [void]$txtSb.AppendLine('Profile: ' + $Profile)
        [void]$txtSb.AppendLine('Removals requested: ' + @($RemovePackages).Count)
        [void]$txtSb.AppendLine('Removals authorized: ' + @($decision.removals_authorized).Count)
        [void]$txtSb.AppendLine('Removals blocked: ' + @($decision.removals_blocked).Count)
        foreach ($b in @($decision.removals_blocked)) { [void]$txtSb.AppendLine('  BLOCKED: ' + $b.Package + ' - ' + $b.Reason) }
        foreach ($a in @($decision.removals_authorized)) { [void]$txtSb.AppendLine('  AUTHORIZED: ' + $a.Package + ' - ' + $a.Reason) }
        foreach ($n in @($decision.notes)) { [void]$txtSb.AppendLine('  NOTE: ' + $n) }
        Write-WinISOFile -Path $decisionTxtPath -Content $txtSb.ToString()
        $r.Artifacts['profile-decision.json'] = $decisionPath
        $r.Artifacts['profile-decision.txt'] = $decisionTxtPath

        $servicedImage = Test-Path -LiteralPath (Join-Path $full 'Reports\SERVICING-RESULTS.json')
        if (@($decision.removals_authorized).Count -gt 0 -and $servicedImage) {
            # Removal execution on the serviced WIM (mount -> analyze -> remove -> commit).
            $installWim = ''
            foreach ($n in @('install.wim', 'install.esd')) {
                if (Test-Path -LiteralPath (Join-Path $full ('ExtractedISO\sources\' + $n))) { $installWim = Join-Path $full ('ExtractedISO\sources\' + $n); break }
            }
            if ($installWim) {
                $mountDir = Join-Path $full 'Mount\ImageRemoval'
                if (-not (Test-Path -LiteralPath $mountDir)) { [void](New-Item -ItemType Directory -Path $mountDir -Force) }
                $mounted = $false
                try {
                    $m = Invoke-WinISODism -Arguments @('/English', '/Mount-Image', ('/ImageFile:' + $installWim), ('/Index:1'), ('/MountDir:' + $mountDir)) -TimeoutSeconds 2400 -LogPath $log
                    if ($m.ExitCode -ne 0) { throw ('Removal mount failed (exit ' + $m.ExitCode + ')') }
                    $mounted = $true
                    $pkgs = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Get-Packages') -TimeoutSeconds 1800 -LogPath $log
                    foreach ($auth in @($decision.removals_authorized)) {
                        $pkgName = ''
                        $pkgMatch = [regex]::Match([string]$pkgs.Output, '(?im)^Package Identity\s*:\s*(.*' + [regex]::Escape([string]$auth.Package) + '.*)$')
                        if ($pkgMatch.Success) { $pkgName = $pkgMatch.Groups[1].Value.Trim() }
                        if (-not $pkgName) {
                            $decision.removal_applied.Add([pscustomobject]@{ Package = $auth.Package; Result = 'not-found'; Note = 'No installed package identity matches.' })
                            continue
                        }
                        if (-not $SkipDependencyAnalysis) {
                            $info = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Get-PackageInfo', ('/PackageName:' + $pkgName)) -TimeoutSeconds 900 -LogPath $log
                            Add-WinISOLogLine -Path $log -Line ('Dependency analysis for ' + $pkgName + ':' + "`r`n" + [string]$info.Output)
                        }
                        $rm = Invoke-WinISODism -Arguments @('/English', ('/Image:' + $mountDir), '/Remove-Package', ('/PackageName:' + $pkgName), '/NoRestart') -TimeoutSeconds 2400 -LogPath $log
                        if ($rm.ExitCode -eq 0) {
                            $decision.removal_applied.Add([pscustomobject]@{ Package = $auth.Package; Result = 'removed'; Note = 'Package identity: ' + $pkgName })
                        }
                        else {
                            $cls = Get-WinISODismErrorClass -ExitCode $rm.ExitCode -Output $rm.Output
                            $decision.removal_applied.Add([pscustomobject]@{ Package = $auth.Package; Result = $cls.Class; Note = $cls.Description })
                            $r.Errors.Add('Removal of ' + $auth.Package + ' failed: ' + $cls.Class + ' - ' + $cls.Description)
                        }
                    }
                    $u = Invoke-WinISODism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Commit') -TimeoutSeconds 2400 -LogPath $log
                    $mounted = $false
                    if ($u.ExitCode -ne 0) { $r.Errors.Add('Removal commit failed (exit ' + $u.ExitCode + ').') }
                    Add-WinISOLogLine -Path $log -Line 'Removal pass committed.'
                }
                finally {
                    if ($mounted) {
                        $null = Invoke-WinISODism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Discard') -TimeoutSeconds 1200 -LogPath $log
                        Add-WinISOLogLine -Path $log -Line 'Removal mount discarded by guaranteed cleanup.'
                        $r.Errors.Add('Removal mount was discarded after a failure; no removal changes were kept.')
                    }
                }
                Write-WinISOJsonFile -Path $decisionPath -Object $decision
                $r.Steps.Add('Removal pass executed on the serviced WIM (see PROFILE-DECISION.json).')
            }
            else {
                $r.Errors.Add('Removals authorized but no extracted WIM exists under ExtractedISO\sources\.')
            }
        }
        elseif (@($decision.removals_authorized).Count -gt 0) {
            $r.Status = 'Skipped'
            $r.Reason = 'Removals were authorized but no serviced image is present (SERVICING-RESULTS.json missing); nothing to apply. The decision manifest is recorded in Reports\PROFILE-DECISION.json.'
            $r.Summary = $r.Reason
            return $r
        }
        $r.Steps.Add('Profile decision recorded: ' + $Profile)
        $r.Summary = 'Profile ' + $Profile + ' applied as a decision manifest; removals authorized=' + @($decision.removals_authorized).Count + ', blocked=' + @($decision.removals_blocked).Count + '.'
        if ($r.Errors.Count -gt 0) { $r.Status = 'Failed' }
        else { $r.Status = 'Succeeded' }
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Customization profile threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 7 - Boot media rebuild (oscdimg; split-WIM strategy for > 4 GiB)
# ---------------------------------------------------------------------------

function Copy-WinISOFullMedia {
    # Full read-only extraction of an ISO into the destination directory.
    param([string]$SourceIso, [string]$DestDir, [string]$LogPath = '')
    $mountedIso = $null
    try {
        if (-not (Test-Path -LiteralPath $DestDir)) { [void](New-Item -ItemType Directory -Path $DestDir -Force) }
        $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
        $mountedIso = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
        $letter = ''
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            Start-Sleep -Milliseconds 500
            $after = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $newLetters = @($after | Where-Object { $before -notcontains $_ })
            foreach ($l in $newLetters) {
                if (Test-Path -LiteralPath ($l + ':\sources\boot.wim')) { $letter = $l; break }
            }
            if (-not $letter -and $newLetters.Count -gt 0) { $letter = $newLetters[0] }
            if ($letter) { break }
        }
        if (-not $letter) { return @{ Ok = $false; Error = 'ISO attached but no drive letter was assigned.' } }
        Copy-Item -Path ($letter + ':\*') -Destination $DestDir -Recurse -Force
        Get-ChildItem -LiteralPath $DestDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
        if ($LogPath) { Add-WinISOLogLine -Path $LogPath -Line ('Full media extraction: ' + $SourceIso + ' -> ' + $DestDir) }
        return @{ Ok = $true; Error = '' }
    }
    catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
    finally {
        if ($mountedIso) {
            try { Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
}

function Invoke-WinISORebuildMedia {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [string]$OutputIsoName = ''
    )
    $r = Get-WinISOResult -Phase 7 -Name 'Boot media rebuild'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase7-RebuildMedia'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $mediaRoot = Join-Path $full 'ExtractedISO'
        $sourcesDir = Join-Path $mediaRoot 'sources'
        if (-not (Test-Path -LiteralPath (Join-Path $sourcesDir 'boot.wim'))) {
            $r.Status = 'Skipped'
            $r.Reason = 'No extracted media tree (ExtractedISO\sources\boot.wim missing). Media rebuild requires the extracted media from Phase 2/4.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $installWim = ''
        foreach ($n in @('install.wim', 'install.esd')) {
            if (Test-Path -LiteralPath (Join-Path $sourcesDir $n)) { $installWim = Join-Path $sourcesDir $n; break }
        }
        if (-not $installWim) {
            $r.Status = 'Failed'
            $r.Errors.Add('install.wim/install.esd missing from ExtractedISO\sources\; nothing to rebuild.')
            $r.Summary = 'No install image in the extracted tree.'
            return $r
        }
        # Full extraction if the media tree is incomplete and a source ISO was given.
        if ($SourceIso -and (Test-Path -LiteralPath $SourceIso -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $mediaRoot 'boot\etfsboot.com'))) {
            $extract = Copy-WinISOFullMedia -SourceIso $SourceIso -DestDir $mediaRoot -LogPath $log
            if (-not $extract.Ok) {
                $r.Status = 'Failed'
                $r.Errors.Add('Full media extraction failed: ' + $extract.Error)
                $r.Summary = 'Media extraction failed.'
                return $r
            }
            $r.Steps.Add('Extracted full media tree from the source ISO into ExtractedISO\.')
        }
        # oscdimg is required - detect and error clearly if missing.
        $osc = Find-WinISOOscdimg
        if (-not $osc) {
            $r.Status = 'Failed'
            $r.Errors.Add('oscdimg.exe not found. Install the Windows ADK Deployment Tools (https://learn.microsoft.com/windows-hardware/get-started/adk-install) and re-run. No ISO was produced.')
            $r.Summary = 'oscdimg.exe missing.'
            return $r
        }
        # Boot structure validation - never emit a silently non-bootable ISO.
        $etfs = Join-Path $mediaRoot 'boot\etfsboot.com'
        $efisys = Join-Path $mediaRoot 'efi\microsoft\boot\efisys.bin'
        if (-not (Test-Path -LiteralPath $etfs)) {
            $r.Status = 'Failed'
            $r.Errors.Add('BIOS boot file missing: boot\etfsboot.com (would produce a non-bootable ISO).')
            $r.Summary = 'BIOS boot file missing.'
            return $r
        }
        if (-not (Test-Path -LiteralPath $efisys)) {
            $r.Status = 'Failed'
            $r.Errors.Add('UEFI boot file missing: efi\microsoft\boot\efisys.bin (would produce a non-UEFI-bootable ISO).')
            $r.Summary = 'UEFI boot file missing.'
            return $r
        }
        # Overlay media-root autounattend.xml (supported setup mechanism).
        $ua = Join-Path $full 'Output\unattend.xml'
        if (Test-Path -LiteralPath $ua) {
            Copy-Item -LiteralPath $ua -Destination (Join-Path $mediaRoot 'autounattend.xml') -Force
            $r.Steps.Add('Overlaid media-root autounattend.xml (supported setup mechanism).')
        }
        # Label (sanitized: uppercase letters/digits/underscore only, <= 32 chars).
        $label = 'WINDOWSINSTALL'
        $buildStr = 'unknown'
        $archStr = 'unknown'
        $invPath = Join-Path $full 'Reports\ISO-INVENTORY.json'
        if (Test-Path -LiteralPath $invPath) {
            try {
                $inv = Get-Content -LiteralPath $invPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($inv.detected.build) { $buildStr = [string]$inv.detected.build }
                if ($inv.detected.architecture) { $archStr = [string]$inv.detected.architecture }
                $candidate = ('WIN_' + $buildStr + '_' + $archStr) -replace '[^A-Za-z0-9_]', '_'
                $label = $candidate.Substring(0, [math]::Min(32, $candidate.Length))
            }
            catch { $label = 'WINDOWSINSTALL' }
        }
        # Output naming
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $isoName = $OutputIsoName
        if (-not $isoName) { $isoName = ('WinISO-' + $buildStr + '-' + $archStr + '-' + $stamp + '.iso') }
        if ($isoName -notmatch '\.iso$') { $isoName += '.iso' }
        $isoPath = Join-Path (Join-Path $full 'Output') $isoName

        # Build the UDF ISO with BIOS + UEFI boot entries.
        $bootdata = '2#p0,e,b"' + $etfs + '"#pEF,e,b"' + $efisys + '"'
        $build = Invoke-WinISOProcess -FilePath $osc -ArgumentList @(
            '-m', '-o', '-u2', '-udfver102',
            ('-bootdata:' + $bootdata),
            ('-l' + $label),
            ('"' + $mediaRoot + '"'),
            ('"' + $isoPath + '"')
        ) -TimeoutSeconds 3600 -LogPath $log
        if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $isoPath)) {
            $r.Status = 'Failed'
            $r.Errors.Add('oscdimg failed (exit ' + $build.ExitCode + '): ' + $build.Output)
            $r.Summary = 'oscdimg build failed.'
            return $r
        }
        $r.Artifacts['output.iso'] = $isoPath
        $r.Steps.Add('Built ' + $isoPath + ' with oscdimg (BIOS + UEFI boot, UDF).')

        # > 4 GiB install.wim strategy: split into .swm for FAT32 media
        # alongside the single UDF ISO. Never blindly compress or convert.
        $wimFile = Get-Item -LiteralPath $installWim
        $mediaReport = [ordered]@{
            generated_utc = [DateTime]::UtcNow.ToString('o')
            oscdimg_path  = $osc
            label         = $label
            udf_iso       = $isoPath
            install_wim_bytes = [long]$wimFile.Length
            split_required = ($wimFile.Length -gt 4GB)
            split_files   = @()
            fat32_iso     = ''
        }
        if ($wimFile.Length -gt 4GB) {
            Add-WinISOLogLine -Path $log -Line ('install.wim is ' + [math]::Round($wimFile.Length / 1GB, 2) + ' GiB (> 4 GiB): applying the split-WIM (FAT32 media) strategy.')
            $staging = Join-Path $full 'Output\FAT32-Media'
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            Copy-Item -Path (Join-Path $mediaRoot '*') -Destination $staging -Recurse -Force
            $stagingInstall = Join-Path $staging ('sources\' + [System.IO.Path]::GetFileName($installWim))
            if (Test-Path -LiteralPath $stagingInstall) { Remove-Item -LiteralPath $stagingInstall -Force }
            $swmBase = Join-Path $staging 'sources\install.swm'
            $sp = Invoke-WinISODism -Arguments @('/English', '/Split-Image', ('/ImageFile:' + $installWim), ('/SWMFile:' + $swmBase), '/FileSize:3800') -TimeoutSeconds 3600 -LogPath $log
            if ($sp.ExitCode -ne 0) {
                $r.Errors.Add('dism /Split-Image failed (exit ' + $sp.ExitCode + '). The UDF ISO was still produced; FAT32 media is unavailable for this run.')
                Add-WinISOLogLine -Path $log -Line 'Split-WIM generation failed; UDF ISO remains valid.'
            }
            else {
                $mediaReport.split_files = @((Get-ChildItem -LiteralPath (Join-Path $staging 'sources') -Filter 'install*.swm' -File | ForEach-Object { $_.Name }))
                # Verify no file in the staging tree exceeds the FAT32 limit.
                $oversized = @(Get-ChildItem -LiteralPath $staging -Recurse -File | Where-Object { $_.Length -gt 4GB })
                if ($oversized.Count -gt 0) {
                    $r.Errors.Add('FAT32 staging still contains file(s) larger than 4 GiB: ' + ($oversized.Name -join ', '))
                }
                $fat32Iso = Join-Path (Join-Path $full 'Output') ($isoName -replace '\.iso$', '-FAT32-split.iso')
                $build2 = Invoke-WinISOProcess -FilePath $osc -ArgumentList @(
                    '-m', '-o', '-u2', '-udfver102',
                    ('-bootdata:' + $bootdata),
                    ('-l' + $label),
                    ('"' + $staging + '"'),
                    ('"' + $fat32Iso + '"')
                ) -TimeoutSeconds 3600 -LogPath $log
                if ($build2.ExitCode -eq 0 -and (Test-Path -LiteralPath $fat32Iso)) {
                    $mediaReport.fat32_iso = $fat32Iso
                    $r.Artifacts['output-fat32-split.iso'] = $fat32Iso
                    $r.Steps.Add('Built split-WIM FAT32 media ISO: ' + $fat32Iso)
                }
                else {
                    $r.Errors.Add('FAT32 split ISO build failed (oscdimg exit ' + $build2.ExitCode + ').')
                }
            }
        }
        $reportPath = Join-Path $full 'Reports\MEDIA-BUILD-REPORT.json'
        $reportTxtPath = Join-Path $full 'Reports\MEDIA-BUILD-REPORT.txt'
        Write-WinISOJsonFile -Path $reportPath -Object $mediaReport
        $txtSb = New-Object System.Text.StringBuilder
        [void]$txtSb.AppendLine('MEDIA BUILD REPORT')
        [void]$txtSb.AppendLine('oscdimg: ' + $osc)
        [void]$txtSb.AppendLine('UDF ISO: ' + $isoPath)
        [void]$txtSb.AppendLine('install.wim bytes: ' + $mediaReport.install_wim_bytes)
        [void]$txtSb.AppendLine('Split required (> 4 GiB): ' + $mediaReport.split_required)
        [void]$txtSb.AppendLine('Split files: ' + (@($mediaReport.split_files) -join ', '))
        [void]$txtSb.AppendLine('FAT32 ISO: ' + $mediaReport.fat32_iso)
        Write-WinISOFile -Path $reportTxtPath -Content $txtSb.ToString()
        $r.Artifacts['media-build-report.json'] = $reportPath
        $r.Artifacts['media-build-report.txt'] = $reportTxtPath

        # Verify the built ISO: attach read-only and check core structure.
        $attach = $null
        try {
            $attach = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
            $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $after = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $newLetters = @($after | Where-Object { $before -notcontains $_ })
            $letter = ''
            foreach ($l in $newLetters) {
                if (Test-Path -LiteralPath ($l + ':\sources\boot.wim')) { $letter = $l; break }
            }
            if (-not $letter -and $newLetters.Count -gt 0) { $letter = $newLetters[0] }
            if ($letter) {
                $okBoot = Test-Path -LiteralPath ($letter + ':\sources\boot.wim')
                $okInstall = Test-Path -LiteralPath ($letter + ':\sources\install.wim') -or (Test-Path -LiteralPath ($letter + ':\sources\install.esd'))
                $okBios = Test-Path -LiteralPath ($letter + ':\boot\etfsboot.com')
                $okUefi = Test-Path -LiteralPath ($letter + ':\efi\microsoft\boot\efisys.bin')
                $r.Steps.Add('Built ISO structure check: boot.wim=' + $okBoot + ' install.wim/esd=' + $okInstall + ' etfsboot.com=' + $okBios + ' efisys.bin=' + $okUefi)
                if (-not ($okBoot -and $okInstall)) {
                    $r.Errors.Add('Built ISO is missing boot.wim or install.wim/esd under sources\.')
                }
            }
        }
        finally {
            if ($attach) { try { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null } catch { } }
        }
        if ($r.Errors.Count -gt 0) { $r.Status = 'Failed' } else { $r.Status = 'Succeeded' }
        $r.Summary = 'Media rebuilt: ' + $isoPath + ' (' + $(if ($mediaReport.split_required) { 'split-WIM FAT32 media also produced' } else { 'no split required' }) + ').'
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Boot media rebuild threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 8 - Validation (health, integrity, boot structure, hashes, compare)
# ---------------------------------------------------------------------------

function Invoke-WinISOValidate {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = ''
    )
    $r = Get-WinISOResult -Phase 8 -Name 'Validation'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase8-Validation'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $isos = @(Get-ChildItem -LiteralPath (Join-Path $full 'Output') -Filter *.iso -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($isos.Count -eq 0) {
            $r.Status = 'Skipped'
            $r.Reason = 'No rebuilt ISO exists in Output\. Build media first (Phase 7).'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $iso = $isos[0]
        $checks = New-Object 'System.Collections.Generic.List[System.Management.Automation.PSObject]'
        $attach = $null
        $letter = ''
        try {
            # SHA-256 of the final ISO.
            $hash = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash
            $hashPath = Join-Path $full 'Output\ISO-SHA256.txt'
            $hashSb = New-Object System.Text.StringBuilder
            [void]$hashSb.AppendLine('ISO file : ' + $iso.FullName)
            [void]$hashSb.AppendLine('Size     : ' + $iso.Length + ' bytes')
            [void]$hashSb.AppendLine('SHA-256  : ' + $hash)
            [void]$hashSb.AppendLine('Date     : ' + [DateTime]::UtcNow.ToString('o'))
            Write-WinISOFile -Path $hashPath -Content $hashSb.ToString()
            $r.Artifacts['iso-sha256.txt'] = $hashPath
            $checks.Add([pscustomobject]@{ Check = 'ISO SHA-256 computed'; Result = 'PASS'; Detail = $hash })

            # Attach read-only and validate boot structure.
            $attach = Mount-DiskImage -ImagePath $iso.FullName -PassThru -ErrorAction Stop
            $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $after = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $newLetters = @($after | Where-Object { $before -notcontains $_ })
            foreach ($l in $newLetters) {
                if (Test-Path -LiteralPath ($l + ':\sources\boot.wim')) { $letter = $l; break }
            }
            if (-not $letter -and $newLetters.Count -gt 0) { $letter = $newLetters[0] }
            if ($letter) {
                $checkPairs = @(
                    @{ Check = 'BIOS boot manager (bootmgr)'; Path = 'bootmgr' },
                    @{ Check = 'UEFI boot file (efi\boot\bootx64.efi)'; Path = 'efi\boot\bootx64.efi' },
                    @{ Check = 'BIOS boot sector file (boot\etfsboot.com)'; Path = 'boot\etfsboot.com' },
                    @{ Check = 'UEFI boot image (efi\microsoft\boot\efisys.bin)'; Path = 'efi\microsoft\boot\efisys.bin' },
                    @{ Check = 'Setup boot image (sources\boot.wim)'; Path = 'sources\boot.wim' }
                )
                foreach ($cp in $checkPairs) {
                    if (Test-Path -LiteralPath ($letter + ':\' + $cp.Path)) {
                        $checks.Add([pscustomobject]@{ Check = $cp.Check; Result = 'PASS'; Detail = $cp.Path + ' present' })
                    }
                    else {
                        $checks.Add([pscustomobject]@{ Check = $cp.Check; Result = 'FAIL'; Detail = $cp.Path + ' missing' })
                    }
                }
                $hasInstall = (Test-Path -LiteralPath ($letter + ':\sources\install.wim')) -or (Test-Path -LiteralPath ($letter + ':\sources\install.esd')) -or ((Get-ChildItem -LiteralPath ($letter + ':\sources') -Filter 'install*.swm' -File -ErrorAction SilentlyContinue).Count -gt 0)
                $checks.Add([pscustomobject]@{ Check = 'Install image present (wim/esd/swm)'; Result = $(if ($hasInstall) { 'PASS' } else { 'FAIL' }); Detail = 'sources\install.wim|esd|install*.swm' })

                # WIM integrity + source-vs-destination inventory comparison.
                $newInstall = $null
                foreach ($n in @('install.wim', 'install.esd')) {
                    if (Test-Path -LiteralPath ($letter + ':\sources\' + $n)) { $newInstall = $letter + ':\sources\' + $n; break }
                }
                if ($newInstall) {
                    $wi = Get-WinISOWimInfo -WimPath $newInstall -LogPath $log
                    if ($wi.ExitCode -eq 0 -and @($wi.Indexes).Count -gt 0) {
                        $checks.Add([pscustomobject]@{ Check = 'Rebuilt WIM readable (dism /Get-WimInfo)'; Result = 'PASS'; Detail = (@($wi.Indexes).Count.ToString() + ' index(es)') })
                        $invPath = Join-Path $full 'Reports\ISO-INVENTORY.json'
                        if (Test-Path -LiteralPath $invPath) {
                            try {
                                $inv = Get-Content -LiteralPath $invPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                $srcCount = 0
                                foreach ($wf in @($inv.wim_files)) {
                                    if ($wf.kind -eq 'install') { $srcCount = @($wf.images).Count }
                                }
                                $newNames = @($wi.Indexes | ForEach-Object { [string]$_.Name } | Sort-Object)
                                $srcNames = @()
                                foreach ($wf in @($inv.wim_files)) {
                                    if ($wf.kind -eq 'install') { $srcNames = @($wf.images | ForEach-Object { [string]$_.name } | Sort-Object) }
                                }
                                $same = ($newNames.Count -eq $srcNames.Count) -and (@(Compare-Object $newNames $srcNames).Count -eq 0)
                                $checks.Add([pscustomobject]@{ Check = 'Source-vs-destination inventory comparison'; Result = $(if ($same) { 'PASS' } else { 'FAIL' }); Detail = ('source indexes=' + $srcNames.Count + ', rebuilt indexes=' + $newNames.Count + ', names match=' + $same) })
                            }
                            catch {
                                $checks.Add([pscustomobject]@{ Check = 'Source-vs-destination inventory comparison'; Result = 'FAIL'; Detail = 'could not read ISO-INVENTORY.json: ' + $_.Exception.Message })
                            }
                        }
                        else {
                            $checks.Add([pscustomobject]@{ Check = 'Source-vs-destination inventory comparison'; Result = 'NA'; Detail = 'no source inventory recorded (Phase 2 never ran)' })
                        }
                    }
                    else {
                        $checks.Add([pscustomobject]@{ Check = 'Rebuilt WIM readable (dism /Get-WimInfo)'; Result = 'FAIL'; Detail = 'exit ' + $wi.ExitCode })
                    }
                }
            }
            else {
                $checks.Add([pscustomobject]@{ Check = 'ISO attach (read-only)'; Result = 'FAIL'; Detail = 'no drive letter assigned' })
            }
            # Component-store deep health is performed at mount time in Phase 4
            # (see SERVICING-RESULTS.json); recorded here for completeness.
            $checks.Add([pscustomobject]@{ Check = 'Component-store health (CheckHealth)'; Result = 'NA'; Detail = 'verified in Phase 4 at mount time; see Reports\SERVICING-RESULTS.json' })
        }
        finally {
            if ($attach) { try { Dismount-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue | Out-Null } catch { } }
        }

        $htmlPath = Join-Path $full 'Reports\FINAL-VALIDATION-REPORT.html'
        $txtPath = Join-Path $full 'Reports\FINAL-VALIDATION-REPORT.txt'
        Write-WinISOFile -Path $htmlPath -Content (New-WinISOValidationHtml -IsoName $iso.FullName -Sha256 $hash -Checks @($checks) -GeneratedUtc ([DateTime]::UtcNow.ToString('o')))
        $txtSb = New-Object System.Text.StringBuilder
        [void]$txtSb.AppendLine('FINAL VALIDATION REPORT')
        [void]$txtSb.AppendLine('ISO: ' + $iso.FullName)
        [void]$txtSb.AppendLine('SHA-256: ' + $hash)
        foreach ($c in @($checks)) { [void]$txtSb.AppendLine('[' + $c.Result + '] ' + $c.Check + ' - ' + $c.Detail) }
        Write-WinISOFile -Path $txtPath -Content $txtSb.ToString()
        $r.Artifacts['final-validation-report.html'] = $htmlPath
        $r.Artifacts['final-validation-report.txt'] = $txtPath
        $r.Steps.Add('Validation checks executed: ' + @($checks).Count)

        $failCount = @($checks | Where-Object { $_.Result -eq 'FAIL' }).Count
        if ($failCount -gt 0) {
            $r.Status = 'Failed'
            $r.Summary = 'Validation found ' + $failCount + ' FAILED check(s).'
            foreach ($c in @($checks | Where-Object { $_.Result -eq 'FAIL' })) { $r.Errors.Add($c.Check + ': ' + $c.Detail) }
        }
        else {
            $r.Status = 'Succeeded'
            $r.Summary = 'All applicable validation checks passed for ' + $iso.Name + '.'
        }
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Validation threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

function New-WinISOValidationHtml {
    param([string]$IsoName, [string]$Sha256, [object[]]$Checks, [string]$GeneratedUtc)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html><head><meta charset="utf-8"><title>ISO validation report</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em}table{border-collapse:collapse}td,th{border:1px solid #999;padding:4px 8px}.pass{color:#0a0}.fail{color:#a00}.na{color:#888}</style></head><body>')
    [void]$sb.AppendLine('<h1>Windows ISO servicing - final validation</h1>')
    [void]$sb.AppendLine('<p>ISO: ' + [System.Net.WebUtility]::HtmlEncode($IsoName) + '<br>SHA-256: ' + $Sha256 + '<br>Generated (UTC): ' + $GeneratedUtc + '</p>')
    [void]$sb.AppendLine('<table><tr><th>Check</th><th>Result</th><th>Detail</th></tr>')
    foreach ($c in @($Checks)) {
        $cls = 'pass'
        if ([string]$c.Result -eq 'FAIL') { $cls = 'fail' }
        if ([string]$c.Result -eq 'NA') { $cls = 'na' }
        [void]$sb.AppendLine('<tr><td>' + [System.Net.WebUtility]::HtmlEncode([string]$c.Check) + '</td><td class="' + $cls + '">' + [System.Net.WebUtility]::HtmlEncode([string]$c.Result) + '</td><td>' + [System.Net.WebUtility]::HtmlEncode([string]$c.Detail) + '</td></tr>')
    }
    [void]$sb.AppendLine('</table></body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# PHASE 9 - Test installation (plan generation only; never auto-runs)
# ---------------------------------------------------------------------------

function Invoke-WinISOVmTest {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = '',
        [string]$VmName = 'WinISO-TestVM',
        [string]$Hypervisor = 'Auto'
    )
    $r = Get-WinISOResult -Phase 9 -Name 'Test installation'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase9-VmTest'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $iso = ''
        if ($SourceIso -and (Test-Path -LiteralPath $SourceIso -PathType Leaf)) { $iso = $SourceIso }
        else {
            $isos = @(Get-ChildItem -LiteralPath (Join-Path $full 'Output') -Filter *.iso -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($isos.Count -gt 0) { $iso = [string]$isos[0].FullName }
        }
        if (-not $iso) {
            $r.Status = 'Skipped'
            $r.Reason = 'No ISO available to test (build one via Phase 7 or pass -SourceIso).'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $generator = Join-Path $PSScriptRoot 'Test-ISOInVM.ps1'
        if (-not (Test-Path -LiteralPath $generator)) {
            $r.Status = 'Failed'
            $r.Errors.Add('Test-ISOInVM.ps1 not found next to the module: ' + $generator)
            $r.Summary = 'VM test generator script missing.'
            return $r
        }
        $gen = & $generator -IsoPath $iso -VmName $VmName -Hypervisor $Hypervisor -Action Generate -OutputDir (Join-Path $full 'Output\VM-Test')
        foreach ($k in @($gen.Artifacts.Keys)) {
            $r.Artifacts[$k] = [string]$gen.Artifacts[$k]
        }
        $r.Steps.Add('Hypervisor detection: Hyper-V=' + $gen.HyperVisorDetected.HyperV + ', VirtualBox=' + $gen.HyperVisorDetected.VirtualBox + ', chosen=' + $gen.ChosenHypervisor)
        $r.Steps.Add('Generated VM definition and test plan; NO virtual machine was created or started and NO unattended install was triggered.')
        $r.Status = 'Skipped'
        $r.Reason = 'Test plan generated only. Installation tests are never executed automatically; success is only claimed after an operator runs the plan and every checklist item is recorded as passed.'
        $r.Summary = $r.Reason
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Test installation threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

# ---------------------------------------------------------------------------
# PHASE 10 - Final report
# ---------------------------------------------------------------------------

function Invoke-WinISOFinalReport {
    [CmdletBinding()]
    param(
        [string]$Workspace = $script:DefaultWorkspace,
        [string]$SourceIso = ''
    )
    $r = Get-WinISOResult -Phase 10 -Name 'Final report'
    $log = New-WinISOLogPath -Workspace $Workspace -Tag 'Phase10-FinalReport'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $full = [System.IO.Path]::GetFullPath($Workspace)
        $invPath = Join-Path $full 'Reports\ISO-INVENTORY.json'
        if (-not (Test-Path -LiteralPath $invPath)) {
            $r.Status = 'Skipped'
            $r.Reason = 'No ISO inventory exists (Phase 2 never succeeded); there is nothing to report.'
            $r.Summary = $r.Reason
            Add-WinISOLogLine -Path $log -Line ('SKIPPED: ' + $r.Reason)
            return $r
        }
        $state = Read-WinISOState -Workspace $full
        $md = New-WinISOFinalReportMarkdown -Workspace $full -State $state
        $reportPath = Join-Path $full 'Reports\FINAL-REPORT.md'
        Write-WinISOFile -Path $reportPath -Content $md
        $r.Artifacts['final-report.md'] = $reportPath
        $r.Steps.Add('Aggregated inventories, state and test results into ' + $reportPath)
        $r.Status = 'Succeeded'
        $r.Summary = 'Final report written to ' + $reportPath
        $r.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        return $r
    }
    catch {
        $msg = $_.Exception.Message
        $r.Status = 'Failed'
        $r.Errors.Add($msg)
        $r.Summary = 'Final report threw an exception: ' + $msg
        Add-WinISOLogLine -Path $log -Line ('EXCEPTION: ' + $msg)
        return $r
    }
}

function New-WinISOFinalReportMarkdown {
    param([string]$Workspace, [object]$State)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Windows ISO servicing - final report')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Generated (UTC): ' + [DateTime]::UtcNow.ToString('o'))
    [void]$sb.AppendLine('')
    $helper = {
        param($RelPath)
        $p = Join-Path $Workspace $RelPath
        if (Test-Path -LiteralPath $p) {
            try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
        }
        return $null
    }
    $inv = & $helper 'Reports\ISO-INVENTORY.json'
    $manifest = & $helper 'Reports\UPDATE-MANIFEST.json'
    $servicing = & $helper 'Reports\SERVICING-RESULTS.json'
    $decision = & $helper 'Reports\PROFILE-DECISION.json'
    $validationTxt = ''
    $valPath = Join-Path $Workspace 'Reports\FINAL-VALIDATION-REPORT.txt'
    if (Test-Path -LiteralPath $valPath) { $validationTxt = Get-Content -LiteralPath $valPath -Raw -Encoding UTF8 }
    $hashTxt = ''
    $hashPath = Join-Path $Workspace 'Output\ISO-SHA256.txt'
    if (Test-Path -LiteralPath $hashPath) { $hashTxt = Get-Content -LiteralPath $hashPath -Raw -Encoding UTF8 }

    [void]$sb.AppendLine('## Source')
    if ($inv) {
        [void]$sb.AppendLine('| Field | Value |')
        [void]$sb.AppendLine('|---|---|')
        [void]$sb.AppendLine('| Source ISO | ' + [string]$inv.source.path + ' |')
        [void]$sb.AppendLine('| Source build | ' + [string]$inv.detected.build + '.' + [string]$inv.detected.revision + ' |')
        [void]$sb.AppendLine('| Target build | ' + [string]$inv.detected.build + ' (unchanged; updates are additive) |')
        [void]$sb.AppendLine('| Architecture | ' + [string]$inv.detected.architecture + ' |')
        [void]$sb.AppendLine('| Language | ' + [string]$inv.detected.language + ' |')
        [void]$sb.AppendLine('| Editions | ' + (@($inv.detected.editions) -join ', ') + ' |')
        [void]$sb.AppendLine('| Source SHA-256 | ' + [string]$inv.source.sha256 + ' |')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Updates integrated / skipped')
    if ($servicing) {
        foreach ($img in @($servicing.images)) {
            [void]$sb.AppendLine('### Index ' + [string]$img.Index)
            foreach ($u in @($img.Updates)) { [void]$sb.AppendLine('- ' + [string]$u.Kb + ': **' + [string]$u.Result + '** - ' + [string]$u.Note) }
            foreach ($e in @($img.Errors)) { [void]$sb.AppendLine('- ERROR: ' + $e) }
        }
    }
    elseif ($manifest) {
        [void]$sb.AppendLine('No servicing was performed. Manifest status: ' + [string]$manifest.catalog_status)
    }
    else {
        [void]$sb.AppendLine('No update manifest or servicing results recorded.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Drivers integrated')
    if ($servicing -and $servicing.drivers_requested) {
        foreach ($img in @($servicing.images)) { [void]$sb.AppendLine('- Index ' + [string]$img.Index + ': ' + [string]$img.DriversAdded + ' driver package(s) added') }
    }
    else {
        [void]$sb.AppendLine('None (drivers were not requested).')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Configuration changes')
    $uaPath = Join-Path $Workspace 'Output\unattend.xml'
    if (Test-Path -LiteralPath $uaPath) { [void]$sb.AppendLine('- unattend.xml generated: ' + $uaPath + ' (media-root staging: autounattend.xml)') }
    if ($decision) {
        [void]$sb.AppendLine('- Profile: ' + [string]$decision.profile)
        [void]$sb.AppendLine('- Removals authorized: ' + @($decision.removals_authorized).Count + ', blocked: ' + @($decision.removals_blocked).Count)
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Components removed')
    if ($decision -and @($decision.removal_applied).Count -gt 0) {
        foreach ($rm in @($decision.removal_applied)) { [void]$sb.AppendLine('- ' + [string]$rm.Package + ' -> ' + [string]$rm.Result + ' - ' + [string]$rm.Note) }
    }
    else {
        [void]$sb.AppendLine('None.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Known limitations')
    [void]$sb.AppendLine('- Update catalog metadata is parsed from the public web UI; applicability is heuristically classified and must be reviewed before Phase 4.')
    [void]$sb.AppendLine('- Update downloads are intentionally out of scope; packages must be placed under Updates\ manually.')
    [void]$sb.AppendLine('- VM installation tests are never run automatically; success requires recorded, all-pass checklist results.')
    [void]$sb.AppendLine('- Deep component-store health is verified at mount time in Phase 4, not on the final ISO.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Test results')
    $vmDef = Join-Path $Workspace 'Output\VM-Test\VM-TEST-DEFINITION.json'
    if (Test-Path -LiteralPath $vmDef) {
        [void]$sb.AppendLine('VM definition generated (see Output\VM-Test\). Tests not executed by policy.')
    }
    else {
        [void]$sb.AppendLine('No VM test artifacts recorded.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Output media')
    $isos = @(Get-ChildItem -LiteralPath (Join-Path $Workspace 'Output') -Filter *.iso -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($isos.Count -gt 0) {
        foreach ($i in $isos) { [void]$sb.AppendLine('- ' + $i.FullName + ' (' + [math]::Round($i.Length / 1MB, 1) + ' MB)') }
        if ($hashTxt) { [void]$sb.AppendLine('```text'); [void]$sb.AppendLine($hashTxt.Trim()); [void]$sb.AppendLine('```') }
    }
    else {
        [void]$sb.AppendLine('No ISO produced yet.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Errors and resolutions (from STATE.json)')
    if ($State -and @($State.errors).Count -gt 0) {
        foreach ($e in @($State.errors)) { [void]$sb.AppendLine('- ' + $e) }
    }
    else {
        [void]$sb.AppendLine('- No errors recorded.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Reproducibility')
    [void]$sb.AppendLine('```powershell')
    [void]$sb.AppendLine('& D:\WimMount\Scripts\Invoke-WinISOService.ps1 -Workspace D:\WimMount -SourceIso <path-to-iso>')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('State file: State\STATE.json (restartable; completed phases are not re-run).')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Validation')
    if ($validationTxt) { [void]$sb.AppendLine('```text'); [void]$sb.AppendLine($validationTxt.Trim()); [void]$sb.AppendLine('```') }
    else { [void]$sb.AppendLine('No validation report recorded.') }
    return $sb.ToString()
}

Export-ModuleMember -Function *
