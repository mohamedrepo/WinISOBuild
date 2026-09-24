# WinISOBuild - Windows 10/11 ISO servicing toolchain

A reproducible, verifiable PowerShell toolchain that inspects a Windows 10/11
installation ISO, researches the applicable Microsoft updates, integrates them
offline into the install image, applies optional OOBE/unattend configuration,
and rebuilds a bootable ISO.

## Files
- `Scripts/Invoke-WinISOService.ps1` - master orchestrator / state machine (Phases 1-10).
- `Scripts/WinISOService.psm1` - all phase implementations and helpers.
- `Scripts/Initialize-WorkSpace.ps1` - creates the workspace layout + initial STATE.json.
- `Scripts/New-UnattendXml.ps1` - generates unattend.xml from parameters.
- `Reports/` - env audit, ISO inventory, and update manifest from a real run
  (Windows 11 25H2, build 26200/26100, x64).

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
.\Scripts\Invoke-WinISOService.ps1 -TargetPhase 3 -SourceIso D:\ISO\Win11.iso
# place .msu/.cab files under Updates\, then:
.\Scripts\Invoke-WinISOService.ps1 -TargetPhase 8 -SourceIso D:\ISO\Win11.iso
```

## Notes
- Update discovery reads the public Microsoft Update Catalog; offline integration
  of the latest cumulative update is supported (the modern .msu is applied by DISM directly).
- Phases 4-10 mutate only copies; the source media is never altered.