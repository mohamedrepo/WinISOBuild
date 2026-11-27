# v1.12.0 — naming follows the serviced level

The output ISO is now named after the level the image reaches **after** the
commit, and the pipeline that produces it no longer silently applies nothing.

## Naming

- `windows11pro26300.9457.iso` (the source level the GUI used to pre-fill) is
  re-based to the serviced level, e.g. `windows11pro26300.9974.iso`.
- Phase 4 writes `State\SERVICED-LEVEL.json` when the commit ends: build,
  revision, which evidence set the level, the applied KBs, the WIM's own level,
  the edition and the derived file name.
- Precedence for the level: **DISM package inventory** (`/Get-Packages` reports
  the identity version of what is installed) → the level an applied package's
  catalog row declares → the WIM's `ServicePack Build`. Offline servicing keeps
  that WIM value at the source revision until first boot, so it is the weakest
  evidence, not the strongest.
- `OUTPUT-ISO-META.json` now records the serviced `build` + `servicePackBuild`
  (it used to write the build twice, which produced `.26300.26300.iso` names)
  and keeps the source level separately.
- The record is fingerprinted with the source ISO path, size and write time, so a
  record written for another source can never name a new build.

## Pipeline correctness

- Phase 3 knows build 26300 = 26H2 and rejects a catalog row whose declared level
  belongs to another base build. Before, the version check was a no-op for 26H2
  and the manifest mixed 24H2 / 25H2 / 26H1 packages.
- Update discovery reads 25 catalog rows instead of 10, so the rows for the
  detected build are not cut off before filtering.
- Phase 4 treats a selected update with no package file as a skip, not a failure;
  `-RequireAllUpdates` restores the strict behaviour. A run with nothing to apply
  is `Skipped`, not `Failed`.
- Phase 7 rebuilds an empty `ExtractedISO\` from `-SourceIso` before giving up, so
  the GUI's "rebuild media only" path finally works. It keeps an already-serviced
  `install.wim`.
- After the ISO is built, the media is checked against its own file name: the
  `install.wim` build must match, and every applied KB must appear in the image's
  package list.
- `Get-WinISOUpdates.ps1 -FromManifest` downloads exactly the KBs Phase 3
  selected, and each download is written back into `Reports\UPDATE-MANIFEST.json`
  with its file, size, digest and declared level — one contract, not two.

## New

- `Scripts/Clear-WinISOWorkingFolders.ps1` removes `Mount\`, `ExtractedISO\`,
  `Backup\`, `Work\`, `Output\FAT32-Media\` and `Updates\_expanded\` after a
  finished build. Deliverables and inputs are never touched, a `.gitkeep` stays,
  `-DryRun` reports without deleting, `-RemoveUpdates` also deletes the `.msu`
  files, and the command refuses to run while an image is still mounted.
  `Invoke-WinISOService.ps1 -CleanupWorkspace` runs it after a successful build
  (`-KeepBuildBackup`, `-CleanupUpdates` tune it).
- `New-UnattendXml.ps1 -BypassHardwareChecks` writes the documented
  `LabConfig` / `MoSetup` values in the windowsPE pass, so setup skips the
  Windows 11 TPM / Secure Boot / RAM / CPU / storage checks for this media only.
  The GUI exposes it as **Bypass Windows 11 TPM/CPU/RAM/Secure Boot checks** in
  the OOBE group. Nothing is written to the installed OS.

## Tests

- `Scripts/Test-WinISOLevelNaming.ps1` — 17 checks for the naming rules and the
  level readers.
- `Scripts/Test-WinISOCleanup.ps1` — cleanup semantics on a throw-away workspace.
- `Scripts/Test-WinISOGuiWiring.ps1` — headless GUI construction (now 93
  controls).
- PSScriptAnalyzer with the repository settings: no findings on
  `WinISOService.psm1`.

## Upgrade notes

- `VERSION` is 1.12.0; tag the same commit `v1.12.0`.
- An existing `Output\OUTPUT-ISO-META.json` written by 1.11.x can contain the
  duplicate build value; the GUI and the level reader ignore a revision equal to
  the build, so old files cannot produce `.26300.26300.iso` names.
- A stale `State\SERVICED-LEVEL.json` is ignored when the source ISO differs.
