# Security

This tool downloads an executable from the internet and runs it. That deserves a plain
statement of what is checked, what is not, and why — rather than a reassuring silence.

## What the script does

- Talks to exactly two hosts: `api.github.com` for the release metadata, and the asset
  URL GitHub returns (normally `objects.githubusercontent.com`).
- Sends no telemetry, writes no data anywhere but the installation folder, and reads no
  credentials. The GitHub API is called unauthenticated, so no token is stored or needed.
- Forces TLS 1.2 (and 1.3 where available) before any request.
- Never elevates itself. If the installation folder is not writable it says so and stops,
  leaving the choice to run elevated to you.

## What is verified before anything is installed

1. **SHA-256** — compared against the `digest` GitHub publishes for the asset. A mismatch
   aborts the update and leaves the installed build untouched.
2. **Authenticode signature** — reported, and enforced according to this policy:

| Digest | Signature | Result |
| --- | --- | --- |
| matches | valid | installed |
| matches | absent | installed, with a warning |
| matches | present but invalid | explicit confirmation required |
| absent | valid | installed |
| absent | absent | explicit confirmation required |
| mismatch | any | aborted |

Upstream currently ships unsigned builds, which is why a matching digest is treated as
sufficient on its own.

## What this does **not** protect against

The digest is published by GitHub alongside the asset, so it proves that the bytes you
received are the bytes GitHub is serving. It does **not** prove that those bytes are
benign. If the upstream repository, its maintainer account, or its release pipeline were
compromised, this script would faithfully install the compromised build — exactly as
downloading the release by hand would.

In other words: **trust this tool exactly as much as you trust the upstream project.** It
automates a download you would otherwise do manually; it does not add a trust layer on top
of it.

There is also a deliberate limit on the process side: the script closes running instances
of the target executable before replacing it. It only touches processes whose path matches
the executable being updated, but it does terminate them without asking, and unsaved state
in those processes is lost.

## Reporting a vulnerability

Open a [security advisory](https://github.com/hybrid2102/usage-monitor-updater/security/advisories/new)
or a regular issue if the matter is not sensitive. Please include your PowerShell edition
and version (`$PSVersionTable`), and the output of a run with `-Verbose`.

Vulnerabilities in Usage Monitor for Claude itself belong
[upstream](https://github.com/jens-duttke/usage-monitor-for-claude), not here.

## Supported versions

Only the latest release receives fixes.
