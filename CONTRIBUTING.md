# Contributing

Thanks for taking the time. This is a small, single-purpose tool, so the bar is simple:
changes should keep it working on a stock Windows machine, in both PowerShell editions,
without new dependencies.

## Reporting a bug

Include:

- `$PSVersionTable` output (edition and version matter — the two editions have already
  diverged in ways that caused a real bug);
- the full output of the failing run with `-Verbose`;
- what you expected instead.

## Development setup

No build step. You need the two modules the CI uses:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Before opening a pull request

Run what CI runs:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

Both must be clean. If a rule genuinely does not apply, exclude it in
`PSScriptAnalyzerSettings.psd1` **with a comment explaining why** — the existing
exclusions all carry one. Silencing a rule without a reason will be asked about.

Then exercise the real path at least once, safely:

```powershell
.\Update-UsageMonitor.ps1 -InstallDir "$env:TEMP\umtest" -ExeName 'Probe.exe' -NonInteractive -WhatIf
```

Drop `-WhatIf` for a full run against a throwaway folder. Never test against your own
installation while iterating.

## House style

- **PowerShell 5.1 compatible.** No `$IsWindows` without a version guard, no ternaries,
  no null-coalescing, no `Clean` blocks. CI runs the tests on both editions and will
  catch it, but it is faster to know up front.
- **Comments explain why, not what.** The code says what it does; a comment earns its
  place by recording the reason a non-obvious choice was made — a platform quirk, a
  failure mode seen in practice. Several existing comments follow this shape; match them.
- **Verb-Noun, singular nouns** for function names, per PowerShell convention.
- **Errors must be actionable.** A message should tell the user what to do next, not just
  what went wrong. Compare "HTTP 403" with the rate-limit message the script prints.
- **ASCII only** in the scripts. Accented characters need a UTF-8 BOM to survive Windows
  PowerShell 5.1, and it is not worth the trap.
- Line endings for `.ps1` and `.bat` are pinned to CRLF by `.gitattributes`.

## Changelog

User-visible changes go in `CHANGELOG.md` under `## [Unreleased]`, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Purely internal refactors do
not need an entry.

## Cutting a release

Releases are built and published by CI. There is nothing to build by hand.

1. Bump `.VERSION` in the `<#PSScriptInfo #>` block at the top of `Update-UsageMonitor.ps1`.
   This is the version the PowerShell Gallery publishes under, and the Gallery **never**
   allows a version to be replaced - only unlisted. Get it right before tagging.
2. Move the `## [Unreleased]` entries in `CHANGELOG.md` into a `## [X.Y.Z] - YYYY-MM-DD`
   section and update the link references at the bottom.
3. Commit, then push an annotated tag:

   ```powershell
   git tag -a v1.2.3 -m "v1.2.3 - short summary"
   git push origin v1.2.3
   ```

The release workflow then refuses to publish unless the tag, the `.VERSION` line and a
changelog section all agree, and unless the script parses. It builds the zip, attaches
`SHA256SUMS.txt`, and creates the GitHub release. Publishing that release triggers the
Gallery workflow, which validates the metadata again, skips silently if the version is
already published, and always performs a `-WhatIf` dry run before the real upload.

## Scope

This tool updates one application, in one folder, and restarts it. Requests that turn it
into a general-purpose package manager will likely be declined — but a well-argued issue
is always welcome before you write the code.
