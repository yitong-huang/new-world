using System.Text;
using System.Windows;
using System.Windows.Controls;

namespace NWVPN;

public partial class MainWindow : Window
{
    private readonly StringBuilder _logBuf = new(4096);
    private const int LogMaxChars = 8000;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => LoadUiFromSettings();
        InsecureCheck.Checked += (_, _) => UpdateCaPanelVisibility();
        InsecureCheck.Unchecked += (_, _) => UpdateCaPanelVisibility();
    }

    private void LoadUiFromSettings()
    {
        var s = SettingsStore.Load();
        HostBox.Text = s.Host;
        PortBox.Text = s.Port;
        UserBox.Text = s.Username;
        PassBox.Password = s.Password;
        InsecureCheck.IsChecked = s.InsecureTls;
        CaPathBox.Text = s.CaCertPath ?? "";
        UpdateCaPanelVisibility();
    }

    private void UpdateCaPanelVisibility()
    {
        CaPanel.Visibility = InsecureCheck.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
    }

    public void PersistSettingsFromUi() => SaveUiToSettings();

    private void SaveUiToSettings()
    {
        SettingsStore.Save(new SettingsStore.Model
        {
            Host = HostBox.Text,
            Port = PortBox.Text,
            Username = UserBox.Text,
            Password = PassBox.Password,
            InsecureTls = InsecureCheck.IsChecked == true,
            CaCertPath = string.IsNullOrWhiteSpace(CaPathBox.Text) ? null : CaPathBox.Text.Trim(),
        });
    }

    public void SetStatus(string status, string? error = null)
    {
        StatusText.Text = status;
        ErrorText.Text = error ?? "";
    }

    public void AppendLog(string line)
    {
        if (_logBuf.Length > LogMaxChars)
        {
            _logBuf.Remove(0, _logBuf.Length - LogMaxChars / 2);
        }
        _logBuf.AppendLine(line);
        LogText.Text = _logBuf.ToString();
        LogScroll.ScrollToEnd();
    }

    public void ClearLog() => _logBuf.Clear();

    public void SetTunnelRunning(bool running)
    {
        ConnectBtn.IsEnabled = !running;
        DisconnectBtn.IsEnabled = running;
    }

    private void Connect_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Text = "";
        SaveUiToSettings();
        if (Application.Current is App app)
        {
            app.StartTunnel(
                HostBox.Text,
                PortBox.Text,
                UserBox.Text,
                PassBox.Password,
                InsecureCheck.IsChecked == true,
                string.IsNullOrWhiteSpace(CaPathBox.Text) ? null : CaPathBox.Text.Trim());
        }
    }

    private void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        if (Application.Current is App app) app.StopTunnel();
    }
}
