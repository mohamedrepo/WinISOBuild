# WinISOIntegrity.Tests.ps1
# Pester tests (3.4 / 4.x / 5.x friendly syntax) for the verification helpers in
# WinISOIntegrity.psm1 and the commands built on them.
#
# Run with:
#   Invoke-Pester -Path .\Scripts\Tests
#
# Nothing here mounts an image, touches a disk or needs elevation: the module is
# pure, and the CLI calls that are exercised stop before they would.

# The scripts live one level above this Tests folder; fall back to this folder
# when the suite is copied next to the scripts instead. Never hard-code a drive.
$script:root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1'))) {
    $script:root = $PSScriptRoot
}
$script:psExe = (Get-Process -Id $PID).Path
if (-not $script:psExe) { $script:psExe = 'powershell.exe' }

Import-Module (Join-Path $script:root 'WinISOIntegrity.psm1') -Force -WarningAction SilentlyContinue

function Invoke-WinISOChild {
    param([string]$ScriptPath, [string[]]$ScriptArgs = @())
    $stamp = [guid]::NewGuid().ToString('N')
    $out = Join-Path $env:TEMP ('winiso-int-' + $stamp + '.out.log')
    $err = Join-Path $env:TEMP ('winiso-int-' + $stamp + '.err.log')
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

$script:temp = Join-Path $env:TEMP ('winiso-integrity-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:temp -Force)

Describe 'File hashing' {
    It 'returns MD5 and SHA256 for the same file in one call' {
        $file = Join-Path $script:temp 'payload.bin'
        [System.IO.File]::WriteAllText($file, 'winiso')
        $h = @(Get-WinISOFileHash -Path $file -Algorithm @('MD5', 'SHA256'))
        $h.Count | Should Be 2
        $h[0].Algorithm | Should Be 'MD5'
        $h[1].Algorithm | Should Be 'SHA256'
        $h[0].Hash.Length | Should Be 32
        $h[1].Hash.Length | Should Be 64
    }

    It 'rejects an unknown algorithm instead of silently skipping it' {
        $file = Join-Path $script:temp 'payload2.bin'
        [System.IO.File]::WriteAllText($file, 'x')
        { Get-WinISOFileHash -Path $file -Algorithm @('CRC32') } | Should Throw
    }

    It 'formats the hashes for the clipboard' {
        $h = @([pscustomobject]@{ Algorithm = 'SHA256'; Hash = ('a' * 64); Path = 'D:\x.iso'; Bytes = 1 })
        $text = Format-WinISOHashText -Hashes $h
        $text | Should Match 'SHA256  aaaa'
        (Format-WinISOHashText -Hashes $h -IncludePath) | Should Match 'x\.iso'
    }
}

Describe 'Checksum sidecar' {
    It 'round-trips a written sidecar' {
        $file = Join-Path $script:temp 'iso.bin'
        [System.IO.File]::WriteAllText($file, 'iso bytes')
        $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        $sidecar = Join-Path $script:temp 'ISO-SHA256.txt'
        [System.IO.File]::WriteAllText($sidecar, ($sha + '  ' + $file))
        $e = @(Read-WinISOHashSidecar -Path $sidecar)
        $e.Count | Should Be 1
        $e[0].Algorithm | Should Be 'SHA256'
        (Test-WinISOHashMatch -Expected $e[0].Hash -Actual $sha) | Should Be $true
    }

    It 'detects a mismatched digest' {
        (Test-WinISOHashMatch -Expected ('a' * 64) -Actual ('b' * 64)) | Should Be $false
    }

    It 'ignores case and an algorithm prefix' {
        (Test-WinISOHashMatch -Expected ('AB' * 32) -Actual ('SHA256: ' + ('ab' * 32))) | Should Be $true
    }
}

Describe 'Download manifest verification' {
    It 'accepts an intact package, flags an altered one and reports a missing one' {
        $dir = Join-Path $script:temp 'downloads'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $good = Join-Path $dir 'good.msu'
        $bad = Join-Path $dir 'bad.msu'
        [System.IO.File]::WriteAllText($good, 'payload')
        [System.IO.File]::WriteAllText($bad, 'payload')
        $goodSha = (Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = Join-Path $dir 'DOWNLOAD-MANIFEST.json'
        $doc = [ordered]@{
            generated_utc = 'x'
            files         = @(
                [ordered]@{ kb = 'KB1'; file = 'good.msu'; bytes = 7; sha256 = $goodSha },
                [ordered]@{ kb = 'KB2'; file = 'bad.msu'; bytes = 7; sha256 = ('0' * 64) },
                [ordered]@{ kb = 'KB3'; file = 'gone.msu'; bytes = 7; sha256 = $goodSha }
            )
        }
        [System.IO.File]::WriteAllText($manifest, ($doc | ConvertTo-Json -Depth 5))
        $r = Test-WinISOManifestPayload -ManifestPath $manifest -DownloadDir $dir
        @($r.Ok).Count | Should Be 1
        @($r.Mismatched).Count | Should Be 1
        @($r.Missing).Count | Should Be 1
        $r.Failed | Should Be $true
    }

    It 'flags a package whose size disagrees with the manifest' {
        $dir = Join-Path $script:temp 'sizes'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $file = Join-Path $dir 'short.msu'
        [System.IO.File]::WriteAllText($file, 'tiny')
        $manifest = Join-Path $dir 'DOWNLOAD-MANIFEST.json'
        $doc = [ordered]@{ files = @([ordered]@{ file = 'short.msu'; bytes = 4096; sha256 = '' }) }
        [System.IO.File]::WriteAllText($manifest, ($doc | ConvertTo-Json -Depth 5))
        $r = Test-WinISOManifestPayload -ManifestPath $manifest -DownloadDir $dir
        @($r.Mismatched).Count | Should Be 1
        ([string](@($r.Mismatched)[0].Reason)) | Should Match 'size'
    }

    It 'treats a missing manifest as nothing to check' {
        $r = Test-WinISOManifestPayload -ManifestPath (Join-Path $script:temp 'nope.json') -DownloadDir $script:temp
        $r.Checked | Should Be 0
        $r.Failed | Should Be $false
    }
}

Describe 'Package ordering and already-applied detection' {
    It 'orders servicing stack, cumulative update, then .NET' {
        $o = @(Get-WinISOPackageOrder -Packages @(
            'windows11.0-kb5127694-x64-ndp481_abc.msu',
            'windows11.0-kb5127648-x64_def.msu',
            'windows11.0-kb5005-x64-ssu_ghi.msu'))
        $o[0].Kind | Should Be 'ssu'
        $o[1].Kind | Should Be 'lcu'
        $o[2].Kind | Should Be 'netfx'
    }

    It 'refuses an LCU listed before the servicing stack' {
        $problems = @(Test-WinISOPackageOrder -Packages @(
            'windows11.0-kb5127648-x64.msu',
            'windows11.0-kb5005-x64-ssu.msu'))
        $problems.Count | Should Be 1
        ($problems[0]) | Should Match 'servicing stack'
    }

    It 'accepts a legal order and a list without a servicing stack' {
        @(Test-WinISOPackageOrder -Packages @(
            'windows11.0-kb5005-x64-ssu.msu',
            'windows11.0-kb5127648-x64.msu')).Count | Should Be 0
        @(Test-WinISOPackageOrder -Packages @('windows11.0-kb5127648-x64.msu')).Count | Should Be 0
    }

    It 'parses a package identity, its level and its kind' {
        $text = @'
Package information:

Package Identity : Package_for_RollupFix~31bf3856ad364e35~amd64~~22621.4317.1.11
State : Not Present
Applicable : Yes
'@
        $info = ConvertFrom-WinISOPackageInfoText -Text $text
        $info.Kind | Should Be 'lcu'
        $info.Build | Should Be 22621
        $info.Revision | Should Be 4317
        $info.Applicable | Should Be 'Yes'
    }

    It 'skips an LCU the image already reached but not a newer one' {
        (Test-WinISOPackageAlreadyInImage -Kind 'lcu' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 4400) | Should Be $true
        (Test-WinISOPackageAlreadyInImage -Kind 'lcu' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 4000) | Should Be $false
        (Test-WinISOPackageAlreadyInImage -Kind 'netfx' -PackageBuild 22621 -PackageRevision 4317 -ImageBuild 22621 -ImageRevision 9999) | Should Be $false
    }
}

Describe 'unattend.xml validation' {
    It 'accepts the file the generator writes' {
        $path = Join-Path $script:temp 'unattend-good.xml'
        $out = & (Join-Path $script:root 'New-UnattendXml.ps1') -OutputPath $path -ComputerName 'LAB01' `
               -LocalAccountName 'labuser' -LocalAccountPassword 'ChangeMe123!' -LocalAccountAdmin
        $out.Validated | Should Be $true
        @($out.Passes).Count | Should BeGreaterThan 2
        $check = Test-WinUnattendDocument -Path $path
        $check.Ok | Should Be $true
    }

    It 'rejects a file that is missing passes and components' {
        $path = Join-Path $script:temp 'unattend-bad.xml'
        [System.IO.File]::WriteAllText($path, '<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="windowsPE"></settings></unattend>')
        $check = Test-WinUnattendDocument -Path $path
        $check.Ok | Should Be $false
        ($check.Problems -join '; ') | Should Match 'specialize'
        ($check.Problems -join '; ') | Should Match 'oobeSystem'
    }

    It 'rejects a file that is not XML' {
        $path = Join-Path $script:temp 'unattend-notxml.xml'
        [System.IO.File]::WriteAllText($path, 'this is not xml')
        (Test-WinUnattendDocument -Path $path).Ok | Should Be $false
    }
}

Describe 'Build profile' {
    It 'round-trips the settings a build needs' {
        $path = Join-Path $script:temp 'State\BuildProfile.json'
        [void](Save-WinISOProfile -Path $path -Values @{
            workspace = 'D:\WimMount'; edition_index = 6; run_cleanup = $true; capabilities = @('NetFx3')
        })
        $read = Read-WinISOProfile -Path $path
        [int]$read['edition_index'] | Should Be 6
        [bool]$read['run_cleanup'] | Should Be $true
        @($read['capabilities'])[0] | Should Be 'NetFx3'
        [string]$read['saved_utc'] | Should Not Be ''
    }
}

Describe 'Test-WinISOIntegrity.ps1' {
    It 'passes its own self test' {
        $r = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-SelfTest')
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'SELFTEST OK'
    }

    It 'reports MD5 and SHA256 and matches a fresh sidecar' {
        $iso = Join-Path $script:temp 'sample.iso'
        [System.IO.File]::WriteAllText($iso, 'not a real iso')
        $first = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-IsoPath', $iso, '-WriteSidecar')
        $first.ExitCode | Should Be 0
        $first.StdOut | Should Match 'HASH:MD5:[0-9a-f]{32}'
        $first.StdOut | Should Match 'HASH:SHA256:[0-9a-f]{64}'
        $second = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-IsoPath', $iso)
        $second.ExitCode | Should Be 0
        $second.StdOut | Should Match 'INTEGRITY OK'
    }

    It 'fails when the ISO no longer matches its sidecar' {
        $iso = Join-Path $script:temp 'tampered.iso'
        [System.IO.File]::WriteAllText($iso, 'original bytes')
        [void](Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-IsoPath', $iso, '-WriteSidecar'))
        [System.IO.File]::WriteAllText($iso, 'tampered bytes!')
        $r = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-IsoPath', $iso)
        $r.ExitCode | Should Be 1
        $r.StdOut | Should Match 'INTEGRITY FAILED'
    }

    It 'validates an answer file and rejects a broken one' {
        $good = Join-Path $script:temp 'answer-ok.xml'
        & (Join-Path $script:root 'New-UnattendXml.ps1') -OutputPath $good | Out-Null
        $ok = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-Unattend', $good)
        $ok.ExitCode | Should Be 0
        $bad = Join-Path $script:temp 'answer-bad.xml'
        [System.IO.File]::WriteAllText($bad, '<unattend/>')
        $nok = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Test-WinISOIntegrity.ps1') -ScriptArgs @('-Unattend', $bad)
        $nok.ExitCode | Should Be 1
    }
}

Describe 'Answer file validation mode' {
    It 'exits 0 for a usable file and 1 for a broken one' {
        $good = Join-Path $script:temp 'validate-ok.xml'
        & (Join-Path $script:root 'New-UnattendXml.ps1') -OutputPath $good -ComputerName 'LAB02' | Out-Null
        $r1 = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'New-UnattendXml.ps1') -ScriptArgs @('-ValidatePath', $good)
        $r1.ExitCode | Should Be 0
        $r1.StdOut | Should Match 'unattend OK'
        $bad = Join-Path $script:temp 'validate-bad.xml'
        [System.IO.File]::WriteAllText($bad, '<unattend/>')
        $r2 = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'New-UnattendXml.ps1') -ScriptArgs @('-ValidatePath', $bad)
        $r2.ExitCode | Should Be 1
        $r2.StdOut | Should Match 'unattend INVALID'
    }
}

Describe 'USB burner answer file gate' {
    It 'refuses an unusable answer file before looking at any disk' {
        $bad = Join-Path $script:temp 'burn-bad.xml'
        [System.IO.File]::WriteAllText($bad, '<unattend/>')
        $r = Invoke-WinISOChild -ScriptPath (Join-Path $script:root 'Burn-WinISOToUsb.ps1') `
             -ScriptArgs @('-IsoPath', (Join-Path $script:temp 'nope.iso'), '-DiskNumber', '99', '-AnswerFile', $bad, '-DryRun')
        $r.ExitCode | Should Be 1
        $r.StdOut | Should Match 'the answer file is not usable'
    }
}

Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
