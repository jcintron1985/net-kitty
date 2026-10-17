#requires -Version 5.1
[CmdletBinding()]
param([switch]$Simulation, [switch]$SendTestEmail, [switch]$SystemCredentialProbe, [switch]$CheckSystemCredential, [string]$Root = "$env:ProgramData\JLCIPWatch")
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JLCIPWatch.Core.psm1') -Force
if ($Simulation) {
    $tests = Join-Path $PSScriptRoot 'Tests\Run-Tests.ps1'
    if (-not (Test-Path -LiteralPath $tests)) { throw 'Run simulation from the source package, which includes Tests.' }
    & $tests; return
}
if ($SystemCredentialProbe) {
    $ok = $false
    try { $secret = Get-JLCSecret (Join-Path $Root 'smtp.credential'); $ok = -not [string]::IsNullOrWhiteSpace($secret); $secret = $null } catch { }
    Write-JLCJson (Join-Path $Root 'credential-check.json') @{ Utc = [datetime]::UtcNow.ToString('o'); IsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'); Accessible = $ok }
    if (-not $ok) { exit 1 }; exit 0
}
$config = Read-JLCJson (Join-Path $Root 'config.json'); Assert-JLCConfig $config
$connectivity = Test-JLCConnectivity $config
$statePath = Join-Path $Root 'state.json'; $state = Read-JLCState $statePath
$stateValid = $false; try { Assert-JLCState (Read-JLCJson $statePath); $stateValid = $true } catch { }
$task = Get-ScheduledTask -TaskName 'Net Kitty' -ErrorAction SilentlyContinue
$taskInfo = Get-ScheduledTaskInfo -TaskName 'Net Kitty' -ErrorAction SilentlyContinue
$identity = if ($null -ne $task) { $task.Principal.UserId } else { '' }
$systemTask = $identity -in @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')
$interval = if ($null -ne $task) { @($task.Triggers | Where-Object { $null -ne $_.Repetition -and $_.Repetition.Interval } | ForEach-Object { $_.Repetition.Interval }) } else { @() }
if ($CheckSystemCredential) {
    Assert-JLCAdmin
    $probePath = Join-Path $Root 'credential-check.json'
    if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force }
    Start-ScheduledTask -TaskName 'Net Kitty Credential Check'
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $probePath) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
}
$credential = $null
if (Test-Path -LiteralPath (Join-Path $Root 'credential-check.json')) { $credential = Read-JLCJson (Join-Path $Root 'credential-check.json') }
$result = [ordered]@{ Connectivity = $connectivity; PublicIPv4 = (Get-JLCPublicIP $config); DefaultAdapter = (Get-JLCDefaultAdapter); StateValid = $stateValid; PendingAlerts = $state.Pending.Count; RebootDecision = (Get-JLCRebootDecision $state $config ([datetime]::UtcNow)); TaskExists = ($null -ne $task); TaskRunsAsSystem = $systemTask; TaskInterval = $interval; LastTaskResult = $(if ($null -ne $taskInfo) { $taskInfo.LastTaskResult } else { $null }); SystemCredentialCheck = $credential }
if ($SendTestEmail) {
    Send-JLCMail $config (Join-Path $Root 'smtp.credential') @{ Subject = 'Diagnostic test'; Body = "SMTP authentication and delivery test from $env:COMPUTERNAME"; Id = [guid]::NewGuid().ToString() }
    $result.SmtpAcceptedTest = $true
}
$result | ConvertTo-Json -Depth 10
