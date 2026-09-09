#requires -Version 5.1

[CmdletBinding()]
param([switch]$DiagnoseCleanup, [string]$ScreenshotDirectory, [switch]$Persistent)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this interactive browser smoke test in Windows PowerShell 5.1 with -STA.' }
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
if ($DiagnoseCleanup) {
    $script:FreshSessionSourceFactory = ${function:Get-EeaSessionLauncherSource}
    function Get-EeaSessionLauncherSource {
        param($Website, $EdgePath, $AppName, [bool]$FreshSession = $true, [string]$LaunchMode = 'Maximized', [bool]$AlwaysOnTop = $false)
        $generatedSource = & $script:FreshSessionSourceFactory -Website $Website -EdgePath $EdgePath -AppName $AppName -FreshSession $FreshSession -LaunchMode $LaunchMode -AlwaysOnTop $AlwaysOnTop
        foreach ($exceptionType in @('IOException', 'UnauthorizedAccessException', 'InvalidOperationException')) {
            $generatedSource = $generatedSource.Replace(('catch (' + $exceptionType + ') { return false; }'), ('catch (' + $exceptionType + ' failure) { File.WriteAllText(Path.Combine(root, "cleanup-error.txt"), failure.ToString()); return false; }'))
        }
        return $generatedSource
    }
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -ReferencedAssemblies System, System.Core, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class FreshSessionHttpProbe : IDisposable
{
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    private readonly ConcurrentQueue<string> reports = new ConcurrentQueue<string>();
    private readonly AutoResetEvent reported = new AutoResetEvent(false);
    private readonly Thread worker;
    private volatile bool stopped;
    private int cacheRequests;
    public string Origin { get; private set; }
    public FreshSessionHttpProbe()
    {
        listener.Start();
        Origin = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Serve);
        worker.IsBackground = true;
        worker.Start();
    }
    private void Serve()
    {
        while (!stopped)
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                {
                    client.ReceiveTimeout = 5000;
                    using (NetworkStream stream = client.GetStream())
                    using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true))
                    {
                        string request = reader.ReadLine();
                        if (String.IsNullOrEmpty(request)) continue;
                        int length = 0;
                        string header;
                        while (!String.IsNullOrEmpty(header = reader.ReadLine()))
                            if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(header.Substring(15).Trim());
                        string body = "";
                        string contentType = "text/plain";
                        string cache = "no-store";
                        if (request.StartsWith("POST /report ", StringComparison.Ordinal))
                        {
                            char[] data = new char[Math.Min(length, 8192)];
                            int offset = 0;
                            while (offset < data.Length)
                            {
                                int count = reader.Read(data, offset, data.Length - offset);
                                if (count == 0) throw new EndOfStreamException();
                                offset += count;
                            }
                            reports.Enqueue(new string(data));
                            reported.Set();
                            body = "ok";
                        }
                        else if (request.StartsWith("GET /cache ", StringComparison.Ordinal))
                        {
                            body = "cache-" + (++cacheRequests);
                            cache = "public, max-age=3600";
                        }
                        else if (request.StartsWith("GET /app", StringComparison.Ordinal))
                        {
                            contentType = "text/html";
                            body = "<!doctype html><title>Easy Edge Apps fresh-session test</title><h1>Synthetic fresh-session test</h1><script>(async()=>{const before={cookie:document.cookie,storage:localStorage.getItem('eeaProbe')};document.cookie='eeaProbe=synthetic; Max-Age=3600; Path=/; SameSite=Lax';localStorage.setItem('eeaProbe','synthetic');const cache=await(await fetch('/cache')).text();await fetch('/report',{method:'POST',body:JSON.stringify({before,cache})});document.body.append('Fixture reported.');})()</script>";
                        }
                        byte[] bytes = Encoding.UTF8.GetBytes(body);
                        byte[] headers = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: " + contentType + "; charset=utf-8\r\nCache-Control: " + cache + "\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
                        stream.Write(headers, 0, headers.Length);
                        stream.Write(bytes, 0, bytes.Length);
                    }
                }
            }
            catch { if (stopped) return; }
        }
    }
    public string WaitForReport()
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(25);
        string report;
        while (!reports.TryDequeue(out report))
        {
            TimeSpan remaining = deadline - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero || !reported.WaitOne(remaining)) throw new TimeoutException("The owned Edge test window did not report its local storage state.");
        }
        return report;
    }
    private delegate bool WindowCallback(IntPtr window, IntPtr state);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out WindowRectangle rectangle);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr word, IntPtr data, uint flags, uint timeout, out UIntPtr result);
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRectangle { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length, IntPtr returned);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    public static string DescribeJob(string directory)
    {
        IntPtr job = OpenJobObject(4, false, "Local\\EasyEdgeApps-Fresh-" + Path.GetFileName(directory));
        if (job == IntPtr.Zero) return "No queryable session job; Win32 error " + Marshal.GetLastWin32Error();
        IntPtr information = Marshal.AllocHGlobal(65536);
        try
        {
            if (!QueryInformationJobObject(job, 3, information, 65536, IntPtr.Zero)) return "Job query failed: " + Marshal.GetLastWin32Error();
            int count = Marshal.ReadInt32(information, 4);
            StringBuilder description = new StringBuilder("Owned job processes: " + count);
            for (int index = 0; index < count; index++)
            {
                int processId = Marshal.ReadIntPtr(information, 8 + index * IntPtr.Size).ToInt32();
                try
                {
                    using (System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(processId))
                        description.Append("; " + processId + " " + process.ProcessName);
                }
                catch (ArgumentException) { description.Append("; exited " + processId); }
            }
            return description.ToString();
        }
        finally { Marshal.FreeHGlobal(information); CloseHandle(job); }
    }
    public static IntPtr FindTestWindow(int process)
    {
        IntPtr found = IntPtr.Zero;
        int count = 0;
        EnumWindows(delegate(IntPtr window, IntPtr state)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)process) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf("Easy Edge Apps fresh-session test", StringComparison.Ordinal) < 0) return true;
            found = window;
            count++;
            return true;
        }, IntPtr.Zero);
        if (count > 1) throw new InvalidOperationException("More than one owned test window was found.");
        return found;
    }
    public static void ActivateTestWindow(int process)
    {
        IntPtr window = FindTestWindow(process);
        if (window == IntPtr.Zero) throw new InvalidOperationException("The owned test window is unavailable.");
        if (GetForegroundWindow() != window) SetForegroundWindow(window);
        if (GetForegroundWindow() != window) throw new InvalidOperationException("The test window could not receive foreground focus.");
        DwmFlush();
    }
    public static void CaptureTestWindow(int process, string path)
    {
        IntPtr window = FindTestWindow(process);
        WindowRectangle rectangle;
        if (window == IntPtr.Zero || !GetWindowRect(window, out rectangle)) throw new InvalidOperationException("The owned test window is unavailable.");
        if (GetForegroundWindow() != window) SetForegroundWindow(window);
        if (GetForegroundWindow() != window) throw new InvalidOperationException("The test window is not foreground; no screen content was captured.");
        DwmFlush();
        using (Bitmap image = new Bitmap(rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top))
        using (Graphics graphics = Graphics.FromImage(image))
        {
            graphics.CopyFromScreen(rectangle.Left, rectangle.Top, 0, 0, image.Size, CopyPixelOperation.SourceCopy);
            System.Collections.Generic.HashSet<int> colors = new System.Collections.Generic.HashSet<int>();
            for (int pixelY = 45; pixelY < Math.Min(300, image.Height); pixelY += 2)
                for (int pixelX = 15; pixelX < Math.Min(700, image.Width); pixelX += 2)
                    colors.Add(image.GetPixel(pixelX, pixelY).ToArgb());
            if (colors.Count < 16) throw new InvalidOperationException("The browser content capture is blank.");
            image.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
    public static int CloseTestWindows(int process)
    {
        IntPtr window = FindTestWindow(process);
        if (window == IntPtr.Zero) return 0;
        UIntPtr result;
        return SendMessageTimeout(window, 16, IntPtr.Zero, IntPtr.Zero, 2, 3000, out result) != IntPtr.Zero ? 1 : 0;
    }
    public void Dispose()
    {
        stopped = true;
        listener.Stop();
        worker.Join(6000);
        reported.Dispose();
    }
}
'@

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.NativeSessionSmoke.' + [Guid]::NewGuid().ToString('N'))
$sessions = New-Object 'Collections.Generic.List[object]'
$server = New-Object FreshSessionHttpProbe
$taskbarType = Initialize-EeaTaskbarTypes

function Assert-FreshGuestWindow {
    param($Session, [int]$LaunchNumber)
    if (-not $Persistent -and -not [IO.Directory]::Exists((Join-Path $Session.Directory 'Profile\Guest Profile'))) { throw 'The fresh session did not create an isolated Guest profile.' }
    $ownedBrowsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Session.Directory) })
    $windowCount = 0
    foreach ($browser in $ownedBrowsers) {
        $window = [FreshSessionHttpProbe]::FindTestWindow($browser.ProcessId)
        if ($window -eq [IntPtr]::Zero) { continue }
        $windowCount++
        if ($ScreenshotDirectory) { [FreshSessionHttpProbe]::ActivateTestWindow($browser.ProcessId) }
        $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $windowAppId = $taskbarType::GetWindowAppId($window)
            if ($windowAppId -eq $script:ExpectedWindowAppId) { break }
            [Windows.Forms.Application]::DoEvents()
        } while ([DateTime]::UtcNow -lt $identityDeadline)
        if ($windowAppId -cne $script:ExpectedWindowAppId) { throw ('The website window did not retain its own taskbar identity: ' + $windowAppId) }
        try {
            $automationRoot = [Windows.Automation.AutomationElement]::FromHandle($window)
            $controls = $automationRoot.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
            $promptFound = @($controls | Where-Object { $_.Current.Name -match 'syncing your browsing data|has signed in on this device' }).Count -gt 0
            if (-not $Persistent -and $promptFound) { throw 'Edge displayed the automatic browser sign-in or sync prompt in a fresh Guest session.' }
            if ($ScreenshotDirectory) {
                $contentCondition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Synthetic fresh-session test')
                $contentDeadline = [DateTime]::UtcNow.AddSeconds(5)
                do {
                    $content = $automationRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, $contentCondition)
                    if ($null -ne $content) { break }
                    [Windows.Forms.Application]::DoEvents()
                } while ([DateTime]::UtcNow -lt $contentDeadline)
                if ($null -eq $content) { throw 'Foreground screenshot requires the rendered synthetic heading in UI Automation.' }
                [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
                $captureName = if ($Persistent) { 'persistent-launch-' } else { 'guest-launch-' }
                [FreshSessionHttpProbe]::CaptureTestWindow($browser.ProcessId, (Join-Path $ScreenshotDirectory ($captureName + $LaunchNumber + '.png')))
            }
        }
        finally {
            $controls = $null
            $automationRoot = $null
            $content = $null
            $contentCondition = $null
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }
    }
    if ($windowCount -ne 1) { throw 'Each test launch must retain exactly one owned website window.' }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ($Persistent) { Write-Host ('PASS: Persistent launch ' + $LaunchNumber + ' retains exactly one website window with its own taskbar identity.') }
    else { Write-Host ('PASS: Launch ' + $LaunchNumber + ' uses an isolated Guest profile without the reported automatic sign-in or sync dialog and retains its website taskbar identity.') }
}

function Close-FreshTestSession {
    param($Session)
    $ownedBrowsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Session.Directory) })
    $closedWindows = 0
    foreach ($browser in $ownedBrowsers) { $closedWindows += [FreshSessionHttpProbe]::CloseTestWindows($browser.ProcessId) }
    if ($closedWindows -ne 1) { throw ('Could not close the exact owned test window: ' + $closedWindows) }
    if (-not $Session.Process.WaitForExit(25000) -or $Session.Process.ExitCode -ne 0) {
        Write-Host ('Test launcher exited: ' + $Session.Process.HasExited)
        if ($Session.Process.HasExited) { Write-Host ('Test launcher exit code: ' + $Session.Process.ExitCode) }
        $remainingBrowsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Session.Directory) })
        Write-Host ('Remaining owned browser processes: ' + $remainingBrowsers.Count)
        foreach ($browser in $remainingBrowsers) {
            $processType = if ($browser.CommandLine -match '--type=([^\s]+)') { $Matches[1] } else { 'browser' }
            Write-Host ('Remaining owned process type: ' + $processType + '; test window present = ' + ([FreshSessionHttpProbe]::FindTestWindow($browser.ProcessId) -ne [IntPtr]::Zero))
        }
        Write-Host ([FreshSessionHttpProbe]::DescribeJob($Session.Directory))
        $diagnosticFile = Join-Path ([IO.Path]::GetDirectoryName($Session.Directory)) 'cleanup-error.txt'
        if ($DiagnoseCleanup -and [IO.File]::Exists($diagnosticFile)) { Write-Host ([IO.File]::ReadAllText($diagnosticFile)) }
        if ([IO.Directory]::Exists($Session.Directory)) {
            Get-ChildItem -LiteralPath $Session.Directory -Recurse -File | Select-Object -First 12 -ExpandProperty Name | Write-Host
        }
        throw 'The fresh-session launcher did not cleanly complete after normal window closure.'
    }
    if ($Persistent) {
        if (-not [IO.Directory]::Exists($Session.Directory)) { throw 'A persistent app profile was unexpectedly removed.' }
    }
    elseif ([IO.Directory]::Exists($Session.Directory)) { throw 'The closed session profile was not removed.' }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $launcher = Join-Path $testRoot 'fresh-session.exe'
    New-EeaIcon -Path (Join-Path $testRoot 'icon.ico') -AppName 'Taskbar test'
    Write-EeaSessionLauncher -Path $launcher -Website ($server.Origin + '/app') -EdgePath (Find-EeaEdge) -AppName 'Taskbar test' -FreshSession:(-not $Persistent)
    $launcherAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($launcher))
    $launcherType = $launcherAssembly.GetType('EeaFreshSession')
    $script:ExpectedWindowAppId = $launcherType::AppId((Join-Path $testRoot 'Sessions'))
    foreach ($launchNumber in @(1, 2, 3)) {
        $process = Start-Process -FilePath $launcher -PassThru
        $session = [pscustomobject]@{ Process = $process; Directory = '' }
        $sessions.Add($session)
        $report = ConvertFrom-EeaJson ($server.WaitForReport())
        if ($Persistent -and $launchNumber -gt 1) {
            if ($report.before.cookie -cne 'eeaProbe=synthetic' -or $report.before.storage -cne 'synthetic' -or $report.cache -cne 'cache-1') { throw 'The persistent app did not retain its synthetic cookies, local storage, and cache.' }
        }
        elseif ($report.before.cookie -cne '' -or $null -ne $report.before.storage -or $report.cache -cne ('cache-' + $launchNumber)) { throw 'The fresh session reused synthetic browser data.' }
        if ($Persistent) { $session.Directory = Join-Path $testRoot 'AppProfile' }
        else {
            $newDirectories = @([IO.Directory]::GetDirectories((Join-Path $testRoot 'Sessions')) | Where-Object { $sessions.Directory -cnotcontains $_ })
            if ($newDirectories.Count -ne 1) { throw 'Each launch must have exactly one new owned session directory.' }
            $session.Directory = $newDirectories[0]
        }
        Assert-FreshGuestWindow -Session $session -LaunchNumber $launchNumber
        if ($Persistent) {
            $secondLaunch = Start-Process -FilePath $launcher -PassThru
            try {
                if (-not $secondLaunch.WaitForExit(10000) -or $secondLaunch.ExitCode -ne 0) { throw 'Reopening the running persistent app did not reuse its existing window.' }
                Assert-FreshGuestWindow -Session $session -LaunchNumber $launchNumber
            }
            finally { if (-not $secondLaunch.HasExited) { $secondLaunch.Kill() }; $secondLaunch.Dispose() }
            Close-FreshTestSession $session
            Write-Host ('PASS: Persistent app launch ' + $launchNumber + ' preserves its profile and avoids a second app window.')
            continue
        }
        Write-Host ('PASS: Real app-mode launch ' + $launchNumber + ' begins with empty cookies, local storage, and cache.')
        if ($launchNumber -eq 2) {
            Close-FreshTestSession $sessions[0]
            $sessions[1].Process.Refresh()
            if ($sessions[1].Process.HasExited -or -not [IO.Directory]::Exists($sessions[1].Directory)) { throw 'Closing the first session disturbed the second one.' }
            Write-Host 'PASS: Closing one session removes its profile while the other session stays open.'
        }
    }
    if ($Persistent) { Write-Host 'PASS: Real persistent app profile, cookies, storage, cache, single-window relaunch, and stable website taskbar identity.' }
    else {
        Close-FreshTestSession $sessions[1]
        Close-FreshTestSession $sessions[2]
        if ([IO.Directory]::GetDirectories((Join-Path $testRoot 'Sessions')).Length -ne 0) { throw 'Temporary profiles remain after normal window closure.' }
        Write-Host 'PASS: Real Edge fresh-session isolation, independent closure, clean relaunch, and profile removal.'
    }
}
finally {
    foreach ($session in $sessions) {
        $session.Process.Refresh()
        if (-not $session.Process.HasExited) { $session.Process.Kill(); [void]$session.Process.WaitForExit(10000) }
        $session.Process.Dispose()
    }
    $server.Dispose()
    try { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }
    catch { Write-Warning ('Synthetic test cleanup remains at: ' + $testRoot) }
}