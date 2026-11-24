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
- `Scripts/Test-WinISOIntegrity.ps1`    - hashes an ISO with MD5 and SHA256, checks it
  against its `ISO-SHA256.txt` sidecar, re-hashes every package listed in
  `Reports/DOWNLOAD-MANIFEST.json`, and validates an unattend.xml.
- `Scripts/WinISOIntegrity.psm1`        - the verification helpers (hashing, manifest,
  package order, already-applied rule, answer-file validation, build profile).
- `Reports/` - env audit, ISO inventory, update manifest, build report from a real run.

## Verification and safeguards

Integrity is checked before anything is modified, not after a failure:

```powershell
# MD5 + SHA256, compared with the sidecar the build wrote
.\Scripts\Test-WinISOIntegrity.ps1 -IsoPath .\Output\Win11_Pro_x64_26300.9711_Updated_20261020.iso
# re-hash every downloaded .msu against the manifest
.\Scripts\Test-WinISOIntegrity.ps1 -Updates .\Updates -RequireAllPayloads
# check an answer file without installing anything
.\Scripts\New-UnattendXml.ps1 -ValidatePath .\Output\unattend.xml
```

`Build-WinISOUpdated.ps1` and `Invoke-WinISOIntegrate.ps1` use the same rules:

- every `.msu` is re-hashed against `Reports/DOWNLOAD-MANIFEST.json` before DISM
  sees it, so a truncated download fails in seconds instead of mid-package
- a servicing stack update is ordered before the cumulative update, and a list
  that violates that is refused rather than silently repaired
- a cumulative update the image already reached (same build, same or older
  revision) is skipped instead of being applied twice
- `Dism /Cleanup-Image /CheckHealth` runs on the mounted image before servicing
  (`-ScanHealth` for the slow full scan), and a damaged component store aborts
  the build with a precise message

Optional build switches: `-StartComponentCleanup` (with `/ResetBase` from the GUI),
`-Capabilities NetFx3,OpenSSH.Client`, `-OptionalFeatures`,
`-RemoveAppx <provisioned package>`, `-Esd` (re-encode `install.wim` as
`install.esd` with `/Compress:recovery`), `-Profile <json>` / `-SaveProfile`
(`State/BuildProfile.json`), and `-VerifyOnly` (check inputs and exit without
mounting anything). Every DISM call writes to one `Logs/dism-*.log`, and each
finished build writes `Reports/BUILD-REPORT.json` alongside
`Output/OUTPUT-ISO-META.json`.

The USB burner validates an answer file before it erases a drive, splits
`install.wim` into `install.swm` parts for FAT32, verifies every copied file's
size, then verifies the boot chain (`bootmgr`, `boot\bcd`, `sources\boot.wim`,
UEFI loader) it found on the ISO actually landed on the stick.

## Find and download the missed updates
`Get-WinISOUpdates.ps1` detects the target build (from `-Build` or directly from an
ISO) and queries the Microsoft Update Catalog. It compares each candidate against
the image's installed cumulative-update level and reports only what is actually
missing, then downloads the confirmed-applicable `.msu` files (optionally including
the optional/preview stream) into `Updates\`. Every file is verified against the
SHA1 (`digest`) and SHA256 the catalog's download dialog publishes for it, so a
truncated download or an error page saved as `.msu` is reported as
`failed its catalog digest`; `Reports\DOWNLOAD-MANIFEST.json` records
`catalog_sha1`, `catalog_sha256`, `hash_match` and the rounded `catalog_bytes`
for each file, plus a top-level `hash_failures` list.

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
- Rebuilt images are named `windows<version><edition><build>.<revision>.iso` in lower
  case, for example `windows11pro26300.10075.iso`. The build and revision come from
  the newest level Microsoft lists for the image's base build on the Windows 11 /
  Windows 10 release information page (`Get-WinISOReleaseBuild`); if that lookup is
  unavailable, or `-NoReleaseLookup` is used, the name carries the image level.
  arm64 media keeps `​.arm64` before `.iso` so it cannot overwrite the x64 ISO.
- Phases 4-10 mutate only copies; the source media is never altered.
