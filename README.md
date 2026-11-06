# SupportIssueFixes

A growing collection of field fixes for real support issues — the kind that show up on actual machines, get misdiagnosed for months, and turn out to have a specific, findable cause.

![Grok Bot, the night shift: repair complete, the disabled extensions bagged and labeled](case-studies/grokbot-overnight-fix.jpg)

*The first fix in this repo was made overnight by Grok Bot, verified the next morning, and written up so it can be replicated. The bot gets the cover art. (AI-generated image.)*

Each tool is packaged the same way:

- **The issue** — symptoms as a user actually experiences them
- **The tell** — the diagnostic pattern that separates the real cause from the obvious wrong one
- **The tool** — a script that fixes it, written to be read before it is run
- **The undo** — every change is reversible, and the rollback is documented up front

Rules for everything in this repo: back up before changing anything, change one layer at a time, never uninstall what you can demote, and leave the machine in a state the next tech can understand.

## Tools

| # | Tool | Issue it fixes |
|---|------|----------------|
| 1 | [Demote-CloudShellExtensions](tools/Demote-CloudShellExtensions/) | Windows Explorer and Open/Save dialogs hang on "Working on it…" because stacked cloud-sync clients (OneDrive, Dropbox, iCloud) have loaded shell extensions into every folder view and file dialog. |

## Case studies

| Case | Story |
|------|-------|
| [LeighNSteve Explorer hang](case-studies/LeighNSteve-Explorer-Incident-Writeup.pdf) | Months of a nearly unusable machine and a ~6-hour 2 GB USB copy, traced to shell-extension stackup — not malware, not dying hardware. Fixed overnight without a Windows reinstall. The incident behind tool #1. |

---

Maintained by Steven Powell. Tools are provided as-is; read the script and its per-tool README before running anything, and run with `-WhatIf` first.
