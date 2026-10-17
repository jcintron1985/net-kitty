#requires -Version 5.1
[CmdletBinding()]
param([switch]$RemoveLogs)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JLCIPWatch.Core.psm1') -Force
Assert-JLCAdmin
$root = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'JLCIPWatch'))
if (-not (Test-Path -LiteralPath $root)) { Write-Output 'Already uninstalled.'; return }
if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Application root is a link. Removal refused.' }
if (@(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Application tree contains links. Removal refused.' }
foreach ($name in @('Net Kitty','Net Kitty Credential Check')) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}
$mutex = Get-JLCMutex $root; $locked = $false
try {
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'A watchdog process has not stopped. Removal paused. Try again.' }
    $state = Read-JLCState (Join-Path $root 'state.json')
    if ($null -ne $state.DisabledAdapter) { Restore-JLCAdapter $state.DisabledAdapter }
    # A shutdown already requested by a completed cycle is not owned by this process and is not blindly aborted.
    $shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Net Kitty.lnk'
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    Remove-Item -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JLCIPWatch' -Recurse -Force -ErrorAction SilentlyContinue
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    foreach ($item in Get-ChildItem -LiteralPath $root -Force) {
        if (-not $RemoveLogs -and $item.Name -eq 'Logs') { continue }
        $target = [IO.Path]::GetFullPath($item.FullName)
        if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Removal target escaped the application directory.' }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    if ($RemoveLogs) { Remove-Item -LiteralPath $root -Force }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
Write-Output 'Net Kitty removed. Logs are preserved unless RemoveLogs was selected.'
