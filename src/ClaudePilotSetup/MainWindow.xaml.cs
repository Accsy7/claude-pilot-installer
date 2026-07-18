using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace ClaudePilotSetup;

public partial class MainWindow : Window
{
    private const int DefaultWindowWidth = 980;
    private const int DefaultWindowHeight = 640;
    private readonly LaunchOptions _launchOptions;
    private readonly string _enginePath;
    private readonly bool _resumeOnly;
    private bool _busy;

    public ObservableCollection<CheckItem> Checks { get; } = [];

    public MainWindow(LaunchOptions launchOptions)
    {
        InitializeComponent();
        WindowAppearance.AttachFixedPhysicalSize(this, DefaultWindowWidth, DefaultWindowHeight);
        DataContext = this;
        SetStatus("准备就绪", "info");
        _launchOptions = launchOptions;
        _resumeOnly = launchOptions.AutoResume;
        _enginePath = ResolveEnginePath(launchOptions.EnginePath);
        DataRootBox.Text = !string.IsNullOrWhiteSpace(launchOptions.DataRoot)
            ? launchOptions.DataRoot
            : GetDefaultDataRoot();
        if (_resumeOnly)
            Loaded += MainWindow_Loaded;
        else
            ShowReadyState();
        Closing += MainWindow_Closing;
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (!_busy) return;
        e.Cancel = true;
        MessageBox.Show(this,
            "当前操作仍在执行。请等待界面给出完成、失败或需要重启的明确结果后再关闭窗口。",
            "Claude Desktop 正在执行",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        Title = "Claude Desktop - 重启续装";
        PreviewBox.Text = "• 正在使用受管续装副本完成重启后复核。\n• 本窗口只开放检查与验证，避免卸载正在运行的续装程序。\n• 后续安装、修复或卸载请从原始交付包启动。";
        await RunActionAsync("Resume", elevated: false, requireKey: false);
    }

    private async void InstallButton_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync("Install", elevated: true, requireKey: true);

    private async void RepairButton_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync(
            "Repair",
            elevated: true,
            requireKey: true,
            forceReinstall: true,
            displayName: "自动修复");

    private async void UninstallButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var dataRoot = GetValidatedDataRoot();
        if (dataRoot is null) return;
        PreviewBox.Text =
            $"• 卸载当前用户 Claude Desktop 和 Cowork 受管组件。\n\n" +
            $"• 仅保留 Cowork 文件夹：{Path.Combine(dataRoot, "Cowork")}\n\n" +
            "• 保留 Git 和 VirtualMachinePlatform。\n\n" +
            "• 本地删除不会自动撤销 DeepSeek 后台 Key。";
        var detail =
            "安全卸载将执行以下固定范围：\n\n" +
            $"仅保留以下 Cowork 文件夹：\n{Path.Combine(dataRoot, "Cowork")}\n\n" +
            "数据目录中的 MCP、日志、备份、状态和 Support 会删除。\n" +
            "Git 和 VirtualMachinePlatform 保留。\n\n" +
            "是否继续？";
        if (MessageBox.Show(this, detail, "确认安全卸载", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;
        await RunActionAsync(
            "Uninstall",
            elevated: true,
            requireKey: false,
            uninstallMode: "PreserveWork");
    }

    private async void AdvancedButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _resumeOnly) return;
        var dataRoot = GetValidatedDataRoot();
        if (dataRoot is null) return;

        var ownership = DeploymentOwnershipReader.Read(dataRoot);
        var dialog = new AdvancedOperationsWindow(ownership) { Owner = this };
        if (dialog.ShowDialog() != true) return;

        switch (dialog.SelectedOperation)
        {
            case AdvancedOperation.ForceReinstall:
                PreviewBox.Text =
                    "• 重新注册当前用户 Claude Desktop。\n\n" +
                    "• 覆盖修复 Cowork 离线运行组件、中文、Flash Max 和 Office MCP。\n\n" +
                    $"• Cowork 文件夹不删除：{Path.Combine(dataRoot, "Cowork")}\n\n" +
                    "• 保留 Git 和 VirtualMachinePlatform。";
                if (MessageBox.Show(
                        this,
                        "仅保留任务生成并保存到该目录的文档\n" +
                        $"{Path.Combine(dataRoot, "Cowork")}\n\n" +
                        "彻底重装会重新注册 Claude Desktop 并覆盖受管组件。\n\n" +
                        "需要在主界面输入该设备专用的 DeepSeek API Key。是否继续？",
                        "确认彻底重装",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Warning) != MessageBoxResult.Yes)
                    return;
                await RunActionAsync(
                    "Repair",
                    elevated: true,
                    requireKey: true,
                    forceReinstall: true,
                    displayName: "彻底重装");
                break;

            case AdvancedOperation.PreserveWorkUninstall:
                PreviewBox.Text =
                    "• 卸载当前用户 Claude Desktop、Cowork 和受管配置。\n\n" +
                    $"• 仅保留 Cowork 文件夹：{Path.Combine(dataRoot, "Cowork")}\n\n" +
                    $"• Git：{(dialog.RemoveGit ? "状态证明归属后请求卸载" : "保留")}\n\n" +
                    $"• VirtualMachinePlatform：{(dialog.DisableVmp ? "状态证明归属后请求关闭" : "保留")}。";
                var preserveDetail =
                    "仅保留任务生成并保存到该目录的文档\n" +
                    $"{Path.Combine(dataRoot, "Cowork")}\n\n" +
                    "数据目录中的其他受管内容会删除。\n\n" +
                    $"Git：{(dialog.RemoveGit ? "请求卸载；内核会再次核验归属" : "保留")}\n" +
                    $"VirtualMachinePlatform：{(dialog.DisableVmp ? "请求关闭；内核会再次核验归属" : "保留")}\n\n" +
                    "是否继续？";
                if (MessageBox.Show(this, preserveDetail, "确认高级卸载范围", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                    return;
                await RunActionAsync(
                    "Uninstall",
                    elevated: true,
                    requireKey: false,
                    uninstallMode: "PreserveWork",
                    removeGit: dialog.RemoveGit,
                    disableVmp: dialog.DisableVmp,
                    displayName: "高级卸载");
                break;

            case AdvancedOperation.FullCleanupUninstall:
                PreviewBox.Text =
                    $"• 删除整个受管数据目录：{dataRoot}\n\n" +
                    "• 包括 Cowork 工作文件、MCP、日志、备份和状态。\n\n" +
                    $"• Git：{(dialog.RemoveGit ? "状态证明归属后请求卸载" : "保留")}\n\n" +
                    $"• VirtualMachinePlatform：{(dialog.DisableVmp ? "状态证明归属后请求关闭" : "保留")}。";
                var danger = new DangerConfirmationWindow(dataRoot) { Owner = this };
                if (danger.ShowDialog() != true) return;
                await RunActionAsync(
                    "Uninstall",
                    elevated: true,
                    requireKey: false,
                    uninstallMode: "FullCleanup",
                    removeGit: dialog.RemoveGit,
                    disableVmp: dialog.DisableVmp,
                    displayName: "彻底清理");
                break;
        }
    }

    private async void DiagnosticsButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var dataRoot = GetValidatedDataRoot();
        if (dataRoot is null) return;

        var consent = new DiagnosticConsentWindow { Owner = this };
        if (consent.ShowDialog() != true) return;

        var dialog = new SaveFileDialog
        {
            Title = "保存 Claude Pilot 脱敏诊断包",
            FileName = $"ClaudePilot-Diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip",
            DefaultExt = ".zip",
            AddExtension = true,
            OverwritePrompt = true,
            Filter = "ZIP 压缩包 (*.zip)|*.zip",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments)
        };
        if (dialog.ShowDialog(this) != true) return;

        var packageRoot = FolderIconManager.FindDeliveryRoot();
        if (string.IsNullOrWhiteSpace(packageRoot))
        {
            MessageBox.Show(this,
                "当前程序不在完整交付包中，无法定位资源目录。请从“Claude智能体部署包”根目录启动。",
                "无法导出诊断",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        SetBusy(true, "Diagnostics", "导出诊断");
        ProgressBar.Value = 0;
        ProgressText.Text = "0%";
        ResultsTabs.SelectedIndex = 1;
        AppendLog("[INFO] 已确认诊断白名单；不会读取 API Key、Office 文档或 Cowork 工作文件。");
        try
        {
            var runner = new DiagnosticRunner(ResolveDiagnosticScriptPath());
            runner.ProgressChanged += (percent, message) => Dispatcher.Invoke(() =>
            {
                ProgressBar.Value = percent;
                ProgressText.Text = $"{percent}%";
                SetStatus(message, "busy");
                AppendLog($"[INFO] {message}");
            });
            runner.OutputReceived += line => Dispatcher.Invoke(() => AppendLog($"[OUT] {line}"));
            await runner.ExportAsync(dataRoot, packageRoot, dialog.FileName, LogBox.Text);
            SetStatus("脱敏诊断包已生成", "success");
            ReportBox.Text =
                "脱敏诊断包已生成。\n\n" +
                $"保存位置：{dialog.FileName}\n\n" +
                "文件不会自动上传或发送。请先自行检查，再决定是否交给支持人员。";
            ResultsTabs.SelectedIndex = 2;
            MessageBox.Show(this,
                $"诊断包已保存：\n{dialog.FileName}\n\n文件不会自动上传或发送。",
                "导出完成",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            SetStatus("诊断导出失败", "fail");
            ReportBox.Text = $"诊断导出失败。\n\n{ex.Message}";
            ResultsTabs.SelectedIndex = 2;
            AppendLog($"[FAIL] {ex.Message}");
            MessageBox.Show(this, ex.Message, "诊断导出失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            SetBusy(false, "Diagnostics");
        }
    }

    private void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var dialog = new OpenFolderDialog
        {
            Title = "选择 Claude Pilot 数据目录",
            Multiselect = false,
            InitialDirectory = Directory.Exists(DataRootBox.Text) ? DataRootBox.Text : null
        };
        if (dialog.ShowDialog(this) == true)
        {
            DataRootBox.Text = dialog.FolderName;
            ShowReadyState();
            PreviewBox.Text = $"工作目录：{dialog.FolderName}\n\n现在输入 DeepSeek API Key，然后点击“一键安装”。";
        }
    }

    private async Task<EngineResult?> RunActionAsync(
        string action,
        bool elevated,
        bool requireKey,
        string uninstallMode = "PreserveWork",
        bool removeGit = false,
        bool disableVmp = false,
        bool forceReinstall = false,
        string? displayName = null)
    {
        if (_busy) return null;
        var dataRoot = GetValidatedDataRoot();
        if (dataRoot is null) return null;
        if (requireKey && string.IsNullOrWhiteSpace(ApiKeyBox.Password))
        {
            MessageBox.Show(this, "请输入 DeepSeek API Key。", "需要 API Key", MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }

        var key = requireKey ? ApiKeyBox.Password : string.Empty;
        SetBusy(true, action, displayName);
        LogBox.Clear();
        ReportBox.Clear();
        ProgressBar.Value = 0;
        ProgressText.Text = "0%";

        try
        {
            var runner = new EngineRunner(_enginePath);
            runner.ProgressChanged += progress => Dispatcher.Invoke(() => ApplyProgress(progress));
            runner.OutputReceived += line => Dispatcher.Invoke(() => AppendLog($"[OUT] {line}"));
            var options = new EngineRunOptions
            {
                Action = action,
                DataRoot = dataRoot,
                ApiKey = key,
                Elevated = elevated,
                UninstallMode = uninstallMode,
                RemoveGit = removeGit,
                DisableVmp = disableVmp,
                ForceReinstall = forceReinstall,
                UpdatePolicy = "Block"
            };
            var result = await runner.RunAsync(options);
            ApplyResult(result);
            return result;
        }
        catch (OperationCanceledException ex)
        {
            SetStatus("已取消", "warn");
            AppendLog($"[WARN] {ex.Message}");
            return null;
        }
        catch (Exception ex)
        {
            SetStatus("执行失败", "fail");
            AppendLog($"[FAIL] {ex.Message}");
            var friendly = GetFriendlyMessage(ex.Message);
            ReportBox.Text = $"操作未完成。\n\n{friendly}";
            ResultsTabs.SelectedIndex = 2;
            MessageBox.Show(this, friendly, "Claude Desktop", MessageBoxButton.OK, MessageBoxImage.Error);
            return null;
        }
        finally
        {
            key = string.Empty;
            if (requireKey) ApiKeyBox.Clear();
            SetBusy(false, action);
        }
    }

    private string? GetValidatedDataRoot()
    {
        if (string.IsNullOrWhiteSpace(DataRootBox.Text))
        {
            MessageBox.Show(this, "请先选择数据目录。", "缺少数据目录", MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
        try
        {
            return Path.GetFullPath(DataRootBox.Text.Trim());
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"数据目录无效：{ex.Message}", "数据目录错误", MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
    }

    private void ApplyProgress(ProgressEvent progress)
    {
        ProgressBar.Value = progress.Percent;
        ProgressText.Text = $"{progress.Percent}%";
        var tone = progress.Level.Equals("FAIL", StringComparison.OrdinalIgnoreCase)
            ? "fail"
            : progress.Level.Equals("WARN", StringComparison.OrdinalIgnoreCase) ? "warn" : "busy";
        SetStatus(progress.Message, tone);
        AppendLog($"[{progress.Level}] {progress.Message}");
    }

    private void ApplyResult(EngineResult result)
    {
        Checks.Clear();
        foreach (var item in GetFriendlyDisplayChecks(result)) Checks.Add(item);
        if (result.Preview.Count > 0)
            PreviewBox.Text = string.Join(Environment.NewLine, result.Preview.Select(x => $"• {x}"));

        if (!string.IsNullOrWhiteSpace(result.ReportPath) && File.Exists(result.ReportPath))
        {
            try { ReportBox.Text = File.ReadAllText(result.ReportPath); }
            catch (Exception ex) { ReportBox.Text = $"报告路径：{result.ReportPath}\n读取失败：{ex.Message}"; }
        }
        else if (!string.IsNullOrWhiteSpace(result.ReportPath))
        {
            ReportBox.Text = $"报告路径：{result.ReportPath}";
        }
        else if (result.Checks.Count > 0)
        {
            ReportBox.Text = "完整检查结果\n\n" +
                string.Join(
                    Environment.NewLine,
                    result.Checks.Select(x => $"[{x.DisplayStatus}] {x.Name}：{x.Detail}"));
        }

        var failCount = result.Checks.Count(x => x.Status == "FAIL");
        var warnCount = result.Checks.Count(x => x.Status is "WARN" or "MANUAL");
        var friendlyError = GetFriendlyMessage(result.Error);
        var statusMessage = result.Success
            ? (result.RestartRequired ? "部署完成，等待重启续装" : warnCount > 0 ? $"完成，有 {warnCount} 项提示/人工验收" : "完成")
            : $"未完成：{(string.IsNullOrWhiteSpace(friendlyError) ? $"{failCount} 个问题" : friendlyError)}";
        SetStatus(statusMessage, result.Success ? (result.RestartRequired || warnCount > 0 ? "warn" : "success") : "fail");

        if (!result.Success)
        {
            if (string.IsNullOrWhiteSpace(ReportBox.Text))
                ReportBox.Text = string.IsNullOrWhiteSpace(result.Error)
                    ? "操作未通过，请查看 FAIL 项和实时进度。"
                    : friendlyError;
            ResultsTabs.SelectedIndex = result.Checks.Count > 0 ? 0 : 2;
            MessageBox.Show(this,
                result.Checks.Count > 0
                    ? "暂时不能继续。请查看红色“需处理”项目，处理后再试一次。"
                    : (string.IsNullOrWhiteSpace(friendlyError) ? "操作未完成，请稍后重试。" : friendlyError),
                 "操作未完成", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        else if (result.RestartRequired)
        {
            var restart = new RestartCountdownWindow(60) { Owner = this };
            restart.ShowDialog();
        }
    }

    private void AppendLog(string line)
    {
        LogBox.AppendText($"{DateTime.Now:HH:mm:ss} {line}{Environment.NewLine}");
        LogBox.ScrollToEnd();
    }

    private void ShowReadyState()
    {
        Checks.Clear();
        Checks.Add(new CheckItem
        {
            Status = "READY",
            Name = "可以开始",
            Detail = "选择工作目录，输入 DeepSeek API Key，然后点击“一键安装”。"
        });
        ResultsTabs.SelectedIndex = 0;
        LogBox.Clear();
        ReportBox.Clear();
        ProgressBar.Value = 0;
        ProgressText.Text = "—";
        PreviewBox.Text = "一键安装会自动检查电脑、完成安装，再做安装后复核。\n\n只有出现红色问题时，才需要手动处理。";
        SetStatus("等待开始", "info");
    }

    private static IReadOnlyList<CheckItem> GetFriendlyDisplayChecks(EngineResult result)
    {
        var issues = result.Checks
            .Where(x => x.Status is "FAIL" or "WARN" or "MANUAL")
            .Select(ToFriendlyCheck)
            .ToList();
        if (issues.Count > 0) return issues;

        return
        [
            new CheckItem
            {
                Status = result.Success ? "PASS" : "FAIL",
                Name = result.Success ? "检查完成" : "未能继续",
                Detail = result.Success
                    ? (result.Action == "Preflight" ? "电脑可以继续安装。" : "没有发现需要处理的问题。")
                    : (string.IsNullOrWhiteSpace(result.Error) ? "请打开“详细信息”查看原因。" : result.Error)
            }
        ];
    }

    private static CheckItem ToFriendlyCheck(CheckItem item)
    {
        var name = item.Name switch
        {
            "Windows x64 与版本" => "Windows 版本",
            "PowerShell 5.1" => "Windows 系统组件",
            "数据目录固定 NTFS 与空间" => "工作目录",
            "C 盘 Cowork 运行时空间" => "C 盘空间",
            "Claude-3p 物理目录" => "Claude 运行目录",
            "BIOS/UEFI 或嵌套虚拟化" => "虚拟化功能",
            "BIOS/UEFI 虚拟化" => "虚拟化功能",
            "VirtualMachinePlatform" => "Windows 虚拟化组件",
            "离线资源完整性" => "安装文件",
            "Claude MSIX 厂商签名" => "Claude 安装文件",
            "Git 安装器厂商签名" => "Git 安装文件",
            "Cowork Host Code 厂商签名" => "Cowork 安装文件",
            "已有 Claude Desktop" => "Claude Desktop",
            "已有 Git" => "Git",
            "DeepSeek API 网络" => "DeepSeek 网络",
            _ => item.Name
        };

        var detail = (item.Name, item.Status) switch
        {
            ("管理员权限", "WARN") => "安装时 Windows 会弹出管理员确认，请点击“是”。",
            ("VirtualMachinePlatform", "WARN") => "安装程序会自动启用该功能，之后可能需要重启电脑。",
            ("Microsoft Word", "WARN") => "未检测到 Word；不影响 Claude Desktop 安装。",
            ("Microsoft Excel", "WARN") => "未检测到 Excel；不影响 Claude Desktop 安装。",
            ("Microsoft PowerPoint", "WARN") => "未检测到 PowerPoint；不影响安装。",
            ("DeepSeek API 网络", "WARN") => "当前无法连接 DeepSeek，请检查网络后重试。",
            ("数据目录固定 NTFS 与空间", "FAIL") when item.Detail.Contains("空间不足", StringComparison.OrdinalIgnoreCase) => "磁盘空间不足",
            ("C 盘 Cowork 运行时空间", "FAIL") => "磁盘空间不足",
            ("BIOS/UEFI 或嵌套虚拟化", "FAIL") => "当前电脑不满足虚拟化要求。",
            ("BIOS/UEFI 虚拟化", "FAIL") => "请在 BIOS 中开启虚拟化后重试。",
            ("Claude 真实启动", "FAIL") => "Claude 启动异常，安装器已自动恢复。",
            ("离线资源完整性", "FAIL") => "安装文件不完整，请重新解压完整 ZIP。",
            ("Claude MSIX 厂商签名", "FAIL") => "Claude 安装文件校验失败，请重新获取交付包。",
            ("Git 安装器厂商签名", "FAIL") => "Git 安装文件校验失败，请重新获取交付包。",
            ("Cowork Host Code 厂商签名", "FAIL") => "Cowork 安装文件校验失败，请重新获取交付包。",
            _ => item.Detail
        };

        return new CheckItem
        {
            Status = item.Status,
            Name = name,
            Detail = detail,
            Blocking = item.Blocking
        };
    }

    private static string GetFriendlyMessage(string? message)
    {
        if (string.IsNullOrWhiteSpace(message)) return string.Empty;
        if (message.Contains("DeepSeek", StringComparison.OrdinalIgnoreCase) &&
            (message.Contains("HTTP", StringComparison.OrdinalIgnoreCase) ||
             message.Contains("key", StringComparison.OrdinalIgnoreCase) ||
             message.Contains("credential", StringComparison.OrdinalIgnoreCase)))
            return "Key 无效或不可用，请重新输入。";
        if (message.Contains("空间不足", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("not enough space", StringComparison.OrdinalIgnoreCase))
            return "磁盘空间不足";
        if (message.Contains("0x80070005", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("access is denied", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("unauthorized", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("拒绝访问", StringComparison.OrdinalIgnoreCase))
            return "安全软件阻止安装，请点击允许后重试。";
        if (message.Contains("Virtualization", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("虚拟化", StringComparison.OrdinalIgnoreCase))
            return "当前电脑不满足虚拟化要求。";
        if (message.Contains("mainView", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("ERR_FAILED", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("runtime validation", StringComparison.OrdinalIgnoreCase))
            return "Claude 启动异常，安装器已自动恢复。";
        if (message.Contains("already contains", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("已有其他文件", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("Untrusted", StringComparison.OrdinalIgnoreCase))
            return "所选文件夹不能用于安装，请选择一个空文件夹。";
        if (message.Contains("missing", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("找不到", StringComparison.OrdinalIgnoreCase))
            return "安装文件不完整，请重新解压完整安装包。";
        return "安装没有完成，已保留原有文件。请重试或导出诊断。";
    }

    private void SetBusy(bool busy, string action, string? displayName = null)
    {
        _busy = busy;
        InstallButton.IsEnabled = !busy && !_resumeOnly;
        RepairButton.IsEnabled = !busy && !_resumeOnly;
        DiagnosticsButton.IsEnabled = !busy;
        UninstallButton.IsEnabled = !busy && !_resumeOnly;
        AdvancedButton.IsEnabled = !busy && !_resumeOnly;
        BrowseButton.IsEnabled = !busy && !_resumeOnly;
        DataRootBox.IsEnabled = !busy && !_resumeOnly;
        ApiKeyBox.IsEnabled = !busy && !_resumeOnly;
        if (busy) SetStatus($"{displayName ?? GetActionDisplayName(action)}执行中…", "busy");
    }

    private void SetStatus(string text, string tone)
    {
        var foregroundKey = tone switch
        {
            "success" => "SuccessBrush",
            "warn" => "WarningBrush",
            "fail" => "DangerBrush",
            "busy" => "PrimaryBrush",
            _ => "InfoBrush"
        };
        var foreground = (Brush)FindResource(foregroundKey);
        ProgressBar.Foreground = foreground;
        ProgressBar.ToolTip = text;
        ProgressText.Foreground = foreground;
        ProgressText.ToolTip = text;
    }

    private static string GetActionDisplayName(string action) => action switch
    {
        "Preflight" => "环境自检",
        "Install" => "一键安装",
        "Repair" => "修复组件",
        "Verify" => "部署验证",
        "Uninstall" => "卸载",
        "Resume" => "重启续装",
        "Diagnostics" => "导出诊断",
        _ => action
    };

    private string ResolveDiagnosticScriptPath() =>
        Path.Combine(Path.GetDirectoryName(_enginePath)!, "Export-ClaudePilotDiagnostics.ps1");

    private static string ResolveEnginePath(string explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath)) return Path.GetFullPath(explicitPath);
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "资源目录", "配置", "Engine", "Invoke-ClaudePilotR3.ps1"),
            Path.Combine(AppContext.BaseDirectory, "..", "资源目录", "配置", "Engine", "Invoke-ClaudePilotR3.ps1")
        };
        return candidates.Select(Path.GetFullPath).FirstOrDefault(File.Exists) ?? Path.GetFullPath(candidates[0]);
    }

    private static string GetDefaultDataRoot()
    {
        try
        {
            var pointerPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudePilotR3", "deployment-pointer.json");
            if (File.Exists(pointerPath))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(pointerPath));
                foreach (var property in document.RootElement.EnumerateObject())
                {
                    if (string.Equals(property.Name, "DataRoot", StringComparison.OrdinalIgnoreCase) && property.Value.ValueKind == JsonValueKind.String)
                    {
                        var value = property.Value.GetString();
                        if (!string.IsNullOrWhiteSpace(value)) return value;
                    }
                }
            }
        }
        catch { }

        try
        {
            var d = new DriveInfo("D");
            if (d.IsReady && d.DriveType == DriveType.Fixed && string.Equals(d.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase))
                return @"D:\ClaudeDesktop";
        }
        catch { }
        return @"C:\ClaudeDesktopData";
    }
}
