# RDP disconnect breaks Sunshine and Moonlight

## The problem

I could RDP into my home Windows box from my phone, disconnect, and come back to a machine that would not stream. Moonlight reported **"Permission denied"** and Kodi would not start.

The firewall was the first suspect. It was the wrong layer.

## The tell

RDP does not necessarily return the user's desktop to the physical console when the client disconnects. `query user` still showed the user session, but it was **Disconnected** rather than attached to the console.

That leaves the signed-in desktop without the active console session I expected Sunshine to capture. An RDP client disconnecting is not the same thing as signing the user out, and no inbound allow rule fixes that difference.

The diagnostic command is small:

```powershell
query user
```

Look for `Disc`/`Disconnected` in the user-session state. The session ID matters too.

## The fix

I installed a scheduled task triggered by event 24 in `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`: an RDP session had disconnected.

The task runs as SYSTEM, finds the disconnected user session, and runs:

```powershell
tscon.exe <session-id> /dest:console
```

That attaches the disconnected desktop to the console. No logoff or restart is involved.

The first build got the session-selection logic wrong. On November 4 at 5:13:09 PM ET it chose session 0, and `tscon.exe` returned exit code 1. Session 0 is the services session, not the user's console desktop.

After fixing selection to use the disconnected user session, the log recorded **eight successful handoffs**, all exit code 0, from **November 4, 2026 at 6:52:57 PM ET through November 5 at 7:06:18 PM ET** (2026-11-04 18:52:57–2026-11-05 19:06:18 Eastern):

| Date (2026) | Time (ET) | Session | tscon exit |
|-------------|-----------|---------|------------|
| Nov 4 | 18:52:57 | 2 | 0 |
| Nov 4 | 20:24:36 | 2 | 0 |
| Nov 4 | 20:58:32 | 2 | 0 |
| Nov 4 | 21:26:27 | 2 | 0 |
| Nov 4 | 22:51:39 | 2 | 0 |
| Nov 4 | 23:10:58 | 2 | 0 |
| Nov 5 | 14:52:29 | 2 | 0 |
| Nov 5 | 19:06:18 | 2 | 0 |

Those timestamps came from the server-local log, kept in Eastern Time here.

The earlier manual `tscon` log also recorded exit code 0.

## A separate display problem

I also changed three Sunshine display-device settings:

```ini
dd_configuration_option = ensure_active
dd_resolution_option = auto
dd_refresh_rate_option = auto
```

This helped with a **4K tiny-UI problem** by making Sunshine ensure an active display configuration and use automatic resolution and refresh-rate selection. It was useful, but it was not the root fix for the disconnected-console problem.

The display-resolution attempt deserves a footnote rather than a success claim: its log recorded a **0x0@0** starting mode. That is not enough to prove what resolution was actually on the physical console.

## What the stack taught me

- Closing an RDP client does not necessarily hand the desktop back to the console.
- "Streaming stopped" does not automatically mean "firewall blocked it."
- Read the session state first; read the session ID carefully second.
- A scripted fix needs the same validation as the diagnosis. The first automated run selected session 0 and failed, even though the underlying `tscon` idea was right.

**TODO for Steven:** The source files do not establish whether Kodi launch was re-tested after the working handoff, or whether Moonlight streaming was re-tested end to end after the display changes. Confirm both before treating those as verified outcomes.

The full story, including the GitHub access snag during publishing, is on LinkedIn: [The Firewall Wasn't the Problem (and Neither Was the Code)](https://www.linkedin.com/pulse/firewall-wasnt-problem-neither-code-steven-powell-47tbc/).

The generalized tool and uninstall instructions are in [Handoff-RdpSessionToConsole](../tools/Handoff-RdpSessionToConsole/).
