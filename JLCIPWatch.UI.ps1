#requires -Version 5.1
[CmdletBinding()]
param([string]$PreviewPath, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
trap {
    if (-not $PreviewPath) { [Windows.Forms.MessageBox]::Show(('Net Kitty could not complete this action. ' + $_.Exception.Message),'Net Kitty needs attention','OK','Error') | Out-Null }
    exit 1
}
Import-Module (Join-Path $PSScriptRoot 'JLCIPWatch.Core.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$root = Join-Path $env:ProgramData 'JLCIPWatch'
$installed = Test-Path -LiteralPath (Join-Path $root 'config.json')
$configPath = if ($installed) { Join-Path $root 'config.json' } else { Join-Path $PSScriptRoot 'config.json' }
$script:uiConfig = Read-JLCJson $configPath
$form = [Windows.Forms.Form]::new()
$form.Text = 'Net Kitty 1.0.2'; $form.ClientSize = [Drawing.Size]::new(780,740)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(245,247,250)
$iconPath = Join-Path $PSScriptRoot 'Assets\NetKitty.ico'
if (Test-Path -LiteralPath $iconPath) { $form.Icon = [Drawing.Icon]::new($iconPath) }
function Enable-UIClipboard([Windows.Forms.TextBoxBase]$Control) {
    $Control.ShortcutsEnabled = $true
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $cut = $menu.Items.Add('Cut'); $copy = $menu.Items.Add('Copy'); $paste = $menu.Items.Add('Paste')
    $null = $menu.Items.Add([Windows.Forms.ToolStripSeparator]::new()); $all = $menu.Items.Add('Select all')
    # Windows disables native copy for masked text boxes. These explicit user actions also support passwords.
    $copy.Add_Click({ if ($Control.SelectionLength) { [Windows.Forms.Clipboard]::SetText($Control.SelectedText) } }.GetNewClosure())
    $cut.Add_Click({ if (-not $Control.ReadOnly -and $Control.SelectionLength) { [Windows.Forms.Clipboard]::SetText($Control.SelectedText); $Control.SelectedText = '' } }.GetNewClosure())
    $paste.Add_Click({ if (-not $Control.ReadOnly -and [Windows.Forms.Clipboard]::ContainsText()) { $Control.SelectedText = [Windows.Forms.Clipboard]::GetText() } }.GetNewClosure())
    $all.Add_Click({ $Control.SelectAll() }.GetNewClosure())
    $menu.Add_Opening({
        $copy.Enabled = $Control.SelectionLength -gt 0
        $cut.Enabled = -not $Control.ReadOnly -and $Control.SelectionLength -gt 0
        try { $paste.Enabled = -not $Control.ReadOnly -and [Windows.Forms.Clipboard]::ContainsText() } catch { $paste.Enabled = $false }
    }.GetNewClosure())
    $Control.ContextMenuStrip = $menu
    $Control.Add_KeyDown({
        param($senderControl,$key)
        $action = ''
        if ($key.Control -and -not $key.Alt) {
            switch ($key.KeyCode) { 'A' { $action = 'all' }; 'C' { $action = 'copy' }; 'X' { $action = 'cut' }; 'V' { $action = 'paste' }; 'Insert' { $action = 'copy' } }
        } elseif ($key.Shift -and $key.KeyCode -eq 'Insert') { $action = 'paste' }
        if (-not $action) { return }
        $key.Handled = $true; $key.SuppressKeyPress = $true
        try {
            switch ($action) {
                'all' { $Control.SelectAll() }
                'copy' { if ($Control.SelectionLength) { [Windows.Forms.Clipboard]::SetText($Control.SelectedText) } }
                'cut' { if (-not $Control.ReadOnly -and $Control.SelectionLength) { [Windows.Forms.Clipboard]::SetText($Control.SelectedText); $Control.SelectedText = '' } }
                'paste' { if (-not $Control.ReadOnly -and [Windows.Forms.Clipboard]::ContainsText()) { $Control.SelectedText = [Windows.Forms.Clipboard]::GetText() } }
            }
        } catch { [Windows.Forms.MessageBox]::Show('The clipboard is busy. Please try again.','Clipboard') | Out-Null }
    }.GetNewClosure())
}
function New-UIEyeImage([bool]$Hide) {
    $image = [Drawing.Bitmap]::new(24,20)
    $graphics = [Drawing.Graphics]::FromImage($image); $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(35,65,95),1.8)
    $brush = [Drawing.SolidBrush]::new($pen.Color)
    try {
        $graphics.SmoothingMode = 'AntiAlias'; $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.DrawEllipse($pen,2,5,20,10); $graphics.FillEllipse($brush,9,7,6,6)
        if ($Hide) { $graphics.DrawLine($pen,3,18,21,2) }
    } finally { $graphics.Dispose(); $pen.Dispose(); $brush.Dispose() }
    return $image
}
function Add-UILabel([string]$Text, [int]$X, [int]$Y, [int]$Width = 700, [int]$Height = 26) {
    $label = [Windows.Forms.Label]::new(); $label.Text = $Text; $label.SetBounds($X,$Y,$Width,$Height); $form.Controls.Add($label); return $label
}
function Add-UIInput([string]$Caption, [int]$Y, [string]$Value, [int]$Width = 485) {
    $null = Add-UILabel $Caption 30 $Y 215
    $box = [Windows.Forms.TextBox]::new(); $box.SetBounds(250,$Y - 2,$Width,28); $box.Text = $Value; Enable-UIClipboard $box; $form.Controls.Add($box); return $box
}
function Add-UIButton([string]$Caption, [int]$X, [int]$Y, [int]$Width = 165) {
    $button = [Windows.Forms.Button]::new(); $button.Text = $Caption; $button.SetBounds($X,$Y,$Width,36); $button.FlatStyle = 'System'; $form.Controls.Add($button); return $button
}
$title = Add-UILabel 'Your connection, watched over.' 95 23 645 40
$title.Font = [Drawing.Font]::new('Segoe UI',20,[Drawing.FontStyle]::Bold)
$art = $null
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Assets\NetKitty.png')) {
    $art = [Windows.Forms.PictureBox]::new(); $art.SetBounds(30,18,52,52); $art.SizeMode = 'Zoom'
    $original = [Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'Assets\NetKitty.png'))
    try { $art.Image = [Drawing.Bitmap]::new($original) } finally { $original.Dispose() }
    $form.Controls.Add($art)
}
$null = Add-UILabel 'Starts with Windows. Checks once per hour. Runs without anyone signing in.' 32 73 720 26
$null = Add-UILabel 'EMAIL ACCOUNT' 30 118 700 25
$provider = [Windows.Forms.ComboBox]::new(); $provider.DropDownStyle = 'DropDownList'; $provider.Items.AddRange(@('Gmail','Custom SMTP with STARTTLS')); $provider.SetBounds(250,114,485,30); $form.Controls.Add($provider)
function Invoke-UIProviderClipboard([switch]$Paste) {
    try {
        if ($Paste) {
            if (-not [Windows.Forms.Clipboard]::ContainsText()) { return }
            $match = $provider.FindStringExact([Windows.Forms.Clipboard]::GetText().Trim())
            if ($match -ge 0) { $provider.SelectedIndex = $match } else { Set-UIStatus 'For Email account, paste Gmail or Custom SMTP with STARTTLS.' }
        } else { [Windows.Forms.Clipboard]::SetText([string]$provider.SelectedItem) }
    } catch { Set-UIStatus 'The clipboard is busy. Please try again.' }
}
$providerMenu = [Windows.Forms.ContextMenuStrip]::new()
$providerCopy = $providerMenu.Items.Add('Copy'); $providerPaste = $providerMenu.Items.Add('Paste')
$providerCopy.Add_Click({ Invoke-UIProviderClipboard }); $providerPaste.Add_Click({ Invoke-UIProviderClipboard -Paste }); $provider.ContextMenuStrip = $providerMenu
$provider.Add_KeyDown({ param($senderControl,$key)
    if ($key.Control -and $key.KeyCode -in @('C','Insert')) { Invoke-UIProviderClipboard; $key.Handled = $true; $key.SuppressKeyPress = $true }
    elseif (($key.Control -and $key.KeyCode -eq 'V') -or ($key.Shift -and $key.KeyCode -eq 'Insert')) { Invoke-UIProviderClipboard -Paste; $key.Handled = $true; $key.SuppressKeyPress = $true }
})
$sender = Add-UIInput 'Sending email address' 164 $script:uiConfig.SenderEmail
$recipient = Add-UIInput 'Send alerts to' 207 $script:uiConfig.RecipientEmail
$username = Add-UIInput 'SMTP username' 250 $script:uiConfig.SmtpUsername
$password = Add-UIInput 'App Password' 293 '' 380; $password.UseSystemPasswordChar = $true
$eye = [Windows.Forms.CheckBox]::new(); $eye.Appearance = 'Button'; $eye.SetBounds(641,289,94,30)
$eye.Text = 'Show'; $eye.Image = New-UIEyeImage $false; $eye.ImageAlign = 'MiddleLeft'; $eye.TextAlign = 'MiddleRight'; $eye.AccessibleName = 'Show password'
$eye.Add_CheckedChanged({
    $start = $password.SelectionStart; $length = $password.SelectionLength
    $password.UseSystemPasswordChar = -not $eye.Checked; $password.Select($start,$length)
    $eye.Text = if ($eye.Checked) { 'Hide' } else { 'Show' }
    $eye.AccessibleName = if ($eye.Checked) { 'Hide password' } else { 'Show password' }
    $previousImage = $eye.Image; $eye.Image = New-UIEyeImage $eye.Checked; $previousImage.Dispose()
})
$form.Controls.Add($eye)
$hint = Add-UILabel 'Gmail: use a Google App Password. Leave blank to keep an installed password.' 250 324 490 39
$hint.Font = [Drawing.Font]::new('Segoe UI',9)
$smtp = Add-UIInput 'SMTP server' 374 $script:uiConfig.SmtpHost 345
$port = [Windows.Forms.NumericUpDown]::new(); $port.SetBounds(615,372,120,28); $port.Minimum = 1; $port.Maximum = 65535; $port.Value = $script:uiConfig.SmtpPort; $form.Controls.Add($port)
foreach ($edit in $port.Controls | Where-Object { $_ -is [Windows.Forms.TextBoxBase] }) { Enable-UIClipboard $edit }
$null = Add-UILabel 'Automatic email: internet outage followed by reconnection, or a public IP change.' 30 416 705 35
$checks = @{}
foreach ($spec in @(@('EnableInternetReset','Refresh DNS and DHCP',30),@('EnableAdapterRestart','Restart network adapter',270),@('EnableReboot','Allow protected PC restart',510))) {
    $check = [Windows.Forms.CheckBox]::new(); $check.Text = $spec[1]; $check.SetBounds([int]$spec[2],460,240,28); $check.Checked = [bool]$script:uiConfig[$spec[0]]; $form.Controls.Add($check); $checks[$spec[0]] = $check
}
$null = Add-UILabel 'Recovery after 3 failed checks. Up to 3 tries per step. Adapter restart interrupts access.' 30 501 725 24
$null = Add-UILabel 'PC restarts: at most 2 per 24 hours. First install or damaged state adds a 24 hour hold.' 30 527 720 24
$save = Add-UIButton $(if ($installed) { 'Save settings' } else { 'Install and start' }) 30 572 175
$test = Add-UIButton 'Send test email' 218 572 163
$help = Add-UIButton 'Get App Password' 394 572 163
$logs = Add-UIButton 'Open logs' 570 572 165
$refresh = Add-UIButton 'Refresh status' 30 620 175
$diagnostics = Add-UIButton 'Diagnostics' 218 620 163
$emailPreviews = Add-UIButton 'Email previews' 394 620 163
$remove = Add-UIButton 'Uninstall' 570 620 165
$status = Add-UILabel '' 30 678 710 52; $status.ForeColor = [Drawing.Color]::FromArgb(40,65,95)
function Set-UIStatus([string]$Text) { $status.Text = $Text; $form.Refresh(); [Windows.Forms.Application]::DoEvents() }
function Get-UIConfig {
    $value = ConvertTo-JLCMap ($script:uiConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $value.SenderEmail = $sender.Text.Trim(); $value.RecipientEmail = $recipient.Text.Trim()
    $value.SmtpUsername = $username.Text.Trim(); if (-not $value.SmtpUsername) { $value.SmtpUsername = $value.SenderEmail }
    $value.SmtpHost = $smtp.Text.Trim(); $value.SmtpPort = [int]$port.Value
    $value.IntervalMinutes = 60
    foreach ($key in $checks.Keys) { $value[$key] = $checks[$key].Checked }
    Assert-JLCConfig $value
    return $value
}
function Get-UISecret {
    return ConvertTo-JLCEmailSecret $password.Text -Gmail:($provider.SelectedIndex -eq 0)
}
function Update-UIStatus {
    $task = Get-ScheduledTask -TaskName 'Net Kitty' -ErrorAction SilentlyContinue
    if ($null -eq $task) { Set-UIStatus 'Ready to install. Enter your email details above.'; return }
    $state = Read-JLCState (Join-Path $root 'state.json')
    $info = Get-ScheduledTaskInfo -TaskName 'Net Kitty'
    $last = if ($state.LastCycleUtc) { ([datetime]$state.LastCycleUtc).ToLocalTime().ToString('g') } else { 'waiting for first check' }
    Set-UIStatus ("Task: {0}. Last check: {1}. Next: {2}. Pending emails: {3}." -f $task.State,$last,$info.NextRunTime.ToString('g'),$state.Pending.Count)
}
$provider.Add_SelectedIndexChanged({ if ($provider.SelectedIndex -eq 0) { $smtp.Text = 'smtp.gmail.com'; $port.Value = 587 } })
$provider.SelectedIndex = $(if ($script:uiConfig.SmtpHost -eq 'smtp.gmail.com') { 0 } else { 1 })
$sender.Add_Leave({ if ($provider.SelectedIndex -eq 0 -or -not $username.Text) { $username.Text = $sender.Text.Trim() } })
$save.Add_Click({
    $save.Enabled = $false; $test.Enabled = $false
    try {
        $cfg = Get-UIConfig; $secret = Get-UISecret
        if ($null -eq $secret -and -not (Test-Path -LiteralPath (Join-Path $root 'smtp.credential'))) { throw 'Enter an App Password before installing.' }
        if ($installed -and $null -eq $secret -and ($cfg.SmtpUsername -ne $script:uiConfig.SmtpUsername -or $cfg.SmtpHost -ne $script:uiConfig.SmtpHost)) { throw 'Enter the new account password when changing the sending account or server.' }
        Set-UIStatus 'Installing and registering background monitoring...'
        $null = & (Join-Path $PSScriptRoot 'Install-JLCIPWatch.ps1') -Configuration $cfg -EmailSecret $secret
        $script:uiConfig = $cfg; $script:installed = $true; $password.Clear(); $eye.Checked = $false; $save.Text = 'Save settings'
        Set-UIStatus 'Installed. Monitoring starts now, at Windows startup, and once per hour. Use Send test email to verify delivery.'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Setup needs attention','OK','Error') | Out-Null; Set-UIStatus 'Setup did not complete. Correct the displayed issue and try again.' }
    finally { $save.Enabled = $true; $test.Enabled = $true }
})
$test.Add_Click({
    $test.Enabled = $false; $save.Enabled = $false
    $stage = 'Validate'
    try {
        $cfg = Get-UIConfig; $secret = Get-UISecret
        if ($null -eq $secret -and -not (Test-Path -LiteralPath (Join-Path $root 'smtp.credential'))) { throw 'Enter your App Password first. You can test before installation.' }
        if ($null -eq $secret -and ($cfg.SmtpUsername -ne $script:uiConfig.SmtpUsername -or $cfg.SmtpHost -ne $script:uiConfig.SmtpHost)) { throw 'Enter the password for the new sending account.' }
        Set-UIStatus 'Sending a test email. This may take up to 20 seconds...'
        $stage = 'Send'
        Send-JLCMail $cfg (Join-Path $root 'smtp.credential') @{ Subject = 'Email setup test'; Body = "Email notifications were tested from $env:COMPUTERNAME at $([datetime]::UtcNow.ToString('o'))."; Id = [guid]::NewGuid().ToString() } -Secret $secret
        Set-UIStatus 'Your SMTP server accepted the test email. Check the recipient inbox and spam folder.'
    } catch {
        $reason = if ($stage -eq 'Send') { Get-JLCEmailFailure $_ } else { $_.Exception.Message }
        Set-UIStatus 'Test email failed. The error dialog explains what needs attention.'
        [Windows.Forms.MessageBox]::Show($reason,'Email test needs attention','OK','Error') | Out-Null
    }
    finally { $test.Enabled = $true; $save.Enabled = $true }
})
$help.Add_Click({ Start-Process 'https://myaccount.google.com/apppasswords' })
$emailPreviews.Add_Click({ Show-UIEmailPreviews })
function Show-UIEmailPreviews([string]$PreviewPath) {
    $dialog = [Windows.Forms.Form]::new(); $dialog.Text = 'Net Kitty email previews'; $dialog.Icon = $form.Icon; $dialog.ClientSize = [Drawing.Size]::new(700,440); $dialog.StartPosition = 'CenterParent'; $dialog.Font = $form.Font
    $tabs = [Windows.Forms.TabControl]::new(); $tabs.SetBounds(16,16,668,355)
    $sampleTime = [datetime]::Parse('2026-10-16T14:30:00Z').ToUniversalTime()
    foreach ($kind in @('Reconnected','PublicIPChanged')) {
        $template = Get-JLCEmailTemplate -Kind $kind -PreviousIP '203.0.113.10' -NewIP '203.0.113.25' -OutageStartedUtc '2026-10-16T13:30:00Z'
        $page = [Windows.Forms.TabPage]::new(); $page.Text = if ($kind -eq 'Reconnected') { 'Connection restored' } else { 'Public IP changed' }
        $body = Format-JLCNotificationBody -Body $template.Body -Now $sampleTime -ComputerName 'OFFICE-PC'
        $text = [Windows.Forms.TextBox]::new(); $text.Multiline = $true; $text.ReadOnly = $true; $text.ScrollBars = 'Vertical'; $text.Dock = 'Fill'; $text.BackColor = [Drawing.Color]::White; $text.Font = [Drawing.Font]::new('Consolas',10)
        $text.Text = "Subject: [Net Kitty] $($template.Subject)`r`n`r`n$body`r`nNotification ID: example-preview"
        Enable-UIClipboard $text; $page.Controls.Add($text); $tabs.TabPages.Add($page)
    }
    $dialog.Controls.Add($tabs)
    $note = [Windows.Forms.Label]::new(); $note.Text = 'Example details. Previewing does not send email.'; $note.SetBounds(20,390,460,28); $dialog.Controls.Add($note)
    $copy = [Windows.Forms.Button]::new(); $copy.Text = 'Copy template'; $copy.SetBounds(530,385,150,34)
    $copy.Add_Click({ [Windows.Forms.Clipboard]::SetText($tabs.SelectedTab.Controls[0].Text) }.GetNewClosure()); $dialog.Controls.Add($copy)
    if ($PreviewPath) {
        $dialog.Show(); $dialog.Refresh(); $bitmap = [Drawing.Bitmap]::new($dialog.Width,$dialog.Height)
        try { $dialog.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$dialog.Width,$dialog.Height)); $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose(); $dialog.Close(); $dialog.Dispose() }
    } else { $null = $dialog.ShowDialog($form); $dialog.Dispose() }
}
$logs.Add_Click({ if (Test-Path -LiteralPath (Join-Path $root 'Logs')) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $root 'Logs')) } else { Set-UIStatus 'Logs will be available after installation.' } })
$refresh.Add_Click({ try { Update-UIStatus } catch { Set-UIStatus 'Status could not be loaded. Check the installation and logs.' } })
$diagnostics.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $root 'config.json'))) { throw 'Install first to run diagnostics.' }
        Set-UIStatus 'Running read only connectivity and SYSTEM credential diagnostics...'
        $report = & (Join-Path $PSScriptRoot 'Test-JLCIPWatch.ps1') -CheckSystemCredential | Out-String
        $dialog = [Windows.Forms.Form]::new(); $dialog.Text = 'Net Kitty diagnostics'; $dialog.Size = [Drawing.Size]::new(720,600); $dialog.StartPosition = 'CenterParent'
        $output = [Windows.Forms.TextBox]::new(); $output.Multiline = $true; $output.ReadOnly = $true; $output.ScrollBars = 'Both'; $output.Dock = 'Fill'; $output.Font = [Drawing.Font]::new('Consolas',10); $output.Text = $report; $dialog.Controls.Add($output); $null = $dialog.ShowDialog($form); $dialog.Dispose(); Update-UIStatus
    } catch { Set-UIStatus $_.Exception.Message }
})
$remove.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('Remove Net Kitty and its email credential? Logs will be kept.','Uninstall','YesNo','Question') -eq 'Yes') {
        try { $null = & (Join-Path $PSScriptRoot 'Uninstall-JLCIPWatch.ps1'); [Windows.Forms.MessageBox]::Show('Net Kitty was removed. Logs were kept.','Uninstalled') | Out-Null; $form.Close() }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Removal needs attention') | Out-Null }
    }
})
if ($PreviewPath) {
    $status.Text = 'Ready to install. Enter your email details above.'
    $form.CreateControl(); $form.Show(); $form.Refresh()
    $bitmap = [Drawing.Bitmap]::new($form.Width,$form.Height)
    try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose(); $form.Close(); $form.Dispose() }
    return
}
$form.Add_Shown({ if ($Uninstall) { $remove.PerformClick(); return }; try { Update-UIStatus } catch { Set-UIStatus 'Ready. Enter your email details to configure monitoring.' } })
$null = $form.ShowDialog()
$password.Clear(); $form.Dispose()
