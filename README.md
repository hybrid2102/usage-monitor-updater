# Usage Monitor Updater

A single PowerShell script that updates [Usage Monitor for Claude](https://github.com/jens-duttke/usage-monitor-for-claude)
to the latest GitHub release and restarts it — including a second instance, if you run one.

It shows the **changelog of the new version while the download is running**: the progress
indicator is one line redrawn in place *below* the release notes, so the text stays readable
instead of being covered by the PowerShell progress banner.

> **Not affiliated** with the author of Usage Monitor for Claude, or with Anthropic.
> This is an unofficial convenience script.

---

## What it does

1. Reads the latest release from the GitHub API.
2. Compares it with the installed executable's version. If they already match, it asks
   whether to re-download and re-apply it anyway.
3. Prints the release notes.
4. Closes every running instance of the executable.
5. Downloads the asset matching your CPU architecture and verifies it:
   - **SHA-256** against the digest GitHub publishes for the asset;
   - **Authenticode signature**.

   A matching digest proves the bytes are exactly what GitHub serves for that release, so
   an *unsigned* file is accepted with a warning — Usage Monitor, like many open-source
   projects, ships unsigned builds. A file whose signature is present but invalid
   (tampered, revoked, untrusted chain), or an unsigned file with no published digest to
   check against, always requires an explicit yes.
6. Replaces the executable (with retries, since antivirus scanners often hold a lock for
   a few seconds) and restarts it.

If verification fails, the installed executable is left untouched.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (preinstalled) or PowerShell 7+
- Internet access to `api.github.com` and `objects.githubusercontent.com`

## Install

1. Download `Update-UsageMonitor.ps1` and `Update-UsageMonitor.bat`.
2. Put both **next to `UsageMonitorForClaude.exe`**, in a folder you can write to.
   (Installing under `C:\Program Files\…` works too, but then run the script as
   Administrator.)
3. Windows marks files downloaded from the internet as blocked. Unblock the script once:

```powershell
Unblock-File .\Update-UsageMonitor.ps1
```

## Usage

Double-click `Update-UsageMonitor.bat`, or from a terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-UsageMonitor.ps1
```

`-ExecutionPolicy Bypass` applies to that one process only — it changes no machine or user
setting. It is needed because Windows ships with the policy set to `Restricted`.

### Options

| Parameter | Effect |
| --- | --- |
| `-Repo <owner/name>` | Update from a different repository. Default: `jens-duttke/usage-monitor-for-claude` |
| `-InstallDir <path>` | Folder holding the executable. Default: the script's own folder |
| `-ExeName <name.exe>` | Executable file name. Default: `UsageMonitorForClaude.exe` |
| `-Force` | Reinstall even when already up to date, without asking |
| `-SkipChangelog` | Do not print the release notes |
| `-NonInteractive` | Never prompt; questions take their default answer. For Task Scheduler / CI |
| `-SkipSignatureCheck` | Skip the Authenticode check (the SHA-256 check still runs). Rarely needed |
| `-WhatIf` | Show what would happen without changing anything |
| `-Verbose` | Extra diagnostic output |

Examples:

```powershell
.\Update-UsageMonitor.ps1 -InstallDir 'C:\Tools\UsageMonitor'
```

```powershell
.\Update-UsageMonitor.ps1 -NonInteractive -SkipChangelog
```

### Multiple instances

If you run more than one instance with different settings, create a shortcut next to the
executable named:

```
UsageMonitorForClaude.exe - <anything>.lnk
```

Every matching shortcut is restarted after the update, two seconds after the main instance.
No shortcut, no second instance — nothing else to configure.

### Scheduled updates

```powershell
schtasks /Create /TN "Usage Monitor update" /SC WEEKLY /D SUN /ST 09:00 ^
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\Tools\UsageMonitor\Update-UsageMonitor.ps1\" -NonInteractive"
```

With `-NonInteractive` the script never blocks on a prompt: if it is already up to date it
simply exits.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, or already up to date and nothing to do |
| `1` | Unexpected error |
| `2` | Unsupported platform or bad configuration |
| `3` | Network / GitHub API problem, including rate limiting |
| `4` | Integrity verification of the downloaded file failed |
| `5` | The installed executable could not be replaced (locked or not writable) |

## Troubleshooting

**"GitHub API rate limit reached"** — unauthenticated calls are limited to 60 per hour per
IP address, which is easy to hit behind a corporate NAT. The message tells you when the
limit resets.

**"Could not reach https://api.github.com"** — check your connection or proxy. The script
uses the system proxy with your default credentials.

**"No write permission on …"** — the executable lives in a protected folder. Run the script
as Administrator, or move the installation somewhere you own.

**"Could not replace the executable"** — something still holds the file open. It is usually
an antivirus scan; the script already retries five times. Close everything using it and
retry.

**The script window closes instantly** — you are running the `.ps1` by double-click, where
PowerShell closes the window on exit. Use the `.bat`, which pauses at the end.

**"Not digitally signed — accepted because the SHA-256 digest matched"** — expected, and
not an error: upstream ships unsigned builds. The digest check already proved the file is
byte-for-byte what GitHub serves.

## Security notes

This script downloads and runs an executable from the internet. Two things are worth knowing:

- Integrity is verified against GitHub's own published digest, not against a hash baked into
  this script. That protects against a corrupted or intercepted download, **not** against a
  compromised upstream release. Trust the upstream project as much as you would trust
  downloading its installer by hand.
- The script never runs the downloaded file with elevated privileges of its own, and never
  sends anything anywhere: the only outbound calls are the GitHub API request and the asset
  download.

## License

MIT — see [LICENSE](LICENSE).
