using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

namespace EasyEdgeApps.NativeFixture;

internal static class SyntheticWindow
{
    private static readonly WindowProcedure Procedure = Dispatch;

    internal static int Run(string gateName)
    {
        using (var gate = EventWaitHandle.OpenExisting(gateName))
            if (!gate.WaitOne(10000)) return 2;
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        var instance = GetModuleHandle(null);
        var registration = new WindowClass { Size = (uint)Marshal.SizeOf<WindowClass>(), Procedure = Procedure, Instance = instance, ClassName = "Chrome_WidgetWin_1", Background = new IntPtr(6) };
        if (RegisterClassEx(ref registration) == 0) throw new Win32Exception();
        var window = CreateWindowEx(0, registration.ClassName, "Easy Edge Apps synthetic window", 0x00cf0000, 80, 80, 620, 440, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (window == IntPtr.Zero) throw new Win32Exception();
        ShowWindow(window, 4);
        Console.WriteLine(window.ToInt64().ToString(CultureInfo.InvariantCulture));
        Console.Out.Flush();
        while (true)
        {
            var result = GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result == -1) throw new Win32Exception();
            if (result == 0) return 0;
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
    }

    private static IntPtr Dispatch(IntPtr window, uint message, IntPtr word, IntPtr data)
    {
        if (message == 16) { DestroyWindow(window); return IntPtr.Zero; }
        if (message == 2) { PostQuitMessage(0); return IntPtr.Zero; }
        return DefWindowProc(window, message, word, data);
    }

    private delegate IntPtr WindowProcedure(IntPtr window, uint message, IntPtr word, IntPtr data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WindowClass
    {
        public uint Size, Style;
        public WindowProcedure Procedure;
        public int ClassExtra, WindowExtra;
        public IntPtr Instance, Icon, Cursor, Background;
        public string MenuName, ClassName;
        public IntPtr SmallIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeMessage
    { public IntPtr Window; public uint Message; public UIntPtr Word; public IntPtr Data; public uint Time; public int Left, Top; public uint Private; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassEx(ref WindowClass windowClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateWindowEx(uint extended, string className, string title, uint style, int left, int top, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr word, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern int GetMessage(out NativeMessage message, IntPtr window, uint minimum, uint maximum);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref NativeMessage message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DispatchMessage(ref NativeMessage message);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}