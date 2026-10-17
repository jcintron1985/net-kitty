#requires -Version 5.1
# Explicit, interactive one-message SMTP diagnostic. Never used by scheduled monitoring.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Account)
$ErrorActionPreference = 'Stop'
$address = [Net.Mail.MailAddress]::new($Account)
if ($address.Address -ne $Account -or $Account -match '[\r\n]') { throw 'Enter a plain account email address.' }
$secret = Read-Host 'Enter credential for final direct Gmail diagnostic. It will not be saved' -AsSecureString
$tcp = [Net.Sockets.TcpClient]::new(); $reader = $null; $writer = $null; $ssl = $null
function Read-Reply {
    $response = @()
    for ($i=0; $i -lt 30; $i++) {
        $line = $script:reader.ReadLine()
        if ($null -eq $line) { throw 'SMTP connection was closed before a reply.' }
        if ($line -notmatch '^\d{3}[ -]') { throw 'Invalid SMTP reply.' }
        $response += $line
        if ($line[3] -eq ' ') { return @{ Code = [int]$line.Substring(0,3); Text = ($response -join ' ') } }
    }
    throw 'SMTP reply exceeded the response limit.'
}
function Write-Command([string]$Command) { $script:writer.WriteLine($Command); return Read-Reply }
try {
    $connect = $tcp.BeginConnect('smtp.gmail.com',587,$null,$null)
    if (-not $connect.AsyncWaitHandle.WaitOne(5000)) { throw 'SMTP TCP connection timed out.' }
    $tcp.EndConnect($connect)
    $stream = $tcp.GetStream(); $stream.ReadTimeout = 10000; $stream.WriteTimeout = 10000
    $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
    $writer = [IO.StreamWriter]::new($stream,[Text.Encoding]::ASCII,1024,$true); $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
    if ((Read-Reply).Code -ne 220) { throw 'Gmail greeting was not accepted.' }
    if ((Write-Command 'EHLO NetKitty').Code -ne 250) { throw 'Gmail rejected EHLO.' }
    if ((Write-Command 'STARTTLS').Code -ne 220) { throw 'Gmail rejected STARTTLS.' }
    $reader.Dispose(); $writer.Dispose(); $reader=$null; $writer=$null
    $ssl = [Net.Security.SslStream]::new($stream,$false); $ssl.ReadTimeout = 10000; $ssl.WriteTimeout = 10000
    $ssl.AuthenticateAsClient('smtp.gmail.com',$null,[Security.Authentication.SslProtocols]::Tls12,$true)
    $reader = [IO.StreamReader]::new($ssl,[Text.Encoding]::ASCII,$false,1024,$true)
    $writer = [IO.StreamWriter]::new($ssl,[Text.Encoding]::ASCII,1024,$true); $writer.NewLine = "`r`n"; $writer.AutoFlush = $true
    if ((Write-Command 'EHLO NetKitty').Code -ne 250) { throw 'Gmail rejected encrypted EHLO.' }
    $reply = Write-Command 'AUTH LOGIN'
    if ($reply.Code -ne 334) { throw "Gmail did not offer password authentication. SMTP code $($reply.Code)." }
    $reply = Write-Command ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Account)))
    if ($reply.Code -ne 334) { throw "Gmail rejected the account. SMTP code $($reply.Code)." }
    $plain = [Net.NetworkCredential]::new('', $secret).Password
    try { $reply = Write-Command ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain))) } finally { $plain = $null }
    if ($reply.Code -ne 235) {
        $enhanced = [regex]::Match($reply.Text,'\b[245]\.\d{1,3}\.\d{1,3}\b').Value
        @{ Authenticated = $false; SmtpCode = $reply.Code; EnhancedCode = $enhanced; EmailAccepted = $false; CredentialSaved = $false } | ConvertTo-Json
        exit 1
    }
    if ((Write-Command "MAIL FROM:<$Account>").Code -ne 250) { throw 'Gmail rejected sender.' }
    if ((Write-Command "RCPT TO:<$Account>").Code -ne 250) { throw 'Gmail rejected recipient.' }
    if ((Write-Command 'DATA').Code -ne 354) { throw 'Gmail rejected message data.' }
    $writer.WriteLine("From: $Account`r`nTo: $Account`r`nSubject: Net Kitty requested email test`r`nMIME-Version: 1.0`r`nContent-Type: text/plain; charset=utf-8`r`n`r`nThis is the requested Net Kitty email delivery test. No credential was saved.`r`n.")
    $reply = Read-Reply
    @{ Authenticated = $true; SmtpCode = $reply.Code; EmailAccepted = ($reply.Code -eq 250); CredentialSaved = $false } | ConvertTo-Json
    $null = Write-Command 'QUIT'
} catch { @{ EmailAccepted = $false; ErrorType = $_.Exception.GetType().FullName; CredentialSaved = $false } | ConvertTo-Json; exit 1 }
finally { if($reader){$reader.Dispose()}; if($writer){$writer.Dispose()}; if($ssl){$ssl.Dispose()}; $tcp.Dispose(); $secret.Dispose(); $secret=$null }
