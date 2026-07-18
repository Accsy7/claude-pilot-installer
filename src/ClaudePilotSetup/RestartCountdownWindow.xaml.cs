using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace ClaudePilotSetup;

public partial class RestartCountdownWindow : Window
{
    private readonly DispatcherTimer _timer;
    private int _secondsRemaining;
    private bool _restartStarted;

    public RestartCountdownWindow(int seconds = 60)
    {
        InitializeComponent();
        WindowAppearance.AttachFixedPhysicalSize(this, 520, 260);
        _secondsRemaining = Math.Max(10, seconds);
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += Timer_Tick;
        Loaded += (_, _) =>
        {
            UpdateCountdown();
            _timer.Start();
        };
        Closing += RestartCountdownWindow_Closing;
    }

    private void Timer_Tick(object? sender, EventArgs e)
    {
        _secondsRemaining--;
        UpdateCountdown();
        if (_secondsRemaining <= 0) StartRestart();
    }

    private void UpdateCountdown() =>
        CountdownText.Text = $"将在 {_secondsRemaining} 秒后重启";

    private void RestartNowButton_Click(object sender, RoutedEventArgs e) => StartRestart();

    private void RestartLaterButton_Click(object sender, RoutedEventArgs e)
    {
        _timer.Stop();
        DialogResult = false;
    }

    private void StartRestart()
    {
        if (_restartStarted) return;
        _timer.Stop();
        try
        {
            var shutdown = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "shutdown.exe");
            var startInfo = new ProcessStartInfo
            {
                FileName = shutdown,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            startInfo.ArgumentList.Add("/r");
            startInfo.ArgumentList.Add("/t");
            startInfo.ArgumentList.Add("0");
            startInfo.ArgumentList.Add("/d");
            startInfo.ArgumentList.Add("p:2:4");
            startInfo.ArgumentList.Add("/c");
            startInfo.ArgumentList.Add("Claude Desktop 安装将在登录后自动继续");
            Process.Start(startInfo);
            _restartStarted = true;
            DialogResult = true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                $"无法自动重启，请从 Windows 开始菜单手动重启。\n\n{ex.Message}",
                "需要重启",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void RestartCountdownWindow_Closing(object? sender, CancelEventArgs e)
    {
        _timer.Stop();
    }
}
