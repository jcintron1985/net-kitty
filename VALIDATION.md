# Net Kitty validation

Validation date: October 16, 2026. Platform: Windows with native Windows PowerShell 5.1.19041.6456.

## Confirmed

All 42 safe automated tests passed for version 1.0.2. These include preinstallation email with a mocked SMTP client, secure credential handoff without a stored credential file, helpful field validation, and error classification without echoing passwords. The C# application and installer compiled successfully. The setup executable's embedded ZIP matched the separate source ZIP by SHA256, and packaged source files matched the workspace source.

The safe automated suite exercises monitoring decisions, three attempts per recovery stage, recovery ordering and retesting, outage reconnection, public IP changes, failed IP lookup retention, SMTP retry and batching, the restricted email policy, reboot reservation persistence, rolling reboot limits, cooldowns, interrupted adapter recovery, failed persistence, corrupt state fallback, atomic replacement, DHCP scoping with mocks, physical adapter selection with mocks, and log rotation.

The actual Windows ScheduledTasks cmdlets construct the task definition without registering it. Its SYSTEM service account, startup trigger, hourly trigger, overlap prevention, and twenty minute job timeout are checked.

Windows DPAPI LocalMachine encryption and decryption were exercised with a synthetic credential in a temporary directory. The plaintext was absent from the encrypted bytes.

The complete engine also ran with real DNS, HTTPS, gateway, adapter, and public IPv4 probes in an isolated temporary application root. Recovery, email, and reboot were explicitly disabled. The cycle completed, connectivity was online, and the public IPv4 was valid. The temporary root was removed.

The WinForms window was rendered and visually inspected. The generated tuxedo cat PNG has genuine transparency. The Windows ICO contains nine sizes from 16 to 256 pixels. The compiler embeds the icon in both application and setup launchers.

Version 1.0.2 UI verification used synthetic text to exercise masked password copy, keyboard paste, and the eye control. Showing and hiding preserved the password contents. Email fields, SMTP server, and port had clipboard editing enabled. The email preview dialog was rendered and visually inspected. The system clipboard was restored after verification. No real email credential was used for these UI checks, and no email was sent.

## Still requires deployment testing

The app has not been installed on this development computer. No watchdog task was registered, no real network adapter was disabled, no DHCP lease was changed, and no reboot was requested during testing.

Unattended SYSTEM execution, credential decryption specifically inside SYSTEM, installation and removal on clean Windows 10 and Windows 11, real DHCP and adapter recovery, interruption recovery after a task kill, actual reboot protection across Windows restarts, and corporate proxy or VPN environments still need validation on a spare PC with local access.

Real Gmail connection testing established a TCP connection and a validated TLS 1.2 session. Two SmtpClient attempts with the explicitly authorized account credential failed with a closed transport connection. A final direct SMTP authentication diagnostic received Gmail response 535 with enhanced code 5.7.8. Authentication failed, and no test message was accepted. No further account authentication attempts were made. The supplied credential was read through a masked prompt and was not stored in project files. Successful Gmail delivery still needs a valid Google App Password entered locally in the app and verification of the recipient inbox.

The executable is unsigned. This is a built and safely tested application package, not a claim of production deployment validation.
