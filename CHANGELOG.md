# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.2] - 2026-08-31

No changes to the script itself: `Update-UsageMonitor.ps1` is byte-for-byte the one shipped
in 1.0.1. This release exists so that a tag finally points at a commit whose CI is green —
in 1.0.1 the pipeline was rejected by GitHub before it could run a single test.

### Fixed

- CI: the Pester matrix used `${{ matrix.shell }}` in a step's `shell:` key, which GitHub
  rejects outright (`Unrecognized named-value: 'matrix'`) — the workflow failed at startup
  with no jobs, so nothing was ever tested. Each edition now has its own job.
- Tests: `System.Net.Http` is not loaded by default in Windows PowerShell 5.1, so building
  a real `HttpResponseMessage` threw there. The assembly is loaded explicitly, the test
  skips cleanly if it is unavailable, and a stub-based test covers the same branch on both
  editions. This was a defect in the test harness, not in the script.

### Added

- A 17th test exercising the PowerShell 7 rate-limit header path through a stub, so that
  branch is covered on both editions regardless of assembly availability.

## [1.0.1] - 2026-08-31

### Fixed

- **Friendly network errors were dead code on PowerShell 7.** Only
  `System.Net.WebException` was caught, which is the Windows PowerShell 5.1 type;
  PowerShell 6+ raises `Microsoft.PowerShell.Commands.HttpResponseException`. Rate-limit
  and "no such repository" messages never appeared there, only a raw stack trace. Both
  shapes are now normalised by `Get-HttpErrorInfo`, and HTTP 429 is handled too.
- **The updater could close an unrelated installation.** Instances were matched by
  process name alone, so a second copy of the application running from another folder
  was killed as well. Only processes started from the target executable are stopped now,
  and a process whose path cannot be read is left alone instead of being killed on a
  guess.
- **An interrupted install could destroy the working build.** The download was staged in
  `%TEMP%`, usually a different volume from the installation, making the final move a
  copy-and-delete rather than a rename. The file is now staged next to the target so the
  swap is atomic, the previous build is kept as `.bak` until the swap succeeds, and it is
  restored if anything fails.
- Progress output no longer produces one enormous line when redirected to a file or a CI
  log: without a console to redraw on, it degrades to one line per 10%.
- `==>` step prefixes no longer land on their own line in redirected output.

### Added

- `-Verbose` now actually reports something: request URLs, HTTP failure types, staging
  paths, skipped processes and backup operations. It was advertised in the README but
  produced no output.
- Pester test suite covering version comparison, asset selection, size formatting and
  HTTP error normalisation.
- GitHub Actions CI: PSScriptAnalyzer, a parse check, and the test suite on **both**
  Windows PowerShell 5.1 and PowerShell 7 — the edition split that caused the bug above.
- `SECURITY.md` documenting the threat model, and `CONTRIBUTING.md`.

### Changed

- `Stop-RunningInstances` and `Start-Instances` renamed to the singular
  `Stop-RunningInstance` / `Start-Instance`, and `Initialize-Tls` to
  `Initialize-SecurityProtocol`, following PowerShell verb-noun conventions.
- These helpers now declare `SupportsShouldProcess` themselves rather than reaching for
  the script's `$PSCmdlet` through dynamic scope, so `-WhatIf` propagates properly.

## [1.0.0] - 2026-08-31

### Added

- Initial public release.
- Updates the application to the latest GitHub release and restarts it.
- Prints the release notes before the download starts, with a single-line progress
  indicator below them so the changelog stays readable while the transfer runs.
- Verifies the download against the SHA-256 digest published by GitHub and against its
  Authenticode signature.
- Picks the release asset matching the machine's CPU architecture.
- Restarts additional instances defined by `<exe-name> - *.lnk` shortcuts.
- `-Force`, `-SkipChangelog`, `-NonInteractive`, `-SkipSignatureCheck`, `-Repo`,
  `-InstallDir`, `-ExeName`, plus `-WhatIf` support and documented exit codes.

[Unreleased]: https://github.com/hybrid2102/usage-monitor-updater/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/hybrid2102/usage-monitor-updater/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/hybrid2102/usage-monitor-updater/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/hybrid2102/usage-monitor-updater/releases/tag/v1.0.0
