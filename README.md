# WinISOBuild - Windows 10/11 ISO servicing toolchain

A reproducible, verifiable PowerShell toolchain that inspects a Windows 10/11
installation ISO, researches the applicable Microsoft updates, downloads them,
integrates them offline into the install image, injects drivers, applies optional
OOBE/unattend configuration, and rebuilds a bootable ISO.

## Files
- `Scripts/Invoke-WinISOService.ps1`    - master orchestrator / state machine (Phases 1-10).
- `Scripts/WinISOService.psm1`          - all phase implementations and helpers.
- `Scripts/Initialize-WorkSpace.ps1`    - creates the workspace layout + initial STATE.json.
- `Scripts/New-UnattendXml.ps1`         - generates unattend.xml from parameters.
- `Scripts/Get-WinISOUpdates.ps1`       - finds the updates for a build (SSU, latest CU,
  .NET CU, Safe OS, Setup DU), classifies MISSED vs ALREADY-PRESENT, and downloads
  the applicable/optional ones into Updates\.
- `Scripts/WinISO-GUI.ps1`              - WinForms front-end (choices + integrations, live log).
- `Scripts/Invoke-WinISOIntegrate.ps1`  - extracts a source ISO, integrates the .msu
  packages from Updates\, commits, and rebuilds a bootable ISO.
- `Scripts/Add-WinISODrivers.ps1`       - injects a driver folder into the integrated
  install.wim and rebuilds the ISO.
- `Reports/` - env audit, ISO inventory, update manifest from a real run.

## Find and download the missed updates
`Get-WinISOUpdates.ps1` detects the target build (from `-Build` or directly from an
ISO) and queries the Microsoft Update Catalog. It compares each candidate against
the image's installed cumulative-update level and reports only what is actually
missing, then downloads the confirmed-applicable `.msu` files (optionally including
the optional/preview stream) into `Updates\`.

```powershell
.\Scripts\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso -ListOnly -MissedOnly
.\Scripts\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso -MissedOnly -IncludeOptional
```

## Integrate updates and drivers, then rebuild
```powershell
# 1. integrate the latest cumulative update (+ .NET) taken from Updates\
.\Scripts\Invoke-WinISOIntegrate.ps1 -SourceIso D:\ISO\Win11.iso `
    -UpdatesDir D:\WimMount\Updates -Work C:\WinISOBuild\Integrate -OutDir D:\WimMount\Output

# 2. export the current machine's drivers, then inject them + rebuild
dism /Online /Export-Driver /Destination:D:\WimMount\Drivers-Laptop
.\Scripts\Add-WinISODrivers.ps1 -Media C:\WinISOBuild\Integrate\Media `
    -Drivers D:\WimMount\Drivers-Laptop -OutDir D:\WimMount\Output
```

Nothing is ever downloaded implicitly by `Invoke-WinISOService.ps1`; downloading is
a separate, explicit step, and integration only consumes packages already under `Updates\`.

## Operating principles
- Never modify the source ISO; work on copies.
- Never assume edition index, architecture, language, build or WIM/ESD structure - detect it.
- Prefer Microsoft-supported servicing (DISM /Add-Package, /Add-Driver).
- Stop and diagnose on failure; never force a package.
- Log every significant operation and make the workflow restartable via State/STATE.json.

## Requirements
- Windows host, **elevated** PowerShell (DISM requires admin), DISM.
- Windows ADK Deployment Tools (oscdimg) for the media rebuild.
- Disk headroom roughly 40 GB for a multi-edition, fully integrated build.

## GUI
`Scripts/WinISO-GUI.ps1` is a WinForms front-end that exposes the toolchain's
choices - source ISO, editions to service (read from the selected ISO), update set,
driver injection, customization profile, OOBE/unattend fields and output name - and
runs the orchestrator as a child process while streaming its log. It self-elevates
at launch and asks for confirmation before any mutating phase (>=4).

```powershell
.\Scripts\WinISO-GUI.ps1
.\Scripts\WinISO-GUI.ps1 -SelfTest   # headless wiring validation
```

## Notes
- Update discovery reads the public Microsoft Update Catalog.
- The modern cumulative update `.msu` is a WIM-format package; DISM applies it
  directly (`/Add-Package /PackagePath:<msu>`), so no manual `.cab` extraction is needed.
- Enabling staged FOD/OnDemand capabilities needs the Languages and Optional
  Features ISO (`dism /Add-Capability`); the CU only updates them.
- Rebuilt images are named with the **full build** (e.g. `Win11_Pro_Updated_26200.9550.iso`).
- Phases 4-10 mutate only copies; the source media is never altered.
