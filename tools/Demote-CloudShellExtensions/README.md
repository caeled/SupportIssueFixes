# Demote-CloudShellExtensions

Demotes the OneDrive / Dropbox / iCloud Explorer shell extensions that cause "Working on it…" hangs, **without uninstalling the sync apps**. Sync keeps syncing; the apps just stop hooking into every folder view and file dialog.

## The issue

File Explorer windows and every app's Open/Save dialog stall — sometimes for a minute — before showing folder contents. The taskbar freezes intermittently. File copies crawl, because each step of the copy pays the same stall. The machine feels haunted, and users start changing passwords and suspecting compromise. It is neither.

## The tell

- **CPU stays low while the machine is frozen.** The machine is not busy; it is *waiting* — blocked on a lock, an RPC call, or an out-of-process handler.
- **Raw directory listings are fast.** Enumerating the same folders from the command line returns in milliseconds. The filesystem is fine.
- **Only the shell is slow.** That points at the code Explorer loads to decorate a folder: icon overlays, status handlers, context menus, copy hooks. Cloud sync clients install themselves into exactly those hooks, in-process, so they load into Explorer *and* into every IFileDialog in every application.

One sync client is tolerable. Three or four stacked together means every folder view waits on all of them answering "what's the status of this file?" Icon overlays make it worse: Windows only loads about 15 overlay slots, and machines accumulate far more handlers than that (17+ on the case-study machine), each one queried for every icon drawn.

## What the script does

Reversibly, in layers:

1. **Exports registry backups** (`.reg`) next to its log before changing anything.
2. **Renames icon-overlay keys** for OneDrive / Dropbox / iCloud to `zzz_DISABLED_*` (64-bit and WOW64 roots), pushing them out of the loaded set.
3. **Adds the OneDrive FileSync and Dropbox CLSIDs** to `Shell Extensions\Blocked` (HKLM and HKCU) — the documented Windows mechanism for keeping Explorer from loading a specific extension.
4. **Renames context-menu and copy-hook registrations** (`DropboxExt`, `FileSyncEx`, `DropboxCopyHook`) to `zzz_DISABLED_*`.
5. **Applies two per-user Explorer tweaks:** sync-provider notifications off, folder windows in a separate process.
6. **Optionally** (`-IncludeNameSpace`) demotes the Desktop NameSpace cloud folders.
7. **Restarts Explorer** and logs its PID and responding state (skip with `-SkipExplorerRestart`).

Google Drive's overlays are **deliberately left active** — on the case-study machine Drive had just been clean-reinstalled onto a single filesystem driver and was not the problem.

## What it does not do

- No uninstalls. OneDrive, Dropbox, iCloud and Drive all stay installed and keep syncing. You lose the sync-status icon badges and some right-click menu entries.
- No network calls. No downloads. The script is self-contained PowerShell.
- No Windows reinstall required, and the fix does not depend on a reboot.

## Requirements and usage

- Windows 10/11, PowerShell 5.1 or newer.
- Run **elevated (as Administrator)** for the full machine-wide (HKLM) demotion. Without elevation, the per-user (HKCU) parts still apply and the script logs a warning for the rest.

```powershell
# Preview everything, change nothing:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Demote-CloudShellExtensions.ps1 -WhatIf

# Full run:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Demote-CloudShellExtensions.ps1
```

Logs and registry backups are written to `C:\ProgramData\PowellServerOps` by default (`-LogDir` to change).

## Undo

Import the `.reg` backup written next to the log, **or** rename the `zzz_DISABLED_*` keys back to their original names and delete the value names the script added under `Shell Extensions\Blocked`. Restart Explorer either way.

## Known residuals

- **Sync-client updates may re-register their extensions.** If "Working on it…" comes back after a OneDrive/Dropbox/iCloud update, re-run this script first.
- OneDrive may ask for sign-in again after a reboot following the demotion. Expected and harmless.
- This tool fixes the shell-extension layer only. On the case-study machine, intermittent WMI hangs and a crash-prone third-party USB utility were separate, secondary findings — see the [incident writeup](../../case-studies/LeighNSteve-Explorer-Incident-Writeup.pdf).

## Case study

First packaged from a real incident: months of a nearly unusable home machine, a ~2 GB USB copy that took roughly six hours, and a fix that brought folder opens from ~60 seconds to ~0.8 s (~0.01 s after a later reboot) — with no reinstall. Full writeup: [LeighNSteve Explorer Hang — Incident Writeup](../../case-studies/LeighNSteve-Explorer-Incident-Writeup.pdf).
