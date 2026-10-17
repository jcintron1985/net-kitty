#requires -Version 5.1
# One explicitly requested SMTP test. The password is read from a masked prompt only.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Sender, [Parameter(Mandatory=$true)][string]$Recipient)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'JLCIPWatch.Core.psm1') -Force -DisableNameChecking
$config = Read-JLCJson (Join-Path $project 'config.json')
$config.SenderEmail = $Sender; $config.SmtpUsername = $Sender; $config.RecipientEmail = $Recipient
Assert-JLCConfig $config
$secret = Read-Host 'Enter credential for this single email test. It will not be saved' -AsSecureString
try {
    Send-JLCMail $config '' @{ Subject = 'Requested email delivery test'; Body = 'This is the single email test requested during Net Kitty setup. No monitoring or recovery has been installed or enabled by this test.'; Id = [guid]::NewGuid().ToString() } -Secret $secret
    @{ SmtpAccepted = $true; Sender = $Sender; Recipient = $Recipient; CredentialSaved = $false } | ConvertTo-Json
} catch {
    $plain = [Net.NetworkCredential]::new('', $secret).Password
    $chain = @(); $exception = $_.Exception
    while ($null -ne $exception) {
        $safe = $exception.Message
        if ($plain) { $safe = $safe.Replace($plain,'[redacted]').Replace([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain)),'[redacted]') }
        $chain += @{ Type = $exception.GetType().FullName; Detail = $safe }
        $exception = $exception.InnerException
    }
    $plain = $null
    @{ SmtpAccepted = $false; Reason = (Get-JLCEmailFailure $_); CredentialSaved = $false; Diagnostics = $chain } | ConvertTo-Json -Depth 5
    exit 1
} finally { $secret.Dispose(); $secret = $null }
