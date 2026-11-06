# Home-server firewall lockdown

## The problem

On **November 1, 2026, around 11:27 PM ET**, I audited the inbound administrative firewall rules on my home server.

I expected the usual RDP and WinRM rules. I also found allow rules whose remote scope was wider than the way I actually administer the machine.

## The tell

The important check was not "is Remote Desktop allowed?" It was "which enabled inbound allow rules expose these ports, with what profiles, and from which remote addresses?"

Before the lockdown:

| Rule | Port/protocol | Profile | Old RemoteAddress |
|------|---------------|---------|-------------------|
| Remote Desktop - User Mode (TCP-In) | 3389/TCP | Any profile | Any |
| Remote Desktop - User Mode (UDP-In) | 3389/UDP | Any profile | Any |
| Windows Remote Management (HTTP-In) | 5985/TCP | Public | LocalSubnet |
| Windows Remote Management (HTTP-In), `WINRM-HTTP-In-TCP-NoScope` | 5985/TCP | Domain, Private | Any |
| Custom remote-admin HTTP relay | 5000/TCP | Any profile | Any |
| Custom remote-admin HTTP relay, second rule | 5000/TCP | Any profile | Any |

The normal-looking WinRM rule was already scoped to the local subnet. The separate **NoScope** rule was the trap: the same display name, a different rule name, Domain/Private profiles, and `Any` as the remote scope.

The two application-created allow rules did the same thing for the relay. An app-created allow rule does not know my administration boundary unless someone sets it.

A second pass at **11:30 PM ET** found another unrestricted allow rule: **Remote Desktop - Shadow (TCP-In)**, with its local port reported as **Any**.

## The fix

Before either pass, I exported the complete Windows Firewall policy to a timestamped `.wfw` backup outside the public repo. Then I narrowed the matching rules' remote addresses to:

- `LocalSubnet`;
- the home /24;
- the Tailscale IPv4 CGNAT range;
- the Tailscale IPv6 ULA range.

The after state in the transcript showed **all six initial matches** scoped to those trusted networks. The second transcript showed the same outcome for RDP Shadow. The first pass completed around 11:28 PM ET; the second completed around 11:31 PM ET.

I did not uninstall RDP, WinRM, or the relay. I changed one property on the inbound allow rules: who could reach them.

The generalized tool defaults to RDP, WinRM, and RDP Shadow. The custom relay is not part of that default. Add TCP 5000 with `-ExtraPort 5000` only when that relay is actually in scope.

## Undo

Each generalized run writes a full firewall export, a per-rule JSON record of the old `RemoteAddress`, and a before/after report.

The targeted undo restores only the recorded rules' previous `RemoteAddress` values. The full undo imports the original `.wfw` policy. The second option also replaces unrelated firewall changes made after the backup, so it is the bigger hammer.

## What the stack taught me

- Look for duplicate rules, not just a friendly display name. The scoped WinRM rule and the no-scope duplicate told different stories.
- An installer can create a network opening outside the change you thought you were reviewing.
- RDP Shadow is easy to forget when making an RDP port list.
- Record the old value before changing it. A good undo should not depend on remembering the original scope.

The full story, including the GitHub access snag during publishing, is on LinkedIn: [The Firewall Wasn't the Problem (and Neither Was the Code)](https://www.linkedin.com/pulse/firewall-wasnt-problem-neither-code-steven-powell-47tbc/).

The generalized tool is in [Lock-RemoteAdminToTrustedNets](../tools/Lock-RemoteAdminToTrustedNets/).
