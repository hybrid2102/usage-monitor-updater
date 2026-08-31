## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The reasoning a reviewer cannot get from the diff: the failure mode you hit, the
     platform quirk you worked around, the case that was not covered. -->

## Checks

- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` is clean
- [ ] `Invoke-Pester -Path ./tests` passes
- [ ] Ran the real script at least once (`-WhatIf` against a throwaway folder is enough)
- [ ] Still works on Windows PowerShell 5.1 — no PS7-only syntax
- [ ] `CHANGELOG.md` updated under `## [Unreleased]`, if this is user-visible
