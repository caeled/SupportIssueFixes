<#
.SYNOPSIS
  Return a disconnected RDP user session to the physical console so console
  capture and streaming software can see an active desktop again.

.DESCRIPTION
  Installs a scheduled task triggered by event 24 in
  Microsoft-Windows-TerminalServices-LocalSessionManager/Operational. The task
  runs as SYSTEM and calls this script in -Handoff mode.

  The handler parses query.exe user output, ignores session 0, and selects only
  a disconnected user session. Optionally restrict the handoff to one username.
  It runs tscon.exe <id> /dest:console and records the exit code.

.PARAMETER Install
  Copy this script under ProgramData and register the event-triggered task.

.PARAMETER Uninstall
  Remove the scheduled task and installed handler. Existing logs are retained.

.PARAMETER Status
  Show task, handler, and disconnected-session status without changing them.

.PARAMETER Handoff
  Run the one-shot console handoff. The scheduled task uses this mode.

.PARAMETER UserName
  Only hand off a disconnected session whose query.exe username matches exactly.
  Use the account name, not DOMAIN\account. Matching is not case-sensitive.

.PARAMETER LogDir
  Directory for the append-only handoff log.

.PARAMETER InstallDir
  Directory containing the handler used by the scheduled task.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Handoff-RdpSessionToConsole.ps1 -Install -WhatIf

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Handoff-RdpSessionToConsole.ps1 -Install -UserName streaming

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Handoff-RdpSessionToConsole.ps1 -Uninstall -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(ParameterSetName = 'Install', Mandatory = $true)]
  [switch]$Install,

  [Parameter(ParameterSetName = 'Uninstall', Mandatory = $true)]
  [switch]$Uninstall,

  [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
  [switch]$Status,

  [Parameter(ParameterSetName = 'Handoff', Mandatory = $true)]
  [switch]$Handoff,

  [Parameter(ParameterSetName = 'Install')]
  [Parameter(ParameterSetName = 'Handoff')]
  [string]$UserName,

  [string]$LogDir = 'C:\ProgramData\SupportIssueFixes\RdpConsoleHandoff',
  [string]$InstallDir = 'C:\ProgramData\SupportIssueFixes\RdpConsoleHandoff',

  [Parameter(ParameterSetName = 'Install')]
  [Parameter(ParameterSetName = 'Handoff')]
  [ValidateRange(0, 60)]
  [int]$SettleSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$taskPath = '\SupportIssueFixes\'
$taskName = 'RdpSessionToConsole'
$scriptPath = Join-Path $InstallDir 'Handoff-RdpSessionToConsole.ps1'
$logPath = Join-Path $LogDir 'handoff-rdp-session.log'

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-IsAdministrator {
  if (-not (Test-IsAdministrator)) {
    throw 'Run this mode from an elevated PowerShell console.'
  }
}

function Write-HandoffLog {
  param([Parameter(Mandatory = $true)][string]$Message)

  $line = '{0} {1}' -f (Get-Date -Format o), $Message
  Write-Host $line
  if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Get-DisconnectedUserSession {
  # quser marks the caller's session with '>' and leaves the session-name
  # column blank for some disconnected sessions. Parse fields, not columns.
  $output = @(& query.exe user 2>$null)
  if ($LASTEXITCODE -ne 0) {
    Write-Verbose "query.exe user exited with code $LASTEXITCODE."
    return
  }

  foreach ($rawLine in $output) {
    $line = ([string]$rawLine).Trim()
    if (-not $line) { continue }
    if ($line.StartsWith('>')) {
      $line = $line.Substring(1).TrimStart()
    }

    $match = [regex]::Match(
      $line,
      '^(?<user>\S+)\s+(?:(?<session>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)\s+',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) { continue }
    if ($match.Groups['state'].Value -notmatch '^(Disc|Disconnected)$') { continue }

    $id = [int]$match.Groups['id'].Value
    if ($id -eq 0) { continue }

    [pscustomobject]@{
      UserName    = $match.Groups['user'].Value
      SessionName = $match.Groups['session'].Value
      Id          = $id
      State       = $match.Groups['state'].Value
    }
  }
}

function Install-ConsoleHandoffTask {
  Assert-IsAdministrator
  if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath)) {
    throw 'Run -Install from the saved .ps1 file, not from an interactive paste.'
  }

  if ($PSCmdlet.ShouldProcess($InstallDir, 'Create handler directory')) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  }

  if (-not [string]::Equals(
      [IO.Path]::GetFullPath($PSCommandPath),
      [IO.Path]::GetFullPath($scriptPath),
      [StringComparison]::OrdinalIgnoreCase)) {
    if ($PSCmdlet.ShouldProcess($scriptPath, "Copy handler from $PSCommandPath")) {
      Copy-Item -LiteralPath $PSCommandPath -Destination $scriptPath -Force
    }
  }

  $subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
    <Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[(EventID=24)]]</Select>
  </Query>
</QueryList>
'@

  $triggerClass = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
  $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
  $trigger.Enabled = $true
  $trigger.Subscription = $subscription

  $actionArgument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Handoff -LogDir "{1}" -SettleSeconds {2}' -f $scriptPath, $LogDir, $SettleSeconds
  if ($UserName) {
    $actionArgument += ' -UserName "{0}"' -f ($UserName -replace '"', '`"')
  }

  $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $actionArgument
  $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

  $target = Join-Path $taskPath $taskName
  if ($PSCmdlet.ShouldProcess($target, 'Register SYSTEM task for LocalSessionManager event 24')) {
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Return a disconnected RDP user session to the physical console.' -Force | Out-Null
    Write-HandoffLog "Installed $target. Handler: $scriptPath"
  }
}

function Uninstall-ConsoleHandoffTask {
  Assert-IsAdministrator
  $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
  $target = Join-Path $taskPath $taskName
  if ($existing) {
    if ($PSCmdlet.ShouldProcess($target, 'Unregister console handoff task')) {
      Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
      Write-HandoffLog "Removed $target. Logs retained at $logPath"
    }
  }
  else {
    Write-Verbose "Task not present: $target"
  }

  if (Test-Path -LiteralPath $scriptPath) {
    if ($PSCmdlet.ShouldProcess($scriptPath, 'Remove installed handler; retain logs')) {
      Remove-Item -LiteralPath $scriptPath -Force
    }
  }
}

function Invoke-ConsoleHandoff {
  if ($SettleSeconds -gt 0) {
    Start-Sleep -Seconds $SettleSeconds
  }

  $sessions = @(Get-DisconnectedUserSession | Sort-Object Id)
  if ($UserName) {
    $sessions = @($sessions | Where-Object { $_.UserName -ieq $UserName })
  }
  $session = $sessions | Select-Object -First 1
  if (-not $session) {
    Write-HandoffLog 'No matching disconnected user session; no tscon run.'
    return
  }

  # Session 0 is the services session, never a user's console desktop.
  $target = 'session {0} ({1})' -f $session.Id, $session.UserName
  if ($PSCmdlet.ShouldProcess($target, 'Run tscon.exe /dest:console')) {
    & tscon.exe $session.Id /dest:console
    $tsconExit = $LASTEXITCODE
    Write-HandoffLog ("tscon {0} -> console exit {1}; user={2}" -f $session.Id, $tsconExit, $session.UserName)
    if ($tsconExit -ne 0) {
      throw "tscon.exe failed with exit code $tsconExit."
    }
  }
}

switch ($PSCmdlet.ParameterSetName) {
  'Install'   { Install-ConsoleHandoffTask }
  'Uninstall' { Uninstall-ConsoleHandoffTask }
  'Handoff'   { Invoke-ConsoleHandoff }
  'Status' {
    $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    [pscustomobject]@{
      TaskPath            = $taskPath
      TaskName            = $taskName
      TaskRegistered      = [bool]$existing
      HandlerPath         = $scriptPath
      HandlerInstalled    = Test-Path -LiteralPath $scriptPath
      LogPath             = $logPath
      DisconnectedSessions = @(Get-DisconnectedUserSession)
    }
  }
}
