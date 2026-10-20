# WinISO.Tests.ps1
# Pester smoke tests (Pester 3.4 / 4.x / 5.x friendly syntax) for the
# toolchain entry points.
#
# Run with:
#   Invoke-Pester -Path .\Scripts\Tests
#
# These tests never touch DISM, diskpart, oscdimg, a real ISO or a USB drive:
# they exercise argument handling, self tests, the state machine dry run and the
# headless GUI wiring check.

$script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath (Join-Path $script:root 'WinISO-GUI.ps1'))) {
    $script:root = 'D:\WimMount\Scripts'
}
$script:psExe = (Get-Process -Id $PID).Path
if (-not $script:psExe) { $script:psExe = 'powershell.exe' }

function Invoke-WinISOChildScript {
    param([string]$ScriptPath, [string[]]$ScriptArgs = @())
    $stamp = [guid]::NewGuid().ToString('N')
    $out = Join-Path $env:TEMP ('winiso-test-' + $stamp + '.out.log')
    $err = Join-Path $env:TEMP ('winiso-test-' + $stamp + '.err.log')
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArgs
    $proc = Start-Process -FilePath $script:psExe -NoNewWindow -Wait -PassThru -ArgumentList $arguments `
            -RedirectStandardOutput $out -RedirectStandardError $err
    $stdout = ''
    if (Test-Path -LiteralPath $out) { $stdout = [string](Get-Content -LiteralPath $out -Raw -Encoding UTF8) }
    $stderr = ''
    if (Test-Path -LiteralPath $err) { $stderr = [string](Get-Content -LiteralPath $err -Raw -Encoding UTF8) }
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

Describe 'Scripts parse cleanly' {
    $scripts = @(
        'WinISO-GUI.ps1',
        'WinISOService.psm1',
        'Invoke-WinISOService.ps1',
        'Get-WinISOUpdates.ps1',
        'New-UnattendXml.ps1',
        'Initialize-WorkSpace.ps1',
        'Invoke-WinISOIntegrate.ps1',
        'Add-WinISODrivers.ps1',
        'Build-WinISOUpdated.ps1',
        'Validate-WinISO.ps1',
        'Test-WinISOGuiWiring.ps1'
    )
    foreach ($name in $scripts) {
        $capturedName = $name
        It ($capturedName + ' parses') {
            $path = Join-Path $script:root $capturedName
            (Test-Path -LiteralPath $path) | Should Be $true
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should Be 0
        }
    }
}

Describe 'Entry point self tests' {
    It 'WinISO-GUI.ps1 -SelfTest succeeds' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'WinISO-GUI.ps1') -ScriptArgs @('-SelfTest')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'SELFTEST OK'
    }

    It 'Get-WinISOUpdates.ps1 -SelfTest succeeds' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'Get-WinISOUpdates.ps1') -ScriptArgs @('-SelfTest')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'SELFTEST OK'
    }

    It 'Build-WinISOUpdated.ps1 -SelfTest succeeds' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'Build-WinISOUpdated.ps1') -ScriptArgs @('-SelfTest')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'SELFTEST OK'
    }

    It 'Build-WinISOUpdated.ps1 -DryRun reports a plan without touching the image' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'Build-WinISOUpdated.ps1') `
             -ScriptArgs @('-DryRun', '-SkipPackages', '-SkipDrivers', '-Workspace', 'D:\WimMount')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'DRY RUN'
        $r.StdOut | Should Match 'Would export index 6'
    }

    It 'the GUI builds headlessly with every control wired' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'Test-WinISOGuiWiring.ps1')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'WIRING OK'
    }

    It 'the GUI attaches its panes to the form (no blank window)' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'WinISO-GUI.ps1') -ScriptArgs @('-NoShow', '-NoElevate')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'GUICHECK OK'
        $r.StdOut | Should Match 'GUICHECK tree\s*:\s*\d+ controls, \d+ group boxes'
        $m = [regex]::Match($r.StdOut, 'GUICHECK tree\s*:\s*(\d+) controls, (\d+) group boxes')
        $m.Success | Should Be $true
        ([int]$m.Groups[1].Value -gt 50) | Should Be $true
        ([int]$m.Groups[2].Value -ge 8) | Should Be $true
    }

    It 'the orchestrator dry run plans phases 1..10' {
        $r = Invoke-WinISOChildScript -ScriptPath (Join-Path $script:root 'Invoke-WinISOService.ps1') `
             -ScriptArgs @('-Workspace', 'D:\WimMount', '-TargetPhase', '10', '-DryRun')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'DRY RUN'
        $r.StdOut | Should Match 'Final report'
    }
}
