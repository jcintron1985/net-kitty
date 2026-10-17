#requires -Version 5.1
# Exercises the complete cycle with real read only probes in an isolated temporary root.
# Recovery, SMTP, scheduled task registration, and restart are explicitly disabled.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'JLCIPWatch.Core.psm1') -Force -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('JLCIPWatch-live-readonly-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $config = Read-JLCJson (Join-Path $project 'config.json')
    $config.EnableInternetReset = $false; $config.EnableAdapterRestart = $false; $config.EnableReboot = $false; $config.EnableEmail = $false
    Write-JLCJson (Join-Path $root 'config.json') $config
    Invoke-JLCWatchdog -Root $root
    $state = Read-JLCState (Join-Path $root 'state.json')
    if (-not $state.LastCycleUtc) { throw 'Full engine did not complete a cycle.' }
    if ($state.RebootsUtc.Count -ne 0 -or $null -ne $state.DisabledAdapter -or $state.Pending.Count -ne 0) { throw 'Read only cycle unexpectedly changed recovery or email state.' }
    [ordered]@{ Test = 'Isolated full engine with real read only connectivity probes'; PowerShell = $PSVersionTable.PSVersion.ToString(); Online = $state.LastOnline; PublicIPValid = (Test-JLCPublicIPv4 $state.LastPublicIP); CycleCompleted = $true; RecoveryEnabled = $false; EmailEnabled = $false; RegisteredTasks = $false } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($root); $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'JLCIPWatch-live-readonly-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
