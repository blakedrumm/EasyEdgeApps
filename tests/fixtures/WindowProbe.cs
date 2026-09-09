using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class EeaWindowProbe
{
    private delegate bool WindowCallback(IntPtr window, IntPtr state);
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Monitor { public int Size; public Rectangle Bounds, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct Keyboard { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] private struct InputData { [FieldOffset(0)] public Keyboard Keyboard; [FieldOffset(0)] public Mouse Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputData Data; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
    [DllImport("kernel32.dll")] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool belongs);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref Monitor information);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr word, IntPtr data, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int left, int top, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);

    public static bool IsTopmost(IntPtr window) { return (GetWindowLongPtr(window, -20).ToInt64() & 8) != 0; }

    public static string Describe(IntPtr window)
    {
        return "Synthetic window bounds=" + String.Join(",", Bounds(window)) + "; fullscreen=" + IsFullScreen(window) + "; topmost=" + IsTopmost(window) + "; style=" + GetWindowLongPtr(window, -16).ToInt64().ToString("X") + "; extended=" + GetWindowLongPtr(window, -20).ToInt64().ToString("X");
    }

    public static int[] WorkArea(IntPtr window)
    {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            Monitor monitor = new Monitor();
            monitor.Size = Marshal.SizeOf(typeof(Monitor));
            if (!GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor)) throw new Win32Exception();
            return new[] { monitor.Work.Left, monitor.Work.Top, monitor.Work.Right - monitor.Work.Left, monitor.Work.Bottom - monitor.Work.Top };
        }
        finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    public static bool Belongs(string jobName, IntPtr window)
    {
        IntPtr job = OpenJobObject(4, false, jobName);
        if (job == IntPtr.Zero) return false;
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        IntPtr process = OpenProcess(0x1000, false, processId);
        try
        {
            bool belongs;
            return process != IntPtr.Zero && IsProcessInJob(process, job, out belongs) && belongs;
        }
        finally { if (process != IntPtr.Zero) CloseHandle(process); CloseHandle(job); }
    }

    public static IntPtr[] Find(string jobName)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr state)
        {
            if (!IsWindowVisible(window)) return true;
            StringBuilder name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() == "Chrome_WidgetWin_1" && Belongs(jobName, window)) windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static int[] Bounds(IntPtr window)
    {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            Rectangle rectangle;
            if (!GetWindowRect(window, out rectangle)) throw new Win32Exception();
            return new[] { rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top };
        }
        finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    public static bool IsFullScreen(IntPtr window)
    {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            Rectangle rectangle;
            Monitor monitor = new Monitor();
            monitor.Size = Marshal.SizeOf(typeof(Monitor));
            if (!GetWindowRect(window, out rectangle) || !GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor)) throw new Win32Exception();
            return rectangle.Left == monitor.Bounds.Left && rectangle.Top == monitor.Bounds.Top && rectangle.Right == monitor.Bounds.Right && rectangle.Bottom == monitor.Bounds.Bottom;
        }
        finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    public static void Key(string jobName, IntPtr window, ushort key)
    {
        if (!Belongs(jobName, window)) throw new InvalidOperationException("Keyboard test target is not owned.");
        SetForegroundWindow(window);
        DwmFlush();
        if (GetForegroundWindow() != window) throw new InvalidOperationException("Keyboard test target is not foreground; no input sent.");
        Input[] inputs = new Input[2];
        inputs[0].Type = inputs[1].Type = 1;
        inputs[0].Data.Keyboard.Key = inputs[1].Data.Keyboard.Key = key;
        inputs[1].Data.Keyboard.Flags = 2;
        if (SendInput(2, inputs, Marshal.SizeOf(typeof(Input))) != 2) throw new Win32Exception();
    }

    public static void Resize(string jobName, IntPtr window, int left, int top, int width, int height)
    {
        if (!Belongs(jobName, window)) throw new InvalidOperationException("Resize test target is not owned.");
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { ShowWindowAsync(window, 9); if (!SetWindowPos(window, IntPtr.Zero, left, top, width, height, 0x14)) throw new Win32Exception(); }
        finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    public static void MessageKey(string jobName, IntPtr window, int key)
    {
        if (!Belongs(jobName, window)) throw new InvalidOperationException("Keyboard message target is not owned.");
        UIntPtr result;
        SendMessageTimeout(window, 0x100, new IntPtr(key), new IntPtr(1), 2, 3000, out result);
        SendMessageTimeout(window, 0x101, new IntPtr(key), new IntPtr(unchecked((int)0xc0000001)), 2, 3000, out result);
    }

    public static void Close(string jobName, IntPtr window)
    {
        if (!Belongs(jobName, window)) return;
        UIntPtr result;
        SendMessageTimeout(window, 16, IntPtr.Zero, IntPtr.Zero, 2, 3000, out result);
    }
}