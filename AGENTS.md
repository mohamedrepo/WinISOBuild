# Repository Guidelines

## Project Structure & Module Organization
- `Scripts/`: Contains PowerShell scripts for Windows ISO management (GUI, service, utilities).
- `Source/`: Intended for source code (currently empty).
- `Drivers/`, `Updates/`, `ISO/`, `ExtractedISO/`, `Mount/`, `Output/`, `Logs/`, `Reports/`, `State/`, `Backup/`, `WinISOBuild/`: Working directories for ISO building, driver extraction, update integration, etc.
- `.freebuff/`: Third-party tools or resources.

## Build, Test, and Development Commands
- No formal build process; execute scripts directly in PowerShell.
- Common tasks:
  - Start GUI: `.\Scripts\WinISO-GUI.ps1`
  - Run service: `.\Scripts\Invoke-WinISOService.ps1`
  - Integrate updates: `.\Scripts\Get-WinISOUpdates.ps1` and `.\Scripts\Invoke-WinISOIntegrate.ps1`
  - Add drivers: `.\Scripts\Add-WinISODrivers.ps1`
  - Validate ISO: `.\Scripts\Validate-WinISO.ps1`
- For development, edit scripts in `Scripts/` and test in a isolated environment.

## Coding Style & Naming Conventions
- Follow PowerShell best practices:
  - Function names: PascalCase (e.g., `Add-WinISODrivers`).
  - Variables: camelCase (e.g., `$isoPath`).
  - Indentation: 4 spaces.
  - Avoid aliases in scripts for clarity.
- Recommended tool: PSScriptAnalyzer for linting (run `Invoke-ScriptAnalyzer` on scripts).
- Comment scripts with SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLES blocks.

## Testing Guidelines
- No existing test suite; consider adding Pester tests.
- Test files: `*.Tests.ps1` placed alongside scripts or in a `Tests/` directory.
- Run tests with: `Invoke-Pester -Path Scripts\` (or specific test file).
- Aim for unit tests of individual functions and integration tests for core workflows.

## Commit & Pull Request Guidelines
- Commit messages: Use conventional commits (feat, fix, docs, refactor, test, chore) or clear, descriptive summaries.
- Pull requests should:
  - Summarize changes and motivation.
  - Reference related issues (if any).
  - Include screenshots for GUI changes.
  - Ensure scripts pass basic linting (`Invoke-ScriptAnalyzer`) and manual testing.
  - Keep changes focused; split large changes into multiple PRs if needed.
