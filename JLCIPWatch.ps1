#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = "$env:ProgramData\JLCIPWatch", [switch]$RestoreOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JLCIPWatch.Core.psm1') -Force
try { Invoke-JLCWatchdog -Root $Root -RestoreOnly:$RestoreOnly }
catch { Write-Error 'Watchdog cycle failed. The next scheduled cycle will retry. Inspect the protected local logs.'; exit 1 }
