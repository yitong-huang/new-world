using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace NWVPN;

/// <summary>
/// 启动仓库 go/cmd/nw-client（Wintun + TLS + NW 协议）；与 mac 扩展 / Android 服务同一数据面。
/// </summary>
internal sealed class TunnelRunner : IDisposable
{
    private Process? _process;
    private string? _authTempPath;

    public bool IsRunning => _process is { HasExited: false };

    public event EventHandler? Exited;
    public event EventHandler<string>? LogLine;

    public static string ResolveNwClientExecutable()
    {
        var baseDir = AppContext.BaseDirectory;
        var local = Path.Combine(baseDir, "nw-client.exe");
        if (File.Exists(local)) return local;
        var env = Environment.GetEnvironmentVariable("NW_CLIENT_PATH");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env)) return env;
        throw new FileNotFoundException(
            "未找到 nw-client.exe。请将 go 编译产物拷贝到本程序同目录，或设置环境变量 NW_CLIENT_PATH。\n" +
            "示例：cd go && go build -o ../apps/windows/NWVPN/bin/Release/net8.0-windows/win-x64/publish/nw-client.exe ./cmd/nw-client");
    }

    public void Start(string host, string port, string username, string password, bool insecureTls, string? caCertPath)
    {
        Stop();
        var hostTrim = host.Trim();
        var portTrim = port.Trim();
        if (hostTrim.Length == 0) throw new InvalidOperationException("主机不能为空。");
        if (portTrim.Length == 0) throw new InvalidOperationException("端口不能为空。");

        var exe = ResolveNwClientExecutable();
        var server = $"{hostTrim}:{portTrim}";
        var baseDir = AppContext.BaseDirectory;

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
            WorkingDirectory = baseDir,
        };

        psi.ArgumentList.Add("-server");
        psi.ArgumentList.Add(server);

        if (insecureTls)
        {
            psi.ArgumentList.Add("-insecure");
        }
        else
        {
            var ca = string.IsNullOrWhiteSpace(caCertPath) ? Path.GetFullPath(Path.Combine(baseDir, "certs", "server.crt")) : caCertPath;
            if (!File.Exists(ca))
                throw new FileNotFoundException("关闭「跳过证书校验」时需要有效的 CA/服务端证书 PEM 文件。", ca);
            psi.ArgumentList.Add("-cacert");
            psi.ArgumentList.Add(ca);
        }

        var user = username.Trim();
        if (user.Length > 0)
        {
            _authTempPath = Path.Combine(Path.GetTempPath(), $"nwvpn-auth-{Guid.NewGuid():N}.json");
            var authJson = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["username"] = user,
                ["password"] = password,
            });
            File.WriteAllText(_authTempPath, authJson, Encoding.UTF8);
            psi.ArgumentList.Add("-auth-file");
            psi.ArgumentList.Add(_authTempPath);
        }

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.Exited += (_, _) =>
        {
            TryDeleteAuthTemp();
            Exited?.Invoke(this, EventArgs.Empty);
        };
        p.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data)) LogLine?.Invoke(this, e.Data);
        };
        p.OutputDataReceived += (_, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data)) LogLine?.Invoke(this, e.Data);
        };

        if (!p.Start()) throw new InvalidOperationException("无法启动 nw-client。");
        p.BeginErrorReadLine();
        p.BeginOutputReadLine();
        _process = p;
    }

    private void TryDeleteAuthTemp()
    {
        try
        {
            if (_authTempPath != null && File.Exists(_authTempPath)) File.Delete(_authTempPath);
        }
        catch
        {
            /* ignore */
        }
        finally
        {
            _authTempPath = null;
        }
    }

    public void Stop()
    {
        TryDeleteAuthTemp();
        if (_process == null) return;
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(5000);
            }
        }
        catch
        {
            /* ignore */
        }
        finally
        {
            _process.Dispose();
            _process = null;
        }
    }

    public void Dispose() => Stop();
}
