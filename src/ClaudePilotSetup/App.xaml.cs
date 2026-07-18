using System.Windows;
using System.Security.Principal;
using System.Threading;

namespace ClaudePilotSetup;

public partial class App : Application
{
    private Mutex? _singleInstanceMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        FolderIconManager.TryRepairDeliveryFolderIcon();
        var sid = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        _singleInstanceMutex = new Mutex(true, $"Local\\ClaudePilotR3Setup-{sid}", out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "Claude Desktop 已经在当前 Windows 用户中运行。请切换到已有窗口完成当前操作。",
                "Claude Desktop",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        if (!ConsentManager.IsAccepted())
        {
            var consent = new DeploymentConsentWindow();
            if (consent.ShowDialog() != true)
            {
                Shutdown();
                return;
            }
            if (!ConsentManager.SaveAccepted())
            {
                MessageBox.Show(
                    "你已经确认部署说明，但本机无法保存确认状态。可以继续本次操作；下次启动时会再次显示该说明。",
                    "确认状态未保存",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        var options = LaunchOptions.Parse(e.Args);
        var window = new MainWindow(options);
        MainWindow = window;
        ShutdownMode = ShutdownMode.OnMainWindowClose;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_singleInstanceMutex is not null)
        {
            try { _singleInstanceMutex.ReleaseMutex(); } catch (ApplicationException) { }
            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
        }
        base.OnExit(e);
    }
}
