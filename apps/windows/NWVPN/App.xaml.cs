using System.Drawing;
using System.Windows;
using Application = System.Windows.Application;
using Forms = System.Windows.Forms;

namespace NWVPN;

public partial class App : Application
{
    private TunnelRunner? _tunnel;
    private Forms.NotifyIcon? _tray;
    private MainWindow? _mainWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _tunnel = new TunnelRunner();
        _tunnel.Exited += Tunnel_Exited;
        _tunnel.LogLine += Tunnel_LogLine;

        _mainWindow = new MainWindow();
        MainWindow = _mainWindow;
        _mainWindow.Closing += MainWindow_Closing;

        BuildTrayIcon();
        _mainWindow.Hide();
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        _mainWindow?.Hide();
    }

    private void BuildTrayIcon()
    {
        _tray = new Forms.NotifyIcon
        {
            Text = "NWVPN — 未连接",
            Icon = SystemIcons.Shield,
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip(),
        };
        _tray.ContextMenuStrip.Items.Add("打开控制台", null, (_, _) => ShowMainWindow());
        _tray.ContextMenuStrip.Items.Add("连接", null, (_, _) => _mainWindow?.Dispatcher.Invoke(TrayConnect));
        _tray.ContextMenuStrip.Items.Add("断开", null, (_, _) => _mainWindow?.Dispatcher.Invoke(StopTunnel));
        _tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
        _tray.ContextMenuStrip.Items.Add("退出", null, (_, _) => ShutdownFromTray());
        _tray.DoubleClick += (_, _) => ShowMainWindow();
    }

    private void TrayConnect()
    {
        if (_mainWindow == null) return;
        _mainWindow.PersistSettingsFromUi();
        var s = SettingsStore.Load();
        StartTunnel(s.Host, s.Port, s.Username, s.Password, s.InsecureTls, s.CaCertPath);
    }

    private void ShutdownFromTray()
    {
        StopTunnel();
        _tray?.Visible = false;
        _tray?.Dispose();
        _tray = null;
        _tunnel?.Dispose();
        _tunnel = null;
        Shutdown();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;
        _mainWindow.Show();
        _mainWindow.Activate();
        _mainWindow.WindowState = WindowState.Normal;
    }

    public void StartTunnel(string host, string port, string user, string pass, bool insecure, string? caPath)
    {
        if (_tunnel == null || _mainWindow == null) return;
        _mainWindow.ClearLog();
        _mainWindow.SetStatus("连接中…");
        _mainWindow.SetTunnelRunning(true);
        UpdateTrayText("连接中…");
        try
        {
            _tunnel.Start(host, port, user, pass, insecure, caPath);
            _mainWindow.SetStatus("已连接");
            UpdateTrayText("已连接");
        }
        catch (Exception ex)
        {
            _mainWindow.SetStatus("未连接", ex.Message);
            _mainWindow.SetTunnelRunning(false);
            UpdateTrayText("未连接");
        }
    }

    public void StopTunnel()
    {
        _tunnel?.Stop();
        _mainWindow?.Dispatcher.Invoke(() =>
        {
            _mainWindow?.SetStatus("未连接");
            _mainWindow?.SetTunnelRunning(false);
        });
        UpdateTrayText("未连接");
    }

    private void UpdateTrayText(string state)
    {
        if (_tray == null) return;
        var t = $"NWVPN — {state}";
        _tray.Text = t.Length <= 63 ? t : t[..63];
    }

    private void Tunnel_Exited(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            _mainWindow?.SetStatus("未连接", "隧道已结束（nw-client 退出）");
            _mainWindow?.SetTunnelRunning(false);
        });
        UpdateTrayText("未连接");
    }

    private void Tunnel_LogLine(object? sender, string e)
    {
        Dispatcher.Invoke(() => _mainWindow?.AppendLog(e));
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _tunnel?.Dispose();
        base.OnExit(e);
    }
}
