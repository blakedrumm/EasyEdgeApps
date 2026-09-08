#requires -Version 5.1

[CmdletBinding()]
param([switch]$DiagnoseCleanup)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this interactive browser smoke test in Windows PowerShell 5.1 with -STA.' }
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
if ($DiagnoseCleanup) {
    $script:FreshSessionSourceFactory = ${function:Get-EeaSessionLauncherSource}
    function Get-EeaSessionLauncherSource {
        param($Website, $EdgePath)
        $generatedSource = & $script:FreshSessionSourceFactory -Website $Website -EdgePath $EdgePath
        foreach ($exceptionType in @('IOException', 'UnauthorizedAccessException', 'InvalidOperationException')) {
            $generatedSource = $generatedSource.Replace(('catch (' + $exceptionType + ') { return false; }'), ('catch (' + $exceptionType + ' failure) { File.WriteAllText(Path.Combine(root, "cleanup-error.txt"), failure.ToString()); return false; }'))
        }
        return $generatedSource
    }
}
Add-Type -ReferencedAssemblies System, System.Core -TypeDefinition @'
using System;
using System.Collections.Concurrent;
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
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr word, IntPtr data, uint flags, uint timeout, out UIntPtr result);
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
    public static int CloseTestWindows(int process)
    {
        int closed = 0;
        EnumWindows(delegate(IntPtr window, IntPtr state)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)process) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf("Easy Edge Apps fresh-session test", StringComparison.Ordinal) < 0) return true;
            UIntPtr result;
            if (SendMessageTimeout(window, 16, IntPtr.Zero, IntPtr.Zero, 2, 3000, out result) != IntPtr.Zero) closed++;
            return true;
        }, IntPtr.Zero);
        return closed;
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
        Write-Host ([FreshSessionHttpProbe]::DescribeJob($Session.Directory))
        $diagnosticFile = Join-Path ([IO.Path]::GetDirectoryName($Session.Directory)) 'cleanup-error.txt'
        if ($DiagnoseCleanup -and [IO.File]::Exists($diagnosticFile)) { Write-Host ([IO.File]::ReadAllText($diagnosticFile)) }
        if ([IO.Directory]::Exists($Session.Directory)) {
            Get-ChildItem -LiteralPath $Session.Directory -Recurse -File | Select-Object -First 12 -ExpandProperty Name | Write-Host
        }
        throw 'The fresh-session launcher did not cleanly complete after normal window closure.'
    }
    if ([IO.Directory]::Exists($Session.Directory)) { throw 'The closed session profile was not removed.' }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $launcher = Join-Path $testRoot 'fresh-session.exe'
    Write-EeaSessionLauncher -Path $launcher -Website ($server.Origin + '/app') -EdgePath (Find-EeaEdge)
    foreach ($launchNumber in @(1, 2, 3)) {
        $process = Start-Process -FilePath $launcher -PassThru
        $session = [pscustomobject]@{ Process = $process; Directory = '' }
        $sessions.Add($session)
        $report = ConvertFrom-EeaJson ($server.WaitForReport())
        if ($report.before.cookie -cne '' -or $null -ne $report.before.storage -or $report.cache -cne ('cache-' + $launchNumber)) { throw 'The fresh session reused synthetic browser data.' }
        $newDirectories = @([IO.Directory]::GetDirectories((Join-Path $testRoot 'Sessions')) | Where-Object { $sessions.Directory -cnotcontains $_ })
        if ($newDirectories.Count -ne 1) { throw 'Each launch must have exactly one new owned session directory.' }
        $session.Directory = $newDirectories[0]
        Write-Host ('PASS: Real app-mode launch ' + $launchNumber + ' begins with empty cookies, local storage, and cache.')
        if ($launchNumber -eq 2) {
            Close-FreshTestSession $sessions[0]
            $sessions[1].Process.Refresh()
            if ($sessions[1].Process.HasExited -or -not [IO.Directory]::Exists($sessions[1].Directory)) { throw 'Closing the first session disturbed the second one.' }
            Write-Host 'PASS: Closing one session removes its profile while the other session stays open.'
        }
    }
    Close-FreshTestSession $sessions[1]
    Close-FreshTestSession $sessions[2]
    if ([IO.Directory]::GetDirectories((Join-Path $testRoot 'Sessions')).Length -ne 0) { throw 'Temporary profiles remain after normal window closure.' }
    Write-Host 'PASS: Real Edge fresh-session isolation, independent closure, clean relaunch, and profile removal.'
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