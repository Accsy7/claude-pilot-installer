using System.Windows;
using System.Windows.Controls;

namespace ClaudePilotSetup;

public partial class DangerConfirmationWindow : Window
{
    public DangerConfirmationWindow(string dataRoot)
    {
        InitializeComponent();
        WindowAppearance.Attach(this);
        DataRootTextBox.Text = dataRoot;
    }

    private void ConfirmationTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        ConfirmButton.IsEnabled = string.Equals(
            ConfirmationTextBox.Text.Trim(),
            "彻底清理",
            StringComparison.Ordinal);
    }

    private void ConfirmButton_Click(object sender, RoutedEventArgs e)
    {
        if (!ConfirmButton.IsEnabled) return;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
