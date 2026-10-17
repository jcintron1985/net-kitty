#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function ConvertTo-JLCMap($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}; foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-JLCMap $Value[$key] }; return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}; foreach ($p in $Value.PSObject.Properties) { $result[$p.Name] = ConvertTo-JLCMap $p.Value }; return $result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-JLCMap $_ }) }
    return $Value
}
function Read-JLCJson([string]$Path) { ConvertTo-JLCMap (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
function Write-JLCJson([string]$Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30))
        $file = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, "$Path.bak", $true) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Assert-JLCAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Net Kitty as administrator.' }
}
function Set-JLCPrivateDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Application directories cannot be links or junctions.' }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-JLCPrivateTree([string]$Path) {
    Set-JLCPrivateDirectory $Path
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Application tree cannot contain links or junctions.' }
    foreach ($item in $items) {
        if ($item.PSIsContainer) { Set-JLCPrivateDirectory $item.FullName; continue }
        $acl = [Security.AccessControl.FileSecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')) }
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}
function Protect-JLCCredential([string]$Path, [securestring]$Secret) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    $bytes = $null
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllBytes($temp, $encrypted)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, $null) } else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        $plain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}
function Get-JLCSecret([string]$Path) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return [Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}
function Assert-JLCConfig($Config) {
    foreach ($name in @('IntervalMinutes','FailureThreshold','RecoveryAttemptsPerStage','MaxReboots24Hours','RebootCooldownMinutes','ProbeTimeoutSeconds','SmtpTimeoutSeconds','RecoveryCooldownMinutes','LogRetentionDays','MaxLogBytes','MaxEmailsPerCycle','MaxPendingNotifications')) {
        if (-not $Config.ContainsKey($name) -or $Config[$name] -isnot [ValueType] -or [double]$Config[$name] -ne [int]$Config[$name] -or [int]$Config[$name] -lt 1) { throw "Invalid configuration: $name" }
    }
    if ($Config.IntervalMinutes -lt 5 -or $Config.MaxReboots24Hours -gt 2 -or $Config.RebootCooldownMinutes -lt 30 -or $Config.FailureThreshold -lt 3) { throw 'Safety limits cannot be reduced below the documented safeguards.' }
    if ($Config.RecoveryAttemptsPerStage -gt 3) { throw 'Each recovery stage is limited to three attempts.' }
    if ($Config.ProbeTimeoutSeconds -gt 10 -or $Config.SmtpTimeoutSeconds -gt 30 -or $Config.MaxEmailsPerCycle -gt 5) { throw 'Network timeouts or email batch exceed the cycle time budget.' }
    if ($Config.SmtpPort -notin @(25,587,2525)) { throw 'Use an SMTP STARTTLS port, usually 587. Implicit TLS port 465 is not supported.' }
    foreach ($name in @('ResetWaitSeconds','AdapterWaitSeconds')) { if ([int]$Config[$name] -lt 0 -or [int]$Config[$name] -gt 60) { throw "Invalid configuration: $name" } }
    foreach ($name in @('EnableInternetReset','EnableAdapterRestart','EnableReboot','EnablePublicIP','EnableEmail','Logging')) { if ($Config[$name] -isnot [bool]) { throw "Invalid boolean: $name" } }
    if (@($Config.HttpsEndpoints).Count -lt 2 -or @($Config.DnsNames).Count -lt 1 -or @($Config.PublicIPEndpoints).Count -lt 2) { throw 'Multiple connectivity and public IP endpoints are required.' }
    foreach ($endpoint in @($Config.HttpsEndpoints) + @($Config.PublicIPEndpoints)) { $uri = [uri]$endpoint; if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Probe endpoints must use HTTPS without embedded credentials.' } }
    if ($Config.EnableEmail) {
        foreach ($field in @('SenderEmail','RecipientEmail')) {
            $label = if ($field -eq 'SenderEmail') { 'Sending email address' } else { 'Send alerts to' }
            if ([string]::IsNullOrWhiteSpace($Config[$field])) { throw "Enter an email address in $label." }
            try { $address = [Net.Mail.MailAddress]::new([string]$Config[$field]) } catch { throw "Enter a valid email address in $label." }
            if ($address.Address -ne $Config[$field]) { throw "Enter a plain email address in $label." }
        }
        if ([string]::IsNullOrWhiteSpace($Config.SmtpHost) -or [string]::IsNullOrWhiteSpace($Config.SmtpUsername)) { throw 'SMTP host and username are required.' }
    }
}
function New-JLCState([datetime]$Now = [datetime]::UtcNow) {
    @{
        SchemaVersion = 1; FailureCount = 0; LastPublicIP = ''; OutageSinceUtc = ''
        RebootsUtc = @(); RebootSafetyUntilUtc = $Now.AddHours(24).ToString('o'); Pending = @()
        DisabledAdapter = $null; LastRecoveryUtc = ''; LastCycleUtc = ''; LastOnline = $false
    }
}
function Assert-JLCState($State) {
    $template = New-JLCState
    foreach ($key in $template.Keys) { if (-not $State.ContainsKey($key)) { throw "Missing state field: $key" } }
    if ($State.SchemaVersion -ne 1 -or [int]$State.FailureCount -lt 0 -or $State.Pending -isnot [array] -or $State.RebootsUtc -isnot [array]) { throw 'Invalid persistent state.' }
    foreach ($date in @($State.RebootsUtc) + @($State.RebootSafetyUntilUtc,$State.LastRecoveryUtc,$State.OutageSinceUtc,$State.LastCycleUtc)) { if ($date) { [void][datetime]::Parse($date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } }
    foreach ($item in $State.Pending) { foreach ($key in @('Id','Key','Subject','Body','Attempts','NextAttemptUtc')) { if (-not $item.ContainsKey($key)) { throw 'Invalid notification state.' } }; [void][datetime]::Parse($item.NextAttemptUtc) }
    if ($null -ne $State.DisabledAdapter -and (-not $State.DisabledAdapter.ContainsKey('Guid') -or -not $State.DisabledAdapter.ContainsKey('Utc'))) { throw 'Invalid adapter recovery marker.' }
}
function Read-JLCState([string]$Path) {
    try { $state = Read-JLCJson $Path; Assert-JLCState $state; return $state } catch { }
    try {
        $state = Read-JLCJson "$Path.bak"; Assert-JLCState $state
        $state.RebootSafetyUntilUtc = [datetime]::UtcNow.AddHours(24).ToString('o')
        return $state
    } catch { return New-JLCState }
}
function Write-JLCLog([string]$Root, $Config, [string]$Message) {
    if (-not $Config.Logging) { return }
    $folder = Join-Path $Root 'Logs'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    $path = Join-Path $folder ('watchdog-{0}.log' -f [datetime]::UtcNow.ToString('yyyy-MM-dd'))
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge $Config.MaxLogBytes) { Move-Item -LiteralPath $path -Destination "$path.1" -Force }
    $clean = $Message -replace '[\r\n]', ' '
    Add-Content -LiteralPath $path -Value ('{0} {1}' -f [datetime]::UtcNow.ToString('o'), $clean) -Encoding UTF8
    Get-ChildItem -LiteralPath $folder -File -Filter 'watchdog-*.log*' | Where-Object LastWriteTimeUtc -lt ([datetime]::UtcNow.AddDays(-[int]$Config.LogRetentionDays)) | Remove-Item -Force
}
function Get-JLCEmailTemplate([ValidateSet('Reconnected','PublicIPChanged')][string]$Kind, [string]$PreviousIP, [string]$NewIP, [string]$OutageStartedUtc) {
    if ($Kind -eq 'Reconnected') { return @{ Subject = 'Internet connection restored'; Body = "Outage began UTC: $OutageStartedUtc" } }
    return @{ Subject = 'Public IP address changed'; Body = "Previous IP: $PreviousIP`r`nNew IP: $NewIP" }
}
function Format-JLCNotificationBody([string]$Body, [datetime]$Now, [string]$ComputerName = $env:COMPUTERNAME) {
    return "Computer: $ComputerName`r`nUTC: $($Now.ToString('o'))`r`n$Body"
}
function Add-JLCNotification($State, [string]$Key, [string]$Subject, [string]$Body, [datetime]$Now, $Config) {
    if (-not $Config.EnableEmail) { return }
    if (@($State.Pending | Where-Object Key -eq $Key).Count -gt 0) { return }
    if ($State.Pending.Count -ge $Config.MaxPendingNotifications) { throw 'Notification queue is full. Existing alerts have been retained.' }
    $State.Pending = @($State.Pending) + @(@{ Id = [guid]::NewGuid().ToString(); Key = $Key; Subject = $Subject; Body = (Format-JLCNotificationBody $Body $Now); Attempts = 0; NextAttemptUtc = $Now.ToString('o') })
}
function Get-JLCRebootDecision($State, $Config, [datetime]$Now) {
    if (-not $Config.EnableReboot) { return 'Disabled' }
    if ($State.RebootSafetyUntilUtc -and ([datetime]$State.RebootSafetyUntilUtc).ToUniversalTime() -gt $Now) { return 'State safety hold' }
    $recent = @($State.RebootsUtc | ForEach-Object { ([datetime]$_).ToUniversalTime() } | Where-Object { $_ -gt $Now.AddHours(-24) } | Sort-Object)
    if ($recent.Count -ge $Config.MaxReboots24Hours) { return '24 hour limit' }
    if ($recent.Count -gt 0 -and $recent[-1].AddMinutes($Config.RebootCooldownMinutes) -gt $Now) { return 'Cooldown' }
    return 'Allowed'
}
function Invoke-JLCCycle($State, $Config, $Ops, [datetime]$Now = [datetime]::UtcNow) {
    # All operating system effects are injected. Simulation supplies only inert callbacks.
    & $Ops.Log 'Cycle started'
    # Only outage/reconnection and public IP changes are automatic email events.
    # Remove notifications left by older versions with a broader notification policy.
    $State.Pending = @($State.Pending | Where-Object { $_.Key -like 'ip:*' -or $_.Key -like 'reconnected:*' })
    if ($null -ne $State.DisabledAdapter) {
        & $Ops.RestoreAdapter $State.DisabledAdapter
        $State.DisabledAdapter = $null; & $Ops.Save $State
        & $Ops.Log 'Restored adapter recorded by a previous interrupted cycle'
    }
    $online = [bool](& $Ops.Probe)
    & $Ops.Log "Connectivity online=$online"
    if (-not $online) {
        $State.FailureCount = [int]$State.FailureCount + 1
        if (-not $State.OutageSinceUtc) { $State.OutageSinceUtc = $Now.ToString('o') }
        & $Ops.Save $State
        & $Ops.Log "Consecutive failures=$($State.FailureCount)"
        $eligible = -not $State.LastRecoveryUtc -or ([datetime]$State.LastRecoveryUtc).ToUniversalTime().AddMinutes($Config.RecoveryCooldownMinutes) -le $Now
        if ($State.FailureCount -ge $Config.FailureThreshold -and $eligible) {
            $State.LastRecoveryUtc = $Now.ToString('o'); & $Ops.Save $State
            if ($Config.EnableInternetReset) {
                for ($attempt = 1; $attempt -le $Config.RecoveryAttemptsPerStage; $attempt++) {
                    & $Ops.Log "Stage 1 attempt $attempt of $($Config.RecoveryAttemptsPerStage): DNS flush and DHCP refresh"
                    try { & $Ops.Reset } catch { & $Ops.Log 'Stage 1 operation failed; retesting connectivity' }
                    $online = [bool](& $Ops.Probe)
                    if ($online) { break }
                }
            }
            if (-not $online -and $Config.EnableAdapterRestart) {
                for ($attempt = 1; $attempt -le $Config.RecoveryAttemptsPerStage; $attempt++) {
                    $adapter = & $Ops.FindAdapter
                    if ($null -eq $adapter) { & $Ops.Log 'No eligible default route physical adapter; skipping adapter restart'; break }
                    & $Ops.Log "Stage 2 attempt $attempt of $($Config.RecoveryAttemptsPerStage): restart default route physical adapter $($adapter.Guid)"
                    # Marker is durable BEFORE disable. Restore is attempted in finally and the next cycle.
                    $State.DisabledAdapter = @{ Guid = [string]$adapter.Guid; Utc = $Now.ToString('o') }; & $Ops.Save $State
                    try { & $Ops.DisableAdapter $State.DisabledAdapter }
                    catch { & $Ops.Log 'Adapter disable was interrupted or failed' }
                    finally {
                        & $Ops.RestoreAdapter $State.DisabledAdapter
                        $State.DisabledAdapter = $null; & $Ops.Save $State
                    }
                    & $Ops.AdapterWait $adapter
                    $online = [bool](& $Ops.Probe)
                    if ($online) { break }
                }
            }
            if (-not $online) {
                $decision = Get-JLCRebootDecision $State $Config $Now
                & $Ops.Log "Stage 3 reboot decision: $decision"
                if ($decision -eq 'Allowed') {
                    $State.RebootsUtc = @($State.RebootsUtc | Where-Object { ([datetime]$_).ToUniversalTime() -gt $Now.AddHours(-24) }) + @($Now.ToString('o'))
                    & $Ops.Save $State
                    & $Ops.Reboot
                    return
                }
            } else { & $Ops.Log 'Internet recovery completed successfully' }
        }
    }
    if ($online) {
        if ($State.OutageSinceUtc) { $template = Get-JLCEmailTemplate -Kind Reconnected -OutageStartedUtc $State.OutageSinceUtc; Add-JLCNotification $State ('reconnected:' + $State.OutageSinceUtc) $template.Subject $template.Body $Now $Config }
        $State.OutageSinceUtc = ''; $State.FailureCount = 0
        if ($Config.EnablePublicIP) {
            $ip = & $Ops.PublicIP
            if ($ip -and (Test-JLCPublicIPv4 $ip)) {
                if ($State.LastPublicIP -and $ip -ne $State.LastPublicIP) { $template = Get-JLCEmailTemplate -Kind PublicIPChanged -PreviousIP $State.LastPublicIP -NewIP $ip; Add-JLCNotification $State ('ip:' + [guid]::NewGuid()) $template.Subject $template.Body $Now $Config; & $Ops.Log "Public IPv4 changed from $($State.LastPublicIP) to $ip" }
                $State.LastPublicIP = $ip
            }
        }
    }
    $State.LastOnline = $online; $State.LastCycleUtc = $Now.ToString('o'); & $Ops.Save $State
    if ($online -and $Config.EnableEmail) {
        $sent = 0
        foreach ($item in @($State.Pending)) {
            if ($sent -ge $Config.MaxEmailsPerCycle) { break }
            if (([datetime]$item.NextAttemptUtc).ToUniversalTime() -gt $Now) { continue }
            $sent++
            try {
                & $Ops.Send $item
                $State.Pending = @($State.Pending | Where-Object Id -ne $item.Id)
                & $Ops.Log "Email accepted by SMTP server: $($item.Id)"
            } catch {
                $item.Attempts = [int]$item.Attempts + 1
                $item.NextAttemptUtc = $Now.AddMinutes([math]::Min(360, [math]::Pow(2, [math]::Min(9, $item.Attempts)) * 5)).ToString('o')
                & $Ops.Log "Email failed; retained for retry: $($item.Id)"
            }
            & $Ops.Save $State
        }
    }
    & $Ops.Log 'Cycle completed'
}
function Test-JLCPublicIPv4([string]$Text) {
    if ($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Text, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $ip.GetAddressBytes()
    return -not ($b[0] -in @(0,10,127) -or $b[0] -ge 224 -or ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and ($b[1] -eq 168 -or ($b[1] -eq 0 -and $b[2] -in @(0,2)))) -or ($b[0] -eq 198 -and ($b[1] -in @(18,19) -or ($b[1] -eq 51 -and $b[2] -eq 100))) -or ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))
}
function Get-JLCHttps([string]$Uri, [int]$Seconds) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Timeout = $Seconds * 1000; $request.ReadWriteTimeout = $Seconds * 1000
    $request.AllowAutoRedirect = $false; $request.Proxy = $null; $request.UserAgent = 'JLCIPWatch/1.0'
    $response = $null
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw 'Unexpected HTTPS response.' }
        $reader = [IO.StreamReader]::new($response.GetResponseStream())
        try {
            $buffer = New-Object char[] 4096
            $count = $reader.Read($buffer, 0, $buffer.Length)
            return [string]::new($buffer, 0, $count)
        } finally { $reader.Dispose() }
    } finally { if ($null -ne $response) { $response.Dispose() } }
}
function Test-JLCConnectivity($Config) {
    $dns = $false; $https = 0
    foreach ($name in $Config.DnsNames) {
        try { $job = [Net.Dns]::GetHostAddressesAsync($name); if ($job.Wait($Config.ProbeTimeoutSeconds * 1000) -and $job.Result.Count -gt 0) { $dns = $true; break } } catch { }
    }
    foreach ($uri in $Config.HttpsEndpoints) { try { $null = Get-JLCHttps $uri $Config.ProbeTimeoutSeconds; $https++ } catch { } }
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $gateway = $null; $gatewayReachable = $null
    try {
        $route = Get-JLCDefaultAdapter
        if ($null -ne $route -and $route.Gateway -and $route.Gateway -notin @('0.0.0.0','::')) {
            $gateway = $route.Gateway; $ping = [Net.NetworkInformation.Ping]::new()
            try { $gatewayReachable = $ping.Send($gateway, 1000).Status -eq 'Success' } finally { $ping.Dispose() }
        }
    } catch { }
    # ICMP is advisory because many gateways block it. DNS failure alone is also insufficient.
    @{ Online = ($https -ge 2 -or ($https -ge 1 -and $dns)); Dns = $dns; HttpsSuccesses = $https; UpAdapters = $adapters.Count; Gateway = $gateway; GatewayReachable = $gatewayReachable }
}
function Get-JLCPublicIP($Config) {
    foreach ($uri in $Config.PublicIPEndpoints) { try { $text = (Get-JLCHttps $uri $Config.ProbeTimeoutSeconds).Trim(); if (Test-JLCPublicIPv4 $text) { return $text } } catch { } }
    return $null
}
function Get-JLCDefaultAdapter {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
    $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') -and $_.State -eq 'Alive' })
    $candidates = @()
    foreach ($route in $routes) {
        $adapter = $adapters | Where-Object { $_.ifIndex -eq $route.InterfaceIndex -and $_.Status -eq 'Up' } | Select-Object -First 1
        if ($null -eq $adapter) { continue }
        $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily $route.AddressFamily -ErrorAction Stop | Select-Object -First 1
        $candidates += @{ Guid = [string]$adapter.InterfaceGuid; Index = [int]$adapter.ifIndex; Name = [string]$adapter.Name; Gateway = [string]$route.NextHop; Metric = ([int]$route.RouteMetric + [int]$iface.InterfaceMetric) }
    }
    return $candidates | Sort-Object { $_.Metric } | Select-Object -First 1
}
function Invoke-JLCNative([string]$File, [string]$Arguments, [int]$TimeoutSeconds = 15) {
    $info = [Diagnostics.ProcessStartInfo]::new($File, $Arguments)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch { }; throw 'Native operation timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Native operation failed.' }
    } finally { $process.Dispose() }
}
function Update-JLCDhcp($Adapter) {
    if ($null -eq $Adapter) { return }
    # Do not release any leases or alter static settings. Renew only DHCP-enabled IPv4.
    $iface = Get-NetIPInterface -InterfaceIndex $Adapter.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($null -ne $iface -and $iface.Dhcp -eq 'Enabled') {
        if ($Adapter.Name -match '["*?\r\n]') { throw 'Unsupported adapter name.' }
        Invoke-JLCNative "$env:SystemRoot\System32\ipconfig.exe" ('/renew "{0}"' -f $Adapter.Name)
    }
}
function Restore-JLCAdapter($Marker) {
    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq [string]$Marker.Guid } | Select-Object -First 1
    if ($null -eq $adapter) { throw 'Previously disabled adapter cannot be found. Recovery marker retained.' }
    $adapter | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
}
function ConvertTo-JLCEmailSecret([string]$Text, [switch]$Gmail) {
    if (-not $Text) { return $null }
    if ($Gmail) {
        $Text = $Text -replace '\s', ''
        if ($Text -notmatch '^[a-zA-Z]{16}$') { throw 'Gmail needs its 16 letter Google App Password. Select Get App Password after enabling two step verification. Your regular account password will not work here.' }
    }
    return ConvertTo-SecureString $Text -AsPlainText -Force
}
function Get-JLCEmailFailure($Failure) {
    $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
    $messages = @(); $types = @(); $smtpStatus = ''; $socketStatus = ''
    while ($null -ne $exception) {
        $messages += $exception.Message; $types += $exception.GetType().FullName
        if ($exception -is [Net.Mail.SmtpException]) { $smtpStatus = $exception.StatusCode.ToString() }
        if ($exception -is [Net.Sockets.SocketException]) { $socketStatus = $exception.SocketErrorCode.ToString() }
        $exception = $exception.InnerException
    }
    # Inspect provider responses but return only fixed explanations and numeric response codes.
    # Never expose arbitrary server text, which could echo a credential.
    $text = $messages -join ' '
    $codes = @([regex]::Matches($text, '\b[245]\d\d[ -]+[245]\.\d{1,3}\.\d{1,3}\b') | ForEach-Object { $_.Value.Replace('-',' ') } | Select-Object -Unique)
    $reason = 'The email test failed. Check the SMTP settings and connection.'
    if ($text -match '535|5\.7\.8\b|5\.7\.80\b|Username and Password not accepted') { $reason = 'The email server rejected the account credentials. For Gmail, use a current Google App Password created by the sending account.' }
    elseif ($text -match '534|5\.7\.9\b|Application.specific password required') { $reason = 'Google requires an App Password for this account. Use Get App Password after enabling two step verification.' }
    elseif ($text -match '5\.7\.14\b|log in via your web browser') { $reason = 'Google requires account verification in your browser before this account can send mail.' }
    elseif ($socketStatus -in @('HostNotFound','NoData','TryAgain')) { $reason = 'The SMTP server name could not be resolved. Check the server address and DNS connection.' }
    elseif ($socketStatus -eq 'ConnectionRefused') { $reason = 'The SMTP connection was refused. Check the server port and firewall.' }
    elseif ($socketStatus -eq 'TimedOut' -or $text -match 'timed out|timeout') { $reason = 'The SMTP connection timed out. Check internet access, firewall, and the SMTP server port.' }
    elseif ($text -match 'net_io_connectionclosed|connection was closed|connection.*forcibly closed') { $reason = 'The SMTP server closed the connection before accepting the message. Check the SMTP account and App Password. A firewall or mail security filter can also close the connection.' }
    elseif ($types -contains 'System.Security.Authentication.AuthenticationException' -or $text -match 'certificate|SSL/TLS|secure channel') { $reason = 'The encrypted SMTP connection failed. Check the Windows clock, certificate trust, and security software.' }
    elseif ($smtpStatus -eq 'MustIssueStartTlsFirst' -or $text -match 'STARTTLS') { $reason = 'The server requires STARTTLS or authentication. Use port 587 and the correct SMTP account credentials.' }
    elseif ($types -contains 'System.Net.Mail.SmtpFailedRecipientException' -or $types -contains 'System.Net.Mail.SmtpFailedRecipientsException') { $reason = 'The server rejected the recipient. Check the Send alerts to address and sender permissions.' }
    elseif ($types -contains 'System.IO.FileNotFoundException' -or $types -contains 'System.Security.Cryptography.CryptographicException') { $reason = 'The saved email credential could not be read. Enter the App Password again in this window.' }
    $details = @(); if ($smtpStatus) { $details += "SMTP status: $smtpStatus" }; if ($socketStatus) { $details += "Connection status: $socketStatus" }; if ($codes.Count) { $details += 'Server code: ' + ($codes -join ', ') }
    if ($details.Count) { $reason += "`r`n`r`n" + ($details -join "`r`n") }
    return $reason
}
function New-JLCSmtpClient([string]$HostName, [int]$Port) { return [Net.Mail.SmtpClient]::new($HostName,$Port) }
function Send-JLCMail($Config, [string]$CredentialPath, $Notification, [securestring]$Secret) {
    $client = New-JLCSmtpClient $Config.SmtpHost ([int]$Config.SmtpPort)
    $message = [Net.Mail.MailMessage]::new($Config.SenderEmail, $Config.RecipientEmail)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $client.EnableSsl = $true; $client.Timeout = [int]$Config.SmtpTimeoutSeconds * 1000; $client.UseDefaultCredentials = $false
        if ($null -ne $Secret) { $client.Credentials = [Net.NetworkCredential]::new($Config.SmtpUsername, $Secret) }
        else { $client.Credentials = [Net.NetworkCredential]::new($Config.SmtpUsername, (Get-JLCSecret $CredentialPath)) }
        $message.Subject = '[Net Kitty] ' + $Notification.Subject
        $message.Body = $Notification.Body + "`r`nNotification ID: " + $Notification.Id
        $message.Headers.Add('X-JLC-Notification-ID', $Notification.Id)
        $client.Send($message)
    } finally { $message.Dispose(); $client.Dispose() }
}
function Get-JLCMutex([string]$Root) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $suffix = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant())))).Replace('-','').Substring(0,24) } finally { $hash.Dispose() }
    $security = [Security.AccessControl.MutexSecurity]::new()
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.MutexRights]::FullControl, 'Allow')) }
    $created = $false
    return [Threading.Mutex]::new($false, "Global\JLCIPWatch-$suffix", [ref]$created, $security)
}
function New-JLCTaskDefinition([string]$Root, $Config) {
    $app = Join-Path $Root 'App'
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $app 'JLCIPWatch.ps1')) -WorkingDirectory $app
    $startup = New-ScheduledTaskTrigger -AtStartup; $startup.Delay = 'PT1M'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($Config.IntervalMinutes) -RepetitionInterval (New-TimeSpan -Minutes $Config.IntervalMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    return New-ScheduledTask -Action $action -Trigger @($startup,$repeat) -Principal $principal -Settings $settings -Description 'Hourly internet and public IP watchdog. Runs without interactive sign in.'
}
function Invoke-JLCWatchdog([string]$Root, [switch]$RestoreOnly) {
    $mutex = Get-JLCMutex $Root; $locked = $false; $config = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return }
        $statePath = Join-Path $Root 'state.json'; $state = Read-JLCState $statePath
        # Restore happens before configuration parsing, so a bad config cannot strand an adapter.
        if ($null -ne $state.DisabledAdapter) { Restore-JLCAdapter $state.DisabledAdapter; $state.DisabledAdapter = $null; Write-JLCJson $statePath $state }
        if ($RestoreOnly) { return }
        $config = Read-JLCJson (Join-Path $Root 'config.json'); Assert-JLCConfig $config
        $ops = @{
            Save = { param($value) Write-JLCJson $statePath $value }.GetNewClosure()
            Log = { param($message) Write-JLCLog $Root $config $message }.GetNewClosure()
            Probe = { $result = Test-JLCConnectivity $config; Write-JLCLog $Root $config ("Probe DNS={0} HTTPS={1} adapters={2} gateway={3} ping={4}" -f $result.Dns,$result.HttpsSuccesses,$result.UpAdapters,$result.Gateway,$result.GatewayReachable); return $result.Online }.GetNewClosure()
            PublicIP = { Get-JLCPublicIP $config }.GetNewClosure()
            Reset = { Clear-DnsClientCache; Update-JLCDhcp (Get-JLCDefaultAdapter); Start-Sleep -Seconds $config.ResetWaitSeconds }.GetNewClosure()
            FindAdapter = { Get-JLCDefaultAdapter }
            DisableAdapter = { param($marker) Get-NetAdapter -Physical | Where-Object { [string]$_.InterfaceGuid -eq $marker.Guid } | Disable-NetAdapter -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 2 }
            RestoreAdapter = { param($marker) Restore-JLCAdapter $marker }
            AdapterWait = { param($adapter) Start-Sleep -Seconds $config.AdapterWaitSeconds; Update-JLCDhcp $adapter }.GetNewClosure()
            Reboot = { Invoke-JLCNative "$env:SystemRoot\System32\shutdown.exe" '/r /t 60 /d p:0:0 /c "Net Kitty connectivity recovery"' }
            Send = { param($item) Send-JLCMail $config (Join-Path $Root 'smtp.credential') $item }.GetNewClosure()
        }
        Invoke-JLCCycle $state $config $ops
    } catch {
        if ($null -ne $config) { try { Write-JLCLog $Root $config ('Cycle error type: ' + $_.Exception.GetType().FullName + '. Next scheduled run will retry.') } catch { } }
        throw
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
Export-ModuleMember -Function *-JLC*
