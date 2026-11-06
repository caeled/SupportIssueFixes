# Handoff-RdpSessionToConsole

Returns a disconnected RDP user session to the physical console. This is for a Windows box used as a living-room PC, game-streaming host, or other machine where Sunshine, Kodi, or a locally visible desktop has to survive an RDP visit.

## The issue

You RDP into the machine, finish what you needed, and close the RDP client. The session does not automatically become the physical console session. Sunshine/Moonlight can then fail or report a permission-style error, and a desktop app such as Kodi may not start visibly.

## The tell

Run `query user` after closing RDP. A disconnected user session looks like this:

```text
 USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME
 user                                   2  Disc      none             11/4/2026 6:51 PM
```

`Disc` is the useful part. The user is still signed in, but the desktop is not attached to the physical console. The firewall is not the layer that reconnects that desktop.

Session **0** is not the answer. It is the services session. The first version of this tool extracted the wrong number and tried to hand off session 0; `tscon.exe` returned exit code 1.

## What the script does

1. Registers `RdpSessionToConsole` in the neutral scheduled-task folder `\SupportIssueFixes\`.
2. Triggers on **event 24** in `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` (session disconnected).
3. Runs the installed handler as **SYSTEM**, at highest privilege, with a two-minute task time limit.
4. Parses `query.exe user` output, tolerating the `>` current-session marker and a blank session-name column.
5. Selects the lowest-ID **disconnected user** session, skips session 0, and runs `tscon.exe <id> /dest:console`.
6. Writes the session ID and `tscon.exe` exit code to an append-only log.

`-UserName` limits the handoff to one named account. Use the bare account name, not `DOMAIN\account`. Without the filter, the first matching disconnected session by ID is used.

## What it does not do

- It does not log anyone off or stop a remote-management service.
- It does not change RDP, Sunshine, Moonlight, Kodi, or display settings.
- It does not guarantee a successful handoff on every Windows edition. `tscon.exe` behavior and availability depend on Windows; test on the target before relying on the event trigger.
- It does not bring back a desktop when there is no matching disconnected user session. That case is logged without invoking `tscon.exe`.

## Requirements and usage

- Windows with the Scheduled Tasks and `query.exe`/`tscon.exe` tools, tested in the incident on Windows PowerShell 5.1.
- Install and remove **from an elevated console**. The event handler runs as SYSTEM.

```powershell
# Preview installation; make no task, directory, or file changes.
.\Handoff-RdpSessionToConsole.ps1 -Install -WhatIf

# Install for any disconnected user session.
.\Handoff-RdpSessionToConsole.ps1 -Install

# Install only for a named streaming user.
.\Handoff-RdpSessionToConsole.ps1 -Install -UserName streaming

# Read task and disconnected-session state. No changes.
.\Handoff-RdpSessionToConsole.ps1 -Status

# A manual handoff can help test the command before causing a real disconnect.
.\Handoff-RdpSessionToConsole.ps1 -Handoff

# Preview removal. Existing logs stay behind.
.\Handoff-RdpSessionToConsole.ps1 -Uninstall -WhatIf

# Remove the task and installed handler; retain logs.
.\Handoff-RdpSessionToConsole.ps1 -Uninstall
```

The default handler directory is `C:\ProgramData\SupportIssueFixes\RdpConsoleHandoff`; the log directory is the same. Override with `-InstallDir` and `-LogDir`.

The scheduled task invokes the **installed copy**, so re-run `-Install` after editing the source script. The event handler waits two seconds by default to let disconnect processing settle; change with `-SettleSeconds` (0–60).

## Undo

Run `-Uninstall`. It removes only the `\SupportIssueFixes\RdpSessionToConsole` scheduled task and the copy of the handler under `-InstallDir`. It leaves the log directory and log file intact so the evidence is not lost.

## Case study

[RDP disconnect breaks Sunshine and Moonlight](../../case-studies/rdp-disconnect-breaks-sunshine-moonlight.md)
