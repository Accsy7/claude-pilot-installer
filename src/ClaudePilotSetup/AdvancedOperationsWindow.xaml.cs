using System.Windows;

namespace ClaudePilotSetup;

public enum AdvancedOperation
{
    ForceReinstall,
    PreserveWorkUninstall,
    FullCleanupUninstall
}

public partial class AdvancedOperationsWindow : Window
{
    private readonly ComponentOwnershipInfo _ownership;

    public AdvancedOperation SelectedOperation { get; private set; } = AdvancedOperation.ForceReinstall;
    public bool RemoveGit => RemoveGitCheckBox.IsChecked == true;
    public bool DisableVmp => DisableVmpCheckBox.IsChecked == true;

    public AdvancedOperationsWindow(ComponentOwnershipInfo ownership)
    {
        _ownership = ownership;
        InitializeComponent();
        WindowAppearance.Attach(this);
        RemoveGitCheckBox.IsEnabled = ownership.GitRemovable;
        DisableVmpCheckBox.IsEnabled = ownership.VmpDisableAllowed;
        RemoveGitCheckBox.ToolTip = ownership.GitRemovable
            ? "状态证明 Git 由本部署首次安装。卸载内核仍会再次核验。"
            : "状态未证明 Git 由本部署首次安装，因此已锁定。";
        DisableVmpCheckBox.ToolTip = ownership.VmpDisableAllowed
            ? "状态证明 VMP 由本部署首次启用。卸载内核仍会再次核验。"
            : "状态未证明 VMP 由本部署首次启用，因此已锁定。";
        OwnershipText.Text = ownership.Detail;
        RefreshSelection();
        FitToWorkArea();
    }

    private void FitToWorkArea()
    {
        var area = SystemParameters.WorkArea;
        Width = Math.Max(MinWidth, Math.Min(Width, area.Width - 24));
        Height = Math.Max(MinHeight, Math.Min(Height, area.Height - 24));
    }

    private void OperationRadio_Changed(object sender, RoutedEventArgs e) => RefreshSelection();

    private void DeleteAcknowledgement_Changed(object sender, RoutedEventArgs e) => RefreshSelection();

    private void RefreshSelection()
    {
        if (!IsInitialized) return;
        var uninstall = PreserveUninstallRadio.IsChecked == true || FullCleanupRadio.IsChecked == true;
        RemoveGitCheckBox.IsEnabled = uninstall && _ownership.GitRemovable;
        DisableVmpCheckBox.IsEnabled = uninstall && _ownership.VmpDisableAllowed;
        if (!uninstall)
        {
            RemoveGitCheckBox.IsChecked = false;
            DisableVmpCheckBox.IsChecked = false;
        }

        var fullCleanup = FullCleanupRadio.IsChecked == true;
        DeleteAcknowledgementCheckBox.Visibility = fullCleanup ? Visibility.Visible : Visibility.Collapsed;
        DeleteAcknowledgementCheckBox.IsEnabled = fullCleanup;
        if (!fullCleanup) DeleteAcknowledgementCheckBox.IsChecked = false;
        ContinueButton.IsEnabled = FullCleanupRadio.IsChecked != true ||
                                   DeleteAcknowledgementCheckBox.IsChecked == true;
    }

    private void ContinueButton_Click(object sender, RoutedEventArgs e)
    {
        SelectedOperation = FullCleanupRadio.IsChecked == true
            ? AdvancedOperation.FullCleanupUninstall
            : PreserveUninstallRadio.IsChecked == true
                ? AdvancedOperation.PreserveWorkUninstall
                : AdvancedOperation.ForceReinstall;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
