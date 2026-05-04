# NWVPN（Windows 托盘 + WPF 控制台）

与 macOS 主界面类似的 **服务器 / 认证 / 连接·断开** 表单；启动后驻留在 **任务栏右下角系统托盘**（非 mac 菜单栏）。数据面复用仓库 **`go/cmd/nw-client`**（Wintun + TLS + NW 协议），与 Android `NwVpnService`、mac 扩展同一套隧道逻辑。

## 依赖

- Windows 10/11 x64  
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)  
- 已安装 **Wintun**（`nw-client` 使用 `wintun.dll`；通常随 WireGuard Windows 客户端或自行放置 `wintun.dll` 到 `nw-client.exe` 同目录或系统路径，详见 `go` 模块 `golang.zx2c4.com/wintun` 文档）  
- 将 **`nw-client.exe`** 放在本程序输出目录旁（与 `NWVPN.exe` 同目录），或设置环境变量 **`NW_CLIENT_PATH`** 指向该 exe。

编译 Go 客户端示例（在仓库根目录、已安装 Go）：

```powershell
cd go
go build -o ..\apps\windows\NWVPN\bin\Debug\net8.0-windows\nw-client.exe .\cmd\nw-client
```

发布时常用 `dotnet publish` 后再把 `nw-client.exe` 拷进 `publish\`。

## 构建 UI

```powershell
cd apps\windows\NWVPN
dotnet build -c Release
```

运行（需先有 `nw-client.exe`）：

```powershell
dotnet run -c Release
```

## 托盘行为

- 启动后 **默认只显示托盘图标**；双击托盘或右键 **「打开控制台」** 打开与 mac 类似的设置窗口。  
- 关闭窗口 **不会退出进程**，仅隐藏到托盘；**「退出」** 才会结束应用并断开隧道。  
- 右键 **连接 / 断开** 与窗口内按钮一致（会先保存当前表单到 `%AppData%\NWVPN\settings.json`）。

## 与 mac 的差异说明

| macOS | Windows 本应用 |
|--------|------------------|
| 菜单栏图标 | 系统托盘 `NotifyIcon` |
| Network Extension + System Extension | 子进程 `nw-client`（Wintun） |
| SwiftUI `ContentView` | WPF 表单 |

证书校验：勾选 **「跳过 TLS 证书校验」** 等价于 `nw-client -insecure`；关闭后需填写 **CA PEM** 路径或把 `certs/server.crt` 放在与 `NWVPN.exe` 同目录的 `certs\` 下（与 `nw-client` 默认查找方式一致）。

## 管理员权限

若创建 Wintun 适配器失败，可尝试 **以管理员身份运行** `NWVPN.exe`；具体策略见仓库 `docs/signing-and-ops.md` 中 Windows 相关说明。
