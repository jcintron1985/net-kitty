#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
if (-not $SkipTests) { & (Join-Path $PSScriptRoot 'Tests\Run-Tests.ps1') }
$out = Join-Path $PSScriptRoot 'dist'
if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('JLCIPWatch-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
 <assemblyIdentity version="1.0.2.0" name="JLC.IPWatchdog"/>
 <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false"/></requestedPrivileges></security></trustInfo>
 <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application><supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/></application></compatibility>
</assembly>
'@
$launcher = @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Windows.Forms;
[assembly: AssemblyTitle("Net Kitty")]
[assembly: AssemblyVersion("1.0.2.0")]
static class Launcher {
 [STAThread] static int Main(string[] args) {
  string stage = null;
  try {
   string folder = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
   Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip");
   if (payload != null) {
    string parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "JLCIPWatch-Setup");
    SecureDirectory(parent);
    stage = Path.Combine(parent, Guid.NewGuid().ToString("N")); SecureDirectory(stage);
    using (payload) using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read)) {
     foreach (ZipArchiveEntry entry in archive.Entries) {
      string target = Path.GetFullPath(Path.Combine(stage, entry.FullName));
      if (!target.StartsWith(stage + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe installer path.");
      if (String.IsNullOrEmpty(entry.Name)) { SecureDirectory(target); continue; }
      Directory.CreateDirectory(Path.GetDirectoryName(target)); entry.ExtractToFile(target);
     }
    }
    folder = stage;
   }
   string script = Path.Combine(folder,"JLCIPWatch.UI.ps1");
   if (!File.Exists(script)) throw new Exception("Application files are missing. Run NetKitty-Setup-1.0.2.exe again.");
   string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
   string action = Array.IndexOf(args,"--uninstall") >= 0 ? " -Uninstall" : "";
   ProcessStartInfo info = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"" + action);
   info.UseShellExecute = false; info.CreateNoWindow = true; info.WorkingDirectory = folder;
   using (Process child = Process.Start(info)) { if (stage != null) { child.WaitForExit(); return child.ExitCode; } }
   return 0;
  } catch (Exception ex) { MessageBox.Show(ex.Message,"Net Kitty",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
  finally { if (stage != null) { try { Directory.Delete(stage,true); } catch {} } }
 }
 static void SecureDirectory(string path) {
  if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new Exception("Installer directory cannot be a link.");
  DirectorySecurity acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true,false);
  foreach (string id in new string[]{"S-1-5-18","S-1-5-32-544"}) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(id),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
  acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
  Directory.CreateDirectory(path,acl); Directory.SetAccessControl(path,acl);
 }
}
'@
try {
    Set-Content -LiteralPath (Join-Path $stage 'app.manifest') -Value $manifest -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stage 'Launcher.cs') -Value $launcher -Encoding UTF8
    $payload = Join-Path $stage 'payload'; New-Item -ItemType Directory -Path $payload | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Assets') -Destination $payload -Recurse
    $files = @('JLCIPWatch.ps1','JLCIPWatch.Core.psm1','JLCIPWatch.UI.ps1','Install-JLCIPWatch.ps1','Uninstall-JLCIPWatch.ps1','Test-JLCIPWatch.ps1','config.json','README.md','VALIDATION.md','Build.ps1')
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $payload }
    $args = @('/nologo','/target:winexe','/platform:anycpu',('/win32icon:' + (Join-Path $PSScriptRoot 'Assets\NetKitty.ico')),('/win32manifest:' + (Join-Path $stage 'app.manifest')),'/reference:System.Windows.Forms.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',('/out:' + (Join-Path $payload 'NetKitty.exe')),(Join-Path $stage 'Launcher.cs'))
    & $compiler @args
    if ($LASTEXITCODE -ne 0) { throw 'Application launcher compilation failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Tests') -Destination $payload -Recurse
    Compress-Archive -Path (Join-Path $payload '*') -DestinationPath (Join-Path $stage 'payload.zip') -CompressionLevel Optimal
    $args = @('/nologo','/target:winexe','/platform:anycpu',('/win32icon:' + (Join-Path $PSScriptRoot 'Assets\NetKitty.ico')),('/win32manifest:' + (Join-Path $stage 'app.manifest')),'/reference:System.Windows.Forms.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',('/resource:' + (Join-Path $stage 'payload.zip') + ',payload.zip'),('/out:' + (Join-Path $out 'NetKitty-Setup-1.0.2.exe')),(Join-Path $stage 'Launcher.cs'))
    & $compiler @args
    if ($LASTEXITCODE -ne 0) { throw 'Setup compilation failed.' }
    Copy-Item -LiteralPath (Join-Path $stage 'payload.zip') -Destination (Join-Path $out 'NetKitty-Source.zip') -Force
    Get-FileHash -LiteralPath (Join-Path $out 'NetKitty-Setup-1.0.2.exe'),(Join-Path $out 'NetKitty-Source.zip') -Algorithm SHA256 | ForEach-Object { '{0}  {1}' -f $_.Hash,[IO.Path]::GetFileName($_.Path) } | Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII
    Write-Output "Built $(Join-Path $out 'NetKitty-Setup-1.0.2.exe')"
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'JLCIPWatch-build-*') { throw 'Unexpected build cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
