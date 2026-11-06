<#
.SYNOPSIS
  Back up Windows Firewall, then scope inbound RDP, WinRM, and RDP Shadow allow
  rules to explicitly trusted address ranges.

.DESCRIPTION
  Requires -TrustedAddress and creates a full .wfw export before changing any
  rule. Default targets are enabled inbound allow rules exposing TCP/UDP 3389,
  TCP 5985, or TCP 5986, plus enabled inbound allow rules whose display names
  begin with "Remote Desktop - Shadow".

  Use -ExtraPort 5000 for a custom remote-admin HTTP relay on that port. The
  tool does not detect or assume that any particular service is present.

  A JSON manifest records each matched rule's old RemoteAddress value. Use
  -RestoreRecord for a targeted rollback, or -Restore for a full firewall import.

.PARAMETER TrustedAddress
  One or more Windows Firewall remote-address values: LocalSubnet, IP addresses,
  CIDR ranges, or subnets. No network is trusted by default.

.PARAMETER Restore
  Import a previously exported .wfw firewall policy. This replaces the current
  firewall policy with the backup; unrelated later changes are replaced too.

.PARAMETER RestoreRecord
  Restore only the old RemoteAddress values saved in a -rulerecord-*.json file.

.PARAMETER LogDir
  Directory for firewall backups, reports, and per-rule rollback records.

.PARAMETER ExtraPort
  Add specific local TCP ports to the default 3389/5985/5986 port selection.

.PARAMETER IncludeAmt
  Also match the six common Intel AMT redirection/management TCP ports and
  enabled inbound allow display names containing AMT, Management Engine, or LMS.
  AMT itself is firmware-level; this switch only changes Windows Firewall rules.

.EXAMPLE
  .\Lock-RemoteAdminToTrustedNets.ps1 -TrustedAddress LocalSubnet,100.64.0.0/10 -WhatIf

.EXAMPLE
  .\Lock-RemoteAdminToTrustedNets.ps1 -TrustedAddress LocalSubnet,100.64.0.0/10 -ExtraPort 5000

.EXAMPLE
  .\Lock-RemoteAdminToTrustedNets.ps1 -Restore C:\ProgramData\SupportIssueFixes\FirewallLockdown\firewall-backup-YYYYMMDD-HHMMSS.wfw

.EXAMPLE
  .\Lock-RemoteAdminToTrustedNets.ps1 -RestoreRecord C:\ProgramData\SupportIssueFixes\FirewallLockdown\rulerecord-YYYYMMDD-HHMMSS.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(ParameterSetName = 'Lock', Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string[]]$TrustedAddress,

  [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Restore,

  [Parameter(ParameterSetName = 'RestoreRecord', Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RestoreRecord,

  [string]$LogDir = 'C:\ProgramData\SupportIssueFixes\FirewallLockdown',

  [Parameter(ParameterSetName = 'Lock')]
  [ValidateRange(1, 65535)]
  [int[]]$ExtraPort = @(),

  [Parameter(ParameterSetName = 'Lock')]
  [switch]$IncludeAmt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

function Assert-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell console.'
  }
}

function Get-RemoteAddressValue {
  param([Parameter(Mandatory = $true)]$Rule)

  # The array cast keeps ConvertTo-Json from turning one range into a string.
  return ,@($Rule | Get-NetFirewallAddressFilter | ForEach-Object { @($_.RemoteAddress) } | Select-Object -First 1)
}

function Resolve-TrustedAddress {
  param([Parameter(Mandatory = $true)][string[]]$Address)

  $resolved = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in $Address) {
    foreach ($raw in $entry.Split(',')) {
      $value = $raw.Trim()
      if (-not $value) { throw 'TrustedAddress contains an empty value.' }
      if ($value -match '\\s') {
        throw "TrustedAddress contains whitespace-separated values: '$value'. Pass an array or comma-separated list."
      }
      if ($value -ieq 'Any') {
        throw "'Any' would leave these administrative allow rules unrestricted. Supply a narrower trusted range."
      }
      if ($value -notmatch '^(LocalSubnet|[0-9A-Fa-f:.]+(?:/(?:\d{1,3}|[0-9A-Fa-f:.]+))?)$') {
        throw "Unsupported TrustedAddress value '$value'. Use LocalSubnet, an IP, or a CIDR/subnet range."
      }
      if (-not $resolved.Contains($value)) { $resolved.Add($value) }
    }
  }

  if ($resolved.Count -eq 0) { throw 'At least one trusted address is required.' }
  return $resolved.ToArray()
}

function Invoke-Lockdown {
  param([Parameter(Mandatory = $true)][bool]$PreviewOnly)

  Assert-IsAdministrator
  $allowed = Resolve-TrustedAddress -Address $TrustedAddress
  if (-not $PreviewOnly -and $PSCmdlet.ShouldProcess($LogDir, 'Create firewall backup and report directory')) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = Join-Path $LogDir "firewall-backup-$stamp.wfw"
  $report = Join-Path $LogDir "report-$stamp.log"
  $recordPath = Join-Path $LogDir "rulerecord-$stamp.json"

  # Preview mode never exports or writes files.
  if (-not $PreviewOnly) {
    if ($PSCmdlet.ShouldProcess('Windows Firewall policy', "Export full backup to $backup")) {
      $backupOutput = @(& netsh.exe advfirewall export $backup)
      if ($LASTEXITCODE -ne 0) { throw ($backupOutput -join [Environment]::NewLine) }
      if (-not (Test-Path -LiteralPath $backup)) { throw "Firewall export did not create $backup." }
    }
  }

  $ports = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($port in @('3389', '5985', '5986')) { [void]$ports.Add($port) }
  foreach ($port in $ExtraPort) { [void]$ports.Add([string]$port) }
  if ($IncludeAmt) {
    foreach ($port in @('623', '664', '16992', '16993', '16994', '16995')) { [void]$ports.Add($port) }
  }

  $hits = @()
  $rules = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction Stop)
  foreach ($rule in $rules) {
    $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
    $protocol = ([string]$portFilter.Protocol).ToUpperInvariant()
    $localPorts = @($portFilter.LocalPort | ForEach-Object { [string]$_ })
    $portMatched = $false
    if ($protocol -in @('TCP', 'UDP')) {
      foreach ($localPort in $localPorts) {
        if ($localPort -ne 'Any' -and $ports.Contains($localPort)) { $portMatched = $true }
        if ($protocol -eq 'UDP' -and @('5985', '5986') -contains $localPort) { $portMatched = $false }
      }
    }

    $displayName = [string]$rule.DisplayName
    $shadowMatched = $displayName -like 'Remote Desktop - Shadow*'
    $amtMatched = $IncludeAmt -and $displayName -match '(?i)\bAMT\b|Management Engine|LMS'
    if (-not ($portMatched -or $shadowMatched -or $amtMatched)) { continue }

    $hits += [pscustomobject]@{
      Name              = [string]$rule.Name
      DisplayName       = $displayName
      Profile           = [string]$rule.Profile
      Protocol          = $protocol
      LocalPort         = $localPorts
      OldRemoteAddress  = Get-RemoteAddressValue -Rule $rule
      NewRemoteAddress  = $allowed
    }
  }

  if ($PreviewOnly) {
    Write-Host 'Preview only: no backup, JSON record, log, or firewall change was made.' -ForegroundColor Yellow
    $hits | Format-Table Name, DisplayName, Profile, Protocol, LocalPort, OldRemoteAddress -AutoSize
    Write-Host 'Would also export a full .wfw backup before changing an actual rule.'
    return
  }

  # Record the before state before changing any individual rule.
  if ($PSCmdlet.ShouldProcess($recordPath, "Record old RemoteAddress for $($hits.Count) rule(s)")) {
    @($hits) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath -Encoding UTF8
  }

  $reportLines = New-Object 'System.Collections.Generic.List[string]'
  $reportLines.Add("Started: $(Get-Date -Format o)") | Out-Null
  $reportLines.Add("Backup: $backup") | Out-Null
  if ($WhatIfPreference) { $reportLines.Add('WhatIf: no firewall rules were changed.') | Out-Null }
  $reportLines.Add('--- Rules found (before) ---') | Out-Null
  foreach ($hit in $hits) {
    $reportLines.Add(('{0} | {1} | Profile={2} | {3} {4} | OldRemote={5}' -f $hit.Name, $hit.DisplayName, $hit.Profile, $hit.Protocol, ($hit.LocalPort -join ','), ($hit.OldRemoteAddress -join ','))) | Out-Null
    if ($PSCmdlet.ShouldProcess($hit.Name, "Set RemoteAddress to $($TrustedAddress -join ', ')")) {
      Set-NetFirewallRule -Name $hit.Name -RemoteAddress $allowed -ErrorAction Stop
    }
  }

  $reportLines.Add('--- After ---') | Out-Null
  foreach ($hit in $hits) {
    $after = Get-NetFirewallRule -Name $hit.Name -ErrorAction Stop | Get-NetFirewallAddressFilter -ErrorAction Stop
    $reportLines.Add(('{0} | RemoteAddress={1}' -f $hit.DisplayName, (@($after.RemoteAddress) -join ','))) | Out-Null
  }
  $reportLines.Add("Targeted undo record: $recordPath") | Out-Null
  $reportLines.Add("Full restore: .\Lock-RemoteAdminToTrustedNets.ps1 -Restore '$backup'") | Out-Null
  $reportLines.Add("Targeted restore: .\Lock-RemoteAdminToTrustedNets.ps1 -RestoreRecord '$recordPath'") | Out-Null
  if ($PSCmdlet.ShouldProcess($report, 'Write before/after report')) {
    $reportLines | Set-Content -LiteralPath $report -Encoding UTF8
  }
  $reportLines | ForEach-Object { Write-Host $_ }
}

function Invoke-FullRestore {
  Assert-IsAdministrator
  $backupPath = (Resolve-Path -LiteralPath $Restore -ErrorAction Stop).Path
  if ($PSCmdlet.ShouldProcess('Windows Firewall policy', "Import $backupPath and replace current policy")) {
    $output = @(& netsh.exe advfirewall import $backupPath)
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    Write-Host $output
  }
}

function Invoke-TargetedRestore {
  Assert-IsAdministrator
  $recordPath = (Resolve-Path -LiteralPath $RestoreRecord -ErrorAction Stop).Path
  $records = @(Get-Content -LiteralPath $recordPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
  foreach ($record in $records) {
    $name = [string]$record.Name
    $old = @($record.OldRemoteAddress | ForEach-Object { [string]$_ })
    if (-not $name -or $old.Count -eq 0) { throw "Invalid record in $recordPath." }
    $current = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if (-not $current) {
      Write-Warning "Rule $name from the record is not present; skipped."
      continue
    }
    if ($PSCmdlet.ShouldProcess($name, "Restore previous RemoteAddress: $($old -join ', ')")) {
      Set-NetFirewallRule -Name $name -RemoteAddress $old -ErrorAction Stop
    }
  }
}

if ($PSCmdlet.ParameterSetName -eq 'Lock') {
  Invoke-Lockdown -PreviewOnly ([bool]$WhatIfPreference)
}
elseif ($PSCmdlet.ParameterSetName -eq 'Restore') {
  Invoke-FullRestore
}
else {
  Invoke-TargetedRestore
}
