using System.Windows;

namespace ClaudePilotSetup;

public partial class DiagnosticConsentWindow : Window
{
    public DiagnosticConsentWindow()
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

    private void ConfirmCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        ExportButton.IsEnabled = ConfirmCheckBox.IsChecked == true;
    }

    private void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        if (ConfirmCheckBox.IsChecked != true) return;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
