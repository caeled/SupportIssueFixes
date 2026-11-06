<#
.SYNOPSIS
  Demote OneDrive / Dropbox / iCloud Explorer shell injectors that cause
  "Working on it..." hangs, without uninstalling the sync apps.

.DESCRIPTION
  Reversibly:
  - Renames ShellIconOverlayIdentifiers keys to zzz_DISABLED_* (64-bit + WOW64)
  - Adds CLSIDs under Shell Extensions\Blocked
  - Renames ContextMenuHandlers / CopyHookHandlers (DropboxExt, FileSyncEx, DropboxCopyHook)
  - Optionally demotes Desktop NameSpace cloud folders (HKCU)

  Sync clients keep running; icon overlays and some context menus stop loading
  into Explorer / common file dialogs.

.NOTES
  - Overlay demotions under HKLM need elevation (Run as Administrator).
  - HKCU Blocked / NameSpace changes work at Medium integrity.
  - Restart Explorer after running (script offers to do so).
  - To undo: rename zzz_DISABLED_* keys back, remove Blocked value names,
    restore from .reg backups written next to the log.

.PARAMETER WhatIf
  Show actions without changing the registry.

.PARAMETER SkipExplorerRestart
  Do not kill/restart explorer.exe at the end.

.PARAMETER IncludeNameSpace
  Demote HKCU Desktop\NameSpace cloud CLSIDs (OneDrive/Dropbox/iCloud) if present.

.EXAMPLE
  # Elevated (recommended for full demotion):
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Demote-CloudShellExtensions.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Demote-CloudShellExtensions.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$SkipExplorerRestart,
  [switch]$IncludeNameSpace,
  [string]$LogDir = 'C:\ProgramData\PowellServerOps'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "demote-cloud-shell-$stamp.log"
$backupReg = Join-Path $LogDir "demote-cloud-shell-backup-$stamp.reg"

function Write-Log([string]$Message) {
  $line = '{0} {1}' -f (Get-Date -Format o), $Message
  Add-Content -LiteralPath $log -Value $line
  Write-Host $line
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Export-Backup {
  $paths = @(
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers',
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers',
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
  )
  $args = @('/e', $backupReg) + $paths
  & reg.exe @args | Out-Null
  Write-Log "Backup attempted -> $backupReg (partial OK if some keys missing)"
}

function Rename-ChildKey {
  param(
    [Parameter(Mandatory)][string]$Parent,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$NewName
  )
  $src = Join-Path $Parent $Name
  $dst = Join-Path $Parent $NewName
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Log "Missing (ok): $src"
    return
  }
  if (Test-Path -LiteralPath $dst) {
    Write-Log "Already demoted: $dst"
    return
  }
  if ($PSCmdlet.ShouldProcess($src, "Rename to $NewName")) {
    Rename-Item -LiteralPath $src -NewName $NewName -Force
    Write-Log "Renamed $src -> $NewName"
  }
}

function Set-BlockedClsid {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Clsid,
    [Parameter(Mandatory)][string]$Reason
  )
  if (-not (Test-Path -LiteralPath $Root)) {
    if ($PSCmdlet.ShouldProcess($Root, 'Create Blocked key')) {
      New-Item -Path $Root -Force | Out-Null
    }
  }
  if ($PSCmdlet.ShouldProcess("$Root\$Clsid", 'Set Blocked value')) {
    New-ItemProperty -Path $Root -Name $Clsid -Value $Reason -PropertyType String -Force | Out-Null
    Write-Log "Blocked $Clsid under $Root"
  }
}

Write-Log '=== Demote-CloudShellExtensions START ==='
$admin = Test-IsAdmin
Write-Log ("Elevated admin = {0}" -f $admin)
if (-not $admin) {
  Write-Log 'WARNING: Not elevated. HKLM overlay/context demotions may fail. Re-run as Administrator for full effect.'
}

Export-Backup

# --- Icon overlays: demote Dropbox / OneDrive / iCloud (keep Google Drive active) ---
$overlayRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
)
foreach ($root in $overlayRoots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
    $n = $_.PSChildName
    if ($n -like 'zzz_DISABLED*') { return }
    if ($n -match 'Dropbox|OneDrive|iCloud') {
      $clean = ($n -replace '^\s+', '')
      Rename-ChildKey -Parent $root -Name $n -NewName ("zzz_DISABLED_" + $clean)
    }
  }
}

# --- Shell Extensions\Blocked: OneDrive FileSync + Dropbox CLSIDs commonly seen ---
$oneDriveFileSync = @{
  '{CB3D0F55-BC2C-4C1A-85ED-23ED75B5106B}' = 'FileSyncEx / OneDrive shell (Explorer stability)'
  '{BBACC218-34EA-4666-9D7A-C78F2274DA26}' = 'OneDrive overlay/status (Explorer stability)'
  '{5AB7172C-9C11-4310-BE5B-F9A63A70AF4D}' = 'OneDrive shell (Explorer stability)'
}
$dropboxClsids = @{
  '{FB314ED9-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDA-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDB-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDC-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDD-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDE-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EDF-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EE0-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EE1-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FB314EE2-A251-47B7-93E1-CDD82E34AF8B}' = 'DropboxExt overlay (Explorer stability)'
  '{FBC9D74C-AF55-4309-9FB2-C426E071637F}' = 'DropboxCopyHook (Explorer stability)'
  '{ECD97DE5-3C8F-4ACB-AEEE-CCAB78F7711C}' = 'DropboxExt ContextMenuHandler (Explorer stability)'
}

foreach ($root in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
  )) {
  foreach ($map in @($oneDriveFileSync, $dropboxClsids)) {
    foreach ($k in $map.Keys) {
      try { Set-BlockedClsid -Root $root -Clsid $k -Reason $map[$k] } catch { Write-Log "FAIL Blocked $k : $($_.Exception.Message)" }
    }
  }
}

# --- Context menus / copy hooks ---
$cmhParents = @(
  'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers',
  'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers',
  'HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers',
  'HKLM:\SOFTWARE\WOW6432Node\Classes\*\shellex\ContextMenuHandlers',
  'HKLM:\SOFTWARE\WOW6432Node\Classes\Directory\shellex\ContextMenuHandlers',
  'HKLM:\SOFTWARE\WOW6432Node\Classes\Directory\Background\shellex\ContextMenuHandlers'
)
foreach ($p in $cmhParents) {
  if (-not (Test-Path -LiteralPath $p)) { continue }
  Rename-ChildKey -Parent $p -Name 'DropboxExt' -NewName 'zzz_DISABLED_DropboxExt'
  # OneDrive sometimes registers with a leading space
  Rename-ChildKey -Parent $p -Name ' FileSyncEx' -NewName 'zzz_DISABLED_FileSyncEx'
  Rename-ChildKey -Parent $p -Name 'FileSyncEx' -NewName 'zzz_DISABLED_FileSyncEx'
}

$copyParents = @(
  'HKLM:\SOFTWARE\Classes\Directory\shellex\CopyHookHandlers',
  'HKLM:\SOFTWARE\WOW6432Node\Classes\Directory\shellex\CopyHookHandlers'
)
foreach ($p in $copyParents) {
  if (-not (Test-Path -LiteralPath $p)) { continue }
  Rename-ChildKey -Parent $p -Name 'DropboxCopyHook' -NewName 'zzz_DISABLED_DropboxCopyHook'
}

# --- Optional: demote Desktop NameSpace cloud folders ---
if ($IncludeNameSpace) {
  $ns = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
  if (Test-Path -LiteralPath $ns) {
    Get-ChildItem -LiteralPath $ns -ErrorAction SilentlyContinue | ForEach-Object {
      $n = $_.PSChildName
      if ($n -like 'zzz_DISABLED*') { return }
      $val = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).'(default)'
      if ($val -match 'OneDrive|Dropbox|iCloud|Google Drive') {
        Rename-ChildKey -Parent $ns -Name $n -NewName ("zzz_DISABLED_" + ($n -replace '[{}]',''))
      }
    }
  }
}

# Folder UX tweaks (HKCU, no admin)
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
if (-not (Test-Path $adv)) { New-Item $adv -Force | Out-Null }
if ($PSCmdlet.ShouldProcess($adv, 'Set Explorer Advanced tweaks')) {
  New-ItemProperty -Path $adv -Name 'ShowSyncProviderNotifications' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
  New-ItemProperty -Path $adv -Name 'LaunchFolderWindowsInSeparateProcess' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
  Write-Log 'Set ShowSyncProviderNotifications=0, LaunchFolderWindowsInSeparateProcess=1'
}

if (-not $SkipExplorerRestart) {
  if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart')) {
    Write-Log 'Restarting Explorer...'
    taskkill /F /IM explorer.exe 2>$null | Out-Null
    Start-Sleep -Seconds 2
    Start-Process "$env:WINDIR\explorer.exe"
    Start-Sleep -Seconds 2
    Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object {
      Write-Log ("explorer PID {0} Responding={1}" -f $_.Id, $_.Responding)
    }
  }
}

Write-Log "DONE. Log: $log"
Write-Log 'Undo: restore from backup .reg and/or rename zzz_DISABLED_* keys back; remove Blocked value names.'
Write-Host ''
Write-Host "Log: $log" -ForegroundColor Green
Write-Host 'Google Drive overlays were left alone. Sync apps were not uninstalled.' -ForegroundColor Cyan
