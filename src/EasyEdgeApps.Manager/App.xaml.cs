using Microsoft.UI.Xaml;

namespace EasyEdgeApps.Manager;

public partial class App : Application
{
    private MainWindow? window;
    public App() => InitializeComponent();
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow(Environment.GetCommandLineArgs().Skip(1).ToArray());
        window.Activate();
    }
}