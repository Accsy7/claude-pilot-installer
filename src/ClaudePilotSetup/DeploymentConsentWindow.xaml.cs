using System.Windows;

namespace ClaudePilotSetup;

public partial class DeploymentConsentWindow : Window
{
    public DeploymentConsentWindow()
    {
        InitializeComponent();
        WindowAppearance.Attach(this);
        FitToWorkArea();
    }

    private void FitToWorkArea()
    {
        var area = SystemParameters.WorkArea;
        Width = Math.Max(MinWidth, Math.Min(Width, area.Width - 24));
        Height = Math.Max(MinHeight, Math.Min(Height, area.Height - 24));
    }

    private void AcceptCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        ContinueButton.IsEnabled = AcceptCheckBox.IsChecked == true;
    }

    private void ContinueButton_Click(object sender, RoutedEventArgs e)
    {
        if (AcceptCheckBox.IsChecked != true) return;
        DialogResult = true;
    }

    private void ExitButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
