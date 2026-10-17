# Net Kitty

<img src="Assets/NetKitty.png" alt="Net Kitty tuxedo cat icon" width="128">

**[Download the Windows installer](https://github.com/jcintron1985/net-kitty/releases/latest)**

A small Windows internet watchdog with hourly background checks, protected connection recovery, and email alerts for internet reconnection or public IP changes. Start with the single file installer in Releases. Source scripts are available here for inspection and building.

A Windows 10 and Windows 11 desktop setup and settings app with an unattended PowerShell 5.1 watchdog. Each installation uses its own email sending account. No Windows password, signed in desktop session, extra runtime download, or paid monitoring service is needed.

Checks run **once per hour**, plus a check at Windows startup after a one minute delay and immediately after installation. This follows the requested hourly schedule. Three consecutive failed checks are required before recovery, so an outage can take roughly three hours to trigger recovery. Missed tasks may run when the computer becomes available. Sleep or a powered off PC prevents execution. The app does not wake a sleeping PC.

## Install the Windows app

1. Run `dist\NetKitty-Setup-1.0.2.exe` and approve Windows administrator access.
2. Choose Gmail or a custom SMTP server supporting STARTTLS and username/password authentication.
3. Enter your sending account, recipient address, SMTP username, and App Password. The recipient can use any email provider.
4. Select **Send test email**. Check the recipient inbox and spam folder. A successful test means the SMTP server accepted the message, not proof of inbox delivery.
5. Select **Install and start**. Close the window whenever you like. Monitoring continues under SYSTEM.

Open **Net Kitty** from the Start menu to change settings, test email, view status, read logs, or uninstall. Administrator access is required for settings and diagnostics. Windows Installed Apps also has an uninstall entry. Installation on the development computer has not been performed by the build process.

Version 1.0.2 adds copy and paste through keyboard shortcuts and a right click menu, including the masked password and SMTP port. The eye button switches between Show and Hide for the password being entered. The Gmail preset fills the server and port without disabling editing. **Email previews** displays the same two templates used for actual automatic alerts, with sample details and a Copy template button. Previewing does not send an email.

The executable is unsigned. Windows may show an unknown publisher or SmartScreen prompt. Verify the supplied SHA256 checksum. A publicly distributed release should be signed with the publisher's trusted code signing certificate and validated on clean Windows 10 and Windows 11 machines before calling it production validated.

## Gmail and other providers

For Gmail, enable two step verification, then create a dedicated 16 letter App Password at https://myaccount.google.com/apppasswords. Use that App Password in the app, not the regular account password. Google account policies can make App Passwords unavailable. Spaces in Google's displayed App Password are removed by the GUI.

Gmail defaults are `smtp.gmail.com`, port `587`, STARTTLS, and your full sending email address as SMTP username. No shared sender account or credential is embedded. For a test account, enter that account manually. The project contains no real email password.

Custom SMTP requires the provider's actual host, STARTTLS port, username, and password or app specific credential. Port 465 implicit TLS and providers requiring OAuth are not supported by this version. Outlook.com requires OAuth, so its email address and ordinary password cannot be used as a sending account here. Outlook addresses work as recipients. This app does not implement a universal Google or Microsoft sign in button.

Google documentation: https://support.google.com/accounts/answer/185833

Microsoft documentation: https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com

Version 1.0.1 shows specific setup validation errors and distinguishes authentication rejection, a closed SMTP connection, timeout, DNS failure, and encryption errors. Missing fields and a regular Gmail password are identified before sending. Gmail error 535 with enhanced code 5.7.8 means the credentials were rejected. Create an App Password while signed into the actual sending account. Changing a Google account password revokes existing App Passwords, so create a new one after such a change. Do not paste passwords into chat.

## Monitoring and recovery

Each cycle checks multiple HTTPS endpoints, DNS, up adapters, and default gateway availability. One failed site does not trigger an outage. One successful HTTPS endpoint plus DNS, or two successful HTTPS endpoints, establishes connectivity. Gateway ping is advisory because routers can block ICMP. Captive portals, corporate proxies, VPN routing, and endpoint filtering need environment validation. HTTPS certificate validation stays enabled. Requests bypass interactive user proxy configuration for predictable SYSTEM behavior.

After three failures, the watchdog performs these steps in order. The connection reset and adapter restart stages each get at most **three attempts per monitoring job**, with a connectivity retest after every attempt. Success stops recovery immediately. The next stage begins only after the previous stage exhausts its attempts. Every native command, network request, and the entire scheduled job has a time limit. There are no unlimited recovery loops.

1. Flush DNS and renew DHCP on the default route physical adapter, when DHCP is enabled. Static addresses are not rewritten. Leases are never indiscriminately released.
2. Restart one active physical default route adapter. It records the adapter GUID before disabling it and reenables it in a finally block. If interrupted, the next scheduled cycle attempts to restore that adapter before reading configuration. This stage can disconnect Remote Desktop. VPN and virtual adapters are not selected for restart.
3. Request a Windows restart with a 60 second countdown if connectivity is still unavailable. Only one reboot request is made per job, with the stricter two per day protection described below. Reboot reservations are saved before requesting the restart. Windows may force application closure at the end of the countdown. Do not enable automatic PC restarts on a machine with unsaved work you cannot afford to lose.

Recovery attempts have a 30 minute cooldown. Reboots are limited to two in a rolling 24 hour period, at least 30 minutes apart. On hourly checks, attempts are normally at least one hour apart. Initial installation, a missing state file, or recovery from damaged state imposes an additional 24 hour reboot hold. Monitoring and other recovery steps continue during the hold. Failed reboot requests still consume their reservation, conservatively. Uninstall does not indiscriminately cancel a shutdown already requested by a completed watchdog cycle. To cancel a known pending watchdog reboot during its countdown, an administrator can run `shutdown.exe /a`.

Public IPv4 uses two HTTPS services and strict address validation. Failed lookups keep the previous address. IPv6 public IP change notification is not implemented. **Automatic email is sent only for a public IP change or when internet connectivity returns after a detected outage.** Here, data loss means internet connection loss, not deleted files or lost storage data. Startup, reboot requests, reboot limits, and recovery steps are logged locally without a separate email. The first observed public IP establishes a baseline and sends no email. The Send test email button is an explicit manual test. Notifications remain queued until SMTP accepts them. Retry delay increases up to six hours. With hourly checks, retry happens at the first eligible hourly cycle. At most five notifications are attempted per cycle.

Normal cycles do not duplicate a queued change. SMTP has no transactional delivery guarantee: a process or power failure after SMTP accepts a message but before local acknowledgment can cause a duplicate. Each message carries a stable notification ID for correlation. Queue capacity is 1,000 messages; when full, existing messages are preserved and the cycle logs an error rather than discarding them. A very prolonged outage with many IP changes needs operator attention.

## Storage and security

Installed application: `C:\ProgramData\JLCIPWatch\App`

Configuration: `C:\ProgramData\JLCIPWatch\config.json`

State: `C:\ProgramData\JLCIPWatch\state.json` and its atomic replacement backup.

Credential: `C:\ProgramData\JLCIPWatch\smtp.credential`

Logs: `C:\ProgramData\JLCIPWatch\Logs`

Credentials use Windows DPAPI LocalMachine scope so SYSTEM can decrypt them without an interactive user profile. Restrictive directory ACLs allow only SYSTEM and Administrators. LocalMachine DPAPI is not a boundary against local administrators or another process that obtains the encrypted blob. Do not copy credentials between machines or relax the directory ACLs. Secrets are not written to config, task arguments, or logs. Transient managed memory may contain the secret while SMTP authenticates.

The scheduled task uses SYSTEM service account logon, highest privileges, IgnoreNew overlap policy, a twenty minute execution limit, startup and hourly triggers, and battery operation. A protected global mutex also prevents simultaneous manual and scheduled cycles. An exception fails one cycle; the hourly task remains registered for future cycles. State writes use flushed temporary files and atomic replacement. Backup recovery inhibits reboots. Daily logs rotate at 5 MB with one rotation and 30 day retention.

## Build and safe simulation

Run in native Windows PowerShell 5.1 from the project directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-JLCIPWatch.ps1 -Simulation
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
Get-FileHash .\dist\NetKitty-Setup-1.0.2.exe -Algorithm SHA256
```

The build uses the Windows .NET Framework C# compiler and produces a standalone setup EXE, an inspectable ZIP, and checksums. Simulation injects inert callbacks. It does not probe the network, disable adapters, send emails, request a reboot, or register tasks. Temporary local state, DPAPI test blobs, and logs are exercised and removed. The simulation includes internet loss and restoration, IP changes, reset sequencing, adapter restart sequencing, reboot decisions, persistence, notification retry, cooldowns, and damaged state handling.

To inspect the source package, extract `NetKitty-Source.zip`. From an elevated Windows PowerShell window in that extracted directory, the script installer is also supported:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-JLCIPWatch.ps1
```

It securely prompts for an email App Password, registers the task, and starts the first monitoring cycle. Run `Install-JLCIPWatch.ps1 -TestEmail` to also send an installation test message. No password should be placed in a command line.

## Installed diagnostics

Run as administrator:

```powershell
Set-Location C:\ProgramData\JLCIPWatch\App
.\Test-JLCIPWatch.ps1
.\Test-JLCIPWatch.ps1 -CheckSystemCredential
.\Test-JLCIPWatch.ps1 -SendTestEmail
.\Test-JLCIPWatch.ps1 -Simulation
Get-ScheduledTask -TaskName 'Net Kitty' | Format-List *
Get-ScheduledTaskInfo -TaskName 'Net Kitty'
Get-Content C:\ProgramData\JLCIPWatch\Logs\watchdog-*.log -Tail 40
```

Regular diagnostics use real read only network probes. `SendTestEmail` sends a real email. `CheckSystemCredential` starts a dedicated SYSTEM task that decrypts the blob and writes only a timestamp, identity confirmation, and pass/fail. The result is in `credential-check.json`. An old result is not current proof. A test message accepted by SMTP confirms authentication for that test but needs inbox verification.

Central configuration is editable without changing engine logic. The app saves the interval as 60 minutes. If editing `IntervalMinutes` manually, rerun the script installer or use the GUI to update the scheduled task. Other config edits take effect on the next cycle. Keep at least three failed checks, no more than two reboots per day, and at least a 30 minute reboot cooldown. Invalid settings stop a cycle and remain an operator issue until corrected.

## Remove

Use the app Uninstall button, Windows Installed Apps, or an elevated PowerShell window:

```powershell
& 'C:\ProgramData\JLCIPWatch\App\Uninstall-JLCIPWatch.ps1'
# Or remove logs too:
& 'C:\ProgramData\JLCIPWatch\App\Uninstall-JLCIPWatch.ps1' -RemoveLogs
```

Removal stops and unregisters only the two named watchdog tasks, restores a recorded disabled adapter, removes its credential and application files, and preserves logs by default. Installation and removal use fixed application paths and reject reparse points. They do not rewrite unrelated network configuration. Setup can be rerun to repair or update an installation.

## Validation boundaries

See `VALIDATION.md` for tests actually performed. Safe source tests do not establish unattended SYSTEM execution, real email delivery, DHCP behavior, adapter recovery, installation on a clean PC, or actual reboot behavior. Validate those on a spare Windows PC with local access before unattended deployment. Do not test adapter interruption or reboots on a remote only production machine.
