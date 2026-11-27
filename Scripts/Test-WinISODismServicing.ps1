# Test-WinISODismServicing.ps1
# Real DISM servicing smoke test for CI and for a local elevated run.
#
# SYNOPSIS
#   Mounts a small Windows image, adds a signed package with DISM
#   /Add-Package, commits the image and proves the package survived the commit.
#
# DESCRIPTION
#   A WIM captured from a plain folder cannot be serviced at all: DISM answers
#   "DISM does not support servicing a Windows Vista RTM or earlier operating
#   system" (error 50) because the image has no servicing stack, and a
#   hand-built package has no Microsoft catalog signature to accept. The
#   smallest image DISM will really take a package into is a WinPE image built
#   by copype from the Windows ADK, together with the ADK's own signed WinPE
#   optional components.
#
#   The test builds that image in a throwaway directory, mounts it, adds
#   WinPE-WMI (and its en-us language component when present), checks the
#   package is listed, unmounts with /Commit, mounts the committed image again
#   and checks the package is still there. It never touches a real ISO, a disk
#   or a USB drive.
#
# PARAMETER WorkDir
#   Scratch directory. Defaults to a WinISO-DismServicing folder under %TEMP%.
#   It is removed afterwards unless -KeepWorkDir is used.
#
# PARAMETER AdkRoot
#   Windows ADK root. Defaults to the standard
#   "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit".
#
# PARAMETER Architecture
#   WinPE architecture to build. Defaults to amd64.
#
# PARAMETER KeepWorkDir
#   Keep the generated WinPE media and logs for inspection.
#
# EXAMPLES
#   .\Test-WinISODismServicing.ps1
#   .\Test-WinISODismServicing.ps1 -WorkDir D:\Scratch\DismTest -KeepWorkDir
#
# Exit codes: 0 = the package was added and committed, 1 = the test failed or
# this host cannot run it (not elevated, ADK missing, DISM failed).

[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'WinISO-DismServicing'),
    [string]$AdkRoot = '',
    [string]$Architecture = 'amd64',
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host ('DISM-TEST: ' + $Text)
}

function Invoke-DismStep {
    param([string]$Name, [string[]]$Arguments)

    Write-Step $Name
    $output = & dism.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Write-Host ('  ' + [string]$line) }
    if ($code -ne 0) {
        throw ($Name + ' failed with DISM exit code ' + $code)
    }
    return (@($output) -join "`n")
}

function Find-AdkFile {
    param([string]$Root, [string]$Filter, [switch]$Directory)

    if (-not (Test-Path -LiteralPath $Root)) { return '' }
    $item = Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { if ($Directory) { $_.PSIsContainer } else { -not $_.PSIsContainer } } |
            Select-Object -First 1
    if ($item) { return $item.FullName }
    return ''
}

$mountDir = ''
$mounted = $false

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'DISM SERVICING FAILED: mounting an image needs an elevated session.'
        exit 1
    }

    if (-not $AdkRoot) {
        $candidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit'),
            (Join-Path $env:ProgramFiles 'Windows Kits\10\Assessment and Deployment Kit')
        )
        $AdkRoot = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $AdkRoot) { $AdkRoot = $candidates[0] }
    }
    Write-Step ('ADK root: ' + $AdkRoot)
    if (-not (Test-Path -LiteralPath $AdkRoot)) {
        Write-Host 'DISM SERVICING FAILED: the Windows ADK is not installed.'
        Write-Host 'Install the Deployment Tools and the WinPE add-on, for example:'
        Write-Host '  choco install windows-adk-deploy windows-adk-winpe --yes'
        exit 1
    }

    $copype = Find-AdkFile -Root $AdkRoot -Filter 'copype.cmd'
    if (-not $copype) {
        Write-Host 'DISM SERVICING FAILED: copype.cmd was not found in the ADK (is the Deployment Tools feature installed?).'
        exit 1
    }
    Write-Step ('copype: ' + $copype)

    $ocsRoot = Join-Path $AdkRoot ('Windows Preinstallation Environment\' + $Architecture)
    $ocs = Find-AdkFile -Root $ocsRoot -Filter 'WinPE_OCs' -Directory
    if (-not $ocs) {
        Write-Host ('DISM SERVICING FAILED: WinPE_OCs for ' + $Architecture + ' was not found (is the WinPE add-on installed?).')
        exit 1
    }
    Write-Step ('optional components: ' + $ocs)

    $package = Join-Path $ocs 'WinPE-WMI.cab'
    if (-not (Test-Path -LiteralPath $package)) {
        Write-Host ('DISM SERVICING FAILED: ' + $package + ' is missing.')
        exit 1
    }
    $languagePackage = Join-Path (Join-Path $ocs 'en-us') 'WinPE-WMI_en-us.cab'

    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $WorkDir -Force)

    $peDir = Join-Path $WorkDir 'WinPE'
    Write-Step ('building WinPE media in ' + $peDir)
    $copypeOutput = & $copype $Architecture $peDir 2>&1
    $copypeExit = $LASTEXITCODE
    foreach ($line in @($copypeOutput)) { Write-Host ('  ' + [string]$line) }
    if ($copypeExit -ne 0) {
        throw ('copype failed with exit code ' + $copypeExit)
    }

    $image = Join-Path $peDir 'media\sources\boot.wim'
    if (-not (Test-Path -LiteralPath $image)) {
        throw ('copype did not produce ' + $image)
    }
    Write-Step ('image: ' + $image + ' (' + [int]((Get-Item -LiteralPath $image).Length / 1MB) + ' MB)')

    $mountDir = Join-Path $peDir 'mount'
    if (-not (Test-Path -LiteralPath $mountDir)) {
        [void](New-Item -ItemType Directory -Path $mountDir -Force)
    }

    Invoke-DismStep -Name 'mount the image' -Arguments @(
        '/English', '/Mount-Image', ('/ImageFile:' + $image), '/Index:1', ('/MountDir:' + $mountDir)) | Out-Null
    $mounted = $true

    $before = Invoke-DismStep -Name 'list packages before' -Arguments @(
        '/English', ('/Image:' + $mountDir), '/Get-Packages')
    if ($before -match 'WinPE-WMI') {
        throw 'the image already contains WinPE-WMI, so the add cannot be verified'
    }

    $addArguments = @('/English', ('/Image:' + $mountDir), '/Add-Package', ('/PackagePath:' + $package))
    if (Test-Path -LiteralPath $languagePackage) {
        $addArguments += ('/PackagePath:' + $languagePackage)
    }
    Invoke-DismStep -Name 'add WinPE-WMI' -Arguments $addArguments | Out-Null

    $after = Invoke-DismStep -Name 'list packages after' -Arguments @(
        '/English', ('/Image:' + $mountDir), '/Get-Packages')
    if ($after -notmatch 'WinPE-WMI') {
        throw 'DISM reported success but WinPE-WMI is not listed in the mounted image'
    }

    Invoke-DismStep -Name 'unmount and commit' -Arguments @(
        '/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Commit') | Out-Null
    $mounted = $false

    Invoke-DismStep -Name 'mount the committed image read-only' -Arguments @(
        '/English', '/Mount-Image', ('/ImageFile:' + $image), '/Index:1', ('/MountDir:' + $mountDir), '/ReadOnly') | Out-Null
    $mounted = $true

    $committed = Invoke-DismStep -Name 'list packages after the commit' -Arguments @(
        '/English', ('/Image:' + $mountDir), '/Get-Packages')
    if ($committed -notmatch 'WinPE-WMI') {
        throw 'the package did not survive the commit'
    }

    Invoke-DismStep -Name 'unmount the verification mount' -Arguments @(
        '/English', '/Unmount-Image', ('/MountDir:' + $mountDir), '/Discard') | Out-Null
    $mounted = $false

    Write-Host 'DISM SERVICING OK: WinPE-WMI was added to the image and is still there after the commit.'
    exit 0
}
catch {
    Write-Host ('DISM SERVICING FAILED: ' + $_.Exception.Message)
    exit 1
}
finally {
    if ($mounted -and $mountDir) {
        & dism.exe /English /Unmount-Image ('/MountDir:' + $mountDir) /Discard 2>&1 | ForEach-Object { Write-Host ('  ' + [string]$_) }
    }
    if (-not $KeepWorkDir -and (Test-Path -LiteralPath $WorkDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
