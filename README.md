# WinISOBuild - Windows 10/11 ISO servicing toolchain

A reproducible, verifiable PowerShell toolchain that inspects a Windows 10/11
installation ISO, researches the applicable Microsoft updates, downloads them,
integrates them offline into the install image, applies optional OOBE/unattend
configuration, and rebuilds a bootable ISO.

## Files
- `Scripts/Invoke-WinISOService.ps1` - master orchestrator / state machine (Phases 1-10).
- `Scripts/WinISOService.psm1` - all phase implementations and helpers.
- `Scripts/Initialize-WorkSpace.ps1` - creates the workspace layout + initial STATE.json.
- `Scripts/New-UnattendXml.ps1` - generates unattend.xml from parameters.
- `Scripts/Get-WinISOUpdates.ps1` - finds the updates for a build (SSU, latest CU,
  .NET CU, Safe OS, Setup DU) and downloads the applicable ones into Updates\.
- `Scripts/WinISO-GUI.ps1` - WinForms front-end (choices + integrations, live log).
- `Reports/` - env audit, ISO inventory, update manifest from a real run.

## Find and download the missed updates
`Get-WinISOUpdates.ps1` detects the target build (from `-Build` or directly from
an ISO) and queries the Microsoft Update Catalog for every applicable update
kind. It filters candidates by Windows version + architecture (so 26H1/23H2/arm64
packages are excluded), then downloads the confirmed-applicable `.msu` files into
the workspace `Updates\` folder and writes `Reports\DOWNLOAD-MANIFEST.json`.

```powershell
# inspect only
.\Scripts\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso -ListOnly
# download the applicable packages
.\Scripts\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso
# narrow the kinds
.\Scripts\Get-WinISOUpdates.ps1 -Build 26200 -Architecture x64 -Kinds LatestCU,DotNetCU
```

Nothing is ever downloaded implicitly by `Invoke-WinISOService.ps1`; downloading
is a separate, explicit step, and integration only consumes packages that are
already present under `Updates\`.

## Operating principles
- Never modify the source ISO; work on copies.
- Never assume edition index, architecture, language, build or WIM/ESD structure - detect it.
- Prefer Microsoft-supported servicing (DISM /Add-Package, /Add-Driver).
- Stop and diagnose on failure; never force a package.
- Log every significant operation and make the workflow restartable via State/STATE.json.

## Requirements
- Windows host, elevated PowerShell, DISM.
- Windows ADK Deployment Tools (oscdimg) for the media rebuild.
- Disk headroom roughly 40 GB for a multi-edition, fully integrated build.

## Typical usage
```powershell
.\Scripts\Initialize-WorkSpace.ps1 -Workspace D:\WimMount
.\Scripts\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso
.\Scripts\Invoke-WinISOService.ps1 -TargetPhase 3 -SourceIso D:\ISO\Win11.iso
.\Scripts\Invoke-WinISOService.ps1 -TargetPhase 8 -SourceIso D:\ISO\Win11.iso
```

## GUI
`Scripts/WinISO-GUI.ps1` is a WinForms front-end that exposes the toolchain's
choices - source ISO, editions to service (`-ImageIndexes`), update set, driver
injection, customization profile, OOBE/unattend fields and output name - and runs
the orchestrator as a child process while streaming its log into a pane. It asks
for confirmation before any mutating phase (>=4) and can stop a run.

The edition list is read from the **actually selected ISO** (mounted read-only,
`dism /Get-WimInfo` on `sources\install.wim`), with the cached report as a
fallback, and a `Search + download missing updates` action wraps
`Get-WinISOUpdates.ps1` against that same ISO.

Launch it, or validate the wiring headlessly:

```powershell
.\Scripts\WinISO-GUI.ps1
.\Scripts\WinISO-GUI.ps1 -SelfTest
```

## Notes
- Update discovery reads the public Microsoft Update Catalog.
- The modern cumulative update `.msu` is a WIM-format package; DISM applies it
  directly (`/Add-Package /PackagePath:<msu>`), so no manual `.cab` extraction is needed.
- Phases 4-10 mutate only copies; the source media is never altered.
