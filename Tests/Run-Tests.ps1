#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'JLCIPWatch.Core.psm1') -Force -DisableNameChecking
$script:passed = 0; $script:failed = 0
$script:now = [datetime]::Parse('2026-10-16T12:00:00Z').ToUniversalTime()
function Assert($Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message } }
function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name :: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" }
}
function New-Fixture {
    $script:cfg = Read-JLCJson (Join-Path $project 'config.json')
    $script:cfg.SenderEmail = 'sender@example.com'; $script:cfg.RecipientEmail = 'recipient@example.com'; $script:cfg.SmtpUsername = 'sender@example.com'
    $script:state = New-JLCState $script:now
    $script:state.RebootSafetyUntilUtc = ''
    $script:ctx = @{ Events = [Collections.Generic.List[string]]::new(); Probes = [Collections.Generic.Queue[bool]]::new(); Online = $false; IP = '8.8.8.8'; SendFails = $false; RestoreFails = $false; LastSaved = $null; Sends = 0; Saves = 0 }
    $script:ops = @{
        Log = { param($text) $script:ctx.Events.Add('log:' + $text) }
        Save = { param($value) $script:ctx.LastSaved = ConvertTo-JLCMap ($value | ConvertTo-Json -Depth 30 | ConvertFrom-Json); $script:ctx.Saves++ }
        Probe = { $script:ctx.Events.Add('probe'); if ($script:ctx.Probes.Count) { return $script:ctx.Probes.Dequeue() }; return $script:ctx.Online }
        PublicIP = { return $script:ctx.IP }
        Reset = { $script:ctx.Events.Add('reset') }
        FindAdapter = { return @{ Guid = 'fixture-adapter'; Index = 7; Name = 'Fixture Ethernet' } }
        DisableAdapter = { param($marker) Assert ($null -ne $script:ctx.LastSaved.DisabledAdapter) 'Adapter marker was not durable before disable'; $script:ctx.Events.Add('disable') }
        RestoreAdapter = { param($marker) $script:ctx.Events.Add('enable'); if ($script:ctx.RestoreFails) { throw 'simulated enable failure' } }
        AdapterWait = { param($adapter) $script:ctx.Events.Add('adapter-wait') }
        Reboot = { Assert ($script:ctx.LastSaved.RebootsUtc.Count -gt 0) 'Reboot reservation was not persisted'; $script:ctx.Events.Add('reboot') }
        Send = { param($item) $script:ctx.Sends++; if ($script:ctx.SendFails) { throw 'simulated SMTP failure' }; $script:ctx.Events.Add('send') }
    }
}
Test 'All PowerShell sources parse in Windows PowerShell 5.1' {
    foreach ($file in Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object Extension -in @('.ps1','.psm1')) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ("Parse error in " + $file.Name + ': ' + ($errors | Out-String))
    }
}
Test 'Hourly default and minimum recovery safeguards' { New-Fixture; Assert ($cfg.IntervalMinutes -eq 60); Assert-JLCConfig $cfg; $cfg.FailureThreshold = 1; $threw = $false; try { Assert-JLCConfig $cfg } catch { $threw = $true }; Assert $threw }
Test 'Email validation identifies the missing recipient before sending' {
    New-Fixture; $cfg.RecipientEmail = ''; $message = ''
    try { Assert-JLCConfig $cfg } catch { $message = $_.Exception.Message }
    Assert ($message -like '*Send alerts to*')
}
Test 'Gmail password validation reports App Password requirement' {
    $message = ''; try { $null = ConvertTo-JLCEmailSecret 'synthetic-password' -Gmail } catch { $message = $_.Exception.Message }
    Assert ($message -like '*16 letter Google App Password*')
    $secret = ConvertTo-JLCEmailSecret 'abcd efgh ijkl mnop' -Gmail
    try { Assert ([Net.NetworkCredential]::new('',$secret).Password -eq 'abcdefghijklmnop') } finally { $secret.Dispose() }
}
Test 'SMTP errors distinguish credential rejection, timeout, and transport close without echoing secrets' {
    $fixtureSecret = 'synthetic-private-token'
    $failure = [Net.Mail.SmtpException]::new("535 5.7.8 Username and Password not accepted $fixtureSecret")
    $reason = Get-JLCEmailFailure $failure; Assert ($reason -like '*rejected the account credentials*'); Assert ($reason -like '*535 5.7.8*'); Assert (-not $reason.Contains($fixtureSecret))
    Assert ((Get-JLCEmailFailure ([TimeoutException]::new('Operation timed out.'))) -like '*timed out*')
    $failure = [Net.Mail.SmtpException]::new('Failure sending mail.',[IO.IOException]::new('net_io_connectionclosed'))
    Assert ((Get-JLCEmailFailure $failure) -like '*closed the connection*')
}
Test 'Email before installation uses the supplied secure credential without reading a credential file' {
    New-Fixture; $module = Get-Module JLCIPWatch.Core
    $client = [pscustomobject]@{ EnableSsl = $false; Timeout = 0; UseDefaultCredentials = $true; Credentials = $null; Sent = $false; Disposed = $false; UsedPassword = ''; CapturedFrom = ''; CapturedTo = '' }
    $client | Add-Member -MemberType ScriptMethod -Name Send -Value { param($message) $this.Sent = $true; $this.UsedPassword = $this.Credentials.Password; $this.CapturedFrom = $message.From.Address; $this.CapturedTo = $message.To[0].Address }
    $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
    & $module { param($value) $script:originalFactory = (Get-Item Function:New-JLCSmtpClient).ScriptBlock; $script:testClient = $value; function script:New-JLCSmtpClient { param($HostName,$Port) return $script:testClient } } $client
    $secret = ConvertTo-SecureString 'synthetic-app-secret' -AsPlainText -Force
    $missingPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.missing.credential')
    try {
        Send-JLCMail $cfg $missingPath @{ Subject = 'Test'; Body = 'Test'; Id = 'fixture' } -Secret $secret
        Assert $client.Sent; Assert $client.Disposed; Assert $client.EnableSsl; Assert (-not $client.UseDefaultCredentials)
        Assert ($client.UsedPassword -eq 'synthetic-app-secret'); Assert ($client.CapturedFrom -eq $cfg.SenderEmail); Assert ($client.CapturedTo -eq $cfg.RecipientEmail)
        Assert (-not (Test-Path -LiteralPath $missingPath))
    } finally { $secret.Dispose(); & $module { Set-Item Function:script:New-JLCSmtpClient $script:originalFactory; Remove-Variable testClient -Scope Script } }
}
Test 'Tuxedo cat artwork has transparency and a valid nine size Windows icon' {
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Bitmap]::new((Join-Path $project 'Assets\NetKitty.png'))
    try { Assert ($image.Width -eq $image.Height); Assert ($image.GetPixel(0,0).A -eq 0) } finally { $image.Dispose() }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $project 'Assets\NetKitty.ico')); Assert ([BitConverter]::ToUInt16($bytes,4) -eq 9)
    $icon = [Drawing.Icon]::new((Join-Path $project 'Assets\NetKitty.ico'),[Drawing.Size]::new(32,32))
    try { Assert ($icon.Width -eq 32); Assert ($icon.Height -eq 32) } finally { $icon.Dispose() }
}
Test 'Real Windows task definition uses SYSTEM, boot, hourly, overlap and timeout safeguards' {
    New-Fixture; $definition = New-JLCTaskDefinition 'C:\ProgramData\JLCIPWatch' $cfg
    Assert ($definition.Principal.UserId -eq 'SYSTEM'); Assert ($definition.Principal.LogonType -eq 'ServiceAccount'); Assert ($definition.Principal.RunLevel -eq 'Highest')
    Assert ($definition.Settings.MultipleInstances -eq 'IgnoreNew'); Assert ($definition.Settings.ExecutionTimeLimit -eq 'PT20M'); Assert $definition.Settings.StartWhenAvailable
    Assert (@($definition.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -eq 1)
    Assert (@($definition.Triggers | Where-Object { $null -ne $_.Repetition -and $_.Repetition.Interval -eq 'PT1H' }).Count -eq 1)
    Assert ($definition.Actions[0].Arguments -like '*-NonInteractive*-WindowStyle Hidden*'); Assert ($definition.Actions[0].Execute -like '*WindowsPowerShell\v1.0\powershell.exe')
}
Test 'First two failures never invoke recovery' {
    New-Fixture; Invoke-JLCCycle $state $cfg $ops $now; Invoke-JLCCycle $state $cfg $ops $now.AddHours(1)
    Assert ($state.FailureCount -eq 2); Assert (-not $ctx.Events.Contains('reset')); Assert (-not $ctx.Events.Contains('reboot'))
}
Test 'Third failure follows reset, retest, adapter, retest, reboot' {
    New-Fixture; $state.FailureCount = 2; Invoke-JLCCycle $state $cfg $ops $now
    $events = @($ctx.Events | Where-Object { $_ -in @('probe','reset','disable','enable','adapter-wait','reboot') }) -join ','
    Assert ($events -eq 'probe,reset,probe,reset,probe,reset,probe,disable,enable,adapter-wait,probe,disable,enable,adapter-wait,probe,disable,enable,adapter-wait,probe,reboot') $events
    Assert ($state.RebootsUtc.Count -eq 1); Assert ($null -eq $state.DisabledAdapter)
}
Test 'Stage one success stops further recovery and queues reconnection' {
    New-Fixture; $state.FailureCount = 2; $ctx.Probes.Enqueue($false); $ctx.Probes.Enqueue($true)
    Invoke-JLCCycle $state $cfg $ops $now
    Assert ($state.FailureCount -eq 0); Assert (-not $ctx.Events.Contains('disable')); Assert (-not $ctx.Events.Contains('reboot')); Assert ($ctx.Sends -eq 1)
}
Test 'Stage two success stops reboot' {
    New-Fixture; $state.FailureCount = 2; foreach ($i in 1..4) { $ctx.Probes.Enqueue($false) }; $ctx.Probes.Enqueue($true)
    Invoke-JLCCycle $state $cfg $ops $now
    Assert ($ctx.Events.Contains('enable')); Assert (-not $ctx.Events.Contains('reboot')); Assert ($state.FailureCount -eq 0)
}
Test 'Reconnection resets failure counter' {
    New-Fixture; $state.FailureCount = 2; $state.OutageSinceUtc = $now.AddHours(-2).ToString('o'); $ctx.Online = $true
    Invoke-JLCCycle $state $cfg $ops $now; Assert ($state.FailureCount -eq 0); Assert ($state.OutageSinceUtc -eq ''); Assert ($ctx.Sends -ge 1)
}
Test 'Interrupted adapter is enabled before connectivity probe' {
    New-Fixture; $state.DisabledAdapter = @{ Guid = 'fixture-adapter'; Utc = $now.ToString('o') }
    Invoke-JLCCycle $state $cfg $ops $now
    Assert ($ctx.Events.IndexOf('enable') -lt $ctx.Events.IndexOf('probe')); Assert ($null -eq $state.DisabledAdapter)
}
Test 'Failed adapter restoration retains marker and blocks reboot' {
    New-Fixture; $state.FailureCount = 2; $ctx.RestoreFails = $true; $threw = $false
    try { Invoke-JLCCycle $state $cfg $ops $now } catch { $threw = $true }
    Assert $threw; Assert ($null -ne $state.DisabledAdapter); Assert (-not $ctx.Events.Contains('reboot'))
}
Test 'Persistence failure blocks network recovery' {
    New-Fixture; $state.FailureCount = 2; $ops.Save = { param($value) throw 'disk full' }; $threw = $false
    try { Invoke-JLCCycle $state $cfg $ops $now } catch { $threw = $true }
    Assert $threw; Assert (-not $ctx.Events.Contains('reset')); Assert (-not $ctx.Events.Contains('reboot'))
}
Test 'Two reboots in 24 hours block third' { New-Fixture; $state.RebootsUtc = @($now.AddHours(-4).ToString('o'),$now.AddHours(-1).ToString('o')); Assert ((Get-JLCRebootDecision $state $cfg $now) -eq '24 hour limit') }
Test 'Reboot cooldown and rolling window boundary' {
    New-Fixture; $state.RebootsUtc = @($now.AddMinutes(-29).ToString('o')); Assert ((Get-JLCRebootDecision $state $cfg $now) -eq 'Cooldown')
    $state.RebootsUtc = @($now.AddMinutes(-30).ToString('o')); Assert ((Get-JLCRebootDecision $state $cfg $now) -eq 'Allowed')
    $state.RebootsUtc = @($now.AddHours(-24).ToString('o'),$now.AddHours(-25).ToString('o')); Assert ((Get-JLCRebootDecision $state $cfg $now) -eq 'Allowed')
}
Test 'Missing or damaged state cannot reset reboot budget unsafely' { New-Fixture; $fresh = New-JLCState $now; Assert ((Get-JLCRebootDecision $fresh $cfg $now) -eq 'State safety hold') }
Test 'Reboot safety limit logs without sending email while monitoring continues' {
    New-Fixture; $state.FailureCount = 2; $state.RebootsUtc = @($now.AddHours(-4).ToString('o'),$now.AddHours(-1).ToString('o'))
    Invoke-JLCCycle $state $cfg $ops $now; Invoke-JLCCycle $state $cfg $ops $now.AddMinutes(31)
    Assert ($state.Pending.Count -eq 0); Assert (-not $ctx.Events.Contains('reboot')); Assert ($state.FailureCount -eq 4)
}
Test 'Recovery cooldown prevents repeated adapter interruption' { New-Fixture; $state.FailureCount = 3; $state.LastRecoveryUtc = $now.AddMinutes(-10).ToString('o'); Invoke-JLCCycle $state $cfg $ops $now; Assert (-not $ctx.Events.Contains('reset')) }
Test 'Failed public IP lookup preserves previous IP' { New-Fixture; $ctx.Online = $true; $state.LastPublicIP = '8.8.8.8'; $ctx.IP = $null; Invoke-JLCCycle $state $cfg $ops $now; Assert ($state.LastPublicIP -eq '8.8.8.8') }
Test 'Public IP change retries SMTP without duplicate queue entries' {
    New-Fixture; $ctx.Online = $true; $ctx.SendFails = $true; $state.StartupQueued = $true; $state.LastPublicIP = '8.8.8.8'; $ctx.IP = '1.1.1.1'
    Invoke-JLCCycle $state $cfg $ops $now
    Assert ($state.Pending.Count -eq 1); Assert ($state.Pending[0].Attempts -eq 1); Assert ($state.Pending[0].Body -like '*Previous IP: 8.8.8.8*New IP: 1.1.1.1*')
    Invoke-JLCCycle $state $cfg $ops $now.AddMinutes(1); Assert ($state.Pending.Count -eq 1); Assert ($ctx.Sends -eq 1)
    $ctx.SendFails = $false; Invoke-JLCCycle $state $cfg $ops $now.AddMinutes(11); Assert ($state.Pending.Count -eq 0)
}
Test 'Repeated IP transitions are separate events' {
    New-Fixture; $ctx.Online = $true; $ctx.SendFails = $true; $state.StartupQueued = $true; $state.LastPublicIP = '8.8.8.8'
    $ctx.IP = '1.1.1.1'; Invoke-JLCCycle $state $cfg $ops $now
    $ctx.IP = '8.8.8.8'; Invoke-JLCCycle $state $cfg $ops $now.AddMinutes(1)
    $ctx.IP = '1.1.1.1'; Invoke-JLCCycle $state $cfg $ops $now.AddMinutes(2)
    Assert ($state.Pending.Count -eq 3)
}
Test 'Outage keeps queued emails and reconnection delivers them' {
    New-Fixture; Add-JLCNotification $state 'ip:test' 'Test' 'Retain this' $now $cfg
    Invoke-JLCCycle $state $cfg $ops $now; Assert ($state.Pending.Count -eq 1); Assert ($ctx.Sends -eq 0)
    $ctx.Online = $true; Invoke-JLCCycle $state $cfg $ops $now.AddHours(1); Assert ($state.Pending.Count -eq 0)
}
Test 'Email queue cap retains existing notifications' {
    New-Fixture; $cfg.MaxPendingNotifications = 1; Add-JLCNotification $state 'a' 'a' 'a' $now $cfg
    $threw = $false; try { Add-JLCNotification $state 'b' 'b' 'b' $now $cfg } catch { $threw = $true }; Assert $threw; Assert ($state.Pending[0].Key -eq 'a')
}
Test 'Email batch limits avoid unbounded cycle duration' {
    New-Fixture; $ctx.Online = $true; $state.StartupQueued = $true
    foreach ($i in 1..9) { Add-JLCNotification $state "ip:event$i" 'test' 'test' $now $cfg }
    Invoke-JLCCycle $state $cfg $ops $now; Assert ($ctx.Sends -eq 5); Assert ($state.Pending.Count -eq 4)
}
Test 'No adapter means no indiscriminate disabling' { New-Fixture; $state.FailureCount = 2; $ops.FindAdapter = { return $null }; Invoke-JLCCycle $state $cfg $ops $now; Assert (-not $ctx.Events.Contains('disable')) }
Test 'Disabled recovery options never invoke system effects' { New-Fixture; $state.FailureCount = 2; $cfg.EnableInternetReset = $false; $cfg.EnableAdapterRestart = $false; $cfg.EnableReboot = $false; Invoke-JLCCycle $state $cfg $ops $now; foreach ($event in @('reset','disable','reboot')) { Assert (-not $ctx.Events.Contains($event)) } }
Test 'Each recovery stage is bounded at three attempts' { New-Fixture; $state.FailureCount = 2; Invoke-JLCCycle $state $cfg $ops $now; Assert (@($ctx.Events | Where-Object { $_ -eq 'reset' }).Count -eq 3); Assert (@($ctx.Events | Where-Object { $_ -eq 'disable' }).Count -eq 3); Assert (@($ctx.Events | Where-Object { $_ -eq 'reboot' }).Count -eq 1); $cfg.RecoveryAttemptsPerStage = 4; $threw = $false; try { Assert-JLCConfig $cfg } catch { $threw = $true }; Assert $threw }
Test 'Healthy startup and first public IP observation send no email' { New-Fixture; $ctx.Online = $true; Invoke-JLCCycle $state $cfg $ops $now; Invoke-JLCCycle $state $cfg $ops $now.AddHours(1); Assert ($ctx.Sends -eq 0); Assert ($state.Pending.Count -eq 0); Assert ($state.LastPublicIP -eq '8.8.8.8') }
Test 'Reboot requests never queue an automatic email' { New-Fixture; $state.FailureCount = 2; Invoke-JLCCycle $state $cfg $ops $now; Assert ($ctx.Events.Contains('reboot')); Assert ($state.Pending.Count -eq 0) }
Test 'Legacy startup and reboot alerts are removed before sending' { New-Fixture; $ctx.Online = $true; foreach ($key in @('initial-startup','reboot:old','reboot-limit','recovery:old')) { Add-JLCNotification $state $key 'old' 'old' $now $cfg }; Invoke-JLCCycle $state $cfg $ops $now; Assert ($ctx.Sends -eq 0); Assert ($state.Pending.Count -eq 0) }
Test 'Private, invalid, loopback, multicast IP responses are rejected' { foreach ($ip in @('10.0.0.1','192.168.1.1','172.16.0.1','127.0.0.1','169.254.1.1','100.64.0.1','224.0.0.1','999.1.1.1','1.2.3','::1','<html>')) { Assert (-not (Test-JLCPublicIPv4 $ip)) $ip }; Assert (Test-JLCPublicIPv4 '1.1.1.1') }
Test 'Simulation mode contains no real operating system operations' {
    foreach ($key in @('Reset','DisableAdapter','RestoreAdapter','Reboot','Send','Probe')) {
        New-Fixture
        Assert ($ops[$key].ToString() -notmatch 'Disable-NetAdapter|Enable-NetAdapter|shutdown\.exe|ipconfig\.exe|SmtpClient|Invoke-JLCNative|Send-JLCMail')
    }
}
Test 'Static IPv4 is preserved while DHCP renew is scoped to one adapter' {
    $module = Get-Module JLCIPWatch.Core
    & $module {
        $script:originalNative = (Get-Item Function:Invoke-JLCNative).ScriptBlock
        $script:fixtureDhcp = 'Disabled'; $script:fixtureNativeCalls = @()
        function script:Get-NetIPInterface { param($InterfaceIndex,$AddressFamily,$ErrorAction) return [pscustomobject]@{ Dhcp = $script:fixtureDhcp } }
        function script:Invoke-JLCNative { param($File,$Arguments,$TimeoutSeconds) $script:fixtureNativeCalls += $Arguments }
    }
    try {
        Update-JLCDhcp @{ Index = 7; Name = 'Fixture Ethernet' }
        Assert ((& $module { $script:fixtureNativeCalls.Count }) -eq 0) 'Static configuration must not trigger ipconfig'
        & $module { $script:fixtureDhcp = 'Enabled' }
        Update-JLCDhcp @{ Index = 7; Name = 'Fixture Ethernet' }
        Assert ((& $module { $script:fixtureNativeCalls.Count }) -eq 1)
        Assert ((& $module { $script:fixtureNativeCalls[0] }) -eq '/renew "Fixture Ethernet"')
    } finally {
        & $module { Set-Item Function:script:Invoke-JLCNative $script:originalNative; Remove-Item Function:script:Get-NetIPInterface }
    }
}
Test 'Default route adapter selection combines route and interface metrics' {
    $module = Get-Module JLCIPWatch.Core
    & $module {
        function script:Get-NetAdapter { param([switch]$Physical,$ErrorAction) if (-not $Physical) { throw 'Physical adapter filtering is mandatory' }; return @([pscustomobject]@{ ifIndex = 7; Status = 'Up'; InterfaceGuid = 'physical-a'; Name = 'Ethernet A' },[pscustomobject]@{ ifIndex = 8; Status = 'Up'; InterfaceGuid = 'physical-b'; Name = 'Ethernet B' }) }
        function script:Get-NetRoute { param($ErrorAction) return @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; State = 'Alive'; InterfaceIndex = 7; AddressFamily = 'IPv4'; NextHop = '192.168.1.1'; RouteMetric = 10 },[pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; State = 'Alive'; InterfaceIndex = 8; AddressFamily = 'IPv4'; NextHop = '192.168.2.1'; RouteMetric = 5 }) }
        function script:Get-NetIPInterface { param($InterfaceIndex,$AddressFamily,$ErrorAction) return [pscustomobject]@{ InterfaceMetric = $(if ($InterfaceIndex -eq 7) { 5 } else { 25 }) } }
    }
    try { $adapter = Get-JLCDefaultAdapter; Assert ($adapter.Guid -eq 'physical-a'); Assert ($adapter.Metric -eq 15) }
    finally { & $module { foreach ($name in @('Get-NetAdapter','Get-NetRoute','Get-NetIPInterface')) { Remove-Item -LiteralPath "Function:script:$name" } } }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('JLCIPWatch-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Test 'Atomic persistence preserves array types and reboot reservations' {
        New-Fixture; $path = Join-Path $temp 'state.json'; $state.RebootsUtc = @($now.ToString('o')); Write-JLCJson $path $state
        $loaded = Read-JLCState $path; Assert ($loaded.RebootsUtc.Count -eq 1); Assert ($loaded.Pending -is [array]); Assert ((Get-JLCRebootDecision $loaded $cfg $now) -eq 'Cooldown')
        $loaded.FailureCount = 4; Write-JLCJson $path $loaded; Assert (Test-Path -LiteralPath "$path.bak"); Assert ((Read-JLCState $path).FailureCount -eq 4)
    }
    Test 'Corrupt primary state restores backup with reboot hold' {
        New-Fixture; $path = Join-Path $temp 'backup-state.json'; Write-JLCJson $path $state; $state.FailureCount = 2; Write-JLCJson $path $state; Set-Content -LiteralPath $path -Value '{broken'
        $loaded = Read-JLCState $path; Assert ($loaded.FailureCount -eq 0); Assert ([datetime]$loaded.RebootSafetyUntilUtc -gt [datetime]::UtcNow)
    }
    Test 'Corrupt primary and backup produce fail closed reboot state' {
        $path = Join-Path $temp 'broken-state.json'; Set-Content -LiteralPath $path -Value 'bad'; Set-Content -LiteralPath "$path.bak" -Value 'bad'
        $loaded = Read-JLCState $path; Assert ([datetime]$loaded.RebootSafetyUntilUtc -gt [datetime]::UtcNow)
    }
    Test 'Machine DPAPI roundtrip stores no plaintext secret' {
        $path = Join-Path $temp 'fixture.credential'; $fixture = 'TEST-ONLY-' + [guid]::NewGuid().ToString()
        Protect-JLCCredential $path (ConvertTo-SecureString $fixture -AsPlainText -Force)
        Assert ((Get-JLCSecret $path) -eq $fixture); Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path)).Contains($fixture))
    }
    Test 'Log rotation bounds daily storage' {
        New-Fixture; $cfg.MaxLogBytes = 100; Write-JLCLog $temp $cfg ('x' * 200); Write-JLCLog $temp $cfg 'second record'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $temp 'Logs') -Filter '*.1').Count -eq 1)
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($temp); $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'JLCIPWatch-tests-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "Tests: $script:passed passed, $script:failed failed. Recovery, restart, and email operations were simulated."
if ($script:failed -gt 0) { throw "$script:failed safe tests failed." }
