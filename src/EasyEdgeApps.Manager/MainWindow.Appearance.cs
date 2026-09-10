using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using EasyEdgeApps.Windows;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;

namespace EasyEdgeApps.Manager;

public sealed partial class MainWindow
{
    private readonly Stopwatch sceneClock = new();
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? sceneTimer;
    private StarfieldRenderer? sceneRenderer;
    private System.Drawing.Bitmap? sceneFrame;
    private WriteableBitmap? sceneImage;
    private byte[] scenePixels = [];
    private bool appearanceReady, appearanceDisposed, sceneFailed, updatingMotion;
    private double sceneTime, lastSceneTick;
    private float pointerHorizontal = 0.5f, pointerVertical = 0.5f, pointerInfluence;
    private float targetHorizontal = 0.5f, targetVertical = 0.5f, targetInfluence;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);

    private void InitializeAppearance()
    {
        if (appearanceReady) return;
        appearanceReady = true;
        sceneTimer = DispatcherQueue.CreateTimer();
        sceneTimer.Interval = TimeSpan.FromMilliseconds(33);
        sceneTimer.Tick += (_, _) => AnimateScene();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemPreferenceChanged;
        AppearanceRoot.ActualThemeChanged += (_, _) => { if (ThemeChoice.SelectedIndex == 1) DispatcherQueue.TryEnqueue(RefreshAppearance); };
        AppearanceRoot.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(ScenePointerMoved), true);
        AppearanceRoot.PointerExited += (_, args) =>
        {
            var pointer = args.GetCurrentPoint(AppearanceRoot).Position;
            if (pointer.X < 0 || pointer.Y < 0 || pointer.X >= AppearanceRoot.ActualWidth || pointer.Y >= AppearanceRoot.ActualHeight)
            { targetHorizontal = targetVertical = 0.5f; targetInfluence = 0; }
        };
        AppWindow.Changed += (_, _) => UpdateMotion();
        Closed += (_, _) => DisposeAppearance();
        RefreshAppearance();
    }

    private void SystemPreferenceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs args) => DispatcherQueue.TryEnqueue(RefreshAppearance);

    private void RefreshAppearance()
    {
        if (!appearanceReady || appearanceDisposed) return;
        var contrast = System.Windows.Forms.SystemInformation.HighContrast;
        var animationsAllowed = SystemParametersInfo(0x1042, 0, out var animations, 0) && animations;
        AppearanceRoot.RequestedTheme = contrast || ThemeChoice.SelectedIndex == 1 ? ElementTheme.Default : ThemeChoice.SelectedIndex == 2 ? ElementTheme.Light : ElementTheme.Dark;
        Shell.RequestedTheme = AppearanceRoot.RequestedTheme;
        var light = AppearanceRoot.ActualTheme == ElementTheme.Light;
        SceneImage.Visibility = !contrast && !light && !sceneFailed ? Visibility.Visible : Visibility.Collapsed;
        AppWindow.TitleBar.ButtonForegroundColor = contrast ? null : light ? Microsoft.UI.Colors.Black : Microsoft.UI.Colors.White;
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        updatingMotion = true;
        MotionChoice.IsEnabled = SceneImage.Visibility == Visibility.Visible && animationsAllowed && !System.Windows.Forms.SystemInformation.TerminalServerSession;
        MotionChoice.IsChecked = preferences.MotionEnabled && MotionChoice.IsEnabled;
        updatingMotion = false;
        UpdateMotion();
        RenderScene();
    }

    private void UpdateMotion()
    {
        if (!appearanceReady || appearanceDisposed || sceneTimer is null) return;
        var minimized = AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter && presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized;
        var active = MotionChoice.IsEnabled && preferences.MotionEnabled && AppWindow.IsVisible && !minimized;
        if (active && !sceneTimer.IsRunning)
        { sceneClock.Restart(); lastSceneTick = 0; sceneTimer.Start(); }
        else if (!active)
        { sceneTimer.Stop(); sceneClock.Stop(); }
    }

    private void ScenePointerMoved(object sender, PointerRoutedEventArgs args)
    {
        var pointer = args.GetCurrentPoint(AppearanceRoot).Position;
        targetHorizontal = (float)Math.Clamp(pointer.X / Math.Max(1, AppearanceRoot.ActualWidth), 0, 1);
        targetVertical = (float)Math.Clamp(pointer.Y / Math.Max(1, AppearanceRoot.ActualHeight), 0, 1);
        targetInfluence = 1;
    }

    private void AnimateScene()
    {
        UpdateMotion();
        if (sceneTimer?.IsRunning != true) return;
        var now = sceneClock.Elapsed.TotalSeconds;
        var elapsed = Math.Clamp(now - lastSceneTick, 0, 0.1);
        lastSceneTick = now;
        sceneTime += elapsed;
        var blend = (float)(1 - Math.Exp(-elapsed * 2.8));
        pointerHorizontal += (targetHorizontal - pointerHorizontal) * blend;
        pointerVertical += (targetVertical - pointerVertical) * blend;
        pointerInfluence += (targetInfluence - pointerInfluence) * blend;
        RenderScene();
    }

    private void RenderScene()
    {
        if (!appearanceReady || appearanceDisposed || SceneImage.Visibility != Visibility.Visible || AppearanceRoot.ActualWidth < 1 || AppearanceRoot.ActualHeight < 1) return;
        var clock = Stopwatch.StartNew();
        try
        {
            var rasterScale = AppearanceRoot.XamlRoot?.RasterizationScale ?? 1;
            var scale = Math.Min(rasterScale, 1920 / Math.Max(AppearanceRoot.ActualWidth, AppearanceRoot.ActualHeight));
            var width = Math.Max(1, (int)(AppearanceRoot.ActualWidth * scale));
            var height = Math.Max(1, (int)(AppearanceRoot.ActualHeight * scale));
            sceneRenderer ??= new();
            if (sceneFrame is null || sceneFrame.Width != width || sceneFrame.Height != height)
            {
                sceneFrame?.Dispose();
                sceneFrame = new(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                scenePixels = new byte[checked(width * height * 4)];
                sceneImage = new(width, height);
                SceneImage.Source = sceneImage;
            }
            using (var graphics = System.Drawing.Graphics.FromImage(sceneFrame))
                sceneRenderer.Render(graphics, sceneFrame.Size, sceneTime, new(pointerHorizontal, pointerVertical), pointerInfluence);
            var data = sceneFrame.LockBits(new(System.Drawing.Point.Empty, sceneFrame.Size), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try { Marshal.Copy(data.Scan0, scenePixels, 0, scenePixels.Length); }
            finally { sceneFrame.UnlockBits(data); }
            using (var buffer = sceneImage!.PixelBuffer.AsStream()) buffer.Write(scenePixels);
            sceneImage.Invalidate();
            var minimum = System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Offline ? 50 : 33;
            sceneTimer!.Interval = TimeSpan.FromMilliseconds(Math.Clamp(clock.Elapsed.TotalMilliseconds * 3, minimum, 100));
        }
        catch (Exception failure) when (failure is ArgumentException or ExternalException or OutOfMemoryException)
        {
            sceneFailed = true;
            sceneTimer?.Stop();
            sceneRenderer?.Dispose(); sceneRenderer = null;
            sceneFrame?.Dispose(); sceneFrame = null;
            sceneImage = null; scenePixels = [];
            SceneImage.Source = null;
            RefreshAppearance();
        }
    }

    private void MotionChanged(object sender, RoutedEventArgs args)
    {
        if (loading || updatingMotion || !appearanceReady || !MotionChoice.IsEnabled) return;
        try
        {
            var next = preferences with { MotionEnabled = MotionChoice.IsChecked == true };
            preferenceStore.Save(next);
            preferences = next;
        }
        catch (Exception failure) { SetStatus(SafeMessage(failure)); }
        RefreshAppearance();
    }

    private void DisposeAppearance()
    {
        if (appearanceDisposed) return;
        appearanceDisposed = true;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemPreferenceChanged;
        sceneTimer?.Stop(); sceneClock.Stop();
        sceneRenderer?.Dispose(); sceneFrame?.Dispose();
        SceneImage.Source = null;
        sceneImage = null; scenePixels = [];
    }
}