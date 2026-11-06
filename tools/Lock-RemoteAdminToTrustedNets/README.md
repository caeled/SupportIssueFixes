# Lock-RemoteAdminToTrustedNets

Backs up the full Windows Firewall policy, finds administrative allow rules that are wider than intended, and limits their remote addresses to ranges you explicitly supply. A per-rule JSON record supports a targeted undo; the full `.wfw` export supports a complete restore.

## The issue

A machine can expose RDP or WinRM even when its owner knowingly set up those services only for local administration. A service installer, support tool, or custom remote-admin app can add its own inbound allow rule. Those rules do not necessarily inherit the scope you would choose yourself.

## The tell

Look at the **rule, direction, action, enabled state, port, profile, and RemoteAddress together**. In the incident:

- RDP TCP/UDP port 3389 had enabled inbound allow rules with `RemoteAddress = Any`.
- The normal WinRM HTTP rule was already scoped, but a separate `WINRM-HTTP-In-TCP-NoScope` rule was enabled for Domain/Private networks with `Any`.
- Two application-created inbound allow rules for a custom remote-admin HTTP relay on port 5000 also used `Any`.
- A second pass found `Remote Desktop - Shadow (TCP-In)` unrestricted too.

The duplicate no-scope WinRM rule and the app-created allow rules quietly bypass the safer-looking scoped default. Do not assume port 5000 is part of this script; add it only if you actually run that custom relay.

## What the script does

By default it inspects **enabled inbound Allow** rules for:

- RDP TCP/UDP local port **3389**;
- WinRM TCP local ports **5985** and **5986**;
- display names beginning **Remote Desktop - Shadow**;
- any additional TCP ports supplied with `-ExtraPort`.

It does not modify deny rules, disabled rules, outbound rules, or unrelated allow rules. On a real run it:

1. Creates the log directory.
2. Exports a full `.wfw` firewall backup using `netsh advfirewall export` and checks that it exists.
3. Collects each matching rule's identity, profile, protocol, local port, and old `RemoteAddress`.
4. Writes a JSON rollback record before changing individual rules.
5. Sets `RemoteAddress` on each match to your supplied trust list.
6. Writes a before/after report with both undo commands.

There is no default trusted subnet and no attempt to infer what the right trust boundary is. `-TrustedAddress` is mandatory for a lockdown.

## Requirements and usage

- Written for Windows PowerShell 5.1 or newer. The source commands were Windows PowerShell 5.1; this generalized tool received parser and focused logic checks in PowerShell 7.6.9, not a Windows 5.1 runtime test. Test it on Windows before deploying.
- Run the lockdown and restores elevated.
- Use `-WhatIf` for a read-only preview from an elevated session. It creates no backup, report, JSON record, or directory.

An example trusted set for an overlay-network home server:

```powershell
.\Lock-RemoteAdminToTrustedNets.ps1 `
  -TrustedAddress LocalSubnet,100.64.0.0/10,fd7a:115c:a1e0::/48 `
  -WhatIf
```

`100.64.0.0/10` is Tailscale's IPv4 CGNAT range and `fd7a:115c:a1e0::/48` is its IPv6 ULA range. They are examples, not defaults. If you also need the local IPv4 LAN, use its actual prefix, such as the home LAN shown in your own router configuration.

```powershell
# Scope the default RDP, WinRM, and RDP Shadow rules.
.\Lock-RemoteAdminToTrustedNets.ps1 `
  -TrustedAddress LocalSubnet,100.64.0.0/10,fd7a:115c:a1e0::/48

# Also scope the custom remote-admin HTTP relay on TCP 5000.
.\Lock-RemoteAdminToTrustedNets.ps1 `
  -TrustedAddress LocalSubnet,100.64.0.0/10,fd7a:115c:a1e0::/48 `
  -ExtraPort 5000

# Repeat with -ExtraPort 5000 whenever the relay is in scope; a rerun only finds the default ports otherwise.
```

```powershell
.\Lock-RemoteAdminToTrustedNets.ps1 -RestoreRecord .\rulerecord-YYYYMMDD-HHMMSS.json -WhatIf
```

Default backup, report, and record directory: `C:\ProgramData\SupportIssueFixes\FirewallLockdown`. `-LogDir` changes it.

### Optional AMT matching

`-IncludeAmt` also selects TCP ports 623, 664, and 16992–16995, plus matching display names for AMT, Management Engine, and LMS. This is **opt in** because these rules may belong to a deliberately configured management stack.

Intel AMT is firmware-level. A Windows Firewall rule does not enable, disable, or contain AMT; this switch only scopes matching rules in the Windows OS firewall.

## Undo

### Restore only the rules this run recorded

```powershell
.\Lock-RemoteAdminToTrustedNets.ps1 -RestoreRecord C:\ProgramData\SupportIssueFixes\FirewallLockdown\rulerecord-YYYYMMDD-HHMMSS.json
```

This puts each recorded rule's old `RemoteAddress` list back. A rule that no longer exists is reported and skipped. The JSON contains firewall configuration, so protect and retain it like a firewall backup.

### Restore the entire exported policy

```powershell
.\Lock-RemoteAdminToTrustedNets.ps1 -Restore C:\ProgramData\SupportIssueFixes\FirewallLockdown\firewall-backup-YYYYMMDD-HHMMSS.wfw
```

This imports the full `.wfw` policy from before the run. It can also overwrite unrelated firewall changes made since that backup. Use the JSON record when you want a narrower rollback.

**Remote-access warning:** preview first, include every address you may administer from, and keep local console access available. A bad trust list can lock you out of RDP or WinRM.

## Case study

[Home-server firewall lockdown](../../case-studies/home-server-firewall-lockdown.md)
