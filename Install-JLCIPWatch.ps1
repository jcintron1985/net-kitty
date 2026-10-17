#requires -Version 5.1
[CmdletBinding()]
param([hashtable]$Configuration, [securestring]$EmailSecret, [switch]$NoStart, [switch]$TestEmail)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JLCIPWatch.Core.psm1') -Force
Assert-JLCAdmin
$root = Join-Path $env:ProgramData 'JLCIPWatch'
$app = Join-Path $root 'App'
$interactive = $null -eq $Configuration
if ($null -eq $Configuration) {
    if (Test-Path -LiteralPath (Join-Path $root 'config.json')) { $Configuration = Read-JLCJson (Join-Path $root 'config.json') }
    else { $Configuration = Read-JLCJson (Join-Path $PSScriptRoot 'config.json') }
    $Configuration.SenderEmail = Read-Host 'Your sending email address'
    $Configuration.SmtpUsername = $Configuration.SenderEmail
    $Configuration.RecipientEmail = Read-Host 'Send alerts to this email address'
    $hostName = Read-Host 'SMTP server, press Enter for smtp.gmail.com'
    if ($hostName) { $Configuration.SmtpHost = $hostName }
}
Assert-JLCConfig $Configuration
if ($Configuration.EnableEmail -and $null -eq $EmailSecret -and ($interactive -or -not (Test-Path -LiteralPath (Join-Path $root 'smtp.credential')))) { $EmailSecret = Read-Host 'Email App Password, never your regular Gmail password' -AsSecureString }
Set-JLCPrivateDirectory $root
# Refuse links anywhere in the installed tree before modifying privileged files.
if (@(Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Remove links or junctions from the application directory before installing.' }
Set-JLCPrivateTree $root
foreach ($folder in @($app,(Join-Path $root 'Logs'))) { Set-JLCPrivateDirectory $folder }
foreach ($taskName in @('Net Kitty','Net Kitty Credential Check')) { if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } }
$mutex = Get-JLCMutex $root; $locked = $false
try {
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'A watchdog cycle is still running. Wait and try again.' }
    $statePath = Join-Path $root 'state.json'; $state = Read-JLCState $statePath
    if ($null -ne $state.DisabledAdapter) { Restore-JLCAdapter $state.DisabledAdapter; $state.DisabledAdapter = $null }
    $files = @('JLCIPWatch.ps1','JLCIPWatch.Core.psm1','JLCIPWatch.UI.ps1','Install-JLCIPWatch.ps1','Uninstall-JLCIPWatch.ps1','Test-JLCIPWatch.ps1','README.md','VALIDATION.md','NetKitty.exe')
    foreach ($name in $files) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source)) { throw "Installer file missing: $name. Use the complete build package." }
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath((Join-Path $app $name))) { Copy-Item -LiteralPath $source -Destination (Join-Path $app $name) -Force }
    }
    if ([IO.Path]::GetFullPath($PSScriptRoot) -ne [IO.Path]::GetFullPath($app)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Destination (Join-Path $app 'config.json') -Force
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Tests')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Tests') -Destination $app -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Assets') -Destination $app -Recurse -Force
    }
    if ($null -ne $EmailSecret) { Protect-JLCCredential (Join-Path $root 'smtp.credential') $EmailSecret }
    Write-JLCJson (Join-Path $root 'config.json') $Configuration
    Write-JLCJson $statePath $state
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $definition = New-JLCTaskDefinition $root $Configuration
    Register-ScheduledTask -TaskName 'Net Kitty' -InputObject $definition -Force | Out-Null
    # Credential diagnostic runs inside SYSTEM and reports only pass/fail, never the secret.
    $checkAction = New-ScheduledTaskAction -Execute $exe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -SystemCredentialProbe' -f (Join-Path $app 'Test-JLCIPWatch.ps1')) -WorkingDirectory $app
    $checkSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'Net Kitty Credential Check' -Action $checkAction -Principal $definition.Principal -Settings $checkSettings -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Net Kitty.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath); $shortcut.TargetPath = Join-Path $app 'NetKitty.exe'; $shortcut.WorkingDirectory = $app; $shortcut.Save()
    $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JLCIPWatch'
    New-Item -Path $uninstallKey -Force | Out-Null
    $properties = @{ DisplayName = 'Net Kitty'; DisplayVersion = '1.0.2'; Publisher = 'JLC'; InstallLocation = $app; DisplayIcon = (Join-Path $app 'NetKitty.exe'); UninstallString = ('"{0}" --uninstall' -f (Join-Path $app 'NetKitty.exe')); NoModify = 1; NoRepair = 1 }
    foreach ($key in $properties.Keys) { Set-ItemProperty -Path $uninstallKey -Name $key -Value $properties[$key] }
    Write-JLCLog $root $Configuration 'Installation or settings update completed. Background task registered.'
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
Start-ScheduledTask -TaskName 'Net Kitty Credential Check'
if (-not $NoStart) { Start-ScheduledTask -TaskName 'Net Kitty' }
if ($TestEmail) { Send-JLCMail $Configuration (Join-Path $root 'smtp.credential') @{ Subject = 'Installation test'; Body = "Installation email test from $env:COMPUTERNAME"; Id = [guid]::NewGuid().ToString() } }
Write-Output "Installed. Checks run every $($Configuration.IntervalMinutes) minutes and after Windows starts, under SYSTEM."
